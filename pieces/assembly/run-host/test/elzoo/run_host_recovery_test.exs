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
  alias Elzoo.{DynamicUnits, EffectIntent, Lease, RunEngine, RunHost}
  alias Elzoo.RunApprovalRelease, as: Owner
  alias Elzoo.DurableLog.{Memory, PostgresHarness}

  setup_all do
    repo = database()
    on_exit(fn -> if Process.alive?(repo), do: Supervisor.stop(repo) end)
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "crash_and_wake" do
    test "a same-node restart: the host's own teardown is no proof; with demonstrated fencing the call is lost_outcome, never resent, and the Run fails" do
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

      # Every process of the tenure is gone by the host's own teardown, but the proof
      # is not given yet: no engine starts.
      trace([{RunEngine, :start_link, 1}])

      assert [crash: {:error, :fencing_unproven}] =
               attribute(host, fn -> RunHost.wake(host, [:crash]) end)

      refute_received {:trace, _, :call, {RunEngine, :start_link, _}}

      # The proof: every process of the crashed tenure (and of the refused one) has ended.
      prior = spawned() ++ unit
      assert stub_task in prior
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

      {cell, proof} = proof_cell()
      {host_b, _} = host(env, notify() ++ [specs: specs, owner_id: "node-b", fencing_proof: proof])

      # The processes of node A, found through their group-leader chain: while they live,
      # the proof refuses and no engine starts.
      prove(cell, node_processes(leader), host_a)
      trace([{RunEngine, :start_link, 1}])
      assert [remote: {:error, :fencing_unproven}] = RunHost.wake(host_b, [:remote])
      refute_received {:trace, _, :call, {RunEngine, :start_link, _}}

      # Node A is fenced: every one of them has ended, and the same proof now holds.
      assert :ok = fence_node(leader)
      refute Process.alive?(stub_task)
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

    test "a predecessor's EffectIntent write held after submission across the host's own teardown: fencing_unproven; once it lands, a wake with proof reads it and the slot settles once" do
      env = memory()
      stub = stub([{:block, answer("held outcome")}])
      {:ok, prior} = Agent.start_link(fn -> [] end)

      # The caller's attestation: every process of the predecessor has ended (found by
      # the test without the host) and no write that it submitted is still held.
      proof = fn :held ->
        pids = Agent.get(prior, & &1)

        if pids != [] and alive_pids(pids) == [] and not held?(env, :held),
          do: :fenced,
          else: :unproven
      end

      {host, specs} = host(env, notify() ++ [fencing_proof: proof])
      spec = spec("held", stub)
      remember(specs, :held, spec)

      assert :ok = attribute(host, fn -> RunHost.start_run(host, :held, spec) end)
      assert {:ok, :applied} = RunHost.input(host, :held, "start", start_input(), verified(spec))
      assert_receive {:stub_entered, blocked}, 10_000
      [{intent, armed}] = Map.to_list(heads(env, "intent/"))
      # The directory-owned Unit and its Writer, taken while the call keeps the Unit awake.
      assert [_unit, _writer | _] = unit = unit_pids(state(host).units, "unit/" <> spec.unit)

      # The worker is held, so the call's delivery is never taken. The next append of the
      # namespace, the intent owner's settlement at the intent head, is held after its
      # submission: the Store has it, and its outcome is unknown to the owner.
      worker = run(host, :held).worker
      :sys.suspend(worker)
      :ok = Memory.fault(env.store, :append, {:pause, :held})
      send(blocked, :release)
      eventually(fn -> held?(env, :held) end)

      assert :ok = RunHost.reap(host, :held)
      pids = spawned() ++ unit
      assert worker in pids
      Agent.update(prior, fn _ -> pids end)
      assert alive_pids(pids) == []
      assert heads(env, "intent/") == %{intent => armed}

      # Every process is gone by the host's own confirmed teardown, and still the write
      # can commit: no proof, no engine, no grant, no send.
      activations = heads(env, "intent-host/")
      trace([{RunEngine, :start_link, 1}])

      assert [held: {:error, :fencing_unproven}] =
               attribute(host, fn -> RunHost.wake(host, [:held]) end)

      refute_received {:trace, _, :call, {RunEngine, :start_link, _}}
      assert heads(env, "intent-host/") == activations
      assert length(requests(stub)) == 1

      # The held write lands, on the intent head that nothing moved.
      assert {:committed, landed} = Memory.release(env.store, :held)
      assert landed == armed + 1
      pids = spawned() ++ unit
      assert worker in pids
      Agent.update(prior, fn _ -> pids end)

      # Now the proof is given: recovery reads the landed write and the slot settles once.
      assert [held: :woken] = attribute(host, fn -> RunHost.wake(host, [:held]) end)
      assert_receive {:terminal, :held, :failed}, 10_000
      lost_outcome!(host, :held, spec)
      assert [owner] = Enum.filter(alive_pids(spawned()), &intent?/1)
      assert %{revision: ^landed, attempts: 1} = EffectIntent.status(owner)
      assert length(requests(stub)) == 1
    end

    test "a start_run retry that opens an existing journal: no proof is fencing_unproven with no engine; with proof, one Attempt" do
      env = postgres()
      stub = stub([])
      {host, _} = host(env)
      spec = spec("retry", stub)

      trace([{Elzoo.RunHost.Runner, :init, 1}, {DynamicUnits, :start, 2}])

      assert {:error, {:start_failed, {:engine, :invalid_options_or_recovery}}} =
               attribute(host, fn -> RunHost.start_run(host, :retry, %{spec | request_cap: 0}) end)

      assert_receive {:trace, failed, :call, {Elzoo.RunHost.Runner, :init, _}}
      # The engine refused its options before it started a Unit: the failed start's
      # processes are those that it spawned.
      _ = spawned()
      refute_received {:trace, _, :call, {DynamicUnits, :start, _}}

      trace([{RunEngine, :start_link, 1}])

      assert {:error, :fencing_unproven} =
               attribute(host, fn -> RunHost.start_run(host, :retry, spec) end)

      refute_received {:trace, _, :call, {RunEngine, :start_link, _}}
      assert state(host).runs == %{}

      {cell, proof} = proof_cell()
      prove(cell, spawned(), failed)
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
      trace([{Owner, :command, 2}, {DynamicUnits, :start, 2}])

      start =
        attribute(host, fn ->
          task = Task.async(fn -> RunHost.start_run(host, :first, spec) end)
          eventually(fn -> run(host, :first) != nil end)
          task
        end)

      worker =
        receive do
          {:trace, worker, :return_from, {Owner, :command, 2}, {:ok, _, _}} ->
            :erlang.suspend_process(run(host, :first).pids.owner)
            Process.exit(worker, :kill)
            worker
        after
          5_000 -> flunk("no create")
        end

      assert {:error, _} = Task.await(start)
      eventually(fn -> run(host, :first) == nil end)
      # No engine started, so no Unit: the interrupted start's processes are those that
      # it spawned.
      _ = spawned()
      refute_received {:trace, _, :call, {DynamicUnits, :start, _}}

      assert {:error, :fencing_unproven} =
               attribute(host, fn -> RunHost.start_run(host, :first, spec) end)

      prove(cell, spawned(), worker)
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

    test "an activation on this owner's lease that a re-claim shortened and that passed its own until: refused, the Run lost (:expired)" do
      env = memory()
      stub = stub([answer("never sent")])
      {:ok, armed} = Agent.start_link(fn -> true end)

      # In the gate, before the call's intent asks for its activation, the same owner
      # re-claims the key with a TTL of 1 s and the lease clock moves 2 s: past the
      # re-claimed until, 58 s before the until that the host last confirmed.
      gate = fn _, _ ->
        if Agent.get_and_update(armed, &{&1, false}) do
          {:held, _} = Lease.claim(env.lease, "run/shortened", "node-a", 1_000)
          Lease.Clock.advance(env.clock, 2_000_000)
        end

        :allow
      end

      {host, _} = host(env, notify())
      spec = spec("shortened", stub, gate: %{id: "gate", version: 1, call: gate})
      assert :ok = RunHost.start_run(host, :shortened, spec)
      activations = heads(env, "intent-host/")

      assert {_, _} =
               RunHost.input(host, :shortened, "start", start_input(), verified(spec))

      assert_receive {:lost, :shortened, :expired}, 5_000
      eventually(fn -> run(host, :shortened) == nil end)
      assert heads(env, "intent-host/") == activations
      assert requests(stub) == []
      refute_received {:lost, :shortened, _}
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
      assert [_unit, _writer | _] = unit = unit_pids(state(host).units, "unit/" <> spec.unit)
      old_engine = run(host, :route).pids.engine
      Process.exit(old_engine, :kill)
      Task.await(start)
      eventually(fn -> run(host, :route) == nil end)
      assert requests(stub) == []
      assert count_rows(env, "intent/%") >= 1
      prove(cell, spawned() ++ unit, old_engine)

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

    test "a wake that dispatches an untried intent while its first route read is held past idle_ms: the Unit stays awake and the call settles completed" do
      env = postgres()
      stub = stub([answer("recovered")])
      {host, ref, spec} = untried!(env, "dispatched", stub, idle_ms: 300)
      %{names: names, units: units} = state(host)

      # The wake's engine dispatches the untried intent at its start; then its first route
      # read waits in the engine for five idle periods.
      hold_engine(names, "unit/dispatched")
      wake = Task.async(fn -> RunHost.wake(host, [ref]) end)
      assert_receive {:engine_held, engine}, 10_000
      eventually(fn -> length(requests(stub)) == 1 end)
      [{unit, _}] = Registry.lookup(units, "unit/dispatched")
      Process.sleep(1_500)
      assert [{^unit, _}] = Registry.lookup(units, "unit/dispatched")
      :sys.resume(engine)

      assert [dispatched: :woken] = Task.await(wake)
      assert_receive {:terminal, :dispatched, :completed}, 5_000
      assert [%{outcome: "completed"}] = settlements(transcript(host, ref, spec), "bot:m:1")
      assert length(requests(stub)) == 1
    end

    test "a buffered completion that ends the Run after a verification retry: the wake is :woken and on_terminal is called once" do
      env = postgres(harness: true)
      stub = stub([answer("ends the Run")])
      {host, ref, spec} = untried!(env, "ended", stub, [])

      # The wake's engine dispatches at its start; its completion waits in the worker while
      # the first route read waits in the engine, and that read then fails for a moment.
      hold_engine(state(host).names, "unit/ended")
      wake = Task.async(fn -> RunHost.wake(host, [ref]) end)
      assert_receive {:engine_held, engine}, 10_000
      worker = run(host, ref).worker

      eventually(fn ->
        {:messages, messages} = Process.info(worker, :messages)
        Enum.any?(messages, &match?({:ai_delivery, _, {:outcome, _, {:completed, _}}}, &1))
      end)

      PostgresHarness.hook(env.stores[:unit_store], :inject, [:read, :unavailable])
      :sys.resume(engine)

      assert [ended: :woken] = Task.await(wake)
      assert_receive {:terminal, :ended, :completed}, 5_000
      refute_receive {:terminal, :ended, _}, 300
      assert [%{outcome: "completed"}] = settlements(transcript(host, ref, spec), "bot:m:1")
      assert length(requests(stub)) == 1
    end
  end

  # A Run whose first model call's intent is admitted and never armed: its arm waits in
  # the EffectIntent owner's clock, and the engine is then killed. The next wake dispatches
  # that untried intent at its start. The proof cell holds the first tenure's processes,
  # its directory-owned Unit and Writer included, and the proof holds once they all ended.
  defp untried!(env, name, stub, opts) do
    test = self()
    {:ok, arm} = Agent.start_link(fn -> true end)

    clock = fn ->
      if intent?(self()) do
        n = Process.get(:clock_calls, 0)
        Process.put(:clock_calls, n + 1)

        if n == 1 and Agent.get_and_update(arm, &{&1, false}) do
          send(test, {:arm_blocked, self()})
          receive do: (:release -> :ok)
        end
      end

      clock()
    end

    {cell, proof} = proof_cell()
    ref = String.to_atom(name)
    {host, specs} = host(env, notify() ++ [clock: clock, fencing_proof: proof] ++ opts)
    spec = spec(name, stub)
    remember(specs, ref, spec)
    assert :ok = attribute(host, fn -> RunHost.start_run(host, ref, spec) end)
    start = Task.async(fn -> RunHost.input(host, ref, "start", start_input(), verified(spec)) end)
    assert_receive {:arm_blocked, _}, 10_000
    assert [_unit, _writer | _] = unit = unit_pids(state(host).units, "unit/" <> spec.unit)
    engine = run(host, ref).pids.engine
    Process.exit(engine, :kill)
    Task.await(start)
    eventually(fn -> run(host, ref) == nil end)
    assert requests(stub) == []
    prove(cell, spawned() ++ unit, engine)
    assert proof.(ref) == :fenced
    {host, ref, spec}
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
    test "another gate version or request cap at wake: with no proof fencing_unproven first, with a fresh proof incompatible_recovery, its Unit stopped; the batch goes on" do
      env = postgres()
      stub = stub([])
      {cell, proof} = proof_cell()
      {host, specs} = host(env, fencing_proof: proof)
      runs = for name <- ~w(gate cap same), do: {String.to_atom(name), spec(name, stub)}

      prior =
        for {ref, spec} <- runs do
          assert :ok = attribute(host, fn -> RunHost.start_run(host, ref, spec) end)
          worker = run(host, ref).worker
          assert [_unit, _writer | _] = unit = unit_pids(state(host).units, "unit/" <> spec.unit)
          assert :ok = RunHost.reap(host, ref)
          {worker, unit}
        end

      remember(specs, :gate, %{runs[:gate] | gate: %{runs[:gate].gate | version: 2}})
      remember(specs, :cap, %{runs[:cap] | request_cap: 8})
      remember(specs, :same, runs[:same])
      trace([{RunEngine, :start_link, 1}])

      # No proof yet: each Run is refused before an engine reads its journal.
      assert [
               gate: {:error, :fencing_unproven},
               cap: {:error, :fencing_unproven},
               same: {:error, :fencing_unproven}
             ] = attribute(host, fn -> RunHost.wake(host, [:gate, :cap, :same]) end)

      refute_received {:trace, _, :call, {RunEngine, :start_link, _}}
      pids = spawned() ++ Enum.flat_map(prior, &elem(&1, 1))
      for {worker, _} <- prior, do: prove(cell, pids, worker)

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

  # A write of the Memory namespace held after its submission (`{:pause, token}`).
  defp held?(env, token), do: Map.has_key?(Memory.inspect_state(env.store).paused, token)

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
