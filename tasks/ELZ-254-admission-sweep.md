# ELZ-254 — Keep the admission deadline sweep inside its release window

- Dependencies: ELZ-253
- Release: V1B
- Output: none
- Change class: non-Piece test-harness repair; coordinator-owned one-PR path

## Problem and scope

Reporting issue: https://github.com/balungpisah/elzoo/issues/569.

The PostgreSQL admission deadline sweep sometimes exhausts its three attempts without releasing within the existing 100-microsecond window. A bounded private diagnostic at the unchanged test reproduced missing coverage with one scheduler and two normal-priority CPU workers: baseline failed on sweep three, with 47 in-window and 26 late releases. A candidate passed eleven sweeps with 187 in-window releases and two late releases retried. Both reverted-library controls exposed `intent_unavailable` instead of the required `timeout`. These observations support a test-only scheduling correction, not a production deadline defect, an explanation of the original aggregate miss, or universal timing reliability.

Change only the final spinning portion of `hold/1` in the PostgreSQL test helper: when the existing coarse wait reaches at most 5,000 microseconds remaining, save the current process priority, raise it to `:high`, spin until the existing target, and restore the saved priority in `try/after`. Use a small private `spin_until/1` helper. Do not raise priority around SQL, the coarse wait, the Session, or the whole attempt. This deliberately controls the release worker's scheduling during the fixture's final window; it is not representative production scheduling.

Retain the full seventeen offsets (-300 through +1,300 microseconds in steps of 100), 150 ms lifetime, three attempts, 100-microsecond release criterion, timeout reason, no-request and custody assertions, and existing cleanup-without-release handling. Keep exact-release observations distinct from cancellation/custody observations in the evidence. Do not relax assertions, retries, timeouts or selection, change production code, add a scheduler framework or permanent pressure/instrumentation, or claim that cleanup proves an exact release.

## Acceptance and validation

1. The committed executable delta is confined to that final-spin priority bracket and private helper, with an explanatory comment. Restore the previous priority on normal return and catchable exits; a killed process leaves no live priority state to restore. All other sampling and production behavior is unchanged.
2. Run the actual repository PostgreSQL sweep in one launch with `--repeat-until-failure 10`, capturing exit status and per-sweep duration; all seventeen offsets must satisfy the existing assertions and each sweep must complete below ten seconds. Run the entire PostgreSQL test module as well. Use a disposable PostgreSQL binding and retain real SQL calls.
3. In the actual worktree, temporarily revert only the Session intent-failure reason selection to unconditional `intent_unavailable`, preserving its independent deadline handling and cleanup. The sweep must fail its reason assertion with `intent_unavailable`, not merely miss a timing sample. Capture the nonzero command exit, restore the production source exactly, and obtain a passing focused run. Do not commit the control.
4. Record the existing fixed-profile A/B diagnostic as historical evidence, including sequential-run and instrumentation limits and the candidate control's missing explicit exit status. The fresh worktree control above supplies explicit current-head failure evidence. No further profile search is required.
5. Run `mix check --affected origin/main`, live roadmap/claims and diff checks. No selected-gate shortcut for this coordinator-owned harness repair. Complete independent exact-diff review, exact-head hosted checks, ready-before-merge and the coordinator queue. A reproduced failure remains visible and is not waived by historical diagnostic success.

## Owned paths

`pieces/delivery/data-stream/test/elzoo/data_stream_postgres_test.exs`, `tasks/ELZ-254-admission-sweep.md`, this task's no-output job row in `docs/plans/release-plan.json`, and generated plan views. No Piece Contract, manifest, catalogue, production source, provider/pin, other test/helper, workflow or queue changes. Publish and implement together on coordinator-owned `task/ELZ-254`; create the issue without `task`, then acquire the normal API branch lock. Record measured results and limits in the PR body. Close this task and #569 after successful review and merge.
