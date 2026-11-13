# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/data_stream_test_helper.exs", __DIR__)

defmodule Elzoo.DataStream.OwnerTest do
  use ExUnit.Case, async: false
  alias Elzoo.DataStream, as: Stream
  alias Elzoo.DataStream.{Fixture, Peer}

  setup do
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  test "real HTTP callback, source stop, request death, finish ack and intent settlement" do
    peer = Peer.start(self(), fn mod, s -> Peer.response(mod, s, Fixture.complete()) end)
    parent = self()

    sink = fn frame ->
      send(parent, {:frame, frame})
      Fixture.ack(frame)
    end

    settings = Fixture.settings()
    assert {:ok, owner} = Stream.__start_loopback__(settings, peer.origin)
    assert {:ok, h} = Stream.start(owner, Fixture.effect(), sink)
    assert_receive {:stream_request, _, _, headers, body}, 2_000
    assert String.starts_with?(headers, "POST /v1/messages HTTP/1.1\r\n")
    assert headers =~ "anthropic-version: 2026-10-21"
    assert headers =~ "x-api-key: test-key"
    assert headers =~ "accept-encoding: identity"
    assert {:ok, wire} = Elzoo.DataStream.JSON.decode(body)
    assert wire["stream"] == true and wire["thinking"] == %{"type" => "disabled"}
    assert Elzoo.DataStream.JSON.encode(wire) == body
    assert_receive {:frame, %Stream.Frame{seq: 0, completeness: :partial}}

    assert_receive {:frame,
                    %Stream.FinishFrame{
                      seq: 1,
                      source_complete: true,
                      completeness: :source_complete
                    }}

    t = Fixture.terminal(h)
    assert t.status == :complete and t.delivery_complete and t.source_complete
    assert t.offered_frames == 2 and t.acknowledged_frames == 2
    assert t.intent_confirmation == :confirmed
    assert {:provider_reported, u} = t.incurred_usage
    assert Elzoo.AiModel.Usage.amount(u, :output_tokens) == 5
    assert_receive {:peer_close, _, {:error, :closed}}, 2_000
    assert {:ok, %{phase: :retained}} = Stream.status(owner, h)
    assert {:ok, ^t} = Stream.result(owner, h)
    assert {:ok, :closed} = Stream.close(owner, h)
    assert {:error, :not_found} = Stream.status(owner, h)
    GenServer.stop(owner)
  end

  test "allowed members are never read: same frames, usage and terminal with and without them" do
    # Hand-made values of several JSON kinds; some look like members that are read.
    usage = %{
      "inference_geo" => "eu",
      "server_tool_use" => %{"web_search_requests" => 7, "output_tokens" => 99},
      "service_tier" => ["priority"],
      "speed" => 9
    }

    message = %{
      "container" => %{"id" => "container_1", "expires_at" => "2026-11-13T00:00:00Z"},
      "stop_details" => %{"type" => "refusal", "stop_reason" => "max_tokens"}
    }

    [start, block, text, block_stop, delta, stop] =
      plain = [Fixture.start()] ++ Fixture.text() ++ [Fixture.delta(), Fixture.stop()]

    with_members = [
      start
      |> update_in(["message"], &Map.merge(&1, message))
      |> update_in(["message", "usage"], &Map.merge(&1, usage)),
      put_in(block, ["content_block", "citations"], [%{"type" => "char_location"}]),
      text,
      block_stop,
      delta
      |> Map.put("context_management", %{"applied_edits" => [%{"cleared_input_tokens" => 3}]})
      |> update_in(["delta"], &Map.merge(&1, message))
      |> update_in(["usage"], &Map.merge(&1, usage)),
      stop
    ]

    effect = Fixture.effect()
    parent = self()

    [with_result, plain_result] =
      for events <- [with_members, plain] do
        wire = Fixture.wire(events)
        peer = Peer.start(self(), fn mod, s -> Peer.response(mod, s, wire) end)
        tag = make_ref()

        sink = fn frame ->
          send(parent, {tag, frame})
          Fixture.ack(frame)
        end

        {:ok, owner} = Stream.__start_loopback__(Fixture.settings(), peer.origin)
        {:ok, h} = Stream.start(owner, effect, sink)
        t = Fixture.terminal(h)
        GenServer.stop(owner)
        # This one field counts the bytes of the wire, so it is compared with
        # its own wire. Every other field of the terminal is compared below.
        assert t.received_body_bytes == byte_size(wire)
        {offered(tag), t |> Map.from_struct() |> Map.delete(:received_body_bytes)}
      end

    assert with_result == plain_result
    {frames, t} = with_result

    assert [
             {Stream.Frame, 0, %{kind: :text_delta, payload: "private output"}, :partial},
             {Stream.FinishFrame, 1, %{kind: :finish, payload: %{reason: :stop}}, :source_complete}
           ] = frames

    assert t.status == :complete and t.delivery_complete and t.source_complete
    assert t.provenance.response_id == "msg_1"
    assert {:provider_reported, u} = t.incurred_usage
    assert Elzoo.AiModel.Usage.amount(u, :input_uncached_tokens) == 2
    assert Elzoo.AiModel.Usage.amount(u, :output_tokens) == 5
    assert t.last_usage == %{usage: u, event_index: 4, stage: :message_delta}
  end

  test "direct_recording_owner: the recorded direct stream through the public start is complete" do
    directory = Path.expand("../fixtures/anthropic-direct-stream", __DIR__)
    recorded = File.read!(Path.join(directory, "text.sse"))
    upstream = File.read!(Path.join(directory, "text.upstream.json"))
    {:ok, request} = Elzoo.DataStream.JSON.decode(upstream)
    effect = Fixture.effect(%{}, Map.drop(request, ~w(stream thinking)))

    {frames, t} =
      loopback(recorded, effect, [models: ["claude-haiku-5-5"]], [
        {"content-type", "text/event-stream; charset=utf-8"}
      ])

    # The request bytes of the Piece are the recorded request bytes.
    assert_receive {:stream_request, _, _, _, ^upstream}, 2_000

    assert [
             {Stream.Frame, 0, %{kind: :text_delta, payload: "Red"}, :partial},
             {Stream.Frame, 1, %{kind: :text_delta, payload: "\nOrange\nYellow"}, :partial},
             {Stream.FinishFrame, 2, %{kind: :finish, payload: %{reason: :stop}}, :source_complete}
           ] = frames

    assert t.status == :complete and t.delivery_complete and t.source_complete
    assert t.offered_frames == 3 and t.acknowledged_frames == 3
    assert t.received_body_bytes == 1_408 and t.raw_blocks == 8
    assert t.provenance.response_id == "msg_011Ch1BENb7LZPb4upBAsq3o"
    assert t.provenance.provider_model == "claude-haiku-5-5"
    assert {:provider_reported, u} = t.incurred_usage
    assert Elzoo.AiModel.Usage.amount(u, :input_uncached_tokens) == 22
    assert Elzoo.AiModel.Usage.amount(u, :output_tokens) == 13
    assert Elzoo.AiModel.Usage.amount(u, :cache_read_tokens) == 0
    assert Elzoo.AiModel.Usage.sum(u.cache_writes) == 0
    assert Elzoo.AiModel.Usage.amount(u, :reasoning_tokens) == 0
    assert t.last_usage == %{usage: u, event_index: 6, stage: :message_delta}
  end

  test "unread_event_ignored: an unknown event type gives no frame and the same terminal" do
    # It looks like a text delta, and it holds a number with a fraction.
    unknown = %{
      "type" => "new_event",
      "index" => 0,
      "delta" => %{"type" => "text_delta", "text" => "not offered"},
      "n" => 1.5
    }

    [start, block, text, block_stop, delta, stop] =
      plain = [Fixture.start()] ++ Fixture.text() ++ [Fixture.delta(), Fixture.stop()]

    # Before message_start, inside the open block, after it and after message_delta.
    with_events = [unknown, start, block, unknown, text, block_stop, unknown, delta, unknown, stop]

    [{frames, t}, {plain_frames, plain_t}] =
      for events <- [with_events, plain] do
        wire = Fixture.wire(events)
        {frames, t} = loopback(wire)
        assert t.received_body_bytes == byte_size(wire) and t.raw_blocks == length(events)
        {frames, t}
      end

    assert frames == plain_frames

    assert [
             {Stream.Frame, 0, %{kind: :text_delta, payload: "private output"}, :partial},
             {Stream.FinishFrame, 1, %{kind: :finish, payload: %{reason: :stop}}, :source_complete}
           ] = frames

    assert t.status == :complete and t.delivery_complete and t.source_complete
    # It counts as one event, as ping does: three of the four come before message_delta.
    assert plain_t.last_usage.event_index == 4 and t.last_usage.event_index == 7

    assert %{
             t
             | received_body_bytes: plain_t.received_body_bytes,
               raw_blocks: plain_t.raw_blocks,
               last_usage: plain_t.last_usage
           } == plain_t
  end

  test "failed finish retains source-complete usage; interruption before stop cannot incur it" do
    for {stop, expected} <- [{true, true}, {false, false}] do
      events = [Fixture.start(), Fixture.delta()] ++ if(stop, do: [Fixture.stop()], else: [])

      peer =
        Peer.start(self(), fn mod, s ->
          Peer.response(mod, s, Fixture.wire(events))
          if not stop, do: apply(mod, :send, [s, "0\r\n\r\n"])
        end)

      sink = fn _ -> {:error, :disconnected} end
      {:ok, owner} = Stream.__start_loopback__(Fixture.settings(), peer.origin)
      {:ok, h} = Stream.start(owner, Fixture.effect(), sink)
      t = Fixture.terminal(h)
      assert t.status == :partial and not t.delivery_complete
      assert t.source_complete == expected

      if expected do
        assert {:provider_reported, u} = t.incurred_usage
        assert Elzoo.AiModel.Usage.amount(u, :output_tokens) == 5
      else
        assert t.incurred_usage == :unknown
        assert t.offered_frames == 0
      end

      GenServer.stop(owner)
    end
  end

  test "blocked credentials retain capacity, duplicate identity and caller authority" do
    parent = self()

    credentials = fn ->
      send(parent, {:credentials, self()})

      receive do
        :release -> {:ok, "test-key"}
      end
    end

    {:ok, owner} = Stream.start_link(Fixture.settings(credentials: credentials, capacity: 1))
    effect = Fixture.effect()
    sink = &Fixture.ack/1
    {:ok, h} = Stream.start(owner, effect, sink)
    assert_receive {:credentials, worker}, 2_000
    assert {:ok, ^h} = Stream.start(owner, effect, sink)

    assert {:refused, :identity_conflict} =
             Stream.start(owner, put_in(effect, ["command", "correlation_id"], "changed"), sink)

    assert {:refused, :saturated} =
             Stream.start(
               owner,
               Fixture.effect(%{"message_id" => "other", "idempotency_key" => "other"}),
               sink
             )

    task =
      Task.async(fn ->
        {Stream.status(owner, h), Stream.cancel(owner, h), Stream.result(owner, h),
         Stream.close(owner, h), Stream.start(owner, effect, sink)}
      end)

    assert {{:error, :unauthorized}, {:error, :unauthorized}, {:error, :unauthorized},
            {:error, :unauthorized}, {:error, :unauthorized}} = Task.await(task)

    assert {:ok, :pending} = Stream.cancel(owner, h)
    t = Fixture.terminal(h)
    assert t.reason == :caller_cancelled
    refute Process.alive?(worker)
    assert {:ok, :already_terminal} = Stream.cancel(owner, h)

    assert {:refused, :saturated} =
             Stream.start(
               owner,
               Fixture.effect(%{"message_id" => "other", "idempotency_key" => "other"}),
               sink
             )

    assert {:ok, ^h} = Stream.start(owner, effect, sink)
    assert {:ok, :closed} = Stream.close(owner, h)
    GenServer.stop(owner)
  end

  test "construction refuses unknown/duplicate settings and HTTP overrides" do
    settings = Fixture.settings()

    for extra <- [
          [endpoint: "http://localhost"],
          [retry: true],
          [capacity: 0],
          [allow_volatile: false],
          [authorized_callers: []],
          [models: ["bad/model"]],
          [receive_timeout_ms: 30_001]
        ] do
      assert {:error, :configuration} = Stream.start_link(Keyword.merge(settings, extra))
    end

    assert {:error, :configuration} = Stream.start_link(settings ++ [tenant: "duplicate"])
    assert {:error, :invalid_argument} = Stream.status(:bad, :bad)
    assert Elzoo.DataStream.Terminal.maximal_size() <= 4096
  end

  test "excluded and oversized requests create no intent and never call credentials" do
    parent = self()

    settings =
      Fixture.settings(
        credentials: fn ->
          send(parent, :credentials_called)
          {:ok, "test-key"}
        end
      )

    {:ok, owner} = Stream.start_link(settings)

    for {payload, reason} <- [
          {%{"tools" => []}, :unsupported_feature},
          {%{"thinking" => %{}}, :unsupported_feature},
          {%{"stop_sequences" => []}, :unsupported_feature},
          {%{"temperature" => 1}, :unsupported_feature},
          {%{"unknown" => 1}, :invalid_request},
          {%{"max_tokens" => 4097}, :too_large},
          {%{"messages" => [%{"role" => "user", "content" => String.duplicate("x", 16_385)}]},
           :too_large},
          {%{"messages" => [%{"role" => "user", "content" => []}]}, :unsupported_feature}
        ] do
      assert {:refused, ^reason} = Stream.start(owner, Fixture.effect(%{}, payload), &Fixture.ack/1)
    end

    for bytes <- [
          ~s({"model":"claude-sonnet-5","model":"claude-sonnet-5"}),
          ~s({"a":{"x":1,"\\u0078":2}}),
          "{",
          "1.0"
        ] do
      assert {:refused, :invalid_request} =
               Stream.start(owner, Fixture.effect(%{"payload" => bytes}), &Fixture.ack/1)
    end

    assert {:refused, :too_large} =
             Stream.start(
               owner,
               Fixture.effect(%{"payload" => String.duplicate("x", 65_537)}),
               &Fixture.ack/1
             )

    assert {:refused, :expired} =
             Stream.start(owner, Fixture.effect(%{"deadline_unix_ms" => 0}), &Fixture.ack/1)

    assert {:refused, :invalid_request} =
             Stream.start(owner, Fixture.effect(%{"attempt_id" => "forged"}), &Fixture.ack/1)

    refute_receive :credentials_called
    assert map_size(Elzoo.DurableLog.Memory.inspect_state(settings[:store]).records) == 0
    GenServer.stop(owner)
  end

  test "actual empty HTTP responses and status-only errors never call the sink" do
    for {status, expected} <- [
          {200, :missing_completion},
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
      peer =
        Peer.start(self(), fn mod, s ->
          Peer.response(mod, s, "", status)
          apply(mod, :send, [s, "0\r\n\r\n"])
        end)

      parent = self()
      {:ok, owner} = Stream.__start_loopback__(Fixture.settings(), peer.origin)

      {:ok, h} =
        Stream.start(owner, Fixture.effect(), fn f ->
          send(parent, {:unexpected_frame, f})
          Fixture.ack(f)
        end)

      t = Fixture.terminal(h)
      assert t.reason == expected
      assert t.offered_frames == 0 and not t.source_complete
      refute_receive {:unexpected_frame, _}, 0
      assert_receive {:stream_request, _, _, _, _}, 2_000
      GenServer.stop(owner)
    end
  end

  test "cancel during an open response observes peer close and stops owned tasks" do
    peer =
      Peer.start(self(), fn mod, s -> Peer.response(mod, s, Fixture.wire([Fixture.start()])) end)

    {:ok, owner} = Stream.__start_loopback__(Fixture.settings(), peer.origin)
    {:ok, h} = Stream.start(owner, Fixture.effect(), &Fixture.ack/1)
    assert_receive {:stream_request, _, _, _, _}, 2_000
    e = :sys.get_state(owner).entries[h.ref]
    session = :sys.get_state(e.session)
    pids = [e.session, e.sup, session.bootstrap, session.intent, session.adapter, session.http.pid]
    assert {:ok, :pending} = Stream.cancel(owner, h)
    t = Fixture.terminal(h)
    assert t.reason == :caller_cancelled
    assert_receive {:peer_close, _, {:error, :closed}}, 2_000
    assert Enum.all?(pids, &(not Process.alive?(&1)))
    GenServer.stop(owner)
  end

  test "no next block or finish is processed while a text offer is unresolved" do
    parent = self()
    peer = Peer.start(self(), fn mod, s -> Peer.response(mod, s, Fixture.complete()) end)

    sink = fn f ->
      send(parent, {:held_frame, self(), f})

      receive do
        :ack -> Fixture.ack(f)
      end
    end

    {:ok, owner} = Stream.__start_loopback__(Fixture.settings(ack_timeout_ms: 200), peer.origin)

    try do
      {:ok, h} = Stream.start(owner, Fixture.effect(), sink)
      assert_receive {:held_frame, worker, %Stream.Frame{seq: 0}}, 2_000
      session = :sys.get_state(owner).entries[h.ref].session

      # The sink can run before Session publishes its offer. Run the owner
      # fence from Session so its earlier summaries have the same sender.
      :sys.replace_state(session, fn s ->
        :sys.get_state(owner)
        s
      end)

      assert {:ok, snap} = Stream.status(owner, h)
      assert snap.raw_blocks == 3 and snap.offered_frames == 1 and not snap.source_complete
      send(:sys.get_state(owner).entries[h.ref].session, {:ack, make_ref(), 0})
      t = Fixture.terminal(h)
      assert t.reason == :sink_timeout and t.acknowledged_frames == 0
      refute Process.alive?(worker)
      refute_receive {:held_frame, _, %Stream.FinishFrame{}}, 0
    after
      if Process.alive?(owner), do: GenServer.stop(owner)
    end
  end

  test "finish cancel wins before ack and committed finish wins before later cancel" do
    for cancel_first <- [true, false] do
      parent = self()

      peer =
        Peer.start(self(), fn mod, s ->
          Peer.response(mod, s, Fixture.wire([Fixture.start(), Fixture.delta(), Fixture.stop()]))
        end)

      sink = fn f ->
        send(parent, {:finish_wait, self(), f})

        receive do
          :ack -> Fixture.ack(f)
        end
      end

      {:ok, owner} = Stream.__start_loopback__(Fixture.settings(), peer.origin)
      {:ok, h} = Stream.start(owner, Fixture.effect(), sink)
      assert_receive {:finish_wait, worker, %Stream.FinishFrame{}}, 2_000
      if cancel_first, do: assert({:ok, :pending} = Stream.cancel(owner, h))
      send(worker, :ack)
      t = Fixture.terminal(h)
      assert t.source_complete
      assert t.delivery_complete == not cancel_first
      assert {:ok, :already_terminal} = Stream.cancel(owner, h)
      GenServer.stop(owner)
    end
  end

  test "deadline at processing time defeats ack queued before a delayed timer" do
    parent = self()

    peer =
      Peer.start(self(), fn mod, s ->
        Peer.response(mod, s, Fixture.wire([Fixture.start(), Fixture.delta(), Fixture.stop()]))
      end)

    sink = fn f ->
      send(parent, {:finish_wait, self(), f})

      receive do
        :ack -> Fixture.ack(f)
      end
    end

    {:ok, owner} =
      Stream.__start_loopback__(
        Fixture.settings(total_timeout_ms: 250, receive_timeout_ms: 200, ack_timeout_ms: 200),
        peer.origin
      )

    {:ok, h} = Stream.start(owner, Fixture.effect(), sink)
    assert_receive {:finish_wait, worker, _}, 2_000
    session = :sys.get_state(owner).entries[h.ref].session
    :ok = :sys.suspend(session)
    send(worker, :ack)

    receive do
    after
      300 -> :ok
    end

    :ok = :sys.resume(session)
    t = Fixture.terminal(h)
    assert t.reason == :timeout and not t.delivery_complete and t.source_complete
    GenServer.stop(owner)
  end

  test "blocked headers and continuous pings spend the same total lifetime" do
    for ping <- [false, true] do
      peer =
        Peer.start(self(), fn mod, s ->
          if ping do
            Peer.response(mod, s, Fixture.wire([%{"type" => "ping"}]))
            # One bounded real ping stream; transport inactivity cannot reset D.
            Enum.reduce_while(1..200, :ok, fn _, _ ->
              receive do
              after
                5 -> :ok
              end

              if Peer.chunk(mod, s, Fixture.wire([%{"type" => "ping"}])) == :ok,
                do: {:cont, :ok},
                else: {:halt, :closed}
            end)
          end
        end)

      {:ok, owner} =
        Stream.__start_loopback__(
          Fixture.settings(total_timeout_ms: 200, receive_timeout_ms: 200, ack_timeout_ms: 100),
          peer.origin
        )

      {:ok, h} = Stream.start(owner, Fixture.effect(), &Fixture.ack/1)
      t = Fixture.terminal(h)
      assert t.reason == :timeout and not t.source_complete
      assert_receive {:peer_close, _, {:error, :closed}}, 2_000
      GenServer.stop(owner)
    end
  end

  test "owner and session abrupt kill preserve custody and independently close the peer" do
    for target <- [:owner, :session] do
      peer =
        Peer.start(self(), fn mod, s -> Peer.response(mod, s, Fixture.wire([Fixture.start()])) end)

      {:ok, owner} = Stream.__start_loopback__(Fixture.settings(capacity: 1), peer.origin)
      Process.unlink(owner)
      {:ok, h} = Stream.start(owner, Fixture.effect(), &Fixture.ack/1)
      assert_receive {:stream_request, _, _, _, _}, 2_000
      e = :sys.get_state(owner).entries[h.ref]
      session = :sys.get_state(e.session)

      pids = [
        e.session,
        e.sup,
        session.bootstrap,
        session.intent,
        session.adapter,
        session.http.pid
      ]

      refs = Enum.map(pids, &Process.monitor/1)
      Process.exit(if(target == :owner, do: owner, else: e.session), :kill)
      for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 2_000)
      assert_receive {:peer_close, _, {:error, :closed}}, 2_000

      if target == :session do
        assert Fixture.terminal(h).reason == :session_lost
        assert {:ok, %{phase: :retained}} = Stream.status(owner, h)
        GenServer.stop(owner)
      else
        assert {:error, :unavailable} = Stream.result(owner, h)
      end
    end
  end

  test "bad, spoofed and secret-bearing sink returns never acknowledge a finish" do
    for callback <- [
          fn f -> {:ack, make_ref(), f.seq} end,
          fn f -> {:ack, f.callback_ref, f.seq + 1} end,
          fn _ -> %{usage: 0} end,
          fn _ -> raise "SINK_SECRET" end,
          fn _ -> throw("SINK_SECRET") end,
          fn _ -> exit("SINK_SECRET") end
        ] do
      peer =
        Peer.start(self(), fn mod, s ->
          Peer.response(mod, s, Fixture.wire([Fixture.start(), Fixture.delta(), Fixture.stop()]))
        end)

      {:ok, owner} = Stream.__start_loopback__(Fixture.settings(), peer.origin)
      {:ok, h} = Stream.start(owner, Fixture.effect(), callback)
      t = Fixture.terminal(h)
      assert t.reason == :sink_failed and t.source_complete and not t.delivery_complete
      assert t.offered_frames == 1 and t.acknowledged_frames == 0
      assert {:provider_reported, _} = t.incurred_usage
      refute inspect(t) =~ "SINK_SECRET"
      GenServer.stop(owner)
    end
  end

  test "request construction ignores global Req defaults and fixes transport policy" do
    old = Application.get_env(:req, :default_options)

    on_exit(fn ->
      if is_nil(old),
        do: Application.delete_env(:req, :default_options),
        else: Application.put_env(:req, :default_options, old)
    end)

    Application.put_env(:req, :default_options,
      retry: true,
      redirect: true,
      auth: "GLOBAL_SECRET",
      params: [injected: "secret"]
    )

    request =
      Stream.Transport.request(
        "{}",
        "local-test-key",
        %{receive_timeout_ms: 100},
        fn _, acc -> {:cont, acc} end,
        :production
      )

    assert request.options.retry == false and request.options.redirect == false and
             request.options.raw

    assert request.options.decode_body == false and is_function(request.into, 2)
    refute Map.has_key?(request.options, :auth) or Map.has_key?(request.options, :params)
    assert request.options.finch[:protocols] == [:http1]
  end

  test "TLS loopback offers h2 but the actual request and constructed pool use only HTTP1" do
    cert = Path.expand("../fixtures/loopback-cert.pem", __DIR__)
    key = Path.expand("../fixtures/loopback-key.pem", __DIR__)

    peer =
      Peer.start(self(), fn mod, s -> Peer.response(mod, s, Fixture.complete()) end, {cert, key})

    {:ok, owner} =
      Stream.__start_loopback__(
        Fixture.settings(),
        peer.origin,
        Path.expand("../fixtures/loopback-ca.pem", __DIR__)
      )

    {:ok, h} = Stream.start(owner, Fixture.effect(), &Fixture.ack/1)
    t = Fixture.terminal(h)
    assert t.delivery_complete
    assert_receive {:stream_request, _, _, headers, _}, 2_000
    assert String.starts_with?(headers, "POST /v1/messages HTTP/1.1")
    assert_receive {:alpn, _, {:error, :protocol_not_negotiated}}, 2_000

    req =
      Stream.Transport.request(
        "{}",
        "test-key",
        %{receive_timeout_ms: 100},
        fn _, acc -> {:cont, acc} end,
        :production
      )

    assert req.options.finch[:protocols] == [:http1]
    assert req.options.finch[:conn_opts][:transport_opts][:timeout] == 5_000
    assert req.options.finch[:pool_max_idle_time] == 60_000
    GenServer.stop(owner)
  end

  # One loopback run through the public start: the frames that the sink took
  # and the terminal.
  defp loopback(
         body,
         effect \\ Fixture.effect(),
         settings \\ [],
         headers \\ [{"content-type", "text/event-stream"}]
       ) do
    peer = Peer.start(self(), fn mod, s -> Peer.response(mod, s, body, 200, headers) end)
    parent = self()
    tag = make_ref()

    sink = fn frame ->
      send(parent, {tag, frame})
      Fixture.ack(frame)
    end

    {:ok, owner} = Stream.__start_loopback__(Fixture.settings(settings), peer.origin)
    {:ok, h} = Stream.start(owner, effect, sink)
    t = Fixture.terminal(h)
    GenServer.stop(owner)
    {offered(tag), t}
  end

  # The frames that one sink offered, without the references of the run.
  defp offered(tag) do
    receive do
      {^tag, %module{seq: seq, chunk: chunk, completeness: c}} ->
        [{module, seq, chunk, c} | offered(tag)]
    after
      0 -> []
    end
  end
end
