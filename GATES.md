# Gates: elzoo bootstrap

Scope: A runnable fresh repository ready for autonomous development, with an architecture, revised catalogue and task backlog.

- [x] G1: Architecture and catalogue distinguish owned pieces, upstream reuse and deferred work.
  EVIDENCE: Reviewed docs/architecture.md, catalogue.md, dependencies.md and ADRs; owned/reused/deferred capabilities and present/target boundaries are explicit. Parent corrected P0 named-wiring scope to match ELZ-002/003.
- [x] G2: The pinned Mix project compiles Cure and passes meaningful proofs, runtime tests and negative controls.
  CHECK: mix check
  EXPECT: ELZOO CHECK PASSED
  EVIDENCE: Parent independently ran mix check: 8 tests passed, exit 0, ELZOO CHECK PASSED. Includes independent seeded model comparison, OTP restart, Jason translation, false-proof/type/hole rejection. Fresh-clone acceptance is recorded separately under G3.
- [ ] G3: A clean checkout succeeds using the documented setup and check commands.
  EVIDENCE: pending
- [x] G4: Agent instructions and dependency-ordered tasks permit an agent to start without oral context.
  EVIDENCE: Parent checked all 12 task bodies against DAG table and direct edges: acyclic, resolved IDs, exact agreement. Remote branch claims, distinct session IDs, push/merge progress, independent shared-account review, atomic archived handoff and cleanup are documented. ELZ-007 may run in parallel after ELZ-003. A disposable two-clone Git probe verified first-push claim exclusion, normal fast-forward handoff and exact-tip deletion refusal after a concurrent advance.
- [ ] G5: A private balungpisah/elzoo remote contains the committed bootstrap and task backlog.
  EVIDENCE: pending
- [ ] G6: Repository working tree is clean and bootstrap limitations are recorded.
  EVIDENCE: pending
