# ELZ-103 — Diagnose and deterministically exercise durable-job Writer timeout boundaries

- Phase: reliability closure
- Catalogue IDs: assembly/durable-job (existing Contract unchanged)
- Dependencies: ELZ-009, ELZ-010

## Outcome

Resolve investigation #193 by controlling the actual Store/Writer/Oban boundary behind DJ21b. A Writer call timeout does not prove rollback: the accepted Contract permits a late committed attempt and charges that durable attempt. Distinguish a fixture ordering assumption from a runtime defect with executable evidence.

## Scope and ownership

The worker owns pieces/assembly/durable-job/test/elzoo/durable_job_test.exs and narrowly needed test support in that Piece, plus docs/work/ELZ-103.md and this publication copy. Coordinator owns the corresponding published-task row in docs/plans/release-plan.json and generated views. Preserve production source, Contracts, provider/toolchain pins, CI runner policy and all existing assertions. No timeout increase, budget replenishment, retry-until-green, or dispatcher work. If evidence requires a runtime fix or Contract change, stop and publish a reviewed scope amendment before implementing it.

Use isolated worktree and disposable PostgreSQL; coordinate broad checks sharing infrastructure. Preserve failed evidence and classify before rerunning. No paid calls or historical ELZ-041/044 work.

## Acceptance

1. Precisely explain or reproduce the original failure with controlled barriers through actual PostgreSQL Store, linked Writer and Oban boundaries; record which historical details cannot be inferred from the failed CI log.
2. Make the no-commit DJ21b scenario deterministic: observe Writer death and transaction rollback before releasing the held head lock. Preserve its succeeded/completed, single-attempt and no-error assertions and submit/cancel indeterminate recovery assertions.
3. Exercise the dangerous commit-before-lost-reply boundary separately with the real PostgreSQL transaction and Writer call timeout: a durable attempt consumes the single Run budget, recovery records exhausted, the unacknowledged attempt never invokes its handler, and no attempt_failed or provider error is invented. Keep the existing writer timeout; barriers establish order rather than sleeps establishing correctness.
4. Demonstrate the original unconditional success assumption fails under the controlled committed schedule and the corrected scenarios pass. Do not claim the historical scheduler trace was captured.
5. Run mix setup in the isolated checkout; changed Piece tests and mix check --affected origin/main before push, plus full mix check when current change-class rules require it. Record exact exit codes, failures and hashes. Obtain independent review at corrected SHA, dispose of automated findings, and adopt exact-head hosted checks through the coordinator's serial merge queue.
6. Close #193 only with the supported fixture/runtime disposition and remaining limits. Verify main acceptance and cleanup before task closure.

## Grounding

Finite PostgreSQL/OTP/Oban regression scenarios and source/Contract analysis; no new Cure law or universal timing proof. Store transaction durability, OTP call/exit scheduling and pinned Oban behavior remain upstream assumptions. This restores evidence ordering, not a stronger timeout or delivery guarantee.
