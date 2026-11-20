# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RetentionErasure.AdminRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.RetentionErasure.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.RetentionErasure.LogRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.RetentionErasure.DownRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.RetentionErasure.IdleRepo do
  # Never started: every call on it raises.
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.RetentionErasure.TestMigration do
  @moduledoc false
  use Ecto.Migration

  # The Piece's DDL as a consumer migration calls it, in the test's random schema.
  def up, do: Elzoo.RetentionErasure.Migration.install(:persistent_term.get({__MODULE__, :prefix}))
end

defmodule Elzoo.RetentionErasure.Harness do
  @moduledoc false
  alias Ecto.Adapters.SQL

  @doc """
  Fail-closed target guard before any schema or data effect: ELZOO_TEST_DATABASE_URL must name a
  database, and that database must be the effective current_database().
  """
  def url! do
    url =
      System.get_env("ELZOO_TEST_DATABASE_URL") ||
        raise "ELZOO_TEST_DATABASE_URL is required; tests fail closed"

    if url |> URI.parse() |> Map.get(:path, "") |> to_string() |> String.trim_leading("/") == "",
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

    [[effective]] = query!(repo, "SELECT current_database()").rows
    if effective != configured, do: raise("effective database differs from configured; refusing")
    pid
  end

  def query!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false)

  @doc "A random schema holding the three vault tables."
  def install!(repo) do
    prefix = "elz279_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    query!(repo, ~s(CREATE SCHEMA "#{prefix}"))
    :persistent_term.put({Elzoo.RetentionErasure.TestMigration, :prefix}, prefix)

    :ok =
      Ecto.Migrator.up(repo, 1, Elzoo.RetentionErasure.TestMigration, prefix: prefix, log: false)

    prefix
  end

  def drop!(repo, prefix), do: query!(repo, ~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))
end

defmodule Elzoo.RetentionErasure.TestKek do
  @moduledoc false
  # The host's KEK store for one test: versions => 32 bytes, the current version and a log of
  # every Need call. A destroyed version answers {:error, :not_found}.
  alias Elzoo.Secrets.Credential

  def start!(versions \\ 1..1) do
    keys = Map.new(versions, &{&1, :crypto.strong_rand_bytes(32)})
    {:ok, pid} = Agent.start(fn -> %{keys: keys, current: Enum.max(versions), calls: []} end)
    ExUnit.Callbacks.on_exit(fn -> Agent.stop(pid) end)
    pid
  end

  def need(kek), do: fn arg -> answer(kek, arg) end

  @doc "A Need that reports each call to `test` and waits for `:release` before answering."
  def gated(kek, test) do
    fn arg ->
      send(test, {:kek_called, self(), arg})

      receive do
        :release -> answer(kek, arg)
      end
    end
  end

  def answer(kek, arg) do
    Agent.get_and_update(kek, fn s ->
      version = if arg == :current, do: s.current, else: arg

      reply =
        case s.keys do
          %{^version => bytes} -> {:ok, credential(bytes, version)}
          _ -> {:error, :not_found}
        end

      {reply, %{s | calls: [arg | s.calls]}}
    end)
  end

  def calls(kek), do: Agent.get(kek, &Enum.reverse(&1.calls))
  def bytes(kek, version), do: Agent.get(kek, & &1.keys[version])
  def destroy(kek, version), do: Agent.update(kek, &%{&1 | keys: Map.delete(&1.keys, version)})

  def credential(bytes, version),
    do: %Credential{value: bytes, version: version, expires_at_unix_ms: 0}
end
