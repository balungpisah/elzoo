# ELZ-016 — Declare telemetry/config/control and exercise runtime operation

- Phase: P0 operational contract
- Dependencies: ELZ-015

## Outcome

Carry Zoo's applicable telemetry/config/control contracts into Elzoo without
requiring every pure Piece to expose a runtime interface. Independent of Gleam.

## Scope and acceptance

- [ ] Define Telemetry, Config and Control, applicability/inheritance, desired vs effective configuration, revision conflict, transition timing, authority, receipts and failure semantics.
- [ ] Require honest operational applicability metadata on all ready source bundles; validate it and generate its ledger representation. Preserve existing behavior and readiness.
- [ ] Extend the isolated Ash experiment with a tenant-scoped volatile admission controller: bounded concurrency, versioned config, pause/drain/resume, named completion, redacted telemetry, direct/tool authorization and stale revision rejection.
- [ ] Test dangerous paths including concurrent config writes, denied calls, lowered limits with active work, drain behavior, duplicate completion and observer failure. State delivery/durability limits explicitly.
- [ ] Keep pure decision code free of effects; report tests/upstream contracts without claiming a new Cure proof or production adoption. Record where selected Cure laws would be useful.
- [ ] Run full mix setup/check, independent review, Linux CI, integration and cleanup. Align the next task's contract with these semantics.

No new global control service, UI, automatic LLM governor, arbitrary runtime eval,
durable receipts or production admission service is delivered by this task.
