# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/ai_text_test_helper.exs", __DIR__)

defmodule Elzoo.AiTextTest do
  # Interface scenarios with a scripted test provider; each names its boundary.
  # The EffectIntent owner runs on the volatile Memory store (no database).
  use ExUnit.Case, async: false

  alias Elzoo.AiText
  alias Elzoo.AiText.{Adapter, Conformance, Outcome, Request, Retry, Sink, TestHelper}
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Memory

  @secret "sk-test-SECRET-k91"
  @prompt "prompt-SECRET-p33"

  setup do
    %{intents: start_supervised!({Task.Supervisor, name: nil}, id: :intent)}
  end

  ## helpers

  defp request(extra \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "model" => "test-model",
        "messages" => [%{"role" => "user", "text" => @prompt}],
        "max_output_tokens" => 64
      },
      extra
    )
  end

  defp config(opts \\ []) do
    parent = self()
    respond = Keyword.get(opts, :respond, fn _ -> {:ok, {:raw, TestHelper.raw()}} end)

    base = [
      binding: Elzoo.AiText.TestBinding,
      tenant: "tenant-a",
      provider: Keyword.get(opts, :provider, Elzoo.AiText.TestProvider),
      provider_config: %{parent: parent, respond: respond},
      credentials: Keyword.get(opts, :credentials, fn -> {:ok, @secret} end),
      models: ["test-model"],
      max_output_tokens: 1000,
      sink: Keyword.get(opts, :sink, Sink.to_pid(parent))
    ]

    base = base ++ Keyword.take(opts, [:artifacts, :image_bounds])

    {:ok, c} = AiText.configure(base)
    c
  end

  defp admit(c, req, ref \\ "req-1"),
    do: AiText.admission(c, Conformance.declaration(req, ref, 10_000))

  defp owner(c, admission, ctx) do
    memory =
      start_supervised!({Memory, fold: Intent.fold(c.binding), limits: Intent.limits()},
        id: make_ref()
      )

    host =
      start_supervised!({Memory, fold: StoreHost.fold(), limits: StoreHost.limits()},
        id: make_ref()
      )

    {:ok, pid} =
      Intent.start_link(
        binding: c.binding,
        identity: admission.identity,
        arguments: admission.arguments,
        deadline: admission.deadline,
        clock: fn -> 100 end,
        store: Memory.store(memory),
        host: {StoreHost, %{store: Memory.store(host), authorize: fn _, _ -> :fresh end}},
        task_supervisor: ctx.intents,
        adapter_context: c,
        allow_volatile: true
      )

    pid
  end

  defp settled(pid, tries \\ 250) do
    cond do
      :sys.get_state(pid).tasks == %{} -> Intent.status(pid)
      tries == 0 -> flunk("attempt never settled")
      true -> Process.sleep(20) && settled(pid, tries - 1)
    end
  end

  defp dispatch(c, req, ctx, ref \\ "req-1") do
    {:ok, a} = admit(c, req, ref)
    pid = owner(c, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    status = settled(pid)
    key = a.key
    assert_receive {AiText, ^key, delivery}, 2000
    {pid, a, status, delivery}
  end

  defp calls do
    receive do
      {:call, _, _} -> 1 + calls()
    after
      50 -> 0
    end
  end

  ## I1 call path

  test "I1 completed call through admission, EffectIntent owner and Adapter; content reaches only the sink (owner + Adapter)",
       ctx do
    c = config()
    {pid, a, status, delivery} = dispatch(c, request(), ctx)
    assert {:outcome, attempt_id, {:completed, body}} = delivery
    assert is_binary(attempt_id)
    assert body.content == "hello"
    assert body.finish == :stop
    assert body.provenance.response_id == "resp_1"
    assert body.provenance.request_id == "req_1"

    assert body.provenance.model_ref == %{
             provider: "test",
             model_id: "test-model",
             wire_surface: "scripted"
           }

    assert body.provenance.provider_piece == "test/ai-text-provider"
    assert {:Confirmed, 1} = status.phase
    assert_received {:call, @secret, 120_000}
    # Model output never in the owner's state or status (the request arguments are
    # EffectIntent's classified durable data by its Contract; status omits them).
    state = inspect(:sys.get_state(pid), limit: :infinity, printable_limit: :infinity)
    refute state =~ "hello"
    refute inspect(status) =~ "hello"
    refute inspect(status) =~ @prompt
    assert byte_size(a.arguments) > 0
  end

  ## I2 local refusals before any intent, credential or call

  test "I2 local refusals return before an intent exists, the credential Need runs or the provider is called (admission)" do
    parent = self()

    c =
      config(
        credentials: fn ->
          send(parent, :credential_read)
          {:ok, @secret}
        end
      )

    refusals = [
      {request(%{"model" => "other-model"}), :invalid_request},
      {request(%{"max_output_tokens" => 5000}), :invalid_request},
      {request(%{"messages" => [%{"role" => "user", "text" => "x", "image" => "data"}]}),
       :unsupported_feature},
      {request(%{"tools" => [%{"type" => "web_search", "name" => "web"}]}), :unsupported_feature},
      {request(%{"reasoning" => "max"}), :unsupported_feature},
      {request(%{
         "cache_hint" => %{
           "tenant" => "tenant-b",
           "local_key" => "k",
           "ttl" => "5m",
           "breakpoints" => ["system"]
         }
       }), :invalid_request},
      {request(%{
         "cache_hint" => %{
           "tenant" => "tenant-a",
           "local_key" => "k",
           "ttl" => "1h",
           "breakpoints" => ["system"]
         }
       }), :unsupported_feature},
      {request(%{"output_schema" => %{"$ref" => "https://example.test/schema.json"}}),
       :invalid_request},
      {request(%{"messages" => [%{"role" => "user", "text" => String.duplicate("x", 70_000)}]}),
       :too_large}
    ]

    for {req, reason} <- refusals do
      assert {:error, {:refused, ^reason}} = admit(c, req), inspect(reason)
    end

    refute_received :credential_read
    refute_received {:call, _, _}

    # Sampling is an optional feature: a provider that does not declare it refuses it.
    c2 = config(provider: Elzoo.AiText.TestProviderNoSampling)

    assert {:error, {:refused, :unsupported_feature}} =
             admit(c2, request(%{"sampling" => %{"temperature" => 0.2}}))

    assert {:ok, _} = admit(c, request(%{"sampling" => %{"temperature" => 0.2}}))
    refute_received :credential_read
  end

  test "I2 malformed declarations and payloads (admission)" do
    c = config()
    decl = Conformance.declaration(request(), "r", 10_000)
    assert {:error, :declaration} = AiText.admission(c, put_in(decl, ["classification"], "trusted"))
    assert {:error, :declaration} = AiText.admission(c, put_in(decl, ["operation"], "chat"))
    assert {:error, :declaration} = AiText.admission(c, put_in(decl, ["command", "schema_id"], "x"))

    bad = put_in(decl, ["command", "payload"], ~s({"version":1,"version":1}))
    assert {:error, {:refused, :invalid_request}} = AiText.admission(c, bad)
    unknown = put_in(decl, ["command", "payload"], Jason.encode!(Map.put(request(), "extra", 1)))
    assert {:error, {:refused, :invalid_request}} = AiText.admission(c, unknown)
  end

  ## I3 provider options

  test "I3 provider options: undeclared key and invalid value refused, declared value reaches translate; fixed settings are not options (admission)" do
    c = config()

    assert {:error, {:refused, :invalid_request}} =
             admit(c, request(%{"provider_options" => %{"undeclared" => true}}))

    assert {:error, {:refused, :invalid_request}} =
             admit(c, request(%{"provider_options" => %{"flavour" => "loud"}}))

    for fixed <- ["api_key", "anthropic_version", "max_retries", "receive_timeout"] do
      assert {:error, {:refused, :invalid_request}} =
               admit(c, request(%{"provider_options" => %{fixed => "x"}}))
    end

    assert {:ok, _} = admit(c, request(%{"provider_options" => %{"flavour" => "plain"}}))
    assert_received {:translate, %{"flavour" => "plain"}}

    # The provider's own translate refusal is returned, never ignored.
    assert {:error, {:refused, :unsupported_feature}} =
             admit(
               c,
               request(%{
                 "provider_options" => %{"flavour" => "terse"},
                 "tools" => [Enum.at(Conformance.request(:tool_well_formed, "m")["tools"], 0)]
               })
             )
  end

  ## I4 retries

  test "I4 retries: only the attested no-send credential failure is redispatched; throttled and overloaded are not; unknown never (RetryTimeout policy + owner)",
       ctx do
    {:ok, policy} = Elzoo.RetryTimeout.policy(max_attempts: 3, base_backoff_ms: 10)

    # Credential Need fails twice, then succeeds: three dispatches, one provider call.
    counter = :counters.new(1, [])

    need = fn ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) < 3, do: {:error, :vault_down}, else: {:ok, @secret}
    end

    c = config(credentials: need)
    {:ok, a} = admit(c, request())
    pid = owner(c, a, ctx)

    for attempt <- 1..2 do
      {:ok, :dispatched} = Intent.advance(pid, :dispatch)
      settled(pid)
      key = a.key
      assert_receive {AiText, ^key, {:outcome, _, {:refused, :credentials_unavailable, _}}}

      assert {:retry, 10 * Integer.pow(2, attempt - 1)} ==
               Retry.next(policy, attempt, :credentials_unavailable)

      assert {:ok, _} = Intent.advance(pid, :rearm)
    end

    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert {:Confirmed, 3} = settled(pid).phase
    assert calls() == 1
    assert {:stop, :settle} = Retry.next(policy, 3, :completed)
    assert {:stop, :exhausted} = Retry.next(policy, 3, :credentials_unavailable)

    assert {:stop, :deadline} =
             Retry.next(policy, 1, :credentials_unavailable, now_ms: 95, deadline_ms: 100)

    # Throttled (429-like) and overloaded: failed/dispatched/retryable, not redispatched.
    for tag <- [:throttled, :overloaded] do
      c = config(respond: fn _ -> {:ok, {:status, tag, %{retry_after: 7}}} end)
      {pid, _a, _status, delivery} = dispatch(c, request(), ctx, "t-#{tag}")
      assert {:outcome, _, {:refused, ^tag, %{retry_after: 7}}} = delivery
      assert {:stop, :unresolved} = Retry.next(policy, 1, tag)
      assert {:error, _} = Intent.advance(pid, :rearm)
      assert {:error, _} = Intent.advance(pid, :dispatch)
      assert calls() == 1
    end

    # Unknown outcomes are never retried.
    for tag <- [:timeout, :transport, :provider_error, :malformed_response] do
      assert {:stop, :unresolved} = Retry.next(policy, 1, tag)
    end

    for tag <- [:provider_invalid_request, :authentication_failed, :not_found] do
      assert {:stop, :permanent} = Retry.next(policy, 1, tag)
    end

    # A :redispatch_idempotent policy never turns a dispatched or unknown result
    # into a retry: no provider supplies a replay-safe ground.
    {:ok, idempotent} =
      Elzoo.RetryTimeout.policy(max_attempts: 3, mode: :redispatch_idempotent)

    for tag <- [:throttled, :overloaded, :timeout, :transport, :provider_error, :malformed_response] do
      assert {:stop, :unresolved} = Retry.next(idempotent, 1, tag), inspect(tag)
    end

    assert {:retry, _} = Retry.next(idempotent, 1, :credentials_unavailable)
  end

  ## I5 one identity, one send

  test "I5 a second dispatch of the same identity is refused; re-admission recovers the same key (EffectIntent owner)",
       ctx do
    c = config(respond: fn _ -> {:transport, :timeout} end)
    {pid, a, _status, delivery} = dispatch(c, request(), ctx)
    assert {:outcome, _, {:unknown, :timeout}} = delivery
    assert {:error, _} = Intent.advance(pid, :dispatch)
    assert {:error, _} = Intent.advance(pid, :rearm)
    assert calls() == 1
    {:ok, again} = admit(c, request())
    assert again.key == a.key
    {:ok, other} = admit(c, request(), "req-2")
    refute other.key == a.key
  end

  ## I6 classification table

  test "I6 the Binding table equals the Cure decision; only credentials_unavailable and input_unavailable are attested no-send (decision + binding)" do
    assert Outcome.verify()
    {:ok, b} = Elzoo.AiText.Binding.load(Elzoo.AiText.TestBinding)
    assert Enum.sort(b.no_send_attestations) == [:credentials_unavailable, :input_unavailable]
    refute :input_unavailable in Outcome.provider_tags()

    expected = %{
      credentials_unavailable:
        {{:refused, :credentials_unavailable}, {"timed_out", "not_dispatched", "unavailable"}},
      input_unavailable:
        {{:refused, :input_unavailable}, {"timed_out", "not_dispatched", "unavailable"}},
      provider_invalid_request:
        {{:refused, :invalid_request}, {"failed", "dispatched", "permanent"}},
      provider_too_large: {{:refused, :too_large}, {"failed", "dispatched", "permanent"}},
      authentication_failed:
        {{:refused, :authentication_failed}, {"failed", "dispatched", "permanent"}},
      permission_denied: {{:refused, :permission_denied}, {"failed", "dispatched", "permanent"}},
      not_found: {{:refused, :not_found}, {"failed", "dispatched", "permanent"}},
      throttled: {{:refused, :throttled}, {"failed", "dispatched", "retryable"}},
      overloaded: {{:refused, :overloaded}, {"failed", "dispatched", "retryable"}},
      provider_error: {{:unknown, :provider_error}, {"unknown", "dispatched", "unclassified"}},
      provider_timeout: {{:unknown, :timeout}, {"timed_out", "unknown", "unclassified"}},
      timeout: {{:unknown, :timeout}, {"timed_out", "unknown", "unclassified"}},
      transport: {{:unknown, :transport}, {"unknown", "unknown", "unclassified"}},
      malformed_response:
        {{:unknown, :malformed_response}, {"unknown", "dispatched", "unclassified"}},
      adapter_error: {{:unknown, :provider_error}, {"unknown", "unknown", "unclassified"}}
    }

    assert Enum.sort(Map.keys(expected)) == Enum.sort(Outcome.tags())

    for {tag, {contract, triple}} <- expected do
      assert {:ok, ^contract} = AiText.outcome(tag)
      assert {:ok, ^triple} = Outcome.delivery(tag)
      assert Outcome.failures()[tag] == triple
    end

    assert :error = AiText.outcome(:nonsense)
  end

  test "I6 a provider tag outside its set, a raising provider and a malformed completion are unknown (Adapter)",
       ctx do
    cases = [
      {fn _ -> {:ok, {:status, :credentials_unavailable}} end, {:unknown, :provider_error}},
      {fn _ -> {:ok, {:status, :input_unavailable}} end, {:unknown, :provider_error}},
      {fn _ -> raise "boom #{@secret}" end, {:unknown, :provider_error}},
      {fn _ -> {:ok, {:raw, Map.delete(TestHelper.raw(), :response_id)}} end,
       {:unknown, :malformed_response}},
      {fn _ -> {:ok, {:raw, %{TestHelper.raw() | finish: :weird}}} end,
       {:unknown, :malformed_response}},
      {fn _ -> {:ok, {:raw, %{TestHelper.raw() | usage: %{}}}} end, {:unknown, :malformed_response}}
    ]

    for {{respond, expected}, i} <- Enum.with_index(cases) do
      c = config(respond: respond)
      {_pid, _a, _s, delivery} = dispatch(c, request(), ctx, "m-#{i}")
      assert {:outcome, _, ^expected} = delivery
      refute inspect(delivery) =~ @secret
    end
  end

  ## I7 sink failures

  test "I7 a failing sink never changes classification or settlement; the caller is told sink_failed (Adapter + sink)",
       ctx do
    parent = self()

    sinks = [
      fn _, {:outcome, _, _} -> raise "sink down" end,
      fn _, {:outcome, _, _} -> throw(:x) end,
      fn _, {:outcome, _, _} -> exit(:x) end,
      fn _, {:outcome, _, _} -> :error end
    ]

    for {fail, i} <- Enum.with_index(sinks) do
      sink = fn
        key, {:sink_failed, _} = d ->
          send(parent, {AiText, key, d})
          :ok

        key, d ->
          fail.(key, d)
      end

      c = config(sink: sink)
      {_pid, _a, status, delivery} = dispatch(c, request(), ctx, "s-#{i}")
      assert {:sink_failed, _} = delivery
      assert {:Confirmed, 1} = status.phase
    end
  end

  ## Tool proposals and structured output are checked by the interface

  test "tool proposals are data: malformed ones are marked, never dropped or repaired; structured output is validated (Adapter)",
       ctx do
    tools = Conformance.request(:tool_well_formed, "test-model")["tools"]

    calls = [
      %{id: "t1", name: "lookup", arguments_json: ~s({"q":"x"})},
      %{id: "t2", name: "lookup", arguments_json: ~s({"q":)},
      %{id: "t3", name: "lookup", arguments_json: ~s({"q":5})},
      %{id: "t4", name: "lookup", arguments_json: ~s(["q"])},
      %{id: "t5", name: "unknown_tool", arguments_json: ~s({"q":"x"})}
    ]

    c =
      config(
        respond: fn _ ->
          {:ok, {:raw, TestHelper.raw("", %{tool_calls: calls, finish: :tool_calls})}}
        end
      )

    {_, _, _, {:outcome, _, {:completed, body}}} = dispatch(c, request(%{"tools" => tools}), ctx)

    assert [
             %{id: "t1", arguments: %{"q" => "x"}, malformed: nil},
             %{id: "t2", arguments: nil, malformed: :invalid_json, raw_arguments: ~s({"q":)},
             %{id: "t3", arguments: nil, malformed: :schema_mismatch},
             %{id: "t4", arguments: nil, malformed: :not_an_object},
             %{id: "t5", arguments: nil, malformed: :undeclared_tool}
           ] = body.tool_proposals

    schema = Conformance.request(:structured_valid, "test-model")["output_schema"]

    for {json, expected, i} <- [
          {~s({"answer":42}), {:valid, %{"answer" => 42}}, 1},
          {~s({"answer":"x"}), {:invalid, :schema_mismatch}, 2},
          {~s({"answer":), {:invalid, :invalid_json}, 3},
          {nil, {:invalid, :missing}, 4}
        ] do
      c = config(respond: fn _ -> {:ok, {:raw, TestHelper.raw("", %{structured_json: json})}} end)

      {_, _, _, {:outcome, _, {:completed, body}}} =
        dispatch(c, request(%{"output_schema" => schema}), ctx, "o-#{i}")

      assert body.structured == expected
    end
  end

  ## Request codec

  test "request codec: canonical bytes, duplicate keys, unknown members, roles and bounds (Request)" do
    {:ok, r, canonical} = Request.decode(Jason.encode!(request(%{"reasoning" => "low"})))
    assert r.reasoning == :low
    assert r.tool_choice == :auto
    assert {:ok, ^r, ^canonical} = Request.decode(canonical)
    assert :ok = Adapter.validate(canonical, Adapter.schema())

    assert {:error, :schema} =
             Adapter.validate(Jason.encode!(request(), pretty: true), Adapter.schema())

    assert {:error, :invalid_request} = Request.decode(~s({"version":1,"version":2}))
    assert {:error, :invalid_request} = Request.decode("not json")
    assert {:error, :invalid_request} = Request.decode(<<0xFF>>)
    assert {:error, :too_large} = Request.decode(Jason.encode!(request()), 10)

    bad_messages = [
      [],
      [%{"role" => "robot", "text" => "x"}],
      [%{"role" => "user"}],
      [%{"role" => "tool_result", "text" => "x"}],
      [
        %{
          "role" => "assistant",
          "text" => "",
          "tool_calls" => [%{"id" => "a", "name" => "bad name", "arguments" => %{}}]
        }
      ]
    ]

    for m <- bad_messages,
        do:
          assert(
            {:error, :invalid_request} = Request.decode(Jason.encode!(request(%{"messages" => m})))
          )

    ok =
      request(%{
        "messages" => [
          %{"role" => "system", "text" => "s"},
          %{"role" => "user", "text" => "u"},
          %{
            "role" => "assistant",
            "text" => "",
            "tool_calls" => [%{"id" => "a", "name" => "lookup", "arguments" => %{"q" => "x"}}]
          },
          %{"role" => "tool_result", "tool_use_id" => "a", "text" => "result", "is_error" => false}
        ],
        "tool_choice" => %{"type" => "tool", "name" => "lookup"},
        "stop_sequences" => ["END"],
        "sampling" => %{"temperature" => 0.5, "top_p" => 0.9},
        "cache_hint" => %{
          "tenant" => "t",
          "local_key" => "k",
          "ttl" => "5m",
          "breakpoints" => ["tools", %{"message" => 1}]
        }
      })

    assert {:ok, r, _} = Request.decode(Jason.encode!(ok))
    assert r.tool_choice == {:tool, "lookup"}
    assert r.cache_hint.breakpoints == [:tools, {:message, 1}]
    assert r.sampling == %{temperature: 0.5, top_p: 0.9}
  end

  ## Golden text-only request (recorded on the base before Contract amendment 2)

  @golden_request %{
    "version" => 1,
    "model" => "test-model",
    "messages" => [
      %{"role" => "system", "text" => "s"},
      %{"role" => "user", "text" => "u"},
      %{
        "role" => "assistant",
        "text" => "",
        "tool_calls" => [%{"id" => "a", "name" => "lookup", "arguments" => %{"q" => "x"}}]
      },
      %{"role" => "tool_result", "tool_use_id" => "a", "text" => "result", "is_error" => false}
    ],
    "tools" => [
      %{
        "name" => "lookup",
        "description" => "Look up a term.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{"q" => %{"type" => "string"}},
          "required" => ["q"],
          "additionalProperties" => false
        }
      }
    ],
    "tool_choice" => %{"type" => "tool", "name" => "lookup"},
    "output_schema" => %{
      "type" => "object",
      "properties" => %{"answer" => %{"type" => "integer"}},
      "required" => ["answer"],
      "additionalProperties" => false
    },
    "max_output_tokens" => 64,
    "stop_sequences" => ["END"],
    "sampling" => %{"temperature" => 0.5, "top_p" => 0.9},
    "reasoning" => "low",
    "cache_hint" => %{
      "tenant" => "tenant-a",
      "local_key" => "k",
      "ttl" => "5m",
      "breakpoints" => ["tools", %{"message" => 1}]
    },
    "provider_options" => %{"flavour" => "plain"}
  }

  @golden_bytes ~S({"cache_hint":{"breakpoints":["tools",{"message":1}],"local_key":"k","tenant":"tenant-a","ttl":"5m"},"max_output_tokens":64,"messages":[{"role":"system","text":"s"},{"role":"user","text":"u"},{"role":"assistant","text":"","tool_calls":[{"arguments":{"q":"x"},"id":"a","name":"lookup"}]},{"is_error":false,"role":"tool_result","text":"result","tool_use_id":"a"}],"model":"test-model","output_schema":{"additionalProperties":false,"properties":{"answer":{"type":"integer"}},"required":["answer"],"type":"object"},"provider_options":{"flavour":"plain"},"reasoning":"low","sampling":{"temperature":0.5,"top_p":0.9},"stop_sequences":["END"],"tool_choice":{"name":"lookup","type":"tool"},"tools":[{"description":"Look up a term.","input_schema":{"additionalProperties":false,"properties":{"q":{"type":"string"}},"required":["q"],"type":"object"},"name":"lookup"}],"version":1})

  @golden_term %{
    model: "test-model",
    messages: [
      %{role: :system, text: "s"},
      %{role: :user, text: "u"},
      %{
        role: :assistant,
        text: "",
        tool_calls: [%{id: "a", name: "lookup", arguments: %{"q" => "x"}}]
      },
      %{role: :tool_result, tool_use_id: "a", text: "result", is_error: false}
    ],
    tools: [
      %{
        name: "lookup",
        description: "Look up a term.",
        input_schema: %{
          "additionalProperties" => false,
          "properties" => %{"q" => %{"type" => "string"}},
          "required" => ["q"],
          "type" => "object"
        }
      }
    ],
    tool_choice: {:tool, "lookup"},
    output_schema: %{
      "additionalProperties" => false,
      "properties" => %{"answer" => %{"type" => "integer"}},
      "required" => ["answer"],
      "type" => "object"
    },
    max_output_tokens: 64,
    stop_sequences: ["END"],
    sampling: %{temperature: 0.5, top_p: 0.9},
    reasoning: :low,
    cache_hint: %{
      tenant: "tenant-a",
      local_key: "k",
      ttl: "5m",
      breakpoints: [:tools, {:message, 1}]
    },
    provider_options: %{"flavour" => "plain"}
  }

  @golden_minimal ~S({"max_output_tokens":64,"messages":[{"role":"user","text":"prompt-SECRET-p33"}],"model":"test-model","version":1})

  test "golden text-only request: canonical bytes, translated wire term, admission and Adapter results are unchanged (Request, check, admission, Adapter)",
       ctx do
    # Equality, not a pattern: a map pattern would accept extra keys.
    assert Request.decode(Jason.encode!(@golden_request)) == {:ok, @golden_term, @golden_bytes}
    assert Request.decode(@golden_bytes) == {:ok, @golden_term, @golden_bytes}
    assert Request.canonical(request()) == @golden_minimal

    parent = self()

    c =
      config(
        respond: fn r ->
          send(parent, {:sent, r})
          {:ok, {:raw, TestHelper.raw()}}
        end
      )

    assert AiText.check(c, @golden_term) == {:ok, %{request: @golden_term, cfg: c.provider_config}}

    {:ok, a} = admit(c, @golden_request)
    assert a.arguments == @golden_bytes
    assert a.identity == ["tenant-a", "test:account", "ai-text-test", "generate", "req-1"]
    assert a.deadline == 10_000

    {_pid, _a, status, delivery} = dispatch(c, @golden_request, ctx, "golden")
    assert_received {:sent, sent}
    assert sent == @golden_term
    assert {:outcome, _, {:completed, %{content: "hello", finish: :stop}}} = delivery
    assert {:Confirmed, 1} = status.phase
    assert calls() == 1
  end

  ## Image input by artifact reference (Contract amendment 2)

  @bytes_a "IMAGE-BYTES-A-SECRET-91"
  @bytes_b "IMAGE-BYTES-B-SECRET-37"

  defp record(id, bytes, media \\ "image/png", version \\ 1) do
    %{
      artifact_id: id,
      version: version,
      hash_format: 1,
      sha256: Base.encode16(:crypto.hash(:sha256, <<1, bytes::binary>>), case: :lower),
      size_bytes: byte_size(bytes),
      media_type: media
    }
  end

  # The artifact read Need double: `answers` maps an artifact id to the Need's
  # answer (a term, or a 0-arity function for a raising or changing Need). Each
  # call is reported to the test process.
  defp need(answers) do
    parent = self()

    fn %{artifact_id: id} = ref ->
      send(parent, {:need, ref})

      case Map.fetch(answers, id) do
        {:ok, f} when is_function(f, 0) -> f.()
        {:ok, answer} -> answer
        :error -> {:error, :not_found}
      end
    end
  end

  defp stored(id, bytes, media \\ "image/png"),
    do: {id, {:ok, %{record: record(id, bytes, media), bytes: bytes}}}

  defp image_part(id, media \\ "image/png", version \\ 1),
    do: %{
      "type" => "image",
      "artifact" => %{"id" => id, "version" => version},
      "media_type" => media
    }

  defp parts_request(parts), do: request(%{"messages" => [%{"role" => "user", "parts" => parts}]})

  defp image_config(answers, opts \\ []) do
    parent = self()

    config(
      Keyword.merge(
        [
          provider: Elzoo.AiText.TestProviderImages,
          artifacts: need(answers),
          credentials: fn ->
            send(parent, :credential_read)
            {:ok, @secret}
          end,
          respond: fn r ->
            send(parent, {:sent, r})
            {:ok, {:raw, TestHelper.raw()}}
          end
        ],
        opts
      )
    )
  end

  defp needs do
    receive do
      {:need, _} -> 1 + needs()
    after
      0 -> 0
    end
  end

  test "image parts: admission keeps references only; the Adapter resolves each image, translate gets the bytes in order, one call (check, admission, Adapter)",
       ctx do
    c = image_config(Map.new([stored("img-a", @bytes_a), stored("img-b", @bytes_b, "image/jpeg")]))

    req =
      parts_request([
        image_part("img-a"),
        %{"type" => "text", "text" => "compare"},
        image_part("img-b", "image/jpeg")
      ])

    {:ok, a} = admit(c, req)
    assert needs() == 2
    refute_received :credential_read
    refute a.arguments =~ @bytes_a or a.arguments =~ @bytes_b
    {:ok, decoded, _} = Request.decode(a.arguments)

    assert [%{role: :user, parts: refs}] = decoded.messages

    assert refs == [
             %{type: :image, artifact_id: "img-a", version: 1, media_type: "image/png"},
             %{type: :text, text: "compare"},
             %{type: :image, artifact_id: "img-b", version: 1, media_type: "image/jpeg"}
           ]

    {pid, _a, status, delivery} = dispatch(c, req, ctx, "img")
    assert_received {:need, %{artifact_id: "img-a", version: 1}}
    assert_received {:need, %{artifact_id: "img-b", version: 1}}
    # Two at the test's admission inside dispatch/4, two in the send task.
    assert needs() == 2
    assert_received {:sent, sent}

    assert [%{role: :user, parts: parts}] = sent.messages

    assert parts == [
             %{type: :image, media_type: "image/png", bytes: @bytes_a},
             %{type: :text, text: "compare"},
             %{type: :image, media_type: "image/jpeg", bytes: @bytes_b}
           ]

    assert {:outcome, _, {:completed, %{content: "hello"}}} = delivery
    assert {:Confirmed, 1} = status.phase
    assert calls() == 1

    # No image byte in the intent's state, its status, the outcome or the Config.
    text =
      inspect({:sys.get_state(pid), status, delivery, c},
        limit: :infinity,
        printable_limit: :infinity
      )

    refute text =~ @bytes_a
    refute text =~ @bytes_b
  end

  test "image parts to a provider without :image_input, or without an artifact Need, are unsupported_feature before any Need call (check)" do
    req =
      parts_request([image_part("img-a"), %{"type" => "text", "text" => "x"}, image_part("img-b")])

    answers = Map.new([stored("img-a", @bytes_a), stored("img-b", @bytes_b)])

    for c <- [
          image_config(answers, provider: Elzoo.AiText.TestProvider),
          config(provider: Elzoo.AiText.TestProviderImages)
        ] do
      assert {:error, {:refused, :unsupported_feature}} = admit(c, req)

      assert {:error, :unsupported_feature} =
               AiText.check(c, elem(Request.decode(Request.canonical(req)), 1))
    end

    assert needs() == 0
    refute_received :credential_read
    refute_received {:translate, _}
  end

  test "image bounds at their edges: 8 and 9 images, max_image_bytes, max_total_image_bytes, 64 and 65 parts, media types (Request, check)" do
    many = for i <- 1..9, do: stored("i#{i}", "b#{i}")
    c = image_config(Map.new(many))

    images = for i <- 1..9, do: image_part("i#{i}")
    assert {:ok, _} = admit(c, parts_request(Enum.take(images, 8)))
    assert needs() == 8

    # The ninth image is counted over the whole request, across messages.
    split =
      request(%{
        "messages" => [
          %{"role" => "user", "parts" => Enum.take(images, 4)},
          %{"role" => "user", "parts" => Enum.drop(images, 4)}
        ]
      })

    assert {:error, {:refused, :too_large}} = admit(c, split)
    assert {:error, {:refused, :too_large}} = admit(c, parts_request(images))
    assert needs() == 0

    text = %{"type" => "text", "text" => "t"}
    assert {:ok, _} = admit(c, parts_request([image_part("i1") | List.duplicate(text, 63)]))
    assert needs() == 1

    assert {:error, {:refused, :invalid_request}} =
             admit(c, parts_request([image_part("i1") | List.duplicate(text, 64)]))

    assert needs() == 0

    # Default bounds: 5,242,880 bytes per image, 20,971,520 in all.
    max = :binary.copy("x", 5_242_880)
    over = max <> "x"

    c =
      image_config(
        Map.new([
          stored("max-1", max),
          stored("max-2", max),
          stored("max-3", max),
          stored("max-4", max),
          stored("over", over),
          stored("one", "y")
        ])
      )

    assert {:ok, _} = admit(c, parts_request([image_part("max-1")]))
    assert {:error, {:refused, :too_large}} = admit(c, parts_request([image_part("over")]))
    four = for i <- 1..4, do: image_part("max-#{i}")
    assert {:ok, _} = admit(c, parts_request(four))
    assert {:error, {:refused, :too_large}} = admit(c, parts_request(four ++ [image_part("one")]))

    # Configured bounds.
    c =
      image_config(Map.new([stored("a", "12345"), stored("b", "123"), stored("c", "1234")]),
        image_bounds: %{max_image_bytes: 4, max_total_image_bytes: 7}
      )

    assert {:error, {:refused, :too_large}} = admit(c, parts_request([image_part("a")]))

    # The bounds come before the hash: an oversized answer with a wrong hash is
    # too_large, so it is never hashed.
    {:ok, %{record: rec}} = elem(stored("big", "12345"), 1)

    c2 =
      image_config(%{"big" => {:ok, %{record: %{rec | sha256: "0"}, bytes: "12345"}}},
        image_bounds: %{max_image_bytes: 4, max_total_image_bytes: 7}
      )

    assert {:error, {:refused, :too_large}} = admit(c2, parts_request([image_part("big")]))
    assert {:ok, _} = admit(c, parts_request([image_part("b"), image_part("c")]))

    assert {:error, {:refused, :too_large}} =
             admit(c, parts_request([image_part("b"), image_part("c"), image_part("b")]))

    for media <- ~w(image/png image/jpeg image/webp image/gif) do
      c = image_config(Map.new([stored("m", "m", media)]))
      assert {:ok, _} = admit(c, parts_request([image_part("m", media)])), media
    end

    _ = needs()
    c = image_config(Map.new([stored("m", "m", "image/svg+xml")]))

    assert {:error, {:refused, :unsupported_feature}} =
             admit(c, parts_request([image_part("m", "image/svg+xml")]))

    assert needs() == 0

    base = [
      binding: Elzoo.AiText.TestBinding,
      tenant: "t",
      provider: Elzoo.AiText.TestProviderImages,
      credentials: fn -> {:ok, "k"} end,
      models: ["m"],
      sink: fn _, _ -> :ok end
    ]

    for bad <- [
          [image_bounds: %{max_image_bytes: 5_242_881, max_total_image_bytes: 1}],
          [image_bounds: %{max_image_bytes: 1, max_total_image_bytes: 41_943_041}],
          [image_bounds: %{max_image_bytes: 0, max_total_image_bytes: 1}],
          [image_bounds: %{max_image_bytes: 1, max_total_image_bytes: 1, extra: 1}],
          [image_bounds: %{max_image_bytes: 1}],
          [artifacts: fn -> :ok end]
        ] do
      assert {:error, :configuration} = AiText.configure(base ++ bad), inspect(bad)
    end

    assert {:ok, _} =
             AiText.configure(
               base ++
                 [
                   artifacts: fn _ -> :ok end,
                   image_bounds: %{max_image_bytes: 5_242_880, max_total_image_bytes: 41_943_040}
                 ]
             )
  end

  test "an unresolvable image is input_unavailable before any intent, a media type mismatch invalid_request; a failure at dispatch is the attested no-send and is retried (check, Adapter, Retry)",
       ctx do
    changed =
      binary_part(@bytes_a, 0, 5) <> "X" <> binary_part(@bytes_a, 6, byte_size(@bytes_a) - 6)

    rec = record("img", @bytes_a)

    unavailable = [
      {:ok, %{record: rec, bytes: changed}},
      {:ok, %{record: %{rec | size_bytes: rec.size_bytes + 1}, bytes: @bytes_a}},
      {:ok, %{record: %{rec | artifact_id: "other"}, bytes: @bytes_a}},
      {:ok, %{record: %{rec | version: 2}, bytes: @bytes_a}},
      {:ok, %{record: %{rec | sha256: String.upcase(rec.sha256)}, bytes: @bytes_a}},
      {:ok, %{record: %{rec | hash_format: 0}, bytes: @bytes_a}},
      {:ok, %{record: Map.delete(rec, :sha256), bytes: @bytes_a}},
      {:ok, %{bytes: @bytes_a}},
      {:ok, @bytes_a},
      {:error, :not_found},
      {:error, :deleted},
      fn -> raise "store down #{@bytes_a}" end,
      fn -> throw(:x) end,
      fn -> exit(:x) end
    ]

    for {answer, i} <- Enum.with_index(unavailable) do
      c = image_config(%{"img" => answer})
      result = admit(c, parts_request([image_part("img")]))
      assert {:error, {:refused, :input_unavailable}} = result, "case #{i}"
      refute inspect(result) =~ @bytes_a
    end

    refute_received :credential_read
    refute_received {:translate, _}

    c = image_config(Map.new([stored("img", @bytes_a, "image/jpeg")]))
    assert {:error, {:refused, :invalid_request}} = admit(c, parts_request([image_part("img")]))
    _ = needs()

    # Answers at admission, fails at dispatch: attested no-send, then retried.
    counter = :counters.new(1, [])

    flaky = fn ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 2,
        do: {:error, :deleted},
        else: {:ok, %{record: rec, bytes: @bytes_a}}
    end

    c = image_config(%{"img" => flaky})
    {:ok, policy} = Elzoo.RetryTimeout.policy(max_attempts: 3, base_backoff_ms: 10)
    {:ok, a} = admit(c, parts_request([image_part("img")]))
    pid = owner(c, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    status = settled(pid)
    key = a.key

    assert_receive {AiText, ^key,
                    {:outcome, _, {:refused, :input_unavailable, %{retry_after: nil}} = d}}

    refute inspect({d, status}) =~ @bytes_a
    refute_received :credential_read
    assert calls() == 0
    assert {:retry, 10} = Retry.next(policy, 1, :input_unavailable)
    assert {:ok, _} = Intent.advance(pid, :rearm)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert {:Confirmed, 2} = settled(pid).phase
    assert_receive {AiText, ^key, {:outcome, _, {:completed, _}}}
    assert calls() == 1
  end

  test "an image of zero bytes is invalid_request at admission before translate; one byte is admitted; an empty answer with a wrong record or hash stays input_unavailable (check, admission)" do
    req = parts_request([image_part("img")])
    {:ok, decoded, _} = Request.decode(Jason.encode!(req))

    # Zero bytes, matching record, empty-content hash, the part's media type.
    c = image_config(Map.new([stored("img", "")]))
    assert {:error, {:refused, :invalid_request}} = admit(c, req)
    assert {:error, :invalid_request} = AiText.check(c, decoded)
    assert needs() == 2
    refute_received {:translate, _}
    refute_received :credential_read

    # One byte: admitted, and translate/2 gets the one-byte image.
    c = image_config(Map.new([stored("img", "1")]))
    assert {:ok, _} = admit(c, req)
    assert_received {:translate, _}
    assert {:ok, %{request: wire}} = AiText.check(c, decoded)
    assert_received {:translate, _}

    assert [%{parts: [%{type: :image, media_type: "image/png", bytes: "1"}]}] = wire.messages

    # Order: the empty image is decided after the record and hash checks.
    rec = record("img", "")

    for {answer, i} <-
          Enum.with_index([
            {:ok, %{record: %{rec | sha256: record("img", "1").sha256}, bytes: ""}},
            {:ok, %{record: %{rec | size_bytes: 1}, bytes: ""}},
            {:ok, %{record: %{rec | version: 2}, bytes: ""}}
          ]) do
      c = image_config(%{"img" => answer})
      assert {:error, {:refused, :input_unavailable}} = admit(c, req), "case #{i}"
    end

    _ = needs()
    refute_received {:translate, _}
  end

  test "an image that answers zero bytes at dispatch is the attested no-send input_unavailable before the credential Need, no provider request (Adapter)",
       ctx do
    counter = :counters.new(1, [])

    empty_at_dispatch = fn ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1,
        do: {:ok, %{record: record("img", @bytes_a), bytes: @bytes_a}},
        else: {:ok, %{record: record("img", ""), bytes: ""}}
    end

    c = image_config(%{"img" => empty_at_dispatch})
    {:ok, a} = admit(c, parts_request([image_part("img")]))
    _ = needs()
    # Admission translated the non-empty image; dispatch must not translate.
    assert_received {:translate, _}
    pid = owner(c, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    status = settled(pid)
    key = a.key

    assert_receive {AiText, ^key,
                    {:outcome, _, {:refused, :input_unavailable, %{retry_after: nil}}}}

    assert needs() == 1
    refute_received {:translate, _}
    refute_received :credential_read
    refute_received {:sent, _}
    assert calls() == 0
    refute match?({:Confirmed, _}, status.phase)
    # Attested no-send: the owner accepts a rearm of the same intent.
    assert {:ok, _} = Intent.advance(pid, :rearm)
  end

  test "parts refusals: document part, parts on another role, text with parts, text parts only, malformed parts (Request)" do
    text = %{"type" => "text", "text" => "t"}
    img = image_part("img")

    decode = fn messages -> Request.decode(Jason.encode!(request(%{"messages" => messages}))) end

    unsupported = [
      [
        %{
          "role" => "user",
          "parts" => [img, %{"type" => "document", "artifact" => %{"id" => "d", "version" => 1}}]
        }
      ],
      [%{"role" => "user", "parts" => [img, %{"type" => "audio"}]}],
      [%{"role" => "system", "parts" => [img]}],
      [%{"role" => "assistant", "parts" => [img]}],
      [%{"role" => "tool_result", "tool_use_id" => "a", "parts" => [img]}],
      [%{"role" => "user", "parts" => [img], "document" => "d"}],
      [%{"role" => "user", "parts" => [img], "image" => "i"}]
    ]

    for m <- unsupported, do: assert({:error, :unsupported_feature} = decode.(m), inspect(m))

    invalid = [
      [%{"role" => "user", "text" => "t", "parts" => [img]}],
      [%{"role" => "user", "parts" => [text]}],
      [%{"role" => "user", "parts" => []}],
      [%{"role" => "user", "parts" => img}],
      [%{"role" => "user", "parts" => [img, %{"type" => "text"}]}],
      [%{"role" => "user", "parts" => [img, Map.put(text, "extra", 1)]}],
      [%{"role" => "user", "parts" => [img, %{"text" => "t"}]}],
      [%{"role" => "user", "parts" => [Map.delete(img, "media_type")]}],
      [%{"role" => "user", "parts" => [Map.put(img, "text", "t")]}],
      [%{"role" => "user", "parts" => [image_part("img", "image/png", 0)]}],
      [%{"role" => "user", "parts" => [image_part("img", "image/png", 2_147_483_648)]}],
      [%{"role" => "user", "parts" => [image_part("img", "image/png", "1")]}],
      [%{"role" => "user", "parts" => [image_part("..")]}],
      [%{"role" => "user", "parts" => [image_part("a/b")]}],
      [%{"role" => "user", "parts" => [image_part(String.duplicate("a", 65))]}],
      [%{"role" => "user", "parts" => [put_in(img, ["artifact", "extra"], 1)]}],
      [%{"role" => "user", "parts" => [img, "text"]}]
    ]

    for m <- invalid, do: assert({:error, :invalid_request} = decode.(m), inspect(m))

    assert {:ok, r, _} =
             decode.([
               %{
                 "role" => "user",
                 "parts" => [image_part(String.duplicate("a", 64), "image/gif", 2_147_483_647)]
               }
             ])

    assert [%{parts: [%{version: 2_147_483_647, media_type: "image/gif"}]}] = r.messages
  end

  test "conformance kit: the :image_input scenario of image_scenarios/0 passes with the stub provider; scenarios/0 keeps its 15 (Conformance)",
       ctx do
    assert length(Conformance.scenarios()) == 15
    refute :image_input in Conformance.ids()
    assert [%{id: :image_input}] = Conformance.image_scenarios()
    parent = self()

    c =
      config(
        provider: Elzoo.AiText.TestProviderImages,
        artifacts: Conformance.image_need(),
        respond: fn r ->
          send(parent, {:sent, r})
          {:ok, {:raw, TestHelper.raw(Conformance.text())}}
        end
      )

    for %{id: id} <- Conformance.image_scenarios() do
      {_pid, _a, _status, delivery} =
        dispatch(c, Conformance.request(id, "test-model"), ctx, "conf-#{id}")

      assert :ok = Conformance.check(id, delivery, calls())
      assert_received {:sent, sent}
      png = Conformance.image()
      assert Enum.any?(sent.messages, &match?(%{parts: [_, %{bytes: ^png}]}, &1))
    end
  end

  ## Configuration and redaction

  test "configuration is fixed and validated; Config inspect, errors and status carry no credential or prompt (configure, Inspect)",
       ctx do
    c = config()
    refute inspect(c) =~ @secret
    assert {:error, :configuration} = AiText.configure(binding: Elzoo.AiText.TestBinding)
    assert {:error, :configuration} = AiText.configure([])
    assert {:error, :configuration} = AiText.configure(:nope)

    for bad <- [
          [models: []],
          [max_request_bytes: 70_000],
          [receive_timeout_ms: 0],
          [credentials: "not a function"],
          [unknown: 1]
        ] do
      opts =
        Keyword.merge(
          [
            binding: Elzoo.AiText.TestBinding,
            tenant: "t",
            provider: Elzoo.AiText.TestProvider,
            credentials: fn -> {:ok, "k"} end,
            models: ["m"],
            sink: fn _, _ -> :ok end
          ],
          bad
        )

      assert {:error, :configuration} = AiText.configure(opts), inspect(Keyword.keys(bad))
    end

    for {need, i} <-
          Enum.with_index([
            fn -> {:error, @secret} end,
            fn -> raise "vault #{@secret}" end,
            fn -> {:ok, @secret <> " "} end,
            fn -> {:ok, String.duplicate("k", 1025)} end,
            fn -> {:ok, :atom} end,
            fn -> @secret end
          ]) do
      c = config(credentials: need)
      {pid, _a, status, delivery} = dispatch(c, request(), ctx, "n-#{i}")
      assert {:outcome, _, {:refused, :credentials_unavailable, %{retry_after: nil}}} = delivery
      assert calls() == 0

      text =
        inspect({delivery, status, :sys.get_state(pid)},
          limit: :infinity,
          printable_limit: :infinity
        )

      refute text =~ @secret
      refute inspect({delivery, status}) =~ @prompt
    end
  end

  ## Source audit: the interface loads no provider dependency

  # This Piece's own files exactly as its manifest lists them (never the consumer's
  # whole lib/, which also holds other Pieces' files in an export). In this repository
  # the manifest sits two levels above this file; in an exported consumer this file
  # lands in test/elzoo/ and the manifest in .elzoo/pieces/integration/ai-text/. Exactly
  # one must exist, so a missing manifest is never skipped.
  @layouts [
    {Path.expand("../..", __DIR__), Path.expand("../../piece.json", __DIR__)},
    {Path.expand("../..", __DIR__),
     Path.expand("../../.elzoo/pieces/integration/ai-text/piece.json", __DIR__)}
  ]

  defp own_files do
    case Enum.filter(@layouts, fn {_, manifest} -> File.regular?(manifest) end) do
      [{root, manifest}] ->
        files = Jason.decode!(File.read!(manifest))["files"]
        assert "lib/elzoo/ai_text.ex" in files
        {root, files}

      found ->
        flunk("expected exactly one integration/ai-text manifest, found #{length(found)}")
    end
  end

  test "the interface's own files reference no provider library or provider Piece (source audit of the listed files)" do
    {root, files} = own_files()
    # Built by concatenation so this file does not contain the names it forbids.
    forbidden = [
      "Req" <> "LLM",
      "req" <> "_llm",
      "Pl" <> "ug",
      "Req" <> ".Test",
      "AiText." <> "Anthropic",
      "llm" <> "_db"
    ]

    for file <- files do
      source = File.read!(Path.join(root, file))
      for word <- forbidden, do: refute(source =~ word, "#{file} references #{word}")
    end
  end
end
