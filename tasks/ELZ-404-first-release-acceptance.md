# ELZ-404 — Accept the three frozen first-release gates

- Dependencies: ELZ-403
- Release: V2
- Stage: `release`
- Output: none
- New external dependency: none

## Scope

This root consumer acceptance is Level 3 of `docs/plans/first-release.md`.
ELZ-403 merged at `0a76dd21`; its base `edd27760` supplies the frozen manifest
bytes. The three gates share one integrated check. V2 requires V1; V1B does
not wait for V1. No selector, product, Piece, ready Contract or record-writing
path changes. In particular run-engine, pattern-step, durable-unit and
recipe-test keep their frozen writers. A defect is a separate repair: record
the evidence and refer it to the coordinator. A required writer or Contract
change stops the release for the owner. List any admitted freeze repair with
its commit; its stage is `release`, outside the selected set.

## Acceptance

1. In `docs/research/first-release-acceptance.md`, give one row per frozen
   job, in V1 (106), V1B (265), V2 (29) order. For each published job, check
   its completed issue, merging PR and merge commit against GitHub. Identify
   every ready output by ID and its SHA-256 at F's base (70, 75 and 7 ready
   rows). Give the frozen resolution for each proposal and index-only row.
   For the 20 historical V1 jobs use the evidence in “The published jobs”:
   ready outputs and the integrated check, or the landing commit and the
   check that carries the work today where one exists. For ELZ-001 cite the
   two bootstrap commits and pinned check instead of a PR. List a job without
   evidence as undecided for the coordinator. Do not set **any** gate accepted
   while any such job is undecided.
2. Name the source-copy plan of every ready Piece, aggregate consumer,
   `cure_record_tags_test.exs`, `registry_test.exs`, `install_configuration_test.exs`,
   the provider pins in `registry/providers.json` and install-guidance cases in
   `export_test.exs` and `source_only_provider_test.exs`. For cross-Piece failure
   evidence name the Wave 4–9 root acceptances and their recorded negative
   controls; for claim-level grounding name `scripts/check-claims.py`. State
   that `integration/search-data` (V1) copies `state/tenant-isolation` (V1B):
   the closure is accepted together, without moving jobs.
3. Add `test/first_release_recipe_test.exs`: one package through
   `Elzoo.RecipeTest.run/1` on disposable PostgreSQL. The graph root's call
   node starts an agent; the scripted model asks for a Lua tool, whose real
   sandbox and Lua binding call one scripted module function. The agent
   answers and the graph finishes. Assert completed outcome, exact asked
   counts, empty unused and the graph's finish payload. Supply all five Lua
   limits, with `wall_ms` 1,000 (no sandbox defaults).
4. Remove only the Lua entry: the recipe case must fail on `unbound_tool`.
   Restore it, then target an absent agent from the graph node: recipe-check
   must refuse and the case fail. Restore before the passing run. Record the
   actual failures. No executable generator or control for the job table: the
   independent reviewer checks it against the selector and the issues.
5. On accepted evidence set only the three V1/V1B/V2 gate statuses to
   `accepted by ELZ-404; the release mark follows the fixtures` in
   `docs/plans/release-plan.json`. Add this task's no-output job row and
   regenerate the roadmap views. No fixture or release mark is made here.

## Checks and limits

Run `mix check` with no flag on disposable PostgreSQL 16 and MinIO, plus
`python3 scripts/check-roadmap.py --live`, `python3 scripts/check-claims.py`
and `git diff --check`. Record the local run, commit and exit codes in the PR
body, not the report. A later test or code change repeats `mix check`; a
report/status-only edit needs no repeat. Every PR head takes the full hosted
check; the final head's green run is merge evidence. Full independent review
under “Reviewer by risk”, including the job evidence, before the ready mark.

Finite scenarios, not proofs; each Piece's Limits stand. Models and providers
are scripted. The 14 `later` proposals and the deferred parts of P01, P02,
P04, P07, P08, P10 and P11 are not supplied; in particular none of P11 is
supplied. No complete-product claim. The observations that F left open stay
open; this task adds no provider and changes no dependency.
