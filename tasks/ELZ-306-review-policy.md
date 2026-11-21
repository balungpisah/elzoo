# ELZ-306 — Record the owner's review policy in AGENTS.md section 6

- Dependencies: none

## Outcome and scope

The owner accepted the review practice the coordinator has used in Wave 6
(owner decision, 2026-11-21):

- the one independent review may be a different session of the same model
  when no other model family is available;
- the automated reviewer's pass on the exact head must have finished, and
  each of its threads must be answered and resolved, before each merge;
  the coordinator checks this before it starts the merge queue, and a head
  that the queue makes by merging `main` needs no new pass;
- when a reviewer of another model family becomes available, it rechecks
  three merged Pieces once: `domain/journal` (the money ledger),
  `domain/metering` and `delivery/dead-letter-store`, and each finding
  becomes its own task.

AGENTS.md section 6 states the first point only as a fallback and lets a
worker answer the automated reviewer without saying when its pass must be
finished. This task writes the three points into section 6.

This is a coordinator one-PR documents change: publication and
implementation share one `task/ELZ-306` pull request, and it takes the
documents check.

Owned path:

- `AGENTS.md` section 6 only.

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`.

## Required behavior

1. The reviewer bullet says that a different session of the same model is
   accepted when no other model family is available, by owner decision,
   and that the comment says so.
2. The automated-reviewer bullet requires, before the coordinator starts
   the merge queue, that the automated reviewer's pass on the exact head
   has finished and that every one of its threads is answered and
   resolved, and says that a head the queue makes by merging `main` needs
   no new pass.
3. The paragraph that marks a pull request ready says that the automated
   reviewer reviews only a pull request that is not a draft, so its pass
   starts when the PR is marked ready, and that the coordinator merges only
   starts the queue only after that pass has finished with its threads
   resolved.
4. A bullet records the one-time recheck of the three Pieces above by a
   reviewer of another model family once one is available, with each
   finding as its own task.

No other rule changes. The merge queue script is not changed.

## Acceptance and evidence

1. The diff changes only section 6 of `AGENTS.md`, this task file, its job
   row and the generated views.
2. `scripts/ci-change-class.py` classifies the range as documentation only.
3. `python3 scripts/check-roadmap.py --live`, `python3
   scripts/check-claims.py` and `git diff --check` pass.
4. One light independent review of the wording, a green exact-head hosted
   documents check and the PR marked ready; the coordinator merges on a
   green `main` after the automated reviewer's finished pass with its
   threads resolved.
