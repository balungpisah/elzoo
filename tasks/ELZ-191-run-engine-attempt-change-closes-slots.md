# ELZ-191 — A change of Attempt closes every open slot of the older Attempt

- Dependencies: ELZ-033, ELZ-190
- Output: none. This task changes the ready Piece `assembly/run-engine` in place: what happens to open slots at a change of Attempt becomes a stated part of its Contract. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and `note` of its row).

Issue #433 records the defect; it was found in the review of ELZ-190 and
then read in the code. When the Attempt of a Run changes, the engine closes
only running local work. Every other open slot keeps the older Attempt and
can never be settled: an outcome with the older Attempt is late, an outcome
with the new one does not match the slot, and a refusal that the engine
itself makes for the slot carries the older Attempt and is late too. The
slot stays open for ever.

Facts checked on `main` (lines of `lib/elzoo/run_engine.ex` at the time of
writing; confirm each when you start, and if one differs, stop and ask):

- The transition of `run_view` (about 364 to 394) calls `close_local`
  (about 689 to 715) when the Attempt changes. `close_local` settles only
  `local_work` slots that are `running`, as `failed` with the reason
  `local_closed`, with no Budget step, and rebuilds the slot without its
  reservation field.
- A record whose Attempt is older than the current one is classified
  `:late` (about line 85); a record whose Attempt differs from the slot's
  is `:late` (about line 554). The engine's own refusals use the Attempt of
  the slot (about line 2056).
- An open slot of the older Attempt is counted by `active_count` (about
  2767). So: `:configure` needs `active_count == 0` (about 148), and a new
  Run on the unit is refused as `:incompatible_recovery` (about 1074 to
  1087); a wake, a resource event and other inputs call the pattern only
  when `active_count == 0` (about 506, 530, 543), so the new Attempt gets
  no new request; each stuck slot holds one of the 64 open places; a child
  of a stuck nested parent is never handed over; a kept finish of that
  child stays in the control state.
- `expire_waits` (about 935 to 957) settles a stuck `nested_callable` slot
  and an `:approval` slot as `expired`, but only after their deadline and
  only when an input of the current Attempt arrives. Model, tool and person
  slots are never settled by it.
- The README says only that a parent action of an older Attempt is not
  handed an outcome, and that local work closed at a change has a final
  unknown cost. It says nothing about the other open slots.
- Two tests of ELZ-190 assert the stuck state and must change with this
  task: the test that keeps the parent `{1, 0}` `running` after a change
  of Attempt and a restart (about line 4264 of the test file), and the test
  that keeps the nested slot `running` after a wake of the second Attempt
  (about line 4465).

## The changed Contract

At a change of Attempt, in the same fold step and at the time of the view
record, the engine settles every slot of the older Attempt that is not
settled yet, in every callable (the root and each nested child). After the
change no slot of an older Attempt is open.

- A slot for which nothing can have been sent yet is settled as `refused`
  with the reason `attempt_closed` and the actual 0, so its reservation is
  released.
- A slot for which something may have been sent, or whose cost a recorded
  action may already hold, is settled with no actual and the reason
  `attempt_closed`, and its reservation stays held: unknown is not zero.
  Its cost is final unknown by the rule of ELZ-190. Its outcome class is
  not `refused`: the join records a refusal as not dispatched, which would
  be false here. The table of step 1 proposes the class, from the existing
  outcome vocabulary.
- Running local work keeps its existing rule (`failed`, `local_closed`).
- A `nested_callable` slot is settled with the reason `attempt_closed`.
  The finish that its child kept, if any, is not given to the pattern (the
  step that asked for it belongs to the older Attempt) and leaves the
  control state. Its actual follows the rule of ELZ-190: the committed
  amount of the child Budget when every child cost is known, else unknown.
- A settled slot keeps what a later record needs to find it: a resource
  cursor that arrives after the change still settles the Budget of its
  action and does not fail.
- First settlement wins: a late outcome for such a slot changes nothing,
  and a reserved intent is never sent again, also after a restart.

