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
2. **Jobs (decided: shape A).** The name `check-hosted` stays with a final aggregator job that `needs:` the work jobs. The aggregator runs with `if: always()` and **fails explicitly** when any needed job is not `success` (a skipped, cancelled or failed needed job fails it), so it is never skipped and branch protection sees a real failure; it prints the full marker only when all work jobs are green. The work jobs are new (`check-root`, `check-consumers-db`, `check-consumers`). Branch protection keeps requiring `check-hosted` and `gleam-hosted` and needs no change. The guard pins the aggregator's `if: always()`, its `needs:` list and its explicit failure step. (Shape B, requiring the new job names in protection, was not chosen: a missed protection step leaves `main` unprotected.) **Decided during the implementation: a fifth job, `check-plan`.** A job-level `if:` can read only `needs`, so the one decision for the three work jobs (skip decision of ELZ-058, documentation-only classification of ELZ-071) is made once in `check-plan`, which writes the output `run`. The plan job also runs the claims check, the guard and its tests, the roadmap views and the docs-only check, so a documentation-only run starts two jobs and no service container. The evidence unit is the five jobs `check-plan`, `check-root`, `check-consumers-db`, `check-consumers`, `check-hosted`.
3. **Shared caches.** The dependency and `_build` cache and the S3 binary cache are restored by every job and saved by exactly one job (the root job), so that jobs do not race to save the same key. Each job runs `mix setup` from the cache. On a cold cache every job compiles on its own (see Limits).
4. **Per-job services.** Each job that needs PostgreSQL or the S3 test server starts its own (a job-level `services:` block, as today); jobs that need neither do not start them.
5. **Markers per job.** Each work job prints its own marker line (for example `ELZOO ROOT SUITE PASSED`, `ELZOO CONSUMERS PASSED`) from one pinned step; the aggregator prints `ELZOO CHECK PASSED` only after the `needs:` result is success for all of them. The guard allows each marker on one line of the workflow only (as for `ELZOO DOCS-ONLY CHECK PASSED` in ELZ-071).
6. **Evidence unit.** `scripts/merge-queue.py` and `scripts/ci-skip-decision.py` accept a run only when its job list is exactly the reviewed set: each job once, executed, successful, on a hosted runner (group `GitHub Actions`, label `ubuntu-24.04`, runner name `GitHub Actions <n>`), with a green identity step and its marker line; any missing, skipped, duplicated, extra or red job means no evidence. One attempt must hold all jobs and every executed job must have started at or after the run's `run_started_at`: a partial re-run attempt lists the green jobs of the earlier attempt again with new job IDs, the new `run_attempt` and their old `started_at` (answer to open question 1), so it is no evidence and the safe rule is a full re-run. The job set, not one job, is what `ELZOO MERGE EVIDENCE` and `ELZOO PUSH CHECK SKIPPED` name (all job IDs).
7. **Guard.** `scripts/check-ci-runners.py` pins the job list and order, each job's `if`, `runs-on`, header, `needs:`, permissions, services, steps and step-level conditions, token exposure and markers, and rejects any additional job (the rule today is exactly one job per workflow).
8. **Tests.** First, before any move, an assertion for the aggregate consumer's limits (`@tag timeout: 1_200_000` and `inner_timeout: 300_000`) next to the existing per-ID limit assertions of the selection test in `test/export_test.exs` (a new assertion; no existing assertion changes), so that the split keeps every limit. New negative controls for the guard (each pin), the queue and the skip decision (a missing, skipped, red, cancelled, duplicated or extra job; a job on another runner; a missing or forged marker; a partial attempt), and the selection test of item 1. Existing tests change only where they pin "exactly one job" or the old step list; every such edit is listed in the pull request and approved by the coordinator.
9. **Docs.** `docs/development/10-symbolic-ci.md` (job set, evidence unit, caches, measurement table), `AGENTS.md` (acceptance step 3).

## Acceptance

