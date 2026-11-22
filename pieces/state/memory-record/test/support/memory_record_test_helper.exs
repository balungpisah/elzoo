# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.MemoryRecord.AdminRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.MemoryRecord.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.MemoryRecord.RepeatableRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.MemoryRecord.TestMigration do
  @moduledoc false
  use Ecto.Migration

  def up, do: Elzoo.MemoryRecord.Migration.install(:persistent_term.get({__MODULE__, :prefix}))
end

defmodule Elzoo.MemoryRecord.Harness do
  @moduledoc false
  alias Ecto.Adapters.SQL

  @doc """
  Fail-closed target guard before any schema, role or data effect: ELZOO_TEST_DATABASE_URL
  must name a database and that database must be the effective current_database().
  """
  def url! do
    url =
      System.get_env("ELZOO_TEST_DATABASE_URL") ||
        raise "ELZOO_TEST_DATABASE_URL is required; tests fail closed"

    if url |> URI.parse() |> Map.get(:path, "") |> to_string() |> String.trim_leading("/") == "",
      do: raise("ELZOO_TEST_DATABASE_URL names no database; refusing")

    url
  end

  @doc "The ELZ-285 application role; the tests fail, not skip, without it."
  def app_role! do
    role =
      System.get_env("ELZOO_TEST_APP_ROLE") ||
        raise "ELZOO_TEST_APP_ROLE is required (ELZ-285); tests fail closed"

    if role =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/,
      do: role,
      else: raise("ELZOO_TEST_APP_ROLE is not a plain identifier; refusing")
  end

  def start!(repo, opts) do
    url = url!()
    configured = url |> URI.parse() |> Map.fetch!(:path) |> String.trim_leading("/")
    {:ok, pid} = repo.start_link([url: url, log: false] ++ opts)
    Process.unlink(pid)

    ExUnit.Callbacks.on_exit(fn ->
      try do
        Supervisor.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    [[effective]] = query!(repo, "SELECT current_database()").rows
    if effective != configured, do: raise("effective database differs from configured; refusing")
    pid
  end

  @doc "after_connect of every application connection: SET ROLE, then optional settings."
  def connect(conn, role, settings) do
    Postgrex.query!(conn, ~s(SET ROLE "#{role}"), [])
    for sql <- settings, do: Postgrex.query!(conn, sql, [])
  end

  def query!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false)

  @doc "A random schema with the Piece's tables and only the README grants for `role`."
  def install!(repo, role) do
    prefix = "elz332_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    query!(repo, ~s(CREATE SCHEMA "#{prefix}"))
    :persistent_term.put({Elzoo.MemoryRecord.TestMigration, :prefix}, prefix)
    :ok = Ecto.Migrator.up(repo, 1, Elzoo.MemoryRecord.TestMigration, prefix: prefix, log: false)
    query!(repo, ~s(GRANT USAGE ON SCHEMA "#{prefix}" TO "#{role}"))
    query!(repo, ~s(GRANT SELECT, INSERT, DELETE ON "#{prefix}".elzoo_memory_records TO "#{role}"))
    query!(repo, ~s(GRANT SELECT, INSERT ON "#{prefix}".elzoo_memory_tombstones TO "#{role}"))
    prefix
  end

  def drop!(repo, prefix), do: query!(repo, ~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))
end
