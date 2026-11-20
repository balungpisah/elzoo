# ELZ-274 — Release a replied HTTPJob pool slot before the next call

- Dependencies: ELZ-011

## Outcome and scope

Repair the intermittent `assembly/http-job` confirmation timeout of reporting
issue #584 at its cause in the ready Piece. The Piece's Contract, README,
`piece.json`, Piece ID and catalogue/ready entry stay unchanged. This is a
coordinator one-PR task: publication and implementation share one
`task/ELZ-274` pull request.

Owned implementation paths:

- `pieces/assembly/http-job/lib/elzoo/http_job/call.ex`
- `pieces/assembly/http-job/test/elzoo/http_job_test.exs`

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`. The change touches no shared path, manifest,
README, dependency, pin, timeout or budget.

## Observed defect

The test "real HTTP plus SQL owner confirms; duplicate wakes and result do not
send again" (`http_job_test.exs:285`) intermittently waits 60 s for
`{:Confirmed, 1}` after one wake returned `{:snooze, 2}`. Hosted occurrences:
run 44039907760 (PR #583) and run 44750148089 job check-root-b (PR #617, a
documents-only change).

`Elzoo.HttpJob.Call.run/3` returns as soon as a pool task replies. The task
process exits after that, and its `Task.Supervisor` frees the slot only when it
handles that exit. The owner authenticates a completed receipt through
`Adapter.authenticate/2`, which calls `Call.run` on the same transport pool
immediately after the send's transport task replied. With a one-slot transport
pool (the test's, and an allowed `task_spec(name, 1)`), the still-counted
replied child makes `Task.Supervisor.async` raise `max_children`; `Call.run`
returns `{:error, :call_unavailable}`, authentication fails, and the owner
retains a refusal for a valid completion: `{:Dispatched, :Fresh, 1}`, evidence
1, one PUT. The test drives no later poll, so it never confirms.

ELZ-092 (#170) recorded the same reaping lag for the caller pool under real
concurrency and changed only its test. Here there is no contention: the
refusal comes from the Piece's own finished call.

## Required behavior

After a pool task has replied, `Call.run` removes that child from its
supervisor before it returns, so a following call is not refused by a finished
child. The removal must not signal the caller, and must not lose a reply that
was already received. Timeout and exit paths keep their current results.
Refusal under real pool contention stays fail-closed, as the README states.

Do not weaken the existing test, its assertions, timeouts or budgets; do not
skip or tag it out; add no retry around a refused start and no sleep.

## Acceptance and evidence

1. Reproduce the unchanged test with one `mix test <path>:285
   --repeat-until-failure <n>` launch under CPU load, and capture the owner
   state at failure with temporary diagnostics that are never committed.
2. Add one regression test that holds a replied transport child in the
   one-slot pool for a deterministic window and requires `{:Confirmed, 1}`
   with one PUT. Show it fails with the old `Call.run` (temporary revert) and
   passes repeatedly with the fix.
3. Run the focused repeats after the fix, the whole Piece tests, the Piece
   small gate `mix check --piece "$(git merge-base origin/main HEAD)"` and
   `git diff --check`; classify paths with `scripts/ci-change-class.py`.
4. One independent review with a second pass on fix commits; exact-head hosted
   check green; mark ready. The coordinator merges.

Close this task issue and #584 with the implementation PR. Copied-consumer
child cleanup after an ExUnit timeout (#581) is not in scope.
