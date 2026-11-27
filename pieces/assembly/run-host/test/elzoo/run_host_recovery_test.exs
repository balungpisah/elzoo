# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_host_test_helper.exs", __DIR__)

defmodule Elzoo.RunHostRecoveryTest do
  # Recovery, predecessor fencing, routing at startup, teardown and lease refusals, on
  # disposable PostgreSQL (two scenarios on Memory). A host "on another node" is a host
  # started under its own group leader in this VM: the test stops every process whose
  # group-leader chain reaches it, independently of the host's own tracking.
  use ExUnit.Case, async: false
  import Elzoo.RunHost.TestHelper
  alias Elzoo.{DynamicUnits, Lease, RunEngine, RunHost}
  alias Elzoo.RunApprovalRelease, as: Owner
  alias Elzoo.DurableLog.{Memory, PostgresHarness}

  setup_all do
    repo = database()
    on_exit(fn -> if Process.alive?(repo), do: Supervisor.stop(repo) end)
    load_model_catalog()
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "crash_and_wake" do
    test "same node: after confirmed teardown the call is lost_outcome, never resent, and the Run fails" do
      env = postgres()
      stub = stub([{:block, answer("never delivered")}])
      {host, specs} = host(env, notify())
      spec = spec("crash", stub)
      remember(specs, :crash, spec)

      assert :ok = RunHost.start_run(host, :crash, spec)
      assert {:ok, :applied} = RunHost.input(host, :crash, "start", start_input(), verified(spec))
      assert_receive {:stub_entered, stub_task}, 5_000

      %{pids: %{engine: engine}} = run(host, :crash)
      Process.exit(engine, :kill)
      eventually(fn -> run(host, :crash) == nil end)
      refute Process.alive?(stub_task)
      assert state(host).markers[:crash]

      assert [crash: :woken] = RunHost.wake(host, [:crash])
      assert_receive {:terminal, :crash, :failed}, 5_000
      lost_outcome!(host, :crash, spec)
      assert length(requests(stub)) == 1
    end

    test "another node: a takeover after lease expiry with demonstrated fencing settles lost_outcome once" do
      env = postgres()
      stub = stub([{:block, answer("never delivered")}])
      specs = specs()
      spec = spec("remote", stub)
      remember(specs, :remote, spec)
      leader = node_leader()
      {host_a, _} = host_on_node(leader, env, specs: specs, owner_id: "node-a", lease_ttl_ms: 1_000)

      assert :ok = RunHost.start_run(host_a, :remote, spec)

      assert {:ok, :applied} =
               RunHost.input(host_a, :remote, "start", start_input(), verified(spec))

      assert_receive {:stub_entered, stub_task}, 5_000
      :erlang.suspend_process(host_a)
      stale!(env, spec)

      proof = fn :remote ->
        assert :ok = fence_node(leader)
        refute Process.alive?(stub_task)
        :fenced
      end

      {host_b, _} = host(env, notify() ++ [specs: specs, owner_id: "node-b", fencing_proof: proof])
      assert [remote: :woken] = RunHost.wake(host_b, [:remote])
      assert node_processes(leader) == []
      assert_receive {:terminal, :remote, :failed}, 5_000
      lost_outcome!(host_b, :remote, spec)
      assert length(requests(stub)) == 1
    end

    test "lease expiry alone, with no proof: fencing_unproven, no engine, no activation granted and no new send" do
      env = postgres()
      stub = stub([{:block, answer("never delivered")}])
      specs = specs()
      spec = spec("expired", stub)
      remember(specs, :expired, spec)
      leader = node_leader()
      {host_a, _} = host_on_node(leader, env, specs: specs, owner_id: "node-a", lease_ttl_ms: 1_000)

      assert :ok = RunHost.start_run(host_a, :expired, spec)

      assert {:ok, :applied} =
               RunHost.input(host_a, :expired, "start", start_input(), verified(spec))

      assert_receive {:stub_entered, _}, 5_000
      :erlang.suspend_process(host_a)
      stale!(env, spec)
      activations = count_rows(env, "intent-host/%")

      {host_b, _} = host(env, specs: specs, owner_id: "node-b")
      trace([{RunEngine, :start_link, 1}])
      assert [expired: {:error, :fencing_unproven}] = RunHost.wake(host_b, [:expired])
      # The refused tenure never passed its check: its teardown leaves no marker, so a
      # second wake is refused the same way.
      assert [expired: {:error, :fencing_unproven}] = RunHost.wake(host_b, [:expired])
      refute_received {:trace, _, :call, {RunEngine, :start_link, _}}
      assert count_rows(env, "intent-host/%") == activations
      assert length(requests(stub)) == 1
      assert state(host_b).runs == %{}
      # The processes of node A are still there: nothing of node B stopped them.
      assert node_processes(leader) != []
    end

    test "a start_run retry that opens an existing journal: confirmed teardown on the same host, a proof on a new one" do
      env = postgres()
      stub = stub([])
      {host, _} = host(env)
      spec = spec("retry", stub)

      assert {:error, {:start_failed, {:engine, :invalid_options_or_recovery}}} =
               RunHost.start_run(host, :retry, %{spec | request_cap: 0})

      trace([{Owner, :command, 2}])
      assert :ok = RunHost.start_run(host, :retry, spec)

      assert [{:create, {:unchanged, :duplicate, _}}, {:begin_attempt, {:unchanged, :duplicate, _}}] =
               commands()

      assert [{:attempt, "run-retry", "attempt-retry"}] =
               for(
                 %{kind: "run", payload: p} <- rows(env, "run/" <> spec.unit),
                 event = :erlang.binary_to_term(p),
                 elem(event, 0) == :attempt,
                 do: event
               )

      # A new incarnation of the host on the same node tracked none of the processes.
      ref = Process.monitor(host)
      Process.exit(host, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}
      {fresh, _} = host(env)
      trace([{RunEngine, :start_link, 1}])
      assert {:error, :fencing_unproven} = RunHost.start_run(fresh, :retry, spec)
      refute_received {:trace, _, :call, {RunEngine, :start_link, _}}
      assert state(fresh).runs == %{}
    end

    test "a fresh start interrupted between its first writes and the grant is retried by confirmed teardown" do
      env = postgres()
      {host, _} = host(env)
      spec = spec("first", stub([]))
      trace([{Owner, :command, 2}])
      start = Task.async(fn -> RunHost.start_run(host, :first, spec) end)

      receive do
        {:trace, worker, :return_from, {Owner, :command, 2}, {:ok, _, _}} ->
          :erlang.suspend_process(run(host, :first).pids.owner)
          Process.exit(worker, :kill)
      after
        5_000 -> flunk("no create")
      end

      assert {:error, _} = Task.await(start)
      eventually(fn -> run(host, :first) == nil end)
      assert :ok = RunHost.start_run(host, :first, spec)

      assert {:ok, %{current_attempt: "attempt-first"}} =
               Owner.status(run(host, :first).pids.owner, spec.run_id)
    end

    test "a lease that expired between a crash and the wake: the stale release and the claim are this owner's own" do
      env = postgres()
      {host, specs} = host(env, lease_ttl_ms: 1_000)
      spec = spec("lapsed", stub([]))
      remember(specs, :lapsed, spec)

      assert :ok = RunHost.start_run(host, :lapsed, spec)
      Process.exit(run(host, :lapsed).pids.engine, :kill)
      eventually(fn -> run(host, :lapsed) == nil end)
      stale!(env, spec)
      assert [lapsed: :woken] = RunHost.wake(host, [:lapsed])
      kinds = for %{kind: "lease_" <> _ = kind} <- rows(env, "run/" <> spec.unit), do: kind
      assert ["lease_released", "lease_claimed"] in Enum.chunk_every(kinds, 2, 1)
    end

    test "the fencing proof is asked at each predecessor check, never cached" do
      env = postgres()
      stub = stub([])
      {:ok, answers} = Agent.start_link(fn -> [:fenced, :unproven] end)
      proof = fn :again -> Agent.get_and_update(answers, fn [a | rest] -> {a, rest} end) end
      {host, specs} = host(env, fencing_proof: proof)
      spec = spec("again", stub)
      remember(specs, :again, spec)
      stream = "run/" <> spec.unit

      assert :ok = RunHost.start_run(host, :again, spec)
      assert :ok = RunHost.reap(host, :again)
      {:held, _} = Lease.claim(env.lease, stream, "other-node", 60_000)
      {:free, _} = Lease.release(env.lease, stream, "other-node")
      assert [again: :woken] = RunHost.wake(host, [:again])
      assert :ok = RunHost.reap(host, :again)
      {:held, _} = Lease.claim(env.lease, stream, "other-node", 60_000)
      {:free, _} = Lease.release(env.lease, stream, "other-node")
      assert [again: {:error, :fencing_unproven}] = RunHost.wake(host, [:again])
      assert Agent.get(answers, & &1) == []
    end

    test "a write of a dead predecessor that lands after the marker is read by the recovery (Memory)" do
      env = memory()
      stub = stub([answer("after the late write")])
      {host, specs} = host(env, notify())
      spec = spec("late", stub)
      remember(specs, :late, spec)

      assert :ok = RunHost.start_run(host, :late, spec)
      :ok = Memory.fault(env.store, :append, {:pause, :late})
      refute match?({:ok, _}, RunHost.input(host, :late, "start", start_input(), verified(spec)))
      assert :ok = RunHost.reap(host, :late)
      assert is_integer(state(host).markers[:late])
      assert {:committed, _} = Memory.release(env.store, :late)

      assert [late: :woken] = RunHost.wake(host, [:late])
      assert_receive {:terminal, :late, :completed}, 5_000
      assert [_] = for({"start", _} <- protocol_inputs(env, spec), do: 1)
      assert length(requests(stub)) == 1
    end
  end

  describe "routing" do
    test "an untried intent recovered at wake is sent once; its outcome is held until the route is verified" do
      env = postgres()
      stub = stub([answer("a"), answer("b")])
      test = self()
      {:ok, flags} = Agent.start_link(fn -> %{arm: true} end)

      # The second clock call of the first EffectIntent owner (its arm) waits, after the
      # owner committed its admission: a durable intent with no attempt.
      clock = fn ->
        if intent?(self()) and Agent.get(flags, & &1[:arm]) do
          n = Process.get(:clock_calls, 0)
          Process.put(:clock_calls, n + 1)

          if n == 1 and Agent.get_and_update(flags, &{&1[:arm], Map.put(&1, :arm, false)}) do
            send(test, {:arm_blocked, self()})
            receive do: (:release -> :ok)
          end
        end

        clock()
      end

      proposal = fn action ->
        if action["id"] == "b" and Agent.get_and_update(flags, &{&1[:b], Map.delete(&1, :b)}) do
          send(test, {:proposal_blocked, self()})
          receive do: (:release -> :ok)
        end

        proposal("tenant").(action)
      end

      {host, specs} = host(env, notify() ++ [clock: clock])
      spec = spec("route", stub, pattern: two_calls(), descriptor: [proposal: proposal])
      remember(specs, :route, spec)
      assert :ok = RunHost.start_run(host, :route, spec)

      start =
        Task.async(fn -> RunHost.input(host, :route, "start", start_input(), verified(spec)) end)

      assert_receive {:arm_blocked, _}, 5_000
      Process.exit(run(host, :route).pids.engine, :kill)
      Task.await(start)
      eventually(fn -> run(host, :route) == nil end)
      assert requests(stub) == []
      assert count_rows(env, "intent/%") >= 1

      Agent.update(flags, &Map.put(&1, :b, true))
      wake = Task.async(fn -> RunHost.wake(host, [:route]) end)
      assert_receive {:proposal_blocked, engine}, 5_000
      worker = run(host, :route).worker
      eventually(fn -> length(requests(stub)) == 1 end)

      eventually(fn ->
        {:messages, messages} = Process.info(worker, :messages)
        Enum.any?(messages, &match?({:ai_delivery, _, {:outcome, _, {:completed, _}}}, &1))
      end)

      assert ai_inputs(env, spec) == []
      send(engine, :release)
      assert [route: :woken] = Task.await(wake)
      assert_receive {:terminal, :route, :completed}, 5_000

      entries = transcript(host, :route, spec)
      assert [%{outcome: "completed"}] = settlements(entries, "a")
      assert [%{outcome: "completed"}] = settlements(entries, "b")
      assert length(ai_inputs(env, spec)) == 2
      assert length(requests(stub)) == 2
      # a: the first activation and the recovered one; b: one.
      assert count_rows(env, "intent-host/%") == 3
    end
  end

  describe "teardown" do
    test "a read-only intent owner whose activation never reached the host is stopped by reap" do
      env = postgres(harness: true)
      {host, _} = host(env)
      spec = spec("readonly", stub([answer("never sent")]))
      assert :ok = RunHost.start_run(host, :readonly, spec)
      before = Process.list()
      PostgresHarness.hook(env.stores[:activation_store], :inject, [:head, :unavailable])

      assert {:ok, :applied} =
               RunHost.input(host, :readonly, "start", start_input(), verified(spec))

      assert {:ok, %{slots: slots}} = RunHost.status(host, :readonly)
      assert [%{reconciliation: :read_only}] = Map.values(slots)
      intents = Enum.filter(new_processes(before), &intent?/1)
      assert [_] = intents
      assert :ok = RunHost.reap(host, :readonly)
      assert alive_pids(intents) == []
    end

    test "a send task that traps exits outlives its dead task supervisor and is still stopped" do
      env = postgres()
      stub = stub([{:block_trap, answer("never delivered")}])
      {host, _} = host(env)
      spec = spec("trapping", stub)
      assert :ok = RunHost.start_run(host, :trapping, spec)

      assert {:ok, :applied} =
               RunHost.input(host, :trapping, "start", start_input(), verified(spec))

      assert_receive {:stub_entered, task}, 5_000
      Process.exit(run(host, :trapping).pids.tasks, :kill)
      eventually(fn -> run(host, :trapping) == nil end)
      refute Process.alive?(task)
    end
  end

  describe "fingerprint_and_dispositions" do
    test "another gate version or request cap at wake is incompatible_recovery, its Unit stopped; the batch goes on" do
      env = postgres()
      stub = stub([])
      {host, specs} = host(env)
      runs = for name <- ~w(gate cap same), do: {String.to_atom(name), spec(name, stub)}

      for {ref, spec} <- runs do
        assert :ok = RunHost.start_run(host, ref, spec)
        assert :ok = RunHost.reap(host, ref)
      end

      remember(specs, :gate, %{runs[:gate] | gate: %{runs[:gate].gate | version: 2}})
      remember(specs, :cap, %{runs[:cap] | request_cap: 8})
      remember(specs, :same, runs[:same])

      assert [
               gate: {:error, :incompatible_recovery},
               cap: {:error, :incompatible_recovery},
               same: :woken
             ] = RunHost.wake(host, [:gate, :cap, :same])

      s = state(host)

      for ref <- [:gate, :cap] do
        assert Registry.lookup(s.units, "unit/" <> runs[ref].unit) == []
        assert DynamicUnits.find(s.directory, "unit/" <> runs[ref].unit) == :not_found
      end

      assert Map.keys(s.runs) == [:same]
      assert {:ok, %{phase: :active}} = RunHost.status(host, :same)
    end

    test "a batch with a live Run, a Run with no current Attempt and one whose lease another owner holds" do
      env = postgres()
      stub = stub([])
      {host, specs} = host(env)
      bare = spec("bare", stub)
      held = spec("held", stub)
      live = spec("live", stub)
      remember(specs, :bare, bare)
      remember(specs, :held, held)
      create_without_attempt!(env, bare)
      {:held, _} = Lease.claim(env.lease, "run/" <> held.unit, "other-node", 60_000)
      assert :ok = RunHost.start_run(host, :live, live)
      before = Process.list()
      # Every disposition at once: the batch is answered once and the host goes on.
      assert [live: {:error, :running}, live: {:error, :running}] =
               RunHost.wake(host, [:live, :live])

      assert [
               live: {:error, :running},
               bare: {:error, :no_current_attempt},
               held: {:error, {:lease_refused, %{reason: :active}}}
             ] = RunHost.wake(host, [:live, :bare, :held])

      assert Map.keys(state(host).runs) == [:live]
      pids = new_processes(before)
      eventually(fn -> alive_pids(pids) == [] end)
    end
  end

  describe "lease_fencing" do
    test "two hosts with distinct owner IDs on one PostgreSQL lease key: the second start or wake is refused" do
      lease_refusal(postgres())
    end

    test "on Memory, with one shared Lease backend, the refusal is the lease's own" do
      lease_refusal(memory())
    end
  end

  defp lease_refusal(env) do
    stub = stub([])
    specs = specs()
    {a, _} = host(env, specs: specs, owner_id: "node-a")
    {b, _} = host(env, specs: specs, owner_id: "node-b")
    spec = spec("shared", stub)
    remember(specs, :shared, spec)

    assert :ok = RunHost.start_run(a, :shared, spec)
    trace([{RunEngine, :start_link, 1}])
    assert {:error, {:lease_refused, %{reason: :active}}} = RunHost.start_run(b, :shared, spec)
    assert [shared: {:error, {:lease_refused, %{reason: :active}}}] = RunHost.wake(b, [:shared])
    refute_received {:trace, _, :call, {RunEngine, :start_link, _}}
    assert state(b).runs == %{}
    assert {:ok, %{phase: :active}} = RunHost.status(a, :shared)
  end

  # The recovered intent has a recorded attempt: the slot settles unknown once
  # (lost_outcome) and the Run is readable as failed with model_call_not_completed.
  defp lost_outcome!(host, ref, spec) do
    entries = transcript(host, ref, spec)

    assert [%{outcome: "unknown", reason: "lost_outcome", actual: :unknown}] =
             settlements(entries, "bot:m:1")

    assert {:failed, record} = RunHost.result(host, ref, scope(spec), limits())
    assert record.payload["reason"] == "model_call_not_completed"
  end

  defp stale!(env, spec) do
    eventually(
      fn -> match?({:ok, %{status: :stale}}, Lease.status(env.lease, "run/" <> spec.unit)) end,
      600
    )
  end

  defp commands do
    receive do
      {:trace, _, :call, {Owner, :command, [_, %{kind: kind}]}} ->
        receive do
          {:trace, _, :return_from, {Owner, :command, 2}, reply} -> [{kind, reply} | commands()]
        end
    after
      100 -> []
    end
  end

  defp create_without_attempt!(env, spec) do
    stream = "run/" <> spec.unit
    {:held, held} = Lease.claim(env.lease, stream, "creator", 60_000)

    {:ok, owner} =
      Owner.start_link(
        store: env.stores[:run_store],
        lease: env.lease,
        held: held,
        effect_intent: %{}
      )

    assert {:ok, _, _} =
             Owner.command(owner, %{
               kind: :create,
               run_id: spec.run_id,
               operation_id: spec.operation_id,
               provider_refs: %{},
               expected_revision: held.live.revision
             })

    GenServer.stop(owner)
    {:free, _} = Lease.release(env.lease, stream, "creator")
  end
end
