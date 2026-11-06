# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableLog.WriterTest do
  use ExUnit.Case, async: false
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Memory, Record, Writer}
  @limits %{max_record_bytes: 64, max_batch_size: 8, max_checkpoint_bytes: 10_000}
  defp fold,
    do: %{
      initial: 0,
      kinds: %{"added" => :state_bearing},
      versions: [1],
      destinations: ["sink"],
      reduce: fn n, _, _, _ -> n + 1 end
    }

  defp row(seq, nonce \\ <<1::128>>) do
    r = %Record{
      stream: "writer",
      sequence: seq,
      kind: "added",
      schema_version: 1,
      payload: "event",
      nonce: nonce
    }

    %{r | digest: Log.digest(r)}
  end

  defp start_writer(store, opts \\ []) do
    result =
      Writer.start_link(
        Keyword.merge([store: store, stream: "writer", fold: fold(), limits: @limits], opts)
      )

    if match?({:ok, _}, result) do
      {:ok, pid} = result
      Process.unlink(pid)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    end

    result
  end

  setup do
    Process.flag(:trap_exit, true)
    pid = start_supervised!({Memory, fold: fold(), limits: @limits})
    %{store: Memory.store(pid)}
  end

  defmodule CommitGate do
    for {op, args} <- [
          head: [:stream],
          capabilities: [],
          read: [:stream, :from, :limit],
          read_at: [:stream, :seq]
        ] do
      variables = Enum.map(args, &Macro.var(&1, nil))

      def unquote(op)({_, opts}, unquote_splicing(variables)),
        do: apply(Memory, unquote(op), [{Memory, opts}, unquote_splicing(variables)])
    end

    def append({_, opts}, stream, expected, rows, items) do
      result = Memory.append({Memory, opts}, stream, expected, rows, items)
      send(opts.parent, {Map.get(opts, :gate, :committed_before_reply), self(), result})

      receive do
        :deliver_reply -> result
      end
    end
  end

  test "empty init, committed append and static rejection preserve the authoritative snapshot", %{
    store: s
  } do
    {:ok, writer} = start_writer(s)
    assert %{model: 0, cursor: {0, false, []}, seen: %{}} = Writer.snapshot(writer)
    before = Memory.inspect_state(s)
    assert {:rejected, :empty_batch} = Writer.append(writer, [])
    assert {:rejected, :unknown_kind} = Writer.append(writer, [{"unknown", 1, "event"}])
    assert Memory.inspect_state(s) == before

    assert {:committed, 2} =
             Writer.append(writer, [{"added", 1, "event"}, {"added", 1, "event"}], [
               {"sink", "effect"}
             ])

    assert %{model: 2, cursor: {2, false, []}, seen: seen} = Writer.snapshot(writer)
    assert map_size(seen) == 2
    assert {:ok, [item]} = Memory.pending(s, "writer", 10)
    assert {item.sequence, item.position, item.idempotency_key} == {2, 1, "writer/2/1"}
  end

  test "D9 kill after storage commit but before caller reply; restart folds exactly once", %{
    store: {_, opts} = s
  } do
    {:ok, writer} = start_writer({CommitGate, Map.put(opts, :parent, self())})
    monitor = Process.monitor(writer)
    parent = self()

    spawn(fn ->
      result =
        try do
          Writer.append(writer, [{"added", 1, "event"}])
        catch
          :exit, reason -> {:exit, reason}
        end

      send(parent, {:caller, result})
    end)

    assert_receive {:committed_before_reply, ^writer, {:committed, 1}}
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :killed}
    assert_receive {:caller, {:exit, _}}
    {:ok, restarted} = start_writer(s)
    assert %{model: 1, cursor: {1, false, []}} = Writer.snapshot(restarted)
    assert {:ok, %{revision: 1}} = Memory.head(s, "writer")
  end

  test "D10 paused original remains unknown; deliberate fresh-nonce CAS fences it", %{store: s} do
    {:ok, writer} = start_writer(s)
    monitor = Process.monitor(writer)
    Memory.fault(s, :append, {:pause, :old})
    assert {:indeterminate, info} = Writer.append(writer, [{"added", 1, "event"}])
    assert_receive {:DOWN, ^monitor, :process, ^writer, {:shutdown, {:indeterminate_write, ^info}}}
    request = Map.put(info, :records, [row(1, info.nonce)])
    assert {:error, {:storage, :unfenced}} = start_writer(s, reconcile: request)
    assert {:unknown, :unfenced} = Log.confirm(s, "writer", 0, info.nonce, request.records)
    {:ok, fresh} = start_writer(s)
    assert {:committed, 1} = Writer.append(fresh, [{"added", 1, "event"}])
    assert {:conflict, _} = Memory.release(s, :old)
    assert :superseded = Log.confirm(s, "writer", 0, info.nonce, request.records)
    {:ok, reconciled} = start_writer(s, reconcile: request)
    assert %{model: 1} = Writer.snapshot(reconciled)
  end

  test "D10 confirmed rollback still cannot infer non-commit from absence", %{store: s} do
    {:ok, writer} = start_writer(s)
    monitor = Process.monitor(writer)
    Memory.fault(s, :append, {:pause, :aborted})
    assert {:indeterminate, info} = Writer.append(writer, [{"added", 1, "event"}])
    assert_receive {:DOWN, ^monitor, :process, ^writer, _}
    assert :ok = Memory.conformance_hook(s, :rollback, [:aborted])
    request = Map.put(info, :records, [row(1, info.nonce)])
    assert {:error, {:storage, :unfenced}} = start_writer(s, reconcile: request)
    assert {:unknown, :unfenced} = Log.confirm(s, "writer", 0, info.nonce, request.records)
  end

  test "D10 kill while the transaction is paused before commit; the old transaction can commit later",
       %{store: {_, opts} = s} do
    gate = {CommitGate, Map.merge(opts, %{parent: self(), gate: :paused_before_reply})}
    {:ok, writer} = start_writer(gate)
    monitor = Process.monitor(writer)
    Memory.fault(s, :append, {:pause, :before_commit})
    parent = self()

    spawn(fn ->
      result =
        try do
          Writer.append(writer, [{"added", 1, "event"}])
        catch
          :exit, reason -> {:exit, reason}
        end

      send(parent, {:caller, result})
    end)

    assert_receive {:paused_before_reply, ^writer, {:indeterminate, info}}
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :killed}
    assert_receive {:caller, {:exit, _}}
    request = Map.put(info, :records, [row(1, info.nonce)])
    assert {:error, {:storage, :unfenced}} = start_writer(s, reconcile: request)
    assert {:committed, 1} = Memory.release(s, :before_commit)
    {:ok, restarted} = start_writer(s, reconcile: request)
    assert %{model: 1, cursor: {1, false, []}} = Writer.snapshot(restarted)
  end

  test "D14 concurrent writers use CAS and conflicts refold before the next append", %{store: s} do
    {:ok, first} = start_writer(s)
    {:ok, second} = start_writer(s)

    results =
      [first, second]
      |> Task.async_stream(&Writer.append(&1, [{"added", 1, "event"}]))
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.sort(results) == Enum.sort([{:committed, 1}, {:conflict, 1}])
    assert %{model: 1, cursor: {1, false, []}} = Writer.snapshot(first)
    assert %{model: 1, cursor: {1, false, []}} = Writer.snapshot(second)
    assert {:committed, 2} = Writer.append(second, [{"added", 1, "event"}])
    assert {:conflict, 2} = Writer.append(first, [{"added", 1, "event"}])
    assert Writer.snapshot(first) == Writer.snapshot(second)
  end

  test "conflict preserves the provider's observation even if refolding sees a newer head", %{
    store: {_, opts} = s
  } do
    {:ok, writer} = start_writer({CommitGate, Map.put(opts, :parent, self())})
    assert {:committed, 1} = Memory.append(s, "writer", 0, [row(1)], [])
    caller = Task.async(fn -> Writer.append(writer, [{"added", 1, "event"}]) end)
    assert_receive {:committed_before_reply, ^writer, {:conflict, %{observed: 1}}}
    assert {:committed, 2} = Memory.append(s, "writer", 1, [row(2)], [])
    send(writer, :deliver_reply)
    assert {:conflict, 1} = Task.await(caller)
    assert %{model: 2, cursor: {2, false, []}} = Writer.snapshot(writer)
  end

  test "D15 reply loss and late completion stop the writer and require exact supplied reconciliation",
       %{store: s} do
    for {fault, expected} <- [{:reply_loss, 0}, {{:pause, :late}, 1}] do
      {:ok, writer} = start_writer(s)
      monitor = Process.monitor(writer)
      Memory.fault(s, :append, fault)
      assert {:indeterminate, info} = Writer.append(writer, [{"added", 1, "event"}])
      assert info.expected == expected

      assert_receive {:DOWN, ^monitor, :process, ^writer,
                      {:shutdown, {:indeterminate_write, ^info}}}

      request = Map.put(info, :records, [row(expected + 1, info.nonce)])

      if expected == 1 do
        assert {:error, {:storage, :unfenced}} = start_writer(s, reconcile: request)
        assert {:committed, 2} = Memory.release(s, :late)
      end

      {:ok, restarted} = start_writer(s, reconcile: request)
      assert %{model: model} = Writer.snapshot(restarted)
      assert model == expected + 1
    end

    assert {:error, {:storage, :unfenced}} = start_writer(s, reconcile: %{operation: :append})
  end

  test "D16 only owning init fences and repairs a staged tail; late nonce cannot resurrect", %{
    store: s
  } do
    row = row(1)
    Memory.fault(s, :append, :stage)
    assert {:indeterminate, _} = Memory.append(s, "writer", 0, [row], [])
    assert {:ok, rows, head} = Log.read(s, "writer", 1, 10)
    assert %{tail: :torn} = Log.replay(rows, head, fold())

    assert {:rejected, :unfenced_tail} =
             Memory.repair_torn_tail(s, "writer", 0, row.nonce, <<4::128>>)

    {:ok, writer} = start_writer(s)
    assert %{model: 0, cursor: {0, false, []}} = Writer.snapshot(writer)
    assert {:ok, %{revision: 0, low_water: 0}} = Memory.head(s, "writer")
    assert {:conflict, _} = Memory.release(s, row.nonce)
    assert {:committed, 1} = Writer.append(writer, [{"added", 1, "event"}])
    assert {:ok, stored, _} = Memory.read_at(s, "writer", 1)
    refute stored.nonce == row.nonce
  end

  test "D17 committed corruption is damaged and never repaired by init", %{store: s} do
    assert {:committed, 1} = Memory.append(s, "writer", 0, [row(1)], [])
    Memory.corrupt(s, :records, {"writer", 1}, %{digest: <<0::256>>})
    before = Memory.inspect_state(s)
    assert {:error, {:replay_damaged, [{:corrupt, 1, :digest_mismatch}]}} = start_writer(s)
    assert Memory.inspect_state(s) == before
  end

  test "lost repair reply stops init; exact receipt reconciles without a blind repair retry", %{
    store: s
  } do
    row = row(1)
    Memory.fault(s, :append, :stage)
    assert {:indeterminate, _} = Memory.append(s, "writer", 0, [row], [])
    Memory.fault(s, :repair_torn_tail, :reply_loss)
    assert {:error, {:shutdown, {:indeterminate_write, info}}} = start_writer(s)

    receipt =
      Elzoo.DurableLog.Codec.receipt(:repair_torn_tail, "writer", 0, 0, info.nonce, row.nonce)

    assert {:committed, 0} = Log.confirm_repair(s, receipt)
    {:ok, writer} = start_writer(s, reconcile: receipt)
    assert %{model: 0, cursor: {0, false, []}} = Writer.snapshot(writer)
    assert {:conflict, _} = Memory.release(s, row.nonce)
  end

  test "conflict refolding never repairs a staged tail outside init", %{store: s} do
    {:ok, writer} = start_writer(s)
    monitor = Process.monitor(writer)
    assert {:committed, 1} = Memory.append(s, "writer", 0, [row(1)], [])
    Memory.fault(s, :append, :stage)
    assert {:indeterminate, _} = Memory.append(s, "writer", 1, [row(2)], [])
    before = Memory.inspect_state(s)
    assert {:conflict, 1} = Writer.append(writer, [{"added", 1, "event"}])
    assert_receive {:DOWN, ^monitor, :process, ^writer, {:shutdown, {:storage, :unfenced}}}
    assert Memory.inspect_state(s) == before
  end

  test "gap-only readers return a damaged model while Writer init uniformly refuses it", %{store: s} do
    assert {:committed, 3} = Memory.append(s, "writer", 0, [row(1), row(2), row(3)], [])

    :sys.replace_state(elem(s, 1).pid, fn state ->
      %{state | records: Map.delete(state.records, {"writer", 2})}
    end)

    assert {:ok, rows, head} = Log.read(s, "writer", 1, 10)
    assert %{model: 2, cursor: {3, true, [{3, :gap}]}} = Log.replay(rows, head, fold())
    before = Memory.inspect_state(s)
    assert {:error, {:replay_damaged, [{3, :gap}]}} = start_writer(s)
    assert Memory.inspect_state(s) == before
  end

  test "post-commit reducer failure retains the commit, replies committed and stops", %{store: s} do
    for {fail, expected} <- [
          {fn -> raise "private" end, 0},
          {fn -> throw(:private) end, 1},
          {fn -> exit(:private) end, 2}
        ] do
      bad = %{fold() | reduce: fn n, _, _, _ -> if n >= expected, do: fail.(), else: n + 1 end}
      {:ok, writer} = start_writer(s, fold: bad)
      monitor = Process.monitor(writer)
      assert {:committed, revision} = Writer.append(writer, [{"added", 1, "event"}])
      assert revision == expected + 1

      assert_receive {:DOWN, ^monitor, :process, ^writer,
                      {:shutdown, {:replay_damaged, [{:corrupt, ^revision, :reducer_failure}]}}}

      assert {:ok, %{revision: ^revision}} = Memory.head(s, "writer")
      assert {:error, {:replay_damaged, _}} = start_writer(s, fold: bad)
    end
  end

  test "D19 unavailable reads stop init; unavailable or malformed writes are indeterminate", %{
    store: s
  } do
    Memory.fault(s, :head, :unavailable)
    assert {:error, {:storage, :unavailable}} = start_writer(s)

    for {mode, cause} <- [unavailable: :unavailable, malformed: :malformed_reply] do
      {:ok, writer} = start_writer(s)
      monitor = Process.monitor(writer)
      Memory.fault(s, :append, mode)

      assert {:indeterminate, %{cause: ^cause} = info} =
               Writer.append(writer, [{"added", 1, "event"}])

      assert_receive {:DOWN, ^monitor, :process, ^writer,
                      {:shutdown, {:indeterminate_write, ^info}}}
    end

    stop_supervised(Memory)
    assert {:error, {:storage, :unavailable}} = start_writer(s)
  end

  test "PR #51 owning init fences a staged tail just after a full read page", %{store: s} do
    for batch <- 0..124 do
      rows = for i <- 1..8, do: row(batch * 8 + i)
      assert {:committed, _} = Memory.append(s, "writer", batch * 8, rows, [])
    end

    staged = row(1001, <<9::128>>)
    Memory.fault(s, :append, :stage)
    assert {:indeterminate, _} = Memory.append(s, "writer", 1000, [staged], [])

    {:ok, writer} = start_writer(s)
    assert %{model: 1000, cursor: {1000, false, []}} = Writer.snapshot(writer)
    assert {:conflict, _} = Memory.release(s, staged.nonce)
    assert {:ok, %{revision: 1000}} = Memory.head(s, "writer")
  end
end
