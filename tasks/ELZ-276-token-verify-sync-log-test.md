# ELZ-276 — Run the token-verify tests synchronously so their empty-log check sees only their own logs

- Dependencies: ELZ-268

## Outcome and scope

Repair the intermittent `integration/token-verify` failure of the red `main`
push run 44778242170 (classified `defect` on issue #98) at its cause in the
Piece's test module. The Piece's Contract, library code, README,
`piece.json`, Piece ID and catalogue/ready entry stay unchanged. This is a
coordinator one-PR repair: publication and implementation share one
`task/ELZ-276` pull request.

Owned implementation path:

- `pieces/integration/token-verify/test/elzoo/token_verify_test.exs`

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`. The change touches no shared path, manifest,
README, dependency, pin, timeout or budget.

## Observed defect

The test "secrecy a Need that raises with the token or secret leaks nothing"
(`token_verify_test.exs:847`) failed in check-aggregate of run 44778242170 at
`assert log == ""`. The captured log was a GenServer crash report from
`Elzoo.UnitAdapterTest`, which ran at the same time.

`Elzoo.TokenVerifyTest` is `async: true`, and its `run/2` helper asserts that
the log captured during each verification is empty. ExUnit 1.20 documents
that `capture_log` in an async module can capture other tests' messages, so
the empty-log assertion depends on what other modules log at the same time.

## Required behavior

The module runs `async: false`, so `capture_log` captures only its own
tests' logs. Keep every assertion, including the empty-log check; add no
skip, tag, retry, sleep or log filter.

## Acceptance and evidence

1. Reproduce: with a temporary async module that logs errors during the
   token-verify run, the unchanged module fails on `assert log == ""`. With
   the fix, the same pairing passes.
2. Negative control: a temporary log line in the library's verification
   path makes the fixed tests fail on their empty-log check.
3. Whole Piece tests with `--repeat-until-failure`, `git diff --check`,
   `scripts/ci-change-class.py`, and the index step 3 checks.
4. One independent review; exact-head hosted check green; mark ready. The
   coordinator merges once `main` permits it: on a green `main`, or as the
   classified `defect` repair under the wave-1 advance approval.

Three other async Piece modules (`integration/encryption`,
`integration/secrets`, `integration/egress-policy`) use the same empty-log
pattern. They are not in scope; they get their own task if needed.
