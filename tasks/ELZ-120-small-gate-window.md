# ELZ-120 — Bound the outstanding small-gate merge window

- Dependencies: none
- Allowed implementation paths: `scripts/merge-queue.py`, `scripts/test-merge-queue.py`, `docs/development/10-symbolic-ci.md` only. The documentation change describes this behavior and its limits only.

Implement the count-limit follow-up to PR #219. Before accepting a Piece merge and again immediately before merging, count **all first-parent commits** on canonical main after a valid covering successful main push. Current counts 0, 1 or 2 allow the next Piece merge; count 3 or greater refuses until a newer successful main push covers enough commits. This conservative count includes every first-parent commit, not only Piece merges, and can pause earlier than a Piece-only count.

Covering evidence must be a successful `push` run of `symbolic-check.yml` on `main` whose head is on main's first-parent chain. A success hidden by a later failed or unfinished rerun of that run is not valid. Missing or unreadable covering evidence fails closed for Piece mode. On refusal report the covering SHA and current count when available. Preserve the existing red-main freeze rule, classifier, normal full-run adoption, docs-only checks, dispatch behavior and merge checks. Full evidence remains usable for repairs when existing freeze rules permit them.

Use existing queue facilities. Add no CLI option, state store, configuration or general helper layer. Do not change AGENTS.md or workflows. Ask the coordinator before expanding scope.

## Acceptance

- Existing queue tests distinguish counts 2 and 3; a later covering successful push reopens the window; second-parent ancestry does not qualify; missing, failed or unreadable evidence refuses; the count is rechecked immediately before merge; existing red-main freeze and full-run adoption behavior remain intact.
- Run `python3 scripts/test-merge-queue.py`, `mix check --affected origin/main`, and `git diff --check`. Record failures or unavailable services. One independent review is required for scripts changes.
- These local behavioral tests are not live dispatch evidence. The separately authorized production full-check dispatch uses the actual reviewed implementation PR, not an artificial probe; the PR #219 six-proof hold remains. This task does not assert an automatic fallback or authorize a dispatch.
