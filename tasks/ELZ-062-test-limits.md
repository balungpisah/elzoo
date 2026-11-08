# ELZ-062 — Raise the per-test limit of two slow tests to 300 s, measured

- Phase: P0 harness (tests: `pieces/workflow/approval/test/elzoo/approval_test.exs`, `test/export_test.exs`;
  `docs/development/10-symbolic-ci.md`)
- Catalogue IDs: none
- Dependencies: ELZ-058 (#96) merged first (same docs section; no code overlap). Before or alongside ELZ-059 (#99):
  ELZ-059's staggered `main` runs and push runs are meant to be able to land on `contabo-elzoo-1`.
- Review: independent review required (protected test boundary).
- Owner approval (2026-11-08, "1.", relayed by the coordinator): raise the per-test limit of the two tests that time
  out on `contabo-elzoo-1` to 300 s, as a small measured task, so Contabo can take the staggered full runs of
  `main` and the `main` push runs. Approval covers exactly these two limit changes; no assertion changes.

## Outcome

On `contabo-elzoo-1` two tests ran into the 120 s per-test default in both runs of the current tree:
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
(`mix test --warnings-as-errors --slowest 60`) with every per-test limit raised to 900 s. Same tree, three machines:

| Test | `symbolic-elzoo` (run 42500718766, job 128792642738) | `macbook-ubuntu-elzoo-candidate` (42497402091, 128782613975) | `contabo-elzoo-1`, 8 cores (42497486307, 128782875563) |
|---|---|---|---|
| approval negative control (`approval_test.exs:177`) | 39.1 s | 45.3 s | 93.1 s |
| `assembly/durable-job` consumer (`export_test.exs:120`) | 77.6 s | 91.3 s | 128.7 s |
| `integration/sql` consumer | 18.8 s | 26.1 s | 52.8 s |
| `integration/jobs` consumer | 13.9 s | 17.0 s | 37.6 s |
| root suite | 1266.5 s | 1492.2 s | 3136.7 s |

On Contabo the approval test exceeded 120 s in the two earlier full runs (42484236992, 42492726966) and took 93.1 s in
this one: the spread on one machine is large. The measurement runs also failed two tests each that are expected on
that branch (the selection assertion of 120 s, and the test that reads `scripts/run-ci-check.sh`). Throttling: 0 in 99
host samples on Contabo; host load (1 min) peaked at 2.94; cgroup peaks 3.45 GB (symbolic), 2.75 GB (MacBook),
2.89 GB (Contabo).

## Scope

- (1) add `@tag timeout: 300_000` to the first test, with a comment giving the measured basis: it exceeded 120 s
  on `contabo-elzoo-1` in runs 42484236992 and 42492726966; its time on `symbolic-elzoo` and
  `macbook-ubuntu-elzoo-candidate` is **measured by this task** (the CI logs do not print per-test times, so a
  measurement branch runs the approval test file with `--trace` on both fast runners and, steered, on Contabo).
- (2) `Elzoo.CureConsumerCase.consumer_tests/2` takes one `timeout:` for all IDs it defines, so the three PostgreSQL
  consumers are split: `integration/sql` and `integration/jobs` keep the 120 s default; `assembly/durable-job` is
  defined by its own call with `timeout: 300_000`. The selection test "affected selection only filters the existing
  consumer tests" asserts the per-test limits (120 s for the PostgreSQL consumers in `Elzoo.ExportTest`); it is updated
  for the one new value (300 s for `assembly/durable-job`, 120 s for the others) and stays an exact assertion.
- Time limits only. No assertion, scenario or proof changes. No other limit changes (not the 120 s default in
  `test/test_helper.exs`, not the 240 s of the concurrent groups, not the inner consumer limits).
- Docs: `docs/development/10-symbolic-ci.md` Contabo status moves from "unrouted, measurement only" to "may take
  `any`-tier runs after ELZ-062 merges (the coordinator adds `backend` after the steered run passed)".

## Acceptance

- [ ] Measured times recorded for the approval test on `symbolic-elzoo`, `macbook-ubuntu-elzoo-candidate` and
      `contabo-elzoo-1` (run and job IDs), and for `assembly/durable-job` on the same machines.
- [ ] One steered `tier` = `any` run on `contabo-elzoo-1` on the PR head passes (`ELZOO CHECK PASSED`, run and job
      IDs, duration, cgroup peak, sampled CPU).
- [ ] The usual exact-head run on a fast runner passes.
- [ ] The diff touches only the two time limits, the selection assertion value, the comments and the docs.
- [ ] Independent review of the actual diff (separate agent session, reviewed SHA on the PR); the owner approval is
      quoted in the PR.

## Limits

A longer limit makes a hung test cost up to 300 s instead of 120 s before it fails; it does not prove the tests are
fast. 300 s is a margin over measured times, not a performance target. Contabo reliability over many runs is not
established by one passing run.
