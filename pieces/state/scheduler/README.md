# state/scheduler

Durable schedule definitions plus the caller-driven driver that turns due
slots into occurrences under `delivery/trigger`'s identity and overlap
policy, and dispatches each admitted occurrence as one Oban job through
`integration/jobs`. ELZ-097.

## Contract

A schedule record `%{schedule_id, generation, spec, timezone?,
overlap_policy, dispatch, occurrence_ttl_ms?}` is durable: it survives
restart because every write goes to the ready Store, one atomic append batch
under stream-head CAS per schedule (`Store {:conflict, _}` → `:contended`,
the losing call changes nothing it had not already committed).

- `spec` is `{:cron, five_field_expression}` (minute resolution; `@reboot`
  and six-field/seconds forms refuse `:invalid_spec`) or
  `{:at, instant_unix_ms}` (one-shot; a past instant refuses).
- `timezone` defaults to `"Etc/UTC"`; any other IANA zone resolves through
  the `timezone_database` Need (a `Calendar.TimeZoneDatabase` — `tz` 0.28.4
  is the pinned provider; `Calendar.UTCOnlyTimeZoneDatabase` is the default
  and refuses non-UTC at definition). No global timezone state, no env reads.
- `overlap_policy` is `:skip | :replace | {:queue, n}` exactly as
  `delivery/trigger` declares (n ≤ `max_unsettled_per_schedule`).
- `dispatch` is `{queue, max_attempts, backoff_map}`; the occurrence id
  (`generation:instant:schedule_id`, encoded by trigger) is the `job_key`,
  so a re-enqueue after a crash resolves to the existing job. The backoff
  map is overlaid onto worker args, so the reserved keys `v`, `queue` and
  `job_key` refuse `:invalid_schedule` at definition — occurrence identity
  is untouchable.
- Occurrence identity keys on the UTC instant: an ambiguous local slot
  (fall-back) admits its first UTC match and records the second
  `skipped{ambiguous}`; a gap slot (spring-forward) produces no match.
  Slot evaluation is ordered by UTC instant, so a bounded tick's
  `max_slots_per_tick` truncation and its `backlog` count never skip a due
  instant that wall-clock order would have hidden.

`crontab` 1.2.1 is the pinned cron evaluator. Oban's internal
`Oban.Cron.Expression` was evaluated and rejected: it is `@moduledoc false`
(not public API) and carries no ambiguity/gap semantics for the DST
contract. `tz` 0.28.4 (Apache-2.0) is the pinned
`Calendar.TimeZoneDatabase` provider for non-UTC zones.

`tick/2` evaluates each active indexed schedule: first it reconciles
settlement of already-dispatched occurrences from Oban job state
(`:completed → acknowledged`, `:discarded`/`:cancelled → released`,
in-flight stays unsettled, unreadable is `:settlement_unknown`, never
guessed) through fenced chunked appends, reloads, then restores trigger
from the durable `last_recorded_unix_ms` watermark + post-settlement
unsettled ids, boundary = the persisted last evaluated watermark
(`last_boundary`, or `last_tick_ok_at` for records predating it) when
`now - last_tick_ok_at <= max_availability_gap_ms` else `now` (a clock
regression beyond that refuses `:watermark_invalid`; bounded truncation
never reclassifies known-available backlog as offline catch-up), evaluate
at most `max_slots_per_tick` earliest due slots in UTC-instant order (rest
are `backlog`, capped at 1_000), admit through
`ScheduleOccurrence.admit_slots/3`, and atomically commit slot decisions +
watermark (the last evaluated instant only) + trigger state +
`last_tick_ok_at = now` + boundary + a bounded unsettled count. It then
enqueues admitted occurrences (`{:retry, :unique_lock_held}` records
`pending`, errors record `dispatch_error`, both retried next tick) and
persists the dispatch outcome through a fenced append. Every fenced effect
append re-validates the occurrence under CAS — terminal states
(`settled`, `expired`, `replaced`, `redefined`) are sticky, so a stale
dispatch or slot record can never resurrect an occurrence.

`reap/2` runs the same settlement reconcile for every unsettled occurrence
before the TTL split — a terminal Oban state wins over expiry, so a job
that completed before its first post-TTL reap settles `acknowledged`,
never `expired` — then expiry: unsettled occurrences older than
`occurrence_ttl_ms` are recorded `occurrence_expired` (the released
settlement that frees the overlap slot) and their live Oban job is
cancelled.

`pause/2`, `resume/2`, `delete/2` are durable control transitions (delete
releases unsettled occurrences through chunked fenced appends — it always
fits `max_batch_size` per chunk — cancels their jobs by `(queue, job_key)`
and retires the index); `get/2`, `list/2`, `status/2` report the durable
projection.

Both `tick/2` and `reap/2` are pure entry points — no loop, no supervisor,
no scheduler engine. The consumer wires its own timer (`delivery/time`) and
supplies `now` via the bound `clock` or `opts[:now]`.

## Streams

Each schedule's ledger lives in stream `scheduler/<schedule_id>`; a small
index stream `scheduler` registers ids for enumeration. All record kinds
(`kinds/0`) are `:non_state_bearing` and decode self-contained
`schema_version` 1 JSON payloads; merge `Elzoo.Scheduler.kinds()` into the
consumer fold and keep version `1` in `fold.versions`.

## Failure taxonomy

`:not_found`, `:invalid_schedule`, `:invalid_spec`, `:generation_conflict`,
`:contended`, `:watermark_invalid`, `:invalid_slots` (trigger refused the
evaluated batch), `:paused` and `:retired` (per-schedule tick/reap refusals),
`:store_unavailable`, `:settlement_unknown`, `:dispatch_error`,
`:jobs_unavailable` (via `settlement_unknown`/`dispatch_error` decisions),
`:caller_transaction` (passed through the Store).

## Limits

At-least-once dispatch only — the worker must be idempotent on the
occurrence id. The index stream is a Piece detail; a crashed create can
leave a phantom index entry until delete. Replay scans the schedule stream
(bounded pages); consumer retention bounds its length. `backlog` is exact
to 1_000. See `piece.json` for the full list.

## Evidence

`test/elzoo/scheduler_test.exs` (S0–S24, Memory double + manual clock) and
`test/elzoo/scheduler_postgres_test.exs` (P1–P6, disposable PostgreSQL
schema + real Oban) — see `piece.json` for the claims each scenario grounds.
