# ELZ-009 — Define a reuse-first durable state boundary

- Phase: P2 durable workflow
- Catalogue IDs: state/event-log, state/outbox, state/checkpoint
- Dependencies: ELZ-008

## Outcome

Define the durable-state boundary needed by a real workflow and select a
maintained storage implementation where it satisfies the Contract. Elzoo owns
append/replay/checkpoint/ack semantics; it does not rebuild a WAL or database
when an existing provider is suitable.

## Scope

- define append, replay, checkpoint, tail retention and outbox commit/ack
  contracts;
- compare a concrete maintained OTP/storage candidate and record the selected
  version, assumptions and failure behavior;
- implement the smallest Adapter boundary and test double;
- exercise crash/restart/replay, duplicate and partial-commit cases;
- specify corruption, truncation and unavailable-storage outcomes.

## Acceptance

- [ ] Storage candidate selection is justified by executable boundary checks,
      not documentation alone.
- [ ] Simulated restart/replay reconstructs declared state and does not emit a
      committed item twice.
- [ ] Acknowledgement occurs only at the documented commit point.
- [ ] Failure/corruption/unavailable cases have explicit results and tests.
- [ ] mix check runs selected replay law(s), runtime tests and negative controls.
- [ ] Contract labels provider guarantees as upstream; no local test is called
      proof of disk/replication semantics.

## Evidence and limits

Pure replay laws ground the named invariant. Adapter tests ground listed
provider translations and failures. Actual disk, transaction and replication
semantics remain provider contracts; no consensus or cross-host claim is made.

## Out of scope

No hand-written WAL, second storage engine, replication protocol or product
database schema.
