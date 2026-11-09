# SPDX-License-Identifier: Apache-2.0
sql_helper = Path.expand("durable_log_postgres_test_helper.exs", __DIR__)

sql_helper =
  if File.regular?(sql_helper),
    do: sql_helper,
    else:
      Path.expand(
        "../../../../integration/sql/test/support/durable_log_postgres_test_helper.exs",
        __DIR__
      )

Code.require_file(sql_helper)

defmodule Elzoo.AuditLog.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.AuditLog.SingleTestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.AuditLog.TransientTestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.AuditLog.TestMigration do
  @moduledoc false
  use Ecto.Migration
  def up, do: Elzoo.AuditLog.Migration.up(:persistent_term.get({__MODULE__, :opts}))
  def down, do: Elzoo.AuditLog.Migration.down(:persistent_term.get({__MODULE__, :opts}))
end

defmodule Elzoo.AuditLog.Harness do
  @moduledoc false
  alias Ecto.Adapters.SQL
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{PostgresHarness, Record}

  @limits %{max_record_bytes: 64, max_batch_size: 8, max_checkpoint_bytes: 10_000}
  def limits, do: @limits

  def fold,
    do: %{
      initial: 0,
      kinds: %{"e" => :state_bearing},
      versions: [1],
      destinations: [],
      reduce: fn n, _, _, _ -> n + 1 end
    }

  @doc """
  Fail-closed target guard before any schema, role or data effect: the database named by
  ELZOO_TEST_DATABASE_URL must be the effective current_database(); if
  ELZOO_AUDIT_EXPECTED_DB is set it must name the same database.
  """
  def start!(repo, pool_size, extra \\ []) do
    url = PostgresHarness.database_url!()
    configured = url |> URI.parse() |> Map.get(:path, "") |> String.trim_leading("/")
    if configured == "", do: raise("ELZOO_TEST_DATABASE_URL names no database; refusing")

    case System.get_env("ELZOO_AUDIT_EXPECTED_DB") do
      nil -> :ok
      ^configured -> :ok
      _ -> raise "configured database differs from ELZOO_AUDIT_EXPECTED_DB; refusing"
    end

    pid =
      case repo.start_link([url: url, pool_size: pool_size, log: false] ++ extra) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    Process.unlink(pid)
    PostgresHarness.reachable!(repo)
    [[effective]] = SQL.query!(repo, "SELECT current_database()", [], log: false).rows
    if effective != configured, do: raise("effective database differs from configured; refusing")
    :ok
  end

  def query!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false)

  @doc "Store tables in a private schema plus the audit migration in another one."
  def install!(repo, opts \\ []) do
    hex = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    prefix = "audst_" <> hex
    carbonite = "audcb_" <> hex
    query!(repo, "CREATE SCHEMA #{prefix}")
    :ok = Ecto.Migrator.up(repo, 1, Elzoo.DurableLog.TestMigration, prefix: prefix, log: false)

    if Keyword.get(opts, :audit, true) do
      query!(repo, "CREATE SCHEMA #{carbonite}")

      migration =
        Keyword.merge(
          [store_prefix: prefix, carbonite_prefix: carbonite],
          Keyword.take(opts, [:excluded_columns])
        )

      :persistent_term.put({Elzoo.AuditLog.TestMigration, :opts}, migration)

      :ok =
        Ecto.Migrator.up(repo, 2, Elzoo.AuditLog.TestMigration, prefix: carbonite, log: false)
    end

    %{prefix: prefix, carbonite: carbonite}
  end

  def drop!(repo, %{prefix: prefix, carbonite: carbonite}) do
    query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE")
    query!(repo, "DROP SCHEMA IF EXISTS #{carbonite} CASCADE")
  end

  def store(repo, prefix, extra \\ []),
    do:
      Elzoo.DurableLog.Postgres.store(
        repo,
        [prefix: prefix, fold: fold(), limits: @limits] ++ extra
      )

  def row(stream, sequence, nonce \\ nil, payload \\ nil) do
    r = %Record{
      stream: stream,
      sequence: sequence,
      kind: "e",
      schema_version: 1,
      payload: payload || "secret-#{sequence}",
      nonce: nonce || :crypto.strong_rand_bytes(16)
    }

    %{r | digest: Log.digest(r)}
  end

  @doc "Every captured change, oldest first: [meta, op, table_pk, data]."
  def changes(repo, carbonite),
    do:
      query!(
        repo,
        "SELECT t.meta, c.op, c.table_pk, c.data FROM #{carbonite}.transactions t JOIN #{carbonite}.changes c ON c.transaction_id = t.id ORDER BY c.id"
      ).rows

  def transactions(repo, carbonite),
    do: hd(hd(query!(repo, "SELECT count(*) FROM #{carbonite}.transactions").rows))

  def records(repo, prefix),
    do: hd(hd(query!(repo, "SELECT count(*) FROM #{prefix}.elzoo_log_records").rows))

  def setting(repo),
    do:
      hd(
        hd(
          query!(repo, "SELECT coalesce(current_setting($1, true), '')", [
            Elzoo.AuditLog.Store.setting()
          ]).rows
        )
      )

  @doc "Whether the connected role may create roles (superuser or CREATEROLE)."
  def role_capable?(repo),
    do:
      query!(repo, "SELECT rolsuper OR rolcreaterole FROM pg_roles WHERE rolname = current_user").rows ==
        [[true]]

  def superuser?(repo),
    do: query!(repo, "SELECT rolsuper FROM pg_roles WHERE rolname = current_user").rows == [[true]]

  def refused?(reply), do: match?({:indeterminate, %{cause: :unavailable}}, reply)
end
