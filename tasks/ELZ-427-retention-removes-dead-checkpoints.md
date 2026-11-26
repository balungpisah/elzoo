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
  checkpoints of other streams stay. An exact retry of a committed `retain`
  keeps the existing conflict result and deletes nothing more;
  `Elzoo.DurableLog.confirm_retention/2` confirms the original commit while
  its receipt is current. A refused or conflicting retention deletes no
  checkpoints.
- Add `:checkpoint_below_low_water` to the accepted Store rejection reasons
  (`Store.classify_write/2` turns an unlisted reason into
  `{:indeterminate, ...}`). Both adapters return
  `{:rejected, :checkpoint_below_low_water}` for a valid checkpoint below the
  locked or serialized stream `low_water`, and write nothing, so a late put
  cannot recreate a dead checkpoint. A valid checkpoint at or above
  `low_water`, no later than the head and with an unused key, still commits.
- `latest_checkpoint` and `read_checkpoint` never return a deleted
  checkpoint (`read_checkpoint` gives `{:ok, :absent}`).
- `Elzoo.Checkpoint`'s fallback to an earlier checkpoint (`find_earlier/5` in
  `pieces/state/checkpoint/lib/elzoo/checkpoint.ex`) probes one sequence at a
  time down to 0 when the newest checkpoint does not decode. With the
  checkpoints below `low_water` gone, that path would probe every pruned
  sequence with one Store call each. The fallback stops below the stream's
  `low_water` (read with the head) and returns the existing pruned result,
  so its Store calls are bounded by the distance from the failed checkpoint
  down to `low_water`. The `state/checkpoint` README states the bound in a
  `## Changes` entry.
- Both READMEs document that retention deletes records through `low_water`
  and checkpoints strictly below it. A checkpoint receipt needed for Writer
  reconciliation must be resolved before retaining past its anchor: after
  deletion, `confirm_checkpoint/2` returns `{:unknown, :unfenced}`, and that
  absence does not prove that the put failed. Each README records this in
  its `## Changes` section; each changed `piece.json` gets a new
  `manifest_sha256` in its `entries` row, with `note` equal to a changed
  `contract`.

Paths: `pieces/state/event-log/**`, `pieces/integration/sql/**`,
`pieces/state/checkpoint/**` (only for the fallback bound), the `entries` rows
of these Pieces in `docs/plans/release-plan.json`, and the generated
`LEDGER.md` and `docs/plans/views.md`. The tests of the ready Pieces that use
these Stores must pass unchanged, except an assertion that a checkpoint below
`low_water` survives retention (name each such change in the pull request).
New external dependencies: none.

## Acceptance

On both Stores:

- Write checkpoints at `a < b < c`, with `a` the only checkpoint of fold
  version 2 and `b` and `c` of fold version 1. Retain through `b`. The exact
  read of `a` returns `{:ok, :absent}`, latest for version 2 returns
  `{:ok, :none}`, and `b`, `c` and the other stream's checkpoints remain.
  Latest for version 1 still returns `c`.
- An exact retry of a committed `retain` keeps the existing conflict result
  and deletes nothing more; `Elzoo.DurableLog.confirm_retention/2` confirms
  the original commit while its receipt is current. A refused retention (no
  checkpoint at or above `through`, a pending outbox item, an `expected`
  conflict) deletes no checkpoint.
- `put_checkpoint` below `low_water` returns
  `{:rejected, :checkpoint_below_low_water}` through `Store.write/4` and
  writes nothing; at `low_water` and above it commits.
- PostgreSQL: a `put_checkpoint` below `through` that races the retention
  either commits first and is then deleted by it, or is refused after it;
  never a surviving checkpoint below `low_water` (lock order shown in the
  test).
- For `N > 1`, write valid same-version checkpoints at `N - 1` and `N`, then
  retain through `N`. Recover with a decoder that rejects the model at `N`.
  Assert `{:error, {:pruned, N}}` and zero `read_checkpoint` fallback calls on
  both Stores.
- A negative control: a temporary edit that skips the delete makes the first
  case fail (recorded and reverted).
- `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0, or the pull request records the exact reason a
  command cannot run on the host. The hosted check is green on the exact head.
- One independent review by the strongest available reviewer of another model
  family (the Pieces keep durable state), and the exact-head automated review
  with its threads answered and resolved, or the authorized replacement
  review under `AGENTS.md` section 6.
