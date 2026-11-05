# ELZ-004 — Build the P0 ingest/dedup/accumulate exemplar

- Phase: P0 bootstrap
- Catalogue IDs: runtime/unit, runtime/supervision, runtime/host, runtime/adapter,
  integration/json, assembly/ingest-dedup-accumulate
- Dependencies: ELZ-002, ELZ-003

## Outcome

Compose one small pure ingest, idempotency and accumulation flow and run its
decision directly and behind a supervised OTP Unit. Exercise Jason at one
explicit Adapter boundary. This is a volatile bootstrap exemplar, not a
bounded durable receiver.

The bootstrap already provides a working pure/OTP/Jason sample. This task
adapts and completes that sample against the named contracts and wiring from
ELZ-002/003, preserving its existing tests and scoped guarantees.

## Scope

- implement the pure Operator/Assembly through the ELZ-002/003 boundaries;
- use OTP GenServer/Supervisor/Application for lifecycle and restart;
- route JSON requests/results through an Adapter with declared errors;
- compare direct/fused and OTP traces for named inputs;
- record volatile state, mailbox and restart limits.

## Acceptance

- [ ] Pure and OTP paths produce the same result for the named traces.
- [ ] Supervisor restart and expected Adapter failure are executable tests.
- [ ] Jason success/invalid-input translation is tested and its upstream
      contract is recorded.
- [ ] mix check runs selected proof(s), runtime tests and negative controls.
- [ ] Contract explicitly says the flow is not bounded, durable or a complete
      old Zoo receiver.

## Evidence and limits

Selected Cure laws ground only the pure transition. ExUnit/OTP tests ground
listed traces and restart behavior. Jason and OTP behavior are upstream
contracts. No cross-host, durable or exactly-once claim is made.

## Out of scope

No durable storage, network transport, complete wiring validator or historical
402-pattern port.
