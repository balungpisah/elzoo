# state/checkpoint

Bounded immutable full-prefix checkpoints and fail-closed recovery through the Store boundary; preserves model, complete cursor and identity witnesses.

## Copy and providers

Select `state/checkpoint` with `mix elzoo.take`; the dependency-closed copy is
owned by the consuming application, without Elzoo.Application. See
[consuming](../../../docs/consuming.md). Piece dependencies: `state/event-log`.
Providers: `elixir`, `otp`; exact versions,
source lists and claim-level grounding are in [piece.json](piece.json).
Cure is a build-time compiler; the compiled replay runs without Cure.Compiler.

## Boundary and limits

- Size grows O(applied) with the seen index; oversize snapshots are refused, not truncated.
- Storage guarantees are inherited from the supplied Store; no disk durability, exactly-once or universal refold-equivalence proof.
- Readers never repair or mutate storage. A damaged snapshot cannot anchor retention; pruned recovery without an anchor fails closed.
- Fallback after an invalid latest checkpoint probes earlier sequences one read at a time; cost grows with the gap (no indexed predecessor lookup). The probes stop below the stream's low_water read with the head (ELZ-427): a checkpoint exactly at low_water stays eligible, and on a pruned stream (low_water > 0) with none from the failed checkpoint down to low_water recovery returns the pruned result, so the probes are bounded by that distance, not by the pruned sequences; an unpruned stream still replays from sequence 1.

## Evidence and operations

- `test/elzoo/checkpoint_test.exs`: Finite take/recover, version/digest fallback, complete-seed preservation, checkpoint_too_large, terminal damage, pruned recovery and reader-write audit scenarios; ELZ-427: after a retention through N, a rejected checkpoint at N gives the pruned result with no fallback read, and a checkpoint exactly at low-water still seeds, counted through the Store calls.

- telemetry: **not_applicable** — Callable checkpoint boundary; no events or independent instrumentation lifecycle.
- config: **supported** — Per-call fold_version and model codec; store snapshot form carries max_checkpoint_bytes.
- control: **not_applicable** — No independent runtime lifecycle to pause, drain or resume.

See [ELZ-009](../../../docs/work/ELZ-009.md) for the binding result tables,
operator reconciliation paths, selected laws, provider comparisons and limits.
Proofs, finite tests, local monitored observations, upstream contracts and
consumer assumptions are distinct; no disk durability or exactly-once claim.

## Changes

- ELZ-427 (2026-11-26): `recover/5` stops its fallback to an earlier
  checkpoint below the stream's `low_water`, which it reads with the head; a
  checkpoint exactly at `low_water` still seeds recovery. Before, after an
  invalid or undecodable latest checkpoint it read one checkpoint per sequence
  down to 0. Retention now deletes the checkpoints below `low_water`
  (state/event-log and integration/sql, same task), so that walk would cost one
  Store call per pruned sequence. On a pruned stream (`low_water > 0`) with no
  usable checkpoint from the failed one down to `low_water`, recovery returns
  `{:error, {:pruned, low_water}}`, as before; an unpruned stream still
  replays from sequence 1. One result changes, on the fallback only: it no
  longer reaches a checkpoint below `low_water` that an earlier retention left
  in a PostgreSQL table, so such a checkpoint with terminal damage (corrupt or
  truncated) is no longer returned as the damaged model through the fallback;
  recovery returns the pruned result instead. If such a checkpoint is still
  the latest of its fold version, recovery reads it as before. Nothing to
  move; to remove such rows, see the `## Changes` entry of integration/sql.
