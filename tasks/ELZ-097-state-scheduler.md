# ELZ-097 — Specify the durable schedule and occurrence driver over jobs

- Phase: demand-led state policy
- Catalogue IDs: state/scheduler
- Dependencies: ELZ-006, ELZ-009, ELZ-010, ELZ-027, ELZ-033

## Outcome

Deliver `state/scheduler`: durable schedule definitions and the driver that
turns due slots into admitted occurrences under `delivery/trigger`'s
occurrence identity and overlap policy, then dispatches each admitted
occurrence as a job through the ready `integration/jobs` (Oban) boundary.
Cron/due-instant evaluation is upstream (`Oban.Cron.Expression` from the
pinned Oban, or `crontab` if the reuse check finds a required gap); schedule
identity, generation, watermark, overlap and misfire decisions are Elzoo's.
Oban's static `Oban.Plugins.Cron` is **not** used for runtime schedules — it
reads config at boot only — and no second scheduling engine (Quantum etc.) is
added.

## Decisions this task carries

- Dependencies reconciled: RC-02 listed ELZ-033, ELZ-010, ELZ-027. This task
  adds `ELZ-009` (the ready Store is the required durable boundary for
  schedules, occurrences and the evaluation watermark — Oban's own tables do
  not hold schedule definitions or trigger state) and `ELZ-006`
  (`delivery/time` clock port, `delivery/retry-timeout` result vocabulary).
  Nothing was removed.
- Occurrence identity, generation fencing and the skip/queue(n)/replace
  overlap decision come from the ready `Elzoo.ScheduleOccurrence` (ELZ-027);
  this Piece persists its state and supplies due slots, the availability
  boundary, settlements and the dispatch side. It does not re-implement the
  transition.
- Dispatch is at-least-once with dedup, never exactly-once: the ledger moves
  an occurrence `pending → admitted → dispatching → dispatched`; dispatch
  goes through `Elzoo.Jobs.changeset/4` + `enqueue/2` with `job_key` = the
  encoded occurrence id — `query/2`, `state/3` and `states/3` all key on
  `(queue, job_key)`, so the occurrence identity is always recoverable by
  decoding `job_key`. Oban uniqueness (`keys: [:queue, :job_key],
  period: :infinity, states: :all`) is advisory — an insert-time lock plus
  query, not a database constraint — but combined with the ledger's
  `dispatching → dispatched` transition it yields at most one job per
  occurrence in practice: a re-enqueue after a crash resolves to the
  existing job (`{:ok, id}` on conflict), `{:retry, :unique_lock_held}`
  leaves `dispatch_pending` for the next tick, and `{:error, _}` is recorded
  `dispatch_error` and retried safely. Settlement is *derived*, not pushed:
  each tick reconciles unsettled occurrences through
  `Elzoo.Jobs.state_by_id/2` (Oban `:completed` → trigger `acknowledged`;
  `:discarded`/`:cancelled` → `released`) — the consumer's registered runner
  performs the work and Oban's own retry policy owns attempt-level
  failures, so no callback into this Piece is required and no worker
  Contract is duplicated.
- Timezone: schedules declare an IANA zone; `Etc/UTC` is the default. A
  non-UTC zone requires a timezone database (`tz` hex package or equivalent)
  as an explicit Need — recorded in `registry/providers.json` with license
  if adopted; the Piece reads no environment and configures no global
  `time_zone_database` itself.
