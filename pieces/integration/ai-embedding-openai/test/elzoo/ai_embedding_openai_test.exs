# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/ai_embedding_openai_test_helper.exs", __DIR__)

defmodule Elzoo.AiEmbedding.OpenAITest.Binding do
  use Elzoo.AiEmbedding.Binding,
    id: "openai-embedding-test",
    provider_account: "openai:test-project",
    recovery_grace_ms: 1000
end

defmodule Elzoo.AiEmbedding.OpenAITest do
  # Every exchange goes to an in-process function plug through Req's :plug option
  # (no network, stub keys only). Each scenario names its boundary.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Elzoo.AiModel.Usage
  alias Elzoo.AiEmbedding
  alias Elzoo.AiEmbedding.{Conformance, OpenAI, OpenAIStub, Sink}
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Memory

  @model "text-embedding-3-small"
  @key "sk-proj-test-INJECTED-e5"
  @input "Conformance input."
  @schema_file Path.expand("../fixtures/openai/embeddings.schema.json", __DIR__)

  setup_all do
    doc = Jason.decode!(File.read!(@schema_file))

    build = fn name ->
      {:ok, root} =
        JSV.build(Map.put(doc, "$ref", "#/$defs/" <> name),
          resolver: [],
          formats: false,
          atoms: false
        )

      root
    end

    %{
      schemas: %{
        request: build.("CreateEmbeddingRequest"),
        response: build.("CreateEmbeddingResponse"),
        error: build.("ErrorResponse")
      }
    }
  end

  setup do
    %{intents: start_supervised!({Task.Supervisor, name: nil}, id: :intent)}
  end

  ## helpers

  defp config(plug, opts \\ []) do
    {:ok, c} =
      AiEmbedding.configure(
        binding: Elzoo.AiEmbedding.OpenAITest.Binding,
        tenant: "tenant-a",
        provider: OpenAI,
        provider_config: %{plug: plug},
        credentials: Keyword.get(opts, :credentials, fn -> {:ok, @key} end),
        models: [@model, "text-embedding-3-large"],
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
    {:ok, a} = AiEmbedding.admission(c, Conformance.declaration(request, ref, 10_000))
    pid = owner(c, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    status = settled(pid)
    key = a.key
    assert_receive {AiEmbedding, ^key, delivery}, 5000
    {delivery, OpenAIStub.requests(agent), status, pid}
  end

  defp request(extra \\ %{}),
    do: Map.merge(%{"version" => 1, "model" => @model, "inputs" => [@input]}, extra)

  defp wire(%{body: body}), do: Jason.decode!(body)
  defp header(req, name), do: for({^name, v} <- req.headers, do: v)

  # Every captured request: method, path, the injected bearer key, float encoding,
  # input as an array, and the pinned CreateEmbeddingRequest schema.
  defp conforms(requests, schemas) do
    for req <- requests do
      assert req.method == "POST"
      assert req.path == "/v1/embeddings"
      assert header(req, "authorization") == ["Bearer " <> @key]
      body = wire(req)
      assert body["encoding_format"] == "float"
      assert is_list(body["input"])
      assert {:ok, _} = JSV.validate(body, schemas.request, cast: false), inspect(Map.keys(body))
    end
  end

  defp valid_response?(body, schemas),
    do: match?({:ok, _}, JSV.validate(body, schemas.response, cast: false))

  defp unit(i, dims), do: for(k <- 0..(dims - 1), do: if(k == rem(i, dims), do: 1.0, else: 0.0))

  ## E1 conformance kit

  defp stub_for({:items, items}, model), do: OpenAIStub.ok(OpenAIStub.list(items, model))

  defp stub_for({:items_no_usage, items}, model),
    do: OpenAIStub.ok(OpenAIStub.list(items, model, :none))

  defp stub_for({:items_other_model, items}, _model),
    do: OpenAIStub.ok(OpenAIStub.list(items, "text-embedding-3-large"))

  defp stub_for(:malformed_success, _), do: OpenAIStub.ok(%{"object" => "list", "model" => @model})
  defp stub_for(:timeout, _), do: {:transport_error, :timeout}

  defp stub_for(:throttled, _),
    do:
      {429, [{"x-request-id", "req_429"}, {"retry-after", "7"}],
       OpenAIStub.error("rate_limit_error", "rate_limit_exceeded")}

  defp stub_for(:overloaded, _),
    do: {503, [], OpenAIStub.error("service_unavailable_error", "server_is_overloaded")}

  defp stub_for(:server_error, _), do: {500, [], OpenAIStub.error("server_error", nil)}

  test "E1 every conformance-kit scenario passes for the OpenAI provider; requests and documented-format stubs validate (kit + stub + schema)",
       ctx do
    dims = 8

    for s <- Conformance.scenarios() do
      response = stub_for(Conformance.stub(s.id, dims), @model)

      # The stubs themselves conform to the documented format, except the scenarios
      # whose point is a schema violation (a null element, a 2xx without data, a
      # response without the required usage object).
      with {200, _, body} <- response do
        assert valid_response?(body, ctx.schemas) ==
                 s.id not in [:non_number, :malformed_success, :usage_omitted],
               inspect(s.id)
      end

      {delivery, requests, _status, _pid} =
        run(ctx, Conformance.request(s.id, @model, dims), fn _ -> response end)

      assert :ok == Conformance.check(s.id, delivery, length(requests), dims),
             inspect({s.id, delivery})

      conforms(requests, ctx.schemas)
      assert wire(hd(requests))["dimensions"] == dims
    end

    # The native dimension when none is requested: 1536 for text-embedding-3-small.
    items = Conformance.items(:multiple_inputs, 1536)

    {delivery, [req], _, _} =
      run(ctx, Conformance.request(:multiple_inputs, @model, nil), fn _ ->
        OpenAIStub.ok(OpenAIStub.list(items, @model))
      end)

    assert :ok == Conformance.check(:multiple_inputs, delivery, 1, 1536)
    refute Map.has_key?(wire(req), "dimensions")
    conforms([req], ctx.schemas)
  end

  ## E2 usage

  test "E2 usage: prompt tokens as the input counter; cache and output unknown, never zero; omitted, disagreeing and malformed totals unknown (raw usage)",
       ctx do
    u = OpenAI.Usage.from_raw(%{"prompt_tokens" => 8, "total_tokens" => 8})
    assert u.source == :provider_reported
    assert u.convention == %{input_includes_cached: false}
    assert Usage.amount(u, :input_uncached_tokens) == 8
    assert Usage.amount(u, :cache_read_tokens) == :unknown
    assert Usage.amount(u, :output_tokens) == :unknown
    assert u.cache_writes == [%{ttl: "provider_default", amount: :unknown}]
    assert Usage.prompt_input_tokens(u) == :unknown
    assert {:ok, ^u} = Usage.validate(u)

    for raw <- [
          %{"prompt_tokens" => 8, "total_tokens" => 9},
          %{"prompt_tokens" => -1, "total_tokens" => -1},
          %{"prompt_tokens" => "8", "total_tokens" => 8},
          %{"total_tokens" => 8}
        ] do
      u = OpenAI.Usage.from_raw(raw)
      assert u.source == :provider_reported, inspect(raw)
      assert Usage.amount(u, :input_uncached_tokens) == :unknown, inspect(raw)
      assert u.cache_writes == [%{ttl: "provider_default", amount: :unknown}]
    end

    assert Usage.amount(OpenAI.Usage.from_raw(%{"prompt_tokens" => 5}), :input_uncached_tokens) == 5

    for absent <- [nil, "x", []] do
      u = OpenAI.Usage.from_raw(absent)
      assert u.source == :unknown
      assert Usage.amount(u, :input_uncached_tokens) == :unknown
    end

    # Through a call.
    items = Conformance.items(:single_input, 8)

    {delivery, _, _, _} =
      run(ctx, request(%{"dimensions" => 8}), fn _ ->
        OpenAIStub.ok(OpenAIStub.list(items, @model, %{"prompt_tokens" => 3, "total_tokens" => 3}))
      end)

    assert {:outcome, _, {:completed, body}} = delivery
    assert Usage.amount(body.usage, :input_uncached_tokens) == 3
    assert body.usage.cache_writes == [%{ttl: "provider_default", amount: :unknown}]
    assert body.provenance.request_id == "req_stub_1"
    assert body.provenance.response_id == :absent
    assert body.provenance.provider_piece == "integration/ai-embedding-openai"
    assert body.descriptor.provider == "openai"
  end

  ## E3 translation

  test "E3 dimensions only when requested, user option on the wire, input type and invalid options refused before any request; the model table equals llm_db (translate + capture)",
       ctx do
    ok = fn body ->
      n = length(body["input"])
      dims = body["dimensions"] || 1536

      OpenAIStub.ok(
        OpenAIStub.list(for(i <- 0..(n - 1), do: %{index: i, vector: unit(i, dims)}), body["model"])
      )
    end

    {_, [req], _, _} = run(ctx, request(%{"provider_options" => %{"user" => "user-1234"}}), ok)
    assert wire(req)["user"] == "user-1234"
    assert wire(req)["input"] == [@input]
    conforms([req], ctx.schemas)

    {_, [req], _, _} =
      run(ctx, request(%{"model" => "text-embedding-3-large", "dimensions" => 256}), ok)

    assert wire(req)["model"] == "text-embedding-3-large"
    assert wire(req)["dimensions"] == 256

    {agent, plug} = OpenAIStub.start(ok)
    c = config(plug)

    for {extra, reason} <- [
          {%{"input_type" => "query"}, :unsupported_feature},
          {%{"input_type" => "document"}, :unsupported_feature},
          {%{"provider_options" => %{"user" => ""}}, :invalid_request},
          {%{"provider_options" => %{"user" => "a\nb"}}, :invalid_request},
          {%{"provider_options" => %{"encoding_format" => "base64"}}, :invalid_request},
          {%{"dimensions" => 1537}, :invalid_request},
          {%{"model" => "text-embedding-ada-002"}, :invalid_request}
        ] do
      assert {:error, {:refused, ^reason}} =
               AiEmbedding.admission(c, Conformance.declaration(request(extra), "r", 10_000)),
             inspect(extra)
    end

    assert OpenAIStub.requests(agent) == []

    # An allowlist naming an undeclared model is refused at construction.
    assert {:error, :configuration} =
             AiEmbedding.configure(
               binding: Elzoo.AiEmbedding.OpenAITest.Binding,
               tenant: "t",
               provider: OpenAI,
               credentials: fn -> {:ok, @key} end,
               models: ["text-embedding-ada-002"],
               sink: fn _, _ -> :ok end
             )

    for {id, %{native: n, min: lo, max: hi}} <- OpenAI.models() do
      {:ok, m} = ReqLLM.model("openai:" <> id)

      assert m.capabilities.embeddings == %{
               default_dimensions: n,
               min_dimensions: lo,
               max_dimensions: hi
             },
             id
    end
  end

  ## E4 documented error statuses

  test "E4 documented error statuses and a redirect: one request each, mapped per table, x-request-id and retry-after kept, no body or input in the outcome (halting step)",
       ctx do
    cases = [
      {{400, [], OpenAIStub.error("invalid_request_error", nil)},
       {:refused, :invalid_request, %{retry_after: nil}}},
      {{401, [], OpenAIStub.error("invalid_request_error", "invalid_api_key")},
       {:refused, :authentication_failed, %{retry_after: nil}}},
      {{403, [], OpenAIStub.error("invalid_request_error", "unsupported_country_region_territory")},
       {:refused, :permission_denied, %{retry_after: nil}}},
      {{404, [], OpenAIStub.error("invalid_request_error", "model_not_found")},
       {:refused, :not_found, %{retry_after: nil}}},
      {{413, [], OpenAIStub.error("invalid_request_error", nil)},
       {:refused, :too_large, %{retry_after: nil}}},
      {{429, [{"retry-after", "7"}], OpenAIStub.error("rate_limit_error", "slow_down")},
       {:refused, :throttled, %{retry_after: 7}}},
      {{429, [], OpenAIStub.error("insufficient_quota", "insufficient_quota")},
       {:refused, :throttled, %{retry_after: nil}}},
      {{503, [{"retry-after", "3"}],
        OpenAIStub.error("service_unavailable_error", "server_is_overloaded")},
       {:refused, :overloaded, %{retry_after: 3}}},
      {{500, [], OpenAIStub.error("server_error", nil)}, {:unknown, :provider_error}},
      {{502, [], "<html>bad gateway</html>"}, {:unknown, :provider_error}},
      {{302, [{"location", "/v1/elsewhere"}], ""}, {:unknown, :provider_error}}
    ]

    for {response, expected} <- cases do
      with {_, _, %{} = body} <- response,
           do: assert({:ok, _} = JSV.validate(body, ctx.schemas.error, cast: false))

      {delivery, requests, _, _} = run(ctx, request(), fn _ -> response end)
      assert {:outcome, _, ^expected} = delivery, inspect(response)
      assert length(requests) == 1, inspect(response)
      refute inspect(delivery) =~ @input
      refute inspect(delivery) =~ "stub error"
      conforms(requests, ctx.schemas)
    end

    # The halting step itself keeps the bounded request id and retry-after.
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

  ## E5 one request

  test "E5 a transport timeout after send is unknown with exactly one request; max_retries 0 alone keeps one request without the halting steps (call)",
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

    # The retry setting on its own: the same request options without the Elzoo steps.
    for {reply, label} <- [
          {{:transport_error, :timeout}, :timeout},
          {{500, [], OpenAIStub.error("server_error", nil)}, :status_500},
          {{429, [], OpenAIStub.error("rate_limit_error", nil)}, :status_429}
        ] do
      {agent, plug} = OpenAIStub.start(fn _ -> reply end)
      {:ok, model} = ReqLLM.model("openai:" <> @model)

      {:ok, req} =
        ReqLLM.Providers.OpenAI.prepare_request(:embedding, model, [@input],
          api_key: @key,
          encoding_format: "float",
          req_http_options: [max_retries: 0, receive_timeout: 2000, plug: plug]
        )

      _ = Req.request(req)
      assert length(OpenAIStub.requests(agent)) == 1, inspect(label)
    end

    # That this Piece passes the setting is checked by the E9 source audit.
  end

  ## E6 malformed success

  test "E6 a malformed 2xx is unknown{malformed_response}, never an empty or partial success (decode)",
       ctx do
    good = OpenAIStub.list([%{index: 0, vector: unit(0, 8)}], @model)

    bodies = [
      %{},
      Map.delete(good, "data"),
      %{good | "object" => "embedding"},
      %{good | "data" => "not a list"},
      %{good | "data" => [%{"object" => "embedding", "embedding" => unit(0, 8)}]},
      %{good | "data" => [%{"index" => 0, "embedding" => unit(0, 8)}]},
      %{good | "data" => [%{"object" => "embedding", "index" => 0, "embedding" => "AAAAAA=="}]},
      Map.delete(good, "model"),
      %{good | "model" => ""}
    ]

    for body <- bodies do
      {delivery, requests, _, _} =
        run(ctx, request(%{"dimensions" => 8}), fn _ -> OpenAIStub.ok(body) end)

      assert {:outcome, _, {:unknown, :malformed_response}} = delivery, inspect(body)
      assert length(requests) == 1
    end

    {delivery, _, _, _} = run(ctx, request(%{"dimensions" => 8}), fn _ -> {200, [], "not json"} end)
    assert {:outcome, _, {:unknown, :malformed_response}} = delivery
  end

  ## E7 redaction

  defp collect_telemetry(acc) do
    receive do
      {:telemetry, _, _, _} = t -> collect_telemetry([t | acc])
    after
      100 -> acc
    end
  end

  test "E7 key and input text never in results, errors, inspect, status, logs at debug or req_llm telemetry (all returns, Logger, :telemetry)",
       ctx do
    parent = self()
    secret_input = "INPUT-SECRET-#{System.unique_integer([:positive])}"

    events = [
      [:req_llm, :request, :start],
      [:req_llm, :request, :stop],
      [:req_llm, :request, :exception],
      [:req_llm, :token_usage]
    ]

    :telemetry.attach_many(
      "elz080-e7",
      events,
      fn e, m, md, _ -> send(parent, {:telemetry, e, m, md}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("elz080-e7") end)
    req = request(%{"inputs" => [secret_input], "dimensions" => 8})
    Logger.configure(level: :debug)

    log =
      capture_log([level: :debug], fn ->
        for response <- [
              OpenAIStub.ok(OpenAIStub.list([%{index: 0, vector: unit(0, 8)}], @model)),
              {400, [], OpenAIStub.error("invalid_request_error", nil, secret_input)},
              {:transport_error, :timeout}
            ] do
          {delivery, _, status, pid} = run(ctx, req, fn _ -> response end)
          state = inspect(:sys.get_state(pid), limit: :infinity, printable_limit: :infinity)
          refute state =~ @key
          refute inspect(status) =~ secret_input
          refute inspect(delivery, limit: :infinity, printable_limit: :infinity) =~ @key
          refute inspect(delivery, limit: :infinity, printable_limit: :infinity) =~ secret_input
        end
      end)

    Logger.configure(level: :warning)
    refute log =~ @key
    refute log =~ secret_input

    text = inspect(collect_telemetry([]), limit: :infinity, printable_limit: :infinity)
    refute text =~ @key
    refute text =~ secret_input
  end

  ## E8 ambient keys

  test "E8 ambient keys never used: a failing Need makes no request with env, app config and a .env file present; a working Need wins over them (credential Need)",
       ctx do
    System.put_env("OPENAI_API_KEY", "sk-ambient-env")
    Application.put_env(:req_llm, :openai_api_key, "sk-ambient-app")

    on_exit(fn ->
      System.delete_env("OPENAI_API_KEY")
      Application.delete_env(:req_llm, :openai_api_key)
    end)

    # The repository configuration sets load_dotenv: false and the README requires
    # every consumer to set it; an exported consumer without that line gets it here
    # so the restart below exercises the setting itself.
    dotenv_setting = Application.get_env(:req_llm, :load_dotenv)
    Application.put_env(:req_llm, :load_dotenv, false)
    on_exit(fn -> Application.put_env(:req_llm, :load_dotenv, dotenv_setting) end)
    ok = OpenAIStub.ok(OpenAIStub.list([%{index: 0, vector: unit(0, 8)}], @model))

    {delivery, requests, _, _} =
      run(ctx, request(%{"dimensions" => 8}), fn _ -> ok end,
        credentials: fn -> {:error, :vault} end
      )

    assert {:outcome, _, {:refused, :credentials_unavailable, _}} = delivery
    assert requests == []

    {_, [req], _, _} = run(ctx, request(%{"dimensions" => 8}), fn _ -> ok end)
    assert header(req, "authorization") == ["Bearer " <> @key]

    dir = Path.join(System.tmp_dir!(), "elz080-dotenv-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".env"), "ELZ080_DOTENV_SENTINEL=loaded\nOPENAI_API_KEY=sk-dotenv\n")
    previous = File.cwd!()

    try do
      File.cd!(dir)
      :ok = Application.stop(:req_llm)
      {:ok, _} = Application.ensure_all_started(:req_llm)
    after
      File.cd!(previous)
      File.rm_rf!(dir)
    end

    assert System.get_env("ELZ080_DOTENV_SENTINEL") == nil
    assert System.get_env("OPENAI_API_KEY") == "sk-ambient-env"
  end

  ## E9 source audit of this Piece's own files

  test "E9 source audit: no ambient key reads, facade calls or unhalted Req pipelines in this Piece's own sources (own files)" do
    # This Piece's own lib files as its manifest lists them: two levels above this
    # file in the repository, .elzoo/pieces/integration/ai-embedding-openai/ in an
    # exported consumer; exactly one must exist.
    root = Path.expand("../..", __DIR__)

    manifests =
      [
        Path.join(root, "piece.json"),
        Path.join(root, ".elzoo/pieces/integration/ai-embedding-openai/piece.json")
      ]
      |> Enum.filter(&File.regular?/1)

    assert [manifest] = manifests

    files =
      for f <- Jason.decode!(File.read!(manifest))["files"], String.starts_with?(f, "lib/"), do: f

    assert "lib/elzoo/ai_embedding/openai.ex" in files

    forbidden = [
      "System.get_env",
      "Application.get_env(:req_llm",
      "Dotenvy",
      "ReqLLM.embed(",
      "ReqLLM.Embedding.",
      "generate_text"
    ]

    for f <- files do
      source = File.read!(Path.join(root, f))
      for word <- forbidden, do: refute(source =~ word, "#{f} contains #{word}")
      if source =~ "Req.request(", do: assert(source =~ "prepend_response_steps(elzoo_capture:")
      if source =~ "prepare_request(", do: assert(source =~ "max_retries: 0")
    end
  end

  ## E10 install configuration (consumer Need)

  # This Piece's README: in this repository it is three levels above test/elzoo/
  # under pieces/; in an exported consumer the copier puts it under
  # .elzoo/pieces/integration/ai-embedding-openai/ while this file lands in test/elzoo/.
  # Exactly one must exist, so a missing README is never skipped.
  @readmes [
    Path.expand("../../../../../pieces/integration/ai-embedding-openai/README.md", __DIR__),
    Path.expand("../../.elzoo/pieces/integration/ai-embedding-openai/README.md", __DIR__)
  ]

  test "E10 the README's Install configuration section carries the exact consumer config line (README, either layout)" do
    assert [readme] = Enum.filter(@readmes, &File.regular?/1)
    text = File.read!(readme)
    [_, section] = String.split(text, "## Install configuration", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)
    assert section =~ "\nconfig :req_llm, load_dotenv: false\n"
    assert section =~ "merges no configuration"
    assert section =~ "does not prove a consumer's configuration"
  end
end
