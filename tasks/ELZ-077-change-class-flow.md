# ELZ-077 — Change-class flow: the coordinator's map

- Phase: P0 harness (documentation only; `docs/development/12-change-class-flow.md`, this task copy)
- Catalogue IDs: none
- Dependencies: ELZ-075 (#140) and ELZ-076 (#142) merged (rule 9, the worker gate and the claim rule); ELZ-071 (#131) merged (the classifier); ELZ-073 (#136) decided by measurement.
- Review: documentation only; no independent review. Automated review findings dispositioned in the PR.

## Outcome

Owner decision 2026-11-09 (17:30 WIB): the flow is guided by the coordinator and conditions may alter it without loss of quality; the coordinator holds the map and gives the order; the machines verify the class so that neither a worker nor the coordinator can drift. This task writes that map as one page: six change classes, how each is computed (by a machine today or by the coordinator only), the order per class (local gate, CI shape, review depth, combine or split, queue evidence), the floor steps no class skips, and the candidates for new machine checks, each gated by a measured saving.

## Scope

1. New page `docs/development/12-change-class-flow.md` with the two layers (the coordinator decides, the machines verify), the floor, the class graph, the per-class order table with observed costs from 2026-11-09, the departure rules and the candidates list.
2. One line in `docs/development/11-coordination-rules.md` section 9 pointing to the page.
3. Task copy byte-equal to the live issue body.

## Acceptance

- [ ] The page exists and every class names its machine check or says "coordinator-only".
- [ ] `check-roadmap.py` and `check-claims.py` exit 0; `git diff --check` clean; the link check of the roadmap script passes with the new page linked.
- [ ] Documentation-only pull request merged through the short check (`mode=docs-only`).
- [ ] Automated review findings dispositioned.

## Limits

A map, not a mechanism: the classes T, C and parts of P are verified by the coordinator only until a machine check exists; each new check needs its own task with a measured saving (rule 9). The page changes no command, workflow or `AGENTS.md` text.
