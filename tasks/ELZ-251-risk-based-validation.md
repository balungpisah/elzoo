# ELZ-251 — Make local validation proportional to risk and isolation

- Dependencies: ELZ-248
- Release: V1B
- Output: none
- Change class: documents only; coordinator-owned one-PR task

## Scope

Clarify the authoritative workflow in AGENTS.md and the matching local-versus-hosted explanation in docs/development/10-symbolic-ci.md. The owner requested risk-based validation rather than repeating unrelated checks merely because a new isolated spike is absent from the hosted classifier's fixed allowlist.

## Acceptance

1. State a practical fast/slow decision: ordinary documentation and bounded pure policy use their existing focused gates; durability, authorization, identity, concurrency, uncertainty and external-effect boundaries require relevant real-service and adversarial evidence. High risk selects stronger relevant scenarios and review, not unrelated tests by default. Shared executable paths, root dependencies/pins, or uncertain impact retain the existing full/affected requirements.
2. Make local evidence distinct from hosted job selection. An isolated spike plus non-executable reports/task/plan documents may use its own checks locally even when an unregistered spike directory makes hosted CI conservatively run the full suite. The worker must establish isolation from the actual diff and root compilation, test and runtime loading paths. The exception excludes production Piece/root executable changes, root dependencies/pins, scripts/workflows, exports or any transitive consumption of changed spike contents by production/root checks. Ambiguity takes the heavier gate.
3. Require the spike's exact own checks and the task's boundary/fault cases, with disposable real services where relevant, plus roadmap/claims/diff checks. Record the isolation reason, actual classifier result, executed checks and limitations in the existing PR evidence fields. A green root suite that did not execute the spike is not spike evidence. Do not invent a new checklist, approval loop or marker.
4. Apply the same distinction to planned-only publication: new task/plan documents and added planned catalogue entries may use roadmap/live/claims/diff checks plus the existing registry test locally when the diff preserves every existing catalogue row, adds only planned entries without manifests, and changes no Piece, ready entry, manifest, provider, generated ledger input other than those planned additions, or executable input. Validate this exact restriction against the diff; any departure or uncertain impact takes the existing heavier gate. Hosted classification, full hosted checks where selected, and strict publication main-green guards remain unchanged. Do not call this docs-only when the classifier says otherwise.
5. Preserve exact-head hosted checks, classifier/workflow/queue behavior, one independent review, ready-before-merge, green-main/freeze rules, and explicit checks required by a task Contract. The policy does not turn the existing root affected command into a selective spike command or ignore a known failure. Do not claim an omitted check passed or weaken a task to get green.
6. Remove contradictory wording that makes the hosted fallback alone mandate an unrelated local full run. Keep the full local gate for real shared-code impact. Do not repeat completed passing checks solely for ceremony when the checked delta and relevant inputs are unchanged; existing new-head, base, and merge requirements still apply.
7. Check the written decision against six cases: isolated new spike plus research report; spike plus root dependency; pure Piece; durable Piece with real-service cases; strictly planned-only publication; uncertain/root executable impact. Explain the outcomes briefly in the PR. The policy itself changes no executable behavior.

## Owned paths and validation

AGENTS.md; docs/development/10-symbolic-ci.md; this task file; its job row in docs/plans/release-plan.json; generated docs/plans/views.md and docs/plans/dependencies.mmd. No Piece, registry, executable script, workflow, queue, provider, lockfile or toolchain changes.

Create the issue without task label and claim task/ELZ-251 with the API lock. Publish the task and implementation together using the coordinator-owned non-Piece path. Run the docs classifier, python3 scripts/check-roadmap.py --write, python3 scripts/check-roadmap.py, python3 scripts/check-roadmap.py --live, python3 scripts/check-claims.py and git diff --check. Obtain independent review and exact-head hosted checks, then use the merge queue. Do not add executable tests for this prose-only change.
