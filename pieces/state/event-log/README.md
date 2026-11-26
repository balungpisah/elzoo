# state/event-log

Validated canonical append/replay and conservative Store confirmation boundary, owning Writer shell and volatile Memory test double. Selected supplied-decision count_step laws only; no storage engine or delivery guarantee.

## Copy and providers

Select `state/event-log` with `mix elzoo.take`; the dependency-closed copy is
owned by the consuming application, without Elzoo.Application. See
[consuming](../../../docs/consuming.md). Piece dependencies: none.
Providers: `cure`, `elixir`, `otp`; exact versions,
source lists and claim-level grounding are in [piece.json](piece.json).
Cure is a build-time compiler; the compiled replay runs without Cure.Compiler.

## Boundary and limits

- Memory is volatile. No disk/fsync/replication, WAL, lease, tamper evidence or exactly-once claim.
- L1a–L5 cover count_step with supplied decisions only, not classify, refold equivalence, reducers, the Elixir shell or providers.
- Absence never proves non-commit; indeterminate writes stop the Writer. Unknown reconciliation requires deliberate fresh-nonce CAS or read-only inspection.
- Revisions/sequences are nonnegative signed-bigint values; versions/positions are positive signed-integer values; stored text is UTF-8 without NUL.
- Checkpoint support is optional and requires state/checkpoint; no checkpoint dependency is needed for replay, Store, Memory or ordinary Writer use.
- Store-only reason :caller_transaction (ELZ-032, same ID): the shell accepts the Store reply {:rejected, :caller_transaction} and the read error :caller_transaction, and confirm/5 returns {:unknown, :caller_transaction}. A third-party Store returning that reply was classed indeterminate before and is rejected now. The ID is kept because the change is strictly additive: the shell already trusts Store-only rejection reasons (:torn_repair_unsupported, :unfenced_tail), the value adds no new trust relationship, it is the only way to restore the integration/sql Contract without returning indeterminate, Memory never produces it, and no in-repo consumer matches the reasons exhaustively.
- Retention deletes the checkpoints it leaves unusable (ELZ-427, same ID): a committed Memory retain deletes the stream's records at or below through and, in the same state update, its checkpoints of every fold version with a sequence below through; checkpoints at or above through and those of other streams stay. A refused or conflicting retain, including an exact retry of a committed one, deletes nothing. put_checkpoint below the stream's low_water returns {:rejected, :checkpoint_below_low_water} and writes nothing, also for a key that retention deleted; Store.classify_write/2 accepts that reason from any Store (a third-party Store returning it was classed indeterminate before). A deleted checkpoint reads {:ok, :absent}, latest_checkpoint no longer returns it, and confirm_checkpoint/2 returns {:unknown, :unfenced}, which does not prove that the put failed: resolve a checkpoint receipt needed for Writer reconciliation before retaining past its anchor.

## Evidence and operations

- `test/elzoo/durable_log_test.exs`: Finite D1–D6/D18 replay, seed/truncation, reducer failure and validation scenarios; selected-law compilation and both negative controls, not universal recovery proofs.
- `test/elzoo/durable_log_memory_test.exs`: Volatile CAS, uncertainty/readback and staged-tail fault scenarios; ELZ-427: retention deletes the stream's checkpoints below through and keeps the rest, an exact retry and refused retention delete nothing, a put below low-water is refused through Store.write.
- `test/elzoo/durable_log_writer_test.exs`: Owning init, uniform damaged-seed refusal, conflict, indeterminate shutdown and post-commit failure scenarios.
- `test/elzoo/durable_log_domain_test.exs`: Core and Memory share the portable numeric/text domain; malformed/rejected cases.
- `test/elzoo/durable_log_conformance_test.exs`: K1–K11 against volatile Memory; named checks, error and missing-hook cases, not disk persistence.

- telemetry: **planned** — Damaged/torn states are returned values; no telemetry events emitted.
- config: **supported** — Start-time store, stream, fold specification and limits; no hot reconfiguration.
- control: **planned** — Writer supplies OTP start/stop only; no business pause/drain/resume contract.

See [ELZ-009](../../../docs/work/ELZ-009.md) for the binding result tables,
operator reconciliation paths, selected laws, provider comparisons and limits.
Proofs, finite tests, local monitored observations, upstream contracts and
consumer assumptions are distinct; no disk durability or exactly-once claim.

## Changes

- ELZ-427 (2026-11-26): a committed retain of the Memory Store now also deletes
  the stream's checkpoints with a sequence below `through`, of every fold
  version; before, it kept every checkpoint. `put_checkpoint` below the
  stream's `low_water` now returns `{:rejected, :checkpoint_below_low_water}`
  and writes nothing; before, it committed, or conflicted on an existing key.
  `read_checkpoint` of a deleted checkpoint returns `{:ok, :absent}`,
  `latest_checkpoint` no longer returns it, and `confirm_checkpoint/2` returns
  `{:unknown, :unfenced}`, which does not prove that the put failed.
  `Store.classify_write/2` accepts the new reason, so a Store that returns it
  is no longer classed indeterminate. How to move: resolve any checkpoint
  receipt that Writer reconciliation still needs before retaining past its
  anchor, and treat `:checkpoint_below_low_water` like
  `:checkpoint_beyond_tail`: nothing was written; take a checkpoint of a
  current replay instead.
