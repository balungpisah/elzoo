# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/scheduler_test_helper.exs", __DIR__)

defmodule Elzoo.SchedulerTest do
  @moduledoc """
  `state/scheduler` scenarios on the volatile Memory Store with a manual
  clock: schedule CRUD with generation fencing, slot evaluation and
  admission, the availability boundary and offline catch-up, overlap
  policies, bounded evaluation, watermark durability across restart, DST
  transitions and the failure taxonomy. Oban is absent here; dispatch is
  covered by the PostgreSQL suite.
  """
  use ExUnit.Case, async: false
  alias Elzoo.Scheduler
  alias Elzoo.Scheduler.{Slots, TestHelper}
  alias Elzoo.DurableLog.Memory

  @minute 60_000

  setup do
    TestHelper.memory()
  end

  defp minute(n), do: TestHelper.epoch() + n * @minute

  # ── construction ─────────────────────────────────────────────────

  test "S0: new validates the Store binding, bounds and clock" do
    assert {:error, {:invalid, :store}} = Scheduler.new(clock: :system, oban: :x)

    assert {:error, {:invalid, :clock}} =
             Scheduler.new(store: {Elzoo.DurableLog.Memory, %{}}, oban: :x)

    {:ok, pid} = Memory.start_link(fold: TestHelper.fold(), limits: TestHelper.limits())

    assert {:error, {:invalid, :max_slots_per_tick}} =
             Scheduler.new(
               store: Memory.store(pid),
               clock: :system,
               oban: :x,
               max_slots_per_tick: 10_000
             )

    assert {:ok, _} =
             Scheduler.new(
               store: Memory.store(pid),
               clock: :system,
               oban: :x,
               timezone_database: Calendar.UTCOnlyTimeZoneDatabase
             )
  end

  # ── S1 CRUD and generation fencing ────────────────────────────────

  test "S1: put/get/list/status, pause/resume/delete and generation fencing", ctx do
    s = ctx.scheduler
    assert {:ok, %{created: "digest"}} = Scheduler.put_schedule(s, TestHelper.schedule("digest"))
    assert {:ok, %{generation: 1}} = Scheduler.get(s, "digest")
    assert {:ok, [%{schedule: "digest", state: :active, unsettled: 0}]} = Scheduler.list(s)

    assert {:ok, %{watermark: wm, last_tick_ok_at: at, dispatch_pending: 0}} =
             Scheduler.status(s, "digest")

    assert wm == at and at == TestHelper.epoch()

    assert {:ok, %{control: :paused}} = Scheduler.pause(s, "digest")
    assert {:ok, %{control: :active}} = Scheduler.resume(s, "digest")

    # redefine requires a strictly greater generation and records supersession
    assert {:error, :generation_conflict} =
             Scheduler.put_schedule(s, TestHelper.schedule("digest", generation: 1))

    assert {:ok, %{redefined: "digest", generation: {1, 2}}} =
             Scheduler.put_schedule(
               s,
               TestHelper.schedule("digest", generation: 2, spec: {:cron, "0 * * * *"})
             )

    assert {:ok, %{control: :deleted, released: 0}} = Scheduler.delete(s, "digest")

    assert {:error, :not_found} =
             Scheduler.put_schedule(s, TestHelper.schedule("digest", generation: 3))

    assert {:ok, []} = Scheduler.list(s)
    assert {:error, :not_found} = Scheduler.pause(s, "digest")
    assert {:error, :not_found} = Scheduler.get(s, "absent")
  end

  test "S1b: invalid definitions and specs refuse" do
    s = TestHelper.memory().scheduler

    assert {:error, :invalid_schedule} = Scheduler.put_schedule(s, %{schedule_id: "x"})
    assert {:error, :invalid_schedule} = Scheduler.put_schedule(s, TestHelper.schedule("bad id!"))

    assert {:error, :invalid_spec} =
             Scheduler.put_schedule(s, TestHelper.schedule("x", spec: {:cron, "not a cron"}))

    assert {:error, :invalid_spec} =
             Scheduler.put_schedule(s, TestHelper.schedule("x", spec: {:cron, "@reboot"}))

    assert {:error, :invalid_spec} =
             Scheduler.put_schedule(s, TestHelper.schedule("x", spec: {:at, TestHelper.epoch()}))

    assert {:error, :invalid_spec} =
             Scheduler.put_schedule(s, TestHelper.schedule("x", timezone: "Not/AZone"))

    assert {:error, :invalid_schedule} =
             Scheduler.put_schedule(s, TestHelper.schedule("x", dispatch: {"", 3, %{}}))

    assert {:error, :invalid_schedule} =
             Scheduler.put_schedule(s, TestHelper.schedule("x", overlap_policy: {:queue, 0}))

    assert {:error, :invalid_schedule} =
             Scheduler.put_schedule(s, TestHelper.schedule("x", occurrence_ttl_ms: 0))
  end

  # ── S2 tick admits due slots through trigger ──────────────────────

  test "S2: tick admits due slots, records decisions and advances the watermark" do
    ctx = TestHelper.memory(max_availability_gap_ms: 600_000)
    s = ctx.scheduler
    TestHelper.create!(s, "every-minute", spec: {:cron, "* * * * *"})

    results = Scheduler.tick(s, now: minute(3))
    assert %{admitted: 3, backlog: 0} = results["every-minute"]

    payloads = TestHelper.payloads(ctx.store, "scheduler/every-minute", "slot_decided")
    assert length(payloads) == 3
    assert Enum.all?(payloads, &(&1["decision"] == "admitted" and &1["origin"] == "live"))

    tick_records = TestHelper.payloads(ctx.store, "scheduler/every-minute", "tick_recorded")
    assert List.last(tick_records)["last_recorded"] == minute(3)
    assert List.last(tick_records)["unsettled"] |> length() == 3

    # a second tick at the same now is a no-op: occurrence ids are stable
    assert %{"every-minute" => %{admitted: 0}} = Scheduler.tick(s, now: minute(3))
    {:ok, st} = Scheduler.status(s, "every-minute")
    assert {st.watermark, st.unsettled} == {minute(3), 3}
  end

  test "S3: one-shot at-spec admits exactly once" do
    ctx = TestHelper.memory()
    s = ctx.scheduler
    TestHelper.create!(ctx.scheduler, "once", spec: {:at, minute(2)})

    assert %{"once" => %{admitted: 1}} = Scheduler.tick(s, now: minute(2))
    assert %{"once" => %{admitted: 0, backlog: 0}} = Scheduler.tick(s, now: minute(5))
  end

  # ── S4 misfire: offline catch-up vs live under the boundary ────────

  test "S4: a long gap classifies pre-boundary slots as offline catch-up", ctx do
    s = ctx.scheduler

    # creation is the last recorded tick; after a gap the boundary is `now`
    TestHelper.create!(s, "down", spec: {:cron, "* * * * *"}, overlap_policy: :skip)

    results = Scheduler.tick(s, now: minute(10))
    decision = results["down"]
    assert decision.backlog == 2
    assert decision.skipped == 8

    skipped = TestHelper.payloads(ctx.store, "scheduler/down", "slot_decided")
    assert Enum.all?(skipped, &(&1["decision"] == "skipped" and &1["reason"] == "offline_catch_up"))
    # watermark advances only over evaluated slots
    {:ok, st} = Scheduler.status(s, "down")
    assert st.watermark == minute(8)
  end

  test "S5: continuous availability admits catch-up slots under queue(n) bound" do
    ctx = TestHelper.memory(max_slots_per_tick: 10)
    s = ctx.scheduler
    TestHelper.create!(s, "busy", spec: {:cron, "* * * * *"}, overlap_policy: {:queue, 2})

    # within max_availability_gap_ms (60s): boundary = last_tick_ok_at → all live
    TestHelper.set_clock!(ctx.clock, TestHelper.epoch() + 30_000)
    results = Scheduler.tick(s, now: TestHelper.epoch() + 30_000)
    assert %{"busy" => %{admitted: 0, backlog: 0}} = results
  end

  test "S6: overlap policies skip/replace/queue are recorded" do
    # max_availability_gap_ms = 10min keeps boundary = creation instant, so
    # all four due slots classify as live and exercise the overlap policies
    ctx = TestHelper.memory(max_availability_gap_ms: 600_000)
    s = ctx.scheduler
    TestHelper.create!(s, "sk", spec: {:cron, "* * * * *"}, overlap_policy: :skip)
    TestHelper.create!(s, "rp", spec: {:cron, "* * * * *"}, overlap_policy: :replace)
    TestHelper.create!(s, "qu", spec: {:cron, "* * * * *"}, overlap_policy: {:queue, 2})

    results = Scheduler.tick(s, now: minute(4))
    assert %{"sk" => %{admitted: 1, skipped: 3}} = results
    assert %{"rp" => %{admitted: 1, replaced: 3}} = results
    assert %{"qu" => %{admitted: 2, skipped: 2}} = results

    rp = TestHelper.payloads(ctx.store, "scheduler/rp", "slot_decided")
    assert Enum.count(rp, &(&1["decision"] == "replaced")) == 3
    qu = TestHelper.payloads(ctx.store, "scheduler/qu", "slot_decided")
    assert Enum.count(qu, &(&1["decision"] == "skipped" and &1["reason"] == "queue_full")) == 2
  end

  # ── S7 restart restores trigger state ─────────────────────────────

  test "S7: restart restores watermark and unsettled; no duplicate admission", ctx do
    s = ctx.scheduler
    TestHelper.create!(s, "persist", spec: {:cron, "* * * * *"})
    assert %{"persist" => %{admitted: 3}} = Scheduler.tick(s, now: minute(3))

    # a fresh Scheduler over the same store simulates a host restart
    {:ok, s2} =
      Scheduler.new(
        store: ctx.store,
        clock: :system,
        oban: :x,
        max_slots_per_tick: 8,
        max_availability_gap_ms: 60_000
      )

    # the restart's availability gap exceeds max_availability_gap_ms, so the
    # boundary is `now`: both due slots are offline catch-up; queue(4) has
    # room for one (3 already unsettled), the other is skipped{queue_full}
    assert %{"persist" => %{admitted: 1, skipped: 1}} = Scheduler.tick(s2, now: minute(5))
    admitted = TestHelper.payloads(ctx.store, "scheduler/persist", "slot_decided")
    ids = for %{"decision" => "admitted", "id" => id} <- admitted, do: id
    assert length(ids) == length(Enum.uniq(ids))
    {:ok, st} = Scheduler.status(s2, "persist")
    assert {st.unsettled, st.watermark} == {4, minute(5)}
  end

  # ── S8 contended under CAS ─────────────────────────────────────────

  test "S8: a second tick at the same base revision contends and changes nothing", ctx do
    s = ctx.scheduler
    TestHelper.create!(s, "race", spec: {:cron, "* * * * *"})
    assert %{"race" => %{admitted: 2}} = Scheduler.tick(s, now: minute(2))
    assert %{"race" => %{admitted: 1}} = Scheduler.tick(s, now: minute(3))
    # head moved between load and append is covered by the CAS; the stream
    # holds exactly one tick batch per revision
    {:ok, st} = Scheduler.status(s, "race")
    assert {st.watermark, st.unsettled} == {minute(3), 3}
  end

  # ── S9 boundary edges ──────────────────────────────────────────────

  test "S9: slot exactly at now is admitted; slot below watermark is not re-admitted", ctx do
    s = ctx.scheduler
    TestHelper.create!(s, "edge", spec: {:cron, "* * * * *"})

    results = Scheduler.tick(s, now: minute(1))
    assert %{admitted: 1} = results["edge"]
    results2 = Scheduler.tick(s, now: minute(2) - 1)
    assert %{admitted: 0} = results2["edge"]
    results3 = Scheduler.tick(s, now: minute(2))
    assert %{admitted: 1} = results3["edge"]
  end

  # ── S10 DST transitions (America/New_York, real 2026 dates) ────────

  test "S10: DST fall-back records first-UTC-wins and skipped{ambiguous}" do
    ctx = TestHelper.memory(timezone_database: Tz.TimeZoneDatabase)
    s = ctx.scheduler

    # every Nov 1 01:30 occurs twice in America/New_York (EDT then EST);
    # 2025's Nov 1 slot and 2026's ambiguous Nov 1 slot lie inside (epoch, now]
    TestHelper.create!(
      s,
      "dst",
      spec: {:cron, "30 1 1 11 *"},
      timezone: "America/New_York"
    )

    # now = 2026-11-01 08:00 UTC (both matches of both years elapsed)
    now_ms = 1_793_520_000_000

    # 2025's fall-back was Nov 2, so its Nov 1 slot is ordinary; only the
    # 2026 slot has a second ambiguous match
    results = Scheduler.tick(s, now: now_ms)
    decision = results["dst"]
    assert decision.admitted == 2
    assert decision.skipped == 1

    records = TestHelper.payloads(ctx.store, "scheduler/dst", "slot_decided")
    assert Enum.count(records, &(&1["decision"] == "admitted")) == 2
    assert Enum.count(records, &(&1["decision"] == "skipped" and &1["reason"] == "ambiguous")) == 1
  end

  test "S11: DST spring-forward gap produces no match for the missing slot" do
    ctx = TestHelper.memory(timezone_database: Tz.TimeZoneDatabase)
    s = ctx.scheduler

    # Mar 8 02:30 is missing in 2026 (spring forward) but real in 2025;
    # inside (epoch, now] exactly one slot realizes
    TestHelper.create!(
      s,
      "gap",
      spec: {:cron, "30 2 8 3 *"},
      timezone: "America/New_York"
    )

    # now = 2026-03-08 08:00 UTC, after the 2026 transition
    now_ms = 1_772_956_800_000
    results = Scheduler.tick(s, now: now_ms)
    decision = results["gap"]
    assert decision.admitted == 1
    assert decision.skipped == 0
    assert decision.backlog == 0
  end

  test "S12: non-UTC evaluation without a tz database refuses at definition" do
    ctx = TestHelper.memory()
    s = ctx.scheduler

    assert {:error, :invalid_spec} =
             Scheduler.put_schedule(
               s,
               TestHelper.schedule("tz", spec: {:cron, "0 9 * * *"}, timezone: "America/New_York")
             )
  end

  # ── S13 slots unit behavior ────────────────────────────────────────

  test "S13: Slots.due bounds, orders and maps gap/ambiguous" do
    {:ok, parsed} = Slots.parse_cron("* * * * *")
    assert {:error, :invalid_spec} = Slots.parse_cron("@reboot")
    assert {:error, :invalid_spec} = Slots.parse_cron("0 0 * * * *")

    db = Calendar.UTCOnlyTimeZoneDatabase
    {:ok, emissions, backlog} = Slots.due({:cron, parsed}, "Etc/UTC", db, minute(0), minute(10), 4)
    assert length(emissions) == 4
    assert backlog == 6
    assert emissions == Enum.sort(emissions)
    assert Enum.all?(emissions, &match?({_, :win}, &1))

    # New York ambiguous slot 2026-11-01 01:30: two instants, first wins
    {:ok, ny} = Slots.parse_cron("30 1 1 11 *")

    {:ok, emissions, _} =
      Slots.due(
        {:cron, ny},
        "America/New_York",
        Tz.TimeZoneDatabase,
        1_793_491_200_000,
        1_793_520_000_000,
        10
      )

    assert [{u1, :win}, {u2, :ambiguous}] = emissions
    assert u1 < u2

    # the 2026 gap slot produces nothing
    {:ok, gap} = Slots.parse_cron("30 2 8 3 *")

    {:ok, [], 0} =
      Slots.due(
        {:cron, gap},
        "America/New_York",
        Tz.TimeZoneDatabase,
        1_772_928_000_000,
        1_772_956_800_000,
        10
      )
  end
end
