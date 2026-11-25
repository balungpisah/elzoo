# ELZ-388 — Plan the first release: the frozen selected set, the acceptance of V1, V1B and V2, the record fixtures and the release mark

- Dependencies: ELZ-379

## Outcome and scope

Write the planning input for Elzoo's first release in the form that `docs/plans/bot-platform-wave9.md` used for Wave 9 (ELZ-355), so that its levels can be published as tasks after the owner answers its questions. Wave 9 is the last row of the wave table of `docs/plans/bot-platform.md`, and its root consumer acceptance ELZ-379 is merged on `main` (`c6fe7a8f`). The plan starts from "What remains after Wave 9" in `docs/plans/bot-platform-wave9.md` and from the `release_gates`, `products` and `jobs` of `docs/plans/release-plan.json`. It publishes no implementation task, promotes nothing to ready and builds nothing.

This is a coordinator documents change. Publication and the plan share one pull request on the branch `publish/ELZ-388` (coordinator instruction), and it takes the documents check. The merge queue takes only `task/ELZ-###` branches, so the coordinator merges this pull request on the publication path of `docs/development/13-coordinator.md` (step 3). The pull request names the issue without a closing keyword, so after the merge the coordinator closes the issue as completed by hand.

Owned paths:

- `docs/plans/first-release.md`: a new page;
- `docs/plans/bot-platform-wave9.md`: one sentence at the end of "What remains after Wave 9" that points to the new page.

Publication owns this task file, its no-output job row in `docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and `docs/plans/dependencies.mmd`.

ELZ-388 is reserved for this plan. ELZ-387 and the IDs from ELZ-389 on belong to the publication thread of the #930 repair.

## Owner decisions carried as settled (2026-11-25)

1. The first release does not wait for any deferred, demand-led row. Neither a first chat channel nor a payment provider is chosen. They come later as new Pieces, which needs no new ID for any existing Contract.
2. #930 takes option A: an opt-in run-engine start option, published as ELZ-387 and built in place before the release, so the release depends on it.
3. After the release, freeze the selected set and the record formats; then run V1-ACCEPT, V1B-ACCEPT and V2-ACCEPT; then commit the record fixtures written by the released code to the tests of `assembly/run-engine`, `workflow/pattern-step` and `runtime/recipe-test` (owner, 2026-11-21). From then on, the new-ID rule of `AGENTS.md` section 4 applies.

## Required behavior

1. The page has "Status and scope" with the settled owner decisions, "Source boundaries checked" (facts read at a named `main` commit), "The selected set", "What \"the release\" is", "Open repairs and observations", "Rules of the freeze", "Dependency levels", "Owner questions" and "What remains after the first release".
2. It states the frozen selected set of each gate (`V1-ACCEPT`, `V1B-ACCEPT`, `V2-ACCEPT`) from today's ready catalogue rows, with the job counts that the gate selectors derive, and how the freeze records it without a new selector mechanism.
3. It decides each still-unpublished RC job and each non-ready disposition that a V1, V1B or V2 product or gate selects today: keep and build, move to a later release, accept as an index or superseded resolution, or drop, with the reason for each.
4. It states what "the release" concretely is (a commit, a tag, a version, a changelog, the consuming documents) using only what `docs/consuming.md`, `docs/development/13-coordinator.md` and the export code support, and invents no mechanism that they do not support.
5. It gives the acceptance task of the three gates and the record-fixture tasks, with levels and dependencies, each with its Contract sketch, its new external dependency or "none", and acceptance with negative controls sized to its risk. It prefers fewer, larger acceptance tasks.
6. It decides which open repairs and observations must land before the freeze and which can wait, at least #821, #834, #843, #852, #670, #669, #547, #701, #710, #715, the skip-list rechecks and the `AGENTS.md` section 6 rechecks, and every other open issue at the commit it names, with the reason for each.
7. Each choice that needs the owner is one numbered question with lettered options and a recommendation, including any reading of a settled decision that the coordinator records for the owner to correct.

No Contract, task, Piece, catalogue row or other plan text changes, apart from the owned paths.

## Acceptance and evidence

1. The diff changes only the owned paths, this task file, its job row and the generated views.
2. `scripts/ci-change-class.py` classifies the range as documentation only.
3. `python3 scripts/check-roadmap.py` (plain, `--write` and `--live`), `python3 scripts/check-claims.py`, `git diff --check` and the Registry test (`mix test test/registry_test.exs`) pass.
4. One independent plan review of the selected set against the catalogue and the gate selectors, each disposition and its reason, the release mechanism against the named documents, the levels and the repair decisions against the open issues; a green exact-head hosted documents check; the pull request marked ready; and the automated reviewer's gate of `AGENTS.md` section 6. The coordinator merges on a green `main`.
