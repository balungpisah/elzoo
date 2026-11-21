# ELZ-289 — Require complete copied-consumer evidence and clean up a timed-out consumer

- Dependencies: ELZ-255

## Outcome and scope

Repair the two copied-consumer harness limitations reported in issue #581,
in the root test support that runs copied consumers. No Piece, Contract,
README, `piece.json`, dependency, pin, workflow, timeout, budget, test
selection or consumer isolation assertion changes. This is a coordinator
one-PR repair of a shared root path: publication and implementation share
one `task/ELZ-289` pull request, and it takes the full/affected gate.

Owned implementation paths:

- `test/support/cure_consumer_case_test_helper.exs`
- one new root test of that helper, `test/cure_consumer_case_helper_test.exs`,
  if the acceptance cases need it

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `LEDGER.md`,
`docs/plans/views.md` and `docs/plans/dependencies.mmd`.

## Observed defects

1. After the aggregate's 1,500-second ExUnit timeout, its owned consumer
   BEAM kept running and had to be cleaned up by hand. The helper's
   `System.cmd` call ties no cleanup of that child to the test owner when
   ExUnit kills the owner.
2. An interrupted run ended mid-test with no final top-level suite summary,
   but the command returned status zero, and its output held a nested
   suite's `Result: 63 passed`. The helper's exit-status and substring checks
   accepted it.

The original hosted overrun is not attributed to either limitation. The
signal behind the interruption was not recorded reliably.

## Required behavior

1. The helper accepts a consumer run only when it has evidence that the
   consumer's own top-level suite finished: its exit status, plus a final
   summary that a nested suite's output can't supply. A run that returns
   zero but lacks that evidence fails with a message that says so, even when
   the output holds a nested `Result: N passed`.
2. When the test that owns a consumer is killed, for example by its ExUnit
   timeout, the consumer and its descendants stop. Use OTP or the operating
   system's process ownership, not a generic process framework.

Normal completion still passes unchanged.

## Acceptance and evidence

1. Completion: a controlled consumer that prints a nested `Result: N passed`
   and exits zero before its own summary is rejected. A normally completed
   consumer is accepted.
2. Cleanup: a controlled owner-timeout case, with a short limit only in that
   case, kills the owning test. Then the owned consumer and its actual
   descendants (identified by OS PID) are gone. The unchanged helper leaves
   them running.
3. Negative controls: revert each part on its own, and the matching case
   fails.
4. `mix check --affected origin/main` on the worker's own disposable
   database, `git diff --check`, `scripts/ci-change-class.py` and the index
   step 3 checks. The full hosted check on the exact head must be green,
   including check-aggregate and the consumer jobs.
5. One independent review, and the PR marked ready. The coordinator merges
   on a green `main`, and the PR closes #581.
