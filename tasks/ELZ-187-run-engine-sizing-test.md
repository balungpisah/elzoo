# ELZ-187 — The 64-entry sizing test of `assembly/run-engine` does not depend on host load

- Dependencies: ELZ-033, ELZ-180
- Output: none. A repair of a test of the ready Piece `assembly/run-engine`; the Piece ID and its Contract stay.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` of its row, only when `piece.json` changes).

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

## Task

1. **Measure.** In the test of this task only (a temporary edit, not
   committed), record the time of the first `send_input(engine)` and its
   parts: the gate calls, the journal writes with their record sizes, the
   fingerprint or encoding passes, and the rest. Run the one test 10 times
   alone, and 10 times while `mix test pieces/assembly/run-engine/test`
   runs beside it in a second shell of the same slot (take the Mix seat
   rule into account: both runs are yours). Record the minimum, the median
   and the maximum of each set, and which part holds most of the time.
2. **Repair, in this order of preference.**
   - **A. Avoidable work.** If a part of the time is work that the engine
     or the test does more often than it must (the same term encoded or
     hashed again for each entry, a pass over all slots for each action, a
     cost of the test gate or of the fixture), remove that repetition. The
     engine must give the same journal records, the same fingerprints, the
     same view and the same replies as before: every existing test of the
     Piece passes unchanged, and no assertion of the sizing test changes.
   - **B. Only if A cannot reach the acceptance.** Stop. Comment on the
     issue of this task with the measurements and what holds the time. A
     longer or configurable limit of `input/4` is a change of the Contract
     of the Piece, and the coordinator decides it. Do not add a limit
     operand, do not call the engine process directly from the test, do not
     reduce 64 or 256, and do not tag or skip the test.
3. Change nothing else. No new option, no new public function, no change
   of a bound, of a reason or of the README Contract text. A README line
   changes only if repair A changes something that the README states.

## Acceptance

- The first `send_input(engine)` of the sizing test takes at most 1,000 ms
  in each of 10 runs alone, and at most 2,500 ms in each of 10 runs beside
  the Piece suite, on the worker host. The pull request body records the
  three numbers of each set before and after the repair.
- The assertions of the sizing test are unchanged (the diff of the test
  body is empty, or holds only lines that the repair needs and that weaken
  nothing; name each such line in the pull request body).
- Every test of the Piece passes; the count of tests is unchanged or
  higher.
- Negative control: restore the removed repetition by a temporary edit and
  show that the measured time returns to the earlier range. Revert it.
- The small gate exits 0 three times in a row.
- The pull request closes this task and issue #334.
- One independent review.

## Not in scope

A limit operand of `input/4`, `control/4` or `status/1`, a change of the
engine bounds (64 open and 256 lifetime actions, the state and record
sizes), the hosted workflow, and any other Piece.
