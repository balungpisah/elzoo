# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableLog.Conformance do
  @moduledoc """
  Finite, adapter-neutral Store scenarios (K1–K11), not durability proofs.

  Each check takes a zero-arity factory returning `{store, options}` in a fresh,
  empty namespace. Options supply `fold`, `limits`, `record` (a kind/version/payload
  tuple), `destination`, `encode`, and the test-only `hook.(store, action, args)`.
  An optional zero-arity `cleanup` releases the factory's resources.

  Hooks: `:inject, [operation, mode]` installs a one-shot fault (`:rollback`,
  `:reply_loss`, `:unavailable`, `:malformed`, or `{:pause, token}`);
  `:release, [token]` completes the paused transaction; `:rollback, [token]`
  terminally aborts it; `:duplicate_insert, [row]` attempts a raw insert bypassing
  head CAS; `:snapshot, []` captures logical persisted state for equality;
  `:reopen, []` returns a fresh store handle to the same data. A paused operation
  must return indeterminate without blocking the test. Rollback injection occurs
  after inserts but before commit. These hooks are not production Store callbacks.
  """
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Record, Store}

  def checks do
    [
      append_readback: fn factory -> run(factory, &append_readback/2) end,
      cas_exclusivity: fn factory -> run(factory, &cas_exclusivity/2) end,
      stale_conflict_replaces_nothing: fn factory ->
        run(factory, &stale_conflict_replaces_nothing/2)
      end,
      duplicate_insert_refused: fn factory -> run(factory, &duplicate_insert_refused/2) end,
      atomic_head_record_outbox: fn factory -> run(factory, &atomic_head_record_outbox/2) end,
      unavailable_readback: fn factory -> run(factory, &unavailable_readback/2) end,
      checkpoint_bounded_by_tail: fn factory -> run(factory, &checkpoint_bounded_by_tail/2) end,
      ack_cas: fn factory -> run(factory, &ack_cas/2) end,
      restart_replay: fn factory -> run(factory, &restart_replay/2) end,
      preflight_writes_nothing: fn factory -> run(factory, &preflight_writes_nothing/2) end,
      retention_bounded_by_checkpoint: fn factory ->
        run(factory, &retention_bounded_by_checkpoint/2)
      end
    ]
  end

  defp run(factory, check) do
    try do
      {store, opts} = factory.()

      try do
        check.(store, opts)
        :ok
      after
        Map.get(opts, :cleanup, fn -> :ok end).()
      end
    rescue
      error -> {:error, {error.__struct__, Exception.message(error)}}
    catch
      :throw, {:failed, detail} -> {:error, detail}
      kind, _ -> {:error, {:foreign_failure, kind}}
    end
  end

  defp equal(actual, expected) do
    if actual != expected, do: throw({:failed, %{expected: expected, actual: actual}})
    actual
  end

  defp matches(actual, predicate, label) do
    if not predicate.(actual), do: throw({:failed, {label, actual}})
    actual
  end

  defp hook(store, opts, action, args \\ []), do: opts.hook.(store, action, args)
  defp nonce, do: :crypto.strong_rand_bytes(16)

  defp row(opts, sequence, nonce, stream \\ "conformance") do
    {kind, version, payload} = opts.record

    row = %Record{
      stream: stream,
      sequence: sequence,
      kind: kind,
      schema_version: version,
      payload: payload,
      nonce: nonce
    }

    %{row | digest: Log.digest(row)}
  end

  defp item(opts, row, position \\ 1) do
    item = %{
      stream: row.stream,
      sequence: row.sequence,
      position: position,
      destination: opts.destination,
      payload: "effect",
      nonce: row.nonce,
      idempotency_key: Codec.item_key(row.stream, row.sequence, position),
      state: :pending,
      ack_nonce: nil,
      ack_digest: nil
    }

    Map.put(item, :digest, Codec.hash(Codec.item_bytes(item)))
  end

  defp append(store, rows, items \\ []),
    do: call(store, :append, [hd(rows).stream, hd(rows).sequence - 1, rows, items])

  defp call({module, _} = store, op, args) do
    try do
      apply(module, op, [store | args])
    rescue
      error -> {:callback_failure, error.__struct__}
    catch
      kind, _ -> {:callback_failure, kind}
    end
  end

  defp checkpoint(opts, rows, changes \\ %{}) do
    last = Enum.max_by(rows, & &1.sequence)
    replay = Log.replay(rows, last.sequence, opts.fold)

    checkpoint =
      Map.merge(
        %{
          stream: last.stream,
          sequence: last.sequence,
          fold_version: 1,
          model: opts.encode.(replay.model),
          cursor: replay.cursor,
          seen: replay.seen,
          nonce: nonce()
        },
        changes
      )

    Map.put(checkpoint, :digest, Codec.hash(Codec.checkpoint_bytes(checkpoint)))
  end

  defp conflict(result), do: matches(result, &match?({:conflict, _}, &1), :conflict)
  defp unknown(result), do: matches(result, &match?({:unknown, _}, &1), :unknown)
  defp indeterminate(result), do: matches(result, &match?({:indeterminate, _}, &1), :indeterminate)
  defp snapshot(store, opts), do: hook(store, opts, :snapshot)

  defp append_readback(store, opts) do
    rows = [row(opts, 1, nonce()), row(opts, 2, nonce())]

    rows =
      Enum.map(rows, &%{&1 | nonce: hd(rows).nonce}) |> Enum.map(&%{&1 | digest: Log.digest(&1)})

    equal(append(store, rows), {:committed, 2})

    for row <- rows do
      {:ok, actual, head} = Store.read(store, :read_at, [row.stream, row.sequence])
      equal(head.revision, 2)
      equal(Log.canonical_bytes(actual), Log.canonical_bytes(row))
      equal(actual.digest, row.digest)
    end

    equal(Log.confirm(store, "conformance", 0, hd(rows).nonce, rows), {:committed, 2})
  end

  defp cas_exclusivity(store, opts) do
    results =
      1..16
      |> Task.async_stream(fn _ -> append(store, [row(opts, 1, nonce())]) end,
        max_concurrency: 16,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    equal(Enum.count(results, &match?({:committed, 1}, &1)), 1)
    equal(Enum.count(results, &match?({:conflict, %{expected: 0, observed: 1}}, &1)), 15)
    {:ok, head} = Store.read(store, :head, ["conformance"])
    equal(head.revision, 1)
  end

  defp stale_conflict_replaces_nothing(store, opts) do
    row = row(opts, 1, nonce())
    equal(append(store, [row], [item(opts, row)]), {:committed, 1})
    before = snapshot(store, opts)
    other = row(opts, 1, nonce())
    conflict(append(store, [other], [item(opts, other)]))
    equal(snapshot(store, opts), before)
  end

  defp duplicate_insert_refused(store, opts) do
    row = row(opts, 1, nonce())
    equal(append(store, [row]), {:committed, 1})
    before = snapshot(store, opts)

    matches(
      hook(store, opts, :duplicate_insert, [row(opts, 1, nonce())]),
      &match?({:error, _}, &1),
      :raw_unique_constraint
    )

    equal(snapshot(store, opts), before)
  end

  defp atomic_head_record_outbox(store, opts) do
    row = row(opts, 1, nonce())
    before = snapshot(store, opts)
    equal(hook(store, opts, :inject, [:append, :rollback]), :ok)
    indeterminate(append(store, [row], [item(opts, row)]))
    equal(snapshot(store, opts), before)
    equal(Log.confirm(store, row.stream, 0, row.nonce, [row]), {:unknown, :unfenced})
  end

  defp unavailable_readback(store, opts) do
    for {stream, expected} <- [{"first", 0}, {"existing", 1}, {"rollback", 0}, {"competitor", 0}] do
      if expected == 1, do: equal(append(store, [row(opts, 1, nonce(), stream)]), {:committed, 1})
      row = row(opts, expected + 1, nonce(), stream)
      token = make_ref()
      equal(hook(store, opts, :inject, [:append, {:pause, token}]), :ok)
      indeterminate(append(store, [row]))
      equal(Log.confirm(store, stream, expected, row.nonce, [row]), {:unknown, :unfenced})

      case stream do
        "rollback" ->
          equal(hook(store, opts, :rollback, [token]), :ok)
          equal(Log.confirm(store, stream, expected, row.nonce, [row]), {:unknown, :unfenced})

        "competitor" ->
          equal(append(store, [row(opts, 1, nonce(), stream)]), {:committed, 1})
          conflict(hook(store, opts, :release, [token]))
          equal(Log.confirm(store, stream, expected, row.nonce, [row]), :superseded)

        _ ->
          equal(hook(store, opts, :release, [token]), {:committed, expected + 1})
          equal(Log.confirm(store, stream, expected, row.nonce, [row]), {:committed, expected + 1})
      end
    end

    row = row(opts, 1, nonce())
    equal(hook(store, opts, :inject, [:append, :unavailable]), :ok)
    indeterminate(append(store, [row]))
    equal(Log.confirm(store, row.stream, 0, row.nonce, [row]), {:unknown, :unfenced})
    equal(hook(store, opts, :inject, [:append, :reply_loss]), :ok)
    indeterminate(append(store, [row]))
    equal(Log.confirm(store, row.stream, 0, row.nonce, [row]), {:committed, 1})
    equal(hook(store, opts, :inject, [:read_at, :unavailable]), :ok)
    equal(Log.confirm(store, row.stream, 0, row.nonce, [row]), {:unknown, :unavailable})
    equal(hook(store, opts, :inject, [:read_at, :malformed]), :ok)
    equal(Log.confirm(store, row.stream, 0, row.nonce, [row]), {:unknown, :malformed})
    unknown(Log.confirm(store, row.stream, 0, row.nonce, [row, row(opts, 2, row.nonce)]))
  end

  defp checkpoint_bounded_by_tail(store, opts) do
    nonce = nonce()
    rows = [row(opts, 1, nonce), row(opts, 2, nonce)]
    future = checkpoint(opts, rows)
    equal(call(store, :put_checkpoint, [future]), {:rejected, :checkpoint_beyond_tail})
    equal(append(store, rows), {:committed, 2})
    checkpoint = checkpoint(opts, rows, %{cursor: {2, false, [{1, :out_of_order}]}})
    equal(hook(store, opts, :inject, [:put_checkpoint, :reply_loss]), :ok)
    indeterminate(call(store, :put_checkpoint, [checkpoint]))
    equal(Log.confirm_checkpoint(store, checkpoint), {:committed, 2})
    equal(Store.read(store, :read_checkpoint, ["conformance", 2, 1]), {:ok, checkpoint})
    conflict(call(store, :put_checkpoint, [checkpoint]))

    equal(
      Log.confirm_checkpoint(store, checkpoint(opts, rows, %{fold_version: 2})),
      {:unknown, :unfenced}
    )

    too_large =
      checkpoint(opts, rows, %{model: String.duplicate("x", opts.limits.max_checkpoint_bytes + 1)})

    equal(call(store, :put_checkpoint, [too_large]), {:rejected, :checkpoint_too_large})
    damaged_rows = Enum.map(rows, fn r -> row(opts, r.sequence, r.nonce, "damaged") end)
    equal(append(store, damaged_rows), {:committed, 2})
    damaged = checkpoint(opts, [List.last(damaged_rows)])
    equal(call(store, :put_checkpoint, [damaged]), {:committed, 2})

    equal(
      call(store, :retain, ["damaged", 0, 1, nonce()]),
      {:rejected, :retention_beyond_checkpoint}
    )
  end

  defp ack_cas(store, opts) do
    row = row(opts, 1, nonce())
    items = Enum.map(1..4, &item(opts, row, &1))
    equal(append(store, [row], items), {:committed, 1})
    [first, second, third, fourth] = items
    receipt = Codec.ack_receipt(first.idempotency_key, nonce())
    equal(hook(store, opts, :inject, [:ack, :reply_loss]), :ok)
    indeterminate(call(store, :ack, [receipt.extra, receipt.nonce]))
    equal(Log.confirm_ack(store, receipt), {:committed, 1})
    conflict(call(store, :ack, [receipt.extra, nonce()]))

    for {item, compete?} <- [{second, false}, {third, true}] do
      req = Codec.ack_receipt(item.idempotency_key, nonce())
      token = make_ref()
      equal(hook(store, opts, :inject, [:ack, {:pause, token}]), :ok)
      indeterminate(call(store, :ack, [req.extra, req.nonce]))
      equal(Log.confirm_ack(store, req), {:unknown, :unfenced})

      if compete? do
        equal(call(store, :ack, [req.extra, nonce()]), {:committed, 1})
        conflict(hook(store, opts, :release, [token]))
        equal(Log.confirm_ack(store, req), :superseded)
      else
        equal(hook(store, opts, :release, [token]), {:committed, 1})
        equal(Log.confirm_ack(store, req), {:committed, 1})
      end
    end

    req = Codec.ack_receipt(fourth.idempotency_key, nonce())

    for mode <- [:malformed, :unavailable] do
      equal(hook(store, opts, :inject, [:ack, mode]), :ok)
      indeterminate(call(store, :ack, [req.extra, req.nonce]))
      equal(Log.confirm_ack(store, req), {:unknown, :unfenced})
    end

    equal(call(store, :ack, [req.extra, req.nonce]), {:committed, 1})
    equal(Store.read(store, :pending, [row.stream, 10]), {:ok, []})
    equal(call(store, :put_checkpoint, [checkpoint(opts, [row])]), {:committed, 1})
    equal(call(store, :retain, [row.stream, 0, 1, nonce()]), {:committed, 1})
    equal(Log.confirm_ack(store, receipt), {:unknown, :unfenced})
  end

  defp restart_replay(store, opts) do
    n = nonce()
    rows = [row(opts, 1, n), row(opts, 2, n)]
    items = Enum.map(rows, &item(opts, &1))
    equal(append(store, rows, items), {:committed, 2})
    equal(call(store, :ack, [hd(items).idempotency_key, nonce()]), {:committed, 1})
    {:ok, pending} = Store.read(store, :pending, ["conformance", 10])
    {:ok, before, head} = Log.read(store, "conformance", 1, 10)
    replay = Log.replay(before, head, opts.fold)
    reopened = hook(store, opts, :reopen)
    {:ok, after_rows, after_head} = Log.read(reopened, "conformance", 1, 10)
    equal(Log.replay(after_rows, after_head, opts.fold), replay)
    equal(Store.read(reopened, :pending, ["conformance", 10]), {:ok, pending})
  end

  defp preflight_writes_nothing(store, opts) do
    row = row(opts, 1, nonce())
    before = snapshot(store, opts)
    equal(hook(store, opts, :inject, [:append, :malformed]), :ok)
    {kind, version, payload} = opts.record

    for {stream, expected, rows, items, reason} <- [
          {"", 0, [opts.record], [], :invalid_stream},
          {row.stream, -1, [opts.record], [], :invalid_revision},
          {row.stream, 0, [], [], :empty_batch},
          {row.stream, 0, List.duplicate(opts.record, opts.limits.max_batch_size + 1), [],
           :batch_too_large},
          {row.stream, 0,
           [{kind, version, String.duplicate("x", opts.limits.max_record_bytes + 1)}], [],
           :record_too_large},
          {row.stream, 0, [{"not-declared", version, payload}], [], :unknown_kind},
          {row.stream, 0, [{kind, 0, payload}], [], :unsupported_version},
          {row.stream, 0, [opts.record], [{"not-declared", "body"}], :invalid_outbox_item}
        ] do
      request = %{stream: stream, expected: expected, records: rows, outbox: items}
      equal(Log.preflight(request, opts.fold, opts.limits), {:rejected, reason})

      canonical =
        Enum.with_index(rows, 1)
        |> Enum.map(fn {{k, v, p}, seq} ->
          r = %{row | kind: k, schema_version: v, payload: p, sequence: seq}
          %{r | digest: Log.digest(r)}
        end)

      outbox =
        Enum.map(items, fn {destination, payload} ->
          i = %{item(opts, row) | destination: destination, payload: payload}
          %{i | digest: Codec.hash(Codec.item_bytes(i))}
        end)

      equal(call(store, :append, [stream, expected, canonical, outbox]), {:rejected, reason})
      equal(snapshot(store, opts), before)
    end

    {:indeterminate, info} = append(store, [row])
    equal(info.cause, :malformed_reply)
    equal(snapshot(store, opts), before)
    equal(append(store, [row], [item(opts, row)]), {:committed, 1})
    before = snapshot(store, opts)

    equal(
      call(store, :put_checkpoint, [checkpoint(opts, [row(opts, 2, nonce())])]),
      {:rejected, :checkpoint_beyond_tail}
    )

    large =
      checkpoint(opts, [row], %{model: String.duplicate("x", opts.limits.max_checkpoint_bytes + 1)})

    equal(call(store, :put_checkpoint, [large]), {:rejected, :checkpoint_too_large})
    equal(call(store, :retain, [row.stream, 0, 0, nonce()]), {:rejected, :invalid_retention_range})

    equal(
      call(store, :retain, [row.stream, 0, 1, nonce()]),
      {:rejected, :retention_beyond_checkpoint}
    )

    %{append_visibility: visibility} = Store.read(store, :capabilities, [])
    repair_reason = if visibility == :atomic, do: :torn_repair_unsupported, else: :unfenced_tail

    equal(
      call(store, :repair_torn_tail, [row.stream, 1, nonce(), nonce()]),
      {:rejected, repair_reason}
    )

    equal(snapshot(store, opts), before)
    equal(call(store, :put_checkpoint, [checkpoint(opts, [row])]), {:committed, 1})
    before = snapshot(store, opts)

    equal(
      call(store, :retain, [row.stream, 0, 1, nonce()]),
      {:rejected, :retention_beyond_pending_outbox}
    )

    equal(snapshot(store, opts), before)
  end

  defp retention_bounded_by_checkpoint(store, opts) do
    n = nonce()
    rows = Enum.map(1..3, &row(opts, &1, n))
    items = Enum.map(rows, &item(opts, &1))
    equal(append(store, rows, items), {:committed, 3})
    before = snapshot(store, opts)

    equal(
      call(store, :retain, ["conformance", 0, 1, nonce()]),
      {:rejected, :retention_beyond_checkpoint}
    )

    equal(snapshot(store, opts), before)
    equal(call(store, :put_checkpoint, [checkpoint(opts, Enum.take(rows, 2))]), {:committed, 2})
    before = snapshot(store, opts)

    equal(
      call(store, :retain, ["conformance", 0, 3, nonce()]),
      {:rejected, :retention_beyond_checkpoint}
    )

    equal(
      call(store, :retain, ["conformance", 0, 2, nonce()]),
      {:rejected, :retention_beyond_pending_outbox}
    )

    equal(snapshot(store, opts), before)
    equal(call(store, :ack, [hd(items).idempotency_key, nonce()]), {:committed, 1})
    receipt = Codec.receipt(:retain, "conformance", 0, 1, nonce())
    equal(hook(store, opts, :inject, [:retain, :reply_loss]), :ok)
    indeterminate(call(store, :retain, ["conformance", 0, 1, receipt.nonce]))
    equal(Log.confirm_retention(store, receipt), {:committed, 1})
    equal(call(store, :ack, [List.last(items).idempotency_key, nonce()]), {:committed, 3})
    next = row(opts, 4, nonce())

    jobs = [
      fn -> call(store, :ack, [Enum.at(items, 1).idempotency_key, nonce()]) end,
      fn -> append(store, [next], [item(opts, next)]) end,
      fn -> call(store, :retain, ["conformance", 1, 2, nonce()]) end
    ]

    [ack, append, retention] = jobs |> Enum.map(&Task.async/1) |> Enum.map(&Task.await(&1, 30_000))
    equal(ack, {:committed, 2})
    equal(append, {:committed, 4})

    if retention == {:rejected, :retention_beyond_pending_outbox},
      do: equal(call(store, :retain, ["conformance", 1, 2, nonce()]), {:committed, 2}),
      else: equal(retention, {:committed, 2})

    {:ok, head} = Store.read(store, :head, ["conformance"])
    equal({head.revision, head.low_water}, {4, 2})
    equal(Store.read(store, :read_ack, [hd(items).idempotency_key]), {:ok, :absent})
    {:ok, higher} = Store.read(store, :read_ack, [List.last(items).idempotency_key])
    equal(higher.state, :acked)
    equal(Store.read(store, :pending, ["conformance", 10]), {:ok, [item(opts, next)]})
    unknown(Log.confirm_retention(store, receipt))
    before = snapshot(store, opts)
    conflict(call(store, :retain, ["conformance", 1, 2, nonce()]))
    equal(snapshot(store, opts), before)
    equal(call(store, :put_checkpoint, [checkpoint(opts, rows ++ [next])]), {:committed, 4})
    request = Codec.receipt(:retain, "conformance", 2, 3, nonce())
    token = make_ref()
    equal(hook(store, opts, :inject, [:retain, {:pause, token}]), :ok)
    indeterminate(call(store, :retain, ["conformance", 2, 3, request.nonce]))
    equal(Log.confirm_retention(store, request), {:unknown, :unfenced})
    equal(hook(store, opts, :release, [token]), {:committed, 3})
    equal(Log.confirm_retention(store, request), {:committed, 3})
  end
end
