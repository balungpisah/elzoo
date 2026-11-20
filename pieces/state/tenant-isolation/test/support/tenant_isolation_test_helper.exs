# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TenantIsolation.AdminRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.TenantIsolation.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.TenantIsolation.SandboxRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.TenantIsolation.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.TenantIsolation.LogRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.TenantIsolation.DownRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.TenantIsolation.TestMigration do
  @moduledoc false
  use Ecto.Migration
  alias Elzoo.TenantIsolation.Migration

  # Consumer tables in the test schema, then the Piece's DDL as a consumer migration calls it.
  def up do
    p = :persistent_term.get({__MODULE__, :prefix})

    execute(
      ~s|CREATE TABLE "#{p}".flat (id bigserial PRIMARY KEY, tenant text NOT NULL, body text)|
    )

    execute(
      ~s|CREATE TABLE "#{p}".notes (id bigserial PRIMARY KEY, tenant text NOT NULL, space text, body text)|
    )

    execute(
      ~s|CREATE TABLE "#{p}".vnotes (id bigserial PRIMARY KEY, org varchar(64) NOT NULL, area varchar(64) NOT NULL)|
    )

    Migration.install(p)
    # The "name" form resolves through the migration's search_path.
    execute("SET LOCAL search_path TO #{p}")
    Migration.protect("flat", prefix: p, tenant_column: "tenant", space_column: nil)
    execute("RESET search_path")
    Migration.protect({p, "notes"}, prefix: p, tenant_column: "tenant", space_column: "space")
    Migration.protect({p, "vnotes"}, prefix: p, tenant_column: "org", space_column: "area")
  end
end

defmodule Elzoo.TenantIsolation.Harness do
  @moduledoc false
  alias Ecto.Adapters.SQL

  @doc """
  Fail-closed target guard before any schema, role or data effect: ELZOO_TEST_DATABASE_URL must
  name a database, that database must be the effective current_database(), and the connected
  role must not bypass row security (the isolation cases run as the forced owner).
  """
  def url! do
    url =
      System.get_env("ELZOO_TEST_DATABASE_URL") ||
        raise "ELZOO_TEST_DATABASE_URL is required; tests fail closed"

    if url |> URI.parse() |> Map.get(:path, "") |> String.trim_leading("/") == "",
      do: raise("ELZOO_TEST_DATABASE_URL names no database; refusing")

    url
  end

  def start!(repo, opts) do
    url = url!()
    configured = url |> URI.parse() |> Map.fetch!(:path) |> String.trim_leading("/")
    {:ok, pid} = repo.start_link([url: url] ++ Keyword.merge([log: false], opts))
    Process.unlink(pid)

    ExUnit.Callbacks.on_exit(fn ->
      try do
        Supervisor.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    if Keyword.get(opts, :pool) != Ecto.Adapters.SQL.Sandbox do
      [[effective]] = query!(repo, "SELECT current_database()").rows
      if effective != configured, do: raise("effective database differs from configured; refusing")
    end

    pid
  end

  def query!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false)

  def bypass?(repo),
    do:
      query!(repo, "SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user").rows ==
        [[true]]

  def role_capable?(repo),
    do:
      query!(repo, "SELECT rolsuper OR rolcreaterole FROM pg_roles WHERE rolname = current_user").rows ==
        [[true]]

  @doc "A random schema with the consumer tables, the readers and three protected tables."
  def install!(repo) do
    prefix = "elz270_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    query!(repo, ~s(CREATE SCHEMA "#{prefix}"))
    :persistent_term.put({Elzoo.TenantIsolation.TestMigration, :prefix}, prefix)

    :ok =
      Ecto.Migrator.up(repo, 1, Elzoo.TenantIsolation.TestMigration, prefix: prefix, log: false)

    prefix
  end

  def drop!(repo, prefix), do: query!(repo, ~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))
end
