# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RetryTimeoutAdapterTest do
  use ExUnit.Case, async: false
  alias Elzoo.RetryTimeout, as: R
  alias Elzoo.RetryTimeout.Runner

  defmodule Codec do
    @behaviour Elzoo.UnitAdapter.Codec
    def decode_payload("test/input", 1, value), do: {:ok, value}
    def encode_output({:some, value}), do: {:ok, value}
    def value_schema, do: {"test/output", 1}
  end

  defp wiring do
    port = fn id, direction ->
      %{
        "port" => %{
          "id" => id,
          "direction" => direction,
          "schema_id" => "test/input",
          "schema_version" => 1
        },
        "delivery" => "fused",
        "required_route" => true
      }
    end

    %{
      "version" => 1,
      "units" => [%{"id" => "pipeline", "ports" => [port.("out", "output"), port.("in", "input")]}],
      "edges" => [
        %{
          "id" => "ingress",
          "placement" => "fused",
          "source" => %{"unit_id" => "pipeline", "port_id" => "out"},
          "target" => %{"unit_id" => "pipeline", "port_id" => "in"}
        }
      ]
    }
  end

  test "unchanged Adapter distinguishes explicit absence from noproc after dispatch" do
    tasks = start_supervised!({Task.Supervisor, []})
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _}
    parent = self()

    for {lookup, attempts, reason} <- [
          {:restarting, 2, "retries_exhausted"},
          {dead, 1, "dispatched_unresolved"}
        ] do
      attempt = fn request ->
        send(parent, {:attempt, request})
        {:ok, response} = Elzoo.UnitAdapter.deliver(lookup, wiring(), "ingress", request, Codec)
        response
      end

      {:ok, policy} = R.policy(max_attempts: 2, base_backoff_ms: 0, max_backoff_ms: 0)

      runner =
        start_supervised!(
          {Runner,
           [
             capacity: 1,
             policy: policy,
             attempt_timeout_ms: 1000,
             attempt: attempt,
             dead_letter: fn _ -> :ok end,
             task_supervisor: tasks
           ]},
          id: make_ref()
        )

      request = %{
        "version" => 1,
        "message_id" => "adapter",
        "schema_id" => "test/input",
        "schema_version" => 1,
        "kind" => "event",
        "producer" => %{"unit_id" => "pipeline", "port_id" => "out"},
        "payload" => 3
      }

      {:ok, ref} = Runner.submit(runner, request)
      assert_receive {R, ^ref, {:dead_lettered, record}}, 1000
      assert record["reason"] == reason
      assert record["attempts"] == attempts

      assert record["last_dispatch"] ==
               if(lookup == :restarting, do: "not_dispatched", else: "unknown")

      for _ <- 1..attempts, do: assert_receive({:attempt, _})
      refute_receive {:attempt, _}, 10
    end
  end
end
