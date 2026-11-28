# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_host_test_helper.exs", __DIR__)

defmodule Elzoo.RunHostTimeTest do
  # Deadline wakes and lease renewal and expiry, on disposable PostgreSQL with the
  # trusted engine clock of the node (Unix milliseconds) and the store clock of the
  # lease, and on Memory with a manual lease clock moved independently.
  use ExUnit.Case, async: false
  import Elzoo.RunHost.TestHelper
  alias Elzoo.{Lease, RunEngine, RunHost}
  alias Elzoo.DurableLog.Memory
  alias Elzoo.RunApprovalRelease, as: Owner
  alias Elzoo.EffectIntent.Model
  alias Elzoo.RunHost.Ai

  # Margins of the timing assertions, in ms, each against a cutoff that the test measures
  # itself: the host's deadline can be earlier than a cutoff by the delay between the node
  # time that the host takes before a reading and the reading's lease clock sample
  # (@sampling); a timer, the host's handling of it and the on_lost task that reports the
  # moment take at most @timer.
  @sampling 250
  @timer 300

  setup_all do
    repo = database()
    on_exit(fn -> if Process.alive?(repo), do: Supervisor.stop(repo) end)
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "deadlines" do
    test "an idle Run past its deadline ends :out_of_time through the host's own wake" do
      env = postgres()
      {host, _} = host(env, notify())
      deadline = clock() + 400
      spec = spec("idle", stub([]), run_deadline: deadline)

      assert :ok = RunHost.start_run(host, :idle, spec)
      assert_receive {:terminal, :idle, :out_of_time}, 5_000
      assert [wake] = wakes(transcript(host, :idle, spec))
      assert wake.input_id == wake_id(spec, deadline)
      assert wake.at_ms >= deadline
    end

    test "paused with the Run deadline first: the Run ends at the Run deadline" do
      env = postgres()
      {host, _} = host(env, notify())
      run_deadline = clock() + 600
      spec = spec("run-first", stub([]), run_deadline: run_deadline)
      pause_deadline = clock() + 10_000

      assert :ok = RunHost.start_run(host, :run_first, spec)

      assert {:ok, :applied} =
               RunHost.control(
                 host,
                 :run_first,
                 "pause",
                 %{kind: :pause, pause_deadline: pause_deadline},
                 verified(spec)
               )

      assert {:ok, %{phase: :paused, run_deadline: ^run_deadline, pause_deadline: ^pause_deadline}} =
               RunHost.deadlines(host, :run_first)

      assert_receive {:terminal, :run_first, :out_of_time}, 5_000
      assert [wake] = wakes(transcript(host, :run_first, spec))
      assert wake.input_id == wake_id(spec, run_deadline)
      assert wake.at_ms >= run_deadline and wake.at_ms < pause_deadline
    end

    test "paused with the pause deadline first (a Budget exhaustion under :pause): the Run ends at the pause deadline" do
      env = postgres()
      {host, _} = host(env, notify())

      context = fn ->
        %{
          policy: policy(),
          authority: [%{target: "document", field: "published", value: true}],
          resource_names: ["document"],
          pause_deadline: clock() + 700
        }
      end

      run_deadline = clock() + 60_000

      spec =
        spec("pause-first", stub([answer("too dear")]),
          budget_rule: :pause,
          budget: %{cap: 100, unit: "tokens", id: "budget", incarnation: "sealed"},
          descriptor: [estimate: 10],
          context: context,
          run_deadline: run_deadline
        )

      assert :ok = RunHost.start_run(host, :pause_first, spec)

      assert {:ok, :applied} =
               RunHost.input(
                 host,
                 :pause_first,
                 "start",
                 start_input(),
                 verified(spec, %{pause_deadline: clock() + 700})
               )

      assert_receive {:terminal, :pause_first, :out_of_time}, 5_000
      assert [{_, outcome}] = ai_inputs(env, spec)
      assert outcome.correlation.actual == 2_598
      pause_deadline = outcome.context.pause_deadline
      assert [wake] = wakes(transcript(host, :pause_first, spec))
      assert wake.input_id == wake_id(spec, pause_deadline)
      assert wake.at_ms >= pause_deadline and wake.at_ms < run_deadline
    end

    test "a continue that replaces the Run deadline moves the timer; the replaced timer gives no input" do
      env = postgres()
      {host, _} = host(env, notify())
      first = clock() + 1_000
      spec = spec("moved", stub([]), run_deadline: first)

      assert :ok = RunHost.start_run(host, :moved, spec)

      assert {:ok, :applied} =
               RunHost.control(
                 host,
                 :moved,
                 "pause",
                 %{kind: :pause, pause_deadline: clock() + 20_000},
                 verified(spec)
               )

      second = clock() + 2_000

      assert {:ok, :applied} =
               RunHost.control(
                 host,
                 :moved,
                 "continue",
                 %{kind: :continue, person_id: "person", run_deadline: second},
                 verified(spec, %{verified_person: "person"})
               )

      assert {:ok, %{run_deadline: ^second, pause_deadline: nil}} = RunHost.deadlines(host, :moved)
      assert_receive {:terminal, :moved, :out_of_time}, 6_000
      assert [wake] = wakes(transcript(host, :moved, spec))
      assert wake.input_id == wake_id(spec, second)
      assert wake.at_ms >= second
    end

    test "a wake that the engine refuses for its passed pause operand is sent again with a fresh one" do
      env = postgres()
      {host, _} = host(env, notify())
      {:ok, mode} = Agent.start_link(fn -> :short end)
      deadline = clock() + 600

      spec =
        spec("refused", stub([]),
          budget_rule: :pause,
          context: pause_context(mode),
          run_deadline: deadline
        )

      assert :ok = RunHost.start_run(host, :refused, spec)

      # The wake waits in the engine for the Run owner, past its pause operand.
      owner = run(host, :refused).pids.owner
      :sys.suspend(owner)
      Process.sleep(1_000)
      Agent.update(mode, fn _ -> :long end)
      :sys.resume(owner)
      assert_receive {:terminal, :refused, :out_of_time}, 5_000
      assert [wake] = wakes(transcript(host, :refused, spec))
      assert wake.input_id == wake_id(spec, deadline)
    end

    test "a wake refused before it was taken is sent again only by its timer, a second later, for the current Attempt" do
      env = postgres()
      {host, _} = host(env, notify())
      {:ok, mode} = Agent.start_link(fn -> :short end)
      deadline = clock() + 600

      spec =
        spec("rewoken", stub([]),
          budget_rule: :pause,
          context: pause_context(mode),
          run_deadline: deadline
        )

      trace([{RunEngine, :input, 4}])
      assert :ok = RunHost.start_run(host, :rewoken, spec)
      %{worker: worker, pids: %{owner: owner}} = run(host, :rewoken)

      # The wake waits in the engine for the Run owner, past its pause operand, while a
      # begin_attempt waits behind it in the worker.
      :sys.suspend(owner)

      assert_receive {:trace, ^worker, :call, {RunEngine, :input, [_, "wake:" <> _ = old, _, _]}},
                     5_000

      control =
        Task.async(fn ->
          RunHost.control(
            host,
            :rewoken,
            "second",
            %{kind: :begin_attempt, attempt_id: "second"},
            verified(spec, %{pause_deadline: clock() + 600_000})
          )
        end)

      eventually(fn ->
        {:messages, messages} = Process.info(worker, :messages)
        Enum.any?(messages, &match?({:"$gen_call", _, {:control, "second", _, _}}, &1))
      end)

      Process.sleep(200)
      Agent.update(mode, fn _ -> :long end)
      :sys.resume(owner)

      assert_receive {:trace, ^worker, :return_from, {RunEngine, :input, 4},
                      {:error, :pause_deadline_required}},
                     5_000

      refused = System.monotonic_time(:millisecond)
      assert {:ok, :applied} = Task.await(control)

      # The next wake input reads the committed deadline and the new Attempt again.
      assert_receive {:trace, ^worker, :call,
                      {RunEngine, :input, [_, "wake:" <> _ = id, _, context]}},
                     5_000

      assert System.monotonic_time(:millisecond) - refused >= 950
      assert id != old
      assert context.attempt_id == "second"
      assert id == wake_id(%{spec | attempt_id: "second"}, deadline)
      assert_receive {:terminal, :rewoken, :out_of_time}, 5_000
      assert [wake] = wakes(transcript(host, :rewoken, spec))
      assert wake.input_id == id
    end
  end

  describe "call_limit" do
    @tag timeout: 180_000
    test "an engine read that ends by the call limit decides nothing: a due wake waits for a readable deadline, an input for a confirmed Attempt, and a call queued behind a cancel or an ending outcome finds the Run terminal" do
      env = postgres()

      stub =
        stub(fn
          "call m1" -> answer("old Attempt")
          "call m2" -> answer("new Attempt")
        end)

      {host, _} = host(env, notify() ++ [max_runs: 5])
      trace([{RunEngine, :deadlines, 1}, {RunEngine, :input, 4}, {RunEngine, :control, 4}])

      # A: an idle Run whose engine is held across its deadline, once its timer is set.
      deadline = clock() + 3_000
      unread = spec("unread", stub([]), run_deadline: deadline)
      assert :ok = RunHost.start_run(host, :unread, unread)
      %{worker: worker_a, pids: %{engine: engine_a}} = run(host, :unread)
      eventually(fn -> :sys.get_state(worker_a).timer != nil end)
      :sys.suspend(engine_a)

      # C: an idle Run, cancelled below; started before the Run owner's status is traced.
      cancelled = spec("cancelled", stub([]))
      assert :ok = RunHost.start_run(host, :cancelled, cancelled)
      %{worker: worker_c, pids: %{engine: engine_c, owner: owner_c}} = run(host, :cancelled)

      # B: a begin_attempt whose reply comes, and whose read after it waits in the held engine.
      confirm = spec("confirm", stub, pattern: starts())
      assert :ok = RunHost.start_run(host, :confirm, confirm)

      assert {:ok, :applied} =
               RunHost.input(host, :confirm, "start", start_input(), verified(confirm))

      eventually(fn -> length(settlements(transcript(host, :confirm, confirm), "m1")) == 1 end)
      %{worker: worker_b, pids: %{engine: engine_b, owner: owner_b}} = run(host, :confirm)
      _ = :sys.get_state(worker_b)
      trace([{Owner, :status, 2}])
      :sys.suspend(owner_b)

      control =
        Task.async(fn ->
          RunHost.control(
            host,
            :confirm,
            "second",
            %{kind: :begin_attempt, attempt_id: "second"},
            verified(confirm)
          )
        end)

      # The engine applies the control while its owner is held; a suspension queued
      # meanwhile takes effect right after the engine replies.
      assert_receive {:trace, ^engine_b, :call, {Owner, :status, _}}, 5_000
      spawn(fn -> :sys.suspend(engine_b, :infinity) end)

      eventually(fn ->
        {:messages, messages} = Process.info(engine_b, :messages)
        Enum.any?(messages, &match?({:system, _, :suspend}, &1))
      end)

      :sys.resume(owner_b)

      # The next input already waits behind the control when the worker's read after
      # the control fails, so it is the first thing that the worker takes next.
      second = %{confirm | attempt_id: "second"}

      input =
        Task.async(fn ->
          RunHost.input(host, :confirm, "start-2", start_input(), verified(second))
        end)

      eventually(fn ->
        {:messages, messages} = Process.info(worker_b, :messages)
        Enum.any?(messages, &match?({:"$gen_call", _, {:input, "start-2", _, _}}, &1))
      end)

      # C: the engine applies a cancel while its owner is held and is held right after its
      # reply, so the worker's read after the cancel ends by the call limit too. A control
      # and then an input wait behind the cancel: each passed the worker's terminal check
      # before the cancel was observed.
      :sys.suspend(owner_c)

      cancel =
        Task.async(fn ->
          RunHost.control(
            host,
            :cancelled,
            "cancel",
            %{kind: :cancel, attempt_id: cancelled.attempt_id},
            verified(cancelled)
          )
        end)

      assert_receive {:trace, ^engine_c, :call, {Owner, :status, _}}, 5_000
      spawn(fn -> :sys.suspend(engine_c, :infinity) end)

      eventually(fn ->
        {:messages, messages} = Process.info(engine_c, :messages)
        Enum.any?(messages, &match?({:system, _, :suspend}, &1))
      end)

      pause =
        Task.async(fn ->
          RunHost.control(
            host,
            :cancelled,
            "pause",
            %{kind: :pause, pause_deadline: clock() + 600_000},
            verified(cancelled)
          )
        end)

      eventually(fn ->
        {:messages, messages} = Process.info(worker_c, :messages)
        Enum.any?(messages, &match?({:"$gen_call", _, {:control, "pause", _, _}}, &1))
      end)

      late =
        Task.async(fn ->
          RunHost.input(host, :cancelled, "late", message("late"), verified(cancelled))
        end)

      eventually(fn ->
        {:messages, messages} = Process.info(worker_c, :messages)
        Enum.any?(messages, &match?({:"$gen_call", _, {:input, "late", _, _}}, &1))
      end)

      :sys.resume(owner_c)

      # D and E: a model call's completion ends the Run, and the engine is held right after
      # it answers that input, so the worker's read after it ends by the call limit too. A
      # caller's input (D), and separately a caller's control (E), waits behind it: each
      # passed the worker's terminal check before the end was read.
      {worker_d, engine_d, late_d} =
        ended!(host, :ended_input, "ended-input", fn spec ->
          RunHost.input(host, :ended_input, "late", message("late"), verified(spec))
        end)

      {worker_e, engine_e, late_e} =
        ended!(host, :ended_control, "ended-control", fn spec ->
          RunHost.control(
            host,
            :ended_control,
            "late",
            %{kind: :pause, pause_deadline: clock() + 600_000},
            verified(spec)
          )
        end)

      # Both reads end by the engine's 60 s call limit.
      assert_receive {:trace, ^worker_b, :exception_from, {RunEngine, :deadlines, 1}, _}, 75_000
      assert_receive {:trace, ^worker_a, :exception_from, {RunEngine, :deadlines, 1}, _}, 10_000

      # B: the input is forwarded only after a read confirms the new Attempt, so its model
      # call's key is the new Attempt's and its outcome routes.
      :sys.resume(engine_b)
      assert {:ok, :applied} = Task.await(control)
      assert {:ok, :applied} = Task.await(input)
      eventually(fn -> length(settlements(transcript(host, :confirm, confirm), "m2")) == 1 end)
      assert [%{outcome: "completed"}] = settlements(transcript(host, :confirm, confirm), "m2")
      {:ok, binding} = Elzoo.AiText.Binding.load(Elzoo.RunHost.TestBinding)

      key =
        Model.key([
          "tenant",
          binding.provider_account,
          binding.id,
          "generate",
          Ai.ref(confirm.run_id, "second", "m2")
        ])

      assert Model.stream(key) in streams(env, "intent/%")

      # A: no wake while its deadline could not be read; once it can, one wake.
      refute_receive {:trace, ^worker_a, :call, {RunEngine, :input, [_, "wake:" <> _ | _]}}, 300
      :sys.resume(engine_a)
      assert_receive {:terminal, :unread, :out_of_time}, 5_000
      assert [wake] = wakes(transcript(host, :unread, unread))
      assert wake.input_id == wake_id(unread, deadline)

      # C: the queued control reads the Run again, finds it terminal and gets
      # {:error, :terminal} with no engine call, and so does the input behind it. The
      # terminal observation stays confirmed (a late sink outcome is still forwarded), and
      # on_terminal is called once.
      assert_receive {:trace, ^worker_c, :exception_from, {RunEngine, :deadlines, 1}, _}, 10_000
      :sys.resume(engine_c)
      assert {:ok, :applied} = Task.await(cancel)
      assert {:error, :terminal} = Task.await(pause)
      assert {:error, :terminal} = Task.await(late)
      assert_receive {:terminal, :cancelled, :cancelled}, 5_000
      delivered = :erlang.trace_delivered(worker_c)
      assert_receive {:trace_delivered, ^worker_c, ^delivered}, 5_000
      refute_received {:trace, ^worker_c, :call, {RunEngine, :control, [_, "pause", _, _]}}
      refute_received {:trace, ^worker_c, :call, {RunEngine, :input, [_, "late", _, _]}}
      assert :sys.get_state(worker_c).confirmed
      refute_receive {:terminal, :cancelled, _}, 300

      # D and E: after the completion's input nothing read the Run, so the queued call
      # reads it first, finds it terminal and gets {:error, :terminal} with no engine call;
      # on_terminal is called once.
      for {ref, worker, engine, late, call} <- [
            {:ended_input, worker_d, engine_d, late_d, :input},
            {:ended_control, worker_e, engine_e, late_e, :control}
          ] do
        assert_receive {:trace, ^worker, :exception_from, {RunEngine, :deadlines, 1}, _}, 10_000
        :sys.resume(engine)
        assert {:error, :terminal} = Task.await(late)
        assert_receive {:terminal, ^ref, :completed}, 5_000
        delivered = :erlang.trace_delivered(worker)
        assert_receive {:trace_delivered, ^worker, ^delivered}, 5_000
        refute_received {:trace, ^worker, :call, {RunEngine, ^call, [_, "late", _, _]}}
        refute_receive {:terminal, ^ref, _}, 300
      end
    end
  end

  describe "lease_clock" do
    test "a lease clock moved past the confirmed until stops admission before any node timer" do
      env = memory()
      {host, _} = host(env, notify())
      spec = spec("moved-clock", stub([]))
      assert :ok = RunHost.start_run(host, :moved_clock, spec)
      Lease.Clock.advance(env.clock, 61_000_000)

      assert {:error, :lease_lost} =
               RunHost.input(host, :moved_clock, "start", start_input(), verified(spec))

      assert_receive {:lost, :moved_clock, :expired}, 3_000
      eventually(fn -> run(host, :moved_clock) == nil end)
    end

    test "a claim that waits a whole TTL before the lease samples its clock keeps its lease" do
      {:ok, slow} = Agent.start_link(fn -> true end)

      hook = fn
        :before_lock, _ -> if Agent.get_and_update(slow, &{&1, false}), do: Process.sleep(2_500)
        _, _ -> :ok
      end

      env = postgres(lease: [test_hook: hook])
      stub = stub([answer("still held")])
      {host, _} = host(env, notify() ++ [lease_ttl_ms: 2_000])
      spec = spec("slow-claim", stub)

      assert :ok = RunHost.start_run(host, :slow_claim, spec)

      assert {:ok, :applied} =
               RunHost.input(host, :slow_claim, "start", start_input(), verified(spec))

      assert_receive {:terminal, :slow_claim, :completed}, 5_000
      refute_received {:lost, :slow_claim, _}
    end

    test "a caller held after its admission while a renewal moves until: its reading against the old until is stale, and it is admitted again" do
      env = memory()
      {host, _} = host(env, notify() ++ [lease_ttl_ms: 4_000])
      spec = spec("snapshot", stub([answer("admitted")]))
      assert :ok = RunHost.start_run(host, :snapshot, spec)
      %{lease: %{generation: first, until: until}} = run(host, :snapshot)

      # The caller gets its admission (with the first until) and is held before it
      # reads the lease clock.
      :sys.suspend(host)

      caller =
        Task.async(fn ->
          RunHost.input(host, :snapshot, "start", start_input(), verified(spec))
        end)

      caller_pid = caller.pid

      eventually(fn ->
        {:messages, messages} = Process.info(host, :messages)
        Enum.any?(messages, &match?({:"$gen_call", {^caller_pid, _}, {:admission, :snapshot}}, &1))
      end)

      :erlang.suspend_process(caller.pid)
      :sys.resume(host)

      # The lease clock moves 1.5 s before the renewal (half the TTL after the claim on
      # the node's clock), so the renewal is confirmed with a later until; the lease
      # clock then passes the first until, not the new one.
      Lease.Clock.advance(env.clock, 1_500_000)
      eventually(fn -> run(host, :snapshot).lease.generation != first end)
      assert run(host, :snapshot).lease.until > until
      Lease.Clock.advance(env.clock, 3_000_000)
      :erlang.resume_process(caller.pid)

      assert {:ok, :applied} = Task.await(caller)
      refute_received {:lost, :snapshot, _}
      assert %{phase: :live} = run(host, :snapshot)
    end
  end

  describe "renewal" do
    test "a Run that lives through several TTLs keeps writing, renewed on the lease clock" do
      env = postgres()
      stub = stub([{:block, answer("after the renewals")}])
      {host, _} = host(env, notify() ++ [lease_ttl_ms: 1_000])
      spec = spec("renewed", stub)

      assert :ok = RunHost.start_run(host, :renewed, spec)
      assert {:ok, :applied} = RunHost.input(host, :renewed, "start", start_input(), verified(spec))
      assert_receive {:stub_entered, stub_task}, 10_000

      for n <- 1..6 do
        Process.sleep(500)

        assert {:ok, :applied} =
                 RunHost.input(host, :renewed, "message-#{n}", message("more #{n}"), verified(spec))
      end

      assert renewals(env, spec) >= 4
      send(stub_task, :release)
      assert_receive {:terminal, :renewed, :completed}, 5_000
      refute_received {:lost, :renewed, _}
    end

    test "a lost renewal stops admission for the Run and fences its processes" do
      env = postgres()
      {host, _} = host(env, notify() ++ [lease_ttl_ms: 1_000])
      spec = spec("seized", stub([]))

      assert :ok = attribute(host, fn -> RunHost.start_run(host, :seized, spec) end)
      unit = unit_pids(state(host).units, "unit/" <> spec.unit)

      {:held, _} =
        Lease.seize(env.lease, "run/" <> spec.unit, "operator", 60_000, :operator_takeover)

      assert_receive {:lost, :seized, reason}, 3_000
      assert elem(reason, 0) == :lease_lost

      assert {:error, :lease_lost} =
               RunHost.input(host, :seized, "late", start_input(), verified(spec))

      eventually(fn -> run(host, :seized) == nil end)
      pids = spawned() ++ unit
      assert length(pids) >= 9
      assert alive_pids(pids) == []

      assert {:error, :lease_lost} =
               RunHost.input(host, :seized, "late", start_input(), verified(spec))

      assert {:error, :not_running} = RunHost.status(host, :seized)
    end

    test "a renewal that commits but would reply only after the last confirmed until: the Run is lost (:expired) at the claim's until, before that reply" do
      test = self()
      {:ok, delay} = Agent.start_link(fn -> false end)

      # The renewal commits; its reply would come 1.5 s later, past the last confirmed
      # until (a TTL of 2 s, renewed at half of it) but well within the 5 s caller limit.
      hook = fn
        :after_commit, %{key: "run/late"} ->
          if Agent.get_and_update(delay, &{&1, false}) do
            send(test, {:renewal_committed, System.monotonic_time(:millisecond)})
            Process.sleep(1_500)
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 2_000])
      spec = spec("late", stub([]))
      assert :ok = RunHost.start_run(host, :late, spec)
      # When the claim's until passes on the store clock, by a reading of the test's own.
      cutoff = passes(env.lease, "run/late")
      Agent.update(delay, fn _ -> true end)
      assert_receive {:renewal_committed, committed_at}, 5_000

      # No renewal is confirmed by the last confirmed until: the fence at the deadline loses
      # the Run at that cutoff, no earlier than the host's own sampling margin allows and no
      # later than a timer's, and before the renewal's reply could come; the teardown then
      # stops the owner.
      assert_receive {:lost, :late, :expired, lost_at}, 5_000
      assert lost_at >= cutoff.from - @sampling
      assert lost_at <= cutoff.by + @timer
      assert lost_at < committed_at + 1_500

      assert {:error, :lease_lost} =
               RunHost.input(host, :late, "late", start_input(), verified(spec))

      eventually(fn -> run(host, :late) == nil end)
      refute_receive {:lost, :late, _, _}, 300
      assert renewals(env, spec) == 1
    end

    test "a renewal whose reply comes after the lease clock passed the last confirmed until and whose first reading fails: read again, the Run is lost (:expired) before this node's deadline" do
      test = self()
      {:ok, armed} = Agent.start_link(fn -> false end)

      # The renewal is held in the Lease backend right after it sampled the lease clock.
      hook = fn
        :after_clock, %{key: "run/reread", owner: backend} ->
          if Agent.get_and_update(armed, &{&1, false}) do
            send(test, {:sampled, backend})
            receive do: (:go -> :ok)
          end

        _, _ ->
          :ok
      end

      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
      spec = spec("reread", stub([]))
      started = now_ms()
      assert :ok = RunHost.start_run(host, :reread, spec)

      # The renewal (half the TTL in, on this node's clock) samples the lease clock 2 s
      # after the claim: its until is 6 s after the claim, the last confirmed one 4 s.
      Lease.Clock.advance(env.clock, 2_000_000)
      Agent.update(armed, fn _ -> true end)
      assert_receive {:sampled, backend}, 5_000
      [task] = Task.Supervisor.children(state(host).tasks)
      :erlang.suspend_process(task)

      # Before the reply the lease clock passes the last confirmed until (5 s after the
      # claim) while this node's clock is still before its deadline. Once the reply is in
      # the renewal task, the task's first reading of the lease fails.
      Lease.Clock.advance(env.clock, 3_000_000)
      send(backend, :go)

      eventually(fn ->
        match?({:message_queue_len, n} when n > 0, Process.info(task, :message_queue_len))
      end)

      :ok = Memory.fault(env.store, :head, :unavailable)
      trace([{Lease, :status, 2}])
      trace_spawns(task)
      resumed = now_ms()
      :erlang.resume_process(task)

      # No reading is replaced by this node's clock: the task reads again, and that
      # reading shows the lease clock past the last confirmed until. The loss follows the
      # test's letting the task go on, and comes before the earliest moment that the host's
      # deadline can be: 4 s after its reading in start_run, on a lease clock that stood
      # still until the test moved it.
      assert_receive {:lost, :reread, :expired, lost_at}, 1_500
      assert lost_at >= resumed
      assert lost_at < started + 4_000

      assert_receive {:trace, first, :return_from, {Lease, :status, 2}, {:error, :unavailable}},
                     1_000

      assert_receive {:trace, second, :return_from, {Lease, :status, 2},
                      {:ok, %{status: :active, holder: %{owner: "node-a"}}}},
                     1_000

      # Both readings are the renewal task's own, each in a reader task that it started.
      readers = spawned()
      assert first in readers and second in readers and first != second

      assert {:error, :lease_lost} =
               RunHost.input(host, :reread, "late", start_input(), verified(spec))

      eventually(fn -> run(host, :reread) == nil end)
      refute_receive {:lost, :reread, _, _}, 300
    end

    test "a renewal that commits and whose lease is then seized before its reading: that reading shows the other holder, so the Run is lost at once, with no input" do
      test = self()
      {:ok, armed} = Agent.start_link(fn -> false end)

      # The renewal is held in the Run owner right after its transaction committed.
      hook = fn
        :after_commit, %{key: "run/overtaken"} ->
          if Agent.get_and_update(armed, &{&1, false}) do
            send(test, {:committed, self()})
            receive do: (:go -> :ok)
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
      spec = spec("overtaken", stub([]))
      assert :ok = RunHost.start_run(host, :overtaken, spec)
      cutoff = passes(env.lease, "run/overtaken")
      Agent.update(armed, fn _ -> true end)
      assert_receive {:committed, owner}, 5_000

      seized = now_ms()

      {:held, _} =
        Lease.seize(env.lease, "run/overtaken", "operator", 60_000, :operator_takeover)

      send(owner, :go)

      # The reading after the seizure is the loss: after the seizure, and before the fence
      # of the claim's until could come (the cutoff measured by the test, less the host's
      # sampling margin).
      assert_receive {:lost, :overtaken, {:lease_lost, %{holder: "operator"}}, lost_at}, 1_500
      assert lost_at >= seized
      assert lost_at < cutoff.from - @sampling

      assert {:error, :lease_lost} =
               RunHost.input(host, :overtaken, "late", start_input(), verified(spec))

      eventually(fn -> run(host, :overtaken) == nil end)
      refute_receive {:lost, :overtaken, _, _}, 300
      assert renewals(env, spec) == 1
    end

    @tag timeout: 60_000
    test "a renewal reply delayed past the caller timeout: admission stops, the owner is fenced before any replacement" do
      {:ok, delay} = Agent.start_link(fn -> false end)

      hook = fn
        :after_commit, %{key: "run/slow"} ->
          if Agent.get_and_update(delay, &{&1, false}), do: Process.sleep(6_000)

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {cell, proof} = proof_cell()
      {host, specs} = host(env, notify() ++ [lease_ttl_ms: 12_000, fencing_proof: proof])
      spec = spec("slow", stub([]))
      remember(specs, :slow, spec)

      assert :ok = attribute(host, fn -> RunHost.start_run(host, :slow, spec) end)
      assert [_unit, _writer | _] = unit = unit_pids(state(host).units, "unit/" <> spec.unit)
      owner = run(host, :slow).pids.owner
      Agent.update(delay, fn _ -> true end)

      # The renewal starts at half the TTL and its caller gives up after 5,000 ms,
      # before the expiry deadline: an unconfirmed renewal.
      assert_receive {:lost, :slow, {:unknown, :no_receipt}}, 12_000
      assert Process.alive?(host)

      assert {:error, :lease_lost} =
               RunHost.input(host, :slow, "late", start_input(), verified(spec))

      eventually(fn -> not Process.alive?(owner) end)
      eventually(fn -> run(host, :slow) == nil end)
      prove(cell, spawned() ++ unit, owner)
      assert [slow: :woken] = RunHost.wake(host, [:slow])
      assert run(host, :slow).pids.owner != owner

      # The renewal itself committed: a late success that reopened nothing and gave no
      # receipt for reconcile:.
      assert renewals(env, spec) >= 1
      assert state(host).receipts == %{}
      refute Agent.get(delay, & &1)
    end

    test "an indeterminate renewal result that comes before the owner's exit: on_lost once with that receipt, reconciled at the next start" do
      test = self()
      {:ok, hold} = Agent.start_link(fn -> false end)

      # The renewal is held inside the owner, before it writes anything.
      hook = fn
        :before_lock, %{key: "run/first"} ->
          if Agent.get_and_update(hold, &{&1, false}) do
            send(test, {:renewing, self()})
            receive do: (:never -> :ok)
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {cell, proof} = proof_cell()
      {host, specs} = host(env, notify() ++ [lease_ttl_ms: 2_000, fencing_proof: proof])
      spec = spec("first", stub([answer("after the reconcile")]))
      remember(specs, :first, spec)
      assert :ok = attribute(host, fn -> RunHost.start_run(host, :first, spec) end)
      assert [_unit, _writer | _] = unit = unit_pids(state(host).units, "unit/" <> spec.unit)
      Agent.update(hold, fn _ -> true end)
      assert_receive {:renewing, owner}, 5_000

      # The owner answers an indeterminate renewal as it stops, so its own exit reaches
      # the host before the renewal task's result. The test delivers that result first,
      # under the renewal job's reference, as the task delivers it, while the owner still
      # runs: an indeterminate receipt (for a write that a later record superseded), which
      # the host acts on at once. The teardown then stops the owner, and the task's own
      # result after that adds nothing.
      [job] = for {ref, {:renew, :first, _, _}} <- state(host).jobs, do: ref

      # A renewal record at sequence 2, a revision that the Run's create already holds
      # under another nonce: the next owner's reconcile: finds it superseded.
      nonce = :crypto.strong_rand_bytes(16)

      renewal = %Elzoo.DurableLog.Record{
        stream: "run/first",
        sequence: 2,
        kind: "lease_renewed",
        schema_version: 1,
        payload: "{}",
        nonce: nonce
      }

      receipt = %{stream: "run/first", expected: 1, nonce: nonce, records: [renewal]}

      send(host, {job, {:indeterminate, receipt}})
      assert_receive {:lost, :first, {:indeterminate, ^receipt}}, 5_000
      eventually(fn -> run(host, :first) == nil end)
      refute Process.alive?(owner)
      refute_receive {:lost, :first, _}, 300
      assert state(host).receipts == %{first: receipt}

      trace([{Owner, :start_link, 1}])
      prove(cell, spawned() ++ unit, owner)
      assert [first: :woken] = RunHost.wake(host, [:first])
      assert_receive {:trace, _, :call, {Owner, :start_link, [opts]}}, 1_000
      assert opts[:reconcile] == receipt
      assert state(host).receipts == %{}

      assert {:ok, :applied} =
               RunHost.input(host, :first, "start", start_input(), verified(spec))

      assert_receive {:terminal, :first, :completed}, 10_000
    end

    test "an indeterminate renewal whose result comes last: the reservation is kept until that job ends, its receipt kept" do
      test = self()
      {:ok, armed} = Agent.start_link(fn -> false end)

      # The renewal's transaction fails after its write: an unknown outcome.
      hook = fn
        :after_write, %{key: "run/indeterminate"} ->
          if Agent.get_and_update(armed, &{&1, false}) do
            send(test, {:renewal_written, self()})
            receive do: (:go -> raise "the connection ends after the write")
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {cell, proof} = proof_cell()
      {host, specs} = host(env, notify() ++ [lease_ttl_ms: 4_000, fencing_proof: proof])
      spec = spec("indeterminate", stub([answer("after the reconcile")]))
      remember(specs, :indeterminate, spec)
      assert :ok = attribute(host, fn -> RunHost.start_run(host, :indeterminate, spec) end)
      assert [_unit, _writer | _] = unit = unit_pids(state(host).units, "unit/" <> spec.unit)
      Agent.update(armed, fn _ -> true end)

      # The renewal's task is held, so that its result comes after the owner's exit, the
      # worker's exit and the teardown of every process of the Run.
      assert_receive {:renewal_written, owner}, 5_000
      [task] = Task.Supervisor.children(state(host).tasks)
      :erlang.suspend_process(task)
      send(owner, :go)

      assert_receive {:lost, :indeterminate, {:indeterminate, receipt}}, 5_000

      assert {:error, :lease_lost} =
               RunHost.input(host, :indeterminate, "start", start_input(), verified(spec))

      # The teardown is done, but the reservation waits for the renewal job.
      eventually(fn -> match?(%{phase: :awaiting}, run(host, :indeterminate)) end)
      refute Process.alive?(owner)
      Process.sleep(300)
      assert %{phase: :awaiting} = run(host, :indeterminate)
      :erlang.resume_process(task)
      eventually(fn -> run(host, :indeterminate) == nil end)
      refute_receive {:lost, :indeterminate, _}, 300
      assert state(host).receipts == %{indeterminate: receipt}

      # The renewal never committed: the next start gives its receipt to the owner as
      # reconcile:, and the new claim supersedes it.
      trace([{Owner, :start_link, 1}])
      prove(cell, spawned() ++ unit, owner)
      assert [indeterminate: :woken] = RunHost.wake(host, [:indeterminate])
      assert_receive {:trace, _, :call, {Owner, :start_link, [opts]}}, 1_000
      assert opts[:reconcile] == receipt
      assert state(host).receipts == %{}

      assert {:ok, :applied} =
               RunHost.input(host, :indeterminate, "start", start_input(), verified(spec))

      assert_receive {:terminal, :indeterminate, :completed}, 10_000
    end

    test "a worker's report of an indeterminate owner exit that comes first: on_lost once, the receipt kept" do
      env = postgres()
      {host, _} = host(env, notify())
      spec = spec("reported", stub([]))
      assert :ok = RunHost.start_run(host, :reported, spec)
      %{worker: worker, pids: %{owner: owner}} = run(host, :reported)
      receipt = %{stream: "run/reported", nonce: "forged"}

      # An exit of the owner forged to the worker: the worker's report reaches the host
      # first, and the owner then ends with the worker, with no loss of its own.
      send(worker, {:EXIT, owner, {:shutdown, {:indeterminate, receipt}}})
      assert_receive {:lost, :reported, {:indeterminate, ^receipt}}, 5_000

      assert {:error, :lease_lost} =
               RunHost.input(host, :reported, "start", start_input(), verified(spec))

      eventually(fn -> run(host, :reported) == nil end)
      refute Process.alive?(owner)
      refute_receive {:lost, :reported, _}, 300
      assert state(host).receipts == %{reported: receipt}
    end

    test "a reap during a renewal: the cancelled renewal is no loss, so no on_lost, and the Run is not_running" do
      test = self()
      {:ok, hold} = Agent.start_link(fn -> false end)

      # The renewal waits inside the owner until the reap's teardown kills the owner.
      hook = fn
        :before_lock, %{key: "run/cancelled"} ->
          if Agent.get_and_update(hold, &{&1, false}) do
            send(test, {:renewing, self()})
            receive do: (:never -> :ok)
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])

      on_lost = fn ref, reason ->
        send(test, {:lost, ref, reason})
        receive do: (:never -> :ok)
      end

      {host, _} = host(env, on_lost: on_lost, lease_ttl_ms: 2_000)
      spec = spec("cancelled", stub([]))
      assert :ok = RunHost.start_run(host, :cancelled, spec)
      Agent.update(hold, fn _ -> true end)
      assert_receive {:renewing, _owner}, 5_000

      assert :ok = RunHost.reap(host, :cancelled)
      refute_receive {:lost, :cancelled, _}, 300
      assert run(host, :cancelled) == nil
      assert state(host).lost == %{}

      assert {:error, :not_running} =
               RunHost.input(host, :cancelled, "late", start_input(), verified(spec))

      assert {:ok, %{status: :free}} = Lease.status(env.lease, "run/cancelled")
    end

    test "a reap waits for the exit of the Run's renewal job, not for its result, before it frees the reservation" do
      test = self()
      {:ok, hold} = Agent.start_link(fn -> false end)

      hook = fn
        :before_lock, %{key: "run/awaited"} ->
          if Agent.get_and_update(hold, &{&1, false}) do
            send(test, {:renewing, self()})
            receive do: (:never -> :ok)
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {host, _} = host(env, notify() ++ [lease_ttl_ms: 2_000])
      spec = spec("awaited", stub([]))
      assert :ok = RunHost.start_run(host, :awaited, spec)
      Agent.update(hold, fn _ -> true end)
      assert_receive {:renewing, owner}, 5_000

      # The renewal job (the host's only task now) is held.
      [job] = for {ref, {:renew, :awaited, _, _}} <- state(host).jobs, do: ref
      [task] = Task.Supervisor.children(state(host).tasks)
      :erlang.suspend_process(task)
      reap = Task.async(fn -> RunHost.reap(host, :awaited) end)

      # Every process of the Run is gone; the reservation stays while the job runs.
      eventually(fn -> match?(%{phase: :awaiting}, run(host, :awaited)) end)
      refute Process.alive?(owner)
      assert Task.yield(reap, 300) == nil

      # A task sends its result before it exits: a result that reaches the host while
      # the job's process still runs frees nothing.
      send(host, {job, {:unknown, :no_receipt}})
      assert Task.yield(reap, 300) == nil
      assert %{phase: :awaiting} = run(host, :awaited)
      assert Process.alive?(task)

      :erlang.resume_process(task)
      assert :ok = Task.await(reap)
      refute Process.alive?(task)
      assert run(host, :awaited) == nil
      refute_received {:lost, :awaited, _}
    end

    test "a renewal's loss is acted on when its result arrives, before a reap that comes right after it; that reap still waits for the job's exit" do
      test = self()
      {:ok, hold} = Agent.start_link(fn -> false end)

      hook = fn
        :before_lock, %{key: "run/received"} ->
          if Agent.get_and_update(hold, &{&1, false}) do
            send(test, {:renewing, self()})
            receive do: (:never -> :ok)
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {host, _} = host(env, notify() ++ [lease_ttl_ms: 2_000])
      spec = spec("received", stub([]))
      assert :ok = RunHost.start_run(host, :received, spec)
      Agent.update(hold, fn _ -> true end)
      assert_receive {:renewing, owner}, 5_000

      # The renewal job is held between its result and its exit: the test delivers the
      # result that its task gives at the caller timeout of renew/2 (an unconfirmed
      # renewal), under the job's reference, while the task's process still runs. A reap
      # reaches the host right after that result, before the host has taken either.
      [job] = for {ref, {:renew, :received, _, _}} <- state(host).jobs, do: ref
      [task] = Task.Supervisor.children(state(host).tasks)
      :erlang.suspend_process(task)
      :sys.suspend(host)
      send(host, {job, {:unknown, :no_receipt}})
      reap = Task.async(fn -> RunHost.reap(host, :received) end)
      reaper = reap.pid

      eventually(fn ->
        {:messages, messages} = Process.info(host, :messages)
        Enum.any?(messages, &match?({:"$gen_call", {^reaper, _}, {:reap, :received}}, &1))
      end)

      :sys.resume(host)

      # The loss is the host's first: on_lost is called and admission stops, although the
      # reap began the teardown right after it.
      assert_receive {:lost, :received, {:unknown, :no_receipt}}, 1_000

      assert {:error, :lease_lost} =
               RunHost.input(host, :received, "late", start_input(), verified(spec))

      # Every process of the Run is gone; the reservation waits for the job's exit.
      eventually(fn -> match?(%{phase: :awaiting}, run(host, :received)) end)
      refute Process.alive?(owner)
      assert Task.yield(reap, 300) == nil
      assert Process.alive?(task)

      :erlang.resume_process(task)
      assert :ok = Task.await(reap)
      refute Process.alive?(task)
      assert run(host, :received) == nil
      refute_receive {:lost, :received, _}, 300
    end

    test "a lease that cannot be read at the expiry moment: each Run is lost (:expired) at its deadline, and no blocked reading holds its teardown" do
      test = self()
      {:ok, armed} = Agent.start_link(fn -> %{reply: false, renewal: false} end)

      # :read_held: the renewal commits and replies, and its Lease backend is suspended
      # right after that call, so the renewal's reading after its reply and the expiry
      # check's reading both wait in the backend's queue.
      reply_hook = fn
        :before_write, %{key: "run/read-held", owner: backend} ->
          if Agent.get_and_update(armed, &{&1.reply, %{&1 | reply: false}}) do
            spawn(fn -> :sys.suspend(backend, :infinity) end)

            eventually(fn ->
              {:messages, messages} = Process.info(backend, :messages)
              Enum.any?(messages, &match?({:system, _, :suspend}, &1))
            end)
          end

        _, _ ->
          :ok
      end

      # :renewal_held: the renewal itself waits in its Lease backend, and the expiry
      # check's reading behind it, so no renewal result comes before the caller limit.
      renewal_hook = fn
        :before_lock, %{key: "run/renewal-held", owner: backend} ->
          if Agent.get_and_update(armed, &{&1.renewal, %{&1 | renewal: false}}) do
            send(test, {:renewal_held, backend})
            receive do: (:go -> :ok)
          end

        _, _ ->
          :ok
      end

      on_lost = [
        on_lost: fn ref, reason ->
          send(test, {:lost, ref, reason, System.monotonic_time(:millisecond)})
        end
      ]

      read_env = memory(lease: [test_hook: reply_hook])
      renewal_env = memory(lease: [test_hook: renewal_hook])
      {read_host, _} = host(read_env, on_lost ++ [lease_ttl_ms: 2_000])
      {renewal_host, _} = host(renewal_env, on_lost ++ [lease_ttl_ms: 2_000])

      # On a lease clock that the test does not move, the claim's until is 2 s after the
      # claim, and the host's deadline 2 s after the node time of its reading in start_run.
      read_started = now_ms()
      assert :ok = RunHost.start_run(read_host, :read_held, spec("read-held", stub([])))
      read_ready = now_ms()

      assert :ok =
               RunHost.start_run(renewal_host, :renewal_held, spec("renewal-held", stub([])))

      renewal_ready = now_ms()
      Agent.update(armed, fn _ -> %{reply: true, renewal: true} end)
      assert_receive {:renewal_held, renewal_backend}, 5_000

      # Each Run is lost at its deadline (a Memory reading waits up to 35 s), no reading having
      # moved it: not before the earliest node time that it can be, nor later than the latest
      # plus a timer's margin.
      assert_receive {:lost, :read_held, :expired, read_lost}, 5_000
      assert_receive {:lost, :renewal_held, :expired, renewal_lost}, 5_000
      assert read_lost >= read_started + 2_000 and read_lost <= read_ready + 2_000 + @timer

      assert renewal_lost >= read_ready + 2_000 and
               renewal_lost <= renewal_ready + 2_000 + @timer

      # Both teardowns end with every job of the Run gone, while the readings still wait
      # in their backends: the renewal's and the expiry check's on :read_held, the expiry
      # check's on :renewal_held.
      eventually(fn -> run(read_host, :read_held) == nil end)
      eventually(fn -> run(renewal_host, :renewal_held) == nil end)
      assert now_ms() < renewal_ready + 2_000 + 2_000
      read_backend = Lease.Memory.owner(read_env.lease.backend)

      for {backend, key, n} <- [
            {read_backend, "run/read-held", 2},
            {renewal_backend, "run/renewal-held", 1}
          ] do
        {:messages, messages} = Process.info(backend, :messages)
        assert Enum.count(messages, &match?({:"$gen_call", _, {:read, ^key}}, &1)) == n
      end

      refute_receive {:lost, _, _, _}, 300
      :sys.resume(read_backend)
      send(renewal_backend, :go)
    end

    test "a renewal whose lease a same-holder re-claim shortens before its reading: with no input, the Run is lost (:expired) at the shorter cutoff" do
      test = self()
      {:ok, flags} = Agent.start_link(fn -> %{committed: false, held: false} end)

      # The first renewal is held in the Run owner right after its transaction committed;
      # the next one waits before it locks anything.
      hook = fn
        :after_commit, %{key: "run/cut"} ->
          if Agent.get_and_update(flags, &{&1.committed, %{&1 | committed: false}}) do
            send(test, {:committed, self()})
            receive do: (:go -> :ok)
          end

        :before_lock, %{key: "run/cut"} ->
          if Agent.get_and_update(flags, &{&1.held, %{&1 | held: false}}) do
            send(test, :renewing_again)
            receive do: (:never -> :ok)
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
      spec = spec("cut", stub([]))
      assert :ok = RunHost.start_run(host, :cut, spec)
      Agent.update(flags, &%{&1 | committed: true})
      assert_receive {:committed, owner}, 5_000

      # Between the renewal's commit and its reading the same owner re-claims the key for
      # 1 s: the reading shows this owner's lease live until then, while the renewal itself
      # returned an until 4 s after its commit. The re-claim's until passes 1 s after its
      # store clock sample, which comes between the node times taken around it.
      before = now_ms()
      {:held, %{live: %{at: at, until: cut}}} = Lease.claim(env.lease, "run/cut", "node-a", 1_000)
      cutoff = %{from: before + div(cut - at, 1_000), by: now_ms() + div(cut - at, 1_000)}
      Agent.update(flags, &%{&1 | held: true})
      send(owner, :go)

      # With no further input the Run is lost at the shorter cutoff: no earlier than the
      # host's sampling margin allows, no later than a timer's, and with no renewal of the
      # re-claim's lease record.
      assert_receive {:lost, :cut, :expired, lost_at}, 3_000
      assert lost_at >= cutoff.from - @sampling
      assert lost_at <= cutoff.by + @timer
      refute_received :renewing_again

      assert {:error, :lease_lost} =
               RunHost.input(host, :cut, "late", start_input(), verified(spec))

      eventually(fn -> run(host, :cut) == nil end)
      refute_receive {:lost, :cut, _, _}, 300
      refute_received :renewing_again
      assert renewals(env, spec) == 1
    end

    test "a renewal's confirmation that reaches the host after a newer reading of a shortened lease keeps the shorter deadline" do
      shortened!(:reading_first)
    end

    test "a reading of a shortened lease that reaches the host after the renewal's confirmation still shortens the deadline" do
      shortened!(:confirmation_first)
    end

    test "a renewal whose own reading is given up at a deadline that a newer reading has since moved: a reading after its reply confirms it, and the Run is not lost" do
      test = self()
      key = "run/moved"
      {:ok, armed} = Agent.start_link(fn -> %{lock: false, write: false} end)

      hook = fn
        :before_lock, %{key: ^key, owner: backend} ->
          if Agent.get_and_update(armed, &{&1.lock, %{&1 | lock: false}}) do
            send(test, {:renewing, backend})
            receive do: (:go -> :ok)
          end

        :before_write, %{key: ^key, owner: backend} ->
          if Agent.get_and_update(armed, &{&1.write, %{&1 | write: false}}),
            do: suspend_after_call(backend)

        _, _ ->
          :ok
      end

      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 2_000])
      spec = spec("moved", stub([]))
      assert :ok = RunHost.start_run(host, :moved, spec)
      %{lease: %{deadline: first_deadline, until: until}} = run(host, :moved)
      Agent.update(armed, fn _ -> %{lock: true, write: true} end)

      # The renewal (half the TTL in) samples the lease clock 1 s on and commits an until
      # 3 s after the claim's lease time; the backend suspends right after it, with the
      # renewal's reading after its reply first in its queue.
      assert_receive {:renewing, backend}, 5_000
      Lease.Clock.advance(env.clock, 1_000_000)
      send(backend, :go)
      reader = queued_reader!(backend, key, [])
      renewal = parent(reader)
      gone = Process.monitor(reader)

      # The reader is held, so it never answers its renewal job, and the job is held too.
      :erlang.suspend_process(reader)
      :erlang.suspend_process(renewal)
      :sys.resume(backend)

      # The host's own expiry check, 200 ms before the deadline, reads the lease clock 1 s
      # on: the last confirmed until is still 1 s ahead of it, so the deadline moves 800 ms
      # later.
      eventually(fn -> run(host, :moved).lease.deadline > first_deadline end)
      %{lease: %{deadline: moved}} = run(host, :moved)

      # Only now does the renewal job go on: it gives its reading up at its own deadline (the
      # first one), with no reply, and its result has no reading.
      :erlang.resume_process(renewal)
      assert_receive {:DOWN, ^gone, :process, ^reader, :killed}, 5_000
      assert now_ms() >= first_deadline

      # The host reads again after that reply, and the reading confirms the renewal: its
      # until is the last confirmed one. The Run is lost neither at the first deadline nor at
      # the moved one, and its next generation renews again.
      eventually(fn -> run(host, :moved).lease.until > until end)
      refute_receive {:lost, :moved, _, _}, max(moved + @timer - now_ms(), 0)
      eventually(fn -> renewals(env, spec) == 2 end)
      refute_received {:lost, :moved, _, _}
      assert %{phase: :live} = run(host, :moved)
      assert :ok = RunHost.reap(host, :moved)
    end

    @tag timeout: 15_000
    test "a lease reader that replied and has not exited (it is suspended): the reading is taken at once and the reader stopped, so no job waits for its exit" do
      test = self()

      reader =
        spawn(fn ->
          receive do
            {:reply, to} ->
              send(to, {to, {:ok, :reading}})
              send(test, :replied)
              receive do: (:never -> :ok)
          end
        end)

      # The reader's reply comes as a Task reply does: under the alias of its monitor.
      tag = :erlang.monitor(:process, reader, alias: :demonitor)
      gone = Process.monitor(reader)
      send(reader, {:reply, tag})
      assert_receive :replied
      :erlang.suspend_process(reader)

      task = %Task{pid: reader, ref: tag, owner: self(), mfa: {Lease, :status, 2}}
      deadline = now_ms() + 5_000
      {elapsed, read} = :timer.tc(fn -> RunHost.reading_of(task, deadline) end, :millisecond)

      assert read == {:ok, :reading}
      assert elapsed < 1_000
      refute Process.alive?(reader)
      assert_receive {:DOWN, ^gone, :process, ^reader, :killed}, 1_000
    end
  end

  # A Run whose model call's completion ends it, held at the gate of its finish inside
  # that outcome's input, so that the engine is suspended right after it answers the
  # input: the worker's read after the input waits for the engine. `queued` (a caller's
  # input or control with the ID "late") waits behind it in the worker.
  defp ended!(host, ref, name, queued) do
    test = self()
    {:ok, armed} = Agent.start_link(fn -> true end)

    gate = fn checked, _ ->
      with %{"actions" => [%{"kind" => "finish"} | _]} <- Elzoo.PatternStep.encode(checked),
           true <- Agent.get_and_update(armed, &{&1, false}) do
        send(test, {:finishing, ref, self()})
        receive do: (:go -> :ok)
      end

      :allow
    end

    spec = spec(name, stub([answer("the end")]), gate: %{id: "gate", version: 1, call: gate})
    assert :ok = RunHost.start_run(host, ref, spec)
    assert {:ok, :applied} = RunHost.input(host, ref, "start", start_input(), verified(spec))
    assert_receive {:finishing, ^ref, engine}, 10_000
    %{worker: worker} = run(host, ref)
    spawn(fn -> :sys.suspend(engine, :infinity) end)

    eventually(fn ->
      {:messages, messages} = Process.info(engine, :messages)
      Enum.any?(messages, &match?({:system, _, :suspend}, &1))
    end)

    call = Task.async(fn -> queued.(spec) end)

    eventually(fn ->
      {:messages, messages} = Process.info(worker, :messages)
      Enum.any?(messages, &match?({:"$gen_call", _, {_, "late", _, _}}, &1))
    end)

    send(engine, :go)
    {worker, engine, call}
  end

  # A renewal and a same-holder re-claim that shortens the lease, read in a fixed Store order
  # and applied by the host in a fixed order (Memory, a 4 s TTL, a lease clock that only the
  # test moves). The renewal commits and the Lease backend is suspended right after it, so
  # that the renewal's reading after its reply, the re-claim (a 1 s TTL) and an expiry
  # check's reading wait in its queue in that order: the renewal's reading shows the
  # renewal's record, the check's reading the re-claim's. One of the two jobs is held while
  # the other one's result is applied, then let go. `order` is `:reading_first` (the check's
  # newer reading is applied first, the renewal's confirmation after it) or
  # `:confirmation_first`.
  defp shortened!(order) do
    test = self()
    name = "shortened-#{order}"
    key = "run/" <> name
    ref = String.to_atom(name)
    {:ok, armed} = Agent.start_link(fn -> false end)

    hook = fn
      :before_write, %{key: ^key, owner: backend} ->
        if Agent.get_and_update(armed, &{&1, false}) do
          suspend_after_call(backend)
          send(test, {:suspending, backend})
        end

      _, _ ->
        :ok
    end

    env = memory(lease: [test_hook: hook])
    {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
    spec = spec(name, stub([]))
    assert :ok = RunHost.start_run(host, ref, spec)
    %{token: token, lease: %{generation: first, deadline: deadline}} = run(host, ref)
    {:ok, lease_now} = Lease.Clock.sample(env.clock)
    Agent.update(armed, fn _ -> true end)

    # The renewal (half the TTL in) commits, and its reading after the reply waits first in
    # the suspended backend's queue; the re-claim waits behind it, and behind that the
    # reading of the expiry check of the current deadline, which the test fires itself (the
    # host's own timer message).
    assert_receive {:suspending, backend}, 5_000
    renewal_reader = queued_reader!(backend, key, [])
    reclaim = Task.async(fn -> Lease.claim(env.lease, key, "node-a", 1_000) end)
    eventually(fn -> queued?(backend, &match?({:"$gen_call", _, {:single, ^key, _}}, &1)) end)
    checked = now_ms()
    send(host, {:expiry, ref, token, deadline})
    check_reader = queued_reader!(backend, key, [renewal_reader])
    {renewal, check} = {parent(renewal_reader), parent(check_reader)}

    # The job applied second is held until the first one's result is applied.
    later = if order == :reading_first, do: renewal, else: check
    :erlang.suspend_process(later)
    :sys.resume(backend)
    assert {:held, %{live: %{until: cut}}} = Task.await(reclaim)
    assert cut == lease_now + 1_000_000
    confirmed? = fn -> run(host, ref).lease.generation != first end
    shortened? = fn -> run(host, ref).lease.seen.until == cut end

    if order == :reading_first do
      eventually(shortened?)
      refute confirmed?.()
    else
      eventually(confirmed?)
      refute shortened?.()
    end

    :erlang.resume_process(later)
    eventually(fn -> confirmed?.() and shortened?.() end)
    applied = now_ms()

    # Both are applied, in either order: the renewal's until is the last confirmed one, the
    # check's newer reading is the one seen, and the deadline is the re-claim's, 1 s after
    # the node time of the check's reading (taken after `checked`, before `applied`) on the
    # lease clock that stood still.
    assert %{phase: :live, lease: %{until: until, deadline: short}} = run(host, ref)
    assert until > cut
    assert short >= checked + 1_000 and short <= applied + 1_000

    # The lease clock passes the re-claim's until now (not the renewal's). The Run is lost
    # either by the host's check of the short deadline, which reads it after `moved`, or by
    # the fence at that deadline: never before both, and no later than that deadline plus a
    # timer's margin. With the renewal's until as its deadline, nothing would read the lease
    # before the next renewal, 2 s after the confirmation's reading.
    Lease.Clock.advance(env.clock, 1_500_000)
    moved = now_ms()
    assert_receive {:lost, ^ref, :expired, lost_at}, 5_000
    assert lost_at >= min(moved, short)
    assert lost_at <= short + @timer

    # Nothing renewed the re-claim's lease record.
    eventually(fn -> run(host, ref) == nil end)
    refute_receive {:lost, ^ref, _, _}, 300
    assert renewals(env, spec) == 1
  end

  # Called inside the Memory Lease backend during a call: the backend suspends right after
  # that call, before it takes the next one from its queue.
  defp suspend_after_call(backend) do
    spawn(fn -> :sys.suspend(backend, :infinity) end)
    eventually(fn -> queued?(backend, &match?({:system, _, :suspend}, &1)) end)
  end

  defp queued?(pid, match) do
    {:messages, messages} = Process.info(pid, :messages)
    Enum.any?(messages, match)
  end

  # A process whose read of `key` waits in the Memory Lease backend's queue, other than those
  # of `known`.
  defp queued_reader!(backend, key, known) do
    eventually(fn -> queued_readers(backend, key) -- known != [] end)
    hd(queued_readers(backend, key) -- known)
  end

  defp queued_readers(backend, key) do
    {:messages, messages} = Process.info(backend, :messages)
    for {:"$gen_call", {pid, _}, {:read, ^key}} <- messages, do: pid
  end

  # The process that started `pid`: the renewal or expiry job of a lease reader.
  defp parent(pid) do
    {:dictionary, dictionary} = Process.info(pid, :dictionary)
    hd(dictionary[:"$ancestors"])
  end

  # When the until of a lease's holder passes on a store clock that runs in real time, by a
  # reading of the test's own: its sample comes between the node times taken around it, so
  # the cutoff is between `from` and `by`.
  defp passes(lease, key) do
    before = now_ms()
    {:ok, %{now: lease_now, holder: %{until: until}}} = Lease.status(lease, key)
    left = div(until - lease_now, 1_000)
    %{from: before + left, by: now_ms() + left}
  end

  # on_terminal, and an on_lost that sends the node time of each call.
  defp timed(test \\ self()) do
    [
      on_terminal: fn ref, outcome -> send(test, {:terminal, ref, outcome}) end,
      on_lost: fn ref, reason ->
        send(test, {:lost, ref, reason, System.monotonic_time(:millisecond)})
      end
    ]
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp pause_context(mode) do
    fn ->
      margin = if Agent.get(mode, & &1) == :short, do: 100, else: 600_000

      %{
        policy: policy(),
        authority: [%{target: "document", field: "published", value: true}],
        resource_names: ["document"],
        pause_deadline: clock() + margin
      }
    end
  end

  defp wakes(entries), do: for(%{type: :input, kind: "wake"} = e <- entries, do: e)

  defp wake_id(spec, deadline) do
    "wake:" <>
      (:crypto.hash(
         :sha256,
         :erlang.term_to_binary({spec.run_id, spec.attempt_id, deadline}, [:deterministic])
       )
       |> Base.encode16(case: :lower))
  end

  defp message(text),
    do: %{
      "type" => "input",
      "version" => 1,
      "kind" => "message",
      "schema_id" => "elzoo.agent-loop.message",
      "schema_version" => 1,
      "payload" => %{"text" => text}
    }

  defp renewals(env, spec),
    do: length(for %{kind: "lease_renewed"} <- rows(env, "run/" <> spec.unit), do: 1)
end
