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

## Evidence and operations

- `test/elzoo/durable_log_test.exs`: Finite D1–D6/D18 replay, seed/truncation, reducer failure and validation scenarios; selected-law compilation and both negative controls, not universal recovery proofs.
- `test/elzoo/durable_log_memory_test.exs`: Volatile CAS, uncertainty/readback and staged-tail fault scenarios.
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
