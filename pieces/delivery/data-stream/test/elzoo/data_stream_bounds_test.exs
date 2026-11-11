# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/data_stream_test_helper.exs", __DIR__)

defmodule Elzoo.DataStream.BoundsTest do
  use ExUnit.Case, async: false
  alias Elzoo.DataStream, as: Stream
  alias Elzoo.DataStream.{Fixture, Peer, Terminal}

  setup do
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  test "actual HTTP raw total cap exact and plus one, with ignored comment bytes counted" do
    for extra <- [0, 1] do
      wire = Fixture.complete()
      body = padding(4_194_304 + extra - byte_size(wire)) <> wire
      peer = Peer.start(self(), fn mod, s -> Peer.response(mod, s, body) end)

      settings =
        Fixture.settings(total_timeout_ms: 30_000, receive_timeout_ms: 5_000, ack_timeout_ms: 1_000)

      {:ok, owner} = Stream.__start_loopback__(settings, peer.origin)
      {:ok, h} = Stream.start(owner, Fixture.effect(), &Fixture.ack/1)
      t = Fixture.terminal(h, 32_000)

      if extra == 0 do
        assert t.status == :complete and t.received_body_bytes == 4_194_304
      else
        assert t.reason == :receive_limit and not t.source_complete
        assert t.received_body_bytes > 4_194_304
        assert t.incurred_usage == :unknown
      end

      assert_receive {:peer_close, _, {:error, :closed}}, 2_000
      GenServer.stop(owner)
    end
  end

  test "unresolved request DOWN cannot offer finish even with a halted-result observation" do
    parent = self()

    peer =
      Peer.start(self(), fn mod, s ->
        Peer.response(mod, s, Fixture.wire([Fixture.start(), Fixture.delta()]))
      end)

    sink = fn f ->
      send(parent, {:unexpected_finish, f})
      Fixture.ack(f)
    end

    {:ok, owner} = Stream.__start_loopback__(Fixture.settings(), peer.origin)
    {:ok, h} = Stream.start(owner, Fixture.effect(), sink)
    assert_receive {:stream_request, _, _, _, _}, 2_000

    eventually(fn ->
      case Stream.status(owner, h) do
        {:ok, %{raw_blocks: 2, phase: :streaming}} -> true
        _ -> false
      end
    end)

    e = :sys.get_state(owner).entries[h.ref]
    session = e.session
    s = :sys.get_state(session)
    # Fault injection models a lost normal DOWN independently of a result.
    # The real HTTP task remains alive on its unfinished response.
    :sys.replace_state(session, fn st ->
      %{st | phase: :finishing, terminal: %{st.terminal | source_complete: true}}
    end)

    send(session, {s.http.ref, :source_stop})
    send(session, {:DOWN, make_ref(), :process, s.http.pid, :normal})
    send(session, {:ack, make_ref(), 0})
    assert {:ok, %{phase: :streaming, offered_frames: 0}} = Stream.status(owner, h)
    refute_receive {:unexpected_finish, _}, 50
    assert {:ok, :pending} = Stream.cancel(owner, h)
    assert Fixture.terminal(h).reason == :caller_cancelled
    GenServer.stop(owner)
  end

  test "forged internal sender cannot obtain handoff or offer authority" do
    parent = self()

    settings =
      Fixture.settings(
        credentials: fn ->
          send(parent, {:blocked_need, self()})

          receive do
            :release -> {:ok, "test-key"}
          end
        end
      )

    {:ok, owner} = Stream.start_link(settings)
    {:ok, h} = Stream.start(owner, Fixture.effect(), &Fixture.ack/1)
    assert_receive {:blocked_need, http}, 2_000
    session = :sys.get_state(owner).entries[h.ref].session
    s = :sys.get_state(session)
    assert :error = GenServer.call(session, {:handoff, s.token, http})

    assert {:error, :timeout} =
             GenServer.call(session, {:block, s.token, http, Fixture.wire([Fixture.stop()])})

    assert {:ok, :pending} = Stream.cancel(owner, h)
    assert Fixture.terminal(h).reason == :caller_cancelled
    GenServer.stop(owner)
  end

  test "simultaneous starts have one shared capacity winner at one and at four" do
    for capacity <- [1, 4] do
      parent = self()

      callers =
        for _ <- 1..12 do
          spawn_link(fn ->
            receive do
              {:go, owner, n} ->
                effect =
                  Fixture.effect(%{
                    "message_id" => "message-#{n}",
                    "idempotency_key" => "logical-#{n}"
                  })

                result = Stream.start(owner, effect, &Fixture.ack/1)
                send(parent, {:admitted, self(), result})

                receive do
                  :stop -> :ok
                end
            end
          end)
        end

      settings =
        Fixture.settings(
          capacity: capacity,
          authorized_callers: callers,
          credentials: fn ->
            receive do
              :release -> {:ok, "test-key"}
            end
          end
        )

      {:ok, owner} = Stream.start_link(settings)
      Enum.with_index(callers, fn pid, n -> send(pid, {:go, owner, n}) end)

      results =
        for _ <- callers do
          receive do
            {:admitted, _, result} -> result
          after
            2_000 -> flunk("admission stalled")
          end
        end

      assert Enum.count(results, &match?({:ok, _}, &1)) == capacity
      assert Enum.count(results, &(&1 == {:refused, :saturated})) == 12 - capacity
      assert map_size(:sys.get_state(owner).entries) == capacity
      for pid <- callers, do: send(pid, :stop)
      eventually(fn -> map_size(:sys.get_state(owner).entries) == 0 end)
      GenServer.stop(owner)
    end
  end

  test "retention expires on the common table and forgetting is never resend authority" do
    settings = Fixture.settings(capacity: 1, credentials: fn -> :error end)
    {:ok, owner} = Stream.start_link(settings)
    effect = Fixture.effect()
    {:ok, h} = Stream.start(owner, effect, &Fixture.ack/1)
    assert Fixture.terminal(h).reason == :credentials_unavailable
    assert {:ok, ^h} = Stream.lookup(owner, "message-1")

    assert {:refused, :saturated} =
             Stream.start(
               owner,
               Fixture.effect(%{"message_id" => "other", "idempotency_key" => "other"}),
               &Fixture.ack/1
             )

    receive do
    after
      5_020 -> :ok
    end

    assert {:error, :not_found} = Stream.lookup(owner, "message-1")
    assert {:error, :not_found} = Stream.result(owner, h)
    {:ok, h2} = Stream.start(owner, effect, &Fixture.ack/1)
    assert h2.ref != h.ref
    assert Fixture.terminal(h2).reason == :intent_unavailable
    GenServer.stop(owner)
  end

  test "exact retained duplicate remains inspectable after its original command expires" do
    settings = Fixture.settings(credentials: fn -> :error end)
    {:ok, owner} = Stream.start_link(settings)
    effect = Fixture.effect(%{"deadline_unix_ms" => System.system_time(:millisecond) + 100})
    sink = &Fixture.ack/1
    {:ok, h} = Stream.start(owner, effect, sink)
    Fixture.terminal(h)

    receive do
    after
      120 -> :ok
    end

    assert {:ok, ^h} = Stream.start(owner, effect, sink)

    assert {:refused, :identity_conflict} =
             Stream.start(
               owner,
               put_in(
                 effect,
                 ["command", "deadline_unix_ms"],
                 System.system_time(:millisecond) + 1000
               ),
               sink
             )

    GenServer.stop(owner)
  end

  test "timed-out admission and control are unknown and queued commands can still apply" do
    settings =
      Fixture.settings(
        total_timeout_ms: 10_000,
        credentials: fn ->
          receive do
            :release -> {:ok, "test-key"}
          end
        end
      )

    {:ok, owner} = Stream.start_link(settings)
    :ok = :sys.suspend(owner)

    resumer =
      Task.async(fn ->
        receive do
        after
          1_100 -> :sys.resume(owner)
        end
      end)

    assert {:unknown, :admission} = Stream.start(owner, Fixture.effect(), &Fixture.ack/1)
    Task.await(resumer)
    assert {:ok, h} = Stream.lookup(owner, "message-1")
    :ok = :sys.suspend(owner)

    resumer =
      Task.async(fn ->
        receive do
        after
          1_100 -> :sys.resume(owner)
        end
      end)

    assert {:unknown, :control} = Stream.cancel(owner, h)
    Task.await(resumer)
    assert Fixture.terminal(h).reason == :caller_cancelled
    GenServer.stop(owner)
  end

  test "an already expired HTTP worker never invokes even its credential Need" do
    parent = self()

    config = %{
      credentials: fn ->
        send(parent, :late_credentials)
        {:ok, "test-key"}
      end
    }

    assert :timeout =
             Stream.Transport.run(
               self(),
               make_ref(),
               %{deadline: System.monotonic_time(:millisecond) - 1},
               config,
               :production
             )

    refute_receive :late_credentials, 0
  end

  test "inspection and OTP status contain no prompt, output, credential, usage or identifiers" do
    parent = self()

    settings =
      Fixture.settings(
        credentials: fn ->
          send(parent, {:need, self()})

          receive do
            :release -> {:ok, "SENSITIVE_KEY"}
          end
        end
      )

    {:ok, owner} = Stream.start_link(settings)
    {:ok, h} = Stream.start(owner, Fixture.effect(), &Fixture.ack/1)
    assert_receive {:need, _}, 2_000
    e = :sys.get_state(owner).entries[h.ref]
    s = :sys.get_state(e.session)

    inspected =
      inspect([
        h,
        s,
        :sys.get_state(owner),
        s.config,
        s.protocol,
        s.terminal,
        :sys.get_status(owner),
        :sys.get_status(e.session)
      ])

    for secret <- [
          "private prompt",
          "SENSITIVE_KEY",
          "message-1",
          "logical-1",
          "workspace-test",
          "tenant-test",
          "last_usage",
          "input_tokens"
        ] do
      refute inspected =~ secret
    end

    {:ok, snapshot} = Stream.status(owner, h)

    assert Enum.sort(Map.keys(snapshot)) ==
             Enum.sort([
               :phase,
               :reason,
               :source_complete,
               :delivery_complete,
               :offered_frames,
               :acknowledged_frames,
               :received_body_bytes,
               :raw_blocks
             ])

    assert Terminal.maximal_size() <= 4096
    assert {:ok, :pending} = Stream.cancel(owner, h)
    t = Fixture.terminal(h)
    assert Terminal.size(t) <= 4096
    GenServer.stop(owner)
  end

  defp padding(n) do
    full = ":" <> String.duplicate("x", 65_533) <> "\n\n"
    r = rem(n, 65_536)

    suffix =
      if r < 3, do: String.duplicate("\n", r), else: ":" <> String.duplicate("x", r - 3) <> "\n\n"

    String.duplicate(full, div(n, 65_536)) <> suffix
  end

  defp eventually(f, n \\ 100)
  defp eventually(f, 0), do: assert(f.())

  defp eventually(f, n),
    do:
      if(f.(),
        do: :ok,
        else:
          receive do
          after
            10 -> eventually(f, n - 1)
          end
      )
end
