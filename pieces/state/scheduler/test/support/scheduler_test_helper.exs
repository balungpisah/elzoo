# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Scheduler.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.Scheduler.TestMigration do
  use Ecto.Migration

  def up do
    Elzoo.DurableLog.Postgres.Migration.up()
    Oban.Migration.up(prefix: prefix())
  end

  def down, do: Elzoo.DurableLog.Postgres.Migration.down()
end

defmodule Elzoo.Scheduler.TestHelper do
  @moduledoc """
  Shared fixtures for `state/scheduler` tests: the consumer fold with the
  scheduler kinds merged, the volatile Memory store, a manual clock, the
  disposable-PostgreSQL schema/Oban instance, and forged schedules.
  """
  alias Elzoo.DurableLog.Memory
  alias Elzoo.Scheduler
  alias Elzoo.Scheduler.TestRepo

  @epoch 1_735_689_600_000

  def epoch, do: @epoch

  def fold,
    do: %{
      initial: 0,
      kinds: Map.merge(%{"added" => :state_bearing}, Scheduler.kinds()),
      versions: [1],
      destinations: ["sink"],
      reduce: fn n, _, _, _ -> n + 1 end
    }

  def limits, do: %{max_record_bytes: 4_096, max_batch_size: 64, max_checkpoint_bytes: 10_000}

  def clock_fun(agent), do: fn -> Agent.get(agent, & &1) end

  def clock!(now \\ @epoch) do
    {:ok, pid} = Agent.start_link(fn -> now end)
    pid
  end

  def set_clock!(agent, now), do: Agent.update(agent, fn _ -> now end)

  def memory(opts \\ []) do
    {:ok, pid} =
      Memory.start_link(
        fold: fold(),
        limits: Keyword.get(opts, :limits, limits()),
        append_visibility: :atomic
      )

    store = Memory.store(pid)
    clock = Keyword.get_lazy(opts, :clock, &clock!/0)

    %{store: store, memory: pid, clock: clock, scheduler: scheduler(store, clock, opts)}
  end

  def scheduler(store, clock, opts \\ []) do
    {:ok, scheduler} =
      Scheduler.new(
        store: store,
        clock: clock_fun(clock),
        oban: Keyword.get(opts, :oban, :no_oban),
        timezone_database: Keyword.get(opts, :timezone_database, Calendar.UTCOnlyTimeZoneDatabase),
        max_slots_per_tick: Keyword.get(opts, :max_slots_per_tick, 8),
        max_availability_gap_ms: Keyword.get(opts, :max_availability_gap_ms, 60_000),
        occurrence_ttl_ms: Keyword.get(opts, :occurrence_ttl_ms, 3_600_000),
        max_unsettled_per_schedule: Keyword.get(opts, :max_unsettled_per_schedule, 16)
      )

    scheduler
  end

  def schedule(id, overrides \\ []) do
    %{
      schedule_id: id,
      generation: Keyword.get(overrides, :generation, 1),
      spec: Keyword.get(overrides, :spec, {:cron, "* * * * *"}),
      timezone: Keyword.get(overrides, :timezone, "Etc/UTC"),
      overlap_policy: Keyword.get(overrides, :overlap_policy, {:queue, 4}),
      dispatch: Keyword.get(overrides, :dispatch, {"sched", 3, %{"base_ms" => 100}}),
      occurrence_ttl_ms: Keyword.get(overrides, :occurrence_ttl_ms, 3_600_000)
    }
  end

  def create!(scheduler, id, overrides \\ []) do
    {:ok, _} = Scheduler.put_schedule(scheduler, schedule(id, overrides))
    id
  end

  def rows(store, stream) do
    {:ok, head} = Elzoo.DurableLog.Store.read(store, :head, [stream])
    {:ok, rows, _} = Elzoo.DurableLog.read(store, stream, head.low_water + 1, 10_000)
    rows
  end

  def kinds_in(store, stream) do
    Enum.map(rows(store, stream), & &1.kind)
  end

  def payloads(store, stream, kind) do
    store
    |> rows(stream)
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(&Jason.decode!(&1.payload))
  end

  # ── PostgreSQL + Oban ──────────────────────────────────────────────

  def url! do
    System.get_env("ELZOO_TEST_DATABASE_URL") ||
      raise "ELZOO_TEST_DATABASE_URL is required: PostgreSQL tests fail closed (never skipped)"
  end

  # Called in `setup_all`: the module that starts the Repo stops it when the module ends, so
  # an idle pool does not outlive its module. `setup_database!/0` runs once for each test.
  def start_repo! do
    case TestRepo.start_link(url: url!(), pool_size: 10, log: false) do
      {:ok, repo} ->
        Process.unlink(repo)

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
  end

  def setup_database! do
    start_repo!()

    TestRepo.query!("select 1", [], log: false)

    prefix = "elzoo_sched_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    TestRepo.query!("create schema #{prefix}", [], log: false)
    :ok = Ecto.Migrator.up(TestRepo, 1, Elzoo.Scheduler.TestMigration, prefix: prefix, log: false)
    prefix
  end

  def drop!(prefix),
    do: TestRepo.query!("drop schema if exists #{prefix} cascade", [], log: false)

  def pg_store(repo, prefix),
    do: Elzoo.DurableLog.Postgres.store(repo, prefix: prefix, fold: fold(), limits: limits())

  def oban_opts(name, prefix, queues),
    do: [
      name: name,
      repo: TestRepo,
      prefix: prefix,
      queues: queues,
      stager: [interval: 50],
      notifier: Oban.Notifiers.PG,
      log: false,
      testing: :manual
    ]

  def pg_scheduler(store, oban, opts \\ []) do
    clock = Keyword.get_lazy(opts, :clock, &clock!/0)

    {:ok, scheduler} =
      Scheduler.new(
        store: store,
        clock: clock_fun(clock),
        oban: oban,
        timezone_database: Keyword.get(opts, :timezone_database, Calendar.UTCOnlyTimeZoneDatabase),
        max_slots_per_tick: Keyword.get(opts, :max_slots_per_tick, 8),
        max_availability_gap_ms: Keyword.get(opts, :max_availability_gap_ms, 60_000),
        occurrence_ttl_ms: Keyword.get(opts, :occurrence_ttl_ms, 3_600_000)
      )

    {scheduler, clock}
  end
end

# A scoped Store facade for deterministic interleavings. The competing write
# uses the real underlying Store; the losing append sees its actual CAS result.
defmodule Elzoo.Scheduler.HookedStore do
  @moduledoc false

  def wrap({module, opts} = inner) do
    {__MODULE__, Map.new(opts) |> Map.put(:inner, inner) |> Map.put(:provider, module)}
  end

  def before_append(fun), do: Process.put({__MODULE__, :before_append}, fun)

  def head(store, stream), do: provider(store).head(inner(store), stream)
  def read(store, stream, from, limit), do: provider(store).read(inner(store), stream, from, limit)

  def append(store, stream, expected, records, items) do
    case Process.get({__MODULE__, :before_append}) do
      nil -> :ok
      hook -> hook.(stream, records)
    end

    provider(store).append(inner(store), stream, expected, records, items)
  end

  def clear, do: Process.delete({__MODULE__, :before_append})
  defp inner({_, opts}), do: opts.inner
  defp provider({_, opts}), do: opts.provider
end
