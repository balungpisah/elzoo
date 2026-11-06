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
end
