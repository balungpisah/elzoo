# ELZ-021 — Decompose the Raxol reference into admission records

- Phase: P0 catalogue design
- Dependencies: ELZ-014, ELZ-015, ELZ-018
- User-directed reference study before demand-led implementation prompts.

## Outcome

Read Raxol (DROOdotFOO/raxol, MIT) at a pinned revision as a design reference
for agent-harness safety boundaries, and record which of its ideas earn an
Elzoo admission record, which become design tests on existing tasks, and
which are skipped as surface-, protocol- or product-specific. Ideas only: no
Raxol source, dependency or file format enters Elzoo.

## Scope

- Pin the revision and cite the inspected docs/modules in
  docs/research/orchestration-references.md, separated from proposals.
- Write capability-model admission records (steps 1–6) as task bodies for the
  candidates with a named coverage caller, a pure core and a dangerous failure
  path already listed as a design test: budget reservation/settlement
  (ELZ-022), dispatched-effect intent with unknown-outcome recovery (ELZ-023)
  and authorization/approval reduction (ELZ-024).
- Fold the remaining transferable rules into the existing ELZ-006, ELZ-009,
  ELZ-010 and ELZ-011 bodies as Contract text and design tests, without
  changing their dependencies or ready Contracts.
- Update inventory reasons and the task DAG; add no ready source, build task
  order or library dependency.

## Acceptance

- [ ] Every cited observation links an exact revision; package metadata is
      dated and version-specific.
- [ ] Each new task body contains the six admission steps, names its coverage
      case, state owner, failure paths, reuse check and evidence plan.
- [ ] Existing ready manifests, task dependencies and the P0–P3 chain are
      unchanged; new tasks are demand-led and not inserted into that chain.
- [ ] Ledger, DAG and links validate; mix check passes.

## Limits

No claim about Raxol's correctness, security or maintenance beyond the cited
text. No capability is adopted or implemented by this task; the new bodies are
Contract proposals that their own reviewers may still amend.
