# Gates: elzoo bootstrap

Scope: A runnable fresh repository ready for autonomous development, with an architecture, revised catalogue and task backlog.

- [x] G1: Architecture and catalogue distinguish owned pieces, upstream reuse and deferred work.
  EVIDENCE: Reviewed docs/architecture.md, catalogue.md, dependencies.md and ADRs; owned/reused/deferred capabilities and present/target boundaries are explicit. Parent corrected P0 named-wiring scope to match ELZ-002/003.
- [x] G2: The pinned Mix project compiles Cure and passes meaningful proofs, runtime tests and negative controls.
  CHECK: mix check
  EXPECT: ELZOO CHECK PASSED
  EVIDENCE: Parent independently ran mix check: 8 tests passed, exit 0, ELZOO CHECK PASSED. Includes independent seeded model comparison, OTP restart, Jason translation, false-proof/type/hole rejection. Fresh-clone acceptance is recorded separately under G3. Linux CI run 42013712025 also passed.
- [x] G3: A clean checkout succeeds using the documented setup and check commands.
  EVIDENCE: Fresh remote clone at 3965fb2 had no deps/_build; mix setup and mix check both exited 0 (eight tests). Real failing-test and filtered-check probes exited 2/1 without success markers; source add/remove cleaned BEAM artifacts. See docs/development/07-bootstrap-validation.md.
- [x] G4: Agent instructions and dependency-ordered tasks permit an agent to start without oral context.
  EVIDENCE: Parent checked all 12 task bodies against DAG table and direct edges: acyclic, resolved IDs, exact agreement. Remote branch claims, distinct session IDs, push/merge progress, independent shared-account review, atomic archived handoff and cleanup are documented. ELZ-007 may run in parallel after ELZ-003. A disposable two-clone Git probe verified first-push claim exclusion, normal fast-forward handoff and exact-tip deletion refusal after a concurrent advance.
- [x] G5: A private balungpisah/elzoo remote contains the committed bootstrap and task backlog.
  EVIDENCE: GitHub API confirms private=true; origin/main contains bootstrap 3965fb2; issues #1–12 contain the scoped task bodies and dependency links. docs/development/02-task-dag.md maps all stable IDs to issues.
- [x] G6: Repository working tree is clean and bootstrap limitations are recorded.
  EVIDENCE: Fresh-clone git status was empty after probes; final integration commit is checked clean before handoff. docs/development/07-bootstrap-validation.md records actual checks, limitations and passing Linux CI run 42013712025. No task branches or worktrees were created in the project.
