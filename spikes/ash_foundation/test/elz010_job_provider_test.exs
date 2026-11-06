# SPDX-License-Identifier: Apache-2.0
# ELZ-010 job-provider comparison: AshOban 0.10.3 triggers (A1–A4) and Reactor
# 1.0.7 inside an Oban 2.24.2 worker (O9). Exploration evidence recorded in
# docs/work/ELZ-010.md; not a shipped adapter.
defmodule ElzooAshSpike.Elz010JobProviderTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias ElzooAshSpike.{JobRepo, Ticket}
  @schema "elz010_ash_jobs"

  defmodule Migration do
    use Ecto.Migration
    @schema "elz010_ash_jobs"

    def up do
      Oban.Migration.up(prefix: @schema)

      create table(:probe_tickets, primary_key: false, prefix: @schema) do
        add(:id, :uuid, primary_key: true)
        add(:state, :text, null: false)
        add(:fail_mode, :text)
      end

      create table(:probe_effects, prefix: @schema) do
        add(:job_id, :bigint)
        add(:attempt, :integer)
      end
    end
  end

  setup_all do
    url =
      System.get_env("ELZOO_TEST_DATABASE_URL") ||
        raise "ELZOO_TEST_DATABASE_URL is required: PostgreSQL tests fail closed; provide a disposable local database (never skipped)"

    {:ok, repo} = JobRepo.start_link(url: url, pool_size: 10, log: false)
    Process.unlink(repo)
    JobRepo.query!("drop schema if exists #{@schema} cascade", [], log: false)
    JobRepo.query!("create schema #{@schema}", [], log: false)
    :ok = Ecto.Migrator.up(JobRepo, 1, Migration, prefix: @schema, log: false)
    :ok
  end

  setup do
    JobRepo.query!(
      "truncate #{@schema}.oban_jobs, #{@schema}.probe_tickets, #{@schema}.probe_effects restart identity",
      [],
      log: false
    )

    conf =
      AshOban.config([ElzooAshSpike.JobDomain],
        repo: JobRepo,
        prefix: @schema,
        cron: [crontab: []],
        notifier: Oban.Notifiers.PG,
        queues: [ticket_process: 5, reactor_probe: 2],
        stager: [interval: 50],
        log: false
      )

    start_supervised!({Oban, conf})
    :ok
  end

  defp ticket(state, mode \\ :never),
    do:
      Ticket
      |> Ash.Changeset.for_create(:create, %{state: state, fail_mode: mode})
      |> Ash.create!()

  defp jobs(id) do
    JobRepo.all(
      from(j in "oban_jobs",
        prefix: ^@schema,
        where: fragment("?->>'primary_key' like ?", j.args, ^"%#{id}%"),
        order_by: j.id,
        select: {j.id, j.state, j.attempt, j.max_attempts}
      ),
      log: false
    )
  end

  defp poll(fun, tries \\ 600) do
    cond do
      fun.() -> :ok
      tries == 0 -> raise "poll timeout"
      true -> Process.sleep(25) && poll(fun, tries - 1)
    end
  end

  defp settled?(rows, n),
    do: length(rows) == n and Enum.all?(rows, &(elem(&1, 1) in ~w(completed discarded cancelled)))

  test "A1 run_trigger runs the action once; a duplicate run_trigger while incomplete is deduplicated" do
    record = ticket(:pending)
    j1 = AshOban.run_trigger(record, :process)
    j2 = AshOban.run_trigger(record, :process)
    poll(fn -> settled?(jobs(record.id), 1) end)
    state = Ash.get!(Ticket, record.id).state

    IO.puts(
      "ELZ-010 A1: j1=#{inspect({j1.id, j1.conflict?})} j2=#{inspect({j2.id, j2.conflict?})} jobs=#{inspect(jobs(record.id))} state=#{state}"
    )

    assert j2.conflict? and j2.id == j1.id and state == :done
  end

  test "A2 without on_error, exhaustion leaves the record matching; a re-run starts a fresh budget" do
    record = ticket(:pending, :always)
    AshOban.run_trigger(record, :process)
    poll(fn -> settled?(jobs(record.id), 1) end)
    AshOban.run_trigger(record, :process)
    poll(fn -> settled?(jobs(record.id), 2) end)
    state = Ash.get!(Ticket, record.id).state
    IO.puts("ELZ-010 A2: jobs=#{inspect(jobs(record.id))} state=#{state}")
    assert [{_, "discarded", 2, 2}, {_, "discarded", 2, 2}] = jobs(record.id)
    assert state == :pending
  end

  test "A3 with on_error, exhaustion moves the record out of the where; a re-run does nothing" do
    record = ticket(:pending_guarded, :always)
    AshOban.run_trigger(record, :process_guarded)
    poll(fn -> settled?(jobs(record.id), 1) end)
    AshOban.run_trigger(record, :process_guarded)
    poll(fn -> settled?(jobs(record.id), 2) end)
    state = Ash.get!(Ticket, record.id).state
    IO.puts("ELZ-010 A3: jobs=#{inspect(jobs(record.id))} state=#{state}")
    assert state == :failed
    assert [{_, "completed", 2, 2}, {_, "cancelled", 1, 2}] = jobs(record.id)
  end

  test "A4 a record cancelled after enqueue is not processed (where re-checked)" do
    Oban.pause_queue(queue: :ticket_process)
    record = ticket(:pending)
    AshOban.run_trigger(record, :process)
    Ash.update!(record, %{}, action: :cancel)
    Oban.resume_queue(queue: :ticket_process)
    poll(fn -> settled?(jobs(record.id), 1) end)
    state = Ash.get!(Ticket, record.id).state
    IO.puts("ELZ-010 A4: jobs=#{inspect(jobs(record.id))} state=#{state}")
    assert state == :cancelled
    assert [{_, "cancelled", 1, 2}] = jobs(record.id)
  end

  test "O9 Reactor inside an Oban worker re-executes a completed effect step on job retry" do
    {:ok, job} = Oban.insert(ElzooAshSpike.ReactorJob.new(%{}))

    poll(fn ->
      JobRepo.one(
        from(j in "oban_jobs", prefix: ^@schema, where: j.id == ^job.id, select: j.state)
      ) ==
        "completed"
    end)

    effects =
      JobRepo.all(
        from(e in "probe_effects",
          prefix: ^@schema,
          where: e.job_id == ^job.id,
          order_by: e.id,
          select: e.attempt
        )
      )

    IO.puts("ELZ-010 O9: effect_step_attempts=#{inspect(effects)}")
    assert effects == [1, 2]
  end
end
