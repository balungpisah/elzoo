# ELZ-317 — Skip list: clear the rechecked rows, add the 21 Nov fallback skips

- Dependencies: ELZ-311

## Outcome and scope

Bring the "Skipped automated reviews" list in
`docs/development/13-coordinator.md` up to date.

The other-family reviewer has rechecked every listed range. Its five-line
records, whose Reviewer role begins `recheck of a skipped automated review`,
are posted on #703, #708, #709, #712 and #714 after their rows were added.
The one finding (on #703) became its own task, ELZ-315, which merged as #732.
So, under the list's own removal rule, those five rows go.

Four later pull requests merged with the automated reviewer skipped under
`AGENTS.md` section 6. In each case it posted nothing for the head within 30
minutes of the push, and the other-family fallback review (or, for #719, the
extra fresh-session review) posted on the pull request was the gate. Their
ranges get rows.

This is a coordinator one-PR documents change. Owned paths:
`docs/development/13-coordinator.md` (the list only), this task file, its
no-output job row in `docs/plans/release-plan.json`, and the generated
`LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`. No rule,
Contract, Piece or catalogue entry changes.

## Required behavior

1. Remove the rows for #703 (`b2805e09..ce123ab5`), #708
   (`37949c54..7c864110`), #709 (`08037e02..26e66a06`), #712
   (`682bd985..1d0e9bab`) and #714 (`26efb104..5620eec5`).
2. Add one row each for #719 (`3d624ba1..ac2bc431`), #723
   (`b1fa8b9d..cb1385b9`), #725 (`42910465..d7a0e54b`) and #729
   (`d1316117..3390fc53`). Each gives the reason: nothing was posted for the
   head within 30 minutes of its push, and the review posted on the pull
   request was the gate.
3. Remove the "Quota outage" paragraph under the table, because no remaining
   row cites it. The recheck procedure above the table is unchanged.

## Acceptance and evidence

Documents-only classification (`scripts/ci-change-class.py`), live roadmap,
claims and diff checks, a green exact-head docs-only hosted check, and the PR
marked ready. The coordinator merges on a green `main`.
