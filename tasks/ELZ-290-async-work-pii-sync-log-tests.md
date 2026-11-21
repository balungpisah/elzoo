# ELZ-290 — Run the async-work and pii-redaction empty-log tests synchronously

- Dependencies: ELZ-118, ELZ-278

## Outcome and scope

Repair the test-isolation defect reported in issue #667 in the tests of two
Pieces. Each Piece's Contract, library code, README, `piece.json`, Piece ID
and catalogue/ready entry stay unchanged. This is a coordinator one-PR
repair: publication and implementation share one `task/ELZ-290` pull request.

Owned implementation paths:

- `pieces/runtime/async-work/test/elzoo/async_work_test.exs`
- `pieces/integration/pii-redaction/test/elzoo/pii_redaction_test.exs`

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `LEDGER.md`,
`docs/plans/views.md` and `docs/plans/dependencies.mmd`. The change touches
no shared path, manifest, README, dependency, pin, timeout or budget.

## Observed defect

`Elzoo.AsyncWorkTest` (empty-log checks at L157 and L314) and
`Elzoo.PiiRedactionTest` (L492 and L504) are `async: true` and assert an
empty `capture_log`. ExUnit documents that `capture_log` in an async module
can capture other tests' messages. That is the cause ELZ-276 repaired in
token-verify and ELZ-288 repaired in encryption, secrets and egress-policy.

## Required behavior

Both modules run `async: false`, so `capture_log` sees only their own tests'
logs. Keep every assertion, including the empty-log checks. Add no skip, tag,
retry, sleep or log filter.

## Acceptance and evidence

1. Reproduce: a temporary async module that logs errors while each module
   runs makes the unchanged module fail its empty-log check. The fixed module
   passes in the same pairing.
2. Negative control: a temporary log line in one library's checked path
   makes its fixed empty-log test fail.
3. Each changed Piece's tests with `--repeat-until-failure`, the small gate
   (`mix check --piece`), `git diff --check`, `scripts/ci-change-class.py`
   and the index step 3 checks.
4. One independent review, a green exact-head hosted check, and the PR
   marked ready. The coordinator merges on a green `main`, and the PR closes
   #667.
