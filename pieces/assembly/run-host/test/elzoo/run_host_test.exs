# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_host_test_helper.exs", __DIR__)

defmodule Elzoo.RunHostTest do
  # The host on disposable PostgreSQL (and one full Memory scenario) with the scripted
  # stub of integration/ai-text-anthropic: no network, stub keys only.
  use ExUnit.Case, async: false
  import Elzoo.RunHost.TestHelper
  alias Elzoo.RunHost

  setup_all do
    repo = database()
    on_exit(fn -> if Process.alive?(repo), do: Supervisor.stop(repo) end)
    :ok
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "end_to_end" do
    test "an AgentLoop Run answers; result/4 reads it before reap/2 and not after (PostgreSQL)" do
      end_to_end(postgres())
    end

    test "the same Run on one Memory namespace with a manual-clock Lease" do
      end_to_end(memory())
    end
  end

  defp end_to_end(env) do
    stub = stub([answer("Hello from the model.")])
    {host, _} = host(env, notify())
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
    assert :ok = RunHost.reap(host, :e2e)
    assert {:error, :not_running} = RunHost.result(host, :e2e, scope(spec), limits())
    assert {:error, :not_running} = RunHost.input(host, :e2e, "late", start_input(), verified(spec))
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
      # The host sent the start input and the model call's outcome; no cancel.
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
      eventually(fn -> Registry.lookup(units, sleepy.unit) == [] end)
      assert {:ok, %{phase: :active}} = RunHost.status(host, :sleepy)
      count = length(Process.list())

      assert :ok = RunHost.start_run(host, :done, done)
      assert {:ok, :applied} = RunHost.input(host, :done, "start", start_input(), verified(done))
      assert_receive {:terminal, :done, :completed}, 5_000
      assert {:error, :capacity} = RunHost.start_run(host, :third, spec("third", stub))

      pids = run_pids(host, :done)
      assert length(pids) >= 8
      assert alive_pids(pids) == pids
      assert :ok = RunHost.reap(host, :done)
      assert alive_pids(pids) == []
      eventually(fn -> length(Process.list()) == count end)
      assert {:ok, %{status: :free}} = Elzoo.Lease.status(env.lease, "run/" <> done.unit)

      assert :ok = RunHost.start_run(host, :third, spec("third", stub))
      assert {:error, :capacity} = RunHost.start_run(host, :fourth, spec("fourth", stub))
    end
  end

  describe "options_and_profile" do
    test "start_link refuses missing, out-of-range or inconsistent options" do
      env = postgres()
      {host, _} = host(env)
      base = Enum.reject(state(host).c, fn {k, v} -> is_nil(v) or k == :allow_volatile end)
      assert {:ok, _} = Elzoo.RunHost.start_link(base)

      for opts <- [
            Keyword.delete(base, :owner_id),
            Keyword.put(base, :owner_id, String.duplicate("o", 201)),
            Keyword.put(base, :lease_ttl_ms, 0),
            Keyword.put(base, :max_runs, 0),
            Keyword.put(base, :evidence_store, Keyword.fetch!(memory().stores, :evidence_store)),
            Keyword.put(base, :lease, memory().lease),
            Keyword.put(base, :unknown, 1)
          ] do
        assert {:error, :invalid_options} = Elzoo.RunHost.start_link(opts)
      end
    end

    test "a spec with another Effect binding is refused at start; Approval and Attempt controls are not forwarded" do
      env = postgres()
      stub = stub([{:block, answer("late")}])
      {host, _} = host(env, notify())
      spec = spec("profile", stub)
      tool = %{spec.bindings["finish"] | id: "tool"}

      assert {:error, :outside_profile} =
               RunHost.start_run(host, :tool, %{
                 spec
                 | bindings: Map.put(spec.bindings, "tool_call", tool),
                   unit: "unit-tool"
               })

      assert {:error, :invalid_spec} = RunHost.start_run(host, :bad, Map.delete(spec, :ai))

      assert :ok = RunHost.start_run(host, :profile, spec)

      for kind <- [:approval_evidence, :begin_attempt] do
        assert {:error, :outside_profile} =
                 RunHost.control(host, :profile, "c-#{kind}", %{kind: kind}, verified(spec))
      end

      assert :ok = RunHost.reap(host, :profile)
    end
  end
end
