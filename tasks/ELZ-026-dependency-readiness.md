# ELZ-026 — Specify dependency readiness and cycle admission

- Phase: demand-led workflow policy
- Catalogue IDs: workflow/dependency-graph
- Dependencies: ELZ-003

## Outcome

A pure decision over Work Items, typed prerequisite edges and satisfaction
facts: which items are ready, which are blocked and why, and whether a new
blocking edge may be admitted without creating a cycle. Graph mechanics may
come from libgraph; the satisfaction and admission policy is Elzoo's.

## Admission record

1. **Responsibility and caller.** Decide readiness, blockers and edge
   admission from items, edges, facts and `now`. Callers: C5
   (`assembly/task-workflow` prerequisites) and C6 (bounded child runs). C7
   challenges generality: its prerequisite is a time or trigger fact, not
   another Work Item.
2. **Interface and invariant.** Inputs: `items{id, lifecycle, deferral}`,
   `edges{from, to, kind ∈ {blocking, informational, hierarchy}}`,
   `facts{prerequisite → satisfied | unsatisfied | unknown, source, expiry}`,
   `now`, `propose_edge{from, to, kind}`. Outputs: `ready` (ordered by the
   declared policy), `blocked{id, blockers[{target, present, satisfied,
   reason}]}`, `admit | reject{cycle path}`; a validation report with three
   non-collapsing issue kinds: duplicate node, unknown dependency, cycle (a
   cycle report names every unplaceable node). State owner: the Assembly that
   owns the Work Items; this Piece is pure. Invariants: a blocking edge is
   admitted iff the target cannot already reach the source; a cancelled or
   closed-without-completion prerequisite never satisfies a blocking edge,
   only an explicit `satisfied` fact or an accepted completion does; hierarchy
   edges never block; `unknown` or expired facts are unsatisfied; readiness is
   a function of its inputs only (no clock read, no I/O); the explanation is
   derived from the same predicates as the decision; readiness evidence is
   provenance-tagged (tool result, artifact reference, event fold,
   model-declared) and a model-declared value never by itself makes a
   dependant runnable. Non-goals: execution, claiming, notification, DAG
   templates.
3. **Reuse check.** libgraph (orchestration-references.md row) supplies
   reachability and topological sort; the satisfaction policy, failure
   handling (block/skip/fail per C5) and issue vocabulary are Elzoo's. Reactor
   and AshOban resolve executed-step dependencies, evaluated by ELZ-009/010,
   not durable Work Item prerequisites. The studied bankai graph shows the
   policy is small; its daemon shows what not to do (step 5).
4. **Split test.** Cycle admission and readiness share the edge set and
   satisfaction semantics and stay behind one interface. Ordering policy,
   deferral policy and the external-fact Adapter are separate choices.
5. **Failure and evidence.** Dangerous paths: two concurrent edge additions
   each pass a snapshot cycle check and each commit its own head, producing a
   cycle (concurrent admission must lock both endpoints or re-validate inside
   one commit); a closed item treated as satisfying; a topological sort that
   appends cycle members instead of failing; a stale external fact treated as
   satisfied. Proofs: admitted-edge acyclicity and "unknown never satisfies"
   over the pure reducer. Tests: concurrent admission, closed-vs-completed,
   expired fact, explanation equals decision, the three issue kinds.
6. **Composition record.** Depends on core/operator, the workflow/work-item
   lifecycle vocabulary and, for durable edges, the ELZ-009 boundary; the
   atomic multi-head commit is a storage Contract. External facts arrive
   through runtime/adapter with issuer, expiry and provenance recorded. Data
   classification: identifiers only.

## Scope

- define the pure readiness/admission transition and its result schema;
- select laws for acyclicity of admitted edges and fact satisfaction;
- test the listed dangerous paths against a test double store;
- document the provenance tags and the libgraph boundary.

## Acceptance

- [ ] Concurrent edge admission cannot commit a cycle (executable test).
- [ ] Selected acyclicity and satisfaction laws run through mix check.
- [ ] `closed` ≠ `completed`, expired facts and model-declared readiness are
      listed negative tests.
- [ ] Operational applicability is declared per docs/operational-contracts.md.

## Evidence and limits

Selected laws over the pure reducer; tests over listed scenarios. No
durability, execution or distributed-agreement claim.

## Out of scope

Scheduling, claiming, lease handling (ELZ-028) and DAG templates.

## Reference

Shapes observed in bankai 0.4.0, jido_action 3.0.0-beta.22 and pixir 0.1.17;
see docs/research/ecosystem-round-2.md. No code is copied.
