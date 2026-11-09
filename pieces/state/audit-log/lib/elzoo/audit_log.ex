# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AuditLog do
  @moduledoc """
  Attributable audit log for records appended through the ready `integration/sql` Store.

  `bind/2` validates a caller-supplied session attribution (`actor`, `action`, `reason`) and
  returns a Store tuple that carries it into the Store's own transaction, where Carbonite and
  the trigger installed by `Elzoo.AuditLog.Migration` record one audit transaction per committed
  change of `elzoo_log_records`. A missing or malformed attribution is refused here, before any
  I/O. Once the migration is installed, the database refuses any `elzoo_log_records` change
  that is not covered by a binding.

  The Repo must be started with `DBConnection.ConnectionPool` (Ecto's default pool): when a
  process dies holding a checked-out connection that pool disconnects it, so the session
  setting never survives into another checkout. Other pools (`Ecto.Adapters.SQL.Sandbox`,
  `DBConnection.Ownership`) are refused by `bind/2`.

  `read/3` returns audit transactions with their changes as plain maps.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.AuditLog.{Attribution, Store}

  @identifier ~r/\A[a-z_][a-z0-9_]{0,62}\z/

  @spec bind(Elzoo.DurableLog.Store.store(), map()) ::
          {:ok, Elzoo.DurableLog.Store.store()}
          | {:error, {:attribution, atom()} | {:store, :unsupported | :unsupported_pool}}
  def bind(store, attribution) do
    with {:ok, opts} <- inner_options(store),
         {:ok, attribution} <- Attribution.validate(attribution),
         :ok <- pool(opts.repo) do
      {:ok,
       {Store,
        %{
          inner: store,
          repo: opts.repo,
          prefix: Map.get(opts, :prefix, "public"),
          fold: opts.fold,
          limits: opts.limits,
          attribution: attribution
        }}}
    end
  end

  defp inner_options({Elzoo.DurableLog.Postgres, opts}) when is_map(opts) do
    if is_atom(Map.get(opts, :repo)) and Map.has_key?(opts, :fold) and Map.has_key?(opts, :limits),
      do: {:ok, opts},
      else: {:error, {:store, :unsupported}}
  end

  defp inner_options(_), do: {:error, {:store, :unsupported}}

  # Local lookup of the running Repo's adapter metadata; no database I/O.
  defp pool(repo) do
    if Keyword.get(Ecto.Adapter.lookup_meta(repo).opts, :pool) == DBConnection.ConnectionPool,
      do: :ok,
      else: {:error, {:store, :unsupported_pool}}
  rescue
    _ -> {:error, {:store, :unsupported_pool}}
  end

  @doc """
  Audit transactions, oldest first. `repo` must connect as the audit owner or as a reader role
  granted `USAGE` on the audit schema and `SELECT` on its `transactions` and `changes` tables;
  the application role has no audit-schema privilege by design and gets
  `{:error, :insufficient_privilege}`. Options: `stream` (only changes of that stream),
  `limit` (1..1000, default 100), `after` (transaction ID cursor, default 0).
  """
  def read(repo, carbonite_prefix, opts \\ []) do
    with :ok <- identifier(carbonite_prefix),
         {:ok, limit} <- bounded(Keyword.get(opts, :limit, 100), 1, 1000),
         {:ok, cursor} <- bounded(Keyword.get(opts, :after, 0), 0, 9_223_372_036_854_775_807),
         {:ok, stream} <- stream(Keyword.get(opts, :stream)) do
      rows =
        SQL.query!(
          repo,
          """
          SELECT t.id, t.xact_id::text, t.inserted_at, t.meta, c.op, c.table_prefix, c.table_name,
                 c.table_pk, c.data
          FROM #{carbonite_prefix}.transactions t
          JOIN #{carbonite_prefix}.changes c ON c.transaction_id = t.id
          WHERE t.id IN (
            SELECT t2.id FROM #{carbonite_prefix}.transactions t2
            WHERE t2.id > $1 AND ($2::text IS NULL OR EXISTS (
              SELECT 1 FROM #{carbonite_prefix}.changes c2
              WHERE c2.transaction_id = t2.id AND c2.table_pk[2] = $2))
            ORDER BY t2.id LIMIT $3)
          ORDER BY t.id, c.id
          """,
          [cursor, stream, limit],
          log: false
        ).rows

      {:ok,
       rows
       |> Enum.chunk_by(&hd/1)
       |> Enum.map(fn [[id, xact, at, meta | _] | _] = changes ->
         %{
           transaction_id: id,
           xact_id: xact,
           inserted_at: at,
           actor: meta["actor"],
           action: meta["action"],
           reason: meta["reason"],
           # Carbonite stores primary-key values in sorted column order: sequence, stream.
           changes:
             for [_, _, _, _, op, table_prefix, table, [seq, s], data] <- changes do
               %{
                 op: op,
                 table: {table_prefix, table},
                 stream: s,
                 sequence: String.to_integer(seq),
                 data: data
               }
             end
         }
       end)}
    end
  rescue
    error in Postgrex.Error -> privilege_or_unavailable(error)
    _ in DBConnection.ConnectionError -> {:error, :unavailable}
  end

  @doc false
  def privilege_or_unavailable(%Postgrex.Error{postgres: %{code: :insufficient_privilege}}),
    do: {:error, :insufficient_privilege}

  def privilege_or_unavailable(_), do: {:error, :unavailable}

  @doc """
  Checks that the migration is installed for `store_prefix` and `carbonite_prefix`: both
  triggers present and enabled on `elzoo_log_records`, and both trigger functions
  `SECURITY DEFINER` with the fixed `search_path`. `bind/2` performs no I/O, so a consumer
  calls this at startup; a binding over a schema without the migration records nothing.
  Returns `:ok` or `{:error, :not_installed | :trigger_disabled | :not_secured | :unavailable}`.
  """
  def verify(repo, store_prefix, carbonite_prefix) do
    with :ok <- identifier(store_prefix),
         :ok <- identifier(carbonite_prefix) do
      triggers =
        SQL.query!(
          repo,
          """
          SELECT t.tgname, t.tgenabled FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = $1 AND c.relname = 'elzoo_log_records' AND NOT t.tgisinternal
            AND t.tgname = ANY($2)
          """,
          [
            store_prefix,
            ["elzoo_audit_attribution", "capture_changes_into_#{carbonite_prefix}_trigger"]
          ],
          log: false
        ).rows

      functions =
        SQL.query!(
          repo,
          """
          SELECT p.proname, p.prosecdef, coalesce(p.proconfig, '{}') FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = $1 AND p.proname IN ('elzoo_attribute', 'capture_changes')
          """,
          [carbonite_prefix],
          log: false
        ).rows

      cond do
        length(triggers) != 2 or length(functions) != 2 -> {:error, :not_installed}
        Enum.any?(triggers, fn [_, enabled] -> enabled != "O" end) -> {:error, :trigger_disabled}
        not Enum.all?(functions, &secured?/1) -> {:error, :not_secured}
        true -> :ok
      end
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :unavailable}
  end

  defp secured?([_, true, config]), do: "search_path=pg_catalog, pg_temp" in config
  defp secured?(_), do: false

  @doc false
  def identifier(name) do
    if is_binary(name) and Regex.match?(@identifier, name),
      do: :ok,
      else: {:error, :invalid_prefix}
  end

  defp bounded(n, min, max) when is_integer(n) and n >= min and n <= max, do: {:ok, n}
  defp bounded(_, _, _), do: {:error, :invalid_option}
  defp stream(nil), do: {:ok, nil}

  defp stream(s) when is_binary(s) and byte_size(s) in 1..256,
    do: if(String.valid?(s), do: {:ok, s}, else: {:error, :invalid_option})

  defp stream(_), do: {:error, :invalid_option}
end
