# ELZ-154 — End a data-stream with `timeout` when its lifetime ends during intent admission

- Dependencies: ELZ-101, ELZ-149
- Allowed implementation path: `pieces/delivery/data-stream/**` only, and its index/generated changes under AGENTS.md section 3.

Issue #319 records a point that ELZ-149 found and left to the owner. When the one lifetime of a stream ends while its intent is being admitted, the terminal reason is `intent_unavailable` and not `timeout`. `Session` refuses the registration of the intent from the millisecond of the deadline, the bootstrap worker reports the failure, and the reason is set before the deadline message is handled about one millisecond later. Measured on 2026-11-13 on `main`: 30 of 30 samples in a window of about 1 ms gave `intent_unavailable`; the samples before and after the window gave `timeout`. The README does not say which reason is right there.

Decision of the owner (2026-11-13): `timeout` is right. The cause is the end of the lifetime; the intent store did not fail. The README already says that the one lifetime includes setup, and `Session` already uses this order for the acknowledgement limit: when the lifetime is over at that moment, the stream ends with `timeout` and not with `sink_timeout`.

**Rule.** When the lifetime is over at the moment `Session` records a failure of the intent (a refused or failed admission, the loss of the bootstrap worker or the loss of the intent process), the terminal reason is `timeout`. While the lifetime still runs, the reason stays `intent_unavailable`. Apply the rule at each place where `Session` sets `intent_unavailable`, in one small private function. The cleanup after the failure stays as it is.

Contract: no other reason changes its rule. No change of the public functions, the frames, the settings, the bounds, the schema or the Piece ID. A failure of the intent while the lifetime runs is still `intent_unavailable`.

## Acceptance

- `lifetime_end_during_admission`: one new test holds the return of the first `put_checkpoint` until a chosen moment relative to the end of the lifetime, from 300 µs before it to 1300 µs after it in steps of 100 µs (the sweep of the measurement on #319), at least one sample at each step. Every sample ends with reason `timeout` and leaves no live worker; a sample that is held to the end of the lifetime or later makes no HTTP request. Keep the run time of this test below 10 s.
- Negative control: with the change of `lib/` undone, `lifetime_end_during_admission` fails with `intent_unavailable`. Record at which steps, and revert.
- `intent_failure_within_lifetime`: every existing test that expects `intent_unavailable` stays unchanged and passes. If one of them fails with the new rule, stop and write the exact point on issue #319.
- `blocked_write_test_strict`: in `test/elzoo/data_stream_postgres_test.exs`, an inconclusive sample of the blocked acknowledged-write test must end with `timeout` again (one assertion and its comment). Nothing else in that test changes. This replaces the sentence of the body of ELZ-149 that accepts `intent_unavailable` there; the task file of ELZ-149 is not edited.
- If a sample of either test still ends with `intent_unavailable` after the change, do not accept the two reasons and do not widen the rule: find the place and write it on issue #319.
- The README states the rule where it describes the lifetime; `piece.json` changes only where its text names the reasons or the test count.
- `mix test pieces/delivery/data-stream/test` exits 0 with every other existing case unchanged and passing. Run `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check` before delivery. Record exact commands and exit codes.

One worker owns the claimed branch/worktree. One independent review under AGENTS.md section 6.
