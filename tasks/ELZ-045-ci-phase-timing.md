# ELZ-045 — Print per-phase and per-consumer timing in CI logs

- Phase: P0 harness (CI timing output; `test/export_test.exs`, `lib/mix/tasks/check.ex`)
- Catalogue IDs: none
- Dependencies: ELZ-038 (#68), ELZ-039 (#78) merged
- Source: CI speed assessment 2026-11-08, item 1. Items 2 and 3 need this baseline.

## Outcome

CI logs show where the time goes. Today consumer output is captured, so one silent gap of about
1146 s hides the copied-consumer tests. After this task each log has:

1. One `ELZOO TIMING` line per copied consumer step with a monotonic clock, printed on success,
   assertion failure, raise or exit (not when ExUnit kills a test on a tag timeout):
   plan and write, the consumer `mix test` VM, and the compiler-free runtime VM.
2. One `ELZOO STAGE` line with a UTC time and elapsed seconds before and after each `mix check`
   stage: format, compile, ledger, Ash spike, registry load, root suite.

## Scope

- `test/export_test.exs`: add a private timing helper. Wrap existing steps only. No test is added,
  removed or renamed. No assertion changes. Test counts stay 526 root and 32 Ash.
- `lib/mix/tasks/check.ex`: print stage stamps. No stage is added, removed or reordered.
- `docs/development/10-symbolic-ci.md`: say what the lines mean and what they do not.
- Add this body at `tasks/ELZ-045-ci-phase-timing.md`.

## Acceptance

- [ ] Full `mix setup` and `mix check` pass; `ELZOO CHECK PASSED` still prints; counts unchanged.
- [ ] A local run shows one `ELZOO TIMING` line for the aggregate and for each per-ID consumer.
- [ ] CI run on both backend runners (workflow_dispatch, same SHA) shows the lines. Record run and job IDs.
- [ ] Baseline table per consumer, per runner, in a PR comment.

## Limits

Observation only. Timing is monitored behavior, not proof. It saves no time by itself.
