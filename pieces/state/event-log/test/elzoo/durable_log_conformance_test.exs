# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableLog.ConformanceTest do
  use ExUnit.Case, async: false
  alias Elzoo.DurableLog.{Conformance, Memory}

  @names [
    :append_readback,
    :cas_exclusivity,
    :stale_conflict_replaces_nothing,
    :duplicate_insert_refused,
    :atomic_head_record_outbox,
    :unavailable_readback,
    :checkpoint_bounded_by_tail,
    :ack_cas,
    :restart_replay,
    :preflight_writes_nothing,
    :retention_bounded_by_checkpoint
  ]
  @limits %{max_record_bytes: 64, max_batch_size: 8, max_checkpoint_bytes: 10_000}
  defp factory do
    fn ->
      fold = %{
        initial: 0,
        kinds: %{"added" => :state_bearing},
        versions: [1],
        destinations: ["sink"],
        reduce: fn n, _, _, _ -> n + 1 end
      }

      pid =
        start_supervised!(
          Supervisor.child_spec({Memory, fold: fold, limits: @limits}, id: make_ref())
        )

      {Memory.store(pid),
       %{
         fold: fold,
         limits: @limits,
         record: {"added", 1, "event"},
         destination: "sink",
         encode: &Integer.to_string/1,
         hook: &Memory.conformance_hook/3
       }}
    end
  end

  test "K1–K11 names and order match the Contract" do
    assert Keyword.keys(Conformance.checks()) == @names
    assert Enum.all?(Conformance.checks(), fn {_, f} -> is_function(f, 1) end)
  end

  for {name, index} <- Enum.with_index(@names, 1) do
    test "K#{index} #{name} against volatile Memory" do
      assert :ok == Keyword.fetch!(Conformance.checks(), unquote(name)).(factory())
    end
  end

  test "bad factories, missing hooks and foreign failures return errors instead of raising" do
    check = Keyword.fetch!(Conformance.checks(), :append_readback)
    assert {:error, _} = check.(fn -> nil end)
    assert {:error, _} = check.(fn -> raise "factory failed" end)
    assert {:error, {:foreign_failure, :exit}} = check.(fn -> exit(:unavailable) end)
    {store, opts} = factory().()
    fault_check = Keyword.fetch!(Conformance.checks(), :atomic_head_record_outbox)
    assert {:error, _} = fault_check.(fn -> {store, Map.delete(opts, :hook)} end)
  end

  defmodule RaisingStore do
    def append(_, _, _, _, _), do: raise("callback failed")
  end

  test "callback failures also return errors from concurrent conformance checks" do
    {_, opts} = factory().()

    for name <- [:append_readback, :cas_exclusivity] do
      check = Keyword.fetch!(Conformance.checks(), name)
      assert {:error, _} = check.(fn -> {{RaisingStore, %{}}, opts} end)
    end
  end
end
