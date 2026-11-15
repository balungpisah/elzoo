# ELZ-232 — Each callable has a state bound that control reserves while the callable is open, and a nested start is kept only when there is room for it

- Dependencies: ELZ-033, ELZ-192, ELZ-216
- Output: none. A change in place of the ready Piece `assembly/run-engine`, before the first release, with the same Piece ID. The Contract changes in three points: a nested binding may give the new facts key `state_bytes`; a nested start without room is refused; the state of a closed callable leaves the control state. The README and the `limits` of `piece.json` state them.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` of its row, because `piece.json` changes).

Issues #501 and #502 record one defect on two paths. The durable
control state has a bound of 2,097,152 bytes. The state of a pattern is
kept in it, and nothing reserves room for that state. Issue #501: the
start of a nested child places the child, its first state and its
Budget into control with no check. Issue #502: the state of a callable
is stored again after every input, and it can grow up to 65,536 bytes at
any time; a callable is never removed during a Run. In both cases the
control state can pass its bound inside the stated Limits. The step
then fails, the durable unit stops, and a replay fails on the same
input again: the Run halts and no restart helps. It is the same class
of defect as issue #383 (ELZ-192).

A check at the start alone cannot repair #502: a child can start small
and grow later, and then there is no admission to refuse. So the repair
is a reserve. Each callable has a state bound. While the callable is
open, control reserves the whole bound. Then a later state never needs
new room. The only refusal is at the nested start, with the existing
reason `record_size`. When a callable closes, its state leaves control
and the room comes back.

This task runs after ELZ-216 and before ELZ-217, because every engine
task edits the same file and ELZ-217 rewrites `fits?/1`. ELZ-217
depends on this task and copies the `fits?/1` of this task as its
oracle.

Facts checked on `origin/main` at `3557e16`: they were read, not run.
Lines are of `lib/elzoo/run_engine.ex` at that commit; ELZ-210 to
ELZ-216 move them. ELZ-215 adds a closer for a terminal Run: it is one
more place where a callable closes, so the state must be dropped there
too. Confirm each fact when you start, and if one differs, stop and ask.

- The bound is `fits?/1` (about 2933 to 2944): the bytes of the control
  state plus a reserve (1,024 bytes for each receipt that can still
  come, 4,096 bytes for each active slot, and the bytes of each finish
  that is admitted and not yet kept) must be at most 2,097,152. No term
  counts a pattern state. It is asserted after every step (about lines
  37 and 76); a failure raises.
- The durable unit appends the input first and evaluates then
  (`pieces/runtime/durable-unit/lib/elzoo/durable_unit.ex`, about 145 to
  147). A raise in the step is caught (about 191 to 193) and stops the
  unit with `durable_unit_transition_failed` (about 168 to 173). The
  input stays pending. A new start of the unit evaluates the pending
  input again before it returns (about line 70) and stops the same way.
- A callable is added at two places only: the root at configuration
  (about 1182 to 1190) and a child in the `:nested` fold (about 330 to
  339). No code removes a callable or its state during a Run.
- The fold of a `:nested` record (about 323 to 371) puts the child into
  `control.callables` with `state: facts.initial_state` (about 330 to
  339) and its Budget into `control.budgets` (about 341 to 346). It
  copies `slot.decision.permitted` into the child as its authority
  (about 335). It sets the parent slot to `:running` (about 348) and
  gives the child its `start` input through `invoke/3` (about 360 to
  367). It calls `fits?/1` nowhere.
- `dispatch/3` for a nested callable (about 1932 to 1959) reads the
  facts from `nested.(action)` of the binding (about 1934). It checks
  that the initial state is at most 65,536 bytes and that the payload
  matches its schema (about 1936 to 1944). If not, the action is refused
  with the reason `nested_input` (about 1957).
- `invoke/3` (about 851 to 932) adds one entry to
  `control.invocations` (about 859) and stores the state that the
  pattern returns at three places (about 864, 886 and 928). The only
  check is the state itself: at most 65,536 bytes and plain (about 863,
  885 and 924). A state that fails the check is not stored, and the
  classification is `invalid_pattern_state` (about 865 and 925).
- The state of a callable is read at one line only: about 856, in
  `invoke/3`. `invoke/3` has three callers: about 99 (only when the
  callable is not closed, about 98), about 141 (only when it is not
  closed, about 138) and about 360 (a child that the same fold just
  created). So the state of a closed callable is never read again.
- `closed` is set to true at two places: the continuation of a child
  finish (about 285) and a change of Attempt, for every callable but
  the root (about 742 to 747). No code sets it back to false.
- `step/2` reads `closed` of the callable of every slot, settled slots
  too (about 50). So the node of a closed callable must stay.
- When the child gives a request, `admit_request/5` (about 934 to 989)
  calls `fits?/1` on its candidate (about 980). When that is false it
  returns the state without the request (about 984), but that state
  holds the new pattern state already.
- The work of `step/2` after the fold (about 45 to 75) only removes:
  pending inputs, kept finishes and requests.
- ELZ-192 (about 242 to 248, 2914 to 2919 and 2923 to 2931) refuses a
  child finish without room in the `:admission` fold with
  `keeps_first_finish?/2`, `fits?(admitted)` and
  `deny(before_budget, key, "record_size")`.
- `release_and_deny/4` (about 1127 to 1128) releases the reservation of
  a slot with `settle_budget/4` (actual 0, about 1047 to 1065) and sets
  the slot to `:refusing` with a reason. The `:authorization` fold uses
  it for the reason `authority` (about line 269).
- A slot in `:refusing` gets its outcome from `progress/3` (about 1771
  to 1787). For a nested callable with no child Budget in the control
  state the actual is 0. The outcome is `refused`, with the reason in
  the payload and dispatch `not_dispatched`. `settle_protocol/3` settles
  it (about 600 to 602 and 628 to 666) and releases the reservation once
  more. A release of an entry that is released is a replay in
  `workflow/budget` (`cure/elzoo/budget.cure`, about 285 to 291), as on
  the `authority` path.
- `may_have_sent?/3` (about 842 to 844) counts a refusing nested slot
  as sent only when its child is in `control.callables`.
- The existing tests read `closed` and `[:finish]` of a callable node.
  No line of `test/elzoo/run_engine_test.exs` reads the pattern state of
  a callable.
- `control_headroom/1` of the test support file
  (`test/support/run_engine_test_helper.exs`, about 826) copies the
  formula of `fits?/1`. The group `finish_without_room_is_refused`
  asserts with it (test file, about 5889, 5895 and 5908).
- The base nested binding of the test support file gives the facts of a
  child (about 536 to 546). `nested_setup/2` changes them with the map
  update syntax (about 638 to 662), so a key of the base stays.

## The repair

**The state bound.** Each callable has a state bound, in bytes.

- For the root it is 65,536.
- For a nested child it is the value of the key `state_bytes` in the
  map that `nested.(action)` of its nested binding returns: an integer
  from 1 to 65,536. When the map has no such key, the bound is 65,536.
  This key is new. It is declared there and nowhere else: no option of
  `start_link/1`, no field of the action, no field of the payload.
- It is validated in `dispatch/3` for a nested callable, in the
  existing condition (about 1936): the bound must be an integer from 1
  to 65,536, and the initial state must be at most the bound (today: at
  most 65,536). If not, the action is refused with the existing reason
  `nested_input`, as today for an initial state that is too large. No
  `:nested` record is written for it.
- It is stored in the callable node, under the key `state_bytes`: for a
  child in the `:nested` fold (about 330 to 337), read from the facts of
  the record with the same default; for the root at configuration (about
  1182 to 1190), with 65,536. A node with no such key counts as 65,536.

**The stored state.** `invoke/3` stores a new state only when it is
within the bound of its callable, at the three places (about 863, 885
and 924). Today the limit there is 65,536 for every callable. A larger
state is not stored, and each place keeps the answer that it gives
today: `invalid_pattern_state` at about 865 and 925, and the answer of
the over-cap path at about 885.

**The reserve.** `fits?/1` adds one term to its reserve: for each
callable that is not closed, the bound of the callable minus the bytes
of its stored state (the same `bytes/1` as in the check of `invoke/3`),
and never less than 0. So the sum of control and reserve counts every
open state as its whole bound. A new state within the bound changes
the control bytes and the reserve by the same amount in opposite
directions. After the start, no input can pass the bound through a
pattern state, in any order of inputs.

**The close.** At every place where a callable is set to closed, the
key `state` is removed from its node in the same fold step: the
continuation of a child finish (about 285), the change of Attempt
(about 742 to 747), and the closer of ELZ-215 if it sets `closed`. The
node stays, with its `closed` flag, parent, authority, depth, bound and
kept finish. The Budget, the tracker, the join, the receipts and the
invocations stay. A closed callable has no reserve.

**The refusal at the start.** The `:nested` fold computes its result as
today: the child and its Budget placed, the parent slot `:running`, the
`start` input given to the child. Then it asks `fits?/1` of the state
of that result.

- When it fits, the fold returns that result.
- When it does not fit, the fold drops that result. It returns the state
  that it received, changed by `release_and_deny(state, key, at,
  "record_size")` only, and no output.

So after a refusal: the reservation of the parent action is released;
no callable and no Budget of the child is in the control state; no
invocation, receipt or request of the child is recorded; the request
count is as before. The parent slot is `:refusing` with the reason
`record_size`. The existing steps then settle it: the pattern that
asked for the nested callable gets the ordinary outcome `refused` with
the reason `record_size`, actual 0 and dispatch `not_dispatched`. The
engine goes on.

The check is on the result of the fold, and not on the state before
`invoke/3`, because the start adds more than the state bound: the node
with its authority, the Budget and one invocation entry. One check of
the result covers all of them. The work of `step/2` after the fold only
removes, so a result that fits here also passes the assertion of
`step/2`. The check can be stricter than that assertion by the bytes
that the same step removes later; that is the safe side.

The decision is a pure function of the stored state and the record.
The bound comes from the facts of the `:nested` record and from the
stored node; the reserve comes from the stored state. A replay gives
the same state. A journal that was recorded before this repair can fold
to another state: a stored state over a declared bound cannot occur in
it (there was no declared bound), but the reserve is larger, so a
`:nested` record or a request that fitted can now be refused, and the
state of a closed callable is gone. One more case differs: a `:nested`
record whose result did not fit and whose step still passed, because
the same step removed enough afterwards, now folds to the refusal.
Where the step failed, the input is still pending, and it now folds to
the refusal or to a state that fits. Elzoo is not released, so no
stored journal has to be kept equal; name these cases under `Limits:`.

The evaluation of the child pattern for a refused start leaves no
trace: no charge, no receipt. The child was not started. The README
says so.

Nothing else changes. Add no record kind, input, option, public
function or helper layer. The only new durable field is `state_bytes`
of a callable node; the only removed one is `state` of a closed node.
Use the existing reasons; add no new reason.

## Task

1. **Measure first. Make no edit of the Piece before the coordinator
   answers.** Nothing in this task text was run. On your base:
   - Confirm the facts above.
   - Run the tests of the Piece once and record the result.
   - List every existing test that starts a nested child. For each one,
     give the largest count of children that are open at the same time,
     and say whether its control state comes near the bound (a headroom
     under 131,072 bytes at any input counts as near).
   - Record the largest pattern state, in bytes, of the root and of a
     child in the existing tests.
   - By a temporary edit that you revert and never commit, add the
     reserve term to `fits?/1` with 65,536 for every callable that is
     not closed, and change nothing else. Run the tests of the Piece.
     List each test that fails, with its failing line and the reason in
     one sentence. Revert the edit and show that the tree is clean.
   - Send both lists to the coordinator, with your proposal of which
     tests declare `state_bytes` for their test children and with which
     value. Wait for the answer before you build.
2. The rule for existing tests. The body of an existing test may change
   only to declare `state_bytes` for its test children, through the
   test support file where that is possible, and only for the tests on
   the list that the coordinator accepted. Every assertion stays as it
   is. No other existing test changes. If another test fails, stop and
   ask. One function of the test support file changes with the formula
   and is no test body: `control_headroom/1` gets the new reserve term,
   so that it still recomputes the bound of the engine. Name that
   change in the pull request body.
3. By reading, before the edit of the fold: show that the state which
   the `:nested` fold received, with only the parent slot changed to
   `:refusing` and its Budget entry released, satisfies the control
   bound of `fits?/1` when the state before the step did. Write the
   reasoning in the pull request body with the lines. If it does not
   hold, stop and ask. `deny/3` adds the reason to the slot, as on every
   existing refusal path; a slot at the exact byte of its own bound is
   the same case as on those paths and is not repaired here: name it
   under `Limits:`.
4. Make the repair above: the bound in `dispatch/3`, in the two nodes
   and in the three checks of `invoke/3`; the term in `fits?/1`; the
   removal of the state at each place that closes a callable; the check
   in the `:nested` fold. List every place that sets `closed` at your
   head in the pull request body, with its line. No other clause of
   `transition/2` and no line of `admit_request/5` changes.
5. README, beside the text on nested bindings (about 83 to 86), add:

   > A nested binding may give `state_bytes`, the state bound of the
   > child: an integer from 1 to 65,536. With no `state_bytes` the bound
   > is 65,536. The bound of the root is 65,536. A nested action whose
   > `state_bytes` is outside 1 to 65,536, or whose initial state is
   > larger than its bound, is refused with `nested_input`.

   README, beside the text on the room of a child finish (about 201 to
   208), add:

   > Each callable has a state bound. A pattern state over the bound of
   > its callable is not stored (`invalid_pattern_state`). While a
   > callable is open, control reserves its whole state bound, so an open
   > callable can store any state within its bound at any later input: no
   > input fails for the size of a pattern state. A nested start is kept
   > only when the state after it satisfies the bound, with the state
   > bound of the child, its Budget and its authority counted. With no
   > room, the parent action is refused with `record_size`, actual 0,
   > nothing dispatched; no child and no Budget exist; the evaluation of
   > the child is dropped and charges nothing; the reservation of the
   > parent is released; the engine goes on. The state of a callable
   > leaves control when the callable closes: when its finish is kept,
   > at a change of Attempt, and when a terminal Run closes it. Its room
   > comes back then. The Budget, the join and the receipts of a closed
   > child stay.

   Leave out "and when a terminal Run closes it" if no closer of a
   terminal Run closes a callable at your base.

   README, in "Failure, size and audit limits" (about 289 to 293),
   replace `callable state <=65536 bytes` by:

   > callable state within its state bound (<=65536 bytes), reserved in
   > control while the callable is open

   README, at the end of "Grounding and limits", add:

   > Limits of the state bound. With every child at the bound of 65,536,
   > N children can be open at once in the listed scenario; a binding
   > that gives a smaller `state_bytes` allows more, up to the 64 active
   > actions. A child whose parent action settled while the child was
   > open stays open and keeps its reserve until the Attempt changes. A
   > child holds its reserve until its finish is kept, so a finish needs
   > its own room beside the reserve of its child. A Run recorded before
   > this repair can fold to another state (Elzoo is not released).

   Put the measured number for N. Add the new groups to the list of
   named groups there, each with what it shows, in the way of the groups
   of ELZ-192. If the count in the text of
   `finish_without_room_is_refused` (about 355 to 357) moves, correct it
   to the number that the test prints.
6. `piece.json`, in the entry of `limits` on sizes, replace
   `control <=2097152 with future settlement/receipt reservations` by:

   > control <=2097152 with future settlement/receipt reservations and
   > the whole state bound of each open callable (the root 65536; a
   > nested child the `state_bytes` of its nested binding, 1 to 65536,
   > else 65536)

   In the entry of `limits` on the nested finish, add at the end:

   > A nested start is kept only when control has room for the state
   > bound of the child, its Budget and its authority; with no room the
   > parent action is refused `record_size` with actual 0 and nothing
   > dispatched, and no child exists. A pattern state over the bound of
   > its callable is not stored. The state of a callable leaves control
   > when the callable closes, and its room comes back; a child whose
   > parent settled while it was open keeps its reserve until the
   > Attempt changes.

   Add one entry to `limits`:

   > A Run recorded before the repair of the state bound can fold to
   > another state: a larger reserve can refuse a nested start or a
   > request that fitted, and the state of a closed callable is gone
   > (Elzoo is not released).

   The `contract` string stays, so the `note` of the index row stays;
   `manifest_sha256` follows the new bytes. Extend the test claim in
   `grounding` only as far as the new groups need.
7. Name the two paths of "Not in scope" in the pull request body under
   `Limits:`, with the lines at your head.

## Named acceptance groups

The cases go into the existing group `Durable budget and nested share`
of `test/elzoo/run_engine_test.exs`, so the named groups of
`piece.json` stay. The nearest existing tests are the four groups of
ELZ-192 (`finish_without_room_is_refused` and the three after it). Use
their helpers: `nested_setup/2`, `unit_state/1`, `control_headroom/1`,
`footprint/2` and the pattern `TestPattern.waiting/2`. You may add
clauses to the test pattern in the test support file of the Piece, and
nothing else there but the change of `control_headroom/1`: one clause
that returns a state of a given size on a later input, and one that
returns it on `start` if a group needs it.

1. **`nested_start_without_room_is_refused`**: one Run asks for more
   nested callables than fit, each with `state_bytes` 65,536 and a
   child that waits. The parents stay open. The start that would pass
   the bound is refused: its parent action is settled `refused` with
   the reason `record_size`; the pattern that asked gets that outcome;
   `control.callables` and `control.budgets` hold no entry for it; the
   Budget of the parent callable shows the reservation released (record
   the numbers before and after). Every earlier child is in control
   with its exact state. The engine answers the next input, and the
   bound holds after every input (`control_headroom/1`). Record how
   many starts fit: it is the N of the README.
2. **`declared_bound_decides`**: with the control state near the bound,
   a child with `state_bytes` 65,536 and a small initial state is
   refused as in group 1, and a child with `state_bytes` 1,024 is kept
   and runs. A child with no `state_bytes` is refused at the same place
   as the one with 65,536.
3. **`state_grows_after_start`** (the case of issue #502): children
   start with a small state and wait; then each one gets an input and
   returns a state of exactly its bound. Run it in two different orders
   of those inputs. The bound holds after every input; no step fails;
   the unit is alive and answers the next input; each stored state is
   exact.
4. **`root_state_can_grow`**: with the control state near the bound,
   the root pattern returns a state of exactly 65,536 bytes; it is
   stored and the step passes.
5. **`state_over_its_bound_is_not_stored`**: a child with `state_bytes`
   1,024 returns a state of 1,025 bytes: the classification is
   `invalid_pattern_state` and the stored state is the old one. A state
   of exactly 1,024 bytes is stored.
6. **`bound_is_validated`**: a nested action whose binding gives
   `state_bytes` 0, 65,537 or a value that is no integer, and one whose
   initial state is one byte over its bound, are each refused with
   `nested_input`; no child and no Budget exist; no `:nested` record is
   in the journal. An initial state of exactly the bound is kept.
7. **`room_comes_back_at_close`**: after the refusal of group 1, one
   child finishes. Its node is closed and has no `state` key in the
   unit state. A nested start of the size that was refused is then
   kept. After a change of Attempt, no node but the root has a `state`
   key.
8. **`refusal_leaves_no_trace_of_the_child`**: for the refused start of
   group 1, the request count, the receipts and the invocations of the
   unit state are equal before and after the `:nested` record. The test
   pattern may see the dropped `start` (the evaluation is pure and its
   result is dropped); no later input reaches that child.
9. **`replay_is_equal`**: after groups 1, 3 and 7, a restart of the
   engine, and the unit alone started again on its journal, each give
   an equal state and an equal count of journal records, as in the
   group `replay_is_equal (finish without room)`. The refused start is
   not asked again.
10. **`existing_behaviour`**: every existing test of the Piece passes.
    Its body is unchanged, or changed only by the rule of step 2 of the
    task. List each changed test and each changed line in the pull
    request body.

Negative controls, each by a temporary edit that is reverted and never
committed. Record the failing output in the pull request body.

- Without the new term in `fits?/1`: group 3 fails. The step fails, the
  unit stops with `durable_unit_transition_failed`, and a new start of
  the unit stops in the same way.
- Without the check in the `:nested` fold: group 1 fails in the same
  way.
- Without the removal of the state at the close: group 7 fails (the
  later start is refused).
- With 65,536 in the checks of `invoke/3` in place of the bound of the
  callable: group 5 fails.

## Evidence and gate

Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check "$(git merge-base origin/main HEAD)"`. On the final
head, run the new tests once more in one launch with
`--repeat-until-failure 10`, and record the command and its exit code.
The index row follows in the last commit (AGENTS.md section 3). Record
in the pull request body the time that the new tests add, the lists of
step 1 with the answer of the coordinator, and the number N.

