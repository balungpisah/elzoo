# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_host_test_helper.exs", __DIR__)

defmodule Elzoo.RunHostTest do
  # The host on disposable PostgreSQL (and one full Memory scenario) with the scripted
  # stub of integration/ai-text-anthropic: no network, stub keys only.
  use ExUnit.Case, async: false
  import Elzoo.RunHost.TestHelper
  alias Elzoo.{Lease, RunHost}

  setup_all do
    repo = database()
    on_exit(fn -> if Process.alive?(repo), do: Supervisor.stop(repo) end)
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "end_to_end" do
    test "an AgentLoop Run answers; result/4 reads it before reap/2 and not after (PostgreSQL)" do
      end_to_end(postgres(), [])
    end

    test "the same Run on one Memory namespace with a manual-clock Lease, read again after its Unit sleeps" do
      env = memory()
      {host, spec} = end_to_end(env, idle_ms: 200, reap: false)
      units = state(host).units
      eventually(fn -> Registry.lookup(units, "unit/" <> spec.unit) == [] end)
      assert {:ok, %{outcome: :completed}} = RunHost.status(host, :e2e)

      assert {:ok, %{payload: %{"content" => "Hello from the model."}}} =
               RunHost.result(host, :e2e, scope(spec), limits())

      assert :ok = RunHost.reap(host, :e2e)
    end
  end

  defp end_to_end(env, opts) do
    stub = stub([answer("Hello from the model.")])
    {host, _} = host(env, notify() ++ Keyword.take(opts, [:idle_ms]))
    spec = spec("e2e", stub)

    assert :ok = RunHost.start_run(host, :e2e, spec)
    assert {:ok, :applied} = RunHost.input(host, :e2e, "start", start_input(), verified(spec))
    assert_receive {:terminal, :e2e, :completed}, 10_000

    assert {:ok, record} = RunHost.result(host, :e2e, scope(spec), limits())
    assert record.action_id == "bot:m:1"
    assert record.schema_id == "elzoo.ai-text.result"
    assert record.payload["content"] == "Hello from the model."
    assert record.payload["finish"] == "stop"

    assert {:error, :terminal} =
             RunHost.input(host, :e2e, "again", start_input(), verified(spec))

    assert length(requests(stub)) == 1

    if Keyword.get(opts, :reap, true) do
      assert :ok = RunHost.reap(host, :e2e)
      assert {:error, :not_running} = RunHost.result(host, :e2e, scope(spec), limits())

      assert {:error, :not_running} =
               RunHost.input(host, :e2e, "late", start_input(), verified(spec))
    end

    {host, spec}
  end

  describe "model_call_not_completed" do
    test "a model call that does not complete fails the Run with no host cancel" do
      env = postgres()
      stub = stub([{500, [], Elzoo.AiText.AnthropicStub.error("api_error", "overloaded upstream")}])
      {host, _} = host(env, notify())
      spec = spec("fails", stub)

      assert :ok = RunHost.start_run(host, :fails, spec)
      assert {:ok, :applied} = RunHost.input(host, :fails, "start", start_input(), verified(spec))
      assert_receive {:terminal, :fails, :failed}, 10_000

      assert {:failed, record} = RunHost.result(host, :fails, scope(spec), limits())
      assert record.action_id == "bot:finish"

      assert record.payload == %{
               "status" => "stopped",
               "reason" => "model_call_not_completed",
               "action_id" => nil,
               "turns" => 1
             }

      entries = transcript(host, :fails, spec)
      assert [%{outcome: "unknown", actual: :unknown}] = settlements(entries, "bot:m:1")

      assert [%{kind: "start"}, %{kind: "action_outcome"}] =
               for(
                 %{type: :input, input_id: id} = e <- entries,
                 not String.starts_with?(id, "out:"),
                 do: e
               )

      assert :ok = RunHost.reap(host, :fails)
      assert {:error, :not_running} = RunHost.result(host, :fails, scope(spec), limits())
    end
  end

  describe "capacity" do
    test "max_runs holds a terminal Run that is not reaped and a Run whose Unit sleeps; reap leaves no process of the Run" do
      env = postgres()
      stub = stub([{:block, answer("one")}])
      test = self()

      # The terminal callback of :done is held: a task of the host's shared supervisor
      # that only the reap of :done stops.
      on_terminal = fn
        :done, outcome ->
          send(test, {:terminal, :done, outcome})
          send(test, {:callback, self()})
          receive do: (:never -> :ok)

        ref, outcome ->
          send(test, {:terminal, ref, outcome})
      end

      {host, _} = host(env, on_terminal: on_terminal, max_runs: 2, idle_ms: 100)
      sleepy = spec("sleepy", stub)
      done = spec("done", stub)

      assert :ok = RunHost.start_run(host, :sleepy, sleepy)
      units = state(host).units
      eventually(fn -> Registry.lookup(units, "unit/" <> sleepy.unit) == [] end)
      assert {:ok, %{phase: :active}} = RunHost.status(host, :sleepy)

      # The processes of :done, found without the host's tracking: everything spawned
      # under its start (traced: its group leader, worker and all that the worker starts);
      # every task of the host's shared supervisor from now on (its callbacks, renewal,
      # expiry, teardown and release tasks; :sleepy starts none in this window, its lease
      # renews after 30 s); and its directory-owned Unit with the Writer, taken while its
      # model call keeps the Unit awake.
      trace_spawns(state(host).tasks)
      assert :ok = attribute(host, fn -> RunHost.start_run(host, :done, done) end)
      assert {:ok, :applied} = RunHost.input(host, :done, "start", start_input(), verified(done))
      assert_receive {:stub_entered, blocked}, 10_000
      assert [_unit, _writer | _] = unit = unit_pids(units, "unit/" <> done.unit)
      send(blocked, :release)
      assert_receive {:terminal, :done, :completed}, 5_000
      assert_receive {:callback, callback}, 5_000
      assert {:error, :capacity} = RunHost.start_run(host, :third, spec("third", stub))

      %{worker: worker, pids: %{engine: engine}} = run(host, :done)
      assert :ok = RunHost.reap(host, :done)
      pids = Enum.uniq(spawned() ++ unit)
      assert worker in pids and engine in pids and callback in pids
      assert length(pids) >= 13
      assert alive_pids(pids) == []
      assert {:ok, %{status: :free}} = Lease.status(env.lease, "run/" <> done.unit)

      assert :ok = RunHost.start_run(host, :third, spec("third", stub))
      assert {:error, :capacity} = RunHost.start_run(host, :fourth, spec("fourth", stub))
    end

    test "a reap whose lease release is not confirmed keeps the reservation; a later reap frees it" do
      {:ok, fail} = Agent.start_link(fn -> false end)

      hook = fn
        :before_lock, _ -> if Agent.get_and_update(fail, &{&1, false}), do: raise("release fails")
        _, _ -> :ok
      end

      env = postgres(lease: [test_hook: hook])
      {host, _} = host(env, max_runs: 1)
      spec = spec("release", stub([]))

      assert :ok = RunHost.start_run(host, :release, spec)
      Agent.update(fail, fn _ -> true end)
      assert {:error, :release_unconfirmed} = RunHost.reap(host, :release)
      assert {:ok, %{status: :active}} = Lease.status(env.lease, "run/" <> spec.unit)
      assert {:error, :capacity} = RunHost.start_run(host, :other, spec("other", stub([])))
      assert :ok = RunHost.reap(host, :release)
      assert {:ok, %{status: :free}} = Lease.status(env.lease, "run/" <> spec.unit)
      assert :ok = RunHost.start_run(host, :other, spec("other", stub([])))
    end

    test "a start and a wake waiting on an unconfirmed release are answered without a third request" do
      test = self()
      {:ok, hold} = Agent.start_link(fn -> false end)

      hook = fn
        :before_lock, %{key: "run/handover"} ->
          if Agent.get_and_update(hold, &{&1, false}) do
            send(test, {:releasing, self()})
            receive do: (:fail -> raise("the release fails"))
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {cell, proof} = proof_cell()
      {host, specs} = host(env, max_runs: 1, fencing_proof: proof)
      spec = spec("handover", stub([]))
      remember(specs, :handover, spec)

      assert :ok = attribute(host, fn -> RunHost.start_run(host, :handover, spec) end)
      assert [_unit, _writer | _] = unit = unit_pids(state(host).units, "unit/" <> spec.unit)
      worker = run(host, :handover).worker
      Agent.update(hold, fn _ -> true end)
      reap = Task.async(fn -> RunHost.reap(host, :handover) end)
      assert_receive {:releasing, releaser}, 5_000

      start = Task.async(fn -> RunHost.start_run(host, :handover, spec) end)
      eventually(fn -> length(run(host, :handover).deferred) == 1 end)
      wake = Task.async(fn -> RunHost.wake(host, [:handover]) end)
      eventually(fn -> length(run(host, :handover).deferred) == 2 end)
      # Every process of the torn-down tenure is gone, its Unit and Writer included: the
      # start may open its journal.
      prove(cell, spawned() ++ unit, worker)
      send(releaser, :fail)

      assert {:error, :release_unconfirmed} = Task.await(reap)
      # The start takes the key over; the wake then finds the Run reserved.
      assert :ok = Task.await(start)
      assert [handover: {:error, :running}] = Task.await(wake)
      assert %{phase: :live} = run(host, :handover)

      assert {:ok, %{status: :active, holder: %{owner: "node-a"}}} =
               Lease.status(env.lease, "run/handover")
    end

    test "a failed start whose release is not confirmed keeps its reservation and tries the release again" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      # The claim passes; the release fails twice and then passes.
      hook = fn
        :before_lock, %{key: "run/failing"} ->
          if Agent.get_and_update(calls, &{&1, &1 + 1}) in [1, 2], do: raise("the release fails")

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {host, _} = host(env, max_runs: 1)
      spec = spec("failing", stub([]))

      assert {:error, {:start_failed, {:engine, :invalid_options_or_recovery}}} =
               RunHost.start_run(host, :failing, %{spec | request_cap: 0})

      # The reservation, and the responsibility for the lease, stay with the host.
      assert {:error, :capacity} = RunHost.start_run(host, :other, spec("other", stub([])))

      assert {:ok, %{status: :active, holder: %{owner: "node-a"}}} =
               Lease.status(env.lease, "run/failing")

      eventually(fn -> run(host, :failing) == nil end)
      assert {:ok, %{status: :free}} = Lease.status(env.lease, "run/failing")
      assert Agent.get(calls, & &1) == 4
      assert :ok = RunHost.start_run(host, :other, spec("other", stub([])))
    end

    test "a reap that joins a failed start's unconfirmed release: the release is still tried until confirmed, and a start then succeeds with no other call" do
      test = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      # The claim passes; the first release waits for the test and fails; the next passes.
      hook = fn
        :before_lock, %{key: "run/joined"} ->
          if Agent.get_and_update(calls, &{&1, &1 + 1}) == 1 do
            send(test, {:releasing, self()})
            receive do: (:fail -> raise("the release fails"))
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {host, _} = host(env, max_runs: 1)
      spec = spec("joined", stub([]))
      start = Task.async(fn -> RunHost.start_run(host, :joined, %{spec | request_cap: 0}) end)
      assert_receive {:releasing, releaser}, 5_000

      reap = Task.async(fn -> RunHost.reap(host, :joined) end)
      eventually(fn -> match?(%{reap: true}, run(host, :joined)) end)
      send(releaser, :fail)

      assert {:error, {:start_failed, {:engine, :invalid_options_or_recovery}}} =
               Task.await(start)

      assert {:error, :release_unconfirmed} = Task.await(reap)

      # The failed start keeps its release obligation, tried again with no other call.
      eventually(fn -> run(host, :joined) == nil end)
      assert {:ok, %{status: :free}} = Lease.status(env.lease, "run/joined")
      assert Agent.get(calls, & &1) == 3
      assert :ok = RunHost.start_run(host, :other, spec("other", stub([])))
    end

    test "a wake that waits on an unconfirmed release and ends before its claim: the old lease is still released, so another owner can claim it" do
      test = self()
      {:ok, hold} = Agent.start_link(fn -> false end)

      hook = fn
        :before_lock, %{key: "run/orphaned"} ->
          if Agent.get_and_update(hold, &{&1, false}) do
            send(test, {:releasing, self()})
            receive do: (:fail -> raise("the release fails"))
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {host, _} = host(env, max_runs: 1)
      spec = spec("orphaned", stub([]))

      assert :ok = RunHost.start_run(host, :orphaned, spec)
      Agent.update(hold, fn _ -> true end)
      reap = Task.async(fn -> RunHost.reap(host, :orphaned) end)
      assert_receive {:releasing, releaser}, 5_000

      # No spec is remembered for the Run: the wake's spec callback answers
      # {:error, :unknown_run}, so its tenure ends before it claims the key.
      wake = Task.async(fn -> RunHost.wake(host, [:orphaned]) end)
      eventually(fn -> length(run(host, :orphaned).deferred) == 1 end)
      send(releaser, :fail)

      assert {:error, :release_unconfirmed} = Task.await(reap)
      assert [orphaned: {:error, {:spec, :unknown_run}}] = Task.await(wake)

      # The release that the wake inherited is tried until confirmed: the key is free long
      # before the lease's 60 s expiry, and another owner claims it.
      eventually(fn -> run(host, :orphaned) == nil end)
      assert {:ok, %{status: :free}} = Lease.status(env.lease, "run/orphaned")
      assert {:held, _} = Lease.claim(env.lease, "run/orphaned", "other-node", 60_000)
    end

    test "a tenure that took an old lease over reserves its key while its spec callback runs: another Run of that Unit is refused, and the failed tenure releases only its own old lease" do
      test = self()
      {:ok, hold} = Agent.start_link(fn -> false end)

      hook = fn
        :before_lock, %{key: "run/inherited"} ->
          if Agent.get_and_update(hold, &{&1, false}) do
            send(test, {:releasing, self()})
            receive do: (:fail -> raise("the release fails"))
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])

      # The wake's spec callback, in the new tenure's worker, waits for the test's answer.
      held_spec = fn :inherited ->
        send(test, {:spec_held, self()})
        receive do: ({:answer, answer} -> answer)
      end

      {host, _} = host(env, max_runs: 2, spec: held_spec)
      spec = spec("inherited", stub([]))
      assert :ok = RunHost.start_run(host, :inherited, spec)
      Agent.update(hold, fn _ -> true end)
      reap = Task.async(fn -> RunHost.reap(host, :inherited) end)
      assert_receive {:releasing, releaser}, 5_000

      wake = Task.async(fn -> RunHost.wake(host, [:inherited]) end)
      eventually(fn -> length(run(host, :inherited).deferred) == 1 end)
      send(releaser, :fail)
      assert {:error, :release_unconfirmed} = Task.await(reap)

      # The wake's tenure owes the release of the old lease, and has no Unit yet.
      assert_receive {:spec_held, callback}, 5_000
      assert %{phase: :starting, unit: nil, obligation: "run/inherited"} = run(host, :inherited)

      # Another Run that asks for the same Unit, and so the same lease key, is refused
      # before it claims anything.
      other = %{spec("other", stub([])) | unit: "inherited"}
      assert {:error, :identity_in_use} = RunHost.start_run(host, :other, other)
      assert run(host, :other) == nil

      # The callback fails: the tenure ends before its claim, and its cleanup releases the
      # old lease, which no other Run holds: the host keeps no Run, and another owner can
      # claim the key.
      send(callback, {:answer, {:error, :gone}})
      assert [inherited: {:error, {:spec, :gone}}] = Task.await(wake)
      eventually(fn -> run(host, :inherited) == nil end)
      assert state(host).runs == %{}
      assert {:ok, %{status: :free}} = Lease.status(env.lease, "run/inherited")
      assert {:held, _} = Lease.claim(env.lease, "run/inherited", "other-node", 60_000)
    end

    test "an unconfirmed release whose result reaches the host before its task exits: nothing is freed or handed over until that exit" do
      test = self()
      {:ok, hold} = Agent.start_link(fn -> false end)

      hook = fn
        :before_lock, %{key: "run/handed"} ->
          if Agent.get_and_update(hold, &{&1, false}) do
            send(test, {:releasing, self()})
            receive do: (:fail -> raise("the release fails"))
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {cell, proof} = proof_cell()
      {host, specs} = host(env, max_runs: 1, fencing_proof: proof)
      spec = spec("handed", stub([]))
      remember(specs, :handed, spec)

      assert :ok = attribute(host, fn -> RunHost.start_run(host, :handed, spec) end)
      assert [_unit, _writer | _] = unit = unit_pids(state(host).units, "unit/handed")
      %{token: token, worker: worker} = run(host, :handed)
      Agent.update(hold, fn _ -> true end)
      reap = Task.async(fn -> RunHost.reap(host, :handed) end)

      # The release task waits in the Lease backend; a start of the Run waits behind it.
      assert_receive {:releasing, releaser}, 5_000
      start = Task.async(fn -> RunHost.start_run(host, :handed, spec) end)
      eventually(fn -> length(run(host, :handed).deferred) == 1 end)
      prove(cell, spawned() ++ unit, worker)

      # The release's result, :unconfirmed, reaches the host while its task still runs (the
      # test delivers it under the job's reference, as the task delivers its result, and
      # the host has taken it once a later call returns).
      [job] = for {ref, {:release, :handed, _}} <- state(host).jobs, do: ref
      send(host, {job, :unconfirmed})
      assert %{token: ^token, phase: :releasing, deferred: [_]} = run(host, :handed)

      # Nothing frees the reservation or starts the next tenure while the task runs.
      assert Task.yield(start, 300) == nil
      assert Task.yield(reap, 0) == nil
      assert %{token: ^token, phase: :releasing} = run(host, :handed)
      assert Process.alive?(releaser)

      # Once the task has exited, the reap is answered and the start takes the key over.
      gone = Process.monitor(releaser)
      send(releaser, :fail)
      assert_receive {:DOWN, ^gone, :process, ^releaser, _}, 5_000
      assert {:error, :release_unconfirmed} = Task.await(reap)
      assert :ok = Task.await(start)
      assert %{phase: :live, token: next} = run(host, :handed)
      assert next != token

      assert {:ok, %{status: :active, holder: %{owner: "node-a"}}} =
               Lease.status(env.lease, "run/handed")
    end

    test "a callback's :DOWN that reaches the host after an unconfirmed release's result and before the release task exits frees and hands over nothing" do
      test = self()
      {:ok, hold} = Agent.start_link(fn -> false end)

      hook = fn
        :before_lock, %{key: "run/late"} ->
          if Agent.get_and_update(hold, &{&1, false}) do
            send(test, {:releasing, self()})
            receive do: (:fail -> raise("the release fails"))
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {cell, proof} = proof_cell()
      {host, specs} = host(env, max_runs: 1, fencing_proof: proof)
      spec = spec("late", stub([]))
      remember(specs, :late, spec)

      assert :ok = attribute(host, fn -> RunHost.start_run(host, :late, spec) end)
      assert [_unit, _writer | _] = unit = unit_pids(state(host).units, "unit/late")
      %{token: token, worker: worker} = run(host, :late)
      Agent.update(hold, fn _ -> true end)
      reap = Task.async(fn -> RunHost.reap(host, :late) end)

      assert_receive {:releasing, releaser}, 5_000
      start = Task.async(fn -> RunHost.start_run(host, :late, spec) end)
      eventually(fn -> length(run(host, :late).deferred) == 1 end)
      prove(cell, spawned() ++ unit, worker)

      # The release's result, :unconfirmed, reaches the host while its task still runs.
      [job] = for {ref, {:release, :late, _}} <- state(host).jobs, do: ref
      send(host, {job, :unconfirmed})
      assert %{token: ^token, phase: :releasing, deferred: [_]} = run(host, :late)

      # A callback of the tenure that had exited when finish/3 filtered the callbacks (so
      # the release started), and whose :DOWN the host takes only now: its monitor is the
      # host's, under the Run's token, and its :DOWN arrives before the release task exits.
      callback = spawn(fn -> :ok end)
      monitor = make_ref()
      :sys.replace_state(host, &put_in(&1.monitors[monitor], {:late, token, :callback}))
      send(host, {:DOWN, monitor, :process, callback, :normal})
      refute Map.has_key?(state(host).monitors, monitor)

      # That :DOWN is not the release task's: nothing is freed or handed over.
      assert Task.yield(start, 300) == nil
      assert Task.yield(reap, 0) == nil
      assert %{token: ^token, phase: :releasing, busy: true} = run(host, :late)
      assert Process.alive?(releaser)

      # The release task's own exit acts on its result.
      gone = Process.monitor(releaser)
      send(releaser, :fail)
      assert_receive {:DOWN, ^gone, :process, ^releaser, _}, 5_000
      assert {:error, :release_unconfirmed} = Task.await(reap)
      assert :ok = Task.await(start)
      assert %{phase: :live, token: next} = run(host, :late)
      assert next != token
    end
  end

  describe "callbacks" do
    test "reap stops a callback that still runs before it frees the reservation; a callback may reap its own Run" do
      env = postgres()
      test = self()
      {:ok, cell} = Agent.start_link(fn -> nil end)

      on_terminal = fn
        :blocked, _ ->
          send(test, {:callback, self()})
          receive do: (:never -> :ok)

        :reaps, _ ->
          send(test, {:reaping, self()})
          RunHost.reap(Agent.get(cell, & &1), :reaps)
      end

      {host, _} = host(env, on_terminal: on_terminal, max_runs: 1)
      Agent.update(cell, fn _ -> host end)
      stub = stub([answer("one"), answer("two")])
      blocked = spec("blocked", stub)

      assert :ok = RunHost.start_run(host, :blocked, blocked)

      assert {:ok, :applied} =
               RunHost.input(host, :blocked, "start", start_input(), verified(blocked))

      assert_receive {:callback, callback}, 10_000
      assert :ok = RunHost.reap(host, :blocked)
      refute Process.alive?(callback)
      assert run(host, :blocked) == nil

      reaps = spec("reaps", stub)
      assert :ok = RunHost.start_run(host, :reaps, reaps)
      assert {:ok, :applied} = RunHost.input(host, :reaps, "start", start_input(), verified(reaps))
      assert_receive {:reaping, reaper}, 5_000
      eventually(fn -> run(host, :reaps) == nil end)
      refute Process.alive?(reaper)
      assert :ok = RunHost.start_run(host, :after, spec("after", stub))
    end
  end

  describe "options_and_profile" do
    test "start_link refuses missing, out-of-range, malformed or inconsistent options" do
      env = postgres()
      {host, _} = host(env)
      base = Enum.reject(state(host).c, fn {k, v} -> is_nil(v) or k in [:allow_volatile, :name] end)

      name = fn ->
        Module.concat(Elzoo.RunHost.TestHost, "O#{System.unique_integer([:positive])}")
      end

      assert {:ok, _} = Elzoo.RunHost.start_link([name: name.()] ++ base)
      assert {:error, :invalid_options} = Elzoo.RunHost.start_link([:bad])

      for opts <- [
            Keyword.delete(base, :owner_id),
            Keyword.put(base, :owner_id, String.duplicate("o", 201)),
            Keyword.put(base, :lease_ttl_ms, 0),
            Keyword.put(base, :max_runs, 0),
            Keyword.put(base, :evidence_store, Keyword.fetch!(memory().stores, :evidence_store)),
            Keyword.put(base, :lease, memory().lease),
            Keyword.put(base, :unknown, 1)
          ] do
        assert {:error, :invalid_options} = Elzoo.RunHost.start_link([name: name.()] ++ opts)
      end
    end

    test "a spec with another Effect binding is refused at start; no Approval control is forwarded" do
      env = postgres()
      stub = stub([{:block, answer("late")}])
      {host, _} = host(env, notify())
      spec = spec("profile", stub)
      tool = %{spec.bindings["finish"] | id: "tool"}

      assert {:error, :outside_profile} =
               RunHost.start_run(host, :tool, %{
                 spec
                 | bindings: Map.put(spec.bindings, "tool_call", tool),
                   unit: "tool"
               })

      assert {:error, :invalid_spec} = RunHost.start_run(host, :bad, Map.delete(spec, :ai))

      assert {:error, :invalid_spec} =
               RunHost.start_run(host, :long, %{spec | unit: String.duplicate("u", 156)})

      assert :ok = RunHost.start_run(host, :profile, spec)

      assert {:error, :outside_profile} =
               RunHost.control(
                 host,
                 :profile,
                 "approval",
                 %{kind: :approval_evidence},
                 verified(spec)
               )

      assert :ok = RunHost.reap(host, :profile)
    end

    test "Unit identities cannot name another Run's streams" do
      env = postgres()
      stub = stub([answer("one"), answer("two")])
      {host, _} = host(env, notify())
      x = spec("x", stub)
      y = spec("y", stub, unit: "run/x")

      for {ref, spec} <- [x: x, y: y] do
        assert :ok = RunHost.start_run(host, ref, spec)
        assert {:ok, :applied} = RunHost.input(host, ref, "start", start_input(), verified(spec))
        assert_receive {:terminal, ^ref, :completed}, 10_000
      end

      assert Enum.sort(streams(env, "%x")) == [
               "evidence/run/x",
               "evidence/x",
               "run/run/x",
               "run/x",
               "unit/run/x",
               "unit/x"
             ]
    end

    test "an exit of a Registry of the host stops the host with that reason" do
      env = postgres()
      {host, _} = host(env)
      ref = Process.monitor(host)
      Process.exit(Process.whereis(state(host).names), :kill)
      assert_receive {:DOWN, ^ref, :process, ^host, :killed}, 5_000
    end

    test "a host without a name takes the Registry names of its owner_id, the same after a restart" do
      env = postgres()
      {opts, _} = host_options(env, name: nil, owner_id: "node-stable")
      child = %{id: :stable, start: {RunHost, :start_link, [opts]}, restart: :temporary}
      names = {:"Elixir.Elzoo.RunHost.node-stable.Units", :"Elixir.Elzoo.RunHost.node-stable.Names"}

      first = start_supervised!(child)
      assert {state(first).units, state(first).names} == names
      # One host per name in a VM: a second host on the same names is refused.
      assert {:error, {:already_started, _}} = RunHost.start_link(opts)
      :ok = stop_supervised!(:stable)

      second = start_supervised!(child)
      assert {state(second).units, state(second).names} == names
    end

    test "a Run's group leader ends with its reap, and with its host when the host stops normally" do
      env = postgres()
      {host, _} = host(env)

      assert :ok = RunHost.start_run(host, :relayed, spec("relayed", stub([])))
      gl = run(host, :relayed).gl
      assert :ok = RunHost.reap(host, :relayed)
      refute Process.alive?(gl)

      assert :ok = RunHost.start_run(host, :stopped, spec("stopped", stub([])))
      gl = run(host, :stopped).gl
      assert :ok = GenServer.stop(host)
      refute Process.alive?(gl)
    end

    test "a killed host: its link ends the Run's worker with the host's own exit, and every process of the Run ends" do
      env = postgres()
      {host, _} = host(env)
      spec = spec("orphan", stub([]))
      assert :ok = attribute(host, fn -> RunHost.start_run(host, :orphan, spec) end)
      %{worker: worker} = run(host, :orphan)
      pids = spawned() ++ unit_pids(state(host).units, "unit/orphan")
      assert worker in pids
      ref = Process.monitor(worker)
      Process.exit(host, :kill)
      # The host's exit reason reaches the worker only through their link.
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 5_000
      eventually(fn -> alive_pids(pids) == [] end)
    end
  end
end
