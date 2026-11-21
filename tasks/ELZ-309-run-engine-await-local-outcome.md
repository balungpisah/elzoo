# ELZ-309 — Wait for a local_work outcome before the run-engine tests read it

- Dependencies: ELZ-287

## Outcome and scope

Repair the intermittent `assembly/run-engine` test failure reported in issue
#716 at its cause, in the Piece's tests. The Piece's Contract, library code,
README, `piece.json`, Piece ID and catalogue/ready entry stay unchanged. This
is a coordinator one-PR test-only repair (AGENTS.md section 1): publication
and implementation share one `task/ELZ-309` pull request.

Owned implementation paths:

- `pieces/assembly/run-engine/test/elzoo/*.exs`
- `pieces/assembly/run-engine/test/support/run_engine_test_helper.exs`

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `LEDGER.md`,
`docs/plans/views.md` and `docs/plans/dependencies.mmd`. The change touches
no shared path, manifest, README, dependency, pin, timeout, poll budget or
sleep interval.

## Observed defect

The test "omitted and explicit v1 preserve native configuration and recorded
bytes" (`run_engine_v2_test.exs:992`) failed at line 1018 in the aggregate
consumer of hosted run 44907924901 (check-aggregate) with `KeyError: key
:outcome not found` on a slot `%{kind: "local_work", phase: :running, ...}`.
The change under test touched no executable path.

The test calls `RunEngine.input/4`, gets `{:ok, :applied}`, and then reads
`view(engine).slots[{1, 0}].outcome` at once. In `run_engine.ex`,
`dispatch/3` for `"local_work"` starts the work outside the engine. The work's
result comes back later as a `:durable_unit_input` message, which the engine
commits as a separate protocol input. So `{:ok, :applied}` for the start input
does not mean the local work has completed. Under load the view can still show
the slot running. ELZ-287 made the `wait_for` predicates total; this site has
no wait at all.

## Required behavior

Each test assertion that reads the terminal outcome of a slot whose
completion arrives as a later engine input waits for that completion first,
with `TestHelper.wait_for/3` and a predicate that returns a boolean for a
missing, running or completed slot (as ELZ-287 requires). The final
assertion after the wait keeps its strict match, so a wrong committed
outcome still fails. Fix lines 1017 and 1018. Fix any other direct `view/1`
read of the same shape that a search of the owned test files finds: a read
with no wait, right after an input whose slot completes asynchronously. Decide
from the engine code which reads are of that shape, and list each one you
change or leave in the PR body with the reason. Do not make `wait_for` rescue
predicate errors. Add no retry, skip, tag, sleep, budget or timeout change.
Leave reads whose outcome the engine commits within the call that returns.

## Acceptance and evidence

1. Reproduce: a temporary edit delays the local work's completion input in
   the #716 test. The unchanged read raises `KeyError`, and the fixed test
   waits and passes.
2. Negative control: a temporary edit that makes the engine commit a
   different outcome for the local work makes the fixed test fail on its
   final assertion.
3. The whole Piece's tests with `--repeat-until-failure`, the small gate
   (`mix check --piece`), `git diff --check`, `scripts/ci-change-class.py`
   and the index step 3 checks.
4. One independent review, a green exact-head hosted `check-piece`, and the
   PR marked ready. The coordinator merges on a green `main`, and the PR
   closes #716.
