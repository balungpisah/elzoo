# ELZ-033 — Adopt the product-led catalogue roadmap and gate the first wave

- Phase: roadmap policy and documentation
- Catalogue IDs: planning coverage of all 97 current entries; no readiness promotion
- Dependencies: none (documentation/admission only; implementation dependencies remain unchanged)
- Draft mapping: RC-00 -> ELZ-033. Other RC identifiers remain unpublished proposals.

## Outcome

Adopt a repository-owned product-led catalogue plan that lets independently useful Pieces be selected from concrete product aims before new integration examples exist. Preserve the ordinary issue/claim/review/merge workflow and all published task acceptance. Prepare only ELZ-022, ELZ-024 and ELZ-026 as the first bounded implementation wave. This task creates no runtime Piece and does not authorize draining V1/V2/V3.

## Inputs and authority

Read AGENTS.md and its prescribed read order. Reconcile the four proposal files under <artifact directory>/elzoo-roadmap-2026-11-06/ (roadmap.md, release-plan.json, next-steps.md, baseline.json) against current main, live issue bodies, remote claims and accepted PR evidence. Import necessary content into the repository so the adopted plan does not depend on that local path. Proposals, counts, closed issues and worker reports are not runtime or merge-acceptance evidence.

## Scope and ownership

- Add this exact task body under tasks/ and register its issue in the task DAG.
- Adopt a canonical plan/manifest under docs/plans/ with one authoritative planning task/status/dependency source; derive any graph/table from it or clearly link to it. Live GitHub issue bodies remain the task Contracts and the branch remains the claim. Avoid conflicting manual status boards.
- Account for every current catalogue ID exactly once, preserving the original 97-row baseline and reconciling any live additions. Map product aims, release intent, scoped deliverables, primary planning owners, dependencies, explicit blocked/deferred/duplicate/index/upstream dispositions and release gates. Validate uniqueness, references, acyclicity and release ordering.
- Reconcile GOAL.md, AGENTS.md, docs/development/02-task-dag.md, workflow and relevant capability/architecture wording deliberately: a published admitted Piece may be selected for a concrete product aim without waiting for a new Assembly example. Preserve narrow Contracts, reuse-first admission, new IDs for changed ready behavior, source-copy requirements, all evidence distinctions, pinned tooling and symbolic-only CI.
- Resolve domain/value-types and domain/saas-controls as discoverability/index planning dispositions without claiming executable readiness or changing metadata schema here. Resolve core/grounding's planning deliverable distinctly from ELZ-012 evidence handoff; no invented ready Piece. Any metadata schema or runtime work is a separately reviewed prerequisite.
- RC-43 is a coverage/admission check first: ELZ-010 PR #54 already contains integration/jobs Relay. Inspect its actual source/Contract and eventual acceptance, then ELZ-011/023 boundaries; no duplicate dispatcher or automatic new Piece. state/schema-evolution and state/scheduler remain separately scoped candidates. ELZ-028/state/lease remains conditional on actual provider ownership evidence. Conditional coverage resolves only with exact named evidence; unresolved provider/API/transaction choices block dependent jobs.
- Prepare ELZ-022 (#36), ELZ-024 (#38), ELZ-026 (#43): map concrete product aims, verify prerequisite merge SHAs and acceptance, inspect live claims, and record frozen shared interfaces, local decision ownership and prerequisite needs. Preserve their published acceptance and dependencies. Routine choices can be documented; a changed Contract requires deliberate review, never a weaker test.
- Define first-wave sequencing, at most three implementation workers TOTAL including an active ELZ-010 worker; one independent review slot plus coordinator capacity; no recursive delegation. Each implementation has its own deterministic task branch/claim and isolated workspace. Assign separate ownership of shared Contracts, provider pins/lockfiles and generated ledger integration; serialize backend CI through the existing symbolic queue.

## Boundaries

The original coordinator exclusively owns ELZ-010: do not edit its issue/branch, re-scope, implement, duplicate, merge or close it. Read its thread before discussing status. Preserve unrelated root .gitignore/.ignore work and untracked graft/. New integration examples remain deferred. Do not mechanically publish RC proposals; later provider tasks require admitted APIs, transactions and exact-boundary evidence first. Do not modify runtime sources, ready Piece metadata, provider pins, lockfiles, generated ledger or runner configuration in this documentation task.

## Acceptance

- [ ] All baseline 97 rows have explicit, repository-grounded dispositions and one primary planning owner; candidate IDs are separate.
- [ ] Canonical dependency/status data and generated or linked views agree; no dangling references, cycles, or backwards release dependency; release acceptance and examples-later gates are explicit.
- [ ] Policy documents consistently allow product-led, admitted Piece work while retaining all evidence/claim/merge safeguards and existing issue Contracts.
- [ ] RC-43, umbrella/index entries, core/grounding and conditional provider ownership have precise non-invented dispositions.
- [ ] First-wave task preflights name actual accepted dependency evidence, immutable shared boundaries, resource ownership and unresolved blockers; no implementation dispatch before adoption and per-task gates pass.
- [ ] Independent reviewer inspects the actual policy/contract/evidence diff at an exact SHA; findings resolved and affected checks rerun.
- [ ] Documentation/link/plan consistency checks, git diff --check, python3 scripts/check-claims.py and python3 scripts/check-ci-runners.py pass. Follow repository fresh-checkout mix setup/mix check requirements and report exact output or blocker; no inferred pass. Preserve Cure a004c335cc4e9f2203ba6f51fc31e8540b66378d, Elixir 1.20.4, OTP 29.1.2. Existing symbolic checks and merge-commit acceptance remain required.
- [ ] PR merged through GitHub only after checks/review; merge acceptance recorded, merged task branch/workspace cleaned and issue closed with PR/merge SHA.

## Review and integration

The dedicated roadmap coordinator owns integration, independent review dispatch and the later bounded ELZ-022/024/026 wave. A documentation worker may claim, implement, check and open a self-contained PR, but may not merge or close this issue; the coordinator does so after independent review. No worker delegates further. All future implementation claims recheck live readiness and deterministic branch locks at dispatch.

## Evidence and limits

Planning integrity checks and independent review ground only the plan/policy. No new Cure proof, runtime behavior, provider adoption, product completion, security certification, durability or release acceptance is established by this task. Record assumptions and blocked provider decisions explicitly. The ledger remains authoritative for usable source subsets; the canonical roadmap selects and gates future work.
