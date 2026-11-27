# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_host_test_helper.exs", __DIR__)

defmodule Elzoo.RunHostRecoveryTest do
  # Recovery, predecessor fencing, routing at startup, teardown and lease refusals, on
  # disposable PostgreSQL (one scenario on Memory). Every predecessor check needs a
  # fresh :fenced from fencing_proof; each proof here is demonstrated by the test
  # itself: the predecessor's processes, found without the host's tracking (spawn
  # tracing, attribute/2), have all ended, and no write of theirs is held. A host "on
  # another node" is a host started under its own group leader in this VM: the test
  # stops every process whose group-leader chain reaches it.
  use ExUnit.Case, async: false
  import Elzoo.RunHost.TestHelper
  alias Elzoo.{DynamicUnits, Lease, RunEngine, RunHost}
  alias Elzoo.RunApprovalRelease, as: Owner
  alias Elzoo.DurableLog.PostgresHarness

  setup_all do
    repo = database()
    on_exit(fn -> if Process.alive?(repo), do: Supervisor.stop(repo) end)
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "crash_and_wake" do
    test "a same-node restart with demonstrated fencing: the call is lost_outcome, never resent, and the Run fails" do
      env = postgres()
      stub = stub([{:block, answer("never delivered")}])
      {cell, proof} = proof_cell()
      {host, specs} = host(env, notify() ++ [fencing_proof: proof])
      spec = spec("crash", stub)
      remember(specs, :crash, spec)

      assert :ok = attribute(host, fn -> RunHost.start_run(host, :crash, spec) end)
      assert {:ok, :applied} = RunHost.input(host, :crash, "start", start_input(), verified(spec))
      assert_receive {:stub_entered, stub_task}, 10_000
      unit = unit_pids(state(host).units, "unit/" <> spec.unit)

      %{pids: %{engine: engine}} = run(host, :crash)
      Process.exit(engine, :kill)
      eventually(fn -> run(host, :crash) == nil end)
      prior = spawned() ++ unit
      assert stub_task in prior

      # The proof: every process of the crashed tenure has ended (none of its writes is held).
      assert alive_pids(prior) == []
      Agent.update(cell, fn _ -> prior end)
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

      assert_receive {:stub_entered, stub_task}, 10_000
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

      assert_receive {:stub_entered, _}, 10_000
      :erlang.suspend_process(host_a)
      stale!(env, spec)
      activations = count_rows(env, "intent-host/%")

      {host_b, _} = host(env, specs: specs, owner_id: "node-b")
      trace([{RunEngine, :start_link, 1}])
      assert [expired: {:error, :fencing_unproven}] = RunHost.wake(host_b, [:expired])
      # Each check asks again; with no fencing_proof every check fails.
      assert [expired: {:error, :fencing_unproven}] = RunHost.wake(host_b, [:expired])
      refute_received {:trace, _, :call, {RunEngine, :start_link, _}}
      assert count_rows(env, "intent-host/%") == activations
      assert length(requests(stub)) == 1
      assert state(host_b).runs == %{}
      # The processes of node A are still there: nothing of node B stopped them.
      assert node_processes(leader) != []
    end

    test "a predecessor's Unit write held past the host's own confirmed teardown: no proof, no wake; landed, a wake with proof reads it" do
      env = postgres(harness: true)
      stub = stub([{:block, answer("held outcome")}])
      specs = specs()
      spec = spec("held", stub)
      remember(specs, :held, spec)
      unit_store = env.stores[:unit_store]
      {host, _} = host(env, notify() ++ [specs: specs])

      assert :ok = attribute(host, fn -> RunHost.start_run(host, :held, spec) end)
      assert {:ok, :applied} = RunHost.input(host, :held, "start", start_input(), verified(spec))
      assert_receive {:stub_entered, blocked}, 10_000

      # The outcome's Unit append is held after its compare-and-set on the head:
      # submitted by the predecessor, not committed.
      PostgresHarness.hook(unit_store, :inject, [:append, {:pause, :held}])
      send(blocked, :release)
      eventually(fn -> held?(unit_store, :held) end)
      assert :ok = RunHost.reap(host, :held)
      prior = spawned()
      assert alive_pids(prior) == []
      assert held?(unit_store, :held)

      # The host's own confirmed teardown is no proof: no engine, no grant, no send.
      activations = count_rows(env, "intent-host/%")
      trace([{RunEngine, :start_link, 1}])

      assert [held: {:error, :fencing_unproven}] =
               attribute(host, fn -> RunHost.wake(host, [:held]) end)

      refute_received {:trace, _, :call, {RunEngine, :start_link, _}}
      assert count_rows(env, "intent-host/%") == activations
      assert length(requests(stub)) == 1
      assert held?(unit_store, :held)

      # The held write lands. A host whose proof shows the predecessor gone and nothing
      # held wakes the Run: recovery reads the landed outcome and the slot settles once.
      PostgresHarness.hook(unit_store, :release, [:held])
      refute held?(unit_store, :held)
      {cell, proof} = proof_cell()
      Agent.update(cell, fn _ -> spawned() end)
      {proved, _} = host(env, notify() ++ [specs: specs, fencing_proof: proof])
      assert [held: :woken] = RunHost.wake(proved, [:held])
      assert_receive {:terminal, :held, :completed}, 10_000
      entries = transcript(proved, :held, spec)
      assert [%{outcome: "completed"}] = settlements(entries, "bot:m:1")
      assert length(requests(stub)) == 1
    end

    test "a start_run retry that opens an existing journal: no proof is fencing_unproven with no engine; with proof, one Attempt" do
      env = postgres()
      stub = stub([])
      {host, _} = host(env)
      spec = spec("retry", stub)

      assert {:error, {:start_failed, {:engine, :invalid_options_or_recovery}}} =
               attribute(host, fn -> RunHost.start_run(host, :retry, %{spec | request_cap: 0}) end)

      trace([{RunEngine, :start_link, 1}])

      assert {:error, :fencing_unproven} =
               attribute(host, fn -> RunHost.start_run(host, :retry, spec) end)

      refute_received {:trace, _, :call, {RunEngine, :start_link, _}}
      assert state(host).runs == %{}

      {cell, proof} = proof_cell()
      Agent.update(cell, fn _ -> spawned() end)
      {proved, _} = host(env, fencing_proof: proof)
      trace([{Owner, :command, 2}])
      assert :ok = RunHost.start_run(proved, :retry, spec)

      assert [{:create, {:unchanged, :duplicate, _}}, {:begin_attempt, {:unchanged, :duplicate, _}}] =
               commands()

      assert [{:attempt, "run-retry", "attempt-retry"}] =
               for(
                 %{kind: "run", payload: p} <- rows(env, "run/" <> spec.unit),
                 event = :erlang.binary_to_term(p),
                 elem(event, 0) == :attempt,
                 do: event
               )
    end

    test "a fresh start interrupted after its create: the retry opens its journal and needs a fresh proof" do
      env = postgres()
      {cell, proof} = proof_cell()
      {host, _} = host(env, fencing_proof: proof)
      spec = spec("first", stub([]))
      trace([{Owner, :command, 2}])

      start =
        attribute(host, fn ->
          task = Task.async(fn -> RunHost.start_run(host, :first, spec) end)
          eventually(fn -> run(host, :first) != nil end)
          task
        end)

      receive do
        {:trace, worker, :return_from, {Owner, :command, 2}, {:ok, _, _}} ->
          :erlang.suspend_process(run(host, :first).pids.owner)
          Process.exit(worker, :kill)
      after
        5_000 -> flunk("no create")
      end

      assert {:error, _} = Task.await(start)
      eventually(fn -> run(host, :first) == nil end)

      assert {:error, :fencing_unproven} =
               attribute(host, fn -> RunHost.start_run(host, :first, spec) end)

      Agent.update(cell, fn _ -> spawned() end)
      assert :ok = RunHost.start_run(host, :first, spec)

      assert {:ok, %{current_attempt: "attempt-first"}} =
               Owner.status(run(host, :first).pids.owner, spec.run_id)
    end

    test "the fencing proof is asked at each predecessor check, never cached" do
      env = postgres()
      {:ok, answers} = Agent.start_link(fn -> [:fenced, :unproven] end)
      proof = fn :again -> Agent.get_and_update(answers, fn [a | rest] -> {a, rest} end) end
      {host, specs} = host(env, fencing_proof: proof)
      spec = spec("again", stub([]))
      remember(specs, :again, spec)

      # A fresh start opens no journal and asks nothing.
      assert :ok = RunHost.start_run(host, :again, spec)
      assert :ok = RunHost.reap(host, :again)
      assert [again: :woken] = RunHost.wake(host, [:again])
      assert :ok = RunHost.reap(host, :again)
      assert [again: {:error, :fencing_unproven}] = RunHost.wake(host, [:again])
      assert Agent.get(answers, & &1) == []
    end

    test "an activation after the lease was seized: the callback's reading shows another holder, so no grant, no send, and the Run is lost" do
      env = postgres()
      stub = stub([answer("never sent")])
      {:ok, armed} = Agent.start_link(fn -> true end)

      # The spec's gate runs in the engine after the input was admitted and before the
      # call's intent asks for its activation: the lease is seized right there.
      gate = fn _, _ ->
        if Agent.get_and_update(armed, &{&1, false}) do
          {:held, _} =
            Lease.seize(env.lease, "run/seized", "operator", 60_000, :operator_takeover)
        end

        :allow
      end

      {host, _} = host(env, notify())
      spec = spec("seized", stub, gate: %{id: "gate", version: 1, call: gate})
      assert :ok = RunHost.start_run(host, :seized, spec)
      activations = count_rows(env, "intent-host/%")

      assert {_, _} =
               RunHost.input(host, :seized, "start", start_input(), verified(spec))

      assert_receive {:lost, :seized, {:lease_lost, %{holder: "operator"}}}, 5_000
      eventually(fn -> run(host, :seized) == nil end)
      assert count_rows(env, "intent-host/%") == activations
      assert requests(stub) == []
      refute_received {:lost, :seized, _}
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

      {cell, proof} = proof_cell()
      {host, specs} = host(env, notify() ++ [clock: clock, fencing_proof: proof])
      spec = spec("route", stub, pattern: two_calls(), descriptor: [proposal: proposal])
      remember(specs, :route, spec)
      assert :ok = attribute(host, fn -> RunHost.start_run(host, :route, spec) end)

      start =
        Task.async(fn -> RunHost.input(host, :route, "start", start_input(), verified(spec)) end)

      assert_receive {:arm_blocked, _}, 10_000
      Process.exit(run(host, :route).pids.engine, :kill)
      Task.await(start)
      eventually(fn -> run(host, :route) == nil end)
      assert requests(stub) == []
      assert count_rows(env, "intent/%") >= 1
      Agent.update(cell, fn _ -> spawned() end)

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
      assert :ok = attribute(host, fn -> RunHost.start_run(host, :readonly, spec) end)
      PostgresHarness.hook(env.stores[:activation_store], :inject, [:head, :unavailable])

      assert {:ok, :applied} =
               RunHost.input(host, :readonly, "start", start_input(), verified(spec))

      assert {:ok, %{slots: slots}} = RunHost.status(host, :readonly)
      assert [%{reconciliation: :read_only}] = Map.values(slots)
      intents = Enum.filter(spawned(), &intent?/1)
      assert [_] = intents
      assert :ok = RunHost.reap(host, :readonly)
      assert alive_pids(spawned()) == []
    end

    test "a send task that traps exits outlives its dead task supervisor and is still stopped" do
      env = postgres()
      stub = stub([{:block_trap, answer("never delivered")}])
      {host, _} = host(env)
      spec = spec("trapping", stub)
      assert :ok = RunHost.start_run(host, :trapping, spec)

      assert {:ok, :applied} =
               RunHost.input(host, :trapping, "start", start_input(), verified(spec))

      assert_receive {:stub_entered, task}, 10_000
      Process.exit(run(host, :trapping).pids.tasks, :kill)
      eventually(fn -> run(host, :trapping) == nil end)
      refute Process.alive?(task)
    end
  end

  describe "fingerprint_and_dispositions" do
    test "another gate version or request cap at wake is incompatible_recovery, its Unit stopped; the batch goes on" do
      env = postgres()
      stub = stub([])
      {cell, proof} = proof_cell()
      {host, specs} = host(env, fencing_proof: proof)
      runs = for name <- ~w(gate cap same), do: {String.to_atom(name), spec(name, stub)}

      for {ref, spec} <- runs do
        assert :ok = attribute(host, fn -> RunHost.start_run(host, ref, spec) end)
        assert :ok = RunHost.reap(host, ref)
      end

      Agent.update(cell, fn _ -> spawned() end)
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
      trace([{RunEngine, :start_link, 1}])

      # Every disposition at once: the batch is answered once and the host goes on.
      assert [live: {:error, :running}, live: {:error, :running}] =
               RunHost.wake(host, [:live, :live])

      # The processes that the batch starts, found without the host's tracking.
      assert [
               live: {:error, :running},
               bare: {:error, :no_current_attempt},
               held: {:error, {:lease_refused, %{reason: :active}}}
             ] = attribute(host, fn -> RunHost.wake(host, [:live, :bare, :held]) end)

      refute_received {:trace, _, :call, {RunEngine, :start_link, _}}
      assert Map.keys(state(host).runs) == [:live]
      pids = spawned()
      assert pids != []
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

  # A write of the Unit view's harness held after its compare-and-set (PostgresHarness).
  defp held?({_, %{controller: controller}}, token),
    do: Agent.get(controller, &Map.has_key?(&1.paused, token))

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
