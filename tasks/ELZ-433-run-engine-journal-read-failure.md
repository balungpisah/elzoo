# ELZ-433 — assembly/run-engine: a failed journal read ends in a defined result, never a match error

- Dependencies: ELZ-420

## Outcome and scope

`find_input/4` in `pieces/assembly/run-engine/lib/elzoo/run_engine.ex`
(about line 2678) reads the engine's own journal stream with
`{:ok, rows, head} = Elzoo.DurableLog.read(store, stream, from, 1_000)` and
`true = head.low_water == 0`. `Elzoo.DurableLog.read/4` can return
`{:error, :unavailable}` or `{:error, :gap}`, and a pruned stream has
`low_water > 0`. Any of these makes the engine process exit with a match
error in the middle of a call. Three callers are affected:

- `original_record/4` reads during ingress, to check a recorded protocol
  input;
- `admitted_action/2`;
- the read of the winner after an append returns `{:error, :input_id_conflict}`
  (about line 4449). There a missing winner is also reported as
  `{:error, :integrity_failure}`, even when the read itself failed.

The README defines storage halts (`storage_failure/2`) and says the exit of
an engine call says nothing about whether the input was applied. Neither
covers a read that failed before any write. The ELZ-419 wave 4 work found this
defect when a transient read failure stopped the engine in the middle of a
round. It is fixed in place under the same ID (the rule of ELZ-415).

- `find_input/4` returns its read failure instead of matching on success.
  `{:error, :unavailable}`, `{:error, :gap}` and a head with `low_water > 0`
  are all failures.
- In `original_record/4` and `admitted_action/2`, nothing has been appended.
  The call returns `{:error, :unavailable}` to its caller, the engine keeps
  running, and its committed state is unchanged.
- After `{:error, :input_id_conflict}`, a failed read of the winner ends in
  the existing storage halt with reason `:unavailable`, through
  `storage_failure/2`. Only a winner that was read and differs is
  `:integrity_failure`.
- The README states these results next to the storage halts and adds a
  `## Changes` entry. If `piece.json` changes, its `entries` row gets a new
  `manifest_sha256` and a `note` equal to the changed `contract`.

Paths: `pieces/assembly/run-engine/**`, its `entries` row in
`docs/plans/release-plan.json`, and the generated `LEDGER.md` and
`docs/plans/views.md`. New external dependencies: none.

## Acceptance

- Tests use a Store that fails one read on request (the fault fixtures of the
  run-engine tests). For each of the three callers, `{:error, :unavailable}`
  and `{:error, :gap}` each give the stated result. In the first two cases the
  engine process stays alive and a following call succeeds once the fault is
  cleared. A head with `low_water > 0` gives the same results.
- The conflict case: a winner that was read and differs is still
  `:integrity_failure`, and a failed read of the winner halts with
  `:unavailable`.
- Negative controls, each recorded and reverted: restore the bare match, which
  makes the engine exit in the first case; map a failed winner read to
  `:integrity_failure`, which makes the conflict case fail.
- The frozen-row and cold-recovery tests pass unchanged.
- `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0, or the pull request records the exact reason a
  command cannot run on the host. The hosted check is green on the exact head.
- One independent review by the strongest available reviewer of another model
  family (the Piece keeps durable state), and the exact-head automated review
  with its threads answered and resolved, or the authorized replacement review
  under `AGENTS.md` section 6.
