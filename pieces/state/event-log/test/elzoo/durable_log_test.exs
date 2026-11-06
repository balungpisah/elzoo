# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableLogTest do
  use ExUnit.Case, async: false
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.Record
  @source File.read!(Path.expand("../../cure/elzoo/replay.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)

  defp fold do
    %{
      initial: 0,
      kinds: %{"added" => :state_bearing, "noted" => :non_state_bearing},
      versions: [1],
      reduce: fn model, "added", 1, payload -> model + String.to_integer(payload) end
    }
  end

  defp row(seq, changes \\ %{}) do
    record =
      struct!(
        Record,
        Map.merge(
          %{
            stream: "a/b",
            sequence: seq,
            kind: "added",
            schema_version: 1,
            payload: "10",
            nonce: <<7::128>>
          },
          changes
        )
      )

    %{record | digest: Log.digest(record)}
  end

  defp resume(state), do: Map.take(state, [:model, :cursor, :seen])

  test "D1/D2 empty, mixed kinds, sorted provider order, deterministic prefixes" do
    assert Log.replay([], 0, fold()) == %{
             model: 0,
             cursor: {0, false, []},
             seen: %{},
             tail: :intact
           }

    rows = [row(1), row(2, %{kind: "noted", payload: "opaque"}), row(3)]
    assert %{model: 20, cursor: {3, false, []}} = Log.replay(Enum.reverse(rows), 3, fold())

    for n <- 0..3 do
      prefix = Enum.take(rows, n)
      first = Log.replay(prefix, n, fold())
      assert first == Log.replay(prefix, n, fold())
      assert first == Log.replay(Enum.reverse(prefix), n, fold())

      assert first.model ==
               Enum.reduce(prefix, 0, fn row, sum ->
                 if row.kind == "added", do: sum + String.to_integer(row.payload), else: sum
               end)
    end
  end

  test "D3 identical duplicate vs changed payload/nonce identity, with checkpoint seed" do
    first = row(1)
    seed = Log.replay([first], 1, fold())
    assert Log.replay([first, first], 1, fold()) == seed
    assert Log.replay([first], 1, Map.put(fold(), :resume, resume(seed))) == seed

    for changed <- [row(1, %{payload: "99"}), row(1, %{nonce: <<8::128>>})] do
      for {rows, spec} <- [
            {[first, changed], fold()},
            {[changed], Map.put(fold(), :resume, resume(seed))}
          ] do
        assert %{model: 10, cursor: {1, true, [{:corrupt, 1, :sequence_identity_mismatch}]}} =
                 Log.replay(rows, 1, spec)
      end
    end
  end

  test "D4 earlier identical/unseen rows diagnose order; conflicting identity stops" do
    seed = Log.replay([row(1), row(3)], 3, fold())
    spec = Map.put(fold(), :resume, resume(seed))

    assert %{model: 20, cursor: {3, true, [{2, :out_of_order}, {1, :out_of_order}, {3, :gap}]}} =
             Log.replay([row(2), row(1)], 3, spec)

    assert %{model: 20, cursor: {3, true, [{:corrupt, 1, :sequence_identity_mismatch}, {3, :gap}]}} =
             Log.replay([row(1, %{payload: "8"})], 3, spec)
  end

  test "D5 gaps still apply later records and preserve diagnostic history across calls" do
    seed = Log.replay([row(2)], 2, fold())
    assert %{model: 10, cursor: {2, true, [{2, :gap}]}} = seed

    assert %{model: 20, cursor: {4, true, [{4, :gap}, {2, :gap}]}} =
             Log.replay([row(4)], 4, Map.put(fold(), :resume, resume(seed)))
  end

  test "D6/D17 unknown kinds, versions, malformed and corrupt last/interior rows stop" do
    for {bad, reason} <- [
          {row(2, %{kind: "unknown"}), :unknown_kind},
          {row(2, %{schema_version: 2}), :unsupported_version},
          {%{row(2) | digest: <<0::256>>}, :digest_mismatch},
          {%{row(2) | nonce: "bad"}, :malformed_row}
        ] do
      for suffix <- [[], [row(3)]] do
        assert %{model: 10, cursor: {1, true, [{:corrupt, 2, ^reason}]}} =
                 Log.replay([row(1), bad] ++ suffix, 2 + length(suffix), fold())
      end
    end

    assert %{cursor: {0, true, [{:corrupt, 0, :malformed_row}]}} = Log.replay([:junk], 1, fold())
  end

  test "D6 reducers raise/throw/exit are bounded and terminal across checkpoint seed" do
    for fail <- [fn -> raise "secret" end, fn -> throw(:secret) end, fn -> exit(:secret) end] do
      spec = %{
        fold()
        | reduce: fn model, _, _, payload -> if payload == "fail", do: fail.(), else: model + 10 end
      }

      damaged = Log.replay([row(1), row(2, %{payload: "fail"}), row(3)], 3, spec)
      assert %{model: 10, cursor: {1, true, [{:corrupt, 2, :reducer_failure}]}} = damaged
      assert Log.replay([row(3)], 3, Map.put(spec, :resume, resume(damaged))) == damaged
    end
  end

  test "D18 truncation compares applied cursor including retained-through-head seed" do
    assert %{model: 10, cursor: {1, true, [{:truncated, 3, 1}]}} = Log.replay([row(1)], 3, fold())
    assert %{cursor: {0, true, [{:truncated, 1, 0}]}} = Log.replay([], 1, fold())
    seed = Log.replay([row(1), row(2)], 2, fold())
    head = %{revision: 2, low_water: 2}
    assert Log.replay([], head, Map.put(fold(), :resume, resume(seed))) == seed

    assert Log.replay([row(1)], head, Map.put(fold(), :resume, resume(seed))).cursor ==
             {2, false, [{1, :out_of_order}]}
  end

  test "staged tail requires adapter capability, explicit uncommitted provenance and final position" do
    bad = %{row(2) | digest: <<0::256>>}

    head = %{
      revision: 1,
      low_water: 0,
      capabilities: %{append_visibility: :staged_uncommitted_tail},
      staged_tail: %{sequence: 2, nonce: bad.nonce, uncommitted: true}
    }

    assert %{model: 10, cursor: {1, false, []}, tail: :torn} =
             Log.replay([bad, row(1)], head, fold())

    for h <- [
          1,
          Map.delete(head, :staged_tail),
          %{head | capabilities: %{append_visibility: :atomic}},
          %{head | staged_tail: %{head.staged_tail | nonce: <<9::128>>}}
        ] do
      assert %{cursor: {1, true, [{:corrupt, 2, :digest_mismatch}]}, tail: :intact} =
               Log.replay([row(1), bad], h, fold())
    end

    assert %{cursor: {1, true, [{:corrupt, 2, :digest_mismatch}]}} =
             Log.replay([row(1), bad, row(3)], head, fold())

    assert %{cursor: {1, true, [{:corrupt, 2, :digest_mismatch}]}} =
             Log.replay([row(1), bad], %{head | revision: 2}, fold())
  end

  test "canonical byte vector and untrusted field validation" do
    r = row(1)
    expected = <<1, 3::32, "a/b", 1::64, 5::32, "added", 1::32, 16::32, 7::128, 2::32, "10">>
    assert Log.canonical_bytes(r) == expected
    assert r.digest == :crypto.hash(:sha256, expected)
    assert Log.validate_row(Map.from_struct(r), fold()) == :ok

    for {key, value, reason} <- [
          {:stream, <<255>>, :invalid_stream},
          {:stream, "", :invalid_stream},
          {:sequence, 0, :invalid_revision},
          {:sequence, 18_446_744_073_709_551_616, :invalid_revision},
          {:schema_version, 4_294_967_296, :unsupported_version},
          {:kind, :added, :unknown_kind},
          {:payload, [], :malformed_row},
          {:nonce, nil, :malformed_row},
          {:digest, nil, :digest_mismatch}
        ] do
      assert Log.validate_row(Map.put(r, key, value), fold()) == {:error, reason}
    end

    assert Log.validate_row(r, fold(), %{max_record_bytes: 1}) == {:error, :record_too_large}
  end

  test "static preflight reasons require no provider and never mint atoms" do
    limits = %{max_record_bytes: 2, max_batch_size: 2}
    req = %{stream: "a", expected: 0, records: [{"added", 1, "10"}], outbox: []}
    assert Log.preflight(req, fold(), limits) == :ok
    assert Log.preflight(nil, fold(), limits) == {:rejected, :invalid_stream}

    for {key, value, reason} <- [
          {:stream, "", :invalid_stream},
          {:expected, -1, :invalid_revision},
          {:records, [], :empty_batch},
          {:records, List.duplicate({"added", 1, "1"}, 3), :batch_too_large},
          {:records, [1 | 2], :empty_batch},
          {:outbox, nil, :invalid_outbox_item},
          {:records, [{"added", 1, "123"}], :record_too_large},
          {:records, [{"not-an-atom", 1, "1"}], :unknown_kind},
          {:records, [{"added", 2, "1"}], :unsupported_version},
          {:outbox, [{"undeclared", "1"}], :invalid_outbox_item}
        ] do
      assert Log.preflight(Map.put(req, key, value), fold(), limits) == {:rejected, reason}
    end
  end

  test "selected laws compile/audit and both production negatives reject" do
    assert {:module, :"Cure.Elzoo.Replay"} = Code.ensure_loaded(:"Cure.Elzoo.Replay")
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(audit, key) == [])

    assert audit.absurd == 0

    for {law, arity} <- [
          duplicate_keeps_total: 4,
          duplicate_keeps_cursor: 4,
          out_of_order_keeps_total: 4,
          out_of_order_keeps_applied: 4,
          gap_marks_damaged: 4,
          non_state_bearing_keeps_total: 3
        ] do
      assert function_exported?(:"Cure.Elzoo.Replay", law, arity)
      IO.puts("ELZ-009 law compiled: #{law}")
    end

    for {name, from, to} <- [
          {"ReplayFalseGap", "ReplayGap(), role))), True())", "ReplayGap(), role))), False())"},
          {"ReplayMutatedDuplicate", "ReplayDuplicate() -> cursor",
           "ReplayDuplicate() -> ReplayCursor{applied: sequence, damaged: cursor.damaged, diagnostics: cursor.diagnostics}"}
        ] do
      assert String.contains?(@source, from)

      wrong =
        @source
        |> String.replace("mod Elzoo.Replay", "mod Elzoo." <> name)
        |> String.replace(from, to)

      assert {:error, {:codegen_error, {:source_context, {:conversion_failure, _, _}, _}}} =
               Cure.Compiler.compile_and_load(wrong, source_roots: @roots)

      IO.puts("ELZ-009 negative rejected: #{name}")
    end
  end

  test "PR #51 rows above the committed head are corruption, never committed state" do
    heads = [
      1,
      %{revision: 1, low_water: 0, capabilities: %{append_visibility: :atomic}},
      %{revision: 1, low_water: 0, capabilities: %{append_visibility: :staged_uncommitted_tail}}
    ]

    for head <- heads do
      assert %{model: 10, cursor: {1, true, [{:corrupt, 2, :beyond_head}]}, tail: :intact} =
               Log.replay([row(1), row(2)], head, fold())
    end
  end
end
