# ELZ-008 — Compose the P1 request/route/retry Assembly

- Phase: P1 message resilience
- Catalogue ID: assembly/request-route-retry
- Dependencies: ELZ-004, ELZ-005, ELZ-006, ELZ-007

## Outcome

Compose the selected delivery Pieces into a working message-resilience
Assembly: typed request/reply, routing/transformation, bounded idempotency,
retry/timeout, backpressure and dead-letter behavior.

## Scope

- wire compatible Ports/Edges and use ELZ-007 selection rather than bypassing
  Contracts;
- exercise direct/fused and OTP hop placement where both are claimed;
- demonstrate success, duplicate, timeout, retry exhaustion, overflow and
  dead-letter paths;
- state the delivery class, ordering and failure assumptions.

## Acceptance

- [ ] Assembly topology is visible and all connections pass the typed checks.
- [ ] mix check exercises the happy path and every named boundary/failure case.
- [ ] No rejected message is silently dropped, and retry limits are observed.
- [ ] Contract distinguishes at-most-once local behavior, at-least-once
      assumptions and any unimplemented durable guarantee.
- [ ] Architecture/catalogue identifies reused versus owned components.

## Evidence and limits

Component laws retain their own scope. Runtime tests ground listed traces and
negative cases. Same-VM OTP tests do not prove network partitions or crash
atomicity.

## Out of scope

No durable event log, broker, deployment or all-pattern messaging catalogue.
