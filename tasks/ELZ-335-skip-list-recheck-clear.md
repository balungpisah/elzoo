# ELZ-335 — Skip list: clear the rechecked rows, state the recheck rule

- Dependencies: ELZ-325

## Outcome and scope

On 22 November 2026 the automated reviewer was available again, and every
range in the "Skipped automated reviews" list of
`docs/development/13-coordinator.md` was rechecked once, together with the
ranges of #773 (`1ece4358..02272a0d`), #774 (`5b7df687..a32bf7d0`), #775
(`c815e2d8..605671ea`) and #776 (`f52061d2..9850bdb1`), which were owed and
not yet listed. Each got a posted result: the automated reviewer posted
findings or "no issues found" on a recheck pull request for #719, #723, #725,
#729, #741, #747, #750, #753, #759, #761, #770, #771, #773, #774, #775 and
#776. For #737, the remerge diff of its merge of `main` does not apply on the
range's first SHA, so the reviewer of another model family posted a recheck
record on #737. Each valid finding is its own defect issue.

The recheck paragraph above the table also states the recheck rule that the
coordinator approved on 21 November and tightened on 22 November: which
commits and merges a recheck reads, how the recheck branch is built, and
which rows go to the reviewer of another model family.

This is a coordinator one-PR documents change. Owned paths:
`docs/development/13-coordinator.md` (the "Skipped automated reviews" item
only), this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`. No Contract, Piece or catalogue entry changes.

## Required behavior

1. Remove each row of the list that got a posted result: #719, #723, #725,
   #729, #737, #741, #747, #750, #753, #759, #761, #770 and #771. Add no row
   for #773, #774, #775 or #776, because each got a posted result. The table
   keeps its header.
2. The recheck paragraph states that a recheck reads the pull request's own
   commits (`git log --first-parent --no-merges <range>`) and each merge of
   `main` in the range whose `git show --remerge-diff --format= <merge>` is
   not empty; a merge with an empty remerge diff is not reviewed again.
3. It states how the automated reviewer's recheck branch is built:
   `recheck/<PR>-base` at the range's first SHA, `recheck/<PR>` from it by
   cherry-picking those commits in order (`git log --first-parent
   --no-merges --reverse --format=%H <range>`), with each non-empty remerge
   diff as its own commit after the commits before it; a pull request from
   the second to the first, marked ready, then closed unmerged with both
   branches deleted.
4. It states that a row whose cherry-pick conflicts, or whose remerge diff
   does not apply, pushes nothing and is rechecked by the reviewer of another
   model family (`openai/gpt-6.1-terra` at high effort, in a fresh session),
   which reads `git log --first-parent --no-merges -p <range>` and those
   remerge diffs.
5. The removal rule (a posted result on the recheck pull request, or a
   five-line record whose Reviewer role begins `recheck of a skipped
   automated review`, posted after the row was added; the gate record does
   not count; otherwise the row stays) is unchanged.

## Acceptance and evidence

Documents-only classification (`scripts/ci-change-class.py`), live roadmap,
claims and diff checks, one independent review, a green exact-head docs-only
hosted check, the PR marked ready and the automated reviewer's gate of
`AGENTS.md` section 6. The coordinator merges on a green `main`.
