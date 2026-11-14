# ELZ-187 — A call of `assembly/run-engine` waits long enough for an input at the bounds of the Piece

- Dependencies: ELZ-033, ELZ-180
- Output: none. This task changes the ready Piece `assembly/run-engine` in place: the limit of its three calls becomes a stated part of its Contract. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and `note` of its row).

Issue #334 records the failure. The test `64-entry gate batches and 256
lifetime actions leave refusal capacity, then refuse the next request`
(`pieces/assembly/run-engine/test/elzoo/run_engine_test.exs`, describe
`Sizing and sanitized evidence`) failed four times, on code that does not explain it: one hosted run on 2026-11-13, and on 2026-11-14 two local small gates
and one local full check, each on a host with other work. The two small
gates ran on the branch of ELZ-180, which changed the engine; the same
failure was then reproduced there with the run-engine files of `main`. Each time the
first `send_input(engine)` of the test ended with

    ** (exit) exited in: GenServer.call(#PID<...>, {:input, "start", ...}, 5000)
        ** (EXIT) time out

One measured time was 5,222 ms. By `AGENTS.md` section 5 a second failure of
the same test is a real failure.

Facts checked on `main` (confirm each when you start; if one differs, stop
and ask):

- `Elzoo.RunEngine.input/4` is `GenServer.call(engine, {:input, id, input,
  context})` with no limit operand, so the limit is the 5,000 ms default of
  `GenServer.call/2`. `control/4` and `status/1` are the same.
- The test helper `send_input/2`
  (`test/support/run_engine_test_helper.exs`) calls `RunEngine.input/4`.
- The test starts a fixture with the pattern `{TestPattern, :batches, {0,
  0}}` and `request_cap: 6`, and a gate that denies every entry. Its one
  input makes 256 actions in four gate batches of 64 entries, inside that
  one call. The test asserts sizes and counts. It asserts no time.

So the work of one call is near the limit of the call on a loaded host. The
test fails by speed and not by what it claims.

Amended 2026-11-14 after the measurement (step 1 of the first text; the
numbers are in a comment of the issue of this task). On the worker host the
first input of the sizing test took 4,246 to 4,630 ms alone and 4,309 to
4,988 ms beside the Piece suite, in 10 runs each. About 77 percent is the
journal write path of the durable unit and its log: 260 commits, 1,046
transactions, and 262 result records that hold the whole engine state (36.4
MB in all). That work is outside this Piece, and it follows from the record
count and the record contents, which stay. The work that the engine itself
could avoid is about 0.8 s. So an input at the bounds that the Piece states
(64 open and 256 lifetime actions) needs about 4.5 s of real work, and the
5,000 ms default limit of the call is too near to it for any caller, not
only for this test. The repair is a stated call limit. The first text of
this task forbade a limit operand; that stays.

## Task

1. `input/4`, `control/4` and `status/1` call the engine process with one
   fixed limit of 60,000 ms: one module attribute, used by the three
   calls. Add no operand, no option, no configuration and no new public
   function. `status/1` gets the same limit because its call waits behind
   an input that the engine is working on.
2. Change nothing else of the engine: no journal record, fingerprint,
   view, reply, reason or bound changes, and no internal work is removed
   or reordered in this task.
3. State the limit in the README (Limits and the description of the three
   calls) and in the Contract text of `piece.json`: the value; the measured
   time of an input at the bounds, with the host named by role; that a
   caller which needs a shorter wait runs the call in a process of its own
   and gives up the wait there (for example `Task.async/1`, then
   `Task.yield/2` and `Task.shutdown/2`), because the functions take no
   limit; and what a caller
   knows when the call ends by the limit: the exit says nothing about
   whether the input was applied, and the engine goes on with it. Say what
   the Contract of the Piece already says about sending the same input id
   again; if it says nothing that helps such a caller, say that as a
   Limit. Write no new guarantee.
4. Do not change the sizing test. Do not tag or skip it, and do not reduce
   64 or 256.
5. One existing test depends on the old limit and changes with it: `live
   caller timeout reuses committed bytes, and eviction never repeats a
   logical invocation` (describe `Append rejection/uncertainty`). Its
   caller is a task that catches the exit of `send_input(engine)` while a
   gate blocks, and the test asserts `{:timeout, _} = Task.await(caller,
   6_000)`: the exit of the call after 5 s. With the new limit the caller
   gives up in the way that step 3 names: the task runs
   `send_input(engine)`; the test asserts that `Task.yield(caller, 1_000)`
   is `nil` and then `Task.shutdown(caller, :brutal_kill)` is `nil`. Every
   later line of the test stays as it is: the unit is alive, the control
   count is 1, the gate is released, the slot waits, the same input is
   `:duplicate`, and the eviction part. So the test still shows that a
   caller that stopped waiting meets committed bytes. Change no other
   existing test. If another one fails with the new limit, stop and ask.

## Acceptance

- `call_waits_past_the_default`: an input whose work takes longer than
  5,000 ms returns `{:ok, :applied}`. Make the time certain and not a
  matter of load: a gate (or another callable of the test fixture) that
  sleeps 5,500 ms once. A `status/1` call that is sent while that input
  runs returns its view after the input. The test is tagged with a timeout
  that fits, and it is not excluded from the suite.
- `every_call_waits`: in the same slow input, a `control/4` call and a
  `status/1` call that are sent while the input runs each return their
  normal reply after it, more than 5,000 ms after they were sent. The
  three public functions use the one module attribute, and no call of the
  engine process without it is left in `lib/` (the reviewer checks this in
  the source).
- The sizing test passes unchanged; the diff of its body is empty.
- Every other test of the Piece passes unchanged, except the one test of
  step 5, whose diff is only the lines that step 5 names.
- Negative control: restore the default limit by a temporary edit;
  `call_waits_past_the_default` must end with the time-out exit. Revert it.
- The README and `piece.json` hold the texts of step 3, and the index row
  follows (`manifest_sha256`, `note`).
- The small gate exits 0 three times in a row. Record the time of
  `mix test pieces/assembly/run-engine/test` before and after (the new
  test adds about 6 s, and the test of step 5 becomes about 4 s shorter).
- The pull request closes this task and issue #334.
- One independent review.

## Not in scope

A limit operand or option of the three calls, the journal write path
(`DurableUnit`, `DurableLog`, the store), the avoidable work inside the
engine that the measurement names (its own task, if it is wanted), the
engine bounds, the hosted workflow, and any other Piece.
