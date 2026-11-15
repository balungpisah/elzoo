# ELZ-243 — The engine survives a Unit that dies between the liveness check and the state read

- Dependencies: ELZ-033, ELZ-192
- Output: none. A repair of the ready Piece `assembly/run-engine`: a state read that reaches a Unit which died after the liveness check falls back to the durable recovery read instead of exiting the engine. The Contract and `piece.json` do not change; the README gets the rule. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/lib/**`, `pieces/assembly/run-engine/test/**` and `pieces/assembly/run-engine/README.md` only. No `piece.json`, no index file of another Piece.

Run 43716859739 of `main` at `ed0c5ce0` (the merge of ELZ-234) is
classified `defect` on issue #98. One test failed:
`run_engine_test.exs` "Local work recovery/cancel targeted cancel
closes before controller cancellation; Unit replacement records loss
before queued result" — `GenServer.call` to the engine ended with
`(EXIT) no process`: the engine process was gone. The debug worker
(issue #98 comments and the board) reproduced it on `ed0c5ce0` at
about one run in four to five of that test, and showed that ELZ-217
(PR #549) only narrows the window: its `read_state/1` keeps the same
liveness-check-then-call shape. This is the one forward-repair task
for that defect, under the wave-1 advance approval of
`docs/development/13-coordinator.md` (at most two repair attempts;
repair forward only, no revert, no history rewrite, no new Piece ID).

## The defect

Facts checked on `main` at `ed0c5ce0` (lines of
`lib/elzoo/run_engine.ex` at that commit; confirm each when you
start, and if one differs, stop and ask):

- `snapshot/1` (about 2990 to 3003) reads the live Unit state with
  `Process.alive?(s.unit)` and then `DurableUnit.snapshot(s.unit)`,
  which is `GenServer.call(server, :snapshot)`
  (`pieces/runtime/durable-unit/lib/elzoo/durable_unit.ex`, about
  12). When the Unit is not alive it falls back to
  `Elzoo.Checkpoint.recover/5` over the durable log, the same read a
  restarted Unit replays.
- `handle_info(%Outbox.Item{}, s)` (about 1337 to 1352) calls
  `drain(s)` then `ack(s, item)` with no `try`/`catch`. `drain/1`
  (about 1627) and `ack/2` (about 2866) each call `snapshot(s)`.
  `DynamicUnits.stop/2` terminates the Unit through
  `DynamicSupervisor.terminate_child`
  (`pieces/runtime/dynamic-units/lib/elzoo/dynamic_units.ex`, about
  246 to 249). A Unit that dies between `Process.alive?` and the
  `GenServer.call` makes the call exit; with no handler the exit
  propagates and the engine GenServer (started `restart:
  :temporary`) dies, so the next `RunEngine.input` finds no process.
- The same liveness-check-then-call shape exists at every `snapshot/1`
  caller: `handle_call(:status)` (about 1278), `ingest/4` through
  `checked_ingress/4` (about 1408), `handle_info({:durable_unit_input,
  ...})` through `current/1` and `commit/3`, and inside `drain/1`,
  `again/2`, `progress/3`, `release_waiting/3` and the resource
  consumers. `ingest/4` already catches `:exit` (about 1400 to 1402)
  but maps it to `{:indeterminate, :delivery}` and halts the engine
  with `:delivery_unknown`, which is wrong for a Unit that is being
  replaced on purpose: the test expects the next `input` to apply.
- `commit/3` (about 2833 to 2854) already catches `:exit` and returns
  `{:error, :delivery_unknown, %{s | halted: :delivery_unknown}}`;
  `current/1` (about 1563 to 1581) catches `:exit` and returns
  `{:error, :ownership_unknown, ...}`. Halting is the designed answer
  for an uncertain durable write, not for a state read of a Unit that
  is gone: the durable log still holds every committed record, and
  `Elzoo.Checkpoint.recover/5` reads exactly that.
- The failing test stops the Unit on purpose in its `:replace` branch
  (`run_engine_test.exs`, about 1717 to 1719) and then expects
  `RunEngine.input(engine, "wake", ...)` to answer `{:ok, :applied}`:
  `current/1` starts a replacement Unit through
  `DynamicUnits.start/2`, `recover_local/1` records the loss of the
  running local work, and the input applies. The engine must not be
  halted by an Outbox offer that raced the stop.
- ELZ-217 (PR #549, head `c6659df5`) renames `snapshot/1` to
  `read_state/1` (about 3211 to 3218 of that branch) with the same
  `Process.alive?` then `DurableUnit.snapshot` shape, plus a
  `s.state` cache. It mitigates by calling the read less often but
  does not remove the race. This repair must merge cleanly with #549
  pending and be correct on both `main` and after #549 lands; the
  coordinator sequenced this repair first (board message of
  2026-11-15).

## The repair

In `snapshot/1`, the `DurableUnit.snapshot(s.unit)` call sits inside a
`try`/`catch`: an `:exit` — the Unit died after `Process.alive?`
returned true, or the call otherwise found no live server — takes the
same `Elzoo.Checkpoint.recover/5` fallback that the
`Process.alive? == false` branch already takes, extracted to one
private function so both branches share it. No halt, no new state
field, no new public function, no change to `commit/3`, `current/1`,
`handle_info` or any record. A state read of a dead Unit answers the
last committed durable state, which is what a restarted Unit replays;
the next `current/1` still performs the replacement recovery, and a
genuinely uncertain write still ends in the existing
`:delivery_unknown`/`:ownership_unknown` halts.

Do not change `DynamicUnits`, `DurableUnit`, `Checkpoint`, the test,
the Contract, `piece.json` or any index file of another Piece. If the
identical check on the exact head exposes a second defect, stop for
the coordinator's scope decision rather than extending the repair.

## Acceptance

- **`unit_death_during_state_read_recovers`**: on `main` before the
  repair, `mix test
  pieces/assembly/run-engine/test/elzoo/run_engine_test.exs:1691
  --repeat-until-failure 30` shows the `(EXIT) no process` engine death
  at least once (the measured rate is about one in four to five); on
  the repaired head the same command passes 30 of 30, and a second run
  of 30 passes 30 of 30. A fix that only narrows the window is not
  acceptable: the read must not exit.
- **`no_other_path_changes`**: `git diff origin/main...HEAD` touches
  only `pieces/assembly/run-engine/lib/elzoo/run_engine.ex`,
  `pieces/assembly/run-engine/test/**` (a new regression test only if
  one is needed — prefer proving with the existing named test),
  `pieces/assembly/run-engine/README.md`, `tasks/ELZ-243-*.md`,
  `docs/plans/release-plan.json` and the generated plan views of
  AGENTS.md section 3 for this task row.
- **`small_gate`**: `mix check --piece "$(git merge-base origin/main
  HEAD)"` and `git diff --check` pass on the exact head; the hosted
  `check-piece` run on that head is green.
- **`review`**: one independent review under AGENTS.md section 6; the
  PR body notes that ELZ-217's `read_state/1` needs the same catch when
  #549 rebases onto this repair.
- Record the reproduction before the fix and the passes after it, with
  exact commands and exit codes, in the pull request body.
