# ELZ-129 — Split both critical CI test jobs safely

- Dependencies: ELZ-131 (merged and green)
- Allowed implementation paths: `lib/elzoo/check_selection.ex`, `lib/mix/tasks/check.ex`, `test/check_selection_test.exs`, `test/export_test.exs`, `.github/workflows/symbolic-check.yml`, `scripts/run-ci-check.sh`, `scripts/check-ci-runners.py`, `scripts/test-ci-runners.py`, `docs/development/10-symbolic-ci.md`. Ask the coordinator before adding another path.

Implement option 2: https://ampcode.com/artifacts/elzoo-ci-acceleration-c62f4caf-d222-4792-bded-5b36f41c37f1. Use only the merged, trusted ELZ-131 validators to authorize the new evidence shape. Split root work into two balanced fixed groups from the measured slowest profile, and separate the aggregate consumer from PostgreSQL per-ID consumers. Each database job has a disposable database. Keep all tests, assertions, timeouts, full/affected/Piece semantics, consumer module and registry inventory checks, and non-database consumers.

The fixed work jobs, part names and success markers are:

- `check-root` / `root-a` / `ELZOO ROOT A SUITE PASSED`
- `check-root-b` / `root-b` / `ELZOO ROOT B SUITE PASSED`
- `check-aggregate` / `aggregate` / `ELZOO AGGREGATE CONSUMER PASSED`
- `check-consumers-db` / `consumers-db` / `ELZOO CONSUMERS DB PASSED`
- `check-consumers` / `consumers` / `ELZOO CONSUMERS PASSED`

The complete unit is these five jobs plus `check-plan`, `check-piece` and `check-hosted`, once each. Full runs require each work job's own `Run mix check` step and marker, with Piece skipped. Docs runs skip all five work jobs and Piece; Piece runs skip all five work jobs. Only aggregate `check-hosted` prints the full marker after required results. Keep `check-root` as the real root-a shard with the pinned PostgreSQL service and sole cache writer; run the Ash spike exactly once there. Use standard all-file ExUnit loading with file exclusions, not a generic shard configuration.

## Acceptance

- Check the actual loaded test identity union is exhaustive and disjoint, with no missing or duplicate tests; preserve aggregate 1, DB 5 and non-DB 23 consumer checks. Update selector, workflow and exact-job guard consistently.
- Fail closed on missing, failing, stale, partial or foreign-run evidence. Preserve exact tree/head/current-base/latest-attempt, GitHub-hosted, green-parent and docs guards. A small gate never substitutes for full main; merge-window, main-green and policy-refusal behavior stays unchanged. No self-hosted runner, `runs-on`, protection or pin change.
- Before adoption run at least three complete attempts per frozen baseline and candidate arm, repeated on the same tree within each arm. Non-CI source and bundle blobs and workload must match across arms; workflow differs. Record cold/warm/cache state, head/tree/attempt, setup/stage/test, queue/wall/critical-path and summed runner time, median/range and failures. Existing root 20m47s, DB 17m09s and aggregate 629s are context, not a promised gain. Do not build a benchmark framework.
- Run relevant selector and workflow-guard checks, the required shared-path local gate and `git diff --check`; obtain independent review.
