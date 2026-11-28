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
      started = now_ms()

      assert :ok = RunHost.start_run(host, :renewed, spec)
      # The exits of the Run's processes and the generations that the host confirmed (the
      # claim's, then one per confirmed renewal), kept to explain a failure.
      roles = Map.new(run(host, :renewed).pids, fn {role, pid} -> {Process.monitor(pid), role} end)
      sampler = spawn_link(fn -> generations(host, :renewed, MapSet.new()) end)

      progress =
        &progress!(&1, &2, %{host: host, env: env, spec: spec, started: started, roles: roles})

      progress.("start", RunHost.input(host, :renewed, "start", start_input(), verified(spec)))
      assert_receive {:stub_entered, stub_task}, 10_000

      for n <- 1..6 do
        Process.sleep(500)
        reply = RunHost.input(host, :renewed, "message-#{n}", message("more #{n}"), verified(spec))
        progress.("message-#{n}", reply)
      end

      send(sampler, {:generations, self()})
      assert_receive {:generations, generations}, 1_000
      assert renewals(env, spec) >= 4
      assert MapSet.size(generations) - 1 >= 4
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

      # Both readings are the host's own reading jobs, one after the other; the renewal's
      # job reads nothing.
      assert first != second and task not in [first, second]

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

    test "a pending renewal's reading again stays due when an older record's reading moves the deadline meanwhile, so the renewal is confirmed once the lease can be read again" do
      test = self()
      key = "run/kept-retry"
      {cell, hook} = hold_after_commit(key, test)
      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
      spec = spec("kept-retry", stub([]))
      assert :ok = RunHost.start_run(host, :kept_retry, spec)
      %{token: token, pids: %{owner: owner}, lease: %{generation: first}} = run(host, :kept_retry)

      # A reading of the claim's record, taken by the test a second after the start (as an
      # admission takes one) and held: later on the node than the start's reading.
      Process.sleep(1_000)
      {t0, old} = RunHost.lease_reading(env.lease, key, "node-a")

      # The renewal (half the TTL in) commits, its reply held in the suspended owner; then
      # the lease clock cannot be read, the owner replies, and the renewal is pending while
      # the host reads again every 100 ms and fails.
      Agent.update(cell, fn _ -> owner end)
      held!(owner)
      replied!(owner)
      Lease.Clock.fail(env.clock, true)
      :erlang.resume_process(owner)
      eventually(fn -> run(host, :kept_retry).lease.pending != nil end)
      %{lease: %{deadline: before}} = run(host, :kept_retry)

      # The held reading of the older record arrives: it confirms nothing and moves the
      # deadline later, cancelling that deadline's expiry check.
      assert :ok = GenServer.call(host, {:reading, :kept_retry, token, t0, old})
      assert %{lease: %{deadline: moved, pending: %{}}} = run(host, :kept_retry)
      assert moved > before

      # The lease clock can be read again: the pending renewal's next reading (its retry is
      # configured 100 ms on) confirms it, more than a second before the moved deadline.
      Process.sleep(250)
      Lease.Clock.fail(env.clock, false)
      eventually(fn -> run(host, :kept_retry).lease.generation != first end, 50)
      assert now_ms() < moved - 1_000
      refute_received {:lost, :kept_retry, _, _}
      assert :ok = RunHost.reap(host, :kept_retry)
    end

    test "a reading of the renewed record taken after its commit and before the owner's reply confirms nothing: with no later reading the Run is lost (:expired) at its deadline" do
      test = self()
      key = "run/pre-reply"
      {cell, hook} = hold_after_commit(key, test)
      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 2_000])
      spec = spec("pre-reply", stub([]))
      assert :ok = RunHost.start_run(host, :pre_reply, spec)
      %{token: token, pids: %{owner: owner}, lease: %{generation: first}} = run(host, :pre_reply)
      Agent.update(cell, fn _ -> owner end)

      # The renewal (half the TTL in) commits; its reply waits in the suspended owner. A
      # reading taken now by the test (as an admission takes one) shows the renewed record.
      held!(owner)
      replied!(owner)
      {t0, read} = RunHost.lease_reading(env.lease, key, "node-a")
      assert {:ok, %{record: renewed}} = read

      # Every later reading fails (the lease clock cannot be read); the owner replies, and
      # the renewal is pending.
      Lease.Clock.fail(env.clock, true)
      :erlang.resume_process(owner)
      eventually(fn -> match?(%{pending: %{record: ^renewed}}, run(host, :pre_reply).lease) end)

      # The earlier reading reaches the host only now: it was taken before the reply, so it
      # confirms nothing, and with no later reading the Run is lost at its deadline.
      assert :ok = GenServer.call(host, {:reading, :pre_reply, token, t0, read})

      assert %{lease: %{generation: ^first, pending: %{}, deadline: deadline}} =
               run(host, :pre_reply)

      assert_receive {:lost, :pre_reply, :expired, lost_at}, max(deadline - now_ms(), 0) + 1_000
      assert lost_at >= deadline
      Lease.Clock.fail(env.clock, false)
    end

    test "a reading taken after the owner's reply that reaches the host before the renewal's result confirms the renewal when that result arrives (the result delivered by the test)" do
      test = self()
      key = "run/early-reading"
      {cell, hook} = hold_after_commit(key, test)
      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
      spec = spec("early-reading", stub([]))
      assert :ok = RunHost.start_run(host, :early_reading, spec)

      %{token: token, pids: %{owner: owner}, lease: %{generation: first}} =
        run(host, :early_reading)

      Agent.update(cell, fn _ -> owner end)
      held!(owner)
      replied!(owner)

      # The renewal has committed and its reply waits in the suspended owner. The test stands
      # for the job's reply with a mark of its own taken now, then takes a reading (as an
      # admission does), which reaches the host first.
      [job] = for {ref, {:renew, :early_reading, _, _}} <- state(host).jobs, do: ref
      replied = RunHost.mark()
      {t0, read} = RunHost.lease_reading(env.lease, key, "node-a")
      assert {:ok, %{record: record, holder: %{until: until}}} = read
      assert :ok = GenServer.call(host, {:reading, :early_reading, token, t0, read})

      # No later reading can succeed; the renewal's result, delivered by the test under the
      # job's reference, is confirmed at once by the reading that the host already holds.
      Lease.Clock.fail(env.clock, true)
      send(host, {job, {:renewed, until, record, replied}})

      assert %{lease: %{pending: nil, record: ^record, until: ^until, generation: second}} =
               run(host, :early_reading)

      assert second != first
      Lease.Clock.fail(env.clock, false)
      :erlang.resume_process(owner)
      refute_receive {:lost, :early_reading, _, _}, 300
      assert :ok = RunHost.reap(host, :early_reading)
    end

    test "a same-holder re-claim with the same until as the renewal, taken before that renewal's reading: the reading shows the re-claim's record, so nothing renews it" do
      test = self()
      key = "run/same-until"
      {:ok, armed} = Agent.start_link(fn -> %{write: false, lock: false} end)

      hook = fn
        :before_write, %{key: ^key, owner: backend} ->
          if Agent.get_and_update(armed, &{&1.write, %{&1 | write: false}}) do
            suspend_after_call(backend)
            send(test, {:suspending, backend})
          end

        :before_lock, %{key: ^key} ->
          if Agent.get_and_update(armed, &{&1.lock, %{&1 | lock: false}}),
            do: send(test, :renewing_again)

        _, _ ->
          :ok
      end

      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
      spec = spec("same-until", stub([]))
      assert :ok = RunHost.start_run(host, :same_until, spec)
      %{lease: %{generation: first}} = run(host, :same_until)
      {:ok, lease_now} = Lease.Clock.sample(env.clock)
      Agent.update(armed, &%{&1 | write: true})

      # The renewal (half the TTL in, the lease clock not moved) commits an until 4 s after
      # the claim's lease time; the backend is suspended right after it, and the renewal's
      # reading after its reply waits in its queue. The lease clock moves 1 s and the same
      # owner re-claims for 3 s, queued behind that reading: the same until, another record.
      assert_receive {:suspending, backend}, 5_000
      queued_reader!(backend, key, [])
      Lease.Clock.advance(env.clock, 1_000_000)
      reclaim = Task.async(fn -> Lease.claim(env.lease, key, "node-a", 3_000) end)
      eventually(fn -> queued?(backend, &match?({:"$gen_call", _, {:single, ^key, _}}, &1)) end)
      :sys.resume(backend)
      assert {:held, %{live: %{until: until, revision: reclaimed}}} = Task.await(reclaim)
      assert until == lease_now + 4_000_000

      # The renewal is confirmed by a reading that shows the re-claim's record (its status
      # read came first, the head moved before its record read, so both were read again):
      # the same until as the renewal's, another lease record.
      eventually(fn -> run(host, :same_until).lease.generation != first end)
      %{lease: l} = run(host, :same_until)
      assert l.until == until and l.seen.until == until
      assert l.seen.record == reclaimed and l.record < reclaimed
      Agent.update(armed, &%{&1 | lock: true})

      # No renewal of the re-claim's record starts, also past the moment when the next one
      # was due (half the TTL before a deadline at most 3 s after that reading).
      refute_receive :renewing_again, 1_500
      assert %{phase: :live} = run(host, :same_until)

      # Once the lease clock passes that until, an input finds the lease expired.
      Lease.Clock.advance(env.clock, 3_000_000)

      assert {:error, :lease_lost} =
               RunHost.input(host, :same_until, "late", start_input(), verified(spec))

      assert_receive {:lost, :same_until, :expired, _}, 3_000
      eventually(fn -> run(host, :same_until) == nil end)
      refute_received :renewing_again
      assert renewals(env, spec) == 1
    end

    test "an expiry check that reads the confirmed renewal's record at the same revision and lease time, later on this node: the deadline moves with it, so a renewal held past the old deadline is still confirmed" do
      env = memory()
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 2_000])
      spec = spec("still-clock", stub([]))
      assert :ok = RunHost.start_run(host, :still_clock, spec)
      %{lease: %{generation: first}} = run(host, :still_clock)

      # The first renewal (the lease clock not moved, so the same lease time and until) is
      # confirmed by its reading; the Run then writes nothing.
      eventually(fn -> run(host, :still_clock).lease.generation != first end)

      %{pids: %{owner: owner}, lease: %{generation: second, deadline: old, seen: confirmed}} =
        run(host, :still_clock)

      # The Run owner is suspended, so the next renewal, half the TTL before that deadline,
      # waits in its call (5 s caller limit) before it writes anything.
      :erlang.suspend_process(owner)

      # The expiry check 200 ms before the deadline reads the same head revision and lease
      # time as the confirmation, later on this node: the deadline moves on, and the Run is
      # not lost at the old one.
      Process.sleep(max(old + @timer - now_ms(), 0))
      refute_received {:lost, :still_clock, _, _}

      assert %{phase: :live, lease: %{generation: ^second, deadline: moved, seen: seen}} =
               run(host, :still_clock)

      assert moved > old

      assert {seen.revision, seen.now, seen.record} ==
               {confirmed.revision, confirmed.now, confirmed.record}

      assert seen.t0 > confirmed.t0

      # The held renewal writes and is confirmed.
      :erlang.resume_process(owner)
      eventually(fn -> run(host, :still_clock).lease.generation not in [first, second] end)
      assert renewals(env, spec) == 2
      refute_received {:lost, :still_clock, _, _}
      assert :ok = RunHost.reap(host, :still_clock)
    end

    test "an admission reading that shows a shorter re-claim of this owner moves the Run's deadline and stops its renewals" do
      test = self()
      key = "run/admitted-cut"
      {:ok, armed} = Agent.start_link(fn -> false end)

      hook = fn
        :before_lock, %{key: ^key} ->
          if Agent.get_and_update(armed, &{&1, false}), do: send(test, :renewing)

        _, _ ->
          :ok
      end

      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
      spec = spec("admitted-cut", stub([]))
      assert :ok = RunHost.start_run(host, :admitted_cut, spec)
      %{lease: %{deadline: deadline, record: record}} = run(host, :admitted_cut)

      # Just after the start the same owner re-claims the key for 1 s; then a caller's input
      # is admitted by a reading of that shorter lease (the engine's answer does not matter).
      assert {:held, %{live: %{revision: reclaimed}}} = Lease.claim(env.lease, key, "node-a", 1_000)
      Agent.update(armed, fn _ -> true end)
      before = now_ms()
      _ = RunHost.input(host, :admitted_cut, "probe", message("probe"), verified(spec))

      # That reading is the Run's newest: its deadline is the re-claim's, 1 s after the
      # reading's node time on a lease clock that stands still, and no renewal starts, also
      # past the moment of the renewal that the claim's deadline gave (2 s after the claim).
      eventually(fn -> run(host, :admitted_cut).lease.seen.record == reclaimed end)
      assert %{lease: %{record: ^record, deadline: short}} = run(host, :admitted_cut)
      assert short < deadline and short >= before + 1_000 and short <= now_ms() + 1_000
      refute_receive :renewing, max(deadline - 2_000 + @timer - now_ms(), 0)
      assert %{phase: :live} = run(host, :admitted_cut)

      Lease.Clock.advance(env.clock, 1_000_000)

      assert {:error, :lease_lost} =
               RunHost.input(host, :admitted_cut, "late", start_input(), verified(spec))

      assert_receive {:lost, :admitted_cut, :expired, _}, 3_000
      eventually(fn -> run(host, :admitted_cut) == nil end)
      refute_received :renewing
      assert renewals(env, spec) == 0
    end

    test "an activation reading that shows a shorter re-claim of this owner, still live: the activation is granted, and the reading moves the Run's deadline and stops its renewals" do
      test = self()
      key = "run/activated-cut"
      {:ok, armed} = Agent.start_link(fn -> %{gate: true, lock: false} end)

      hook = fn
        :before_lock, %{key: ^key} ->
          if Agent.get_and_update(armed, &{&1.lock, %{&1 | lock: false}}),
            do: send(test, :renewing)

        _, _ ->
          :ok
      end

      env = memory(lease: [test_hook: hook])

      # In the gate, after the caller's admission and before the call's intent asks for its
      # activation, the same owner re-claims the key for 1 s (the lease clock stands still).
      gate = fn _, _ ->
        if Agent.get_and_update(armed, &{&1.gate, %{&1 | gate: false}}) do
          {:held, %{live: %{revision: revision}}} = Lease.claim(env.lease, key, "node-a", 1_000)
          send(test, {:reclaimed, revision, now_ms()})
          Agent.update(armed, &%{&1 | lock: true})
        end

        :allow
      end

      # A TTL of 60 s: the claim's renewal is due 30 s after the start, past the end of the
      # test (checked below), so the re-claim, the activation reading and the renewal message
      # that its reading schedules come in that order. The host's own messages are traced.
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 60_000])
      started = now_ms()
      stub = stub([{:block, answer("granted")}])
      spec = spec("activated-cut", stub, gate: %{id: "gate", version: 1, call: gate})
      assert :ok = RunHost.start_run(host, :activated_cut, spec)
      %{lease: %{deadline: deadline, record: record}} = run(host, :activated_cut)
      :erlang.trace(host, true, [:receive, {:tracer, self()}])

      assert {:ok, :applied} =
               RunHost.input(host, :activated_cut, "start", start_input(), verified(spec))

      # The activation is granted on the re-claim's reading, and the stub is called.
      assert_receive {:reclaimed, reclaimed, reclaimed_at}, 5_000
      assert_receive {:stub_entered, stub_task}, 5_000
      observed_at = now_ms()

      assert %{phase: :live, lease: %{record: ^record, seen: seen, deadline: short}} =
               run(host, :activated_cut)

      # The deadline is the re-claim's 1 s, from the activation's reading on a lease clock
      # that stands still (taken after the re-claim returned, before this observation).
      assert seen.record == reclaimed
      assert short < deadline
      assert short >= reclaimed_at + 1_000 and short <= observed_at + 1_000

      # The renewal message that this reading scheduled at once reaches the host, and no
      # owner renewal starts.
      assert_receive {:trace, ^host, :receive, {:renew, :activated_cut, _, _, _}}, 1_000
      refute_receive :renewing, 300
      :erlang.trace(host, false, [:receive])
      assert renewals(env, spec) == 0
      assert %{phase: :live} = run(host, :activated_cut)
      assert now_ms() < started + 25_000

      # The reap's release locks the key too: the hook reports no more from here.
      Agent.update(armed, &%{&1 | lock: false})
      send(stub_task, :release)
      assert :ok = RunHost.reap(host, :activated_cut)
    end

    test "a renewal already submitted when a re-claim is observed: it can still write onto the re-claim's record, the owner then reports it fenced, and no other renewal starts" do
      test = self()
      key = "run/in-flight"
      {:ok, armed} = Agent.start_link(fn -> %{hold: false, again: false} end)

      # The renewal waits in the Run owner before it locks anything; any later renewal is
      # reported.
      hook = fn
        :before_lock, %{key: ^key} ->
          cond do
            Agent.get_and_update(armed, &{&1.hold, %{&1 | hold: false}}) ->
              send(test, {:renewing, self()})
              receive do: (:go -> :ok)

            Agent.get_and_update(armed, &{&1.again, %{&1 | again: false}}) ->
              send(test, :renewing_again)

            true ->
              :ok
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
      spec = spec("in-flight", stub([]))
      assert :ok = RunHost.start_run(host, :in_flight, spec)
      Agent.update(armed, &%{&1 | hold: true})
      assert_receive {:renewing, owner}, 5_000

      # While that renewal waits, the same holder re-claims the key, and the host observes
      # the re-claim's record (an expiry check that the test fires: the host's own message).
      assert {:held, %{live: %{revision: reclaimed, until: cut}}} =
               Lease.claim(env.lease, key, "node-a", 3_000)

      %{token: token, lease: %{deadline: deadline}} = run(host, :in_flight)
      send(host, {:expiry, :in_flight, token, deadline})
      eventually(fn -> run(host, :in_flight).lease.seen.record == reclaimed end)
      Agent.update(armed, &%{&1 | again: true})

      # The submitted renewal goes on: Lease.renew appends a renewal onto the re-claim's
      # record before the owner compares the revision, and the owner then stops, fenced.
      send(owner, :go)
      assert_receive {:lost, :in_flight, {:fenced, %{expected: _, observed: observed}}, _}, 5_000
      assert observed == reclaimed
      kinds = for %{kind: "lease_" <> _ = kind} <- rows(env, key), do: kind
      assert Enum.take(kinds, -2) == ["lease_claimed", "lease_renewed"]
      assert {:ok, %{holder: %{until: extended}}} = Lease.status(env.lease, key)
      assert extended > cut

      # The host starts no other renewal, and on_lost was called once.
      eventually(fn -> run(host, :in_flight) == nil end)
      refute_receive {:lost, :in_flight, _, _}, 300
      refute_received :renewing_again
      assert renewals(env, spec) == 1
    end

    test "a definite no-write renewal error waits a twelfth of the TTL before the next renewal, also when a later reading shortens the deadline to now (the error delivered by the test)" do
      env = memory()
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 2_400])
      spec = spec("backoff", stub([]))
      assert :ok = RunHost.start_run(host, :backoff, spec)
      %{token: token, pids: %{owner: owner}, lease: %{generation: first}} = run(host, :backoff)

      # The Run owner is suspended, so the renewal (half the TTL in) waits in its call; each
      # call that reaches the owner is traced with the node time of its arrival.
      :erlang.suspend_process(owner)
      :erlang.trace(owner, true, [:receive, :monotonic_timestamp, {:tracer, self()}])
      assert_receive {:trace_ts, ^owner, :receive, {:"$gen_call", _, {:renew, _}}, _}, 5_000

      # The real reading is taken first (as an admission takes one), after the lease clock
      # moved 1.2 s, so that its deadline alone would make the next renewal due at once.
      # Then the renewal's result, a definite no-write error delivered by the test under the
      # job's reference, and right behind it (same sender, so in that order) the admission's
      # call with that reading reach the host; the call's reply shows that the host has
      # applied the reading.
      [job] = for {ref, {:renew, :backoff, _, _}} <- state(host).jobs, do: ref
      Lease.Clock.advance(env.clock, 1_200_000)
      {t0, read} = RunHost.lease_reading(env.lease, "run/backoff", "node-a")
      failed = now_ms()
      send(host, {job, {:error, :contended}})
      assert :ok = GenServer.call(host, {:reading, :backoff, token, t0, read})
      handled = now_ms()

      # The reading was applied inside the 200 ms floor, and the next renewal reaches the
      # owner after it: no sooner than 200 ms after the error was delivered, and no later
      # than 200 ms after it plus a timer's margin.
      assert handled < failed + 200
      assert_receive {:trace_ts, ^owner, :receive, {:"$gen_call", _, {:renew, _}}, ts}, 1_000
      at = System.convert_time_unit(ts, :nanosecond, :millisecond)
      assert at > handled
      assert at - failed >= 200
      assert at - failed <= 200 + @timer
      :erlang.trace(owner, false, [:receive])

      # The owner goes on: the renewal is confirmed, and the Run is not lost.
      :erlang.resume_process(owner)
      eventually(fn -> run(host, :backoff).lease.generation != first end)
      refute_received {:lost, :backoff, _, _}
      assert :ok = RunHost.reap(host, :backoff)
    end

    test "a pending renewal is confirmed by a caller's admission reading of its record while the host's own reading is held" do
      test = self()
      key = "run/pending"
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

      # A TTL of 60 s: the ordinary expiry check is due about 59.8 s after the start, long
      # after the assertions below (checked); the test starts the renewal itself, with the
      # host's own renewal message.
      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, timed())
      spec = spec("pending", stub([]))
      started = now_ms()
      assert :ok = RunHost.start_run(host, :pending, spec)
      %{token: token, lease: %{generation: first, due: due}} = run(host, :pending)
      Agent.update(armed, fn _ -> true end)
      send(host, {:renew, :pending, token, first, due})

      # The renewal commits and the backend suspends right after it; the host's reading after
      # the reply waits in its queue, and its job is suspended there.
      assert_receive {:suspending, backend}, 5_000
      job = queued_reader!(backend, key, [])
      :erlang.suspend_process(job)
      assert %{lease: %{pending: %{record: record, until: until}}} = run(host, :pending)

      # A caller's admission reads behind it: its reading shows the renewal's record, taken
      # after the reply, so it confirms the renewal while the host's own job is still held.
      caller =
        Task.async(fn ->
          RunHost.input(host, :pending, "probe", message("probe"), verified(spec))
        end)

      eventually(fn -> caller.pid in queued_readers(backend, key) end)
      :sys.resume(backend)
      _ = Task.await(caller, 10_000)

      assert %{lease: %{pending: nil, record: ^record, until: ^until, generation: second}} =
               run(host, :pending)

      assert second != first
      assert now_ms() < started + 50_000

      assert Enum.any?(Map.values(state(host).jobs), fn
               {:expiry, :pending, ^token, %{pid: ^job, key: {:pending, ^record}}} -> true
               _ -> false
             end)

      :erlang.resume_process(job)
      refute_received {:lost, :pending, _, _}
      assert :ok = RunHost.reap(host, :pending)
    end

    test "a renewal confirmed by an admission while its own reading is held leaves that reading no claim on the next renewal, whose reading starts at once and confirms it" do
      test = self()
      key = "run/detached"
      {:ok, armed} = Agent.start_link(fn -> %{write: false, lock: false} end)

      # Armed by the test: the next lease write of the key (renewal N) and, separately, the
      # next lease step's lock (renewal N+1; a Run stream write takes no lock) each suspend
      # the backend right after their call.
      hook = fn
        :before_write, %{key: ^key, owner: backend} ->
          if Agent.get_and_update(armed, &{&1.write, %{&1 | write: false}}) do
            suspend_after_call(backend)
            send(test, {:suspending, backend})
          end

        :before_lock, %{key: ^key, owner: backend} ->
          if Agent.get_and_update(armed, &{&1.lock, %{&1 | lock: false}}) do
            suspend_after_call(backend)
            send(test, {:renewing, backend})
          end

        _, _ ->
          :ok
      end

      # A TTL of 60 s; the test starts the first renewal (N) with the host's own message.
      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, timed())
      spec = spec("detached", stub([]))
      assert :ok = RunHost.start_run(host, :detached, spec)
      %{token: token, lease: %{generation: first, due: due}} = run(host, :detached)
      Agent.update(armed, &%{&1 | write: true})
      send(host, {:renew, :detached, token, first, due})

      # N commits; the host's reading for N waits behind it and its job is suspended there.
      assert_receive {:suspending, backend}, 5_000
      job = queued_reader!(backend, key, [])
      :erlang.suspend_process(job)
      assert %{lease: %{pending: %{record: n}, chase: {:job, n}}} = run(host, :detached)

      # A caller's admission reads behind it and confirms N; N's job is still listed, held,
      # and no longer the Run's obligation.
      caller =
        Task.async(fn ->
          RunHost.input(host, :detached, "probe", message("probe"), verified(spec))
        end)

      eventually(fn -> caller.pid in queued_readers(backend, key) end)
      :sys.resume(backend)
      _ = Task.await(caller, 10_000)

      assert %{lease: %{pending: nil, record: ^n, generation: second, chase: nil}} =
               run(host, :detached)

      assert second != first

      assert Enum.any?(Map.values(state(host).jobs), fn
               {:expiry, :detached, ^token, %{pid: ^job, key: {:pending, ^n}}} -> true
               _ -> false
             end)

      # A second admission reads the lease clock moved 45 s: its deadline is 15 s after its
      # reading (taken after `before`), so the next renewal (N+1) is due at once and the
      # expiry check of that deadline is 14.8 s after the reading. N+1 commits, the backend
      # suspends right after it, and N+1's own reading, started at once (N's held job does
      # not stand for it), waits there.
      Agent.update(armed, &%{&1 | lock: true})
      Lease.Clock.advance(env.clock, 45_000_000)
      before = now_ms()
      _ = RunHost.input(host, :detached, "probe-2", message("probe-2"), verified(spec))
      assert_receive {:renewing, ^backend}, 5_000
      next = queued_reader!(backend, key, [])

      assert %{lease: %{generation: ^second, pending: %{record: n1}, chase: {:job, n1}}} =
               run(host, :detached)

      assert n1 > n

      # N's job ends (killed by the test) with no result while N+1's reading is under way:
      # its end leaves N+1's obligation to N+1's own reading, the only one for it.
      gone = Process.monitor(job)
      Process.exit(job, :kill)
      assert_receive {:DOWN, ^gone, :process, ^job, :killed}, 1_000

      eventually(fn ->
        not Enum.any?(Map.values(state(host).jobs), &match?({_, _, _, %{pid: ^job}}, &1))
      end)

      assert %{lease: %{pending: %{record: ^n1}, chase: {:job, ^n1}}} = run(host, :detached)

      assert [^next] =
               for(
                 {:expiry, :detached, _, %{key: {:pending, _}, pid: pid}} <-
                   Map.values(state(host).jobs),
                 do: pid
               )

      # That reading goes on and confirms N+1, long before the expiry check.
      :sys.resume(backend)
      eventually(fn -> run(host, :detached).lease.generation not in [first, second] end)
      assert now_ms() < before + 10_000
      assert %{lease: %{record: ^n1, pending: nil}} = run(host, :detached)
      refute_received {:lost, :detached, _, _}
      assert :ok = RunHost.reap(host, :detached)
    end

    test "a correlation read again after the head moved takes its node time at the attempt that gives the reading" do
      test = self()
      key = "run/retimed"
      {:ok, armed} = Agent.start_link(fn -> false end)

      # The re-claim waits 1 s in the backend before it locks the key.
      hook = fn
        :before_lock, %{key: ^key} ->
          if Agent.get_and_update(armed, &{&1, false}) do
            Process.sleep(1_000)
            send(test, {:slept, now_ms()})
          end

        _, _ ->
          :ok
      end

      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, timed())
      spec = spec("retimed", stub([]))
      assert :ok = RunHost.start_run(host, :retimed, spec)
      backend = Lease.Memory.owner(env.lease.backend)

      # A caller's status read waits in the suspended backend, and a same-holder re-claim
      # (60 s, the lease clock still) behind it: the re-claim moves the head between the
      # caller's status and record reads, so the caller reads both again, 1 s later.
      :sys.suspend(backend)

      caller =
        Task.async(fn ->
          RunHost.input(host, :retimed, "probe", message("probe"), verified(spec))
        end)

      eventually(fn -> caller.pid in queued_readers(backend, key) end)
      Agent.update(armed, fn _ -> true end)
      reclaim = Task.async(fn -> Lease.claim(env.lease, key, "node-a", 60_000) end)
      eventually(fn -> queued?(backend, &match?({:"$gen_call", _, {:single, ^key, _}}, &1)) end)
      :sys.resume(backend)
      assert {:held, %{live: %{revision: reclaimed}}} = Task.await(reclaim)
      assert_receive {:slept, slept}, 5_000
      _ = Task.await(caller, 10_000)

      # The reading is the second attempt's, timed after the re-claim: 60 s left from then.
      assert %{lease: %{seen: seen, deadline: deadline}} = run(host, :retimed)
      assert seen.record == reclaimed
      assert seen.t0 >= slept
      assert deadline >= slept + 60_000
      refute_received {:lost, :retimed, _, _}
      assert :ok = RunHost.reap(host, :retimed)
    end

    test "an activation that reads another holder keeps that loss when the key is seized back under this owner before its record read" do
      test = self()
      key = "run/seized-back"
      {:ok, armed} = Agent.start_link(fn -> true end)
      env = memory()
      backend = Lease.Memory.owner(env.lease.backend)

      # In the gate, before the call's intent asks for its activation, an operator seizes the
      # key and the backend is suspended, so the activation's status read waits in it.
      gate = fn _, _ ->
        if Agent.get_and_update(armed, &{&1, false}) do
          {:held, _} = Lease.seize(env.lease, key, "operator", 60_000, :operator_takeover)
          :sys.suspend(backend)
          send(test, :seized)
        end

        :allow
      end

      {host, _} = host(env, timed())
      stub = stub([answer("never sent")])
      spec = spec("seized-back", stub, gate: %{id: "gate", version: 1, call: gate})
      assert :ok = RunHost.start_run(host, :seized_back, spec)
      activations = heads(env, "intent-host/")

      input =
        Task.async(fn ->
          RunHost.input(host, :seized_back, "start", start_input(), verified(spec))
        end)

      assert_receive :seized, 5_000

      # Behind the activation's status read, this owner seizes the key back.
      eventually(fn -> Enum.any?(queued_readers(backend, key), &intent?/1) end)
      back = Task.async(fn -> Lease.seize(env.lease, key, "node-a", 60_000, :operator_takeover) end)
      eventually(fn -> queued?(backend, &match?({:"$gen_call", _, {:single, ^key, _}}, &1)) end)
      :sys.resume(backend)
      assert {:held, _} = Task.await(back)

      # The status read showed the operator: that loss stands, with no activation and no send.
      assert_receive {:lost, :seized_back, {:lease_lost, %{holder: "operator"}}, _}, 5_000
      _ = Task.await(input, 10_000)
      eventually(fn -> run(host, :seized_back) == nil end)
      assert heads(env, "intent-host/") == activations
      assert requests(stub) == []
      refute_received {:lost, :seized_back, _, _}
    end

    test "a reading job is bounded by the deadline at its start, also when a later reading moves the deadline, spawns no process (traced from its supervisor), and is dead before a reap that waited on it answers" do
      env = memory()
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
      key = "run/bounded-read"
      assert :ok = RunHost.start_run(host, :bounded, spec("bounded-read", stub([])))
      backend = Lease.Memory.owner(env.lease.backend)
      %{token: token, lease: %{deadline: deadline}} = run(host, :bounded)

      # A reading taken by the test a second later (as an admission takes one), held.
      Process.sleep(1_000)
      {t0, later} = RunHost.lease_reading(env.lease, key, "node-a")

      # Every process that the host's task supervisor spawns, and that they spawn, is traced
      # from before the job is started. An expiry check's reading blocks in the suspended
      # backend: the job itself reads.
      tasks = state(host).tasks
      :erlang.trace(tasks, true, [:procs, :set_on_spawn, {:tracer, self()}])
      :sys.suspend(backend)
      send(host, {:expiry, :bounded, token, deadline})
      job = queued_reader!(backend, key, [])
      assert_receive {:trace, ^tasks, :spawn, ^job, _}, 1_000
      gone = Process.monitor(job)

      # The held reading moves the deadline a second later; the job is still killed at the
      # deadline at its start, having spawned nothing, and the Run lives on.
      assert :ok = GenServer.call(host, {:reading, :bounded, token, t0, later})
      assert %{lease: %{deadline: moved}} = run(host, :bounded)
      assert moved > deadline
      assert_receive {:DOWN, ^gone, :process, ^job, :killed}, max(deadline - now_ms(), 0) + @timer
      assert now_ms() >= deadline
      assert %{phase: :live} = run(host, :bounded)
      refute_received {:trace, ^job, :spawn, _, _}

      # Its next reading blocks too and is held across a reap: the reap's teardown kills it,
      # and when the reap answers, that job is already dead (the host frees the reservation
      # only on the job's own :DOWN, which comes after its death).
      eventually(fn -> for({_, {:expiry, :bounded, _, _}} <- state(host).jobs, do: 1) != [] end)
      [last] = for {_, {:expiry, :bounded, _, %{pid: pid}}} <- state(host).jobs, do: pid
      reap = Task.async(fn -> RunHost.reap(host, :bounded) end)
      eventually(fn -> not Process.alive?(last) end)
      :sys.resume(backend)
      assert :ok = Task.await(reap)
      refute Process.alive?(last)
      assert run(host, :bounded) == nil
      :erlang.trace(tasks, false, [:procs, :set_on_spawn])
      spawned = for {:trace, parent, :spawn, _, _} <- drain_traces([]), do: parent
      assert Enum.all?(spawned, &(&1 == tasks))
    end

    test "a reading job blocked in the Store ends when its host stops" do
      env = memory()
      {host, _} = host(env, timed())
      key = "run/stopped-read"
      assert :ok = RunHost.start_run(host, :stopped, spec("stopped-read", stub([])))
      backend = Lease.Memory.owner(env.lease.backend)
      %{token: token, lease: %{deadline: deadline}} = run(host, :stopped)
      :sys.suspend(backend)
      send(host, {:expiry, :stopped, token, deadline})
      job = queued_reader!(backend, key, [])
      gone = Process.monitor(job)
      GenServer.stop(host)
      assert_receive {:DOWN, ^gone, :process, ^job, _}, 3_000
      :sys.resume(backend)
    end

    test "a reap kills a reading job blocked in the Store at once, long before the deadline that bounds it" do
      env = memory()
      {host, _} = host(env, timed())
      key = "run/reaped-read"
      assert :ok = RunHost.start_run(host, :reaped, spec("reaped-read", stub([])))
      backend = Lease.Memory.owner(env.lease.backend)
      %{token: token, lease: %{deadline: deadline}} = run(host, :reaped)
      :sys.suspend(backend)
      send(host, {:expiry, :reaped, token, deadline})
      job = queued_reader!(backend, key, [])
      gone = Process.monitor(job)

      # The reap's teardown kills the reading job (its deadline is 60 s away); the release
      # then waits in the suspended backend until the test lets it go on.
      reap = Task.async(fn -> RunHost.reap(host, :reaped) end)
      assert_receive {:DOWN, ^gone, :process, ^job, :killed}, 1_000
      assert now_ms() < deadline - 50_000
      :sys.resume(backend)
      assert :ok = Task.await(reap)
    end

    test "a reading job's bound timer is cancelled at its :DOWN, long before the deadline" do
      env = memory()
      {host, _} = host(env, timed())
      key = "run/cancelled-bound"
      assert :ok = RunHost.start_run(host, :cancelled, spec("cancelled-bound", stub([])))
      backend = Lease.Memory.owner(env.lease.backend)
      %{token: token, lease: %{deadline: deadline}} = run(host, :cancelled)
      :sys.suspend(backend)
      send(host, {:expiry, :cancelled, token, deadline})
      job = queued_reader!(backend, key, [])
      [%{timer: timer}] = for {_, {:expiry, :cancelled, _, r}} <- state(host).jobs, do: r
      assert is_integer(Process.read_timer(timer))
      :sys.resume(backend)

      # The host has taken the job's :DOWN once its entry is gone; its bound timer then
      # becomes inactive (the host cancels it without waiting), long before the deadline.
      eventually(fn -> for({_, {:expiry, :cancelled, _, _}} <- state(host).jobs, do: 1) == [] end)
      refute Process.alive?(job)
      eventually(fn -> Process.read_timer(timer) == false end)
      assert now_ms() < deadline - 50_000
      assert :ok = RunHost.reap(host, :cancelled)
    end

    test "a reading job that gave its result and has not exited is still killed at the deadline at its start, also when a later reading moved the deadline (the result delivered by the test)" do
      env = memory()
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 2_000])
      key = "run/result-first"
      assert :ok = RunHost.start_run(host, :result_first, spec("result-first", stub([])))
      backend = Lease.Memory.owner(env.lease.backend)
      %{token: token, lease: %{deadline: deadline}} = run(host, :result_first)

      # A reading taken by the test 500 ms later (as an admission takes one), held.
      Process.sleep(500)
      {t0, later} = RunHost.lease_reading(env.lease, key, "node-a")

      # The job's reading blocks in the suspended backend; the test delivers a result under
      # its reference (a failed reading), so the host holds a result from a job that lives on.
      # Then the held reading moves the deadline 500 ms later.
      :sys.suspend(backend)
      send(host, {:expiry, :result_first, token, deadline})
      job = queued_reader!(backend, key, [])
      [ref] = for {ref, {:expiry, :result_first, _, _}} <- state(host).jobs, do: ref
      send(host, {ref, {:read, now_ms(), {:error, :injected}}})
      assert %{done: true, pid: ^job} = elem(state(host).jobs[ref], 3)
      assert :ok = GenServer.call(host, {:reading, :result_first, token, t0, later})
      assert %{lease: %{deadline: moved}} = run(host, :result_first)
      assert moved > deadline
      gone = Process.monitor(job)

      # The job is killed at the deadline at its start, while the Run still lives.
      assert_receive {:DOWN, ^gone, :process, ^job, :killed}, max(deadline - now_ms(), 0) + @timer
      assert now_ms() < moved
      assert %{phase: :live} = run(host, :result_first)
      :sys.resume(backend)
      assert :ok = RunHost.reap(host, :result_first)
    end

    test "a reading job whose bound fired is closed: a result that reaches the host after the bound is ignored (the result delivered by the test)" do
      env = memory()
      {host, _} = host(env, timed())
      key = "run/late-result"
      assert :ok = RunHost.start_run(host, :late_result, spec("late-result", stub([])))
      backend = Lease.Memory.owner(env.lease.backend)
      %{token: token, lease: %{deadline: deadline, seen: seen}} = run(host, :late_result)

      # A real reading taken by the test 2 s later on the lease clock: newer than the start's,
      # applied it would move the deadline about 2 s earlier.
      Lease.Clock.advance(env.clock, 2_000_000)
      {t0, read} = RunHost.lease_reading(env.lease, key, "node-a")

      # The job's reading blocks; with the host suspended, its bound (the host's own message)
      # and then that result under the job's reference reach the host in that order.
      :sys.suspend(backend)
      send(host, {:expiry, :late_result, token, deadline})
      job = queued_reader!(backend, key, [])
      [ref] = for {ref, {:expiry, :late_result, _, _}} <- state(host).jobs, do: ref
      gone = Process.monitor(job)
      :sys.suspend(host)
      send(host, {:read_bound, ref})
      send(host, {ref, {:read, t0, read}})
      :sys.resume(host)

      # The result is not applied: the deadline and the newest reading stay; the job is
      # killed, and its :DOWN counts as a failed reading.
      assert_receive {:DOWN, ^gone, :process, ^job, :killed}, 1_000
      assert %{lease: %{deadline: ^deadline, seen: ^seen}} = run(host, :late_result)
      :sys.resume(backend)
      assert :ok = RunHost.reap(host, :late_result)
    end

    test "an admission whose live status has no readable record admits nothing; one whose status shows this owner's lease past the last confirmed until is lost on that status alone" do
      key = "run/uncorrelated"
      {:ok, cell} = Agent.start_link(fn -> nil end)

      # A claim of another key makes the Store fail its next record read (set right before its
      # own append, which reads no records after it): queued behind a caller's status read,
      # it makes that caller's record read fail.
      hook = fn
        :before_write, %{key: "run/fail-next-head"} ->
          Memory.fault(Agent.get(cell, & &1), :read, :unavailable)

        _, _ ->
          :ok
      end

      env = memory(lease: [test_hook: hook])
      Agent.update(cell, fn _ -> env.store end)
      {host, _} = host(env, timed())
      spec = spec("uncorrelated", stub([]))
      assert :ok = RunHost.start_run(host, :uncorrelated, spec)
      backend = Lease.Memory.owner(env.lease.backend)

      input = fn ->
        :sys.suspend(backend)

        caller =
          Task.async(fn ->
            RunHost.input(host, :uncorrelated, "probe", message("probe"), verified(spec))
          end)

        eventually(fn -> caller.pid in queued_readers(backend, key) end)
        other = Task.async(fn -> Lease.claim(env.lease, "run/fail-next-head", "other", 1_000) end)
        other_pid = other.pid

        eventually(fn ->
          queued?(backend, &match?({:"$gen_call", {^other_pid, _}, {:single, _, _}}, &1))
        end)

        :sys.resume(backend)
        assert {:held, _} = Task.await(other)
        Task.await(caller, 10_000)
      end

      # This owner's live lease, its record unreadable: nothing is admitted, nothing lost.
      assert {:error, :unavailable} = input.()
      assert %{phase: :live, admission: :open} = run(host, :uncorrelated)

      # The same owner re-claims for 120 s, and the lease clock passes the host's last
      # confirmed until (60 s): the status alone shows the loss, and the admission makes no
      # record read (the Store fault armed behind it concerns a read that is not made).
      assert {:held, _} = Lease.claim(env.lease, key, "node-a", 120_000)
      Lease.Clock.advance(env.clock, 61_000_000)
      assert {:error, :lease_lost} = input.()
      assert_receive {:lost, :uncorrelated, :expired, _}, 3_000
      eventually(fn -> run(host, :uncorrelated) == nil end)
    end

    test "an admission whose status shows this owner's lease past the last confirmed until is lost on that status, with no record read" do
      key = "run/cutoff-first"
      env = memory()
      {host, _} = host(env, timed())
      spec = spec("cutoff-first", stub([]))
      assert :ok = RunHost.start_run(host, :cutoff_first, spec)

      # The same owner re-claims for 120 s and the lease clock passes the host's last
      # confirmed until (60 s): this owner's lease is active, by its own until.
      assert {:held, _} = Lease.claim(env.lease, key, "node-a", 120_000)
      Lease.Clock.advance(env.clock, 61_000_000)
      trace([{Lease, :status, 2}, {Lease, :retention_bound, 2}])

      caller =
        Task.async(fn ->
          RunHost.input(host, :cutoff_first, "probe", message("probe"), verified(spec))
        end)

      caller_pid = caller.pid
      assert {:error, :lease_lost} = Task.await(caller, 10_000)
      assert_receive {:lost, :cutoff_first, :expired, _}, 3_000
      assert_receive {:trace, ^caller_pid, :call, {Lease, :status, _}}, 1_000
      refute_receive {:trace, ^caller_pid, :call, {Lease, :retention_bound, _}}, 300
      eventually(fn -> run(host, :cutoff_first) == nil end)
    end

    test "an activation whose status shows this owner's lease past the host's confirmed until is denied and the Run lost on that status, with no record read" do
      key = "run/activation-cutoff"
      {:ok, armed} = Agent.start_link(fn -> true end)
      env = memory()

      # In the gate, after the caller's admission and before the call's intent asks for its
      # activation, the same owner re-claims for 120 s and the lease clock passes the host's
      # confirmed until (60 s).
      gate = fn _, _ ->
        if Agent.get_and_update(armed, &{&1, false}) do
          {:held, _} = Lease.claim(env.lease, key, "node-a", 120_000)
          Lease.Clock.advance(env.clock, 61_000_000)
        end

        :allow
      end

      {host, _} = host(env, timed())
      stub = stub([answer("never sent")])
      spec = spec("activation-cutoff", stub, gate: %{id: "gate", version: 1, call: gate})
      assert :ok = RunHost.start_run(host, :activation_cutoff, spec)
      trace([{Lease, :status, 2}, {Lease, :retention_bound, 2}])

      caller =
        Task.async(fn ->
          RunHost.input(host, :activation_cutoff, "start", start_input(), verified(spec))
        end)

      caller_pid = caller.pid
      assert_receive {:lost, :activation_cutoff, :expired, _}, 5_000
      _ = Task.await(caller, 10_000)
      eventually(fn -> run(host, :activation_cutoff) == nil end)
      assert requests(stub) == []

      # Every status read other than the caller's admission (the activation's) gave the
      # loss with no record read of its own.
      traces = drain_traces([])
      readers = for {:trace, pid, :call, {Lease, :status, _}} <- traces, pid != caller_pid, do: pid
      correlated = for {:trace, pid, :call, {Lease, :retention_bound, _}} <- traces, do: pid
      assert readers != []
      assert Enum.all?(readers, &(&1 not in correlated))
    end

    test "a claim whose first reading has no record has its confirmation phase bounded at once and is confirmed by the worker's next reading, with no input, so the idle Run is renewed and not lost" do
      test = self()
      key = "run/uncorrelated-claim"
      {:ok, cell} = Agent.start_link(fn -> %{store: nil, armed: true} end)

      # The claim's write suspends the backend right after it; a claim of another key makes
      # the Store fail its next record read.
      hook = fn
        :before_write, %{key: ^key, owner: backend} ->
          if Agent.get_and_update(cell, &{&1.armed, %{&1 | armed: false}}) do
            suspend_after_call(backend)
            send(test, {:claimed, backend})
          end

        :before_write, %{key: "run/fail-next"} ->
          Memory.fault(Agent.get(cell, & &1.store), :read, :unavailable)

        _, _ ->
          :ok
      end

      env = memory(lease: [test_hook: hook])
      Agent.update(cell, &%{&1 | store: env.store})
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 2_000])

      start =
        Task.async(fn ->
          RunHost.start_run(host, :claim_only, spec("uncorrelated-claim", stub([])))
        end)

      assert_receive {:claimed, backend}, 5_000

      # The worker's status read waits in the suspended backend, a claim that fails the next
      # record read behind it: the worker's reading has its status but no record.
      queued_reader!(backend, key, [])
      other = Task.async(fn -> Lease.claim(env.lease, "run/fail-next", "other", 1_000) end)
      other_pid = other.pid
      eventually(fn -> queued?(backend, &match?({:"$gen_call", {^other_pid, _}, _}, &1)) end)

      # The host already bounds the claim's confirmation, before that reading reaches it.
      assert %{lease: %{deadline: deadline, generation: nil}} = run(host, :claim_only)
      assert is_integer(deadline)

      # The host is suspended before the backend goes on: the worker's reading (its status,
      # no record) waits to reach it. The worker is suspended with that call queued, then the
      # host takes it and answers into the suspended worker's mailbox: `:pending`. Meanwhile
      # the start is not answered and no Run owner or engine has started.
      :sys.suspend(host)
      :sys.resume(backend)
      assert {:held, _} = Task.await(other)
      first_read = &match?({:runner, :claim_only, _, {:claim_read, _, {:ok, %{record: nil}}}}, &1)

      callers = fn ->
        for {:"$gen_call", {pid, _}, message} <- queued_messages(host),
            first_read.(message),
            do: pid
      end

      eventually(fn -> callers.() != [] end)
      [worker] = callers.()

      :erlang.suspend_process(worker)
      :sys.resume(host)
      eventually(fn -> queued?(worker, &match?({_, :pending}, &1)) end)
      assert Task.yield(start, 0) == nil
      assert %{phase: :starting, lease: %{generation: nil}, pids: pids} = run(host, :claim_only)
      refute Map.has_key?(pids, :owner) or Map.has_key?(pids, :engine)

      # The worker goes on with the backend suspended: after `:pending` it reads again, and
      # that second reading waits in the backend. Still the start is not answered, no Run
      # owner or engine has started and the claim is unconfirmed. Then the backend goes on
      # with the host suspended: the worker's second reading, correlated with the claim's
      # record, reaches the host, which confirms the claim on it; the start is answered.
      %{held: %{live: %{revision: claimed}}} = run(host, :claim_only)
      :sys.suspend(backend)
      :erlang.resume_process(worker)
      eventually(fn -> worker in queued_readers(backend, key) end)
      assert Task.yield(start, 0) == nil
      assert %{phase: :starting, lease: %{generation: nil}, pids: pids} = run(host, :claim_only)
      refute Map.has_key?(pids, :owner) or Map.has_key?(pids, :engine)
      :sys.suspend(host)
      :sys.resume(backend)

      second_read = fn message ->
        match?({:runner, :claim_only, _, {:claim_read, _, {:ok, %{record: ^claimed}}}}, message)
      end

      eventually(fn ->
        Enum.any?(queued_messages(host), fn
          {:"$gen_call", {^worker, _}, message} -> second_read.(message)
          _ -> false
        end)
      end)

      :sys.resume(host)
      assert :ok = Task.await(start, 10_000)

      # The worker's next reading confirms the claim before the start goes on, and the idle
      # Run is renewed past the confirmation bound, never lost.
      eventually(fn -> run(host, :claim_only).lease.generation != nil end)
      refute_receive {:lost, :claim_only, _, _}, max(deadline - now_ms(), 0) + 500
      assert renewals(env, spec("uncorrelated-claim", stub([]))) >= 1
      assert :ok = RunHost.reap(host, :claim_only)
    end

    test "a pending renewal whose reading has no record (its record read failed) is read again and confirmed more than a second before the deadline" do
      key = "run/record-failed"
      {:ok, cell} = Agent.start_link(fn -> %{store: nil, armed: false} end)

      hook = fn
        :before_write, %{key: ^key, owner: backend} ->
          if Agent.get_and_update(cell, &{&1.armed, %{&1 | armed: false}}),
            do: suspend_after_call(backend)

        :before_write, %{key: "run/fail-next"} ->
          Memory.fault(Agent.get(cell, & &1.store), :read, :unavailable)

        _, _ ->
          :ok
      end

      env = memory(lease: [test_hook: hook])
      Agent.update(cell, &%{&1 | store: env.store})
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
      spec = spec("record-failed", stub([]))
      assert :ok = RunHost.start_run(host, :record_failed, spec)
      backend = Lease.Memory.owner(env.lease.backend)
      %{lease: %{generation: first, deadline: deadline}} = run(host, :record_failed)
      Agent.update(cell, &%{&1 | armed: true})

      # The renewal (half the TTL in) commits and the backend suspends after it; the reading
      # that the pending renewal waits for queues, and behind it a claim that makes the next
      # record read fail: that reading has its status (after the reply) but no record.
      job = queued_reader!(backend, key, [])
      assert %{lease: %{pending: %{}}} = run(host, :record_failed)
      other = Task.async(fn -> Lease.claim(env.lease, "run/fail-next", "other", 1_000) end)
      other_pid = other.pid
      eventually(fn -> queued?(backend, &match?({:"$gen_call", {^other_pid, _}, _}, &1)) end)
      gone = Process.monitor(job)
      :sys.resume(backend)
      assert {:held, _} = Task.await(other)
      assert_receive {:DOWN, ^gone, :process, ^job, _}, 1_000

      # The next reading of the pending renewal (its retry configured 100 ms on) confirms it,
      # more than a second before the deadline (whose own expiry check is 200 ms before it).
      eventually(fn -> run(host, :record_failed).lease.generation != first end, 50)
      assert now_ms() < deadline - 1_000
      refute_received {:lost, :record_failed, _, _}
      assert :ok = RunHost.reap(host, :record_failed)
    end

    test "a pending renewal whose reading found the deadline past is read again when a reading taken before that deadline, and queued before its fence, moves it on, and is confirmed" do
      test = self()
      key = "run/revived"
      {cell, hook} = hold_after_commit(key, test)
      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
      spec = spec("revived", stub([]))
      assert :ok = RunHost.start_run(host, :revived, spec)

      %{token: token, pids: %{owner: owner}, lease: %{generation: first, deadline: a}} =
        run(host, :revived)

      # A reading of the claim's record taken by the test 250 ms later (before any reply), on
      # the lease clock that stands still: applied, it moves the deadline as far as its own
      # node time moved past the claim's reading, which the test bounds: 250 to 340 ms.
      Process.sleep(250)
      {t0, later} = RunHost.lease_reading(env.lease, key, "node-a")
      moved = t0 + 4_000
      assert moved >= a + 250 and moved < a + 340

      # The renewal commits, its reply held; then no reading succeeds and the owner replies:
      # the renewal is pending and its reading again fails every time (every 100 ms).
      Agent.update(cell, fn _ -> owner end)
      held!(owner)
      replied!(owner)
      Lease.Clock.fail(env.clock, true)
      :erlang.resume_process(owner)
      eventually(fn -> match?(%{pending: %{}, chase: {:timer, _}}, run(host, :revived).lease) end)
      %{lease: %{pending: %{record: record}}} = run(host, :revived)

      # 150 ms before the deadline the host is suspended while its obligation is a timer
      # (its received messages traced from then on); that real timer fires into its queue
      # before the deadline, and the held reading is delivered behind it, also before the
      # deadline. The deadline passes (its fence queues behind them); the lease can be read
      # again; the host resumes 150 ms after the deadline, when the moved deadline is less
      # than the expiry check's 200 ms ahead, so no ordinary check is armed for it.
      Process.sleep(max(a - 150 - now_ms(), 0))
      timer = suspend_on_chase_timer!(host, :revived)
      :erlang.trace(host, true, [:receive, {:tracer, self()}])
      eventually(fn -> Process.read_timer(timer) == false end, 20)
      assert queued?(host, &(&1 == {:expiry, :revived, token, {:pending, record}}))
      revive = admit(host, {:reading, :revived, token, t0, later})

      eventually(fn ->
        queued?(host, &match?({:"$gen_call", _, {:reading, :revived, _, _, _}}, &1))
      end)

      assert now_ms() < a
      Process.sleep(max(a + 150 - now_ms(), 0))
      Lease.Clock.fail(env.clock, false)
      backend = Lease.Memory.owner(env.lease.backend)
      :sys.suspend(backend)
      :sys.resume(host)

      # The real message finds the deadline past and clears the obligation. The held reading
      # was sampled before the deadline and reaches the host before its fence: it moves the
      # deadline on, the old fence does nothing, and the pending renewal's next reading is
      # dispatched at once. Every reading job waits in the suspended backend; every other
      # reader waiting there (an ordinary expiry check of the old deadline) is suspended
      # before the backend goes on, so it gives no result: the pending renewal's own reading
      # is the only one that reaches the host, and it confirms the renewal.
      assert :ok = Task.await(revive)

      eventually(fn ->
        Enum.any?(Map.values(state(host).jobs), &match?({:expiry, _, _, %{key: {:pending, _}}}, &1))
      end)

      [{chased, reader}] =
        for {ref, {:expiry, :revived, _, %{key: {:pending, ^record}, pid: pid}}} <-
              state(host).jobs,
            do: {ref, pid}

      eventually(fn -> reader in queued_readers(backend, key) end)
      others = for pid <- queued_readers(backend, key) -- [reader], held?(pid), do: pid
      :sys.resume(backend)
      eventually(fn -> run(host, :revived).lease.generation != first end)
      :erlang.trace(host, false, [:receive])
      delivered = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^delivered}, 1_000
      Enum.each(others, &unhold/1)
      received = for {:trace, ^host, :receive, m} <- drain_traces([]), do: m

      reading_at =
        Enum.find_index(received, &match?({:"$gen_call", _, {:reading, :revived, _, _, _}}, &1))

      after_reading = Enum.drop(received, reading_at + 1)
      assert {:expiry, :revived, token, {:pending, record}} in after_reading
      assert [_ | _] = results = for({ref, {:read, _, _}} <- after_reading, do: ref)
      assert Enum.all?(results, &(&1 == chased))
      refute_receive {:lost, :revived, _, _}, 500
      assert %{phase: :live} = run(host, :revived)
      assert :ok = RunHost.reap(host, :revived)
    end

    test "a renewal that the host takes only after its deadline passed starts nothing and is scheduled again when a reading taken before that deadline, queued before its fence, moves it on" do
      env = memory()
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
      key = "run/rearmed"
      assert :ok = RunHost.start_run(host, :rearmed, spec("rearmed", stub([])))

      %{token: token, pids: %{owner: owner}, lease: %{generation: first, deadline: a, due: due}} =
        run(host, :rearmed)

      # Every message that reaches the owner is traced with its arrival time on the node's
      # monotonic clock. The host is suspended before the real renewal timer fires: its
      # message queues.
      :erlang.trace(owner, true, [:receive, :monotonic_timestamp, {:tracer, self()}])
      Process.sleep(max(due - 100 - now_ms(), 0))
      :sys.suspend(host)
      eventually(fn -> queued?(host, &(&1 == {:renew, :rearmed, token, first, due})) end)

      # A second before the deadline the test's reading of the lease (the lease clock stands
      # still) is delivered behind it as an admission's call; the deadline passes (its fence
      # queues behind both) and the host resumes 100 ms after it.
      Process.sleep(max(a - 1_000 - now_ms(), 0))
      {t0, read} = RunHost.lease_reading(env.lease, key, "node-a")
      admission = admit(host, {:reading, :rearmed, token, t0, read})

      eventually(fn ->
        queued?(host, &match?({:"$gen_call", _, {:reading, :rearmed, _, _, _}}, &1))
      end)

      assert now_ms() < a
      Process.sleep(max(a + 100 - now_ms(), 0))
      :sys.resume(host)

      # The renewal message finds the deadline past and starts nothing; the reading moves the
      # deadline 4 s past its own node time and the renewal is scheduled again, half the TTL
      # before it: the first renewal call reaches the owner then (its traced arrival time),
      # and confirms.
      assert :ok = Task.await(admission)
      assert_receive {:trace_ts, ^owner, :receive, {:"$gen_call", _, {:renew, _}}, ts}, 3_000
      at = System.convert_time_unit(ts, :nanosecond, :millisecond)
      assert at >= t0 + 2_000
      assert at <= t0 + 2_000 + @timer
      :erlang.trace(owner, false, [:receive])
      eventually(fn -> run(host, :rearmed).lease.generation != first end)
      refute_received {:lost, :rearmed, _, _}
      assert :ok = RunHost.reap(host, :rearmed)
    end

    test "readings sampled after a deadline that an earlier queued reading put in place grant nothing, nor does that earlier one; the Run fenced (readings delivered by the test as admission and activation calls)" do
      env = memory()
      {host, _} = host(env, timed())
      key = "run/late-reading"
      assert :ok = RunHost.start_run(host, :late, spec("late-reading", stub([])))
      %{token: token} = run(host, :late)

      # The lease clock moves 59.9 s of the 60 s TTL. With the host suspended, the test's
      # reading with 100 ms left is delivered as an admission's call: it puts the deadline
      # 100 ms after its own node time.
      Lease.Clock.advance(env.clock, 59_900_000)
      :sys.suspend(host)
      {ta, short} = RunHost.lease_reading(env.lease, key, "node-a")
      first = admit(host, {:reading, :late, token, ta, short})

      eventually(fn ->
        queued?(host, &match?({:"$gen_call", _, {:reading, :late, _, _, _}}, &1))
      end)

      # After that deadline (on the still lease clock the lease is live), the test's next
      # reading, sampled after it, is delivered behind the first: as an admission's call and
      # as an activation's `:authorize` call.
      Process.sleep(max(ta + 150 - now_ms(), 0))
      {tb, late} = RunHost.lease_reading(env.lease, key, "node-a")
      assert {:ok, %{sampled_by: sampled_by}} = late
      assert sampled_by >= ta + 100
      second = admit(host, {:reading, :late, token, tb, late})
      activation = admit(host, {:authorize, :late, token, tb, late})

      eventually(fn ->
        messages = queued_messages(host)

        Enum.any?(messages, &match?({:"$gen_call", _, {:authorize, :late, _, _, _}}, &1)) and
          Enum.count(messages, &match?({:"$gen_call", _, {:reading, :late, _, _, _}}, &1)) == 2
      end)

      # The first reading is kept and leaves the deadline passed: it admits nothing either.
      :sys.resume(host)
      assert {:error, :unavailable} = Task.await(first)
      assert {:error, :unavailable} = Task.await(second)
      assert :denied = Task.await(activation)
      assert_receive {:lost, :late, :expired, _}, 1_000
    end

    test "a reading sampled before a deadline that an earlier queued, newer reading put in place grants nothing; the Run fenced (readings delivered by the test as admission and activation calls)" do
      env = memory()
      {host, _} = host(env, timed())
      key = "run/older-behind"
      assert :ok = RunHost.start_run(host, :older_behind, spec("older-behind", stub([])))
      %{token: token} = run(host, :older_behind)

      # An older reading (the test's, with the whole TTL left), then the lease clock moves
      # 59.9 s and a newer reading with 100 ms left. With the host suspended, the newer one is
      # delivered as an admission's call, then the older one behind it, as an admission's
      # and as an activation's call.
      {t_old, old} = RunHost.lease_reading(env.lease, key, "node-a")
      Lease.Clock.advance(env.clock, 59_900_000)
      {ta, short} = RunHost.lease_reading(env.lease, key, "node-a")
      assert {:ok, %{sampled_by: sampled_by}} = old
      assert sampled_by <= ta
      :sys.suspend(host)
      first = admit(host, {:reading, :older_behind, token, ta, short})

      eventually(fn ->
        queued?(host, &match?({:"$gen_call", _, {:reading, :older_behind, _, _, _}}, &1))
      end)

      second = admit(host, {:reading, :older_behind, token, t_old, old})
      activation = admit(host, {:authorize, :older_behind, token, t_old, old})

      eventually(fn ->
        messages = queued_messages(host)

        Enum.any?(messages, &match?({:"$gen_call", _, {:authorize, :older_behind, _, _, _}}, &1)) and
          Enum.count(messages, &match?({:"$gen_call", _, {:reading, :older_behind, _, _, _}}, &1)) ==
            2
      end)

      # The host resumes after the newer reading's deadline: that reading leaves it passed,
      # and the older one, taken before it, is kept but moves nothing (the newer one stays
      # the newest): neither admits, the activation is denied, and the fence loses the Run.
      Process.sleep(max(ta + 150 - now_ms(), 0))
      :sys.resume(host)
      assert {:error, :unavailable} = Task.await(second)
      assert :denied = Task.await(activation)
      assert {:error, :unavailable} = Task.await(first)
      assert_receive {:lost, :older_behind, :expired, _}, 1_000
    end

    test "a public input whose status read starts before a deadline that an earlier queued reading put in place and returns after it is not admitted and reaches no worker: the Run is fenced once the host resumes" do
      env = memory()
      {host, _} = host(env, timed())
      key = "run/straddling"
      spec = spec("straddling", stub([]))
      assert :ok = RunHost.start_run(host, :straddling, spec)
      %{token: token, pids: %{worker: worker}} = run(host, :straddling)
      backend = Lease.Memory.owner(env.lease.backend)

      # The lease clock moves 59.7 s of the 60 s TTL: the test's reading has 300 ms left,
      # so it would put the deadline 300 ms after its own node time (the cutoff).
      Lease.Clock.advance(env.clock, 59_700_000)
      {ta, short} = RunHost.lease_reading(env.lease, key, "node-a")
      cutoff = ta + 300

      # 200 ms later, before the cutoff, a public input takes its snapshot from the running
      # host and its status read waits in the suspended backend. Then the host is suspended
      # and the test's reading is delivered as an admission's call; the worker's received
      # messages are traced from here on.
      :sys.suspend(backend)
      Process.sleep(max(ta + 200 - now_ms(), 0))

      input =
        Task.async(fn ->
          RunHost.input(host, :straddling, "probe", message("probe"), verified(spec))
        end)

      eventually(fn -> input.pid in queued_readers(backend, key) end)
      assert now_ms() < cutoff
      :sys.suspend(host)
      :erlang.trace(worker, true, [:receive, {:tracer, self()}])
      first = admit(host, {:reading, :straddling, token, ta, short})

      eventually(fn ->
        queued?(host, &match?({:"$gen_call", _, {:reading, :straddling, _, _, _}}, &1))
      end)

      # The input's status read returns 50 ms after the cutoff (it sampled the lease clock
      # after it); its reading reaches the suspended host behind the test's.
      Process.sleep(max(cutoff + 50 - now_ms(), 0))
      :sys.resume(backend)

      eventually(fn ->
        Enum.any?(queued_messages(host), fn
          {:"$gen_call", {pid, _}, {:reading, :straddling, _, _, _}} -> pid == input.pid
          _ -> false
        end)
      end)

      # The test's reading leaves the deadline passed; the input's, sampled after it, is not
      # accepted: the input is answered {:error, :unavailable} and nothing of it reaches the
      # worker; the fence, already due, loses the Run once the host resumes.
      :sys.resume(host)
      assert {:error, :unavailable} = Task.await(input)
      assert {:error, :unavailable} = Task.await(first)
      assert_receive {:lost, :straddling, :expired, _}, 1_000
      :erlang.trace(worker, false, [:receive])
      input_pid = input.pid
      refute_received {:trace, ^worker, :receive, {:"$gen_call", {^input_pid, _}, _}}
    end

    test "a renewal stays pending after a newer short re-claim reading marked before the reply; only the older, longer reading taken after the reply confirms it (the short mark set by the test)" do
      test = self()
      key = "run/pending-longer"
      {cell, hook} = hold_after_commit(key, test)
      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
      assert :ok = RunHost.start_run(host, :pending_longer, spec("pending-longer", stub([])))

      %{token: token, pids: %{owner: owner}, lease: %{generation: first}} =
        run(host, :pending_longer)

      # The renewal commits, its reply held; a mark is taken before the owner replies (the
      # mark of a reader that took it then and read the Store later). No reading succeeds
      # from then on, except the test's two below.
      Agent.update(cell, fn _ -> owner end)
      held!(owner)
      replied!(owner)
      early = RunHost.mark()
      Lease.Clock.fail(env.clock, true)
      :erlang.resume_process(owner)
      eventually(fn -> run(host, :pending_longer).lease.pending != nil end)
      %{lease: %{pending: %{record: renewed, replied: replied}}} = run(host, :pending_longer)
      assert early < replied

      # With the host suspended, every reading task that it has dispatched is suspended too
      # (held until the end of the test's readings, so none gives a result meanwhile; new
      # ones read the failing clock): a reading of the renewal's record (after the reply,
      # the longer until), then a same-holder re-claim for 1 s and a reading of it (newer in
      # the Store), whose mark the test sets to the early one.
      :sys.suspend(host)

      held =
        for {:expiry, :pending_longer, _, %{pid: pid}} <- Map.values(state(host).jobs),
            held?(pid),
            do: pid

      Lease.Clock.fail(env.clock, false)
      {t1, long} = RunHost.lease_reading(env.lease, key, "node-a")
      assert {:ok, %{record: ^renewed, mark: long_mark}} = long
      assert long_mark > replied

      assert {:held, %{live: %{revision: reclaimed}}} =
               Lease.claim(env.lease, key, "node-a", 1_000)

      {t2, {:ok, short}} = RunHost.lease_reading(env.lease, key, "node-a")
      assert short.record == reclaimed
      Lease.Clock.fail(env.clock, true)
      short = {:ok, %{short | mark: early}}
      short_call = admit(host, {:reading, :pending_longer, token, t2, short})

      eventually(fn ->
        queued?(host, &match?({:"$gen_call", _, {:reading, :pending_longer, _, _, _}}, &1))
      end)

      :sys.resume(host)

      # The short reading is taken first: newest in the Store, it shortens the deadline, but
      # its mark is before the reply: the renewal is still pending.
      assert :ok = Task.await(short_call)

      assert %{lease: %{generation: ^first, pending: %{record: ^renewed}} = lease} =
               run(host, :pending_longer)

      assert lease.seen.record == reclaimed

      # The held older, longer reading confirms it; the deadline stays the re-claim's.
      assert :ok = GenServer.call(host, {:reading, :pending_longer, token, t1, long})

      assert %{lease: %{generation: second, pending: nil, record: ^renewed} = lease} =
               run(host, :pending_longer)

      assert second != first
      assert lease.seen.record == reclaimed
      assert lease.deadline <= t2 + 1_000
      Enum.each(held, &unhold/1)

      # The re-claim's until passes: the Run is lost (:expired).
      Lease.Clock.fail(env.clock, false)
      Lease.Clock.advance(env.clock, 1_500_000)
      assert_receive {:lost, :pending_longer, :expired, _}, 3_000
      eventually(fn -> run(host, :pending_longer) == nil end)
    end

    test "a claim whose first reading hangs, with no input or activation, is fenced at the bound of its confirmation and its reservation freed; its claimed lease is left in the Store until it expires there" do
      test = self()
      key = "run/hung-claim"
      {:ok, armed} = Agent.start_link(fn -> true end)

      hook = fn
        :before_write, %{key: ^key, owner: backend} ->
          if Agent.get_and_update(armed, &{&1, false}) do
            suspend_after_call(backend)
            send(test, {:claimed, backend})
          end

        _, _ ->
          :ok
      end

      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 2_000, max_runs: 1])
      started = now_ms()
      start = Task.async(fn -> RunHost.start_run(host, :hung, spec("hung-claim", stub([]))) end)
      assert_receive {:claimed, backend}, 5_000
      notified = now_ms()

      # The worker's status read waits in the suspended backend for good. The bound counts
      # from the host's receipt of the claim, which neither of the test's times observes:
      # `started` is taken before the test launches the task that calls the start,
      # `notified` when the test receives the notification sent from inside the claim's
      # write, and `lost_at` inside the `on_lost` callback, after the host fenced the Run.
      queued_reader!(backend, key, [])
      assert_receive {:lost, :hung, :expired, lost_at}, 4_000
      assert lost_at >= started + 2_000
      assert lost_at <= notified + 2_000 + @timer
      assert {:error, :lease_lost} = Task.await(start, 10_000)
      eventually(fn -> run(host, :hung) == nil end)
      assert state(host).runs == %{}

      # Nothing released the claim: once the backend goes on, the lease is still this owner's
      # in the Store (the lease clock stood still), another owner is refused, and it can claim
      # the key only after the lease clock passes the claim's until.
      :sys.resume(backend)
      assert {:ok, %{status: :active, holder: %{owner: "node-a"}}} = Lease.status(env.lease, key)
      assert {:lease_refused, _} = Lease.claim(env.lease, key, "node-b", 1_000)
      Lease.Clock.advance(env.clock, 2_000_000)
      assert {:held, _} = Lease.claim(env.lease, key, "node-b", 1_000)
    end

    test "a claim that a same-holder re-claim replaces before its first reading is lost (superseded), the start fails, and the newer record is not released" do
      test = self()
      key = "run/superseded-claim"
      {:ok, armed} = Agent.start_link(fn -> true end)

      # The worker's claim write waits inside the backend until the test lets it go.
      hook = fn
        :before_write, %{key: ^key} ->
          if Agent.get_and_update(armed, &{&1, false}) do
            send(test, {:claiming, self()})
            receive do: (:go -> :ok)
          end

        _, _ ->
          :ok
      end

      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 60_000])

      start =
        Task.async(fn ->
          RunHost.start_run(host, :superseded, spec("superseded-claim", stub([])))
        end)

      # The host is suspended before the claim returns: the worker's claim waits to reach
      # it, before the worker's first reading. Meanwhile the same owner re-claims the key
      # (another record).
      assert_receive {:claiming, backend}, 5_000
      :sys.suspend(host)
      send(backend, :go)

      eventually(fn ->
        queued?(host, &match?({:"$gen_call", _, {:runner, :superseded, _, {:held, _, _}}}, &1))
      end)

      assert {:held, %{live: %{revision: reclaimed}}} =
               Lease.claim(env.lease, key, "node-a", 60_000)

      :sys.resume(host)

      # The worker's first reading shows the newer record: the claim is lost, the start
      # fails with no Run owner started, and the newer record is still this owner's.
      assert {:error, :lease_lost} = Task.await(start, 10_000)
      assert_receive {:lost, :superseded, {:lease_lost, %{reason: :superseded}}, _}, 3_000
      eventually(fn -> run(host, :superseded) == nil end)
      assert state(host).runs == %{}

      assert {_, {:ok, %{status: :active, holder: %{owner: "node-a"}, record: ^reclaimed}}} =
               RunHost.lease_reading(env.lease, key, "node-a")
    end

    test "a public reap that joins the teardown of a start lost to a same-holder re-claim (its on_lost callback held) releases nothing: the newer record stays this owner's" do
      test = self()
      key = "run/superseded-reap"
      {:ok, armed} = Agent.start_link(fn -> true end)

      hook = fn
        :before_write, %{key: ^key} ->
          if Agent.get_and_update(armed, &{&1, false}) do
            send(test, {:claiming, self()})
            receive do: (:go -> :ok)
          end

        _, _ ->
          :ok
      end

      # The on_lost callback reports and then waits, holding the teardown open.
      on_lost = fn ref, reason ->
        send(test, {:lost, ref, reason, self()})
        receive do: (:go -> :ok)
      end

      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, on_lost: on_lost, lease_ttl_ms: 60_000)

      start =
        Task.async(fn ->
          RunHost.start_run(host, :superseded_reap, spec("superseded-reap", stub([])))
        end)

      # As above: the same owner re-claims the key while the worker's claim waits to reach
      # the suspended host.
      assert_receive {:claiming, backend}, 5_000
      :sys.suspend(host)
      send(backend, :go)

      eventually(fn ->
        queued?(host, &match?({:"$gen_call", _, {:runner, :superseded_reap, _, {:held, _, _}}}, &1))
      end)

      assert {:held, %{live: %{revision: reclaimed}}} =
               Lease.claim(env.lease, key, "node-a", 60_000)

      :sys.resume(host)

      # The start is lost (superseded); its on_lost callback is held, so the Run is still in
      # its teardown (reserved) when a public reap joins it; the reap stops the callback.
      assert_receive {:lost, :superseded_reap, {:lease_lost, %{reason: :superseded}}, callback},
                     3_000

      assert %{phase: phase, admission: :lease_lost} = run(host, :superseded_reap)
      assert phase in [:tearing_down, :awaiting]
      gone = Process.monitor(callback)
      reap = Task.async(fn -> RunHost.reap(host, :superseded_reap) end)
      assert_receive {:DOWN, ^gone, :process, ^callback, _}, 5_000

      # The reap and the start are answered, the slot freed, and nothing was released.
      assert :ok = Task.await(reap, 5_000)
      assert {:error, :lease_lost} = Task.await(start, 10_000)
      assert state(host).runs == %{}

      assert {_, {:ok, %{status: :active, holder: %{owner: "node-a"}, record: ^reclaimed}}} =
               RunHost.lease_reading(env.lease, key, "node-a")
    end

    test "a public reap that joins the teardown of a start whose claim confirmation hung (its on_lost callback held) releases nothing and answers while the backend still hangs" do
      test = self()
      key = "run/hung-reap"
      {:ok, armed} = Agent.start_link(fn -> true end)

      hook = fn
        :before_write, %{key: ^key, owner: backend} ->
          if Agent.get_and_update(armed, &{&1, false}) do
            suspend_after_call(backend)
            send(test, {:claimed, backend})
          end

        _, _ ->
          :ok
      end

      on_lost = fn ref, reason ->
        send(test, {:lost, ref, reason, self()})
        receive do: (:go -> :ok)
      end

      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, on_lost: on_lost, lease_ttl_ms: 2_000, max_runs: 1)
      start = Task.async(fn -> RunHost.start_run(host, :hung_reap, spec("hung-reap", stub([]))) end)
      assert_receive {:claimed, backend}, 5_000
      queued_reader!(backend, key, [])

      # The claim's confirmation bound passes with the worker's reading still in the
      # suspended backend: the start is lost (:expired). Its on_lost callback is held, so the
      # Run is still in its teardown when a public reap joins it; the reap stops the callback.
      assert_receive {:lost, :hung_reap, :expired, callback}, 4_000
      assert %{phase: phase, admission: :lease_lost} = run(host, :hung_reap)
      assert phase in [:tearing_down, :awaiting]
      gone = Process.monitor(callback)
      reap = Task.async(fn -> RunHost.reap(host, :hung_reap) end)
      assert_receive {:DOWN, ^gone, :process, ^callback, _}, 5_000

      # With the backend still suspended, the reap and the start are answered and the slot
      # freed (no release waits in the backend).
      assert :ok = Task.await(reap, 5_000)
      assert {:error, :lease_lost} = Task.await(start, 10_000)
      assert state(host).runs == %{}
      assert {:status, _, _, [_, :suspended | _]} = :sys.get_status(backend)

      # Once the backend goes on, the claimed lease is still this owner's and active.
      :sys.resume(backend)
      assert {:ok, %{status: :active, holder: %{owner: "node-a"}}} = Lease.status(env.lease, key)
    end

    test "an activation's loss judged against an older confirmed until is not applied once a newer generation is confirmed: the host denies it and keeps the Run (the reading delivered by the test)" do
      env = memory()
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
      key = "run/stale-activation"
      assert :ok = RunHost.start_run(host, :stale_activation, spec("stale-activation", stub([])))
      %{token: token, lease: %{generation: first, until: older}} = run(host, :stale_activation)

      # The lease clock moves 2 s, so the renewal (half the TTL in) confirms an until 2 s
      # past the claim's.
      Lease.Clock.advance(env.clock, 2_000_000)
      eventually(fn -> run(host, :stale_activation).lease.generation != first end)
      %{lease: %{until: newer}} = run(host, :stale_activation)
      assert newer > older

      # A status at lease time 0.5 s past the older until, judged against it (the cutoff that
      # an activation would have taken under the first generation): a loss for that until.
      Lease.Clock.advance(env.clock, older - elem(Lease.Clock.sample(env.clock), 1) + 500_000)
      {t0, read} = RunHost.lease_reading(env.lease, key, "node-a", older)
      assert {:ok, %{record: nil}} = read

      # The host judges it against the newer confirmed until: no loss, no grant.
      assert :denied = GenServer.call(host, {:authorize, :stale_activation, token, t0, read})
      refute_receive {:lost, :stale_activation, _, _}, 300
      assert %{phase: :live, admission: :open} = run(host, :stale_activation)
      assert :ok = RunHost.reap(host, :stale_activation)
    end

    test "an older, longer reading taken after the reply that reaches the host after a newer reading of a shorter re-claim leaves the shorter deadline and renews no re-claim" do
      test = self()
      key = "run/older-longer"
      {cell, hook} = hold_after_commit(key, test)
      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
      spec = spec("older-longer", stub([]))
      assert :ok = RunHost.start_run(host, :older_longer, spec)

      %{token: token, pids: %{owner: owner}, lease: %{generation: first}} =
        run(host, :older_longer)

      # The renewal commits, its reply held; no reading succeeds while the owner replies.
      Agent.update(cell, fn _ -> owner end)
      held!(owner)
      replied!(owner)
      Lease.Clock.fail(env.clock, true)
      :erlang.resume_process(owner)
      eventually(fn -> run(host, :older_longer).lease.pending != nil end)

      # With the host suspended: a reading of the renewal's record (after the reply, the
      # longer until), then a same-holder re-claim for 1 s and a reading of it (newer in the
      # Store, shorter). The newer one reaches the host first, the older one after it.
      :sys.suspend(host)
      Lease.Clock.fail(env.clock, false)
      {t1, long} = RunHost.lease_reading(env.lease, key, "node-a")

      assert {:held, %{live: %{revision: reclaimed, until: cut}}} =
               Lease.claim(env.lease, key, "node-a", 1_000)

      {t2, short} = RunHost.lease_reading(env.lease, key, "node-a")
      # Both delivered as admissions' calls, the short one queued at the host before the
      # long one is sent, and both queued before the host resumes.
      reading_calls = fn ->
        for {:"$gen_call", _, {:reading, :older_longer, _, t, _}} <- queued_messages(host), do: t
      end

      short_call = admit(host, {:reading, :older_longer, token, t2, short})
      eventually(fn -> reading_calls.() == [t2] end)
      long_call = admit(host, {:reading, :older_longer, token, t1, long})
      eventually(fn -> reading_calls.() == [t2, t1] end)
      :sys.resume(host)
      assert :ok = Task.await(short_call)
      assert :ok = Task.await(long_call)

      # The renewal is confirmed, the newest reading is the re-claim's, and the deadline is
      # its 1 s, not the renewal's 4 s.
      assert %{lease: %{generation: second, seen: seen, deadline: short_deadline}} =
               run(host, :older_longer)

      assert second != first
      assert seen.record == reclaimed and seen.until == cut
      assert short_deadline <= now_ms() + 1_000

      # The re-claim's until passes: the Run is lost (:expired), and no renewal of the
      # re-claim's record was made.
      Lease.Clock.advance(env.clock, 1_500_000)
      assert_receive {:lost, :older_longer, :expired, _}, 3_000
      eventually(fn -> run(host, :older_longer) == nil end)
      assert renewals(env, spec) == 1
    end

    test "a no-write retry already queued when a reading leaves less than its delay finds the deadline past: no renewal is started, the Run is lost (:expired) (the error delivered by the test)" do
      env = memory()
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 2_400])
      spec = spec("queued-retry", stub([]))
      assert :ok = RunHost.start_run(host, :queued_retry, spec)
      %{token: token, pids: %{owner: owner}} = run(host, :queued_retry)

      # The first renewal waits in the suspended owner; every renewal call that reaches the
      # owner is traced.
      :erlang.suspend_process(owner)
      :erlang.trace(owner, true, [:receive, {:tracer, self()}])
      assert_receive {:trace, ^owner, :receive, {:"$gen_call", _, {:renew, _}}}, 5_000

      # The renewal's result is a definite no-write error (delivered by the test): the retry
      # is due 200 ms later. The test's reading with 100 ms left on the lease clock (moved
      # 2.3 s) is delivered as an admission's call to the suspended host; the order in which
      # the host receives it and the retry's message is traced, not timed. The host's
      # received messages and every call of RunHost.renewal/2 (by any process) are traced
      # from here on.
      [job] = for {ref, {:renew, :queued_retry, _, _}} <- state(host).jobs, do: ref
      send(host, {job, {:error, :contended}})
      %{lease: %{floor: floor}} = run(host, :queued_retry)
      Lease.Clock.advance(env.clock, 2_300_000)
      {t0, read} = RunHost.lease_reading(env.lease, "run/queued-retry", "node-a")
      # (renewal/2 is called locally inside the job's function: a local trace pattern)
      trace([{RunHost, :renewal, 2}])
      :erlang.trace_pattern({RunHost, :renewal, 2}, true, [:local])
      on_exit(fn -> :erlang.trace_pattern({RunHost, :renewal, 2}, false, [:local]) end)
      :sys.suspend(host)
      assert now_ms() < floor
      :erlang.trace(host, true, [:receive, {:tracer, self()}])
      shorten = admit(host, {:reading, :queued_retry, token, t0, read})
      Process.sleep(max(floor - now_ms(), 0) + 50)
      :sys.resume(host)

      # The reading is applied first and leaves the deadline past, so it admits nothing; the
      # retry's message, which the host takes after it, starts no renewal; the fence loses
      # the Run.
      assert {:error, :unavailable} = Task.await(shorten)
      assert_receive {:lost, :queued_retry, :expired, _}, 1_000
      eventually(fn -> run(host, :queued_retry) == nil end)
      :erlang.trace(host, false, [:receive])
      delivered = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^delivered}, 1_000
      traces = drain_traces([])
      received = for {:trace, ^host, :receive, m} <- traces, do: m

      reading_at =
        Enum.find_index(
          received,
          &match?({:"$gen_call", _, {:reading, :queued_retry, _, _, _}}, &1)
        )

      retry_at = Enum.find_index(received, &match?({:renew, :queued_retry, _, _, ^floor}, &1))
      assert is_integer(reading_at) and is_integer(retry_at) and reading_at < retry_at
      assert for({:trace, _, :call, {RunHost, :renewal, _}} = t <- traces, do: t) == []

      assert for({:trace, ^owner, :receive, {:"$gen_call", _, {:renew, _}}} = t <- traces, do: t) ==
               []

      # The teardown ended the suspended owner.
      refute Process.alive?(owner)
    end

    test "a renewal not started yet whose deadline a newer reading of the confirmed record shortens: the renewal moves to that deadline, once, and the Run is not fenced" do
      test = self()
      key = "run/moved-renewal"
      {:ok, armed} = Agent.start_link(fn -> false end)

      hook = fn
        :before_lock, %{key: ^key} -> if Agent.get(armed, & &1), do: send(test, :locking)
        _, _ -> :ok
      end

      env = memory(lease: [test_hook: hook])
      {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
      spec = spec("moved-renewal", stub([]))
      assert :ok = RunHost.start_run(host, :moved_renewal, spec)
      %{lease: %{generation: first}} = run(host, :moved_renewal)

      # The lease clock moves 2 s before the renewal, which commits an until 6 s after the
      # claim's lease time; the host's reading after the reply (lease time + 2 s) confirms
      # it, and the next renewal is due 2 s after that reading.
      Lease.Clock.advance(env.clock, 2_000_000)
      Agent.update(armed, fn _ -> true end)
      assert_receive :locking, 5_000
      eventually(fn -> run(host, :moved_renewal).lease.generation != first end)

      %{token: token, lease: %{generation: second, due: due, deadline: deadline}} =
        run(host, :moved_renewal)

      assert due > now_ms() + 1_000
      refute_received :locking

      # An expiry check of that deadline (the host's own message, sent by the test) samples
      # lease time + 5.5 s on the same record: live, 500 ms before its until, so the deadline
      # moves 500 ms after that reading, and the renewal with it: it starts at once, once,
      # and is confirmed before that deadline.
      Lease.Clock.advance(env.clock, 3_500_000)
      send(host, {:expiry, :moved_renewal, token, deadline})
      assert_receive :locking, 1_000
      eventually(fn -> run(host, :moved_renewal).lease.generation not in [first, second] end)
      refute_received :locking
      refute_received {:lost, :moved_renewal, _, _}
      assert renewals(env, spec) == 2
      assert %{phase: :live} = run(host, :moved_renewal)
      Agent.update(armed, fn _ -> false end)
      assert :ok = RunHost.reap(host, :moved_renewal)
    end

    test "the several-TTL report keeps its observations when its renewal count cannot be read" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, _, _, _}

      c = %{
        host: dead,
        env: %{kind: :postgres, prefix: "elz421_missing_schema"},
        spec: %{unit: "missing"},
        started: now_ms(),
        roles: %{}
      }

      error =
        assert_raise ExUnit.AssertionError, fn ->
          progress!("message-1", {:error, :unavailable}, c)
        end

      assert error.message =~ "message-1 at +"
      assert error.message =~ "{:error, :unavailable}"
      assert error.message =~ "host (run, recorded loss): {:host_unreadable, :exit}"
      assert error.message =~ "renewals committed: {:unreadable, "
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

  # A renewal and a same-holder re-claim that shortens the lease (Memory, a 4 s TTL, a lease
  # clock that only the test moves), applied in a fixed order. `:reading_first`: the renewal
  # commits and its reply is held in the suspended owner; the re-claim (1 s) commits, and an
  # expiry check of the current deadline (the host's own message, sent by the test) reads
  # the re-claim's record before the reply, so it shortens the deadline and confirms nothing;
  # then the owner replies and the host's reading after the reply confirms the renewal.
  # `:confirmation_first`: the renewal is confirmed first; then the re-claim commits and the
  # expiry check's reading shortens the deadline.
  defp shortened!(order) do
    test = self()
    name = "shortened-#{order}"
    key = "run/" <> name
    ref = String.to_atom(name)
    {cell, hook} = hold_after_commit(key, test)
    env = memory(lease: [test_hook: hook])
    {host, _} = host(env, timed() ++ [lease_ttl_ms: 4_000])
    spec = spec(name, stub([]))
    assert :ok = RunHost.start_run(host, ref, spec)
    %{token: token, pids: %{owner: owner}, lease: %{generation: first}} = run(host, ref)
    {:ok, lease_now} = Lease.Clock.sample(env.clock)
    cut = lease_now + 1_000_000
    confirmed? = fn -> run(host, ref).lease.generation != first end
    shortened? = fn -> run(host, ref).lease.seen.until == cut end

    reclaim_and_check = fn ->
      assert {:held, %{live: %{until: ^cut}}} = Lease.claim(env.lease, key, "node-a", 1_000)
      checked = now_ms()
      send(host, {:expiry, ref, token, run(host, ref).lease.deadline})
      checked
    end

    checked =
      if order == :reading_first do
        Agent.update(cell, fn _ -> owner end)
        held!(owner)
        replied!(owner)
        checked = reclaim_and_check.()
        eventually(shortened?)
        refute confirmed?.()
        :erlang.resume_process(owner)
        checked
      else
        eventually(confirmed?)
        refute shortened?.()
        reclaim_and_check.()
      end

    eventually(fn -> confirmed?.() and shortened?.() end)
    applied = now_ms()

    # Both are applied, in either order: the renewal's until is the last confirmed one, the
    # newest reading shows the re-claim's, and the deadline is the re-claim's, 1 s after the
    # node time of a reading taken after `checked` and before `applied`, on the lease clock
    # that stood still.
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

  # A Memory Lease hook for the writes of `key`: once the cell holds the Run owner's pid, the
  # next write waits in the backend until the test has suspended that owner (held!/1), and
  # is then committed, so its reply waits in the suspended owner and the renewal job has no
  # reply yet.
  defp hold_after_commit(key, test) do
    {:ok, cell} = Agent.start_link(fn -> nil end)

    hook = fn
      :before_write, %{key: ^key} ->
        case Agent.get_and_update(cell, &{&1, nil}) do
          nil ->
            :ok

          owner ->
            send(test, {:held_after_commit, owner, self()})
            receive do: (:held -> :ok)
        end

      _, _ ->
        :ok
    end

    {cell, hook}
  end

  # The test suspends the owner whose write waits in the backend, then lets the write go on.
  defp held!(owner) do
    assert_receive {:held_after_commit, ^owner, backend}, 5_000
    :erlang.suspend_process(owner)
    send(backend, :held)
  end

  # The held owner's write has committed: its reply is in the owner's queue.
  defp replied!(owner) do
    eventually(fn ->
      match?({:message_queue_len, n} when n > 0, Process.info(owner, :message_queue_len))
    end)
  end

  # Called inside the Memory Lease backend during a call: the backend suspends right after
  # that call, before it takes the next one from its queue.
  defp suspend_after_call(backend) do
    spawn(fn -> :sys.suspend(backend, :infinity) end)
    eventually(fn -> queued?(backend, &match?({:system, _, :suspend}, &1)) end)
  end

  # An admission's call with its reading, made from its own process (the host may be
  # suspended): awaited for the host's reply.
  defp admit(host, message), do: Task.async(fn -> GenServer.call(host, message) end)

  # Suspends a process that may have ended meanwhile: whether it was suspended.
  defp held?(pid) do
    :erlang.suspend_process(pid)
  rescue
    ArgumentError -> false
  end

  defp unhold(pid) do
    :erlang.resume_process(pid)
  rescue
    ArgumentError -> false
  end

  defp queued_messages(pid) do
    {:messages, messages} = Process.info(pid, :messages)
    messages
  end

  # Suspends the host while its pending renewal's reading is a timer (not a running job):
  # when it is a job, the host goes on a moment and is suspended again, a bounded number
  # of times. Returns that timer.
  defp suspend_on_chase_timer!(host, ref, tries \\ 50) do
    :sys.suspend(host)

    case state(host).runs[ref].lease.chase do
      {:timer, timer} ->
        timer

      _ when tries > 0 ->
        :sys.resume(host)
        Process.sleep(5)
        suspend_on_chase_timer!(host, ref, tries - 1)
    end
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

  # The trace messages received so far (spawn and call traces), in order.
  defp drain_traces(acc) do
    receive do
      {:trace, _, _, _} = m -> drain_traces([m | acc])
      {:trace, _, _, _, _} = m -> drain_traces([m | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The generations that the host confirmed for a Run (the claim's, then one per renewal),
  # sampled every 20 ms until asked.
  defp generations(host, ref, seen) do
    receive do
      {:generations, to} -> send(to, {:generations, seen})
    after
      20 ->
        seen =
          case run(host, ref) do
            %{lease: %{generation: generation}} when generation != nil ->
              MapSet.put(seen, generation)

            _ ->
              seen
          end

        generations(host, ref, seen)
    end
  end

  # A step of a Run that should still be live: one that is not applied fails the test with
  # what explains it, and no Store data: the node time since the start, the callbacks and
  # the exits of the Run's processes that the test received (the shape of each reason), the
  # host's lease state of the Run and its recorded loss, and the count of committed renewals.
  defp progress!(_, {:ok, :applied}, _), do: :ok

  defp progress!(step, reply, c) do
    elapsed = now_ms() - c.started
    Process.sleep(200)

    received =
      for message <- drain([]) do
        case message do
          {:DOWN, ref, :process, _, reason} -> {:exit, c.roles[ref], shape(reason, 4)}
          {tag, _, reason} -> {tag, shape(reason, 4)}
          {tag, _, reason, at} -> {tag, shape(reason, 4), at - c.started}
        end
      end

    host =
      try do
        s = state(c.host)
        {lease_summary(s.runs[:renewed]), shape(s.lost[:renewed], 4)}
      catch
        kind, _ -> {:host_unreadable, kind}
      end

    # Best effort: a count that cannot be read leaves every observation above in the report.
    renewals =
      try do
        renewals(c.env, c.spec)
      rescue
        e -> {:unreadable, e.__struct__}
      catch
        kind, _ -> {:unreadable, kind}
      end

    flunk("""
    #{step} at +#{elapsed} ms gave #{inspect(shape(reply, 4))}
    received: #{inspect(received)}
    host (run, recorded loss): #{inspect(host)}
    renewals committed: #{inspect(renewals)}
    """)
  end

  defp drain(acc) do
    receive do
      {:DOWN, _, :process, _, _} = m -> drain([m | acc])
      {tag, _, _} = m when tag in [:lost, :terminal] -> drain([m | acc])
      {tag, _, _, _} = m when tag in [:lost, :terminal] -> drain([m | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp lease_summary(nil), do: nil

  defp lease_summary(%{phase: phase, admission: admission, lease: l}) do
    now = now_ms()

    %{
      phase: phase,
      admission: admission,
      deadline_in_ms: l && l.deadline && l.deadline - now,
      renewal_due_in_ms: l && l.due && l.due - now,
      renewing: l && l.renewing,
      pending: l && l.pending != nil,
      confirmed_left_ms: l && l.seen && div(l.until - l.seen.now, 1_000),
      seen_left_ms: l && l.seen && div(l.seen.until - l.seen.now, 1_000),
      same_record: l && l.seen && l.seen.record == l.record
    }
  end

  # The structure of a term, with its atoms and integers, and no text, map values or list
  # elements.
  defp shape(_, 0), do: :...
  defp shape(term, _) when is_atom(term) or is_integer(term), do: term

  defp shape(term, depth) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&shape(&1, depth - 1)) |> List.to_tuple()

  defp shape(term, _) when is_binary(term), do: {:binary, byte_size(term)}
  defp shape(term, _) when is_list(term), do: {:list, length(term)}
  defp shape(term, _) when is_map(term), do: {:map, term |> Map.keys() |> Enum.filter(&is_atom/1)}
  defp shape(term, _) when is_pid(term), do: :pid
  defp shape(_, _), do: :other

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
