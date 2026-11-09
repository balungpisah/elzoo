# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/ai_text_openai_test_helper.exs", __DIR__)

defmodule Elzoo.AiText.OpenAITest.Binding do
  use Elzoo.AiText.Binding,
    id: "openai-test",
    provider_account: "openai:test-project",
    recovery_grace_ms: 1000
end

defmodule Elzoo.AiText.OpenAITest do
  # Every exchange goes to an in-process function plug through Req's :plug option
  # (no network, stub keys only). Documented-format stubs are validated against the
  # pinned OpenAPI schema; negative controls are asserted to be rejected by it.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Elzoo.AiModel.Usage
  alias Elzoo.AiText
  alias Elzoo.AiText.{OpenAI, OpenAIStub, Conformance, Schema, Sink}
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Memory

  @model "gpt-6.1-terra"
  @key "sk-proj-test-INJECTED-k7"
  @prompt "Conformance prompt."
  @commit "59f5565459caae84f43c49a738248cf2b268a70f"
  @source_sha "287f2cbf81b668735c56853b5e2ec40048c8912bead00ac8118190fae9716392"
  @schema_file Path.expand("../fixtures/openai/responses.schema.json", __DIR__)

  setup_all do
    bundle = Jason.decode!(File.read!(@schema_file))

    roots =
      for name <- ["CreateResponse", "Response", "ErrorResponse"], into: %{} do
        {:ok, root} = Schema.build(Map.put(bundle, "$ref", "#/$defs/" <> name))
        {name, root}
      end

    %{roots: roots, bundle: bundle}
  end

  setup do
    %{intents: start_supervised!({Task.Supervisor, name: nil}, id: :intent)}
  end

  ## helpers

  defp config(plug, opts) do
    {:ok, c} =
      AiText.configure(
        binding: Elzoo.AiText.OpenAITest.Binding,
        tenant: "tenant-a",
        provider: OpenAI,
        provider_config: %{plug: plug},
        credentials: Keyword.get(opts, :credentials, fn -> {:ok, @key} end),
        models: Keyword.get(opts, :models, [@model]),
        max_output_tokens: 4096,
        receive_timeout_ms: 5000,
        sink: Sink.to_pid(self())
      )

    c
  end

  defp owner(c, a, ctx) do
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
        identity: a.identity,
        arguments: a.arguments,
        deadline: a.deadline,
        clock: fn -> 100 end,
        store: Memory.store(memory),
        host: {StoreHost, %{store: Memory.store(host), authorize: fn _, _ -> :fresh end}},
        task_supervisor: ctx.intents,
        adapter_context: c,
        allow_volatile: true
      )

    pid
  end

  defp settled(pid, tries \\ 300) do
    cond do
      :sys.get_state(pid).tasks == %{} -> Intent.status(pid)
      tries == 0 -> flunk("attempt never settled")
      true -> Process.sleep(20) && settled(pid, tries - 1)
    end
  end

  # One call: admission, owner, dispatch; returns {delivery, requests, status, pid}.
  defp run(ctx, request, respond, opts \\ []) do
    {agent, plug} = OpenAIStub.start(respond)
    c = config(plug, opts)
    ref = "ref-#{System.unique_integer([:positive])}"
    {:ok, a} = AiText.admission(c, Conformance.declaration(request, ref, 10_000))
    pid = owner(c, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    status = settled(pid)
    key = a.key
    assert_receive {AiText, ^key, delivery}, 5000
    {delivery, OpenAIStub.requests(agent), status, pid}
  end

  # Admission only: returns the refusal and asserts nothing reached the stub.
  defp refused(request, opts \\ []) do
    {agent, plug} = OpenAIStub.start(fn _ -> flunk("no request expected") end)
    c = config(plug, opts)
    result = AiText.admission(c, Conformance.declaration(request, "r", 10_000))
    assert OpenAIStub.requests(agent) == []
    result
  end

  defp request(extra \\ %{}), do: Map.merge(Conformance.request(:text_completion, @model), extra)

  defp wire(%{body: body}), do: Jason.decode!(body)

  defp header(req, name), do: for({^name, v} <- req.headers, do: v)

  defp valid?(value, root), do: Schema.validate(value, root) == :ok

  # Every captured request: method, path, injected key, fixed settings, no
  # sampling or stop field, and the pinned CreateResponse schema.
  defp conforms(requests, ctx) do
    for req <- requests do
      assert req.method == "POST"
      assert req.path == "/v1/responses"
      assert header(req, "authorization") == ["Bearer " <> @key]
      body = wire(req)
      assert body["model"] == @model
      assert body["store"] == false
      assert is_integer(body["max_output_tokens"])
      refute Map.has_key?(body, "temperature") or Map.has_key?(body, "top_p")
      refute Map.has_key?(body, "stop")
      assert valid?(body, ctx.roots["CreateResponse"]), "request does not validate"
    end
  end

  # A documented-format stub: the body validates against the pinned schema.
  defp documented!({status, _, body} = spec, ctx) when is_map(body) do
    root = if status in 200..299, do: "Response", else: "ErrorResponse"
    assert valid?(body, ctx.roots[root]), "stub is not a documented #{root}: #{inspect(body)}"
    spec
  end

  defp documented!(spec, _ctx), do: spec

  # A negative control: the pinned schema rejects the body.
  defp negative!({_, _, body} = spec, ctx) do
    refute valid?(body, ctx.roots["Response"]), "negative control validates: #{inspect(body)}"
    spec
  end

  ## O1 conformance kit (the interface's scenarios against documented-format stubs)

  defp stub_for(:text),
    do:
      OpenAIStub.ok(
        OpenAIStub.response([OpenAIStub.message([OpenAIStub.text(Conformance.text())])])
      )

  defp stub_for(:length),
    do:
      OpenAIStub.ok(
        OpenAIStub.response([OpenAIStub.message([OpenAIStub.text("Cut")])],
          status: "incomplete",
          incomplete: %{"reason" => "max_output_tokens"}
        )
      )

  defp stub_for(:refusal),
    do: OpenAIStub.ok(OpenAIStub.response([OpenAIStub.message([OpenAIStub.refusal("No.")])]))

  defp stub_for(:other_finish),
    do:
      OpenAIStub.ok(
        OpenAIStub.response([OpenAIStub.message([OpenAIStub.text("x")])],
          status: "incomplete",
          incomplete: %{"reason" => "max_messages"}
        )
      )

  defp stub_for(:tool_call),
    do: OpenAIStub.ok(OpenAIStub.response([OpenAIStub.function_call(~s({"q":"x"}))]))

  defp stub_for(:tool_invalid_json),
    do: OpenAIStub.ok(OpenAIStub.response([OpenAIStub.function_call(~s({"q":))]))

  defp stub_for(:tool_schema_mismatch),
    do: OpenAIStub.ok(OpenAIStub.response([OpenAIStub.function_call(~s({"q":5}))]))

  defp stub_for(:structured),
    do:
      OpenAIStub.ok(OpenAIStub.response([OpenAIStub.message([OpenAIStub.text(~s({"answer":42}))])]))

  defp stub_for(:structured_mismatch),
    do:
      OpenAIStub.ok(
        OpenAIStub.response([OpenAIStub.message([OpenAIStub.text(~s({"answer":"forty-two"}))])])
      )

  defp stub_for(:no_usage),
    do:
      OpenAIStub.ok(OpenAIStub.response([OpenAIStub.message([OpenAIStub.text("x")])], usage: :none))

  # Negative control (not a documented-format stub): no id, status or model.
  defp stub_for(:malformed_success), do: OpenAIStub.ok(%{"object" => "response", "output" => []})
  defp stub_for(:timeout), do: {:transport_error, :timeout}

  defp stub_for(:throttled),
    do:
      {429, [{"x-request-id", "req_429"}, {"retry-after", "7"}],
       OpenAIStub.error("requests", "Rate limit reached", "rate_limit_exceeded")}

  defp stub_for(:overloaded),
    do: {503, [{"x-request-id", "req_503"}], OpenAIStub.error("server_error", "Slow down")}

  defp stub_for(:server_error), do: {500, [], OpenAIStub.error("server_error")}

  test "O1 conformance kit on Responses; stubs documented (malformed one a rejected negative control); requests validate (kit + stub + pinned schema)",
       ctx do
    for s <- Conformance.scenarios() do
      response =
        if s.stub == :malformed_success,
          do: negative!(stub_for(s.stub), ctx),
          else: documented!(stub_for(s.stub), ctx)

      {delivery, requests, _status, _pid} =
        run(ctx, Conformance.request(s.id, @model), fn _ -> response end)

      assert :ok == Conformance.check(s.id, delivery, length(requests)), inspect({s.id, delivery})
      conforms(requests, ctx)
    end
  end

  ## O2 usage and cache counters, each from a named pinned-schema field

  defp details(cached, writes, breakdown \\ nil) do
    d = %{"cached_tokens" => cached, "cache_write_tokens" => writes}
    if breakdown, do: Map.put(d, "cache_write_tokens_details", breakdown), else: d
  end

  defp raw_usage(input, details) do
    %{
      "input_tokens" => input,
      "input_tokens_details" => details,
      "output_tokens" => 10,
      "output_tokens_details" => %{"reasoning_tokens" => 3},
      "total_tokens" => input + 10
    }
  end

  defp completed_usage(ctx, raw, kind) do
    spec =
      OpenAIStub.ok(OpenAIStub.response([OpenAIStub.message([OpenAIStub.text("x")])], usage: raw))

    spec = if kind == :documented, do: documented!(spec, ctx), else: negative!(spec, ctx)
    {{:outcome, _, {:completed, c}}, requests, _, _} = run(ctx, request(), fn _ -> spec end)
    assert length(requests) == 1
    c.usage
  end

  test "O2 usage under input_includes_cached: documented cases and partial-usage negative controls (raw usage)",
       ctx do
    documented = [
      # Warm read: cached_tokens counted once (subtracted from input_tokens).
      {raw_usage(2006, details(1920, 0)),
       %{uncached: 86, read: 1920, writes: [%{ttl: "provider_default", amount: 0}], prompt: 2006}},
      # Cold write with the documented TTL breakdown.
      {raw_usage(2006, details(0, 1920, %{"ttl_30m_tokens" => 1920, "ttl_12h_tokens" => 0})),
       %{
         uncached: 86,
         read: 0,
         writes: [%{ttl: "30m", amount: 1920}, %{ttl: "12h", amount: 0}],
         prompt: 2006
       }},
      # Total only (the breakdown is optional in the schema).
      {raw_usage(2006, details(0, 1920)),
       %{
         uncached: 86,
         read: 0,
         writes: [%{ttl: "provider_default", amount: 1920}],
         prompt: 2006
       }},
      # Below the cacheable minimum: reported zeros are known zeros.
      {raw_usage(12, details(0, 0)),
       %{uncached: 12, read: 0, writes: [%{ttl: "provider_default", amount: 0}], prompt: 12}},
      # The family's accounting example (ELZ-079 M2): 12000 input, 4000 read,
      # 3000 + 4000 written, 1000 ordinary.
      {raw_usage(12000, details(4000, 7000, %{"ttl_30m_tokens" => 3000, "ttl_12h_tokens" => 4000})),
       %{
         uncached: 1000,
         read: 4000,
         writes: [%{ttl: "30m", amount: 3000}, %{ttl: "12h", amount: 4000}],
         prompt: 12000
       }},
      # Schema-valid but inconsistent: total and breakdown disagree, writes unknown.
      {raw_usage(12000, details(4000, 9000, %{"ttl_30m_tokens" => 3000, "ttl_12h_tokens" => 4000})),
       %{
         uncached: :unknown,
         read: 4000,
         writes: [%{ttl: "provider_default", amount: :unknown}],
         prompt: :unknown
       }},
      # Inconsistent: read exceeds input; never a clamped zero.
      {raw_usage(100, details(400, 0)),
       %{
         uncached: :unknown,
         read: 400,
         writes: [%{ttl: "provider_default", amount: 0}],
         prompt: :unknown
       }}
    ]

    for {raw, e} <- documented do
      u = completed_usage(ctx, raw, :documented)
      assert u.source == :provider_reported
      assert u.convention == %{input_includes_cached: true}
      assert Usage.amount(u, :input_uncached_tokens) == e.uncached, inspect(raw)
      assert Usage.amount(u, :cache_read_tokens) == e.read, inspect(raw)
      assert u.cache_writes == e.writes, inspect(raw)
      assert Usage.prompt_input_tokens(u) == e.prompt, inspect(raw)
      assert Usage.amount(u, :output_tokens) == 10
      assert Usage.amount(u, :reasoning_tokens) == 3
    end

    # Negative controls: the pinned schema requires these fields; their absence
    # is not documented format, and the counters are unknown, never zero.
    negative = [
      {Map.delete(raw_usage(50, details(0, 0)), "input_tokens_details"),
       %{read: :unknown, writes: [%{ttl: "provider_default", amount: :unknown}]}},
      {raw_usage(50, %{"cached_tokens" => 8}),
       %{read: 8, writes: [%{ttl: "provider_default", amount: :unknown}]}},
      {raw_usage(50, %{"cache_write_tokens" => 0}),
       %{read: :unknown, writes: [%{ttl: "provider_default", amount: 0}]}},
      {raw_usage(50, details(0, nil, %{"ttl_30m_tokens" => 5}) |> Map.delete("cache_write_tokens")),
       %{read: 0, writes: [%{ttl: "provider_default", amount: :unknown}]}}
    ]

    for {raw, e} <- negative do
      u = completed_usage(ctx, raw, :negative)
      assert Usage.amount(u, :cache_read_tokens) == e.read, inspect(raw)
      assert u.cache_writes == e.writes, inspect(raw)
      assert Usage.amount(u, :input_uncached_tokens) == :unknown, inspect(raw)
      assert Usage.prompt_input_tokens(u) == :unknown
    end

    u = completed_usage(ctx, Map.delete(raw_usage(50, details(0, 0)), "output_tokens"), :negative)
    assert Usage.amount(u, :output_tokens) == :unknown
  end

  ## O3 cache key and cache-hint mapping

  test "O3 cache key: fixed vectors, prefix, alphabet, 47 bytes, length framing (cache_key/2)" do
    vectors = [
      {"a", "bc", "ez1.tTTOFqycizaCPzmjlc6ODjx62WBbgrVETxjK2s0hel0"},
      {"ab", "c", "ez1.8pOfkDAW5bspseSmHNvTdiIMoDokGAs5mV8tUPLgpkc"},
      {"tenant-a", "docs-v1", "ez1.CIFTtRJEVDbEzBoMe8kiqDovhziauuEB5LLaAD_s9Cs"},
      {"tenant-b", "docs-v1", "ez1.dchKKTeT-G2uRxLirfPkqjzh7PSUbSOk4TrVj3R7Yag"}
    ]

    for {tenant, local, expected} <- vectors do
      key = OpenAI.cache_key(tenant, local)
      assert key == expected
      assert byte_size(key) == 47
      assert key =~ ~r/\Aez1\.[A-Za-z0-9_-]{43}\z/
    end

    assert OpenAI.cache_key("a", "bc") != OpenAI.cache_key("ab", "c")
    assert OpenAI.cache_key("tenant-a", "docs-v1") == OpenAI.cache_key("tenant-a", "docs-v1")
  end

  defp hint(breakpoints, ttl \\ "30m", tenant \\ "tenant-a"),
    do: %{"tenant" => tenant, "local_key" => "docs-v1", "ttl" => ttl, "breakpoints" => breakpoints}

  # A mixed transcript: system, user, assistant with a tool call, tool result, user.
  defp transcript do
    [
      %{"role" => "system", "text" => "Answer briefly."},
      %{"role" => "user", "text" => "look it up"},
      %{
        "role" => "assistant",
        "text" => "",
        "tool_calls" => [%{"id" => "call_1", "name" => "lookup", "arguments" => %{"q" => "x"}}]
      },
      %{"role" => "tool_result", "tool_use_id" => "call_1", "text" => "found"},
      %{"role" => "user", "text" => "and then?"}
    ]
  end

  defp marked(body) do
    for item <- body["input"],
        is_list(item["content"]),
        part <- item["content"],
        Map.has_key?(part, "prompt_cache_breakpoint"),
        do: {item["role"], part["text"], part["prompt_cache_breakpoint"]}
  end

  test "O3 cache hint mapped to key, explicit options and markers on a mixed transcript (captured request)",
       ctx do
    tools = Conformance.request(:tool_well_formed, @model)["tools"]

    ok =
      documented!(
        OpenAIStub.ok(OpenAIStub.response([OpenAIStub.message([OpenAIStub.text("x")])])),
        ctx
      )

    # {:message, i} indexes the non-system messages: 0 = "look it up", 3 = "and then?".
    for {breakpoints, ttl, expected} <- [
          {["system"], "30m", [{"system", "Answer briefly."}]},
          {[%{"message" => 3}], "12h", [{"user", "and then?"}]},
          {["system", %{"message" => 0}, %{"message" => 3}], "30m",
           [{"system", "Answer briefly."}, {"user", "look it up"}, {"user", "and then?"}]}
        ] do
      req =
        request(%{
          "tools" => tools,
          "messages" => transcript(),
          "cache_hint" => hint(breakpoints, ttl)
        })

      {_, [captured], _, _} = run(ctx, req, fn _ -> ok end)
      conforms([captured], ctx)
      body = wire(captured)
      assert body["prompt_cache_key"] == "ez1.CIFTtRJEVDbEzBoMe8kiqDovhziauuEB5LLaAD_s9Cs"
      assert body["prompt_cache_options"] == %{"mode" => "explicit", "ttl" => ttl}

      assert Enum.sort(
               for {r, t, bp} <- marked(body),
                   do:
                     (
                       assert(bp == %{"mode" => "explicit"})
                       {r, t}
                     )
             ) ==
               Enum.sort(expected)
    end

    # Without a hint: no key, no options, no markers (OpenAI's implicit caching).
    {_, [captured], _, _} =
      run(ctx, request(%{"messages" => transcript(), "tools" => tools}), fn _ -> ok end)

    conforms([captured], ctx)
    body = wire(captured)
    refute Map.has_key?(body, "prompt_cache_key") or Map.has_key?(body, "prompt_cache_options")
    assert marked(body) == []
  end

  test "O3 unaddressable or cross-tenant cache targets refused before any request or credential read (admission)" do
    two_systems = [%{"role" => "system", "text" => "a"} | transcript()]
    no_system = tl(transcript())
    tools = Conformance.request(:tool_well_formed, @model)["tools"]
    base = %{"tools" => tools, "messages" => transcript()}

    cases = [
      {Map.put(base, "cache_hint", hint(["tools"])), :unsupported_feature},
      {Map.merge(base, %{"messages" => no_system, "cache_hint" => hint(["system"])}),
       :unsupported_feature},
      {Map.merge(base, %{"messages" => two_systems, "cache_hint" => hint(["system"])}),
       :unsupported_feature},
      # Non-system index 1 is the assistant message, 2 the tool result.
      {Map.put(base, "cache_hint", hint([%{"message" => 1}])), :unsupported_feature},
      {Map.put(base, "cache_hint", hint([%{"message" => 2}])), :unsupported_feature},
      {Map.put(base, "cache_hint", hint([%{"message" => 4}])), :invalid_request},
      {Map.put(base, "cache_hint", hint(["system"], "5m")), :unsupported_feature},
      {Map.put(base, "cache_hint", hint(["system"], "24h")), :unsupported_feature},
      {Map.put(base, "cache_hint", hint(["system"], "30m", "tenant-b")), :invalid_request}
    ]

    for {extra, reason} <- cases do
      read = :counters.new(1, [])
      creds = fn -> :counters.add(read, 1, 1) && {:ok, @key} end

      assert {:error, {:refused, ^reason}} = refused(request(extra), credentials: creds),
             inspect(extra["cache_hint"])

      assert :counters.get(read, 1) == 0
    end
  end

  ## O4 reasoning, sampling, stop sequences, models, tool-result errors, structured output

  test "O4 reasoning, refusals, tool results, structured output and tool choice (translate + admission)",
       ctx do
    ok =
      documented!(
        OpenAIStub.ok(OpenAIStub.response([OpenAIStub.message([OpenAIStub.text("x")])])),
        ctx
      )

    for {level, effort} <- [
          {nil, "none"},
          {"none", "none"},
          {"low", "low"},
          {"medium", "medium"},
          {"high", "high"},
          {"max", "max"}
        ] do
      extra = if level, do: %{"reasoning" => level}, else: %{}
      {_, [captured], _, _} = run(ctx, request(extra), fn _ -> ok end)
      conforms([captured], ctx)
      assert wire(captured)["reasoning"] == %{"effort" => effort}
    end

    assert {:error, {:refused, :unsupported_feature}} =
             refused(request(%{"sampling" => %{"temperature" => 0.1}}))

    assert {:error, {:refused, :unsupported_feature}} =
             refused(request(%{"stop_sequences" => ["END"]}))

    # A model in the host's allowlist but not evidenced by this Piece.
    assert {:error, {:refused, :invalid_request}} =
             refused(Conformance.request(:text_completion, "gpt-4o-mini"),
               models: [@model, "gpt-4o-mini"]
             )

    error_result =
      request(%{
        "messages" => [
          %{"role" => "user", "text" => "look it up"},
          %{
            "role" => "assistant",
            "text" => "",
            "tool_calls" => [%{"id" => "call_1", "name" => "lookup", "arguments" => %{"q" => "x"}}]
          },
          %{
            "role" => "tool_result",
            "tool_use_id" => "call_1",
            "text" => "boom",
            "is_error" => true
          }
        ],
        "tools" => Conformance.request(:tool_well_formed, @model)["tools"]
      })

    assert {:error, {:refused, :unsupported_feature}} = refused(error_result)

    # A successful tool result reaches the wire as a function_call_output.
    success = put_in(error_result, ["messages", Access.at(2), "is_error"], false)
    {_, [captured], _, _} = run(ctx, success, fn _ -> ok end)
    conforms([captured], ctx)

    assert [%{"call_id" => "call_1", "output" => "boom"}] =
             for(i <- wire(captured)["input"], i["type"] == "function_call_output", do: i)

    assert [%{"call_id" => "call_1", "name" => "lookup"}] =
             for(i <- wire(captured)["input"], i["type"] == "function_call", do: i)

    # Structured output: text.format json_schema with the caller's schema unchanged.
    req = Conformance.request(:structured_valid, @model)
    {_, [captured], _, _} = run(ctx, req, fn _ -> stub_for(:structured) end)
    conforms([captured], ctx)
    format = wire(captured)["text"]["format"]
    assert format["type"] == "json_schema"
    assert format["schema"] == req["output_schema"]
    assert format["strict"] == false

    # Tool choice "any" is OpenAI's "required"; a named tool is a function choice.
    tools_req = Conformance.request(:tool_well_formed, @model)

    for {choice, wire_choice} <- [
          {%{"type" => "any"}, "required"},
          {%{"type" => "none"}, "none"},
          {%{"type" => "tool", "name" => "lookup"}, %{"type" => "function", "name" => "lookup"}}
        ] do
      {_, [captured], _, _} =
        run(ctx, Map.put(tools_req, "tool_choice", choice), fn _ -> stub_for(:tool_call) end)

      conforms([captured], ctx)
      assert wire(captured)["tool_choice"] == wire_choice
    end
  end

  ## O5 finish mapping, provider-executed tool items, failed responses, malformed 2xx

  test "O5 finish and status mapping; tool items, failed and malformed bodies unknown, one request each (decode)",
       ctx do
    msg = [OpenAIStub.message([OpenAIStub.text("x")])]

    for {spec, finish} <- [
          {OpenAIStub.response(msg,
             status: "incomplete",
             incomplete: %{"reason" => "content_filter"}
           ), :content_filter},
          {OpenAIStub.response(msg, status: "cancelled"), {:other, "cancelled"}},
          {OpenAIStub.response([OpenAIStub.reasoning() | msg]), :stop}
        ] do
      response = documented!(OpenAIStub.ok(spec), ctx)
      {delivery, requests, _, _} = run(ctx, request(), fn _ -> response end)
      assert {:outcome, _, {:completed, %{finish: ^finish}}} = delivery
      assert length(requests) == 1
    end

    # Documented but never requested: a provider-executed web search item.
    web_search = %{
      "type" => "web_search_call",
      "id" => "ws_1",
      "status" => "completed",
      "action" => %{"type" => "search", "query" => "x"}
    }

    failed =
      OpenAIStub.response([],
        status: "failed",
        error: %{"code" => "server_error", "message" => "stub failure"}
      )

    for {body, outcome} <- [
          {OpenAIStub.response([web_search | msg]), {:unknown, :malformed_response}},
          {failed, {:unknown, :provider_error}}
        ] do
      response = documented!(OpenAIStub.ok(body), ctx)
      {delivery, requests, _, _} = run(ctx, request(), fn _ -> response end)
      assert {:outcome, _, ^outcome} = delivery, inspect(body["output"])
      assert length(requests) == 1
    end

    # Negative controls: rejected by the pinned schema; unknown{malformed_response}.
    for body <- [
          %{},
          Map.delete(OpenAIStub.response(msg), "id"),
          Map.put(OpenAIStub.response(msg), "output", "not a list"),
          Map.put(OpenAIStub.response(msg), "status", "exploded"),
          OpenAIStub.response([OpenAIStub.message([%{"type" => "image"}])])
        ] do
      response = negative!(OpenAIStub.ok(body), ctx)
      {delivery, requests, _, _} = run(ctx, request(), fn _ -> response end)
      assert {:outcome, _, {:unknown, :malformed_response}} = delivery, inspect(body)
      assert length(requests) == 1
    end

    {delivery, _, _, _} = run(ctx, request(), fn _ -> {200, [], "not json"} end)
    assert {:outcome, _, {:unknown, :malformed_response}} = delivery
  end

  ## O6 error statuses and a redirect; O7 timeout

  test "O6 error statuses and a redirect: one request each, mapped, headers kept (halting step)",
       ctx do
    cases = [
      {{400, [], OpenAIStub.error("invalid_request_error", @prompt)},
       {:refused, :invalid_request, %{retry_after: nil}}},
      {{401, [], OpenAIStub.error("invalid_request_error", "Incorrect API key", "invalid_api_key")},
       {:refused, :authentication_failed, %{retry_after: nil}}},
      {{403, [], OpenAIStub.error("invalid_request_error", "Country not supported")},
       {:refused, :permission_denied, %{retry_after: nil}}},
      {{404, [], OpenAIStub.error("invalid_request_error", "model not found", "model_not_found")},
       {:refused, :not_found, %{retry_after: nil}}},
      {{413, [], OpenAIStub.error("invalid_request_error")},
       {:refused, :too_large, %{retry_after: nil}}},
      {{429, [{"retry-after", "7"}], OpenAIStub.error("requests", "rate", "rate_limit_exceeded")},
       {:refused, :throttled, %{retry_after: 7}}},
      {{429, [], OpenAIStub.error("insufficient_quota", "quota", "insufficient_quota")},
       {:refused, :throttled, %{retry_after: nil}}},
      {{500, [], OpenAIStub.error("server_error")}, {:unknown, :provider_error}},
      {{502, [], OpenAIStub.error("server_error")}, {:unknown, :provider_error}},
      {{503, [{"retry-after", "3"}], OpenAIStub.error("server_error", "Slow down")},
       {:refused, :overloaded, %{retry_after: 3}}},
      {{503, [], OpenAIStub.error("server_error", "Slow down")},
       {:refused, :overloaded, %{retry_after: nil}}},
      {{504, [], OpenAIStub.error("server_error")}, {:unknown, :timeout}},
      {{302, [{"location", "/v1/elsewhere"}], ""}, {:unknown, :provider_error}}
    ]

    for {response, expected} <- cases do
      response = documented!(response, ctx)
      {delivery, requests, _, _} = run(ctx, request(), fn _ -> response end)
      assert {:outcome, _, ^expected} = delivery, inspect(response)
      assert length(requests) == 1, inspect(response)
      refute inspect(delivery) =~ @prompt
      refute inspect(delivery) =~ "stub error"
      conforms(requests, ctx)
    end

    {:ok, response} =
      Req.request(
        Req.new(
          url: "http://stub.invalid/x",
          retry: false,
          plug: fn conn ->
            conn
            |> Plug.Conn.put_resp_header("x-request-id", "req_kept")
            |> Plug.Conn.put_resp_header("retry-after", "7")
            |> Plug.Conn.send_resp(429, "{}")
          end
        )
        |> Req.Request.prepend_response_steps(elzoo_capture: &OpenAI.capture/1)
      )

    assert %{status: 429, request_id: "req_kept", retry_after: "7"} = response.private.elzoo_raw
  end

  test "O7 transport timeout after send is unknown with exactly one request (call)",
       ctx do
    {delivery, requests, status, pid} =
      run(ctx, request(), fn _ -> {:transport_error, :timeout} end)

    assert {:outcome, _, {:unknown, :timeout}} = delivery
    assert length(requests) == 1
    assert {:Dispatched, _, 1} = status.phase
    assert {:error, _} = Intent.advance(pid, :dispatch)

    {delivery, requests, _, _} = run(ctx, request(), fn _ -> {:transport_error, :closed} end)
    assert {:outcome, _, {:unknown, :transport}} = delivery
    assert length(requests) == 1
  end

  ## O12 bounds: the response body is capped while received; the pinned minimum output cap

  test "O12 an oversized body is stopped at the bound while received and is unknown with one request; output caps below 16 are refused (call + translate)",
       ctx do
    # Chunked accumulation stops at the 4 MiB bound and never keeps the body.
    chunk = :binary.copy("x", 1_048_576)
    acc = {Req.new(), Req.Response.new(status: 200)}

    {:cont, acc} = OpenAI.bounded({:data, chunk}, acc)
    {:cont, acc} = OpenAI.bounded({:data, chunk}, acc)
    {:cont, acc} = OpenAI.bounded({:data, chunk}, acc)
    {:cont, {_, resp} = acc} = OpenAI.bounded({:data, chunk}, acc)
    assert byte_size(resp.body) == 4_194_304
    {:halt, {_, resp}} = OpenAI.bounded({:data, "y"}, acc)
    assert resp.body == ""
    assert resp.private.elzoo_oversize

    # End to end: a body over the bound is unknown{malformed_response}, one request.
    big = OpenAIStub.response([OpenAIStub.message([OpenAIStub.text(:binary.copy("z", 4_200_000))])])
    {delivery, requests, _, _} = run(ctx, request(), fn _ -> OpenAIStub.ok(big) end)
    assert {:outcome, _, {:unknown, :malformed_response}} = delivery
    assert length(requests) == 1

    # The pinned CreateResponse requires max_output_tokens >= 16.
    assert {:error, {:refused, :invalid_request}} = refused(request(%{"max_output_tokens" => 15}))

    ok =
      documented!(
        OpenAIStub.ok(OpenAIStub.response([OpenAIStub.message([OpenAIStub.text("x")])])),
        ctx
      )

    {_, [captured], _, _} = run(ctx, request(%{"max_output_tokens" => 16}), fn _ -> ok end)
    conforms([captured], ctx)
    assert wire(captured)["max_output_tokens"] == 16
  end

  ## O8 redaction; O9 ambient keys

  test "O8 key, prompt and output never in results, inspect, state, logs or telemetry (redaction)",
       ctx do
    parent = self()
    secret_prompt = "PROMPT-SECRET-#{System.unique_integer([:positive])}"
    secret_output = "OUTPUT-SECRET-#{System.unique_integer([:positive])}"

    events = [
      [:req_llm, :request, :start],
      [:req_llm, :request, :stop],
      [:req_llm, :request, :exception],
      [:req_llm, :token_usage]
    ]

    :telemetry.attach_many(
      "elz087-o8",
      events,
      fn e, m, md, _ -> send(parent, {:telemetry, e, m, md}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("elz087-o8") end)

    req = Map.put(request(), "messages", [%{"role" => "user", "text" => secret_prompt}])

    Logger.configure(level: :debug)

    log =
      capture_log([level: :debug], fn ->
        for response <- [
              OpenAIStub.ok(
                OpenAIStub.response([OpenAIStub.message([OpenAIStub.text(secret_output)])])
              ),
              {400, [], OpenAIStub.error("invalid_request_error", secret_prompt)},
              {:transport_error, :timeout}
            ] do
          {delivery, _, status, pid} = run(ctx, req, fn _ -> response end)
          state = inspect(:sys.get_state(pid), limit: :infinity, printable_limit: :infinity)
          refute state =~ @key
          refute state =~ secret_output
          refute inspect(status) =~ secret_prompt
          refute inspect(delivery, limit: :infinity, printable_limit: :infinity) =~ @key
          refute inspect(delivery, limit: :infinity, printable_limit: :infinity) =~ secret_prompt
        end
      end)

    Logger.configure(level: :warning)
    refute log =~ @key
    refute log =~ secret_prompt
    refute log =~ secret_output

    telemetry = collect_telemetry([])
    text = inspect(telemetry, limit: :infinity, printable_limit: :infinity)
    refute text =~ @key
    refute text =~ secret_prompt
    refute text =~ secret_output
  end

  defp collect_telemetry(acc) do
    receive do
      {:telemetry, _, _, _} = t -> collect_telemetry([t | acc])
    after
      100 -> acc
    end
  end

  test "O9 ambient keys never used, a failing Need sends nothing (credential Need)",
       ctx do
    System.put_env("OPENAI_API_KEY", "sk-ambient-env")
    Application.put_env(:req_llm, :openai_api_key, "sk-ambient-app")

    on_exit(fn ->
      System.delete_env("OPENAI_API_KEY")
      Application.delete_env(:req_llm, :openai_api_key)
    end)

    # The repository configuration sets load_dotenv: false and the README requires
    # every consumer to set it; an exported consumer without that line gets it
    # here so the restart below exercises the setting itself.
    dotenv_setting = Application.get_env(:req_llm, :load_dotenv)
    Application.put_env(:req_llm, :load_dotenv, false)
    on_exit(fn -> Application.put_env(:req_llm, :load_dotenv, dotenv_setting) end)
    ok = OpenAIStub.ok(OpenAIStub.response([OpenAIStub.message([OpenAIStub.text("x")])]))

    {delivery, requests, _, _} =
      run(ctx, request(), fn _ -> ok end, credentials: fn -> {:error, :vault} end)

    assert {:outcome, _, {:refused, :credentials_unavailable, _}} = delivery
    assert requests == []

    {_, [req], _, _} = run(ctx, request(), fn _ -> ok end)
    assert header(req, "authorization") == ["Bearer " <> @key]

    dir = Path.join(System.tmp_dir!(), "elz087-dotenv-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".env"), "ELZ087_DOTENV_SENTINEL=loaded\nOPENAI_API_KEY=sk-dotenv\n")
    previous = File.cwd!()

    try do
      File.cd!(dir)
      :ok = Application.stop(:req_llm)
      {:ok, _} = Application.ensure_all_started(:req_llm)
    after
      File.cd!(previous)
      File.rm_rf!(dir)
    end

    assert System.get_env("ELZ087_DOTENV_SENTINEL") == nil
    assert System.get_env("OPENAI_API_KEY") == "sk-ambient-env"
  end

  ## O10 source audit; O11 fixture provenance; install configuration

  # This Piece's manifest: two levels above this file in the repository; under
  # .elzoo/pieces/integration/ai-text-openai/ in an exported consumer, whose lib/
  # files sit at the consumer root (two levels above this file). Exactly one manifest
  # must exist; the listed files resolve against the same root in both layouts.
  defp manifest do
    root = Path.expand("../..", __DIR__)

    found =
      [
        Path.join(root, "piece.json"),
        Path.join(root, ".elzoo/pieces/integration/ai-text-openai/piece.json")
      ]
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(&(Jason.decode!(File.read!(&1))["id"] == "integration/ai-text-openai"))

    assert [one] = found
    {one, root}
  end

  test "O10 source audit of this Piece's own manifest-listed files (own files)" do
    {manifest, root} = manifest()

    files =
      for f <- Jason.decode!(File.read!(manifest))["files"],
          String.starts_with?(f, "lib/"),
          do: f

    assert "lib/elzoo/ai_text/open_ai.ex" in files

    forbidden = [
      "Tool.execute",
      "execute_and_append_tools",
      "System.get_env",
      "Application.get_env(:req_llm",
      "Dotenvy",
      "put_key",
      "auth_mode",
      "oauth",
      "previous_response_id",
      "generate_text",
      "stream_text",
      "generate_object",
      "Plug"
    ]

    for f <- files do
      source = File.read!(Path.join(root, f))
      for word <- forbidden, do: refute(source =~ word, "#{f} contains #{word}")
      if source =~ "Req.request(", do: assert(source =~ "prepend_response_steps(elzoo_capture:")
    end
  end

  test "O11 schema fixture names the pinned commit and source hash (fixture)",
       ctx do
    assert ctx.bundle["$comment"] =~ @commit
    assert ctx.bundle["$comment"] =~ @source_sha
    assert ctx.bundle["$comment"] =~ "MIT"
    refute File.read!(@schema_file) =~ "#/components/"
    assert map_size(ctx.bundle["$defs"]) == 286
  end

  # This Piece's README: in this repository three levels above test/elzoo/ under
  # pieces/; in an exported consumer the copier puts it under
  # .elzoo/pieces/integration/ai-text-openai/ while this file lands in test/elzoo/.
  # Exactly one must exist, so a missing README is never skipped.
  @readmes [
    Path.expand("../../../../../pieces/integration/ai-text-openai/README.md", __DIR__),
    Path.expand("../../.elzoo/pieces/integration/ai-text-openai/README.md", __DIR__)
  ]

  test "the README's Install configuration section carries the exact consumer config line (README, either layout)" do
    assert [readme] = Enum.filter(@readmes, &File.regular?/1)
    text = File.read!(readme)
    [_, section] = String.split(text, "## Install configuration", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)
    assert section =~ "\nconfig :req_llm, load_dotenv: false\n"
    assert section =~ "merges no configuration"
    assert section =~ "does not prove a consumer's configuration"
  end
end
