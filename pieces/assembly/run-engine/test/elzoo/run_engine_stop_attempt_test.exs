# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)

defmodule Elzoo.RunEngineStopAttemptTest.CompleteForwarder do
  # A seam between the engine and its Run owner: every call goes to the owner, except
  # what `mode` decides. `:kill` kills the engine at its `:complete` command, before the
  # owner sees it (a crash after the pending stop and any evidence row commit). `:refuse`
  # answers every `:complete` command `{:error, :unavailable}`, so the stop stays pending.
  # `{:begin_at_stop, stopped?, attempt, then, test}` begins `attempt` on the owner at the
  # first status read at which `stopped?.()` holds (the engine's revision sample for its
  # `:complete` command), gives that command to the owner as it comes, sends the command
  # and the owner's reply to `test` and gives the reply to the engine. Then `then` is
  # `:kill_at_status` (the engine is killed at its next status read, before it can
  # journal the new Run view) or `:spent` (every later call goes to the owner).
  use GenServer

  def init(arg), do: {:ok, arg}

  def handle_call({:command, %{kind: :complete}}, {caller, _}, {run, :kill}) do
    Process.exit(caller, :kill)
    {:noreply, {run, :spent}}
  end

  def handle_call({:command, %{kind: :complete}}, _from, {_run, :refuse} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call(
        {:status, _} = status,
        _from,
        {run, {:begin_at_stop, stopped?, attempt, then, test}} = state
      ) do
    if stopped?.() do
      {:ok, view} = GenServer.call(run, status, 60_000)

      begin = %{
        kind: :begin_attempt,
        run_id: view.id,
        attempt_id: attempt,
        expected_revision: view.revision
      }

      {:ok, _, _} = GenServer.call(run, {:command, begin}, 60_000)
      {:reply, GenServer.call(run, status, 60_000), {run, {:complete, then, test}}}
    else
      {:reply, GenServer.call(run, status, 60_000), state}
    end
  end

  def handle_call(
        {:command, %{kind: :complete} = command} = message,
        _from,
        {run, {:complete, then, test}}
      ) do
    reply = GenServer.call(run, message, 60_000)
    send(test, {:complete_reply, command, reply})
    {:reply, reply, {run, then}}
  end

  def handle_call({:status, _}, {caller, _}, {run, :kill_at_status}) do
    Process.exit(caller, :kill)
    {:noreply, {run, :spent}}
  end

  # `:over_revision` answers each status read with the owner's view at revision 2^63, one
  # past the largest that the engine takes; `{:set_mode, mode}` switches the mode.
  def handle_call({:set_mode, mode}, _from, {run, _}), do: {:reply, :ok, {run, mode}}

  def handle_call({:status, _} = status, _from, {run, :over_revision} = state) do
    {:ok, view} = GenServer.call(run, status, 60_000)
    {:reply, {:ok, %{view | revision: 9_223_372_036_854_775_808}}, state}
  end

  # `{:revision, real, shown, then}` answers a status read at the owner's revision `real`
  # with `shown` and gives the owner a command that expects `shown` with `real`; with
  # `then` `:kill` it kills the engine at its `:complete` command, then goes on as `:pass`.
  def handle_call({:status, _} = status, _from, {run, {:revision, real, shown, _}} = state) do
    {:ok, view} = GenServer.call(run, status, 60_000)
    {:reply, {:ok, if(view.revision == real, do: %{view | revision: shown}, else: view)}, state}
  end

  def handle_call({:command, %{kind: :complete}}, {caller, _}, {run, {:revision, r, s, :kill}}) do
    Process.exit(caller, :kill)
    {:noreply, {run, {:revision, r, s, :pass}}}
  end

  def handle_call({:command, command}, _from, {run, {:revision, real, shown, _}} = state) do
    command =
      if command[:expected_revision] == shown,
        do: %{command | expected_revision: real},
        else: command

    {:reply, GenServer.call(run, {:command, command}, 60_000), state}
  end

  def handle_call(message, _from, {run, _} = state),
    do: {:reply, GenServer.call(run, message, 60_000), state}
end

defmodule Elzoo.RunEngineStopAttemptTest do
  # ELZ-430: every pending stop (`:completed`, `:failed`, `:cancelled`, `:out_of_time`,
  # `:out_of_budget`), its evidence row where one is written and the owner command are
  # bound to the Attempt that produced the stop; a change of Attempt drops a stale stop, a
  # start or a replacement Unit decides a pending stop before any engine write from the
  # owner's committed Run view and the stop's mark, and the first pending stop wins over a
  # later lifecycle stop, which leaves no trace.
  use ExUnit.Case, async: false
  import Elzoo.RunEngine.TestHelper, except: [result: 1, result: 2]
  alias Elzoo.{DurableLog, DurableUnit, DynamicUnits, RunEngine}
  alias Elzoo.RunApprovalRelease, as: Run
  alias Elzoo.RunEngine.TestPattern
  alias Elzoo.RunEngineStopAttemptTest.CompleteForwarder

  setup do
    Process.flag(:trap_exit, true)
    Process.register(self(), :run_engine_observer)
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

  # A root finish that names no action fails the Run; the fixture's `result` schema
  # admits it.
  @null %{"status" => "stopped", "action_id" => nil}

  # The control facts of a pending stop that the fold before ELZ-430 kept at a change of
  # Attempt (it dropped only a root failure), the mark of this fold included.
  @stop_facts [:stop_pending, :completion, :generation_closed, :cancelled_attempt, :stop_attempt]

  # The stops that earlier_fold_stop builds in v1 and v2 as the fold before ELZ-430 recorded
  # them (earlier/2): {source, replaced}, where `replaced` adds a wake past the Run deadline
  # whose out_of_time that fold let take the place of the stop (a cancel here).
  @earlier [completed: false, cancelled: false, run_deadline: false, cancelled: true]

  # The bytes of the control bound that admission keeps free while no stop is pending.
  @room 695

  # The largest time and Run revision that the engine takes.
  @max_time 9_223_372_036_854_775_807

  # A Resource rate per minute whose actual for one minute's use encodes in 400 bytes.
  @rate Integer.pow(2, 8 * 396)

  # Each source of a pending stop. `:completed` is a root finish naming a completed
  # action; `:failed` a root finish naming no action; `:cancelled` a cancel while local
  # work runs; `:run_deadline` a wake past the Run deadline and `:pause_deadline` a wake
  # at the pause deadline of a paused Run (the Run deadline still ahead), both
  # `:out_of_time`; `:budget` a local-work outcome that spends the monetary Budget and
  # `:request_cap` a wake at the request cap, both `:out_of_budget` under
  # `budget_rule: :finish`.
  @sources [
    :completed,
    :failed,
    :cancelled,
    :run_deadline,
    :pause_deadline,
    :budget,
    :request_cap
  ]

  describe "crash_before_the_owner_command" do
    for source <- @sources do
      test "#{source}: a new Attempt begun before the restart drops the stale stop" do
        cut(unquote(source), :kill)
      end
    end
  end

  describe "stale_answer_then_crash" do
    for source <- @sources do
      test "#{source}: the owner answers the stop's Attempt stale; after a crash before the new Run view is journaled, the restart drops the stop" do
        cut(unquote(source), :stale_kill)
      end
    end
  end

  describe "stale_answer_syncs" do
    for source <- @sources do
      test "#{source}: the owner's stale answer itself makes the engine take the new Run view, which drops the stop" do
        cut(unquote(source), :stale)
      end
    end
  end

  describe "earlier_fold_stop" do
    test "one Attempt: a completion, a cancel, a Run-deadline stop and a stop that replaced a cancel, as the earlier fold recorded them from the producing step on, are delivered, in v1 and v2" do
      for version <- [1, 2], {source, replaced} <- @earlier do
        label = label(source, replaced, version)
        c = earlier(source, version: version, replaced: replaced)
        stop = if replaced, do: :out_of_time, else: stop(source)
        engine = start(c)
        assert %{phase: :terminal, outcome: ^stop} = wait_for(engine, &(&1.outcome != nil)), label
        assert {:ok, %{outcome: ^stop, current_attempt: "attempt"}} = Run.status(c.run, "run")
        assert [{:terminal, "run", ^stop, "engine", _, _}] = terminal_rows(c), label
        assert {:ok, %{entries: [_ | _]}} = transcript(engine), label

        if stop == :completed,
          do: assert({:ok, %{action_id: "work"}} = result(engine), label),
          else: assert({:terminal, ^stop} = result(engine), label)
      end
    end

    test "two Attempts: such a stop kept at the change of Attempt (in v1 also a Budget, pause-deadline and request-cap stop) is refused with no write, also after a lease renewal alone, in v1 and v2" do
      cases =
        for(version <- [1, 2], {source, replaced} <- @earlier, do: {source, replaced, version}) ++
          for source <- [:budget, :pause_deadline, :request_cap], do: {source, false, 1}

      for {source, replaced, version} <- cases do
        label = label(source, replaced, version)
        c = earlier(source, version: version, replaced: replaced, attempts: 2)
        control = last_state(c).control
        stop = if replaced, do: :out_of_time, else: stop(source)
        assert %{stop_pending: ^stop, attempt_id: "second"} = control, label
        refute Map.has_key?(control, :stop_attempt), label

        assert {:ok, %{current_attempt: "second", attempts: ["attempt", "second"]}} =
                 Run.status(c.run, "run")

        assert_refused(c, label)
        assert {:ok, _, _} = Run.renew(c.run, 3_600_000)
        assert_refused(c, "#{label} after a lease renewal")
      end
    end

    test "two Attempts: after the refusal, the host's end of the Run or its new Attempt on the owner is taken at the next start, with no owner command for the stop" do
      for host <- [:cancel, :begin_attempt] do
        c = earlier(:cancelled, attempts: 2)
        assert_refused(c)

        case host do
          :cancel ->
            {:ok, owner} = Run.status(c.run, "run")

            assert {:ok, _, _} =
                     Run.command(c.run, %{
                       kind: :cancel,
                       run_id: "run",
                       attempt_id: "second",
                       expected_revision: owner.revision
                     })

            engine = start(c)
            assert %{phase: :terminal, outcome: :cancelled, reconciliation: nil} = view(engine)
            assert [{:terminal, "run", :cancelled, nil, nil, _}] = terminal_rows(c)
            assert {:terminal, :cancelled} = result(engine)
            assert {:ok, %{entries: [_ | _]}} = transcript(engine)

          :begin_attempt ->
            begin_attempt(c, "third")
            engine = start(c)
            assert %{attempt_id: "third", stop_pending: nil, outcome: nil} = view(engine)
            assert terminal_rows(c) == []
            flush_pattern_inputs()
            third = verified(%{attempt_id: "third"})
            assert {:ok, :applied} = RunEngine.input(engine, "third-wake", input(c, "wake"), third)
            assert_receive {:pattern_input, "root", %{"kind" => "wake"}}, 2_000
            assert {:ok, %{entries: [_ | _]}} = transcript(engine)
        end

        assert evidence_rows(c) == []
      end
    end

    test "two Attempts: owner changes that are neither a new Attempt nor an outcome (another Run's create, a lease renewal, a child attached to this Run) leave the refusal" do
      c = earlier(:cancelled, attempts: 2)
      {:ok, recorded} = Run.status(c.run, "run")
      create_other(c)
      assert {:ok, _, _} = Run.renew(c.run, 3_600_000)
      {:ok, owner} = Run.status(c.run, "run")

      assert {:ok, _, _} =
               Run.command(c.run, %{
                 kind: :attach_child,
                 run_id: "run",
                 attempt_id: "second",
                 child_run_id: "other",
                 child_pid: nil,
                 expected_revision: owner.revision
               })

      assert {:ok, %{outcome: nil, current_attempt: "second", revision: revision}} =
               Run.status(c.run, "run")

      assert revision > recorded.revision + 2
      assert_refused(c)
    end
  end

  describe "start_decision" do
    test "two Attempts: a stop that this fold set for the recorded Attempt is delivered as committed, with the clock set back before the deadline" do
      c = fixture_for(:run_deadline, 1)
      engine = start(c, run_owner: forwarder(c, :kill))
      monitor = Process.monitor(engine)
      assert {:ok, :applied} = start_run(c, engine)
      begin_attempt(c, "second")
      assert {:ok, :applied} = second_wake(c, engine)
      Agent.update(c.clock, fn _ -> 61_000 end)
      late = verified(%{attempt_id: "second"})
      call(fn -> RunEngine.input(engine, "late-wake", input(c, "wake"), late) end)
      assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000

      assert %{stop_pending: :out_of_time, attempt_id: "second"} = control = unit_state(c).control
      assert control.stop_attempt == {"second", :out_of_time}

      Agent.update(c.clock, fn _ -> 3_000 end)
      engine = start(c)
      assert %{outcome: :out_of_time, attempt_id: "second"} = wait_for(engine, &(&1.outcome != nil))
      assert [{:terminal, "run", :out_of_time, "engine", nil, _}] = terminal_rows(c)
      assert {:ok, %{outcome: :out_of_time, current_attempt: "second"}} = Run.status(c.run, "run")
    end

    test "one Attempt: a completion that this fold set, which the fold before ELZ-430 kept through a :pause wake at the request cap that stopped the charge, is delivered as committed, and the v2 history reads" do
      c =
        run_fixture(
          fn frame ->
            [
              frame.([action("work")]),
              frame.([finish_action("finish", %{"action_id" => "work"})])
            ]
          end,
          2,
          request_cap: 2,
          budget_rule: :pause,
          unit_store: memory_unit_store(2)
        )

      engine = start(c, run_owner: forwarder(c, :kill))
      monitor = Process.monitor(engine)
      assert {:ok, :applied} = start_run(c, engine)
      assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
      assert %{stop_pending: :completed, count: 2, cap: 2} = unit_state(c).control

      # A timely wake at the request cap pauses the Run; the fold before ELZ-430 also
      # stopped the charge while the completion was pending, and this fold does not.
      wake =
        record(c, "cap-wake", input(c, "wake", %{"at_ms" => 3_000}),
          context: %{pause_deadline: 50_000}
        )

      step =
        append_legacy(c, "cap-wake", wake, fn _before, next ->
          put_in(next.control.charge_stopped, true)
        end)

      assert %{phase: :paused} = step.legacy.control.lifecycle
      refute step.current.control.charge_stopped

      # The completion is the recorded Attempt's: the owner records it as committed, with
      # the reason of the committed charge stop.
      Agent.update(c.clock, fn _ -> 3_000 end)
      engine = start(c)
      assert %{outcome: :completed} = wait_for(engine, &(&1.outcome != nil))
      assert [{:terminal, "run", :completed, "request_cap", %{}, _}] = terminal_rows(c)
      assert {:ok, %{entries: [_ | _]}} = transcript(engine)
      assert {:ok, %{waits: []}} = RunEngine.event_waits(engine, scope(), limits())
      assert {:ok, %{action_id: "work"}} = result(engine)
    end

    test "two Attempts: the Unit finishes a committed but unpaired wake at the start, as at every open; it leaves the earlier-fold stop as it is, and the start is refused with no engine write" do
      c = earlier(:cancelled, attempts: 2)
      wake = record(c, "late-input", input(c, "wake"), attempt_id: "second")
      append_input(c, "late-input", wake)
      before = rows(c)
      {:ok, owner} = Run.status(c.run, "run")
      assert {:error, :stop_origin_unknown} = RunEngine.start_link(c.opts)
      assert Enum.take(rows(c), length(before)) == before
      assert [%{kind: "result"} = paired] = Enum.drop(rows(c), length(before))
      assert {1, {"late-input", state}} = decode(paired)

      assert %{stop_pending: :cancelled, attempt_id: "second"} = state.control
      refute Map.has_key?(state.control, :stop_attempt)

      assert {evidence_rows(c), Run.status(c.run, "run"), terminal_rows(c)} ==
               {[], {:ok, owner}, []}
    end

    test "a completion stop whose completion slot is missing gives integrity_failure at the start, with no write and no owner command" do
      c = crashed(:completed, unit_store: memory_unit_store(1))
      assert :ok = DynamicUnits.stop(c.directory, c.prefix)
      [last | _] = Enum.reverse(rows(c))
      assert last.kind == "result"
      {1, {id, state}} = decode(last)
      assert %{stop_pending: :completed, completion: source} = state.control
      corrupt_row(c, last, {1, {id, update_in(state.slots, &Map.delete(&1, source))}})
      before = {rows(c), evidence_rows(c), Run.status(c.run, "run")}
      assert {:error, :integrity_failure} = RunEngine.start_link(c.opts)
      assert {rows(c), evidence_rows(c), Run.status(c.run, "run")} == before
      assert terminal_rows(c) == []
    end
  end

  describe "replacement_unit" do
    test "two Attempts: an input after the Unit was replaced by one whose journal holds an earlier-fold stop halts the engine stop_origin_unknown, with no write and no owner command" do
      {c, engine} = running_in_second_with_earlier_stop()
      before = {rows(c), evidence_rows(c), Run.status(c.run, "run")}
      second = verified(%{attempt_id: "second"})

      assert {:error, :stop_origin_unknown} =
               RunEngine.input(engine, "next", input(c, "wake"), second)

      assert {rows(c), evidence_rows(c), Run.status(c.run, "run")} == before
      assert %{reconciliation: :stop_origin_unknown} = view(engine)
      assert terminal_rows(c) == []
    end

    test "two Attempts: an outbox offer that comes after the Unit stopped runs the Unit check before the drain, and the earlier-fold stop halts the engine with no owner command" do
      {c, engine} = running_in_second_with_earlier_stop()
      before = {rows(c), evidence_rows(c), Run.status(c.run, "run")}
      send(engine, %Elzoo.Outbox.Item{payload: binary({1, {:request, 1}})})
      assert %{reconciliation: :stop_origin_unknown} = wait_for(engine, &(&1.reconciliation != nil))
      assert {rows(c), evidence_rows(c), Run.status(c.run, "run")} == before
      assert terminal_rows(c) == []
    end

    test "a replacement Unit takes the owner's new Attempt before it records the loss of the older Attempt's running local work" do
      c = fixture_for(:cancelled, 1)
      engine = start(c)
      assert {:ok, :applied} = start_run(c, engine)
      assert_receive {:local_started, _}, 5_000
      assert :ok = DynamicUnits.stop(c.directory, c.prefix)
      begin_attempt(c, "second")
      assert {:ok, :applied} = second_wake(c, engine)
      assert {_, %{phase: :settled}} = slot_of(view(engine), "slow")
      assert [_] = for(%{kind: :run_view, view: %{current_attempt: "second"}} <- records(c), do: 1)
      refute Enum.any?(records(c), &match?(%{kind: :protocol, correlation: %{loss: _}}, &1))
    end
  end

  describe "pending_stop_replay" do
    test "a Run view changed to name the older Attempt is damaged history, in v1 and v2" do
      for source <- [:completed, :cancelled], version <- [1, 2] do
        {c, engine} = dropped_on_memory(source, version)
        assert {:ok, %{entries: [_ | _]}} = transcript(engine)

        # Only the Run-view input now names the older Attempt, its row digest made valid;
        # its recorded state (the new Attempt, the stop dropped) is left as it was.
        {row, id, record} = new_attempt_view_row(c)
        corrupt_row(c, row, {1, {id, put_in(record.view.current_attempt, "attempt")}})
        assert_history(transcript(engine), "#{source} v#{version}")
      end
    end

    test "a Run view that kept the older Attempt's stop, as the fold before ELZ-430 recorded it, reads as recorded, in v1 and v2" do
      for source <- [:completed, :cancelled], version <- [1, 2] do
        {c, engine} = dropped_on_memory(source, version)
        {row, _id, record} = new_attempt_view_row(c)
        {before, {id, dropped}, paired} = step_states(c, row)

        # The state with the stop facts of the state before kept is exactly the step of the
        # fold before ELZ-430, and not of this fold, which drops them.
        kept =
          put_in(dropped.control, Map.merge(dropped.control, Map.take(before.control, @stop_facts)))

        assert kept.control.stop_pending == stop(source)
        assert {:ok, kept} === RunEngine.project_event_wait_transition(before, record, :base)
        assert {:ok, dropped} === RunEngine.project_event_wait_transition(before, record)
        corrupt_row(c, paired, {1, {id, kept}})
        assert {:ok, %{entries: [_ | _]}} = transcript(engine), "#{source} v#{version}"
      end
    end

    test "a terminal Run view whose recorded state keeps the pending stop is damaged history, in v1 and v2" do
      for source <- [:completed, :failed], version <- [1, 2] do
        stop = stop(source)
        c = fixture_for(source, version, unit_store: memory_unit_store(version))
        engine = start(c)
        assert {:ok, :applied} = start_run(c, engine)
        wait_for(engine, &(&1.outcome == stop))
        assert {:ok, %{entries: [_ | _]}} = transcript(engine)
        assert {:ok, %{waits: []}} = RunEngine.event_waits(engine, scope(), limits())
        assert elem(result(engine), 0) in [:ok, :failed]

        # The state recorded after the terminal Run view keeps the stop pending, its row
        # digest made valid; the Run view itself is left as it was.
        {row, _id, _record} =
          input_row(c, &match?(%{kind: :run_view, view: %{outcome: ^stop}}, &1))

        {_before, {id, state}, paired} = step_states(c, row)
        assert state.control.stop_pending == nil
        corrupt_row(c, paired, {1, {id, put_in(state.control.stop_pending, stop)}})
        label = "#{source} v#{version}"
        assert_history(transcript(engine), "#{label} transcript")
        assert_history(RunEngine.event_waits(engine, scope(), limits()), "#{label} event_waits")
        assert_history(result(engine), "#{label} result")
      end
    end

    test "a completed terminal view whose recorded lifecycle outcome alone is changed to cancelled is damaged history, in v1" do
      terminal_tamper(1, &put_in(&1.control.lifecycle.outcome, :cancelled))
    end

    test "a completed terminal view whose recorded Run revision alone is changed to an equal float is damaged history, in v2" do
      terminal_tamper(2, &put_in(&1.control.run_revision, &1.control.run_revision / 1))
    end

    test "a terminal Run view recorded with the close before ELZ-215 while a cancel was pending (the running local work closed, a waiting ask left open) is damaged history, in v1" do
      {_c, engine} = pre_215_close(1, :cancel_input)
      assert_history(transcript(engine), "v1 transcript")
      assert_history(RunEngine.event_waits(engine, scope(), limits()), "v1 event_waits")
    end

    test "the same terminal view is damaged history in v2" do
      {_c, engine} = pre_215_close(2, :cancel_input)
      assert_history(transcript(engine), "v2 transcript")
      assert_history(RunEngine.event_waits(engine, scope(), limits()), "v2 event_waits")
    end

    test "with no stop pending, the host's own cancel taken as a terminal Run view recorded with the close before ELZ-215 is damaged history, in v1 and v2" do
      for version <- [1, 2] do
        {_c, engine} = pre_215_close(version, :owner_cancel)
        assert_history(transcript(engine), "v#{version} transcript")
        assert_history(RunEngine.event_waits(engine, scope(), limits()), "v#{version} event_waits")
      end
    end

    test "a lifecycle stop that replaced a pending completion, as the fold before ELZ-430 recorded it, reads as recorded, in v1 and v2" do
      for version <- [1, 2] do
        c = run_fixture(&completed_while_slow/1, version, unit_store: memory_unit_store(version))
        engine = start(c, run_owner: forwarder(c, :kill))
        monitor = Process.monitor(engine)
        assert {:ok, :applied} = start_run(c, engine)
        assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
        assert_receive {:local_started, _}, 5_000
        Agent.update(c.clock, fn _ -> 61_000 end)
        engine = start(c)
        assert %{outcome: :completed} = wait_for(engine, &(&1.outcome != nil))

        # The recorded state after the loss of `slow` past the Run deadline now holds the
        # out_of_time that its lifecycle step asked for in place of the pending
        # completion: exactly the step of the fold before ELZ-430.
        {row, _id, record} =
          input_row(
            c,
            &match?(%{kind: :protocol, input: %{"at_ms" => 61_000}, correlation: %{loss: _}}, &1)
          )

        {before, {id, state}, paired} = step_states(c, row)
        assert state.control.stop_pending == :completed
        replaced = put_in(state.control.stop_pending, :out_of_time)
        assert {:ok, replaced} === RunEngine.project_event_wait_transition(before, record, :base)
        corrupt_row(c, paired, {1, {id, replaced}})
        assert {:ok, %{entries: [_ | _]}} = transcript(engine), "v#{version}"
        assert {:ok, %{action_id: "work"}} = result(engine), "v#{version}"
      end
    end
  end

  describe "completion_by_its_finish_record" do
    test "a root finish held for Approval, settled by its correlated outcome and named by another root finish, completes the Run" do
      script = fn frame ->
        [
          frame.([finish_action("held", %{"value" => 1})]),
          frame.([finish_action("finish", %{"action_id" => "held"}, "message")])
        ]
      end

      c = run_fixture(script, 1)
      require_approval(c)
      computation = c.opts[:bindings]["finish"]
      held = %{computation | effect_class: "publish", id: "held-binding"}
      bindings = Map.put(c.opts[:bindings], "finish", %{"result" => held, "message" => computation})
      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = start_run(c, engine)

      {key, _} =
        engine
        |> wait_for(&match?({_, %{phase: :approval}}, slot_of(&1, "held")))
        |> slot_of("held")

      outcome = Elzoo.RunEngine.TestHelper.result("held")
      context = verified(%{occurrence: key, actual: 1, dispatch: "dispatched"})
      assert {:ok, :applied} = RunEngine.input(engine, "held-outcome", outcome, context)
      assert %{outcome: :completed} = wait_for(engine, &(&1.outcome != nil))
      assert [%{source: ^key}] = for(%{kind: :finish} = r <- records(c), do: r)
      assert [{:terminal, "run", :completed, "engine", %{}, _}] = terminal_rows(c)
      assert {:ok, %{action_id: "held"}} = result(engine)
    end
  end

  describe "losing_cancel_keeps_the_work" do
    test "a cancel control that loses to a request-cap stop that its current/1 took from a Resource outcome cancels no work" do
      payload = %{"run_id" => "run", "resource_name" => "document", "data" => %{}}

      script = fn frame ->
        [
          frame.([action("open", "resource_open", payload), action("slow")]),
          frame.([action("more")])
        ]
      end

      c = run_fixture(script, 1, request_cap: 1)
      {owner, bindings} = resource(c)
      engine = start(c, resources: %{"document" => owner}, bindings: bindings)
      assert {:ok, :applied} = start_run(c, engine)
      assert_receive {:effect_started, _opening, _}, 5_000
      assert_receive {:local_started, task}, 5_000

      assert {:ok, _} =
               Elzoo.RunResource.command(owner, %{
                 id: "opened",
                 at_ms: 2_000,
                 body:
                   {:observed, ["tenant", "account", "effect", "publish", "open"],
                    {:completed, %{opened_at_ms: 2_000}}}
               })

      # The control's current/1 reads the open's outcome first: the root asks over the
      # cap, and the request-cap stop is pending before the cancel applies, which loses.
      cancel = %{kind: :cancel, attempt_id: "attempt"}
      assert {:ok, :applied} = RunEngine.control(engine, "cancel", cancel, verified())
      view = view(engine)
      assert %{phase: :terminal, outcome: :out_of_budget} = view
      assert [{:terminal, "run", :out_of_budget, "request_cap", nil, _}] = terminal_rows(c)
      assert unit_state(c).control.cancelled_attempt == nil

      # The stop retains the running work, and its task runs on and settles it.
      assert {_, %{phase: :running}} = slot_of(view, "slow")
      assert Process.alive?(task)
      send(task, :finish)
      wait_for(engine, &match?({_, %{phase: :settled, outcome: "completed"}}, slot_of(&1, "slow")))
    end

    test "an input whose context holds cancel_work: true, past a running slot's deadline, cancels no task" do
      c = fixture_for(:cancelled, 1)
      engine = start(c)
      assert {:ok, :applied} = start_run(c, engine)
      assert_receive {:local_started, task}, 5_000
      assert {_, %{phase: :running, deadline_ms: deadline}} = slot_of(unit_state(c), "slow")
      assert deadline < 60_000
      Agent.update(c.clock, fn _ -> deadline end)
      monitor = Process.monitor(task)
      context = verified(%{cancel_work: true})
      assert {:ok, :applied} = RunEngine.input(engine, "late-wake", input(c, "wake"), context)
      assert {_, %{phase: :settled}} = slot_of(view(engine), "slow")
      refute_receive {:DOWN, ^monitor, :process, ^task, _}, 500
    end
  end

  describe "first_stop_wins" do
    test "a pending completion: a restart past the Run deadline with local work running records it, in v1 and v2" do
      for version <- [1, 2] do
        c = run_fixture(&completed_while_slow/1, version)

        # The finish is dispatched while `slow` runs; the engine dies at its owner command,
        # after the completion and its evidence row.
        engine = start(c, run_owner: forwarder(c, :kill))
        monitor = Process.monitor(engine)
        assert {:ok, :applied} = start_run(c, engine)
        assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
        assert_receive {:local_started, _}, 5_000
        state = unit_state(c)
        assert %{stop_pending: :completed, completion: source} = state.control
        assert {_, %{phase: :running}} = slot_of(state, "slow")
        assert [orphan] = evidence_rows(c)

        # From that state a wake past the Run deadline, a cancel and a wake at the request
        # cap each ask the lifecycle for a stop; each step keeps the completion, and the
        # cancel and the wake at the cap leave no trace of their own.
        at_cap = put_in(state.control.count, state.control.cap)

        for {from, input, asked} <- [
              {state, Map.put(input(c, "wake"), "at_ms", 61_000), :out_of_time},
              {state, input(c, "cancel", %{"attempt_id" => "attempt"}), :cancelled},
              {at_cap, input(c, "wake"), :out_of_budget}
            ] do
          assert {:Transition, next, :none} = RunEngine.step(from, record(c, "later", input))
          assert next.control.classification == {:request_outcome, asked}
          assert %{stop_pending: :completed, completion: ^source} = next.control
          assert %{charge_stopped: false, cancelled_attempt: nil} = next.control

          if asked != :out_of_time,
            do: assert({_, %{phase: :running}} = slot_of(next, "slow"))
        end

        # The restart is past the Run deadline: recovery records the loss of `slow` at that
        # time and the lifecycle asks for out_of_time in that step. The completion stays.
        Agent.update(c.clock, fn _ -> 61_000 end)
        engine = start(c)
        assert %{phase: :terminal, outcome: :completed} = wait_for(engine, &(&1.outcome != nil))

        assert [_] =
                 for(
                   %{kind: :protocol, input: %{"at_ms" => 61_000}, correlation: %{loss: _}} <-
                     records(c),
                   do: :loss
                 )

        assert [^orphan, named] = evidence_rows(c)
        ref = %{stream: "evidence", sequence: named.sequence}
        assert [{:terminal, "run", :completed, "engine", ^ref, _}] = terminal_rows(c)

        assert {:ok,
                %{
                  attempt_id: "attempt",
                  action_id: "work",
                  payload: %{"value" => 7},
                  evidence_ref: ^ref
                }} = result(engine)
      end
    end

    test "a pending cancellation that settled running local work: a wake past the Run deadline or at the request cap keeps it, and a restart past the deadline records it, in v1 and v2" do
      for version <- [1, 2] do
        c = fixture_for(:cancelled, version)
        engine = start(c, run_owner: forwarder(c, :kill))
        monitor = Process.monitor(engine)
        drive(c, engine, :cancelled)
        assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000

        # The cancel settled the running local work in its own step.
        state = unit_state(c)
        assert %{stop_pending: :cancelled, cancelled_attempt: "attempt"} = state.control
        assert {_, %{phase: :settled, outcome: "failed"}} = slot_of(state, "slow")
        at_cap = put_in(state.control.count, state.control.cap)

        for {from, input, asked} <- [
              {state, Map.put(input(c, "wake"), "at_ms", 61_000), :out_of_time},
              {at_cap, input(c, "wake"), :out_of_budget}
            ] do
          assert {:Transition, next, :none} = RunEngine.step(from, record(c, "later", input))
          assert next.control.classification == {:request_outcome, asked}
          assert %{stop_pending: :cancelled, charge_stopped: false} = next.control
        end

        Agent.update(c.clock, fn _ -> 61_000 end)
        engine = start(c)
        assert %{phase: :terminal, outcome: :cancelled} = wait_for(engine, &(&1.outcome != nil))
        assert [{:terminal, "run", :cancelled, "engine", nil, _}] = terminal_rows(c)
        assert evidence_rows(c) == []
        assert {:terminal, :cancelled} = result(engine)
      end
    end
  end

  describe "losing_request_leaves_no_trace" do
    for stop <- [:completed, :cancelled, :failed], request <- [:deadline, :cancel, :budget, :cap] do
      test "#{stop} pending: a #{request} request loses, and the owner's reason and the end of the Run are the pending stop's" do
        losing(unquote(stop), unquote(request))
      end
    end
  end

  describe "stop_mark" do
    test "rollback, then this revision again: a completion set for Attempt B, which the earlier fold replaced with out_of_time keeping the mark, is delivered with one owner Attempt, refused with two" do
      for attempts <- [1, 2] do
        b = if attempts == 2, do: "second", else: "attempt"
        c = run_fixture(&completed_while_slow/1, 1)
        if attempts == 2, do: begin_attempt(c, "second")
        engine = start(c, run_owner: forwarder(c, :kill))
        monitor = Process.monitor(engine)
        assert {:ok, :applied} = start_run(c, engine, b)
        assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
        assert_receive {:local_started, _}, 5_000
        state = unit_state(c)
        assert %{stop_pending: :completed, attempt_id: ^b} = state.control
        assert state.control.stop_attempt == {b, :completed}

        # The earlier revision, taken again on this journal in a VM that knows the key's
        # atom, starts past the Run deadline: its local recovery records the loss of `slow`,
        # and its fold lets that step's out_of_time replace the completion and keeps the key
        # that it does not know. It dies before its owner command.
        Agent.update(c.clock, fn _ -> 61_000 end)
        {key, _} = slot_of(state, "slow")
        step = append_earlier(c, "loss", loss_record(c, state, key))
        assert %{stop_pending: :out_of_time, stop_attempt: {^b, :completed}} = step.legacy.control
        assert step.current.control.stop_pending == :completed

        if attempts == 1 do
          engine = start(c)
          assert %{outcome: :out_of_time} = wait_for(engine, &(&1.outcome != nil))
          assert [{:terminal, "run", :out_of_time, "engine", nil, _}] = terminal_rows(c)
          assert {:terminal, :out_of_time} = result(engine)
        else
          assert_refused(c, "two Attempts")
        end
      end
    end

    test "a protocol cancel whose recorded mark alone names another Attempt is damaged history, in v1 and v2, also while the stop stays pending" do
      for version <- [1, 2], pending <- [true, false] do
        label = "v#{version}#{if pending, do: " with the stop pending"}"
        script = fn frame -> [frame.([action("ask", "ask_person")])] end
        c = run_fixture(script, version, unit_store: memory_unit_store(version))
        engine = if pending, do: start(c, run_owner: forwarder(c, :refuse)), else: start(c)
        assert {:ok, :applied} = start_run(c, engine)
        wait_for(engine, &match?({_, %{phase: :waiting}}, slot_of(&1, "ask")))
        cancel = input(c, "cancel", %{"attempt_id" => "attempt"})
        RunEngine.input(engine, "cancel", cancel, verified())

        if pending do
          assert %{stop_pending: :cancelled} = unit_state(c).control
          assert {:ok, %{outcome: nil}} = Run.status(c.run, "run")
        else
          wait_for(engine, &(&1.outcome == :cancelled))
        end

        assert {:ok, %{entries: [_ | _]}} = transcript(engine), label

        {row, _id, _record} =
          input_row(c, &match?(%{kind: :protocol, input: %{"kind" => "cancel"}}, &1))

        {_before, {id, state}, paired} = step_states(c, row)
        assert state.control.stop_attempt == {"attempt", :cancelled}
        other = put_in(state.control.stop_attempt, {"other", :cancelled})
        corrupt_row(c, paired, {1, {id, other}})
        assert_history(transcript(engine), "#{label} transcript")
        assert_history(RunEngine.event_waits(engine, scope(), limits()), "#{label} event_waits")
      end
    end

    test "a pending cancel whose recorded stop and mark are both changed to out_of_time is damaged history, in v1 and v2" do
      for version <- [1, 2] do
        script = fn frame -> [frame.([action("ask", "ask_person")])] end
        c = run_fixture(script, version, unit_store: memory_unit_store(version))
        engine = start(c, run_owner: forwarder(c, :refuse))
        assert {:ok, :applied} = start_run(c, engine)
        wait_for(engine, &match?({_, %{phase: :waiting}}, slot_of(&1, "ask")))
        cancel = input(c, "cancel", %{"attempt_id" => "attempt"})
        RunEngine.input(engine, "cancel", cancel, verified())
        assert %{stop_pending: :cancelled} = unit_state(c).control
        assert {:ok, %{entries: [_ | _]}} = transcript(engine)

        {row, _id, _record} =
          input_row(c, &match?(%{kind: :protocol, input: %{"kind" => "cancel"}}, &1))

        # Neither fold gives this mark to the recorded timely cancel; the mark agrees with
        # the changed stop, so only a check against the record finds it.
        {_before, {id, state}, paired} = step_states(c, row)
        changed = put_in(state.control.stop_pending, :out_of_time)
        changed = put_in(changed.control.stop_attempt, {"attempt", :out_of_time})
        corrupt_row(c, paired, {1, {id, changed}})
        assert_history(transcript(engine), "v#{version} transcript")
        assert_history(RunEngine.event_waits(engine, scope(), limits()), "v#{version} event_waits")
      end
    end
  end

  describe "room_for_a_stop" do
    test "at the admission limit in a 1-byte Attempt, then the Run view of a 200-byte Attempt: a wake past the Run deadline and, separately, a cancel each commit marked, and the Unit reopens" do
      for {kind, stop} <- [wake: :out_of_time, cancel: :cancelled] do
        {c, state} = in_attempt("a")
        long = String.duplicate("l", 200)

        # At the admission limit, from the shortest classification (`:late`), from which the
        # step that sets a stop grows most: the smallest input for the pattern (a wake with
        # a 1-byte ID) is refused for room.
        padded = pad_invocations(put_in(state.control.classification, :late), 0)
        small = protocol_record("w", wake(), attempt_id: "a")
        assert {:Transition, refused, :none} = RunEngine.step(padded, small)
        assert refused.control.classification == :record_size, "#{kind}"

        # By the fold alone, past the largest growth that no admission checks before such a
        # step: the Run view of the 200-byte Attempt with the largest Run revision, then a
        # cancel, which marks its stop within the bound.
        view = %{
          version: 1,
          kind: :run_view,
          view: %{
            id: "run",
            operation_id: "operation",
            current_attempt: long,
            revision: 9_223_372_036_854_775_807,
            outcome: nil,
            at_ms: 2_000
          }
        }

        assert {:Transition, viewed, :none} = RunEngine.step(padded, view)
        cancel = input(c, "cancel", %{"attempt_id" => long})
        fold_cancel = record(c, "fold-cancel", cancel, attempt_id: long)
        assert {:Transition, cancelled, :none} = RunEngine.step(viewed, fold_cancel)
        assert cancelled.control.stop_attempt == {long, :cancelled}
        assert control_headroom(cancelled) >= 0
        journal_state(c, padded)

        # The host begins a 200-byte Attempt; the start takes its Run view, which admits
        # nothing and grows the recorded Attempt ID by 199 bytes, past the admission limit.
        begin_attempt(c, long)
        engine = start(c, run_owner: forwarder(c, :kill))
        monitor = Process.monitor(engine)
        taken = unit_state(c)
        assert %{attempt_id: ^long, stop_pending: nil, classification: :late} = taken.control
        assert control_headroom(taken) < 0

        stop_request(c, engine, kind, long)
        assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
        committed = unit_state(c)
        assert %{stop_pending: ^stop, attempt_id: ^long} = committed.control
        assert committed.control.stop_attempt == {long, stop}
        assert control_headroom(committed) >= 0

        # The Unit reopens on its journal; the marked stop is delivered in this Run of three
        # Attempts.
        assert :ok = DynamicUnits.stop(c.directory, c.prefix)
        engine = start(c)
        assert %{outcome: ^stop} = wait_for(engine, &(&1.outcome != nil))
        assert [{:terminal, "run", ^stop, "engine", nil, _}] = terminal_rows(c)
      end
    end

    test "at the bound as an earlier revision recorded it, the largest state whose unmarked wake fits: the wake past the Run deadline commits unmarked, the Unit reopens, the start refuses it" do
      long = String.duplicate("l", 200)
      {c, state} = in_attempt(long)

      # The largest state that an earlier revision recorded without the room from which the
      # unmarked wake still fits: from `:late` the wake grows control by 34 bytes, which
      # leave none of the bound, and its mark does not fit.
      padded = pad_invocations(put_in(state.control.classification, :late), 34 - @room)
      late = protocol_record("late-wake", Map.put(wake(), "at_ms", 61_000), attempt_id: long)
      assert {:Transition, next, :none} = RunEngine.step(padded, late)
      assert next.control.stop_pending == :out_of_time
      refute Map.has_key?(next.control, :stop_attempt)
      assert control_headroom(next) == 0
      journal_state(c, padded)

      engine = start(c, run_owner: forwarder(c, :kill))
      monitor = Process.monitor(engine)
      stop_request(c, engine, :wake, long)
      assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
      committed = unit_state(c)
      assert %{stop_pending: :out_of_time, attempt_id: ^long} = committed.control
      refute Map.has_key?(committed.control, :stop_attempt)

      assert :ok = DynamicUnits.stop(c.directory, c.prefix)
      assert_refused(c)
      assert unit_state(c) == committed
    end

    test "one byte past that state: the wake past the Run deadline fails after its input commits, as before ELZ-430, and the Unit does not reopen" do
      long = String.duplicate("l", 200)
      {c, state} = in_attempt(long)
      padded = pad_invocations(put_in(state.control.classification, :late), 33 - @room)
      late = protocol_record("late-wake", Map.put(wake(), "at_ms", 61_000), attempt_id: long)
      assert_raise MatchError, fn -> RunEngine.step(padded, late) end
      journal_state(c, padded)

      engine = start(c)
      refute match?({:ok, _}, stop_request(c, engine, :wake, long))
      if Process.alive?(engine), do: call(fn -> GenServer.stop(engine) end)

      # The input is committed with no result; each start fails and writes nothing.
      failed = rows(c)
      [last | _] = Enum.reverse(failed)
      assert last.kind == "input"
      assert {1, {"late-wake", _}} = decode(last)

      for _ <- 1..2 do
        assert {:error, _} = RunEngine.start_link(c.opts)
        assert rows(c) == failed
      end
    end

    test "a Resource cursor record that adds its key or lengthens its sequence's encoding is admitted only with the room; one that grows nothing always is" do
      {_c, state} = in_attempt("a")
      padded = pad_invocations(put_in(state.control.classification, :late), 0)
      refute RunEngine.cursor_admits?(padded, cursor_record(1))
      at_255 = put_in(padded.control.cursors["document"], 255)
      refute RunEngine.cursor_admits?(at_255, cursor_record(256))
      assert RunEngine.cursor_admits?(at_255, cursor_record(254))

      assert RunEngine.cursor_admits?(
               put_in(at_255.control.cursors["document"], 200),
               cursor_record(255)
             )

      roomy = pad_invocations(put_in(state.control.classification, :late), 64)
      assert RunEngine.cursor_admits?(roomy, cursor_record(1))
    end

    test "at the admission limit, the entry of an opened Resource whose cursor record would add its key writes no row and leaves the cursor unchanged, and a cancel then commits marked" do
      {c, opts} = blocked_open()
      before = rows(c)
      engine = start(c, [run_owner: forwarder(c, :kill)] ++ opts)
      monitor = Process.monitor(engine)
      # The start reconciles the open's tried intent (a :continuation record); the entry
      # itself writes no row: no input of it and no cursor record.
      assert entry_rows(c, before) == []
      refute Map.has_key?(unit_state(c).control.cursors, "document")

      cancel = input(c, "cancel", %{"attempt_id" => "attempt"})
      call(fn -> RunEngine.input(engine, "cancel", cancel, verified()) end)
      assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
      control = unit_state(c).control
      assert control.stop_attempt == {"attempt", :cancelled}
      refute Map.has_key?(control.cursors, "document")
      assert entry_rows(c, before) == []
    end

    test "a fresh configuration whose Budget ID leaves less than the room is refused with no write; at the limit, a wake and a cancel in a 200-byte Attempt commit marked" do
      long = String.duplicate("l", 200)
      probe = run_fixture(fn _frame -> [] end, 1)
      engine = start(probe)
      configured = unit_state(probe)
      GenServer.stop(engine)
      refused = run_fixture(fn _frame -> [] end, 1, budget: budget_leaving(configured, -1))
      assert {:error, :record_size} = RunEngine.start_link(refused.opts)
      assert rows(refused) == []

      for {kind, stop} <- [wake: :out_of_time, cancel: :cancelled] do
        c = run_fixture(fn _frame -> [] end, 1, budget: budget_leaving(configured, 0))
        engine = start(c, run_owner: forwarder(c, :kill))
        assert control_headroom(unit_state(c)) == 0
        monitor = Process.monitor(engine)
        # The next request takes the Run view of the 200-byte Attempt, then sets the stop.
        begin_attempt(c, long)
        stop_request(c, engine, kind, long)
        assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
        assert unit_state(c).control.stop_attempt == {long, stop}
        assert :ok = DynamicUnits.stop(c.directory, c.prefix)
        engine = start(c)
        assert %{outcome: ^stop} = wait_for(engine, &(&1.outcome != nil))
      end
    end

    test "a rollover configuration whose Budget ID leaves less than the room is refused with no write; one at the limit is taken" do
      probe = ended_run()
      engine = start(probe, run_id: "period-two")
      configured = unit_state(probe)
      assert configured.control.run_id == "period-two"
      GenServer.stop(engine)
      c = ended_run()
      before = rows(c)
      over = [run_id: "period-two", budget: budget_leaving(configured, -1)]
      assert {:error, :record_size} = RunEngine.start_link(Keyword.merge(c.opts, over))
      assert rows(c) == before
      start(c, run_id: "period-two", budget: budget_leaving(configured, 0))
      assert control_headroom(unit_state(c)) == 0
    end

    test "with 200-byte action and Attempt IDs, an ask at the admission limit is admitted and waits, one byte under it is refused, and a cancel then commits marked" do
      {c, long, ask, allowed, admission} = allowed_ask()
      {:Transition, admitted, :none} = RunEngine.step(allowed, admission)
      growth = control_headroom(allowed) - control_headroom(admitted)
      under = pad_invocations(allowed, growth - 1)
      assert {:Transition, refused, :none} = RunEngine.step(under, admission)
      assert %{phase: :refusing, refusal: "record_size"} = refused.slots[{1, 0}]
      at_limit = pad_invocations(allowed, growth)
      assert {:Transition, next, :none} = RunEngine.step(at_limit, admission)
      assert %{phase: :authorizing} = next.slots[{1, 0}]
      assert control_headroom(next) == 0

      journal_state(c, at_limit)
      engine = start(c, run_owner: forwarder(c, :kill))
      monitor = Process.monitor(engine)
      assert %{phase: :waiting} = unit_state(c).slots[{1, 0}]
      stop_request(c, engine, :cancel, long)
      assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
      committed = unit_state(c)
      assert committed.control.stop_attempt == {long, :cancelled}
      assert %{phase: :waiting} = committed.slots[{1, 0}]
      assert Map.has_key?(committed.control.lifecycle.waits, ask["id"])
      assert control_headroom(committed) >= 0
      assert :ok = DynamicUnits.stop(c.directory, c.prefix)
      engine = start(c)
      assert %{outcome: :cancelled} = wait_for(engine, &(&1.outcome != nil))
    end

    test "an ask whose action ID has a shorter wait listed counts the growth of its own wait in that wait's place: one byte under the limit is refused, and at the limit the room stays once the wait is listed" do
      {_c, long, ask, allowed, admission} = allowed_ask()

      # No engine path lists a wait under an action ID before the action's admission (a Run
      # takes each action ID once, and a change of Attempt empties the waits), so the state
      # is built: a wait of a 1-byte Attempt ID, which the ask's wait of a 200-byte Attempt
      # ID replaces when its continuation lists it, growing control by 199 bytes.
      short = %{kind: :person, attempt_id: "a", one_shot: true}
      listed = put_in(allowed.control.lifecycle.waits[ask["id"]], short)
      {:Transition, admitted, :none} = RunEngine.step(listed, admission)
      growth = control_headroom(listed) - control_headroom(admitted)
      under = pad_invocations(listed, growth - 1)
      assert {:Transition, refused, :none} = RunEngine.step(under, admission)
      assert %{phase: :refusing, refusal: "record_size"} = refused.slots[{1, 0}]
      at_limit = pad_invocations(listed, growth)
      assert {:Transition, next, :none} = RunEngine.step(at_limit, admission)
      assert %{phase: :authorizing} = next.slots[{1, 0}]
      wait = %{kind: :person, attempt_id: long, one_shot: true}
      assert control_headroom(put_in(next.control.lifecycle.waits[ask["id"]], wait)) == 0
    end

    test "at the admission limit with the Run revision and the deadlines at the largest that a wake reaches, a wake at the Run deadline, a cancel and a cancel at the Run deadline commit marked" do
      long = String.duplicate("l", 200)

      for {rule, deadline} <- [finish: @max_time, pause: @max_time - 1],
          kind <- [:wake, :cancel, :deadline_cancel] do
        label = "#{rule} #{kind}"
        stop = if kind == :cancel, do: :cancelled, else: :out_of_time
        {c, state} = in_attempt("a", budget_rule: rule, run_deadline: deadline)
        journal_state(c, pad_invocations(put_in(state.control.classification, :late), 0))
        begin_attempt(c, long)
        {:ok, %{revision: real}} = Run.status(c.run, "run")
        engine = start(c, run_owner: forwarder(c, {:revision, real, @max_time, :kill}))
        monitor = Process.monitor(engine)
        # The start took the Run view of the 200-byte Attempt at the largest revision; the
        # Run is paused with the largest pause deadline.
        far = verified(%{attempt_id: long, pause_deadline: @max_time})
        pause = %{kind: :pause, pause_deadline: @max_time}
        assert {:ok, :applied} = RunEngine.control(engine, "pause", pause, far), label
        if kind != :cancel, do: Agent.update(c.clock, fn _ -> deadline end)
        fields = if kind == :wake, do: %{}, else: %{"attempt_id" => long}
        request = input(c, if(kind == :wake, do: "wake", else: "cancel"), fields)
        call(fn -> RunEngine.input(engine, "stop", request, far) end)
        assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
        control = unit_state(c).control
        assert %{stop_pending: ^stop, attempt_id: ^long, run_revision: @max_time} = control
        assert %{run_deadline: ^deadline, pause_deadline: @max_time} = control.lifecycle
        assert control.stop_attempt == {long, stop}, label
        assert :ok = DynamicUnits.stop(c.directory, c.prefix)
        engine = start(c, run_owner: forwarder(c, {:revision, real, @max_time, :pass}))
        assert %{outcome: ^stop} = wait_for(engine, &(&1.outcome != nil)), label
      end
    end

    test "a cancel at the Run deadline grows its step most with its mark: from `:late` in a 200-byte Attempt they take 468 bytes, which commit marked with none of the bound left, and one byte less leaves the stop unmarked" do
      long = String.duplicate("l", 200)
      {c, state} = in_attempt(long)
      late = put_in(state.control.classification, :late)
      cancel = fn at -> input(c, "cancel", %{"attempt_id" => long, "at_ms" => at}) end
      at_deadline = record(c, "cancel", cancel.(60_000), attempt_id: long)
      before_deadline = record(c, "cancel", cancel.(3_000), attempt_id: long)

      # The bytes of the bound that are left, with the room counted back while no stop is
      # pending, and what a step that sets a stop takes of them, its mark included.
      left = &(control_headroom(&1) + if(is_nil(&1.control.stop_pending), do: @room, else: 0))

      taken = fn record ->
        assert {:Transition, next, :none} = RunEngine.step(late, record)
        assert Map.has_key?(next.control, :stop_attempt)
        left.(late) - left.(next)
      end

      # At the Run deadline the cancel records its Attempt and asks for out_of_time: 234
      # bytes and a mark of 234; before it, `:cancelled`, 230 and 232.
      assert taken.(at_deadline) == 468
      assert taken.(before_deadline) == 462

      exact = pad_invocations(late, 468 - @room)
      assert {:Transition, next, :none} = RunEngine.step(exact, at_deadline)
      assert %{stop_pending: :out_of_time, cancelled_attempt: ^long} = next.control
      assert next.control.stop_attempt == {long, :out_of_time}
      assert control_headroom(next) == 0

      short = pad_invocations(late, 467 - @room)
      assert {:Transition, unmarked, :none} = RunEngine.step(short, at_deadline)
      assert %{stop_pending: :out_of_time, cancelled_attempt: ^long} = unmarked.control
      refute Map.has_key?(unmarked.control, :stop_attempt)
      assert control_headroom(unmarked) == 233
    end

    test "at request cap 1, a nested start whose child's first request passes the cap and asks for out_of_budget is admitted only with the room for a stop, and marks that stop" do
      {ready, nested} = ready_nested_at_cap()
      key = nested.occurrence

      start_at = fn target ->
        assert {:Transition, next, _} = RunEngine.step(pad_invocations(ready, target), nested)
        next
      end

      # The least headroom (the room counted) at which the start is admitted.
      {_, limit} =
        {-@room, control_headroom(ready) - 43}
        |> Stream.iterate(fn {lo, hi} ->
          mid = div(lo + hi, 2)
          if start_at.(mid).control.stop_pending, do: {lo, mid}, else: {mid, hi}
        end)
        |> Enum.find(fn {lo, hi} -> hi - lo <= 1 end)

      # Admitted, the child's request over the cap stops the charge and asks for
      # out_of_budget, which the step marks, with room left for the growth that no check
      # admits (a longer Attempt ID, the encodings of the revision and deadlines, the phase).
      admitted = start_at.(limit)
      assert %{stop_pending: :out_of_budget, charge_stopped: true} = admitted.control
      assert admitted.control.stop_attempt == {"attempt", :out_of_budget}
      assert %{phase: :refusing, refusal: "out_of_budget"} = admitted.slots[key]
      assert control_headroom(admitted) >= 199 + 27 + 1

      # One byte under it the start is refused for room: no child, no request, no stop.
      refused = start_at.(limit - 1)
      assert %{stop_pending: nil, count: 1} = refused.control
      refute Map.has_key?(refused.control, :stop_attempt)
      refute Map.has_key?(refused.control.callables, "1:0")
      assert %{phase: :refusing, refusal: "record_size"} = refused.slots[key]
    end

    test "a 4 KiB nested estimate, long child Budget ID, empty child: each admitted start keeps the bound, and so does the change of Attempt that closes the child and settles the parent at zero" do
      estimate = Integer.pow(2, 8 * 4_096) - 1
      long = String.duplicate("b", 60_000)

      {ready, nested} =
        ready_nested_at_cap(estimate: estimate, budget_id: long, request_cap: 20, child_script: [])

      key = nested.occurrence

      admitted =
        window(ready, fn target ->
          {:Transition, next, _} = RunEngine.step(pad_invocations(ready, target), nested)
          match?(%{phase: :running}, next.slots[key])
        end)

      assert admitted != []

      # The child's script is empty: it asks for nothing and stays open, so no drain can give
      # its parent an outcome. A change of Attempt closes it (with no slot, its cost is
      # known: zero) and settles the parent with that amount in the Run view's own step.
      view = %{
        version: 1,
        kind: :run_view,
        view: %{
          id: "run",
          operation_id: "operation",
          current_attempt: "second",
          revision: ready.control.run_revision + 1,
          outcome: nil,
          at_ms: 3_000
        }
      }

      for target <- admitted do
        {:Transition, next, _} = RunEngine.step(pad_invocations(ready, target), nested)
        assert %{closed: false} = next.control.callables["1:0"]
        assert {:Transition, changed, :none} = RunEngine.step(next, view)
        assert %{closed: true} = changed.control.callables["1:0"]
        assert %{phase: :settled, outcome: "unknown", actual: 0} = changed.slots[key]
        assert control_headroom(changed) >= 0
      end
    end

    test "a verified answer whose actual would cut into the room is refused record_size with no write; with room it commits and marks the Budget stop that it asks for" do
      {c, waiting} = waiting_ask()
      key = {1, 0}
      # A truthful actual of about 32 KiB, within the ingress and slot bounds; its step
      # stores it twice in the Budget (the committed amount and the settled entry).
      big = Integer.pow(2, 8 * 32_760)

      answer =
        input(c, "person_answer", %{
          "action_id" => "ask",
          "person_id" => "person",
          "schema_id" => "result",
          "schema_version" => 1,
          "payload" => %{}
        })

      context = verified(%{occurrence: key, actual: big, verified_person: "person"})

      # By the fold alone, at the admission limit the step fails the bound, which the
      # slot's reserve and wait do not cover; the check before the write refuses it.
      padded = pad_invocations(waiting, 0)

      folded =
        record(c, "answer", answer,
          correlation: %{occurrence: key, actual: big},
          context: %{verified_person: "person", pause_deadline: 50_000}
        )

      assert_raise MatchError, fn -> RunEngine.step(padded, folded) end
      refute RunEngine.actual_admits?(padded, folded)
      assert RunEngine.actual_admits?(waiting, folded)

      journal_state(c, padded)
      engine = start(c)
      before = rows(c)
      assert {:error, :record_size} = RunEngine.input(engine, "answer", answer, context)
      assert rows(c) == before
      assert %{phase: :waiting} = unit_state(c).slots[key]

      # With the owner moved by another Run's create, the refusal appends no record of the
      # answer: only the Run view that the call journaled before its check.
      create_other(c)
      seen = records(c)
      assert {:error, :record_size} = RunEngine.input(engine, "answer", answer, context)
      assert [%{kind: :run_view}] = records(c) -- seen
      GenServer.stop(engine)

      # After the refusal the Unit reopens on its journal, the ask still waiting.
      assert :ok = DynamicUnits.stop(c.directory, c.prefix)
      engine = start(c)
      assert %{phase: :waiting} = unit_state(c).slots[key]
      GenServer.stop(engine)

      # With room, the answer settles the ask and spends the Budget: the step asks for
      # out_of_budget and marks it.
      journal_state(c, waiting, "relieved")
      engine = start(c, run_owner: forwarder(c, :kill))
      monitor = Process.monitor(engine)
      call(fn -> RunEngine.input(engine, "answer", answer, context) end)
      assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
      committed = unit_state(c)
      assert committed.control.stop_pending == :out_of_budget
      assert committed.control.stop_attempt == {"attempt", :out_of_budget}
      assert %{phase: :settled, actual: ^big} = committed.slots[key]

      # After the accepted settlement the Unit reopens and delivers the marked stop.
      assert :ok = DynamicUnits.stop(c.directory, c.prefix)
      engine = start(c)
      assert %{outcome: :out_of_budget} = wait_for(engine, &(&1.outcome != nil))
    end

    test "a Budget-spending answer: without the room, unmarked at exact fit within the old bound and marked once its mark fits; with the room, admitted only where its dropped stop leaves the room" do
      {c, waiting} = waiting_ask()
      key = {1, 0}
      long = String.duplicate("l", 200)
      # The mark's bytes as an entry of the control map (its key and value, without the
      # version byte and the tuple header of a separate term).
      mark = byte_size(binary({:stop_attempt, {"attempt", :out_of_budget}})) - 3
      left = &(control_headroom(&1) + if(is_nil(&1.control.stop_pending), do: @room, else: 0))

      # An actual whose step grows control (its amount twice in the Budget) by between 100
      # and 200 bytes more than the slot's reserve and wait that the settlement frees, so
      # its exact fit lies within the bound that an earlier revision kept (no room).
      {record, growth} =
        Enum.find_value(Stream.iterate(2_000, &(&1 + 4)), fn n ->
          record = spending_answer(c, key, Integer.pow(2, 8 * n))
          {:Transition, next, :none} = RunEngine.step(waiting, record)
          growth = left.(waiting) - left.(next) - mark
          if growth in 100..200, do: {record, growth}
        end)

      admitted? = fn target ->
        RunEngine.actual_admits?(pad_invocations(waiting, target), record)
      end

      least = fn lo, hi ->
        {lo, hi}
        |> Stream.iterate(fn {lo, hi} ->
          mid = div(lo + hi, 2)
          if admitted?.(mid), do: {lo, mid}, else: {mid, hi}
        end)
        |> Enum.find(fn {lo, hi} -> hi - lo <= 1 end)
        |> elem(1)
      end

      # Without the room for a step that sets a stop (fewer than its 468 bytes free, so
      # neither this revision nor its admission wrote the state): the least headroom (with
      # the room counted) at which the answer is admitted, from the fullest state that the
      # bound records (no room left).
      refute admitted?.(-@room)
      limit = least.(-@room, 467 - @room)
      assert limit == growth - @room
      assert limit > -@room
      at_limit = pad_invocations(waiting, limit)
      assert {:Transition, next, :none} = RunEngine.step(at_limit, record)
      assert next.control.stop_pending == :out_of_budget
      refute Map.has_key?(next.control, :stop_attempt)
      assert control_headroom(next) == 0
      refute admitted?.(limit - 1)
      assert_raise MatchError, fn -> RunEngine.step(pad_invocations(waiting, limit - 1), record) end

      # With the mark's bytes more, still without the room, the step marks the stop.
      assert admitted?.(limit + mark)
      marked_at = pad_invocations(waiting, limit + mark)
      assert {:Transition, marked, :none} = RunEngine.step(marked_at, record)
      assert marked.control.stop_attempt == {"attempt", :out_of_budget}
      assert control_headroom(marked) == 0

      # With the room (at the admission limit and above), the answer takes its stop and mark
      # from the room, and the rest of its growth keeps the room as any admitted growth
      # does: at the admission limit it is refused, and the least padding that admits it
      # leaves a state that, once a change of Attempt drops its stop, keeps the room. After
      # the Run view of a 200-byte Attempt, a cancel at the Run deadline marks its stop.
      refute admitted?.(0)
      cut = least.(0, control_headroom(waiting) - 43)
      assert cut <= growth
      refute admitted?.(cut - 1)
      assert {:Transition, stopped, :none} = RunEngine.step(pad_invocations(waiting, cut), record)
      assert stopped.control.stop_attempt == {"attempt", :out_of_budget}

      view = %{
        version: 1,
        kind: :run_view,
        view: %{
          id: "run",
          operation_id: "operation",
          current_attempt: long,
          revision: stopped.control.run_revision + 1,
          outcome: nil,
          at_ms: 3_000
        }
      }

      assert {:Transition, changed, :none} = RunEngine.step(stopped, view)
      assert changed.control.stop_pending == nil
      cancel = input(c, "cancel", %{"attempt_id" => long, "at_ms" => 60_000})
      at_deadline = record(c, "cancel-at-deadline", cancel, attempt_id: long)
      assert {:Transition, cancelled, :none} = RunEngine.step(changed, at_deadline)
      assert cancelled.control.stop_attempt == {long, :out_of_time}
    end

    test "with the room kept, a Budget-spending answer whose step and mark take part of the room is admitted and marked" do
      {c, waiting} = waiting_ask()
      at_room = pad_invocations(waiting, 0)

      # The smallest actual (by its bytes) whose marked step takes some of the room: its
      # growth with the mark is within the room, so it is admitted and marks the stop.
      cut =
        Enum.find_value(100..4_000, fn n ->
          record = spending_answer(c, {1, 0}, Integer.pow(2, 8 * n))
          {:Transition, next, :none} = RunEngine.step(at_room, record)
          if control_headroom(next) < @room, do: {record, next}
        end)

      assert {record, next} = cut
      assert Map.has_key?(next.control, :stop_attempt)
      assert control_headroom(next) >= 0
      assert RunEngine.actual_admits?(at_room, record)
    end

    test "with the room kept, a nested start whose child asks past the cap: byte by byte around the least admitted padding, no admitted start leaves its stop unmarked" do
      {ready, nested} = ready_nested_at_cap()
      # A fixed child Budget ID; only the padding of the parent's state varies.
      nested = put_in(nested.facts.budget_id, String.duplicate("b", 300))

      step_at = fn target ->
        {:Transition, next, _} = RunEngine.step(pad_invocations(ready, target), nested)
        {next.control.stop_pending, Map.has_key?(next.control, :stop_attempt)}
      end

      # The least padding at which the start is admitted (its child's own state bound is
      # held in reserve, so it lies above the room: the state before keeps the room).
      [least | _] = window(ready, fn target -> elem(step_at.(target), 0) != nil end)
      assert least >= 0

      results = for target <- max(least - 64, 0)..(least + 64), do: {target, step_at.(target)}

      IO.puts(
        "ELZ-430: nested start least admitted padding #{least}; " <>
          inspect(Enum.frequencies_by(results, &elem(&1, 1)))
      )

      assert {least - 1, {nil, false}} in results or least == 0
      assert {least, {:out_of_budget, true}} in results
      assert [] == for({target, {:out_of_budget, false}} <- results, do: target)
    end

    test "a paused v2 answer whose pending input cannot be kept for continue is refused with no write, unsettled; with room it is applied and continue gives it to the pattern once" do
      c = run_fixture(fn frame -> [frame.([action("ask", "ask_person", %{})])] end, 2)
      engine = start(c)
      assert {:ok, :applied} = start_run(c, engine)
      wait_for(engine, &match?({_, %{phase: :waiting}}, slot_of(&1, "ask")))
      pause = %{kind: :pause, pause_deadline: 50_000}
      assert {:ok, :applied} = RunEngine.control(engine, "pause", pause, verified())
      paused = unit_state(c)
      GenServer.stop(engine)
      key = {1, 0}
      record = spending_answer(c, key, nil)

      # The fold keeps the answer as the slot's pending input only with the room; where it
      # cannot, it settles the slot and classifies `record_size`: the preflight refuses there.
      refused =
        Enum.find(0..2_000, fn extra ->
          {:Transition, next, :none} = RunEngine.step(pad_invocations(paused, extra), record)
          next.control.classification != :record_size
        end)

      assert refused > 0
      short = pad_invocations(paused, refused - 1)
      assert {:Transition, dropped, :none} = RunEngine.step(short, record)
      assert %{phase: :settled} = dropped.slots[key]
      refute Map.has_key?(dropped.slots[key], :pending_input)
      refute RunEngine.actual_admits?(short, record)

      journal_state(c, short)
      flush_pattern_inputs()
      engine = start(c)
      before = rows(c)
      context = verified(%{occurrence: key, verified_person: "person"})

      assert {:error, :record_size} =
               RunEngine.input(engine, "answer", record.input |> Map.delete("at_ms"), context)

      assert rows(c) == before
      assert %{phase: :waiting} = unit_state(c).slots[key]
      GenServer.stop(engine)

      # With room, applied while paused; continue gives the answer to the pattern exactly once.
      journal_state(c, paused, "relieved")
      engine = start(c)

      assert {:ok, :applied} =
               RunEngine.input(engine, "answer", record.input |> Map.delete("at_ms"), context)

      # Kept as the slot's pending input, the slot keeps its reserve (it stays active), and
      # its listed wait is removed.
      kept = unit_state(c)
      assert %{phase: :settled, pending_input: %{}} = kept.slots[key]
      refute Map.has_key?(kept.control.lifecycle.waits, "ask")

      continue = %{kind: :continue, person_id: "person", run_deadline: 60_000}

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "continue",
                 continue,
                 verified(%{verified_person: "person"})
               )

      assert_receive {:pattern_input, "root", %{"kind" => "person_answer", "action_id" => "ask"}},
                     5_000

      refute_receive {:pattern_input, "root", %{"kind" => "person_answer"}}, 300
    end

    test "an ask admitted at the limit, then a Run view of the same Attempt whose revision encoding grows from 255 to 256: a Budget-spending answer is admitted only where it marks its stop" do
      {c, waiting} = waiting_ask()
      key = {1, 0}
      assert waiting.control.run_revision <= 255

      view = fn state, revision ->
        %{
          version: 1,
          kind: :run_view,
          view: %{
            id: "run",
            operation_id: state.control.operation_id,
            current_attempt: "attempt",
            revision: revision,
            outcome: nil,
            at_ms: 2_000
          }
        }
      end

      {:Transition, at_255, :none} = RunEngine.step(waiting, view.(waiting, 255))
      admitted = pad_invocations(at_255, 0)
      # The owner's update takes 3 bytes of the room with no admission check.
      {:Transition, at_256, :none} = RunEngine.step(admitted, view.(admitted, 256))
      assert control_headroom(at_256) == -3

      answer = fn n -> spending_answer(c, key, Integer.pow(2, 8 * n)) end

      outcome = fn n ->
        try do
          {:Transition, next, :none} = RunEngine.step(at_256, answer.(n))
          assert next.control.stop_pending == :out_of_budget
          if Map.has_key?(next.control, :stop_attempt), do: :marked, else: :unmarked
        rescue
          MatchError -> :failed
        end
      end

      # The smallest actual (by its bytes) whose step by the fold leaves its stop unmarked:
      # its unmarked step fits and its mark does not. Admission refuses it; an answer whose
      # step marks its stop and keeps the room once the stop is dropped is admitted.
      assert outcome.(1) == :marked
      assert RunEngine.actual_admits?(at_256, answer.(1))

      first =
        {1, 8_000}
        |> Stream.iterate(fn {lo, hi} ->
          mid = div(lo + hi, 2)
          if outcome.(mid) == :marked, do: {mid, hi}, else: {lo, mid}
        end)
        |> Enum.find(fn {lo, hi} -> hi - lo <= 1 end)
        |> elem(1)

      assert outcome.(first) == :unmarked
      refute RunEngine.actual_admits?(at_256, answer.(first))
    end

    test "a state recorded without the room, with a nested child open at zero cost beside a waiting ask: a Budget-spending answer whose unmarked step fits exactly is taken unmarked" do
      script = fn frame ->
        [frame.([action("nested", "nested_callable"), action("ask", "ask_person", %{})])]
      end

      c = run_fixture(script, 1)
      base = c.opts[:bindings]["nested_callable"]
      child = %{name: "nested", script: []}
      nested = fn a -> %{base.nested.(a) | mfa: {TestPattern, :scripted}, initial_state: child} end
      bindings = Map.put(c.opts[:bindings], "nested_callable", %{base | nested: nested})
      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = start_run(c, engine)
      wait_for(engine, &match?({_, %{phase: :waiting}}, slot_of(&1, "ask")))
      state = unit_state(c)
      GenServer.stop(engine)
      {key, _} = slot_of(state, "ask")
      {parent, %{phase: :running}} = slot_of(state, "nested")
      assert %{closed: false, parent: ^parent} = state.control.callables["1:0"]
      mark = byte_size(binary({:stop_attempt, {"attempt", :out_of_budget}})) - 3
      left = &(control_headroom(&1) + if(is_nil(&1.control.stop_pending), do: @room, else: 0))

      {record, growth} =
        Enum.find_value(Stream.iterate(2_000, &(&1 + 4)), fn n ->
          record = spending_answer(c, key, Integer.pow(2, 8 * n))
          {:Transition, next, :none} = RunEngine.step(state, record)
          growth = left.(state) - left.(next) - mark
          if growth in 100..200, do: {record, growth}
        end)

      admitted? = &RunEngine.actual_admits?(pad_invocations(state, &1), record)
      refute admitted?.(-@room)

      limit =
        {-@room, 467 - @room}
        |> Stream.iterate(fn {lo, hi} ->
          mid = div(lo + hi, 2)
          if admitted?.(mid), do: {lo, mid}, else: {mid, hi}
        end)
        |> Enum.find(fn {lo, hi} -> hi - lo <= 1 end)
        |> elem(1)

      # No charge of the open child is counted against the step: its parent's charge lands
      # in a later step, not in this one.
      assert limit == growth - @room
      assert {:Transition, next, :none} = RunEngine.step(pad_invocations(state, limit), record)
      assert next.control.stop_pending == :out_of_budget
      refute Map.has_key?(next.control, :stop_attempt)
      assert control_headroom(next) == 0
    end

    test "an answer of another Run whose Attempt, action and occurrence match the open ask is late: not refused for size, and not an own settlement" do
      {c, waiting} = waiting_ask()
      key = {1, 0}
      big = Integer.pow(2, 8 * 32_760)
      record = spending_answer(c, key, big)
      other = %{record | run_id: "earlier-run"}
      padded = pad_invocations(waiting, 0)
      refute RunEngine.actual_admits?(padded, record)
      refute RunEngine.own_settlement?(padded, other, key)
      assert RunEngine.actual_admits?(padded, other)
      assert {:Transition, next, :none} = RunEngine.step(padded, other)
      assert next.control.classification == :late
      assert %{phase: :waiting} = next.slots[key]
      assert next.control.budgets == padded.control.budgets
    end

    test "budget_rule :pause: a v2 answer whose own step pauses the Run on an exhausted Budget is refused with no write where its pending input cannot be kept; with room it is kept" do
      c =
        run_fixture(fn frame -> [frame.([action("ask", "ask_person", %{})])] end, 2,
          budget_rule: :pause
        )

      engine = start(c)
      assert {:ok, :applied} = start_run(c, engine)
      wait_for(engine, &match?({_, %{phase: :waiting}}, slot_of(&1, "ask")))
      GenServer.stop(engine)
      # The Budget is exhausted as a root Resource cursor's settlement leaves it: by its own
      # Budget step, which leaves the lifecycle phase as it is.
      exhausted = exhaust_root(unit_state(c))
      assert exhausted.control.lifecycle.phase == :waiting
      key = {1, 0}
      record = spending_answer(c, key, nil)

      assert {:Transition, kept, :none} = RunEngine.step(exhausted, record)
      assert kept.control.lifecycle.phase == :paused
      assert %{phase: :settled, pending_input: %{}} = kept.slots[key]

      refused =
        Enum.find(0..4_000, fn extra ->
          {:Transition, next, :none} = RunEngine.step(pad_invocations(exhausted, extra), record)
          next.control.classification != :record_size
        end)

      assert refused > 0
      short = pad_invocations(exhausted, refused - 1)
      assert {:Transition, dropped, :none} = RunEngine.step(short, record)
      assert dropped.control.lifecycle.phase == :paused
      assert %{phase: :settled} = dropped.slots[key]
      refute Map.has_key?(dropped.slots[key], :pending_input)
      refute RunEngine.actual_admits?(short, record)
      assert RunEngine.actual_admits?(pad_invocations(exhausted, refused), record)

      journal_state(c, short)
      engine = start(c)
      before = rows(c)
      context = verified(%{occurrence: key, verified_person: "person"})
      answer = record.input |> Map.delete("at_ms")
      assert {:error, :record_size} = RunEngine.input(engine, "answer", answer, context)
      assert rows(c) == before
      assert %{phase: :waiting} = unit_state(c).slots[key]
      GenServer.stop(engine)

      journal_state(c, exhausted, "relieved")
      engine = start(c)
      assert {:ok, :applied} = RunEngine.input(engine, "answer", answer, context)
      state = unit_state(c)
      assert state.control.lifecycle.phase == :paused
      assert %{phase: :settled, pending_input: %{}} = state.slots[key]
    end

    test "a paused v2 Run: a Resource entry whose outcome cannot be kept for continue writes no row and stays unconsumed; with room it is kept and continue gives it once" do
      payload = %{"run_id" => "run", "resource_name" => "document", "data" => %{}}
      c = run_fixture(fn frame -> [frame.([action("open", "resource_open", payload)])] end, 2)
      {owner, bindings} = resource(c)
      opts = [resources: %{"document" => owner}, bindings: bindings]
      engine = start(c, opts)
      assert {:ok, :applied} = start_run(c, engine)
      assert_receive {:effect_started, _opening, _}, 5_000
      pause = %{kind: :pause, pause_deadline: 50_000}
      assert {:ok, :applied} = RunEngine.control(engine, "pause", pause, verified())
      GenServer.stop(engine)
      paused = unit_state(c)
      assert paused.control.lifecycle.phase == :paused
      {key, _} = slot_of(paused, "open")
      cursor = paused.control.cursors["document"]
      observed(owner, "opened", "open", %{opened_at_ms: 2_000}, 2_000)
      {:ok, %{entries: entries}} = Elzoo.RunResource.read(owner, cursor)

      input =
        Enum.find_value(entries, fn entry ->
          Enum.find(entry.inputs, &(&1["action_id"] == "open"))
        end)

      # The record that the engine commits for that input; its stable ID is longer than
      # this one, so a state that refuses this record refuses it too.
      record = %{
        version: 2,
        kind: :protocol,
        id: "resource-probe",
        run_id: "run",
        attempt_id: "attempt",
        input: Map.put(input, "version", 2),
        correlation: %{occurrence: key, resource: "document"},
        context: %{pause_deadline: 50_000}
      }

      refused =
        Enum.find(0..4_000, fn extra ->
          {:Transition, next, :none} = RunEngine.step(pad_invocations(paused, extra), record)
          next.control.classification != :record_size
        end)

      assert refused > 0
      short = pad_invocations(paused, refused - 1)
      assert {:Transition, dropped, :none} = RunEngine.step(short, record)
      assert %{phase: :settled} = dropped.slots[key]
      refute Map.has_key?(dropped.slots[key], :pending_input)

      # The padded state is synthetic (pad_invocations/2): a boundary-sized predecessor,
      # not a history that an engine recorded. The engine calls that follow are real.
      journal_state(c, short)
      before = rows(c)
      flush_pattern_inputs()
      engine = start(c, opts)
      assert entry_rows(c, before) == []
      state = unit_state(c)
      refute state.slots[key].phase == :settled
      assert state.control.cursors["document"] == cursor

      # The same engine on the same blocked entry: a continue resumes the Run, and the next
      # call's pass (a wake) consumes the entry, now settled without being retained, and
      # gives its outcome to the pattern once.
      continue = %{kind: :continue, person_id: "person", run_deadline: 60_000}

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "continue",
                 continue,
                 verified(%{verified_person: "person"})
               )

      assert {:ok, _} = RunEngine.input(engine, "after-continue", input(c, "wake"), verified())
      assert unit_state(c).control.cursors["document"] > cursor

      assert_receive {:pattern_input, "root", %{"kind" => "action_outcome", "action_id" => "open"}},
                     5_000

      refute_receive {:pattern_input, "root", %{"kind" => "action_outcome", "action_id" => "open"}},
                     300
    end

    test "a paused v2 Run lost at a restart, then at a replacement Unit of the same Attempt: the local_restart loss that cannot be kept is not written and the work stays running; after continue it is recorded and given once" do
      c = run_fixture(fn frame -> [frame.([action("slow")])] end, 2)
      engine = start(c)
      assert {:ok, :applied} = start_run(c, engine)
      assert_receive {:local_started, _}, 5_000
      pause = %{kind: :pause, pause_deadline: 50_000}
      assert {:ok, :applied} = RunEngine.control(engine, "pause", pause, verified())
      GenServer.stop(engine)
      paused = unit_state(c)
      {key, %{phase: :running}} = slot_of(paused, "slow")
      # The loss that the restart records; its stable ID is longer than this one, so a
      # state that refuses this record refuses it too.
      loss = %{loss_record(c, paused, key) | context: %{pause_deadline: 50_000}}

      refused =
        Enum.find(0..4_000, fn extra ->
          {:Transition, next, :none} = RunEngine.step(pad_invocations(paused, extra), loss)
          next.control.classification != :record_size
        end)

      assert refused > 0
      # A synthetic boundary-sized predecessor (pad_invocations/2); the calls are real.
      journal_state(c, pad_invocations(paused, refused - 1))
      flush_pattern_inputs()
      engine = start(c)

      losses = fn ->
        for %{kind: :protocol, correlation: %{loss: :unavailable}} <- records(c), do: :loss
      end

      assert %{phase: :running} = unit_state(c).slots[key]
      assert losses.() == []
      # The Unit is replaced (same Attempt): the next call recovers it, refuses the loss
      # again, and the continue then resumes the Run.
      assert :ok = DynamicUnits.stop(c.directory, c.prefix)
      continue = %{kind: :continue, person_id: "person", run_deadline: 60_000}

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "continue",
                 continue,
                 verified(%{verified_person: "person"})
               )

      assert_receive {:pattern_input, "root",
                      %{"kind" => "action_outcome", "action_id" => "slow", "outcome" => "failed"}},
                     5_000

      assert %{phase: :settled, outcome: "failed"} = unit_state(c).slots[key]
      assert losses.() == [:loss]

      refute_receive {:pattern_input, "root", %{"kind" => "action_outcome", "action_id" => "slow"}},
                     300
    end

    test "a paused v2 Run whose dispatched tool call is lost at a restart: a lost_outcome that cannot be kept is not written; after continue it is recorded and given once, with no second dispatch" do
      c = run_fixture(fn frame -> [frame.([action("tool", "tool_call")])] end, 2)
      engine = start(c)
      assert {:ok, :applied} = start_run(c, engine)
      assert_receive {:effect_started, _provider, _}, 5_000
      pause = %{kind: :pause, pause_deadline: 50_000}
      assert {:ok, :applied} = RunEngine.control(engine, "pause", pause, verified())
      GenServer.stop(engine)
      paused = unit_state(c)
      {key, %{phase: :running}} = slot_of(paused, "tool")

      lost =
        record(
          c,
          "lost",
          input(c, "action_outcome", %{
            "action_id" => "tool",
            "outcome" => "unknown",
            "schema_id" => "elzoo.run-engine.refusal",
            "schema_version" => 1,
            "payload" => %{
              "reason" => "lost_outcome",
              "gate_id" => paused.control.gate.id,
              "gate_version" => paused.control.gate.version,
              "request" => elem(key, 0),
              "index" => elem(key, 1)
            }
          }),
          correlation: %{occurrence: key, dispatch: "unknown"},
          context: %{pause_deadline: 50_000}
        )

      refused =
        Enum.find(0..4_000, fn extra ->
          {:Transition, next, :none} = RunEngine.step(pad_invocations(paused, extra), lost)
          next.control.classification != :record_size
        end)

      assert refused > 0
      # A synthetic boundary-sized predecessor (pad_invocations/2); the calls are real.
      journal_state(c, pad_invocations(paused, refused - 1))
      Agent.update(c.host_mode, fn _ -> :recover end)
      flush_pattern_inputs()
      engine = start(c)

      unknowns = fn ->
        for %{kind: :protocol, input: %{"outcome" => "unknown"}} <- records(c), do: :lost
      end

      assert %{phase: :running} = unit_state(c).slots[key]
      assert unknowns.() == []
      continue = %{kind: :continue, person_id: "person", run_deadline: 60_000}

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "continue",
                 continue,
                 verified(%{verified_person: "person"})
               )

      assert_receive {:pattern_input, "root",
                      %{"kind" => "action_outcome", "action_id" => "tool", "outcome" => "unknown"}},
                     5_000

      assert %{phase: :settled, outcome: "unknown"} = unit_state(c).slots[key]
      assert unknowns.() == [:lost]
      refute_receive {:effect_started, _, _}, 300
    end

    test "a paused v2 Run with an expiry report held and running local work lost at a restart: after continue, the report is given before the loss" do
      c =
        run_fixture(fn frame -> [frame.([action("ask", "ask_person", %{}), action("slow")])] end, 2)

      person = c.opts[:bindings]["ask_person"]
      early = %{person | facts: fn a -> %{person.facts.(a) | deadline_ms: 30_000} end}
      opts = [bindings: Map.put(c.opts[:bindings], "ask_person", early), expiry_reports: :owner]
      engine = start(c, opts)
      assert {:ok, :applied} = start_run(c, engine)
      assert_receive {:local_started, _}, 5_000
      wait_for(engine, &match?({_, %{phase: :waiting}}, slot_of(&1, "ask")))
      pause = %{kind: :pause, pause_deadline: 50_000}
      assert {:ok, :applied} = RunEngine.control(engine, "pause", pause, verified())
      Agent.update(c.clock, fn _ -> 30_000 end)
      assert {:ok, _} = RunEngine.input(engine, "expire", input(c, "wake"), verified())
      GenServer.stop(engine)
      paused = unit_state(c)
      {ask, %{pending_input: %{}}} = slot_of(paused, "ask")
      {key, %{phase: :running}} = slot_of(paused, "slow")
      loss = %{loss_record(c, paused, key) | context: %{pause_deadline: 50_000}}

      refused =
        Enum.find(0..4_000, fn extra ->
          {:Transition, next, :none} = RunEngine.step(pad_invocations(paused, extra), loss)
          next.control.classification != :record_size
        end)

      assert refused > 0
      # A synthetic boundary-sized predecessor (pad_invocations/2); the calls are real.
      journal_state(c, pad_invocations(paused, refused - 1))
      flush_pattern_inputs()
      engine = start(c, opts)
      assert %{phase: :running} = unit_state(c).slots[key]
      assert %{pending_input: %{}} = unit_state(c).slots[ask]
      continue = %{kind: :continue, person_id: "person", run_deadline: 60_000}

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "continue",
                 continue,
                 verified(%{verified_person: "person"})
               )

      assert_receive {:pattern_input, "root", first}, 5_000
      assert_receive {:pattern_input, "root", second}, 5_000
      assert %{"action_id" => "ask", "outcome" => "expired"} = first
      assert %{"action_id" => "slow", "outcome" => "failed"} = second
    end

    test "a Resource outcome that current/1 takes sets a request-cap stop before a refused local outcome from the mailbox: the stop is drained all the same, in v1 and v2" do
      for version <- [1, 2] do
        payload = %{"run_id" => "run", "resource_name" => "document", "data" => %{}}

        script = fn frame ->
          [
            frame.([action("open", "resource_open", payload), action("slow")]),
            frame.([action("more")])
          ]
        end

        c = run_fixture(script, version, request_cap: 1)
        {owner, bindings} = resource(c)
        engine = start(c, resources: %{"document" => owner}, bindings: bindings)
        assert {:ok, :applied} = start_run(c, engine)
        assert_receive {:effect_started, _opening, _}, 5_000
        assert_receive {:local_started, task}, 5_000
        observed(owner, "opened", "open", %{opened_at_ms: 2_000}, 2_000)
        {key, _} = slot_of(unit_state(c), "slow")

        # A message of the engine's own mailbox form whose actual the slot bound cannot
        # hold: the retained-input rule refuses it, with no record of it written.
        id = "local:refused-#{version}"

        outcome =
          input(
            c,
            "action_outcome",
            Elzoo.RunEngine.TestHelper.result("slow") |> Map.delete("version")
          )

        refused = %{
          version: version,
          kind: :protocol,
          id: id,
          run_id: "run",
          attempt_id: "attempt",
          input: Map.put(outcome, "at_ms", 2_000),
          correlation: %{occurrence: key, actual: Integer.pow(2, 8 * 200_000)},
          context: %{}
        }

        send(engine, {:durable_unit_input, id, refused})
        assert %{outcome: :out_of_budget} = wait_for(engine, &(&1.outcome != nil)), "v#{version}"
        assert [{:terminal, "run", :out_of_budget, "request_cap", nil, _}] = terminal_rows(c)
        refute Enum.any?(records(c), &(Map.get(&1, :id) == id))
        assert {_, %{phase: :running}} = slot_of(view(engine), "slow")
        send(task, :finish)
        GenServer.stop(engine)
      end
    end

    test "an ask admitted at the limit in a 1-byte Attempt, then a timely wake that calls no pattern and widens the classification: a Budget-spending answer is admitted only where it marks its stop" do
      # The ask waits in Attempt "a" (begun on the owner before the start), with the Run
      # revision and the Run deadline (250, the clock at 10) below 256 and no pause deadline,
      # so the growth that no check admits leaves 4 of the 227 bytes spare.
      script = fn frame -> [frame.([action("ask", "ask_person", %{})])] end
      c = run_fixture(script, 1, run_deadline: 250)
      Agent.update(c.clock, fn _ -> 10 end)
      begin_attempt(c, "a")
      engine = start(c)
      assert {:ok, :applied} = start_run(c, engine, "a")
      wait_for(engine, &match?({_, %{phase: :waiting}}, slot_of(&1, "ask")))
      waiting = unit_state(c)
      GenServer.stop(engine)
      assert %{attempt_id: "a", run_revision: revision} = waiting.control
      assert revision < 256
      assert %{run_deadline: 250, pause_deadline: nil} = waiting.control.lifecycle
      key = {1, 0}
      # A synthetic boundary-sized predecessor (pad_invocations/2) at the admission limit.
      admitted = pad_invocations(waiting, 0)
      wake = record(c, "timely-wake", input(c, "wake", %{"at_ms" => 20}), attempt_id: "a")
      {:Transition, woken, :none} = RunEngine.step(admitted, wake)
      assert woken.control.classification == :remain_waiting
      assert %{phase: :waiting} = woken.slots[key]
      assert control_headroom(woken) < 0

      answer = fn n ->
        record = %{spending_answer(c, key, Integer.pow(2, 8 * n)) | attempt_id: "a"}
        put_in(record.input["at_ms"], 30)
      end

      outcome = fn n ->
        try do
          {:Transition, next, :none} = RunEngine.step(woken, answer.(n))
          assert next.control.stop_pending == :out_of_budget
          if Map.has_key?(next.control, :stop_attempt), do: :marked, else: :unmarked
        rescue
          MatchError -> :failed
        end
      end

      assert outcome.(1) == :marked
      assert RunEngine.actual_admits?(woken, answer.(1))

      first =
        {1, 8_000}
        |> Stream.iterate(fn {lo, hi} ->
          mid = div(lo + hi, 2)
          if outcome.(mid) == :marked, do: {mid, hi}, else: {lo, mid}
        end)
        |> Enum.find(fn {lo, hi} -> hi - lo <= 1 end)
        |> elem(1)

      assert outcome.(first) == :unmarked
      refute RunEngine.actual_admits?(woken, answer.(first))
    end

    test "a request-cap stop committed by a Resource outcome that current/1 takes, then a verified answer of an open ask: admitted while the stop is pending, and drained" do
      payload = %{"run_id" => "run", "resource_name" => "document", "data" => %{}}

      script = fn frame ->
        [
          frame.([action("open", "resource_open", payload), action("ask", "ask_person", %{})]),
          frame.([action("more")])
        ]
      end

      c = run_fixture(script, 1, request_cap: 1)
      {owner, bindings} = resource(c)
      engine = start(c, resources: %{"document" => owner}, bindings: bindings)
      assert {:ok, :applied} = start_run(c, engine)
      assert_receive {:effect_started, _opening, _}, 5_000
      wait_for(engine, &match?({_, %{phase: :waiting}}, slot_of(&1, "ask")))
      observed(owner, "opened", "open", %{opened_at_ms: 2_000}, 2_000)
      {key, _} = slot_of(unit_state(c), "ask")
      answer = spending_answer(c, key, 3).input |> Map.delete("at_ms")
      context = verified(%{occurrence: key, actual: 3, verified_person: "person"})
      assert {:ok, :applied} = RunEngine.input(engine, "answer", answer, context)
      assert %{outcome: :out_of_budget} = wait_for(engine, &(&1.outcome != nil))
      assert [{:terminal, "run", :out_of_budget, "request_cap", nil, _}] = terminal_rows(c)
      assert %{phase: :settled, actual: 3} = unit_state(c).slots[key]
    end

    test "through the engine: a Budget stop at the least admitted padding, a crash, then a 200-byte Attempt B: the stop is dropped and a cancel at the Run deadline commits marked" do
      {c, waiting} = waiting_ask()
      key = {1, 0}
      long = String.duplicate("l", 200)
      big = Integer.pow(2, 8 * 2_400)
      record = spending_answer(c, key, big)
      admitted? = &RunEngine.actual_admits?(pad_invocations(waiting, &1), record)

      cut =
        {0, control_headroom(waiting) - 43}
        |> Stream.iterate(fn {lo, hi} ->
          mid = div(lo + hi, 2)
          if admitted?.(mid), do: {lo, mid}, else: {mid, hi}
        end)
        |> Enum.find(fn {lo, hi} -> hi - lo <= 1 end)
        |> elem(1)

      refute admitted?.(cut - 1)
      journal_state(c, pad_invocations(waiting, cut))
      engine = start(c, run_owner: forwarder(c, :kill))
      monitor = Process.monitor(engine)
      context = verified(%{occurrence: key, actual: big, verified_person: "person"})
      answer = record.input |> Map.delete("at_ms")
      call(fn -> RunEngine.input(engine, "answer", answer, context) end)
      assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
      assert unit_state(c).control.stop_attempt == {"attempt", :out_of_budget}

      begin_attempt(c, long)
      assert :ok = DynamicUnits.stop(c.directory, c.prefix)
      engine = start(c, run_owner: forwarder(c, :kill))
      monitor = Process.monitor(engine)
      assert %{attempt_id: ^long, stop_pending: nil} = unit_state(c).control
      Agent.update(c.clock, fn _ -> 60_000 end)
      stop_request(c, engine, :cancel, long)
      assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
      committed = unit_state(c)
      assert %{stop_pending: :out_of_time, attempt_id: ^long} = committed.control
      assert committed.control.stop_attempt == {long, :out_of_time}
      assert :ok = DynamicUnits.stop(c.directory, c.prefix)
      engine = start(c)
      assert %{outcome: :out_of_time} = wait_for(engine, &(&1.outcome != nil))
    end
  end

  # The paddings (headrooms that pad_invocations/2 can give `state`) at which `admitted?`
  # first holds and the 64 above it: the least is found by bisection, between the state at
  # the bound itself (no room left: a recorded state never lies beyond it) and the state's
  # own headroom. Each call of `admitted?` that steps a state also checks, by the fold's
  # own bound, that what it admits fits.
  defp window(state, admitted?) do
    hi = control_headroom(state) - 43
    lo = -@room

    least =
      if admitted?.(lo) do
        lo
      else
        {lo, hi}
        |> Stream.iterate(fn {lo, hi} ->
          mid = div(lo + hi, 2)
          if admitted?.(mid), do: {lo, mid}, else: {mid, hi}
        end)
        |> Enum.find(fn {lo, hi} -> hi - lo <= 1 end)
        |> elem(1)
      end

    Enum.filter(least..min(least + 64, hi), admitted?)
  end

  # The verified answer of ask `key` in `c`'s protocol version, at actual `actual` (none
  # when nil), as the engine records it.
  defp spending_answer(c, key, actual) do
    answer =
      input(c, "person_answer", %{
        "action_id" => "ask",
        "person_id" => "person",
        "schema_id" => "result",
        "schema_version" => 1,
        "payload" => %{},
        "at_ms" => 2_000
      })

    correlation = if actual, do: %{occurrence: key, actual: actual}, else: %{occurrence: key}

    record(c, "answer", answer,
      correlation: correlation,
      context: %{verified_person: "person", pause_deadline: 50_000}
    )
  end

  describe "cursor_transition" do
    test "at the admission limit, a same-width cursor advance whose entry settles a held Budget with a 400-byte actual writes no row and leaves the cursor and the Budget unchanged" do
      {c, opts, owner} = closed_resource(@rate)
      state = unit_state(c)
      cursor = state.control.cursors["document"]
      {:ok, %{entries: [entry]}} = Elzoo.RunResource.read(owner, cursor)
      assert {:settle, %{actual: @rate}} = entry.budget_command
      assert byte_size(binary(entry.seq)) == byte_size(binary(cursor))
      journal_state(c, pad_invocations(state, 0))
      before = rows(c)
      start(c, opts)
      assert entry_rows(c, before) == []
      control = unit_state(c).control
      assert control.cursors == state.control.cursors
      assert control.budgets == state.control.budgets
    end

    test "a cursor record whose projected step fails (its Budget command names a holder with no Budget) is not admitted, also with room" do
      {_c, state} = in_attempt("a")
      roomy = pad_invocations(put_in(state.control.classification, :late), 64)
      assert RunEngine.cursor_admits?(roomy, cursor_record(1))
      settle = {:settle, %{cost_ref: "1:0", generation: {"sealed", 1}, actual: 1}}
      broken = %{cursor_record(1) | budget_owner: "missing", budget_command: settle}
      refute RunEngine.cursor_admits?(roomy, broken)
    end

    test "an entry refused at the check before its cursor record keeps its committed inputs, leaves the cursor and the Budget unchanged, and a later pass reads it again" do
      {c, opts, owner} = closed_resource(@rate)
      state = unit_state(c)
      cursor = state.control.cursors["document"]
      {:ok, %{entries: [entry]}} = Elzoo.RunResource.read(owner, cursor)

      # Room for the entry's cursor transition alone: the check before its first commit
      # passes, its input (the closed event, given to the root) takes the room of its
      # invocation entry, and the check before its cursor record refuses it.
      record = %{
        cursor_record(entry.seq)
        | budget_owner: "root",
          budget_command: entry.budget_command
      }

      {:Transition, settled, :none} = RunEngine.step(state, record)
      padded = pad_invocations(state, control_headroom(state) - control_headroom(settled))
      journal_state(c, padded)
      before = rows(c)
      engine = start(c, opts)
      assert [_ | _] = inputs = entry_rows(c, before)
      assert Enum.all?(inputs, &String.starts_with?(&1, "resource:"))
      control = unit_state(c).control
      assert control.cursors["document"] == cursor
      assert control.budgets == state.control.budgets

      # A later pass reads the entry again from the unchanged cursor. With room (the
      # padding taken out of the recorded state), its committed input is not committed
      # again, and its cursor record and Budget settlement commit.
      GenServer.stop(engine)
      padding = Map.keys(padded.control.invocations) -- Map.keys(state.control.invocations)
      relieved = update_in(unit_state(c).control.invocations, &Map.drop(&1, padding))
      journal_state(c, relieved, "relieved")
      before = rows(c)
      start(c, opts)
      assert [id] = Enum.uniq(entry_rows(c, before))
      assert String.starts_with?(id, "cursor:")
      assert unit_state(c).control.cursors["document"] == entry.seq
      assert committed(c) == @rate
    end

    test "a slot that waits on a blocked Resource stays open at its own deadline, before the Run deadline, and the Run's stop settles it" do
      {c, opts} = blocked_open()
      engine = start(c, opts)
      {key, %{deadline_ms: 40_000}} = slot_of(unit_state(c), "open")
      Agent.update(c.clock, fn _ -> 40_000 end)
      assert {:ok, _} = RunEngine.input(engine, "at-deadline", input(c, "wake"), verified())
      state = unit_state(c)
      refute state.slots[key].phase == :settled
      refute Map.has_key?(state.control.cursors, "document")
      cancel = input(c, "cancel", %{"attempt_id" => "attempt"})
      assert {:ok, _} = RunEngine.input(engine, "cancel", cancel, verified())
      assert %{outcome: :cancelled} = wait_for(engine, &(&1.outcome != nil))
      assert %{phase: :settled, outcome: "unknown"} = settled = unit_state(c).slots[key]
      assert is_nil(settled[:actual])
    end

    test "a new Attempt while a Resource entry is blocked: the state paired with its Run view, before any later cursor, settles the sent slot unknown with no actual, its Budget held and the cursor unmoved" do
      {c, opts} = blocked_open()
      engine = start(c, opts)
      blocked = unit_state(c)
      {key, slot} = slot_of(blocked, "open")
      refute slot.phase == :settled
      refute Map.has_key?(blocked.control.cursors, "document")

      reserved = fn state ->
        budget = state.control.budgets[slot.callable].state
        {:Transition, _, {:some, {:status, status}}} = Elzoo.Budget.step(budget, {2_000, :status})
        status.reserved
      end

      held = reserved.(blocked)
      assert held > 0
      GenServer.stop(engine)
      begin_attempt(c, "second")
      before = rows(c)
      engine = start(c, opts)

      # The Run view's own input and result rows, as the start committed them, before any
      # later record.
      [{_, paired}] =
        for row <- Enum.drop(rows(c), length(before)),
            row.kind == "result",
            {1, {"run:" <> _, state}} <- [decode(row)],
            do: {row, state}

      assert paired.control.attempt_id == "second"
      assert %{phase: :settled, outcome: "unknown"} = settled = paired.slots[key]
      assert is_nil(settled[:actual])
      assert reserved.(paired) == held
      refute Map.has_key?(paired.control.cursors, "document")
      GenServer.stop(engine)
    end

    test "a request-cap stop retains a sent Resource slot that waits on a blocked Resource: the slot stays open after the Run ends, as the stop retains any sent Resource slot" do
      {c, opts} = blocked_open(request_cap: 1)
      engine = start(c, opts)
      {key, _} = slot_of(unit_state(c), "open")
      assert {:ok, _} = RunEngine.input(engine, "cap", input(c, "wake"), verified())
      assert %{outcome: :out_of_budget} = wait_for(engine, &(&1.outcome != nil))
      assert [{:terminal, "run", :out_of_budget, "request_cap", nil, _}] = terminal_rows(c)
      state = unit_state(c)
      # Open (the start reconciled its sent intent read-only), not settled by the end.
      assert state.slots[key].phase in [:running, :reconcile]
      refute Map.has_key?(state.control.cursors, "document")
    end

    test "a child's Resource cursor that settles its held Budget: at every padding near the limit, a cursor that admission takes keeps the bound with its parent's charge after it" do
      {_c, _opts, changed, record} = settled_parent_with_resource(@rate)
      parent = {1, 0}
      admitted = window(changed, &RunEngine.cursor_admits?(pad_invocations(changed, &1), record))
      assert admitted != []

      for target <- admitted do
        assert {:Transition, charged, :none} =
                 RunEngine.step(pad_invocations(changed, target), record)

        status = Elzoo.Budget.step(charged.control.budgets["1:0"].state, {3_000, :status})
        {:Transition, _, {:some, {:status, %{committed: amount}}}} = status

        charge = %{
          version: 1,
          kind: :nested_actual,
          occurrence: parent,
          actual: amount,
          at_ms: 3_000
        }

        assert {:Transition, _, :none} = RunEngine.step(charged, charge)
      end
    end

    test "reported cursor: same-width, settling 1 against 2^40, refused without room for the parent charge, admitted with it" do
      {_c, _opts, changed, record} = settled_parent_with_resource(1, Integer.pow(2, 40))
      parent = {1, 0}
      cursor = changed.control.cursors["document"]
      assert {:settle, %{actual: 1}} = record.budget_command
      assert byte_size(binary(record.sequence)) == byte_size(binary(cursor))

      # The premise: the cursor step itself grows neither control nor the slots.
      assert {:Transition, stepped, :none} = RunEngine.step(changed, record)
      assert byte_size(binary(stepped.control)) <= byte_size(binary(changed.control))
      assert byte_size(binary(stepped.slots)) <= byte_size(binary(changed.slots))

      # The parent's later charge at 1 settles its held entry; its growth is within the bound
      # that admission counts for it (twice the amount's bytes and 32).
      charge = %{version: 1, kind: :nested_actual, occurrence: parent, actual: 1, at_ms: 3_000}
      assert {:Transition, charged, :none} = RunEngine.step(stepped, charge)
      growth = control_headroom(stepped) - control_headroom(charged)
      assert growth >= 0 and growth <= 2 * byte_size(binary(1)) + 32

      # At the admission limit the cursor is refused (its Budget command takes it out of the
      # no-growth exception); a cursor-only advance there is still admitted.
      at_limit = pad_invocations(changed, 0)
      refute RunEngine.cursor_admits?(at_limit, record)
      cursor_only = %{record | budget_owner: nil, budget_command: nil}
      assert RunEngine.cursor_admits?(at_limit, cursor_only)

      # With room for the charge after it, admitted, and the charge keeps the bound.
      admitted = window(changed, &RunEngine.cursor_admits?(pad_invocations(changed, &1), record))
      assert [least | _] = admitted
      assert least > 0

      for target <- admitted do
        assert {:Transition, next, :none} = RunEngine.step(pad_invocations(changed, target), record)
        assert {:Transition, _, :none} = RunEngine.step(next, charge)
      end
    end

    test "reported paused v1 parent: a 70 KiB tool actual of a finished child is refused with no record; a small one is kept" do
      # The parent's outcome while paused would keep the actual twice in its slot (its
      # actual and its pending input), past the slot bound.
      script = fn frame -> [frame.([action("nested", "nested_callable")])] end
      budget = %{cap: 5, unit: "credits", id: "budget", incarnation: "sealed"}
      c = run_fixture(script, 1, budget_rule: :pause, budget: budget)
      base = c.opts[:bindings]["nested_callable"]
      child = %{requests: [request([action("slow", "tool_call"), finish_action("finish-child")])]}

      nested = %{
        base
        | facts: fn a -> %{base.facts.(a) | estimate: 5} end,
          nested: fn a -> %{base.nested.(a) | initial_state: child} end
      }

      engine = start(c, bindings: Map.put(c.opts[:bindings], "nested_callable", nested))
      assert {:ok, :applied} = start_run(c, engine)
      assert_receive {:effect_started, provider, _}, 5_000
      pause = %{kind: :pause, pause_deadline: 50_000}
      assert {:ok, :applied} = RunEngine.control(engine, "pause", pause, verified())
      tool = {2, 0}

      context = fn actual ->
        verified(%{occurrence: tool, actual: actual, dispatch: "dispatched"})
      end

      big = Integer.pow(2, 8 * 70_000)
      before = rows(c)
      big_result = Elzoo.RunEngine.TestHelper.result("slow")
      assert {:error, :record_size} = RunEngine.input(engine, "big", big_result, context.(big))
      assert rows(c) == before
      refute unit_state(c).slots[tool].phase == :settled

      assert {:ok, :applied} = RunEngine.input(engine, "small", big_result, context.(7))
      state = unit_state(c)
      assert %{phase: :settled} = state.slots[tool]
      assert %{pending_input: %{record: %{correlation: %{actual: 7}}}} = state.slots[{1, 0}]
      send(provider, {:result, %{}})
    end

    test "approved child finish of 60,000 bytes: a 40,000-byte tool actual is refused before or after the Approval, a small one is kept with the finish" do
      # The parent's outcome, which exhausts the root Budget under budget_rule :pause and so
      # is kept while paused, carries the child's finish and its actual twice in its slot.
      for order <- [:actual_first, :approval_first] do
        {c, engine, provider} = approved_child()
        tool = slot_key(c, "tool")
        result = Elzoo.RunEngine.TestHelper.result("tool")

        context = fn actual ->
          verified(%{occurrence: tool, actual: actual, dispatch: "dispatched"})
        end

        big = Integer.pow(2, 8 * 40_000)

        if order == :approval_first, do: approve_finish(c, engine)
        before = rows(c)

        assert {:error, :record_size} = RunEngine.input(engine, "big", result, context.(big)),
               "#{order}"

        # No record of the refused input is appended; the rows that the call adds are only
        # those of the owner's Run view that current/1 journals before the check.
        added = for row <- Enum.drop(rows(c), length(before)), do: decode(row)

        IO.puts(
          "ELZ-430: #{order}: rows added by the refused call: #{inspect(Enum.map(added, &row_kind/1))}"
        )

        refute Enum.any?(added, &match?({1, {"big", _}}, &1))
        assert Enum.all?(added, &(row_kind(&1) in [:run_view, :result]))
        refute unit_state(c).slots[tool].phase == :settled

        assert {:ok, :applied} = RunEngine.input(engine, "small", result, context.(7))
        if order == :actual_first, do: approve_finish(c, engine)
        state = unit_state(c)
        assert state.control.lifecycle.phase == :paused, "#{order}"
        assert %{pending_input: %{record: record}} = state.slots[{1, 0}]
        assert record.correlation.actual == 7
        assert record.input =~ String.duplicate("x", 60_000)
        send(provider, {:result, %{}})
      end
    end

    test "a parent charge into a root Budget with 60 entries expiring at 100: its sweep grows 60 bytes, and at every padding that admits the child's cursor the charge keeps the room for a stop" do
      {_c, _opts, changed, record} = settled_parent_with_resource(@rate)
      parent = {1, 0}
      held = hold_expiring(changed, "root", 60, 100)
      root = held.control.budgets["root"].state
      {:Transition, swept, _} = Elzoo.Budget.step(root, {3_000, :sweep})
      assert byte_size(binary(swept)) - byte_size(binary(root)) == 60
      charge = %{version: 1, kind: :nested_actual, occurrence: parent, actual: @rate, at_ms: 3_000}
      admitted = window(held, &RunEngine.cursor_admits?(pad_invocations(held, &1), record))
      assert admitted != []

      # The charge fits the bound and leaves the room for a stop free: its sweep's growth
      # was counted when the cursor was admitted.
      for target <- admitted do
        assert {:Transition, charged, :none} = RunEngine.step(pad_invocations(held, target), record)
        assert {:Transition, settled, :none} = RunEngine.step(charged, charge)
        assert settled.slots[parent].actual == @rate
        assert control_headroom(settled) >= 0
      end
    end

    test "after a change of Attempt settled a nested parent with no actual, its child's last Resource charge is admitted only with room for the charge that the parent takes after it; refused, it writes no row and strands no input" do
      {c, opts, changed, record} = settled_parent_with_resource(@rate)
      parent = {1, 0}
      assert %{phase: :settled} = changed.slots[parent]
      refute is_integer(changed.slots[parent][:actual])

      # The cursor transition settles the child's held Budget at the 400-byte actual, so
      # the child's cost is known, and the engine then charges the parent that amount,
      # stored twice in the root Budget, by a :nested_actual record of its own.
      assert {:Transition, charged, :none} = RunEngine.step(changed, record)
      child = charged.control.budgets["1:0"].state
      status = Elzoo.Budget.step(child, {3_000, :status})
      {:Transition, _, {:some, {:status, %{committed: amount}}}} = status
      assert amount == @rate
      charge = %{version: 1, kind: :nested_actual, occurrence: parent, actual: amount, at_ms: 3_000}
      assert {:Transition, settled, :none} = RunEngine.step(charged, charge)
      assert settled.slots[parent].actual == @rate
      cursor_growth = control_headroom(changed) - control_headroom(charged)
      charge_growth = control_headroom(charged) - control_headroom(settled)
      assert charge_growth > @room

      # With room for the cursor transition alone, the transition is refused: its charge
      # would fail the bound after the :nested_actual input commits.
      alone = pad_invocations(changed, cursor_growth)
      refute RunEngine.cursor_admits?(alone, record)
      assert {:Transition, alone_charged, :none} = RunEngine.step(alone, record)
      assert_raise MatchError, fn -> RunEngine.step(alone_charged, charge) end

      # With room for both, measured as admission bounds the charge (its amount twice in
      # the parent's Budget and 32 bytes for the entry's form, no release counted), it is
      # admitted, and the charge keeps the room; one byte less is refused.
      bound = cursor_growth + 2 * byte_size(binary(@rate)) + 32
      assert bound >= cursor_growth + charge_growth
      both = pad_invocations(changed, bound)
      assert RunEngine.cursor_admits?(both, record)
      refute RunEngine.cursor_admits?(pad_invocations(changed, bound - 1), record)
      assert {:Transition, both_charged, :none} = RunEngine.step(both, record)
      assert {:Transition, both_settled, :none} = RunEngine.step(both_charged, charge)
      assert control_headroom(both_settled) >= 0

      # Through the engine, with room for the cursor transition alone: the entry writes no
      # row, no charge is written, and the Unit reopens.
      journal_state(c, alone)
      before = rows(c)
      engine = start(c, opts)
      assert entry_rows(c, before) == []
      refute Enum.any?(records(c), &match?(%{kind: :nested_actual}, &1))
      assert unit_state(c).control.cursors == changed.control.cursors
      GenServer.stop(engine)
      assert :ok = DynamicUnits.stop(c.directory, c.prefix)
      start(c, opts)
      assert unit_state(c).control.cursors == changed.control.cursors
    end
  end

  # A root nested_callable whose child asks in one request for a tool call (dispatched with
  # no Approval) and a finish of 60,000 bytes that waits for Approval, under
  # budget_rule :pause with a root Budget of 5. Returns the fixture, the engine and the
  # tool's provider; the finish waits for Approval and the tool runs.
  defp approved_child do
    finish = finish_action("fin", %{"x" => String.duplicate("x", 60_000)})
    child = %{requests: [request([action("tool", "tool_call"), finish])]}
    script = fn frame -> [frame.([action("nested", "nested_callable")])] end
    budget = %{cap: 5, unit: "credits", id: "budget", incarnation: "sealed"}
    c = run_fixture(script, 1, budget_rule: :pause, budget: budget)
    require_approval(c)
    base = c.opts[:bindings]["nested_callable"]

    nested = %{
      base
      | facts: fn a -> %{base.facts.(a) | estimate: 5} end,
        nested: fn a -> %{base.nested.(a) | initial_state: child} end
    }

    bindings =
      c.opts[:bindings]
      |> Map.put("nested_callable", nested)
      |> Map.update!("tool_call", &%{&1 | effect_class: "compute"})
      |> Map.update!("finish", &%{&1 | effect_class: "publish"})

    engine = start(c, bindings: bindings)
    assert {:ok, :applied} = start_run(c, engine)
    assert_receive {:effect_started, provider, _}, 5_000
    wait_for(engine, &match?({_, %{phase: :approval}}, slot_of(&1, "fin")))
    {c, engine, provider}
  end

  # The host gives the Approval evidence of the child's finish.
  defp approve_finish(c, engine) do
    {:ok, run} = Run.status(c.run, "run")
    [%{request_key: key}] = run.approvals
    approval = %{kind: :approval_evidence, request_key: key, evidence: consent(key)}
    assert {:ok, :applied} = RunEngine.control(engine, "approve", approval, verified())
  end

  # The kind of a decoded Unit row: an input's record kind, or :result for a result row.
  defp row_kind({1, {_id, %{kind: kind}}}), do: kind
  defp row_kind(_), do: :result

  defp slot_key(c, action_id) do
    {key, _} = slot_of(unit_state(c), action_id)
    key
  end

  describe "bounded_times" do
    test "a time above 2^63 - 1 is refused with no write: the run_deadline start option, a pause or continue control, an input's context pause_deadline and a clock sample" do
      c = run_fixture(fn _frame -> [] end, 1)
      over = @max_time + 1
      assert {:error, _} = RunEngine.start_link(Keyword.put(c.opts, :run_deadline, over))
      assert rows(c) == []
      engine = start(c)
      assert {:ok, :applied} = start_run(c, engine)
      before = rows(c)
      pause = %{kind: :pause, pause_deadline: over}
      assert {:error, :invalid_control} = RunEngine.control(engine, "pause", pause, verified())
      continue = %{kind: :continue, run_deadline: over, person_id: "person"}

      assert {:error, :invalid_control} =
               RunEngine.control(engine, "continue", continue, verified())

      far = verified(%{pause_deadline: over})

      assert {:error, :pause_deadline_required} =
               RunEngine.input(engine, "far", input(c, "wake"), far)

      Agent.update(c.clock, fn _ -> over end)

      assert {:error, :invalid_input} =
               RunEngine.input(engine, "late", input(c, "wake"), verified())

      assert rows(c) == before
      assert %{reconciliation: nil} = view(engine)
    end

    test "a Run view whose revision is above 2^63 - 1 fails the start with no write, and later halts the engine before its commit" do
      c = run_fixture(fn _frame -> [] end, 1)
      over = forwarder(c, :over_revision)
      assert {:error, _} = RunEngine.start_link(Keyword.put(c.opts, :run_owner, over))
      assert rows(c) == []
      seam = forwarder(c, :spent)
      engine = start(c, run_owner: seam)
      assert {:ok, :applied} = start_run(c, engine)
      before = rows(c)
      assert :ok = GenServer.call(seam, {:set_mode, :over_revision})
      wake = input(c, "wake")
      assert {:error, :integrity_failure} = RunEngine.input(engine, "next", wake, verified())
      assert rows(c) == before
      assert %{reconciliation: :integrity_failure} = view(engine)
    end

    test "with an owner revision that the engine has not taken, a time above 2^63 - 1 in a control or at a fresh input writes nothing" do
      c = run_fixture(fn _frame -> [] end, 1)
      engine = start(c)
      assert {:ok, :applied} = start_run(c, engine)
      create_other(c)
      before = rows(c)
      seen = records(c)
      over = @max_time + 1
      far = verified(%{pause_deadline: over})
      pause = %{kind: :pause, pause_deadline: over}
      assert {:error, :invalid_control} = RunEngine.control(engine, "pause", pause, verified())
      continue = %{kind: :continue, run_deadline: over, person_id: "person"}

      assert {:error, :invalid_control} =
               RunEngine.control(engine, "continue", continue, verified())

      cancel = %{kind: :cancel, attempt_id: "attempt"}
      assert {:error, :invalid_control} = RunEngine.control(engine, "cancel", cancel, far)

      assert {:error, :pause_deadline_required} =
               RunEngine.input(engine, "far", input(c, "wake"), far)

      at = Agent.get(c.clock, & &1)
      Agent.update(c.clock, fn _ -> over end)
      pause = %{kind: :pause, pause_deadline: 50_000}
      assert {:error, :invalid_control} = RunEngine.control(engine, "now", pause, verified())

      assert {:error, :invalid_input} =
               RunEngine.input(engine, "late", input(c, "wake"), verified())

      assert rows(c) == before

      # The next request with bounded times takes the owner's new revision first.
      Agent.update(c.clock, fn _ -> at end)
      assert {:ok, _} = RunEngine.input(engine, "next", input(c, "wake"), verified())
      assert Enum.any?(records(c) -- seen, &match?(%{kind: :run_view}, &1))
    end

    test "an input, a pause, a continue and a cancel each read the clock once, before the owner's Run view is taken; a begin_attempt and approval evidence read it for no record of their own" do
      c = run_fixture(fn _frame -> [] end, 1)
      reads = start_supervised!({Agent, fn -> [] end}, id: make_ref())

      # Each read gives the next millisecond and is kept.
      clock = fn ->
        at = Agent.get_and_update(c.clock, &{&1, &1 + 1})
        Agent.update(reads, &[at | &1])
        at
      end

      engine = start(c, clock: clock)
      assert {:ok, :applied} = start_run(c, engine)

      # The times that the clock gave during `call`, in order, and the records that the call
      # committed, in commit order.
      sampled = fn call ->
        seen = records(c)
        Agent.update(reads, fn _ -> [] end)
        assert {:ok, :applied} = call.()
        {Enum.reverse(Agent.get(reads, & &1)), records(c) -- seen}
      end

      wake = fn id -> fn -> RunEngine.input(engine, id, input(c, "wake"), verified()) end end

      control = fn id, command, context ->
        fn -> RunEngine.control(engine, id, command, context) end
      end

      # With the owner's Run view taken, an input reads the clock once, for its record.
      assert {[at], [%{kind: :protocol, input: %{"at_ms" => at}}]} = sampled.(wake.("one"))

      # With the owner's revision moved by another Run's create, the input's one sample
      # comes first; the Run view that current/1 then journals takes a sample of its own.
      create_other(c)
      assert {[at, viewed], [synced, record]} = sampled.(wake.("two"))
      assert %{kind: :run_view, view: %{at_ms: ^viewed}} = synced
      assert %{kind: :protocol, input: %{"at_ms" => ^at}} = record

      # So do a pause and a continue, for their record.
      pause = control.("pause", %{kind: :pause, pause_deadline: 50_000}, verified())
      assert {[at], [%{kind: :lifecycle, command: %{at_ms: at}}]} = sampled.(pause)
      create_other(c, "another")
      continue = %{kind: :continue, person_id: "person", run_deadline: 60_000}
      continue = control.("continue", continue, verified(%{verified_person: "person"}))
      assert {[at, viewed], [synced, record]} = sampled.(continue)
      assert %{kind: :run_view, view: %{at_ms: ^viewed}} = synced
      assert %{kind: :lifecycle, command: %{at_ms: ^at}} = record

      # A begin_attempt reads the clock only for the Run view of the new Attempt.
      begin = control.("begin", %{kind: :begin_attempt, attempt_id: "second"}, verified())

      assert {[viewed], [%{kind: :run_view, view: %{at_ms: viewed, current_attempt: "second"}}]} =
               sampled.(begin)

      # Approval evidence (one that the owner refuses here) reads it for nothing.
      Agent.update(reads, fn _ -> [] end)
      evidence = %{kind: :approval_evidence, request_key: "none", evidence: %{}}

      assert {:error, {:run_control, _}} =
               RunEngine.control(engine, "evidence", evidence, verified())

      assert Agent.get(reads, & &1) == []

      # A cancel reads it once, for its input; each later read is the sample of a Run view
      # that the engine journals as the Run ends.
      cancel = control.("cancel", %{kind: :cancel, attempt_id: "second"}, verified())
      assert {[at | later], [cancelled | ended]} = sampled.(cancel)
      assert %{kind: :protocol, input: %{"kind" => "cancel", "at_ms" => ^at}} = cancelled
      assert [_ | _] = ended
      assert later == for(%{kind: :run_view, view: %{at_ms: viewed}} <- ended, do: viewed)
      assert length(later) == length(ended)
    end

    test "a fresh v2 outside event with a clock sample above 2^63 - 1 is invalid_input with no write; a paired retry is unchanged" do
      %{c: c, engine: engine, outside: outside, context: context} = waiting_event()
      create_other(c)
      before = rows(c)
      at = Agent.get(c.clock, & &1)
      Agent.update(c.clock, fn _ -> @max_time + 1 end)
      assert {:error, :invalid_input} = RunEngine.input(engine, "event", outside, context)
      Agent.update(c.clock, fn _ -> at end)
      far = Map.put(context, :pause_deadline, @max_time + 1)
      assert {:error, :pause_deadline_required} = RunEngine.input(engine, "event", outside, far)
      assert rows(c) == before
      assert {:ok, :applied} = RunEngine.input(engine, "event", outside, context)
      Agent.update(c.clock, fn _ -> @max_time + 1 end)
      assert {:ok, :unchanged} = RunEngine.input(engine, "event", outside, context)
    end

    test "a fresh v2 outside event whose clock sample is nil or 0 is invalid_input with no write" do
      %{c: c, engine: engine, outside: outside, context: context, queue: queue} = waiting_event()
      create_other(c)
      before = rows(c)

      for sample <- [nil, 0] do
        Agent.update(queue, fn _ -> [sample] end)
        assert {:error, :invalid_input} = RunEngine.input(engine, "event", outside, context)
        assert rows(c) == before
      end
    end

    test "a fresh v2 outside event reads the clock once, before the owner's Run view is taken, and records that sample: a later sample above 2^63 - 1 is not read" do
      %{c: c, engine: engine, outside: outside, context: context, queue: queue} = waiting_event()
      create_other(c)
      seen = records(c)
      at = Agent.get(c.clock, & &1)
      # The event's sample, the sample of the Run view that current/1 journals, then one
      # above the bound, which a second sample of the event would read.
      Agent.update(queue, fn _ -> [at, at + 1, @max_time + 1] end)
      assert {:ok, :applied} = RunEngine.input(engine, "event", outside, context)
      assert [synced, event] = records(c) -- seen
      assert %{kind: :run_view, view: %{at_ms: viewed}} = synced
      assert viewed == at + 1
      assert %{kind: :protocol, input: %{"kind" => "outside_event", "at_ms" => ^at}} = event
      assert Agent.get(queue, & &1) == [@max_time + 1]
    end

    test "a cancel control whose clock sample is nil is invalid_control with no write and cancels no task; with a sample, it cancels the task of the local work that its step closed" do
      c = fixture_for(:cancelled, 1)
      {clock, queue} = queued_clock(c)
      engine = start(c, clock: clock)
      assert {:ok, :applied} = start_run(c, engine)
      assert_receive {:local_started, task}, 5_000
      monitor = Process.monitor(task)
      before = rows(c)
      Agent.update(queue, fn _ -> [nil] end)
      cancel = %{kind: :cancel, attempt_id: "attempt"}
      assert {:error, :invalid_control} = RunEngine.control(engine, "cancel", cancel, verified())
      assert rows(c) == before
      assert {_, %{phase: :running}} = slot_of(unit_state(c), "slow")
      refute_receive {:DOWN, ^monitor, :process, ^task, _}, 200
      assert {:ok, :applied} = RunEngine.control(engine, "cancel", cancel, verified())
      assert {_, %{phase: :settled}} = slot_of(unit_state(c), "slow")
      assert_receive {:DOWN, ^monitor, :process, ^task, _}, 5_000
    end

    test "an ask_person binding whose facts give a deadline of 2^63 halts the engine integrity_failure before the admission commits, with no row; a later control, also one with a time above 2^63 - 1, gives that halt" do
      c = run_fixture(fn frame -> [frame.([action("ask", "ask_person")])] end, 1)
      person = c.opts[:bindings]["ask_person"]
      far = %{person | facts: &%{person.facts.(&1) | deadline_ms: @max_time + 1}}
      bindings = Map.put(c.opts[:bindings], "ask_person", far)
      engine = start(c, bindings: bindings)
      assert {:error, :integrity_failure} = start_run(c, engine)
      assert %{reconciliation: :integrity_failure} = view(engine)
      refute Enum.any?(records(c), &match?(%{kind: :admission}, &1))
      assert %{phase: :allowed} = slot = unit_state(c).slots[{1, 0}]
      refute Map.has_key?(slot, :deadline_ms)
      halted = rows(c)

      # The stored halt comes before a control's own checks, with no write.
      over = %{kind: :pause, pause_deadline: @max_time + 1}
      assert {:error, :integrity_failure} = RunEngine.control(engine, "over", over, verified())
      pause = %{kind: :pause, pause_deadline: 50_000}
      assert {:error, :integrity_failure} = RunEngine.control(engine, "pause", pause, verified())
      assert rows(c) == halted
      GenServer.stop(engine)
      before = rows(c)

      assert {:error, :integrity_failure} =
               RunEngine.start_link(Keyword.put(c.opts, :bindings, bindings))

      assert rows(c) == before
    end

    test "a journal that the earlier revision started with a run_deadline of 2^63 fails its restart with the same options, with no write" do
      probe = run_fixture(fn _frame -> [] end, 1)
      engine = start(probe)
      configured = unit_state(probe)
      GenServer.stop(engine)
      assert fingerprint(probe.opts, 60_000) == configured.control.fingerprint

      # The configuration as the earlier revision recorded it with that start option.
      over = @max_time + 1
      control = %{configured.control | fingerprint: fingerprint(probe.opts, over)}
      control = put_in(control.lifecycle.run_deadline, over)
      record = %{version: 1, kind: :configure, control: control}
      empty = %{version: 1, control: nil, slots: %{}, requests: %{}}
      assert {:Transition, recorded, :none} = RunEngine.step(empty, record)
      c = run_fixture(fn _frame -> [] end, 1)
      id = "configure:" <> Base.encode16(:crypto.hash(:sha256, binary("run")), case: :lower)

      append_rows(c, [
        {"input", 1, binary({1, {id, record}})},
        {"result", 1, binary({1, {id, recorded}})}
      ])

      before = rows(c)
      assert {:error, _} = RunEngine.start_link(Keyword.put(c.opts, :run_deadline, over))
      assert rows(c) == before
    end
  end

  # One crash cut of one source, in v1. The engine runs in Attempt "attempt" behind a
  # forwarder; the host begins Attempt "second" on the owner. `:kill`: the engine dies at
  # its `:complete` command and the host begins the new Attempt before the restart.
  # `:stale_kill`: the host begins it at the engine's revision sample for the command, the
  # owner answers the command (with the stop's Attempt) stale, and the engine dies at the
  # status read that follows, before it journals the new Run view; then it restarts.
  # `:stale`: as `:stale_kill`, and the engine goes on. In each case no stale stop is
  # pending, no other evidence row is written, the owner holds no terminal record, and a
  # wake of the new Attempt then reaches the root or asks for the stop of an unchanged
  # Run-wide limit.
  defp cut(source, mode) do
    stop = stop(source)
    c = fixture_for(source, 1)
    engine = start(c, run_owner: forwarder(c, owner_mode(c, stop, mode)))
    monitor = Process.monitor(engine)
    reply = drive(c, engine, source)

    engine =
      case mode do
        :kill ->
          assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
          # The stop (and the evidence row of a completion or failure) is committed; the
          # owner has seen no command.
          assert %{stop_pending: ^stop, attempt_id: "attempt"} = unit_state(c).control
          assert {:ok, %{outcome: nil, current_attempt: "attempt"}} = Run.status(c.run, "run")
          begin_attempt(c, "second")
          start(c)

        :stale_kill ->
          assert_stale_answer(c)
          assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
          assert %{stop_pending: ^stop, attempt_id: "attempt"} = unit_state(c).control
          start(c)

        :stale ->
          assert_stale_answer(c)
          assert reply == {:ok, :applied}
          wait_for(engine, &(&1.attempt_id == "second"))
          engine
      end

    evidence = evidence_rows(c)

    if stop in [:completed, :failed] do
      assert [row] = evidence
      assert decode(row).attempt_id == "attempt"
    else
      assert evidence == []
    end

    assert_open_in_second(c, engine, evidence)
    assert {:pending, :not_completed} = result(engine)
    after_change(c, engine, source)
    assert evidence_rows(c) == evidence
  end

  # The Run is open in Attempt "second": the owner holds no terminal record and only the
  # evidence rows `evidence`, and no stop, completion or cancel record of the older
  # Attempt is pending.
  defp assert_open_in_second(c, engine, evidence) do
    assert {:ok, %{outcome: nil, current_attempt: "second"}} = Run.status(c.run, "run")
    assert terminal_rows(c) == []
    assert evidence_rows(c) == evidence
    view = view(engine)
    assert %{attempt_id: "second", outcome: nil, stop_pending: nil, reconciliation: nil} = view
    assert view.phase != :terminal

    assert %{stop_pending: nil, completion: nil, attempt_id: "second", cancelled_attempt: nil} =
             unit_state(c).control
  end

  # The owner, now in "second", answers the command stale with its current revision; the
  # command carries the stop's own Attempt.
  defp assert_stale_answer(c) do
    assert_receive {:complete_reply, command, reply}, 5_000
    {:ok, owner} = Run.status(c.run, "run")
    assert owner.current_attempt == "second"
    assert {:unchanged, :stale, revision} = reply
    assert revision == owner.revision
    assert command.attempt_id == "attempt"
  end

  defp assert_history(read, label),
    do: assert(read == {:error, :history}, "#{label}: #{inspect(read, limit: 3)}")

  # A wake of the new Attempt reaches the root after a completion, a failure, a cancel and
  # an old pause deadline; past the Run deadline, with the Budget spent or at the request
  # cap it asks for that stop again, which the owner records for the new Attempt.
  defp after_change(c, engine, source)
       when source in [:completed, :failed, :cancelled, :pause_deadline] do
    flush_pattern_inputs()
    assert {:ok, :applied} = second_wake(c, engine)
    assert_receive {:pattern_input, "root", %{"kind" => "wake"}}, 2_000
    assert %{attempt_id: "second", outcome: nil, stop_pending: nil} = view(engine)
    assert {:ok, %{outcome: nil}} = Run.status(c.run, "run")
  end

  defp after_change(c, engine, source) do
    {outcome, reason} =
      case source do
        :run_deadline -> {:out_of_time, "engine"}
        :budget -> {:out_of_budget, "engine"}
        :request_cap -> {:out_of_budget, "request_cap"}
      end

    assert {:ok, :applied} = second_wake(c, engine)
    assert %{phase: :terminal, outcome: ^outcome, attempt_id: "second"} = view(engine)

    assert {:ok, %{outcome: ^outcome, reason: ^reason, current_attempt: "second"}} =
             Run.status(c.run, "run")

    assert [{:terminal, "run", ^outcome, ^reason, nil, _}] = terminal_rows(c)
    assert {:terminal, ^outcome} = result(engine)
  end

  defp second_wake(c, engine),
    do: RunEngine.input(engine, "second-wake", input(c, "wake"), verified(%{attempt_id: "second"}))

  defp stop(:completed), do: :completed
  defp stop(:failed), do: :failed
  defp stop(:cancelled), do: :cancelled
  defp stop(source) when source in [:run_deadline, :pause_deadline], do: :out_of_time
  defp stop(source) when source in [:budget, :request_cap], do: :out_of_budget

  defp owner_mode(_c, _stop, :kill), do: :kill
  defp owner_mode(c, stop, :stale_kill), do: begin_at_stop(c, stop, :kill_at_status)
  defp owner_mode(c, stop, :stale), do: begin_at_stop(c, stop, :spent)

  defp begin_at_stop(c, stop, then) do
    stopped? = fn ->
      case DynamicUnits.find(c.directory, c.prefix) do
        {:ok, unit} -> match?(%{control: %{stop_pending: ^stop}}, DurableUnit.snapshot(unit))
        _ -> false
      end
    end

    {:begin_at_stop, stopped?, "second", then, self()}
  end

  # The steps of each source up to the input whose step (or whose local work's outcome)
  # asks for the stop. A call that the forwarder ends by killing the engine gives :exit.
  defp drive(c, engine, source) when source in [:completed, :budget], do: start_run(c, engine)
  defp drive(c, engine, :failed), do: call(fn -> start_run(c, engine) end)

  defp drive(c, engine, :cancelled) do
    assert {:ok, :applied} = start_run(c, engine)
    assert_receive {:local_started, _}, 5_000

    call(fn ->
      RunEngine.input(
        engine,
        "cancel",
        input(c, "cancel", %{"attempt_id" => "attempt"}),
        verified()
      )
    end)
  end

  defp drive(c, engine, :run_deadline) do
    assert {:ok, :applied} = start_run(c, engine)
    Agent.update(c.clock, fn _ -> 61_000 end)
    call(fn -> RunEngine.input(engine, "late-wake", input(c, "wake"), verified()) end)
  end

  defp drive(c, engine, :pause_deadline) do
    assert {:ok, :applied} = start_run(c, engine)
    pause = %{kind: :pause, pause_deadline: 10_000}
    assert {:ok, :applied} = RunEngine.control(engine, "pause", pause, verified())
    assert view(engine).phase == :paused
    Agent.update(c.clock, fn _ -> 10_000 end)
    call(fn -> RunEngine.input(engine, "late-wake", input(c, "wake"), verified()) end)
  end

  defp drive(c, engine, :request_cap) do
    assert {:ok, :applied} = start_run(c, engine)

    assert %{request_count: 1} =
             wait_for(engine, &match?(%{slots: %{{1, 0} => %{phase: :settled}}}, &1))

    call(fn -> RunEngine.input(engine, "cap-wake", input(c, "wake"), verified()) end)
  end

  defp call(fun) do
    fun.()
  catch
    :exit, _ -> :exit
  end

  defp start_run(c, engine, attempt \\ "attempt"),
    do:
      RunEngine.input(
        engine,
        "start",
        %{start_input() | "version" => version(c)},
        verified(%{attempt_id: attempt})
      )

  defp fixture_for(source, version, opts \\ []),
    do: run_fixture(&script(source, &1), version, limit_opts(source) ++ opts)

  defp script(:completed, frame),
    do: [
      frame.([action("work")]),
      frame.([finish_action("finish", %{"action_id" => "work"})]),
      frame.([action("more")])
    ]

  defp script(:failed, frame),
    do: [frame.([finish_action("finish", @null)]), frame.([action("more")])]

  defp script(:cancelled, frame), do: [frame.([action("slow")])]
  defp script(:budget, frame), do: [frame.([action("work")])]
  defp script(:request_cap, frame), do: [frame.([action("one")])]
  defp script(_source, _frame), do: []

  # `work` completes; then `slow` is dispatched and runs while the finish that names
  # `work` completes the Run.
  defp completed_while_slow(frame),
    do: [
      frame.([action("work")]),
      frame.([action("slow"), finish_action("finish", %{"action_id" => "work"})])
    ]

  defp limit_opts(:budget),
    do: [budget: %{cap: 1, unit: "credits", id: "budget", incarnation: "sealed"}]

  defp limit_opts(:request_cap), do: [request_cap: 1]
  defp limit_opts(_source), do: []

  # A Run whose root is a scripted pattern that reports its inputs to the test process.
  # Local work named `slow` blocks; any other local work gives its payload back.
  defp run_fixture(script, version, opts \\ []) do
    parent = self()
    frame = if version == 2, do: &request_v2/1, else: &request/1
    root = {TestPattern, :scripted, %{name: "root", script: script.(frame)}}
    version_opts = if version == 2, do: [protocol_version: 2], else: []
    c = fixture([pattern: root] ++ version_opts ++ opts)

    work = fn action ->
      if action["id"] == "slow",
        do: {TestPattern, :blocked, [parent, action["payload"]]},
        else: {TestPattern, :work, [action["payload"]]}
    end

    bindings = Map.update!(c.opts[:bindings], "local_work", &Map.put(&1, :work, work))
    %{c | opts: Keyword.merge(c.opts, bindings: bindings, result_reader: reader(c))}
  end

  # `source`'s stop pending in Attempt "attempt" after the engine died at its owner
  # command, in protocol `version:` (1 by default); other `opts` go to the fixture.
  defp crashed(source, opts) do
    {version, opts} = Keyword.pop(opts, :version, 1)
    c = fixture_for(source, version, opts)
    engine = start(c, run_owner: forwarder(c, :kill))
    monitor = Process.monitor(engine)
    drive(c, engine, source)
    assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
    assert unit_state(c).control.stop_pending == stop(source)
    c
  end

  # A journal that the fold before ELZ-430 recorded from the step that set `source`'s stop
  # on, in Attempt "attempt", on the in-memory Store, in protocol `version:` (1 by
  # default): the engine died at its owner command, and each result row from the stop's
  # producing step on is that fold's projection (:base) of its input record, so the stop
  # holds no mark (rebase_earlier/1). `replaced: true` adds a wake past the Run deadline
  # whose out_of_time that fold let take the place of the stop. `attempts: 2` then has the
  # host begin "second" on the owner and adds that fold's Run view of "second", which kept
  # the stop; the owner revision matches the recorded one.
  defp earlier(source, opts) do
    version = Keyword.get(opts, :version, 1)
    c = crashed(source, version: version, unit_store: memory_unit_store(version))
    assert :ok = DynamicUnits.stop(c.directory, c.prefix)
    rebase_earlier(c)

    if Keyword.get(opts, :replaced, false) do
      Agent.update(c.clock, fn _ -> 61_000 end)
      wake = record(c, "late-wake", input(c, "wake", %{"at_ms" => 61_000}))
      step = append_earlier(c, "late-wake", wake)
      assert %{stop_pending: :out_of_time} = step.legacy.control
      assert step.current.control.stop_pending == stop(source)
    end

    if Keyword.get(opts, :attempts, 1) == 2 do
      begin_attempt(c, "second")
      {:ok, owner} = Run.status(c.run, "run")
      step = append_earlier(c, "run:#{owner.revision}", second_view(c, owner.revision))
      assert %{attempt_id: "second", stop_pending: kept} = step.legacy.control
      assert kept != nil and step.current.control.stop_pending == nil
    end

    c
  end

  # Rewrites the journal from the step that set the pending stop on as the fold before
  # ELZ-430 recorded it: each result row from that step on holds that fold's projection of
  # its input record on the rewritten state before it, its row digest made valid. This
  # fold had marked the stop; the rewritten journal holds no mark.
  defp rebase_earlier(c) do
    rows = rows(c)
    state = fn row -> elem(elem(decode(row), 1), 1) end

    index =
      Enum.find_index(rows, &(&1.kind == "result" and state.(&1).control.stop_pending != nil))

    assert Map.has_key?(state.(Enum.at(rows, index)).control, :stop_attempt)

    rows
    |> Enum.drop(index - 1)
    |> Enum.chunk_every(2)
    |> Enum.reduce(state.(Enum.at(rows, index - 2)), fn [input, result], before ->
      assert {input.kind, result.kind} == {"input", "result"}
      {1, {id, record}} = decode(input)
      {:ok, earlier} = RunEngine.project_event_wait_transition(before, record, :base)
      corrupt_row(c, result, {1, {id, earlier}})
      earlier
    end)

    refute Map.has_key?(last_state(c).control, :stop_attempt)
  end

  defp second_view(c, revision),
    do: %{
      version: version(c),
      kind: :run_view,
      view: %{
        id: "run",
        operation_id: "operation",
        current_attempt: "second",
        revision: revision,
        outcome: nil,
        at_ms: Agent.get(c.clock, & &1)
      }
    }

  # Journals `record` under `id` with the recorded state `legacy.(before, next)`, where
  # `next` is the state that today's fold gives: a pair that an earlier engine version
  # recorded, asserted to be exactly the step of the fold before ELZ-430. The Unit is
  # stopped first, as after a crash; the next start reads the pair. Returns the state
  # before, today's state and the recorded state.
  defp append_legacy(c, id, record, legacy) do
    assert :ok = DynamicUnits.stop(c.directory, c.prefix)
    before = last_state(c)
    {:Transition, next, :none} = RunEngine.step(before, record)
    recorded = legacy.(before, next)
    assert {:ok, recorded} === RunEngine.project_event_wait_transition(before, record, :base)

    append_rows(c, [
      {"input", 1, binary({1, {id, record}})},
      {"result", 1, binary({1, {id, recorded}})}
    ])

    %{before: before, current: next, legacy: recorded}
  end

  # Journals `record` under `id` with exactly the state that the fold before ELZ-430 gives.
  defp append_earlier(c, id, record) do
    append_legacy(c, id, record, fn before, _next ->
      {:ok, recorded} = RunEngine.project_event_wait_transition(before, record, :base)
      recorded
    end)
  end

  # Journals `record` under `id` as a committed input with no result, which the Unit
  # finishes at its next open. The Unit is stopped first.
  defp append_input(c, id, record) do
    assert :ok = DynamicUnits.stop(c.directory, c.prefix)
    append_rows(c, [{"input", 1, binary({1, {id, record}})}])
  end

  defp append_rows(c, rows) do
    {:ok, writer} =
      DurableLog.Writer.start_link(
        store: c.store,
        stream: c.prefix,
        fold: DurableUnit.fold(c.unit_opts),
        limits: DurableUnit.limits(c.unit_opts)
      )

    for row <- rows, do: assert({:committed, _} = DurableLog.Writer.append(writer, [row]))
    GenServer.stop(writer)
  end

  # The state of the last result row of the Unit journal.
  defp last_state(c) do
    [last | _] = Enum.reverse(rows(c))
    assert last.kind == "result"
    {1, {_id, state}} = decode(last)
    state
  end

  # The engine runs in Attempt "second" (it took that Run view while "ask" waited); then
  # its Unit stops, and the journal gains a wake of "second" past the Run deadline as the
  # fold before ELZ-430 recorded it, whose out_of_time carries no mark. The engine has not
  # read it.
  defp running_in_second_with_earlier_stop do
    c = run_fixture(fn frame -> [frame.([action("ask", "ask_person")])] end, 1)
    engine = start(c)
    assert {:ok, :applied} = start_run(c, engine)
    wait_for(engine, &match?({_, %{phase: :waiting}}, slot_of(&1, "ask")))
    begin_attempt(c, "second")
    assert {:ok, :applied} = second_wake(c, engine)
    assert %{attempt_id: "second", stop_pending: nil} = view(engine)
    Agent.update(c.clock, fn _ -> 61_000 end)
    wake = record(c, "late-wake", input(c, "wake", %{"at_ms" => 61_000}), attempt_id: "second")
    step = append_earlier(c, "late-wake", wake)
    assert %{stop_pending: :out_of_time, attempt_id: "second"} = step.legacy.control
    refute Map.has_key?(step.legacy.control, :stop_attempt)
    {c, engine}
  end

  # A cancelled Run in protocol `version` whose terminal Run view is as the revisions
  # before ELZ-215 recorded it, row digests made valid: the view (projected by hand) closed
  # the local work only, so the waiting ask stays open, where each fold that the reader
  # knows closes it. `:cancel_input`: a cancel input set the stop before the view, its
  # state as the fold before ELZ-430 recorded it (no mark). `:owner_cancel`: the host
  # cancelled the Run on the owner alone, and the next start took the terminal view with
  # no stop pending.
  defp pre_215_close(version, how) do
    c =
      run_fixture(fn frame -> [frame.([action("ask", "ask_person")])] end, version,
        unit_store: memory_unit_store(version)
      )

    engine = start(c)
    assert {:ok, :applied} = start_run(c, engine)
    wait_for(engine, &match?({_, %{phase: :waiting}}, slot_of(&1, "ask")))
    engine = cancel_run(c, engine, how)
    wait_for(engine, &(&1.outcome == :cancelled))
    assert {:ok, %{entries: [_ | _]}} = transcript(engine)
    unmarked = if how == :cancel_input, do: unmark_cancel(c)

    {row, _id, %{view: view} = record} =
      input_row(c, &match?(%{kind: :run_view, view: %{outcome: :cancelled}}, &1))

    {before, {id, _}, paired} = step_states(c, row)
    if unmarked, do: assert(before === unmarked)
    assert before.control.stop_pending == if(how == :cancel_input, do: :cancelled)
    assert {_, %{phase: :waiting}} = slot_of(before, "ask")

    legacy =
      before
      |> put_in([:control, :run_revision], view.revision)
      |> put_in([:control, :operation_id], view.operation_id)
      |> put_in([:control, :stop_pending], nil)
      |> put_in([:control, :lifecycle, :phase], :terminal)
      |> put_in([:control, :lifecycle, :outcome], :cancelled)

    for fold <- [:current, :base] do
      {:ok, projected} = RunEngine.project_event_wait_transition(before, record, fold)
      assert {_, %{phase: :settled}} = slot_of(projected, "ask")
    end

    corrupt_row(c, paired, {1, {id, legacy}})
    {c, engine}
  end

  defp cancel_run(c, engine, :cancel_input) do
    cancel = input(c, "cancel", %{"attempt_id" => "attempt"})
    assert {:ok, :applied} = RunEngine.input(engine, "cancel", cancel, verified())
    engine
  end

  defp cancel_run(c, engine, :owner_cancel) do
    GenServer.stop(engine)
    {:ok, owner} = Run.status(c.run, "run")

    assert {:ok, _, _} =
             Run.command(c.run, %{
               kind: :cancel,
               run_id: "run",
               attempt_id: "attempt",
               expected_revision: owner.revision
             })

    start(c)
  end

  # Rewrites the cancel's step as the fold before ELZ-430 recorded it, that fold's own
  # step with no mark, its row digest made valid; returns that state.
  defp unmark_cancel(c) do
    {row, _id, step} =
      input_row(c, &match?(%{kind: :protocol, input: %{"kind" => "cancel"}}, &1))

    {prior, {id, cancelled}, paired} = step_states(c, row)
    assert %{stop_pending: :cancelled, stop_attempt: {"attempt", :cancelled}} = cancelled.control
    {:ok, unmarked} = RunEngine.project_event_wait_transition(prior, step, :base)
    refute Map.has_key?(unmarked.control, :stop_attempt)
    corrupt_row(c, paired, {1, {id, unmarked}})
    unmarked
  end

  # The start refuses the pending stop: {:error, :stop_origin_unknown}, no new row, no
  # evidence row and no owner command.
  defp assert_refused(c, label \\ "") do
    before = {rows(c), evidence_rows(c), Run.status(c.run, "run")}
    assert {:error, :stop_origin_unknown} = RunEngine.start_link(c.opts), label
    assert {rows(c), evidence_rows(c), Run.status(c.run, "run")} == before, label
    assert terminal_rows(c) == [], label
  end

  defp label(source, replaced, version),
    do: "#{source}#{if replaced, do: " replaced by out_of_time"} v#{version}"

  # The loss that a local recovery records (recover_local/1) for the running local work in
  # slot `key` of `state`, at the clock: a `failed` outcome with reason `local_restart`.
  defp loss_record(c, state, {request, index} = key) do
    slot = state.slots[key]

    refusal = %{
      "reason" => "local_restart",
      "gate_id" => state.control.gate.id,
      "gate_version" => state.control.gate.version,
      "request" => request,
      "index" => index
    }

    outcome =
      input(c, "action_outcome", %{
        "action_id" => slot.action_id,
        "outcome" => "failed",
        "schema_id" => "elzoo.run-engine.refusal",
        "schema_version" => 1,
        "payload" => refusal,
        "at_ms" => Agent.get(c.clock, & &1)
      })

    record(c, "loss", outcome,
      attempt_id: slot.attempt_id,
      correlation: %{loss: :unavailable, occurrence: key}
    )
  end

  # A Run open in Attempt `attempt` (a 200-byte ID is the longest that the engine and the
  # Run owner take): the host begins it on the owner (the Run's second Attempt) and the
  # engine takes its Run view. `opts` go to the fixture. Returns the fixture and the Unit
  # state; the engine is stopped.
  defp in_attempt(attempt, opts \\ []) do
    c = run_fixture(fn _frame -> [] end, 1, opts)
    engine = start(c)
    assert {:ok, :applied} = start_run(c, engine)
    begin_attempt(c, attempt)
    wake = input(c, "wake")
    assert {:ok, :applied} = RunEngine.input(engine, "wake", wake, verified(%{attempt_id: attempt}))
    assert %{attempt_id: ^attempt, stop_pending: nil} = view(engine)
    state = unit_state(c)
    GenServer.stop(engine)
    {c, state}
  end

  # An ask with a 200-byte action ID in a 200-byte Attempt that the host began: the engine
  # dies at the ask's binding facts once, so its slot stays :allowed. Returns the fixture,
  # the Attempt ID, the action, the Unit state and the :admission record that the engine
  # commits for the ask, whose growth is its Budget reservation and the ask's wait, which
  # its continuation lists later.
  defp allowed_ask do
    long = String.duplicate("l", 200)
    ask = action(String.duplicate("q", 200), "ask_person", %{})
    c = run_fixture(fn frame -> [frame.([ask])] end, 1)
    person = c.opts[:bindings]["ask_person"]
    crash = start_supervised!({Agent, fn -> true end}, id: make_ref())

    facts = fn action ->
      if Agent.get_and_update(crash, &{&1, false}), do: Process.exit(self(), :kill)
      person.facts.(action)
    end

    begin_attempt(c, long)
    engine = start(c, bindings: Map.put(c.opts[:bindings], "ask_person", %{person | facts: facts}))
    call(fn -> start_run(c, engine, long) end)
    allowed = unit_state(c)
    assert %{phase: :allowed} = allowed.slots[{1, 0}]
    facts = person.facts.(ask)
    facts = Map.merge(facts, %{binding_id: person.id, binding_version: person.version, action: ask})
    at = Agent.get(c.clock, & &1)
    admission = %{version: 1, kind: :admission, occurrence: {1, 0}, facts: facts, at_ms: at}
    {c, long, ask, allowed, admission}
  end

  # An ask `ask` (to "person") waiting in Attempt "attempt", its wait listed. Returns the
  # fixture and the Unit state; the engine is stopped.
  defp waiting_ask do
    c = run_fixture(fn frame -> [frame.([action("ask", "ask_person", %{})])] end, 1)
    engine = start(c)
    assert {:ok, :applied} = start_run(c, engine)
    wait_for(engine, &match?({_, %{phase: :waiting}}, slot_of(&1, "ask")))
    state = unit_state(c)
    GenServer.stop(engine)
    assert Map.has_key?(state.control.lifecycle.waits, "ask")
    {c, state}
  end

  # `state` with `count` one-credit entries held in Budget `holder` that expire at
  # `expiry` (entries that a Run on a clock below `expiry` reserved, as the Budget takes
  # them).
  defp hold_expiring(state, holder, count, expiry) do
    budget = state.control.budgets[holder].state
    {:Transition, _, {:some, {:status, status}}} = Elzoo.Budget.step(budget, {1, :status})

    held =
      Enum.reduce(1..count, budget, fn index, acc ->
        reserve = %{
          cap: status.cap,
          unit: status.unit,
          estimate: 1,
          cost_ref: "held-#{index}",
          expiry: expiry
        }

        {:Transition, next, {:some, {:reserved, _}}} =
          Elzoo.Budget.step(acc, {1, {:reserve, reserve}})

        next
      end)

    put_in(state.control.budgets[holder].state, held)
  end

  # `state` with its root Budget spent to its cap by a Budget step of its own (as a root
  # Resource cursor's settlement spends it), the lifecycle left as it is.
  defp exhaust_root(state) do
    budget = state.control.budgets["root"].state
    {:Transition, _, {:some, {:status, status}}} = Elzoo.Budget.step(budget, {2_000, :status})
    spend = status.cap - status.committed - status.reserved

    reserve = %{
      cap: status.cap,
      unit: status.unit,
      estimate: spend,
      cost_ref: "spent",
      expiry: 50_000
    }

    {:Transition, held, {:some, {:reserved, %{generation: generation}}}} =
      Elzoo.Budget.step(budget, {2_000, {:reserve, reserve}})

    settle = %{cost_ref: "spent", generation: generation, actual: spend + status.reserved}

    {:Transition, spent, {:some, {:settled, _}}} =
      Elzoo.Budget.step(held, {2_000, {:settle, settle}})

    put_in(state.control.budgets["root"].state, spent)
  end

  # A root request with a nested_callable `nested` whose child asks for `child_script` (by
  # default an action in its first request, past request cap 1): the engine dies at the
  # nested binding once, so the slot stays :ready. `opts`: `request_cap` (1), `estimate`
  # (the nested action's estimate, also the root Budget's cap; the binding's when absent),
  # `budget_id` (the child Budget's ID) and `child_script`. Returns the Unit state and the
  # :nested record that the engine commits for the slot.
  defp ready_nested_at_cap(opts \\ []) do
    script = fn frame -> [frame.([action("nested", "nested_callable")])] end
    estimate = opts[:estimate]

    budget =
      if estimate,
        do: [budget: %{cap: estimate, unit: "credits", id: "budget", incarnation: "sealed"}],
        else: []

    c = run_fixture(script, 1, [request_cap: Keyword.get(opts, :request_cap, 1)] ++ budget)
    base = c.opts[:bindings]["nested_callable"]
    child = %{name: "nested", script: Keyword.get(opts, :child_script, [request([action("deep")])])}
    budget_id = opts[:budget_id]

    facts = fn a ->
      nested = %{base.nested.(a) | mfa: {TestPattern, :scripted}, initial_state: child}
      if budget_id, do: %{nested | budget_id: budget_id}, else: nested
    end

    admission =
      if estimate, do: fn a -> %{base.facts.(a) | estimate: estimate} end, else: base.facts

    crash = start_supervised!({Agent, fn -> true end}, id: make_ref())

    nested = fn a ->
      if Agent.get_and_update(crash, &{&1, false}), do: Process.exit(self(), :kill)
      facts.(a)
    end

    bindings =
      Map.put(c.opts[:bindings], "nested_callable", %{base | nested: nested, facts: admission})

    engine = start(c, bindings: bindings)
    call(fn -> start_run(c, engine) end)
    ready = unit_state(c)
    assert %{phase: :ready} = ready.slots[{1, 0}]

    record = %{
      version: 1,
      id: "nested",
      kind: :nested,
      occurrence: {1, 0},
      facts: facts.(action("nested", "nested_callable")),
      at_ms: Agent.get(c.clock, & &1),
      context: %{pause_deadline: 50_000}
    }

    {ready, record}
  end

  # A nested_callable `nested` whose child opened a Resource "document" (at `rate` per
  # minute, its reservation in the child's Budget) that closed on a pause; the host then
  # began Attempt "second", and the fold of its Run view settled the parent with no actual.
  # The Resource's next entry settles the child's held Budget at the rate. Returns the
  # fixture, the engine options, the state after that Run view (by the fold alone; the
  # engine is stopped and the owner is in "second") and the entry's cursor record. With
  # `estimate`, the open's reservation, the nested action's estimate and the root Budget's
  # cap are that amount.
  defp settled_parent_with_resource(rate, estimate \\ nil) do
    payload = %{"run_id" => "run", "resource_name" => "document", "data" => %{}}
    child = %{name: "nested", script: [request([action("open", "resource_open", payload)])]}
    script = fn frame -> [frame.([action("nested", "nested_callable")])] end

    root =
      if estimate,
        do: [budget: %{cap: estimate, unit: "credits", id: "budget", incarnation: "sealed"}],
        else: []

    c = run_fixture(script, 1, root)

    budget = %{
      budget_id: "nested-nested",
      unit: "credits",
      cost_ref: "2:0",
      generation: {"sealed", 1}
    }

    {owner, bindings} = resource(c, :close, budget, %{rate_per_minute: rate})

    bindings =
      if estimate do
        Map.new(bindings, fn {kind, binding} ->
          if kind in ["resource_open", "resource_use", "resource_close", "nested_callable"],
            do: {kind, %{binding | facts: &%{binding.facts.(&1) | estimate: estimate}}},
            else: {kind, binding}
        end)
      else
        bindings
      end

    base = bindings["nested_callable"]
    nested = fn a -> %{base.nested.(a) | mfa: {TestPattern, :scripted}, initial_state: child} end
    bindings = Map.put(bindings, "nested_callable", %{base | nested: nested})
    opts = [resources: %{"document" => owner}, bindings: bindings]
    engine = start(c, opts)
    assert {:ok, :applied} = start_run(c, engine)
    assert_receive {:effect_started, _opening, _}, 5_000
    observed(owner, "opened", "open", %{opened_at_ms: 2_000}, 2_000)
    assert {:ok, :applied} = RunEngine.input(engine, "consume-open", input(c, "wake"), verified())
    Agent.update(c.clock, fn _ -> 3_000 end)
    assert {:ok, _} = Elzoo.RunResource.command(owner, %{id: "pause", at_ms: 3_000, body: :pause})
    assert {:ok, :applied} = RunEngine.input(engine, "consume-close", input(c, "wake"), verified())
    assert_receive {:effect_started, _closing, _}, 5_000
    assert {:ok, :applied} = RunEngine.input(engine, "dispatched", input(c, "wake"), verified())
    observed(owner, "closed", "cleanup", %{opened_at_ms: 2_000, closed_at_ms: 3_000}, 3_000)
    GenServer.stop(engine)
    state = unit_state(c)
    begin_attempt(c, "second")
    {:ok, %{revision: revision}} = Run.status(c.run, "run")

    view = %{
      version: 1,
      kind: :run_view,
      view: %{
        id: "run",
        operation_id: "operation",
        current_attempt: "second",
        revision: revision,
        outcome: nil,
        at_ms: 3_000
      }
    }

    assert {:Transition, changed, :none} = RunEngine.step(state, view)
    cursor = changed.control.cursors["document"]
    {:ok, %{entries: [entry]}} = Elzoo.RunResource.read(owner, cursor)
    assert {:settle, %{actual: ^rate}} = entry.budget_command

    record = %{
      cursor_record(entry.seq)
      | budget_owner: "1:0",
        budget_command: entry.budget_command,
        at_ms: 3_000
    }

    {c, opts, changed, record}
  end

  # A clock that gives the times queued in the returned Agent first, one per read, and the
  # fixture's clock once the queue is empty.
  defp queued_clock(c) do
    queue = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    clock = fn ->
      case Agent.get_and_update(queue, fn
             [] -> {:empty, []}
             [at | rest] -> {{:queued, at}, rest}
           end) do
        {:queued, at} -> at
        :empty -> Agent.get(c.clock, & &1)
      end
    end

    {clock, queue}
  end

  # A v2 Run whose `wait_event` waits on a source that gives the requested event at
  # sequence 1, with the engine on a queued clock (queued_clock/1). Returns the fixture,
  # the engine, the outside event for the wait, its context and the clock's queue.
  defp waiting_event do
    ticket = start_supervised!({Agent, fn -> nil end}, id: make_ref())

    event = fn _scope, id ->
      {:ok,
       %{
         head: %{revision: 1, low_water: 0},
         event: %{
           id: id,
           source_id: "events",
           correlation_id: Agent.get(ticket, & &1),
           sequence: 1,
           schema_id: "result",
           schema_version: 1,
           payload: %{"accepted" => true}
         }
       }}
    end

    head = fn _scope -> {:ok, %{revision: 0, low_water: 0}} end
    source = %{id: "events", version: 1, head: head, read: event}
    script = fn frame -> [frame.([action("wait", "wait_event")])] end
    c = run_fixture(script, 2, event_source: source)
    {clock, queue} = queued_clock(c)
    engine = start(c, clock: clock)
    assert {:ok, :applied} = start_run(c, engine)
    {:ok, %{waits: [waiting]}} = RunEngine.event_waits(engine, scope(), limits())
    Agent.update(ticket, fn _ -> waiting.correlation_id end)

    outside = %{
      "type" => "input",
      "version" => 2,
      "kind" => "outside_event",
      "action_id" => waiting.action_id,
      "source_id" => waiting.source_id,
      "correlation_id" => waiting.correlation_id,
      "event_id" => "event",
      "schema_id" => "result",
      "schema_version" => 1,
      "payload" => %{"accepted" => true}
    }

    context = verified(%{occurrence: waiting.occurrence, actual: 0, dispatch: "not_dispatched"})
    %{c: c, engine: engine, outside: outside, context: context, queue: queue}
  end

  # Journals `state` as the Unit's recorded state, after an input of its own (`id`); the
  # Unit is stopped first, and the engine's next start reads it.
  defp journal_state(c, state, id \\ "padded") do
    assert :ok = DynamicUnits.stop(c.directory, c.prefix)

    append_rows(c, [
      {"input", 1, binary({1, {id, %{version: state.version, kind: :pad}}})},
      {"result", 1, binary({1, {id, state}})}
    ])
  end

  # A request in Attempt `attempt` that sets a stop: a wake past the Run deadline (the
  # clock set there) or a cancel. A call that the forwarder ends by killing the engine
  # gives :exit.
  defp stop_request(c, engine, :wake, attempt) do
    Agent.update(c.clock, fn _ -> 61_000 end)
    wake = input(c, "wake")
    call(fn -> RunEngine.input(engine, "late-wake", wake, verified(%{attempt_id: attempt})) end)
  end

  defp stop_request(c, engine, :cancel, attempt) do
    cancel = input(c, "cancel", %{"attempt_id" => attempt})
    call(fn -> RunEngine.input(engine, "cancel", cancel, verified(%{attempt_id: attempt})) end)
  end

  # Another Run's create (Run `other`) on the shared owner moves the owner's revision, and
  # not this Run's Attempt or outcome.
  defp create_other(c, other \\ "other") do
    {:ok, owner} = Run.status(c.run, "run")

    assert {:ok, _, _} =
             Run.command(c.run, %{
               kind: :create,
               run_id: other,
               operation_id: "operation-" <> other,
               provider_refs: %{},
               expected_revision: owner.revision
             })
  end

  # A :resource_cursor record of Resource "document" at `sequence`, with no Budget command.
  defp cursor_record(sequence),
    do: %{
      version: 1,
      kind: :resource_cursor,
      resource: "document",
      sequence: sequence,
      budget_owner: nil,
      budget_command: nil,
      at_ms: 2_000
    }

  # An opened Resource "document" at the admission limit whose next entry would add its
  # key: its first entries were read with room, then its key was removed from the recorded
  # state, padded to the limit, and the host reported the open completed. The engine is
  # stopped; the open's slot runs. `fixture_opts` go to the fixture.
  defp blocked_open(fixture_opts \\ []) do
    payload = %{"run_id" => "run", "resource_name" => "document", "data" => %{}}
    script = fn frame -> [frame.([action("open", "resource_open", payload)])] end
    c = run_fixture(script, 1, fixture_opts)
    {owner, bindings} = resource(c)
    opts = [resources: %{"document" => owner}, bindings: bindings]
    engine = start(c, opts)
    assert {:ok, :applied} = start_run(c, engine)
    assert_receive {:effect_started, _opening, _}, 5_000
    GenServer.stop(engine)
    state = put_in(unit_state(c).control.classification, :late)
    assert %{"document" => _} = state.control.cursors
    padded = pad_invocations(update_in(state.control.cursors, &Map.delete(&1, "document")), 0)
    journal_state(c, padded)
    observed(owner, "opened", "open", %{opened_at_ms: 2_000}, 2_000)
    {c, opts}
  end

  # An opened Resource "document" at `rate` per minute, closed on a pause after one
  # minute's use or less: the entry that the engine reads next gives the root the closed
  # event and settles the open's held Budget at `rate`, a same-width cursor advance. The
  # engine is stopped. Returns the fixture, the engine options and the Resource owner.
  defp closed_resource(rate) do
    payload = %{"run_id" => "run", "resource_name" => "document", "data" => %{}}
    c = run_fixture(fn frame -> [frame.([action("open", "resource_open", payload)])] end, 1)
    {owner, bindings} = resource(c, :close, nil, %{rate_per_minute: rate})
    opts = [resources: %{"document" => owner}, bindings: bindings]
    engine = start(c, opts)
    assert {:ok, :applied} = start_run(c, engine)
    assert_receive {:effect_started, _opening, _}, 5_000
    observed(owner, "opened", "open", %{opened_at_ms: 2_000}, 2_000)
    assert {:ok, :applied} = RunEngine.input(engine, "consume-open", input(c, "wake"), verified())
    Agent.update(c.clock, fn _ -> 3_000 end)
    assert {:ok, _} = Elzoo.RunResource.command(owner, %{id: "pause", at_ms: 3_000, body: :pause})
    assert {:ok, :applied} = RunEngine.input(engine, "consume-close", input(c, "wake"), verified())
    assert_receive {:effect_started, _closing, _}, 5_000
    # The engine's dispatch of the cleanup is an entry of its own, read here.
    assert {:ok, :applied} = RunEngine.input(engine, "dispatched", input(c, "wake"), verified())
    observed(owner, "closed", "cleanup", %{opened_at_ms: 2_000, closed_at_ms: 3_000}, 3_000)
    GenServer.stop(engine)
    {c, opts, owner}
  end

  # The host's report to the Resource `owner` that its effect `effect` completed.
  defp observed(owner, id, effect, data, at) do
    identity = ["tenant", "account", "effect", "publish", effect]

    assert {:ok, _} =
             Elzoo.RunResource.command(owner, %{
               id: id,
               at_ms: at,
               body: {:observed, identity, {:completed, data}}
             })
  end

  # The IDs of the rows after `before` that consume a Resource entry: its inputs and
  # results, and its cursor record.
  defp entry_rows(c, before) do
    for row <- Enum.drop(rows(c), length(before)),
        {1, {id, record}} <- [decode(row)],
        Map.get(record, :kind) == :resource_cursor or String.starts_with?(id, "resource:"),
        do: id
  end

  # A Budget option whose configuration leaves `headroom` bytes past the room, from the
  # state `configured` that the fixture's Budget gave: its ID is longer than 65,535
  # characters, which encode in 2 bytes each, and the incarnation sets the parity.
  defp budget_leaving(configured, headroom) do
    Enum.find_value(["sealed", "sealed!"], fn incarnation ->
      left = fn n ->
        {:ok, budget} = Elzoo.Budget.initial(String.duplicate("b", n), incarnation, 100, "credits")
        control_headroom(put_in(configured.control.budgets["root"].state, budget))
      end

      gap = left.(65_536) - headroom
      n = 65_536 + div(gap, 2)

      if rem(gap, 2) == 0 and left.(n) == headroom,
        do: %{cap: 100, unit: "credits", id: String.duplicate("b", n), incarnation: incarnation}
    end)
  end

  # A Unit whose Run a cancel ended, and the owner's next Run "period-two" in its Attempt
  # "attempt-two"; the engine is stopped.
  defp ended_run do
    c = run_fixture(fn _frame -> [] end, 1)
    engine = start(c)
    assert {:ok, :applied} = start_run(c, engine)
    cancel = input(c, "cancel", %{"attempt_id" => "attempt"})
    assert {:ok, _} = RunEngine.input(engine, "cancel", cancel, verified())
    wait_for(engine, &(&1.outcome == :cancelled))
    GenServer.stop(engine)
    {:ok, ended} = Run.status(c.run, "run")

    assert {:ok, revision, _} =
             Run.command(c.run, %{
               kind: :create,
               run_id: "period-two",
               operation_id: "operation-two",
               provider_refs: %{},
               expected_revision: ended.revision
             })

    assert {:ok, _, _} =
             Run.command(c.run, %{
               kind: :begin_attempt,
               run_id: "period-two",
               attempt_id: "attempt-two",
               expected_revision: revision
             })

    c
  end

  # The fingerprint that a v1 engine records for `opts` with the Run deadline `deadline`:
  # the digest of its identity (pattern, schemas, bindings, gate, scope, caps, unit, rule
  # and Run deadline).
  defp fingerprint(opts, deadline) do
    {module, function, _initial} = opts[:pattern]
    schemas = Map.new(opts[:schemas], fn {key, schema} -> {key, {schema.port, schema.digest}} end)

    bindings =
      Map.new(opts[:bindings], fn {key, binding} -> {key, {binding.id, binding.version}} end)

    gate = Map.take(opts[:gate], [:id, :version])
    budget = opts[:budget]

    identity =
      {{module, function}, schemas, bindings, gate, opts[:tenant], opts[:principal],
       opts[:request_cap], budget.cap, budget.unit, opts[:budget_rule], deadline}

    :crypto.hash(:sha256, binary(identity))
  end

  # A completed Run whose state recorded after the terminal Run view is `tamper`ed, its
  # row digest made valid, reads as damaged history.
  defp terminal_tamper(version, tamper) do
    c = fixture_for(:completed, version, unit_store: memory_unit_store(version))
    engine = start(c)
    assert {:ok, :applied} = start_run(c, engine)
    wait_for(engine, &(&1.outcome == :completed))
    assert {:ok, %{entries: [_ | _]}} = transcript(engine)

    {row, _id, _record} =
      input_row(c, &match?(%{kind: :run_view, view: %{outcome: :completed}}, &1))

    {_before, {id, state}, paired} = step_states(c, row)
    changed = tamper.(state)
    refute changed === state
    corrupt_row(c, paired, {1, {id, changed}})
    assert_history(transcript(engine), "v#{version} transcript")
    assert_history(result(engine), "v#{version} result")
  end

  # The state before the step of the input row `row`, its paired {input ID, recorded
  # state}, and the result row that holds it.
  defp step_states(c, row) do
    [prior] = Enum.filter(rows(c), &(&1.sequence == row.sequence - 1))
    [paired] = Enum.filter(rows(c), &(&1.sequence == row.sequence + 1))
    assert {prior.kind, paired.kind} == {"result", "result"}
    {1, {_, before}} = decode(prior)
    {1, recorded} = decode(paired)
    {before, recorded, paired}
  end

  # `stop` is pending after a crash at the owner command, with local work `slow` running
  # (closed by the cancel of a pending cancellation) and the asks `ask` and `pay`
  # waiting. A request of `request` kind is then journaled as the engine journals an
  # input (a wake past the Run deadline, a cancel, an answer of `pay` whose actual spends
  # the Budget, a wake at the request cap): it asks for a stop, loses to `stop` and leaves
  # no trace (no charge stop, no cancel record, no closed local work of its own). The
  # restart completes the owner with `stop` and its own reason, and the end of the Run
  # settles every slot (none is retained as for a request-cap stop).
  defp losing(stop, request) do
    count = if stop == :completed, do: 2, else: 1
    cap = if request == :cap, do: count, else: count + 1
    budget = %{cap: 5, unit: "credits", id: "budget", incarnation: "sealed"}
    c = run_fixture(&losing_script(stop, &1), 1, request_cap: cap, budget: budget)
    engine = start(c, run_owner: forwarder(c, :kill))
    monitor = Process.monitor(engine)
    drive_losing(c, engine, stop)
    assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
    crashed = unit_state(c)
    assert %{stop_pending: ^stop, count: ^count, charge_stopped: false} = crashed.control

    for id <- ["ask", "pay"], do: assert({_, %{phase: :waiting}} = slot_of(crashed, id))
    {pay, _} = slot_of(crashed, "pay")
    {at, losing, asked} = losing_record(c, request, pay)
    {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
    assert {:ok, :applied} = DurableUnit.step(unit, "losing", losing)

    folded = unit_state(c)
    if request == :budget, do: assert(committed(c) >= 5)

    # The restart completes the owner with the pending stop and its own reason, and the end
    # of the Run settles every slot.
    Agent.update(c.clock, fn _ -> at end)
    engine = start(c)
    assert %{phase: :terminal, outcome: ^stop} = wait_for(engine, &(&1.outcome != nil))
    reason = if stop == :failed, do: "pattern", else: "engine"
    assert {:ok, %{outcome: ^stop, reason: ^reason}} = Run.status(c.run, "run")
    assert [{:terminal, "run", ^stop, ^reason, _, _}] = terminal_rows(c)
    final = unit_state(c)

    for id <- ["slow", "ask", "pay"],
        do: assert({_, %{phase: :settled}} = slot_of(final, id), "#{id} is settled")

    refute final.control.charge_stopped

    # The step of the request asked for its stop and kept the pending one, with no charge
    # stop, cancel record or closed local work of its own.
    assert %{stop_pending: ^stop, charge_stopped: false} = folded.control
    assert folded.control.cancelled_attempt == crashed.control.cancelled_attempt
    assert folded.control.completion == crashed.control.completion
    if asked, do: assert(folded.control.classification == {:request_outcome, asked})

    if request == :cancel,
      do: assert(elem(slot_of(folded, "slow"), 1).phase == elem(slot_of(crashed, "slow"), 1).phase)
  end

  defp drive_losing(c, engine, :completed), do: assert({:ok, :applied} = start_run(c, engine))

  defp drive_losing(c, engine, :failed) do
    call(fn -> start_run(c, engine) end)
    assert_receive {:local_started, _}, 5_000
  end

  defp drive_losing(c, engine, :cancelled), do: drive(c, engine, :cancelled)

  defp losing_script(stop, frame) do
    open = [action("slow"), action("ask", "ask_person"), action("pay", "ask_person")]

    case stop do
      :completed ->
        [
          frame.([action("work")]),
          frame.(open ++ [finish_action("finish", %{"action_id" => "work"})])
        ]

      :failed ->
        [frame.(open ++ [finish_action("finish", @null)])]

      :cancelled ->
        [frame.(open)]
    end
  end

  defp losing_record(c, :deadline, _pay),
    do: {61_000, record(c, "losing", input(c, "wake", %{"at_ms" => 61_000})), :out_of_time}

  defp losing_record(c, :cancel, _pay) do
    cancel = input(c, "cancel", %{"attempt_id" => "attempt", "at_ms" => 3_000})
    {3_000, record(c, "losing", cancel), :cancelled}
  end

  defp losing_record(c, :cap, _pay),
    do: {3_000, record(c, "losing", input(c, "wake", %{"at_ms" => 3_000})), :out_of_budget}

  # The answer of `pay` reports an actual of 5: with what is committed it spends the
  # Budget of 5, and the step that settles it asks for out_of_budget.
  defp losing_record(c, :budget, pay) do
    answer =
      input(c, "person_answer", %{
        "action_id" => "pay",
        "person_id" => "person",
        "schema_id" => "result",
        "schema_version" => 1,
        "payload" => %{},
        "at_ms" => 3_000
      })

    opts = [correlation: %{occurrence: pay, actual: 5}, context: %{verified_person: "person"}]
    {3_000, record(c, "losing", answer, opts), nil}
  end

  # The source's stop is pending after a crash at the owner command, the host began
  # Attempt "second" on the owner, and the restart's Run view dropped the stop; on the
  # in-memory Store, whose rows a test can change.
  defp dropped_on_memory(source, version) do
    c = fixture_for(source, version, unit_store: memory_unit_store(version))
    engine = start(c, run_owner: forwarder(c, :kill))
    monitor = Process.monitor(engine)
    drive(c, engine, source)
    assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
    assert unit_state(c).control == Map.merge(unit_state(c).control, crashed_control(source))
    begin_attempt(c, "second")
    engine = start(c)
    assert %{attempt_id: "second", stop_pending: nil} = view(engine)
    {c, engine}
  end

  # The control facts of the source's pending stop that the change of Attempt drops.
  defp crashed_control(:completed),
    do: %{stop_pending: :completed, completion: {1, 0}, generation_closed: true}

  defp crashed_control(:cancelled), do: %{stop_pending: :cancelled, cancelled_attempt: "attempt"}

  defp new_attempt_view_row(c),
    do: input_row(c, &match?(%{kind: :run_view, view: %{current_attempt: "second"}}, &1))

  defp input(c, kind), do: input(c, kind, %{})

  defp input(c, kind, fields),
    do: Map.merge(%{"type" => "input", "version" => version(c), "kind" => kind}, fields)

  defp record(c, id, input, opts \\ []),
    do: %{protocol_record(id, input, opts) | version: version(c)}

  defp version(c), do: Keyword.get(c.opts, :protocol_version, 1)

  defp forwarder(c, mode),
    do:
      start_supervised!(%{
        id: make_ref(),
        start: {GenServer, :start_link, [CompleteForwarder, {c.run, mode}]}
      })

  # The host begins `attempt` on the Run owner alone, with no engine command.
  defp begin_attempt(c, attempt) do
    {:ok, owner} = Run.status(c.run, "run")

    assert {:ok, _, _} =
             Run.command(c.run, %{
               kind: :begin_attempt,
               run_id: "run",
               attempt_id: attempt,
               expected_revision: owner.revision
             })
  end

  defp flush_pattern_inputs do
    receive do
      {:pattern_input, _, _} -> flush_pattern_inputs()
    after
      0 -> :ok
    end
  end

  defp unit_state(c) do
    {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
    DurableUnit.snapshot(unit)
  end

  defp committed(c) do
    root = unit_state(c).control.budgets["root"]
    at = Agent.get(c.clock, & &1)
    {:Transition, _, {:some, {:status, status}}} = Elzoo.Budget.step(root.state, {at, :status})
    status.committed
  end

  # The engine records of the Unit journal, in commit order.
  defp records(c) do
    for %{kind: "input", payload: payload} <- rows(c),
        {1, {_id, record}} <- [:erlang.binary_to_term(payload, [:safe])],
        do: record
  end

  defp evidence_rows(c) do
    {:ok, rows, _head} = DurableLog.read(c.evidence_store, "evidence", 1, 1_000)
    rows
  end

  # The owner's terminal records of this Run.
  defp terminal_rows(c) do
    {:ok, rows, _head} = DurableLog.read(c.run_store, "runs", 1, 1_000)

    for %{kind: "run", payload: payload} <- rows,
        {:terminal, "run", _, _, _, _} = event <- [:erlang.binary_to_term(payload, [:safe])],
        do: event
  end

  defp decode(row), do: :erlang.binary_to_term(row.payload, [:safe])

  # The one Unit input row whose record `fun` selects: the row, its input ID and record.
  defp input_row(c, fun) do
    [found] =
      for %{kind: "input", payload: payload} = row <- rows(c),
          {1, {id, record}} <- [:erlang.binary_to_term(payload, [:safe])],
          fun.(record),
          do: {row, id, record}

    found
  end

  # A Unit row of the in-memory Store with `term` as its payload, its digest made valid.
  defp corrupt_row(c, row, term) do
    changed = %{row | payload: binary(term)}
    changed = %{changed | digest: DurableLog.digest(changed)}
    changes = Map.take(changed, [:payload, :digest])
    assert :ok = DurableLog.Memory.corrupt(c.store, :records, {row.stream, row.sequence}, changes)
  end

  defp memory_unit_store(version) do
    options = [
      operator: {RunEngine, :step, %{version: version, control: nil, slots: %{}, requests: %{}}},
      retention_count: 1_024,
      max_record_bytes: 16_777_216,
      max_checkpoint_bytes: 33_554_432
    ]

    pid =
      start_supervised!(%{
        id: make_ref(),
        start:
          {DurableLog.Memory, :start_link,
           [[fold: DurableUnit.fold(options), limits: DurableUnit.limits(options)]]}
      })

    DurableLog.Memory.store(pid)
  end

  defp slot_of(view, action_id),
    do: Enum.find(view.slots, fn {_, slot} -> slot.action_id == action_id end)

  defp binary(term), do: :erlang.term_to_binary(term, [:deterministic, {:minor_version, 2}])
  defp result(engine), do: RunEngine.result(engine, scope(), limits())
  defp transcript(engine), do: RunEngine.transcript(engine, scope(), limits())
  defp reader(c), do: %{evidence_store: c.evidence_store, retention_count: 1_024}
  defp scope, do: %{tenant: "tenant", principal: "principal", run_id: "run"}
  defp limits, do: %{max_records: 65_536, max_bytes: 536_870_912}
end
