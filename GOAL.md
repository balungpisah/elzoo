# Elzoo standing goal

Build a source catalogue of honest, composable Cure/Elixir Pieces for reliable
systems. Developers take selected pieces into their own applications and own
the copied source and wiring. A Piece has an explicit interface, Contract and evidence. Pure
decision logic belongs in Cure where it fits; Elixir/OTP and maintained
libraries provide runtime/integration behavior; Adapters perform Effects at
declared boundaries.

This is a fresh project, not a promise to recreate the old Zoo repository or
all 402 historical patterns. Start with one small Assembly that demonstrates
typed composition, a bounded receiver, durable-state boundaries, a
representative Effect and an OTP Host. Add new owned policies when an Assembly needs them. Direct-library Recipes
can be adopted independently when their concrete usage is tested and scoped
in the Piece Ledger.

The reusable capability model spans SaaS, identity, money, task management
and agent orchestration. Coverage is recorded in docs/capability-coverage.md;
these are design cases, not implemented products or a quota of pieces to build.
Use existing libraries where their Contracts fit. Write only the missing policy
needed by a selected Assembly, using docs/capability-model.md to choose its seam.

## Working order

1. Read CONTEXT.md, this file, docs/development/01-workflow.md and
   docs/development/02-task-dag.md.
2. Read the selected task body and its architecture/catalogue dependencies.
   PLAN.md, GATES.md and gates/*.md are needed for bootstrap integration, not
   as a permanent lifecycle requirement.
3. Claim its deterministic task/ELZ-### branch with the Git push protocol in
   AGENTS.md before implementation.
4. Implement only its interface and Contract, selected proofs, tests and
   adapter/runtime boundary.
5. Run mix check, report scoped evidence, obtain risk-appropriate review and
   open a PR.
6. The coordinator merges, deletes the branch, removes the worktree and closes
   the issue only after acceptance is true on the merged commit.

The task bodies and task DAG enumerate the stable ELZ IDs. Architecture may rename a
provisional handle before publication, but must preserve IDs and dependency
edges.

## Done means grounded and bounded

A task is done only when all dependencies are merged, the implementation and
Contract match its issue, selected checks run through mix check, external
contracts are named rather than presented as proofs, required independent
review is complete, and merged commit/cleanup are recorded.

Proof, test, monitor and upstream contract remain distinct claims. Passing a
test does not prove an unbounded property. Better wording does not upgrade
evidence. A known limitation is a successful handoff when stated clearly.

## Batch boundary

The bootstrap is intentionally narrow. A bounded receiver is not the complete
historical receiver; a storage adapter is not a replicated database; one
effect adapter is not an integrations catalogue. Add a new issue and dependency
edge when a real Assembly needs a capability. Do not open 402 placeholders or
require proof for every external operation.

See AGENTS.md and docs/development/01-workflow.md for pick, claim, work,
verify, review, merge and cleanup.
