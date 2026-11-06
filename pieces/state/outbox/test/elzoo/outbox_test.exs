# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.OutboxTest do
  use ExUnit.Case, async: false
  alias Elzoo.Outbox
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Memory, Record}
  @limits %{max_record_bytes: 64, max_batch_size: 8, max_checkpoint_bytes: 10_000}
  defp fold,
    do: %{
      initial: 0,
      kinds: %{"added" => :state_bearing},
      versions: [1],
      destinations: ["sink"],
      reduce: fn n, _, _, _ -> n + 1 end
    }

  defp row(n, nonce \\ <<1::128>>) do
    r = %Record{
      stream: "s/with/slashes",
      sequence: n,
      kind: "added",
      schema_version: 1,
      payload: "event",
      nonce: nonce
    }

    %{r | digest: Log.digest(r)}
  end

  defp item(seq, pos \\ 1), do: Outbox.new("s/with/slashes", seq, pos, "sink", "body", <<1::128>>)

  setup do
    pid = start_supervised!({Memory, fold: fold(), limits: @limits})
    %{store: Memory.store(pid, %{fold: fold()})}
  end

  test "D12/D13 pending stable identities, ack CAS, no ack before commit", %{store: s} do
    i = item(1)
    assert {:ok, {"s/with/slashes", 1, 1}} = Outbox.parse_id(i.idempotency_key)

    for bad <- ["s/01/1", "s/1/0", "s/1", "s/1/1junk"] do
      assert {:error, :invalid_outbox_item} = Outbox.parse_id(bad)
    end

    assert {:conflict, _} = Outbox.ack(s, i.idempotency_key, <<2::128>>)
    assert {:committed, 1} = Memory.append(s, i.stream, 0, [row(1)], [i, item(1, 2)])
    assert {:ok, [^i, second]} = Outbox.pending(s, i.stream, 10)
    assert {:ok, [^i, ^second]} = Outbox.pending(s, i.stream, 10)
    assert {:committed, 1} = Outbox.ack(s, i.idempotency_key, <<2::128>>)
    assert {:conflict, _} = Outbox.ack(s, i.idempotency_key, <<3::128>>)
    assert {:ok, [^second]} = Outbox.pending(s, i.stream, 10)
    assert {:committed, 1} = Log.confirm_ack(s, Codec.ack_receipt(i.idempotency_key, <<2::128>>))
    assert :superseded = Log.confirm_ack(s, Codec.ack_receipt(i.idempotency_key, <<3::128>>))
  end

  test "paused ack pending means unknown; late ack confirms or competing ack fences", %{store: s} do
    i = item(1)
    Memory.append(s, i.stream, 0, [row(1)], [i, item(1, 2)])

    for {id, token} <- [{i.idempotency_key, 1}, {item(1, 2).idempotency_key, 2}] do
      Memory.fault(s, :ack, {:pause, token})
      assert {:indeterminate, %{cause: :timeout}} = Outbox.ack(s, id, <<2::128>>)
      req = Codec.ack_receipt(id, <<2::128>>)
      assert {:unknown, :unfenced} = Log.confirm_ack(s, req)

      if token == 1 do
        assert {:committed, 1} = Memory.release(s, token)
        assert {:committed, 1} = Log.confirm_ack(s, req)
      else
        assert {:committed, 1} = Outbox.ack(s, id, <<3::128>>)
        assert {:conflict, _} = Memory.release(s, token)
        assert :superseded = Log.confirm_ack(s, req)
      end
    end
  end

  test "D22 retention blocks pending children, deletes only acked children and records, prunes ack evidence",
       %{store: s} do
    rows = [row(1), row(2), row(3)]
    items = [item(1), item(2), item(3)]
    stream = hd(items).stream
    Memory.append(s, stream, 0, rows, items)
    state = Log.replay(rows, 3, fold())

    c = %{
      stream: stream,
      sequence: 3,
      fold_version: 1,
      model: "3",
      cursor: state.cursor,
      seen: state.seen,
      nonce: <<8::128>>
    }

    c = Map.put(c, :digest, Codec.hash(Codec.checkpoint_bytes(c)))
    assert {:committed, 3} = Memory.put_checkpoint(s, c)
    before = Memory.inspect_state(s)

    assert {:rejected, :retention_beyond_pending_outbox} =
             Memory.retain(s, stream, 0, 2, <<3::128>>)

    assert Memory.inspect_state(s) == before

    for i <- [item(1), item(3)],
        do: assert({:committed, i.sequence} == Outbox.ack(s, i.idempotency_key, <<4::128>>))

    assert {:rejected, :retention_beyond_pending_outbox} =
             Memory.retain(s, stream, 0, 2, <<3::128>>)

    assert {:committed, 1} = Memory.retain(s, stream, 0, 1, <<3::128>>)
    assert {:ok, [second]} = Outbox.pending(s, stream, 10)
    assert second.sequence == 2
    assert {:ok, %{state: :acked}} = Memory.read_ack(s, item(3).idempotency_key)

    assert {:unknown, :unfenced} =
             Log.confirm_ack(s, Codec.ack_receipt(item(1).idempotency_key, <<4::128>>))

    assert {:committed, 2} = Outbox.ack(s, item(2).idempotency_key, <<4::128>>)
    assert {:committed, 2} = Memory.retain(s, stream, 1, 2, <<5::128>>)
    assert {:conflict, _} = Memory.retain(s, stream, 0, 3, <<6::128>>)
    assert {:ok, %{revision: 3, low_water: 2}} = Memory.head(s, stream)
    assert {:ok, _, %{revision: 3}} = Memory.read_at(s, stream, 3)
  end

  defmodule ReadOnly do
    def pending({__MODULE__, opts}, stream, limit),
      do: Memory.pending({Memory, opts}, stream, limit)

    def head({__MODULE__, opts}, stream), do: Memory.head({Memory, opts}, stream)

    def ack(_, _, _), do: raise("reader attempted ack")
    def append(_, _, _, _, _), do: raise("reader attempted append")
  end

  test "pending reader audit and malformed row rejection; unavailable ack is indeterminate", %{
    store: s
  } do
    i = item(1)
    Memory.append(s, i.stream, 0, [row(1)], [i])
    before = Memory.inspect_state(s)
    assert {:ok, [^i]} = Outbox.pending({ReadOnly, elem(s, 1)}, i.stream, 10)
    assert Memory.inspect_state(s) == before
    Memory.fault(s, :ack, :unavailable)
    assert {:indeterminate, %{cause: :unavailable}} = Outbox.ack(s, i.idempotency_key, <<3::128>>)
    Memory.corrupt(s, :items, i.idempotency_key, %{digest: <<0::256>>})
    assert {:error, :malformed} = Outbox.pending(s, i.stream, 10)

    assert {:unknown, :malformed} =
             Log.confirm_ack(s, Codec.ack_receipt(i.idempotency_key, <<3::128>>))
  end

  test "untrusted pending rows must match declared destinations and size limits", %{store: s} do
    i = item(1)
    Memory.append(s, i.stream, 0, [row(1)], [i])

    for changes <- [%{destination: "undeclared"}, %{payload: String.duplicate("x", 65)}] do
      changed = Map.merge(i, changes)
      changed = %{changed | digest: Codec.hash(Codec.item_bytes(changed))}
      Memory.corrupt(s, :items, i.idempotency_key, Map.from_struct(changed))
      assert {:error, :malformed} = Outbox.pending(s, i.stream, 10)
    end
  end
end
