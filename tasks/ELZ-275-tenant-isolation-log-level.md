# ELZ-275 — Make the tenant-isolation log test independent of the global Logger level

- Dependencies: ELZ-270

## Outcome and scope

Repair the red `main` push run 44778242170 (merge of #631, classified
`defect` on issue #98) at its cause in the test of `state/tenant-isolation`.
The Piece's Contract, library code, README, `piece.json`, Piece ID and
catalogue/ready entry stay unchanged. This is a coordinator one-PR repair:
publication and implementation share one `task/ELZ-275` pull request.

Owned implementation path:

- `pieces/state/tenant-isolation/test/elzoo/tenant_isolation_test.exs`

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`. The change touches no shared path, manifest,
README, dependency, pin, timeout or budget.

## Observed defect

The test "the helper's set and clear queries are not logged by a logging Repo
(log: false)" (`tenant_isolation_test.exs:690`) fails in check-root and
check-aggregate of run 44778242170 at `assert log =~ "control-log-probe"` with
an empty captured log. It passes alone and in the Piece's own run.

The test starts a Repo with `log: :info` and runs a control query that must be
logged. Under the fixed seed of the full check, earlier test modules leave the
global Logger level at `:warning` (for example the `on_exit` of
`pieces/integration/ai-text-openai/test/elzoo/ai_text_openai_test.exs`), so
the `:info` control entry is dropped and the test's positive control fails.
The `refute` assertions it guards are unaffected.

## Required behavior

The test sets the global Logger level to `:info` for its own run and restores
the previous level on exit; the module is `async: false`. Keep every
assertion, including the positive control; add no skip, tag, retry or sleep.

## Acceptance and evidence

1. Show the unchanged test fails when the global level is `:warning` before
   it runs (temporary edit), and the fixed test passes in the same condition.
2. Negative control: with the helper's set query logged (temporary removal of
   `log: false` in the library), the fixed test fails on its `refute`.
3. Whole Piece tests, `git diff --check`, `scripts/ci-change-class.py`, and
   the index step 3 checks.
4. One independent review; exact-head hosted check green; mark ready. The
   coordinator merges under the wave-1 advance approval for a classified
   `defect` repair.

The intermittent `integration/token-verify` secrecy test failure of the same
run (a global captured log that includes a concurrent module's crash log) is
not in scope; it is its own task.
