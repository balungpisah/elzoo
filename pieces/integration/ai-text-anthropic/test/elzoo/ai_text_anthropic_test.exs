# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/ai_text_anthropic_test_helper.exs", __DIR__)

defmodule Elzoo.AiText.AnthropicTest.Binding do
  use Elzoo.AiText.Binding,
    id: "anthropic-test",
    provider_account: "anthropic:test-workspace",
    recovery_grace_ms: 1000
end

defmodule Elzoo.AiText.AnthropicTest do
  # Every exchange goes to an in-process function plug through Req's :plug option
  # (no network, stub keys only). Each scenario names its boundary.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Elzoo.AiModel.Usage
  alias Elzoo.AiText
  alias Elzoo.AiText.{Anthropic, AnthropicStub, Conformance, Schema, Sink}
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Memory

  @model "claude-sonnet-4-5"
  @key "sk-ant-test-INJECTED-k7"
  @prompt "Conformance prompt."
  @schema_file Path.expand("../fixtures/anthropic/messages-request.schema.json", __DIR__)

  setup do
    {:ok, schema} = Schema.build(Jason.decode!(File.read!(@schema_file)))
    %{intents: start_supervised!({Task.Supervisor, name: nil}, id: :intent), schema: schema}
  end

  ## helpers

  defp config(plug, opts \\ []) do
    {:ok, c} =
      AiText.configure(
        [
          binding: Elzoo.AiText.AnthropicTest.Binding,
          tenant: "tenant-a",
          provider: Anthropic,
          provider_config: %{plug: plug},
          credentials: Keyword.get(opts, :credentials, fn -> {:ok, @key} end),
          models: Keyword.get(opts, :models, [@model]),
          max_output_tokens: 4096,
          receive_timeout_ms: 5000,
          sink: Sink.to_pid(self())
        ] ++ Keyword.take(opts, [:artifacts, :image_bounds])
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

  # One call: admission, owner, dispatch; returns {delivery, requests, status}.
  defp run(ctx, request, respond, opts \\ []) do
    {agent, plug} = AnthropicStub.start(respond)
    c = config(plug, opts)
    ref = "ref-#{System.unique_integer([:positive])}"
    {:ok, a} = AiText.admission(c, Conformance.declaration(request, ref, 10_000))
    pid = owner(c, a, ctx)
    {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    status = settled(pid)
    key = a.key
    assert_receive {AiText, ^key, delivery}, 5000
    {delivery, AnthropicStub.requests(agent), status, pid}
  end

  defp request(extra \\ %{}), do: Map.merge(Conformance.request(:text_completion, @model), extra)

  defp wire(%{body: body}), do: Jason.decode!(body)

  defp header(req, name), do: for({^name, v} <- req.headers, do: v)

  # Every captured request: method, path, pinned version, injected key, no
  # sampling, and the hand-derived schema.
  defp conforms(requests, schema) do
    for req <- requests do
      assert req.method == "POST"
      assert req.path == "/v1/messages"
      assert header(req, "anthropic-version") == ["2026-10-21"]
      assert header(req, "x-api-key") == [@key]
      body = wire(req)

      refute Map.has_key?(body, "temperature") or Map.has_key?(body, "top_p") or
               Map.has_key?(body, "top_k")

      assert :ok == Schema.validate(body, schema),
             "request does not validate: #{inspect(Map.keys(body))}"
    end
  end

  ## A1 conformance kit (the interface's scenarios against documented-format stubs)

  defp stub_for(:text),
    do:
      AnthropicStub.ok(AnthropicStub.message([AnthropicStub.text(Conformance.text())], "end_turn"))

  defp stub_for(:length),
    do: AnthropicStub.ok(AnthropicStub.message([AnthropicStub.text("Cut")], "max_tokens"))

  defp stub_for(:refusal),
    do: AnthropicStub.ok(AnthropicStub.message([AnthropicStub.text("")], "refusal"))

  defp stub_for(:other_finish),
    do: AnthropicStub.ok(AnthropicStub.message([AnthropicStub.text("x")], "pause_turn"))

  defp stub_for(:tool_call),
    do: AnthropicStub.ok(AnthropicStub.message([AnthropicStub.tool_use(%{"q" => "x"})], "tool_use"))

  defp stub_for(:tool_invalid_json),
    do: AnthropicStub.ok(AnthropicStub.message([AnthropicStub.tool_use(~s({"q":))], "tool_use"))

  defp stub_for(:tool_schema_mismatch),
    do: AnthropicStub.ok(AnthropicStub.message([AnthropicStub.tool_use(%{"q" => 5})], "tool_use"))

  defp stub_for(:structured),
    do: AnthropicStub.ok(AnthropicStub.message([AnthropicStub.text(~s({"answer":42}))], "end_turn"))

  defp stub_for(:structured_mismatch),
    do:
      AnthropicStub.ok(
        AnthropicStub.message([AnthropicStub.text(~s({"answer":"forty-two"}))], "end_turn")
      )

  defp stub_for(:no_usage),
    do: AnthropicStub.ok(AnthropicStub.message([AnthropicStub.text("x")], "end_turn", :none))

  defp stub_for(:malformed_success), do: AnthropicStub.ok(%{"type" => "message", "content" => []})
  defp stub_for(:timeout), do: {:transport_error, :timeout}

  defp stub_for(:throttled),
    do:
      {429, [{"request-id", "req_429"}, {"retry-after", "7"}],
       AnthropicStub.error("rate_limit_error")}

  defp stub_for(:overloaded),
    do: {529, [{"request-id", "req_529"}], AnthropicStub.error("overloaded_error")}

  defp stub_for(:server_error), do: {500, [], AnthropicStub.error("api_error")}

  test "A1 every conformance-kit scenario passes for the Anthropic provider and every request validates (kit + stub + schema)",
       ctx do
    for s <- Conformance.scenarios() do
      response = stub_for(s.stub)

      {delivery, requests, _status, _pid} =
        run(ctx, Conformance.request(s.id, @model), fn _ -> response end)

      assert :ok == Conformance.check(s.id, delivery, length(requests)), inspect({s.id, delivery})
      conforms(requests, ctx.schema)
    end
  end

  ## Golden wire requests (ELZ-371 acceptance 1): recorded on the base before
  ## the image change, so a text-only request translates byte for byte as before.

  @golden_headers [
    {"accept", "application/json"},
    {"anthropic-version", "2026-10-21"},
    {"content-type", "application/json"},
    {"user-agent", "req/0.7.5"}
  ]

  @golden_body %{
    "max_tokens" => 256,
    "messages" => [%{"content" => "Conformance prompt.", "role" => "user"}],
    "model" => "claude-sonnet-4-5-20250929",
    "stream" => false,
    "system" => "Answer briefly."
  }

  @golden_tools %{
    "tool_choice" => %{"type" => "auto"},
    "tools" => [
      %{
        "description" => "Look up a term.",
        "input_schema" => %{
          "additionalProperties" => false,
          "properties" => %{"q" => %{"type" => "string"}},
          "required" => ["q"],
          "type" => "object"
        },
        "name" => "lookup"
      }
    ]
  }

  @golden_structured %{
    "output_config" => %{
      "format" => %{
        "schema" => %{
          "additionalProperties" => false,
          "properties" => %{"answer" => %{"type" => "integer"}},
          "required" => ["answer"],
          "type" => "object"
        },
        "type" => "json_schema"
      }
    }
  }

  defp golden(id) when id in [:tool_well_formed, :tool_invalid_json, :tool_schema_invalid],
    do:
      {[{"anthropic-beta", "tools-2024-05-16"} | @golden_headers],
       Map.merge(@golden_body, @golden_tools)}

  defp golden(id) when id in [:structured_valid, :structured_invalid],
    do: {@golden_headers, Map.merge(@golden_body, @golden_structured)}

  defp golden(_), do: {@golden_headers, @golden_body}

  test "golden: the wire request of every A1 scenario (method, path, headers other than the key, decoded body) equals the recording on the base (translate + call)",
       ctx do
    assert length(Conformance.scenarios()) == 15

    for s <- Conformance.scenarios() do
      response = stub_for(s.stub)

      {_, [req], _, _} =
        run(ctx, Conformance.request(s.id, @model), fn _ -> response end)

      {headers, body} = golden(s.id)
      assert {req.method, req.path} == {"POST", "/v1/messages"}, inspect(s.id)

      assert Enum.sort(Enum.reject(req.headers, &match?({"x-api-key", _}, &1))) ==
               Enum.sort(headers),
             inspect(s.id)

      assert wire(req) == body, inspect(s.id)
    end
  end

  ## A2 usage and cache counters from the raw usage map

  test "A2 usage: reported, omitted fields, cold write, warm read, mixed TTL, below minimum, total and breakdown (raw usage)",
       ctx do
    cases = [
      # Cold write: write > 0, read 0.
      {%{
         "input_tokens" => 21,
         "cache_creation_input_tokens" => 1800,
         "cache_read_input_tokens" => 0,
         "output_tokens" => 393
       }, %{input: 21, read: 0, writes: [%{ttl: "provider_default", amount: 1800}], prompt: 1821}},
      # Warm read.
      {%{
         "input_tokens" => 21,
         "cache_creation_input_tokens" => 0,
         "cache_read_input_tokens" => 1800,
         "output_tokens" => 393
       }, %{input: 21, read: 1800, writes: [%{ttl: "provider_default", amount: 0}], prompt: 1821}},
      # Mixed TTL ("1-hour cache duration" example).
      {%{
         "input_tokens" => 2048,
         "cache_read_input_tokens" => 1800,
         "cache_creation_input_tokens" => 248,
         "output_tokens" => 503,
         "cache_creation" => %{
           "ephemeral_5m_input_tokens" => 148,
           "ephemeral_1h_input_tokens" => 100
         }
       },
       %{
         input: 2048,
         read: 1800,
         writes: [%{ttl: "5m", amount: 148}, %{ttl: "1h", amount: 100}],
         prompt: 4096
       }},
      # Below the cacheable minimum: both zero, no error.
      {%{
         "input_tokens" => 12,
         "cache_creation_input_tokens" => 0,
         "cache_read_input_tokens" => 0,
         "output_tokens" => 4
       }, %{input: 12, read: 0, writes: [%{ttl: "provider_default", amount: 0}], prompt: 12}},
      # Cache fields absent: unknown, never zero.
      {%{"input_tokens" => 12, "output_tokens" => 4},
       %{
         input: 12,
         read: :unknown,
         writes: [%{ttl: "provider_default", amount: :unknown}],
         prompt: :unknown
       }},
      # Partial breakdown without a total: the missing TTL is unreported, so unknown.
      {%{
         "input_tokens" => 12,
         "cache_read_input_tokens" => 0,
         "output_tokens" => 1,
         "cache_creation" => %{"ephemeral_5m_input_tokens" => 5}
       },
       %{
         input: 12,
         read: 0,
         writes: [%{ttl: "provider_default", amount: :unknown}],
         prompt: :unknown
       }},
      {%{
         "input_tokens" => 12,
         "cache_read_input_tokens" => 0,
         "output_tokens" => 1,
         "cache_creation" => %{"ephemeral_1h_input_tokens" => 5}
       },
       %{
         input: 12,
         read: 0,
         writes: [%{ttl: "provider_default", amount: :unknown}],
         prompt: :unknown
       }},
      # Partial breakdown that matches the total is complete.
      {%{
         "input_tokens" => 12,
         "cache_read_input_tokens" => 0,
         "output_tokens" => 1,
         "cache_creation_input_tokens" => 5,
         "cache_creation" => %{"ephemeral_5m_input_tokens" => 5}
       }, %{input: 12, read: 0, writes: [%{ttl: "5m", amount: 5}], prompt: 17}},
      # Total disagrees with the breakdown: unknown, never counted twice.
      {%{
         "input_tokens" => 1,
         "cache_read_input_tokens" => 0,
         "cache_creation_input_tokens" => 300,
         "output_tokens" => 1,
         "cache_creation" => %{
           "ephemeral_5m_input_tokens" => 148,
           "ephemeral_1h_input_tokens" => 100
         }
       },
       %{
         input: 1,
         read: 0,
         writes: [%{ttl: "provider_default", amount: :unknown}],
         prompt: :unknown
       }}
    ]

    for {raw, e} <- cases do
      response = AnthropicStub.ok(AnthropicStub.message([AnthropicStub.text("x")], "end_turn", raw))
      {{:outcome, _, {:completed, c}}, requests, _, _} = run(ctx, request(), fn _ -> response end)
      assert length(requests) == 1
      u = c.usage
      assert u.source == :provider_reported
      assert u.convention == %{input_includes_cached: false}
      assert Usage.amount(u, :input_uncached_tokens) == e.input, inspect(raw)
      assert Usage.amount(u, :cache_read_tokens) == e.read, inspect(raw)
      assert u.cache_writes == e.writes, inspect(raw)
      assert Usage.prompt_input_tokens(u) == e.prompt, inspect(raw)
    end
  end

  ## A3 cache hint and reasoning translation

  defp hint(breakpoints, ttl \\ "5m"),
    do: %{
      "tenant" => "tenant-a",
      "local_key" => "docs-v1",
      "ttl" => ttl,
      "breakpoints" => breakpoints
    }

  test "A3 cache hint mapped to cache_control markers; inexpressible or overflowing hints refused before any request (translate)",
       ctx do
    ok = AnthropicStub.ok(AnthropicStub.message([AnthropicStub.text("x")], "end_turn"))

    {_, [req], _, _} = run(ctx, request(%{"cache_hint" => hint(["system"])}), fn _ -> ok end)
    conforms([req], ctx.schema)
    assert inspect(wire(req)) =~ "ephemeral"

    {_, [req], _, _} =
      run(ctx, request(%{"cache_hint" => hint(["system", %{"message" => 0}], "1h")}), fn _ -> ok end)

    conforms([req], ctx.schema)
    assert inspect(wire(req)) =~ "1h"

    {agent, plug} = AnthropicStub.start(fn _ -> ok end)
    c = config(plug)

    for {h, reason} <- [
          {hint(["tools"]), :unsupported_feature},
          {hint(["system", %{"message" => 0}, %{"message" => 1}]), :unsupported_feature},
          {hint(["system", "tools", %{"message" => 0}, %{"message" => 1}, %{"message" => 2}]),
           :invalid_request},
          {hint(["system"], "24h"), :unsupported_feature},
          {%{hint(["system"]) | "tenant" => "tenant-b"}, :invalid_request}
        ] do
      assert {:error, {:refused, ^reason}} =
               AiText.admission(
                 c,
                 Conformance.declaration(request(%{"cache_hint" => h}), "h", 10_000)
               ),
             inspect(h)
    end

    assert {:error, {:refused, :unsupported_feature}} =
             AiText.admission(
               c,
               Conformance.declaration(request(%{"reasoning" => "max"}), "r", 10_000)
             )

    assert {:error, {:refused, :unsupported_feature}} =
             AiText.admission(
               c,
               Conformance.declaration(
                 request(%{"sampling" => %{"temperature" => 0.1}}),
                 "s",
                 10_000
               )
             )

    assert AnthropicStub.requests(agent) == []

    {_, [req], _, _} = run(ctx, request(%{"reasoning" => "low"}), fn _ -> ok end)
    conforms([req], ctx.schema)
    body = wire(req)
    assert Map.has_key?(body, "thinking") or Map.has_key?(body, "output_config")
  end

  ## A4 error statuses, redirects; A5 timeout; A6 malformed 2xx

  test "A4 documented error statuses and a redirect: one request each, mapped per table, request-id and retry-after kept, no body in the outcome (halting step)",
       ctx do
    cases = [
      {{400, [], AnthropicStub.error("invalid_request_error", @prompt)},
       {:refused, :invalid_request, %{retry_after: nil}}},
      {{401, [], AnthropicStub.error("authentication_error")},
       {:refused, :authentication_failed, %{retry_after: nil}}},
      {{403, [], AnthropicStub.error("permission_error")},
       {:refused, :permission_denied, %{retry_after: nil}}},
      {{404, [], AnthropicStub.error("not_found_error")},
       {:refused, :not_found, %{retry_after: nil}}},
      {{413, [], AnthropicStub.error("request_too_large")},
       {:refused, :too_large, %{retry_after: nil}}},
      {{429, [{"retry-after", "7"}], AnthropicStub.error("rate_limit_error")},
       {:refused, :throttled, %{retry_after: 7}}},
      {{429, [], AnthropicStub.error("rate_limit_error")},
       {:refused, :throttled, %{retry_after: nil}}},
      {{500, [], AnthropicStub.error("api_error")}, {:unknown, :provider_error}},
      {{500, [], AnthropicStub.error("timeout_error")}, {:unknown, :timeout}},
      {{504, [], AnthropicStub.error("timeout_error")}, {:unknown, :timeout}},
      {{529, [], AnthropicStub.error("overloaded_error")},
       {:refused, :overloaded, %{retry_after: nil}}},
      {{302, [{"location", "/v1/elsewhere"}], ""}, {:unknown, :provider_error}},
      {{402, [], AnthropicStub.error("billing_error")}, {:unknown, :provider_error}}
    ]

    for {response, expected} <- cases do
      {delivery, requests, _, _} = run(ctx, request(), fn _ -> response end)
      assert {:outcome, _, ^expected} = delivery, inspect(response)
      assert length(requests) == 1, inspect(response)
      refute inspect(delivery) =~ @prompt
      refute inspect(delivery) =~ "stub error"
      conforms(requests, ctx.schema)
    end

    # The halting step itself keeps the bounded request-id and retry-after.
    {:ok, response} =
      Req.request(
        Req.new(
          url: "http://stub.invalid/x",
          retry: false,
          plug: fn conn ->
            conn
            |> Plug.Conn.put_resp_header("request-id", "req_kept")
            |> Plug.Conn.put_resp_header("retry-after", "7")
            |> Plug.Conn.send_resp(429, "{}")
          end
        )
        |> Req.Request.prepend_response_steps(elzoo_capture: &Anthropic.capture/1)
      )

    assert %{status: 429, request_id: "req_kept", retry_after: "7"} = response.private.elzoo_raw
  end

  test "A5 a transport timeout after send is unknown with exactly one request; req_llm never retries (call)",
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

  test "A6 a malformed 2xx is unknown{malformed_response}, never an empty success (decode)", ctx do
    bodies = [
      %{},
      Map.delete(AnthropicStub.message([AnthropicStub.text("x")], "end_turn"), "id"),
      Map.put(AnthropicStub.message([AnthropicStub.text("x")], "end_turn"), "stop_reason", nil),
      AnthropicStub.message([%{"type" => "image"}], "end_turn"),
      AnthropicStub.message("not a list", "end_turn")
    ]

    for body <- bodies do
      {delivery, requests, _, _} = run(ctx, request(), fn _ -> AnthropicStub.ok(body) end)
      assert {:outcome, _, {:unknown, :malformed_response}} = delivery, inspect(body)
      assert length(requests) == 1
    end

    {delivery, _, _, _} = run(ctx, request(), fn _ -> {200, [], "not json"} end)
    assert {:outcome, _, {:unknown, :malformed_response}} = delivery
  end

  ## A7 redaction; A8 ambient keys; A11 conflicting sources

  test "A7 key, prompt and output never in results, errors, inspect, status, logs at debug or req_llm telemetry (all returns, Logger, :telemetry)",
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
      "elz079-a7",
      events,
      fn e, m, md, _ -> send(parent, {:telemetry, e, m, md}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("elz079-a7") end)

    req =
      Map.put(request(), "messages", [%{"role" => "user", "text" => secret_prompt}])

    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    log =
      capture_log([level: :debug], fn ->
        for response <- [
              AnthropicStub.ok(
                AnthropicStub.message([AnthropicStub.text(secret_output)], "end_turn")
              ),
              {400, [], AnthropicStub.error("invalid_request_error", secret_prompt)},
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

  test "A8/A11 ambient keys never used: a failing Need makes no request even with env, app config and a .env file; a working Need wins over them (credential Need)",
       ctx do
    System.put_env("ANTHROPIC_API_KEY", "sk-ambient-env")
    Application.put_env(:req_llm, :anthropic_api_key, "sk-ambient-app")

    on_exit(fn ->
      System.delete_env("ANTHROPIC_API_KEY")
      Application.delete_env(:req_llm, :anthropic_api_key)
    end)

    # The repository configuration sets load_dotenv: false and the Piece documentation
    # requires every consumer to set it; an exported consumer without that line
    # gets it here so the restart below exercises the setting itself.
    dotenv_setting = Application.get_env(:req_llm, :load_dotenv)
    Application.put_env(:req_llm, :load_dotenv, false)
    on_exit(fn -> Application.put_env(:req_llm, :load_dotenv, dotenv_setting) end)
    ok = AnthropicStub.ok(AnthropicStub.message([AnthropicStub.text("x")], "end_turn"))

    {delivery, requests, _, _} =
      run(ctx, request(), fn _ -> ok end, credentials: fn -> {:error, :vault} end)

    assert {:outcome, _, {:refused, :credentials_unavailable, _}} = delivery
    assert requests == []

    {_, [req], _, _} = run(ctx, request(), fn _ -> ok end)
    assert header(req, "x-api-key") == [@key]

    # A .env file in the working directory is not loaded when req_llm starts.
    dir = Path.join(System.tmp_dir!(), "elz079-dotenv-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, ".env"),
      "ELZ079_DOTENV_SENTINEL=loaded\nANTHROPIC_API_KEY=sk-dotenv\n"
    )

    previous = File.cwd!()

    try do
      File.cd!(dir)
      :ok = Application.stop(:req_llm)
      {:ok, _} = Application.ensure_all_started(:req_llm)
    after
      File.cd!(previous)
      File.rm_rf!(dir)
    end

    assert System.get_env("ELZ079_DOTENV_SENTINEL") == nil
    assert System.get_env("ANTHROPIC_API_KEY") == "sk-ambient-env"
  end

  ## A10 source audit of this Piece's own files

  test "A10 source audit: no tool execution, ambient key reads or facade calls in this Piece's own sources (own files)" do
    # This Piece's own lib files as its manifest lists them: two levels above this
    # file in the repository, .elzoo/pieces/integration/ai-text-anthropic/ in an
    # exported consumer; exactly one must exist.
    root = Path.expand("../..", __DIR__)

    manifests =
      [
        Path.join(root, "piece.json"),
        Path.join(root, ".elzoo/pieces/integration/ai-text-anthropic/piece.json")
      ]
      |> Enum.filter(&File.regular?/1)

    assert [manifest] = manifests

    files =
      for f <- Jason.decode!(File.read!(manifest))["files"], String.starts_with?(f, "lib/"), do: f

    assert "lib/elzoo/ai_text/anthropic.ex" in files

    forbidden = [
      "Tool.execute",
      "execute_and_append_tools",
      "System.get_env",
      "Application.get_env(:req_llm",
      "Dotenvy",
      "generate_text",
      "stream_text",
      "generate_object"
    ]

    for f <- files do
      source = File.read!(Path.join(root, f))
      for word <- forbidden, do: refute(source =~ word, "#{f} contains #{word}")
      # Every Req pipeline built here goes through the halting steps.
      if source =~ "Req.request(", do: assert(source =~ "prepend_response_steps(elzoo_capture:")
    end
  end

  ## Install configuration (consumer Need)

  # This Piece's README: in this repository it is three levels above test/elzoo/
  # under pieces/; in an exported consumer the copier puts it under
  # .elzoo/pieces/integration/ai-text-anthropic/ while this file lands in test/elzoo/.
  # Exactly one must exist, so a missing README is never skipped.
  @readmes [
    Path.expand("../../../../../pieces/integration/ai-text-anthropic/README.md", __DIR__),
    Path.expand("../../.elzoo/pieces/integration/ai-text-anthropic/README.md", __DIR__)
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

  test "tool results keep their error flag on the wire; a successful one carries none (translate + captured request)",
       ctx do
    ok = AnthropicStub.ok(AnthropicStub.message([AnthropicStub.text("x")], "end_turn"))
    tools = Conformance.request(:tool_well_formed, @model)["tools"]

    for flag <- [true, false] do
      req =
        request(%{
          "tools" => tools,
          "messages" => [
            %{"role" => "user", "text" => "look it up"},
            %{
              "role" => "assistant",
              "text" => "",
              "tool_calls" => [
                %{"id" => "toolu_01A", "name" => "lookup", "arguments" => %{"q" => "x"}}
              ]
            },
            %{
              "role" => "tool_result",
              "tool_use_id" => "toolu_01A",
              "text" => "not found",
              "is_error" => flag
            }
          ]
        })

      {_, [captured], _, _} = run(ctx, req, fn _ -> ok end)
      conforms([captured], ctx.schema)

      [block] =
        for m <- wire(captured)["messages"],
            is_list(m["content"]),
            b <- m["content"],
            b["type"] == "tool_result",
            do: b

      assert block["tool_use_id"] == "toolu_01A"
      if flag, do: assert(block["is_error"] == true), else: refute(Map.has_key?(block, "is_error"))
    end
  end

  ## Image input (ELZ-371): image parts as Messages API image blocks

  @no_image_model "claude-3-5-haiku-20241022"

  # The artifact read Need double: `images` maps an artifact id to {bytes, media
  # type}, answered as Elzoo.Artifact.get/4 does (hash format 1).
  defp need(images) do
    fn %{artifact_id: id, version: v} ->
      case Map.fetch(images, id) do
        {:ok, {bytes, media}} ->
          record = %{
            artifact_id: id,
            version: v,
            hash_format: 1,
            sha256: Base.encode16(:crypto.hash(:sha256, <<1, bytes::binary>>), case: :lower),
            size_bytes: byte_size(bytes),
            media_type: media
          }

          {:ok, %{record: record, bytes: bytes}}

        :error ->
          {:error, :not_found}
      end
    end
  end

  defp image_part(id, media),
    do: %{"type" => "image", "artifact" => %{"id" => id, "version" => 1}, "media_type" => media}

  defp parts_request(parts, extra \\ %{}),
    do:
      request(
        Map.merge(
          %{
            "messages" => [
              %{"role" => "system", "text" => "Answer briefly."},
              %{"role" => "user", "parts" => parts}
            ]
          },
          extra
        )
      )

  # The content blocks of the captured request's user messages, in order.
  defp user_blocks(req),
    do: for(%{"role" => "user", "content" => c} <- wire(req)["messages"], is_list(c), b <- c, do: b)

  defp image_data(%{"type" => "image", "source" => %{"type" => "base64", "data" => d}}),
    do: Base.decode64!(d)

  # A request already resolved by ai-text: each image part carries `bytes`.
  defp resolved(json, bytes) do
    {:ok, r, _} = AiText.Request.decode(AiText.Request.canonical(json))

    messages =
      Enum.map(r.messages, fn
        %{parts: parts} = m ->
          %{
            m
            | parts:
                Enum.map(parts, fn
                  %{type: :image, media_type: mt} -> %{type: :image, media_type: mt, bytes: bytes}
                  p -> p
                end)
          }

        m ->
          m
      end)

    %{r | messages: messages}
  end

  defp ok_text,
    do:
      AnthropicStub.ok(AnthropicStub.message([AnthropicStub.text(Conformance.text())], "end_turn"))

  test "image: the :image_input scenario passes with an artifact Need double; one user message with a text block and an image block of the PNG; the request validates (image_scenarios + stub + schema)",
       ctx do
    assert :image_input in Anthropic.capabilities().features
    assert [%{id: :image_input} = s] = Conformance.image_scenarios()
    response = stub_for(s.stub)

    {delivery, requests, _, _} =
      run(ctx, Conformance.request(:image_input, @model), fn _ -> response end,
        artifacts: Conformance.image_need()
      )

    assert :ok == Conformance.check(:image_input, delivery, length(requests))
    conforms(requests, ctx.schema)
    [req] = requests
    body = wire(req)
    assert body["system"] == "Answer briefly."

    assert [%{"role" => "user", "content" => [text, image]}] = body["messages"]
    assert text == %{"type" => "text", "text" => "Describe the image."}

    assert %{"type" => "image", "source" => %{"type" => "base64", "media_type" => "image/png"}} =
             image

    assert map_size(image) == 2 and map_size(image["source"]) == 3
    assert image_data(image) == Conformance.image()
  end

  test "image: each media type of the set gives a block with that media type; eight images give eight blocks in order, text parts kept between them (translate + captured request)",
       ctx do
    for media <- ~w(image/png image/jpeg image/webp image/gif) do
      bytes = "bytes of #{media}"

      {{:outcome, _, {:completed, _}}, [req], _, _} =
        run(ctx, parts_request([image_part("one", media)]), fn _ -> ok_text() end,
          artifacts: need(%{"one" => {bytes, media}})
        )

      conforms([req], ctx.schema)
      assert [%{"source" => %{"media_type" => ^media}} = block] = user_blocks(req)
      assert image_data(block) == bytes
    end

    images = for i <- 1..8, into: %{}, do: {"img-#{i}", {"image #{i} bytes", "image/png"}}

    parts =
      for i <- 1..8,
          p <- [%{"type" => "text", "text" => "Image #{i}:"}, image_part("img-#{i}", "image/png")],
          do: p

    {{:outcome, _, {:completed, _}}, [req], _, _} =
      run(ctx, parts_request(parts), fn _ -> ok_text() end, artifacts: need(images))

    conforms([req], ctx.schema)

    expected =
      for i <- 1..8, do: [{:text, "Image #{i}:"}, {:image, "image #{i} bytes"}]

    assert Enum.map(user_blocks(req), fn
             %{"type" => "text", "text" => t} -> {:text, t}
             %{"type" => "image"} = b -> {:image, image_data(b)}
           end) == List.flatten(expected)
  end

  test "image: a ninth image, an image over max_image_bytes and images over max_total_image_bytes are refused by ai-text before translation; no request reaches the stub (admission)" do
    {agent, plug} = AnthropicStub.start(fn _ -> ok_text() end)
    nine = for i <- 1..9, into: %{}, do: {"img-#{i}", {"x", "image/png"}}
    big = %{"big" => {:binary.copy(<<7>>, 5_242_881), "image/png"}}

    pair = %{
      "a" => {:binary.copy(<<1>>, 100), "image/png"},
      "b" => {:binary.copy(<<2>>, 100), "image/png"}
    }

    for {images, ids, opts} <- [
          {nine, Map.keys(nine), []},
          {big, ["big"], []},
          {pair, ["a", "b"], [image_bounds: %{max_image_bytes: 100, max_total_image_bytes: 150}]}
        ] do
      c = config(plug, [artifacts: need(images)] ++ opts)
      req = parts_request(Enum.map(ids, &image_part(&1, "image/png")))

      assert {:error, {:refused, :too_large}} =
               AiText.admission(c, Conformance.declaration(req, "big", 10_000)),
             inspect(ids)
    end

    assert AnthropicStub.requests(agent) == []
  end

  test "image: a model whose LLMDB input modalities lack :image and a cache breakpoint on the parts message are unsupported_feature with no request; text-only and other-message controls are sent (translate)",
       ctx do
    {:ok, model} = ReqLLM.model("anthropic:" <> @no_image_model)
    # LLMDB 2026.11.0 holds no modalities for this record: no :image input.
    assert model.modalities == nil
    images = %{"one" => {Conformance.image(), "image/png"}}
    opts = [artifacts: need(images), models: [@model, @no_image_model]]
    {agent, plug} = AnthropicStub.start(fn _ -> ok_text() end)
    c = config(plug, opts)

    no_image = Map.put(parts_request([image_part("one", "image/png")]), "model", @no_image_model)

    # Three non-system messages; message 0 holds the parts.
    conversation = fn breakpoint ->
      request(%{
        "messages" => [
          %{"role" => "system", "text" => "Answer briefly."},
          %{"role" => "user", "parts" => [image_part("one", "image/png")]},
          %{"role" => "assistant", "text" => "Seen."},
          %{"role" => "user", "text" => "Again."}
        ],
        "cache_hint" => hint(["system", %{"message" => breakpoint}])
      })
    end

    for req <- [no_image, conversation.(0)] do
      assert {:error, {:refused, :unsupported_feature}} =
               AiText.admission(c, Conformance.declaration(req, "u", 10_000))

      # The refusal is the provider's: translate/2 alone refuses the resolved request.
      assert {:refused, :unsupported_feature} =
               Anthropic.translate(resolved(req, Conformance.image()), %{plug: plug})
    end

    assert AnthropicStub.requests(agent) == []

    # Controls: the same model without image parts, and a breakpoint on a text message.
    {{:outcome, _, {:completed, _}}, [req], _, _} =
      run(ctx, request(%{"model" => @no_image_model}), fn _ -> ok_text() end, opts)

    conforms([req], ctx.schema)

    {{:outcome, _, {:completed, _}}, [req], _, _} =
      run(ctx, conversation.(2), fn _ -> ok_text() end, opts)

    conforms([req], ctx.schema)

    assert [_, _, %{"content" => [%{"cache_control" => %{"type" => "ephemeral"}}]}] =
             wire(req)["messages"]
  end

  test "image: translate/2 alone refuses an image over the documented 10 MB base64 limit too_large and accepts one at it; ai-text's largest max_image_bytes is sent (translate + captured request)",
       ctx do
    json = parts_request([image_part("one", "image/png")])

    # 7,500,000 bytes encode to exactly 10,000,000 base64 bytes; one more byte exceeds it.
    assert {:ok, _} = Anthropic.translate(resolved(json, :binary.copy(<<0>>, 7_500_000)), nil)

    assert {:refused, :too_large} =
             Anthropic.translate(resolved(json, :binary.copy(<<0>>, 7_500_001)), nil)

    largest = :crypto.strong_rand_bytes(5_242_880)

    {{:outcome, _, {:completed, _}}, [req], _, _} =
      run(ctx, json, fn _ -> ok_text() end, artifacts: need(%{"one" => {largest, "image/png"}}))

    conforms([req], ctx.schema)
    assert [block] = user_blocks(req)
    assert byte_size(block["source"]["data"]) == 6_990_508
    assert image_data(block) == largest
  end
end
