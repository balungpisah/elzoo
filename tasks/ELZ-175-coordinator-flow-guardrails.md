# ELZ-175 — Coordinator guide: four guardrails from wave 3 of the bot platform track

- Dependencies: ELZ-033
- Change class: documents only; coordinator one-PR path (`AGENTS.md` section 1). No output Piece ID and no Piece Contract change.
- Allowed path: `docs/development/13-coordinator.md`, this task file, its job row in `docs/plans/release-plan.json` and the generated plan views.

Owner decision, 2026-11-14: put the four rules below into the flow, and
remove an older rule where it disagrees. They come from what cost time in
wave 3:

- Four publications needed a second or third review pass because the task
  text stated something about a ready Piece that the code does not do, or
  an acceptance case that cannot occur. Two built Pieces met such a clause.
- Each merge rewrites the generated plan views. Two publications that were
  open at one time conflicted, and a publication that was open during Piece
  merges went stale after each of them.
- Ready pull requests that went to the queue one at a time conflicted with
  each other in the index files and needed repair rounds.
- The only reviewer with quota was a fast, low-cost model. It gave "no
  finding" on a native host that runs untrusted source.

## Change, in `docs/development/13-coordinator.md` only

1. **Check the text first.** A new first step of "Publish a batch of tasks
   for workers": before an issue is created, check each statement of the
   task about a ready Piece against the code on `main` (function, return
   shape, bound, reason), and work each acceptance group through by hand: a
   case that cannot occur, or that the Piece cannot test, is a fault of the
   task. Name the faults that happened as examples.
2. **One publication for each level.** In the batch steps and in "Levels":
   a level is published as one pull request with all its tasks; only one
   publication is open at one time; it merges when `main` is green and no
   queue run is active, and it is not opened in the middle of a burst of
   Piece merges. Replace the sentence that allows "publish the next level,
   or add the label" one task at a time where it disagrees.
3. **One queue run for the ready pull requests.** A new bullet: give the
   queue every ready pull request in one run, in dependency order; a worker
   merges `main` and runs step 3 of the index files immediately before it
   marks its pull request ready, and marks it ready only when GitHub shows
   it mergeable.
4. **Reviewer by risk.** A new bullet: for a Piece that runs untrusted
   input, holds native code or keeps durable state, the reviewer is the
   strongest reasoning model of another family that is available; when only
   a weaker one is available, the merge is not held, a second review with
   the stronger model is recorded on the issue #341-style hand-over record
   of the wave and done when that model is available, and each finding is
   its own task. A reviewer of such a Piece finds the code and a test for
   each rule of the issue body.

Change nothing else: not `AGENTS.md`, not the CI guide, not the queue.

## Acceptance

- The four rules are in the guide, each in the place where a coordinator
  reads it at that step, and no older sentence of the guide contradicts
  them. `AGENTS.md` sections 6, 7 and 9 are not contradicted.
- `python3 scripts/check-roadmap.py`, `python3 scripts/check-roadmap.py --live`
  and `git diff --check` exit 0; `python3 scripts/ci-change-class.py range
  origin/main HEAD` reports a documents-only change.
- One independent review.
