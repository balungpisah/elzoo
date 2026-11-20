# ELZ-287 — Make the run-engine test wait predicates total over a running slot

- Dependencies: ELZ-127

## Outcome and scope

Repair the intermittent `assembly/run-engine` test failure reported in issue
#660 at its cause, in the Piece's tests. The Piece's Contract, library code,
README, `piece.json`, Piece ID and catalogue/ready entry stay unchanged. This
is a coordinator one-PR repair: publication and implementation share one
`task/ELZ-287` pull request.

Owned implementation paths:

- `pieces/assembly/run-engine/test/elzoo/*.exs`
- `pieces/assembly/run-engine/test/support/run_engine_test_helper.exs`

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `LEDGER.md`,
`docs/plans/views.md` and `docs/plans/dependencies.mmd`. The change touches
no shared path, manifest, README, dependency, pin, timeout, poll budget or
sleep interval.

## Observed defect

The test "v2 schema-map binding selects its result schema and rejects a
mismatched result" (`run_engine_v2_test.exs:819`) failed in check-root of
hosted run 44821383173 with `KeyError: key :outcome not found` on a slot
`%{phase: :running, ...}`. The run passed when it was rerun on the same head.

`TestHelper.wait_for/3` polls `RunEngine.status/1` and calls the predicate on
each view. The predicate `&(&1.slots[{1, 0}].outcome == "completed")` uses
strict field access. A slot that is still running has no `:outcome` key, so
a poll that sees the slot before it completes raises instead of returning
false.

## Required behavior

Every `wait_for` predicate in the run-engine tests returns a boolean for
every view the engine can report while it waits: a missing slot, a running
slot, or a completed one. Fix the one in #660, and any other predicate of the
same shape that a search of the owned test files finds. Each final assertion
after the wait keeps its strict match, so a wrong committed state still
fails. Don't make `wait_for` rescue predicate errors, and add no retry, skip,
tag, sleep, budget or timeout change.

## Acceptance and evidence

1. Reproduce: a temporary edit makes the view in the #660 test show the
   running slot first. The unchanged predicate raises `KeyError`, and the
   fixed one waits and passes.
2. Negative control: a temporary edit that makes the engine commit a
   different outcome makes the fixed test fail on its final assertion.
3. The whole Piece's tests with `--repeat-until-failure`, the small gate
   (`mix check --piece`), `git diff --check`, `scripts/ci-change-class.py`
   and the index step 3 checks.
4. One independent review, a green exact-head hosted check, and the PR
   marked ready. The coordinator merges on a green `main`, and the PR closes
   #660.
