# ELZ-210 — A drain ends when a round changes nothing, and a parent past its deadline in a terminal request-cap Run is not selected again

- Dependencies: ELZ-033, ELZ-192
- Output: none. A repair of the ready Piece `assembly/run-engine`: the engine answers where it now loops for ever. One Limit sentence gets more exact. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and `note` of its row).

The automated review of pull request #432 (ELZ-190) found it, and the
code confirms a worse form. A Run that stopped at the request cap is
terminal, but it keeps the work that was started before the stop. If
such a Run holds a nested parent whose deadline has passed and whose
child is closed, `drain/1` selects that parent as the parent of a
finished child, writes an outcome for it, the fold classifies the
outcome as late, and `drain/1` selects the same parent again. Nothing
ends this. At a restart the start of the engine never returns; with a
live engine the call of `input/4` never returns. ELZ-192 comes first
because it changes the same file.

Facts checked on `main` (lines of `lib/elzoo/run_engine.ex` at the time
of writing; confirm each when you start, and if one differs, stop and
ask):

- `drain/1` (about 1548 to 1623) has four branches that go on. Three of
  them call `drain(s)` again with no condition: `stop_pending` (about
  1572 to 1574), a pending input (about 1576 to 1586) and
  `finished_child` (about 1588 to 1610). Only the last branch stops
  when the state did not change: `if snapshot(s) == before` (about
  1617 to 1621).
- `due_child/4` (about 1628 to 1653) takes a parent as `running?` when
  its slot is `running`, has the current Attempt, and the Run is not
  terminal or `retained?/1` holds (about 1635 to 1637). `retained?/1`
  (about 1655 to 1656) has no term for the deadline of the slot.
- `settle_protocol/3` computes `retained` with that term: the time of
  the record must be before `slot.deadline_ms` (about 577 to 579). A
  record that is not retained goes through `local_precedence/3` with
  `false` (about 593 and 670 to 690), which asks the lifecycle. In the
  phase `Terminal` the decision is always `Unchanged`
  (`pieces/workflow/bot-run-lifecycle/cure/elzoo/bot_run_lifecycle.cure`,
  about line 11), so the record is classified late and the slot stays
  `running`. The expiry of the same slot in `expire_waits/2` (about
  1060 to 1082) takes the same way and is late too.
- A terminal view does not close running work when `charge_stopped` is
  set (about line 392). So a request-cap stop with `budget_rule:
  :finish` gives a terminal Run with `running` slots.
- The outcome that `nested_outcome/4` writes (about 2142 to 2159) has
  the stable ID `out:` of the occurrence (about 2170 to 2174) and a new
  clock value. `commit/3` (about 2704 to 2722) answers `{:ok, s}` for a
  duplicate, and for an ID conflict whose winner has the same kind and
  occurrence. So each round after the first writes nothing and reads
  the journal once.
- Two sequences reach the loop. (a) A parent with the deadline 10,000
  and a child tool call with the deadline 40,000, a request-cap stop,
  then a restart at 15,000: `recover_intents/1` records the tool call
  as lost (about 2637 to 2638), the child cost is `:unknown`, and the
  `drain(s)` of `init/1` (about line 1221) loops. (b) No restart: the
  real result of the tool call, with an actual, arrives at 15,000. The
  child cost is `:known`, the reserved amount of the child Budget is
  0, and the drain inside `input/4` (about 1342) loops.
- `Enum.find_value` over the callables (about 1558 to 1561) gives the
  first child that is due. So with the stop alone, a parent that is
  selected and cannot settle would end each drain before a second due
  child, and before the branch `next`, is reached.
- The README says that a parent that can no longer take an outcome is
  not handed one, "any parent once the Run is terminal (unless the
  request-cap stop retains it)" (about 184 to 190), and names the
  group `no_loop_for_a_parent_that_cannot_settle`. `piece.json` says
  the same in its fifth limit. Neither names the deadline.

## The repair

Two edits. Both are needed: the first bounds the drain in every case,
the second keeps other work from waiting behind a parent that cannot
settle.

1. Each branch of `drain/1` calls `drain(s)` again only when its round
   changed the durable state. A round that changed nothing ends the
   drain with `{:ok, s}`. Use the test that the last branch already
   has (the state before the round against the state after it); a
   cheaper test is the subject of a later task.
2. `due_child/4` does not select a parent of a terminal request-cap
   Run at or after the deadline of its slot. The term is the one of
   `settle_protocol/3`, read with the clock of the engine, so the
   selector and the fold agree. When the clock passes the deadline
   between the selection and the record, edit 1 ends the round.

The parent that is not selected stays `running`. This task does not
settle it (its own task, on the slots of a terminal Run). The fold does
not change, so a recorded Run folds as before. No input, option,
control command, public function, record kind or durable field is
added.

The README and the fifth limit of `piece.json` get the deadline: a
parent of a terminal Run is handed an outcome only when the request-cap
stop retains it and its deadline has not passed; after the deadline it
is not selected and stays open. The README names the new groups and the
negative controls beside the group
`no_loop_for_a_parent_that_cannot_settle`, and the grounding claim of
`piece.json` follows. The index row follows in the last commit before
the pull request is opened (in-place change of a ready Piece, same
Piece ID).

## Named acceptance groups

The nearest existing tests are `both charge-stop rules retain slow
within-cap completion and denial obligations` (about line 811 of
`test/elzoo/run_engine_test.exs`), `an expired parent whose child later
closes with a lost cost stays as settled and the Run goes on` (about
4319) and the two tests of `no_loop_for_a_parent_that_cannot_settle`
(about 4458 and 4472). Use `nested_setup/2`, `lost_setup/3`,
`bounded/2`, `restart/3`, `journal/1` and `outcome_records/2` of the
test file. To reach the stop with a parent still running, the excess
request must come from the root, not from the child (an excess of the
child refuses its parent, about 906 to 911).

1. **`start_returns_with_an_expired_retained_parent`**: sequence (a)
   above. The start of the engine returns inside a bounded wait; the
   parent is still `running`; the tool call is settled with no actual.
2. **`input_returns_with_an_expired_retained_parent`**: sequence (b).
   The call of `input/4` returns `{:ok, :applied}` inside a bounded
   wait.
3. **`nothing_more_is_written`**: after group 1 and after group 2, one
   more input and one more restart leave the count of journal records
   for the parent as it was, and the view is equal.
4. **`retained_parent_before_its_deadline_settles`**: the same Run with
   the clock before the deadline of the parent: the result of the
   child reaches the parent, which settles `completed` with the
   committed child amount.
5. **`other_work_goes_on`**: two parents in one request, the first
   past its deadline and the second not, both children with only
   known costs, in a terminal request-cap Run: the second parent
   settles `completed` with its actual and the first stays `running`.
6. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged. No existing test asserts the loop.

## Evidence and gate

Negative controls, each by a temporary edit that is reverted: without
edit 1 and without edit 2, groups 1 and 2 do not return (record the
bounded failure); with edit 1 and without edit 2, group 5 fails (the
second parent is not settled).

Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk high (durable state
and a loop in the engine process).

## Not in scope

The settlement of a slot that stays open in a terminal Run (its own
task), a cheaper test for "the round changed nothing" (the cost task),
a timer for the deadline of a slot, the journal write path, and any
other Piece.
