# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_host_test_helper.exs", __DIR__)

defmodule Elzoo.RunHostAiTest do
  # The AI text bindings of the host on disposable PostgreSQL with the scripted stub of
  # integration/ai-text-anthropic: admission refusals, the sink route, the outcome
  # translation and the pause operand. The engine inputs and sink calls are observed
  # by call tracing.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Elzoo.RunHost.TestHelper
  alias Elzoo.{AiText, RunEngine, RunHost}
  alias Elzoo.DurableLog.PostgresHarness
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

  describe "admission_refusal" do
    test "a request with an image part is settled refused, with no intent and no stub call" do
      env = postgres()
      stub = stub([answer("never sent")])
      {host, _} = host(env, notify())
      spec = spec("image", stub, pattern: agent(image_input: true))
      image = %{"artifact" => %{"id" => "img-1", "version" => 1}, "media_type" => "image/png"}

      assert :ok = RunHost.start_run(host, :image, spec)

      assert {:ok, :applied} =
               RunHost.input(
                 host,
                 :image,
                 "start",
                 start_input("Look.", %{"images" => [image]}),
                 verified(spec)
               )

      assert_receive {:terminal, :image, :failed}, 5_000
      entries = transcript(host, :image, spec)
      occurrence = hd(for %{type: :gate, occurrence: o} <- entries, do: o)

      assert [%{verdict: :deny, reason: "unsupported_feature"}] =
               for(%{type: :gate, occurrence: ^occurrence} = e <- entries, do: e)

      assert [%{outcome: "refused", reason: "unsupported_feature", actual: 0}] =
               settlements(entries, "bot:m:1")

      assert requests(stub) == []
      assert streams(env, "intent/%") == []
      assert streams(env, "intent-host/%") == []
      assert :ok = RunHost.reap(host, :image)
    end
  end

  describe "sink_route" do
    test "the key derives from the Run, the action's Attempt and its ID; a duplicate delivery gives no second input" do
      env = postgres()
      stub = stub([answer("once")])
      {host, _} = host(env, notify())
      spec = spec("dup", stub)
      trace([{AiText.Sink, :deliver, 4}, {RunEngine, :input, 4}])

      assert :ok = RunHost.start_run(host, :dup, spec)
      assert {:ok, :applied} = RunHost.input(host, :dup, "start", start_input(), verified(spec))
      assert_receive {:terminal, :dup, :completed}, 5_000
      assert_receive {:trace, _, :call, {AiText.Sink, :deliver, [sink, key, attempt, outcome]}}

      reference =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary({spec.run_id, spec.attempt_id, "bot:m:1"}, [:deterministic])
        )
        |> Base.encode16(case: :lower)

      assert key ==
               Model.key([
                 "tenant",
                 "anthropic:test-workspace",
                 "run-host-test",
                 "generate",
                 reference
               ])

      assert streams(env, "intent/%") == [Model.stream(key)]

      first = engine_input(&ai_input?/1)
      assert first.reply == {:ok, :applied}
      occurrence = occurrence(transcript(host, :dup, spec), "bot:m:1")
      assert first.id == Ai.input_id(spec.run_id, spec.attempt_id, occurrence)
      assert byte_size(first.id) == 67

      assert first.context == %{
               run_id: spec.run_id,
               attempt_id: spec.attempt_id,
               occurrence: occurrence,
               dispatch: "dispatched",
               actual: 2_598
             }

      assert first.frame["outcome"] == "completed"
      assert first.frame["schema_id"] == "elzoo.ai-text.result"

      assert Map.keys(first.frame["payload"]) |> Enum.sort() == [
               "content",
               "finish",
               "tool_proposals"
             ]

      assert :ok = AiText.Sink.deliver(sink, key, attempt, outcome)
      _ = :sys.get_state(run(host, :dup).worker)
      id = first.id
      refute_receive {:trace, _, :call, {RunEngine, :input, [_, ^id | _]}}, 300

      assert [%{outcome: "completed", actual: 2_598}] =
               settlements(transcript(host, :dup, spec), "bot:m:1")

      assert length(ai_inputs(env, spec)) == 1
      assert length(requests(stub)) == 1
    end

    test "under budget_rule :pause the duplicate is recognized after the context gives another pause deadline" do
      env = postgres()
      stub = stub([answer("paused rule")])
      {host, _} = host(env, notify())
      {:ok, samples} = Agent.start_link(fn -> 0 end)

      context = fn ->
        n = Agent.get_and_update(samples, &{&1, &1 + 1})

        %{
          policy: policy(),
          authority: [%{target: "document", field: "published", value: true}],
          resource_names: ["document"],
          pause_deadline: clock() + 600_000 + n
        }
      end

      spec = spec("pause", stub, budget_rule: :pause, context: context)
      trace([{AiText.Sink, :deliver, 4}, {RunEngine, :input, 4}])

      assert :ok = RunHost.start_run(host, :pause, spec)

      assert {:ok, :applied} =
               RunHost.input(
                 host,
                 :pause,
                 "start",
                 start_input(),
                 verified(spec, %{pause_deadline: clock() + 600_000})
               )

      assert_receive {:terminal, :pause, :completed}, 5_000
      assert_receive {:trace, _, :call, {AiText.Sink, :deliver, [sink, key, attempt, outcome]}}
      first = engine_input(&ai_input?/1)
      assert first.reply == {:ok, :applied}
      assert is_integer(first.context.pause_deadline)
      assert context.().pause_deadline != first.context.pause_deadline

      assert :ok = AiText.Sink.deliver(sink, key, attempt, outcome)
      _ = :sys.get_state(run(host, :pause).worker)
      id = first.id
      refute_receive {:trace, _, :call, {RunEngine, :input, [_, ^id | _]}}, 300
      assert [{_, record}] = ai_inputs(env, spec)
      assert record.context.pause_deadline == first.context.pause_deadline
      assert [%{outcome: "completed"}] = settlements(transcript(host, :pause, spec), "bot:m:1")
    end

    test "acknowledged inputs: no second journal input after Unit dedup eviction, no submission by a retry after success" do
      env = postgres(harness: true)

      stub =
        stub(fn
          "call a" -> answer("a")
          "call b" -> {:block, answer("b")}
        end)

      {host, _} = host(env, notify())
      spec = spec("acked", stub, pattern: two_calls(), retention: 1)
      trace([{AiText.Sink, :deliver, 4}, {RunEngine, :input, 4}])

      assert :ok = RunHost.start_run(host, :acked, spec)
      assert {:ok, :applied} = RunHost.input(host, :acked, "start", start_input(), verified(spec))
      assert_receive {:stub_entered, blocked}, 5_000
      a = delivery!("a")
      eventually(fn -> length(settlements(transcript(host, :acked, spec), "a")) == 1 end)

      # The next Unit read fails: the outcome of b is not taken and is retried.
      PostgresHarness.hook(env.stores[:unit_store], :inject, [:read, :unavailable])
      send(blocked, :release)
      b = delivery!("b")
      worker = run(host, :acked).worker
      eventually(fn -> map_size(:sys.get_state(worker).retries) == 1 end)
      apply(AiText.Sink, :deliver, b)
      assert_receive {:terminal, :acked, :completed}, 5_000
      Process.sleep(500)
      [_, key_b | _] = b
      id_b = input_of(host, :acked, spec, key_b)
      b_calls = for {:trace, _, :call, {RunEngine, :input, [_, ^id_b | _]}} <- messages(), do: id_b
      assert length(b_calls) == 2

      # After the finish, a's input ID left the Unit's retention of 1.
      apply(AiText.Sink, :deliver, a)
      _ = :sys.get_state(worker)
      assert length(ai_inputs(env, spec)) == 2
      assert [%{outcome: "completed"}] = settlements(transcript(host, :acked, spec), "a")
    end

    test "a timeout is dispatch unknown with no actual" do
      env = postgres()
      stub = stub([{:transport_error, :timeout}])
      {host, _} = host(env, notify())
      spec = spec("timeout", stub)

      assert :ok = RunHost.start_run(host, :timeout, spec)
      assert {:ok, :applied} = RunHost.input(host, :timeout, "start", start_input(), verified(spec))
      assert_receive {:terminal, :timeout, :failed}, 5_000

      assert [{_, record}] = ai_inputs(env, spec)
      assert record.input["outcome"] == "unknown"

      assert record.input["payload"] == %{
               "reason" => "timeout",
               "retry_after" => nil,
               "candidate" => nil
             }

      assert record.correlation == %{occurrence: record.correlation.occurrence, dispatch: "unknown"}

      assert [%{outcome: "unknown", actual: :unknown}] =
               settlements(transcript(host, :timeout, spec), "bot:m:1")
    end

    test "a completion over the engine's payload bound is refused too_large, dispatched, with no actual" do
      env = postgres()
      stub = stub([answer(String.duplicate("x", 70 * 1_024))])
      {host, _} = host(env, notify())
      spec = spec("large", stub)

      assert :ok = RunHost.start_run(host, :large, spec)
      assert {:ok, :applied} = RunHost.input(host, :large, "start", start_input(), verified(spec))
      assert_receive {:terminal, :large, :failed}, 5_000

      assert [{_, record}] = ai_inputs(env, spec)
      assert record.input["outcome"] == "refused"
      assert record.input["schema_id"] == "elzoo.ai-text.result"

      assert record.input["payload"] == %{
               "reason" => "too_large",
               "retry_after" => nil,
               "candidate" => nil
             }

      assert record.correlation == %{
               occurrence: record.correlation.occurrence,
               dispatch: "dispatched"
             }

      # No actual: the call's reservation stays reserved.
      assert [%{outcome: "refused", actual: :unknown}] =
               settlements(transcript(host, :large, spec), "bot:m:1")

      assert {:failed, %{payload: %{"reason" => "model_call_not_completed"}}} =
               RunHost.result(host, :large, scope(spec), limits())

      assert length(requests(stub)) == 1
    end

    test "a small completion whose tool arguments reach the engine's 32 levels is refused too_large, dispatched, with no actual; its reservation stays reserved" do
      # 30 nested objects in the arguments: the deepest sits at level 32 of the
      # completed view (view 0, tool_proposals 1, proposal 2, arguments 3).
      {host, env, spec, stub} = deep_call("deep", 30)

      assert [{_, record}] = ai_inputs(env, spec)
      assert record.input["kind"] == "action_outcome"
      assert record.input["action_id"] == "deep"
      assert record.input["outcome"] == "refused"
      assert record.input["schema_id"] == "elzoo.ai-text.result"
      assert record.input["schema_version"] == 1

      assert record.input["payload"] == %{
               "reason" => "too_large",
               "retry_after" => nil,
               "candidate" => nil
             }

      # Dispatched, and no actual although the provider reported a usage that converts.
      assert record.correlation == %{
               occurrence: record.correlation.occurrence,
               dispatch: "dispatched"
             }

      assert [%{outcome: "refused", actual: :unknown}] =
               settlements(transcript(host, :deep, spec), "deep")

      # The call's reservation (its estimate of 1,000) stays reserved; nothing committed.
      assert %{reserved: 1_000, committed: 0} = budget(host, spec)
      assert length(requests(stub)) == 1
    end

    test "the same completion one level shallower settles completed with its actual" do
      {host, env, spec, _} = deep_call("shallow", 29)
      assert_receive {:terminal, :shallow, :completed}, 5_000

      assert [{_, record}] = ai_inputs(env, spec)
      assert record.input["outcome"] == "completed"

      assert [%{"arguments" => arguments, "malformed" => nil}] =
               record.input["payload"]["tool_proposals"]

      assert arguments == nested(29)

      assert record.correlation == %{
               occurrence: record.correlation.occurrence,
               dispatch: "dispatched",
               actual: 2_598
             }

      assert [%{outcome: "completed", actual: 2_598}] =
               settlements(transcript(host, :shallow, spec), "shallow")

      assert %{reserved: 0} = budget(host, spec)
    end

    test "a sink failure gives no input, and no delivery gives no settlement" do
      env = postgres()
      stub = stub([{:block, answer("held")}])
      {host, _} = host(env, notify())
      spec = spec("silent", stub)
      trace([{AiText.Adapter, :send_effect, 1}])

      assert :ok = RunHost.start_run(host, :silent, spec)
      assert {:ok, :applied} = RunHost.input(host, :silent, "start", start_input(), verified(spec))
      assert_receive {:stub_entered, _}, 5_000
      assert_receive {:trace, _, :call, {AiText.Adapter, :send_effect, [request]}}
      worker = run(host, :silent).worker

      log =
        capture_log(fn ->
          assert :ok = request.context.sink.(request.key, {:sink_failed, request.attempt_id})
          _ = :sys.get_state(worker)
        end)

      assert log =~ "a sink failure"
      Process.sleep(200)
      assert ai_inputs(env, spec) == []
      assert {:ok, %{slots: slots, outcome: nil}} = RunHost.status(host, :silent)
      assert [%{phase: :running}] = for({_, %{action_id: "bot:m:1"} = slot} <- slots, do: slot)
      assert settlements(transcript(host, :silent, spec), "bot:m:1") == []
      assert :ok = RunHost.reap(host, :silent)
      assert length(requests(stub)) == 1
    end

    test "an outcome is kept when the route cannot be read for a moment, and settles once" do
      env = postgres(harness: true)
      stub = stub([{:block, answer("after a failed read")}])
      {host, _} = host(env, notify())
      spec = spec("transient", stub)

      assert :ok = RunHost.start_run(host, :transient, spec)

      assert {:ok, :applied} =
               RunHost.input(host, :transient, "start", start_input(), verified(spec))

      assert_receive {:stub_entered, blocked}, 5_000
      PostgresHarness.hook(env.stores[:unit_store], :inject, [:read, :unavailable])
      send(blocked, :release)
      assert_receive {:terminal, :transient, :completed}, 5_000
      assert [%{outcome: "completed"}] = settlements(transcript(host, :transient, spec), "bot:m:1")
    end

    test "a successful call held past idle_ms keeps its Unit awake and settles completed" do
      env = postgres()
      stub = stub([{:block, answer("slow but complete")}])
      {host, _} = host(env, notify() ++ [idle_ms: 300])
      spec = spec("awake", stub)

      assert :ok = RunHost.start_run(host, :awake, spec)
      assert {:ok, :applied} = RunHost.input(host, :awake, "start", start_input(), verified(spec))
      assert_receive {:stub_entered, blocked}, 5_000
      Process.sleep(1_200)
      send(blocked, :release)
      assert_receive {:terminal, :awake, :completed}, 5_000
      assert [%{outcome: "completed"}] = settlements(transcript(host, :awake, spec), "bot:m:1")
    end

    test "a begin_attempt in the middle of a Run: an old-Attempt delivery and a new-Attempt call each route and settle once" do
      env = postgres()

      stub =
        stub(fn
          "call m1" -> {:block, answer("old Attempt")}
          "call m2" -> answer("new Attempt")
        end)

      {host, _} = host(env, notify())
      trace([{RunEngine, :input, 4}])
      spec = spec("attempts", stub, pattern: starts())

      assert :ok = RunHost.start_run(host, :attempts, spec)

      assert {:ok, :applied} =
               RunHost.input(host, :attempts, "start", start_input(), verified(spec))

      assert_receive {:stub_entered, blocked}, 5_000

      assert {:ok, :applied} =
               RunHost.control(
                 host,
                 :attempts,
                 "second",
                 %{kind: :begin_attempt, attempt_id: "second"},
                 verified(spec)
               )

      second = %{spec | attempt_id: "second"}

      assert {:ok, :applied} =
               RunHost.input(host, :attempts, "start-2", start_input(), verified(second))

      eventually(fn -> length(settlements(transcript(host, :attempts, spec), "m2")) == 1 end)

      {context, log} =
        with_log(fn ->
          send(blocked, :release)

          receive do
            {:trace, _, :call,
             {RunEngine, :input, [_, "ai:" <> _, %{"action_id" => "m1"}, context]}} ->
              context
          after
            5_000 -> flunk("the old-Attempt delivery reached no engine input")
          end
          |> tap(fn _ -> _ = :sys.get_state(run(host, :attempts).worker) end)
        end)

      refute log =~ "no route"
      assert context.attempt_id == spec.attempt_id
      entries = transcript(host, :attempts, spec)
      assert [%{outcome: "unknown"}] = settlements(entries, "m1")
      assert [%{outcome: "completed"}] = settlements(entries, "m2")

      d = descriptor(stub)
      {:ok, b} = AiText.Binding.load(d.ai_text[:binding])

      for {action, attempt} <- [{"m1", spec.attempt_id}, {"m2", "second"}] do
        key =
          Model.key([
            "tenant",
            b.provider_account,
            b.id,
            "generate",
            Ai.ref(spec.run_id, attempt, action)
          ])

        assert Model.stream(key) in streams(env, "intent/%")
      end

      assert :ok = RunHost.reap(host, :attempts)
    end
  end

  describe "unit_awake" do
    test "a cold first dispatch with a short idle_ms: the Unit stays awake through the catalog load, with no caller warm-up" do
      env = postgres()
      stub = stub([answer("cold")])
      {host, _} = host(env, notify() ++ [idle_ms: 300])
      spec = spec("cold", stub)
      assert :ok = RunHost.start_run(host, :cold, spec)

      # The adapter's model catalog is unloaded: the first admission loads it again
      # while the engine's input waits, far longer than idle_ms.
      LLMDB.Store.clear!()

      {micros, reply} =
        :timer.tc(fn -> RunHost.input(host, :cold, "start", start_input(), verified(spec)) end)

      assert reply == {:ok, :applied}
      assert micros > 300_000
      assert_receive {:terminal, :cold, :completed}, 5_000
      assert [%{outcome: "completed"}] = settlements(transcript(host, :cold, spec), "bot:m:1")
    end

    test "a transcript read that holds the worker past idle_ms while a call is in flight: the Unit stays awake and the call settles completed" do
      env = postgres()
      stub = stub([{:block, answer("after the held read")}])
      {host, _} = host(env, notify() ++ [idle_ms: 300])
      spec = spec("held-read", stub)
      units = state(host).units

      assert :ok = RunHost.start_run(host, :held_read, spec)

      assert {:ok, :applied} =
               RunHost.input(host, :held_read, "start", start_input(), verified(spec))

      assert_receive {:stub_entered, blocked}, 5_000
      %{worker: worker, pids: %{engine: engine}} = run(host, :held_read)
      [{unit, _}] = Registry.lookup(units, "unit/held-read")

      # The delivery's key is not in the route read at the start: the worker reads the
      # transcript, and that read waits in the suspended engine for five idle periods.
      :sys.suspend(engine)
      send(blocked, :release)

      eventually(fn ->
        {:messages, messages} = Process.info(engine, :messages)
        Enum.any?(messages, &match?({:"$gen_call", {^worker, _}, {:transcript, _, _}}, &1))
      end)

      Process.sleep(1_500)
      assert [{^unit, _}] = Registry.lookup(units, "unit/held-read")
      :sys.resume(engine)
      assert_receive {:terminal, :held_read, :completed}, 5_000

      assert [%{outcome: "completed"}] =
               settlements(transcript(host, :held_read, spec), "bot:m:1")
    end

    test "an idle Run sleeps: with no input in progress and no call in flight its keep-alive touches nothing" do
      env = postgres()
      {host, _} = host(env, notify() ++ [idle_ms: 200])
      spec = spec("idle", stub([]))
      units = state(host).units

      assert :ok = RunHost.start_run(host, :idle_unit, spec)
      %{pids: %{keep_alive: keep_alive}} = run(host, :idle_unit)
      eventually(fn -> Registry.lookup(units, "unit/idle") == [] end)
      assert Process.alive?(keep_alive)
      assert {:ok, %{phase: :active}} = RunHost.status(host, :idle_unit)
      assert :ok = RunHost.reap(host, :idle_unit)
    end
  end

  describe "route_verification" do
    test "a wake whose route cannot be read is {:route, :history}, never woken, and leaves no Run" do
      {host, env, _} = woken_once("unread")
      hold_engine(state(host).names, "unit/unread")
      wake = Task.async(fn -> RunHost.wake(host, [:unread]) end)
      assert_receive {:engine_held, engine}, 10_000
      prune!(env, "unit/unread")
      :sys.resume(engine)
      assert [unread: {:error, {:route, :history}}] = Task.await(wake)
      assert run(host, :unread) == nil
    end

    test "a wake whose route read fails for a moment and then for good is {:route, :history}, never woken" do
      {host, env, _} = woken_once("flaky", harness: true)
      hold_engine(state(host).names, "unit/flaky")
      wake = Task.async(fn -> RunHost.wake(host, [:flaky]) end)
      assert_receive {:engine_held, engine}, 10_000
      # The first read finds the Unit view unavailable; the next one a pruned history.
      PostgresHarness.hook(env.stores[:unit_store], :inject, [:read, :unavailable])
      prune!(env, "unit/flaky")
      :sys.resume(engine)
      assert [flaky: {:error, {:route, :history}}] = Task.await(wake)
      assert run(host, :flaky) == nil
    end

    test "a live Run whose route cannot be read for good reports its delivery and gives no input" do
      env = postgres()
      stub = stub([{:block, answer("unroutable")}])
      {host, _} = host(env, notify())
      spec = spec("lost-route", stub)
      trace([{AiText.Sink, :deliver, 4}])
      assert :ok = RunHost.start_run(host, :lost_route, spec)

      assert {:ok, :applied} =
               RunHost.input(host, :lost_route, "start", start_input(), verified(spec))

      assert_receive {:stub_entered, blocked}, 5_000
      prune!(env, "unit/lost-route")

      log =
        capture_log(fn ->
          send(blocked, :release)
          assert_receive {:trace, _, :return_from, {AiText.Sink, :deliver, 4}, :ok}, 5_000
          _ = :sys.get_state(run(host, :lost_route).worker)
        end)

      assert log =~ "an outcome that cannot be routed (:history)"
      assert ai_inputs(env, spec) == []
      assert {:ok, %{slots: slots, outcome: nil}} = RunHost.status(host, :lost_route)
      assert [%{phase: :running}] = for({_, %{action_id: "bot:m:1"} = slot} <- slots, do: slot)
      assert %{phase: :live} = run(host, :lost_route)
    end

    test "a sink failure held during a wake's route verification is reported once the route is read; the worker goes on" do
      {host, env, spec} = woken_once("buffered", harness: true)
      inputs = ai_inputs(env, spec)
      hold_engine(state(host).names, "unit/buffered")
      trace([{AiText, :configure, 1}])
      {:ok, binding} = AiText.Binding.load(Elzoo.RunHost.TestBinding)

      key =
        Model.key([
          "tenant",
          binding.provider_account,
          binding.id,
          "generate",
          Ai.ref(spec.run_id, spec.attempt_id, "bot:m:1")
        ])

      log =
        capture_log(fn ->
          wake = Task.async(fn -> RunHost.wake(host, [:buffered]) end)

          assert_receive {:trace, _, :return_from, {AiText, :configure, 1}, {:ok, config}},
                         5_000

          assert_receive {:engine_held, engine}, 10_000
          # The worker waits in its first route read; the Run's own sink hands it a sink
          # failure for the routed call, and the read then fails for a moment.
          assert :ok = config.sink.(key, {:sink_failed, "attempt-1"})
          PostgresHarness.hook(env.stores[:unit_store], :inject, [:read, :unavailable])
          :sys.resume(engine)
          assert [buffered: :woken] = Task.await(wake)
          _ = :sys.get_state(run(host, :buffered).worker)
        end)

      assert log =~ "a sink failure"
      %{phase: :live, worker: worker} = run(host, :buffered)
      assert Process.alive?(worker)
      assert ai_inputs(env, spec) == inputs
    end
  end

  # A Run answered once and reaped, its every process gone (attributed without the
  # host): a wake of it passes the predecessor check with that demonstrated proof.
  defp woken_once(name, opts \\ []) do
    env = postgres(Keyword.take(opts, [:harness]))
    stub = stub([answer("first")])
    {cell, proof} = proof_cell()
    {host, specs} = host(env, notify() ++ [fencing_proof: proof])
    ref = String.to_atom(name)
    spec = spec(name, stub)
    remember(specs, ref, spec)

    assert :ok = attribute(host, fn -> RunHost.start_run(host, ref, spec) end)
    assert {:ok, :applied} = RunHost.input(host, ref, "start", start_input(), verified(spec))
    assert_receive {:terminal, ^ref, :completed}, 5_000
    assert :ok = RunHost.reap(host, ref)
    Agent.update(cell, fn _ -> spawned() end)
    {host, env, spec}
  end

  # One model call `name` whose provider answers a tool proposal with `depth` nested
  # objects as its arguments (with the stub's default usage, 2,598 tokens): the Run
  # once its call has settled.
  defp deep_call(name, depth) do
    env = postgres()
    body = AiText.AnthropicStub.message([AiText.AnthropicStub.tool_use(nested(depth))], "tool_use")
    stub = stub([AiText.AnthropicStub.ok(body)])
    {host, _} = host(env, notify())
    ref = String.to_atom(name)
    spec = spec(name, stub, pattern: tool_call(name))

    assert :ok = RunHost.start_run(host, ref, spec)
    assert {:ok, :applied} = RunHost.input(host, ref, "start", start_input(), verified(spec))
    eventually(fn -> settlements(transcript(host, ref, spec), name) != [] end)
    {host, env, spec, stub}
  end

  # `depth` objects, each the only member of the one around it.
  defp nested(depth),
    do: Enum.reduce(2..depth//1, %{"leaf" => true}, fn _, inner -> %{"next" => inner} end)

  describe "translation" do
    @usage %{
      counters: [
        %{unit: :input_uncached_tokens, amount: 5},
        %{unit: :output_tokens, amount: 2},
        %{unit: :cache_read_tokens, amount: :unknown}
      ],
      cache_writes: [],
      convention: %{input_includes_cached: false},
      source: :provider_reported
    }

    test "every outcome of ai-text has one input form, and only a reported usage gives an actual" do
      body = %{
        content: "text",
        finish: :tool_calls,
        tool_proposals: [%{id: "t1", name: "lookup", arguments: %{"q" => 1}, malformed: nil}],
        structured: nil,
        usage: @usage,
        provenance: %{}
      }

      view = %{
        "content" => "text",
        "finish" => "tool_calls",
        "tool_proposals" => [
          %{"id" => "t1", "name" => "lookup", "arguments" => %{"q" => 1}, "malformed" => nil}
        ]
      }

      assert {:input, "completed", "dispatched", 7, ^view} =
               Ai.translate({:completed, body}, &tokens/1)

      assert {:input, "completed", "dispatched", nil, _} =
               Ai.translate({:completed, %{body | usage: %{@usage | source: :unknown}}}, &tokens/1)

      assert {:input, "completed", "dispatched", nil, _} =
               Ai.translate({:completed, body}, fn _ -> raise "conversion" end)

      assert {:input, "completed", _, _,
              %{"finish" => %{"other" => "pause_turn"}, "tool_proposals" => [p]}} =
               Ai.translate(
                 {:completed,
                  %{
                    body
                    | finish: {:other, "pause_turn"},
                      tool_proposals: [
                        %{id: nil, name: "x", arguments: nil, malformed: :invalid_json}
                      ]
                  }},
                 &tokens/1
               )

      assert p == %{"id" => nil, "name" => "x", "arguments" => nil, "malformed" => "invalid_json"}

      for reason <- [:credentials_unavailable, :input_unavailable] do
        assert {:input, "refused", "not_dispatched", 0,
                %{"reason" => _, "retry_after" => nil, "candidate" => nil}} =
                 Ai.translate({:refused, reason, %{retry_after: nil}}, &tokens/1)
      end

      for reason <- [:throttled, :overloaded, :authentication_failed, :invalid_request, :not_found] do
        assert {:input, "refused", "dispatched", nil, %{"reason" => r, "retry_after" => 30}} =
                 Ai.translate({:refused, reason, %{retry_after: 30}}, &tokens/1)

        assert r == Atom.to_string(reason)
      end

      for reason <- [:timeout, :transport, :provider_error] do
        assert {:input, "unknown", "unknown", nil, %{"reason" => r}} =
                 Ai.translate({:unknown, reason}, &tokens/1)

        assert r == Atom.to_string(reason)
      end

      assert {:input, "unknown", "dispatched", nil, %{"reason" => "malformed_response"}} =
               Ai.translate({:unknown, :malformed_response}, &tokens/1)

      assert :none = Ai.translate({:sink_failed, "attempt"}, &tokens/1)
    end
  end

  # The traced arguments of the delivery of the call whose request text is "call <id>".
  defp delivery!(id) do
    receive do
      {:trace, _, :call, {AiText.Sink, :deliver, [_, _, _, {:completed, %{content: ^id}}] = args}} ->
        args
    after
      5_000 -> flunk("no delivery of #{id}")
    end
  end

  defp messages do
    {:messages, messages} = Process.info(self(), :messages)
    messages
  end

  # The engine input ID of the outcome of the call whose intent key is `key`.
  defp input_of(host, ref, spec, key) do
    {:ok, b} = AiText.Binding.load(Elzoo.RunHost.TestBinding)

    hd(
      for %{type: :action, kind: "model_call"} = e <- transcript(host, ref, spec),
          Model.key([
            "tenant",
            b.provider_account,
            b.id,
            "generate",
            Ai.ref(spec.run_id, e.attempt_id, e.action_id)
          ]) == key,
          do: Ai.input_id(spec.run_id, e.attempt_id, e.occurrence)
    )
  end
end
