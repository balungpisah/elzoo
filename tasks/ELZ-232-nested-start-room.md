# ELZ-232 — A nested start is kept only when the control state has room for the child

- Dependencies: ELZ-033, ELZ-192, ELZ-216
- Output: none. A repair of the ready Piece `assembly/run-engine` that restores its Contract on the bound of the control state. The README and the `limits` of `piece.json` get the new refusal. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` of its row, because `piece.json` changes).

Issue #501 records the defect. The start of a nested child places the
initial state of the child and a new Budget into the durable control
state. Nothing asks whether the control state has room for them. With
enough children started, the control state passes its bound. The step
then fails, the durable unit stops, and a replay fails on the same input
again: the Run halts and no restart helps. It is the same class of
defect as issue #383 (ELZ-192), on another path. The repair is the same
kind: a refusal with the existing reason `record_size`.

This task runs after ELZ-216 and before ELZ-217, because every engine
task edits the same file and ELZ-217 rewrites `fits?/1`. ELZ-217 will
depend on this task.

Facts checked on `main` as it will be when ELZ-192 is merged: they were
read at the head of pull request #472 (ELZ-192), not run. Lines are of
`lib/elzoo/run_engine.ex` at that head; ELZ-210 to ELZ-216 move them.
Confirm each when you start, and if one differs, stop and ask.

- The bound is `fits?/1` (about 2933 to 2944): the bytes of the control
  state plus a reserve (1,024 bytes for each receipt that can still
  come, 4,096 bytes for each active slot, and the bytes of each finish
  that is admitted and not yet kept) must be at most 2,097,152. It is
  asserted after every step (about lines 37 and 76); a failure raises.
- The fold of a `:nested` record (about 323 to 371) puts the child into
  `control.callables` with `state: facts.initial_state` (about 330 to
  339) and its Budget into `control.budgets` (about 341 to 346). It sets
  the parent slot to `:running` (about 348) and gives the child its
  `start` input through `invoke/3` (about 360 to 367). It calls `fits?/1`
  nowhere.
- `dispatch/3` for a nested callable (about 1932 to 1959) checks only
  that the initial state is at most 65,536 bytes (about 1936). A larger
  one is refused there with the reason `nested_input`.
- `invoke/3` (about 851 to 932) adds more to the control state in the
  same step: one entry in `control.invocations` (about 859), the first
  state that the child pattern returns, at most 65,536 bytes, with no
  relation to the size of the initial state (about 864, 886 and 928),
  and one receipt when the child gives an output (about 879).
- When the child gives a request, `admit_request/5` (about 934 to 989)
  calls `fits?/1` on its candidate (about 980). When that is false it
  returns the state without the request (about 984), but that state
  holds the child, its Budget and its new state already.
- The work of `step/2` after the fold (about 45 to 75) only removes:
  pending inputs, kept finishes and requests.
- The durable unit appends the input first and evaluates then
  (`pieces/runtime/durable-unit/lib/elzoo/durable_unit.ex`, about 145 to
  147). A raise in the step is caught (about 191 to 193) and stops the
  unit with `durable_unit_transition_failed` (about 166 to 173). The
  input stays pending. A new start of the unit evaluates the pending
  input again before it returns (about 70 to 77) and stops the same way.
  The README says that a transition defect or oversize needs repair
  (about line 280).
- The defect is inside the stated Limits. An initial state may have
  65,536 bytes, and 2,097,152 / 65,536 = 32. A Run may have 64 active
  and 256 lifetime actions (about 938 to 939). So fewer than 33 nested
  starts with a large initial state pass the bound.
- A callable is added at two places only: the root at configuration
  (about 1182) and a child in the `:nested` fold (about 339). No code
  removes a callable or its state from the control state during a Run.
  Only a kept finish leaves (about 57 to 66), and a new Run on the unit
  replaces the whole control state (about 147 to 151).
- ELZ-192 (about 242 to 248, 2914 to 2919 and 2923 to 2931) refuses a
  child finish without room in the `:admission` fold with
  `keeps_first_finish?/2`, `fits?(admitted)` and
  `deny(before_budget, key, "record_size")`.
- `release_and_deny/4` (about 1127 to 1128) releases the reservation of
  a slot with `settle_budget/4` (actual 0, about 1047 to 1065) and sets
  the slot to `:refusing` with a reason. The `:authorization` fold uses
  it for the reason `authority` (about line 269).
- A slot in `:refusing` gets its outcome from `progress/3` (about 1771
  to 1786). For a nested callable with no child Budget in the control
  state the actual is 0. The outcome is `refused`, with the reason in
  the payload and dispatch `not_dispatched`. `settle_protocol/3` settles
  it (about 600 to 602 and 628 to 666) and releases the reservation once
  more. A release of an entry that is released is a replay in
  `workflow/budget` (`cure/elzoo/budget.cure`, about 285 to 291), as on
  the `authority` path.
- `may_have_sent?/3` (about 842 to 844) counts a refusing nested slot
  as sent only when its child is in `control.callables`.

## The repair

The `:nested` fold computes its result as today: the child and its
Budget placed, the parent slot `:running`, the `start` input given to
the child. Then it asks `fits?/1` of the state of that result.

- When it fits, the fold returns that result. Nothing changes.
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
`invoke/3`, for two reasons that the facts above give. The start adds
an invocation entry that no reserve covers. And the first state of the
child can be much larger than its initial state. One check of the
result covers both, and it is the same value that `step/2` asserts,
because the work after the fold only removes.

The decision is a pure function of the stored state and the record. A
replay gives the same state. A journal that was recorded before this
repair folds as before where the step passed. Where the step failed,
the input is still pending, and it now folds to the refusal.

The evaluation of the child pattern for a refused start leaves no
trace: no charge, no receipt. The child was not started. The README
says so.

Nothing else changes. Do not change `fits?/1` or its reserve (ELZ-217
copies it as an oracle). Add no record kind, durable field, input,
option, public function or helper layer. Use the existing reason; add
no new reason.

## Task

1. Confirm the facts above at your base. Then, by reading, before the
   edit: show that the state which the fold received, with only the
   parent slot changed to `:refusing` and its Budget entry released,
   satisfies the control bound of `fits?/1` when the state before the
   step did. Write the reasoning in the pull request body with the
   lines. If it does not hold, stop and ask. `deny/3` adds the reason
   to the slot, as on every existing refusal path; a slot at the exact
   byte of its own bound is the same case as on those paths and is not
   repaired here: name it under `Limits:`.
2. Make the repair above in the `:nested` fold. No other clause of
   `transition/2` and no line of `invoke/3` or `admit_request/5`
   changes.
3. README: beside the text on nested bindings (about 83 to 86) or the
   text on the room of a child finish (about 201 to 208), state the
   rule. A nested start is kept only when the state after it satisfies
   the bound, with the child's first state and its Budget in control.
   With no room, the parent action is refused with `record_size`,
   actual 0, nothing dispatched; no child and no Budget exist; the
   evaluation of the child is dropped and charges nothing; the
   reservation of the parent is released; the engine goes on. State as
   a Limit that a callable and its state stay in control until the end
   of the Run, so the room does not come back when a child closes.
4. `piece.json`: the same rule in one or two sentences in the entry of
   `limits` on nested callables. The `contract` string stays, so the
   `note` of the index row stays; `manifest_sha256` follows the new
   bytes. Extend the test claim in `grounding` only as far as the new
   cases need.
5. Change no existing test. If one fails, stop and ask.
6. Name the sibling path of "Not in scope" in the pull request body
   under `Limits:`, with the lines at your head.

## Named acceptance groups

The cases go into the existing group `Durable budget and nested share`
of `test/elzoo/run_engine_test.exs`, so the named groups of
`piece.json` stay. The nearest existing tests are the four groups of
ELZ-192 (`finish_without_room_is_refused` and the three after it). Use
their helpers: `nested_setup/2`, `unit_state/1`, `control_headroom/1`,
`footprint/2` and the pattern `TestPattern.waiting/2`.

1. **`nested_start_without_room_is_refused`**: one Run asks for more
   nested callables than fit (for example 34), each with an initial
   state near 65,536 bytes and a child that waits. The parents stay
   open. The start that would pass the bound is refused: its parent
   action is settled `refused` with the reason `record_size`; the
   pattern that asked gets that outcome; `control.callables` and
   `control.budgets` hold no entry for it; the Budget of the parent
   callable shows the reservation released (record the numbers before
   and after). Every earlier child is in control with its exact initial
   state. The engine answers the next input, and the bound holds after
   every input (`control_headroom/1`). Record how many starts fit.
2. **`first_state_counts`**: with the control state near the bound, a
   child with a small initial state whose `start` returns a state near
   65,536 bytes is refused in the same way, with the same view as in
   group 1.
3. **`smaller_start_fits`**: after the refusal of group 1, a nested
   start with a small initial state and a small first state is kept
   and its child runs. So the refusal is a lack of room and no refusal
   in advance.
4. **`refusal_leaves_no_trace_of_the_child`**: for the refused start of
   group 1, the request count, the receipts and the invocations of the
   unit state are equal before and after the `:nested` record. The
   test pattern may see the dropped `start` (the evaluation is pure
   and its result is dropped); no later input reaches that child.
5. **`replay_is_equal`**: after group 1, a restart of the engine, and
   the unit alone started again on its journal, each give an equal
   state and an equal count of journal records, as in the group
   `replay_is_equal (finish without room)`. The refused start is not
   asked again.
6. **`existing_behaviour`**: every existing test of the Piece passes
   with an empty diff of its body.

Negative control, by a temporary edit that is reverted and never
committed: without the check, the step of group 1 fails, the unit stops
with `durable_unit_transition_failed`, and a new start of the unit
stops in the same way. Record the failing output in the pull request
body. Make it once more for group 2.

## Evidence and gate

Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check "$(git merge-base origin/main HEAD)"`. The index row
follows in the last commit (AGENTS.md section 3). Record in the pull
request body the time that the new tests add. The pull request closes
this task and issue #501.

