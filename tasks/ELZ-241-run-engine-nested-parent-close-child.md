# ELZ-241 — When a nested parent action settles, its child callable and every callable below it close

- Dependencies: ELZ-033, ELZ-192, ELZ-217
- Output: none. A change of behaviour in place of the ready Piece `assembly/run-engine`, before the first release, with the same Piece ID: the Contract, the README and the `limits` of `piece.json` state the new rule. The Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/assembly/run-engine/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and `note` of its row, because `piece.json` changes).

Issue #509 records the defect, found by reading for issue #502; the
coordinator sized it (comment of 2026-11-15) and decided: when a
nested parent slot settles, its child callable and every callable
below it close; open child slots settle by their own rules. On the
over-cap path the defect does not exist — the generation closes in
the same step — it exists on the path where a running parent expires
at its deadline.

Facts checked on `main` at `640707ac` (lines of
`lib/elzoo/run_engine.ex` at that commit; confirm each when you
start, and if one differs, stop and ask):

- A callable is set to `closed` (and loses its `state`) at two places
  only: the continuation of its own finish, which passes
  `finish_callable` (about 289 to 295), and `close_open/4`, which
  closes every non-root callable when the Attempt changes or the Run
  ends (about 771 to 778).
- A `nested_callable` slot of a child is created by the fold of a
  `:nested` record (about 332 to 387): the child callable
  `occurrence_id(key)` is stored with `parent: key` (the slot key) and
  `depth` one more than its owner's (about 340 to 348), and the parent
  slot goes to `:running`.
- The parent slot can settle while the child is open:
  `expire_waits/2` settles a `nested_callable` slot in `:running` at
  its deadline through `settle_protocol/3` (about 1102 to 1124); the
  over-cap deny turns the parent to `:refusing` and
  `progress/3` settles it (about 915 to 955 and 1849 to 1865); a
  terminal Run or a change of Attempt closes it through
  `close_open/4`, which already closes the callables. No other path
  closes the child callable when the parent settles by expiry or by
  the over-cap deny.
- While the child callable stays open its pattern still gets the
  outcomes of its own actions: the fold calls `invoke/3` when the
  callable is not closed (the guard at about 96 to 104 asks only
  `closed`), and a closed callable gets no more pattern inputs but
  its open slots still settle by `settle_protocol/3`,
  `expire_waits/2` and `close_open/4` as today.
- Nobody can read the result of such a child: a finish it sends later
  is kept and dropped again in the same step, because its parent is
  settled (the `:continuation` fold at about 281 to 330 keeps the
  finish only when `finish_callable` is set, and the parent slot is
  already `:settled`).
- The cost of the parent stays open while the child is open:
  `child_cost/2` answers `:open` for a callable that is not closed
  (about 1746 to 1759), so `due_child/4` does not select it and no
  `:nested_actual` record can follow (about 1708 to 1735 and 126 to
  135). The count of open callables is bounded only by the 256
  lifetime actions, not by the 64 active ones, and after ELZ-232 each
  open callable holds a reserve of its whole state bound in the
  control state (`fits?/1`, about 3056 to 3072), so room is lost for
  new nested starts until the Attempt changes or the Run ends.
- The proposal of the issue (a pure function of the stored state and
  the record) stands: the close is decided inside the fold, from the
  record that settles the parent, with no clock and no process.

## The rule

When a `nested_callable` slot becomes `:settled` — by
`settle_protocol/3` (an outcome, an expiry or a denial that reaches
it) — its child callable `occurrence_id(key)` and every callable
below it close in the same fold step, the way `close_open/4` closes
callables deepest first: `closed: true` and `state` removed, so the
reserve of ELZ-232 leaves the control state. A callable below is one
whose `parent` chain reaches the child callable (each callable's
`parent` is the slot key of the action that spawned it, and its id is
`occurrence_id` of that key).

Open slots of the closed callables are not settled by the close: they
settle by their own rules — their outcomes through `settle_protocol/3`,
their deadlines through `expire_waits/2`, and the end of the Attempt
or Run through `close_open/4` as today. Their costs still reach the
parent Budget: `child_cost/2` then counts the closed callable by its
slots, `due_child/4` selects it when every cost is known or final
unknown, and the parent gets its `:nested_actual` or its unknown
outcome as today. A finish the child already kept stays in control
until the parent settles, as today.

The change is a pure function of the stored state and the record. No
input, option, control command, public function, record kind or
durable field is added. The Contract, the README and the `limits` of
`piece.json` state the rule; in particular the sentence that a child
whose parent settled while it was open keeps its reserve until the
Attempt changes or the Run ends is replaced by the close rule.

## Named acceptance groups

The cases go into the existing nested groups of the Piece (for
example beside `nested_lost_effect_reaches_parent`,
`unknown_is_not_zero`, `known_costs_are_exact`,
`still_waits_for_a_cost_that_can_come`, `two_levels` and the groups of
the end of the Run), so the named groups of `piece.json` stay or gain
the new named group the worker adds to `piece.json` and the README.
Nearest existing fixtures: `lost_setup/2` and `nested_setup/1` of the
test file (about 4498 to 4512), `restart/3`, `bounded_restart/3`,
`view/1`, `unit_state/1` and `budget_status/3`.

1. **`expired_parent_closes_its_child`**: a nested parent whose child
   holds an open cost (a running tool call, for example) passes its
   deadline; the first input at or after the deadline settles the
   parent `expired`; in the same step the child callable and every
   callable below it are closed (`status/1` or the unit state shows
   no open callable but the root), the child's open slot is still
   open, and the pattern of the child gets no more inputs.
2. **`child_cost_still_reaches_the_parent`**: after group 1 the child's
   open slot settles by its own outcome; the parent gets its actual
   once by `:nested_actual` when every child cost is known (the
   committed child amount), or keeps no actual when one is final
   unknown — the same rule as without the close.
3. **`two_levels_close`**: a child that itself spawned a grandchild:
   when the top parent settles, the child callable and the grandchild
   callable close in the same step, deepest first; the grandchild's
   open slots settle by their own rules.
4. **`over_cap_parent_closes_its_child`**: the over-cap deny of a
   settled parent keeps its present behaviour (the generation closes
   in the same step); where a running parent is refused `out_of_budget`
   while its child is open, the child callable closes with it.
5. **`room_comes_back`**: after group 1 the reserve of the closed
   callables leaves the control state (`fits?/1` reserve terms), so a
   later nested start that needed the room is admitted; a restart
   replays an equal state.
6. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged, including the groups that a parent of a terminal Run or
   of an older Attempt is settled by `close_open/4` (that closer
   already closes every callable).

## Evidence and gate

Negative control, by a temporary edit that is reverted: without the
close, group 1 leaves the child callable open (`child_cost` stays
`:open`, no `:nested_actual` follows, the reserve stays), group 3
leaves the grandchild open, and group 5 refuses the later nested
start. Record each failure, then revert; never commit the edit.

Run `mix test pieces/assembly/run-engine/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk high (durable state
and nested costs).

## Not in scope

Settling the open slots of the closed callables at once (they settle
by their own rules), the finish a closed child kept (it is given to
no pattern, as today), the cost of the engine steps (ELZ-217), the
recovery of a sent Resource action (ELZ-240), the room of an input
that settles no slot (ELZ-234), and any other Piece.
