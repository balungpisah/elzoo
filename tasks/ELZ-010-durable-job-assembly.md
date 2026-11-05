# ELZ-010 — Compose the P2 durable job Assembly

- Phase: P2 durable workflow
- Catalogue IDs: state/schema-evolution, state/scheduler, workflow/state-machine,
  integration/jobs, assembly/durable-job
- Dependencies: ELZ-008, ELZ-009

## Outcome

Use the durable-state boundary in one narrow workflow/job Assembly. Reuse a
maintained job/scheduler provider where it fits and keep job idempotency,
schema-version handling and state-machine decisions in explicit Contracts.

## Scope

- define job request, attempt, deadline, retry and completion schemas;
- use state-machine decisions in Cure and OTP/provider facilities for scheduling
  and execution;
- exercise schema evolution/upcast or explicitly defer it with a Contract;
- test restart/replay, duplicate job, retry exhaustion and cancellation;
- record whether the chosen job provider is reuse or adapt and why.

## Acceptance

- [ ] A named job flow survives the tested restart/replay boundary.
- [ ] Duplicate and retry outcomes are deterministic and idempotent at the
      declared boundary.
- [ ] Scheduler/provider behavior and version are recorded as upstream
      grounding; no provider implementation is presented as a Cure proof.
- [ ] mix check exercises success, failure and negative controls.
- [ ] The Assembly exposes its durable limits and does not claim all workflow
      patterns.

## Evidence and limits

Selected state-machine/replay proofs ground pure decisions; runtime tests ground
listed provider scenarios. Scheduling, storage and process behavior remain
upstream contracts or explicit assumptions.

## Out of scope

No generic workflow engine, distributed scheduler, consensus or product-specific
job fleet.

## Ash foundation reuse decision

Read ADR-0005 and the ELZ-015 spike limits. Evaluate AshPostgres/AshOban and
Reactor for the selected boundary before writing equivalent machinery. Do not
infer durable jobs, atomic state transitions or crash recovery from the ETS
spike. Record why the chosen provider fits this task's Contract; Ash remains
optional for unrelated pure Pieces.
