# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)

defmodule Elzoo.RunEngineStopAttemptTest.CompleteForwarder do
  # A seam between the engine and its Run owner: every call goes to the owner, except
  # what `mode` decides. `:kill` kills the engine at its `:complete` command, before the
  # owner sees it (a crash after the pending stop and any evidence row commit).
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
    test "two Attempts: a stop that a Run view kept as the fold before ELZ-430 did (a cancel, a completion, a Budget, Run-deadline, pause-deadline or request-cap stop) is refused with no write and no owner command, in v1 and v2" do
      for {source, version} <- [
            cancelled: 1,
            cancelled: 2,
            completed: 1,
            completed: 2,
            budget: 1,
            run_deadline: 1,
            pause_deadline: 1,
            request_cap: 1
          ] do
        {c, _evidence} = legacy(source, version: version)
        control = last_state(c).control
        assert %{stop_pending: stop, attempt_id: "second"} = control
        assert stop == stop(source)
        refute Map.get(control, :stop_attempt) == "second"

        assert {:ok, %{current_attempt: "second", attempts: ["attempt", "second"]}} =
                 Run.status(c.run, "run")

        assert_refused(c)
      end
    end

    test "two Attempts: after the refusal, the host's end of the Run or its new Attempt on the owner is taken at the next start, with no owner command for the stop" do
      for host <- [:cancel, :begin_attempt] do
        {c, []} = legacy(:cancelled)
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
      {c, []} = legacy(:cancelled)
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

      assert %{stop_pending: :out_of_time, attempt_id: "second", stop_attempt: "second"} =
               unit_state(c).control

      Agent.update(c.clock, fn _ -> 3_000 end)
      engine = start(c)
      assert %{outcome: :out_of_time, attempt_id: "second"} = wait_for(engine, &(&1.outcome != nil))
      assert [{:terminal, "run", :out_of_time, "engine", nil, _}] = terminal_rows(c)
      assert {:ok, %{outcome: :out_of_time, current_attempt: "second"}} = Run.status(c.run, "run")
    end

    test "one Attempt: a stop that the fold before ELZ-430 set, also one it set in place of another stop of that Attempt, is delivered as committed" do
      c = fixture_for(:cancelled, 1)
      engine = start(c)
      assert {:ok, :applied} = start_run(c, engine)
      assert_receive {:local_started, _}, 5_000
      GenServer.stop(engine)
      cancel = record(c, "cancel", input(c, "cancel", %{"attempt_id" => "attempt"}))
      append_earlier(c, "cancel", cancel)
      Agent.update(c.clock, fn _ -> 61_000 end)
      wake = record(c, "late-wake", input(c, "wake", %{"at_ms" => 61_000}))
      step = append_earlier(c, "late-wake", wake)
      assert %{stop_pending: :out_of_time, cancelled_attempt: "attempt"} = step.legacy.control
      refute Map.has_key?(step.legacy.control, :stop_attempt)

      engine = start(c)
      assert %{outcome: :out_of_time} = wait_for(engine, &(&1.outcome != nil))
      assert [{:terminal, "run", :out_of_time, "engine", nil, _}] = terminal_rows(c)
      assert evidence_rows(c) == []
      assert {:ok, %{entries: [_ | _]}} = transcript(engine)
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
      {c, []} = legacy(:cancelled)
      wake = record(c, "late-input", input(c, "wake"), attempt_id: "second")
      append_input(c, "late-input", wake)
      before = rows(c)
      {:ok, owner} = Run.status(c.run, "run")
      assert {:error, :stop_origin_unknown} = RunEngine.start_link(c.opts)
      assert Enum.take(rows(c), length(before)) == before
      assert [%{kind: "result"} = paired] = Enum.drop(rows(c), length(before))
      assert {1, {"late-input", state}} = decode(paired)

      assert %{stop_pending: :cancelled, attempt_id: "second", stop_attempt: "attempt"} =
               state.control

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

    test "a cancellation's terminal view recorded before ELZ-215, which left a waiting ask open, still reads in v1" do
      {_c, engine} = pre_215_cancellation(1)
      assert {:ok, %{entries: entries}} = transcript(engine)
      assert [%{outcome: :cancelled}] = Enum.filter(entries, &(&1.type == :terminal))
      refute Enum.any?(entries, &(&1.type == :settlement and &1.action_id == "ask"))
      assert {:ok, %{waits: []}} = RunEngine.event_waits(engine, scope(), limits())
      assert {:terminal, :cancelled} = result(engine)
    end

    test "the same terminal view in v2, which came after ELZ-215, is damaged history" do
      {_c, engine} = pre_215_cancellation(2)
      assert_history(transcript(engine), "v2 transcript")
      assert_history(RunEngine.event_waits(engine, scope(), limits()), "v2 event_waits")
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

  defp start_run(c, engine),
    do: RunEngine.input(engine, "start", %{start_input() | "version" => version(c)}, verified())

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

  # The cut that the fold before ELZ-430 left: the engine died at its owner command with
  # the stop pending in Attempt "attempt", the host began "second", and the next start
  # journaled the Run view of "second" with that fold, which kept the stop (with the mark
  # of "attempt" that this fold recorded, as that fold keeps every control fact it does not
  # know), and died before its owner command. The owner revision matches the recorded one.
  # `opts` go to crashed/2. Returns the fixture and the evidence rows.
  defp legacy(source, opts \\ []) do
    c = crashed(source, opts)
    evidence = evidence_rows(c)
    begin_attempt(c, "second")
    {:ok, owner} = Run.status(c.run, "run")

    kept = fn before, next ->
      put_in(next.control, Map.merge(next.control, Map.take(before.control, @stop_facts)))
    end

    view = second_view(c, owner.revision)
    append_legacy(c, "run:#{owner.revision}", view, kept)
    {c, evidence}
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

  # A cancellation in protocol `version` whose cancel and terminal Run view are as the fold
  # before ELZ-215 recorded them, row digests made valid: the cancel's state carries no stop
  # mark, and the terminal view closed the local work only, so the waiting ask stays open.
  defp pre_215_cancellation(version) do
    c =
      run_fixture(fn frame -> [frame.([action("ask", "ask_person")])] end, version,
        unit_store: memory_unit_store(version)
      )

    engine = start(c)
    assert {:ok, :applied} = start_run(c, engine)
    wait_for(engine, &match?({_, %{phase: :waiting}}, slot_of(&1, "ask")))
    cancel = input(c, "cancel", %{"attempt_id" => "attempt"})
    assert {:ok, :applied} = RunEngine.input(engine, "cancel", cancel, verified())
    wait_for(engine, &(&1.outcome == :cancelled))
    assert {:ok, %{entries: [_ | _]}} = transcript(engine)

    {row, _id, _record} =
      input_row(c, &match?(%{kind: :protocol, input: %{"kind" => "cancel"}}, &1))

    {_before, {id, cancelled}, paired} = step_states(c, row)
    assert %{stop_pending: :cancelled, stop_attempt: "attempt"} = cancelled.control
    unmarked = update_in(cancelled.control, &Map.delete(&1, :stop_attempt))
    corrupt_row(c, paired, {1, {id, unmarked}})

    {row, _id, %{view: view} = record} =
      input_row(c, &match?(%{kind: :run_view, view: %{outcome: :cancelled}}, &1))

    {before, {id, _}, paired} = step_states(c, row)
    assert before === unmarked
    assert {_, %{phase: :waiting}} = slot_of(before, "ask")

    legacy =
      before
      |> put_in([:control, :run_revision], view.revision)
      |> put_in([:control, :operation_id], view.operation_id)
      |> put_in([:control, :stop_pending], nil)
      |> put_in([:control, :lifecycle, :phase], :terminal)
      |> put_in([:control, :lifecycle, :outcome], :cancelled)

    assert {:ok, legacy} === RunEngine.project_event_wait_transition(before, record, :pre_215)
    corrupt_row(c, paired, {1, {id, legacy}})
    {c, engine}
  end

  # The start refuses the pending stop: {:error, :stop_origin_unknown}, no new row, no
  # evidence row and no owner command.
  defp assert_refused(c) do
    before = {rows(c), evidence_rows(c), Run.status(c.run, "run")}
    assert {:error, :stop_origin_unknown} = RunEngine.start_link(c.opts)
    assert {rows(c), evidence_rows(c), Run.status(c.run, "run")} == before
    assert terminal_rows(c) == []
  end

  # Another Run's create on the shared owner moves the owner's revision, and not this Run's
  # Attempt or outcome.
  defp create_other(c) do
    {:ok, owner} = Run.status(c.run, "run")

    assert {:ok, _, _} =
             Run.command(c.run, %{
               kind: :create,
               run_id: "other",
               operation_id: "operation-other",
               provider_refs: %{},
               expected_revision: owner.revision
             })
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
