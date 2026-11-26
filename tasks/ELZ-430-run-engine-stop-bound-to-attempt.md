# ELZ-430 — assembly/run-engine: a pending stop is bound to its Attempt

- Dependencies: ELZ-420, ELZ-423, ELZ-429

## Outcome and scope

A defect found while fixing ELZ-420's review. ELZ-420 binds a pending root
failure, its evidence row and the owner command to the finish slot's own
Attempt, so a restart after the host began a new Attempt drops the stale
failure instead of failing the new Attempt. The other pending stops still
have that race: a completed Run (`stop_pending: :completed`) and the
lifecycle stops (`:cancelled`, `:out_of_time`, `:out_of_budget`). If the
engine dies before its owner command and the host begins a new Attempt before
the restart, the restart completes the new Attempt with the old Attempt's
source or stop; `result/3` then fails closed (`{:error,
:completion_mismatch}`), and the new Attempt ends without ever running. It
is fixed in place under the same ID (the rule of ELZ-415).

- Every pending stop, its evidence row (where one is written) and the owner
  command carry the Attempt that produced the stop. If the owner has moved to
  a newer Attempt, its stale answer makes the engine sync the new Run view,
  and a change of Attempt drops the stale stop, as ELZ-420 does for a root
  failure. The new Attempt runs normally.
- The result reader accepts a stop only for the owner's current Attempt, and
  requires every record that ends a pending stop or changes the Attempt to
  replay to exactly its recorded state, in v1 and v2, as ELZ-420 does.
- Histories without such a restart keep their journal, transcripts, frozen
  fixtures and cold-recovery results unchanged.
- The README `## Changes` entry names the change; a changed `piece.json` gets
  a new `manifest_sha256` in its `entries` row, with `note` equal to a changed
  `contract`.

Paths: `pieces/assembly/run-engine/**`, its `entries` row in
`docs/plans/release-plan.json`, and the generated `LEDGER.md` and
`docs/plans/views.md`. New external dependencies: none.

## Acceptance

- For a completed stop and for each lifecycle stop: the engine is killed
  after the stop is pending (and after its evidence row, where one exists),
  the host begins a new Attempt on the owner, and the engine restarts. The
  Run stays open in the new Attempt, no stale stop is pending, no extra
  evidence row is written, the owner has no terminal record of the old stop,
  and a wake reaches the root of the new Attempt. Both crash orders (before
  and after the owner answers stale) are covered.
- A digest-valid edit of a Run-view row that keeps the older Attempt cannot
  drop a pending stop: `{:error, :history}` in v1 and v2.
- Negative controls (each recorded and reverted): the Run-view fold keeps the
  stale stop; the owner command uses the owner's current Attempt; the reader
  accepts an older Attempt's stop.
- The frozen-row and cold-recovery tests pass unchanged.
- `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0, or the pull request records the exact reason a
  command cannot run on the host. The hosted check is green on the exact head.
- One independent review by the strongest available reviewer of another model
  family (the Piece keeps durable state), and the exact-head automated review
  with its threads answered and resolved, or the authorized replacement
  review under `AGENTS.md` section 6.
