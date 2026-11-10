# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/scheduler_test_helper.exs", __DIR__)

defmodule Elzoo.SchedulerPostgresTest do
  @moduledoc """
  `state/scheduler` over the ready PostgreSQL Store and a real Oban boundary:
  dispatch idempotency and derived settlement. Requires
  ELZOO_TEST_DATABASE_URL (a disposable database; fail closed, never skipped).
  """
  use ExUnit.Case, async: false
  alias Elzoo.Scheduler
  alias Elzoo.Scheduler.TestHelper
  alias Elzoo.Scheduler.TestRepo

  @minute 60_000

  setup_all do
    {:ok, _} = Application.ensure_all_started(:oban)
    :ok
  end

  setup do
    prefix = TestHelper.setup_database!()
    on_exit(fn -> TestHelper.drop!(prefix) end)
    {:ok, prefix: prefix, store: TestHelper.pg_store(TestRepo, prefix)}
  end

  defp minute(n), do: TestHelper.epoch() + n * @minute

  test "P1: admitted occurrences enqueue one Oban job each (dedup on re-tick)", ctx do
    {:ok, oban} =
      Oban.start_link(TestHelper.oban_opts(:sched_oban_p1, ctx.prefix, sched: 2))

    {s, _clock} = TestHelper.pg_scheduler(ctx.store, :sched_oban_p1)
    TestHelper.create!(s, "cronjob", spec: {:cron, "* * * * *"})

    results = Scheduler.tick(s, now: minute(2))
    assert %{admitted: 2, dispatched: 2, contended: false} = results["cronjob"]

    jobs =
      TestRepo.query!("select id, state from #{ctx.prefix}.oban_jobs order by id", [], log: false).rows

    assert length(jobs) == 2

    # re-tick at the same instant: nothing re-admitted or re-enqueued
    assert %{"cronjob" => %{admitted: 0, dispatched: 0}} = Scheduler.tick(s, now: minute(2))

    assert TestRepo.query!("select count(*) from #{ctx.prefix}.oban_jobs", [], log: false).rows == [
             [2]
           ]

    Supervisor.stop(oban)
  end

  test "P2: derived settlement maps terminal Oban states; unreadable stays unsettled", ctx do
    {:ok, oban} = Oban.start_link(TestHelper.oban_opts(:sched_oban_p2, ctx.prefix, sched: 2))
    {s, _clock} = TestHelper.pg_scheduler(ctx.store, :sched_oban_p2)
    TestHelper.create!(s, "settle", spec: {:cron, "* * * * *"})

    assert %{dispatched: 2} = Scheduler.tick(s, now: minute(2))["settle"]

    [[j1], [j2]] =
      TestRepo.query!("select id from #{ctx.prefix}.oban_jobs order by id", [], log: false).rows

    TestRepo.query!("update #{ctx.prefix}.oban_jobs set state='completed' where id=$1", [j1],
      log: false
    )

    TestRepo.query!("update #{ctx.prefix}.oban_jobs set state='discarded' where id=$1", [j2],
      log: false
    )

    assert %{settled: 2} = Scheduler.tick(s, now: minute(3))["settle"]
    assert {:ok, %{unsettled: 1}} = Scheduler.status(s, "settle")

    settled = TestHelper.payloads(ctx.store, "scheduler/settle", "occurrence_settled")
    assert Enum.any?(settled, &(&1["kind"] == "acknowledged" and &1["via"] == "completed"))
    assert Enum.any?(settled, &(&1["kind"] == "released" and &1["via"] == "discarded"))

    Supervisor.stop(oban)
  end

  test "P3: reap expires old occurrences and cancels their jobs", ctx do
    {:ok, oban} = Oban.start_link(TestHelper.oban_opts(:sched_oban_p3, ctx.prefix, sched: 2))
    {s, clock} = TestHelper.pg_scheduler(ctx.store, :sched_oban_p3, occurrence_ttl_ms: 60_000)
    TestHelper.create!(s, "exp", spec: {:cron, "* * * * *"}, occurrence_ttl_ms: 60_000)

    assert %{dispatched: 1} = Scheduler.tick(s, now: minute(1))["exp"]

    TestHelper.set_clock!(clock, minute(3))
    assert %{expired: 1} = Scheduler.reap(s, now: minute(3))["exp"]

    expired = TestHelper.payloads(ctx.store, "scheduler/exp", "occurrence_expired")
    assert length(expired) == 1
    assert {:ok, %{unsettled: 0}} = Scheduler.status(s, "exp")

    [[state]] = TestRepo.query!("select state from #{ctx.prefix}.oban_jobs", [], log: false).rows
    assert state == "cancelled"

    Supervisor.stop(oban)
  end

  test "P4: two schedulers CAS-contend; the loser changes nothing", ctx do
    {s1, _} = TestHelper.pg_scheduler(ctx.store, :no_oban)
    {s2, _} = TestHelper.pg_scheduler(ctx.store, :no_oban)
    TestHelper.create!(s1, "contended", spec: {:cron, "* * * * *"})

    assert %{admitted: 1} = Scheduler.tick(s1, now: minute(1))["contended"]
    assert %{admitted: 0} = Scheduler.tick(s2, now: minute(1))["contended"]

    records = TestHelper.payloads(ctx.store, "scheduler/contended", "tick_recorded")
    assert length(records) == 3
  end

  test "P5: a completed job frees its overlap slot in the same tick", ctx do
    {:ok, oban} = Oban.start_link(TestHelper.oban_opts(:sched_oban_p5, ctx.prefix, sched: 2))
    {s, _clock} = TestHelper.pg_scheduler(ctx.store, :sched_oban_p5)
    TestHelper.create!(s, "skipfree", spec: {:cron, "* * * * *"}, overlap_policy: :skip)

    assert %{"skipfree" => %{admitted: 1, dispatched: 1}} = Scheduler.tick(s, now: minute(1))

    [[j1]] = TestRepo.query!("select id from #{ctx.prefix}.oban_jobs", [], log: false).rows

    TestRepo.query!("update #{ctx.prefix}.oban_jobs set state='completed' where id=$1", [j1],
      log: false
    )

    # the pre-admission reconcile settles the completed job first, so :skip
    # sees an empty unsettled set and admits the next due slot
    assert %{"skipfree" => %{admitted: 1, settled: 1, dispatched: 1}} =
             Scheduler.tick(s, now: minute(2))

    assert {:ok, %{unsettled: 1}} = Scheduler.status(s, "skipfree")
    Supervisor.stop(oban)
  end

  test "P6: reap settles a completed job instead of expiring it", ctx do
    {:ok, oban} = Oban.start_link(TestHelper.oban_opts(:sched_oban_p6, ctx.prefix, sched: 2))
    {s, clock} = TestHelper.pg_scheduler(ctx.store, :sched_oban_p6, occurrence_ttl_ms: 60_000)

    TestHelper.create!(s, "ttlwin", spec: {:cron, "* * * * *"}, occurrence_ttl_ms: 60_000)
    assert %{"ttlwin" => %{dispatched: 1}} = Scheduler.tick(s, now: minute(1))

    [[j1]] = TestRepo.query!("select id from #{ctx.prefix}.oban_jobs", [], log: false).rows

    TestRepo.query!("update #{ctx.prefix}.oban_jobs set state='completed' where id=$1", [j1],
      log: false
    )

    TestHelper.set_clock!(clock, minute(3))

    # the job completed before its first post-TTL reap: terminal Oban state
    # wins over the expiry split — acknowledged, never expired, never cancelled
    assert %{"ttlwin" => %{expired: 0, settled: 1}} = Scheduler.reap(s, now: minute(3))

    assert TestHelper.payloads(ctx.store, "scheduler/ttlwin", "occurrence_expired") == []

    assert Enum.any?(
             TestHelper.payloads(ctx.store, "scheduler/ttlwin", "occurrence_settled"),
             &(&1["kind"] == "acknowledged" and &1["via"] == "completed")
           )

    [[state]] = TestRepo.query!("select state from #{ctx.prefix}.oban_jobs", [], log: false).rows
    assert state == "completed"
    Supervisor.stop(oban)
  end
end
