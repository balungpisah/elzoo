# ELZ-211 — A refusal over the cap never turns a settled parent back into a refusing slot

- Dependencies: ELZ-033, ELZ-192, ELZ-210
- Output: none. A repair of the ready Piece `assembly/run-engine` that restores "first settlement wins" for a nested parent; one stated Limit goes away. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and `note` of its row).

Issue #441 records the defect. It was found by reading in the task
ELZ-191. A nested parent can be settled while its child goes on, for
example by its deadline. When that child then asks for a request over
the shared cap, the engine marks the parent as refusing with no look at
its phase. The parent was settled; now it is open again, and no record
can settle it a second time. It stays open for ever. ELZ-191 only made
the closer at a change of Attempt tolerate such a slot.

Facts checked on `main` (lines of `lib/elzoo/run_engine.ex` at the time
of writing; confirm each when you start, and if one differs, stop and
ask):

- `expire_waits/2` (about 1060 to 1082) settles a `running`
  `nested_callable` slot as `expired` at its deadline. The child
  callable is not closed by that, so it still takes outcomes of the
  current Attempt (about 96 to 99).
- In `invoke/3`, a request whose ordinal is over the cap (about 873 to
  913) ends with `deny(state, node.parent, "out_of_budget")` whenever
  the callable has a parent (about 906 to 911). `deny/3` (about 1114 to
  1116) merges `phase: :refusing` and the refusal into the slot. The
  outcome, the actual and the reservation of the settled slot stay.
- Every other caller of `deny/3` checks the phase first: the precheck
  (about 153 to 157), the admission (about 191) and
  `release_and_deny/4` after an authorization (about 253 to 260). The
  continuation step takes only slots that are not settled (about line
  270).
- `drain/1` then takes the slot as `next` (about 1563 to 1569);
  `progress/3` for `:refusing` (about 1762 to 1778) writes the `out:`
  record; `settle_protocol/3` does not see a settled slot (about 563),
  lets the refusing slot pass `local_precedence/3` (about 591 to 593),
  and the tracker answers late because it settled the action before
  (about 659 to 660). The slot stays `refusing`. The next round is a
  duplicate and the drain stops.
- `active_count/1` (about 2892 to 2893) counts the slot. So a new Run
  cannot be configured on the unit (about 148 and 1199 to 1213), no
  wake reaches the pattern (about 515, 539, 552), the slot holds one
  of the 64 places, and `ack/2` (about 2740 to 2746) never
  acknowledges the request.
- ELZ-191 added two things for such a slot. `may_have_sent?/3` treats
  a refusing nested parent whose child exists as sent (about 833 to
  835). The closer has a fallback: when the tracker does not apply the
  outcome, it sets only the phase back to `settled` (about 796 to
  799).
- The test `a settled parent turned back to refusing by an over-cap
  child is settled again at the change, first outcome kept`
  (`test/elzoo/run_engine_test.exs`, about 5481 to 5557, group
  `first_settlement_wins`) builds the defect on purpose: it waits for
  the phase `refusing` (about line 5536). The README (about 380 to
  384) and the sixth limit of `piece.json` name the defect as known
  and not repaired, and both name the negative control "a hard match
  in the fallback of the closer".
- The durable unit folds the stored result of each input; it does not
  run a completed step again. So a Run that already holds such a slot
  keeps it after this repair.

## The repair

A request over the cap marks the parent of its callable as refusing
only when that parent is not settled. A settled parent keeps its
phase, its outcome, its actual and its reservation; no `out:` record
is written for it. Everything else of the over-cap step stays: the
generation closes, the charge stops, the lifecycle gets its wake, and
a parent that is still running is refused as today and gets its actual
by the existing rules. A cost of the child that becomes known later
still reaches the settled parent by `:nested_actual`.

The Contract does not change: this is the stated rule "first
settlement wins". No input, option, control command, public function,
record kind or durable field is added.

What happens to the guard and the test of ELZ-191:

- The fallback of the closer (about 796 to 799) and the term in
  `may_have_sent?/3` (about 833 to 835) stay. The term is also needed
  for a running parent that was refused. The fallback is the only
  thing that frees a slot that a Run recorded before this repair
  already holds.
- The test at about 5481 changes, and the pull request body names each
  changed line. Its first part becomes the new truth: after the
  over-cap record the slot is still `settled` (the wait at about 5536
  no longer waits for `refusing`). The fallback can no longer be
  reached through the engine, so it gets a direct case: take the
  durable state of that Run, put the phase `refusing` and the refusal
  into the settled parent (the state that the unrepaired engine
  recorded), and give it to `Elzoo.RunEngine.step/2` with a `run_view`
  record of a new Attempt. The slot is `settled` again, with the first
  outcome, actual and reservation, and the Budgets are equal. Change
  no other existing test; if another one fails, stop and ask.

The README and `piece.json` lose the sentence that the deny is not
repaired. They say instead: a Run recorded before this repair that
already holds such a slot keeps it until a change of Attempt sets it
settled again (Elzoo is not released; a Limit). The README names the
new groups. The index row follows in the last commit before the pull
request is opened (in-place change of a ready Piece, same Piece ID).

## Named acceptance groups

Nearest existing tests: the test at about 5481 (the sequence), `nested
denial chain uses shared charge and settles its previously admitted
parent` (about 569), `charge-stopped child propagates later actual
without changing its settled parent outcome` (about 370) and `after
the change the Run ends and a new Run with another id configures on
the same unit` (about 5167).

1. **`settled_parent_stays_settled`**: a parent settled `expired` with
   no actual, then its child asks over the cap: the slot of the parent
   is equal, term for term, to the slot before; no outcome record
   exists for the parent; the Budgets did not move.
2. **`unit_configures_after_the_stop`**: in the Run of group 1 the stop
   ends the Run, no slot is open, and a new Run with another run id
   configures on the same unit and runs one action.
3. **`running_parent_is_still_refused`**: the tests at about 370 and
   569 pass unchanged: a running parent is refused `out_of_budget`
   and gets a later actual.
4. **`later_actual_reaches_the_settled_parent`**: in the Run of group
   1 the child cost becomes known after the stop: the parent keeps its
   outcome and gets the actual once.
5. **`replay_is_equal`**: a restart after group 1 gives an equal view,
   equal Budgets and an equal count of journal records.
6. **`recorded_defect_is_closed_at_a_change`**: the changed test of
   ELZ-191 with its direct case, as described above.

## Evidence and gate

Negative controls, each by a temporary edit that is reverted: the deny
with no look at the phase (group 1 fails: the slot is `refusing`; group
2 fails: the start of the new Run is refused as
`:incompatible_recovery`); a hard match in the fallback of the closer
(group 6 fails in `step/2`).

Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk high (durable state
and money accounting).

## Not in scope

A repair of a slot that a recorded Run already holds, other than the
existing closer; the close of a child callable when its parent
expires; the slots of a terminal Run (its own task); and any other
Piece.
