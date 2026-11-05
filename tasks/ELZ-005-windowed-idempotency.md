# ELZ-005 — Add a bounded windowed idempotency policy

- Phase: P1 message resilience
- Catalogue ID: delivery/windowed-idempotency
- Dependencies: ELZ-003, ELZ-004

## Outcome

Provide a deliberately bounded receiver policy for duplicate and stale input
within a declared window. It is a separate P1 policy layered on the volatile
P0 exemplar; it must not rewrite the P0 claim into durable or exactly-once
delivery. Its new ID is delivery/windowed-idempotency: delivery/idempotency and
its P0 consumers keep their existing exact-key, unbounded, volatile Contract.
The new Piece records its own sources, operational applicability and grounding.

## Scope

- define key/sequence/window configuration and state transition;
- specify first delivery, duplicate, in-window reorder and out-of-window input;
- keep the transition pure and composable through the typed boundary;
- add selected laws for duplicate idempotence/window bounds and boundary cases;
  test the actual receiver/detection transition, not only a precomputed duplicate
  flag. Label any helper-only proof narrowly and disclose receiver-level gaps;
- document per-sender ordering, retention and clock/delivery assumptions.

## Acceptance

- [ ] Window size and retention are explicit in the Contract.
- [ ] Duplicate input in the window does not emit twice.
- [ ] Out-of-window behavior is deterministic and tested.
- [ ] Selected laws and boundary tests run through mix check.
- [ ] Contract says this is not the complete historical receiver, durable
      storage or cross-sender ordering.

## Evidence and limits

Selected laws ground named window invariants; tests ground named sequence
cases. Ordering, delivery and clock assumptions are external/assembly
contracts. No exactly-once Effect claim is made.

## Out of scope

No replicated log, network transport, unbounded dedup set or P0 behavior rewrite.
