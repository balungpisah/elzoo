# ELZ-427 — durable log: retention removes the checkpoints it leaves unusable

- Dependencies: ELZ-416

## Outcome and scope

A Store's `retain(stream, expected, through, nonce)` deletes the log records
of the stream at or below `through` and its acknowledged outbox rows, and
moves `low_water` to `through`. It requires a valid checkpoint at or above
`through` (`{:rejected, :retention_beyond_checkpoint}` otherwise). It deletes
no checkpoint: the PostgreSQL Store of `integration/sql`
(`lib/elzoo/durable_log/postgres.ex`, table `elzoo_checkpoints`) and the
Memory Store of `state/event-log` (`lib/elzoo/durable_log/memory.ex`) keep
every checkpoint forever. A checkpoint below `low_water` can never be used
again (the records after its anchor up to `low_water` are gone), yet it keeps
the projection it held. A stream that retains on a cadence (ELZ-418 writes a
bounded checkpoint each maintenance cycle) therefore grows its checkpoints
without bound and keeps data that its owner evicted.

Both Pieces improve in place under their IDs (the rule of ELZ-415):

- A committed `retain` also deletes, in the same transaction (PostgreSQL) or
  the same state update (Memory), every checkpoint of that stream with a
  sequence below `through`, of every checkpoint version. Checkpoints at or
  above `through`, including the one the retention check requires, and the
  checkpoints of other streams stay. The replay of a committed retention
  (same nonce, the existing duplicate path) deletes nothing more and returns
  its first result. A refused or conflicting retention deletes nothing.
- `put_checkpoint` of a checkpoint whose sequence is below the stream's
  `low_water` is refused with `{:rejected, :checkpoint_below_low_water}`, so a
  late put cannot recreate a dead checkpoint. A put at or above `low_water`
  behaves as today.
- `latest_checkpoint` and `read_checkpoint` never return a deleted
  checkpoint (`read_checkpoint` gives `:absent`).
- The README of each Piece states the rule (where it says records and
  checkpoints are immutable, it says that retention deletes them below
  `low_water`), with a `## Changes` entry; each changed `piece.json` gets a new
  `manifest_sha256` in its `entries` row, with `note` equal to a changed
  `contract`.

Paths: `pieces/state/event-log/**`, `pieces/integration/sql/**`, the
`entries` rows of these two Pieces in `docs/plans/release-plan.json`, and the
generated `LEDGER.md` and `docs/plans/views.md`. The tests of the ready
Pieces that use these Stores must pass unchanged, except an assertion that a
checkpoint below `low_water` survives retention (name each such change in the
pull request). New external dependencies: none.

## Acceptance

On both Stores:

- Three checkpoints at sequences `a < b < c` (one of another version below
  `b`), and a retention through `b`: the checkpoints below `b` are gone
  (`read_checkpoint` gives `:absent`), `b` and `c` remain, `latest_checkpoint`
  is unchanged, and the checkpoints of another stream are untouched.
- A replayed retention (same nonce) and a refused one (no checkpoint at or
  above `through`, a pending outbox item, an `expected` conflict) delete no
  checkpoint.
- `put_checkpoint` below `low_water` is refused and writes nothing; at
  `low_water` and above it commits.
- PostgreSQL: a `put_checkpoint` below `through` that races the retention
  either commits first and is then deleted by it, or is refused after it;
  never a surviving checkpoint below `low_water` (lock order shown in the
  test).
- A negative control: a temporary edit that skips the delete makes the first
  case fail (recorded and reverted).
- `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0, or the pull request records the exact reason a
  command cannot run on the host. The hosted check is green on the exact head.
- One independent review by the strongest available reviewer of another model
  family (the Pieces keep durable state), and the exact-head automated review
  with its threads answered and resolved, or the authorized replacement
  review under `AGENTS.md` section 6.
