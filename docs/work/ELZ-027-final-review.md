# ELZ-027 independent final diff review

Redacted for publication; SHA-256 of the reviewer's original report: 84826b4791349934d8cd553cb313bec2dd9e9a2192ed9f80c08335349072a885

Reviewer: the independent reviewer (Codex), final diff review.
Reviewed head: `95fb678ee45dcde4665f3326b751b22afbe693e7`; comparison base: `3297219af46741442a3ccd49a15be9c93468d130`.

## Findings

**BLOCKING:** None found in the schedule-occurrence transition or the amended Contract.

**REQUIRED 1 — Timer cancellation is not established and the scenario can race.** In `pieces/delivery/trigger/test/elzoo/schedule_occurrence_test.exs`, S13c schedules the tested timer with delay 0, then allows `Process.cancel_timer/1` to return `false` and accepts a third admission. Thus a passing run need not exercise successful cancellation, although the PR and `docs/work/ELZ-027.md` claim a cancelled timer stops a further admission. Worse, if the tick is handled before the cancellation call, `handle_info` sets the timer to nil and `Process.cancel_timer(nil)` can crash the owner. Use a deterministically cancellable timer, assert successful cancellation and no subsequent admission, and avoid relying on scheduler timing. Recheck the timing-boundary scenario and applicable full checks on the final head.

**REQUIRED 2 — Explicit confirmation cleanup remains undone.** `docs/work/ELZ-027-confirmation.md` calls for cleaning up the stale `idempotency_message/3` name during implementation. `docs/work/ELZ-027.md` still claims that function exercises the real receiver; the implementation uses `consumer_dedup/3`. The same record says no implementation is committed and claims S13a builds a result with `Elzoo.Envelope.encode_result/1`, while the committed test constructs maps directly. Correct those statements or explicitly mark them as historical proposals so the executed evidence is accurate; the live Envelope validator itself is exercised.

**LOW — Roadmap live drift outside this task.** The branch's live roadmap check now stops first at ELZ-028, not the anticipated ELZ-029. The issue #44 body equals the task copy and its manifest hash, so this is a separate live-planning reconciliation, not evidence of ELZ-027 drift. The early work records retain generic temporary-directory references; no identifying absolute paths, session identifiers, or database names were found in the final diff or PR body.

## Gates and confirmation

| Gate | Assessment |
| --- | --- |
| G1 | Met: A1-rev2 is live; exact issue/task bytes and issue SHA-256 match. Numeric validation is not represented as proof of availability; inability is the caller's obligation to refuse the call. |
| G2 | Met on inspected diff: authorized trigger row/entry and regenerated views, with no tracked claim marker or protected files changed. |
| G3 | Met by inspection and the named finite scenarios: complete ordered input and serialized retention are Needs; watermark, replay, settlement, delivery matching, generation and restart are implemented. No clock or I/O is performed by the operator. |
| G4 | Met based on committed implementation and recorded check: production `identify_schedule_id`, `identify_generation`, `identify_instant`, `bound_skip`, `bound_replace`, `bound_queue` and supporting production-chain laws are named; S15 compiles production mutations and requires failures at the named laws. The field mutations target `identify` itself; placement has a separate control. Scope is hypotheses and admissible bounded states, not concurrency or availability. |
| G5 | Conditional: finite scenarios cover the dangerous paths, restart, policies, validation, composition and seven controls. Real Envelope validation and per-schedule real receiver isolation include the same-sender collision and duplicate for both schedules. The time recipe shell/timer boundary is exercised, but the successful cancellation assertion is missing and has a race (REQUIRED 1). Copied consumer was selected by the full check as recorded. |
| G6 | Met with the coordinator's recorded interpretation: actual dependencies are declared; the recipe schedules and cancels timers while the owner reads the clock; neither the recipe nor the piece claims to read it. Crontab 1.2.1 and Oban 2.24.2 are recorded as unexercised candidates, and fixture instants are not DST computation. |
| G7 | Met: all three applicability statuses are declared; Config specifies generation, queue bounds and evidence referencing the in-bundle scenarios. |
| G8 | Conditional on resolution and exact-head rechecking. The PR records pinned `mix setup` and full `mix check` at the reviewed SHA, 32 and 659 passed, full marker and UTC times, plus an earlier exit-2 environment failure and its diagnosis; no independent rerun was authorized for this review. The PR's check-fast job now passed and its log shows Cure compilation, 32 and 659 passes and the aggregate consumer selected; its selection is `affected` with a full fallback, distinct from the author's full run. Devin's zero-findings review is on the reviewed head. The committed work record points to the PR for exact run times and output, rather than independently storing those logs. This is the required independent implementation review. |

## Shared paths and scope

| Path | Assessment |
| --- | --- |
| `registry/catalogue.json` | Only the `delivery/trigger` entry changes; its ready manifest is `pieces/delivery/trigger/piece.json`. |
| `docs/plans/release-plan.json` | Only the ELZ-027 issue hash and `delivery/trigger` entry change. The manifest SHA-256 is `dd6b28e11645d88c26c98c7cf2553c6a7bc241f58c0e9ba2818bdfb8bd5c1b06`; it matches committed bytes, and the note equals the manifest Contract. |
| `LEDGER.md`, `docs/plans/views.md` | Only the trigger row and derived ready count change. The ledger row's Contract and applicability agree with the manifest; the branch roadmap checker passes. No Mix ledger regeneration was run by this reviewer. |
| `tasks/ELZ-027-schedule-occurrence.md` | Byte-equal to the live issue body; SHA-256 `1d1ea7504ebc53d39bb525906103771433a485d32b8e7a50eb132e8914393c22` matches the release plan. |
| Other paths | New trigger files and work records only. No existing test, `mix.exs`, provider, workflow, script, or protected compile/check/export/selection file changed. |

## Commands and limits

- `git fetch origin --prune`: 0. `git diff --check origin/main...origin/task/ELZ-027`: 0. The full diff, PR body/files/comments, live issue and committed work/review records were inspected with read-only commands.
- `gh pr view 117 --json body,files,comments`: 0. `gh issue view 44 --json body,title`: 0. `gh pr checks 117`: initially 8 while check-fast was pending, then 0 with check-fast and Gleam passed, check-any skipped, and Devin passed. `gh pr view 117 --json reviews,statusCheckRollup`: 0. Read-only fast-job log inspection: 0.
- `python3 scripts/check-roadmap.py`: 0 in the coordinator checkout; the same script against the existing reviewed-head tree: 0. `python3 scripts/check-roadmap.py --live`: 1 in the coordinator checkout at ELZ-027; against the reviewed-head tree: 1 at ELZ-028. `python3 scripts/check-claims.py`: 0 in the coordinator checkout; independent `git ls-tree` of the reviewed head confirms no tracked claim marker.
- Read-only Python comparisons of live issue, task copy, manifest bytes, release note and ledger Contract: 0, all comparisons true. `git diff --name-only ebcb4c4 95fb678`: 0 and shows only work-record redactions.
- No Mix command was run by the reviewer. Recorded proof and test execution is attributed to the author and CI; finite tests are not treated as proofs. The check results are tied to the reviewed SHA and must be reassessed if that SHA changes.

NOT CLEAR — resolve REQUIRED 1 and REQUIRED 2, then rerun applicable checks and review the changed head.