- Misfire: two distinct persisted instants, matching trigger's two inputs.
  `last_recorded_unix_ms` is the slot-domain watermark persisted with the
  trigger state (trigger's `restore/3` argument). Availability is a separate
  fact: the Piece persists `last_tick_ok_at_unix_ms` — the instant the last
  tick completed its Store writes. On each tick it computes the boundary as
  `last_tick_ok_at` when `now - last_tick_ok_at <=
  max_availability_gap_ms` (declared config, recommended 2× the caller's
  tick interval) and `now` otherwise — the conservative rule: a gap means
  the Piece cannot show continuous availability, so every unevaluated slot
  classifies as an offline catch-up slot. Offline catch-up slots are
  admitted only under `queue(n)` up to its bound and are otherwise recorded
  `skipped{offline_catch_up}` — trigger's Contract, not re-decided here. A
  missing/corrupt watermark or `last_tick_ok_at` refuses the tick for that
  schedule (`:watermark_invalid`); the Piece never guesses a boundary.
- Concurrency: two hosts may tick the same store; each schedule's ledger
  lives in one stream and each tick is one atomic append batch under
  head-revision CAS (the `state/lease` precedent). Store `{:conflict, _}`
  maps to `:contended` — the loser changes nothing.

## Admission record

1. **Responsibility and caller.** Durable schedule CRUD with generation,
   due-slot evaluation, occurrence admission through trigger, job dispatch
   through jobs, settlement and expiry recording. Callers (RC-02): C7
   scheduled research digest; C5 timers. `delivery/trigger` owns the pure
   occurrence transition; `integration/jobs` owns Oban mechanics; the
   consumer owns the worker module that performs the work.
2. **Interface and invariant.**
   - *Construction.* `new/1` takes a Store binding (ready PostgreSQL Store;
     the ready in-memory variant for tests where offered), a clock port, an
     Oban instance reference for `integration/jobs`, bounds
     (`max_schedules`, `max_unsettled_per_schedule`, `tick_batch`), and a
     default occurrence TTL. No environment reads; no root Application.
   - *Schedule record.* `%{schedule_id, generation, spec, timezone,
     overlap_policy, dispatch: {queue, max_attempts, backoff_policy},
     occurrence_ttl_ms, active, created_at_unix_ms, updated_at_unix_ms}`
     where `spec ∈ {:cron, expression} | {:at, instant_unix_ms}` (one-shot)
     and `overlap_policy ∈ {:skip, {:queue, n}, :replace}` exactly as
     trigger declares. The dispatch binding is the `Elzoo.Jobs.changeset/4`
     input shape; the consumer
     registers the runner for that queue via `Elzoo.Jobs.register/2` and
     resolves the occurrence's work from the job's `job_key` (the encoded
     occurrence id) plus `get/2`/`status/2` on this Piece. `put_schedule/2`
     creates or redefines; a redefine keeps the `schedule_id`, requires a
     strictly greater `generation` (trigger's fence — a spec change is not
     required by trigger, though this Piece recommends one), surfaces
     trigger's `redefined` supersession records for pending occurrences
     (distinct from the overlap policy's `replaced` decisions), and
     increments `generation`. `pause/2`, `resume/2`, `delete/2` (retires the
     schedule; unsettled occurrences are recorded `released` and their Oban
     jobs cancelled through `Elzoo.Jobs.cancel/3`, pending slots
     stop), `list/2`, `get/2`, `status/2`.
   - *Tick.* `tick/1` (injectable `now`) is **caller-driven** — the Piece
     runs no loop or supervisor; the consumer wires a timer (the
     `delivery/time` `Process.send_after` recipe or its own). Per active
     schedule: load durable `last_recorded`, unsettled occurrence ids and
     `last_tick_ok_at` → restore trigger state → compute the availability
     boundary per the misfire rule → evaluate at most `max_slots_per_tick`
     oldest due slots in `(last_recorded, now]` via the pinned cron
     evaluator in the declared zone (overflow continues next tick;
     `last_recorded` advances only over evaluated slots) → `admit_slots`
     with the computed boundary → write the new watermark, occurrence
     ledger records, trigger state and `last_tick_ok_at = now` as **one
     atomic append batch on the schedule's stream** under head-revision CAS
     (bounded by the Store's batch limit; `{:conflict, _}` → `:contended`)
     → reconcile settlements for previously dispatched occurrences via
     `Elzoo.Jobs.state_by_id/2` → for each admitted occurrence without a
     job record, `Elzoo.Jobs.enqueue/2` a changeset whose `job_key` is the
     encoded occurrence id and store the returned Oban id → record dispatch
     state. Returns per-schedule decisions `{admitted, skipped, replaced,
     redefined, expired, contended, refused, backlog}` — every overlap and
     catch-up decision is recorded, never silent.
   - *Settlement and expiry.* Settlement is derived during `tick`/`reap`
     from Oban job state (`:completed` → `acknowledged`; `:discarded`,
     `:cancelled` → `released`; `:retryable`/`:executing`/`:scheduled` stay
     unsettled) and fed to trigger's `settle/2` — no worker callback is
     required. `reap/1` marks occurrences older than `occurrence_ttl_ms`:
     the trigger settlement is recorded `released` (the only non-ack
     terminal kind trigger accepts — it frees the overlap slot) *and* the
     ledger status is `expired`; when an Oban job exists it is cancelled
     through `Elzoo.Jobs.cancel/3` so a late completion cannot resurrect
     the occurrence. `status/2` reports schedule state, watermark,
     `last_tick_ok_at`, unsettled count and dispatch-pending count.
   - *Invariants.* Occurrence id = `f(schedule_id, generation,
     scheduled_instant)` from trigger — stable across restart, retries and
     re-ticks; two activations of one slot yield one occurrence and one job.
     At most the policy bound of unsettled occurrences per schedule. A
     redefinition never silently replaces pending work (generation fence +
     recorded `replaced` decisions). Derived settlement is idempotent: a
     terminal Oban state settles its occurrence once, and reconcile never
     reopens or double-settles it; an Oban state that cannot be read leaves
     the occurrence unsettled (`:settlement_unknown`), never guessed.
     Dispatch is idempotent per the admission record: advisory Oban
     uniqueness on `(queue, job_key)` plus the ledger's
     `dispatching → dispatched` transition make re-enqueue resolve to the
     existing job.
   - *Failure taxonomy.* `:not_found`, `:invalid_schedule`,
     `:invalid_spec` (unparseable cron, `@reboot` — it has no durable
     meaning and is refused, past `at`, empty queue bound, unresolvable
     timezone),
     `:generation_conflict`, `:contended` (the Store `{:conflict, _}` CAS
     mapping — the losing tick changes nothing), `:watermark_invalid`
     (missing/corrupt `last_recorded` or `last_tick_ok_at` — refuses without
     guessing),
     `:store_unavailable`, `:jobs_unavailable`, `:dispatch_error` (enqueue
     returned `{:error, _}` or exited — recorded on the occurrence; the next
     tick re-attempts enqueue, idempotent via advisory uniqueness plus the
     ledger transition; `{:retry, :unique_lock_held}` waits a tick),
     `:settlement_unknown` (job state cannot be read — occurrence stays
     unsettled, never guessed), `:expired`. Timezone resolution failure for
     a declared zone is `:invalid_spec` at `put_schedule` when the database
     cannot resolve it.
3. **Reuse check.** `crontab` 1.2.1 (MIT — the disposition's named
   candidate, public documented API) is the preferred cron evaluator;
   `Oban.Cron.Expression` (already pinned via oban 2.24.2, Apache-2.0) is
   the fallback — it exposes `parse/1`, `now?/2`, `next_at/2`, `last_at/2`
   with timezone-string support but is `@moduledoc false` internal API, so
   relying on it requires a recorded justification (stability expectations,
   upgrade risk) or adoption of `crontab` instead. Either way the choice is
   pinned in `registry/providers.json` with license and the rejected
   alternative recorded; `@reboot` schedules are refused regardless.
   `Elzoo.ScheduleOccurrence`
   (ELZ-027), `Elzoo.Jobs`/Oban (ELZ-010), the ready Store (ELZ-009) and
   `delivery/time` clock (ELZ-006) are consumed as-is. No Quantum, no second
   cron engine, no new scheduling policy.
4. **Split test.** Schedule persistence + watermark + dispatch share the
   "durable ledger drives trigger, jobs carry occurrences" invariant and stay
   together. Cron parsing, occurrence transition, job mechanics, worker
   execution and settlement reporting are separate ready Pieces/consumer
   duties.
5. **Failure and evidence.** Dangerous paths (RC-02 acceptance): restart
   with unsettled occurrences and a valid watermark (state restored, no
   duplicate admission); duplicate occurrence (two ticks, two hosts → one
   occurrence id, one job); missed interval while down (offline catch-up
   under `queue(n)` bound, `skipped` otherwise, boundary from durable
   watermark); clock boundary (slot exactly at `now`/watermark — inclusive/
   exclusive edges tested); declared skip/queue/replace each recorded;
   generation conflict, derived settlement from each terminal Oban state
   (completed/discarded/cancelled) with idempotent re-reconcile, unreadable
   job state stays unsettled, expiry reap cancels the job, 2026 DST
   spring-forward gap and fall-back overlap at real 2026 transitions
   (America/New_York): a repeated local time yields at most one occurrence —
   occurrences are keyed by UTC instant, so the first matching UTC instant
   wins and any second match for the same local slot is recorded
   `skipped{ambiguous}`; a gap slot produces no match and is covered by the
   misfire/catch-up recording; enqueue `{:error, _}` and
   `{:retry, :unique_lock_held}` recovered on later ticks without duplicate
   jobs; slot-evaluation overflow respects `max_slots_per_tick` with
   `backlog` recorded; `put_schedule` redefinition while occurrences
   unsettled surfaces `redefined` supersession records. Proofs: none
   required beyond selected laws if a pure decision earns them; tests carry
   the weight. Timezone database behavior, cron evaluator semantics and Oban
   insert/uniqueness behavior are named upstream contracts.
6. **Composition record.** Piece dependencies: `delivery/trigger` (ELZ-027),
   `integration/jobs` (ELZ-010), `state/event-log` + `integration/sql`
   (ELZ-009), `delivery/time` clock port (ELZ-006). Needs: Store
   (PostgreSQL for the multi-host CAS path; memory variant for
   single-process tests), Oban instance, timezone database for non-UTC
   schedules, per-schedule dispatch binding (`queue`, `max_attempts`,
   `backoff`) supplied by the consumer, and a caller-driven tick (the
   consumer wires the timer — the Piece runs no loop). Telemetry:
   `supported` — bounded tick/admission/expiry/dispatch-failure events, no
   schedule payloads; readiness ships the event tests. Config: `supported`
   at construction (bounds, `max_availability_gap_ms`, default TTL).
   Control: `supported` — `pause`/`resume`/`delete` are recorded durable
   transitions; redefine is a new generation, not hot reconfiguration; no
   drain claims (the caller stops ticking). Data classification: schedule
   metadata and occurrence ids only.

## Scope

- add `pieces/state/scheduler/` with README, `piece.json`, `lib/`, `cure/`
  (if a pure decision earns it), `test/` and examples;
- publication duties on the task branch (main's publication step already
  created the issue): create `tasks/ELZ-097-state-scheduler.md` byte-equal to
  the live issue body; add release-plan job `ELZ-097` (paths, dependencies,
  `issue_body_sha256` of the live body, outputs `["state/scheduler"]`, plus
  `kind`/`release`/`stage`/`product_aims` carried from RC-02 — P06); move
  the `state/scheduler` entry's `job` from `RC-02` to `ELZ-097` and mark
  RC-02 superseded for this output; run `mix elzoo.ledger`; regenerate
  `LEDGER.md` and roadmap views;
- dependency change: the reuse check's winner (`crontab` 1.2.1 preferred;
  `Oban.Cron.Expression` only with recorded justification; `tz`/`tzdata` for
  non-UTC zones) added to `mix.exs`/`mix.lock`/`config/` and
  `registry/providers.json` is a class-X change — one local full
  `mix setup && mix check` at the head, sequenced with other workers; if
  the pinned `Oban.Cron.Expression` suffices for UTC-only scope and no new
  Hex package is needed, record that and skip the dependency change;
- at readiness: registry row, `piece.json` manifest hashes, operational
  declarations, consumer-layout test;
- worker gate `mix check --affected origin/main` +
  `mix test pieces/state/scheduler/test` before every push.

## Acceptance

- [ ] Schedule CRUD with generation fencing; `put_schedule` validates spec,
      timezone and bounds; redefine increments generation.
- [ ] `tick/1` admits due slots through `Elzoo.ScheduleOccurrence`, persists
      watermark + ledger + trigger state atomically per schedule, enqueues
      jobs keyed by the encoded occurrence id, and returns recorded
      per-schedule decisions.
- [ ] RC-02 scenarios pass: restart with unsettled occurrences (no duplicate
      occurrence or job), duplicate occurrence across ticks/hosts, missed
      interval while down — slots before the computed availability boundary
      classify `offline_catch_up` (queue-bound admit or recorded skip),
      slots after it follow the overlap policy — clock boundary edges,
      each overlap policy recorded, `max_slots_per_tick` overflow →
      `backlog` with watermark advancing only over evaluated slots,
      generation conflict, expiry reap, 2026 DST gap/overlap behavior
      documented and tested.
- [ ] Dispatch idempotency: crash between ledger commit and enqueue
      completes on next tick; re-enqueue resolves through advisory
      uniqueness plus the ledger transition to the existing job;
      `{:retry, :unique_lock_held}` waits; `{:error, _}` recorded as
      `dispatch_error` and retried safely.
- [ ] Settlement is derived from Oban job state during tick: `:completed` →
      `acknowledged`, `:discarded`/`:cancelled` → `released`, in-flight
      states stay unsettled, unreadable state → `:settlement_unknown`;
      re-reconcile is idempotent.
- [ ] `:contended` under concurrent ticks changes nothing; `:watermark_invalid`
      refuses without guessing.
- [ ] Non-UTC schedules require and use the declared timezone database;
      resolution failure is `:invalid_spec` at definition time.
- [ ] No schedule payload, worker args content or secret in telemetry,
      errors or inspect values; the Piece reads no environment variables.
- [ ] Operational applicability declared per docs/operational-contracts.md.
- [ ] Piece tests pass in the exported consumer layout; the root Application
      is not required.
- [ ] Full hosted `symbolic-check.yml` green on the exact PR head; local
      worker gate (and full local check if dependencies changed) recorded
      with exit codes.

## Evidence and limits

Finite tests over the listed scenarios on the ready Store (PostgreSQL where
the CAS path requires it; memory variant where offered) with a controllable
clock and the real Oban boundary (test instance or the jobs Piece's own
harness); upstream contracts of `Oban.Cron.Expression`/`crontab` (whichever
the reuse check pins), Oban insert/unique semantics, OTP `Task`, and the
ready Store transaction boundary. No claim of exactly-once dispatch (it is
at-least-once with occurrence-id dedup), no guarantee that a worker's own
retry policy preserves occurrence identity (the worker Contract owns that —
args carry the id), no cron-second granularity beyond the evaluator's
resolution, no evaluation while the host is down beyond the recorded
catch-up/skip decision, no hot schedule reconfiguration.

## Out of scope

Workflow timers and durable sagas (`workflow/run`), job execution and worker
implementation, cron expression authoring UI, Oban queue configuration and
plugins beyond job insertion, notification on fire, schedule templates,
calendar (non-cron) schedules, second scheduler instance coordination beyond
the Store CAS.

## Reference

RC-02 contract and acceptance ("Schedule identity, generation and instant ->
durable occurrence admission … occurrence identity survives restart …
Timer recipe alone cannot satisfy this job");
`docs/plans/catalogue-dispositions.md#state-scheduler` (ADOPT Oban 2.24.2 +
crontab 1.2.1 candidates, occurrence identity from ELZ-027, no second
Quantum); `delivery/trigger` (ELZ-027) Contract — availability boundary,
offline catch-up, overlap policies; `integration/jobs`/`state/lease` READMEs
(Store transaction, fencing and Oban precedents); owner decision OD-A;
`docs/work/research/owner-decisions-2026-11-08.md`.

## Open questions (none blocks a builder)

1. Reuse-check outcome: `crontab` 1.2.1 (public API, disposition's named
   candidate) vs already-pinned `Oban.Cron.Expression` (internal API) —
   decided by capability coverage (expression syntax, named zones, DST
   resolution, seconds field if needed) and the internal-API justification
   bar; `tz`/`tzdata` adoption for non-UTC zones likewise. Recorded with
   licenses either way.
2. Whether one-shot `{:at, instant}` schedules are in this slice (recommended:
   yes — same ledger, trivial cron-free path) or deferred; recorded either
   way.
3. Whether settlement stays purely derived from Oban state (recommended: yes
   — `Elzoo.Jobs.state_by_id` covers completed/discarded/cancelled) or an
   explicit consumer override input is added later; recorded either way.
