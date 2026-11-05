# ELZ-003 — Bind envelopes, edges and the first wiring shape

- Phase: P0 foundation
- Catalogue IDs: core/envelope, core/edge, core/wiring
- Dependencies: ELZ-001, ELZ-002

## Outcome

Define a minimal versioned Envelope and named Port/Edge/Wiring shape that the
typed boundary can inspect. Distinguish fused calls from hop messages without
claiming durable transport.

## Scope

- define required identity/schema/kind fields and explicit optional metadata;
- define fused versus hop placement and the delivery policy carried by a Port;
- represent one legal unit/port/edge binding and one incompatible/required-route
  rejection;
- keep message payload separate from telemetry and sensitive data;
- document volatile OTP mailbox assumptions and unspecified delivery cases.

## Acceptance

- [ ] Legal envelope and wiring examples pass the type/contract check.
- [ ] Missing required field, incompatible schema or invalid route is rejected
      by an executable negative control.
- [ ] Fused and hop semantics are described without exactly-once or durability
      claims.
- [ ] mix check exercises the positive and negative paths.
- [ ] The shape is usable by the P0 assembly without a custom wiring CLI.

## Evidence and limits

Type/contract checks and listed executable scenarios ground the boundary.
Transport ordering, mailbox loss and crash gaps remain OTP/upstream or
assembly assumptions.

## Out of scope

No generated manifest, network broker, durable log or full graph validator.
