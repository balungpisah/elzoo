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
  alias Elzoo.{AiText, RunHost}
  alias Elzoo.EffectIntent.Model
  alias Elzoo.RunHost.Ai

  setup_all do
    repo = database()
    on_exit(fn -> if Process.alive?(repo), do: Supervisor.stop(repo) end)
    :ok
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
      occurrence = occurrence_of_gate(entries)

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
    test "the key derives from the stable Run and Attempt IDs and the action ID; a duplicate delivery is a duplicate input" do
      env = postgres()
      stub = stub([answer("once")])
      {host, _} = host(env, notify())
      spec = spec("dup", stub)
      trace([{AiText.Sink, :deliver, 4}, {Elzoo.RunEngine, :input, 4}])

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
      second = engine_input(&ai_input?/1)
      assert Map.take(second, [:id, :frame, :context]) == Map.take(first, [:id, :frame, :context])
      assert second.reply == {:ok, :duplicate}

      assert [%{outcome: "completed", actual: 2_598}] =
               settlements(transcript(host, :dup, spec), "bot:m:1")

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
      trace([{AiText.Sink, :deliver, 4}, {Elzoo.RunEngine, :input, 4}])

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
      second = engine_input(&ai_input?/1)
      assert second.context == first.context
      assert second.reply == {:ok, :duplicate}
      assert [%{outcome: "completed"}] = settlements(transcript(host, :pause, spec), "bot:m:1")
    end

    test "a timeout is dispatch unknown with no actual" do
      env = postgres()
      stub = stub([{:transport_error, :timeout}])
      {host, _} = host(env, notify())
      spec = spec("timeout", stub)

      assert :ok = RunHost.start_run(host, :timeout, spec)
      assert {:ok, :applied} = RunHost.input(host, :timeout, "start", start_input(), verified(spec))
      assert_receive {:terminal, :timeout, :failed}, 5_000

      assert [{_, record}] =
               for({"ai:" <> _ = id, record} <- protocol_inputs(env, spec.unit), do: {id, record})

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
      assert for({"ai:" <> _, _} <- protocol_inputs(env, spec.unit), do: 1) == []
      assert {:ok, %{slots: slots, outcome: nil}} = RunHost.status(host, :silent)
      assert [%{phase: :running}] = for({_, %{action_id: "bot:m:1"} = slot} <- slots, do: slot)
      assert settlements(transcript(host, :silent, spec), "bot:m:1") == []
      assert :ok = RunHost.reap(host, :silent)
      assert length(requests(stub)) == 1
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

  defp occurrence_of_gate(entries), do: hd(for %{type: :gate, occurrence: o} <- entries, do: o)
end
