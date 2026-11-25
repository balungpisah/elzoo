# ELZ-389 — assembly/run-engine: stabilize unpaired input recovery after owner-tree fencing

- Dependencies: ELZ-127, ELZ-385, ELZ-387
- Release: V1B
- Output: no new Piece ID; restore the existing recovery evidence or behavior for #852.
- Change class: Piece-only implementation (test-only if the defect is in the test).
- Owned paths: `pieces/assembly/run-engine/**`; its manifest hash and note in `docs/plans/release-plan.json` and generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd` only if the manifest changes. No root helper or dependency changes.

## Contract

Unchanged. Diagnose why the caller in `run_engine_v2_source_test.exs` ("unpaired original input resumes from stored time and facts after owner-tree fencing", line 2048 on `3e72f6f9`) sometimes fails to report `:caller_fenced`. If the test races, repair only its ordering. If the engine is at fault, restore the documented fencing and recovery behavior. Do not increase a wait to mask a race or weaken assertions. Stop and report if the repair needs a different durable record format or control key, or if the failure cannot be reproduced and attributed.

## Acceptance

- On the build base, run the named case at its current line with `mix test <file>:<line> --repeat-until-failure 200`; record the failure and completed iteration count. Attribute it to the failing interleaving, not just the receive timeout.
- After the repair, the same repeat reaches 200 and all run-engine tests pass on disposable PostgreSQL. Keep the assertions that fencing leaves the unpaired input intact; recovery uses its original time and verified source facts, appends its result without fetching the event again, and treats a repeat of the same input as unchanged.
- Negative control: temporarily restore the faulty ordering or code and record the reproduced failure in the same repeat; restore the fix before the final gate.

Durable state, concurrency and unknown outcomes: local small gate and full review. No new dependency.
