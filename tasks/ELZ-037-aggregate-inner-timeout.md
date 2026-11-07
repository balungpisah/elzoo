# ELZ-037 — Give inner tests of the aggregate consumer a measured per-test time limit

- Phase: P0 harness (test reliability; shared `test/export_test.exs`)
- Catalogue IDs: none (no Piece or Contract change)
- Dependencies: ELZ-036

## Outcome

After ELZ-036, the aggregate consumer test (`test/export_test.exs:112`) runs to the end, but
one inner test can exceed ExUnit's default 60 s per-test limit inside the copied consumer:

- PR #59 head `528e6a3`, run 42327909118 attempt 1: inner consumer `Result: 424/425 passed`;
  `pieces/assembly/request-route-retry/test/elzoo/request_route_retry_test.exs:123`
  `ExUnit.TimeoutError … 60000ms`, stack in `Cure.Compiler.Lexer` under
  `Cure.Elab.Program.user_source_path/1` (Cure reads every copied source root).
- The same test passes in the aggregate run locally (`/tmp/elz024-aggregate.log`, 493.6 s total).

The inner time grows with the number of ready Pieces copied together.

## Scope

- Only for the aggregate consumer, write `ExUnit.start(seed: 0, timeout: 300_000)` into the
  copied consumer's `test/test_helper.exs`. The per-ID consumers keep the default 60 s limit.
- No change to any assertion, selected IDs, or any Piece's own tests.
- Add this task's source body at `tasks/ELZ-037-aggregate-inner-timeout.md`.

## Acceptance

- [ ] Only the helper option, its comment and the task file change.
- [ ] Full `mix check` passes; symbolic CI passes on the PR head and on the merge commit.
- [ ] Independent review of the actual diff.

## Evidence and limits

One CI timeout and one local pass ground the change. 300 s is 5x the default limit; it is not
a bound on future growth. Splitting the aggregate test is the likely next step and is not part
of this task.

## Out of scope

Splitting or restructuring the aggregate test; Cure compiler performance; ELZ-034 runners.
