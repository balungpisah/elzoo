# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/provider_stream_test_helper.exs", __DIR__)

defmodule Elzoo.ProviderStreamTest do
  # The recorded streams were recorded through OpenRouter's Anthropic-compatible
  # endpoint, routed to Anthropic, except the one of `direct_recording`, which
  # came from Anthropic's own endpoint (see the PROVENANCE.md of each fixture
  # directory). They are Monitored observations replayed by a loopback peer,
  # not the provider's Contract. Each case below runs over real HTTP/1.1
  # against that peer.
  use ExUnit.Case, async: true
  alias Elzoo.AiModel.{StreamChunk, Usage}
  alias Elzoo.ProviderStream.{Chunk, Fixture, Peer, Protocol}

  # Hand-built, not recorded: an `error` event in the format of Anthropic's
  # "Streaming messages" page (Error events). No such event was recorded.
  @hand_built_error ~s(event: error\ndata: {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}\n\n)

  defp texts(frames), do: for(%{chunk: %{kind: :text_delta, payload: t}} <- frames, do: t)

  defp kinds(frames), do: Enum.map(frames, & &1.chunk.kind)

  describe "text_only" do
    test "text frames in order, each acknowledged before the next, then complete" do
      origin = Peer.start(Fixture.whole(Fixture.read("text.sse")))

      task =
        Fixture.run(
          Fixture.read("text.ai-text.json"),
          Fixture.holding_sink(),
          Fixture.settings(),
          origin
        )

      frames = Fixture.release(25, fn _ -> 20 end)
      assert {:complete, result} = Task.await(task)

      assert_receive {:request, ^origin, head, body}
      assert head =~ ~r/\APOST \/v1\/messages HTTP\/1.1\r\n/
      assert Jason.decode!(body) == Fixture.upstream("text")
      refute_receive {:request, _, _, _}, 100

      assert Enum.map(frames, & &1.seq) == Enum.to_list(0..24)
      assert Enum.all?(frames, &(&1.chunk.seq == &1.seq))
      assert Enum.join(texts(frames)) == result.content

      for f <- frames do
        assert {:ok, _} = StreamChunk.validate(f.chunk)
        assert {:ok, _} = Chunk.validate(f.chunk)
      end

      assert result.tool_calls == []
      assert result.finish == :stop
      assert Usage.amount(result.usage, :input_uncached_tokens) == 37
      assert Usage.amount(result.usage, :output_tokens) == 93
      assert Usage.amount(result.usage, :cache_read_tokens) == 0
      assert result.usage.cache_writes == [%{ttl: "provider_default", amount: 0}]
      assert result.usage.source == :provider_reported

      assert result.provenance == %{
               model_ref: %{
                 provider: "anthropic",
                 model_id: "claude-haiku-5-5",
                 wire_surface: "messages"
               },
               provider_model: "anthropic/claude-haiku-5.5",
               response_id: "msg_011CgzXnzKALMgLi5HCHiogj",
               request_id: "req_loopback_1",
               provider_piece: "delivery/provider-stream"
             }
    end

    test "a refused request reaches neither the credential function nor the peer" do
      origin = Peer.start(Fixture.whole(Fixture.read("text.sse")))
      base = Jason.decode!(Fixture.read("text.ai-text.json"))
      [system, user] = base["messages"]

      cases = [
        {"{", :invalid_request},
        {Jason.encode!(Map.put(base, "messages", [%{"role" => "user", "image" => "x"}])),
         :unsupported_feature},
        {Jason.encode!(Map.put(base, "output_schema", %{"type" => "object"})),
         :unsupported_feature},
        {Jason.encode!(Map.put(base, "sampling", %{"temperature" => 0.5})), :unsupported_feature},
        {Jason.encode!(Map.put(base, "reasoning", "low")), :unsupported_feature},
        {Jason.encode!(Map.put(base, "stop_sequences", ["x"])), :unsupported_feature},
        {Jason.encode!(Map.put(base, "provider_options", %{"a" => 1})), :unsupported_feature},
        {Jason.encode!(
           Map.put(base, "cache_hint", %{
             "tenant" => "t",
             "local_key" => "k",
             "ttl" => "5m",
             "breakpoints" => ["system"]
           })
         ), :unsupported_feature},
        {Jason.encode!(Map.put(base, "messages", [user, system])), :unsupported_feature},
        {Jason.encode!(Map.put(base, "model", "claude-other")), :invalid_request},
        {Jason.encode!(
           Map.put(base, "messages", [user, %{"role" => "assistant", "text" => ""}, user])
         ), :invalid_request}
      ]

      for {payload, reason} <- cases do
        task = Fixture.run(payload, Fixture.acking_sink(), Fixture.settings(), origin)
        assert Task.await(task) == {:refused, reason}
      end

      refute_received :credentials_read
      refute_receive {:request, _, _, _}, 200
    end

    test "assistant tool calls and tool results translate to the documented blocks" do
      origin = Peer.start(Fixture.whole(Fixture.read("text.sse")))
      base = Jason.decode!(Fixture.read("tool.ai-text.json"))
      [system, user] = base["messages"]
      call = %{"id" => "toolu_1", "name" => "save_note", "arguments" => %{"title" => "a"}}

      messages = [
        system,
        user,
        %{"role" => "assistant", "text" => "", "tool_calls" => [call]},
        %{
          "role" => "tool_result",
          "tool_use_id" => "toolu_1",
          "text" => "saved",
          "is_error" => true
        },
        %{"role" => "tool_result", "tool_use_id" => "toolu_1", "text" => "again"}
      ]

      payload = Jason.encode!(%{base | "messages" => messages, "tool_choice" => %{"type" => "any"}})
      task = Fixture.run(payload, Fixture.acking_sink(), Fixture.settings(), origin)
      assert {:complete, _} = Task.await(task)
      assert_receive {:request, ^origin, _, body}
      sent = Jason.decode!(body)
      assert sent["tool_choice"] == %{"type" => "any"}

      assert Enum.drop(sent["messages"], 1) == [
               %{
                 "role" => "assistant",
                 "content" => [
                   %{
                     "type" => "tool_use",
                     "id" => "toolu_1",
                     "name" => "save_note",
                     "input" => %{"title" => "a"}
                   }
                 ]
               },
               %{
                 "role" => "user",
                 "content" => [
                   %{
                     "type" => "tool_result",
                     "tool_use_id" => "toolu_1",
                     "content" => "saved",
                     "is_error" => true
                   },
                   %{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "again"}
                 ]
               }
             ]
    end
  end

  describe "tool_call_split" do
    test "pieces cut inside events give tool_start, nine deltas and a complete call" do
      sse = Fixture.read("tool.sse")
      pieces = for <<piece::binary-size(97) <- sse>>, do: piece
      pieces = pieces ++ [binary_part(sse, 97 * length(pieces), rem(byte_size(sse), 97))]
      assert Enum.any?(pieces, &(not String.ends_with?(&1, "\n\n")))

      origin =
        Peer.start(fn s ->
          Peer.head(s)
          for p <- pieces, do: Peer.chunk(s, p) && Process.sleep(1)
          Peer.finish(s)
        end)

      task =
        Fixture.run(
          Fixture.read("tool.ai-text.json"),
          Fixture.holding_sink(),
          Fixture.settings(),
          origin
        )

      # The tool_start frame is held longest: no delta may be offered meanwhile.
      frames = Fixture.release(14, &if(&1.chunk.kind == :tool_start, do: 400, else: 20))
      assert {:complete, result} = Task.await(task)
      assert_receive {:request, ^origin, _, body}
      assert Jason.decode!(body) == Fixture.upstream("tool")

      assert kinds(frames) ==
               List.duplicate(:text_delta, 4) ++ [:tool_start] ++ List.duplicate(:tool_delta, 9)

      [start, first_delta | _] = Enum.drop(frames, 4)

      assert start.chunk.payload == %{
               index: 1,
               id: "toolu_01Cj23WuFfcxzpBvktwJhJET",
               name: "save_note"
             }

      assert {:ok, _} = Chunk.validate(start.chunk)
      assert {:error, :stream_chunk} = StreamChunk.validate(start.chunk)
      assert first_delta.chunk.payload.index == 1

      deltas = for %{chunk: %{kind: :tool_delta} = c} <- frames, do: c
      assert Enum.all?(deltas, &match?({:ok, _}, StreamChunk.validate(&1)))
      assert Enum.all?(deltas, &(&1.payload.index == 1 and &1.payload.delta != ""))

      assert [%{id: "toolu_01Cj23WuFfcxzpBvktwJhJET", name: "save_note", arguments_json: args}] =
               result.tool_calls

      assert args == Enum.map_join(deltas, & &1.payload.delta)
      message = Jason.decode!(Fixture.read("tool.message.json"))
      assert [%{"input" => input}] = for(%{"type" => "tool_use"} = b <- message["content"], do: b)
      assert Jason.decode!(args) == input
      assert result.content == "Saving your tomato watering reminder now."
      assert result.finish == :tool_calls
    end
  end

  describe "cut_in_tool_call" do
    setup do
      prefix = Fixture.through(Fixture.read("tool.sse"), "input_json_delta", 5)
      assert String.ends_with?(prefix, "\"}}\n\n")
      %{prefix: prefix}
    end

    test "connection closed after a tool delta is incomplete transport", %{prefix: prefix} do
      origin =
        Peer.start(fn s ->
          Peer.head(s)
          Peer.chunk(s, prefix)
          Process.sleep(50)
          :gen_tcp.close(s)
        end)

      task =
        Fixture.run(
          Fixture.read("tool.ai-text.json"),
          Fixture.acking_sink(),
          Fixture.settings(),
          origin
        )

      assert Task.await(task) == {:incomplete, :transport}
      assert :tool_start in kinds(Fixture.offered())
    end

    test "body ended normally after a tool delta is incomplete missing_completion", %{
      prefix: prefix
    } do
      origin = Peer.start(Fixture.whole(prefix))

      task =
        Fixture.run(
          Fixture.read("tool.ai-text.json"),
          Fixture.acking_sink(),
          Fixture.settings(),
          origin
        )

      assert Task.await(task) == {:incomplete, :missing_completion}
      assert Enum.count(kinds(Fixture.offered()), &(&1 == :tool_delta)) == 5
    end
  end

  describe "slow_consumer" do
    test "one unacknowledged frame holds the stream; a sink that never returns times out and closes" do
      parent = self()

      sink = fn frame ->
        send(parent, {:held, frame.seq})
        Process.sleep(:infinity)
      end

      origin = Peer.start(Fixture.open(Fixture.read("text.sse")))
      task = Fixture.run(Fixture.read("text.ai-text.json"), sink, Fixture.settings(), origin)

      assert_receive {:held, 0}, 2_000
      refute_receive {:held, _}, 400
      refute_received {:peer_close, _, _}
      assert Task.await(task) == {:incomplete, :sink_timeout}
      assert_receive {:peer_close, ^origin, {:error, :closed}}, 2_000
      refute_received {:held, _}
    end

    test "a sink that cancels, disconnects, fails, raises or acks another frame closes the request" do
      for {sink, reason} <- [
            {fn _ -> {:cancel, :caller_cancelled} end, :caller_cancelled},
            {fn _ -> {:error, :disconnected} end, :disconnected},
            {fn _ -> :ok end, :sink_failed},
            {fn f -> {:ack, make_ref(), f.seq} end, :sink_failed},
            {fn f -> {:ack, f.callback_ref, f.seq + 1} end, :sink_failed},
            {fn _ -> raise "sink" end, :sink_failed}
          ] do
        origin = Peer.start(Fixture.open(Fixture.read("text.sse")))
        task = Fixture.run(Fixture.read("text.ai-text.json"), sink, Fixture.settings(), origin)
        assert Task.await(task) == {:incomplete, reason}
        assert_receive {:peer_close, ^origin, {:error, :closed}}, 2_000
      end
    end
  end

  describe "result_over_bound" do
    for {name, size, last} <- [{"text", 283, :text_delta}, {"tool", 212, :tool_delta}] do
      test "#{name}: complete at #{size} bytes, result_limit at #{size - 1}" do
        name = unquote(name)
        size = unquote(size)
        sse = Fixture.read(name <> ".sse")
        payload = Fixture.read(name <> ".ai-text.json")

        origin = Peer.start(Fixture.whole(sse))
        settings = Fixture.settings(max_result_bytes: size)

        assert {:complete, r} =
                 Task.await(Fixture.run(payload, Fixture.acking_sink(), settings, origin))

        assert size ==
                 byte_size(r.content) +
                   Enum.sum(
                     Enum.map(r.tool_calls, &byte_size(&1.id <> &1.name <> &1.arguments_json))
                   )

        all = Fixture.offered()

        origin = Peer.start(Fixture.open(sse))
        settings = Fixture.settings(max_result_bytes: size - 1)
        task = Fixture.run(payload, Fixture.acking_sink(), settings, origin)
        assert Task.await(task) == {:incomplete, :result_limit}
        offered = Fixture.offered()
        assert length(offered) == length(all) - 1
        assert kinds(offered) == Enum.drop(kinds(all), -1)
        assert List.last(kinds(all)) == unquote(last)
        assert_receive {:peer_close, ^origin, {:error, :closed}}, 2_000
      end
    end

    test "a missing or out-of-range max_result_bytes, or another bad setting, is a configuration error and sends nothing" do
      origin = Peer.start(Fixture.whole(Fixture.read("text.sse")))
      payload = Fixture.read("text.ai-text.json")

      for settings <- [
            Keyword.delete(Fixture.settings(), :max_result_bytes),
            Fixture.settings(max_result_bytes: 0),
            Fixture.settings(max_result_bytes: 1_048_577),
            Fixture.settings(max_result_bytes: "283"),
            Fixture.settings() ++ [max_result_bytes: 283],
            Fixture.settings(unknown: 1),
            Fixture.settings(models: ["claude-haiku-5-5" | "claude-other"])
          ] do
        assert Task.await(Fixture.run(payload, Fixture.acking_sink(), settings, origin)) ==
                 {:error, :configuration}
      end

      refute_received :credentials_read
      refute_receive {:request, _, _, _}, 200
    end
  end

  describe "provider_error_mid_stream" do
    test "a hand-built error event after a recorded prefix is stream_error" do
      prefix = Fixture.through(Fixture.read("text.sse"), "text_delta", 3)
      origin = Peer.start(Fixture.open(prefix <> @hand_built_error))

      task =
        Fixture.run(
          Fixture.read("text.ai-text.json"),
          Fixture.acking_sink(),
          Fixture.settings(),
          origin
        )

      assert Task.await(task) == {:incomplete, :stream_error}
      assert length(Fixture.offered()) == 3
      assert_receive {:peer_close, ^origin, {:error, :closed}}, 2_000
    end

    test "status 529 with no stream is refused overloaded" do
      origin =
        Peer.start(fn s ->
          :gen_tcp.send(s, "HTTP/1.1 529 Overloaded\r\ncontent-length: 0\r\n\r\n")
        end)

      task =
        Fixture.run(
          Fixture.read("text.ai-text.json"),
          Fixture.acking_sink(),
          Fixture.settings(),
          origin
        )

      assert Task.await(task) == {:refused, :overloaded}
      assert Fixture.offered() == []
    end
  end

  describe "equals_non_stream" do
    for name <- ["text", "tool"] do
      test "#{name}: content, tool calls and finish equal the second form" do
        name = unquote(name)
        origin = Peer.start(Fixture.whole(Fixture.read(name <> ".sse")))
        payload = Fixture.read(name <> ".ai-text.json")

        assert {:complete, r} =
                 Task.await(Fixture.run(payload, Fixture.acking_sink(), Fixture.settings(), origin))

        message = Jason.decode!(Fixture.read(name <> ".message.json"))

        assert r.content ==
                 Enum.map_join(
                   for(%{"type" => "text"} = b <- message["content"], do: b),
                   & &1["text"]
                 )

        assert Enum.map(r.tool_calls, &{&1.id, &1.name, Jason.decode!(&1.arguments_json)}) ==
                 for(
                   %{"type" => "tool_use"} = b <- message["content"],
                   do: {b["id"], b["name"], b["input"]}
                 )

        assert r.finish == Protocol.finish(message["stop_reason"])
      end
    end

    test "the finish mapping is the one of Elzoo.AiText.Anthropic" do
      assert Enum.map(
               ~w(end_turn stop_sequence max_tokens tool_use refusal pause_turn),
               &Protocol.finish/1
             ) ==
               [:stop, :stop, :length, :tool_calls, :refusal, {:other, "pause_turn"}]

      assert Protocol.finish(String.duplicate("x", 65)) == {:other, "unrecognized"}
    end
  end

  describe "direct_recording" do
    # One text stream recorded from Anthropic's own endpoint; the PROVENANCE.md
    # of its directory lists the facts. The Piece did not build the request of
    # that call. The request below takes its model, limit and prompt, and the
    # POST body is not compared with it.
    @direct Path.expand("../fixtures/anthropic-direct-stream", __DIR__)

    for {name, size, count} <- [
          {"whole", 1_408, 1},
          {"in pieces of 97 bytes", 97, 15},
          {"in pieces of 1 byte", 1, 1_408}
        ] do
      test "#{name}: two text frames, none for the ping, then complete" do
        sse = File.read!(Path.join(@direct, "text.sse"))
        assert sse =~ ~s(event: ping\ndata: {"type": "ping"}\n\n)

        pieces =
          sse
          |> :binary.bin_to_list()
          |> Enum.chunk_every(unquote(size))
          |> Enum.map(&:binary.list_to_bin/1)

        assert length(pieces) == unquote(count)

        origin =
          Peer.start(fn s ->
            Peer.head(s)
            for p <- pieces, do: Peer.chunk(s, p)
            Peer.finish(s)
          end)

        sent = Jason.decode!(File.read!(Path.join(@direct, "text.upstream.json")))
        [%{"role" => "user", "content" => prompt}] = sent["messages"]

        payload =
          Jason.encode!(%{
            version: 1,
            model: sent["model"],
            max_output_tokens: sent["max_tokens"],
            messages: [%{role: "user", text: prompt}]
          })

        task = Fixture.run(payload, Fixture.holding_sink(), Fixture.settings(), origin)
        frames = Fixture.release(2, fn _ -> 20 end)
        assert {:complete, result} = Task.await(task)
        refute_received {:held, _, _}

        assert Enum.map(frames, &{&1.seq, &1.chunk}) == [
                 {0, %{seq: 0, kind: :text_delta, payload: "Red"}},
                 {1, %{seq: 1, kind: :text_delta, payload: "\nOrange\nYellow"}}
               ]

        assert result.content == "Red\nOrange\nYellow"
        assert result.tool_calls == []
        assert result.finish == :stop
        assert Usage.amount(result.usage, :input_uncached_tokens) == 22
        assert Usage.amount(result.usage, :output_tokens) == 13
        assert Usage.amount(result.usage, :cache_read_tokens) == 0
        assert result.usage.cache_writes == [%{ttl: "provider_default", amount: 0}]

        assert result.provenance == %{
                 model_ref: %{
                   provider: "anthropic",
                   model_id: "claude-haiku-5-5",
                   wire_surface: "messages"
                 },
                 provider_model: "claude-haiku-5-5",
                 response_id: "msg_011Ch1BENb7LZPb4upBAsq3o",
                 request_id: "req_loopback_1",
                 provider_piece: "delivery/provider-stream"
               }
      end
    end
  end

  describe "declared paths" do
    setup do
      %{
        start: Fixture.through(Fixture.read("text.sse"), "message_start", 1),
        payload: Fixture.read("text.ai-text.json")
      }
    end

    test "more than 4,194,304 received bytes give receive_limit", %{start: start, payload: p} do
      comment = ":" <> String.duplicate("x", 65_000) <> "\n\n"

      origin =
        Peer.start(fn s ->
          Peer.head(s)
          Peer.chunk(s, start)
          for _ <- 1..65, do: Peer.chunk(s, comment)
        end)

      task = Fixture.run(p, Fixture.acking_sink(), Fixture.settings(), origin)
      assert Task.await(task) == {:incomplete, :receive_limit}
      assert_receive {:peer_close, ^origin, {:error, :closed}}, 2_000
    end

    test "total_timeout_ms ends a stream that keeps sending", %{start: start, payload: p} do
      origin =
        Peer.start(fn s ->
          Peer.head(s)
          Peer.chunk(s, start)

          Enum.reduce_while(1..30, :ok, fn _, _ ->
            Process.sleep(100)
            if Peer.chunk(s, ": ping\n\n") == :ok, do: {:cont, :ok}, else: {:halt, :ok}
          end)
        end)

      settings =
        Fixture.settings(total_timeout_ms: 600, receive_timeout_ms: 400, ack_timeout_ms: 500)

      t0 = System.monotonic_time(:millisecond)

      assert Task.await(Fixture.run(p, Fixture.acking_sink(), settings, origin)) ==
               {:incomplete, :timeout}

      assert System.monotonic_time(:millisecond) - t0 < 1_500
      assert_receive {:peer_close, ^origin, {:error, :closed}}, 3_000
    end

    test "receive_timeout_ms ends a silent stream before the total", %{start: start, payload: p} do
      origin = Peer.start(Fixture.open(start))
      settings = Fixture.settings(total_timeout_ms: 5_000, receive_timeout_ms: 300)
      t0 = System.monotonic_time(:millisecond)

      assert Task.await(Fixture.run(p, Fixture.acking_sink(), settings, origin)) ==
               {:incomplete, :timeout}

      assert System.monotonic_time(:millisecond) - t0 < 2_000
      assert_receive {:peer_close, ^origin, {:error, :closed}}, 2_000
    end

    test "a credential function that gives no key is refused and sends nothing", %{payload: p} do
      origin = Peer.start(Fixture.whole(Fixture.read("text.sse")))
      settings = Fixture.settings(credentials: fn -> :error end)

      assert Task.await(Fixture.run(p, Fixture.acking_sink(), settings, origin)) ==
               {:refused, :credentials_unavailable}

      refute_receive {:request, _, _, _}, 200
    end

    test "an HTTP worker killed by an exit signal gives adapter_error to a caller that traps exits",
         %{payload: p} do
      parent = self()
      origin = Peer.start(Fixture.whole(Fixture.read("text.sse")))

      settings =
        Fixture.settings(
          credentials: fn ->
            send(parent, {:worker, self()})
            Process.sleep(:infinity)
          end
        )

      task =
        Task.async(fn ->
          Process.flag(:trap_exit, true)
          Elzoo.ProviderStream.run(p, Fixture.acking_sink(), settings, {:loopback, origin, nil})
        end)

      assert_receive {:worker, worker}, 2_000
      Process.exit(worker, :stopped_from_outside)
      assert Task.await(task, 1_000) == {:incomplete, :adapter_error}
    end
  end

  describe "protocol" do
    # Hand-built event sequences, applied one raw block at a time.
    defp feed(events, limit \\ 1_000) do
      Enum.reduce_while(events, Protocol.new(limit), fn e, p ->
        raw = if is_binary(e), do: e, else: "data: " <> Jason.encode!(e) <> "\n\n"

        case Protocol.block(p, raw) do
          {:ok, p, _} -> {:cont, p}
          {:stop, p} -> {:cont, p}
          {:error, r} -> {:halt, r}
        end
      end)
    end

    @start %{
      "type" => "message_start",
      "message" => %{"id" => "msg_1", "model" => "m", "extra" => 1}
    }
    @text_start %{
      "type" => "content_block_start",
      "index" => 0,
      "content_block" => %{"type" => "text", "text" => ""}
    }
    @tool_start %{
      "type" => "content_block_start",
      "index" => 0,
      "content_block" => %{"type" => "tool_use", "id" => "toolu_1", "name" => "n", "input" => %{}}
    }
    @stop0 %{"type" => "content_block_stop", "index" => 0}
    @delta %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}}
    @end_ %{"type" => "message_stop"}

    defp json(j),
      do: %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "input_json_delta", "partial_json" => j}
      }

    defp text(t),
      do: %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => t}
      }

    test "listed order, member and type rules" do
      assert %{phase: :stopped} =
               feed([
                 ": comment\n\n",
                 %{"type" => "ping"},
                 @start,
                 %{"type" => "future_event"},
                 @text_start,
                 @stop0,
                 @delta,
                 @end_
               ])

      assert %{phase: :stopped, calls: [%{arguments_json: "{}"}]} =
               feed([@start, @tool_start, @stop0, @delta, @end_])

      for {events, reason} <- [
            {[@text_start], :malformed_response},
            {[@start, @start], :malformed_response},
            {[@start, %{@text_start | "index" => 1}], :malformed_response},
            {[@start, @text_start, @text_start], :malformed_response},
            {[@start, @text_start, json("{")], :malformed_response},
            {[@start, @tool_start, text("x")], :malformed_response},
            {[@start, @tool_start, json("[1]"), @stop0], :malformed_response},
            {[@start, @tool_start, json("{"), @stop0], :malformed_response},
            {[@start, @text_start, @delta], :malformed_response},
            {[@start, @end_], :malformed_response},
            {[@start, @delta, @end_, %{"type" => "ping"}], :malformed_response},
            {[@start, @text_start, text(1)], :malformed_response},
            {[%{@start | "message" => %{"id" => "bad id", "model" => "m"}}], :malformed_response},
            {[@start, put_in(@text_start["content_block"], %{"type" => "thinking"})],
             :unsupported_response},
            {[@start, @text_start, put_in(text("x")["delta"]["type"], "citations_delta")],
             :unsupported_response},
            {[@start, %{"type" => "error", "error" => %{}}], :stream_error},
            {[@start, @text_start, text(String.duplicate("x", 21))], :result_limit},
            {["event: ping\ndata: {\"type\":\"message_start\"}\n\n"], :malformed_response}
          ] do
        assert feed(events, 20) == reason, inspect(events)
      end
    end
  end
end
