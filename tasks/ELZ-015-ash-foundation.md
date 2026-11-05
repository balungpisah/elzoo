# ELZ-015 — Evaluate Ash as an application foundation and define the fork policy

- Phase: P0 foundation evaluation
- Dependencies: ELZ-014
- User-authorized Ash proof-of-fit before autonomous implementation prompts.

## Outcome

Exercise Ash as the preferred candidate foundation for application actions,
authorization and resource lifecycle, preserving independently consumable
Cure/Elixir Pieces. Establish a maintained-fork policy for MIT dependencies.

## Scope

- Isolated, locked Mix spike under spikes/ash_foundation; no compulsory Ash dependency for source consumers.
- Tenant-scoped work-item actions and authorization; valid and invalid transitions; direct and agent-tool callers share the same action and authority checks.
- Exercise background execution with an explicitly volatile OTP task; no durable-job claim.
- Exercise a selected existing Cure decision through an explicit Elixir boundary if suitable; retain the existing Cure grounding harness.
- Integrate reproducible spike checks with mix setup/check and CI; record precise versions, evidence and limitations.
- ADR distinguishes preferred application foundation from mandatory composition kernel. Revisit downstream task provider selection, without marking untested capabilities ready.
- MIT fork policy: concrete trigger, balungpisah ownership, upstream provenance/notices, immutable pins, delta tests and maintenance/upstream synchronization obligations. No speculative forks.

## Acceptance

- [ ] Repeatable tests reject unauthenticated, unauthorized, cross-tenant and invalid-transition calls, including the tool path.
- [ ] A valid caller can create, inspect and complete a work item through the shared action boundary, including background invocation.
- [ ] The spike states volatility, trusted host context, concurrency and non-goals; no financial, persistence or complete agent-orchestration claims.
- [ ] Foundation decision and capability mappings distinguish evaluated behavior from candidates and production adoption.
- [ ] Fork policy preserves upstream license/provenance and records who owns modified behavior; no fork is created without a concrete need.
- [ ] Full mix check and independent review pass; PR integration and Linux CI follow the repository workflow.
