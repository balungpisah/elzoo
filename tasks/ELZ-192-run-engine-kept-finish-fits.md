# ELZ-192 — A child finish is admitted only when the control state has room to keep it

- Dependencies: ELZ-033, ELZ-191
- Output: none. A repair of the ready Piece `assembly/run-engine` that restores its Contract on the bound of the control state; the Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and `note` of its row, when `piece.json` changes).

Issue #383 records the defect. The first admitted `finish` of a nested
child is kept in the durable control state until its parent action
settles. Nothing reserves room for it. With enough parents open at the
same time, each with a child that has finished with a large payload and
still has an open cost, the kept finishes pass the bound of the control
state. The step then fails, the durable unit stops, and a replay fails on
the same input again: the Run halts. ELZ-191 comes first because it
changes which parents settle, and so when a kept finish leaves the state.

Facts checked on `main` (lines of `lib/elzoo/run_engine.ex` at the time of
writing; confirm each when you start, and if one differs, stop and ask):

- The bound is `fits?` (about 2772 to 2780): the bytes of the control
  state plus a reserve (1,024 bytes for each receipt that can still come
  and 4,096 bytes for each active slot) must be at most 2,097,152. It is
  asserted after every step (about line 76); a failure raises.
- A child finish is dispatched and its continuation keeps the finish in
  `control.callables[child][:finish]` (about 1852 to 1859 and 279 to 282).
  It leaves the control state when the parent slot settles (about 57 to
  64).
- The admission of an action checks `slot_fits?` only (about line 208),
  which refuses with the reason `record_size`. It does not count the bytes
  of a finish that will be kept.
- A raise in a step stops the durable unit with
  `durable_unit_transition_failed` and leaves the input unresolved; the
  README describes that a Run then halts.

## The repair

A `finish` of a nested child whose callable has kept no finish yet is
admitted only when the control state, with that finish placed in it, still
satisfies `fits?`. From the admission until the continuation has kept the
finish, its bytes are held in the reserve, so that no other admission in
between can take the room. When there is no room, the finish is refused
with the existing reason `record_size`: the child pattern gets an ordinary
refusal, the parent action is not completed by it, and the engine goes on.

Nothing else changes: only the first admitted finish is kept; its payload
is exact; a root finish and every other action kind are admitted as today;
no record kind, durable field, input, option or public function is added.
The README states the rule beside the existing text on the kept finish.

## Named acceptance groups

1. **`finish_without_room_is_refused`**: parents open together, each with
   a child that holds an open cost and finishes with a payload near the
   payload bound: the finish that would pass the bound is refused with
   `record_size`; every earlier one is kept; the engine answers the next
   input; `fits?` holds after every step. Record how many finishes fit.
2. **`room_comes_back`**: after one parent settles, a finish of the size
   that was refused is admitted.
3. **`smaller_finish_fits`**: after the refusal a finish with a small
   payload of the same child is admitted and reaches the parent by the
   existing rules.
4. **`replay_is_equal`**: a restart after group 1 gives an equal view and
   an equal count of journal records, and the refused finish is not asked
   again.
5. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged.

Negative control, by a temporary edit that is reverted: without the check,
the step of group 1 fails and the unit stops.

Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk high (durable state).

## Not in scope

The growth of the joins in the control state through settled payloads
(name it in the pull request body under `Limits:` with the lines, as an
observation), the bound itself, the journal write path, and any other
Piece.