- [x] **Before** (rule change of the coordinator, 2026-11-09: the 43 recorded full hosted runs, not three new runs; no cold-cache run): "Result of the measurement" below. It settles the two figures of the measured basis (aggregate consumer: median 356 s, range 233 to 431 s).
- [x] **After** (the prototype, warm, one run at a time): "Result of the measurement" below, per job and as wall time from the first job start to the last job end, with the runner time. The decision used the sequential stopping rule of the coordinator.
- [x] Decision rule (accepted by the coordinator, 2026-11-09): adopt the shape only if the median warm wall time falls by at least 25 percent and the sum of runner minutes rises by less than 60 percent; otherwise close the task with the measurements and no change. **Result: -48.6 percent wall time, +12.4 percent runner time: adopt.**
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


## Result of the measurement (2026-11-09)

**BEFORE** (single job `check-hosted`; the 43 successful full-mode runs of `symbolic-check.yml` on the hosted lane since 00:00 WIB; times in seconds; created time in UTC; "tree" is the head SHA of the run). Median (range): job wall 1250 (819 to 1504); `Run mix check` 1166 (766 to 1389); root suite stage 1058 (695 to 1275); ExUnit async 264 (158 to 358), sync 802 (538 to 967); aggregate consumer 356 (233 to 431). Two more sequential runs on `measure/ELZ-073-before` (= `main` b076432): run 42581604081 1020 s and run 42583484887 1348 s (not in the table; the table was fixed before run 2 ended).

