# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableMailbox.AdminRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.DurableMailbox.AppRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.DurableMailbox.RepeatableRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.DurableMailbox.CrashRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.DurableMailbox.TestMigration do
  @moduledoc false
  use Ecto.Migration

  def up,
    do: Elzoo.DurableMailbox.Migration.install(:persistent_term.get({__MODULE__, :prefix}))
end

defmodule Elzoo.DurableMailbox.Harness do
  @moduledoc false
  alias Ecto.Adapters.SQL

  @tables ["elzoo_mailbox_chains", "elzoo_mailbox_links", "elzoo_mailbox_messages"]

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
    prefix = "elz344_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    query!(repo, ~s(CREATE SCHEMA "#{prefix}"))
    :persistent_term.put({Elzoo.DurableMailbox.TestMigration, :prefix}, prefix)

    :ok =
      Ecto.Migrator.up(repo, 1, Elzoo.DurableMailbox.TestMigration, prefix: prefix, log: false)

    query!(repo, ~s(GRANT USAGE ON SCHEMA "#{prefix}" TO "#{role}"))

    for table <- @tables,
        do: query!(repo, ~s(GRANT SELECT, INSERT, UPDATE ON "#{prefix}".#{table} TO "#{role}"))

    prefix
  end

  def drop!(repo, prefix), do: query!(repo, ~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))
end
