# ELZ-413 — assembly/run-engine: wait for Unit removal in the nested result restart test

- Dependencies: ELZ-411

## Outcome and scope

Defect #994. In `nested_result_survives_restart`, the test injects append-reply loss, stops the engine, then calls `DynamicUnits.stop/2`. On the unchanged release commit `218afe42` the stop returned `{:error, :busy}` on run 14 under CPU load. Stopping the engine does not synchronize the directory with the terminating Unit. Wait for the directory to observe the Unit absent under a total time bound before asserting that a single stop returns `:ok`.

This is a coordinator-owned test-only Piece repair on the one-PR path (`AGENTS.md` section 1). Publication and implementation share one `task/ELZ-413` pull request. Release V2, stage `later`. The Piece Contract is unchanged; the only Piece file in scope is the manifest-listed `pieces/assembly/run-engine/test/elzoo/run_engine_test.exs`. No output Piece ID, fixture or pin change, manifest, README, library or index change. Publication paths: this task file, `docs/plans/release-plan.json` and its generated views.

## Acceptance

- On disposable PostgreSQL record the unchanged base's repeat failure, completed pass count and failed assertion.
- After the repair, `mix test pieces/assembly/run-engine/test/elzoo/run_engine_test.exs:4668 --repeat-until-failure 200` and `mix test pieces/assembly/run-engine/test` exit 0. Retain all three committed cuts (22, 23, 24), the no-double-action checks and the single outcomes for the child finish and parent action.
- Negative control: temporarily restore the original ordering in the worktree and repeat until the same stop fails. Record the result, restore the repair and never commit the control.
- `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check` exit 0, and `check-piece` passes on the exact head.
