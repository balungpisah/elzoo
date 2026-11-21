# ELZ-291 — Confirm each stop before listing children in copied-consumer cleanup

- Dependencies: ELZ-289

## Outcome and scope

Repair the cleanup race reported in issue #671, in the root test support
that ELZ-289 added. No Piece, Contract, README, `piece.json`, dependency,
pin, workflow, consumer timeout, budget, test selection or consumer isolation
assertion changes. This is a coordinator one-PR repair of a shared root path:
publication and implementation share one `task/ELZ-291` pull request, and it
takes the full/affected gate.

Owned implementation paths:

- `test/support/cure_consumer_case_test_helper.exs`
- `test/cure_consumer_case_helper_test.exs`

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `LEDGER.md`,
`docs/plans/views.md` and `docs/plans/dependencies.mmd`.

## Observed defect

`stop_process_tree/1` sends SIGSTOP from the root down, lists each signalled
process's children, then sends SIGKILL. It lists a process's children
without first confirming that the process has stopped. A descendant that
forks in that window leaves a child that is never listed and escapes
cleanup. In the ELZ-289 review, a scratch reproduction with a parent forking
about every 60 ms saw a child escape in 4 of 60 runs. A variant that waited
for each signalled process to show as stopped (state `T`) had 0 escapes in
120 runs.

## Required behavior

Before listing a process's children, the cleanup confirms that the process
has stopped or has already exited. The wait is bounded: if a process neither
stops nor exits inside the bound, cleanup kills what it has found and the
owning case fails with a message that names the PID. It never hangs. Normal
completion and the ELZ-289 cases still pass unchanged. Build no generic
process framework.

## Acceptance and evidence

1. Race case: a controlled consumer whose descendant forks continuously is
   killed through its owning test's timeout, with a short limit only in that
   case. Afterwards no recorded OS PID, and no process descended from the
   consumer, is still running. Repeat it enough times (at least 60 in one
   launch) that the unfixed helper fails it; record the counts.
2. Negative control: remove the stop confirmation, and the race case fails.
   Revert it.
3. The ELZ-289 cases and its controls A–C still behave as recorded in #668.
4. `mix check --affected origin/main` on the worker's own disposable
   database, `git diff --check`, `scripts/ci-change-class.py` and the index
   step 3 checks. The full hosted check on the exact head must be green,
   including check-aggregate and the consumer jobs.
5. One independent review, and the PR marked ready. The coordinator merges
   on a green `main`, and the PR closes #671.
