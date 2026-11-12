# ELZ-125 — Restore Run test-helper portability in copied consumers

- Dependencies: ELZ-116
- Allowed implementation path: `pieces/workflow/run/test/support/run_test_helper.exs` only.

Main Check run 43240042406 at 9e2e3cb422be5cf981f527c06995de5be79a8bac failed its aggregate copied-consumer test. Run's helper assumes the repository layout and tries to require the SQL helper through `../../../../integration/sql`; after export it is under `test/support`, so that path fails with Code.LoadError. This run is classified `defect` on issue #98. This is the one forward-repair task under the wave1 advance approval, with at most two repair attempts for the red run. No revert, history rewrite or new Piece ID.

Reuse the existing local-first resolution in `pieces/state/audit-log/test/support/audit_log_test_helper.exs:2–13`: resolve `durable_log_postgres_test_helper.exs` beside `__DIR__`; select it when `File.regular?`, otherwise resolve the existing repository-relative SQL-helper path; call `Code.require_file` on the selected path. Missing both must still raise, never skip. `integration/sql` is already a declared Run dependency and exports that helper, so the copied helpers are siblings.

Change only the allowed helper path. No resolver module, option, environment variable, search/glob, copied fixture duplication, exporter change, manifest/README/runtime/root-test/dependency/pin edit, added test/assertion or ready Contract change. Use the existing convention directly. If the identical aggregate exposes a second defect, stop for the coordinator's scope decision rather than extending the repair.

## Acceptance

- On the actual repair checkout with private disposable PostgreSQL and required aggregate services, run `mix test test/export_test.exs --only aggregate_consumer --warnings-as-errors` with the original helper and record the Code.LoadError/nonzero exit. Change only the lookup and run the identical command to exit 0. A negative control after the correction may temporarily restore only the original helper in the actual worktree, then restore the correction; never commit the negative.
- Keep all 31 Run cases and assertions unchanged. `mix test pieces/workflow/run/test` exits 0 with 31 passing cases.
- Run `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check` before delivery. The selected gate excludes the aggregate and is not a substitute for the named aggregate result. Record exact commands, exit codes and any unavailable service without claiming an unexecuted check passed.
- The hosted database lane is `sh scripts/run-ci-check.sh --part consumers-db`. Record healthy exact-head hosted evidence and the covering full-main result; unrelated merges and publication remain frozen until current main is green.

One worker owns the claimed branch/worktree. Keep the correction to this test-portability defect and existing facilities; ask the coordinator before expansion. Record the inspected diff and evidence in the PR. No additional correctness review is required for this lookup-only test repair with unchanged assertions under AGENTS.md section 6; any change beyond that boundary returns to the coordinator before proceeding.
