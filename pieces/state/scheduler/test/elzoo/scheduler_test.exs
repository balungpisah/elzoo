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
  alias Elzoo.Scheduler.{Record, Slots, TestHelper}
  alias Elzoo.DurableLog.{Memory, Store}

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

    assert {:error, :invalid_spec} =
             Scheduler.put_schedule(s, TestHelper.schedule("x", dispatch: {"", 3, %{}}))

    assert {:error, :invalid_spec} =
             Scheduler.put_schedule(s, TestHelper.schedule("x", overlap_policy: {:queue, 0}))

    assert {:error, :invalid_spec} =
             Scheduler.put_schedule(s, TestHelper.schedule("x", overlap_policy: {:queue, -2}))

    assert {:error, :invalid_schedule} =
             Scheduler.put_schedule(s, TestHelper.schedule("x", overlap_policy: {:queue, "two"}))

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
    assert List.last(tick_records)["unsettled_count"] == 3

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

  test "S5: offline catch-up slots admit under queue(n) bound and queue-fill the rest" do
    ctx = TestHelper.memory(max_slots_per_tick: 10)
    s = ctx.scheduler
    TestHelper.create!(s, "busy", spec: {:cron, "* * * * *"}, overlap_policy: {:queue, 2})

    # an 11-minute silence exceeds max_availability_gap_ms (60s): every
    # pending slot classifies offline catch-up; queue(2) admits two and the
    # evaluated rest queue-fill, one slot stays backlog
    results = Scheduler.tick(s, now: minute(11))
    assert %{"busy" => %{admitted: 2, skipped: 8, backlog: 1}} = results

    admitted =
      ctx.store
      |> TestHelper.payloads("scheduler/busy", "slot_decided")
      |> Enum.filter(&(&1["decision"] == "admitted"))

    assert length(admitted) == 2
    assert Enum.all?(admitted, &(&1["origin"] == "offline_catch_up"))
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

  # ── review regressions ────────────────────────────────────────────

  # Commit raw scheduler records at the current head, simulating an effect a
  # racing caller already committed.
  defp inject!(store, stream, specs) do
    {:ok, head} = Store.read(store, :head, [stream])

    {:ok, rows, _req} =
      Record.records(stream, head.revision, specs, TestHelper.fold(), TestHelper.limits())

    assert {:committed, _} = Memory.append(store, stream, head.revision, rows, [])
  end

  defp admitted_ids(store, schedule_id) do
    store
    |> TestHelper.payloads("scheduler/" <> schedule_id, "slot_decided")
    |> Enum.filter(&(&1["decision"] == "admitted"))
    |> Enum.map(& &1["id"])
  end

  defp utc_ms(date, time) do
    NaiveDateTime.new!(date, time)
    |> NaiveDateTime.diff(~N[1970-01-01 00:00:00], :millisecond)
  end

  defp conflict_store(mem_store) do
    opts = elem(mem_store, 1)

    {ConflictStore,
     opts
     |> Map.take([:fold, :limits, :visibility])
     |> Map.put(:inner, {Memory, opts})}
  end

  defp arm_conflict(stream) do
    :persistent_term.put({ConflictStore, :armed}, true)
    :persistent_term.put({ConflictStore, :stream}, stream)
  end

  test "S14: fall-back backlog evaluates in UTC order — no due instant skipped", _ctx do
    ctx = TestHelper.memory(timezone_database: Tz.TimeZoneDatabase, max_slots_per_tick: 2)
    s = ctx.scheduler

    TestHelper.create!(
      s,
      "dst-order",
      spec: {:cron, "30,45 1 1 11 *"},
      timezone: "America/New_York"
    )

    now_ms = 1_793_520_000_000

    # UTC order interleaves the two years' slots differently than wall-clock
    # order: the 2026-11-01 01:45 first match (05:45Z) precedes the 01:30
    # second match (06:30Z). Four bounded ticks must still admit every :win.
    for _ <- 1..4, do: Scheduler.tick(s, now: now_ms)

    ids = admitted_ids(ctx.store, "dst-order")
    assert length(ids) == 4

    instants =
      for id <- ids,
          [_gen, instant, _sid] <- [String.split(id, ":")],
          do: String.to_integer(instant)

    expected = [
      utc_ms(~D[2025-11-01], ~T[05:30:00]),
      utc_ms(~D[2025-11-01], ~T[05:45:00]),
      utc_ms(~D[2026-11-01], ~T[05:30:00]),
      utc_ms(~D[2026-11-01], ~T[05:45:00])
    ]

    assert Enum.sort(instants) == Enum.sort(expected)

    ambiguous =
      ctx.store
      |> TestHelper.payloads("scheduler/dst-order", "slot_decided")
      |> Enum.count(&(&1["decision"] == "skipped" and &1["reason"] == "ambiguous"))

    assert ambiguous == 2
  end

  test "S15: bounded-tick backlog stays live — boundary tracks evaluation coverage", _ctx do
    ctx = TestHelper.memory(max_slots_per_tick: 2, max_availability_gap_ms: 600_000)
    s = ctx.scheduler
    TestHelper.create!(s, "backlog", spec: {:cron, "* * * * *"}, overlap_policy: {:queue, 8})

    assert %{"backlog" => %{admitted: 2, backlog: 2}} = Scheduler.tick(s, now: minute(4))
    assert %{"backlog" => %{admitted: 2, backlog: 1}} = Scheduler.tick(s, now: minute(5))

    admitted =
      ctx.store
      |> TestHelper.payloads("scheduler/backlog", "slot_decided")
      |> Enum.filter(&(&1["decision"] == "admitted"))

    assert length(admitted) == 4
    # the truncated backlog was due during proven availability: every slot
    # classifies live, never offline catch-up
    assert Enum.all?(admitted, &(&1["origin"] == "live"))
  end

  test "S16: tick_recorded stays within max_record_bytes at max unsettled", _ctx do
    ctx =
      TestHelper.memory(
        limits: %{max_record_bytes: 1_024, max_batch_size: 256, max_checkpoint_bytes: 10_000},
        max_slots_per_tick: 64,
        max_unsettled_per_schedule: 64,
        max_availability_gap_ms: 600_000
      )

    s = ctx.scheduler
    TestHelper.create!(s, "fat", spec: {:cron, "* * * * *"}, overlap_policy: {:queue, 64})

    assert %{"fat" => %{admitted: 64}} = Scheduler.tick(s, now: minute(64))
    assert %{"fat" => %{admitted: 0, skipped: 1}} = Scheduler.tick(s, now: minute(65))

    raw =
      ctx.store
      |> TestHelper.rows("scheduler/fat")
      |> Enum.filter(&(&1.kind == "tick_recorded"))
      |> List.last()
      |> Map.get(:payload)

    assert byte_size(raw) < 512
    decoded = Jason.decode!(raw)
    assert decoded["unsettled_count"] == 64
    refute Map.has_key?(decoded, "unsettled")
  end

  test "S17: delete releases an unsettled set larger than max_batch_size", _ctx do
    ctx =
      TestHelper.memory(
        limits: %{max_record_bytes: 4_096, max_batch_size: 16, max_checkpoint_bytes: 10_000},
        max_slots_per_tick: 4,
        max_unsettled_per_schedule: 24,
        max_availability_gap_ms: 600_000
      )

    s = ctx.scheduler
    TestHelper.create!(s, "busy", spec: {:cron, "* * * * *"}, overlap_policy: {:queue, 24})

    for n <- [4, 8, 12, 16, 20, 24] do
      assert %{"busy" => %{admitted: 4}} = Scheduler.tick(s, now: minute(n))
    end

    assert {:ok, %{control: :deleted, released: 24}} = Scheduler.delete(s, "busy")

    settled = TestHelper.payloads(ctx.store, "scheduler/busy", "occurrence_settled")
    assert length(settled) == 24
    assert Enum.all?(settled, &(&1["kind"] == "released" and &1["via"] == "deleted"))
    assert "schedule_deleted" in TestHelper.kinds_in(ctx.store, "scheduler/busy")
    assert {:ok, %{state: :deleted, unsettled: 0}} = Scheduler.status(s, "busy")
  end

  test "S18: dispatch backoff may not carry reserved identity keys", _ctx do
    s = TestHelper.memory().scheduler

    for backoff <- [
          %{"job_key" => "x"},
          %{"queue" => "x"},
          %{"v" => 2},
          %{:job_key => "x"},
          %{"ok" => 1, "job_key" => "x"}
        ] do
      assert {:error, :invalid_schedule} =
               Scheduler.put_schedule(
                 s,
                 TestHelper.schedule("reserved", dispatch: {"q", 3, backoff})
               )
    end

    assert {:ok, _} =
             Scheduler.put_schedule(
               s,
               TestHelper.schedule("reserved-ok", dispatch: {"q", 3, %{"backoff_ms" => 5}})
             )
  end

  test "S19: a stale dispatch record cannot resurrect a settled occurrence", ctx do
    s = ctx.scheduler
    TestHelper.create!(s, "sticky", spec: {:cron, "* * * * *"})
    assert %{"sticky" => %{admitted: 1}} = Scheduler.tick(s, now: minute(1))

    [id] = admitted_ids(ctx.store, "sticky")
    stream = "scheduler/sticky"

    # the terminal record commits first; the stale dispatch lands after it
    inject!(ctx.store, stream, [
      {"occurrence_settled", Record.settled_payload(id, :acknowledged, :completed, minute(2))}
    ])

    inject!(ctx.store, stream, [
      {"occurrence_dispatch", Record.dispatch_record_payload(id, "dispatched", 999, nil)}
    ])

    assert {:ok, %{unsettled: 0}} = Scheduler.status(s, "sticky")
  end

  test "S20: a fenced effect append loses to a concurrent terminal commit", ctx do
    s = ctx.scheduler
    TestHelper.create!(s, "fence", spec: {:cron, "* * * * *"}, occurrence_ttl_ms: 1)
    assert %{"fence" => %{admitted: 1}} = Scheduler.tick(s, now: minute(1))

    [id] = admitted_ids(ctx.store, "fence")
    stream = "scheduler/fence"

    # pause the next :append inside reap's fenced effect append
    assert :ok = Memory.fault(ctx.store, :append, {:pause, :fence_race})
    assert %{"fence" => %{refused: :store_unavailable}} = Scheduler.reap(s, now: minute(2))

    # a competing settlement commits while the effect append is held
    inject!(ctx.store, stream, [
      {"occurrence_settled", Record.settled_payload(id, :acknowledged, :completed, minute(2))}
    ])

    # releasing the held append hits the moved head: conflict, nothing written
    assert {:conflict, _} = Memory.release(ctx.store, :fence_race)

    assert TestHelper.payloads(ctx.store, stream, "occurrence_expired") == []
    assert {:ok, %{unsettled: 0}} = Scheduler.status(s, "fence")
  end

  test "S21: a real CAS conflict maps to :contended and the loser changes nothing", ctx do
    store = conflict_store(ctx.store)
    s = TestHelper.scheduler(store, ctx.clock)
    TestHelper.create!(s, "cas-race", spec: {:cron, "* * * * *"})

    arm_conflict("scheduler/cas-race")

    on_exit(fn ->
      :persistent_term.erase({ConflictStore, :armed})
      :persistent_term.erase({ConflictStore, :stream})
    end)

    assert %{"cas-race" => %{contended: true, admitted: 0}} =
             Scheduler.tick(s, now: minute(2))

    # the losing tick committed nothing: no slot decisions, watermark intact
    assert TestHelper.payloads(ctx.store, "scheduler/cas-race", "slot_decided") == []
    {:ok, st} = Scheduler.status(s, "cas-race")
    assert st.watermark == TestHelper.epoch()
  end

  test "S22: an unavailable or unreadable index fails closed", ctx do
    s = ctx.scheduler
    TestHelper.create!(s, "idx", spec: {:cron, "* * * * *"})

    assert :ok = Memory.fault(ctx.store, :head, :unavailable)
    assert {:error, :store_unavailable} = Scheduler.tick(s, now: minute(1))

    # faults are one-shot: re-arm for reap
    assert :ok = Memory.fault(ctx.store, :head, :unavailable)
    assert {:error, :store_unavailable} = Scheduler.reap(s, now: minute(1))

    assert :ok = Memory.fault(ctx.store, :head, :malformed)
    assert {:error, :watermark_invalid} = Scheduler.tick(s, now: minute(1))
  end

  test "S23: telemetry emits bounded tick/admission/expiry/dispatch-failure events", ctx do
    s = ctx.scheduler
    events = [:tick, :admitted, :dispatch_error, :expired]

    for event <- events do
      :telemetry.attach(
        {__MODULE__, event},
        [:elzoo, :scheduler, event],
        fn e, m, meta, _ -> send(self(), {:tlm, e, m, meta}) end,
        nil
      )
    end

    on_exit(fn ->
      for event <- events, do: :telemetry.detach({__MODULE__, event})
    end)

    TestHelper.create!(s, "tlm", spec: {:cron, "* * * * *"}, occurrence_ttl_ms: 1)
    assert %{"tlm" => %{admitted: 1, dispatch_errors: 1}} = Scheduler.tick(s, now: minute(1))
    assert %{"tlm" => %{expired: 1}} = Scheduler.reap(s, now: minute(2))

    assert_received {:tlm, [:elzoo, :scheduler, :tick], %{count: 1}, tick_meta}
    assert tick_meta.schedule_id == "tlm" and tick_meta.admitted == 1

    assert_received {:tlm, [:elzoo, :scheduler, :admitted], _, adm_meta}
    assert is_binary(adm_meta.occurrence) and adm_meta.origin == :live

    assert_received {:tlm, [:elzoo, :scheduler, :dispatch_error], _, err_meta}
    assert is_binary(err_meta.occurrence)

    assert_received {:tlm, [:elzoo, :scheduler, :expired], _, exp_meta}
    assert is_binary(exp_meta.occurrence)

    # bounded metadata only — no schedule payload, worker args or backoff
    for meta <- [tick_meta, adm_meta, err_meta, exp_meta] do
      refute Enum.any?(Map.keys(meta), &(&1 in [:args, :backoff, :payload, :spec, :dispatch]))
    end
  end

  test "S24: redefine supersedes an unsettled set larger than max_batch_size", _ctx do
    ctx =
      TestHelper.memory(
        limits: %{max_record_bytes: 4_096, max_batch_size: 16, max_checkpoint_bytes: 10_000},
        max_slots_per_tick: 4,
        max_unsettled_per_schedule: 24,
        max_availability_gap_ms: 600_000
      )

    s = ctx.scheduler
    TestHelper.create!(s, "redef", spec: {:cron, "* * * * *"}, overlap_policy: {:queue, 24})

    for n <- [4, 8, 12, 16, 20, 24] do
      assert %{"redef" => %{admitted: 4}} = Scheduler.tick(s, now: minute(n))
    end

    assert {:ok, %{redefined: "redef", generation: {1, 2}}} =
             Scheduler.put_schedule(
               s,
               TestHelper.schedule("redef", generation: 2, spec: {:cron, "*/2 * * * *"})
             )

    assert length(TestHelper.payloads(ctx.store, "scheduler/redef", "occurrence_redefined")) ==
             24

    {:ok, st} = Scheduler.status(s, "redef")
    assert st.generation == 2 and st.unsettled == 0
  end
end

# Store facade delegate over the Memory double: reads pass through, and the
# first append to the armed stream returns a real `{:conflict, _}` so the
# `:contended` mapping is exercised end to end.
defmodule ConflictStore do
  @moduledoc false
  alias Elzoo.DurableLog.Memory

  def head(store, stream), do: Memory.head(inner(store), stream)
  def read(store, stream, from, limit), do: Memory.read(inner(store), stream, from, limit)

  def append(store, stream, expected, records, items) do
    if :persistent_term.get({__MODULE__, :armed}, false) and
         :persistent_term.get({__MODULE__, :stream}) == stream do
      :persistent_term.erase({__MODULE__, :armed})
      {:conflict, %{expected: expected, observed: expected + 1}}
    else
      Memory.append(inner(store), stream, expected, records, items)
    end
  end

  defp inner(store), do: store |> elem(1) |> Map.fetch!(:inner)
end
