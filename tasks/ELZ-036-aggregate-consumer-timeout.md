# ELZ-036 — Raise the aggregate consumer test time limit to a measured margin

- Phase: P0 harness (test reliability; shared `test/export_test.exs`)
- Catalogue IDs: none (no Piece or Contract change)
- Dependencies: none

## Outcome

`test/export_test.exs:112` ("all selected sources compile and run outside Elzoo with only
upstream code paths") runs every ready bundle's own tests in one copied consumer. Each merged
Piece makes it slower. Its `@tag timeout: 360_000` is now too short:

- PR #59 head `4fdc8ad`, run 42314209016 attempts 1 and 2: `ExUnit.TimeoutError … 360000ms`
  at `test/export_test.exs:112`; 505/506 passed.
- Local, same head, limit removed in a scratch copy only: the test passed in 493.6 s
  (`Finished in 493.6 seconds`, exit 0, 2026-11-07).
- One earlier local untimed run exited 2 after 969 s; its output was not kept. Not reproduced.

## Scope

- Change only the `@tag timeout` on `test/export_test.exs:112` to `1_200_000` and update the
  comment above it with the new measurement and margin (~2.4x local).
- No change to the assertion, the selected IDs, or any other test.
- Add this task's source body at `tasks/ELZ-036-aggregate-consumer-timeout.md`.

## Acceptance

- [ ] Only the timeout value, its comment and the task file change.
- [ ] Full `mix check` passes; symbolic CI passes on the PR head and on the merge commit.
- [ ] Independent review of the actual diff.

## Evidence and limits

One local timing grounds the margin. It is not a bound on future runs: the test grows with
each ready Piece. A split of the aggregate test is a possible later task, not part of this one.

## Out of scope

Splitting or restructuring the aggregate test; the per-ID consumer list gap; ELZ-035 flakes;
CI runner changes (ELZ-034).