| run | created (UTC) | tree | event/branch | job s | Run mix check s | mix setup s | root suite s | async s | sync s | aggregate s |
|---|---|---|---|---|---|---|---|---|---|---|
| 42518583815 | 11-08 20:08 | 6fd39be | pull_request-task/ELZ-028 | 1339 | 1265 | 5 | 1133 | 354 | 778 | 350 |
| 42520133125 | 11-08 20:26 | 48462d4 | workflow_dispatch-main | 1118 | 1048 | 2 | 932 | 280 | 652 | 290 |
| 42520214059 | 11-08 20:27 | 2c69308 | workflow_dispatch-task/ELZ-067 | 1345 | 1267 | 3 | 1134 | 358 | 776 | 343 |
| 42521924097 | 11-08 20:47 | 48462d4 | workflow_dispatch-main | 819 | 766 | 2 | 695 | 158 | 538 | 233 |
| 42522189688 | 11-08 20:50 | 0fc9bd7 | workflow_dispatch-task/ELZ-027 | 1312 | 1211 | 37 | 1102 | 280 | 822 | 369 |
| 42522646898 | 11-08 20:56 | 340e92a | pull_request-task/ELZ-029 | 1102 | 1041 | 2 | 948 | 194 | 754 | 338 |
| 42523673343 | 11-08 21:08 | 0470275 | pull_request-task/ELZ-068 | 1211 | 1149 | 3 | 1038 | 254 | 784 | 354 |
| 42524135823 | 11-08 21:13 | f176e92 | workflow_dispatch-task/ELZ-027 | 1297 | 1204 | 37 | 1094 | 279 | 815 | 364 |
| 42524777153 | 11-08 21:21 | f6008b5 | pull_request-task/ELZ-062 | 872 | 817 | 3 | 746 | 166 | 579 | 252 |
| 42525156796 | 11-08 21:25 | a6a4cc4 | pull_request-task/ELZ-029 | 963 | 907 | 3 | 833 | 170 | 663 | 302 |
| 42525247997 | 11-08 21:26 | 8c2a082 | pull_request-task/ELZ-028 | 865 | 810 | 2 | 737 | 169 | 568 | 246 |
| 42526079714 | 11-08 21:36 | 2fc05e4 | workflow_dispatch-task/ELZ-031 | 1331 | 1231 | 39 | 1118 | 287 | 830 | 369 |
| 42526794473 | 11-08 21:45 | 6d07552 | pull_request-task/ELZ-028 | 943 | 865 | 25 | 789 | 181 | 608 | 265 |
| 42527909718 | 11-08 21:59 | 4d48da3 | pull_request-task/ELZ-029 | 1035 | 955 | 27 | 874 | 187 | 687 | 302 |
| 42528052986 | 11-08 22:00 | 91df9a3 | workflow_dispatch-task/ELZ-068 | 1320 | 1215 | 38 | 1103 | 282 | 820 | 366 |
| 42530190341 | 11-08 22:25 | 053906b | workflow_dispatch-task/ELZ-062 | 1264 | 1166 | 36 | 1056 | 264 | 792 | 352 |
| 42533681836 | 11-08 23:08 | e49fefa | pull_request-task/ELZ-028 | 998 | 915 | 28 | 832 | 205 | 626 | 271 |
| 42534330839 | 11-08 23:15 | d14392e | pull_request-task/ELZ-069 | 1279 | 1214 | 2 | 1100 | 281 | 819 | 364 |
| 42534554911 | 11-08 23:18 | 6a9fe22 | pull_request-task/ELZ-029 | 1388 | 1290 | 38 | 1181 | 284 | 896 | 401 |
| 42536154158 | 11-08 23:38 | 051e930 | pull_request-task/ELZ-069 | 1238 | 1179 | 2 | 1066 | 264 | 802 | 356 |
| 42537494430 | 11-08 23:55 | 6a9fe22 | workflow_dispatch-task/ELZ-029 | 1164 | 1102 | 2 | 1008 | 226 | 782 | 348 |
| 42538072818 | 11-09 00:02 | b50e1cb | pull_request-task/ELZ-028 | 1324 | 1265 | 3 | 1153 | 291 | 862 | 386 |
| 42541633497 | 11-09 00:42 | c1e88a8 | workflow_dispatch-task/ELZ-069 | 1187 | 1078 | 40 | 987 | 222 | 765 | 338 |
| 42544622452 | 11-09 01:15 | e32a7c2 | pull_request-task/ELZ-070 | 1361 | 1299 | 3 | 1185 | 287 | 898 | 403 |
| 42546614345 | 11-09 01:38 | 043832a | pull_request-task/ELZ-028 | 1451 | 1389 | 3 | 1275 | 308 | 967 | 431 |
| 42546837682 | 11-09 01:40 | cb2f4a1 | pull_request-task/ELZ-070 | 1140 | 1084 | 3 | 993 | 228 | 765 | 337 |
| 42548636231 | 11-09 02:01 | cb2f4a1 | workflow_dispatch-task/ELZ-070 | 1003 | 915 | 33 | 839 | 182 | 657 | 286 |
| 42552278647 | 11-09 02:41 | 396fbb1 | pull_request-task/ELZ-072 | 1407 | 1291 | 51 | 1181 | 284 | 897 | 400 |
| 42554519140 | 11-09 03:06 | 396fbb1 | workflow_dispatch-task/ELZ-072 | 1440 | 1315 | 55 | 1198 | 296 | 902 | 401 |
| 42555940045 | 11-09 03:21 | 2eb29b8 | pull_request-task/ELZ-059 | 1124 | 1065 | 2 | 974 | 218 | 755 | 333 |
| 42556924695 | 11-09 03:32 | 2dcfd2b | pull_request-task/ELZ-028 | 1237 | 1172 | 2 | 1079 | 232 | 847 | 379 |
| 42559260968 | 11-09 03:58 | 2dcfd2b | workflow_dispatch-task/ELZ-028 | 1494 | 1383 | 54 | 1267 | 304 | 963 | 430 |
| 42560987398 | 11-09 04:17 | 774d206 | pull_request-task/ELZ-059 | 1337 | 1276 | 3 | 1164 | 272 | 891 | 398 |
| 42563217144 | 11-09 04:41 | 479fdf3 | pull_request-task/ELZ-059 | 1027 | 954 | 24 | 875 | 193 | 682 | 298 |
| 42567045270 | 11-09 05:23 | 2359f3d | pull_request-task/ELZ-071 | 1473 | 1358 | 52 | 1245 | 295 | 950 | 425 |
| 42571174103 | 11-09 06:07 | 7306080 | pull_request-task/ELZ-074 | 996 | 910 | 31 | 838 | 178 | 660 | 288 |
| 42573066847 | 11-09 06:26 | 949be86 | pull_request-task/ELZ-074 | 1445 | 1374 | 2 | 1258 | 298 | 960 | 431 |
| 42573215720 | 11-09 06:28 | ffd19a4 | pull_request-task/ELZ-071 | 1219 | 1152 | 3 | 1058 | 233 | 825 | 369 |
| 42575794829 | 11-09 06:53 | c92554f | pull_request-task/ELZ-074 | 1433 | 1368 | 2 | 1254 | 300 | 954 | 425 |
| 42578901373 | 11-09 07:22 | b076432 | workflow_dispatch-main | 1504 | 1376 | 52 | 1261 | 300 | 961 | 428 |
| 42578912167 | 11-09 07:22 | b076432 | workflow_dispatch-main | 1250 | 1139 | 41 | 1047 | 234 | 812 | 357 |
| 42578922661 | 11-09 07:22 | b076432 | workflow_dispatch-main | 1277 | 1143 | 44 | 1055 | 229 | 825 | 359 |
| 42581604081 | 11-09 07:48 | b076432 | workflow_dispatch-measure/ELZ-073-before | 1020 | 961 | 2 | 886 | 191 | 695 | 304 |

