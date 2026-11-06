# SPDX-License-Identifier: Apache-2.0
root = Path.expand("../../../..", __DIR__)

files = [
  "pieces/state/event-log/lib/elzoo/durable_log.ex",
  "pieces/state/event-log/lib/elzoo/durable_log/codec.ex",
  "pieces/state/event-log/lib/elzoo/durable_log/store.ex",
  "pieces/state/event-log/lib/elzoo/durable_log/confirmation.ex",
  "pieces/state/event-log/lib/elzoo/durable_log/conformance.ex",
  "pieces/integration/sql/lib/elzoo/durable_log/postgres.ex",
  "pieces/integration/sql/lib/elzoo/durable_log/postgres/migration.ex"
]

{:ok, _, _} =
  Kernel.ParallelCompiler.compile(Enum.map(files, &Path.join(root, &1)), return_diagnostics: true)

Code.require_file(
  Path.join(root, "pieces/integration/sql/test/support/durable_log_postgres_test_helper.exs")
)

Elzoo.DurableLog.PostgresHarness.database_url!()
replay = Path.join(root, "_build/test/lib/elzoo/ebin/Cure.Elzoo.Replay")

case :code.load_abs(String.to_charlist(replay)) do
  {:module, :"Cure.Elzoo.Replay"} ->
    :ok

  _ ->
    raise "Compile the common replay first: run MIX_ENV=test mix compile from the repository root"
end

