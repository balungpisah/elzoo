# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableJob.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.DurableJob.UnreachableRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.DurableJob.TestMigration do
  use Ecto.Migration

  def up do
    # prefix/0 is Ecto.Migration's: the migrator's :prefix option.
    Oban.Migration.up(prefix: prefix())
    Elzoo.DurableLog.Postgres.Migration.up()
  end
end

defmodule Elzoo.DurableJob.TestHelper do
  @moduledoc false
  import ExUnit.Callbacks
  alias Elzoo.DurableJob
  alias Elzoo.DurableJob.{Run, TestRepo}
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Memory, Postgres}

  def url! do
    System.get_env("ELZOO_TEST_DATABASE_URL") ||
      raise "ELZOO_TEST_DATABASE_URL is required: PostgreSQL tests fail closed; provide a disposable local database (never skipped)"
  end

  def setup_database! do
    case TestRepo.start_link(url: url!(), pool_size: 20, log: false) do
      {:ok, repo} -> Process.unlink(repo)
      {:error, {:already_started, _}} -> :ok
    end

    try do
      TestRepo.query!("select 1", [], log: false)
    rescue
      _ ->
        raise "ELZOO_TEST_DATABASE_URL is unreachable: PostgreSQL tests fail closed (never skipped)"
    end

    prefix = "elzoo_dj_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    TestRepo.query!("create schema #{prefix}", [], log: false)
    :ok = Ecto.Migrator.up(TestRepo, 1, Elzoo.DurableJob.TestMigration, prefix: prefix, log: false)
    prefix
  end

  def drop!(prefix), do: TestRepo.query!("drop schema if exists #{prefix} cascade", [], log: false)

  def store(:memory, _prefix) do
    {:ok, pid} = Memory.start_link(fold: Run.store_fold(), limits: Run.limits())
    Memory.store(pid)
  end

  def store(:postgres, prefix),
    do: Postgres.store(TestRepo, prefix: prefix, fold: Run.store_fold(), limits: Run.limits())

  @doc "Start Oban and the Assembly for a fresh queue; the relay is manual."
  def flow(prefix, backend, opts \\ []) do
    queue = "dj" <> Integer.to_string(System.unique_integer([:positive]))
    store = Keyword.get_lazy(opts, :store, fn -> store(backend, prefix) end)
    oban = String.to_atom("Elzoo.DurableJob.TestOban." <> queue)
    start_oban(oban, prefix, queue, Keyword.get(opts, :oban, []))
    start_job(queue, store, oban, opts)
    %{queue: queue, store: store, oban: oban, prefix: prefix}
  end

  def start_oban(oban, prefix, queue, extra) do
    base = [
      name: oban,
      repo: TestRepo,
      prefix: prefix,
      queues: [{String.to_atom(queue), 5}],
      stager: [interval: 50],
      notifier: Oban.Notifiers.PG,
      log: false
    ]

    start_supervised!({Oban, Keyword.merge(base, extra)}, id: oban)
  end

  def start_job(queue, store, oban, opts) do
    job_opts =
      [queue: queue, store: store, repo: TestRepo, oban: oban, relay_interval_ms: :manual]
      |> Keyword.merge(
        Keyword.take(opts, [
          :handler,
          :now_ms,
          :test_hook,
          :relay_limit,
          :snooze_s,
          :writer_timeout_ms
        ])
      )

    start_supervised!({DurableJob, job_opts}, id: {DurableJob, queue})
  end

  def relay!(queue), do: Elzoo.Jobs.Relay.run_once(DurableJob.relay_process(queue))

  def records(store, stream) do
    {:ok, rows, _} = Log.read(store, stream, 1, 1_000)
    Enum.map(rows, &{&1.kind, Jason.decode!(&1.payload)})
  end

  def kinds(store, stream), do: Enum.map(records(store, stream), &elem(&1, 0))

  def oban_state(f, key) do
    case Elzoo.Jobs.state(f.oban, f.queue, key) do
      {:ok, {_, state}} -> state
      {:ok, :absent} -> :absent
    end
  end

  def poll(fun, tries \\ 800) do
    cond do
      fun.() -> :ok
      tries == 0 -> raise "poll timeout"
      true -> Process.sleep(25) && poll(fun, tries - 1)
    end
  end

  def phase(f, key) do
    case DurableJob.status(f.queue, key) do
      {:ok, %{phase: phase}} -> phase
      other -> other
    end
  end

  @doc "Hold FOR UPDATE on a stream's head row for `ms` in another process; returns once locked."
  def hold_head_lock(prefix, stream, ms) do
    parent = self()

    task =
      Task.async(fn ->
        TestRepo.transaction(fn ->
          TestRepo.query!(
            "select 1 from #{prefix}.elzoo_log_heads where stream = $1 for update",
            [stream],
            log: false
          )

          send(parent, :head_locked)
          Process.sleep(ms)
        end)
      end)

    receive do
      :head_locked -> task
    after
      5_000 -> raise "head lock not taken"
    end
  end

  def far, do: System.os_time(:millisecond) + 3_600_000
  def fast, do: [max_attempts: 3, base_backoff_ms: 0, max_backoff_ms: 0]

  @doc "Handler that reports each call and blocks until released with a result."
  def blocking_handler(parent) do
    fn input ->
      send(parent, {:entered, self(), input})

      receive do
        {:release, result} -> result
      end
    end
  end
end