Which phase and which action kind falls under "nothing sent" and which
under "may have been sent" is decided from the code, phase by phase (step 1
below). The class follows from the kind and the phase together, not from
the phase alone. At least these are "may have been sent": a
`nested_callable` slot whose child was dispatched, also when the slot is
being refused (the refusal over the cap, about line 783); a slot waiting
for an approval that holds a request key, because the Run may have
dispatched it already (about 2421 to 2440); a `resource_open` or
`resource_use` slot that is ready, because a resource command may already
be recorded (about 1881 to 1884). When in doubt a slot is "may have been
sent".

A Run that was recorded before this repair, with a change of Attempt and
open slots, folds to another state after it. Elzoo is not released, so
this is accepted; the README states it as a Limit.

No input, option, control command, public function, record kind or durable
field is added.

## Task

1. Before the build, write to the evidence directory a table of every slot
   phase and action kind that can be open at a change of Attempt, with file
   and line: can a request have left the engine in that phase; which
   outcome and reason it gets under the rule above; what happens to its
   reservation. Send the table to the coordinator with your proposal for
   the kinds that are not plain (resource actions in each phase, approvals
   with and without a request key, slots in reconcile), and wait for the
   answer before the writer starts.
2. Implement the rule in the fold. The step that changes the Attempt
   settles the slots; nothing is decided from process state or a clock.
3. Change the two tests of ELZ-190 named above to the new truth, and name
   each changed line in the pull request body. Change no other existing
   test; if another one fails, stop and ask.
4. Update the README and `piece.json` (Contract, Limits, the lists of named
   groups) to the rule above. Index row in the last commit before the pull
   request is opened.

## Named acceptance groups

1. **`sent_slot_becomes_unknown`**: a tool action that was dispatched,
   then a change of Attempt: the slot is settled with no actual and the
   reason `attempt_closed`; the Budget still holds its reservation and the
   committed amount did not move (asserted as numbers); after a restart no
   second dispatch happens; a late result with an actual changes nothing. The same holds
   for a slot in reconcile and for a waiting slot of a kind that may have
   been sent.
2. **`unsent_slot_is_released`**: for each phase of the table in which
   nothing was sent, a slot in that phase at the change is `refused` with
   `attempt_closed`, and its reservation is released.
3. **`nested_parent_and_child_close`**: a nested parent with a running
   child at the change: every slot of the child and the parent slot are
   settled; a finish that the child had kept is not given to any pattern
   and is gone from the control state; the parent's actual is exact when
   every child cost is known and unknown when one is not.
4. **`new_attempt_works`**: after the change, a wake in the new Attempt
   makes the pattern ask a new request, and that request runs to its
   outcome; the 64 open places are all free again. A second change of
   Attempt directly after the first closes what the second Attempt opened
   and leaves the earlier settlements as they were.
5. **`run_ends_and_unit_configures`**: after the change the Run reaches a
   terminal state, and a new Run with another run id configures on the
   same unit. Negative control: with the old `close_local` the configure is
   refused as `:incompatible_recovery`.
6. **`resource_cost_still_arrives`**: a resource action open at the
   change, then its cursor: the Budget of that action is settled by the
   cursor and nothing fails. The same with the
   resource action inside a nested child: the cursor settles the child
   Budget, and the actual of the parent follows by the rule of ELZ-190.
7. **`replay_is_equal`**: for the runs of groups 1, 3 and 6, a restart
   after the change gives an equal view, equal Budget states of every
   callable and an equal count of journal records, and writes nothing
   more.
8. **`first_settlement_wins`**: after the change, an outcome with the old
   Attempt, an outcome with the new Attempt, and an expiry for a closed
   slot each leave the slot as it was settled.

## Evidence and gate

Negative controls, each by a temporary edit that is reverted: the old
`close_local` (group 5 must fail as stated); release the reservation of a
sent slot as zero (group 1 must fail).

Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk high (durable state and
money accounting).

## Not in scope

The size of kept finishes in the control state (ELZ-192, which follows
this task), a way to carry an action over a change of Attempt, the journal
write path, and any other Piece.
