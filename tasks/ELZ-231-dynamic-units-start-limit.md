# ELZ-231 — A call of `runtime/dynamic-units` waits long enough for a unit that replays a large journal

- Dependencies: ELZ-122, ELZ-189
- Output: none. This task changes the ready Piece `runtime/dynamic-units` in place: the limit of its four calls becomes a stated part of its Contract. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/runtime/dynamic-units/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` of its row). No file of `pieces/assembly/run-engine/`.

Issue #488 records the failure. `assembly/run-engine` starts its
durable unit with `DynamicUnits.start/2`. That is a `GenServer.call`
with the 5,000 ms default. The directory starts the unit inside the
call, and the unit replays its whole journal before the start returns.
Measured on a worker host: a first start with an empty journal took 5
to 13 ms; a restart of a unit near the control bound of the engine (834
journal rows, about 411 MB as Erlang terms) took 3.0 to 4.9 s. With
other work on the host the call passed 5,000 ms in 2 of 3 launches on
`main`, each time with

    {:timeout, {GenServer, :call, [_, {:start, identity}, 5000]}}

The engine catches the exit and stops with `:indeterminate_startup`. So
a Run that is valid by every stated bound can make its engine unable to
start again. This is the same family as the limit that ELZ-187 removed
from the calls of the engine, and the repair is the same: a fixed,
stated limit.

Facts checked on `main` (confirm each when you start, and if one
differs, stop and ask):

- `pieces/runtime/dynamic-units/lib/elzoo/dynamic_units.ex`, 26 to 29:
  `start/2`, `find/2`, `stop/2` and `route/3` are `GenServer.call` with
  no limit operand.
- The same file, `wake/3` (about 188 to 231): the directory calls
  `DynamicSupervisor.start_child/2` inside its own `handle_call` (about
  214). That call has no limit of its own and returns when the `init`
  of the unit returns. `route/3` goes through `wake/3` too (about 171),
  so a route to a sleeping identity holds the same start.
- `pieces/runtime/durable-unit/lib/elzoo/durable_unit.ex`, `init/1`
  (about 48 to 85): it starts the writer of the journal, reads the
  folded model from it, finishes a pending input and makes one offer
  pass, all before it returns.
- The directory is one process. While it holds one start, every other
  call waits in its mailbox: a `find`, a `stop`, a `route`, and a
  `start` of the same or of another identity.
- When a caller of `start/2` stops waiting, the directory does not
  stop: it finishes the start, installs the unit and sends a reply that
  nobody reads. A later `find/2` returns `{:ok, pid}` of that unit, and
  a later `start/2` returns the same pid. A second `start/2` that was
  sent in the meantime waits in the mailbox and then finds the unit
  live, so it cannot start a second unit. The limit is only how long
  the caller waits. It decides nothing about the unit.
- `start_unit/4` (about 33 to 38) sends `{:unit_started, ...}` to the
  directory. It serves the replacement that the supervisor starts after
  an abnormal exit (`handle_info`, about 93 to 110). It is not a start
  outside the call: the first start of an identity is always inside the
  `handle_call`.
- `stop/2` calls `DynamicSupervisor.terminate_child/2` inside the call
  (about 242), with the shutdown policy of the unit.
- The README of the Piece, about 64 to 66: "Ordinary GenServer timeouts
  remain uncertain for any mutating operation, including waiting in the
  controller mailbox." About 81 to 83: "Slow recovery, transition or
  termination may block this small directory". `piece.json`, third and
  fourth entry of `limits`: "Caller timeout is uncertain." and "Slow
  operations block the directory". No text states a value.
- `pieces/assembly/run-engine/lib/elzoo/run_engine.ex` calls the
  directory at three places and passes no limit: `DynamicUnits.start`
  in `init/1` (about 1143; the `catch :exit` of `init/1`, about 1230,
  gives `{:stop, :indeterminate_startup}`), `DynamicUnits.start` in
  `current/1` (about 1487; its `catch :exit` halts with
  `:ownership_unknown`), and `DynamicUnits.stop` (about 2728). The
  README and `piece.json` of the engine state no time for these calls.
- Other callers under `pieces/`: the tests of the engine (`find` and
  `stop`), the test helper of `runtime/recipe-test` (`stop`, about
  807), and the example of this Piece. None passes a limit, and none
  asserts an exit by time of a directory call. No test of the engine
  asserts `:indeterminate_startup`.
- The test file of the Piece has the seam that this task needs. The
  `unit_options` callback of `pool/3` (about 60 to 93) blocks inside
  the directory when the probe says `callback: :block`, sends
  `{:starting, identity, pid}` to the test and waits for `:continue`.
  The test `DY3` uses it (about 281 to 289). `async_call/2` (about 97)
  runs a call in a process of its own. The supervisor of `pool/3` has
  `max_children: 2`.

## Why this repair and not another

- A directory that starts a unit outside its own loop would be a new
  design. The supervisor itself starts one child at a time inside its
  own process, and `find`, `route` and `stop` ask that supervisor for
  its children, so they would still wait behind a start. The existing
  `{:unit_started, ...}` message does not do part of it. Not in this
  task.
- An engine that treats the exit as "still starting" and then waits by
  `find/2` would change the engine file, which a chain of open tasks
  changes now, and it would need a limit of its own for that wait. It
  is not needed: with a limit far above the measured time the start
  returns inside the call.
- A limit operand or an option of the calls is not needed either. The
  engine passes none.

## Task

1. `start/2`, `find/2`, `stop/2` and `route/3` call the directory with
   one fixed limit of 60,000 ms: one module attribute, used by the four
   calls. Add no operand, no option, no configuration and no new public
   function. `find/2` and `stop/2` get the same limit because they wait
   behind a start that the directory is working on; `route/3` because
   it can hold a start itself.
2. Change nothing else of the directory: no reply, no reason, no state,
   no order of work, and no limit of a call that the directory itself
   makes (the supervisor calls and the barrier `DurableUnit.snapshot/1`
   of a route stay as they are).
3. State the limit in the README (the paragraph on results and
   timeouts, and the sentence on a blocked directory) and in the
   `limits` of `piece.json`: the value; that the four functions take no
   limit; the measured time of a restart near the control bound of
   `assembly/run-engine`, with the host named by role, as one
   observation and not a bound; that a caller which needs a shorter
   wait runs the call in a process of its own and gives up the wait
   there (`Task.async/1`, then `Task.yield/2` and `Task.shutdown/2`);
   and what a caller knows when the call ends by the limit or it stops
   waiting: nothing about whether the operation was done, and the
   directory goes on with it. For a start, say what the facts above
   say: a later `find/2` or `start/2` returns the unit when the start
   succeeded. Keep the word "uncertain" for `stop` and `route`. Write
   no new guarantee and no bound on the time of a replay.
4. The `contract` string of `piece.json` stays, so the `note` of the
   index row stays; `manifest_sha256` follows the new bytes.
5. Change no existing test. If one fails with the new limit, stop and
   ask.

The engine is not edited. It passes no limit, so it waits up to
60,000 ms at its three call sites, and its two `catch :exit` clauses
stay: a start that does not return inside the limit still stops the
engine with `:indeterminate_startup` (in `init/1`) or halts it with
`:ownership_unknown` (in `current/1`), as today, only later.

## Named acceptance groups

New tests in `pieces/runtime/dynamic-units/test/elzoo/dynamic_units_test.exs`.
The nearest existing test is the blocked start of `DY3`. Make the time
certain and not a matter of load: hold the start with the blocking
callback for 5,500 ms. No test replays a large journal. No new test
is excluded from the suite or tagged to be skipped.

1. **`start_waits_past_the_default`**: with `callback: :block`, a
   `start/2` of one identity is sent from a process of its own. The
   test waits 5,500 ms after `{:starting, identity, pid}`, in which no
   reply comes. Then it sets `callback: :ok` and sends `:continue`. The
   start returns `{:ok, pid}`, `find/2` returns the same pid, and the
   supervisor has one child.
2. **`every_call_waits_behind_a_start`**: during the same hold, a
   second `start/2` of the same identity, a `find/2` of another
   identity and a `stop/2` of another identity are sent, each from a
   process of its own. Each returns its normal reply after the release,
   more than 5,000 ms after it was sent: the same `{:ok, pid}`,
   `:not_found` and `:ok`. One unit exists.
3. **`route_wake_waits_past_the_default`**: a `route/3` to a sleeping
   or new identity whose wake is held for 5,500 ms returns `{:ok,
   :routed}`, and the unit evaluated the input once.
4. **`one_limit_for_the_four_calls`**: the four public functions use
   the one module attribute, and no call of the directory process
   without it is left in `lib/` (the reviewer checks this in the
   source).
5. **`existing_behaviour`**: every existing test of the Piece passes
   with an empty diff of its body. The tests of `assembly/run-engine`
   and of every other ready Piece that the small gate selects pass
   unchanged.

Groups 1 and 2 may share one hold, so that the suite waits 5,500 ms
twice and not three times.

Negative controls, each by a temporary edit that is reverted and never
committed:

- With the default limit restored on `start/2`,
  `start_waits_past_the_default` fails: the caller ends with the
  time-out exit and no reply comes.
- With the default limit restored on `find/2`,
  `every_call_waits_behind_a_start` fails.
- With the default limit restored on `route/3`,
  `route_wake_waits_past_the_default` fails.

## Evidence and gate

Run `mix test pieces/runtime/dynamic-units/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. The small gate also runs `assembly/run-engine` and
the other ready Pieces that depend on this one. The index row follows
in the last commit (AGENTS.md section 3). Record in the pull request
body the time of `mix test pieces/runtime/dynamic-units/test` before
and after (the new tests add about 11 s). The pull request closes this
task and issue #488.

