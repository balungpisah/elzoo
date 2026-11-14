# ELZ-190 — A nested Run with a lost Effect still gives its finish to its parent

- Dependencies: ELZ-033, ELZ-187
- Output: none. This task changes the ready Piece `assembly/run-engine` in place: one sentence of its Contract on nested cost changes. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and `note` of its row).

Found by the worker of ELZ-183 (issue #408) and confirmed by reading the
engine. When the engine is restarted while an Effect of a nested child Run
is in flight, the action is recorded as `unknown` with the reason
`lost_outcome` and with no actual cost. The child then goes on and
finishes. Its parent never gets the finish: the parent slot stays
`running` and the Run stalls. The same loss in a root Run does not stop the
root from finishing. ELZ-187 comes first because it changes the same file.

Facts checked on `main` (lines of `lib/elzoo/run_engine.ex` at the time of
writing; confirm each when you start, and if one differs, stop and ask):

- A lost action is settled with `actual: nil`. `settle_budget` acts only
  for an integer actual, so the reservation of that action stays held. This
  is the Contract: "unknown is not zero" (README, the Budget paragraph).
- No later input gives such a slot an actual: a protocol input for a
  settled slot is classified `:late`; the README says that no reset, rearm
  or retry exists. A Resource action is different: `:resource_cursor` can
  still settle its cost later.
- In `drain/1` the selector `finished_child` (about lines 1431 to 1440)
  matches a closed child only when each slot of that child is settled and
  has no reservation or an integer actual. A lost slot has a reservation
  and no actual, so the child never matches. The branch below it (about
  1467 to 1491) then needs `reserved == 0` of the child Budget to give the
  parent its outcome with `actual: status.committed`.
- A parent slot can already be settled with `actual: nil` and get its
  actual later through a `:nested_actual` record: the refusal path (about
  1568 to 1578) does this while the child Budget still has a reservation.
- The README says: "Child finish does not settle the parent's share until
  outstanding child actual costs are known" and "`actual` stays the
  committed child Budget amount".
- A root `finish` does not look at reservations.

## The changed Contract

A settled slot has a **final unknown cost** when the Budget of its
callable still counts a reservation for it, it has no actual, and no later
record can give it one. "Counts a reservation" is decided by the Budget and
not by a field of the slot: one path is known in which the two differ
(`close_local`, about lines 686 to 712, settles a running local work as
failed with no Budget step and rebuilds the slot without its reservation
field, while the Budget still holds the entry). Such a slot is final
unknown too. The cases:

- a slot of a kind whose cost only its own outcome settles (an Effect, an
  ask, a local work: list the kinds from the code and say for each, with
  the line, why no later record settles it), settled with no actual;
- a `nested_callable` slot settled with no actual whose child is closed,
  has every slot settled, and has one or more slots with a final unknown
  cost.

A slot whose cost a later record can still settle (a Resource action; a
nested slot whose child still has an open or unsettled slot) is not final:
for it the engine waits as today.

When a nested child is closed, every one of its slots is settled, each
cost is known or final unknown, and one or more is final unknown, the
engine gives the parent its outcome in the same way as today (the kept
first finish, the same schema rules, the same reasons), with one
difference: the actual of the parent slot is unknown (`nil`). The share
that the parent reserved for the child stays reserved: nothing is released
and nothing is committed for it. No `:nested_actual` record follows for
that parent. When every child cost is known, nothing changes: the actual is
the committed amount of the child Budget, exactly as today.

Unknown stays not zero at every level, a reserved intent is never sent
again, and no input, option, control command or public function is added.

## Task

1. Before you design, write to the evidence directory, for each action
   kind of the engine and for each path that settles a slot (an outcome, a
   refusal, an expiry, a recovery after a restart, `close_local` at a
   cancel or a change of Attempt), whether the Budget can still count a
   reservation for the settled slot, and whether a later record can settle
   it, with file and line. If a kind or a path is unclear, stop and ask.
2. Change `finished_child` and its branch to the rule above. A closed
   child whose costs are all known or final unknown, with one or more
   final unknown, must not match again once its parent slot is settled,
   however that parent was settled: handed by this rule, or settled
   earlier as expired or refused with no actual. No `:nested_actual` can
   ever follow for it, so `drain/1` must go on to the next work in the same
   call. The finality of the child costs in the durable state tells this
   case from the existing one in which the actual still comes; add no new
   marker to the state unless you show that this is not enough, and then
   stop and ask.
3. The fold must give the same state from the same records: a restart
   after the parent was settled this way changes nothing and writes no
   second outcome.
4. Update the README sentences on child finish and `actual`, and the
   Contract and Limits texts of `piece.json`, to the rule above. Add the
   eight groups below to the list of named groups in the README and to the
   test claim of `piece.json` that lists the groups. Index row in the last
   commit before the pull request is opened.

## Named acceptance groups

Use the full restart idiom of the Piece's own tests (stop the engine, stop
the unit, host mode `:recover`, start). Keep every existing test green and
unchanged; if one must change, stop and ask.