Write under `Assumptions:` what no test of this task shows: a unit that
the defect stopped before the repair folds its pending input to the
refusal or to a state that fits. That follows from the pure decision;
no test holds a journal of the old engine. Write there also that the
4,096 bytes of an active slot are taken to cover the growth at its
settlement; this task does not measure it.

The pull request closes this task, issue #501 and issue #502.

One independent review, risk high (durable state).

## Review risk

High: the fold of the durable control state, the size check of every
step, a durable field that is added and one that is removed, and a
refusal that drops an evaluated result. One independent review by a
strong reasoning model. The reviewer checks:

- that the reserve term and the checks of `invoke/3` use the same bound
  and the same `bytes/1`, so that a stored state never changes the sum
  of control and reserve;
- that every place that sets `closed` removes the state in the same
  fold step, and that no code reads the state of a closed callable;
- that the node of a closed callable, its Budget, tracker, join and
  receipts are equal to the base;
- that the refused state holds nothing of the dropped result (no
  callable, Budget, invocation, receipt, count, tracker, slot or
  request of the child), and that the fold gives no output for it;
- that the check uses the state of the result of the fold, so that it
  agrees with the assertion of `step/2`;
- that the state returned on refusal satisfies the bound (step 3 of
  the task);
- that the parent action settles once, with `refused`, `record_size`
  and actual 0, and that a change of Attempt while the slot is
  `:refusing` treats it as not sent;
