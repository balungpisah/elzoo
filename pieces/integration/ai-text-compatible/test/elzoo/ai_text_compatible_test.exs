# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiText.CompatibleTest.Binding do
  use Elzoo.AiText.Binding,
    id: "compatible-test",
    provider_account: "compatible:test-endpoint",
    recovery_grace_ms: 1000
end

defmodule Elzoo.AiText.CompatibleTest do
  # Every exchange goes to an in-process function plug (or a recording Req
  # adapter) returned by the transport Need; names resolve through a resolver
  # double. No socket is opened and no real key is used.
  use ExUnit.Case, async: false

  alias Elzoo.AiText
  alias Elzoo.AiText.{Compatible, Conformance, Schema, Sink}
  alias Elzoo.AiModel.Usage
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.DurableLog.Memory
  alias Elzoo.EgressPolicy

  @key "sk-compat-test-INJECTED-q9"
  @base "https://llm.example.com:8443/api/v1"
  @path "/api/v1/chat/completions"
  @checked %{
    host: "llm.example.com",
    port: 8443,
    addresses: [{93, 184, 216, 34}, {93, 184, 216, 35}]
  }
  @kit "kit-model"
  @features [:tools, :structured_output, :stop_sequences, :sampling, :image_input]
  @schema_file Path.expand("../fixtures/openai/chat_completions_request.schema.json", __DIR__)

  setup_all do
    {:ok, root} = Schema.build(Jason.decode!(File.read!(@schema_file)))
    %{root: root}
  end

  setup do
    %{intents: start_supervised!({Task.Supervisor, name: nil}, id: :intent)}
  end

  ## doubles

  defp policy do
    EgressPolicy.policy(
      hosts: [
        "llm.example.com",
        "private.example.com",
        "gone.example.com",
        "down.example.com"
      ],
      ports: [443, 8443]
    )
  end

  # Records each lookup in the calling process.
  defp resolver do
    test = self()

    fn host ->
      send(test, {:resolved, host})

      case host do
        # Unsorted, with a duplicate: the policy returns them distinct and sorted.
        "llm.example.com" -> {:ok, [{93, 184, 216, 35}, {93, 184, 216, 34}, {93, 184, 216, 35}]}
        "private.example.com" -> {:ok, [{93, 184, 216, 34}, {10, 0, 0, 5}]}
        "gone.example.com" -> {:error, :nxdomain}
        "down.example.com" -> {:error, :unavailable}
      end
    end
  end

  # A recorder function plug; `respond` maps the decoded body to a response spec.
  defp stub(respond) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 8_000_000)

      Agent.update(agent, fn seen ->
        seen ++
          [%{method: conn.method, path: conn.request_path, headers: conn.req_headers, body: body}]
      end)

      reply(conn, respond.(Jason.decode!(body)))
    end

    {agent, plug}
  end

  defp requests(agent), do: Agent.get(agent, & &1)

  defp reply(conn, {:transport_error, reason}), do: Req.Test.transport_error(conn, reason)

  defp reply(conn, {status, headers, body}) do
    headers
    |> Enum.reduce(conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, if(is_binary(body), do: body, else: Jason.encode!(body)))
  end

  # The transport Need: reports its argument and answers with `answer`.
  defp transport(answer) do
    test = self()

    fn target ->
      send(test, {:transport, target})
      answer.()
    end
  end

  defp table do
    [%{id: @kit, features: [:tools, :structured_output, :image_input]}, %{id: "bare", features: []}] ++
      for f <- @features, do: %{id: "only-#{f}", features: [f]}
  end

  defp endpoint!(transport, models \\ table()) do
    {:ok, e} =
      Compatible.endpoint(
        base_url: @base,
        policy: policy(),
        resolver: resolver(),
        transport: transport,
        models: models
      )

    e
  end

  defp config(endpoint) do
    {:ok, c} =
      AiText.configure(
        binding: Elzoo.AiText.CompatibleTest.Binding,
        tenant: "tenant-a",
        provider: Compatible,
        provider_config: endpoint,
        credentials: fn -> {:ok, @key} end,
        models: Enum.map(table(), & &1.id) ++ ["unlisted"],
        max_output_tokens: 4096,
        receive_timeout_ms: 5000,
        artifacts: Conformance.image_need(),
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

  # Admission, then (only when admitted) the owner and one dispatch. Returns
  # {admission or delivery, requests at the stub}.
  defp attempt(ctx, request, respond) do
    {agent, plug} = stub(respond)
    c = config(endpoint!(transport(fn -> {:ok, plug: plug} end)))
    ref = "ref-#{System.unique_integer([:positive])}"

    case AiText.admission(c, Conformance.declaration(request, ref, 10_000)) do
      {:ok, a} ->
        pid = owner(c, a, ctx)
        {:ok, :dispatched} = Intent.advance(pid, :dispatch)
        settled(pid)
        key = a.key
        assert_receive {AiText, ^key, delivery}, 5000
        {delivery, requests(agent)}

      refused ->
        {refused, requests(agent)}
    end
  end

  defp header(req, name), do: for({^name, v} <- req.headers, do: v)

  # Method, path under the base URL's path, the injected key, the model and the
  # fixture schema.
  defp conforms(requests, model, ctx) do
    for req <- requests do
      assert req.method == "POST"
      assert req.path == @path
      assert header(req, "authorization") == ["Bearer " <> @key]
      body = Jason.decode!(req.body)
      assert body["model"] == model
      assert Schema.validate(body, ctx.root) == :ok, "request does not validate: #{req.body}"
    end
  end

  ## documented-format stubs (Chat Completions response and error objects)

  defp completion(message, finish, opts \\ []) do
    base = %{
      "id" => "chatcmpl-B9MHDbslfkBeAs8l4bebGdFOJ6PeG",
      "object" => "chat.completion",
      "created" => 1_741_570_283,
      "model" => @kit,
      "choices" => [
        %{"index" => 0, "message" => message, "finish_reason" => finish, "logprobs" => nil}
      ]
    }

    case Keyword.get(opts, :usage, :default) do
      :default -> Map.put(base, "usage", usage(19, 10, %{"cached_tokens" => 0}))
      :none -> base
      u -> Map.put(base, "usage", u)
    end
  end

  defp usage(prompt, output, details),
    do: %{
      "prompt_tokens" => prompt,
      "completion_tokens" => output,
      "total_tokens" => prompt + output,
      "prompt_tokens_details" => details,
      "completion_tokens_details" => %{"reasoning_tokens" => 0}
    }

  defp text(t), do: %{"role" => "assistant", "content" => t, "refusal" => nil}

  defp call(args),
    do: %{
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        %{
          "id" => "call_abc123",
          "type" => "function",
          "function" => %{"name" => "lookup", "arguments" => args}
        }
      ]
    }

  defp ok(body), do: {200, [{"x-request-id", "req_stub_1"}], body}

  defp error(type, message \\ "stub error"),
    do: %{"error" => %{"message" => message, "type" => type, "param" => nil, "code" => nil}}

  defp stub_for(:text), do: ok(completion(text(Conformance.text()), "stop"))
  defp stub_for(:length), do: ok(completion(text("Cut"), "length"))

  defp stub_for(:refusal),
    do: ok(completion(%{"role" => "assistant", "content" => nil, "refusal" => "No."}, "stop"))

  # The documented, deprecated `function_call` reason is outside the neutral set.
  defp stub_for(:other_finish), do: ok(completion(text("x"), "function_call"))
  defp stub_for(:tool_call), do: ok(completion(call(~s({"q":"x"})), "tool_calls"))
  defp stub_for(:tool_invalid_json), do: ok(completion(call(~s({"q":)), "tool_calls"))
  defp stub_for(:tool_schema_mismatch), do: ok(completion(call(~s({"q":5})), "tool_calls"))
  defp stub_for(:structured), do: ok(completion(text(~s({"answer":42})), "stop"))
  defp stub_for(:structured_mismatch), do: ok(completion(text(~s({"answer":"forty-two"})), "stop"))
  defp stub_for(:no_usage), do: ok(completion(text("x"), "stop", usage: :none))
  defp stub_for(:malformed_success), do: ok(%{"object" => "chat.completion", "choices" => []})
  defp stub_for(:timeout), do: {:transport_error, :timeout}

  defp stub_for(:throttled),
    do: {429, [{"x-request-id", "req_429"}, {"retry-after", "7"}], error("requests", "Rate limit")}

  defp stub_for(:overloaded), do: {503, [], error("server_error", "Slow down")}
  defp stub_for(:server_error), do: {500, [], error("server_error")}

  ## 1. conformance kit

  test "1 conformance kit and image scenario on a model declaring tools, structured output and image input; requests validate under the base path",
       ctx do
    for s <- Conformance.scenarios() ++ Conformance.image_scenarios() do
      response = stub_for(s.stub)
      {delivery, requests} = attempt(ctx, Conformance.request(s.id, @kit), fn _ -> response end)
      assert :ok == Conformance.check(s.id, delivery, length(requests)), inspect({s.id, delivery})
      conforms(requests, @kit, ctx)
      [body] = Enum.map(requests, &Jason.decode!(&1.body))
      sent = Conformance.request(s.id, @kit)

      # The caller's output schema and tools reach the endpoint, not only a
      # canned reply.
      case sent do
        %{"output_schema" => schema} ->
          assert %{"type" => "json_schema", "json_schema" => %{"schema" => ^schema}} =
                   body["response_format"]

        _ ->
          refute Map.has_key?(body, "response_format")
      end

      case sent do
        %{"tools" => [%{"name" => name, "input_schema" => input}]} ->
          assert [%{"type" => "function", "function" => %{"name" => ^name, "parameters" => ^input}}] =
                   body["tools"]

        _ ->
          refute Map.has_key?(body, "tools")
      end
    end

    {_, [req]} = attempt(ctx, Conformance.request(:image_input, @kit), fn _ -> stub_for(:text) end)
    [_system, user] = Jason.decode!(req.body)["messages"]

    assert user["content"] == [
             %{"type" => "text", "text" => "Describe the image."},
             %{
               "type" => "image_url",
               "image_url" => %{
                 "url" => "data:image/png;base64," <> Base.encode64(Conformance.image())
               }
             }
           ]
  end

  test "1 the fixture schema rejects shapes outside the documented request (negative controls)",
       ctx do
    good = %{"model" => "m", "messages" => [%{"role" => "user", "content" => "hi"}]}
    assert Schema.validate(good, ctx.root) == :ok

    for bad <- [
          Map.put(good, "stop", ["a", "b", "c", "d", "e"]),
          Map.put(good, "store", false),
          Map.put(good, "messages", []),
          Map.put(good, "temperature", 3),
          Map.put(good, "messages", [%{"role" => "tool", "content" => "x"}]),
          Map.put(good, "messages", [
            %{"role" => "user", "content" => [%{"type" => "image", "data" => "x"}]}
          ])
        ] do
      refute Schema.validate(bad, ctx.root) == :ok, inspect(bad)
    end
  end

  ## 2. per-model features; 3. model outside the table

  defp feature_request(:tools, m), do: Conformance.request(:tool_well_formed, m)
  defp feature_request(:structured_output, m), do: Conformance.request(:structured_valid, m)
  defp feature_request(:image_input, m), do: Conformance.request(:image_input, m)

  defp feature_request(:stop_sequences, m),
    do: Map.put(Conformance.request(:text_completion, m), "stop_sequences", ["END", "STOP"])

  defp feature_request(:sampling, m),
    do:
      Map.put(Conformance.request(:text_completion, m), "sampling", %{
        "temperature" => 1,
        "top_p" => 0.5
      })

  test "2 a feature the table does not declare for the model is unsupported_feature with no request; the model that declares it sends",
       ctx do
    for f <- @features, model <- ["bare" | for(g <- @features, do: "only-#{g}")] do
      {result, requests} = attempt(ctx, feature_request(f, model), fn _ -> stub_for(:text) end)

      if model == "only-#{f}" do
        assert {:outcome, _, {:completed, _}} = result, inspect({f, model, result})
        assert length(requests) == 1
        conforms(requests, model, ctx)
      else
        assert length(requests) == 0, inspect({f, model, :requests, length(requests)})
        assert result == {:error, {:refused, :unsupported_feature}}, inspect({f, model})
      end
    end

    {_, [stop]} =
      attempt(ctx, feature_request(:stop_sequences, "only-stop_sequences"), fn _ ->
        stub_for(:text)
      end)

    assert Jason.decode!(stop.body)["stop"] == ["END", "STOP"]

    {_, [sampling]} =
      attempt(ctx, feature_request(:sampling, "only-sampling"), fn _ -> stub_for(:text) end)

    assert %{"temperature" => 1.0, "top_p" => 0.5} = Jason.decode!(sampling.body)
  end

  test "2 Chat Completions bounds of this Piece: 4 stop sequences sent, 5 invalid_request, a tool-result error flag unsupported_feature, with no request",
       ctx do
    stops = fn n ->
      Map.put(
        Conformance.request(:text_completion, "only-stop_sequences"),
        "stop_sequences",
        for(i <- 1..n, do: "S#{i}")
      )
    end

    {result, [req]} = attempt(ctx, stops.(4), fn _ -> stub_for(:text) end)
    assert {:outcome, _, {:completed, _}} = result
    assert Jason.decode!(req.body)["stop"] == ["S1", "S2", "S3", "S4"]
    conforms([req], "only-stop_sequences", ctx)

    assert {{:error, {:refused, :invalid_request}}, []} =
             attempt(ctx, stops.(5), fn _ -> stub_for(:text) end)

    tool_result = fn flag ->
      Map.put(Conformance.request(:tool_well_formed, @kit), "messages", [
        %{"role" => "user", "text" => "Look up x."},
        %{
          "role" => "assistant",
          "text" => "Looking.",
          "tool_calls" => [%{"id" => "call_1", "name" => "lookup", "arguments" => %{"q" => "x"}}]
        },
        %{
          "role" => "tool_result",
          "tool_use_id" => "call_1",
          "text" => "failed",
          "is_error" => flag
        }
      ])
    end

    {result, [req]} = attempt(ctx, tool_result.(false), fn _ -> stub_for(:text) end)
    assert {:outcome, _, {:completed, _}} = result

    assert %{"role" => "tool", "tool_call_id" => "call_1", "content" => "failed"} =
             List.last(Jason.decode!(req.body)["messages"])

    conforms([req], @kit, ctx)

    assert {{:error, {:refused, :unsupported_feature}}, []} =
             attempt(ctx, tool_result.(true), fn _ -> stub_for(:text) end)

    # A replay of earlier tool calls and results with no tool offered now is
    # still tool use: refused for a model without :tools, sent for one with it.
    replay = fn model ->
      Map.merge(tool_result.(false), %{"model" => model}) |> Map.delete("tools")
    end

    assert {{:error, {:refused, :unsupported_feature}}, []} =
             attempt(ctx, replay.("bare"), fn _ -> stub_for(:text) end)

    {result, [req]} = attempt(ctx, replay.("only-tools"), fn _ -> stub_for(:text) end)
    assert {:outcome, _, {:completed, _}} = result
    body = Jason.decode!(req.body)
    refute Map.has_key?(body, "tools")
    assert [_, %{"tool_calls" => [_]}, %{"role" => "tool"}] = body["messages"]
    conforms([req], "only-tools", ctx)
  end

  test "3 a model outside the table is invalid_request before any request; a non-endpoint term too",
       ctx do
    {result, requests} =
      attempt(ctx, Conformance.request(:text_completion, "unlisted"), fn _ -> stub_for(:text) end)

    assert result == {:error, {:refused, :invalid_request}}
    assert requests == []

    {:ok, request, _} =
      Conformance.request(:text_completion, @kit)
      |> Jason.encode!()
      |> AiText.Request.decode(65_536)

    assert Compatible.translate(request, %{base_url: @base}) == {:refused, :invalid_request}
    assert Compatible.translate(request, nil) == {:refused, :invalid_request}
  end

  ## 4. endpoint/1

  defp endpoint(base_url, models \\ table()) do
    Compatible.endpoint(
      base_url: base_url,
      policy: policy(),
      resolver: resolver(),
      transport: fn _ -> {:ok, []} end,
      models: models
    )
  end

  test "4 endpoint/1: egress reasons from the policy, shape refusals with no resolver call" do
    assert {:error, {:egress, :non_public_address}} = endpoint("https://private.example.com/v1")
    assert_received {:resolved, "private.example.com"}
    assert {:error, {:egress, :dns_failed}} = endpoint("https://gone.example.com/v1")
    assert {:error, {:egress, :unavailable}} = endpoint("https://down.example.com/v1")
    assert {:error, {:egress, :not_allowed}} = endpoint("https://other.example.com/v1")
    assert {:error, {:egress, :host}} = endpoint("https://93.184.216.34/v1")
    assert {:error, {:egress, :port}} = endpoint("https://llm.example.com:9443/v1")

    assert_received {:resolved, "gone.example.com"}
    assert_received {:resolved, "down.example.com"}
    # The policy refuses a name, a literal or a port before any lookup.
    refute_received {:resolved, _}

    pad = fn n -> "https://llm.example.com/" <> String.duplicate("a", n - 24) end
    assert byte_size(pad.(2049)) == 2049

    for url <- [
          "http://llm.example.com/v1",
          "https://user:pw@llm.example.com/v1",
          "https://llm.example.com/v1?api-version=1",
          "https://llm.example.com/v1?",
          "https://llm.example.com/v1#frag",
          pad.(2049),
          "",
          :not_a_url
        ] do
      assert endpoint(url) == {:error, :invalid}, inspect(url)
    end

    refute_received {:resolved, _}

    assert {:ok, e} = endpoint(pad.(2048))
    assert_received {:resolved, "llm.example.com"}
    assert {e.host, e.port} == {"llm.example.com", 443}
  end

  test "4 endpoint/1: 64 models accepted; 65, a duplicate, an unknown feature or a bad id refused; exact keys" do
    many = for i <- 1..65, do: %{id: "m-#{i}", features: [:tools]}
    assert {:ok, _} = endpoint(@base, Enum.take(many, 64))
    assert_received {:resolved, "llm.example.com"}

    for models <- [
          many,
          [],
          [%{id: "a", features: []}, %{id: "a", features: [:tools]}],
          [%{id: "a", features: [:reasoning]}],
          [%{id: "a", features: [:cache_hint]}],
          [%{id: "a", features: :tools}],
          [%{id: "", features: []}],
          [%{id: "a\nb", features: []}],
          [%{id: "a\u0085b", features: []}],
          [%{id: String.duplicate("a", 257), features: []}],
          [%{id: "a", features: [], extra: 1}],
          [%{id: "a"}]
        ] do
      assert endpoint(@base, models) == {:error, :invalid}, inspect(models)
    end

    opts = [
      base_url: @base,
      policy: policy(),
      resolver: resolver(),
      transport: fn _ -> {:ok, []} end,
      models: table()
    ]

    assert Compatible.endpoint(Keyword.delete(opts, :transport)) == {:error, :invalid}
    assert Compatible.endpoint(opts ++ [extra: 1]) == {:error, :invalid}
    assert Compatible.endpoint(opts ++ [models: table()]) == {:error, :invalid}
    assert Compatible.endpoint(Keyword.put(opts, :resolver, :nope)) == {:error, :invalid}
    assert Compatible.endpoint(Keyword.put(opts, :policy, %{})) == {:error, :invalid}
    refute_received {:resolved, _}
  end

  ## 5. the transport Need

  test "5 the transport Need gets exactly the checked target; a failing Need sends nothing",
       ctx do
    {_, [_]} =
      attempt(ctx, Conformance.request(:text_completion, @kit), fn _ -> stub_for(:text) end)

    assert_received {:transport, @checked}

    {:ok, request, _} =
      Conformance.request(:text_completion, @kit)
      |> Jason.encode!()
      |> AiText.Request.decode(65_536)

    call_opts = %{credential: @key, receive_timeout_ms: 1000}

    # Each answer carries the stub plug where it could, so a wrongly accepted
    # answer would reach the stub rather than the network.
    for answer <- [
          fn _ -> raise "host transport down" end,
          fn _ -> throw(:down) end,
          fn _ -> exit(:down) end,
          fn _ -> {:error, :no_pool} end,
          fn plug -> {:ok, %{plug: plug}} end,
          fn plug -> {:ok, [{:plug, plug}, 2]} end,
          fn plug -> {:ok, plug: plug, not_a_req_option: 1} end,
          fn _ -> :ok end
        ] do
      {agent, plug} = stub(fn _ -> stub_for(:text) end)
      e = endpoint!(transport(fn -> answer.(plug) end))
      {:ok, wire} = Compatible.translate(request, e)
      assert Compatible.call(wire, call_opts) == {:transport, :unavailable}
      assert_received {:transport, @checked}
      assert requests(agent) == []
    end

    assert Compatible.classify_failure({:transport, :unavailable}) == :transport
  end

  test "5 connect_options from the Need reach the one request with no finch option (recording adapter)",
       ctx do
    test = self()

    adapter = fn request ->
      send(test, {:adapter, request.options, request.url})
      {request, Req.Response.new(status: 200, body: Jason.encode!(completion(text("x"), "stop")))}
    end

    e =
      endpoint!(
        transport(fn -> {:ok, connect_options: [hostname: "llm.example.com"], adapter: adapter} end)
      )

    c = config(e)

    {:ok, a} =
      AiText.admission(
        c,
        Conformance.declaration(Conformance.request(:text_completion, @kit), "r5", 10_000)
      )

    pid = owner(c, a, ctx)

    # Req 0.7.5 warns that a function adapter is deprecated; the warning is kept
    # out of the test output.
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      {:ok, :dispatched} = Intent.advance(pid, :dispatch)
      settled(pid)
    end)

    key = a.key
    assert_receive {AiText, ^key, {:outcome, _, {:completed, _}}}, 5000

    assert_received {:adapter, options, url}
    refute_received {:adapter, _, _}
    assert options.connect_options == [hostname: "llm.example.com"]
    refute Map.has_key?(options, :finch)
    assert options.retry == false and options.redirect == false
    assert options.receive_timeout == 5000
    assert URI.to_string(url) =~ "llm.example.com:8443"
  end

  test "5 a host finch pool keeps its name and settings but not its own receive_timeout (recording adapter)" do
    test = self()

    adapter = fn request ->
      send(test, {:adapter, request.options})
      {request, Req.Response.new(status: 200, body: Jason.encode!(completion(text("x"), "stop")))}
    end

    e =
      endpoint!(
        transport(fn ->
          {:ok,
           finch: [name: :host_pinned_pool, receive_timeout: 30_000, pool_timeout: 7],
           adapter: adapter}
        end)
      )

    {:ok, request, _} =
      Conformance.request(:text_completion, @kit)
      |> Jason.encode!()
      |> AiText.Request.decode(65_536)

    {:ok, wire} = Compatible.translate(request, e)

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      send(test, {:result, Compatible.call(wire, %{credential: @key, receive_timeout_ms: 1234})})
    end)

    assert_received {:result, {:ok, %{status: 200}}}
    assert_received {:adapter, options}
    # Req.Finch.build/1 merges these after the top-level timeout, so a kept
    # receive_timeout here would override the interface's.
    assert options.finch == [name: :host_pinned_pool, pool_timeout: 7]
    assert options.receive_timeout == 1234
  end

  ## 6. statuses, timeout, malformed body

  test "6 each status of the table, 429 with and without Retry-After, a timeout and a malformed body: one request each",
       ctx do
    cases = [
      {{400, [], error("invalid_request_error")},
       {:refused, :invalid_request, %{retry_after: nil}}},
      {{401, [], error("invalid_request_error", "Incorrect API key " <> @key)},
       {:refused, :authentication_failed, %{retry_after: nil}}},
      {{403, [], error("invalid_request_error")},
       {:refused, :permission_denied, %{retry_after: nil}}},
      {{404, [], error("invalid_request_error")}, {:refused, :not_found, %{retry_after: nil}}},
      {{413, [], error("invalid_request_error")}, {:refused, :too_large, %{retry_after: nil}}},
      {{429, [{"retry-after", "7"}], error("requests")}, {:refused, :throttled, %{retry_after: 7}}},
      {{429, [], error("requests")}, {:refused, :throttled, %{retry_after: nil}}},
      {{429, [{"retry-after", "Wed, 21 Oct 2026 07:28:00 GMT"}], error("requests")},
       {:refused, :throttled, %{retry_after: nil}}},
      {{500, [], error("server_error")}, {:unknown, :provider_error}},
      {{502, [], error("server_error")}, {:unknown, :provider_error}},
      {{503, [{"retry-after", "3"}], error("server_error")},
       {:refused, :overloaded, %{retry_after: 3}}},
      {{504, [], error("server_error")}, {:unknown, :timeout}},
      {{302, [{"location", "https://elsewhere.example.com/"}], ""}, {:unknown, :provider_error}},
      {{:transport_error, :timeout}, {:unknown, :timeout}},
      {{200, [], "not json"}, {:unknown, :malformed_response}},
      {{200, [], %{"object" => "chat.completion", "id" => "x", "model" => "m", "choices" => []}},
       {:unknown, :malformed_response}},
      {ok(
         completion(
           %{"role" => "assistant", "content" => nil, "tool_calls" => [%{"type" => "x"}]},
           "tool_calls"
         )
       ), {:unknown, :malformed_response}},
      {ok(completion(%{}, "stop")), {:unknown, :malformed_response}},
      {ok(completion(%{"role" => "assistant", "refusal" => nil}, "stop")),
       {:unknown, :malformed_response}},
      {ok(completion(%{"role" => "user", "content" => "x"}, "stop")),
       {:unknown, :malformed_response}},
      {{200, [], String.duplicate(" ", 4_194_305)}, {:unknown, :malformed_response}}
    ]

    for {response, expected} <- cases do
      {delivery, requests} =
        attempt(ctx, Conformance.request(:text_completion, @kit), fn _ -> response end)

      assert {:outcome, _, ^expected} = delivery, inspect(response, limit: 5, printable_limit: 80)
      assert length(requests) == 1
      refute inspect(delivery) =~ @key
      refute inspect(delivery) =~ "stub error"
    end
  end

  test "6 a body over 4 MiB of wire bytes is stopped while received and is malformed_response whatever its status, one request each",
       ctx do
    big = String.duplicate(" ", 4_194_305)

    for {status, headers} <- [
          {200, []},
          {400, []},
          {429, [{"retry-after", "7"}]},
          {503, [{"retry-after", "3"}]}
        ] do
      {delivery, requests} =
        attempt(ctx, Conformance.request(:text_completion, @kit), fn _ ->
          {status, headers, big}
        end)

      assert {:outcome, _, {:unknown, :malformed_response}} = delivery, inspect(status)
      assert length(requests) == 1
    end

    # Exactly 4 MiB is kept; the chunk that crosses the bound halts the transfer
    # and drops what was received.
    acc = {Req.new(), Req.Response.new(status: 429, body: "")}
    {:cont, {_, at_bound}} = Compatible.bounded({:data, String.duplicate("a", 4_194_304)}, acc)
    assert byte_size(at_bound.body) == 4_194_304
    assert {:halt, {_, over}} = Compatible.bounded({:data, "b"}, {Req.new(), at_bound})
    assert over.body == ""
    assert over.private.elzoo_oversize == true
    assert {:failure, :malformed_response} = Compatible.decode(%{oversize: true, status: 429}, nil)
  end

  # The one test with a socket: a disposable loopback listener, as in
  # integration/ai-text-openai, to show Req/Finch stop a live chunked transfer.
  test "6 Req/Finch stops a chunked receive above the bound before the server finishes its body" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 429 Too Many Requests\r\nTransfer-Encoding: chunked\r\n\r\n"
          )

        chunk = :binary.copy("x", 1_048_576)

        for data <- [chunk, chunk, chunk, chunk, "y"] do
          :ok =
            :gen_tcp.send(socket, [Integer.to_string(byte_size(data), 16), "\r\n", data, "\r\n"])
        end

        send(parent, :oversized_chunks_sent)
        # No terminating chunk: a collector that buffers the whole body would
        # wait for it and time out instead of returning the oversize marker.
        receive do
          :finish -> :ok
        after
          10_000 -> :ok
        end

        :gen_tcp.close(socket)
      end)

    try do
      result =
        Req.request(
          %{
            Req.new(url: "http://127.0.0.1:#{port}/", retry: false, receive_timeout: 2000)
            | into: &Compatible.bounded/2
          }
          |> Req.Request.prepend_response_steps(elzoo_capture: &Compatible.capture/1)
        )

      assert_receive :oversized_chunks_sent, 1000
      assert {:ok, response} = result
      assert %{status: 429, oversize: true, body: nil} = response.private.elzoo_raw
      assert {:failure, :malformed_response} = Compatible.decode(response.private.elzoo_raw, nil)
    after
      send(server.pid, :finish)
      Task.yield(server, 1000) || Task.shutdown(server, :brutal_kill)
      :gen_tcp.close(listener)
    end
  end

  test "6 usage from the documented usage object; absent fields :unknown", ctx do
    for {u, uncached, read, writes, output} <- [
          {usage(2006, 10, %{"cached_tokens" => 1920, "cache_write_tokens" => 0}), 86, 1920, 0, 10},
          {usage(2006, 10, %{"cached_tokens" => 1920}), :unknown, 1920, :unknown, 10},
          {%{"prompt_tokens" => 12, "total_tokens" => 12}, :unknown, :unknown, :unknown, :unknown}
        ] do
      {{:outcome, _, {:completed, c}}, [_]} =
        attempt(ctx, Conformance.request(:text_completion, @kit), fn _ ->
          ok(completion(text("x"), "stop", usage: u))
        end)

      assert c.usage.source == :provider_reported
      assert c.usage.convention == %{input_includes_cached: true}
      assert Usage.amount(c.usage, :input_uncached_tokens) == uncached
      assert Usage.amount(c.usage, :cache_read_tokens) == read
      assert Usage.sum(c.usage.cache_writes) == writes
      assert Usage.amount(c.usage, :output_tokens) == output
    end
  end

  ## 7. redaction

  test "7 no key in an outcome, an error or inspect of the endpoint or the Config", ctx do
    e = endpoint!(fn _ -> {:ok, []} end)
    c = config(e)

    for term <- [e, c] do
      refute inspect(term, limit: :infinity) =~ @key
    end

    refute inspect(e, limit: :infinity) =~ "#Function"
    assert inspect(e) =~ "llm.example.com"

    {delivery, _} =
      attempt(ctx, Conformance.request(:text_completion, @kit), fn _ -> stub_for(:text) end)

    refute inspect(delivery, limit: :infinity) =~ @key
    assert {:error, {:egress, :non_public_address}} == endpoint("https://private.example.com/v1")
  end

  test "capabilities pass the interface's check" do
    caps = Compatible.capabilities()
    assert AiText.Provider.valid_capabilities?(caps)
    assert caps.features == @features

    assert {caps.provider, caps.wire_surface, caps.reasoning} ==
             {"openai-compatible", "chat_completions", []}
  end
end
