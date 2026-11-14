# ELZ-189 — The dynamic-units tests wait for a process exit without a 100 ms limit

- Dependencies: ELZ-033
- Output: none. A repair of tests of the ready Piece `runtime/dynamic-units`; the Piece ID and its Contract stay.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/runtime/dynamic-units/test/**` only. No file of `lib/`, no `piece.json`, no README, no index file.

Issue #420 records the failure. In a hosted full check, inside the copied
consumer of all sources (about 2,100 tests in one run), the test `DY4 OTP
abnormal replacement, durable recovery, named shutdown and intensity`
(`pieces/runtime/dynamic-units/test/elzoo/dynamic_units_test.exs`) failed
at

    assert_receive {:DOWN, ^sup_ref, :process, _, :shutdown}

with "no matching message after 100ms". The test kills the last unit, which
exceeds the restart intensity, and waits for the shutdown of the
supervisor. It asserts that the shutdown happens and with which reason. It
asserts no time. The 100 ms is the default of `assert_receive/1`.

Facts checked on `main` (confirm when you start):

- The test file has five `assert_receive {:DOWN, ...}` lines with no
  explicit limit, each after an action that ends a process (a kill, a stop,
  a conflict).
- The file has a helper `eventually/1` for conditions that need time.

## Task

Give each `assert_receive` of this test file that waits for a `:DOWN`
message an explicit limit of 5,000 ms. Change nothing else: no pattern, no
reason, no order of assertions, no `refute_receive`, no tag, and no other
`assert_receive` unless it waits for the end or the start of a process and
has the default limit; name each changed line in the pull request body.

## Acceptance

- The diff changes only limits of `assert_receive` lines in the test files
  of `runtime/dynamic-units`.
- `mix test pieces/runtime/dynamic-units/test` passes 20 times in a row,
  and 5 times while the Piece suites of two other Pieces run beside it in
  the same slot; record the commands and exit codes.
- Negative control: with the limit of the DY4 line set to 0 by a temporary
  edit the test fails; revert it. This shows that the line still waits for
  the message.
- The small gate exits 0.
- The pull request closes this task and issue #420.
- One independent review.

## Not in scope

The library code of the Piece, its Contract texts, and any other Piece.
