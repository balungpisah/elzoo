# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_host_test_helper.exs", __DIR__)

defmodule Elzoo.RunHostRecoveryTest do
  # Recovery, predecessor fencing, routing at startup and lease refusals, on
  # disposable PostgreSQL (one lease refusal on Memory). A host "on another node" is a
  # host started under its own group leader in this VM: the test stops every process
  # that inherits it, independently of the host's own tracking.
  use ExUnit.Case, async: false
  import Elzoo.RunHost.TestHelper
  alias Elzoo.{DynamicUnits, Lease, RunHost}
  alias Elzoo.RunApprovalRelease, as: Owner

  setup_all do
    repo = database()
    on_exit(fn -> if Process.alive?(repo), do: Supervisor.stop(repo) end)
    :ok
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

    test "lease expiry alone, with no proof: fencing_unproven, no activation granted and no new send" do
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
      activations = activation_rows(env)

      {host_b, _} = host(env, specs: specs, owner_id: "node-b")
      assert [expired: {:error, :fencing_unproven}] = RunHost.wake(host_b, [:expired])
      assert activation_rows(env) == activations
      assert length(requests(stub)) == 1
      assert state(host_b).runs == %{}
      assert Registry.lookup(state(host_b).names, spec.unit) == []
      # No engine of node B, and no process of the Run on it.
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
      assert {:error, :fencing_unproven} = RunHost.start_run(fresh, :retry, spec)
      assert state(fresh).runs == %{}
      assert Registry.lookup(state(fresh).names, spec.unit) == []
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
  end

  describe "routing" do
    test "an untried intent first dispatched during wake is held until the route is verified, then settles once" do
      env = postgres()
      stub = stub([answer("first"), answer("second")])
      {:ok, blocks} = Agent.start_link(fn -> %{"a" => true} end)
      test = self()

      proposal = fn action ->
        # The engine reads the proposal at authorization and again before dispatch:
        # a block holds the first read only.
        if Agent.get_and_update(blocks, &Map.pop(&1, action["id"])) do
          send(test, {:proposal_blocked, action["id"], self()})
          receive do: (:release -> :ok)
        end

        proposal("tenant").(action)
      end

      {host, specs} = host(env, notify())
      spec = spec("route", stub, pattern: two_calls(), descriptor: [proposal: proposal])
      remember(specs, :route, spec)
      assert :ok = RunHost.start_run(host, :route, spec)

      start =
        Task.async(fn -> RunHost.input(host, :route, "start", start_input(), verified(spec)) end)

      assert_receive {:proposal_blocked, "a", engine}, 5_000
      Process.exit(engine, :kill)
      assert {:error, :not_running} = Task.await(start)
      eventually(fn -> run(host, :route) == nil end)
      assert requests(stub) == []

      Agent.update(blocks, fn _ -> %{"b" => true} end)
      wake = Task.async(fn -> RunHost.wake(host, [:route]) end)
      assert_receive {:proposal_blocked, "b", engine}, 5_000
      worker = run(host, :route).worker
      eventually(fn -> length(requests(stub)) == 1 end)

      eventually(fn ->
        {:messages, messages} = Process.info(worker, :messages)
        Enum.any?(messages, &match?({:ai_delivery, _, {:outcome, _, {:completed, _}}}, &1))
      end)

      # Held: the engine has not been given it.
      assert for({"ai:" <> _, _} <- protocol_inputs(env, spec.unit), do: 1) == []

      send(engine, :release)
      assert [route: :woken] = Task.await(wake)
      assert_receive {:terminal, :route, :completed}, 5_000

      entries = transcript(host, :route, spec)
      assert [%{outcome: "completed"}] = settlements(entries, "a")
      assert [%{outcome: "completed"}] = settlements(entries, "b")
      a = occurrence(entries, "a")

      assert [_] =
               for(
                 {"ai:" <> _, %{correlation: %{occurrence: ^a}}} <- protocol_inputs(env, spec.unit),
                 do: 1
               )

      assert length(requests(stub)) == 2
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
        assert Registry.lookup(s.units, runs[ref].unit) == []
        assert DynamicUnits.find(s.directory, runs[ref].unit) == :not_found
      end

      assert Map.keys(s.runs) == [:same]
      assert {:ok, %{phase: :active}} = RunHost.status(host, :same)
    end

    test "a batch with a Run that has no current Attempt and one whose lease another owner holds" do
      env = postgres()
      stub = stub([])
      {host, specs} = host(env)
      bare = spec("bare", stub)
      held = spec("held", stub)
      remember(specs, :bare, bare)
      remember(specs, :held, held)
      create_without_attempt!(env, bare)
      {:held, _} = Lease.claim(env.lease, "run/" <> held.unit, "other-node", 60_000)
      count = length(Process.list())

      assert [
               bare: {:error, :no_current_attempt},
               held: {:error, {:lease_refused, %{reason: :active}}}
             ] = RunHost.wake(host, [:bare, :held])

      assert state(host).runs == %{}
      assert Registry.select(state(host).names, [{{:"$1", :_, :_}, [], [:"$1"]}]) == []
      eventually(fn -> length(Process.list()) == count end)
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
    assert {:error, {:lease_refused, %{reason: :active}}} = RunHost.start_run(b, :shared, spec)
    assert [shared: {:error, {:lease_refused, %{reason: :active}}}] = RunHost.wake(b, [:shared])
    assert state(b).runs == %{}
    assert Registry.lookup(state(b).names, spec.unit) == []
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

  defp activation_rows(env) do
    [[n]] =
      sql!(
        "SELECT count(*) FROM #{Elzoo.DurableLog.Postgres.identifier(env.prefix)}.elzoo_log_records WHERE stream LIKE 'intent-host/%'"
      )

    n
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
