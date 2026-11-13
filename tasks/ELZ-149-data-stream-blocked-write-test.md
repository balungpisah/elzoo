# ELZ-149 — Make the blocked acknowledged-write test of data-stream conclusive

- Dependencies: ELZ-101
- Allowed implementation path: `pieces/delivery/data-stream/test/elzoo/data_stream_postgres_test.exs` only.

Issue #312 records two failures on 2026-11-13 of the test "blocked acknowledged-write path spends D, cleanup keeps accepted SQL writes unknown" (line 201), on merges that change no file of this Piece: run 43389423973 (`check-aggregate`) and run 43411158095 (`check-root`). Both times `assert_receive {:blocked_sql, worker}, 1_000` got no message, and the mailbox of the second run held only `{:data_stream_terminal, _, _}`.

Diagnosis by reading, to be confirmed first: the test gives the stream a lifetime of 150 ms (`total_timeout_ms: 150`). The lifetime starts when the session starts. The checkpoint write that the test blocks comes after PostgreSQL work of the intent. When that work takes longer than 150 ms, the stream ends with `timeout` before the blocked write is reached, the worker is killed in cleanup, and `{:blocked_sql, _}` is never sent. That sample says nothing about the blocked path: it is inconclusive, not a failure of the Contract.

Contract: unchanged. Keep the three settings of the test (`total_timeout_ms: 150`, `receive_timeout_ms: 100`, `ack_timeout_ms: 100`) and every assertion of a blocked sample: terminal reason `timeout`, the blocked worker is dead, and no HTTP request was made. Change no runtime code, no other test, no setting of the module setup and no existing wait bound.

Make the verdict depend on an observation, not on a fixed race. A sample is one stream started under the blocking mode. It is conclusive only when `{:blocked_sql, worker}` was sent before its terminal arrived; assert the three facts above on it. A sample whose terminal arrives without that message is inconclusive: it must still end without an HTTP request and with reason `timeout`, or with reason `intent_unavailable` (on `main` a lifetime that ends while the intent is being admitted gives that reason; the comment on this issue records the window), and then one more sample is taken with a fresh effect (a new idempotency key; the first test of the module shows that a repeated key is fenced). Take at most five samples. Fail when none is conclusive. Never count an inconclusive sample as a pass.

## Acceptance

- Confirm the diagnosis before the change: a temporary delay of more than 150 ms before the blocked checkpoint write makes the test on `main` fail as issue #312 records (no `{:blocked_sql, _}`, terminal present). Record what was done and seen. If it does not, stop and write the finding on issue #312 instead of changing the test.
- With the change: the same temporary delay, applied to the first sample only, gives a pass on a later conclusive sample; applied to every sample, the test fails with a message that names the inconclusive samples. A temporary fault that the test exists to catch (for example a terminal reason other than `timeout` on a blocked sample, or a blocked worker left alive) still fails it. Remove every temporary edit.
- Run the test alone twenty times and the Piece suite once: `mix test pieces/delivery/data-stream/test`. Record the count of conclusive first samples.
- Run `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check` before delivery. Record exact commands and exit codes.

One worker owns the claimed branch/worktree. If the repair does not fit this one file, stop for the coordinator's scope decision. One independent review under AGENTS.md section 6. The pull request closes issue #312 as well.
