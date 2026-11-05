# ELZ-014 — Define reusable capability boundaries and cross-domain coverage

- Phase: P0 catalogue design
- Dependencies: ELZ-013
- User-directed concept clarification before autonomous implementation prompts.

## Outcome

Make explicit how canonical functional Pieces compose across SaaS, money,
identity/user management, task management and agent orchestration. Study
OpenMausBot and iii at pinned revisions for patterns, not adoption claims.

## Scope

- Define admission/split rules for Pieces, Assemblies and product policies.
- Record source-linked reference findings and limitations.
- Map representative domain workflows and failure cases to reusable capability IDs.
- Refine the inventory with honest planned/deferred gaps, reuse-first candidates
  and verification obligations; preserve existing ready implementation claims.
- Align agent read order and ELZ-002 with the clarified model. Do not implement
  domain engines or turn every coverage cell into a build task.

## Acceptance

- [ ] Piece boundaries are explained with cross-domain examples and counterexamples.
- [ ] Reference observations are pinned, cited and separated from proposals.
- [ ] All requested domains have representative assembly/failure walkthroughs.
- [ ] Existing and missing capabilities are traceable to catalogue IDs; no new
      dependency is called adopted without executable boundary evidence.
- [ ] Ledger, task DAG and links validate; independent design/evidence review
      and required checks pass before PR integration.

## Limits

No claim of universal completeness, financial/security certification, upstream
runtime correctness, library adoption through documentation alone, or an
implementation of every capability. No worker-start prompt in this task.
