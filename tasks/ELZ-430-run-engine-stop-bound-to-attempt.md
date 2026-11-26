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
restart, the engine can terminalize the new Attempt without running it. For
`:completed`, it uses the older Attempt's source and `result/3` can return
`{:error, :completion_mismatch}`. For `:cancelled`, `:out_of_time` and
`:out_of_budget`, no evidence row is written and `result/3` returns
`{:terminal, outcome}`. It is fixed in place under the same ID (the rule of
ELZ-415).

- Every pending stop, its evidence row (where one is written) and the owner
  command carry the Attempt that produced the stop. If the owner has moved to
  a newer Attempt, its stale answer makes the engine sync the new Run view,
  and a change of Attempt drops the stale stop, as ELZ-420 does for a root
  failure. The new Attempt can generate work when the existing Run-wide
  deadline, Budget and request cap permit it; an Attempt change resets none of
  them.
- During a retained-history read in v1 or v2, when a stop is pending, any
  record that ends it or changes the Attempt must replay to exactly its
  recorded state. A selected completion or root failure must belong to the
  owner's current Attempt. Plain lifecycle results remain authoritative owner
  outcomes.
- Histories without a stale pending stop keep their journal, transcripts,
  frozen fixtures and cold-recovery results unchanged.
- The README `## Changes` entry names the change; a changed `piece.json` gets
  a new `manifest_sha256` in its `entries` row, with `note` equal to a changed
  `contract`.

Paths: `pieces/assembly/run-engine/**`, its `entries` row in
`docs/plans/release-plan.json`, and the generated `LEDGER.md` and
`docs/plans/views.md`. New external dependencies: none.

## Acceptance

- For each stop, exercise two crash cuts after the pending stop and any
  evidence are committed. First, kill the engine before forwarding
  `:complete`, then begin the new Attempt and restart. Second, begin the new
  Attempt before the engine samples the revision for `:complete`, forward the
  command with the stop's original Attempt, and assert the real owner returns
  `{:unchanged, :stale, revision}`. Deliver that reply, then kill the engine
  at the ensuing status call before it journals the new Run view. Repeat the
  second case without killing the engine to verify that the stale reply
  itself triggers sync and clears the stop. In each case no stale stop is
  pending, no extra evidence row is written and the owner has no terminal
  record of the old stop.
- A current-Attempt wake reaches the root after completion, cancellation, and
  expiry of an old pause deadline while the Run deadline is still in the
  future. After Run-deadline or budget exhaustion, a fresh wake requests a
  stop for the new Attempt under the unchanged limit.
- With the new Attempt open, first assert `transcript/3` succeeds. Then change
  only the Run-view input to name the old Attempt, recompute its row digest,
  and leave its paired state unchanged. Assert `transcript/3` returns
  `{:error, :history}` in v1 and v2; disabling the pending-stop replay check
  must make the v1 case fail.
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
