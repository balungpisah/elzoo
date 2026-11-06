# state/outbox

Validated committed pending offers, right-parsed derived idempotency keys and nonce-bound acknowledgement CAS through the Store; no effect dispatch.

## Copy and providers

Select `state/outbox` with `mix elzoo.take`; the dependency-closed copy is
owned by the consuming application, without Elzoo.Application. See
[consuming](../../../docs/consuming.md). Piece dependencies: `state/event-log`.
Providers: `elixir`, `otp`; exact versions,
source lists and claim-level grounding are in [piece.json](piece.json).
Cure is a build-time compiler; the compiled replay runs without Cure.Compiler.

## Boundary and limits

- Pending may be offered repeatedly until acked; no exactly-once effects or guaranteed delivery.
- Consumer dispatch/failure policy is separate from durable state; persistence depends on the selected Store.
- No scheduler, retry loop, dispatcher or external-effect confirmation is supplied.

## Evidence and operations

- `test/elzoo/outbox_test.exs`: Finite pending/ack, repeated-offer, key parsing, malformed input, nonce confirmation, retention and reader-write audit scenarios against Memory.

- telemetry: **not_applicable** — Callable offers/ack boundary with no emitted telemetry.
- config: **supported** — Per-call pending limit; declared destination and payload limits come from the Store configuration.
- control: **not_applicable** — No dispatcher process or lifecycle is supplied.

See [ELZ-009](../../../docs/work/ELZ-009.md) for the binding result tables,
operator reconciliation paths, selected laws, provider comparisons and limits.
Proofs, finite tests, local monitored observations, upstream contracts and
consumer assumptions are distinct; no disk durability or exactly-once claim.