**AFTER** (prototype branch `measure/ELZ-073-after`, never merged; exact cache hit; one run at a time). Stopping condition that fired: both wall times under 790 s after two runs.

| Run | Wall | `check-root` | `check-consumers-db` | `check-consumers` | `check-hosted` | Runner time |
| --- | --- | --- | --- | --- | --- | --- |
| 42587366903 | 586 | 579 | 543 | 201 | 4 | 1327 |
| 42588632529 | 698 | 692 | 488 | 301 | 3 | 1484 |
| 42590080625 (after the decision, not used) | 704 | 667 | 615 | 199 | 4 | 1485 |

Median of the two decision runs: wall 642 s against 1250 s (-48.6 percent; the threshold was 938 s); runner time 1406 s against 1250 s (+12.4 percent; in minutes rounded up per job 26.5 against 21, +26.2 percent). Decision: adopt shape A. Invalid run 42586258340 (cancelled) stopped at `check-claims.py` because the measurement branch held the claim marker; fixed at 00e0af7. Limits: AFTER n = 2 for the decision; the BEFORE sample spans a day and several trees; warm caches only; the prototype had no plan job and left out two guard steps of about 7 s, so the run of the pull request itself is recorded in the guide ("Parallel jobs (ELZ-073)").

## Open questions (answered during the implementation)

1. How does the API list the jobs of attempt N after a partial re-run (`actions/runs/{id}/attempts/{n}/jobs`)? **Answered by a measurement (run 42590080625, attempt 2, only the failed job re-run):** the listing of attempt 2 holds all five jobs; the green jobs of attempt 1 appear again with new job IDs and the new `run_attempt`, but with their old `started_at`. The evidence rule therefore compares each executed job's `started_at` with the run's `run_started_at`.
2. Closed by construction (shape A: the aggregator is never skipped and fails explicitly when a needed job is not green). **Verified on the measurement run:** in AFTER run 1 (42587366903) `check-root` failed and `check-hosted` failed, it was not skipped.
3. Is the synchronous part of the root suite (`async: false`) really independent of the consumer tests (shared files, ports, the database)? **Answered:** the three parts ran side by side without interference in all three AFTER runs; the only failures were two root tests that read the workflow file (expected on the prototype shape; updated in the real change).

## Sequence of pull requests (decided by the coordinator, 2026-11-09): two pull requests for one ID, on purpose

1. **Task copy (documentation only).** After ELZ-071 (PR #135) is merged, `task/ELZ-073` is claimed from the new `main`, the claim marker is removed in a later commit, and the pull request adds only `tasks/ELZ-073-parallel-hosted-jobs.md` (this body). It is the first documentation-only pull request and the **live observation of ELZ-071 acceptance item 1** (#131): a short `check-hosted` run (run ID and minutes) and a queue merge on the docs-only marker. When it is merged, the branch is deleted.
2. **Implementation.** The implementation pull request claims `task/ELZ-073` again (a deleted branch may be claimed again), after the first pull request is merged and the branch is deleted. It does not start before ELZ-071 is merged and the first pull request is merged.

The two pull requests carry the same ID because the task copy is documentation of this task; this is a deliberate exception to "one task, one branch, one pull request" and is recorded here so that the history is not read as a mistake.

