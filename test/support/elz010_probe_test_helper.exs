# SPDX-License-Identifier: Apache-2.0
# ELZ-010 pre-implementation provider probes (exploration evidence for the
# Contract proposal in docs/work/ELZ-010.md). Not a Piece and not shipped.
defmodule Elzoo.Elz010Probe.Repo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.Elz010Probe.Migration do
  use Ecto.Migration
  @prefix "elz010_probe"

  def up do
    Oban.Migration.up(prefix: @prefix)

    create table(:probe_effects, prefix: @prefix) do
      add(:job_id, :bigint)
      add(:attempt, :integer)
      add(:executor, :text)
      add(:tag, :text)
    end

    create table(:probe_domain, primary_key: false, prefix: @prefix) do
      add(:k, :text, primary_key: true)
    end
  end
end

defmodule Elzoo.Elz010Probe do
  @moduledoc false
  import Ecto.Query
  alias Elzoo.Elz010Probe.Repo
  @prefix "elz010_probe"

  def prefix, do: @prefix

  def url! do
    System.get_env("ELZOO_TEST_DATABASE_URL") ||
      raise "ELZOO_TEST_DATABASE_URL is required: PostgreSQL tests fail closed; provide a disposable local database (never skipped)"
  end

  def record(job, executor, tag \\ "perform") do
    Repo.query!(
      "insert into #{@prefix}.probe_effects (job_id, attempt, executor, tag) values ($1, $2, $3, $4)",
      [job.id, job.attempt, executor, tag],
      log: false
    )
  end

  def effects(job_id) do
    Repo.all(
      from(e in "probe_effects",
        prefix: ^@prefix,
        where: e.job_id == ^job_id,
        order_by: e.id,
        select: {e.attempt, e.executor, e.tag}
      ),
      log: false
    )
  end

  def job(id) do
    Repo.one!(
      from(j in "oban_jobs",
        prefix: ^@prefix,
        where: j.id == ^id,
        select: %{state: j.state, attempt: j.attempt, attempted_at: j.attempted_at}
      ),
      log: false
    )
  end

  def count(table, where \\ "true") do
    [[n]] =
      Repo.query!("select count(*) from #{@prefix}.#{table} where #{where}", [], log: false).rows

    n
  end

  def wait(key) do
    :global.register_name({:elz010, key}, self())

    receive do
      {:release, result} -> result
    end
  end

  def release(key, result \\ :ok) do
    send(poll(fn -> :global.whereis_name({:elz010, key}) end), {:release, result})
  end

  def poll(fun, tries \\ 600) do
    case fun.() do
      v when v in [nil, false, :undefined] ->
        if tries == 0, do: raise("poll timeout")
        Process.sleep(25)
        poll(fun, tries - 1)

      v ->
        v
    end
  end
end

defmodule Elzoo.Elz010Probe.Flaky do
  use Oban.Worker, queue: :probe, max_attempts: 3
  @impl true
  def perform(%Oban.Job{args: %{"fail_until" => n}} = job) do
    Elzoo.Elz010Probe.record(job, "flaky")
    if job.attempt <= n, do: {:error, "transient #{job.attempt}"}, else: :ok
  end

  @impl true
  def backoff(_job), do: 1
end

defmodule Elzoo.Elz010Probe.Blocking do
  use Oban.Worker, queue: :probe, max_attempts: 5
  @impl true
  def perform(%Oban.Job{} = job) do
    Elzoo.Elz010Probe.record(job, "attempt-#{job.attempt}", "start")
    result = Elzoo.Elz010Probe.wait({job.id, job.attempt})
    Elzoo.Elz010Probe.record(job, "attempt-#{job.attempt}", "finish")
    result
  end

  @impl true
  def backoff(_job), do: 0
end

defmodule Elzoo.Elz010Probe.Record do
  use Oban.Worker, queue: :probe, max_attempts: 1
  @impl true
  def perform(%Oban.Job{} = job) do
    Elzoo.Elz010Probe.record(job, inspect(job.attempted_by))
    :ok
  end
end

defmodule Elzoo.Elz010Probe.Unique do
  use Oban.Worker, queue: :probe, unique: [keys: [:job_key], period: :infinity, states: :all]
  @impl true
  def perform(_job), do: :ok
end

defmodule Elzoo.Elz010Probe.SnoozeOnce do
  use Oban.Worker, queue: :probe, max_attempts: 1
  @impl true
  def perform(%Oban.Job{} = job) do
    Elzoo.Elz010Probe.record(job, "snooze", "run")

    if Elzoo.Elz010Probe.count("probe_effects", "job_id = #{job.id}") == 1,
      do: {:snooze, 1},
      else: :ok
  end
end

defmodule Elzoo.Elz010Probe.Victim do
  use Oban.Worker, queue: :probe, max_attempts: 3
  @impl true
  def perform(%Oban.Job{} = job) do
    Elzoo.Elz010Probe.record(job, "os-pid-" <> System.pid(), "start")
    if job.attempt == 1, do: Process.sleep(:infinity)
    :ok
  end
end
