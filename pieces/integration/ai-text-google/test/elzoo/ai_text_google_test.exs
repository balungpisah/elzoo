# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/ai_text_google_test_helper.exs", __DIR__)

defmodule Elzoo.AiText.GoogleTest.Binding do
  use Elzoo.AiText.Binding,
    id: "google-test",
    provider_account: "google:test-project",
    recovery_grace_ms: 1000
end

defmodule Elzoo.AiText.GoogleTest do
  # Provider exchanges use an in-process function plug with stub keys; no
  # network and no live API spend. Every captured request is validated against
  # the hand-derived request schema of the fetched generateContent reference.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Elzoo.AiModel.Usage
  alias Elzoo.AiText
  alias Elzoo.AiText.{Google, GoogleStub, Conformance, Schema, Sink}
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Memory

  @model "gemini-3.8-flash"
  @path "/v1beta/models/gemini-3.8-flash:generateContent"
  @key "AIzaSy-test-INJECTED-g3"
  @prompt "Conformance prompt."
  @source_sha "a11386534137dfde9430553b9ee63ffc25a2c6e41908e5192cabcb650252773c"
  @schema_file Path.expand("../fixtures/google/generate-content-request.schema.json", __DIR__)

  setup_all do
    bundle = Jason.decode!(File.read!(@schema_file))
    {:ok, root} = Schema.build(bundle)
    %{root: root, bundle: bundle}
  end

  setup do
    %{intents: start_supervised!({Task.Supervisor, name: nil}, id: :intent)}
  end

  ## helpers

  defp config(plug, opts) do
    {:ok, c} =
      AiText.configure(
        [
          binding: Elzoo.AiText.GoogleTest.Binding,
          tenant: "tenant-a",
          provider: Google,
          provider_config: %{plug: plug},
          credentials: Keyword.get(opts, :credentials, fn -> {:ok, @key} end),
          models: Keyword.get(opts, :models, [@model]),
          max_output_tokens: 4096,
          receive_timeout_ms: 5000,
          sink: Sink.to_pid(self())
        ] ++ if(opts[:artifacts], do: [artifacts: opts[:artifacts]], else: [])
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
    {agent, plug} = GoogleStub.start(respond)
    c = config(plug, opts)
    ref = "ref-#{System.unique_integer([:positive])}"
    {:ok, a} = AiText.admission(c, Conformance.declaration(request, ref, 10_000))
    pid = owner(c, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    status = settled(pid)
    key = a.key
    assert_receive {AiText, ^key, delivery}, 5000
    {delivery, GoogleStub.requests(agent), status, pid}
  end

  # Admission only: returns the result and asserts nothing reached the stub.
  defp refused(request, opts \\ []) do
    {agent, plug} = GoogleStub.start(fn _ -> flunk("no request expected") end)
    c = config(plug, opts)
    result = AiText.admission(c, Conformance.declaration(request, "r", 10_000))
    assert GoogleStub.requests(agent) == []
    result
  end

  defp request(extra \\ %{}), do: Map.merge(Conformance.request(:text_completion, @model), extra)

  defp wire(%{body: body}), do: Jason.decode!(body)

  defp header(req, name), do: for({^name, v} <- req.headers, do: v)

  # Every captured request: method, path, no query, the injected key only in
  # x-goog-api-key, and the hand-derived request schema.
  defp conforms(requests, ctx) do
    for req <- requests do
      assert req.method == "POST"
      assert req.path == @path
      assert req.query == ""
      assert header(req, "x-goog-api-key") == [@key]

      for {name, value} <- req.headers,
          name != "x-goog-api-key",
          do: refute(value =~ @key, "key in header #{name}")

      refute req.body =~ @key
      assert Schema.validate(wire(req), ctx.root) == :ok, "request does not validate: #{req.body}"
    end
  end

  defp ok_text(t \\ Conformance.text()),
    do: GoogleStub.ok(GoogleStub.response([GoogleStub.text(t)], "STOP"))

  ## G1 conformance kit (every scenario and the image scenario)

  defp stub_for(:text), do: ok_text()

  defp stub_for(:length),
    do: GoogleStub.ok(GoogleStub.response([GoogleStub.text("Cut")], "MAX_TOKENS"))

  defp stub_for(:refusal), do: GoogleStub.ok(GoogleStub.response(:none, "SAFETY"))

  defp stub_for(:other_finish),
    do: GoogleStub.ok(GoogleStub.response([GoogleStub.text("x")], "RECITATION"))

  defp stub_for(:tool_call),
    do: GoogleStub.ok(GoogleStub.response([GoogleStub.function_call(%{"q" => "x"})], "STOP"))

  # Negative control (args is documented as an object): a string.
  defp stub_for(:tool_invalid_json),
    do: GoogleStub.ok(GoogleStub.response([GoogleStub.function_call(~s({"q":))], "STOP"))

  defp stub_for(:tool_schema_mismatch),
    do: GoogleStub.ok(GoogleStub.response([GoogleStub.function_call(%{"q" => 5})], "STOP"))

  defp stub_for(:structured), do: ok_text(~s({"answer":42}))
  defp stub_for(:structured_mismatch), do: ok_text(~s({"answer":"forty-two"}))

  defp stub_for(:no_usage),
    do: GoogleStub.ok(GoogleStub.response([GoogleStub.text("x")], "STOP", usage: :none))

  # Negative control: no responseId and no finishReason.
  defp stub_for(:malformed_success),
    do:
      GoogleStub.ok(%{
        "candidates" => [%{"content" => %{"role" => "model", "parts" => [%{"text" => "x"}]}}]
      })

  defp stub_for(:timeout), do: {:transport_error, :timeout}

  defp stub_for(:throttled),
    do: {429, [{"retry-after", "7"}], GoogleStub.error(429, "RESOURCE_EXHAUSTED")}

  defp stub_for(:overloaded), do: {503, [], GoogleStub.error(503, "UNAVAILABLE")}
  defp stub_for(:server_error), do: {500, [], GoogleStub.error(500, "INTERNAL")}

  test "G1 conformance kit on generateContent: every scenario, captured requests validate, key only in x-goog-api-key, tool schemas unchanged (kit + stub + schema)",
       ctx do
    for s <- Conformance.scenarios() do
      req = Conformance.request(s.id, @model)
      response = stub_for(s.stub)
      {delivery, requests, _status, _pid} = run(ctx, req, fn _ -> response end)

      assert :ok == Conformance.check(s.id, delivery, length(requests)), inspect({s.id, delivery})
      conforms(requests, ctx)
      [body] = Enum.map(requests, &wire/1)

      case req["tools"] do
        [tool] ->
          assert [%{"functionDeclarations" => [decl]}] = body["tools"]
          assert decl["parametersJsonSchema"] == tool["input_schema"]
          assert decl["parametersJsonSchema"]["additionalProperties"] == false
          refute Map.has_key?(decl, "parameters")

        nil ->
          refute Map.has_key?(body, "tools")
      end

      case req["output_schema"] do
        nil ->
          refute Map.has_key?(body["generationConfig"], "responseJsonSchema")

        schema ->
          assert body["generationConfig"]["responseJsonSchema"] == schema
          assert body["generationConfig"]["responseMimeType"] == "application/json"
      end

      assert body["generationConfig"]["maxOutputTokens"] == 256
      assert body["systemInstruction"] == %{"parts" => [%{"text" => "Answer briefly."}]}
    end
  end

  test "G1 image scenario: inline data carries the kit's PNG after the text part (kit + stub + schema)",
       ctx do
    for s <- Conformance.image_scenarios() do
      {delivery, requests, _, _} =
        run(ctx, Conformance.request(s.id, @model), fn _ -> stub_for(s.stub) end,
          artifacts: Conformance.image_need()
        )

      assert :ok == Conformance.check(s.id, delivery, length(requests)), inspect(delivery)
      conforms(requests, ctx)
      [body] = Enum.map(requests, &wire/1)

      assert [%{"role" => "user", "parts" => [%{"text" => "Describe the image."}, image]}] =
               body["contents"]

      assert image["inline_data"]["mime_type"] == "image/png"
      assert Base.decode64!(image["inline_data"]["data"]) == Conformance.image()
    end
  end

  test "G2 undeclared features are refused unsupported_feature by ai-text with no request (admission)" do
    assert Google.capabilities().features == [:tools, :structured_output, :image_input]

    for extra <- [
          %{"stop_sequences" => ["END"]},
          %{"sampling" => %{"temperature" => 0.5}},
          %{"reasoning" => "low"},
          %{
            "cache_hint" => %{
              "tenant" => "tenant-a",
              "local_key" => "k",
              "ttl" => "5m",
              "breakpoints" => ["system"]
            }
          }
        ] do
      assert {:error, {:refused, :unsupported_feature}} = refused(request(extra)), inspect(extra)
    end
  end

  ## G3 translation: transcript, tool choice, structured output, images

  @lookup Conformance.request(:tool_well_formed, @model)["tools"] |> hd()

  test "G3 mixed transcript: system parts, model function calls with ids, function responses with ids and error key, tool choice (captured request)",
       ctx do
    # $schema is removed on req_llm's parameters path: sent unchanged here.
    tool =
      put_in(@lookup, ["input_schema", "$schema"], "https://json-schema.org/draft/2020-12/schema")

    transcript = %{
      "tools" => [tool],
      "tool_choice" => %{"type" => "tool", "name" => "lookup"},
      "messages" => [
        %{"role" => "system", "text" => "S1"},
        %{"role" => "system", "text" => "S2"},
        %{"role" => "user", "text" => "Q"},
        %{
          "role" => "assistant",
          "text" => "Calling.",
          "tool_calls" => [
            %{"id" => "c1", "name" => "lookup", "arguments" => %{"q" => "x"}},
            %{"id" => "c2", "name" => "lookup", "arguments" => %{"q" => "y"}}
          ]
        },
        %{"role" => "tool_result", "tool_use_id" => "c1", "text" => "R1"},
        %{"role" => "tool_result", "tool_use_id" => "c2", "text" => "R2", "is_error" => true},
        %{"role" => "user", "text" => "Next"}
      ]
    }

    {{:outcome, _, {:completed, _}}, requests, _, _} =
      run(ctx, request(transcript), fn _ -> ok_text() end)

    conforms(requests, ctx)
    [body] = Enum.map(requests, &wire/1)

    assert body["systemInstruction"] == %{"parts" => [%{"text" => "S1"}, %{"text" => "S2"}]}

    assert [
             %{"role" => "user", "parts" => [%{"text" => "Q"}]},
             %{"role" => "model", "parts" => [%{"text" => "Calling."}, fc1, fc2]},
             %{"role" => "user", "parts" => [fr1, fr2, %{"text" => "Next"}]}
           ] = body["contents"]

    assert fc1["functionCall"] == %{"id" => "c1", "name" => "lookup", "args" => %{"q" => "x"}}
    assert fc2["functionCall"] == %{"id" => "c2", "name" => "lookup", "args" => %{"q" => "y"}}
    # req_llm's documented skip value for calls with no Gemini-issued signature.
    assert fc1["thoughtSignature"] == Base.encode64("skip_thought_signature_validator")

    assert fr1["functionResponse"] == %{
             "id" => "c1",
             "name" => "lookup",
             "response" => %{"content" => "R1"}
           }

    assert fr2["functionResponse"] == %{
             "id" => "c2",
             "name" => "lookup",
             "response" => %{"error" => "R2"}
           }

    assert [%{"functionDeclarations" => [decl]}] = body["tools"]
    assert decl["parametersJsonSchema"] == tool["input_schema"]

    assert body["toolConfig"] == %{
             "functionCallingConfig" => %{"mode" => "ANY", "allowedFunctionNames" => ["lookup"]}
           }

    for {choice, mode} <- [{"auto", "AUTO"}, {"none", "NONE"}, {"any", "ANY"}] do
      extra = %{"tools" => [@lookup], "tool_choice" => %{"type" => choice}}
      {_, [req], _, _} = run(ctx, request(extra), fn _ -> ok_text() end)
      conforms([req], ctx)
      assert wire(req)["toolConfig"] == %{"functionCallingConfig" => %{"mode" => mode}}
    end
  end

  test "G3 shapes generateContent cannot express exactly are refused before any request (admission)" do
    user = %{"role" => "user", "text" => "Q"}
    answer = Conformance.request(:structured_valid, @model)["output_schema"]

    cases = [
      # A system message after another message.
      {%{"messages" => [user, %{"role" => "system", "text" => "late"}, user]},
       :unsupported_feature},
      # A final model turn (prefill).
      {%{"messages" => [user, %{"role" => "assistant", "text" => "Sure"}]}, :unsupported_feature},
      # Only system messages.
      {%{"messages" => [%{"role" => "system", "text" => "S"}]}, :invalid_request},
      # A tool result that answers no earlier call: no function name.
      {%{
         "messages" => [user, %{"role" => "tool_result", "tool_use_id" => "nope", "text" => "R"}]
       }, :invalid_request},
      # Structured output together with tools.
      {%{"tools" => [@lookup], "output_schema" => answer}, :unsupported_feature},
      # Output schema keywords outside the reference's responseJsonSchema list.
      {%{"output_schema" => Map.put(answer, "minProperties", 1)}, :unsupported_feature},
      {%{"output_schema" => put_in(answer, ["properties", "answer", "multipleOf"], 2)},
       :unsupported_feature},
      {%{
         "output_schema" => %{
           "$ref" => "#/$defs/a",
           "type" => "object",
           "$defs" => %{"a" => answer}
         }
       }, :unsupported_feature},
      {%{"output_schema" => %{"enum" => [true]}}, :unsupported_feature},
      # Beside $ref, a "$" keyword outside the list.
      {%{
         "output_schema" =>
           Map.put(answer, "properties", %{
             "answer" => %{"$ref" => "#/$defs/n", "$comment" => "c"}
           })
           |> Map.put("$defs", %{"n" => %{"type" => "integer"}})
       }, :unsupported_feature},
      {%{
         "output_schema" =>
           Map.put(answer, "$schema", "https://json-schema.org/draft/2020-12/schema")
       }, :unsupported_feature},
      # A $ref that names no $defs entry does not compile: ai-text refuses it.
      {%{"output_schema" => %{"$ref" => "#/$defs/missing", "$defs" => %{}}}, :invalid_request},
      # A $ref outside root $defs, and cyclic references (also through a
      # non-required property).
      {%{"output_schema" => %{"$ref" => "#"}}, :unsupported_feature},
      {%{
         "output_schema" => %{
           "$defs" => %{
             "node" => %{
               "type" => "object",
               "properties" => %{"next" => %{"$ref" => "#/$defs/node"}}
             }
           },
           "$ref" => "#/$defs/node"
         }
       }, :unsupported_feature},
      {%{
         "output_schema" => %{
           "$defs" => %{
             "a" => %{
               "type" => "object",
               "properties" => %{"b" => %{"$ref" => "#/$defs/b"}},
               "required" => ["b"]
             },
             "b" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/a"}}
           },
           "type" => "object",
           "properties" => %{"root" => %{"$ref" => "#/$defs/a"}}
         }
       }, :unsupported_feature}
    ]

    for {extra, reason} <- cases do
      assert {:error, {:refused, ^reason}} = refused(request(extra)), inspect(extra)
    end

    # The provider's own check, for a "$" keyword that jsv would not compile.
    {:ok, base, _} = Elzoo.AiText.Request.decode(Jason.encode!(request()))

    dynamic = %{
      "type" => "object",
      "properties" => %{"answer" => %{"$ref" => "#/$defs/n", "$dynamicRef" => "#a"}},
      "$defs" => %{"n" => %{"type" => "integer"}}
    }

    assert {:refused, :unsupported_feature} =
             Google.translate(%{base | output_schema: dynamic}, nil)

    # The listed keywords, nested, are accepted.
    nested = %{
      "$defs" => %{"n" => %{"type" => "integer", "minimum" => 0}},
      "type" => "object",
      "properties" => %{
        "a" => %{"$ref" => "#/$defs/n"},
        "b" => %{"type" => "array", "items" => %{"enum" => ["x", 1]}, "maxItems" => 3}
      },
      "required" => ["a"],
      "additionalProperties" => false,
      "propertyOrdering" => ["a", "b"]
    }

    assert {:ok, _} = refused(request(%{"output_schema" => nested}))
  end

  defp image_need(images) do
    fn %{artifact_id: id, version: 1} ->
      case Map.fetch(images, id) do
        {:ok, {media_type, bytes}} ->
          {:ok,
           %{
             record: %{
               artifact_id: id,
               version: 1,
               hash_format: 1,
               sha256: Base.encode16(:crypto.hash(:sha256, <<1, bytes::binary>>), case: :lower),
               size_bytes: byte_size(bytes),
               media_type: media_type
             },
             bytes: bytes
           }}

        :error ->
          {:error, :not_found}
      end
    end
  end

  test "G3 images of each media type of the set arrive as inline data in order (captured request)",
       ctx do
    images = %{
      "img-png" => {"image/png", Conformance.image()},
      "img-jpeg" => {"image/jpeg", <<0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3>>},
      "img-webp" => {"image/webp", "RIFF" <> <<0, 0, 0, 0>> <> "WEBPVP8 "},
      "img-gif" => {"image/gif", "GIF89a" <> <<1, 0, 1, 0>>}
    }

    order = ["img-jpeg", "img-png", "img-gif", "img-webp"]

    parts =
      for id <- order do
        {m, _} = images[id]
        %{"type" => "image", "artifact" => %{"id" => id, "version" => 1}, "media_type" => m}
      end

    req =
      request(%{
        "messages" => [
          %{"role" => "user", "parts" => [%{"type" => "text", "text" => "Compare."} | parts]}
        ]
      })

    {{:outcome, _, {:completed, c}}, requests, _, _} =
      run(ctx, req, fn _ -> ok_text() end, artifacts: image_need(images))

    assert c.content == Conformance.text()
    conforms(requests, ctx)
    [body] = Enum.map(requests, &wire/1)
    assert [%{"parts" => [%{"text" => "Compare."} | inline]}] = body["contents"]

    assert Enum.map(inline, fn %{"inline_data" => d} ->
             {d["mime_type"], Base.decode64!(d["data"])}
           end) ==
             Enum.map(order, &images[&1])
  end

  ## G4 finish and usage mapping (decode)

  test "G4 finish mapping: STOP, function calls, MAX_TOKENS, the declining reasons as refusal, other reasons, a blocked prompt; thought parts skipped (decode)",
       ctx do
    cases =
      [
        {[GoogleStub.thought("thinking"), GoogleStub.text("Hi")], "STOP", :stop, "Hi"},
        {[GoogleStub.text("a"), GoogleStub.function_call(%{"q" => "x"})], "STOP", :tool_calls, "a"},
        {[GoogleStub.text("Cut")], "MAX_TOKENS", :length, "Cut"}
      ] ++
        for(
          r <- ~w(SAFETY PROHIBITED_CONTENT BLOCKLIST SPII IMAGE_SAFETY),
          do: {:none, r, :refusal, ""}
        ) ++
        for(
          r <-
            ~w(RECITATION LANGUAGE OTHER MALFORMED_FUNCTION_CALL UNEXPECTED_TOOL_CALL TOO_MANY_TOOL_CALLS),
          do: {[GoogleStub.text("x")], r, {:other, r}, "x"}
        )

    for {parts, reason, finish, content} <- cases do
      response = GoogleStub.ok(GoogleStub.response(parts, reason))

      {{:outcome, _, {:completed, c}}, requests, _, _} =
        run(ctx, request(%{"tools" => [@lookup]}), fn _ -> response end)

      assert length(requests) == 1
      assert {c.finish, c.content} == {finish, content}, reason
    end

    blocked = %{
      "promptFeedback" => %{"blockReason" => "PROHIBITED_CONTENT"},
      "usageMetadata" => %{"promptTokenCount" => 9, "totalTokenCount" => 9},
      "modelVersion" => @model,
      "responseId" => "blocked-1"
    }

    {{:outcome, _, {:completed, c}}, [_], _, _} =
      run(ctx, request(), fn _ -> GoogleStub.ok(blocked) end)

    assert {c.finish, c.content, c.provenance.response_id} == {:refusal, "", "blocked-1"}

    {{:outcome, _, {:completed, c}}, [_], _, _} =
      run(ctx, request(), fn _ ->
        GoogleStub.ok(put_in(blocked, ["promptFeedback", "blockReason"], "OTHER"))
      end)

    assert c.finish == {:other, "OTHER"}
  end

  test "G4 usage: promptTokenCount includes cached; output is candidates plus thoughts; unreported counters unknown (decode)",
       ctx do
    cases = [
      {GoogleStub.usage(2006, 1920, 80, 7),
       %{uncached: 86, read: 1920, output: 87, reasoning: 7, prompt: 2006}},
      {GoogleStub.usage(36, 0, 80, 0),
       %{uncached: 36, read: 0, output: 80, reasoning: 0, prompt: 36}},
      {Map.delete(GoogleStub.usage(36, 0, 80, 7), "thoughtsTokenCount"),
       %{uncached: 36, read: 0, output: :unknown, reasoning: :unknown, prompt: 36}},
      {Map.delete(GoogleStub.usage(36, 0, 80, 7), "cachedContentTokenCount"),
       %{uncached: :unknown, read: :unknown, output: 87, reasoning: 7, prompt: :unknown}},
      # Inconsistent: cached exceeds the prompt; never a clamped zero.
      {GoogleStub.usage(10, 40, 1, 1),
       %{uncached: :unknown, read: 40, output: 2, reasoning: 1, prompt: :unknown}}
    ]

    for {raw, e} <- cases do
      response = GoogleStub.ok(GoogleStub.response([GoogleStub.text("x")], "STOP", usage: raw))
      {{:outcome, _, {:completed, c}}, [_], _, _} = run(ctx, request(), fn _ -> response end)
      u = c.usage
      assert u.source == :provider_reported
      assert u.convention == %{input_includes_cached: true}
      assert u.cache_writes == []
      assert Usage.amount(u, :input_uncached_tokens) == e.uncached, inspect(raw)
      assert Usage.amount(u, :cache_read_tokens) == e.read, inspect(raw)
      assert Usage.amount(u, :output_tokens) == e.output, inspect(raw)
      assert Usage.amount(u, :reasoning_tokens) == e.reasoning, inspect(raw)
      assert Usage.prompt_input_tokens(u) == e.prompt, inspect(raw)
    end
  end

  ## G5 status table, retry_after, transport, malformed bodies: one request each

  test "G5 each status of the table, retry_after forms, a redirect and malformed bodies: one request each (decode)",
       ctx do
    e = &GoogleStub.error/4
    nil_ra = %{retry_after: nil}

    cases = [
      {{400, [], e.(400, "INVALID_ARGUMENT", @prompt, [])}, {:refused, :invalid_request, nil_ra}},
      {{400, [], e.(400, "FAILED_PRECONDITION", "billing", [])},
       {:refused, :invalid_request, nil_ra}},
      {{400, [],
        e.(400, "INVALID_ARGUMENT", "API key not valid. Please pass a valid API key.", [
          GoogleStub.error_info("API_KEY_INVALID")
        ])}, {:refused, :authentication_failed, nil_ra}},
      {{401, [], e.(401, "UNAUTHENTICATED", "x", [])}, {:refused, :authentication_failed, nil_ra}},
      {{403, [], e.(403, "PERMISSION_DENIED", "x", [])}, {:refused, :permission_denied, nil_ra}},
      {{404, [], e.(404, "NOT_FOUND", "x", [])}, {:refused, :not_found, nil_ra}},
      {{413, [], e.(413, "INVALID_ARGUMENT", "x", [])}, {:refused, :too_large, nil_ra}},
      {{429, [{"retry-after", "7"}], e.(429, "RESOURCE_EXHAUSTED", "x", [])},
       {:refused, :throttled, %{retry_after: 7}}},
      {{429, [], e.(429, "RESOURCE_EXHAUSTED", "x", [GoogleStub.retry_info("1.5s")])},
       {:refused, :throttled, %{retry_after: 2}}},
      {{429, [], e.(429, "RESOURCE_EXHAUSTED", "x", [GoogleStub.retry_info("31s")])},
       {:refused, :throttled, %{retry_after: 31}}},
      {{429, [], e.(429, "RESOURCE_EXHAUSTED", "x", [GoogleStub.retry_info("86400.000000001s")])},
       {:refused, :throttled, nil_ra}},
      {{429, [], e.(429, "RESOURCE_EXHAUSTED", "x", [GoogleStub.retry_info("90000s")])},
       {:refused, :throttled, nil_ra}},
      {{429, [], e.(429, "RESOURCE_EXHAUSTED", "x", [GoogleStub.retry_info("1.5")])},
       {:refused, :throttled, nil_ra}},
      {{429, [], e.(429, "RESOURCE_EXHAUSTED", "x", [])}, {:refused, :throttled, nil_ra}},
      # The header wins over the body when there is one.
      {{429, [{"retry-after", "4"}],
        e.(429, "RESOURCE_EXHAUSTED", "x", [GoogleStub.retry_info("9s")])},
       {:refused, :throttled, %{retry_after: 4}}},
      {{429, [{"retry-after", "90000"}], e.(429, "RESOURCE_EXHAUSTED", "x", [])},
       {:refused, :throttled, nil_ra}},
      # A header that is not delta-seconds gives nil, with no fallback to the body.
      {{429, [{"retry-after", "Wed, 21 Oct 2026 07:28:00 GMT"}],
        e.(429, "RESOURCE_EXHAUSTED", "x", [GoogleStub.retry_info("9s")])},
       {:refused, :throttled, nil_ra}},
      {{429, [{"retry-after", "1.5"}],
        e.(429, "RESOURCE_EXHAUSTED", "x", [GoogleStub.retry_info("9s")])},
       {:refused, :throttled, nil_ra}},
      {{503, [], e.(503, "UNAVAILABLE", "x", [GoogleStub.retry_info("3s")])},
       {:refused, :overloaded, %{retry_after: 3}}},
      {{503, [], e.(503, "UNAVAILABLE", "x", [])}, {:refused, :overloaded, nil_ra}},
      {{500, [], e.(500, "INTERNAL", "x", [GoogleStub.retry_info("3s")])},
       {:unknown, :provider_error}},
      {{502, [], "<html>bad gateway</html>"}, {:unknown, :provider_error}},
      {{402, [], e.(402, "RESOURCE_EXHAUSTED", "x", [])}, {:unknown, :provider_error}},
      {{504, [], e.(504, "DEADLINE_EXCEEDED", "x", [])}, {:unknown, :timeout}},
      {{302, [{"location", "/v1beta/elsewhere"}], ""}, {:unknown, :provider_error}},
      # Malformed 2xx bodies.
      {{200, [], "not json"}, {:unknown, :malformed_response}},
      {GoogleStub.ok(%{"candidates" => []}), {:unknown, :malformed_response}},
      {GoogleStub.ok(
         Map.update!(GoogleStub.response([GoogleStub.text("x")], "STOP"), "candidates", &(&1 ++ &1))
       ), {:unknown, :malformed_response}},
      {GoogleStub.ok(
         GoogleStub.response(
           [%{"executableCode" => %{"language" => "PYTHON", "code" => "1"}}],
           "STOP"
         )
       ), {:unknown, :malformed_response}},
      {GoogleStub.ok(Map.delete(GoogleStub.response([GoogleStub.text("x")], "STOP"), "responseId")),
       {:unknown, :malformed_response}}
    ]

    for {response, expected} <- cases do
      {delivery, requests, _, _} = run(ctx, request(), fn _ -> response end)
      assert {:outcome, _, ^expected} = delivery, inspect(response)
      assert length(requests) == 1, inspect(response)
      refute inspect(delivery) =~ @prompt
      conforms(requests, ctx)
    end
  end

  test "G5 transport timeout and a closed connection each give their outcome with exactly one request (call)",
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

  test "G5 a body over the 4 MiB bound is unknown{malformed_response} with one request, for 200 and 429 (call)",
       ctx do
    big = String.duplicate("a", 4_194_305)

    for status <- [200, 429] do
      {delivery, requests, _, _} =
        run(ctx, request(), fn _ -> {status, [{"retry-after", "3"}], big} end)

      assert {:outcome, _, {:unknown, :malformed_response}} = delivery
      assert length(requests) == 1
    end
  end

  test "G5 a body req_llm did not encode with one part per neutral call and tool result is not sent (call)" do
    {agent, plug} = GoogleStub.start(fn _ -> flunk("no request expected") end)

    req =
      request(%{
        "tools" => [@lookup],
        "messages" => [
          %{"role" => "user", "text" => "Q"},
          %{
            "role" => "assistant",
            "text" => "",
            "tool_calls" => [%{"id" => "c1", "name" => "lookup", "arguments" => %{"q" => "x"}}]
          },
          %{"role" => "tool_result", "tool_use_id" => "c1", "text" => "R"}
        ]
      })

    {:ok, normalized, _} = Elzoo.AiText.Request.decode(Jason.encode!(req))
    {:ok, wire} = Google.translate(normalized, %{plug: plug})
    call_opts = %{credential: @key, receive_timeout_ms: 1000}

    for edits <- [
          %{wire.edits | call_ids: []},
          %{wire.edits | call_ids: ["c1", "c2"]},
          %{wire.edits | result_ids: []},
          %{wire.edits | result_ids: ["c1", "c1"]}
        ] do
      assert Google.call(%{wire | edits: edits}, call_opts) == {:transport, :not_sent}
    end

    assert GoogleStub.requests(agent) == []
  end

  ## G6 model table, key handling

  test "G6 a model outside the table is invalid_request before any request, even when allowlisted (translate)" do
    for model <- ["gemini-3.6-flash", "gemini-4-hydrogen"] do
      assert {:error, {:refused, :invalid_request}} =
               refused(Map.put(request(), "model", model), models: [@model, model])
    end

    assert {:refused, :invalid_request} = Google.translate(%{model: "gemini-3.6-flash"}, nil)

    for bad <- [%{base_url: "http://insecure.example"}, %{other: 1}, :config] do
      assert {:error, {:refused, :invalid_request}} = refused_config(bad)
    end
  end

  defp refused_config(provider_config) do
    {:ok, c} =
      AiText.configure(
        binding: Elzoo.AiText.GoogleTest.Binding,
        tenant: "tenant-a",
        provider: Google,
        provider_config: provider_config,
        credentials: fn -> flunk("no credential read expected") end,
        models: [@model],
        sink: Sink.to_pid(self())
      )

    AiText.admission(c, Conformance.declaration(request(), "r", 10_000))
  end

  test "G6 key, prompt and output never in results, inspect, owner state or debug logs (redaction)",
       ctx do
    secret_prompt = "PROMPT-SECRET-#{System.unique_integer([:positive])}"
    secret_output = "OUTPUT-SECRET-#{System.unique_integer([:positive])}"
    req = Map.put(request(), "messages", [%{"role" => "user", "text" => secret_prompt}])

    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    log =
      capture_log([level: :debug], fn ->
        for response <- [
              ok_text(secret_output),
              {400, [], GoogleStub.error(400, "INVALID_ARGUMENT", secret_prompt)},
              {429, [], GoogleStub.error(429, "RESOURCE_EXHAUSTED", @key)},
              {:transport_error, :timeout}
            ] do
          {delivery, _, status, pid} = run(ctx, req, fn _ -> response end)
          state = inspect(:sys.get_state(pid), limit: :infinity, printable_limit: :infinity)
          refute state =~ @key
          refute state =~ secret_output
          refute inspect(status) =~ secret_prompt
          text = inspect(delivery, limit: :infinity, printable_limit: :infinity)
          refute text =~ @key
          refute text =~ secret_prompt
        end
      end)

    refute log =~ @key
    refute log =~ secret_prompt
    refute log =~ secret_output

    {:ok, wire} =
      Google.translate(
        elem(Elzoo.AiText.Request.decode(Jason.encode!(req)), 1),
        nil
      )

    refute inspect(wire, limit: :infinity, printable_limit: :infinity) =~ @key
  end

  test "G6 ambient keys never used; a failing Need sends nothing (credential Need)", ctx do
    System.put_env("GOOGLE_API_KEY", "AIza-ambient-env")
    System.put_env("GEMINI_API_KEY", "AIza-ambient-env2")
    Application.put_env(:req_llm, :google_api_key, "AIza-ambient-app")

    on_exit(fn ->
      System.delete_env("GOOGLE_API_KEY")
      System.delete_env("GEMINI_API_KEY")
      Application.delete_env(:req_llm, :google_api_key)
    end)

    {delivery, requests, _, _} =
      run(ctx, request(), fn _ -> ok_text() end, credentials: fn -> {:error, :vault} end)

    assert {:outcome, _, {:refused, :credentials_unavailable, _}} = delivery
    assert requests == []

    {_, [req], _, _} = run(ctx, request(), fn _ -> ok_text() end)
    assert header(req, "x-goog-api-key") == [@key]
    conforms([req], ctx)
  end

  ## G7 fixture provenance and negative controls; source audit; README

  test "G7 request schema names its source and rejects documented-shape deviations (fixture)",
       ctx do
    assert ctx.bundle["$comment"] =~ @source_sha
    assert ctx.bundle["$comment"] =~ "2026-11-24"
    assert ctx.bundle["$comment"] =~ "generate-content.openapi.json"

    good = %{
      "contents" => [%{"role" => "user", "parts" => [%{"text" => "Q"}]}],
      "tools" => [
        %{
          "functionDeclarations" => [
            %{
              "name" => "lookup",
              "description" => "d",
              "parametersJsonSchema" => %{"type" => "object"}
            }
          ]
        }
      ],
      "generationConfig" => %{"maxOutputTokens" => 5}
    }

    assert Schema.validate(good, ctx.root) == :ok

    bad = [
      put_in(
        good,
        ["tools", Access.at(0), "functionDeclarations", Access.at(0), "parameters"],
        %{}
      ),
      Map.put(good, "key", @key),
      Map.put(good, "contents", []),
      put_in(good, ["contents", Access.at(0), "role"], "assistant"),
      put_in(good, ["contents", Access.at(0), "parts"], [%{"text" => "a", "inline_data" => %{}}]),
      put_in(good, ["generationConfig", "responseJsonSchema"], %{"type" => "object"}),
      put_in(good, ["generationConfig", "temperature"], 0.5),
      Map.put(good, "toolConfig", %{
        "functionCallingConfig" => %{"mode" => "AUTO", "allowedFunctionNames" => ["lookup"]}
      })
    ]

    for b <- bad, do: refute(Schema.validate(b, ctx.root) == :ok, inspect(b))
  end

  # This Piece's manifest: two levels above this file in the repository; under
  # .elzoo/pieces/integration/ai-text-google/ in an exported consumer. Exactly one
  # manifest must exist; the listed files resolve against the same root.
  defp manifest do
    root = Path.expand("../..", __DIR__)

    found =
      [
        Path.join(root, "piece.json"),
        Path.join(root, ".elzoo/pieces/integration/ai-text-google/piece.json")
      ]
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(&(Jason.decode!(File.read!(&1))["id"] == "integration/ai-text-google"))

    assert [one] = found
    {one, root}
  end

  test "G7 source audit of this Piece's own manifest-listed files (own files)" do
    {manifest, root} = manifest()

    files =
      for f <- Jason.decode!(File.read!(manifest))["files"], String.starts_with?(f, "lib/"), do: f

    assert "lib/elzoo/ai_text/google.ex" in files

    forbidden = [
      "Tool.execute",
      "execute_and_append_tools",
      "System.get_env",
      "Application.get_env(:req_llm",
      "Dotenvy",
      "google_auth_header",
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

  @readmes [
    Path.expand("../../../../../pieces/integration/ai-text-google/README.md", __DIR__),
    Path.expand("../../.elzoo/pieces/integration/ai-text-google/README.md", __DIR__)
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
