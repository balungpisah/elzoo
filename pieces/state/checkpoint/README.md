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

## Evidence and operations

- `test/elzoo/checkpoint_test.exs`: Finite take/recover, version/digest fallback, complete-seed preservation, checkpoint_too_large, terminal damage, pruned recovery and reader-write audit scenarios.

- telemetry: **not_applicable** — Callable checkpoint boundary; no events or independent instrumentation lifecycle.
- config: **supported** — Per-call fold_version and model codec; store snapshot form carries max_checkpoint_bytes.
- control: **not_applicable** — No independent runtime lifecycle to pause, drain or resume.

See [ELZ-009](../../../docs/work/ELZ-009.md) for the binding result tables,
operator reconciliation paths, selected laws, provider comparisons and limits.
Proofs, finite tests, local monitored observations, upstream contracts and
consumer assumptions are distinct; no disk durability or exactly-once claim.