Write under `Assumptions` in the pull request body what no test of this
task shows:

- A call that is not answered ends with the time-out exit at 60,000 ms.
  This is the behaviour of `GenServer.call/3` (`Upstream`); a test of
  it would wait 60 s in every gate, so there is none.
- The engine then stops with `:indeterminate_startup` or halts with
  `:ownership_unknown`. This is read in the code of the engine, which
  is unchanged; no test of the engine asserts it today.
- An engine whose unit replays for more than 5,000 ms starts again.
  This follows from the limit and from the unchanged call sites; no
  test of this task starts an engine. Make no claim about the time of a
  replay.

## Review risk

High: startup and recovery of durable units. One independent review by
a strong reasoning model. The reviewer checks that nothing but the wait
of the caller changed; that a caller which waits longer cannot now
receive a reply for a start that the directory gave up (the directory
gives up no start); and that the README does not turn the limit into a
bound on a replay.

## Not in scope

A limit operand or option of the four calls. A start outside the loop
of the directory. Any file of `assembly/run-engine`, also its README
and its tests. The cost of the replay and of the journal
(`runtime/durable-unit`, the log, the store, issue #431). The limit of
`DurableUnit.snapshot/1`, `step/3`, `checkpoint/1` and
`offer_pending/1`. Any other Piece.
