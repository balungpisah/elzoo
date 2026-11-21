# ELZ-310 — List the automated-review skips of the 21 Nov quota outage

- Dependencies: ELZ-307

## Outcome and scope

Add rows to the "Skipped automated reviews" list in
`docs/development/13-coordinator.md` for the pull requests whose final heads
the automated reviewer did not review on 21 November 2026, and record the
reason: the owner confirmed that the automated reviewer's quota ran out, with
service expected back at about 08:30 UTC on 22 November. Until then the
coordinator does not wait 30 minutes on a new head. The extra fresh-session
review in `AGENTS.md` section 6 is the gate at once, as that section already
allows when the reviewer is out of quota.

This is a coordinator one-PR documents change. Owned paths:
`docs/development/13-coordinator.md` (the list only), this task file, its
no-output job row in `docs/plans/release-plan.json`, and the generated
`LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`. No rule,
Contract, Piece or catalogue entry changes.

## Required behavior

1. One row each for #712 (`682bd985..1d0e9bab`) and #714
   (`26efb104..5620eec5`). For each, the reason is that nothing was posted
   for the final head (quota outage), and the extra review was the gate.
2. One sentence under the table naming the outage window, saying that
   rows stay until the recheck the list describes, and saying that each
   recheck finding becomes its own task.
3. Existing rows and the recheck procedure are unchanged.

## Acceptance and evidence

Documents-only classification (`scripts/ci-change-class.py`), live roadmap,
claims and diff checks, a green exact-head docs-only hosted check, and the PR
marked ready. The coordinator merges on a green `main`.
