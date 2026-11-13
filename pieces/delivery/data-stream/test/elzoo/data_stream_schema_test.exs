# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/data_stream_test_helper.exs", __DIR__)

defmodule Elzoo.DataStream.SchemaTest do
  use ExUnit.Case, async: true
  alias Elzoo.DataStream.{Fixture, JSON, Protocol, Usage, Framer, Transport}
  alias Elzoo.AiModel.Usage, as: Core

  # ELZ-155. One text stream recorded from Anthropic's own endpoint; the facts
  # are in PROVENANCE.md beside it.
  @recording Path.expand("../fixtures/anthropic-direct-stream/text.sse", __DIR__)

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
  # The members that ELZ-151 named: the event, the path of the map that holds
  # them, and their names. Since ELZ-155 they are ignored as each other member
  # that the Piece does not read.
  @unread [
    {"message_start", ["message"], ~w(container stop_details)},
    {"message_start", ["message", "usage"], ~w(inference_geo server_tool_use service_tier speed)},
    {"content_block_start", ["content_block"], ~w(citations)},
    {"message_delta", [], ~w(context_management)},
    {"message_delta", ["delta"], ~w(container stop_details)},
    {"message_delta", ["usage"], ~w(inference_geo server_tool_use service_tier speed)}
  ]

  test "nested event schema, order, variants and finish reasons" do
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
    assert {:ok, _, :none} = plain = Protocol.event(s, "message_start", Fixture.start())

    # ELZ-155: a member that is not read is ignored. It was unsupported_response.
    for added <- [
          Map.put(Fixture.start(), "extra", 1),
          put_in(Fixture.start(), ["message", "extra"], 1)
        ] do
      assert Protocol.event(s, "message_start", added) == plain
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

    # ELZ-155: an event type that is not read is ignored and counted. It was
    # unsupported_response.
    assert Protocol.event(s, "new_event", %{"type" => "new_event"}) ==
             {:ok, %{s | index: s.index + 1}, :none}
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
    end

    # ELZ-155: a member that is not read is ignored in output_tokens_details.
    # In cache_creation it is a lifetime that is not read: the group is not
    # used. Both were unsupported_response.
    assert Usage.merge(r, %{"output_tokens_details" => %{"unknown" => 0}}) ==
             Usage.merge(r, %{"output_tokens_details" => %{}})

    assert Usage.merge(r, %{"output_tokens_details" => %{"unknown" => 0}}) == {:ok, r}

    assert Usage.merge(r, %{"cache_creation" => %{"unknown" => 0}}) ==
             {:ok, %{r | writes: [%{ttl: "provider_default", amount: :unknown}]}}

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

    # ELZ-155: a number with a fraction as the value of a member that is not
    # read is ignored. It was malformed_response.
    raw = String.replace(@derived["message_delta"], ~s("speed":"standard"), ~s("speed":1.5))
    assert raw != @derived["message_delta"]
    block = "event: message_delta\ndata: " <> raw <> "\n\n"

    assert Protocol.block(block, expecting("message_delta")) ==
             feed("message_delta", bare("message_delta"))
  end

  test "replaced rule: a member in no list and the OpenRouter members are ignored; a model text with / is refused" do
    # ELZ-155: each result of this test but the one of `model` was
    # unsupported_response, and the last one was malformed_response.
    for {name, path, _} <- @unread do
      assert {:ok, _, :none} = plain = feed(name, decoded(name))
      assert feed(name, put_in(decoded(name), path ++ ["extra"], nil)) == plain
    end

    start = decoded("message_start")

    assert feed("message_start", put_in(start, ["message", "provider"], "Anthropic")) ==
             feed("message_start", start)

    # A rule of a member that the Piece reads: it stays.
    assert {:error, :malformed_response, _} =
             feed(
               "message_start",
               put_in(start, ["message", "model"], "anthropic/claude-haiku-5.5")
             )

    for {name, path} <- [{"message_start", ["message", "usage"]}, {"message_delta", ["usage"]}],
        {member, value} <- [{"cost", 0}, {"is_byok", false}, {"cost_details", %{}}] do
      assert feed(name, put_in(decoded(name), path ++ [member], value)) ==
               feed(name, decoded(name))
    end

    # As recorded through OpenRouter, `cost` is a number with a fraction.
    raw =
      String.replace(
        @derived["message_delta"],
        ~s("speed":"standard"}),
        ~s("speed":"standard","cost":0.000049698})
      )

    assert raw != @derived["message_delta"]
    block = "event: message_delta\ndata: " <> raw <> "\n\n"

    assert Protocol.block(block, expecting("message_delta")) ==
             feed("message_delta", decoded("message_delta"))
  end

  test "direct_recording_replay: the recorded direct stream ends stopped at four piece sizes" do
    bytes = File.read!(@recording)
    assert byte_size(bytes) == 1_408

    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) ==
             "2d76b71a857ec16d5fec8bdbc4e90998c7e85fda3544b98fb32ae314a999362a"

    for n <- [1, 7, 97, 4_096] do
      assert {:halt, f, {s, text}} = replay(bytes, n, "claude-haiku-5-5")
      assert f.blocks == 8 and s.index == 8
      assert s.phase == :stopped and s.finish == :stop
      assert text == "Red\nOrange\nYellow"
      assert {:provider_reported, u} = s.incurred_usage
      assert Core.amount(u, :input_uncached_tokens) == 22
      assert Core.amount(u, :output_tokens) == 13
      assert Core.amount(u, :cache_read_tokens) == 0
      assert Core.sum(u.cache_writes) == 0
      assert Core.amount(u, :reasoning_tokens) == 0
      assert s.last_usage == %{usage: u, event_index: 6, stage: :message_delta}
      assert s.provenance.response_id == "msg_011Ch1BENb7LZPb4upBAsq3o"
      assert s.provenance.provider_model == "claude-haiku-5-5"
    end
  end

  test "unread_member_ignored: one added member with six kinds of value in each object that is read" do
    usage = %{
      "input_tokens" => 2,
      "output_tokens" => 2,
      "cache_read_input_tokens" => 0,
      "cache_creation_input_tokens" => 5,
      "cache_creation" => %{"ephemeral_5m_input_tokens" => 2, "ephemeral_1h_input_tokens" => 3},
      "output_tokens_details" => %{"thinking_tokens" => 0}
    }

    start = Fixture.start(usage)
    delta = Fixture.delta(usage)
    [block_start, block_delta, block_stop] = Fixture.text("hello")

    error = %{
      "type" => "error",
      "error" => %{"type" => "overloaded_error", "message" => "Overloaded"},
      "request_id" => "req_1"
    }

    # The events before, the event, and the path of each object of it that the
    # Piece reads. `cache_creation` has its own rule and its own test.
    cases = [
      {[], %{"type" => "ping"}, [[]]},
      {[], start,
       [[], ["message"], ["message", "usage"], ["message", "usage", "output_tokens_details"]]},
      {[start], block_start, [[], ["content_block"]]},
      {[start, block_start], block_delta, [[], ["delta"]]},
      {[start, block_start], block_stop, [[]]},
      {[start], delta, [[], ["delta"], ["usage"], ["usage", "output_tokens_details"]]},
      {[start, delta], Fixture.stop(), [[]]},
      {[start], error, [[], ["error"]]}
    ]

    # null, a text, an integer, a number with a fraction, an object and a list.
    values = [nil, "end_turn", 7, 0.5, %{"type" => "text", "input_tokens" => 9}, [1, "x", nil]]
    assert Fixture.wire([%{"type" => "ping", "extra" => 0.5}]) =~ ~s("extra":0.5)

    for {before, m, paths} <- cases, path <- paths do
      s = after_events(before)
      assert {:ok, _, _} = plain = Protocol.block(Fixture.wire([m]), s)

      for value <- values do
        added = put_in(m, path ++ ["extra"], value)
        assert Protocol.block(Fixture.wire([added]), s) == plain
      end
    end

    assert {:ok, _, {:text, "hello"}} =
             Protocol.block(Fixture.wire([block_delta]), after_events([start, block_start]))

    assert {:ok, %{provider_reason: :overloaded_error}, :stream_error} =
             Protocol.block(Fixture.wire([error]), after_events([start]))
  end

  test "unread_event_ignored: an unknown event type at four points gives no frame and the same end" do
    [a_start, a_delta, a_stop] = Fixture.text("one")

    [b_start, b_delta, b_stop] =
      Enum.map(Fixture.text("two"), &Map.put(&1, "index", 1))

    stream = [
      Fixture.start(),
      a_start,
      a_delta,
      a_stop,
      b_start,
      b_delta,
      b_stop,
      Fixture.delta(),
      Fixture.stop()
    ]

    unknown = %{"type" => "new_event", "index" => 0, "delta" => %{"text" => "lost?"}, "n" => 1.5}
    assert {:halt, plain_f, {plain, "onetwo"}} = replay(Fixture.wire(stream), 7, "claude-sonnet-5")
    assert plain.phase == :stopped and plain.index == 9 and plain_f.blocks == 9

    # Before message_start, inside an open block, between two blocks and after message_delta.
    for at <- [0, 2, 4, 8] do
      before = Enum.take(stream, at)
      s = after_events(before)
      assert Protocol.event(s, "new_event", unknown) == {:ok, %{s | index: s.index + 1}, :none}
      wire = Fixture.wire(List.insert_at(stream, at, unknown))
      assert {:halt, f, {ended, "onetwo"}} = replay(wire, 7, "claude-sonnet-5")
      # It counts as one event, as ping does; nothing else differs.
      assert f.blocks == 10 and ended.index == 10
      counted = if at < 8, do: 1, else: 0
      assert ended.last_usage.event_index == plain.last_usage.event_index + counted

      assert %{ended | index: plain.index, last_usage: plain.last_usage} == plain
    end

    s = after_events([Fixture.start(), a_start])

    for data <- [
          ~s([{"type":"new_event"}]),
          ~s("new_event"),
          "7",
          "null",
          "{",
          "{}",
          ~s({"type":null}),
          ~s({"type":"other_event"}),
          ~s({"type":"ping"}),
          ~s({"type":"new_event","type":"new_event"})
        ] do
      block = "event: new_event\ndata: " <> data <> "\n\n"
      assert {:error, :malformed_response, _} = Protocol.block(block, s)
    end

    # After the stop no event is accepted, as it is for ping.
    for name <- ["ping", "new_event"] do
      assert {:error, :malformed_response} = Protocol.event(plain, name, %{"type" => name})
    end
  end

  test "number_rule: a fraction or an exponent is accepted up to 64 bytes and is no integer" do
    s = expecting("message_delta")

    data = fn member ->
      ~s({"type":"message_delta","delta":{"stop_reason":"end_turn"},) <>
        ~s("usage":{"output_tokens":5#{member}}})
    end

    block = fn name, data -> "event: " <> name <> "\ndata: " <> data <> "\n\n" end

    assert {:ok, %{finish: :stop}, :none} =
             plain = Protocol.block(block.("message_delta", data.("")), s)

    # At the bound: 64 bytes, with a fraction, with an exponent and with a sign.
    at_bound = [
      "0." <> String.duplicate("1", 62),
      "1" <> String.duplicate("0", 60) <> "e-1",
      "-0." <> String.duplicate("1", 61)
    ]

    for lexeme <- ~w(0.000049698 -1.5 1e2 1E+2 2.5e-3 0.0 12345678901234567890.5) ++ at_bound do
      assert byte_size(lexeme) <= 64
      added = block.("message_delta", data.(~s(,"cost":#{lexeme})))
      assert Protocol.block(added, s) == plain
    end

    # One byte more than the bound, and a value above the range of a double.
    for lexeme <- Enum.map(at_bound, &(&1 <> "1")) ++ ["1e309"] do
      assert byte_size(lexeme) == 65 or lexeme == "1e309"
      added = block.("message_delta", data.(~s(,"cost":#{lexeme})))
      assert {:error, :malformed_response, _} = Protocol.block(added, s)
    end

    # The bound of an integer stays: 19 digits, also in a member that is not read.
    nineteen = String.duplicate("9", 19)
    assert Protocol.block(block.("message_delta", data.(~s(,"extra":#{nineteen}))), s) == plain
    assert Protocol.block(block.("message_delta", data.(~s(,"extra":-#{nineteen}))), s) == plain

    assert {:error, :malformed_response, _} =
             Protocol.block(block.("message_delta", data.(~s(,"extra":#{nineteen}9))), s)

    # A member that is read as an integer refuses a number that is not an
    # integer. The same event with the integer 22 passes: only the number differs.
    counted = %{"output_tokens" => 5}

    for {name, m} <- [
          {"message_start", Fixture.start(counted)},
          {"message_delta", Fixture.delta(counted)}
        ] do
      raw = fn lexeme ->
        String.replace(Fixture.wire([m]), ~s("usage":{), ~s("usage":{"input_tokens":#{lexeme},))
      end

      assert raw.("22") =~ ~s("usage":{"input_tokens":22,"output_tokens":5})

      assert {:ok, %{last_usage: %{usage: u}}, :none} =
               Protocol.block(raw.("22"), expecting(name))

      assert Core.amount(u, :input_uncached_tokens) == 22

      for lexeme <- ~w(22.0 22.5 2.2e1 22e0 -0.0) do
        assert {:error, :malformed_response, _} = Protocol.block(raw.(lexeme), expecting(name))
      end
    end

    [block_start, block_delta, block_stop] = Fixture.text("hello")
    open = after_events([Fixture.start(), block_start])

    for {m, state} <- [
          {block_start, expecting("content_block_start")},
          {block_delta, open},
          {block_stop, open}
        ],
        lexeme <- ~w(0.0 0e0 0.5 -0.0) do
      raw = String.replace(Fixture.wire([m]), ~s("index":0), ~s("index":#{lexeme}))
      assert raw =~ ~s("index":#{lexeme})
      assert {:ok, _, _} = Protocol.block(Fixture.wire([m]), state)
      assert {:error, :malformed_response, _} = Protocol.block(raw, state)
    end

    # The request decoder is not changed: it refuses a fraction and an exponent.
    for lexeme <- ~w(1.0 1e2 0.5) do
      assert {:error, :invalid_json} = JSON.decode(~s({"n":#{lexeme}}))
      assert {:ok, %{"n" => n}} = JSON.decode_event(~s({"n":#{lexeme}}))
      assert is_float(n)
    end
  end

  test "cache_creation_unread_member: a lifetime that is not read leaves the group unused" do
    {:ok, old} =
      Usage.merge(Usage.new(), %{
        "cache_creation" => %{"ephemeral_5m_input_tokens" => 2, "ephemeral_1h_input_tokens" => 3}
      })

    assert old.writes == [%{ttl: "1h", amount: 3}, %{ttl: "5m", amount: 2}]

    for extra <- [4, nil, "4", 0.5, %{}, []],
        read <- [
          %{"ephemeral_5m_input_tokens" => 2, "ephemeral_1h_input_tokens" => 3},
          %{"ephemeral_5m_input_tokens" => 2},
          %{}
        ] do
      group = Map.put(read, "ephemeral_2h_input_tokens", extra)

      # With the total: provider_default with its amount.
      assert {:ok, r} =
               Usage.merge(old, %{"cache_creation_input_tokens" => 9, "cache_creation" => group})

      assert r.writes == [%{ttl: "provider_default", amount: 9}]
      {:ok, u} = Usage.value(r)
      assert Core.sum(u.cache_writes) == 9

      # With the total absent, and with the total null: unknown.
      for total <- [%{}, %{"cache_creation_input_tokens" => nil}] do
        assert {:ok, r} = Usage.merge(old, Map.put(total, "cache_creation", group))
        assert r.writes == [%{ttl: "provider_default", amount: :unknown}]
      end
    end

    # The two members that are read keep their type rule.
    for invalid <- [-1, 1.0, "1", 9_223_372_036_854_775_808],
        k <- ["ephemeral_5m_input_tokens", "ephemeral_1h_input_tokens"] do
      group = %{k => invalid, "ephemeral_2h_input_tokens" => 4}

      assert {:error, :malformed_response} =
               Usage.merge(old, %{"cache_creation_input_tokens" => 9, "cache_creation" => group})
    end

    # Through one event: the total of the same usage object is the amount.
    usage = %{
      "input_tokens" => 2,
      "cache_read_input_tokens" => 1,
      "cache_creation_input_tokens" => 9,
      "cache_creation" => %{"ephemeral_5m_input_tokens" => 4, "ephemeral_2h_input_tokens" => 5}
    }

    assert {:ok, %{last_usage: %{usage: u}}, :none} = feed("message_start", Fixture.start(usage))
    assert u.cache_writes == [%{ttl: "provider_default", amount: 9}]
    assert Core.prompt_input_tokens(u) == 12
  end

  test "rules_kept: variants, stop_sequence, the error event and the bounds" do
    [block_start, block_delta, block_stop] = Fixture.text("hello")
    start = Fixture.start()
    content = after_events([start])
    open = after_events([start, block_start])

    # A content block that is not text, with the members of its own kind.
    for block <- [
          %{"type" => "tool_use", "id" => "toolu_1", "name" => "get", "input" => %{}},
          %{"type" => "thinking", "thinking" => "", "signature" => ""},
          %{"type" => "tool_use"},
          %{"type" => "tool_use", "text" => ""}
        ] do
      assert {:error, :unsupported_response} =
               Protocol.event(content, "content_block_start", %{
                 block_start
                 | "content_block" => block
               })
    end

    # A delta that is not text_delta.
    for delta <- [
          %{"type" => "input_json_delta", "partial_json" => "{"},
          %{"type" => "thinking_delta", "thinking" => "x"},
          %{"type" => "citations_delta", "citation" => %{}},
          %{"type" => "input_json_delta"},
          %{"type" => "thinking_delta", "text" => "x"}
        ] do
      assert {:error, :unsupported_response} =
               Protocol.event(open, "content_block_delta", %{block_delta | "delta" => delta})
    end

    # A read member that is absent or of a wrong type is still malformed.
    for {name, bad} <- [
          {"content_block_start", put_in(block_start, ["content_block"], %{"text" => ""})},
          {"content_block_start", put_in(block_start, ["content_block"], %{"type" => "text"})},
          {"content_block_start", put_in(block_start, ["content_block", "text"], 5)},
          {"content_block_start", Map.delete(block_start, "index")},
          {"content_block_start", Map.put(block_start, "index", 1)},
          {"message_delta", Map.delete(Fixture.delta(), "delta")},
          {"message_delta", Map.put(Fixture.delta(), "delta", [])},
          {"message_delta", Map.put(Fixture.delta(), "usage", [])}
        ] do
      assert {:error, :malformed_response} = Protocol.event(content, name, bad)
    end

    for {name, bad} <- [
          {"content_block_delta", put_in(block_delta, ["delta"], %{"text" => "x"})},
          {"content_block_delta", put_in(block_delta, ["delta"], %{"type" => "text_delta"})},
          {"content_block_delta", put_in(block_delta, ["delta", "text"], nil)},
          {"content_block_delta", Map.put(block_delta, "index", 1)},
          {"content_block_stop", Map.delete(block_stop, "index")}
        ] do
      assert {:error, :malformed_response} = Protocol.event(open, name, bad)
    end

    new = Protocol.new("claude-sonnet-5", :absent)

    for bad <- [
          Map.delete(start, "message"),
          update_in(start, ["message"], &Map.delete(&1, "stop_reason")),
          update_in(start, ["message"], &Map.delete(&1, "stop_sequence")),
          update_in(start, ["message"], &Map.delete(&1, "content")),
          put_in(start, ["message", "stop_sequence"], "END"),
          put_in(start, ["message", "role"], "user"),
          put_in(start, ["message", "content"], [%{"type" => "text", "text" => ""}])
        ] do
      assert {:error, :malformed_response} = Protocol.event(new, "message_start", bad)
    end

    # A stop_sequence that is not null in the delta of message_delta.
    for value <- ["END", "", 0, false] do
      assert {:error, :unsupported_response} =
               Protocol.event(
                 content,
                 "message_delta",
                 put_in(Fixture.delta(), ["delta", "stop_sequence"], value)
               )
    end

    assert {:ok, %{finish: :stop}, :none} =
             Protocol.event(
               content,
               "message_delta",
               put_in(Fixture.delta(), ["delta", "stop_sequence"], nil)
             )

    # The error event ends the stream at each point before the stop, and its
    # read members keep their checks.
    error = %{"type" => "error", "error" => %{"type" => "overloaded_error", "message" => "x"}}

    for s <- [new, content, open, after_events([start, Fixture.delta()])] do
      assert {:ok, %{provider_reason: :overloaded_error}, :stream_error} =
               Protocol.event(s, "error", error)
    end

    assert {:ok, %{provider_reason: :provider_error}, :stream_error} =
             Protocol.event(content, "error", put_in(error, ["error", "type"], "new_error"))

    assert {:ok, _, :stream_error} =
             Protocol.event(content, "error", Map.put(error, "request_id", "req_1"))

    for bad <- [
          Map.delete(error, "error"),
          Map.put(error, "error", "overloaded_error"),
          update_in(error, ["error"], &Map.delete(&1, "type")),
          update_in(error, ["error"], &Map.delete(&1, "message")),
          put_in(error, ["error", "type"], "two words"),
          put_in(error, ["error", "type"], String.duplicate("e", 65)),
          put_in(error, ["error", "message"], nil),
          put_in(error, ["error", "message"], String.duplicate("m", 16_385)),
          Map.put(error, "request_id", "bad id"),
          Map.put(error, "request_id", nil)
        ] do
      assert {:error, :malformed_response} = Protocol.event(content, "error", bad)
    end

    # The bound of one text and the count of blocks.
    assert {:ok, _, {:text, _}} =
             Protocol.event(
               open,
               "content_block_delta",
               put_in(block_delta, ["delta", "text"], String.duplicate("t", 65_536))
             )

    assert {:error, :malformed_response} =
             Protocol.event(
               open,
               "content_block_delta",
               put_in(block_delta, ["delta", "text"], String.duplicate("t", 65_537))
             )

    full =
      Enum.reduce(0..63, content, fn n, s ->
        {:ok, s, :none} = Protocol.event(s, "content_block_start", %{block_start | "index" => n})
        {:ok, s, :none} = Protocol.event(s, "content_block_stop", %{block_stop | "index" => n})
        s
      end)

    assert full.next == 64

    assert {:error, :malformed_response} =
             Protocol.event(full, "content_block_start", %{block_start | "index" => 64})

    # The bounds of the decoder hold inside a member that is not read: the
    # depth, the length of an integer and a duplicate key at any depth.
    ping = fn value -> ~s(event: ping\ndata: {"type":"ping","extra":#{value}}\n\n) end
    nest = fn n -> String.duplicate("[", n) <> String.duplicate("]", n) end
    assert {:ok, _, :none} = Protocol.block(ping.(nest.(15)), new)
    assert {:ok, _, :none} = Protocol.block(ping.(~s({"a":{"b":1,"c":2}})), new)

    for value <- [
          nest.(16),
          String.duplicate("9", 20),
          ~s({"a":1,"a":2}),
          ~s([{"a":{"x":1,"\\u0078":2}}])
        ] do
      assert {:error, :malformed_response, _} = Protocol.block(ping.(value), new)
    end
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

  # The state after the listed events.
  defp after_events(events) do
    Enum.reduce(events, Protocol.new("claude-sonnet-5", :absent), fn m, s ->
      {:ok, s, _} = Protocol.event(s, m["type"], m)
      s
    end)
  end

  # Feeds the bytes through Framer and Protocol in pieces of n bytes and joins
  # the text of the actions.
  defp replay(bytes, n, model) do
    cb = fn block, {s, text} ->
      case Protocol.block(block, s) do
        {:ok, p} -> {:ok, {p, text}}
        {:ok, p, :stop} -> {:halt, {p, text}}
        {:ok, p, {:text, more}} -> {:ok, {p, text <> more}}
        {:ok, p, _} -> {:ok, {p, text}}
        {:error, r, p} -> {:error, r, {p, text}}
      end
    end

    pieces = for <<part::binary-size(^n) <- bytes>>, do: part
    tail = binary_part(bytes, byte_size(bytes) - rem(byte_size(bytes), n), rem(byte_size(bytes), n))
    start = {:ok, Framer.new(), {Protocol.new(model, :absent), ""}}

    Enum.reduce_while(pieces ++ [tail], start, fn part, {:ok, f, acc} ->
      case Framer.feed(f, part, acc, cb) do
        {:ok, f, acc} -> {:cont, {:ok, f, acc}}
        done -> {:halt, done}
      end
    end)
  end
end