defmodule ElzooAshSpike.LogStore do
  @moduledoc "Test-only K1–K5/K8 translation through Ash; not a complete Store adapter."
  require Ash.Query
  alias ElzooAshSpike.{LogHead, LogRecord, LogItem, LogCheckpoint}
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Postgres, PostgresHarness, Record, Store}
  @record_fields [:stream, :sequence, :kind, :schema_version, :payload, :nonce, :digest]
  @item_fields [
    :stream,
    :sequence,
    :position,
    :destination,
    :payload,
    :nonce,
    :digest,
    :ack_nonce,
    :ack_digest
  ]

  def hook({__MODULE__, opts}, :duplicate_insert, [row]),
    do: create(LogRecord, Map.take(row, @record_fields), opts)

  def hook({__MODULE__, opts}, action, args),
    do: PostgresHarness.hook({Postgres, opts}, action, args)

  def append({__MODULE__, opts}, stream, expected, rows, items) do
    req = %{
      operation: :append,
      stream: stream,
      expected: expected,
      target: expected + length(rows),
      nonce: hd(rows).nonce,
      digest: Codec.hash(Enum.map(rows, &Log.canonical_bytes/1))
    }

    write(opts, req, fn ->
      h = get(LogHead, %{stream: stream}, opts)
      h = if h == nil, do: create!(LogHead, %{stream: stream, revision: 0}, opts), else: h
      if h.revision != expected, do: opts.repo.rollback(:cas_conflict)

      h
      |> Ash.Changeset.for_update(:advance, %{target: req.target}, tenant: opts.prefix)
      |> Ash.update!()

      opts.test_hook.(:append, :after_head_cas, opts.repo)
      Enum.each(rows, &create!(LogRecord, Map.take(&1, @record_fields), opts))

      Enum.each(items, fn i ->
        create!(
          LogItem,
          i
          |> Map.take(@item_fields)
          |> Map.drop([:ack_nonce, :ack_digest])
          |> Map.put(:state, "pending"),
          opts
        )
      end)

      {:committed, req.target}
    end)
  end

  def head({__MODULE__, opts}, stream),
    do: read(opts, :head, fn -> {:ok, fetch_head(opts, stream)} end)

  def read_at({__MODULE__, opts}, stream, sequence) do
    read(opts, :read_at, fn ->
      h = fetch_head(opts, stream)

      case get(LogRecord, %{stream: stream, sequence: sequence}, opts) do
        nil -> {:ok, :absent, h}
        r -> {:ok, decode_record(r, opts), h}
      end
    end)
  end

  def pending({__MODULE__, opts}, stream, limit) do
    read(opts, :pending, fn ->
      items =
        LogItem
        |> Ash.Query.filter(stream == ^stream and state == "pending")
        |> Ash.Query.sort([:sequence, :position])
        |> Ash.Query.limit(limit)
        |> Ash.read!(tenant: opts.prefix)

      {:ok, Enum.map(items, &decode_item(&1, opts))}
    end)
  end

  def read_ack({__MODULE__, opts}, id) do
    read(opts, :read_ack, fn ->
      {:ok, {stream, sequence, position}} = Codec.parse_key(id)

      case get(LogItem, %{stream: stream, sequence: sequence, position: position}, opts) do
        nil -> {:ok, :absent}
        item -> {:ok, decode_item(item, opts)}
      end
    end)
  end

  def ack({__MODULE__, opts}, id, nonce) do
    req = Codec.ack_receipt(id, nonce)
    {:ok, {stream, sequence, position}} = Codec.parse_key(id)

    write(opts, req, fn ->
      LogHead
      |> Ash.Query.filter(stream == ^stream)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!(tenant: opts.prefix)

      opts.test_hook.(:maintenance, :after_head_lock, opts.repo)
      item = get(LogItem, %{stream: stream, sequence: sequence, position: position}, opts)
      if item == nil or item.state != "pending", do: opts.repo.rollback(:cas_conflict)

      item
      |> Ash.Changeset.for_update(:ack, %{ack_nonce: nonce, ack_digest: req.digest},
        tenant: opts.prefix
      )
      |> Ash.update!()

      {:committed, sequence}
    end)
  end

  def put_checkpoint({__MODULE__, opts}, c) do
    true = Codec.checkpoint_valid?(c)

    req = %{
      operation: :put_checkpoint,
      stream: c.stream,
      expected: c.sequence,
      target: c.sequence,
      nonce: c.nonce,
      digest: c.digest
    }

    write(opts, req, fn ->
      h = lock_head(opts, c.stream)
      if c.sequence > h.revision, do: opts.repo.rollback(:checkpoint_beyond_tail)

      attrs =
        Map.take(c, [:stream, :sequence, :fold_version, :model, :nonce, :digest])
        |> Map.put(:cursor, Codec.cursor_bytes(c.cursor))
        |> Map.put(:seen, Codec.seen_bytes(c.seen))

      create!(LogCheckpoint, attrs, opts)
      {:committed, c.sequence}
    end)
  end

  def retain({__MODULE__, opts}, stream, expected, through, nonce) do
    req = Codec.receipt(:retain, stream, expected, through, nonce)

    write(opts, req, fn ->
      h = lock_head(opts, stream)
      if h.low_water != expected or through > h.revision, do: opts.repo.rollback(:cas_conflict)

      anchors =
        LogCheckpoint
        |> Ash.Query.filter(stream == ^stream and sequence >= ^through)
        |> Ash.read!(tenant: opts.prefix)

      valid =
        Enum.any?(anchors, fn c ->
          {:ok, cursor} = Codec.decode_cursor(c.cursor)
          {:ok, seen} = Codec.decode_seen(c.seen)

          c =
            c
            |> Map.take([:stream, :sequence, :fold_version, :model, :nonce, :digest])
            |> Map.put(:cursor, cursor)
            |> Map.put(:seen, seen)

          Codec.checkpoint_valid?(c) and not elem(c.cursor, 1)
        end)

      if not valid, do: opts.repo.rollback(:retention_beyond_checkpoint)

      pending =
        LogItem
        |> Ash.Query.filter(stream == ^stream and sequence <= ^through and state == "pending")
        |> Ash.Query.limit(1)
        |> Ash.read!(tenant: opts.prefix)

      if pending != [], do: opts.repo.rollback(:retention_beyond_pending_outbox)

      LogItem
      |> Ash.Query.filter(stream == ^stream and sequence <= ^through and state == "acked")
      |> Ash.read!(tenant: opts.prefix)
      |> Enum.each(&Ash.destroy!(&1, tenant: opts.prefix))

      LogRecord
      |> Ash.Query.filter(stream == ^stream and sequence <= ^through)
      |> Ash.read!(tenant: opts.prefix)
      |> Enum.each(&Ash.destroy!(&1, tenant: opts.prefix))

      h
      |> Ash.Changeset.for_update(
        :retain,
        %{
          low_water: through,
          last_retention_nonce: nonce,
          last_retention_digest: req.digest,
          last_retention_expected: expected,
          last_retention_through: through
        },
        tenant: opts.prefix
      )
      |> Ash.update!()

      {:committed, through}
    end)
  end

  defp lock_head(opts, stream),
    do:
      LogHead
      |> Ash.Query.filter(stream == ^stream)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!(tenant: opts.prefix)

  defp write(opts, req, fun) do
    run = fn ->
      result =
        Ash.transact(
          [LogHead, LogRecord, LogItem, LogCheckpoint],
          fn ->
            result = fun.()
            opts.test_hook.(req.operation, :before_commit, opts.repo)
            result
          end,
          tenant: opts.prefix,
          timeout: 30_000
        )

      case result do
        {:ok, reply} ->
          opts.test_hook.(req.operation, :after_commit_reply, opts.repo)
          reply

        {:error, _} ->
          failed_write(opts, req)
      end
    end

    try do
      Store.classify_write({:reply, opts.test_dispatch.(req.operation, req, run)}, req)
    rescue
      _ in Ash.Error.Invalid -> failed_write(opts, req)
    end
  end

  defp failed_write(opts, %{operation: :append} = req) do
    observed = fetch_head(opts, req.stream).revision

    if observed != req.expected,
      do: {:conflict, %{expected: req.expected, observed: observed}},
      else: Store.unknown(req, :unavailable)
  end

  defp failed_write(opts, %{operation: :ack} = req) do
    {:ok, {stream, sequence, position}} = Codec.parse_key(req.extra)
    item = get(LogItem, %{stream: stream, sequence: sequence, position: position}, opts)

    if item != nil and item.state == "acked",
      do: {:conflict, %{expected: req.expected, observed: :unknown}},
      else: Store.unknown(req, :unavailable)
  end

  defp failed_write(_, req), do: Store.unknown(req, :unavailable)

  defp read(opts, op, fun) do
    case opts.test_read.(op) do
      :ok -> fun.()
      error -> error
    end
  end

  defp get(resource, key, opts),
    do: Ash.get!(resource, key, tenant: opts.prefix, not_found_error?: false)

  defp create(resource, attrs, opts),
    do: resource |> Ash.Changeset.for_create(:create, attrs, tenant: opts.prefix) |> Ash.create()

  defp create!(resource, attrs, opts),
    do: resource |> Ash.Changeset.for_create(:create, attrs, tenant: opts.prefix) |> Ash.create!()

  defp fetch_head(opts, stream) do
    case get(LogHead, %{stream: stream}, opts) do
      nil ->
        %{revision: 0, low_water: 0}

      h ->
        if not Codec.uint?(h.revision) or not Codec.uint?(h.low_water) or h.low_water > h.revision,
          do: raise("malformed head")

        %{revision: h.revision, low_water: h.low_water}
    end
  end

  defp decode_record(r, opts) do
    row = struct!(Record, Map.take(r, @record_fields))
    :ok = Log.validate_row(row, opts.fold, opts.limits)
    row
  end

  defp decode_item(item, opts) do
    state =
      case item.state do
        "pending" -> :pending
        "acked" -> :acked
      end

    i =
      item
      |> Map.take(@item_fields)
      |> Map.put(:state, state)
      |> Map.put(:idempotency_key, Codec.item_key(item.stream, item.sequence, item.position))

    if not Codec.item_valid?(i) or i.destination not in opts.fold.destinations,
      do: raise("malformed outbox item")

    i
  end
end