- that the bound is read from the record and the stored node only, and
  that a node or a record with no `state_bytes` counts as 65,536;
- that each changed existing test changed only by the rule of step 2,
  with every assertion equal to the base;
- that the README and `piece.json` hold the sentences of this task and
  claim no more than the listed cases show.

## Not in scope

**The invocation entries of inputs that settle no slot.** `invoke/3`
adds one entry to `control.invocations` for each input that reaches a
pattern (about 859), and no code removes one during a Run. An input
that settles a slot is taken to be covered by the 4,096 bytes of that
slot. A `wake` that reaches the root while no slot is active, a granted
Resource event and the other input kinds have no reserve, and their
number has no limit. Enough of them pass the bound, and the step then
fails in the same way as in issue #502. It has its own issue, #508,
and gets its own task; name it in the pull request body under `Limits:`.

**A child whose parent action settled while the child was open.** A
parent can settle by its deadline while its child is open, and no code
closes that child. It stays open, its pattern still gets inputs, and it
keeps its reserve until the Attempt changes. Whether a child closes
when its parent action settles is a change of behaviour with its own
issue, #509, and its own task; name it under `Limits:`.

Also not here: a kept finish that takes the place of the reserve of its
child (a finish needs its own room, as ELZ-192 defines it); the growth
of the joins (they keep a digest and no payload, and the lifetime limit
bounds them); a child pattern function that raises on its `start`; a
callable that fails when it returns a state over its bound (the answer
stays `invalid_pattern_state`); a bound of the root that the host
declares; the control bound itself; the cost of `fits?/1` (ELZ-217);
the journal write path; and any other Piece.
