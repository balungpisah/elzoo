# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableLog.DomainTest do
  use ExUnit.Case, async: false
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Memory, Record}
  @max 9_223_372_036_854_775_807
  @small 2_147_483_647
  @limits %{max_record_bytes: 64, max_batch_size: 8, max_checkpoint_bytes: 10_000}
  defp fold,
    do: %{
      initial: 0,
      kinds: %{"added" => :state_bearing},
      versions: [1, @small],
      destinations: ["sink"],
      reduce: fn n, _, _, _ -> n + 1 end
    }

  defp row(changes \\ %{}) do
    r =
      struct!(
        Record,
        Map.merge(
          %{
            stream: "s",
            sequence: 1,
            kind: "added",
            schema_version: 1,
            payload: "event",
            nonce: <<1::128>>
          },
          changes
        )
      )

    %{r | digest: Log.digest(r)}
  end

  test "portable numeric boundaries reject before storage and damage out-of-domain rows" do
    assert Log.validate_row(row(%{sequence: @max, schema_version: @small}), fold()) == :ok
    assert {:error, :invalid_revision} = Log.validate_row(row(%{sequence: @max + 1}), fold())

    assert {:error, :unsupported_version} =
             Log.validate_row(row(%{schema_version: @small + 1}), fold())

    assert {:rejected, :invalid_revision} =
             Log.preflight(
               %{stream: "s", expected: @max, records: [{"added", 1, "event"}], outbox: []},
               fold(),
               @limits
             )

    assert %{cursor: {0, true, [{:corrupt, _, :invalid_revision}]}} =
             Log.replay([row(%{sequence: @max + 1})], @max, fold())

    assert {:error, :invalid_outbox_item} = Codec.parse_key("s/1/#{@small + 1}")
    assert {:ok, {"s", @max, @small}} = Codec.parse_key("s/#{@max}/#{@small}")
  end

  test "UTF-8/no-NUL inputs use existing reasons and invalid tables cannot construct Memory" do
    pid = start_supervised!({Memory, fold: fold(), limits: @limits})
    s = Memory.store(pid)

    for bad <- [<<0>>, <<255>>, "a" <> <<0>>] do
      before = Memory.inspect_state(s)
      assert {:rejected, :invalid_stream} = Memory.append(s, bad, 0, [row()], [])
      assert {:rejected, :unknown_kind} = Memory.append(s, "s", 0, [row(%{kind: bad})], [])

      assert {:rejected, :invalid_outbox_item} =
               Memory.append(s, "s", 0, [row()], [%{destination: bad, payload: "x"}])

      assert Memory.inspect_state(s) == before

      assert {:error, :invalid_fold} =
               Memory.start_link(fold: %{fold() | kinds: %{bad => :state_bearing}}, limits: @limits)

      assert {:error, :invalid_fold} =
               Memory.start_link(fold: %{fold() | destinations: [bad]}, limits: @limits)
    end

    assert {:error, :invalid_fold} =
             Memory.start_link(fold: %{fold() | versions: [@small + 1]}, limits: @limits)

    refute Codec.uint?(@max + 1)
    refute Codec.checkpoint_valid?(%{fold_version: @small + 1})
  end

  test "Memory rejects numeric overflow before mutation, including checkpoint versions and retention bounds" do
    pid = start_supervised!({Memory, fold: fold(), limits: @limits})
    s = Memory.store(pid)
    before = Memory.inspect_state(s)

    assert {:rejected, :invalid_revision} =
             Memory.append(s, "s", @max, [row(%{sequence: @max + 1})], [])

    assert {:rejected, :unsupported_version} =
             Memory.append(s, "s", 0, [row(%{schema_version: @small + 1})], [])

    item = %{
      stream: "s",
      sequence: 1,
      position: @small + 1,
      destination: "sink",
      payload: "effect",
      nonce: <<1::128>>,
      state: :pending,
      ack_nonce: nil,
      ack_digest: nil,
      idempotency_key: Codec.item_key("s", 1, @small + 1)
    }

    item = Map.put(item, :digest, Codec.hash(Codec.item_bytes(item)))
    assert {:rejected, :invalid_outbox_item} = Memory.append(s, "s", 0, [row()], [item])
    assert {:rejected, :invalid_retention_range} = Memory.retain(s, "s", 0, @max + 1, <<1::128>>)

    c = %{
      stream: "s",
      sequence: 0,
      fold_version: @small,
      model: "0",
      cursor: {0, false, []},
      seen: %{},
      nonce: <<1::128>>
    }

    c = Map.put(c, :digest, Codec.hash(Codec.checkpoint_bytes(c)))
    assert Codec.checkpoint_valid?(c)
    invalid = %{c | fold_version: @small + 1}
    invalid = %{invalid | digest: Codec.hash(Codec.checkpoint_bytes(invalid))}
    refute Codec.checkpoint_valid?(invalid)
    assert {:indeterminate, _} = Memory.put_checkpoint(s, invalid)
    assert Memory.inspect_state(s) == before
  end

  test "declared empty kinds remain valid; stream and destination retain nonempty bounds" do
    empty = %{fold() | kinds: %{"" => :state_bearing}}
    assert Codec.fold_valid?(empty)
    refute Codec.stream?("")

    assert :ok =
             Log.preflight(
               %{
                 stream: "s",
                 expected: 0,
                 records: [{"", 1, "event"}],
                 outbox: [{"sink", "effect"}]
               },
               empty,
               @limits
             )

    pid = start_supervised!({Memory, fold: empty, limits: @limits})
    assert {:committed, 1} = Memory.append(Memory.store(pid), "s", 0, [row(%{kind: ""})], [])

    assert {:rejected, :invalid_outbox_item} =
             Log.preflight(
               %{stream: "s", expected: 0, records: [{"", 1, "event"}], outbox: [{"", "effect"}]},
               empty,
               @limits
             )

    assert {:error, :invalid_fold} =
             Memory.start_link(fold: %{empty | destinations: [""]}, limits: @limits)
  end

  test "checkpoint wire fields round trip without terms or atom conversion; malformed encodings fail closed" do
    cursor =
      {2, true,
       [{2, :gap}, {1, :out_of_order}, {:corrupt, 3, :digest_mismatch}, {:truncated, 4, 2}]}

    seen = %{1 => <<1::256>>, 2 => <<2::256>>}
    assert {:ok, ^cursor} = Codec.decode_cursor(Codec.cursor_bytes(cursor))
    assert {:ok, ^seen} = Codec.decode_seen(Codec.seen_bytes(seen))

    for bytes <- [<<>>, <<1>>, <<1, 0::64, 2, 0::32>>, <<1, 0::64, 1, 1::32, 255, 1::64>>] do
      assert {:error, :malformed} = Codec.decode_cursor(bytes)
    end

    assert {:error, :malformed} = Codec.decode_seen(<<1, 1::32>>)
    assert {:error, :malformed} = Codec.decode_seen(<<1, 2::32, 1::64, 0::256, 1::64, 0::256>>)
  end
end
