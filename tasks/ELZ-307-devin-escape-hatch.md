# ELZ-307 — Do not wait on an unavailable automated reviewer

- Dependencies: ELZ-306

## Outcome and scope

AGENTS.md section 6 (ELZ-306) makes the automated reviewer's finished pass
on the exact head, with its threads resolved, a condition for starting the
merge queue. The owner asked for a way through when that reviewer is out of
quota or unavailable (owner decision, 2026-11-21): do not wait; run one
extra independent review instead, record the skip, and let the automated
reviewer recheck the skipped pull requests once it is back.

What the automated reviewer shows, from its reviews on this repository: on
its first pass after a pull request is marked ready it always posts a
review, either "No Issues Found" or its findings. On a later head it posts
only new findings or replies in its threads, so a later head can stay
silent. It posts nothing when it starts. So the only observable signal is a
post for the head.

This is a coordinator one-PR documents change: publication and
implementation share one `task/ELZ-307` pull request, and it takes the
documents check.

Owned paths:

- `AGENTS.md` section 6 only;
- `docs/development/13-coordinator.md`: one new list of skipped automated
  reviews, with its rule.

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`.

## Required behavior

1. Section 6 says: when the automated reviewer has posted nothing for the
   exact head 30 minutes after the ready mark or after that head was
   pushed, or says that it is out of quota or unavailable, the coordinator
   does not wait (owner decision).
2. Instead, one extra independent review in a fresh session reads the
   commits since the automated reviewer's last posted pass (the whole diff
   when it posted none), looking for edge cases, races, bounds and error
   paths, and records the five lines. With no blocker open, it is the gate
   in place of the automated pass.
3. The coordinator records on the pull request that the automated reviewer
   was skipped and why, and adds the pull request, with the skipped range,
   to the list in the coordinator guide.
4. A Piece with any weight from section 5 keeps the full review; the extra
   review does not replace it.
5. The coordinator guide holds the list. When the automated reviewer is
   available again, it rechecks each listed range once; each finding becomes
   its own task, and the row is removed after the recheck. The list starts
   with the two pull requests merged today after a silent automated pass on
   their final heads: #703 (`b2805e09..ce123ab5`) and #708
   (`37949c54..7c864110`).

No other rule changes. The merge queue script is not changed.

## Acceptance and evidence

1. The diff changes only the owned paths, this task file, its job row and
   the generated views.
2. `scripts/ci-change-class.py` classifies the range as documentation only.
3. `python3 scripts/check-roadmap.py --live`, `python3
   scripts/check-claims.py` and `git diff --check` pass.
4. One light independent review of the wording, a green exact-head hosted
   documents check and the PR marked ready; the coordinator starts the
   queue on a green `main` after the automated reviewer's finished pass, or
   after the extra review this task defines when that pass does not come.
