# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_host_test_helper.exs", __DIR__)

defmodule Elzoo.RunHostTimeTest do
  # Deadline wakes and lease renewal and expiry, on disposable PostgreSQL with the
  # trusted engine clock of the node (Unix milliseconds) and the store clock of the
  # lease, and on Memory with a manual lease clock moved independently.
  use ExUnit.Case, async: false
  import Elzoo.RunHost.TestHelper
  alias Elzoo.{Lease, RunEngine, RunHost}
  alias Elzoo.RunApprovalRelease, as: Owner
  alias Elzoo.EffectIntent.Model
  alias Elzoo.RunHost.Ai

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
    test "an engine read that ends by the call limit decides nothing: a due wake waits for a readable deadline, an input for a confirmed Attempt" do
      env = postgres()

      stub =
        stub(fn
          "call m1" -> answer("old Attempt")
          "call m2" -> answer("new Attempt")
        end)

      {host, _} = host(env, notify())
      trace([{RunEngine, :deadlines, 1}, {RunEngine, :input, 4}])

      # A: an idle Run whose engine is held across its deadline, once its timer is set.
      deadline = clock() + 3_000
      unread = spec("unread", stub([]), run_deadline: deadline)
      assert :ok = RunHost.start_run(host, :unread, unread)
      %{worker: worker_a, pids: %{engine: engine_a}} = run(host, :unread)
      eventually(fn -> :sys.get_state(worker_a).timer != nil end)
      :sys.suspend(engine_a)

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

      # Both reads end by the engine's 60 s call limit.
      assert_receive {:trace, ^worker_b, :exception_from, {RunEngine, :deadlines, 1}, _}, 75_000
      assert_receive {:trace, ^worker_a, :exception_from, {RunEngine, :deadlines, 1}, _}, 10_000

      # B: the input that comes at once is forwarded only after a read confirms the new
      # Attempt, so its model call's key is the new Attempt's and its outcome routes.
      :sys.resume(engine_b)
      second = %{confirm | attempt_id: "second"}

      assert {:ok, :applied} =
               RunHost.input(host, :confirm, "start-2", start_input(), verified(second))

      assert {:ok, :applied} = Task.await(control)
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
      {host, _} = host(env, notify() ++ [lease_ttl_ms: 1_000])
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

      # The renewal is confirmed with a later until; the lease clock then passes the first.
      Lease.Clock.advance(env.clock, 400_000)
      eventually(fn -> run(host, :snapshot).lease.generation != first end)
      assert run(host, :snapshot).lease.until > until
      Lease.Clock.advance(env.clock, 700_000)
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

    test "a renewal confirmed after the last confirmed until and taken before the expiry check's reading loses the Run (:expired)" do
      test = self()
      {:ok, delay} = Agent.start_link(fn -> false end)

      # The renewal commits; its reply comes 1.5 s later, past the last confirmed until
      # (a TTL of 2 s, renewed at half of it) but well within the 5 s caller limit.
      hook = fn
        :after_commit, %{key: "run/late"} ->
          if Agent.get_and_update(delay, &{&1, false}) do
            send(test, :renewal_committed)
            Process.sleep(1_500)
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {host, _} = host(env, notify() ++ [lease_ttl_ms: 2_000])
      spec = spec("late", stub([]))
      assert :ok = RunHost.start_run(host, :late, spec)
      Agent.update(delay, fn _ -> true end)
      assert_receive :renewal_committed, 5_000

      # The host takes the expiry check (due at the last confirmed until) and then the
      # renewal's late result, before the expiry check's own reading comes back.
      :sys.suspend(host)

      eventually(
        fn ->
          {:messages, messages} = Process.info(host, :messages)

          Enum.any?(messages, &match?({:expiry, :late, _, _}, &1)) and
            Enum.any?(messages, &match?({ref, {:renewed, _, _, _}} when is_reference(ref), &1))
        end,
        600
      )

      :sys.resume(host)
      assert_receive {:lost, :late, :expired}, 5_000

      assert {:error, :lease_lost} =
               RunHost.input(host, :late, "late", start_input(), verified(spec))

      eventually(fn -> run(host, :late) == nil end)
      refute_received {:lost, :late, _}
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
      Agent.update(cell, fn _ -> spawned() end)
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
      Agent.update(hold, fn _ -> true end)
      assert_receive {:renewing, owner}, 5_000

      # The owner answers an indeterminate renewal as it stops, so its own exit reaches
      # the host before the renewal task's result. The test delivers that result first,
      # under the renewal job's reference, as the task delivers it: an indeterminate
      # receipt (for a write that a later record superseded) while the owner still runs.
      [job] = for {ref, {:renew, :first, _, _}} <- state(host).jobs, do: ref
      receipt = %{stream: "run/first", expected: 1, nonce: :crypto.strong_rand_bytes(16), records: [:renewal]}
      send(host, {job, {:indeterminate, receipt}})

      assert_receive {:lost, :first, {:indeterminate, ^receipt}}, 5_000
      eventually(fn -> run(host, :first) == nil end)
      refute Process.alive?(owner)
      refute_receive {:lost, :first, _}, 300
      assert state(host).receipts == %{first: receipt}

      trace([{Owner, :start_link, 1}])
      Agent.update(cell, fn _ -> spawned() end)
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
      Agent.update(cell, fn _ -> spawned() end)
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

    test "a reap waits for the Run's renewal job before it frees the reservation" do
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
      {host, _} = host(env, lease_ttl_ms: 2_000)
      spec = spec("awaited", stub([]))
      assert :ok = RunHost.start_run(host, :awaited, spec)
      Agent.update(hold, fn _ -> true end)
      assert_receive {:renewing, owner}, 5_000

      # The renewal job (the host's only task now) is held.
      [job] = Task.Supervisor.children(state(host).tasks)
      :erlang.suspend_process(job)
      reap = Task.async(fn -> RunHost.reap(host, :awaited) end)

      # Every process of the Run is gone; the reservation stays while the job runs.
      eventually(fn -> match?(%{phase: :awaiting}, run(host, :awaited)) end)
      refute Process.alive?(owner)
      assert Task.yield(reap, 300) == nil
      :erlang.resume_process(job)
      assert :ok = Task.await(reap)
      refute Process.alive?(job)
      assert run(host, :awaited) == nil
    end
  end

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
