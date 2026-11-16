# ELZ-248 — Distinguish private Git cleanup from published history

- Dependencies: ELZ-033
- Release: V1B
- Output: none
- Change class: documents only

## Scope

Clarify the Git and public-writing rules so routine private cleanup and standard authorship attribution do not block delivery. This coordinator-owned non-Piece task uses one publication-and-implementation PR.

## Contract and acceptance

1. Keep the ban on force-pushes, direct commits to main, and rewriting published or shared history. A commit is shared when pushed, supplied for review, or used by another worker as a dependency.
2. Permit the sole owner to amend or reorganize their own unpublished local commits before sharing them, without a separate permission request. Preserve all intended work and respect uncommitted changes. This permission does not allow changing Git identity, discarding another worker's work, or bypassing a protection or refusal.
3. Retain the existing review and exact-head test rules. Changed code receives the prescribed delta review; a changed head must satisfy the applicable local and hosted gates. This clarification adds no evidence-reuse exception.
4. Allow standard Git author/committer/co-author metadata and platform authorship attribution. The public-writing rule still forbids personal or environment details in authored repository content, examples, issue/PR prose, and session links. Automatic authorship metadata alone needs neither a rewrite nor an approval request.
5. Align the active change-class guide with the narrowed rule. Do not alter queue implementation, branch protection, main-green rules, provider pins, runtime code, Piece Contracts or catalogue entries.

## Owned paths

- AGENTS.md
- docs/development/12-change-class-flow.md
- tasks/ELZ-248-git-history-and-attribution.md
- docs/plans/release-plan.json: this job row only
- docs/plans/views.md and docs/plans/dependencies.mmd: generator output only

## Checks

Run the actual-path change classifier, roadmap check including live issue hash, claims check and git diff --check. Keep one independent review and exact-head hosted evidence; merge through the normal task queue. No executable inputs are changed, so no new runtime test is required.
