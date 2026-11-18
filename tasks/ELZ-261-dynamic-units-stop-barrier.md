# ELZ-261 — Synchronize the DynamicUnits stopping-capacity test

- Dependencies: ELZ-231

## Outcome and scope

Repair only the synchronization in the DY3 capacity test of the ready
`runtime/dynamic-units` Piece. Its public Contract and production implementation
stay unchanged. This is a Piece-only test implementation after separate task
publication; it is not a root/shared harness change.

Owned implementation path:

- `pieces/runtime/dynamic-units/test/elzoo/dynamic_units_test.exs`

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`. The implementation changes no shared path, manifest,
README, dependency, pin, timeout budget or catalogue/ready entry.

## Observed defect

Reporting issue #596 records a copied aggregate failure: DY3 received
`{:third, {:error, :capacity}}` at its unchanged pending-response assertion.
An isolated initial execution plus fifty repeats passed on unchanged main.
A separate scheduling probe established that the supervisor's generic
`:waiting` status can be true before the stop requester submits its call.
In that permitted ordering, a third start correctly receives `{:error, :capacity}`
because both slots remain occupied. The exact ordering of the historical
aggregate failure was not captured; do not present the probe as that history.

## Required behavior

Before launching the third start in the stopping phase, positively establish
that the directory has accepted the request to stop the suspended second Unit.
Before resuming that Unit, establish that the third start has actually been
submitted while stop remains blocked. Use bounded existing OTP/test
observability, such as exact-message tracing; clean it up on both success and
failure. A process's generic `:waiting` status is not an operation barrier.

Preserve all existing starting, stopping and restarting phases, capacity
refusals, pending-response assertions, resume/termination behavior, final child
counts and identity checks. Retain their assertion strength and time limits.
Do not add a production hook, generic synchronization framework, retry around
the assertion, committed sleep-based ordering, skipped scenario or dependency.

## Acceptance and evidence

1. Run DY3 with one `mix test <test-path>:<DY3-line>
   --repeat-until-failure 50` launch. Record the selector, seed, executions,
   counts, exit and wall time; an initial execution plus fifty repeats is 51.
   Run the complete DynamicUnits Piece tests as well.
2. Exercise the changed test in a disposable copied consumer built through the
   existing export/consumer facilities with the Piece's dependency closure.
   Run at least the whole DynamicUnits test module, preserving normal copied
   test support; confirm that copied production/test source matches the candidate
   and no root-project implementation is loaded. Record commands and results.
   No new committed exporter or root harness code is in scope.
3. Make an actual-worktree paired control: temporarily delay the stop requester
   before submission and show the fixed barrier still passes. With that delay
   retained, restore the old generic status predicate so that the third start
   can overtake stop. The existing pending-response assertion must fail
   with the capacity response, not an unrelated setup/cleanup failure. Record
   the exact mutation, command, nonzero exit and assertion. Revert every temporary
   change, verify source restoration, and rerun the fixed focused test. Keep
   diagnostic runs, failures and restored-candidate evidence distinct.
4. Run cheap format, compile, source-read, roadmap/live-roadmap, claims and diff
   checks before the selected gate. Classify the actual paths with
   `scripts/ci-change-class.py`; shared executable impact or uncertainty requires
   stopping this scoped implementation and publishing the needed prerequisite.
5. Run the repository's Piece gate,
   `mix check --piece "$(git merge-base origin/main HEAD)"`, and
   `git diff --check`. Before a long gate, use the reusable private preflight to
   verify selected-worktree dependencies and required extensions through the
   exact disposable database binding; store safe results with that gate.
6. Freeze for independent exact-diff review, address blockers, pass exact-head
   hosted checks, mark ready, and merge through the queue. The full post-merge
   main check must pass before this repair's aggregate outcome is accepted.
   A passing selected check does not erase the historical aggregate failure.

Keep raw diagnostic evidence private and publish only sanitized commands,
results and limits. Record all failed controls or setup attempts honestly.
Close this task and reporting issue #596 with the implementation PR. Do not
fold DataStream repair #595, channel acceptance #590, or HTTPJob investigation
#584 into this change.
