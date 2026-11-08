# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Lease.Postgres do
  @moduledoc """
  PostgreSQL Adapter of `state/lease` over the `integration/sql` Store schema
  (ownership decision OD-1, Option L). Every lease operation is **one
  transaction** on the Store's own Repo: lock the key's head row
  (`FOR UPDATE`), sample `clock_timestamp()` under that lock, read the latest
  lease record, let the pure shell decide, insert the lease record(s) and
  advance the revision, commit. The holder's non-terminal state writes keep
  using the ready Store's public `append`; the rows this Adapter writes are
  ordinary Store records (`Elzoo.DurableLog.Record`, same digest and nonce
  rules), so `read`, `replay`, `confirm` and `retain` handle them unchanged.

  OD-1a: this Adapter understands migration version 1 of
  `Elzoo.DurableLog.Postgres.Migration` only (tables `elzoo_log_heads` and
  `elzoo_log_records` under the Store's prefix) and fails closed with
  `{:error, {:schema, detail}}` on any other table shape, checked at `new/2`
  and before the first statement of every transaction.

  Every entry point refuses to run inside the caller's open Ecto transaction
  (`repo.in_transaction?/0`) before any statement, for the ELZ-032 reason.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Postgres, Store}
  alias Elzoo.Lease.{Clock, Record}

  defstruct [:repo, :prefix, :fold, :limits, :timeout, :hook]

  # Migration v1 pin (OD-1a): columns as {name, data_type, is_nullable, column_default}
  # and constraints as {name, type, definition} exactly as PostgreSQL renders them.
  @heads_columns MapSet.new([
                   {"stream", "text", "NO", nil},
                   {"revision", "bigint", "NO", nil},
                   {"low_water", "bigint", "NO", "0"},
                   {"last_retention_nonce", "bytea", "YES", nil},
                   {"last_retention_digest", "bytea", "YES", nil},
                   {"last_retention_expected", "bigint", "YES", nil},
                   {"last_retention_through", "bigint", "YES", nil}
                 ])
  @heads_constraints MapSet.new([
                       {"elzoo_log_heads_pkey", "p", "PRIMARY KEY (stream)"},
                       {"elzoo_head_bounds", "c",
                        "CHECK (((revision >= 0) AND (low_water >= 0) AND (low_water <= revision)))"}
                     ])
  @records_columns MapSet.new([
                     {"stream", "text", "NO", nil},
                     {"sequence", "bigint", "NO", nil},
                     {"kind", "text", "NO", nil},
                     {"schema_version", "integer", "NO", nil},
                     {"payload", "bytea", "NO", nil},
                     {"nonce", "bytea", "NO", nil},
                     {"digest", "bytea", "NO", nil}
                   ])
  @records_constraints MapSet.new([
                         {"elzoo_log_records_pkey", "p", "PRIMARY KEY (stream, sequence)"},
                         {"elzoo_record_bounds", "c",
                          "CHECK (((sequence > 0) AND (schema_version > 0) AND (octet_length(nonce) = 16) AND (octet_length(digest) = 32)))"}
                       ])
  @record_fields "stream, sequence, kind, schema_version, payload, nonce, digest"

  @doc "Build the Adapter from the Store term; checks the schema shape (OD-1a)."
  def new({Postgres, opts}, lease_opts) do
    opts = Map.new(opts)

    backend = %__MODULE__{
      repo: opts.repo,
      prefix: Map.get(opts, :prefix, "public"),
      fold: opts.fold,
      limits: opts.limits,
      timeout: Keyword.get(lease_opts, :timeout_ms, 30_000),
      hook: Keyword.get(lease_opts, :test_hook)
    }

    cond do
      caller_transaction?(backend) -> {:error, :caller_transaction}
      true -> with :ok <- schema_check(backend), do: {:ok, backend}
    end
  end

  @doc "OD-1a shape check of the two tables through information_schema (read-only)."
  def schema_check(backend) do
    try do
      case shape(backend) do
        :ok -> :ok
        {:schema, detail} -> {:error, {:schema, detail}}
      end
    rescue
      _ -> {:error, :unavailable}
    catch
      _, _ -> {:error, :unavailable}
    end
  end

  defp shape(backend) do
    columns =
      query(
        backend,
        "SELECT table_name, column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema = $1 AND table_name IN ('elzoo_log_heads', 'elzoo_log_records')",
        [backend.prefix]
      ).rows

    constraints =
      query(
        backend,
        "SELECT cl.relname, c.conname, c.contype::text, pg_get_constraintdef(c.oid) FROM pg_constraint c JOIN pg_class cl ON cl.oid = c.conrelid JOIN pg_namespace n ON n.oid = cl.relnamespace WHERE n.nspname = $1 AND cl.relname IN ('elzoo_log_heads', 'elzoo_log_records')",
        [backend.prefix]
      ).rows

    actual_columns = fn table ->
      columns
      |> Enum.filter(&(hd(&1) == table))
      |> Enum.map(fn [_, c, t, n, d] -> {c, t, n, d} end)
      |> MapSet.new()
    end

    actual_constraints = fn table ->
      constraints
      |> Enum.filter(&(hd(&1) == table))
      |> Enum.map(fn [_, name, type, def] -> {name, type, def} end)
      |> MapSet.new()
    end

    detail = %{
      version: 1,
      heads: %{
        columns: diff(@heads_columns, actual_columns.("elzoo_log_heads")),
        constraints: diff(@heads_constraints, actual_constraints.("elzoo_log_heads"))
      },
      records: %{
        columns: diff(@records_columns, actual_columns.("elzoo_log_records")),
        constraints: diff(@records_constraints, actual_constraints.("elzoo_log_records"))
      }
    }

    clean? =
      Enum.all?(
        [
          detail.heads.columns,
          detail.heads.constraints,
          detail.records.columns,
          detail.records.constraints
        ],
        &(&1.missing == [] and &1.unexpected == [])
      )

    if clean?, do: :ok, else: {:schema, detail}
  end

  defp diff(expected, actual),
    do: %{
      missing: MapSet.difference(expected, actual) |> Enum.sort(),
      unexpected: MapSet.difference(actual, expected) |> Enum.sort()
    }

  @doc "The holder's non-terminal write on PostgreSQL: the OD-1a shape check, then the ready Store's append."
  def store_write(backend, store, key, revision, rows, outbox, request) do
    cond do
      caller_transaction?(backend) ->
        {:rejected, :caller_transaction}

      true ->
        case schema_check(backend) do
          :ok -> Store.write(store, :append, [key, revision, rows, outbox], request)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Confirm by nonce only after the caller and OD-1a schema fences pass."
  def confirm(backend, store, key, expected, nonce, rows) do
    cond do
      caller_transaction?(backend) ->
        {:error, :caller_transaction}

      true ->
        case schema_check(backend) do
          :ok -> Log.confirm(store, key, expected, nonce, rows)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  One single-key lease transaction. `fun.(ctx)` receives
  `%{key, revision, low_water, latest, now}` (latest is the latest lease
  `%Record{}` or nil) and returns `{:write, rows, request, result}` or
  `{:refuse, result}`.
  """
  def single(backend, key, fun) do
    if caller_transaction?(backend),
      do: {:error, :caller_transaction},
      else: transact(backend, key, fun)
  end

  defp transact(backend, key, fun) do
    Process.put({__MODULE__, :wrote}, nil)

    try do
      result =
        backend.repo.transaction(
          fn ->
            check_shape!(backend)
            hook(backend, :before_lock, key)
            insert_head(backend, key)
            head = lock_head(backend, key, "FOR UPDATE")
            now = clock(backend)
            hook(backend, :after_clock, key)
            latest = latest(backend, key, head)

            case fun.(%{
                   key: key,
                   revision: head.revision,
                   low_water: head.low_water,
                   latest: latest,
                   now: now
                 }) do
              {:refuse, result} -> backend.repo.rollback({:refuse, result})
              {:write, rows, request, result} -> write!(backend, key, head, rows, request, result)
            end
          end,
          timeout: backend.timeout
        )

      if match?({:ok, _}, result), do: hook(backend, :after_commit, key)
      unwrap(result)
    rescue
      e -> failure(e)
    catch
      :exit, _ -> failure(nil)
    end
  end

  @doc """
  One sweep transaction over sorted candidate keys (`claim_expired`). Per key:
  `FOR UPDATE SKIP LOCKED`; when no row, `SAVEPOINT` + `FOR UPDATE NOWAIT`
  decides existence and lock state at one instant (row → evaluate it; none →
  free; `lock_not_available` → `skipped_locked`). Never inserts a head.
  `fun.(ctx)` returns `{:write, rows, request, held}` or `{:refuse, refusal}`;
  `free_fun.(key)` yields the refusal for a key without a committed head.
  """
  def sweep(backend, keys, limit, fun, free_fun) do
    if caller_transaction?(backend),
      do: {:error, :caller_transaction},
      else: sweep_transact(backend, keys, limit, fun, free_fun)
  end

  defp sweep_transact(backend, keys, limit, fun, free_fun) do
    Process.put({__MODULE__, :wrote}, nil)
    acc0 = %{held: [], refused: %{}, skipped_locked: [], skipped: []}

    try do
      result =
        backend.repo.transaction(
          fn ->
            check_shape!(backend)

            Enum.reduce(Enum.sort(keys), acc0, fn key, acc ->
              if length(acc.held) >= limit do
                %{acc | skipped: acc.skipped ++ [key]}
              else
                case lock_or_probe(backend, key) do
                  :locked_elsewhere ->
                    %{acc | skipped_locked: acc.skipped_locked ++ [key]}

                  :absent ->
                    %{acc | refused: Map.put(acc.refused, key, free_fun.(key))}

                  {:ok, head} ->
                    now = clock(backend)
                    hook(backend, :after_clock, key)
                    latest = latest(backend, key, head)

                    case fun.(%{
                           key: key,
                           revision: head.revision,
                           low_water: head.low_water,
                           latest: latest,
                           now: now
                         }) do
                      {:refuse, refusal} ->
                        %{acc | refused: Map.put(acc.refused, key, refusal)}

                      {:write, rows, request, held} ->
                        write!(backend, key, head, rows, request, held)
                        %{acc | held: acc.held ++ [held]}
                    end
                end
              end
            end)
          end,
          timeout: backend.timeout
        )

      case result do
        {:ok, acc} ->
          hook(backend, :before_return, :sweep)
          {:claimed, acc}

        other ->
          unwrap(other)
      end
    rescue
      e -> failure(e)
    catch
      :exit, _ -> failure(nil)
    end
  end

  defp lock_or_probe(backend, key) do
    case head_rows(backend, key, "FOR UPDATE SKIP LOCKED") do
      [row] ->
        {:ok, head(row)}

      [] ->
        hook(backend, :after_skip_locked, key)
        query(backend, "SAVEPOINT lease_probe")

        case SQL.query(
               backend.repo,
               "SELECT revision, low_water FROM #{table(backend, "elzoo_log_heads")} WHERE stream = $1 FOR UPDATE NOWAIT",
               [key],
               log: false
             ) do
          {:ok, %{rows: [row]}} ->
            query(backend, "RELEASE SAVEPOINT lease_probe")
            {:ok, head(row)}

          {:ok, %{rows: []}} ->
            query(backend, "RELEASE SAVEPOINT lease_probe")
            :absent

          {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} ->
            query(backend, "ROLLBACK TO SAVEPOINT lease_probe")
            :locked_elsewhere

          {:error, error} ->
            raise error
        end
    end
  end

  @doc """
  Unlocked read protocol (`status/2`, `hold/3`, `retention_bound/2`): head,
  clock sample, latest lease record, head again; restart when the head moved,
  at most three times, then `{:error, :contended}`.
  """
  def read(backend, key) do
    if caller_transaction?(backend),
      do: {:error, :caller_transaction},
      else: read_attempt(backend, key, 3)
  end

  defp read_attempt(_backend, _key, 0), do: {:error, :contended}

  defp read_attempt(backend, key, attempts) do
    try do
      case shape(backend) do
        :ok -> :ok
        {:schema, detail} -> throw({:schema, detail})
      end

      first = fetch_head(backend, key)
      now = clock(backend)
      latest = latest(backend, key, first)
      second = fetch_head(backend, key)

      if first == second,
        do:
          {:ok,
           %{
             key: key,
             revision: first.revision,
             low_water: first.low_water,
             latest: latest,
             now: now
           }},
        else: read_attempt(backend, key, attempts - 1)
    rescue
      _ -> {:error, :unavailable}
    catch
      :throw, :malformed -> {:error, :malformed}
      :throw, {:schema, detail} -> {:error, {:schema, detail}}
      :exit, _ -> {:error, :unavailable}
    end
  end

  # ── transaction internals ────────────────────────────────────────────

  defp write!(backend, key, head, rows, request, result) do
    hook(backend, :before_write, key)
    Process.put({__MODULE__, :wrote}, request)
    Enum.each(rows, &insert_record(backend, &1))

    updated =
      query(
        backend,
        "UPDATE #{table(backend, "elzoo_log_heads")} SET revision = $2 WHERE stream = $1 AND revision = $3",
        [key, request.target, head.revision]
      )

    if updated.num_rows != 1 do
      {:indeterminate, info} = Store.unknown(request, :malformed_reply)
      backend.repo.rollback({:indeterminate, Map.put(info, :records, request.records)})
    end

    hook(backend, :after_write, key)
    result
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, {:refuse, result}}), do: result
  defp unwrap({:error, {:indeterminate, info}}), do: {:indeterminate, info}
  defp unwrap({:error, {:schema, detail}}), do: {:error, {:schema, detail}}
  defp unwrap({:error, _}), do: {:error, :unavailable}

  # A failure after the first write statement is an unknown outcome; before it
  # nothing was written: a lock or query timeout is :contended, else :unavailable.
  defp failure(error) do
    case Process.get({__MODULE__, :wrote}) do
      %{} = request ->
        {:indeterminate, info} = Store.unknown(request, :unavailable)
        {:indeterminate, Map.put(info, :records, request.records)}

      _ ->
        if timeout?(error), do: {:error, :contended}, else: {:error, :unavailable}
    end
  end

  defp timeout?(%DBConnection.ConnectionError{message: message}),
    do: String.contains?(message, ["timeout", "timed out"])

  defp timeout?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in [:query_canceled, :lock_not_available]

  defp timeout?(_), do: false

  defp check_shape!(backend) do
    case shape(backend) do
      :ok -> :ok
      {:schema, detail} -> backend.repo.rollback({:schema, detail})
    end
  end

  defp insert_head(backend, key),
    do:
      query(
        backend,
        "INSERT INTO #{table(backend, "elzoo_log_heads")} (stream, revision) VALUES ($1, 0) ON CONFLICT DO NOTHING",
        [key]
      )

  defp lock_head(backend, key, lock) do
    case head_rows(backend, key, lock) do
      [row] -> head(row)
      _ -> throw(:malformed)
    end
  end

  defp fetch_head(backend, key) do
    case head_rows(backend, key, "") do
      [] -> %{revision: 0, low_water: 0}
      [row] -> head(row)
    end
  end

  defp head_rows(backend, key, lock),
    do:
      query(
        backend,
        "SELECT revision, low_water FROM #{table(backend, "elzoo_log_heads")} WHERE stream = $1 #{lock}",
        [key]
      ).rows

  defp head([revision, low_water]) do
    if not Elzoo.DurableLog.Codec.uint?(revision) or not Elzoo.DurableLog.Codec.uint?(low_water) or
         low_water > revision,
       do: throw(:malformed)

    %{revision: revision, low_water: low_water}
  end

  defp clock(backend) do
    case query(backend, Clock.postgres_sql()).rows do
      [[now]] when is_integer(now) and now >= 0 -> now
      _ -> throw(:malformed)
    end
  end

  defp latest(backend, key, head) do
    rows =
      query(
        backend,
        "SELECT #{@record_fields} FROM #{table(backend, "elzoo_log_records")} WHERE stream = $1 AND sequence > $2 AND sequence <= $3 AND kind = ANY($4) ORDER BY sequence DESC LIMIT 1",
        [key, head.low_water, head.revision, Record.kind_names()]
      ).rows

    case rows do
      [] ->
        nil

      [[stream, seq, kind, version, payload, nonce, digest]] ->
        %Log.Record{
          stream: stream,
          sequence: seq,
          kind: kind,
          schema_version: version,
          payload: payload,
          nonce: nonce,
          digest: digest
        }
    end
  end

  defp insert_record(backend, r),
    do:
      query(
        backend,
        "INSERT INTO #{table(backend, "elzoo_log_records")} (#{@record_fields}) VALUES ($1,$2,$3,$4,$5,$6,$7)",
        [r.stream, r.sequence, r.kind, r.schema_version, r.payload, r.nonce, r.digest]
      )

  defp hook(%{hook: nil}, _, _), do: :ok
  defp hook(backend, phase, key), do: backend.hook.(phase, %{key: key, repo: backend.repo})

  defp table(backend, name),
    do: Postgres.identifier(backend.prefix) <> "." <> Postgres.identifier(name)

  defp query(backend, sql, params \\ []), do: SQL.query!(backend.repo, sql, params, log: false)
  # False when the Repo is not running: the next statement then reports :unavailable.
  defp caller_transaction?(backend) do
    backend.repo.in_transaction?() == true
  rescue
    _ -> false
  end
end
