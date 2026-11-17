# ELZ-255 — Preserve shared PostgreSQL test support in copied consumers

- Dependencies: ELZ-249, ELZ-254
- Release: V1B
- Output: none
- Change class: non-Piece test-harness repair; coordinator-owned one-PR path

## Problem and scope

Reporting issue: https://github.com/balungpisah/elzoo/issues/519. The full main check after PR #579 exceeded the aggregate consumer's 25-minute outer budget. Private diagnostic progress exposed SQL setup failures. The checked-command test file searches only the repository layout for the SQL helper; when that path is absent it defines replacement modules under the shared `Elzoo.DurableLog.TestRepo` and `Elzoo.DurableLog.PostgresHarness` names. The replacement `database_url!/0` returns `nil`. Loading those replacements into a copied consumer can overwrite real SQL test support used by other Pieces. A child stopped during diagnosis is not evidence of complete aggregate runtime.

Repair the checked-command test bootstrap so it locates the real SQL test helper in both repository and exported layouts, and never defines replacement modules under another Piece's shared names. Keep PostgreSQL checks real. When the copied support is available, run the existing SQL cases; do not skip them merely because the repository-relative path is absent. If optional test support is genuinely unavailable, report that limitation explicitly without fabricating successful SQL behavior or contaminating another module. Correct the README's copied-test coverage statement to match the observed export closure.

The public CheckedCommand and Store Contracts are unchanged. This is a test-support isolation repair, not a timeout adjustment or a production persistence change.

## Acceptance and validation

1. Use the actual Export plan and copied paths to establish where the SQL helper is present. Add a focused root regression that loads the actual checked-command test source and real SQL support in fresh child VMs, including support already loaded before the checked-command file and the reverse load order. Assert that shared helper behavior remains real and that the SQL cases are enabled when their support is present. Exercise the genuinely missing-support branch without defining or replacing another Piece's helper modules. Do not run all tests recursively from the regression.
2. Run all existing checked-command tests against disposable PostgreSQL. Run its actual copied consumer with the real helper available and explicitly report the SQL case count. Verify affected SQL consumers in the complete aggregate; a nested suite's success text or process exit zero alone is not evidence that the top-level aggregate finished. Record a final top-level suite summary and the wrapper's original runtime postchecks.
3. In the actual repair worktree, temporarily restore the defective checked-command bootstrap and run the focused regression. Capture a nonzero exit caused by helper contamination or disabled required SQL cases, restore the source byte-for-byte, and rerun the intended assertions successfully. Do not commit the control.
4. Retain the aggregate outer limit, per-test limits, all existing assertions, SQL calls, and selection. Do not add a dependency, generic runner, fake Store, global placeholder helper, or production instrumentation. If another independent failure appears, record it and scope it separately.
5. Run `mix check --affected origin/main`, live roadmap/claims and diff checks. This shared test-support repair requires a full hosted check even if automatic path classification selects a smaller check. Obtain one independent exact-diff review, exact-head hosted evidence, ready-before-merge state, and the coordinator queue merge. Verify green main before ELZ-252 admission.

## Owned paths

`pieces/assembly/checked-command/test/elzoo/checked_command_test.exs`, `pieces/assembly/checked-command/README.md`, `test/checked_command_copy_support_test.exs`, `tasks/ELZ-255-shared-sql-test-support.md`, this task's no-output job row in `docs/plans/release-plan.json`, and generated plan views. No production source, Piece Contract, manifest, catalogue, provider/pin, other Piece's test/helper, workflow, queue, or timeout changes. Publish and implement together on coordinator-owned `task/ELZ-255`; create the issue without `task`, then acquire the normal API branch lock. Record finite evidence and limitations in the PR body. Close this task after successful review and merge; close #519 only when its aggregate failure is resolved and green-main evidence exists.
