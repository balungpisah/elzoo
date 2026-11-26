# ELZ-428 — state/lease: a malformed reply inside a write transaction returns an error

- Dependencies: ELZ-416

## Outcome and scope

A defect found while planning ELZ-422. In `Elzoo.Lease.Postgres`, the write
transaction `transact/3` and the sweep transaction call helpers that
`throw(:malformed)` when PostgreSQL returns a head row that is not exactly one
valid row (`lock_head/3`, `head/1`) or a clock sample that is not a
non-negative integer (`clock/1`). `transact/3` handles raised errors
(`rescue`) and exits (`catch :exit`) but not throws, and the Repo's
transaction re-raises a throw after its rollback. So such a reply crashes the
calling process (for a Run owner, without a reply) instead of returning an
error; on a later key of a sweep it also escapes, after earlier keys may have
entered their writes. The read path `read_attempt/3` already
returns `{:error, :malformed}` for the same throw. Under the pinned table
constraints the case is rare, but a fault in a ready Piece's error path is
fixed in place (the rule of ELZ-415).

- Catch `throw(:malformed)` in both transaction wrappers. Before `write!/6`
  marks a lease-record write attempted, return `{:error, :malformed}` after
  rollback, including rollback of any provisional head insert. After that
  marker, return `{:indeterminate, info}` through the existing write-failure
  path. In both the `SKIP LOCKED` lookup and the `NOWAIT` probe of the sweep,
  normalize an unexpected successful reply or invalid head row to
  `throw(:malformed)`. Keep the existing behavior for an empty row set and SQL
  errors. Apply the before/after lease-record write rule above. Other
  outcomes stay unchanged.
- No other result changes. The README names `{:error, :malformed}` among the
  write errors, with a `## Changes` entry; a changed `piece.json` gets a new
  `manifest_sha256` in its `entries` row, with `note` equal to a changed
  `contract`.

Paths: `pieces/state/lease/**`, the `entries` row of `state/lease` in
`docs/plans/release-plan.json`, and the generated `LEDGER.md` and
`docs/plans/views.md`. New external dependencies: none.

## Acceptance

- Force the head and clock checks to throw separately in a single-key
  transaction and before the first lease-record write of a sweep. Assert the
  error, caller survival, and no persisted head or record changes. Use a
  query-level fault fixture for malformed replies; existing phase hooks can
  inject the throw but cannot replace a query reply. Then inject the throw on
  a later sweep key after an earlier key enters `write!/6`, and assert an
  indeterminate result and rollback of the sweep.
- A negative control: removing the new handling makes the test fail with the
  crash (recorded and reverted).
- `mix test pieces/state/lease/test` on PostgreSQL 19, and
  `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0, or the pull request records the exact reason a
  command cannot run on the host. The hosted check is green on the exact head.
- One independent review by the strongest available reviewer of another model
  family (the Piece keeps durable state), and the exact-head automated review
  with its threads answered and resolved, or the authorized replacement
  review under `AGENTS.md` section 6.
