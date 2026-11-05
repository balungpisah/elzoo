# Gates: workflow

Scope: Autonomous agents can pick and finish scoped work using a small standard workflow.

- [x] W1: AGENTS.md and GOAL.md define read order, autonomy, boundaries, done criteria, blocked-work handling and concurrency without porting Zoo's task engine.
  EVIDENCE: AGENTS.md (read order, ownership, synchronization, blocked/stale handling, review and cleanup); GOAL.md (standing goal and done criteria).
- [x] W2: Initial tasks have stable IDs, dependencies, scope and runnable or concrete acceptance criteria; the first task is independently actionable.
  EVIDENCE: docs/development/02-task-dag.md; tasks/ELZ-001-pinned-mix-cure-harness.md through tasks/ELZ-012-clean-check-evidence-handoff.md. ELZ-001 is the bootstrap harness task's current action; ELZ-002 follows its merged acceptance.
- [x] W3: Workflow supports isolated worktrees and a race-resistant task claim using ordinary Git/GitHub, reviews and cleanup; no hidden task service is required.
  EVIDENCE: AGENTS.md Claim/Review/Merge sections; docs/development/01-workflow.md; docs/development/05-stale-claims.md.
- [x] W4: Guidance distinguishes proof, tests, monitored behavior and upstream assumptions, and explains version-pinned Cure/Elixir development.
  EVIDENCE: docs/development/03-claims-and-evidence.md; docs/development/06-toolchain.md; task evidence/limits sections.
