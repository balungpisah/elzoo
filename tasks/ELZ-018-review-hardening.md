# ELZ-018 — Resolve pre-dispatch adversarial review findings

- Phase: P0 handoff hardening
- Dependencies: ELZ-017

## Outcome

Resolve the review of c896bce before dispatching ELZ-002, preserving scoped ready behavior and keeping deferred capabilities out of implementation scope.

## Scope and acceptance

- [ ] Resolve C1–C4: explicit typed/metadata boundary, single owners for field groups, merge-time acceptance and ready Contract evolution rule.
- [ ] Resolve A1–A4 and D1: separate bounded-idempotency identity, parallel timeout ownership, consumer-owned supervision, consistent Config applicability and application/library namespace policy.
- [ ] Fix D2–D3: compiler-only Cure installation guidance with tested-version versus consumer-resolution distinction; CI rejects tracked claim markers.
- [ ] Resolve E1–E4: narrow idempotency proof wording, move negative controls/audits to owning bundles, audit coverage wording, require supported operational test references.
- [ ] Resolve E5 and synchronize published task bodies/dependency history after merge.
- [ ] Add deferred C9 metering/pricing/LLM routing-resale coverage with explicit boundaries and no implementation claim.
- [ ] Run meaningful negative controls, isolated consumer checks and full mix check; independent review of contracts/validator/export/CI changes; Linux CI before merge and clean handoff.

No implementation of ELZ-002 or later tasks. Preserve existing proof strength and operational behavior. Review report is provided in the coordinating conversation; the work report maps each finding to its resolution and evidence.
