# ELZ-294 — Let a test-only Piece repair use the coordinator's one-PR path

- Dependencies: none

## Outcome and scope

AGENTS.md section 1 allows publication and implementation to share one PR
only for "a coordinator-owned non-Piece change". The coordinator has used the
same path for repairs that change only a Piece's tests (ELZ-274, ELZ-275,
ELZ-276, ELZ-287, ELZ-288 and ELZ-290), each with the Piece flow's gates. The
written rule does not cover them. This task makes the rule say so outright,
under the owner's standing allowance for rule changes that speed the cycle
while staying safe; the owner can veto it.

This is a coordinator one-PR documents change: publication and
implementation share one `task/ELZ-294` pull request, and it takes the
documents check.

Owned path:

- `AGENTS.md` section 1: the "Piece-only implementation" row of the flow
  table and the one-PR paragraph under it, only.

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`.

## Required behavior

1. The one-PR paragraph also admits a coordinator-owned test-only Piece
   repair: a change under the `test/` directory of one or more ready Pieces
   only, with no output Piece ID, no Piece Contract change, and no change to
   `lib/`, `cure/`, `examples/`, `README.md`, `piece.json` or an index row.
2. Such a repair keeps the Piece flow's gates: the small gate, `check-piece`
   on the exact head, the section 6 review and the merge queue.
3. The "Piece-only implementation" row points to that paragraph for this
   case.
4. Every other condition of the paragraph stays: no `task` label, the section
   2 API lock, the task file and job row on the task branch, closing the task
   and reporting issues, not offering it to another worker, and "All review,
   gate and queue rules remain".

No other rule changes.

## Acceptance and evidence

1. The diff changes only the owned lines, this task file, its job row and the
   generated views.
2. `scripts/ci-change-class.py` classifies the range as documentation only.
3. `python3 scripts/check-roadmap.py --live`, `python3
   scripts/check-claims.py` and `git diff --check` pass.
4. One light independent review of the wording, a green exact-head hosted
   documents check, and the PR marked ready. The coordinator merges on a
   green `main`.
