# SPDX-License-Identifier: Apache-2.0
# state/scheduler wiring example: a consumer merges the scheduler's kinds into
# its Store fold, binds the Store, a clock, its Oban instance and a timezone
# database, then drives tick/2 from its own timer (the delivery/time recipe).
# The Piece starts no process and reads no environment.

fold = %{
  initial: 0,
  kinds: Map.merge(%{"my_event" => :state_bearing}, Elzoo.Scheduler.kinds()),
  versions: [1],
  destinations: [],
  reduce: fn acc, _record, _outbox, _meta -> acc + 1 end
}

limits = %{max_record_bytes: 4_096, max_batch_size: 64, max_checkpoint_bytes: 10_000}
store = Elzoo.DurableLog.Postgres.store(MyApp.Repo, prefix: "my_app", fold: fold, limits: limits)

{:ok, scheduler} =
  Elzoo.Scheduler.new(
    store: store,
    clock: :system,
    oban: MyApp.Oban,
    timezone_database: Tz.TimeZoneDatabase,
    max_slots_per_tick: 32,
    max_availability_gap_ms: 120_000,
    occurrence_ttl_ms: 86_400_000
  )

{:ok, _} =
  Elzoo.Scheduler.put_schedule(scheduler, %{
    schedule_id: "digest",
    generation: 1,
    spec: {:cron, "0 9 * * *"},
    timezone: "America/New_York",
    overlap_policy: {:queue, 2},
    dispatch: {"digest", 5, %{"base_ms" => 1_000, "cap_ms" => 60_000}},
    occurrence_ttl_ms: 86_400_000
  })

# Caller-driven; typically invoked from your own GenServer timer.
decisions = Elzoo.Scheduler.tick(scheduler)
IO.inspect(decisions)

# Expire stale occurrences and derive settlements without evaluating slots.
IO.inspect(Elzoo.Scheduler.reap(scheduler))
IO.inspect(Elzoo.Scheduler.status(scheduler, "digest"))
