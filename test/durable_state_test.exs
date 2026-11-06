# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableStateCompositionTest do
  use ExUnit.Case, async: false
  alias Elzoo.{Checkpoint, Outbox}
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Memory, Writer}
  @limits %{max_record_bytes: 64, max_batch_size: 8, max_checkpoint_bytes: 10_000}
  defp fold,
    do: %{
      initial: 0,
      kinds: %{"added" => :state_bearing},
      versions: [1],
      destinations: ["sink"],
      reduce: fn n, _, _, _ -> n + 1 end
    }

  defp decode(bytes), do: {:ok, String.to_integer(bytes)}

  defp start_writer(store, opts \\ []) do
    result =
      Writer.start_link(
        Keyword.merge(
          [
            store: store,
            stream: "joined",
            fold: fold(),
            limits: @limits,
            checkpoint: %{fold_version: 1, decode: &decode/1}
          ],
          opts
        )
      )

    if match?({:ok, _}, result) do
      {:ok, writer} = result
      Process.unlink(writer)
      on_exit(fn -> if Process.alive?(writer), do: GenServer.stop(writer) end)
    end

    result
  end

  setup do
    Process.flag(:trap_exit, true)
    pid = start_supervised!({Memory, fold: fold(), limits: @limits})
    %{store: Memory.store(pid)}
  end

  test "Writer checkpoint + Outbox ack + retain-through-head recovers without truncation", %{
    store: s
  } do
    {:ok, writer} = start_writer(s)

    assert {:committed, 2} =
             Writer.append(writer, List.duplicate({"added", 1, "event"}, 2), [
               {"sink", "first"},
               {"sink", "second"}
             ])

    snapshot = Writer.snapshot(writer)
    assert {:committed, 2} = Checkpoint.take(writer, "joined", 1, &Integer.to_string/1)
    assert {:ok, [first, second]} = Outbox.pending(s, "joined", 10)
    assert {:committed, 2} = Outbox.ack(s, first.idempotency_key, <<2::128>>)

    assert {:rejected, :retention_beyond_pending_outbox} =
             Memory.retain(s, "joined", 0, 2, <<3::128>>)

    assert {:committed, 2} = Outbox.ack(s, second.idempotency_key, <<4::128>>)
    assert {:committed, 2} = Memory.retain(s, "joined", 0, 2, <<3::128>>)
    GenServer.stop(writer)

    assert %{cursor: {2, false, []}} =
             recovered = Checkpoint.recover(s, "joined", fold(), 1, &decode/1)

    assert recovered == snapshot
    {:ok, restarted} = start_writer(s)
    assert Writer.snapshot(restarted) == snapshot
    assert {:committed, 3} = Writer.append(restarted, [{"added", 1, "event"}], [{"sink", "third"}])
    assert %{model: 3, cursor: {3, false, []}} = Writer.snapshot(restarted)
    assert {:ok, [third]} = Outbox.pending(s, "joined", 10)
    assert third.idempotency_key == "joined/3/1"

    assert {:unknown, :unfenced} =
             Log.confirm_ack(s, Codec.ack_receipt(first.idempotency_key, <<2::128>>))
  end

  test "gap-only checkpoint recover returns the damaged model; Writer refuses it without mutation",
       %{store: s} do
    {:ok, writer} = start_writer(s)
    assert {:committed, 3} = Writer.append(writer, List.duplicate({"added", 1, "event"}, 3))
    GenServer.stop(writer)

    :sys.replace_state(elem(s, 1).pid, fn state ->
      %{state | records: Map.delete(state.records, {"joined", 2})}
    end)

    assert {:ok, rows, head} = Log.read(s, "joined", 1, 10)
    assert %{model: 2, cursor: {3, true, [{3, :gap}]}} = damaged = Log.replay(rows, head, fold())

    assert {:committed, 3} =
             Checkpoint.take({s, damaged, @limits}, "joined", 1, &Integer.to_string/1)

    before = Memory.inspect_state(s)
    assert Checkpoint.recover(s, "joined", fold(), 1, &decode/1) == damaged
    assert {:error, {:replay_damaged, [{3, :gap}]}} = start_writer(s)
    assert Memory.inspect_state(s) == before
  end

  test "writer-form checkpoint grows with seen witnesses and rejects over-limit without provider calls",
       %{store: s} do
    limits = %{@limits | max_checkpoint_bytes: 400}
    {:ok, writer} = start_writer(s, limits: limits)
    assert {:committed, 1} = Writer.append(writer, [{"added", 1, "event"}])
    assert {:committed, 1} = Checkpoint.take(writer, "joined", 1, &Integer.to_string/1)
    assert {:ok, small} = Memory.read_checkpoint(s, "joined", 1, 1)
    assert {:committed, 9} = Writer.append(writer, List.duplicate({"added", 1, "event"}, 8))
    snapshot = Writer.snapshot(writer)
    big = %{small | sequence: 9, model: "9", cursor: snapshot.cursor, seen: snapshot.seen}
    assert byte_size(Checkpoint.canonical_bytes(big)) > byte_size(Checkpoint.canonical_bytes(small))
    Memory.fault(s, :put_checkpoint, :malformed)
    before = Memory.inspect_state(s)

    assert {:rejected, :checkpoint_too_large} =
             Checkpoint.take(writer, "joined", 1, &Integer.to_string/1)

    assert Memory.inspect_state(s) == before
    assert Writer.snapshot(writer) == snapshot

    assert {:error, :encode_failure} =
             Checkpoint.take(writer, "joined", 1, fn _ -> raise "private" end)

    assert {:rejected, :invalid_stream} = Checkpoint.take(writer, "wrong", 1, &Integer.to_string/1)
  end

  test "D15 writer-owned checkpoint indeterminate stops; exact checkpoint request reconciles", %{
    store: s
  } do
    {:ok, writer} = start_writer(s)
    assert {:committed, 1} = Writer.append(writer, [{"added", 1, "event"}])
    snapshot = Writer.snapshot(writer)
    monitor = Process.monitor(writer)
    Memory.fault(s, :put_checkpoint, :reply_loss)
    assert {:indeterminate, info} = Checkpoint.take(writer, "joined", 1, &Integer.to_string/1)
    assert_receive {:DOWN, ^monitor, :process, ^writer, {:shutdown, {:indeterminate_write, ^info}}}
    assert {:ok, checkpoint} = Memory.read_checkpoint(s, "joined", 1, 1)
    assert {:committed, 1} = Log.confirm_checkpoint(s, checkpoint)
    {:ok, restarted} = start_writer(s, reconcile: Map.put(info, :checkpoint, checkpoint))
    assert Writer.snapshot(restarted) == snapshot
    monitor = Process.monitor(restarted)
    Memory.fault(s, :put_checkpoint, {:pause, :checkpoint})

    assert {:indeterminate, paused_info} =
             Checkpoint.take(restarted, "joined", 2, &Integer.to_string/1)

    assert_receive {:DOWN, ^monitor, :process, ^restarted,
                    {:shutdown, {:indeterminate_write, ^paused_info}}}

    pending = %{checkpoint | fold_version: 2, nonce: paused_info.nonce, digest: paused_info.digest}
    request = Map.put(paused_info, :checkpoint, pending)
    assert {:error, {:storage, :unfenced}} = start_writer(s, reconcile: request)
    assert {:committed, 1} = Memory.release(s, :checkpoint)
    {:ok, reconciled} = start_writer(s, reconcile: request)
    assert Writer.snapshot(reconciled) == snapshot
  end
end
