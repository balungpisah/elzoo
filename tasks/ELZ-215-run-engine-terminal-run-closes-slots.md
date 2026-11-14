# ELZ-215 — A terminal Run keeps open only what a request-cap stop retains, and only until its deadline

- Dependencies: ELZ-033, ELZ-192, ELZ-214
- Output: none. This task changes the ready Piece `assembly/run-engine` in place: what happens to open slots when the Run is terminal becomes a stated part of its Contract. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and `note` of its row).

Two reports led here, and the code shows that they are one defect with
a wider reach. The automated review of pull request #437 (ELZ-192)
found that a waiting nested parent is not settled when the Run ends.
The triage of the review threads of pull request #432 found, by
reading, that a slot which a request-cap stop retains is never
settled once its deadline has passed. In both cases the slot stays
open for ever, so the unit can never be configured for a new Run.
ELZ-191 closes open slots only at a change of Attempt, and a terminal
Run takes no new Attempt.

Facts checked on `main` (lines of `lib/elzoo/run_engine.ex` at the time
of writing; read in the code, not run; confirm each when you start,
and if one differs, stop and ask):

- A view with an outcome sets the lifecycle to `terminal` (about 390
  to 400). It closes running local work, and only when
  `charge_stopped` is not set (about line 392). No other slot is
  touched.
- A new Run is configured on the unit only when the old Run is
  terminal and `active_count/1` is 0 (about 148, 1199 to 1213 and
  2892 to 2893).
- In the phase `Terminal` the lifecycle always decides `Unchanged`
  (`pieces/workflow/bot-run-lifecycle/cure/elzoo/bot_run_lifecycle.cure`,
  about line 11; its wrapper gives the state back unchanged). So in a
  terminal Run every outcome and every expiry is classified late,
  for each kind: a model call, tool call or person ask by the
  lifecycle branch (about 599 to 616), and local work, a nested
  callable, a finish and the Resource kinds by `local_precedence/3`
  with `false` (about 583 to 597 and 668 to 690). `expire_waits/2`
  (about 1060 to 1082) takes the same way. `due_child/4` does not
  select a parent of a terminal Run (about 1635 to 1637).
- One exception exists, `retained` (about 577 to 579): the generation
  is closed, the charge is stopped, no Attempt was cancelled, and the
  time of the record is before the deadline of the slot. Then the
  outcome is applied. At or after the deadline the exception ends,
  and the slot can never settle.
- What still moves in a terminal Run: `drain/1` drives a slot in
  `checking`, `refusing`, `allowed`, `authorizing`, `ready` or
  `approval` (about 1563 to 1569) to a refusal: the admission denies
  with `run_terminal` (about 199 to 200), a ready slot is refused
  with `run_or_authority` (about 1845 to 1853), a slot in `approval`
  is refused with `run_terminal` (about 1817 to 1826). A refusing
  slot settles because `local_precedence/3` is skipped for it (about
  591 to 593). The gate is still asked for a slot in `checking`.
- So these stay open for ever in a terminal Run that is not a
  request-cap stop: a running model or tool call, a waiting person
  ask, a slot in reconcile, a running nested parent and every slot
  of its child, a running Resource action, a ready slot that holds a
  request key under an ASK decision (about 1849 to 1850 and 2511 to
  2512), and a slot in `approval` whose Effect the Run lists as
  unknown, settled or in reconciliation (it is set `running` and its
  `unknown` outcome is then late, about 1821 to 1823). In a
  request-cap stop the same slots, and running local work, stay open
  from their deadline on.
- ELZ-191 has the closer for a change of Attempt: `close_attempt/3`,
  `close_slot/3` and `may_have_sent?/3` (about 731 to 840). It
  settles a slot that nothing can have left as `refused` with the
  actual 0, and a slot that may have been sent as `unknown` with no
  actual and its reservation held.
- The README says that a new room period needs "terminal state and
  all obligations settle" (about 147 to 153), and that a parent of a
  terminal Run is not handed an outcome "unless the request-cap stop
  retains it" (about 184 to 187). `piece.json` says the second in
  its fifth limit. ELZ-192 adds a Limit that the end of the Run does
  not settle a waiting parent.
- One existing test asserts the open state and must change with this
  task: `a child with a known cost: the call returns and no record
  is written for the parent` (`test/elzoo/run_engine_test.exs`, group
  `no_loop_for_a_parent_that_cannot_settle`, about 4458 to 4470)
  asserts that the parent is `running` after the Run completed
  (about line 4463). The test `both charge-stop rules retain slow
  within-cap completion and denial obligations` (about 811) shows a
  retained slot before its deadline and must pass unchanged.

## The changed Contract (proposal; step 1 decides)

In a terminal Run a slot is open only while the request-cap stop
retains it and its deadline has not passed. The fold settles every
other open slot at the first step that sees it: the step of the
terminal view, and each later protocol input of the current Attempt,
at the time of that record. Nothing is decided from process state or
from a clock.

- "Retains" is the existing rule (about 577 to 579). A slot with no
  deadline yet (not admitted) is retained in a request-cap stop, and
  the drain drives it to its refusal as today. This is what a
  terminal Run keeps open on purpose: the work that was started
  within the cap, until its own deadline.
