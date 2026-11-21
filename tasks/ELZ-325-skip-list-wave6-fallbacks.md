# ELZ-325 — Skip list: add the later 21 Nov fallback skips

- Dependencies: ELZ-317

## Outcome and scope

Five more pull requests merged with the automated reviewer skipped under
`AGENTS.md` section 6. Each skip comment on the pull request gives the reason
and links the fallback record: the automated reviewer posted nothing for the
head within 30 minutes of its push (and, for #741 and #750, the ready mark),
and the other-family fallback review (openai/gpt-6.1-terra, fresh session)
posted on the pull request, with no blocker open, was the gate. The fifth,
#753, is the ELZ-324 publication. Their ranges get rows in the "Skipped
automated reviews" list of `docs/development/13-coordinator.md`, so that the
recheck procedure there covers them.

This is a coordinator one-PR documents change. Owned paths:
`docs/development/13-coordinator.md` (the list only), this task file, its
no-output job row in `docs/plans/release-plan.json`, and the generated
`docs/plans/views.md` and `docs/plans/dependencies.mmd`. No rule, Contract,
Piece or catalogue entry changes.

## Required behavior

1. Add one row each, after the existing rows and in the format of the
   existing rows, for #737 (`4304e053..d8171bde`), #741
   (`fc3abf63..03f2d744`), #747 (`36937f30..e24f4cce`), #750
   (`0c14fd52..5aa596f5`) and #753 (`a1920865..db617841`). Each gives the
   reason: nothing was posted for the head within 30 minutes of its push (for
   #741 and #750, of its push and the ready mark), and the other-family
   fallback review was the gate.
2. The existing rows and the recheck procedure above the table are unchanged.

## Acceptance and evidence

Documents-only classification (`scripts/ci-change-class.py`), live roadmap,
claims and diff checks, one independent review, a green exact-head docs-only
hosted check, the PR marked ready and the automated reviewer's gate of
`AGENTS.md` section 6. The coordinator merges on a green `main`.
