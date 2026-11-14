# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Jobs.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.Jobs.TestMigration do
  use Ecto.Migration
  # prefix/0 is Ecto.Migration's: the migrator's :prefix option.
  def up, do: Oban.Migration.up(prefix: prefix())
end

defmodule Elzoo.Jobs.TestHelper do
  @moduledoc false
  alias Elzoo.Jobs.TestRepo

  def url! do
    System.get_env("ELZOO_TEST_DATABASE_URL") ||
      raise "ELZOO_TEST_DATABASE_URL is required: PostgreSQL tests fail closed; provide a disposable local database (never skipped)"
  end

  @doc "Start the test Repo and an isolated Oban schema; returns the prefix."
  def setup_database! do
    case TestRepo.start_link(url: url!(), pool_size: 10, log: false) do
      {:ok, repo} ->
        Process.unlink(repo)
        # The module that started the Repo stops it: an idle pool must not outlive its module.
        ExUnit.Callbacks.on_exit(fn ->
          try do
            Supervisor.stop(TestRepo)
          catch
            :exit, _ -> :ok
          end
        end)

      {:error, {:already_started, _}} ->
        :ok
    end

    try do
      TestRepo.query!("select 1", [], log: false)
    rescue
      _ ->
        raise "ELZOO_TEST_DATABASE_URL is unreachable: PostgreSQL tests fail closed (never skipped)"
    end

    prefix = "elzoo_jobs_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    TestRepo.query!("create schema #{prefix}", [], log: false)
    :ok = Ecto.Migrator.up(TestRepo, 1, Elzoo.Jobs.TestMigration, prefix: prefix, log: false)
    prefix
  end

  def drop!(prefix), do: TestRepo.query!("drop schema if exists #{prefix} cascade", [], log: false)

  def oban_opts(name, prefix, queues),
    do: [
      name: name,
      repo: TestRepo,
      prefix: prefix,
      queues: queues,
      stager: [interval: 50],
      notifier: Oban.Notifiers.PG,
      log: false
    ]

  def poll(fun, tries \\ 600) do
    cond do
      fun.() -> :ok
      tries == 0 -> raise "poll timeout"
      true -> Process.sleep(25) && poll(fun, tries - 1)
    end
  end
end
