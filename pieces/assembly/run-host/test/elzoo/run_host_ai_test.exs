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
    load_model_catalog()
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

      assert {:failed, %{payload: %{"reason" => "model_call_not_completed"}}} =
               RunHost.result(host, :large, scope(spec), limits())

      assert length(requests(stub)) == 1
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
