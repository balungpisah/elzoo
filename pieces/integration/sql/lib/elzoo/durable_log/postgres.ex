# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableLog.Postgres do
  @moduledoc """
  Atomic Store over a consumer-owned Ecto Repo. Options: `repo`, optional `prefix`
  (default public), fixed `fold` and `limits`. No Repo or application is shipped.
  `test_dispatch` and `test_hook` are explicit test-only injection seams.
  Invalid record rows remain visible to replay as damaged input, never repaired;
  checkpoint decoding failures remain invalid snapshots for recovery fallback.

  Every callback refuses to run inside the calling process's open Ecto transaction
  on `repo` (`repo.in_transaction?/0`), before any statement: writes return
  `{:rejected, :caller_transaction}` and reads `{:error, :caller_transaction}`. A
  nested `repo.transaction/2` would join the caller's transaction, so no COMMIT
  would back a `committed` reply. Static, I/O-free validation runs first, so invalid
  input inside a caller transaction keeps its existing result (a write's rejection
  or `indeterminate(:malformed_reply)`, `{:error, :malformed}` from a read with an I/O-free pre-check such as `read_ack` key parsing or an unknown `read_maintenance` operation; reads that validate input during the query, such as `head`/`read` with an invalid stream, return `{:error, :caller_transaction}` instead); no SQL is issued in either case. The
  check is per process and is false under `Ecto.Adapters.SQL.Sandbox` outside an
  explicit `Repo.transaction`; see the
  README limits.
  """
  @behaviour Elzoo.DurableLog.Store
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Record, Store}
  alias Ecto.Adapters.SQL
  @record_fields "stream, sequence, kind, schema_version, payload, nonce, digest"
  @item_fields "stream, sequence, position, destination, payload, nonce, digest, state, ack_nonce, ack_digest"
  @checkpoint_fields "stream, sequence, fold_version, model, cursor, seen, nonce, digest"

  def store(repo, opts) do
    opts = opts |> Map.new() |> Map.put(:repo, repo)
    if not Codec.fold_valid?(opts.fold), do: raise(ArgumentError, "invalid fold tables")
    identifier(Map.get(opts, :prefix, "public"))
    {__MODULE__, opts}
  end

  def identifier(name) when is_binary(name) do
    if byte_size(name) in 1..63 and String.valid?(name) and not String.contains?(name, <<0>>),
      do: "\"" <> String.replace(name, "\"", "\"\"") <> "\"",
      else: raise(ArgumentError, "invalid SQL identifier")
  end

  defp options({__MODULE__, opts}), do: Map.new(opts)

  defp table(opts, name),
    do: identifier(Map.get(opts, :prefix, "public")) <> "." <> identifier(name)

  defp query(opts, sql, params \\ []), do: SQL.query!(opts.repo, sql, params, log: false)

  @impl true
  def capabilities(_), do: %{append_visibility: :atomic}
  @impl true
  def repair_torn_tail(store, _, _, _, _),
    do: refuse_in_caller_transaction(store, {:rejected, :torn_repair_unsupported})

  @impl true
  def append(store, stream, expected, records, items) do
    info = %{
      operation: :append,
      stream: stream,
      expected: expected,
      target: nil,
      nonce: nil,
      digest: nil
    }

    try do
      opts = options(store)

      tuples =
        Enum.map(
          records,
          &{Map.get(&1, :kind), Map.get(&1, :schema_version), Map.get(&1, :payload)}
        )

      outbox = Enum.map(items, &{Map.get(&1, :destination), Map.get(&1, :payload)})

      with :ok <-
             Log.preflight(
               %{stream: stream, expected: expected, records: tuples, outbox: outbox},
               opts.fold,
               opts.limits
             ) do
        if valid_batch?(opts, stream, expected, records, items) do
          info = %{
            info
            | target: expected + length(records),
              nonce: hd(records).nonce,
              digest: Codec.hash(Enum.map(records, &Log.canonical_bytes/1))
          }

          write(opts, info, fn ->
            if expected == 0, do: insert_head(opts, stream)

            result =
              query(
                opts,
                "UPDATE #{table(opts, "elzoo_log_heads")} SET revision = $2 WHERE stream = $1 AND revision = $3",
                [stream, info.target, expected]
              )

            if result.num_rows == 0,
              do:
                opts.repo.rollback(
                  {:conflict, %{expected: expected, observed: fetch_head(opts, stream).revision}}
                )

            barrier(opts, :append, :after_head_cas)
            Enum.each(records, &insert_record(opts, &1))
            Enum.each(items, &insert_item(opts, &1))
            {:committed, info.target}
          end)
        else
          {:rejected, :invalid_outbox_item}
        end
      end
    catch
      _, _ -> Store.unknown(info, :malformed_reply)
    end
  end

  @impl true
  def head(store, stream), do: read(store, :head, fn opts -> {:ok, fetch_head(opts, stream)} end)
  @impl true
  def read(store, stream, from, limit) do
    read(store, :read, fn opts ->
      h = fetch_head(opts, stream)

      if from <= h.low_water do
        {:error, {:pruned, h.low_water}}
      else
        rows =
          query(
            opts,
            "SELECT #{@record_fields} FROM #{table(opts, "elzoo_log_records")} WHERE stream = $1 AND sequence >= $2 ORDER BY sequence LIMIT $3",
            [stream, from, limit]
          ).rows

        {:ok, Enum.map(rows, &record(opts, &1)), h}
      end
    end)
  end

  @impl true
  def read_at(store, stream, sequence) do
    read(store, :read_at, fn opts ->
      h = fetch_head(opts, stream)

      if sequence <= h.low_water do
        {:error, {:pruned, h.low_water}}
      else
        rows =
          query(
            opts,
            "SELECT #{@record_fields} FROM #{table(opts, "elzoo_log_records")} WHERE stream = $1 AND sequence = $2",
            [stream, sequence]
          ).rows

        {:ok,
         case rows do
           [] -> :absent
           [row] -> record(opts, row)
         end, h}
      end
    end)
  end

  @impl true
  def put_checkpoint(store, checkpoint) do
    info = %{
      operation: :put_checkpoint,
      stream: Map.get(checkpoint, :stream),
      expected: Map.get(checkpoint, :sequence),
      target: Map.get(checkpoint, :sequence),
      nonce: Map.get(checkpoint, :nonce),
      digest: Map.get(checkpoint, :digest)
    }

    opts = options(store)

    cond do
      not Codec.checkpoint_valid?(checkpoint) ->
        Store.unknown(info, :malformed_reply)

      byte_size(Codec.checkpoint_bytes(checkpoint)) + 32 > opts.limits.max_checkpoint_bytes ->
        {:rejected, :checkpoint_too_large}

      true ->
        write(opts, info, fn ->
          h = lock_head(opts, checkpoint.stream)

          if checkpoint.sequence > h.revision,
            do: opts.repo.rollback({:rejected, :checkpoint_beyond_tail})

          c = checkpoint

          query(
            opts,
            "INSERT INTO #{table(opts, "elzoo_checkpoints")} (#{@checkpoint_fields}) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)",
            [
              c.stream,
              c.sequence,
              c.fold_version,
              c.model,
              Codec.cursor_bytes(c.cursor),
              Codec.seen_bytes(c.seen),
              c.nonce,
              c.digest
            ]
          )

          {:committed, c.sequence}
        end)
    end
  end

  @impl true
  def latest_checkpoint(store, stream, version) do
    read(store, :latest_checkpoint, fn opts ->
      rows =
        query(
          opts,
          "SELECT #{@checkpoint_fields} FROM #{table(opts, "elzoo_checkpoints")} WHERE stream = $1 AND fold_version = $2 ORDER BY sequence DESC LIMIT 1",
          [stream, version]
        ).rows

      {:ok,
       case rows do
         [] -> :none
         [c] -> checkpoint(c)
       end}
    end)
  end

  @impl true
  def read_checkpoint(store, stream, sequence, version) do
    read(store, :read_checkpoint, fn opts ->
      rows =
        query(
          opts,
          "SELECT #{@checkpoint_fields} FROM #{table(opts, "elzoo_checkpoints")} WHERE stream = $1 AND sequence = $2 AND fold_version = $3",
          [stream, sequence, version]
        ).rows

      {:ok,
       case rows do
         [] -> :absent
         [c] -> checkpoint(c)
       end}
    end)
  end

  @impl true
  def pending(store, stream, limit) do
    read(store, :pending, fn opts ->
      rows =
        query(
          opts,
          "SELECT #{@item_fields} FROM #{table(opts, "elzoo_outbox")} WHERE stream = $1 AND state = 'pending' ORDER BY sequence, position LIMIT $2",
          [stream, limit]
        ).rows

      decoded = Enum.map(rows, &item/1)
      if Enum.all?(decoded, &valid_item?(opts, &1)), do: {:ok, decoded}, else: {:error, :malformed}
    end)
  end

  @impl true
  def read_ack(store, id) do
    with {:ok, {stream, sequence, position}} <- Codec.parse_key(id) do
      read(store, :read_ack, fn opts ->
        rows =
          query(
            opts,
            "SELECT #{@item_fields} FROM #{table(opts, "elzoo_outbox")} WHERE stream=$1 AND sequence=$2 AND position=$3",
            [stream, sequence, position]
          ).rows

        case rows do
          [] ->
            {:ok, :absent}

          [row] ->
            i = item(row)
            if valid_item?(opts, i), do: {:ok, i}, else: {:error, :malformed}
        end
      end)
    else
      _ -> {:error, :malformed}
    end
  end

  @impl true
  def ack(store, id, nonce) do
    with {:ok, {stream, sequence, position}} <- Codec.parse_key(id), true <- Codec.nonce?(nonce) do
      opts = options(store)
      request = Codec.ack_receipt(id, nonce)

      write(opts, request, fn ->
        lock_head(opts, stream)

        rows =
          query(
            opts,
            "SELECT #{@item_fields} FROM #{table(opts, "elzoo_outbox")} WHERE stream=$1 AND sequence=$2 AND position=$3 FOR UPDATE",
            [stream, sequence, position]
          ).rows

        case rows do
          [row] ->
            i = item(row)
            if not valid_item?(opts, i), do: opts.repo.rollback(:malformed)

            if i.state != :pending,
              do: opts.repo.rollback({:conflict, %{expected: sequence, observed: :unknown}})

          [] ->
            opts.repo.rollback({:conflict, %{expected: sequence, observed: :unknown}})
        end

        query(
          opts,
          "UPDATE #{table(opts, "elzoo_outbox")} SET state='acked', ack_nonce=$4, ack_digest=$5 WHERE stream=$1 AND sequence=$2 AND position=$3 AND state='pending'",
          [stream, sequence, position, nonce, request.digest]
        )

        {:committed, sequence}
      end)
    else
      _ -> {:rejected, :invalid_outbox_item}
    end
  end

  @impl true
  def retain(store, stream, expected, through, nonce) do
    if Codec.stream?(stream) and Codec.uint?(expected) and Codec.uint?(through) and
         expected < through and Codec.nonce?(nonce) do
      opts = options(store)
      request = Codec.receipt(:retain, stream, expected, through, nonce)

      write(opts, request, fn ->
        h = lock_head(opts, stream)

        cond do
          through > h.revision ->
            opts.repo.rollback({:rejected, :invalid_retention_range})

          expected != h.low_water ->
            opts.repo.rollback({:conflict, %{expected: expected, observed: h.low_water}})

          true ->
            :ok
        end

        anchors =
          query(
            opts,
            "SELECT #{@checkpoint_fields} FROM #{table(opts, "elzoo_checkpoints")} WHERE stream=$1 AND sequence >= $2",
            [stream, through]
          ).rows

        if not Enum.any?(anchors, fn row ->
             c = checkpoint(row)
             Codec.checkpoint_valid?(c) and not elem(c.cursor, 1)
           end),
           do: opts.repo.rollback({:rejected, :retention_beyond_checkpoint})

        pending =
          query(
            opts,
            "SELECT 1 FROM #{table(opts, "elzoo_outbox")} WHERE stream=$1 AND sequence <= $2 AND state='pending' LIMIT 1",
            [stream, through]
          ).rows

        if pending != [], do: opts.repo.rollback({:rejected, :retention_beyond_pending_outbox})

        query(
          opts,
          "DELETE FROM #{table(opts, "elzoo_outbox")} WHERE stream=$1 AND sequence <= $2 AND state='acked'",
          [stream, through]
        )

        query(
          opts,
          "DELETE FROM #{table(opts, "elzoo_log_records")} WHERE stream=$1 AND sequence <= $2",
          [stream, through]
        )

        query(
          opts,
          "UPDATE #{table(opts, "elzoo_log_heads")} SET low_water=$2, last_retention_nonce=$3, last_retention_digest=$4, last_retention_expected=$5, last_retention_through=$2 WHERE stream=$1",
          [stream, through, nonce, request.digest, expected]
        )

        {:committed, through}
      end)
    else
      {:rejected, :invalid_retention_range}
    end
  end

  @impl true
  def read_maintenance(store, stream, :retain),
    do:
      read(store, :read_maintenance, fn opts ->
        {:ok, Map.get(fetch_head(opts, stream), :last_retention, :absent)}
      end)

  def read_maintenance(store, _, :repair_torn_tail),
    do: refuse_in_caller_transaction(store, {:ok, :absent})

  def read_maintenance(_, _, _), do: {:error, :malformed}

  defp write(opts, request, transaction) do
    run = fn ->
      result =
        opts.repo.transaction(
          fn ->
            try do
              result = transaction.()
              barrier(opts, request.operation, :before_commit)
              result
            rescue
              e in Postgrex.Error ->
                if e.postgres && e.postgres.code == :unique_violation,
                  do:
                    opts.repo.rollback(
                      {:conflict, %{expected: request.expected, observed: :unknown}}
                    ),
                  else: reraise(e, __STACKTRACE__)
            end
          end,
          timeout: Map.get(opts, :timeout, 30_000)
        )

      case result do
        {:ok, reply} ->
          barrier(opts, request.operation, :after_commit_reply)
          reply

        {:error, {:conflict, _} = reply} ->
          reply

        {:error, {:rejected, _} = reply} ->
          reply

        {:error, _} ->
          Store.unknown(request, :unavailable)
      end
    end

    try do
      result =
        case {caller_transaction?(opts), Map.get(opts, :test_dispatch)} do
          {true, _} -> {:rejected, :caller_transaction}
          {false, nil} -> run.()
          {false, dispatch} -> dispatch.(request.operation, request, run)
        end

      Store.classify_write({:reply, result}, request)
    rescue
      _ in [Postgrex.Error, DBConnection.ConnectionError] -> Store.unknown(request, :unavailable)
      _ -> Store.unknown(request, :exception)
    catch
      :exit, {:timeout, _} -> Store.unknown(request, :timeout)
      :exit, _ -> Store.unknown(request, :exit)
      _, _ -> Store.unknown(request, :exception)
    end
  end

  defp read(store, operation, fun) do
    try do
      opts = options(store)
      if caller_transaction?(opts), do: throw(:caller_transaction)

      case Map.get(opts, :test_read) do
        nil ->
          :ok

        hook ->
          case hook.(operation) do
            :ok -> :ok
            {:error, reason} -> throw(reason)
          end
      end

      case opts.repo.transaction(
             fn ->
               query(opts, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
               fun.(opts)
             end,
             timeout: Map.get(opts, :timeout, 5_000)
           ) do
        {:ok, result} -> result
        _ -> {:error, :unavailable}
      end
    rescue
      _ -> {:error, :unavailable}
    catch
      :throw, :malformed -> {:error, :malformed}
      :throw, :caller_transaction -> {:error, :caller_transaction}
      _, _ -> {:error, :unavailable}
    end
  end

  # Process-local check (Ecto SQL 3.14.0 reads the conn from the process dictionary);
  # it issues no statement. Callers keep it inside their never-raise handling.
  defp caller_transaction?(opts), do: opts.repo.in_transaction?() == true

  # Callbacks that otherwise answer without I/O. If the Repo cannot be looked up,
  # no caller transaction can be open on it, so the fixed reply stands.
  defp refuse_in_caller_transaction(store, reply) do
    caller? =
      try do
        caller_transaction?(options(store))
      rescue
        _ -> false
      catch
        _, _ -> false
      end

    cond do
      not caller? -> reply
      match?({:rejected, _}, reply) -> {:rejected, :caller_transaction}
      true -> {:error, :caller_transaction}
    end
  end

  defp insert_head(opts, stream),
    do:
      query(
        opts,
        "INSERT INTO #{table(opts, "elzoo_log_heads")} (stream,revision) VALUES ($1,0) ON CONFLICT DO NOTHING",
        [stream]
      )

  defp lock_head(opts, stream) do
    insert_head(opts, stream)
    h = fetch_head(opts, stream, " FOR UPDATE")
    barrier(opts, :maintenance, :after_head_lock)
    h
  end

  defp fetch_head(opts, stream, lock \\ "") do
    rows =
      query(
        opts,
        "SELECT revision, low_water, last_retention_nonce, last_retention_digest, last_retention_expected, last_retention_through FROM #{table(opts, "elzoo_log_heads")} WHERE stream=$1#{lock}",
        [stream]
      ).rows

    case rows do
      [] ->
        %{revision: 0, low_water: 0}

      [[revision, low_water, nonce, digest, expected, through]] ->
        if not Codec.uint?(revision) or not Codec.uint?(low_water) or low_water > revision,
          do: throw(:malformed)

        h = %{revision: revision, low_water: low_water}

        if [nonce, digest, expected, through] == [nil, nil, nil, nil] do
          h
        else
          if not Codec.uint?(expected) or not Codec.uint?(through) or not Codec.nonce?(nonce) or
               not is_binary(digest),
             do: throw(:malformed)

          receipt = Codec.receipt(:retain, stream, expected, through, nonce)
          if not Codec.receipt_valid?(receipt) or receipt.digest != digest, do: throw(:malformed)
          Map.put(h, :last_retention, receipt)
        end
    end
  end

  defp barrier(opts, operation, phase) do
    if hook = Map.get(opts, :test_hook), do: hook.(operation, phase, opts.repo)
    :ok
  end

  defp insert_record(opts, r),
    do:
      query(
        opts,
        "INSERT INTO #{table(opts, "elzoo_log_records")} (#{@record_fields}) VALUES ($1,$2,$3,$4,$5,$6,$7)",
        [r.stream, r.sequence, r.kind, r.schema_version, r.payload, r.nonce, r.digest]
      )

  defp insert_item(opts, i),
    do:
      query(
        opts,
        "INSERT INTO #{table(opts, "elzoo_outbox")} (#{@item_fields}) VALUES ($1,$2,$3,$4,$5,$6,$7,'pending',NULL,NULL)",
        [i.stream, i.sequence, i.position, i.destination, i.payload, i.nonce, i.digest]
      )

  defp record(opts, [stream, seq, kind, version, payload, nonce, digest]) do
    row = %Record{
      stream: stream,
      sequence: seq,
      kind: kind,
      schema_version: version,
      payload: payload,
      nonce: nonce,
      digest: digest
    }

    case Log.validate_row(row, opts.fold, opts.limits) do
      :ok -> row
      {:error, _} -> Map.from_struct(row)
    end
  end

  defp item([stream, seq, pos, dest, payload, nonce, digest, state, ack_nonce, ack_digest]) do
    state =
      case state do
        "pending" -> :pending
        "acked" -> :acked
        _ -> :invalid
      end

    %{
      stream: stream,
      sequence: seq,
      position: pos,
      destination: dest,
      payload: payload,
      nonce: nonce,
      digest: digest,
      state: state,
      ack_nonce: ack_nonce,
      ack_digest: ack_digest,
      idempotency_key: Codec.item_key(stream, seq, pos)
    }
  end

  defp checkpoint([stream, seq, version, model, cursor, seen, nonce, digest]) do
    c = %{
      stream: stream,
      sequence: seq,
      fold_version: version,
      model: model,
      nonce: nonce,
      digest: digest
    }

    with {:ok, cursor} <- Codec.decode_cursor(cursor), {:ok, seen} <- Codec.decode_seen(seen) do
      decoded = Map.merge(c, %{cursor: cursor, seen: seen})
      if Codec.checkpoint_valid?(decoded), do: decoded, else: Map.delete(decoded, :digest)
    else
      _ -> c
    end
  end

  defp valid_item?(opts, i),
    do:
      Codec.item_valid?(i) and i.destination in Map.get(opts.fold, :destinations, []) and
        byte_size(i.payload) <= opts.limits.max_record_bytes

  defp valid_batch?(opts, stream, expected, records, items) do
    nonce = hd(records).nonce

    Enum.with_index(records, expected + 1)
    |> Enum.all?(fn {r, seq} ->
      r.stream == stream and r.sequence == seq and r.nonce == nonce and
        Log.validate_row(r, opts.fold, opts.limits) == :ok
    end) and
      Enum.all?(items, fn i ->
        valid_item?(opts, i) and i.stream == stream and i.nonce == nonce and i.state == :pending and
          i.sequence > expected and i.sequence <= expected + length(records)
      end)
  end
end
