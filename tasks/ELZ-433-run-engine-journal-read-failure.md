# ELZ-433 — assembly/run-engine: a failed journal read ends in a defined result, never a match error

- Dependencies: ELZ-420

## Outcome and scope

`find_input/4` in `pieces/assembly/run-engine/lib/elzoo/run_engine.ex`
(about line 2678) reads the engine's own journal stream with
`{:ok, rows, head} = Elzoo.DurableLog.read(store, stream, from, 1_000)` and
`true = head.low_water == 0`. `Elzoo.DurableLog.read/4` can return
`{:error, :unavailable}`, `{:error, :malformed}` (the Store layer's result for
a reply it cannot accept, a `:gap` reply included) or
`{:error, {:pruned, low_water}}` when the scan starts below the retention
boundary. A successful page can also carry a head with `low_water > 0`, which
cannot establish a complete history. Any of these makes the engine process
exit with a match error in the middle of a call. Three lookups are affected:

- `original_record/4`, used by ingress (`input/4`) and by `control/4` (pause,
  continue and cancel);
- `admitted_action/2`, the second lookup of a retried settled outcome
  (`recheck_settled/5`); a failure there raises today, and once `find_input/4`
  returns it, the `nil` fallback of `recheck_settled/5` would discard it;
- the read of the winner after `DurableUnit.step/3` returns
  `{:error, :input_id_conflict}` from its completed-ID check (about line
  4449).

The README defines storage halts (`storage_failure/2`) and says the exit of
an engine call says nothing about whether the input was applied. Neither
covers a read that failed before any write. The ELZ-419 wave 4 work found this
defect when a transient read failure stopped the engine in the middle of a
round. It is fixed in place under the same ID (the rule of ELZ-415).

- `find_input/4` returns `{:error, :unavailable}` for every failed or
  incomplete read listed above instead of matching on success. A complete
  scan that finds no record returns `nil`, as today.
- A failed `original_record/4` lookup commits nothing for the submitted input
  or control. The public call returns `{:error, :unavailable}`: `input/4` and
  `control/4` alike, never `:invalid_control` or `:cancel_unknown`. The engine
  keeps running. A Run-view synchronization that `current/1` completed before
  the lookup stays committed.
- A failed `admitted_action/2` lookup on a retried settled outcome makes that
  retry return `{:error, :unavailable}` and commit nothing; it is not
  discarded.
- After `{:error, :input_id_conflict}`, a failed read of the winner ends in
  the existing storage halt with reason `:unavailable`, through
  `storage_failure/2`. A complete scan that finds no winner contradicts the
  completed-ID record and still halts with `:integrity_failure`, as does a
  winner that was read and differs on `:kind`, `:request` or `:occurrence`
  (the existing comparison).
- The README states these results next to the storage halts and adds a
  `## Changes` entry. If `piece.json` changes, its `entries` row gets a new
  `manifest_sha256` and a `note` equal to the changed `contract`.

Paths: `pieces/assembly/run-engine/**`, its `entries` row in
`docs/plans/release-plan.json`, and the generated `LEDGER.md` and
`docs/plans/views.md`. New external dependencies: none.

## Acceptance

- Tests use a Store that fails one read on request (the fault fixtures of the
  run-engine tests). For each lookup, `{:error, :unavailable}`,
  `{:error, :malformed}`, `{:error, {:pruned, low_water}}` and a successful
  page whose head has `low_water > 0` each give the stated result.
- `original_record/4`: through `input/4` and through `control/4` for pause,
  continue and cancel, the public call returns `{:error, :unavailable}`. No
  journal record is added for the submitted ID, the engine process stays
  alive, and the same call succeeds once the fault is cleared.
- `admitted_action/2`: on a retried settled outcome, the second lookup fails
  (the first succeeds). The retry returns `{:error, :unavailable}` and commits
  nothing. After the fault is cleared, the same retry on the same engine
  returns `{:ok, :duplicate}`.
- The conflict case: a failed read of the winner halts with `:unavailable`;
  a complete scan with no winner, and a winner that differs on `:kind`,
  `:request` or `:occurrence`, still halt with `:integrity_failure`.
- Negative controls, each recorded and reverted: restore the bare match,
  which makes the engine exit in the ingress case; let control map the
  failure through its existing else clause, which gives `:invalid_control`;
  discard the `admitted_action/2` failure as `nil`; map a failed winner read
  to `:integrity_failure`.
- The frozen-row and cold-recovery tests pass unchanged.
- `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0, or the pull request records the exact reason a
  command cannot run on the host. The hosted check is green on the exact head.
- One independent review by the strongest available reviewer of another model
  family (the Piece keeps durable state), and the exact-head automated review
  with its threads answered and resolved, or the authorized replacement review
  under `AGENTS.md` section 6.
