# ELZ-260 — Increase the admission timing-sample acquisition budget

- Dependencies: ELZ-254
- Release: V1B
- Output: none
- Change class: non-Piece test-harness repair; coordinator-owned one-PR path

## Problem and scope

The local affected check for ELZ-258 failed the DataStream PostgreSQL admission sweep because the -200 microsecond offset had no qualifying sample. The same failure class reproduces on unchanged main at other offsets. Temporary timing observations place several misses inside the existing high-priority spin, after the coarse wait returned before the target; raising the spin to maximum priority also failed. The original aggregate attempts were not individually instrumented, and the exact OS/runtime preemptor is not established. This is evidence of an insufficient test-sample acquisition budget, not a demonstrated production deadline defect.

Change only the per-offset acquisition cap in `held_samples/3` from three attempts to ten, and its explanatory comment. Keep the existing high-priority final spin unchanged. This deliberately revises the acquisition cap preserved by ELZ-254; it does not revise a DataStream Contract or product retry policy. All attempted samples, including those outside the release window, must remain in the timeout-reason assertion. Every offset must still obtain the existing qualifying held sample. More attempts must never discard a wrong terminal reason or convert inconclusive sampling into a pass.

Preserve the seventeen offsets (-300 through +1,300 microseconds in steps of 100), 150 ms lifetime, strictly less than 100 microseconds release-lateness criterion, timeout reason, no-request and custody assertions, and existing cleanup-without-release classification for nonnegative offsets. Preserve all other test and production behavior. No priority escalation beyond the existing `:high`, new clock abstraction, scheduler framework, permanent pressure/instrumentation, dependency/pin change, or test exclusion.

## Acceptance and validation

1. The executable delta is only the cap change and comment in the named PostgreSQL test. Each attempt retains its distinct logical key and its reason is checked, regardless of whether it contributes held-sample coverage. A step without a qualifying sample after ten attempts still fails.
2. Record the candidate's fixed-profile diagnostic honestly: one scheduler, two normal-priority CPU workers, real disposable PostgreSQL, one `--repeat-until-failure 50` launch. It executed the initial run plus fifty repeats (51 passing sweeps), 888 attempts, a maximum seven attempts for one offset and maximum measured sweep duration 4.118312 seconds. Temporary pressure and post-sweep logging were then removed. These observations are not universal timing guarantees, and the retained cleanup classification is not proof that every held sample actually released in its window.
3. On the final uninstrumented source, run the actual repository sweep in one `--repeat-until-failure 10` launch and the entire PostgreSQL module. Record actual executions, exclusions and exit codes, recognizing that the repeat option adds repetitions after the initial run. Each observed passing sweep must complete below ten seconds; do not increase product timeouts or the release window to meet this.
4. Preserve the actual-worktree negative-control evidence: temporarily making `Session.intent_failed/1` choose unconditional `:intent_unavailable` must fail the timeout-reason assertion; temporarily delaying release by 200 microseconds while measuring against the original target must fail held-sample coverage. Both controls exited 2 in the diagnostic worktree. Restore all production/test bytes except the intended cap/comment delta, never commit controls or instrumentation, and obtain a fresh passing focused run after restoration. Repeat controls only if relevant source changes invalidate that evidence.
5. Run format, relevant cheap/source guards, live roadmap/claims checks, `mix check --affected origin/main` and `git diff --check`. Complete independent exact-diff review, full hosted evidence on the final head (dispatch the existing full workflow if the PR classifier only selects Piece checks), ready-before-merge, the coordinator queue and green-main verification. Known failures remain visible; a passing repeat does not erase an earlier failure.

## Owned paths

`pieces/delivery/data-stream/test/elzoo/data_stream_postgres_test.exs`, `tasks/ELZ-260-admission-sampling.md`, this task's no-output job row in `docs/plans/release-plan.json`, and generated `docs/plans/views.md` / `docs/plans/dependencies.mmd`. No Piece Contract, manifest, catalogue, production source, other test/helper, workflow or queue changes. Publish and implement together on coordinator-owned `task/ELZ-260`; create the issue without `task`, then acquire the normal API branch lock. Record results and limitations in the PR body. Keep this repair separate from ELZ-258 and the HTTPJob investigation in #584.
