# ELZ-253 — Give the complete aggregate consumer a measured 25-minute budget

- Dependencies: ELZ-251
- Release: V1B
- Output: none
- Change class: non-Piece root test-harness repair; coordinator-owned one-PR path

## Problem and scope

Reporting issue: https://github.com/balungpisah/elzoo/issues/571.

The aggregate export test has a 1,200,000 ms outer limit covering export, child compilation/tests and the successful-child consumer checks that follow. A local diagnostic completed all 2,571 inner tests: 2,570 passed and the independently tracked DataStream timing sample failed (#569). The inner test phase took approximately 1,204.6 seconds; compilation brought the observed child work to approximately 1,265 seconds. The outer test timed out first. An earlier hosted child stage took approximately 945.7 seconds. These observations establish a total-budget overrun and variability, not a performance root cause or a green aggregate run.

Increase only the aggregate outer limit to 1,500,000 ms (25 minutes), its matching partition/timeout guard assertion and the nearby explanation. This leaves approximately 235 seconds above the observed local child work; it is a measured margin, not a worst-case guarantee. The complete successful wrapper must still be exercised.

Keep the copied consumer's 300,000 ms per-test default, explicit individual test limits, complete ready-Piece selection, assertions, default filters and post-child configuration/compiler-free runtime checks unchanged. Do not skip tests, change production deadlines, serialize already serialized tests, alter providers/runners/CI job budgets, remove substantive replay scenarios, or assume a resource-contention cause. This repair does not repair or hide #569; a failing inner test remains a failing outer test.

## Acceptance and validation

1. The aggregate outer tag and its existing guard agree on exactly 1,500,000 ms. The inner default remains exactly 300,000 ms and all other limits/selections/assertions remain unchanged.
2. Run the existing partition/timeout guard and exercise the complete aggregate wrapper with disposable services, either through `MIX_ENV=test mix test test/export_test.exs:160 --include aggregate_consumer` or its actual execution in the required full/affected gate; do not repeat an unchanged passing wrapper solely for ceremony. Record actual total-wrapper and child-stage durations and the final result. A child finishing after the old outer timeout, a partial log or an independently failing child is not a passing wrapper.
3. Run `mix check --affected origin/main`, live roadmap/claims and diff checks. Keep any separately observed failure visible; do not claim a green gate from the budget change alone. Independent exact-diff review, exact-head hosted checks, ready-before-merge and the coordinator queue remain required.

## Owned paths

`test/export_test.exs`, `tasks/ELZ-253-aggregate-budget.md`, this task's no-output job row in `docs/plans/release-plan.json`, and generated plan views. No Piece Contract, implementation, other root test/helper, dependency, workflow or queue change. Publish and implement in one coordinator-owned `task/ELZ-253` PR; create the issue without `task` and use the normal API branch lock. Close this task issue and #571 after successful review and merge; leave #569 independent.
