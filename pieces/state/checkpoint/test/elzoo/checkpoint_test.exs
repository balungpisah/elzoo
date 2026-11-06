# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CheckpointTest do
  use ExUnit.Case, async: false
  alias Elzoo.Checkpoint
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Memory, Record}
  @limits %{max_record_bytes: 64, max_batch_size: 8, max_checkpoint_bytes: 10_000}
  defp fold,
    do: %{
      initial: 0,
      kinds: %{"added" => :state_bearing},
      versions: [1],
      reduce: fn n, _, _, p -> n + String.to_integer(p) end
    }

  defp decode(binary) do
    case Integer.parse(binary) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :invalid}
    end
  end

  defp row(n) do
    r = %Record{
      stream: "s",
      sequence: n,
      kind: "added",
      schema_version: 1,
      payload: "2",
      nonce: <<1::128>>
    }

    %{r | digest: Log.digest(r)}
  end

  defp take(store, state, version \\ 1, limits \\ @limits),
    do: Checkpoint.take({store, state, limits}, "s", version, &Integer.to_string/1)

  setup do
    pid = start_supervised!({Memory, fold: fold(), limits: @limits})
    %{store: Memory.store(pid, %{fold: fold()})}
  end

  test "D7 full replay equals checkpoint plus tail; all cursor and witnesses survive", %{store: s} do
    rows = [row(1), row(2), row(3)]
    assert {:committed, 3} = Memory.append(s, "s", 0, rows, [])
    seed = Log.replay(Enum.take(rows, 2), 2, fold())
    assert {:committed, 2} = take(s, seed)
    assert Checkpoint.recover(s, "s", fold(), 1, &decode/1) == Log.replay(rows, 3, fold())
    assert {:ok, c} = Memory.latest_checkpoint(s, "s", 1)
    assert Checkpoint.valid?(c)

    for changes <- [
          %{model: "99"},
          %{cursor: {2, true, [{2, :gap}]}},
          %{seen: %{2 => <<0::256>>}},
          %{nonce: <<9::128>>}
        ] do
      refute Checkpoint.valid?(Map.merge(c, changes))
    end
  end

  test "gap-only damage may fold onward; terminal damage snapshots do not replay failing rows", %{
    store: s
  } do
    rows = [row(1), row(2), row(3)]
    Memory.append(s, "s", 0, rows, [])
    gap = Log.replay([row(2)], 2, fold())
    assert {:committed, 2} = take(s, gap)
    result = Checkpoint.recover(s, "s", fold(), 1, &decode/1)
    assert %{model: 4, cursor: {3, true, [{2, :gap}]}} = result

    ordered =
      Log.replay([row(1)], 2, Map.put(fold(), :resume, Map.take(gap, [:model, :cursor, :seen])))

    assert {:committed, 2} = take(s, ordered, 2)

    assert %{cursor: {3, true, [{1, :out_of_order}, {2, :gap}]}} =
             Checkpoint.recover(s, "s", fold(), 2, &decode/1)

    bad = Log.replay([row(1), %{row(2) | digest: <<0::256>>}], 3, fold())
    assert {:committed, 1} = take(s, bad, 3)
    assert Checkpoint.recover(s, "s", fold(), 3, &decode/1) == bad
    assert {:rejected, :retention_beyond_checkpoint} = Memory.retain(s, "s", 0, 1, <<7::128>>)
  end

  test "D8 invalid latest falls back to earlier checkpoint, invalid decode/stale version refold", %{
    store: s
  } do
    rows = [row(1), row(2), row(3)]
    Memory.append(s, "s", 0, rows, [])
    assert {:committed, 1} = take(s, Log.replay([row(1)], 1, fold()))
    assert {:committed, 2} = take(s, Log.replay(Enum.take(rows, 2), 2, fold()))
    Memory.corrupt(s, :checkpoints, {"s", 2, 1}, %{digest: <<0::256>>})
    full = Log.replay(rows, 3, fold())
    assert Checkpoint.recover(s, "s", fold(), 1, &decode/1) == full
    assert Checkpoint.recover(s, "s", fold(), 9, &decode/1) == full
    assert Checkpoint.recover(s, "s", fold(), 1, fn _ -> {:error, :bad} end) == full
  end

  test "retained through head recovers healthy; invalid or undecodable anchor fails closed", %{
    store: s
  } do
    rows = [row(1), row(2)]
    Memory.append(s, "s", 0, rows, [])
    state = Log.replay(rows, 2, fold())
    assert {:committed, 2} = take(s, state)
    assert {:committed, 2} = Memory.retain(s, "s", 0, 2, <<2::128>>)
    assert Checkpoint.recover(s, "s", fold(), 1, &decode/1) == state
    assert {:error, {:pruned, 2}} = Checkpoint.recover(s, "s", fold(), 2, &decode/1)
    assert {:error, {:pruned, 2}} = Checkpoint.recover(s, "s", fold(), 1, fn _ -> throw(:bad) end)
    Memory.corrupt(s, :checkpoints, {"s", 2, 1}, %{digest: <<0::256>>})
    assert {:error, {:pruned, 2}} = Checkpoint.recover(s, "s", fold(), 1, &decode/1)
  end

  test "bounded checkpoint rejects before provider call; beyond tail/duplicate and lost reply", %{
    store: s
  } do
    Memory.append(s, "s", 0, [row(1)], [])
    state = Log.replay([row(1)], 1, fold())
    before = Memory.inspect_state(s)

    assert {:rejected, :checkpoint_too_large} =
             take(s, state, 1, %{@limits | max_checkpoint_bytes: 1})

    assert Memory.inspect_state(s) == before
    future = Log.replay([row(2)], 2, fold())
    assert {:rejected, :checkpoint_beyond_tail} = take(s, future)
    Memory.fault(s, :put_checkpoint, :reply_loss)
    assert {:indeterminate, %{operation: :put_checkpoint}} = take(s, state)
    assert {:ok, c} = Memory.latest_checkpoint(s, "s", 1)
    assert {:committed, 1} = Log.confirm_checkpoint(s, c)
    assert {:conflict, _} = take(s, state)
    request = %{c | fold_version: 2}
    request = %{request | digest: Codec.hash(Codec.checkpoint_bytes(request))}
    assert {:unknown, :unfenced} = Log.confirm_checkpoint(s, request)
  end

  defmodule ReadOnly do
    for {name, arity} <- [
          capabilities: 0,
          head: 1,
          read: 3,
          read_at: 2,
          latest_checkpoint: 2,
          read_checkpoint: 3,
          pending: 2
        ] do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)({__MODULE__, underlying}, unquote_splicing(args)),
        do: apply(Memory, unquote(name), [underlying, unquote_splicing(args)])
    end

    for {name, arity} <- [append: 4, put_checkpoint: 1, retain: 4, ack: 2, repair_torn_tail: 4] do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(_, unquote_splicing(args)), do: raise("reader attempted mutation")
    end
  end

  test "reader-write audit: read/replay and recovery have no mutating callback", %{store: s} do
    Memory.append(s, "s", 0, [row(1)], [])
    state = Log.replay([row(1)], 1, fold())
    take(s, state)
    readonly = {ReadOnly, s}
    before = Memory.inspect_state(s)
    assert {:ok, rows, head} = Log.read(readonly, "s", 1, 10)
    assert Log.replay(rows, head, fold()) == state
    assert Checkpoint.recover(readonly, "s", fold(), 1, &decode/1) == state
    assert Memory.inspect_state(s) == before
  end

  test "empty checkpoint, encode errors and complete snapshot field validation", %{store: s} do
    empty = Log.replay([], 0, fold())
    assert {:committed, 0} = take(s, empty)
    assert Checkpoint.recover(s, "s", fold(), 1, &decode/1) == empty

    for encode <- [
          fn _ -> raise "private" end,
          fn _ -> throw(:private) end,
          fn _ -> exit(:private) end
        ] do
      assert {:error, :encode_failure} = Checkpoint.take({s, empty, @limits}, "s", 2, encode)
    end

    Memory.append(s, "s", 0, [row(1)], [])
    state = Log.replay([row(1)], 1, fold())
    assert {:committed, 1} = take(s, state, 2)
    {:ok, c} = Memory.latest_checkpoint(s, "s", 2)

    for changes <- [
          %{sequence: 2},
          %{seen: %{}},
          %{cursor: {1, false, [{1, :gap}]}},
          %{cursor: {1, true, [{:corrupt, 1, :invented}]}},
          %{nonce: <<0>>}
        ] do
      changed = Map.merge(c, changes)
      refute Checkpoint.valid?(changed)
    end

    truncated = %{state | cursor: {1, true, [{:truncated, 3, 1}]}}
    assert {:committed, 1} = take(s, truncated, 3)
    assert Checkpoint.recover(s, "s", fold(), 3, &decode/1) == truncated
  end

  for committed <- [999, 1000] do
    test "PR #51 recovery reports a staged tail at #{committed + 1} around a full read page",
         %{store: s} do
      committed = unquote(committed)

      for chunk <- Enum.chunk_every(1..committed, 8) do
        expected = hd(chunk) - 1
        assert {:committed, _} = Memory.append(s, "s", expected, Enum.map(chunk, &row/1), [])
      end

      staged = %{row(committed + 1) | nonce: <<9::128>>}
      staged = %{staged | digest: Log.digest(staged)}
      Memory.fault(s, :append, :stage)
      assert {:indeterminate, _} = Memory.append(s, "s", committed, [staged], [])

      model = committed * 2

      assert %{model: ^model, cursor: {^committed, false, []}, tail: :torn} =
               Checkpoint.recover(s, "s", fold(), 1, &decode/1)
    end
  end

  test "PR #51 a beyond_head damaged snapshot round-trips through a checkpoint", %{store: s} do
    assert {:committed, 1} = Memory.append(s, "s", 0, [row(1)], [])
    beyond = Log.replay([row(1), row(2)], 1, fold())
    assert %{cursor: {1, true, [{:corrupt, 2, :beyond_head}]}} = beyond
    assert {:committed, 1} = take(s, beyond)
    assert Checkpoint.recover(s, "s", fold(), 1, &decode/1) == beyond
    assert {:rejected, :retention_beyond_checkpoint} = Memory.retain(s, "s", 0, 1, <<7::128>>)
  end
end
