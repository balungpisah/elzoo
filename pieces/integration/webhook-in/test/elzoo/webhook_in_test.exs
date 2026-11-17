defmodule Elzoo.WebhookInTest.ReadAdapter do
  def read_req_body(%{owner: owner, steps: [step | rest]} = state, options) do
    send(owner, {:read_options, options})

    case step do
      {:sleep, milliseconds, result, data} ->
        Process.sleep(milliseconds)
        answer(result, data, %{state | steps: rest})

      {result, data} ->
        answer(result, data, %{state | steps: rest})

      :error_timeout ->
        {:error, :timeout}

      :error_other ->
        {:error, :closed}
    end
  end

  def read_req_body(%{owner: owner}, options) do
    send(owner, {:read_options, options})
    {:error, :closed}
  end

  defp answer(:ok, data, state), do: {:ok, data, state}
  defp answer(:more, data, state), do: {:more, data, state}
end

defmodule Elzoo.WebhookInTest do
  use ExUnit.Case, async: true

  alias Elzoo.WebhookIn

  @source_id "source-1"
  @now 1_700_000_000
  @key :binary.copy(<<11>>, 32)
  @body ~s({"version":1,"event_id":"evt-1","conversation_id":"conv-1","input_id":"input-1","expected_revision":0,"text":"hello"})
  @scope %{tenant: "tenant-1", actor: "actor-1", resources: ["conv-1"]}

  test "init requires exactly five well-formed options with one fixed error" do
    valid = defaults()
    assert is_map(WebhookIn.init(valid))

    invalid = [
      Keyword.delete(valid, :admit),
      valid ++ [source_id: "source-1"],
      Keyword.put(valid, :extra, true),
      Keyword.put(valid, :source_id, "é"),
      Keyword.put(valid, :source_id, <<255>>),
      Keyword.put(valid, :source_id, String.duplicate("a", 129)),
      Keyword.put(valid, :source_id, "bad/source"),
      Keyword.put(valid, :key, fn _ -> {:ok, @key} end),
      Keyword.put(valid, :clock, fn _ -> @now end),
      Keyword.put(valid, :principal, fn -> {:ok, @scope} end),
      Keyword.put(valid, :admit, fn _ -> :unknown end),
      %{source_id: "source-1"}
    ]

    Enum.each(invalid, fn options ->
      error = assert_raise ArgumentError, fn -> WebhookIn.init(options) end
      assert Exception.message(error) == "invalid webhook ingress options"
      refute Exception.message(error) =~ "source-1"
    end)
  end

  test "independent known HMAC vector admits the exact framed raw request" do
    signature = "v1=d23c3ca8ba1fa74e41d7929bdd1fc88f9a6fd07a523da18fd945b31cf05d7970"
    conn = build_conn(body: @body, signature: signature)
    response = WebhookIn.call(conn, WebhookIn.init(defaults()))

    assert response.status == 202
    assert response.halted

    assert Jason.decode!(response.resp_body) == %{
             "status" => "committed",
             "event_id" => "evt-1",
             "revision" => 1
           }
  end

  @tag :mac_body_binding
  test "HMAC binds source, timestamp, fixed method and path, raw body, and LF framing" do
    {conn, _body} = request(body: @body)
    tampered = String.replace(@body, "hello", "world")

    unsigned_body_frame =
      "elzoo-webhook-v1\n" <>
        @source_id <>
        "\nPOST\n/elzoo/v1/messages\n" <>
        Integer.to_string(@now) <>
        "\n"

    unbound_signature =
      "v1=" <> Base.encode16(:crypto.mac(:hmac, :sha256, @key, unsigned_body_frame), case: :lower)

    bad_body = build_conn(body: tampered, signature: unbound_signature)

    assert_response(WebhookIn.call(bad_body, WebhookIn.init(defaults())), 401, "unauthorized")
    assert_response(WebhookIn.call(conn, WebhookIn.init(defaults())), 202, "committed")

    original_signature = signature(@source_id, @key, Integer.to_string(@now), @body)

    assert_response(
      WebhookIn.call(
        build_conn(body: tampered, signature: original_signature),
        WebhookIn.init(defaults())
      ),
      401,
      "unauthorized"
    )

    timestamp = Integer.to_string(@now)
    prefix = "elzoo-webhook-v1\n" <> @source_id <> "\n"

    altered_frames = [
      prefix <> "PUT\n/elzoo/v1/messages\n" <> timestamp <> "\n" <> @body,
      prefix <> "POST\n/elzoo/v1/elsewhere\n" <> timestamp <> "\n" <> @body,
      prefix <> "POST\n/elzoo/v1/messages\n" <> timestamp <> @body,
      prefix <> "POST\n/elzoo/v1/messages\n" <> timestamp <> "\n" <> @body <> "\n"
    ]

    for frame <- altered_frames do
      response =
        WebhookIn.call(
          build_conn(body: @body, signature: mac_signature(frame)),
          WebhookIn.init(defaults())
        )

      assert_response(response, 401, "unauthorized")
    end

    other_source = defaults(source_id: "source-2")
    assert_response(WebhookIn.call(conn, WebhookIn.init(other_source)), 401, "unauthorized")

    bad_timestamp =
      build_conn(
        timestamp: Integer.to_string(@now + 1),
        signature: signature(@source_id, @key, Integer.to_string(@now), @body)
      )

    assert_response(WebhookIn.call(bad_timestamp, WebhookIn.init(defaults())), 401, "unauthorized")
  end

  test "route, method, and query admission use fixed responses before callbacks" do
    opts =
      defaults(
        principal: fn _ ->
          send(self(), :principal)
          {:ok, @scope}
        end
      )

    assert_response(call_request(path: "/elsewhere", config: opts), 404, "not_found")
    assert_response(call_request(path: "/elzoo/v1/messages?x=1", config: opts), 404, "not_found")
    assert_response(call_request(method: "GET", config: opts), 405, "method_not_allowed")
    refute_received :principal
  end

  test "media, encoding, duplicate and coalesced content headers are rejected" do
    for {headers, status, tag} <- [
          {[{"content-type", "text/plain"}], 415, "unsupported_media_type"},
          {[{"content-type", "application/json; charset=utf-8"}], 415, "unsupported_media_type"},
          {[{"content-type", "application/json"}, {"content-type", "application/json"}], 400,
           "invalid"},
          {[{"content-type", "application/json, application/json"}], 400, "invalid"},
          {[{"content-encoding", "gzip"}], 415, "unsupported_media_type"},
          {[{"content-encoding", "gzip, br"}], 400, "invalid"},
          {[{"content-encoding", "gzip"}, {"content-encoding", "br"}], 400, "invalid"}
        ] do
      assert_response(call_request(headers: headers), status, tag)
    end
  end

  test "content length is optional, canonical, bounded, and rejects duplicates" do
    {conn, _body} = request(content_length: nil)
    assert Plug.Conn.get_req_header(conn, "content-length") == []
    assert_response(WebhookIn.call(conn, WebhookIn.init(defaults())), 202, "committed")

    for {values, status, tag} <- [
          {["+1"], 400, "invalid"},
          {["01"], 400, "invalid"},
          {["1, 1"], 400, "invalid"},
          {["65537"], 413, "too_large"},
          {["1", "1"], 400, "invalid"}
        ] do
      headers = Enum.map(values, &{"content-length", &1})
      assert_response(call_request(headers: headers), status, tag)
    end
  end

  test "timestamp and signature headers reject malformed, duplicate, coalesced, or uppercase values" do
    for headers <- [
          [{"x-elzoo-timestamp", "01"}],
          [{"x-elzoo-timestamp", "+1"}],
          [{"x-elzoo-timestamp", "1,2"}],
          [{"x-elzoo-timestamp", "1"}, {"x-elzoo-timestamp", "1"}],
          [{"x-elzoo-timestamp", String.duplicate("9", 20)}],
          [{"x-elzoo-timestamp", "9223372036854775808"}],
          [{"x-elzoo-signature", "V1=" <> String.duplicate("a", 64)}],
          [{"x-elzoo-signature", "v1=" <> String.duplicate("A", 64)}],
          [{"x-elzoo-signature", "v1=" <> String.duplicate("a", 63)}],
          [{"x-elzoo-signature", "v1=" <> String.duplicate("a", 65)}],
          [{"x-elzoo-signature", "v1=" <> String.duplicate("a", 64) <> ",x"}],
          [
            {"x-elzoo-signature", "v1=" <> String.duplicate("a", 64)},
            {"x-elzoo-signature", "v1=" <> String.duplicate("a", 64)}
          ]
        ] do
      assert_response(call_request(headers: headers), 400, "invalid")
    end
  end

  test "authentication failure precedes JSON parsing and does not expose an event ID" do
    parent = self()

    opts =
      defaults(
        key: fn ->
          send(parent, :key)
          {:ok, @key}
        end,
        clock: fn ->
          send(parent, :clock)
          @now
        end,
        principal: fn _ ->
          send(parent, :principal)
          {:ok, @scope}
        end,
        admit: fn _, _ ->
          send(parent, :admit)
          {:committed, 1}
        end
      )

    {conn, _body} = request(body: "not json", signature: "v1=" <> String.duplicate("0", 64))
    response = WebhookIn.call(conn, WebhookIn.init(opts))
    assert_response(response, 401, "unauthorized")
    refute Map.has_key?(Jason.decode!(response.resp_body), "event_id")
    assert_received :key
    assert_received :clock
    refute_received :principal
    refute_received :admit
  end

  test "timestamp freshness accepts the inclusive edges and rejects outside values" do
    for delta <- [-300, 300] do
      assert_response(call_request(timestamp: Integer.to_string(@now + delta)), 202, "committed")
    end

    for delta <- [-301, 301] do
      assert_response(call_request(timestamp: Integer.to_string(@now + delta)), 401, "unauthorized")
    end

    max = 9_223_372_036_854_775_807

    assert_response(
      call_request(timestamp: "0", config: defaults(clock: fn -> 0 end)),
      202,
      "committed"
    )

    assert_response(
      call_request(timestamp: Integer.to_string(max), config: defaults(clock: fn -> max end)),
      202,
      "committed"
    )
  end

  test "key and clock Needs fail closed before principal or admission" do
    for key <- [
          fn -> {:error, :unavailable} end,
          fn -> {:ok, <<0::size(31 * 8)>>} end,
          fn -> {:ok, :bad} end,
          fn -> raise "secret" end
        ] do
      opts =
        defaults(
          key: key,
          principal: fn _ ->
            send(self(), :principal)
            {:ok, @scope}
          end
        )

      response = call_request(config: opts)
      assert_response(response, 503, "unavailable")
      refute Map.has_key?(Jason.decode!(response.resp_body), "event_id")
      refute_received :principal
    end

    for clock <- [
          fn -> {:error, :unavailable} end,
          fn -> {:ok, @now} end,
          fn -> -1 end,
          fn -> 9_223_372_036_854_775_808 end,
          fn -> "bad" end,
          fn -> raise "clock" end
        ] do
      opts =
        defaults(
          clock: clock,
          principal: fn _ ->
            send(self(), :principal)
            {:ok, @scope}
          end
        )

      assert_response(call_request(config: opts), 503, "unavailable")
      refute_received :principal
    end

    assert_response(
      call_request(config: defaults(key: fn -> {:ok, :binary.copy(<<1>>, 129)} end)),
      503,
      "unavailable"
    )

    key128 = :binary.copy(<<1>>, 128)

    assert_response(
      call_request(signing_key: key128, config: defaults(key: fn -> {:ok, key128} end)),
      202,
      "committed"
    )
  end

  test "principal Need shapes, scope IDs, exact keys, and resource grants are validated locally" do
    invalid_scopes = [
      %{},
      %{tenant: "t", actor: "a", resources: [], extra: true},
      %{tenant: "", actor: "a", resources: []},
      %{tenant: String.duplicate("t", 129), actor: "a", resources: []},
      %{tenant: "t", actor: String.duplicate("a", 129), resources: []},
      %{tenant: <<255>>, actor: "a", resources: []},
      %{tenant: "t", actor: "a\0", resources: []},
      %{tenant: "t", actor: "a", resources: List.duplicate("r", 65)},
      %{tenant: "t", actor: "a", resources: ["r\0"]},
      %{tenant: "t", actor: "a", resources: [<<255>>]},
      %{tenant: "t", actor: "a", resources: ["r" | :tail]}
    ]

    for result <- [
          {:error, :unavailable},
          :bad,
          {:ok, %{}},
          {:ok, MapSet.new()},
          {:ok, %{tenant: "t", actor: "a", resources: ["other"]}}
        ] do
      response = call_request(config: defaults(principal: fn _ -> result end))

      expected =
        if result == {:ok, %{tenant: "t", actor: "a", resources: ["other"]}}, do: 403, else: 503

      assert_response(response, expected, if(expected == 403, do: "forbidden", else: "unavailable"))
      assert Jason.decode!(response.resp_body)["event_id"] == "evt-1"
    end

    forbidden = call_request(config: defaults(principal: fn _ -> {:error, :forbidden} end))
    assert_response(forbidden, 403, "forbidden")

    for scope <- invalid_scopes do
      response = call_request(config: defaults(principal: fn _ -> {:ok, scope} end))
      assert_response(response, 503, "unavailable")
    end

    for result <- [:raise, :throw] do
      principal =
        case result do
          :raise -> fn _ -> raise "secret detail" end
          :throw -> fn _ -> throw(:private) end
        end

      assert_response(call_request(config: defaults(principal: principal)), 503, "unavailable")
    end
  end

  test "valid host-vouched actors and repeated resource IDs remain acceptable" do
    scope = %{tenant: "another-tenant", actor: "another-actor", resources: ["conv-1", "conv-1"]}
    opts = defaults(principal: fn _ -> {:ok, scope} end)
    response = call_request(config: opts)
    assert_response(response, 202, "committed")

    resources = Enum.map(1..63, &"resource-#{&1}") ++ ["conv-1"]

    max_scope = %{
      tenant: String.duplicate("t", 128),
      actor: String.duplicate("a", 128),
      resources: resources
    }

    assert_response(
      call_request(config: defaults(principal: fn _ -> {:ok, max_scope} end)),
      202,
      "committed"
    )

    unicode_scope = %{tenant: "租户", actor: "用户", resources: ["conv-1"]}

    assert_response(
      call_request(config: defaults(principal: fn _ -> {:ok, unicode_scope} end)),
      202,
      "committed"
    )
  end

  test "an authenticated conversation without a resource grant is forbidden before admission" do
    parent = self()
    scope = %{tenant: "tenant-1", actor: "actor-1", resources: []}

    admit = fn _, _ ->
      send(parent, :admit)
      {:committed, 1}
    end

    response = call_request(config: defaults(principal: fn _ -> {:ok, scope} end, admit: admit))

    assert_response(response, 403, "forbidden")
    assert Jason.decode!(response.resp_body)["event_id"] == "evt-1"
    refute_received :admit
  end

  test "flat JSON schema preserves exact IDs, revision, and text bytes" do
    body =
      ~s({"version":1,"event_id":"evt.1","conversation_id":"conv-1","input_id":"input-1","expected_revision":0,"text":"line1\\nline2\\ttab"})

    parent = self()

    opts =
      defaults(
        admit: fn event, _scope ->
          send(parent, {:event, event})
          {:committed, 1}
        end
      )

    assert_response(call_request(body: body, config: opts), 202, "committed")
    assert_received {:event, %{event_id: "evt.1", expected_revision: 0, text: "line1\nline2\ttab"}}
  end

  test "all event IDs accept 128 ASCII bytes and reject 129" do
    id128 = String.duplicate("i", 128)
    id129 = String.duplicate("i", 129)

    for field <- [:event_id, :input_id] do
      assert_response(call_request(body: valid_body([{field, id128}])), 202, "committed")
      assert_response(call_request(body: valid_body([{field, id129}])), 400, "invalid")
    end

    for {conversation_id, status, tag} <- [
          {id128, 202, "committed"},
          {id129, 400, "invalid"}
        ] do
      parent = self()

      opts =
        defaults(
          principal: fn _ ->
            send(parent, :principal)
            {:ok, %{tenant: "tenant", actor: "actor", resources: [conversation_id]}}
          end
        )

      response =
        call_request(body: valid_body(conversation_id: conversation_id), config: opts)

      assert_response(response, status, tag)

      if status == 202 do
        assert_received :principal
      else
        refute_received :principal
      end
    end
  end

  test "duplicate keys at any JSON depth, unknown fields, nested values and invalid field bounds are rejected" do
    invalid = [
      ~s({"version":1,"event_id":"e","event_id":"e","conversation_id":"conv-1","input_id":"i","expected_revision":0,"text":"x"}),
      ~s({"version":1,"event_id":"e","conversation_id":"conv-1","input_id":"i","expected_revision":0,"text":"x","tenant":"t"}),
      ~s({"version":1,"event_id":"e","conversation_id":"conv-1","input_id":"i","expected_revision":0,"text":{"nested":{"x":1,"x":2}}}),
      ~s([{"version":1}]),
      ~s({"version":1,"event_id":"e","conversation_id":"conv-1","input_id":"i","expected_revision":0.0,"text":"x"}),
      ~s({"version":2,"event_id":"e","conversation_id":"conv-1","input_id":"i","expected_revision":0,"text":"x"}),
      ~s({"version":1,"event_id":"","conversation_id":"conv-1","input_id":"i","expected_revision":0,"text":"x"}),
      ~s({"version":1,"event_id":"e","conversation_id":"conv-1","input_id":"i","expected_revision":9223372036854775807,"text":"x"}),
      ~s({"version":1,"event_id":"e","conversation_id":"conv-1","input_id":"i","expected_revision":-1,"text":"x"}),
      ~s({"version":1,"event_id":"e","conversation_id":"conv-1","input_id":"i","expected_revision":0,"text":""}),
      ~s({"version":1,"event_id":"e","conversation_id":"conv-1","input_id":"i","expected_revision":0,"text":"a\u0000b"}),
      ~s({"version":1,"event_id":"é","conversation_id":"conv-1","input_id":"i","expected_revision":0,"text":"x"}),
      ~s({"version":1,"event_id":"e","conversation_id":"conv-1","input_id":"i","expected_revision":0,"text":"x","actor":"actor"}),
      ~s({"version":1,"event_id":"e","conversation_id":"conv-1","input_id":"i","expected_revision":0,"text":"x","run_id":"run"}),
      ~s({"version":1,"event_id":"e","conversation_id":"conv-1","input_id":"i","expected_revision":0,"text":"x","policy":"policy"}),
      ~s({"version":1,"event_id":"e","conversation_id":"conv-1","input_id":"i","expected_revision":0,"text":"x","authority":"authority"})
    ]

    for body <- invalid do
      response = call_request(body: body)
      assert_response(response, 400, "invalid")
      refute Map.has_key?(Jason.decode!(response.resp_body), "event_id")
    end

    long_id = String.duplicate("a", 129)

    assert_response(
      call_request(
        body:
          Jason.encode!(%{
            "version" => 1,
            "event_id" => long_id,
            "conversation_id" => "conv-1",
            "input_id" => "i",
            "expected_revision" => 0,
            "text" => "x"
          })
      ),
      400,
      "invalid"
    )

    assert_response(
      call_request(body: valid_body(text: String.duplicate("x", 4097))),
      400,
      "invalid"
    )

    assert_response(
      call_request(body: valid_body(text: String.duplicate("x", 4096))),
      202,
      "committed"
    )

    assert_response(
      call_request(body: valid_body(text: String.duplicate("é", 2048))),
      202,
      "committed"
    )

    assert_response(
      call_request(body: valid_body(text: String.duplicate("é", 2049))),
      400,
      "invalid"
    )
  end

  test "principal and admission callbacks have exact scope/event, and admission is once only" do
    parent = self()

    opts =
      defaults(
        principal: fn conn ->
          send(parent, {:principal_conn, conn.request_path})
          {:ok, @scope}
        end,
        admit: fn event, scope ->
          send(parent, {:admit, event, scope})
          {:committed, event.expected_revision + 1}
        end
      )

    assert_response(call_request(config: opts), 202, "committed")
    assert_received {:principal_conn, "/elzoo/v1/messages"}
    assert_received {:admit, event, scope}
    assert scope == @scope

    assert Enum.sort(Map.keys(event)) == [
             :conversation_id,
             :event_id,
             :expected_revision,
             :input_id,
             :text,
             :version
           ]

    refute Map.has_key?(event, :source_id)
    refute_received {:admit, _, _}
  end

  test "all admission outcomes are normalized, bounded, halted, and preserve the authenticated event ID" do
    for {reply, status, tag, extra} <- [
          {{:committed, 1}, 202, "committed", %{"revision" => 1}},
          {{:pending, :approval}, 202, "pending_approval", %{}},
          {{:rejected, :forbidden}, 403, "forbidden", %{}},
          {{:rejected, :conflict}, 409, "conflict", %{}},
          {{:rejected, :invalid}, 400, "invalid", %{}},
          {:unknown, 503, "unknown", %{}},
          {{:error, :unavailable}, 503, "unavailable", %{}},
          {{:committed, 2}, 503, "unknown", %{}},
          {{:committed, :bad}, 503, "unknown", %{}},
          {:malformed, 503, "unknown", %{}}
        ] do
      admit = if reply == :malformed, do: fn _, _ -> :anything end, else: fn _, _ -> reply end
      response = call_request(config: defaults(admit: admit))
      assert_response(response, status, tag)
      body = Jason.decode!(response.resp_body)
      assert body["event_id"] == "evt-1"
      assert Map.take(body, ["revision"]) == extra
      assert byte_size(response.resp_body) <= 512
    end
  end

  test "the last valid expected revision commits at the maximum signed revision" do
    max_revision = 9_223_372_036_854_775_806
    body = valid_body(expected_revision: max_revision)
    response = call_request(body: body)
    assert_response(response, 202, "committed")
    assert Jason.decode!(response.resp_body)["revision"] == max_revision + 1
  end

  test "admission exceptions after a simulated commit are unknown and never retried" do
    parent = self()

    admit = fn _event, _scope ->
      send(parent, :simulated_commit)
      raise "provider detail"
    end

    response = call_request(config: defaults(admit: admit))
    assert_response(response, 503, "unknown")
    assert_received :simulated_commit
    refute_received :simulated_commit
    refute response.resp_body =~ "provider detail"
  end

  test "event IDs and expected revisions are supplied unchanged on resubmission" do
    parent = self()

    admit = fn event, _scope ->
      send(
        parent,
        {event.event_id, event.input_id, event.conversation_id, event.expected_revision}
      )

      {:rejected, :conflict}
    end

    opts = defaults(admit: admit)
    body = valid_body(event_id: "retry-1", input_id: "input-original", expected_revision: 17)

    assert_response(call_request(body: body, config: opts), 409, "conflict")
    assert_response(call_request(body: body, config: opts), 409, "conflict")
    assert_received {"retry-1", "input-original", "conv-1", 17}
    assert_received {"retry-1", "input-original", "conv-1", 17}
    refute_received {_, _, _, _}
  end

  @tag :cumulative_size
  test "body cap accepts exactly 65,536 bytes and refuses cumulative overflow without Content-Length" do
    exact = @body <> String.duplicate(" ", 65_536 - byte_size(@body))
    assert byte_size(exact) == 65_536
    assert_response(call_request(body: exact, content_length: "65536"), 202, "committed")

    overflow = exact <> " "
    assert_response(call_request(body: overflow, content_length: nil), 413, "too_large")
  end

  test "the reader passes bounded options, threads returned connections, and refuses no progress or errors" do
    {conn, body} = request(body: @body)
    split = div(byte_size(body), 2)
    first = binary_part(body, 0, split)
    second = binary_part(body, split, byte_size(body) - split)
    conn = use_reader(conn, [{:more, first}, {:ok, second}])
    response = WebhookIn.call(conn, WebhookIn.init(defaults()))
    assert_response(response, 202, "committed")
    assert_received {:read_options, first_options}
    assert_received {:read_options, second_options}

    for options <- [first_options, second_options] do
      assert options[:length] == 8192
      assert options[:read_length] == 8192
      assert options[:read_timeout] in 1..5000
    end

    for {steps, status, tag} <- [
          {[{:more, ""}], 408, "timeout"},
          {[:error_timeout], 408, "timeout"},
          {[:error_other], 400, "invalid"},
          {[{:ok, "partial"}], 401, "unauthorized"}
        ] do
      {conn, _} = request()
      response = WebhookIn.call(use_reader(conn, steps), WebhookIn.init(defaults()))
      assert_response(response, status, tag)
    end
  end

  test "body errors and a prior parsed body never invoke principal or admission" do
    parent = self()

    opts =
      defaults(
        principal: fn _ ->
          send(parent, :principal)
          {:ok, @scope}
        end
      )

    {conn, _} = request()
    parsed = %{conn | body_params: %{"already" => true}}
    assert_response(WebhookIn.call(parsed, WebhookIn.init(opts)), 400, "invalid")
    refute_received :principal

    {conn, _} = request()
    response = WebhookIn.call(use_reader(conn, [:error_other]), WebhookIn.init(opts))
    assert_response(response, 400, "invalid")
    refute_received :principal
  end

  test "a prior partial Plug read may remain observable only as a later authentication refusal" do
    {conn, _} = request()
    assert {:more, _partial, conn} = Plug.Conn.read_body(conn, length: 10)
    assert %Plug.Conn.Unfetched{aspect: :body_params} = conn.body_params

    response = WebhookIn.call(conn, WebhookIn.init(defaults()))
    assert_response(response, 401, "unauthorized")

    {conn, _} = request()
    assert {:ok, _body, conn} = Plug.Conn.read_body(conn)
    assert %Plug.Conn.Unfetched{aspect: :body_params} = conn.body_params
    assert_response(WebhookIn.call(conn, WebhookIn.init(defaults())), 401, "unauthorized")
  end

  test "a real 15-second monotonic read budget refusal occurs before principal or admission" do
    parent = self()

    opts =
      defaults(
        principal: fn _ ->
          send(parent, :principal)
          {:ok, @scope}
        end
      )

    {conn, _} = request()

    response =
      WebhookIn.call(use_reader(conn, [{:sleep, 15_050, :more, "{"}]), WebhookIn.init(opts))

    assert_response(response, 408, "timeout")
    refute_received :principal
  end

  test "principal delay beyond the real body budget prevents admission" do
    parent = self()

    opts =
      defaults(
        principal: fn _ ->
          send(parent, :principal_started)
          Process.sleep(15_250)
          {:ok, @scope}
        end,
        admit: fn _event, _scope ->
          send(parent, :admit)
          {:committed, 1}
        end
      )

    {conn, body} = request()
    response = WebhookIn.call(use_reader(conn, [{:ok, body}]), WebhookIn.init(opts))

    assert_response(response, 408, "timeout")
    assert Jason.decode!(response.resp_body)["event_id"] == "evt-1"
    assert_received :principal_started
    assert_received {:read_options, options}
    assert options[:read_timeout] in 1..5000
    refute_received :admit
  end

  test "slow trickling chunks share one monotonic budget and keep per-read bounds" do
    parent = self()

    opts =
      defaults(
        principal: fn _ ->
          send(parent, :principal)
          {:ok, @scope}
        end
      )

    {conn, body} = request()
    chunks = for <<chunk::binary-size(31) <- body>>, do: chunk
    remainder = binary_part(body, length(chunks) * 31, byte_size(body) - length(chunks) * 31)
    chunks = if remainder == "", do: chunks, else: chunks ++ [remainder]
    final_index = length(chunks) - 1

    steps =
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} ->
        result = if index == final_index, do: :ok, else: :more
        {:sleep, 4_010, result, chunk}
      end)

    response = WebhookIn.call(use_reader(conn, steps), WebhookIn.init(opts))
    assert_response(response, 408, "timeout")
    refute_received :principal

    timeouts =
      for _ <- 1..length(chunks) do
        assert_receive {:read_options, options}
        assert options[:length] == 8192
        assert options[:read_length] == 8192
        assert options[:read_timeout] in 1..5000
        options[:read_timeout]
      end

    assert List.last(timeouts) < 5000
  end

  defp defaults(overrides \\ []) do
    [
      source_id: @source_id,
      key: fn -> {:ok, @key} end,
      clock: fn -> @now end,
      principal: fn _conn -> {:ok, @scope} end,
      admit: fn event, _scope -> {:committed, event.expected_revision + 1} end
    ]
    |> Keyword.merge(overrides)
  end

  defp call_request(options) do
    {conn, _body} = request(options)
    config = Keyword.get(options, :config, defaults())
    WebhookIn.call(conn, WebhookIn.init(config))
  end

  defp request(options \\ []) do
    body = Keyword.get(options, :body, @body)
    source_id = Keyword.get(options, :source_id, @source_id)
    signing_key = Keyword.get(options, :signing_key, @key)
    timestamp = Keyword.get(options, :timestamp, Integer.to_string(@now))
    signature = Keyword.get(options, :signature, signature(source_id, signing_key, timestamp, body))
    method = Keyword.get(options, :method, "POST")
    path = Keyword.get(options, :path, "/elzoo/v1/messages")

    extra_headers = Keyword.get(options, :headers, [])

    content_length_headers =
      case Keyword.get(options, :content_length, :default) do
        :default -> [{"content-length", Integer.to_string(byte_size(body))}]
        nil -> []
        value -> [{"content-length", value}]
      end

    base_headers =
      [
        {"content-type", "application/json"},
        {"x-elzoo-timestamp", timestamp},
        {"x-elzoo-signature", signature}
      ] ++ content_length_headers

    extra_names = Enum.map(extra_headers, &elem(&1, 0))
    headers = Enum.reject(base_headers, fn {name, _} -> name in extra_names end) ++ extra_headers

    uri = path
    conn = Plug.Test.conn(method, uri, body)
    replaced_names = ["content-length" | Enum.map(headers, &elem(&1, 0))]

    kept =
      Enum.reject(conn.req_headers, fn {name, _} -> name in replaced_names end)

    {%{conn | req_headers: kept ++ headers}, body}
  end

  defp build_conn(options) do
    {conn, _body} = request(options)
    conn
  end

  defp use_reader(conn, steps) do
    state = %{owner: self(), steps: steps}
    %{conn | adapter: {Elzoo.WebhookInTest.ReadAdapter, state}}
  end

  defp signature(source_id, key, timestamp, body) do
    framed =
      "elzoo-webhook-v1\n" <>
        source_id <> "\nPOST\n/elzoo/v1/messages\n" <> timestamp <> "\n" <> body

    "v1=" <> Base.encode16(:crypto.mac(:hmac, :sha256, key, framed), case: :lower)
  end

  defp mac_signature(framed),
    do: "v1=" <> Base.encode16(:crypto.mac(:hmac, :sha256, @key, framed), case: :lower)

  defp valid_body(overrides) do
    Jason.encode!(%{
      "version" => 1,
      "event_id" => Keyword.get(overrides, :event_id, "evt-1"),
      "conversation_id" => Keyword.get(overrides, :conversation_id, "conv-1"),
      "input_id" => Keyword.get(overrides, :input_id, "input-1"),
      "expected_revision" => Keyword.get(overrides, :expected_revision, 0),
      "text" => Keyword.get(overrides, :text, "hello")
    })
  end

  defp assert_response(conn, status, tag) do
    assert conn.status == status
    assert conn.halted

    assert conn.resp_headers
           |> Enum.any?(fn {name, value} ->
             name == "content-type" and String.starts_with?(value, "application/json")
           end)

    body = Jason.decode!(conn.resp_body)
    assert body["status"] == tag
    assert byte_size(conn.resp_body) <= 512
  end
end
