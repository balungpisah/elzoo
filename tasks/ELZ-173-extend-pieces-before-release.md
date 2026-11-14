# ELZ-173 — AGENTS.md: before the first release a ready Piece is extended in place

- Dependencies: ELZ-033
- Change class: documents only; coordinator one-PR path (`AGENTS.md` section 1). No output Piece ID and no Piece Contract change.
- Allowed path: `AGENTS.md`, this task file, its job row in `docs/plans/release-plan.json` and the generated plan views.

Owner decision, 2026-11-14, with the request to put it in `AGENTS.md`: Elzoo
is not released yet. When a ready Piece lacks something that clearly belongs
to it, the Piece is extended, refactored or cut clean in place, with the same
Piece ID. No second Piece is made for the same job. The rule "a changed
Contract gets a new Piece ID" protects consumers and applies from the first
release. The decision is already recorded in `docs/plans/bot-platform.md`, and
ELZ-172 was its first use (`assembly/run-engine`).

## Change

1. Section 4, the bullet that starts "A ready Piece ID is a stable Contract":
   state the rule before the first release first (extend in place when the
   scope fits and is clear; the task body states the changed Contract; the
   manifest, the README and the index rows follow; a separate capability
   still gets its own Piece), then the rule from the first release (the
   present text).
2. Section 1, table "Choose the flow", row "New or changed Piece Contract":
   a changed Contract of a ready Piece is, before the first release, a
   published task on the same ID; a new capability gets a new Piece ID, which
   the coordinator publishes first. Keep "never reuse an old ID for a new
   Contract" for the time from the first release.

Change nothing else: no other section, no other document. `docs/consuming.md`
describes what a consumer gets from a release and stays as it is.

## Acceptance

- The two places read as above and do not contradict each other or
  `docs/plans/bot-platform.md`.
- `python3 scripts/check-roadmap.py`, `python3 scripts/check-roadmap.py --live`
  and `git diff --check` exit 0; `python3 scripts/ci-change-class.py range
  origin/main HEAD` reports a documents-only change.
- One independent review.
