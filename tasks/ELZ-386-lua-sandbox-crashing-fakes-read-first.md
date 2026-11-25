# ELZ-386 — runtime/lua-sandbox: the crashing fakes that write bytes read the frame header first, so their test cannot lose the race to the request

- Phase: repair of the ready Piece `runtime/lua-sandbox` before the first release (defect #932)
- Dependencies: ELZ-163, ELZ-195
- Release: V1B
- Output: none. A test repair in place of the ready Piece `runtime/lua-sandbox` (ELZ-163), with the same Piece ID (`AGENTS.md` section 4). The host's classification does not change; two test fakes change, and the README group and `piece.json` claim that list the changed fakes follow them.
- Change class: Piece-only implementation (`scripts/ci-change-class.py`: the Piece directory, its index row and generated files). It is not the test-only one-PR path of `AGENTS.md` section 1, because the README and the `piece.json` claim name the fakes that stay unchanged.
- Owned paths: `pieces/runtime/lua-sandbox/test/elzoo/lua_sandbox_protocol_test.exs`, `pieces/runtime/lua-sandbox/README.md`, `pieces/runtime/lua-sandbox/piece.json`; the `manifest_sha256` and `note` of its `entries` row in `docs/plans/release-plan.json` and the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd` (`AGENTS.md` section 3). No change of `lib/` (the C host and `Elzoo.LuaSandbox.Child` included), no other test file, no other Piece, no root test or helper, no `mix.exs`, `mix.lock` or CI.

## Defect and cause

Reported in #932. This publication does not settle #932; the build pull request does.

The test "malformed frames from a fake child a crashing child" (`test/elzoo/lua_sandbox_protocol_test.exs`, line 430) failed once in run 45464707669 (attempt 1, job check-root): the fake `partial-then-fail`, whose body is `printf` of `<<9, 0, 0, 0, ?{>>` and then `exit 2`, gave `{:host_outcome, :protocol_error}` where the test expects `{:host_outcome, :process_exit}`. The full rerun passed.

The cause is in the test, not in the Piece's classification. Checked on `main` at `c6fe7a8f`:

- `Elzoo.LuaSandbox.Child` (`lib/elzoo/lua_sandbox/child.ex`) writes the request to the Port only after the child is started (`run/4`, `send(port, {self(), {:command, frame}})`). The owner then reads `await/4`: an `{:exit_status, status}` report with no complete frame is `process_exit` for every status other than 0 (`exited/3`); an `{:EXIT, port, _}` with no exit report (a write into a closed child input) is `protocol_error` when bytes that are not one reply frame were read and `process_exit` otherwise.
- The moduledoc of `Elzoo.LuaSandbox` (`lib/elzoo/lua_sandbox.ex`, about lines 117–120, section "Cleanup") states that rule: "An exit of the Port, for example a write into a closed child input, is a message to the owner and a host outcome (`process_exit`, or `protocol_error` when bytes that are not one reply frame were read), never an exit signal to the caller." The README does not: its paragraph that begins "One fresh process and Lua state per call" says only that such an exit "is a host outcome and never an exit signal to the caller", and its sentence "A partial header or body, EOF, … are `protocol_error`" names no order of events. So both results are documented answers of the Piece to two different orders of events in the moduledoc, and the README is silent on which one a Port exit gives.
- `partial-then-fail` and `reply-then-fail` (line 435: a whole reply frame, then `exit 1`) write and exit without reading their input. When the child has ended and its exit is not yet reported when the request is written, the write meets a closed input: the Port ends with no exit report, after the fake's bytes were read (`protocol_error` for the partial frame; for the whole frame, `protocol_error` too when only part of it was read first).
- The race was not reproduced with the unchanged fake. The cause is an inference from the code: the `{:EXIT, port, _}` branch of `await/4` is the only path in `child.ex` that gives `protocol_error` for these five bytes followed by exit 2. A probe on the orb, a temporary edit that was reverted, shows that branch: with a 150 ms sleep before the request write in `run/4`, a fake that closes its input (`exec 0<&-`), writes the same partial frame, sleeps 0.5 s and exits 2 gave `protocol_error`, and the same fake with `head -c 4 >/dev/null` first, in place of the close, gave `process_exit`. The window is narrow: with a random sleep of 1 to 12 ms before the write, 85 runs of the unchanged test all passed, and an independent review's 300 Port-level runs with 0 to 150 ms before the write all gave the data and then `exit_status` 2.

ELZ-195 (group 25, `fakes_read_first`) made each fake that writes or exits without a read, and whose test expects a result other than `process_exit`, read the frame header first. These two fakes expect `process_exit`, so that rule left them out, but they write bytes before they exit, so they can lose the same race.

## The change

- In the test "a crashing child", the bodies of `reply-then-fail` and `partial-then-fail` begin with `head -c 4 >/dev/null`, as the fakes of group 25 do. Their expected results stay `{:host_outcome, :process_exit}`. The fakes that write no byte (`exit3`, `killed`, `segv`) stay as they are: a Port exit with no byte read is `process_exit` in either order.
- README, paragraph "One fresh process and Lua state per call": the sentence on an exit of the Port gains the moduledoc's rule, so it reads that such an exit "is a host outcome (`process_exit`, or `protocol_error` when bytes that are not one reply frame were read) and never an exit signal to the caller". This states behaviour that `lib/` already has and the moduledoc already says; no result changes.
- README, group 25 (`fakes_read_first`): it also names the two crashing fakes that write bytes before they exit and read the header first, with the reason (a Port exit after their bytes would be `protocol_error`). `piece.json`: the `fakes_read_first` part of the `plain_data_and_protocol` grounding claim says the same, and its words "the crashing, closing, killed and never-reading fakes stay as they are" name the crashing fakes that write no byte. The `note` and `manifest_sha256` of the index row follow `piece.json`.
- Nothing else changes: no expected result, no other fake, no `lib/` file (the moduledoc included).

## Acceptance

1. The two fakes read the four header bytes before they write; `git diff "$(git merge-base origin/main HEAD)" -- pieces/runtime/lua-sandbox/test` changes only those two bodies.
2. `mix test pieces/runtime/lua-sandbox/test/elzoo/lua_sandbox_protocol_test.exs:430 --repeat-until-failure 200` passes in one launch (`AGENTS.md` section 4), as group 25's repeat did; the command, its result and its time are recorded in the pull request. The unchanged test also passes such repeats, so this shows that the repair breaks nothing, not that it removes the race; the negative control and the review of the fakes carry that.
3. Every test of the Piece passes, with the same count of tests as on `main`.

Negative control, a temporary edit in the worktree that is reverted and never committed: with a sleep of 150 ms before the request write in `run/4` of `lib/elzoo/lua_sandbox/child.ex`, change the body of `partial-then-fail` to close its input first (`exec 0<&-`, the partial frame, `sleep 0.5`, `exit 2`) and run the test: it fails with `protocol_error`. Then, with the same sleep, the repaired body passes. Record both runs in the pull request. As in group 25, removing the read alone is not a decisive control, because the race is narrow; the review reads the fakes.

## Gate, review and build

Run `mix test pieces/runtime/lua-sandbox/test`, then the small gate `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`. The Piece runs untrusted input and holds native code, so it keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk", `AGENTS.md` section 6), although only two test fakes and their wording change. The hosted `check-piece` run on the exact head and the merge queue follow.

## Limits to state

- The host's classification is unchanged, so a real child that writes bytes and ends before its request is written is still `protocol_error`, and one that is reaped first is `process_exit`: both host outcomes, as the moduledoc and, after this task, the README say.
- The race was not reproduced with the unchanged fake; its cause is inferred from the one code path that can give that result, and shown with a delayed write and a fake that closes its input.
- A fake that reads four bytes and ends cannot meet a closed input only while the rest of the request fits the pipe buffer of its input; the request of these tests is small, and its size is not measured here.
- A repeat of one test, not a proof that no other fake of the Piece can race.