Write under `Assumptions:` what no test of this task shows: a unit that
the defect stopped before the repair folds its pending input to the
refusal. That follows from the pure decision; no test holds a journal
of the old engine.

One independent review, risk high (durable state).

## Review risk

High: the fold of the durable control state, and a refusal that drops
an evaluated result. One independent review by a strong reasoning
model. The reviewer checks:

- that the refused state holds nothing of the dropped result (no
  callable, Budget, invocation, receipt, count, tracker, slot or
  request of the child), and that the fold gives no output for it;
- that the check uses the state of the result of the fold, so that it
  agrees with the assertion of `step/2`;
- that the state returned on refusal satisfies the bound (step 1 of
  the task);
- that the parent action settles once, with `refused`, `record_size`
  and actual 0, and that a change of Attempt while the slot is
  `:refusing` treats it as not sent;
- that `fits?/1`, its reserve and every other fold clause are equal to
  the base;
- that the README and `piece.json` state the refusal and the Limit, and
  claim no more than the listed cases show.

## Not in scope

**The state of a callable that grows after its start.** `invoke/3`
stores the new state of a pattern after every input (about 864, 886 and
928) with one check only: the state itself is at most 65,536 bytes.
Callables are never removed from control during a Run. So children that
start small and grow later can pass the bound of the control state
inside the stated Limits (33 children with states near 65,536 bytes;
256 lifetime actions allow them), and the step then fails in the same
way as in issue #501. This task covers that growth only in the step of
the start. It does not cover a later input, for three reasons. There is
no admission to refuse: the input is an outcome that the same step has
settled into its tracker and join before the pattern runs. The only
existing answer, `invalid_pattern_state`, drops a state that is valid
by the Contract and leaves the pattern without the input. And the state
without the new pattern state is not sure to fit either: the settled
payload in the join, the invocation entry and, for a request that does
not fit, the stored state (about 928 and 984) are in it. The repair
needs a decision on the Contract: a reserve of 65,536 bytes for each
open callable, or the removal of the state of a closed child whose
parent is settled, or a stated failure of the callable. Each changes
`fits?/1`, its reserve or the durable shape. It has its own issue, #502, and gets
its own task; name it in the pull request body under `Limits:`.

Also not here: the growth of the joins through settled payloads (named
in ELZ-192); the growth of `control.invocations`, which gets one entry
for each input that reaches a pattern and which no code read here
removes (an observation by reading; it belongs to the same issue); a
child pattern function that raises on its `start`; the bound itself and
`fits?/1` (ELZ-217); the refusal `nested_input`; room that comes back
when a child closes; the journal write path; and any other Piece.
