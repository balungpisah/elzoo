# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableLogMemoryTest do
  use ExUnit.Case, async: false
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Memory, Record, Store}
  @limits %{max_record_bytes: 64, max_batch_size: 8, max_checkpoint_bytes: 10_000}
  defp fold,
    do: %{
      initial: 0,
      kinds: %{"added" => :state_bearing},
      versions: [1],
      destinations: ["sink"],
      reduce: fn n, _, _, p -> n + String.to_integer(p) end
    }

  setup do
    pid = start_supervised!({Memory, fold: fold(), limits: @limits})
    %{store: Memory.store(pid, %{fold: fold()})}
  end

  defp row(seq, nonce \\ <<1::128>>) do
    r = %Record{
      stream: "s",
      sequence: seq,
      kind: "added",
      schema_version: 1,
      payload: "2",
      nonce: nonce
    }

    %{r | digest: Log.digest(r)}
  end

  defp checkpoint(state, seq, changes \\ %{}) do
    c =
      Map.merge(
        %{
          stream: "s",
          sequence: seq,
          fold_version: 1,
          model: "#{state.model}",
          cursor: state.cursor,
          seen: state.seen,
          nonce: <<2::128>>
        },
        changes
      )

    Map.put(c, :digest, Codec.hash(Codec.checkpoint_bytes(c)))
  end

  test "head CAS, immutable sequence and exact readback", %{store: s} do
    r = row(1)
    assert {:committed, 1} = Memory.append(s, "s", 0, [r], [])
    assert {:conflict, %{expected: 0, observed: 1}} = Memory.append(s, "s", 0, [r], [])
    assert {:ok, ^r, %{revision: 1}} = Memory.read_at(s, "s", 1)
    assert {:committed, 1} = Log.confirm(s, "s", 0, r.nonce, [r])
    assert :superseded = Log.confirm(s, "s", 0, <<3::128>>, [row(1, <<3::128>>)])
    assert {:unknown, :unfenced} = Log.confirm(s, "s", 1, <<3::128>>, [row(2, <<3::128>>)])
    assert %{records: records} = Memory.inspect_state(s)
    assert map_size(records) == 1
  end

  test "paused append absence never proves rollback; late commit or competing CAS fences", %{
    store: s
  } do
    for expected <- [0, 1] do
      r = row(expected + 1, <<expected + 1::128>>)
      assert :ok = Memory.fault(s, :append, {:pause, expected})

      assert {:indeterminate, %{cause: :timeout, operation: :append, target: target}} =
               Memory.append(s, "s", expected, [r], [])

      assert target == expected + 1
      assert {:unknown, :unfenced} = Log.confirm(s, "s", expected, r.nonce, [r])

      if expected == 0 do
        assert {:committed, 1} = Memory.release(s, expected)
        assert {:committed, 1} = Log.confirm(s, "s", expected, r.nonce, [r])
      else
        assert {:committed, 2} = Memory.append(s, "s", expected, [row(2, <<9::128>>)], [])
        assert {:conflict, _} = Memory.release(s, expected)
        assert :superseded = Log.confirm(s, "s", expected, r.nonce, [r])
      end
    end
  end

  test "reply loss, malformed/unavailable reads, committed last-row corruption", %{store: s} do
    r = row(1)
    Memory.fault(s, :append, :reply_loss)

    assert {:indeterminate, %{cause: :unavailable, nonce: nonce, digest: digest}} =
             Memory.append(s, "s", 0, [r], [])

    assert nonce == r.nonce and is_binary(digest)
    assert {:committed, 1} = Log.confirm(s, "s", 0, r.nonce, [r])
    Memory.fault(s, :read, :unavailable)
    assert {:error, :unavailable} = Log.read(s, "s", 1, 10)
    Memory.fault(s, :read, :malformed)
    assert {:error, :malformed} = Log.read(s, "s", 1, 10)
    Memory.corrupt(s, :records, {"s", 1}, %{digest: <<0::256>>})
    assert {:ok, rows, head} = Log.read(s, "s", 1, 10)

    assert %{model: 0, cursor: {0, true, [{:corrupt, 1, :digest_mismatch}]}} =
             Log.replay(rows, head, fold())

    assert {:unknown, :malformed} = Log.confirm(s, "s", 0, r.nonce, [r])
    assert {:rejected, :unfenced_tail} = Memory.repair_torn_tail(s, "s", 1, r.nonce, <<3::128>>)
  end

  test "D16 staged append is read-only, requires fenced repair and cannot resurrect", %{store: s} do
    r = row(1)
    Memory.fault(s, :append, :stage)
    assert {:indeterminate, _} = Memory.append(s, "s", 0, [r], [])
    assert {:ok, rows, head} = Log.read(s, "s", 1, 10)
    assert %{model: 0, cursor: {0, false, []}, tail: :torn} = Log.replay(rows, head, fold())
    assert {:rejected, :unfenced_tail} = Memory.repair_torn_tail(s, "s", 0, r.nonce, <<4::128>>)
    Memory.fence(s, r.nonce)
    Memory.fault(s, :repair_torn_tail, :reply_loss)
    assert {:indeterminate, _} = Memory.repair_torn_tail(s, "s", 0, r.nonce, <<4::128>>)
    receipt = Codec.receipt(:repair_torn_tail, "s", 0, 0, <<4::128>>, r.nonce)
    assert {:committed, 0} = Log.confirm_repair(s, receipt)
    assert {:ok, %{revision: 0, low_water: 0}} = Memory.head(s, "s")
    assert {:conflict, _} = Memory.release(s, r.nonce)
    assert {:committed, 1} = Memory.append(s, "s", 0, [row(1, <<5::128>>)], [])
  end

  test "checkpoint immutable insert, beyond-tail, retention receipts and overwritten evidence", %{
    store: s
  } do
    rows = [row(1), row(2)]
    assert {:committed, 2} = Memory.append(s, "s", 0, rows, [])
    state = Log.replay(rows, 2, fold())
    c = checkpoint(state, 2)
    assert {:committed, 2} = Memory.put_checkpoint(s, c)
    assert {:conflict, _} = Memory.put_checkpoint(s, c)
    assert {:committed, 2} = Log.confirm_checkpoint(s, c)
    other = checkpoint(state, 2, %{nonce: <<8::128>>})
    assert :superseded = Log.confirm_checkpoint(s, other)
    future = checkpoint(Log.replay([row(3)], 3, fold()), 3)
    assert {:rejected, :checkpoint_beyond_tail} = Memory.put_checkpoint(s, future)
    Memory.fault(s, :retain, :reply_loss)
    assert {:indeterminate, _} = Memory.retain(s, "s", 0, 1, <<4::128>>)
    receipt = Codec.receipt(:retain, "s", 0, 1, <<4::128>>)
    assert {:committed, 1} = Log.confirm_retention(s, receipt)
    assert {:committed, 2} = Memory.retain(s, "s", 1, 2, <<5::128>>)
    assert {:unknown, :unfenced} = Log.confirm_retention(s, receipt)
    assert {:error, {:pruned, 2}} = Memory.read_at(s, "s", 1)
  end

  defmodule BadStore do
    def append({_, mode}, _, _, _, _) do
      case mode do
        :raise -> raise "private"
        :throw -> throw(:private)
        :exit -> exit(:private)
        :timeout -> exit({:timeout, :private})
        :malformed -> {:committed, 99}
        :unavailable -> {:error, :unavailable}
      end
    end
  end

  test "safe write shell bounds all foreign failures and validates result target" do
    req = %{
      operation: :append,
      stream: "s",
      expected: 0,
      target: 1,
      nonce: <<1::128>>,
      digest: <<0::256>>
    }

    for {mode, cause} <- [
          raise: :exception,
          throw: :exception,
          exit: :exit,
          timeout: :timeout,
          malformed: :malformed_reply,
          unavailable: :unavailable
        ] do
      assert {:indeterminate, info} =
               Store.write({BadStore, mode}, :append, ["s", 0, [row(1)], []], req)

      assert info == Map.put(req, :cause, cause)
    end
  end

  test "static rejected append leaves every table untouched", %{store: s} do
    before = Memory.inspect_state(s)
    assert {:rejected, :empty_batch} = Memory.append(s, "s", 0, [], [])
    assert Memory.inspect_state(s) == before
    assert {:rejected, :unknown_kind} = Memory.append(s, "s", 0, [%{row(1) | kind: "unknown"}], [])
    assert Memory.inspect_state(s) == before
    Memory.fault(s, :append, :malformed)

    req = %{
      operation: :append,
      stream: "s",
      expected: 0,
      target: 1,
      nonce: row(1).nonce,
      digest: <<0::256>>
    }

    assert {:indeterminate, %{cause: :malformed_reply}} =
             Store.write(s, :append, ["s", 0, [row(1)], []], req)
  end

  test "all static append bounds run before any provider call", %{store: s} do
    Memory.fault(s, :append, :malformed)
    before = Memory.inspect_state(s)

    for {stream, expected, records, items, reason} <- [
          {"", 0, [row(1)], [], :invalid_stream},
          {"s", -1, [row(1)], [], :invalid_revision},
          {"s", 0, [], [], :empty_batch},
          {"s", 0, List.duplicate(row(1), 9), [], :batch_too_large},
          {"s", 0, [%{row(1) | payload: String.duplicate("x", 65)}], [], :record_too_large},
          {"s", 0, [%{row(1) | schema_version: 2}], [], :unsupported_version},
          {"s", 0, [%{row(1) | kind: "unknown"}], [], :unknown_kind},
          {"s", 0, [row(1)], [%{destination: "unknown", payload: "x"}], :invalid_outbox_item}
        ] do
      assert {:rejected, ^reason} = Memory.append(s, stream, expected, records, items)
      assert Memory.inspect_state(s) == before
    end
  end

  test "concurrent head CAS has one winner and rejected retention/repair changes nothing", %{
    store: s
  } do
    results =
      1..16
      |> Task.async_stream(fn n -> Memory.append(s, "s", 0, [row(1, <<n::128>>)], []) end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:committed, 1}, &1)) == 1
    assert Enum.count(results, &match?({:conflict, _}, &1)) == 15
    before = Memory.inspect_state(s)
    assert {:rejected, :invalid_retention_range} = Memory.retain(s, "s", 0, 0, <<3::128>>)
    assert {:rejected, :retention_beyond_checkpoint} = Memory.retain(s, "s", 0, 1, <<3::128>>)
    assert Memory.inspect_state(s) == before

    pid =
      start_supervised!(
        Supervisor.child_spec({Memory, fold: fold(), limits: @limits, append_visibility: :atomic},
          id: :atomic_memory
        )
      )

    atomic = Memory.store(pid)
    assert %{append_visibility: :atomic} = Memory.capabilities(atomic)

    assert {:rejected, :torn_repair_unsupported} =
             Memory.repair_torn_tail(atomic, "s", 0, <<1::128>>, <<2::128>>)
  end

  test "paused checkpoint and retention remain unknown until their exact receipts commit", %{
    store: s
  } do
    Memory.append(s, "s", 0, [row(1)], [])
    c = checkpoint(Log.replay([row(1)], 1, fold()), 1)
    Memory.fault(s, :put_checkpoint, {:pause, :checkpoint})
    assert {:indeterminate, _} = Memory.put_checkpoint(s, c)
    assert {:unknown, :unfenced} = Log.confirm_checkpoint(s, c)
    assert {:committed, 1} = Memory.release(s, :checkpoint)
    assert {:committed, 1} = Log.confirm_checkpoint(s, c)
    receipt = Codec.receipt(:retain, "s", 0, 1, <<3::128>>)
    Memory.fault(s, :retain, {:pause, :retain})
    assert {:indeterminate, _} = Memory.retain(s, "s", 0, 1, receipt.nonce)
    assert {:unknown, :unfenced} = Log.confirm_retention(s, receipt)
    assert {:committed, 1} = Memory.release(s, :retain)
    assert {:committed, 1} = Log.confirm_retention(s, receipt)
  end

  # ELZ-427 fixture: stream "s" holds records 1..3 and the checkpoints a (1, fold
  # version 2), b (2, version 1) and c (3, version 1); stream "o" holds record 1 and
  # one checkpoint at 1 of each version, so a delete that ignores the stream shows.
  defp stream_row(stream, seq, nonce \\ <<1::128>>) do
    r = %{row(seq, nonce) | stream: stream}
    %{r | digest: Log.digest(r)}
  end

  defp checkpoint_at(rows, seq, version, nonce) do
    state = Log.replay(Enum.take(rows, seq), seq, fold())
    checkpoint(state, seq, %{stream: hd(rows).stream, fold_version: version, nonce: nonce})
  end

  defp seed_retention(s) do
    rows = Enum.map(1..3, &row/1)
    other = [stream_row("o", 1)]
    assert {:committed, 3} = Memory.append(s, "s", 0, rows, [])
    assert {:committed, 1} = Memory.append(s, "o", 0, other, [])
    a = checkpoint_at(rows, 1, 2, <<11::128>>)
    b = checkpoint_at(rows, 2, 1, <<12::128>>)
    c = checkpoint_at(rows, 3, 1, <<13::128>>)
    others = [checkpoint_at(other, 1, 1, <<14::128>>), checkpoint_at(other, 1, 2, <<15::128>>)]

    for checkpoint <- [a, b, c | others],
        do: assert({:committed, checkpoint.sequence} == Memory.put_checkpoint(s, checkpoint))

    %{rows: rows, a: a, b: b, c: c, others: others}
  end

  defp checkpoint_keys(s), do: Memory.inspect_state(s).checkpoints |> Map.keys() |> Enum.sort()

  defp put_request(c),
    do: %{
      operation: :put_checkpoint,
      stream: c.stream,
      expected: c.sequence,
      target: c.sequence,
      nonce: c.nonce,
      digest: c.digest
    }

  @kept [{"o", 1, 1}, {"o", 1, 2}, {"s", 2, 1}, {"s", 3, 1}]

  test "ELZ-427 committed retention deletes the stream's checkpoints below through, of every version",
       %{store: s} do
    %{a: a, b: b, c: c, others: others} = seed_retention(s)
    assert {:committed, 2} = Memory.retain(s, "s", 0, 2, <<20::128>>)
    assert {:ok, :absent} = Memory.read_checkpoint(s, "s", 1, 2)
    assert {:ok, :none} = Memory.latest_checkpoint(s, "s", 2)
    assert {:ok, ^b} = Memory.read_checkpoint(s, "s", 2, 1)
    assert {:ok, ^c} = Memory.read_checkpoint(s, "s", 3, 1)
    assert {:ok, ^c} = Memory.latest_checkpoint(s, "s", 1)

    for o <- others,
        do: assert({:ok, o} == Memory.read_checkpoint(s, "o", 1, o.fold_version))

    # The receipt of a deleted checkpoint can no longer be confirmed.
    assert {:unknown, :unfenced} = Log.confirm_checkpoint(s, a)
    assert checkpoint_keys(s) == @kept
  end

  test "ELZ-427 an exact retention retry keeps its conflict, deletes nothing more, and the receipt confirms",
       %{store: s} do
    %{rows: rows} = seed_retention(s)
    receipt = Codec.receipt(:retain, "s", 0, 2, <<21::128>>)
    Memory.fault(s, :retain, :reply_loss)
    assert {:indeterminate, _} = Memory.retain(s, "s", 0, 2, receipt.nonce)
    assert {:committed, 2} = Log.confirm_retention(s, receipt)
    assert checkpoint_keys(s) == @kept

    # A checkpoint below low-water that no retention deleted, as a store written
    # before this change can hold: the retry must not delete it either.
    left = checkpoint_at(rows, 1, 1, <<22::128>>)

    :sys.replace_state(elem(s, 1).pid, fn state ->
      put_in(state.checkpoints[{"s", 1, 1}], left)
    end)

    before = Memory.inspect_state(s)
    assert {:conflict, %{expected: 0, observed: 2}} = Memory.retain(s, "s", 0, 2, receipt.nonce)
    assert Memory.inspect_state(s) == before
    assert {:committed, 2} = Log.confirm_retention(s, receipt)

    # The next committed retention deletes it with the rest below its through.
    assert {:committed, 3} = Memory.retain(s, "s", 2, 3, <<23::128>>)
    assert checkpoint_keys(s) == [{"o", 1, 1}, {"o", 1, 2}, {"s", 3, 1}]
  end

  test "ELZ-427 refused or conflicting retention deletes no checkpoint", %{store: s} do
    rows = Enum.map(1..3, &row/1)

    item = %{
      stream: "s",
      sequence: 3,
      position: 1,
      destination: "sink",
      payload: "effect",
      nonce: <<1::128>>,
      idempotency_key: Codec.item_key("s", 3, 1),
      state: :pending,
      ack_nonce: nil,
      ack_digest: nil
    }

    item = Map.put(item, :digest, Codec.hash(Codec.item_bytes(item)))
    assert {:committed, 3} = Memory.append(s, "s", 0, rows, [item])

    for c <- [checkpoint_at(rows, 1, 2, <<11::128>>), checkpoint_at(rows, 2, 1, <<12::128>>)],
        do: assert({:committed, c.sequence} == Memory.put_checkpoint(s, c))

    before = Memory.inspect_state(s)
    assert {:rejected, :retention_beyond_checkpoint} = Memory.retain(s, "s", 0, 3, <<20::128>>)
    assert Memory.inspect_state(s) == before
    assert {:committed, 3} = Memory.put_checkpoint(s, checkpoint_at(rows, 3, 1, <<13::128>>))
    before = Memory.inspect_state(s)
    assert {:rejected, :retention_beyond_pending_outbox} = Memory.retain(s, "s", 0, 3, <<21::128>>)
    assert {:conflict, %{expected: 1, observed: 0}} = Memory.retain(s, "s", 1, 2, <<22::128>>)
    assert Memory.inspect_state(s) == before
    assert {:committed, 2} = Memory.retain(s, "s", 0, 2, <<23::128>>)
    assert checkpoint_keys(s) == [{"s", 2, 1}, {"s", 3, 1}]
  end

  test "ELZ-427 a checkpoint below low-water is refused through Store.write and writes nothing",
       %{store: s} do
    %{rows: rows, a: a} = seed_retention(s)
    assert {:committed, 2} = Memory.retain(s, "s", 0, 2, <<30::128>>)
    before = Memory.inspect_state(s)
    unused = checkpoint_at(rows, 1, 1, <<31::128>>)
    empty = checkpoint(Log.replay([], 0, fold()), 0, %{nonce: <<32::128>>})

    # An unused key, the key that retention deleted, and sequence 0.
    for c <- [unused, a, empty] do
      assert {:rejected, :checkpoint_below_low_water} =
               Store.write(s, :put_checkpoint, [c], put_request(c))
    end

    assert Memory.inspect_state(s) == before
    assert {:ok, :absent} = Memory.read_checkpoint(s, "s", 1, 1)
    at_low_water = checkpoint_at(rows, 2, 3, <<33::128>>)

    assert {:committed, 2} =
             Store.write(s, :put_checkpoint, [at_low_water], put_request(at_low_water))

    rows = rows ++ [row(4, <<4::128>>)]
    assert {:committed, 4} = Memory.append(s, "s", 3, [List.last(rows)], [])
    above = checkpoint_at(rows, 4, 1, <<34::128>>)
    assert {:committed, 4} = Store.write(s, :put_checkpoint, [above], put_request(above))
    beyond = checkpoint_at(rows ++ [row(5, <<5::128>>)], 5, 1, <<35::128>>)

    assert {:rejected, :checkpoint_beyond_tail} =
             Store.write(s, :put_checkpoint, [beyond], put_request(beyond))
  end
end
