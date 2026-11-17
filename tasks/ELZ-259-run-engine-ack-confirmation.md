# ELZ-259 — Reconcile uncertain native outbox acknowledgements

- Phase: Wave 4 prerequisite repair
- Release: V1B
- Change class: Piece-only correction of the existing Contract
- Dependencies: ELZ-127, ELZ-256
- Output: none; repair the ready `assembly/run-engine` Piece in place
- Owned paths: `pieces/assembly/run-engine/**`, its existing index rows and
  normally generated views. No other Piece, dependency, pin, root executable,
  CI, workflow or shared test-helper changes.

## Defect and outcome

Restore the existing RunEngine acknowledgement reconciliation path. Its native
outbox handler currently passes the indeterminate receipt from `Outbox.ack/3`
directly to `DurableLog.confirm_ack/2`. `Store.unknown/2` omits `extra` and adds
`cause`; `confirm_ack/2` first accesses `request.extra`, and receipt validation
expects the canonical receipt. The actual public codec/Store/confirmation chain
therefore raises `KeyError` for `extra` instead of reconciling an uncertain ack.
This is a caller correction, not a new delivery guarantee or Store API change.

Use the original item key and acknowledgement nonce to supply the canonical
public acknowledgement request when reconciling. A confirmed commit must keep
normal native progress possible. Missing, pending, unavailable, malformed,
mismatched or superseded confirmation must preserve the existing explicit
unknown/fenced behavior, without an exception or a replacement acknowledgement
identity. Do not infer the original nonce committed from an empty pending list.
Do not change unrelated known-conflict behavior in this repair.

Keep the public RunEngine API, native admission/dispatch ordering, Budget,
local-work restart-loss behavior, and existing read-only result Contract intact.
No new retry loop, wrapper framework, timeout increase or weaker assertion.

## Acceptance

1. Add an actual public RunEngine regression using a disposable PostgreSQL Store
   and a controlled acknowledgement reply loss. Execute the real ack before
   hiding its response. Confirm the original key/nonce through the actual public
   confirmation API, keep the engine alive, and observe native completion without
   an additional dispatch or Budget charge. A direct helper reproduction alone
   is not implementation acceptance.
2. Exercise an acknowledgement that has not committed and a committed ack whose
   confirmation read is unavailable. The owner must remain explicit about
   uncertainty, not raise or resend under a fresh nonce. Repeated offers must not
   add dispatch/charge while halted. Include a different winning nonce so it is
   not mistaken for confirmation of the original acknowledgement.
3. After fencing the old task/owner/caller/connection tree and reopening, preserve
   the original Run, Attempt, Unit and result identities. Use a completed cut for
   a completed-result assertion; preserve native `local_restart` semantics if
   work was still volatile. Assert exact outbox contents/ack state and work counts
   across the selected restart boundary. Do not claim universal process/network
   cancellation from the finite fixture.
4. Temporarily restore the defective production call in the real worktree. The
   new regression must fail at the intended native acknowledgement boundary.
   Restore the implementation byte-for-byte and record the failing control and
   restored source hash. Never commit the control.

Run all RunEngine Piece tests with PostgreSQL enabled, the selected Piece gate,
roadmap/live-roadmap and claims checks, and `git diff --check`. Update the Piece
README/grounding only as needed to describe the finite added evidence; retain
its existing Contract and limitations. Recompute affected manifest hashes and
generate indexes normally. Do not report Wave 4 complete from this repair.

One independent review, exact-head hosted checks and the required merge queue
remain mandatory. Record test commands/results and any unresolved failure in
the PR. No private environment details, credentials or session links in public
repository prose.
