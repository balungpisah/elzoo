# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/data_stream_test_helper.exs", __DIR__)

defmodule Elzoo.DataStream.SchemaTest do
  use ExUnit.Case, async: true
  alias Elzoo.DataStream.{Fixture, Protocol, Usage, Framer, Transport}
  alias Elzoo.AiModel.Usage, as: Core

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
end
