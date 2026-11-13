# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/data_stream_test_helper.exs", __DIR__)

defmodule Elzoo.DataStream.SchemaTest do
  use ExUnit.Case, async: true
  alias Elzoo.DataStream.{Fixture, JSON, Protocol, Usage, Framer, Transport}
  alias Elzoo.AiModel.Usage, as: Core

  # ELZ-151. Derived data, not a recording; no test reads a file of another
  # Piece. These are the `data` lines of the message_start, the text
  # content_block_start and the message_delta event of one text stream that was
  # recorded on 2026-11-13 through OpenRouter's Anthropic-compatible endpoint,
  # routed to Anthropic. Only the OpenRouter differences are removed: the member
  # `provider` of the message; the `anthropic/` prefix and the `.` form of
  # `model` (here the model ID of the test settings); `cost`, `is_byok` and
  # `cost_details` of `usage`.
  @derived %{
    "message_start" =>
      ~s({"type":"message_start","message":{"id":"msg_011CgzXnzKALMgLi5HCHiogj",) <>
        ~s("type":"message","role":"assistant","container":null,"content":[],) <>
        ~s("model":"claude-sonnet-5","stop_reason":null,"stop_details":null,) <>
        ~s("stop_sequence":null,"usage":{"input_tokens":37,"output_tokens":3,) <>
        ~s("output_tokens_details":null,"cache_creation_input_tokens":0,) <>
        ~s("cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,) <>
        ~s("ephemeral_1h_input_tokens":0},"inference_geo":"global","server_tool_use":null,) <>
        ~s("service_tier":"standard","speed":"standard"}}}),
    "content_block_start" =>
      ~s({"type":"content_block_start","index":0,) <>
        ~s("content_block":{"type":"text","text":"","citations":[]}}),
    "message_delta" =>
      ~s({"type":"message_delta","delta":{"container":null,"stop_details":null,) <>
        ~s("stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":37,) <>
        ~s("output_tokens":93,"output_tokens_details":{"thinking_tokens":0},) <>
        ~s("cache_creation_input_tokens":0,"cache_read_input_tokens":0,) <>
        ~s("cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},) <>
        ~s("server_tool_use":null,"service_tier":"standard","speed":"standard"},) <>
        ~s("context_management":null})
  }
  # The members that are allowed and never read: the event, the path of the map
  # that one accepted list checks, and the names that the list gained.
  @unread [
    {"message_start", ["message"], ~w(container stop_details)},
    {"message_start", ["message", "usage"], ~w(inference_geo server_tool_use service_tier speed)},
    {"content_block_start", ["content_block"], ~w(citations)},
    {"message_delta", [], ~w(context_management)},
    {"message_delta", ["delta"], ~w(container stop_details)},
    {"message_delta", ["usage"], ~w(inference_geo server_tool_use service_tier speed)}
  ]

  test "exact nested event schema, order, variants and finish reasons" do
    for {reason, expected} <- [
          {"end_turn", :stop},
          {"max_tokens", :length},
          {"refusal", :refusal},
          {"model_context_window_exceeded", :context_limit}
        ] do
      s = Protocol.new("claude-sonnet-5", :absent)
      {:ok, s, :none} = Protocol.event(s, "message_start", Fixture.start())
      {:ok, s, :none} = Protocol.event(s, "message_delta", Fixture.delta(%{}, reason))

      assert {:ok, %{finish: ^expected, phase: :stopped}, :stop} =
               Protocol.event(s, "message_stop", Fixture.stop())
    end

    s = Protocol.new("claude-sonnet-5", :absent)

    for bad <- [
          Map.put(Fixture.start(), "extra", 1),
          put_in(Fixture.start(), ["message", "extra"], 1)
        ] do
      assert {:error, :unsupported_response} = Protocol.event(s, "message_start", bad)
    end

    for bad <- [
          put_in(Fixture.start(), ["message", "stop_reason"], "end_turn"),
          put_in(Fixture.start(), ["message", "id"], String.duplicate("i", 129)),
          put_in(Fixture.start(), ["message", "usage", "output_tokens"], -1)
        ] do
      assert {:error, :malformed_response} = Protocol.event(s, "message_start", bad)
    end

    assert {:error, :malformed_response} = Protocol.event(s, "message_stop", Fixture.stop())
    {:ok, s, :none} = Protocol.event(s, "message_start", Fixture.start())
    assert {:error, :malformed_response} = Protocol.event(s, "message_start", Fixture.start())
    assert {:error, :malformed_response} = Protocol.event(s, "message_stop", Fixture.stop())
    [start, delta, stop] = Fixture.text("hello")
    assert {:error, :malformed_response} = Protocol.event(s, "content_block_delta", delta)

    assert {:error, :unsupported_response} =
             Protocol.event(
               s,
               "content_block_start",
               put_in(start, ["content_block", "type"], "thinking")
             )

    {:ok, s, :none} = Protocol.event(s, "content_block_start", start)
    assert {:error, :malformed_response} = Protocol.event(s, "message_delta", Fixture.delta())

    assert {:error, :malformed_response} =
             Protocol.event(s, "content_block_stop", %{stop | "index" => 1})

    assert {:ok, _, {:text, ""}} =
             Protocol.event(s, "content_block_delta", put_in(delta, ["delta", "text"], ""))

    {:ok, s, :none} = Protocol.event(s, "content_block_stop", stop)

    for reason <- ["tool_use", "pause_turn", "stop_sequence", "other"] do
      assert {:error, :unsupported_response} =
               Protocol.event(s, "message_delta", Fixture.delta(%{}, reason))
    end

    {:ok, s, :none} = Protocol.event(s, "message_delta", Fixture.delta(%{}, nil))
    assert {:error, :malformed_response} = Protocol.event(s, "content_block_start", start)
    assert {:error, :malformed_response} = Protocol.event(s, "message_stop", Fixture.stop())
    assert {:error, :malformed_response} = Protocol.event(s, "ping", %{"type" => "message_stop"})

    assert {:error, :unsupported_response} =
             Protocol.event(s, "new_event", %{"type" => "new_event"})
  end

  test "cumulative components and exact nested null/omission rules" do
    raw = %{
      "input_tokens" => 2,
      "output_tokens" => 2,
      "cache_read_input_tokens" => 0,
      "cache_creation_input_tokens" => 5,
      "cache_creation" => %{"ephemeral_5m_input_tokens" => 2, "ephemeral_1h_input_tokens" => 3},
      "output_tokens_details" => %{"thinking_tokens" => 0}
    }

    {:ok, r} = Usage.merge(Usage.new(), raw)
    {:ok, u} = Usage.value(r)
    assert Core.prompt_input_tokens(u) == 7
    {:ok, r} = Usage.merge(r, %{"output_tokens" => 5})
    {:ok, u} = Usage.value(r)
    assert Core.amount(u, :output_tokens) == 5
    assert Core.amount(u, :input_uncached_tokens) == 2
    assert Core.sum(u.cache_writes) == 5
    {:ok, r} = Usage.merge(r, %{"cache_creation" => %{}})
    {:ok, u} = Usage.value(r)
    assert Core.sum(u.cache_writes) == :unknown
    {:ok, r} = Usage.merge(r, %{"cache_creation_input_tokens" => 10})
    assert r.writes == [%{ttl: "provider_default", amount: 10}]
    {:ok, r} = Usage.merge(r, %{"cache_creation" => %{"ephemeral_5m_input_tokens" => 2}})
    assert r.writes == [%{ttl: "provider_default", amount: :unknown}]

    {:ok, r} =
      Usage.merge(r, %{
        "cache_creation_input_tokens" => 10,
        "cache_creation" => %{"ephemeral_5m_input_tokens" => 2, "ephemeral_1h_input_tokens" => 3}
      })

    assert r.writes == [%{ttl: "provider_default", amount: :unknown}]
    {:ok, r} = Usage.merge(r, %{"output_tokens_details" => %{}})
    assert r.reasoning == :unknown

    {:ok, r} =
      Usage.merge(r, %{
        "input_tokens" => nil,
        "cache_creation" => nil,
        "output_tokens_details" => nil
      })

    assert r.input == :unknown and r.output == 5 and r.reasoning == :unknown
    {:ok, r} = Usage.merge(r, nil)
    assert r == Usage.new()

    for invalid <- [-1, 1.0, "1", 9_223_372_036_854_775_808] do
      assert {:error, :malformed_response} = Usage.merge(r, %{"output_tokens" => invalid})
    end

    for k <- ["cache_creation", "output_tokens_details"] do
      assert {:error, :malformed_response} = Usage.merge(r, %{k => []})
      assert {:error, :unsupported_response} = Usage.merge(r, %{k => %{"unknown" => 0}})
    end

    assert {:error, :unsupported_response} =
             Usage.merge(r, %{"output_tokens_details" => %{"thinking_tokens" => 1}})

    assert {:error, :malformed_response} =
             Usage.merge(r, %{
               "input_tokens" => 9_223_372_036_854_775_807,
               "cache_read_input_tokens" => 1,
               "cache_creation_input_tokens" => 0
             })
  end

  test "last observation index counts validated events and interim output is unknown at stop" do
    s = Protocol.new("claude-sonnet-5", :absent)
    {:ok, s, :none} = Protocol.event(s, "ping", %{"type" => "ping"})
    {:ok, s, :none} = Protocol.event(s, "message_start", Fixture.start())
    assert s.last_usage.event_index == 1
    {:ok, s, :none} = Protocol.event(s, "message_delta", Map.delete(Fixture.delta(), "usage"))
    assert s.last_usage.stage == :message_start
    {:ok, s, :stop} = Protocol.event(s, "message_stop", Fixture.stop())
    {:provider_reported, u} = s.incurred_usage
    assert Core.amount(u, :output_tokens) == :unknown
    assert Core.amount(s.last_usage.usage, :output_tokens) == 2
  end

  test "no synthetic completion on EOF, split UTF8 and real CR delimiters" do
    cb = fn block, s ->
      case Protocol.block(block, s) do
        {:ok, p} -> {:ok, p}
        {:ok, p, :stop} -> {:halt, p}
        {:ok, p, :none} -> {:ok, p}
        {:error, r, p} -> {:error, r, p}
      end
    end

    wire = <<239, 187, 191>> <> Fixture.wire([Fixture.start(), Fixture.delta(), Fixture.stop()])

    for ending <- ["\n", "\r", "\r\n"] do
      bytes = String.replace(wire, "\n", ending)

      for n <- 0..byte_size(bytes) do
        a = binary_part(bytes, 0, n)
        b = binary_part(bytes, n, byte_size(bytes) - n)
        result = Framer.feed(Framer.new(), a, Protocol.new("claude-sonnet-5", :absent), cb)

        result =
          case result do
            {:ok, f, s} -> Framer.feed(f, b, s, cb)
            done -> done
          end

        result =
          case result do
            {:ok, f, s} -> Framer.eof(f, s, cb)
            done -> done
          end

        assert {:halt, _, %{phase: :stopped}} = result
      end
    end

    for fragment <- [
          String.trim_trailing(wire, "\n"),
          Fixture.wire([Fixture.start(), Fixture.delta()]),
          "event: message_stop\ndata: {\"type\":\"message_stop\"}",
          <<239, 187>>,
          <<255>>
        ] do
      result = Framer.feed(Framer.new(), fragment, Protocol.new("claude-sonnet-5", :absent), cb)

      result =
        case result do
          {:ok, f, s} -> Framer.eof(f, s, cb)
          done -> done
        end

      refute match?({:halt, _, %{phase: :stopped}}, result)
    end
  end

  test "empty/comment event ceiling and parser-independent whole-block guard" do
    cb = fn _, n -> {:ok, n + 1} end
    assert {:ok, f, 65_536} = Framer.feed(Framer.new(), String.duplicate("\n", 65_536), 0, cb)
    assert {:error, :event_limit, _, 65_536} = Framer.feed(f, "\n", 65_536, cb)

    assert {:error, :block_limit, _, 0} =
             Framer.feed(Framer.new(), ":" <> String.duplicate("x", 65_534) <> "\n\n", 0, cb)

    assert {:error, :block_limit, _, 0} =
             Framer.feed(
               Framer.new(),
               "unknown: " <> String.duplicate("x", 65_536) <> "\n\n",
               0,
               cb
             )
  end

  test "closed HTTP status mapping includes empty bodies and never depends on body" do
    for {status, tag} <- [
          {400, :provider_invalid_request},
          {401, :authentication_failed},
          {402, :billing_error},
          {403, :permission_denied},
          {404, :not_found},
          {409, :conflict},
          {413, :provider_too_large},
          {429, :throttled},
          {504, :provider_timeout},
          {529, :overloaded},
          {500, :provider_error},
          {302, :provider_error},
          {201, :provider_error}
        ] do
      assert {:error, ^tag, :unknown} = Transport.headers(status, %{})
    end

    assert {:ok, :absent, :unknown} =
             Transport.headers(200, %{"content-type" => ["text/event-stream; charset=UTF-8"]})

    for headers <- [
          %{},
          %{"content-type" => ["text/event-stream", "text/event-stream"]},
          %{"content-type" => ["text/event-stream"], "content-encoding" => ["gzip"]},
          %{"content-type" => ["text/event-stream"], "request-id" => ["bad id"]},
          %{"content-type" => ["text/event-stream; charset=utf-8; other=x"]}
        ] do
      assert {:error, :malformed_response, _} = Transport.headers(200, headers)
    end

    for {v, n} <- [
          {"0", 0},
          {"86400", 86_400},
          {"86401", :unknown},
          {"-1", :unknown},
          {"1.0", :unknown},
          {"Thu, 01 Jan", :unknown}
        ] do
      assert {:error, :throttled, ^n} = Transport.headers(429, %{"retry-after" => [v]})
    end
  end

  test "derived message_start passes; container, stop_details and its usage members are not read" do
    assert {:ok, %{phase: :content, finish: nil} = s, :none} = derived("message_start")
    assert s.provenance.response_id == "msg_011CgzXnzKALMgLi5HCHiogj"
    assert s.provenance.provider_model == "claude-sonnet-5"
    assert s.last_usage.stage == :message_start
    assert Core.prompt_input_tokens(s.last_usage.usage) == 37
    assert Core.amount(s.last_usage.usage, :output_tokens) == 3
  end

  test "derived text content_block_start passes; citations is not read" do
    assert {:ok, %{phase: :content, open: 0, next: 1}, :none} = derived("content_block_start")
  end

  test "derived message_delta passes; context_management, container and stop_details are not read" do
    assert {:ok, %{phase: :delta, finish: :stop} = s, :none} = derived("message_delta")
    assert s.last_usage.stage == :message_delta
    assert Core.amount(s.last_usage.usage, :output_tokens) == 93
    assert Core.amount(s.last_usage.usage, :reasoning_tokens) == 0
  end

  test "each allowed member alone holds any JSON value and changes neither state nor action" do
    values = [nil, true, 0, -1, "max_tokens", [], [%{"a" => [nil]}], %{"output_tokens" => 9}]

    for {name, path, members} <- @unread, member <- members, value <- values do
      assert {:ok, _, :none} = without = feed(name, bare(name))
      assert feed(name, put_in(bare(name), path ++ [member], value)) == without
    end

    # Every bound stays: a number with a fraction is refused before a map
    # exists, also as the value of a member that is never read.
    raw = String.replace(@derived["message_delta"], ~s("speed":"standard"), ~s("speed":1.5))
    assert raw != @derived["message_delta"]
    block = "event: message_delta\ndata: " <> raw <> "\n\n"
    assert {:error, :malformed_response, _} = Protocol.block(block, expecting("message_delta"))
  end

  test "rule kept: a member in no list is unsupported and the OpenRouter differences are refused" do
    for {name, path, _} <- @unread do
      assert {:ok, _, :none} = feed(name, decoded(name))

      assert {:error, :unsupported_response, _} =
               feed(name, put_in(decoded(name), path ++ ["extra"], nil))
    end

    start = decoded("message_start")

    assert {:error, :unsupported_response, _} =
             feed("message_start", put_in(start, ["message", "provider"], "Anthropic"))

    assert {:error, :malformed_response, _} =
             feed(
               "message_start",
               put_in(start, ["message", "model"], "anthropic/claude-haiku-5.5")
             )

    for {name, path} <- [{"message_start", ["message", "usage"]}, {"message_delta", ["usage"]}],
        {member, value} <- [{"cost", 0}, {"is_byok", false}, {"cost_details", %{}}] do
      assert {:error, :unsupported_response, _} =
               feed(name, put_in(decoded(name), path ++ [member], value))
    end

    # As recorded, `cost` is a number with a fraction: the JSON bound refuses it first.
    raw =
      String.replace(
        @derived["message_delta"],
        ~s("speed":"standard"}),
        ~s("speed":"standard","cost":0.000049698})
      )

    assert raw != @derived["message_delta"]
    block = "event: message_delta\ndata: " <> raw <> "\n\n"
    assert {:error, :malformed_response, _} = Protocol.block(block, expecting("message_delta"))
  end

  # The state in which Protocol expects the event, built from the ELZ-101 fixtures.
  defp expecting("message_start"), do: Protocol.new("claude-sonnet-5", :absent)

  defp expecting(_) do
    {:ok, s, :none} = Protocol.event(expecting("message_start"), "message_start", Fixture.start())
    s
  end

  defp decoded(name) do
    {:ok, m} = JSON.decode(@derived[name])
    m
  end

  defp feed(name, m), do: Protocol.block(Fixture.wire([m]), expecting(name))

  # The derived event without the members that @unread names for it.
  defp bare(name) do
    for {^name, path, members} <- @unread, reduce: decoded(name) do
      m when path == [] -> Map.drop(m, members)
      m -> update_in(m, path, &Map.drop(&1, members))
    end
  end

  # Feeds the derived text of one event as one raw block. The same event without
  # the named members must give the same state and the same action.
  defp derived(name) do
    block = "event: " <> name <> "\ndata: " <> @derived[name] <> "\n\n"
    result = Protocol.block(block, expecting(name))
    assert result == feed(name, bare(name))
    result
  end
end