- The settlement follows the rule of ELZ-191, with the reason
  `run_closed`. A slot for which nothing can have been sent is
  `refused` with the actual 0, and its reservation is released. A
  slot for which something may have been sent, or whose cost a
  recorded action may hold, is settled with the outcome `unknown`
  and no actual, and its reservation stays held: unknown is not
  zero. Running local work keeps its rule (`failed`,
  `local_closed`). A nested parent and its child close deepest
  first; the parent gets the committed child amount when every child
  cost is known, else no actual; a finish that the child kept is
  given to no pattern and leaves the control state.
- A settled slot keeps what a later record needs to find it: a
  Resource cursor that arrives after the close still settles the
  Budget of its action.
- First settlement wins: a later outcome or expiry for such a slot
  changes nothing, and a reserved intent is never sent again, also
  after a restart.
- The engine has no timer. A retained slot past its deadline is
  settled by the next protocol input of the current Attempt. A host
  that wants to configure a new Run sends one input (a wake) after
  the last deadline.

After the close, `active_count/1` is 0 and a new Run with another run
id configures on the unit.

A Run that was recorded before this repair and is already terminal
keeps its open slots until the next protocol input reaches it; then
it folds to another state than before. Elzoo is not released, so this
is accepted; the README states it as a Limit.

No input, option, control command, public function, record kind or
durable field is added. The reason text `run_closed` is new.

## Task

1. Before the build, write to the evidence directory a table of every
   slot kind and phase that can be open at a terminal view and after
   it, with file and line: in a request-cap stop and in every other
   ending; before and after the deadline of the slot; can a request
   have left the engine; which rule settles it today, if any; which
   outcome, reason and reservation it gets under the proposal. Name
   each row where the proposal changes a refusal that the drain
   writes today (`run_terminal`, `run_or_authority`) and say whether
   the gate is still asked. Send the table to the coordinator with
   your proposal, and wait for the answer before the writer starts.
   If the table shows that the rule above is wrong for one row, say
   so; do not bend the row.
2. Implement the rule in the fold. Use the closer of ELZ-191; do not
   write a second one.
3. Change the test named above to the new truth, and name each
   changed line in the pull request body. Change no other existing
   test; if another one fails, stop and ask.
4. Update the README and `piece.json` (Contract, Limits, the lists of
   named groups), and remove the Limit of ELZ-192 that this task
   ends. Index row in the last commit before the pull request is
   opened (in-place change of a ready Piece, same Piece ID).

## Named acceptance groups

Nearest existing tests: the two named above, `room period needs a
distinct explicit Run after settlement and retains lifetime capacity`
(about 495), `after the change the Run ends and a new Run with another
id configures on the same unit` (about 5167), and the groups of the
change of Attempt (about 4638 to 5557), whose helpers `footprint/2`,
`budgets/1`, `late_results/3`, `trap_context/3` and `halt_engine/2`
serve here too.

1. **`waiting_parent_closes_with_the_run`**: a root that finishes
   while a nested parent is running: after the Run completed, the
   parent and every slot of its child are settled; no record is
   written for the parent; the parent's actual is exact when every
   child cost is known and absent when one is not.
2. **`sent_slot_becomes_unknown_at_the_end`**: a dispatched tool
   call, a slot in reconcile and a waiting person ask, in a Run that
   then ends and is not a request-cap stop: each is `unknown` with
   the reason `run_closed` and no actual; the Budget holds its
   reservation and the committed amount did not move (asserted as
   numbers); after a restart no second dispatch happens.
3. **`unsent_slot_is_released_at_the_end`**: for each phase of the
   table in which nothing was sent, a slot in that phase at the end
   is `refused` and its reservation is released.
4. **`retained_slot_stays_until_its_deadline`**: in a request-cap
   stop, before the deadline, an input leaves the retained slot
   open, and its result then settles it as today (the test at about
   811 passes unchanged).
5. **`retained_slot_closes_after_its_deadline`**: in a request-cap
   stop, the clock passes the deadline of a running local work, of a
   dispatched tool call and of a nested parent; one wake settles
   each by the rule; a late result changes nothing.
6. **`unit_configures_after_the_end`**: after groups 1 and 5 a new
   Run with another run id configures on the same unit and runs one
   action. Negative control below.
7. **`resource_cost_still_arrives`**: a Resource action open at the
   end, then its cursor: the Budget of that action is settled by the
   cursor and nothing fails.
8. **`replay_is_equal`**: for the Runs of groups 1, 2 and 5, a
   restart gives an equal view, equal Budget states of every
   callable and an equal count of journal records, and writes
   nothing more.

## Evidence and gate

Negative controls, each by a temporary edit that is reverted: without
the close, group 6 fails (the start of the new Run is refused as
`:incompatible_recovery`); release the reservation of a sent slot as
zero (group 2 fails); close a retained slot before its deadline
(group 4 fails).

Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk high (durable state
and money accounting).

## Not in scope

A timer for the deadline of a slot, a way to carry an action into a
new Run, the request-cap stop under the rule `pause` (the Run is
paused, not terminal), the journal write path, and any other Piece.
