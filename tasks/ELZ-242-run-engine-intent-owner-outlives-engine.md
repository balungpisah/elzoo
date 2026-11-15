# ELZ-242 — The README states the rule for an Effect intent process that outlives the engine

- Dependencies: ELZ-033, ELZ-192
- Output: none. No behaviour change to the ready Piece `assembly/run-engine`: one observation test shows what a new start sees, and the README states the rule. The Contract and `piece.json` do not change. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/test/**` and `pieces/assembly/run-engine/README.md` only. No `lib/`, no `piece.json`, no index file.

Issue #514 records the question, and the coordinator sized it (comment
of 2026-11-15): no behaviour change; the README states the rule — the
host fences the old engine and its intent owners before a new start,
as it already must for the engine itself — after one observation test
shows what a new start sees. Stopping the owners when the engine ends
would not run on a kill, so it cannot be the guarantee.

Facts checked on `main` at `640707ac` (lines of
`lib/elzoo/run_engine.ex` and of the test files at that commit;
confirm each when you start, and if one differs, stop and ask):

- `intent/3` (about 2186 to 2215) starts an `Elzoo.EffectIntent`
  process with `EffectIntent.start_link/1` and unlinks it at once
  (about 2205 to 2208). The engine keeps the PID only in its own
  process state `s.intents` (initially `%{}`, about 1237); a full
  restart of the engine starts with an empty map, and a replacement
  of the unit keeps the map of the running engine (about 1569).
- The engine has no `terminate/2`: nothing stops the intents when the
  engine stops. An intent process has no link and no supervisor, so
  it lives on after the engine and can still append its result or
  `Lost` to its store later. `Elzoo.RunApprovalRelease` does stop its
  intents in `terminate/2`
  (`pieces/workflow/run-approval-release/lib/elzoo/run_approval_release.ex`,
  about 821 to 824); the engine does not.
- On a new start, `recover_intents/1` (about 2730 to 2767) calls
  `intent/3` for each running or reconcile slot with no request key;
  `s.intents[key]` is nil, so `EffectIntent.start_link/1` starts a
  new process for the same identity while the old one may still be
  alive: a second owner for the same identity can exist.
- The test file already reads the engine's intent map:
  `:sys.get_state(engine).intents` gives the `%{key => pid}` of the
  running engine (used at about line 1442). The fixture's teardown
  also stops every intent pid it recorded before the schema goes
  (about 625 to 646, the comment of issue #505).
- The nearest existing test is `ALLOW dispatches once and a reserved
  recovery never sends again` (about 1530 to 1557): a `tool_call` is
  dispatched, the engine is stopped with `GenServer.stop/1`, the host
  mode switches to `:recover`, and `start/2` starts a new engine; the
  slot settles `unknown` and no second send happens.

## The work

1. Observation test, in the existing group `Intent recovery windows`
   of `test/elzoo/run_engine_test.exs`. With the `tool_call` setup
   above: after `send_input/2` the engine's `intents` map holds one
   pid (`:sys.get_state(engine).intents`); `GenServer.stop(engine)`
   leaves that pid alive (`Process.alive?/1`); `start(c)` in recover
   mode gives the new engine a second pid for the same intent while
   the first is still alive — the new start sees a second owner for
   the same identity. Assert exactly that, and that the engine
   behaves as the existing test records (the slot settles `unknown`,
   no second send). Name the test `intent_owner_outlives_the_engine`.
2. README rule, one paragraph where the README describes recovery or
   host construction (near the paragraph on intents and recovery,
   about lines 92 to 97 or 307 to 315): an Effect intent process is
   unlinked and has no supervisor, so it outlives the engine and can
   still append to its store; a new start begins with no intent
   process and can start a second owner for the same identity; the
   host fences the old engine and its intent owners before a new
   start, as it already must for the engine itself; stopping the
   owners in `terminate/2` would not run on a kill and is not the
   guarantee.

No `lib/` change, no `piece.json` change, no Contract change. The
test observes; it does not change what the engine does.

## Evidence and gate

The test is an observation: it asserts the documented behaviour, so a
green run is the evidence. If the observation shows something else
(for example the old pid is already dead, or no second pid appears),
stop and report on the issue instead of writing the README rule.

Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review; risk low (test and
document only).

## Not in scope

Stopping the intents when the engine stops, a supervisor or a
registry for the intents, a fence inside the engine, the
`terminate/2` of `RunApprovalRelease`, and any other Piece.
