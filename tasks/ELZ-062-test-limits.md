# ELZ-062 — Raise the per-test limit of two slow tests to 300 s, measured

- Phase: P0 harness (tests: `pieces/workflow/approval/test/elzoo/approval_test.exs`, `test/export_test.exs`;
  `docs/development/10-symbolic-ci.md`)
- Catalogue IDs: none
- Dependencies: ELZ-058 (#96) and ELZ-066 (#115) merged (same docs file; no code overlap). The Contabo runner this task
  was written for was unregistered at the flip on 2026-11-09; the evidence is now a hosted run (see "Hosted
  measurement").
- Review: independent review required (protected test boundary).
- Owner approval (2026-11-08, "1.", relayed by the coordinator): raise the per-test limit of the two tests that time
  out on the slow VPS runner to 300 s, as a small measured task, so Contabo can take the staggered full runs of
  `main` and the `main` push runs. Approval covers exactly these two limit changes; no assertion changes.
- Coordinator decision (2026-11-09): decision rule for the changed situation: if both tests stay under 60 percent of
  120 s (72 s) on the hosted runner, the task closes with no code change and a measurement record; otherwise the PR raises
  only these two limits to 300 s.

## Outcome

On the slow VPS runner two tests ran into the 120 s per-test default in both runs of the current tree:
run 42484236992 (5-core cap) and run 42492726966 (8-core cap, warm cache): 640/642 passed each time. They pass on
the fast runners. The re-test with all 8 cores showed that the CPU cap was not the limit; per-thread speed is
(root suite 2243.7 s and 2228.9 s). Contabo is unrouted (no `backend` label) until this task decides otherwise.

1. `pieces/workflow/approval/test/elzoo/approval_test.exs:177` "negative control: dropping g_self from the gate
   list is rejected inside self_approval_refused" (a Cure proof check; stack in `Cure.Core.Normalise` and
   `Cure.Core.Conv`).
2. `test/export_test.exs:120` the PostgreSQL consumer `assembly/durable-job` (consumer step; `System.cmd`).
   Measured on the fast runners: 71.2 s and 83.4 s (`ELZOO TIMING consumer=assembly/durable-job total`).

## Measured basis (done on branch `measure/ELZ-062`, never merged)

CI logs print no per-test times, so a measurement branch ran the full root suite as `mix check` does in full mode
(`mix test --warnings-as-errors --slowest 60`) with the default per-test limits raised to 900 s. Same tree, three machines:

| Test | the first fast runner (run 42500718766, job 128792642738) | the second fast runner (42497402091, 128782613975) | the slow VPS runner, 8 cores (42497486307, 128782875563) |
|---|---|---|---|
| approval negative control (`approval_test.exs:177`) | 39.1 s | 45.3 s | 93.1 s |
| `assembly/durable-job` consumer (`export_test.exs:120`) | 77.6 s | 91.3 s | 128.7 s |
| `integration/sql` consumer | 18.8 s | 26.1 s | 52.8 s |
| `integration/jobs` consumer | 13.9 s | 17.0 s | 37.6 s |
| root suite | 1266.5 s | 1492.2 s | 3136.7 s |

On Contabo the approval test exceeded 120 s in the two earlier full runs (42484236992, 42492726966) and took 93.1 s in
this one: the spread on one machine is large. The measurement runs also failed two tests each that are expected on
that branch (the selection assertion of 120 s, and the test that reads `scripts/run-ci-check.sh`). Throttling: 0 in 99
host samples on Contabo; host load (1 min) peaked at 2.94; cgroup peaks 3.45 GB (machine A), 2.75 GB (machine B),
2.89 GB (Contabo).

## Hosted measurement (2026-11-09)

The same measurement branch (`measure/ELZ-062`, merged with `main` at 48462d4, never merged back; the default per-test limits
900 s, the explicit tags unchanged, `mix test --warnings-as-errors --slowest 60`) ran once on the GitHub-hosted runner: run 42522317222, job
128858289534, 20:52:35Z to 21:15:27Z (rule input, same tree as the three machines above, newer `main`; line numbers are those of the measurement commit).

| Test | Hosted `ubuntu-24.04` | Share of the 120 s default |
|---|---|---|
| approval negative control (`approval_test.exs:177`) | 40.8 s | 34 percent |
| `assembly/durable-job` consumer (`export_test.exs:120`) | 79.0 s (inner `consumer_mix_test` 71.2 s; 74.8 s, 67.5 s and 61.9 s in the full hosted runs 42517023581, 42520133125 and 42521924097) | 66 percent |
| `integration/sql` consumer | 19.0 s | 16 percent |
| `integration/jobs` consumer | 14.9 s | 12 percent |
| root suite | 1307.8 s (504.7 s async, 803.1 s sync) | |

The run passed 640 of 642 tests; the two failures are the ones expected on that branch (the selection test's 120 s
expectation and the test that reads `scripts/run-ci-check.sh`). By the decision rule the approval test stays under the
line (40.8 s of 72 s) and the durable-job test does not (79.0 s above 72 s), so the PR raises the two limits to 300 s:
the margin of the durable-job test is 41 s on a runner whose full-suite time varied from 695 s to 1139 s on one commit.

## Scope

- (1) add `@tag timeout: 300_000` to the first test, with a comment giving the measured basis: it exceeded 120 s
  on the slow VPS runner in runs 42484236992 and 42492726966; its time on the first fast runner and
  the second fast runner is **measured by this task** (the CI logs do not print per-test times, so a
  measurement branch runs the approval test file with `--trace` on both fast runners and, steered, on Contabo).
- (2) `Elzoo.CureConsumerCase.consumer_tests/2` takes one `timeout:` for all IDs it defines, so the three PostgreSQL
  consumers are split: `integration/sql` and `integration/jobs` keep the 120 s default; `assembly/durable-job` is
  defined by its own call with `timeout: 300_000`. The selection test "affected selection only filters the existing
  consumer tests" asserts the per-test limits (120 s for the PostgreSQL consumers in `Elzoo.ExportTest`); it is updated
  for the one new value (300 s for `assembly/durable-job`, 120 s for the others) and stays an exact assertion.
- Time limits only. No assertion, scenario or proof changes. No other limit changes (not the 120 s default in
  `test/test_helper.exs`, not the 240 s of the concurrent groups, not the inner consumer limits).
- Docs: `docs/development/10-symbolic-ci.md` records the hosted measurement and the decision rule; the Contabo status
  stays history (the runner is unregistered).

## Acceptance

- [x] Measured times recorded for the approval test and for `assembly/durable-job` on the first fast runner,
      the second fast runner, the slow VPS runner (run and job IDs, above) and the hosted runner (run 42522317222,
      job 128858289534).
- [ ] The exact-head full run on the PR head passes on the hosted lane (`ELZOO CHECK PASSED`, run and job IDs).
      (The steered Contabo run of the first draft is dropped: the runner is unregistered.)
- [ ] The diff touches only the two time limits, the selection assertion value, the comments and the docs.
- [ ] Independent review of the actual diff (separate agent session, reviewed SHA on the PR); the owner approval is
      quoted in the PR.

## Limits

A longer limit makes a hung test cost up to 300 s instead of 120 s before it fails; it does not prove the tests are
fast. 300 s is a margin over measured times, not a performance target. The hosted figures come from one run of the
measurement branch; the full-suite time on one hosted commit varied from 695 s to 1139 s.
