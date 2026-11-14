# ELZ-202 — `JobRun.retry_decision/3` refuses an unknown class also at attempt 0

- Dependencies: ELZ-010
- Output: none. A repair of the ready Piece `workflow/state-machine` that restores its Contract; the Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/workflow/state-machine/lib/**` and `pieces/workflow/state-machine/test/**` only. No `piece.json`, no README, no index file.

The automated review of pull request #54 found that the clause for
attempt 0 has no guard on the class.

Facts checked on `main` (confirm each when you start):

- `retry_decision(_policy, 0, _class)` (`lib/elzoo/job_run.ex`, about
  line 87) returns `{:ok, :retry}` for every class. The next clause
  (about 89 to 90) has the guard `class in [:retryable, :permanent]`,
  and the last one returns `{:error, :invalid_class}`.
- The README (about 24 to 25) names the classes `:retryable` and
  `:permanent` only.
- The test "retry decisions come from the unchanged ELZ-006 policy"
  (`test/elzoo/job_run_test.exs`, about 138 to 145) checks an unknown
  class at attempt 1 only.
- The two callers in `assembly/durable-job` pass one of the two classes.

## Task

Give the clause for attempt 0 the guard `class in [:retryable,
:permanent]`. Both classes keep `{:ok, :retry}` at attempt 0. Change
nothing else. Contract unchanged.

## Acceptance

- **`unknown_class_at_zero`** (new assertions in the existing test of
  the retry decisions): `retry_decision(policy, 0, :dispatched)` and
  `retry_decision(policy, 0, nil)` return `{:error, :invalid_class}`;
  `retry_decision(policy, 0, :retryable)` and
  `retry_decision(policy, 0, :permanent)` return `{:ok, :retry}`.
- Every existing test of the Piece passes unchanged.
- Negative control, by a temporary edit that is reverted: without the
  guard the first assertion fails.
- `mix test pieces/workflow/state-machine/test`, then
  `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0. The small gate also runs the ready Pieces
  that depend on this one.
- One independent review, risk low.

## Not in scope

The policy operand at attempt 0, the Cure laws, `step/4`,
`assembly/durable-job`, and any other Piece.
