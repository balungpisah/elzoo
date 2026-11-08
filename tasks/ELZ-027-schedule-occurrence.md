# ELZ-027 — Specify schedule occurrence identity and overlap policy

- Phase: demand-led delivery policy
- Catalogue IDs: delivery/trigger (schedule occurrence slice)
- Dependencies: ELZ-003

## Outcome

Decide whether a due schedule slot becomes one admissible occurrence, give it
a stable identity, and decide what happens to further slots while that
occurrence is unsettled. Due-instant computation stays upstream (Oban cron, quantum,
sched_ex) and enters as already computed due slots; the identity function
and the overlap decision are Elzoo's.

## Admission record

1. **Responsibility and caller.** Admit, identify and settle schedule
   occurrences under a declared overlap policy. Callers: C7 scheduled research
   digest; C1 invitation expiry sweep challenges generality (one-shot
   schedule).
2. **Interface and invariant.** Inputs: `{schedule id, generation, overlap policy ∈ {skip, queue(n),
   replace}}`, the due slots computed upstream since the last recorded
   instant, that last recorded instant, the current instant from a clock
   port, settlement events `{acknowledged | released, occurrence id}` and
   deliveries `{occurrence id, payload}` presented for admission.
   Outputs: `occurrence{id = f(schedule id, generation, scheduled instant)}`,
   `skipped{slot}`, `replaced{old occurrence id}`, `rejected{stale_generation}`.
   Identity excludes arrival time, node, process and delivery id. Invariants:
   at most `n` unsettled occurrences per schedule under `queue(n)`, at most
   one under `skip`/`replace`; a redefinition needs a strictly greater
   generation; a delivery is admitted only when its occurrence id and payload
   match an unsettled occurrence. The caller identifies each due slot passed
   while the scheduler was offline as an offline catch-up slot, using its
   retained last recorded instant and availability boundary; an offline
   catch-up slot becomes an occurrence only under `queue`, subject to its
   bound. Slots identified as live use the declared overlap policy. The caller
   supplies the availability boundary; elapsed time or a grace period alone
   does not establish whether a slot was offline. The overlap decision is
   recorded, never silent.
   Non-goals: cron parsing, transport, job execution.
3. **Reuse check.** Oban cron, sched_ex and quantum compute due instants; none
   exposes generation-scoped identity or an explicit overlap policy as a
   testable value. state/scheduler (Oban candidate) consumes occurrences; it
   does not define them.
4. **Split test.** Identity and overlap policy share the "one unsettled
   occurrence" invariant and stay together. Clock, transport and the consuming
   job are separate choices.
5. **Failure and evidence.** Dangerous paths: two activations both enqueue
   the same slot (identity must dedupe); a redefinition with an unchanged
   generation silently replacing pending work; a stale delivery of a settled
   occurrence re-admitted; offline catch-up flooding under `queue`. Proofs:
   identity determinism and the per-policy bound over the pure transition.
   Tests: restart with an unsettled occurrence, generation conflict, stale
   delivery, each overlap policy.
6. **Composition record.** Depends on the ready delivery/time recipe (clock port; no open task
   owns it), core/envelope
   result schema and delivery/idempotency on the consumer side; durable
   occurrences compose with ELZ-009 once available (volatile until then).
   Data classification: schedule metadata only.

## Scope

- define the pure occurrence transition and result schema;
- select laws for identity determinism and the per-policy bound;
- test the listed dangerous paths with a controllable clock.

## Acceptance

- [ ] Two activations of one slot yield one occurrence (executable test).
- [ ] Selected identity and bound laws run through mix check.
- [ ] Each overlap policy has a recorded decision in a listed scenario.
- [ ] Operational applicability is declared per docs/operational-contracts.md.

## Evidence and limits

Selected laws and listed scenarios; cron correctness and clock accuracy are
named upstream contracts.

## Out of scope

Webhook and app-event triggers (the rest of delivery/trigger), job execution,
durable scheduling providers.

## Reference

Shapes observed in jido 3.0.0-beta.2 schedule occurrences and the lux 0.5.0
scheduler negative example; see docs/research/ecosystem-round-2.md.
