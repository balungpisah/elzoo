# ELZ-022 — Specify budget reservation and settlement

- Phase: demand-led workflow policy
- Catalogue IDs: workflow/budget (shared unit arithmetic also serves domain/quota)
- Dependencies: ELZ-003, ELZ-004

## Outcome

Bound the resource consumption of one Run with a reserve → call → settle
Contract whose admission check and reservation are one step. The pure
decision lives in Cure; one OTP owner process serializes it. This is a budget
of unit-tagged cost (tokens, calls, seconds, cents-as-estimate); it is not a
financial ledger, a rate limiter or a tenant quota.

## Admission record

1. **Responsibility and caller.** Decide whether a spend-bearing call may
   start under a cap, record the reservation atomically with that decision,
   and settle the observed cost afterwards. Callers: C2 (report run budget)
   and C6/C7 (bounded agent fan-out cost). C9's provider-cost reservation
   challenges generality with a second unit type.
2. **Interface and invariant.** Inputs: budget identity, cap, unit, estimate,
   opaque `cost_ref`, and later the observed actual. Outputs: `reserved`,
   `rejected{reason}`, `settled{refund}`. State owner: one budget owner per
   budget identity. Outputs: `reserved`, `rejected{reason}`,
   `settled{refund}` and `settled{overage}`. Invariant: admission preserves
   `committed + reserved <= cap` after any interleaving; settle replaces the
   reservation with the observed actual, never a capped or guessed figure;
   when the actual is below the reservation the difference is returned as
   `refund`, when it is above the difference is recorded as `overage` and
   committed may then exceed the cap (the gate bounds admission, the provider
   bounds the charge); remaining budget is reported as `max(cap - committed -
   reserved, 0)` and an owner in overage admits nothing until reset; refund
   and overage are derived from the (reservation, actual) pair, never a
   separate write; release/settle are idempotent per `cost_ref`; non-positive
   or non-finite amounts are rejected. Strict enforcement requires the caller
   to pass a provider-enforced maximum charge at or below the estimate; without
   one the Contract promises bounded admission, not a bounded total. Non-goals: pricing, currency conversion, durability
   beyond the owner's declared storage, cross-node agreement.
3. **Reuse check.** hammer (rate limiting) and a read-then-increment counter
   do not satisfy the concurrent-reservation requirement (C2 design test).
   Ash/AshMoney and ex_money own currency arithmetic if a product needs money;
   this Piece carries abstract units. Record why the remaining policy (one-step
   check-and-reserve, derived refund) is Elzoo's.
4. **Split test.** Check and reserve cannot be two callable halves; keep them
   behind one interface. Estimate policy, unit choice and the storage of the
   owner are separately chosen by the Assembly.
5. **Failure and evidence.** Dangerous paths: two concurrent reservations
   both admitted for the last unit; a crash between call and settle leaving a
   reservation open forever (explicit expiry/cancel path, visible in the
   Contract); an actual above the estimate silently dropped or capped; a
   missing policy must fail closed in a deployed release.
   Proofs: the admission-scoped cap law and idempotence laws over the pure
   transition (an overage state satisfies them by admitting nothing).
   Tests: owner serialization under concurrent callers, restart with open
   reservations, rejection paths. Upstream: OTP process semantics.
6. **Composition record.** Depends on core/envelope result schemas and the
   runtime/unit owner pattern. Delivery of settle is at-least-once, so settle
   must be idempotent per `cost_ref`. Data classification: usage figures, not
   secrets. Durable reservations compose with ELZ-009 only after that boundary
   exists; until then the Contract states volatile ownership.

## Scope

- define the pure reserve/settle/release transition and its result schema;
- implement the owner process with the smallest test double;
- select laws with an admission-only premise: every `reserved` result leaves
  `committed + reserved <= cap`, settle and release are idempotent per
  `cost_ref`, rejection paths; overage post-states are valid inputs to those
  laws, not counterexamples;
- test concurrent admission, expiry of an abandoned reservation and restart;
- document unit tagging, estimate-versus-actual (refund and overage) and the
  fail-closed default.

## Acceptance

- [ ] Concurrent callers cannot both reserve the last unit (executable test).
- [ ] Selected admission-scoped cap and idempotence laws run through mix check.
- [ ] An abandoned reservation has a documented, tested release path.
- [ ] An actual above its reservation settles as `overage`, committed carries
      the observed figure, remaining budget never reads positive while in
      overage, and the next admission is rejected (executable test).
- [ ] Contract states this is not money settlement, quota or rate limiting.
- [ ] Operational applicability is declared per docs/operational-contracts.md.

## Evidence and limits

Selected laws ground the named invariant on the pure transition; tests ground
owner serialization and listed scenarios. No durability, cross-node or
financial claim is made.

## Out of scope

No pricing, invoicing, journal posting, distributed budget or provider usage
collection.

## Reference

Shape observed in Raxol's spend gate and ledger reservations; see the pinned
rows in docs/research/orchestration-references.md. No code is copied.
