# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)

defmodule Elzoo.RunEngineDeadlinesTest do
  # ELZ-423: deadlines/1 reads the committed Run deadline and, while paused, the
  # committed pause deadline, from the state that status/1 reads.
  use ExUnit.Case, async: false
  import Elzoo.RunEngine.TestHelper
  alias Elzoo.{DurableUnit, DynamicUnits, RunEngine}
  alias Elzoo.RunEngine.TestPattern

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  setup_all do
    pid = database()
    {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.TestRegistry)
    {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.UnitRegistry)
    for process <- [registry, units], do: Process.unlink(process)

    on_exit(fn ->
      for process <- [registry, units, pid], Process.alive?(process), do: Supervisor.stop(process)
    end)

    :ok
  end

  describe "deadlines_follow_the_lifecycle" do
    test "a new Run reads the start option, no pause deadline, and the phase of status/1" do
      engine = start(asking())
      assert deadlines(engine) == %{phase: :active, run_deadline: 60_000, pause_deadline: nil}
      assert {:ok, :applied} = send_input(engine)
      assert deadlines(engine) == %{phase: :waiting, run_deadline: 60_000, pause_deadline: nil}
    end

    test "pause sets the pause deadline, a second pause keeps it, continue replaces the Run deadline and clears it" do
      engine = start(asking())
      assert {:ok, :applied} = send_input(engine)
      pause(engine, "pause", 50_000)
      assert deadlines(engine) == %{phase: :paused, run_deadline: 60_000, pause_deadline: 50_000}
      pause(engine, "pause-again", 45_000)
      assert deadlines(engine) == %{phase: :paused, run_deadline: 60_000, pause_deadline: 50_000}
      continue(engine, "continue", 70_000)
      assert %{phase: phase, run_deadline: 70_000, pause_deadline: nil} = deadlines(engine)
      assert phase in [:active, :waiting]
    end

    test "an internal pause under budget_rule :pause takes the pause deadline of the pausing record's context" do
      {c, engine} = internal_pause()
      assert deadlines(engine) == %{phase: :paused, run_deadline: 60_000, pause_deadline: 47_000}
      # The record that paused the Run is the local-work outcome, sampled at 47,000;
      # the start input carried 50,000.
      assert local_outcome_contexts(c) == [%{pause_deadline: 47_000}]
    end

    test "a continue that an exhausted Budget leaves paused keeps both committed deadlines" do
      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("cost", "tool_call")])]}},
          budget: %{cap: 1, unit: "credits", id: "budget", incarnation: "sealed"},
          budget_rule: :pause
        )

      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, provider, _}

      # An actual of 3 over a cap of 1 pauses the Run with the input's pause deadline.
      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "actual",
                 result("cost"),
                 verified(%{occurrence: {1, 0}, actual: 3, dispatch: "dispatched"})
               )

      assert deadlines(engine) == %{phase: :paused, run_deadline: 60_000, pause_deadline: 50_000}
      # Timely and verified, so applied, but the Budget keeps the Run paused: the proposed
      # Run deadline is not committed and the pause deadline stays.
      continue(engine, "continue", 70_000)
      assert deadlines(engine) == %{phase: :paused, run_deadline: 60_000, pause_deadline: 50_000}
      send(provider, {:result, %{}})
    end
  end

  describe "deadlines_after_restart" do
    test "after a continue that replaced the Run deadline, a restart with the original options reads the committed values" do
      c = asking()
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      pause(engine, "pause", 50_000)
      continue(engine, "continue", 70_000)
      engine = restart(c, engine)
      assert c.opts[:run_deadline] == 60_000
      assert deadlines(engine) == %{phase: :waiting, run_deadline: 70_000, pause_deadline: nil}

      pause(engine, "pause-2", 55_000)
      engine = restart(c, engine)
      assert deadlines(engine) == %{phase: :paused, run_deadline: 70_000, pause_deadline: 55_000}
    end

    test "after an internal pause, a restart reads the committed pause deadline, not a new context sample" do
      {c, engine} = internal_pause()
      Agent.update(c.context, &Map.put(&1, :pause_deadline, 99_000))
      engine = restart(c, engine)
      assert deadlines(engine) == %{phase: :paused, run_deadline: 60_000, pause_deadline: 47_000}
      assert unit_state(c).control.lifecycle.pause_deadline == 47_000
    end
  end

  describe "deadlines_at_the_end" do
    test "a wake at the Run deadline ends the Run :out_of_time; the Run deadline stays and no pause deadline is read" do
      c = asking()
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      # A continue replaces the start option (60,000), so the terminal read must give 65,000.
      pause(engine, "pause", 50_000)
      continue(engine, "continue", 65_000)
      Agent.update(c.clock, fn _ -> 65_000 end)
      assert {:ok, :applied} = RunEngine.input(engine, "wake", wake(), verified())
      assert view(engine).outcome == :out_of_time
      assert deadlines(engine) == %{phase: :terminal, run_deadline: 65_000, pause_deadline: nil}
    end

    test "a wake at the pause deadline of a paused Run ends it :out_of_time with no pause deadline read" do
      c = asking()
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      pause(engine, "pause", 50_000)
      Agent.update(c.clock, fn _ -> 50_000 end)
      assert {:ok, :applied} = RunEngine.input(engine, "wake", wake(), verified())
      assert view(engine).outcome == :out_of_time
      # The lifecycle keeps the pause deadline it ended on; the read gives it only while paused.
      assert unit_state(c).control.lifecycle.pause_deadline == 50_000
      assert deadlines(engine) == %{phase: :terminal, run_deadline: 60_000, pause_deadline: nil}
    end
  end

  describe "deadlines_wait_for_the_engine" do
    @tag timeout: 30_000
    test "a read sent during an input slower than 5 s replies after it, from the state it committed" do
      parent = self()
      first_call = :atomics.new(1, [])

      engine =
        start(asking(),
          gate: %{
            id: "gate",
            version: 1,
            call: fn _, _ ->
              if :atomics.add_get(first_call, 1, 1) == 1 do
                send(parent, {:gate_barrier, self()})
                receive do: (:release -> :ok)
              end

              :allow
            end
          }
        )

      input = Task.async(fn -> send_input(engine) end)
      assert_receive {:gate_barrier, gate}
      read = Task.async(fn -> RunEngine.deadlines(engine) end)
      # The interval starts once the read is queued at the blocked engine: past the
      # 5,000 ms default of GenServer.call/2 it still waits.
      await_queued(engine, :deadlines)
      assert Task.yield(read, 5_500) == nil
      send(gate, :release)
      assert {:ok, :applied} = Task.await(input, 20_000)

      assert {:ok, %{phase: :waiting, run_deadline: 60_000, pause_deadline: nil} = reply} =
               Task.await(read, 20_000)

      assert reply.phase == view(engine).phase
    end
  end

  defp await_queued(engine, request, left \\ 400) do
    {:messages, messages} = Process.info(engine, :messages)

    cond do
      Enum.any?(messages, &match?({:"$gen_call", _, ^request}, &1)) -> :ok
      left == 0 -> flunk("the read did not reach the engine")
      true -> Process.sleep(5) && await_queued(engine, request, left - 1)
    end
  end

  # A Run whose root asks a person and then waits.
  defp asking,
    do:
      fixture(pattern: {TestPattern, :step, %{requests: [request([action("ask", "ask_person")])]}})

  # A :pause Run at request cap 1: its local work completes at once and the pattern's
  # second request is the first excess, so the local-work outcome pauses the Run with
  # the pause deadline that the context callback gave for it (47,000).
  defp internal_pause do
    c =
      fixture(
        pattern:
          {TestPattern, :step, %{requests: [request([action("a")]), request([action("b")])]}},
        request_cap: 1,
        budget_rule: :pause
      )

    Agent.update(c.context, &Map.put(&1, :pause_deadline, 47_000))
    engine = start(c)
    assert {:ok, :applied} = send_input(engine)
    paused = wait_for(engine, &(&1.phase == :paused))
    assert paused.generation_closed
    assert paused.request_count == 2
    {c, engine}
  end

  defp deadlines(engine) do
    assert {:ok, deadlines} = RunEngine.deadlines(engine)
    assert deadlines.phase == view(engine).phase
    deadlines
  end

  defp pause(engine, id, deadline) do
    assert {:ok, :applied} =
             RunEngine.control(engine, id, %{kind: :pause, pause_deadline: deadline}, verified())
  end

  defp continue(engine, id, deadline) do
    assert {:ok, :applied} =
             RunEngine.control(
               engine,
               id,
               %{kind: :continue, person_id: "person", run_deadline: deadline},
               verified(%{verified_person: "person"})
             )
  end

  # Stops the engine and its Unit, then starts both again on the same journal with the
  # original start options.
  defp restart(c, engine) do
    GenServer.stop(engine)
    assert :ok = DynamicUnits.stop(c.directory, c.prefix)
    Agent.update(c.host_mode, fn _ -> :recover end)
    start(c)
  end

  defp unit_state(c) do
    {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
    DurableUnit.snapshot(unit)
  end

  defp local_outcome_contexts(c) do
    for %{kind: "input"} = row <- rows(c),
        {1, {"local:" <> _, record}} <- [:erlang.binary_to_term(row.payload, [:safe])],
        do: record.context
  end
end
