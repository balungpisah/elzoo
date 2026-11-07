# ELZ-035 — Stabilize the durable-job DJ11 and DJ13 checks

- Phase: P2 durable workflow (test reliability for the ELZ-010 ready Contract)
- Catalogue IDs: assembly/durable-job, integration/jobs (no Contract change unless a finding requires one)
- Dependencies: ELZ-010

## Outcome

`mix check` fails intermittently in two ELZ-010 checks, on commits that do not touch
durable-job code. Each failure blocks merge acceptance for unrelated work and needs a manual
re-run. Find the cause of each failure and remove it without weakening what the checks prove.

Observed failures (all recorded on #10):

- DJ13 `reply lost after the succeeded commit` (`pieces/assembly/durable-job/test/elzoo/durable_job_test.exs:373`):
  `assert job_row(f, id) == {"cancelled", 1}` got `{"cancelled", 2}`. Seen on main
  `bc14b24` (run 42275914611 attempt 1), on PR #57 head `2d49979` (run 42299328141 attempt 1),
  and in one local run while other `mix check` runs shared the machine. Each passed on re-run.
- DJ11 `postgres: rescued-but-alive stale attempt is re-classified stale and snoozes`
  (`durable_job_test.exs:91`): `start_supervised!` of Oban failed because `Oban.Notifiers.PG`
  was not alive when the notifier registered. Seen on PR #57 head `2d49979` (same run).

Both ran inside the copied-consumer run of `test/export_test.exs:125`.

## Scope

- Reproduce under load (for example, parallel `mix check` runs or a constrained scheduler) and
  record the exact reproduction command and rate before any change.
- DJ13: decide whether the attempt counter reaching 2 is (a) a test timing assumption or (b) a
  real Oban snooze/attempt interaction that contradicts the ELZ-010 Contract text. For (a), make
  the test deterministic: synchronize on an observable event, never sleep longer or loosen the
  assertion. For (b), stop and record the Contract finding on this issue before changing behavior.
- DJ11: make the notifier/PG dependency explicit at test start (for example, ensure the required
  application or process is started and ready) so the start is deterministic.
- Change only `pieces/assembly/durable-job/test/**`, `test/support/**` and, if (b) is accepted
  in review, the minimal durable-job source. No change to mix.exs, mix.lock, provider pins,
  workflows or other Pieces. Do not add retries or skip tags to hide failures.
- Add this task's source body at `tasks/ELZ-035-durable-job-check-stability.md`.

## Acceptance

- [ ] The reproduction command and failure rate before the change are recorded.
- [ ] After the change, the same reproduction runs at least 20 times with no DJ11 or DJ13 failure;
      the exact command and counts are recorded.
- [ ] Each existing DJ assertion is unchanged or strictly stronger; any changed assertion is
      listed with its reason.
- [ ] Full `mix check` passes; symbolic CI passes on the PR head and on the merge commit.
- [ ] Independent review of the actual diff.

## Evidence and limits

Repeated runs ground only the listed reproduction. They are not a proof of absence of other
timing faults. Oban and Postgrex behavior are upstream contracts at the pinned versions.

## Out of scope

The `runtime/host` copied-consumer failure "module Cure.Compiler is not available" seen once on
a shared machine (PR #58 comment 6697178071) unless it is shown to have the same cause; new
durable-job features; CI runner changes (ELZ-034).
