# ELZ-073 — Parallel hosted jobs: copied consumers run beside the root suite

- Phase: P0 harness (CI; `.github/workflows/symbolic-check.yml`, `scripts/check-ci-runners.py`, `scripts/merge-queue.py`, `scripts/ci-skip-decision.py`, `scripts/run-ci-check.sh` or the `mix check` task arguments, the tests of these scripts, `docs/development/10-symbolic-ci.md`, `AGENTS.md`)
- Catalogue IDs: none
- Dependencies: ELZ-059 (#99) merged (1e12105). **ELZ-071 (#131, PR #135) must be merged first** (decision of the coordinator, 2026-11-09): this task builds on its classification step and its docs-only shape. Do not claim this task before ELZ-071 is merged. No larger runners.
- Review: independent review required (workflow, guard, queue and skip decision are protected surfaces; the evidence unit changes from one job to a job set).

## Outcome

One run of `check-hosted` is one job of 17 minutes. Its longest part, the root suite, contains the copied-consumer tests, which need no result of the other tests. This task runs the consumers in one or two further hosted jobs on the same tree, at the same time as the root suite, and makes the queue and the push-run skip treat the job set of one run as one evidence unit (all green, or no evidence). Acceptance is by measurement: wall time of one run before and after on the same tree, and the per-job timings, recorded in this task.

## Measured basis (what is known today, and what is not)

Run 42563217144 (the full-mode `pull_request` run of PR #132's head 479fdf3, dependency cache warm, 2026-11-09):

| Part | Time |
| --- | --- |
| Job, start to end (04:41:46 to 04:58:53 UTC) | 17 min 7 s |
| Before `mix check` (containers 12 s, libraries 8 s, checkout 2 s, guard and script tests 11 s, S3 binary restore 2 s, setup-beam 5 s, `mix setup` 24 s, other steps 5 s) | 69 s |
| `Run mix check` | 954 s |
| `mix check` stages: format and compile 0.2 s, ledger 5.5 s, Ash spike 66 s, registry load 5.6 s, root suite 874.8 s | |
| ExUnit of the root suite | 874.8 s, of which 193.1 s async and 681.7 s sync (798 tests) |
| Copied consumers: 27 `total` timings add up to 595.1 s | aggregate(48) 298.2 s, `assembly/durable-job` 63.5 s, the other 25 consumers 233.4 s (0.5 s to 37 s each) |

How the consumers are scheduled today (`docs/development/10-symbolic-ci.md`, "Concurrent database-free consumers"): the 23 database-free consumers run in three `async: true` modules; the three PostgreSQL consumers (`integration/sql`, `integration/jobs`, `assembly/durable-job`), the aggregate consumer, the OTP-only consumer and the plan and write tests stay in `test/export_test.exs` with `async: false`.

What this implies, as an estimate that the acceptance measurement must confirm or correct: the sync part (681.7 s) holds the aggregate (298 s) and the three PostgreSQL consumers (about 76 s). Moving only those out leaves about 300 s of sync tests; the 23 async consumers add about 233 s of consumer time spread over three modules that share the 193 s async window with the other async tests. So the root suite after the split is probably about 6 to 8 minutes, not 15 minutes, and the longest job of the new shape would be the root suite or the aggregate job, about 5 to 8 minutes plus the 1 min 10 s of job start. **Two figures of the brief do not match this run:** the aggregate consumer took 298.2 s here (the brief says about 420 s), and the root suite does not stay at about 15 minutes after the split if the consumers are taken out. Both are checked in the "before" measurement below. The cold-cache run (33 min 7 s, run 42517023581) and the warm runs (18 min 38 s, 13 min 39 s) in the "Hosted CI" table of the guide are the older reference points.

## Scope

1. **Split mechanism.** The consumers keep their names and `consumer_id` tags. Add tags (or `--only` and `--exclude` arguments to `mix test`, as the affected mode uses) so that three selections exist: the root suite without any copied consumer; the aggregate consumer with the PostgreSQL consumers (they need one disposable database, so they stay together); the database-free per-ID consumers. `mix check` with no argument stays the full check, unchanged for local use. The selection test in `test/export_test.exs` (26 per-ID tests plus the aggregate) must prove that the three selections together equal the full suite and do not overlap: a test that is in none of them, or in two, fails.
2. **Jobs (decided: shape A).** The name `check-hosted` stays with a final aggregator job that `needs:` the work jobs. The aggregator runs with `if: always()` and **fails explicitly** when any needed job is not `success` (a skipped, cancelled or failed needed job fails it), so it is never skipped and branch protection sees a real failure; it prints the full marker only when all work jobs are green. The work jobs are new (`check-root`, `check-consumers-db`, `check-consumers`). Branch protection keeps requiring `check-hosted` and `gleam-hosted` and needs no change. The guard pins the aggregator's `if: always()`, its `needs:` list and its explicit failure step. (Shape B, requiring the new job names in protection, was not chosen: a missed protection step leaves `main` unprotected.)
3. **Shared caches.** The dependency and `_build` cache and the S3 binary cache are restored by every job and saved by exactly one job (the root job), so that jobs do not race to save the same key. Each job runs `mix setup` from the cache. On a cold cache every job compiles on its own (see Limits).
4. **Per-job services.** Each job that needs PostgreSQL or the S3 test server starts its own (a job-level `services:` block, as today); jobs that need neither do not start them.
5. **Markers per job.** Each work job prints its own marker line (for example `ELZOO ROOT SUITE PASSED`, `ELZOO CONSUMERS PASSED`) from one pinned step; the aggregator prints `ELZOO CHECK PASSED` only after the `needs:` result is success for all of them. The guard allows each marker on one line of the workflow only (as for `ELZOO DOCS-ONLY CHECK PASSED` in ELZ-071).
6. **Evidence unit.** `scripts/merge-queue.py` and `scripts/ci-skip-decision.py` accept a run only when its job list is exactly the reviewed set: each job once, executed, successful, on a hosted runner (group `GitHub Actions`, label `ubuntu-24.04`, runner name `GitHub Actions <n>`), with a green identity step and its marker line; any missing, skipped, duplicated, extra or red job means no evidence. One attempt must hold all jobs: a partial re-run attempt (only the failed job re-run) is not evidence until it is shown how the API lists such an attempt (open question 1); the safe rule is a full re-run. The job set, not one job, is what `ELZOO MERGE EVIDENCE` and `ELZOO PUSH CHECK SKIPPED` name (all job IDs).
7. **Guard.** `scripts/check-ci-runners.py` pins the job list and order, each job's `if`, `runs-on`, header, `needs:`, permissions, services, steps and step-level conditions, token exposure and markers, and rejects any additional job (the rule today is exactly one job per workflow).
8. **Tests.** First, before any move, an assertion for the aggregate consumer's limits (`@tag timeout: 1_200_000` and `inner_timeout: 300_000`) next to the existing per-ID limit assertions of the selection test in `test/export_test.exs` (a new assertion; no existing assertion changes), so that the split keeps every limit. New negative controls for the guard (each pin), the queue and the skip decision (a missing, skipped, red, cancelled, duplicated or extra job; a job on another runner; a missing or forged marker; a partial attempt), and the selection test of item 1. Existing tests change only where they pin "exactly one job" or the old step list; every such edit is listed in the pull request and approved by the coordinator.
9. **Docs.** `docs/development/10-symbolic-ci.md` (job set, evidence unit, caches, measurement table), `AGENTS.md` (acceptance step 3).

## Acceptance

- [ ] **Before** (same tree, the commit just before the change, caches warm): three runs of the current single-job shape, recorded as run ID, job time, `Run mix check` seconds, root suite seconds, aggregate consumer seconds. One cold-cache run recorded once. This also settles the two figures of the measured basis.
- [ ] **After** (the same tree with the change, warm): three runs of the new shape, recorded per job (start, end, setup, test seconds) and as wall time from the first job start to the last job end; the table in the task and the guide shows both shapes side by side. Runner minutes (the sum of job times) are recorded too, since they rise.
- [ ] Decision rule (accepted by the coordinator, 2026-11-09): adopt the shape only if the median warm wall time falls by at least 25 percent (about 4 of 17 minutes) and the sum of runner minutes rises by less than 60 percent; otherwise close the task with the measurements and no change.
- [ ] One pull request run and the queue's merge on the new evidence unit (run ID, job IDs, minutes), and the first push run on the merge commit (skipped on the job set, or its own green run).
- [ ] Guard and tests pass with the negative controls; merged-test edits listed and approved; independent review of the diff (reviewed SHA on the PR); Devin findings dispositioned.
- [ ] Branch protection still requires `check-hosted` and `gleam-hosted`, and a merge through the queue is accepted by GitHub (not refused by "the base branch policy prohibits the merge").

## Limits

- Two or three jobs compile on a cold cache, each on its own: the wall time of a cold run does not rise much, but the runner minutes triple for that run. A change of `mix.lock` or `mix.exs` makes every job cold once.
- Each work job pays the job start (containers, libraries, checkout, cache restore, `setup-beam`, `mix setup`: 69 s in run 42563217144). The saving is at most the part that moves minus that start.
- If the sync tests of the root suite are the long pole after the split, a further split is a separate task. The consumers' own time limits stay exactly as they are and travel with their tests: 120 s for the sequential per-ID tests, 300 s for `assembly/durable-job` (ELZ-062), 240 s for the concurrent groups, and 1200 s with an inner limit of 300 s for the aggregate consumer (`test/export_test.exs`, `test/support/cure_consumer_case_test_helper.exs`). The selection test "affected selection only filters the existing consumer tests" asserts the per-ID limits exactly (120 s, 300 s for `assembly/durable-job`, 240 s for the concurrent groups) and counts the aggregate test (one), but it does **not** assert the aggregate's 1200 s and its inner 300 s: the implementation adds that assertion first (Scope item 8), so that a move of the aggregate test cannot lose its limits unnoticed.
- More jobs mean more chances of an infrastructure failure per run. Re-running a single failed job is not evidence for the queue (item 6).
- GitHub's limit of concurrent jobs applies and has not been measured here; two runs of one pull request overlapping (after `update-branch`) would double the jobs in flight.
- ELZ-071 (#131, PR #135) and this task change the same workflow, guard, queue and skip decision. ELZ-071 goes first (decided): this task builds on its classification step and its docs-only shape (every work job skips its heavy steps when `docs_only` is true; the aggregator accepts the docs-only shape).

## Open questions (to settle before or during the implementation)

1. How does the API list the jobs of attempt N after a partial re-run (`actions/runs/{id}/attempts/{n}/jobs`)? The queue reads one attempt; the evidence unit needs all jobs in it. **Answered by a measurement run with one job re-run, on a scratch branch, before any queue code depends on it** (decision of the coordinator).
2. Closed by construction (shape A: the aggregator is never skipped and fails explicitly when a needed job is not green). **Verify it once on the measurement run:** a scratch branch with a failing work job must show `check-hosted` as failed, not skipped.
3. Is the synchronous part of the root suite (`async: false`) really independent of the consumer tests (shared files, ports, the database)? **A result of the task:** the measurement run on the split shape answers it; a failure there is recorded, not a reason to loosen a test.

## Sequence of pull requests (decided by the coordinator, 2026-11-09): two pull requests for one ID, on purpose

1. **Task copy (documentation only).** After ELZ-071 (PR #135) is merged, `task/ELZ-073` is claimed from the new `main`, the claim marker is removed in a later commit, and the pull request adds only `tasks/ELZ-073-parallel-hosted-jobs.md` (this body). It is the first documentation-only pull request and the **live observation of ELZ-071 acceptance item 1** (#131): a short `check-hosted` run (run ID and minutes) and a queue merge on the docs-only marker. When it is merged, the branch is deleted.
2. **Implementation.** The implementation pull request claims `task/ELZ-073` again (a deleted branch may be claimed again), after the first pull request is merged and the branch is deleted. It does not start before ELZ-071 is merged and the first pull request is merged.

The two pull requests carry the same ID because the task copy is documentation of this task; this is a deliberate exception to "one task, one branch, one pull request" and is recorded here so that the history is not read as a mistake.