1. **`nested_lost_effect_reaches_parent`**: a child with two actions; the
   Effect of the first is in flight at a restart and becomes `unknown` /
   `lost_outcome`; the second completes and the child finishes with a
   result in the schema of the parent binding. The parent slot settles
   `completed` with that result and with no actual; the pattern of the
   parent gets the result and the root Run finishes. Without the repair
   the parent slot is still `running` after the child has finished (the
   negative control).
2. **`unknown_is_not_zero`**: after group 1 the child Budget still holds
   the reservation of the lost action, the parent Budget still holds the
   share of the child, and neither committed amount moved. A parent whose
   Budget has no room left beside that share refuses a next action as
   `out_of_budget`, as it would with a known cost of that size.
3. **`known_costs_are_exact`**: the same child with no loss settles the
   parent with the committed amount of the child Budget, and a refused
   parent slot still gets its `:nested_actual` later; the records of both
   runs equal those that `main` writes for them (compare the journal rows
   of the run with a recorded expectation made on the unrepaired code).
4. **`no_second_outcome`**: after group 1, three more inputs and a second
   restart write no further outcome and no `:nested_actual` for that
   parent; another open slot of the Run makes progress in the same
   `drain`; the view, the Budget status of each callable and the count of
   journal records are equal before and after the second restart.
5. **`loss_two_levels_down`**: a grandchild with a lost Effect: its
   parent slot (inside the child) gets an unknown actual, and so does the
   slot of the child in the root. Each level keeps its reservation.
6. **`still_waits_for_a_cost_that_can_come`**: a child with a settled
   Resource action whose cost is not yet settled by the cursor, and a
   child with one slot still open: the parent is not settled early; when
   the cost arrives, the parent gets the exact committed amount.
7. **`local_work_closed_without_a_budget_step`**: a child whose running
   local work is closed by a cancel or a change of Attempt (the
   `close_local` path), then finishes: the parent is settled with an
   unknown actual and the next work of the Run goes on. An expired parent
   slot whose child later closes with a lost cost stays as it was settled,
   gets no second record, and does not stop the next work.
   If the engine cannot reach one of these two states (for example
   because a cancel also closes the child for good), show that with file
   and line and ask the coordinator before you drop the case.
8. **`finish_rules_hold`**: with a lost Effect in the child, a finish in
   another schema gives the parent `nested_result_invalid`, and a child
   that settles with no admitted finish gives `nested_completed`, both
   with an unknown actual.

## Evidence and gate

Negative controls, each by a temporary edit that is reverted: restore the
old selector (group 1 must fail by the stall, shown with a bounded wait);
release the share as zero when the cost is unknown (group 2 must fail).

Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk high (durable state and
money accounting).

## Not in scope

A way to reconcile a lost cost later, a release of an unknown cost, any
input, option or control command, the journal write path, the call limit
(ELZ-187), `runtime/recipe-test` (ELZ-183 uses this repair), and any other
Piece.
