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

  test "P4: concurrent PostgreSQL ticks race on the same revision", ctx do
    alias Elzoo.Scheduler.HookedStore
    {:ok, oban} = Oban.start_link(TestHelper.oban_opts(:sched_oban_p4, ctx.prefix, sched: 2))
    {base, _} = TestHelper.pg_scheduler(ctx.store, :sched_oban_p4)
    TestHelper.create!(base, "contended")
    scheduler = %{base | store: HookedStore.wrap(ctx.store)}
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          HookedStore.before_append(fn stream, rows ->
            if stream == "scheduler/contended" and Enum.any?(rows, &(&1.kind == "tick_recorded")) do
              HookedStore.clear()
              send(parent, {:ready, self()})

              receive do
                :append -> :ok
              after
                5_000 -> raise "CAS barrier timeout"
              end
            end
          end)

          Scheduler.tick(scheduler, now: minute(1))["contended"]
        end)
      end

    assert_receive {:ready, first}, 5_000
    assert_receive {:ready, second}, 5_000
    send(first, :append)
    send(second, :append)
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, & &1.contended) == 1
    assert Enum.sum(Enum.map(results, & &1.admitted)) == 1
    assert length(TestHelper.payloads(ctx.store, "scheduler/contended", "slot_decided")) == 1

    assert TestRepo.query!("select count(*) from #{ctx.prefix}.oban_jobs", [], log: false).rows == [
             [1]
           ]

    Supervisor.stop(oban)
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

  test "P7: restart repairs enqueue committed before its dispatch record", ctx do
    alias Elzoo.Scheduler.HookedStore
    {:ok, oban} = Oban.start_link(TestHelper.oban_opts(:sched_oban_p7, ctx.prefix, sched: 2))
    {base, _} = TestHelper.pg_scheduler(ctx.store, :sched_oban_p7)
    s = %{base | store: HookedStore.wrap(ctx.store)}
    TestHelper.create!(s, "restart-job", spec: {:at, minute(1)})

    HookedStore.before_append(fn _, rows ->
      if hd(rows).kind == "occurrence_dispatch" do
        HookedStore.clear()
        # Move the real head, so the stale dispatch append loses CAS after
        # Oban has committed the job. No fabricated conflict response.
        assert {:ok, _} = Scheduler.pause(base, "restart-job")
      end
    end)

    assert %{"restart-job" => %{contended: true}} = Scheduler.tick(s, now: minute(1))
    assert {:ok, %{dispatch_pending: 1}} = Scheduler.status(base, "restart-job")
    assert {:ok, _} = Scheduler.resume(base, "restart-job")
    {restarted, _} = TestHelper.pg_scheduler(ctx.store, :sched_oban_p7)

    assert %{"restart-job" => %{admitted: 0, dispatched: 1}} =
             Scheduler.tick(restarted, now: minute(1))

    assert TestRepo.query!("select count(*) from #{ctx.prefix}.oban_jobs", [], log: false).rows == [
             [1]
           ]

    assert {:ok, %{dispatch_pending: 0}} = Scheduler.status(restarted, "restart-job")
    Supervisor.stop(oban)
  end

  test "P8: expired dispatch-pending work is never enqueued on recovery", ctx do
    {s, _} = TestHelper.pg_scheduler(ctx.store, :sched_oban_p8)
    TestHelper.create!(s, "expired-pending", spec: {:at, minute(1)}, occurrence_ttl_ms: 1)
    assert %{"expired-pending" => %{dispatch_errors: 1}} = Scheduler.tick(s, now: minute(1))
    {:ok, oban} = Oban.start_link(TestHelper.oban_opts(:sched_oban_p8, ctx.prefix, sched: 2))
    assert %{"expired-pending" => %{expired: 1, dispatched: 0}} = Scheduler.tick(s, now: minute(2))

    assert TestRepo.query!("select count(*) from #{ctx.prefix}.oban_jobs", [], log: false).rows == [
             [0]
           ]

    assert {:ok, %{unsettled: 0}} = Scheduler.status(s, "expired-pending")
    Supervisor.stop(oban)
  end

  test "P9: delete and reap winning during enqueue leave cancelled jobs", ctx do
    {:ok, oban} = Oban.start_link(TestHelper.oban_opts(:sched_oban_p9, ctx.prefix, sched: 2))
    {s, _} = TestHelper.pg_scheduler(ctx.store, :sched_oban_p9)
    parent = self()

    for {id, action} <- [{"cancel-delete", :delete}, {"cancel-reap", :reap}] do
      TestHelper.create!(s, id, spec: {:at, minute(1)}, occurrence_ttl_ms: 1)
      handler = {__MODULE__, id}

      :telemetry.attach(
        handler,
        [:oban, :engine, :insert_job, :stop],
        fn _, _, meta, _ ->
          if meta.job.args["job_key"] == "1:#{minute(1)}:#{id}" do
            :telemetry.detach(handler)

            result =
              case action do
                :delete -> Scheduler.delete(s, id)
                :reap -> Scheduler.reap(s, now: minute(2))
              end

            send(parent, {:raced, action, result})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert %{dispatched: 0} = Scheduler.tick(s, now: minute(1))[id]
      assert_receive {:raced, ^action, result}

      case action do
        :delete -> assert {:ok, %{control: :deleted}} = result
        :reap -> assert %{^id => %{expired: 1}} = result
      end

      assert {:ok, %{unsettled: 0}} = Scheduler.status(s, id)
    end

    assert TestRepo.query!("select distinct state from #{ctx.prefix}.oban_jobs", [], log: false).rows ==
             [["cancelled"]]

    Supervisor.stop(oban)
  end

  test "P10: cancelled and unreadable jobs settle once or remain unknown", ctx do
    {:ok, oban} = Oban.start_link(TestHelper.oban_opts(:sched_oban_p10, ctx.prefix, sched: 2))
    {s, _} = TestHelper.pg_scheduler(ctx.store, :sched_oban_p10)
    TestHelper.create!(s, "unknown", overlap_policy: {:queue, 4})
    assert %{dispatched: 2} = Scheduler.tick(s, now: minute(2))["unknown"]

    [[j1], [j2]] =
      TestRepo.query!("select id from #{ctx.prefix}.oban_jobs order by id", [], log: false).rows

    TestRepo.query!("update #{ctx.prefix}.oban_jobs set state='cancelled' where id=$1", [j1],
      log: false
    )

    TestRepo.query!("delete from #{ctx.prefix}.oban_jobs where id=$1", [j2], log: false)
    parent = self()
    handler = {__MODULE__, :unknown}

    :telemetry.attach(
      handler,
      [:elzoo, :scheduler, :settlement_unknown],
      fn event, m, meta, _ ->
        send(parent, {event, m, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert %{settled: 1, settlement_unknown: 1} = Scheduler.tick(s, now: minute(2))["unknown"]
    assert %{settled: 0, settlement_unknown: 1} = Scheduler.tick(s, now: minute(2))["unknown"]
    assert length(TestHelper.payloads(ctx.store, "scheduler/unknown", "occurrence_settled")) == 1
    assert {:ok, %{unsettled: 1}} = Scheduler.status(s, "unknown")

    assert_receive {[:elzoo, :scheduler, :settlement_unknown], %{count: 1},
                    %{schedule_id: "unknown"}}

    Supervisor.stop(oban)
  end

  test "P11: reap recovers expiry committed before cancellation", ctx do
    alias Elzoo.Scheduler.Record
    {:ok, oban} = Oban.start_link(TestHelper.oban_opts(:sched_oban_p11, ctx.prefix, sched: 2))
    {s, _} = TestHelper.pg_scheduler(ctx.store, :sched_oban_p11)
    TestHelper.create!(s, "cancel-recovery", spec: {:at, minute(1)})
    assert %{dispatched: 1} = Scheduler.tick(s, now: minute(1))["cancel-recovery"]
    [admitted] = TestHelper.payloads(ctx.store, "scheduler/cancel-recovery", "slot_decided")
    stream = "scheduler/cancel-recovery"
    {:ok, head} = Elzoo.DurableLog.Store.read(ctx.store, :head, [stream])

    {:ok, rows, _} =
      Record.records(
        stream,
        head.revision,
        [{"occurrence_expired", Record.expired_payload(admitted["id"], minute(2))}],
        TestHelper.fold(),
        TestHelper.limits()
      )

    {provider, _} = ctx.store
    assert {:committed, _} = provider.append(ctx.store, stream, head.revision, rows, [])

    # A restarted reaper must cancel the previously expired job even though
    # there are no new TTL decisions to make.
    {restarted, _} = TestHelper.pg_scheduler(ctx.store, :sched_oban_p11)
    assert %{expired: 0, settled: 0} = Scheduler.reap(restarted, now: minute(3))["cancel-recovery"]

    assert TestRepo.query!("select state from #{ctx.prefix}.oban_jobs", [], log: false).rows == [
             ["cancelled"]
           ]

    assert length(TestHelper.payloads(ctx.store, stream, "occurrence_expired")) == 1
    Supervisor.stop(oban)
  end

  test "P12: real Oban uniqueness lock leaves dispatch pending until retry", ctx do
    alias Elzoo.Jobs

    {:ok, oban} =
      Oban.start_link(
        TestHelper.oban_opts(:sched_oban_p12, ctx.prefix, [])
        |> Keyword.put(:testing, :disabled)
      )

    {s, _} = TestHelper.pg_scheduler(ctx.store, :sched_oban_p12)
    TestHelper.create!(s, "unique-lock", spec: {:at, minute(1)})
    key = "1:#{minute(1)}:unique-lock"
    parent = self()

    holder =
      Task.async(fn ->
        TestRepo.transaction(fn ->
          assert {:ok, _} = Jobs.enqueue(:sched_oban_p12, Jobs.changeset("sched", key, 3))
          send(parent, :held)

          receive do
            :rollback -> TestRepo.rollback(:probe)
          after
            5_000 -> TestRepo.rollback(:timeout)
          end
        end)
      end)

    assert_receive :held, 5_000
    assert %{dispatch_pending: 1, dispatched: 0} = Scheduler.tick(s, now: minute(1))["unique-lock"]
    assert {:ok, %{dispatch_pending: 1}} = Scheduler.status(s, "unique-lock")
    send(holder.pid, :rollback)
    assert {:error, :probe} = Task.await(holder)

    assert %{dispatch_pending: 0, dispatched: 1, admitted: 0} =
             Scheduler.tick(s, now: minute(1))["unique-lock"]

    assert {:ok, [{_, "available"}]} = Jobs.states(:sched_oban_p12, "sched", key)
    Supervisor.stop(oban)
  end
end
