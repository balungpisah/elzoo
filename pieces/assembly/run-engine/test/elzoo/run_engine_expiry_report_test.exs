# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)

defmodule Elzoo.RunEngineExpiryReportTest do
  use ExUnit.Case, async: false
  import Elzoo.RunEngine.TestHelper
  alias Elzoo.{DurableUnit, DynamicUnits, RunEngine}
  alias Elzoo.RunEngine.TestPattern

  # One pinned engine identity: engine record IDs hash it (gate:, out:), and the
  # fixture's own identity is its random schema prefix.
  @identity "elzoo-run-engine-expiry-report"

  # The default-off trace of the recorded scenario, recorded on the base commit
  # 3e412170 before the option existed (three equal runs there).
  @golden_sha256 "36c17202b1427e9e6008a54914f521746b73c5c1c7f3766f4de47640150a9ba4"
  @golden_bytes 19_644

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  setup_all do
    pid = database()
    {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.TestRegistry)
    {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.UnitRegistry)
    for p <- [registry, units], do: Process.unlink(p)
    on_exit(fn -> for p <- [registry, units, pid], Process.alive?(p), do: Supervisor.stop(p) end)
    :ok
  end

  describe "default_off_is_unchanged" do
    test "the recorded scenario without the option has the trace of the base" do
      trace = recorded_scenario([])
      bin = :erlang.term_to_binary(trace, [:deterministic, {:minor_version, 2}])
      sha = Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

      assert {sha, byte_size(bin)} == {@golden_sha256, @golden_bytes}
    end
  end

  # The recorded scenario: the root asks a nested callable C (deadline 55,000) and a
  # person (deadline 30,000); C asks three tool calls (deadline 40,000) and waits.
  # A wake at 30,000 expires the root ask; the Run pauses; a wake at 40,000 expires
  # C's three tool slots while paused; continue; one restart; a wake at 55,000
  # expires the parent and is given to the root; a wake at the Run deadline ends the Run.
  defp recorded_scenario(overrides) do
    root = [request([action("nested", "nested_callable"), action("ask", "ask_person")])]

    tools = request(for id <- ["t1", "t2", "t3"], do: action(id, "tool_call"))

    {c, bindings} =
      nested_setup(%{"nested" => [tools]},
        identity: @identity,
        pattern: {TestPattern, :scripted, %{name: "root", script: root}}
      )

    bindings = deadlines(bindings, %{"nested" => 55_000, "ask" => 30_000})
    engine = start(c, [bindings: bindings] ++ overrides)
    assert {:ok, :applied} = send_input(engine)
    for _ <- 1..3, do: assert_receive({:effect_started, _, _}, 5_000)

    wait_for(engine, fn v ->
      Enum.all?([{2, 0}, {2, 1}, {2, 2}], &(v.slots[&1].phase == :running)) and
        v.slots[{1, 1}].phase == :waiting
    end)

    at(c, 30_000)
    assert {:ok, _} = RunEngine.input(engine, "w1", wake(), verified())
    assert view(engine).slots[{1, 1}].outcome == "expired"
    assert {:ok, :applied} = pause(engine)
    at(c, 40_000)
    assert {:ok, _} = RunEngine.input(engine, "w2", wake(), verified())
    assert Enum.all?([{2, 0}, {2, 1}, {2, 2}], &(view(engine).slots[&1].outcome == "expired"))
    assert {:ok, :applied} = continue(engine)
    engine = restart(c, engine, [bindings: bindings] ++ overrides)
    at(c, 55_000)
    assert {:ok, _} = RunEngine.input(engine, "w3", wake(), verified())
    assert view(engine).slots[{1, 0}].outcome == "expired"
    at(c, 60_000)
    assert {:ok, _} = RunEngine.input(engine, "w4", wake(), verified())
    assert wait_for(engine, &(&1.phase == :terminal)).outcome == :out_of_time

    {unit_inputs(c), unit_state(c), pattern_inputs()}
  end

  # Gives the action of each listed ID the listed deadline.
  defp deadlines(bindings, by_id) do
    Map.new(bindings, fn {kind, binding} ->
      {kind,
       %{
         binding
         | facts: fn a ->
             facts = binding.facts.(a)

             case by_id[a["id"]] do
               nil -> facts
               deadline -> %{facts | deadline_ms: deadline}
             end
           end
       }}
    end)
  end

  defp at(c, ms), do: Agent.update(c.clock, fn _ -> ms end)

  defp pause(engine),
    do: RunEngine.control(engine, "pause", %{kind: :pause, pause_deadline: 50_000}, verified())

  defp continue(engine, id \\ "continue"),
    do:
      RunEngine.control(
        engine,
        id,
        %{kind: :continue, person_id: "person", run_deadline: 60_000},
        verified(%{verified_person: "person"})
      )

  defp identity(c), do: Keyword.fetch!(c.opts, :identity)

  defp restart(c, engine, overrides) do
    GenServer.stop(engine)
    assert :ok = DynamicUnits.stop(c.directory, identity(c))
    Agent.update(c.host_mode, fn _ -> :recover end)
    start(c, overrides)
  end

  defp unit_state(c) do
    {:ok, unit} = DynamicUnits.find(c.directory, identity(c))
    DurableUnit.snapshot(unit)
  end

  # The committed Unit inputs, in commit order: {input ID, record}.
  defp unit_inputs(c) do
    {:ok, rows, _} = Elzoo.DurableLog.read(c.store, identity(c), 1, 1_000)
    for %{kind: "input"} = row <- rows, do: elem(:erlang.binary_to_term(row.payload, [:safe]), 1)
  end

  # Every pattern input sent so far, in order: {callable name, input}.
  defp pattern_inputs(acc \\ []) do
    receive do
      {:pattern_input, name, input} -> pattern_inputs([{name, input} | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end
end
