# ELZ-095 — Normalize nullable lock-wait observations in the lease test probe

- Phase: test-only CI blocker repair (class T)
- Catalogue IDs: state/lease (test support only; ready Contract unchanged)
- Dependencies: ELZ-028

## Outcome

Repair the existing LS28 lease regression's polling probe, which crashed in the
aggregate copied consumer of PR #176, hosted run 42777290506. The raw failure
is BadBooleanError at wait_until/2 because contender_waits_on_lock?/1 returns
nil when PostgreSQL reports NULL for wait_event_type before entering a lock
wait. No SearchData assertion failed. Normalize that observation to false;
retain the lease assertions and timing limits unchanged.

## Admission record

1. Caller: the root and exported-consumer test gates for the accepted state/lease
   Piece. This is a concrete observed test defect, not a new catalogue capability.
2. Invariant: a lock-wait probe returns a boolean; an active backend with no lock
   wait reports false, an observed Lock wait reports true. LS28 still requires the
   actual lock wait and unchanged held/contended results. No production changes.
3. Reuse: PostgreSQL COALESCE and the existing TestRepo; no new package or service.
4. Split: independent test-only repair, integrated before resuming ELZ-082 acceptance.
5. Failure evidence: a deterministic real-PostgreSQL regression on the same checked-out
   backend must fail before the change (nil rather than false), pass afterward, and
   leave existing LS28 assertions/timeouts intact. Obtain independent narrow review.
6. Composition: test fixture only, no new Need, Telemetry, Config or Control surface.
   Existing database isolation/guard and copied-consumer constraints remain in force.

## Scope and coordinator approval

Only pieces/state/lease/test/elzoo/lease_postgres_test.exs: the existing SQL literal
in contender_waits_on_lock?/1 plus a new deterministic regression. No existing
assertion, timeout, outcome, wait_until/2 implementation, law, runtime Adapter or
other Piece may change. The coordinator approves this exact existing-test edit:

Before:
```elixir
"SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = $1"
```
After:
```elixir
"SELECT COALESCE(wait_event_type = 'Lock', FALSE) FROM pg_stat_activity WHERE pid = $1"
```

Also own work/review record, byte-equal task publication copy and scoped planning
job/generated views. No Piece manifest/ledger change is needed for this helper
regression. Do not weaken any ready Contract or claim a test as a proof.

## Acceptance

- Deterministic regression fails on old SQL, passes on corrected SQL.
- Existing state/lease tests pass, including LS28; no timeout/assertion weakening.
- mix check --affected origin/main and the Piece tests run before publication,
  using a guarded disposable database and verified S3 fixture; independent review.
- Exact-head hosted full five-job evidence passes; merge through the queue,
  confirm main's push evidence, remove only merged branch/worktree, close issue.

## Evidence and limits

Classify the inherited PR #176 failure as a test defect exposed by scheduling,
not a SearchData failure or a production lease bug. Record the failed run before
any new run. No new Cure proof, universal race-freedom or production behavior claim.

## Reference

ELZ-028 (#45); PR #176; run 42777290506, check-consumers-db aggregate consumer,
LS28 at lease_postgres_test.exs:1010 and wait_until/2:128.
