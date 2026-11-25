# ELZ-407 — runtime/recipe-test: pin the frozen run/1 records

- Dependencies: ELZ-181, ELZ-183, ELZ-404
- Release: V2
- Stage: `release`
- Output: no new Piece ID.
- New external dependency: none.
- Change class: Piece-only implementation.
- Owned paths: fixture files and fixture test under `pieces/runtime/recipe-test/test/`, the file list in its `piece.json`, only its manifest hash and note in `docs/plans/release-plan.json`, and generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`. The existing `test/support/recipe_test_helper.exs` may be edited for the temporary negative control only.

## Contract

Unchanged. This is X3 in `docs/plans/first-release.md`, owner answer Q4 A. First compare all four frozen record-writing paths at the build base with `0a76dd21` (F's merge): `lib/` and `cure/` where present in `workflow/pattern-step`, `assembly/run-engine`, `runtime/durable-unit` and `runtime/recipe-test`, plus `runtime/recipe-test`'s `test/support/recipe_test_helper.exs`. Stop and report to the coordinator if any differ. They match at the publication base `00c842f9`. Use the frozen code at the build base; no writer, reader or runtime Contract changes, and no new public reader.

At the publication base `Elzoo.RecipeTest.run/1` is the sole public entry point (`test/support/recipe_test_helper.exs:67`). The private `record/1`, `steps/3` and `step/1` (lines 1047, 1059 and 1072) make the record: `outcome` comes from `RunEngine.status/1`; `asked`, `unused` and `restarted` come from harness state; only `steps` comes from decoding version-1 rows in the Run's own DurableLog stream. `run/1` starts its own engine and does read rows it writes during the run; it does not consume preloaded fixture rows. X2 pins those engine Store rows separately.

## Acceptance

- Capture the `record` in `{:ok, record}` from `run/1` for four named specs: a scripted agent, a graph with a decision child, a Lua tool with scripted module calls in the real sandbox, and a model-proposed graph after one restart. Use the existing agent, graph-with-children, Lua module-call and model-graph-after-restart tests as examples. Give the Lua fixture all five limits and set `wall_ms` to 1,000 (the existing Lua test helper defaults to 500; Level 4 calls for 1,000 for this fixture). Require the model graph spec to actually restart.
- Store the four real outputs as deterministic external terms. Pin each committed file's SHA-256 in the test. On disposable PostgreSQL, call `run/1` for each spec and assert `{:ok, record}` with exact equality to the entire golden record. A format change must be deliberate, under a new Piece ID after the release; later additions do not rewrite pinned files.
- Negative control: temporarily rename a step kind emitted by private `step/1`, show a golden-record comparison fails, and restore before the passing gate. Add fixtures to `piece.json`'s `files`, update the index hash and ensure its note still equals the unchanged `contract`.

Durable state and a real Lua sandbox: run the Piece tests, local small gate and `git diff --check`; require exact-head hosted `check-piece` and full independent review under “Reviewer by risk”. Equal records for equal specs are observed, not proven. A hosted mismatch takes the `AGENTS.md` section 5 rerun rule (as with the sandbox under load in #547): record the first failure, rerun all jobs on that same head without a push, and track the flake on its issue. A second mismatch of the same case is a real failure; do not regenerate the fixture to make it pass.
