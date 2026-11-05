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
- specify corruption, truncation and unavailable-storage outcomes;
- specify the read model as a deterministic fold over the log: refolding
  any prefix yields the same model, a duplicate record is ignored and an
  out-of-order record is recorded as a diagnostic result rather than
  silently dropped, and a forward gap keeps surviving records but returns
  the model with a damaged flag that the shell may report as Telemetry;
- distinguish a torn final record (crash mid-append; tolerated on read;
  only the owning writer may repair it when it next opens the log) from interior
  corruption (fail closed with the longest valid prefix and a damaged
  result); readers never truncate or repair a live log;
- keep durable records and reconstructable ephemeral updates in distinct
  tiers; no durable state may depend on an ephemeral update having been
  observed;
- record, for the later state/audit-log task, whether an append-time hash
  chain over canonical records is needed; a decision, not a default
  implementation
  (ELZ-021 reference study).

## Acceptance

- [ ] Storage candidate selection is justified by executable boundary checks,
      not documentation alone.
- [ ] Simulated restart/replay reconstructs declared state and does not emit a
      committed item twice.
- [ ] Acknowledgement occurs only at the documented commit point.
- [ ] Failure/corruption/unavailable cases have explicit results and tests.
- [ ] Interior corruption yields the longest valid prefix and a damaged
      result; a torn tail is recovered without any reader-side write.
- [ ] Refolding a prefix is deterministic and duplicate records do not
      change the model (selected replay law or listed test).
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

## Ash foundation reuse decision

Read ADR-0005 and the ELZ-015 spike limits. Evaluate AshPostgres/AshOban and
Reactor for the selected boundary before writing equivalent machinery. Do not
infer durable jobs, atomic state transitions or crash recovery from the ETS
spike. Record why the chosen provider fits this task's Contract; Ash remains
optional for unrelated pure Pieces.
