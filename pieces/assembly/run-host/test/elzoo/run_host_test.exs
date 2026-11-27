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
    load_model_catalog()
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
    assert_receive {:terminal, :e2e, :completed}, 5_000

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
      assert_receive {:terminal, :fails, :failed}, 5_000

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
    test "max_runs holds a terminal Run that is not reaped and a Run whose Unit sleeps" do
      env = postgres()
      stub = stub([answer("one")])
      {host, _} = host(env, notify() ++ [max_runs: 2, idle_ms: 100])
      sleepy = spec("sleepy", stub)
      done = spec("done", stub)

      assert :ok = RunHost.start_run(host, :sleepy, sleepy)
      units = state(host).units
      eventually(fn -> Registry.lookup(units, "unit/" <> sleepy.unit) == [] end)
      assert {:ok, %{phase: :active}} = RunHost.status(host, :sleepy)

      before = Process.list()
      assert :ok = RunHost.start_run(host, :done, done)
      assert {:ok, :applied} = RunHost.input(host, :done, "start", start_input(), verified(done))
      assert_receive {:terminal, :done, :completed}, 5_000
      assert {:error, :capacity} = RunHost.start_run(host, :third, spec("third", stub))

      # The processes of the Run, found without the host's tracking.
      pids = new_processes(before)
      assert length(pids) >= 8
      assert :ok = RunHost.reap(host, :done)
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

      assert_receive {:callback, callback}, 5_000
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
        assert_receive {:terminal, ^ref, :completed}, 5_000
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

    test "a killed host: its links end the Run's worker, the processes that the worker started and the Unit" do
      env = postgres()
      {host, _} = host(env)
      spec = spec("orphan", stub([]))
      before = Process.list()
      assert :ok = RunHost.start_run(host, :orphan, spec)
      pids = new_processes(before)
      assert run(host, :orphan).worker in pids
      Process.exit(host, :kill)
      eventually(fn -> alive_pids(pids) == [] end)
    end
  end
end
