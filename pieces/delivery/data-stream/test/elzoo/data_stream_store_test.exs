# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/data_stream_test_helper.exs", __DIR__)

defmodule Elzoo.DataStream.BlockingHost do
  def activate({parent, token}, _) do
    send(parent, {:blocked_activation, self(), token})

    receive do
      :release -> {:read_only, :refused}
    end
  end
end

defmodule Elzoo.DataStream.WrongMappingBinding do
  def __data_stream_binding__, do: true

  use Elzoo.EffectIntent.Binding,
    adapter: Elzoo.DataStream.Adapter,
    id: "wrong-mapping",
    provider_account: "workspace-test",
    operation: "generate_stream",
    clock: "unix-ms",
    replay: :none,
    revision: :forbidden,
    recovery_grace_ms: :none,
    failures:
      Map.put(
        Elzoo.DataStream.Binding.failures(),
        :credentials_unavailable,
        {"timed_out", "unknown", "unclassified"}
      ),
    no_send_attestations: []
end

defmodule Elzoo.DataStream.StoreTest do
  use ExUnit.Case, async: false
  alias Elzoo.DataStream, as: Stream
  alias Elzoo.DataStream.{Fixture, Peer}
  alias Elzoo.DurableLog.Memory

  setup do
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  test "construction checks the helper and exact failure table beyond generic Binding exhaustiveness" do
    settings = Fixture.settings(binding: Stream.WrongMappingBinding)
    assert {:error, :configuration} = Stream.start_link(settings)
  end

  test "failed and indeterminate intended barriers never ask for credentials or HTTP" do
    parent = self()
    peer = Peer.start(self(), fn mod, s -> Peer.response(mod, s, Fixture.complete()) end)

    for {op, mode} <- [
          {:append, :unavailable},
          {:append, :reply_loss},
          {:put_checkpoint, :unavailable},
          {:put_checkpoint, :reply_loss},
          {:append, {:pause, :later}}
        ] do
      settings =
        Fixture.settings(
          credentials: fn ->
            send(parent, :credentials)
            {:ok, "test-key"}
          end
        )

      :ok = Memory.fault(settings[:store], op, mode)
      {:ok, owner} = Stream.__start_loopback__(settings, peer.origin)
      {:ok, h} = Stream.start(owner, Fixture.effect(), &Fixture.ack/1)
      t = Fixture.terminal(h)
      assert t.reason == :intent_unavailable and not t.delivery_complete
      refute_receive :credentials, 0
      refute_receive {:stream_request, _, _, _, _}, 0

      if match?({:pause, _}, mode) do
        Memory.release(settings[:store], :later)
        refute_receive :credentials, 10
      end

      GenServer.stop(owner)
    end
  end

  test "activation blocked beyond D is cleaned without a late launch grant" do
    token = make_ref()

    settings =
      Fixture.settings(
        host: {Stream.BlockingHost, {self(), token}},
        total_timeout_ms: 100,
        receive_timeout_ms: 100,
        ack_timeout_ms: 50
      )

    {:ok, owner} = Stream.start_link(settings)
    {:ok, h} = Stream.start(owner, Fixture.effect(), &Fixture.ack/1)
    assert_receive {:blocked_activation, worker, ^token}, 1_000
    assert {:ok, %{phase: :preparing}} = Stream.status(owner, h)
    t = Fixture.terminal(h)
    assert t.reason == :timeout
    refute Process.alive?(worker)
    send(worker, :release)
    GenServer.stop(owner)
  end

  test "credentials failure is the only no-send tag; neither duplicate nor forgetting rearms" do
    parent = self()
    peer = Peer.start(self(), fn mod, s -> Peer.response(mod, s, Fixture.complete()) end)

    for credentials <- [
          fn -> :error end,
          fn -> {:ok, "bad key"} end,
          fn -> raise "private credential error" end,
          fn -> throw(:private) end,
          fn -> exit(:private) end
        ] do
      settings =
        Fixture.settings(
          credentials: fn ->
            send(parent, :credential_attempt)
            credentials.()
          end
        )

      {:ok, owner} = Stream.__start_loopback__(settings, peer.origin)
      effect = Fixture.effect()
      sink = &Fixture.ack/1
      {:ok, h} = Stream.start(owner, effect, sink)
      assert_receive :credential_attempt, 1_000
      t = Fixture.terminal(h)
      assert t.reason == :credentials_unavailable and t.status == :refused
      assert {:ok, ^h} = Stream.start(owner, effect, sink)
      refute_receive :credential_attempt, 0
      assert {:ok, :closed} = Stream.close(owner, h)
      {:ok, again} = Stream.start(owner, effect, sink)
      assert Fixture.terminal(again).reason == :intent_unavailable
      refute_receive :credential_attempt, 0
      refute_receive {:stream_request, _, _, _, _}, 0
      GenServer.stop(owner)
    end
  end

  test "malformed and duplicate event JSON settle as the declared malformed response" do
    for raw <- ["{", ~s({"type":"ping","type":"ping"})] do
      peer =
        Peer.start(self(), fn mod, socket ->
          Peer.response(
            mod,
            socket,
            Fixture.wire([Fixture.start()]) <> "event: ping\ndata: " <> raw <> "\n\n"
          )
        end)

      settings = Fixture.settings()
      {:ok, owner} = Stream.__start_loopback__(settings, peer.origin)
      {:ok, h} = Stream.start(owner, Fixture.effect(), &Fixture.ack/1)
      t = Fixture.terminal(h)
      assert t.reason == :malformed_response and t.status == :partial
      assert t.intent_confirmation == :confirmed
      stream = Elzoo.EffectIntent.Model.stream(t.correlation.intent_key)
      {:ok, row, _} = Elzoo.DurableLog.Store.read(settings[:store], :read_at, [stream, 3])
      {:ok, {:step, 1, event, _, _, _}} = Elzoo.EffectIntent.Model.decode_term(row.payload, 131_072)
      assert event == :Lost
      GenServer.stop(owner)
    end
  end

  test "public handle and wrong observation fences cannot forge or rewrite outcomes" do
    parent = self()

    settings =
      Fixture.settings(
        credentials: fn ->
          send(parent, :blocked_need)

          receive do
            :never -> :error
          end
        end
      )

    {:ok, owner} = Stream.start_link(settings)
    {:ok, h} = Stream.start(owner, Fixture.effect(), &Fixture.ack/1)
    assert_receive :blocked_need, 2_000
    e = :sys.get_state(owner).entries[h.ref]

    fake = %Stream.Terminal{
      status: :complete,
      reason: :completed,
      source_complete: true,
      delivery_complete: true
    }

    send(owner, {:summary, h.ref, :finishing, fake})
    send(owner, {:summary, h.ref, make_ref(), h.generation, e.session, :finishing, fake})
    send(owner, {:settled, h.ref, e.observation_fence, make_ref(), e.session, fake})
    assert {:ok, %{delivery_complete: false, source_complete: false}} = Stream.status(owner, h)
    assert {:ok, :pending} = Stream.cancel(owner, h)
    t = Fixture.terminal(h)
    assert t.reason == :caller_cancelled and not t.delivery_complete
    send(owner, {:settled, h.ref, e.observation_fence, h.generation, e.session, fake})
    assert {:ok, ^t} = Stream.result(owner, h)
    GenServer.stop(owner)
  end

  test "post-200 error usage stays interim and never retries a charged request" do
    error = %{
      "type" => "error",
      "error" => %{"type" => "overloaded_error", "message" => "private provider error"}
    }

    peer =
      Peer.start(self(), fn mod, s ->
        Peer.response(mod, s, Fixture.wire([Fixture.start(), Fixture.delta(), error]))
      end)

    settings = Fixture.settings()
    {:ok, owner} = Stream.__start_loopback__(settings, peer.origin)
    effect = Fixture.effect()
    sink = &Fixture.ack/1
    {:ok, h} = Stream.start(owner, effect, sink)
    t = Fixture.terminal(h)

    assert t.status == :partial and t.reason == :stream_error and
             t.provider_reason == :overloaded_error

    assert t.incurred_usage == :unknown
    assert Elzoo.AiModel.Usage.amount(t.last_usage.usage, :output_tokens) == 5
    assert_receive {:stream_request, _, _, _, _}, 2_000
    assert {:ok, :closed} = Stream.close(owner, h)
    {:ok, h2} = Stream.start(owner, effect, sink)
    assert Fixture.terminal(h2).reason == :intent_unavailable
    refute_receive {:stream_request, _, _, _, _}, 20
    GenServer.stop(owner)
  end
end
