# ELZ-196 — A graph whose last result passes the state bound finishes `failed` with `state_over_bound`

- Dependencies: ELZ-168, ELZ-172
- Output: none. A repair of the ready Piece `workflow/graph-run` that restores its Contract on the state bound, with one narrowed claim and one corrected sentence; the Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/workflow/graph-run/**` only, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` of its row, because `piece.json` changes).

The automated review of pull request #380 left three findings on this
Piece, and the review of pull request #371 one that is the same as the
second: the state bound is not held on the last settlement, the claim on
the arrival order is false for one kind of map, and one sentence on the
run engine is out of date.

Facts checked on `main` (lines of `lib/elzoo/graph_run.ex` at the time of
writing; confirm each when you start, and if one differs, stop and ask):

- `bounded/2` (about 76 to 81) measures `next`, the state that
  `transition/3` returns, and gives `state_over_bound` when it is over
  65,536 bytes.
- On the last settlement `conclude/1` calls `done/1` (about 509 to 520),
  and `finish/6` (about 531 to 551) returns `closed(state)`, which is
  `%{phase: :closed, id: ...}`. That state is always small. So a last
  result that brings the running state over the bound completes the
  graph, and its `gives` go into the finish.
- The same result at a node that is not the last one gives
  `state_over_bound`. The test "a state over the bound finishes failed
  with state_over_bound" (`test/elzoo/graph_run_test.exs`, about 1283 to
  1295) covers the start and a node that is not the last.
- The README (about 151 to 154) says: "a graph whose state would pass
  65,536 bytes ... finishes `failed`, `state_over_bound`, at once and
  without awaiting open actions".
- `continue/2` for a map (about 268 to 275) starts a further item only
  when `stop` is false, and the settlement of an item (about 383 to 387)
  sets `stop` at the first item that is not `completed` when the mode is
  `:fail`. With three items and concurrency 2, "item 0 completes, then
  item 1 fails" asks for item 2; "item 1 fails, then item 0 completes"
  does not.
- `piece.json` (about line 19) says: "Results in a different arrival
  order give the same set of actions and the same finish except the
  action_id of the finish". The README (about 125 to 128) says the same.
  The group `arrival_order` (about 946 to 1008) tests successes only.
- The README (about 226 to 228) says: "The ready `assembly/run-engine`
  holds no result of the child in its outcome of a nested callable, so
  with that engine a `call`, `decision`, `map` or `loop` node settles as
  `failed`". The README of `assembly/run-engine` (about 189 to 195) says
  since ELZ-172 that the first admitted finish of a nested callable is
  given to the parent: a finish whose schema key equals the `result` of
  the parent's `nested_callable` binding completes the parent action with
  the exact payload, another schema fails it with
  `nested_result_invalid`, and a child with no admitted finish keeps
  `completed` with the reason `nested_completed`. The stale sentence is
  not in `piece.json`.

## The repair

1. **State bound.** `done/1` measures the running state before it makes
   a finish. When that state is over 65,536 bytes the finish is `failed`
   with `state_over_bound` and no node, as `bounded/2` gives it; this
   comes before `completed` and before `ambiguous_output`. A graph that
   ends through `no_outcome_link` keeps that reason. The measure is the
   existing `size/1`. Nothing else of the step changes.
2. **Arrival order.** Narrow the claim in `piece.json` and in the README
   to what holds: the set of actions and the finish do not depend on the
   arrival order, except the `action_id` of the finish, and except a map
   with `on_item_failure` `:fail` that has more items than its
   concurrency: there a later item is asked for only when a result
   arrives before the first item that is not `completed`. Change no
   code for this part.
3. **Engine sentence.** Replace the stale clause with what the ready
   `assembly/run-engine` does since ELZ-172, in the words of its README:
   it gives the first admitted finish of a nested callable to the parent
   action when the schema key of that finish equals the `result` of the
   parent's `nested_callable` binding, fails the parent action with
   `nested_result_invalid` for another schema, and settles it `completed`
   with no result when the child gave no admitted finish. Keep "No engine
   claim": this Piece tests nothing with the engine. Leave the other
   clauses of that paragraph as they are.

The changed Contract text is the sentence of step 2. `piece.json`
changes (that sentence and the test claim that names the groups), so the
`manifest_sha256` of the index row follows in the last commit before the
pull request is opened (in-place change of a ready Piece, same Piece ID;
Elzoo is not released). The `contract` sentence is unchanged.

## Named acceptance groups

1. **`last_result_over_bound_fails`**: a graph of one call node whose
   result is 70,000 bytes finishes `failed` with `state_over_bound`,
   node `nil`, and is closed; two last nodes whose gives pass the bound
   only together finish the same way at the second result; a last result
   that keeps the state at or under the bound completes as today.
2. **`fail_fast_map_two_orders`**: a map with three items, concurrency 2
   and `:fail`. The order "item 0 completes, item 1 fails" asks for item
   2; the order "item 1 fails, item 0 completes" does not. The test
   records the set of actions and the finish of each order.
3. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged, the group `arrival_order` included.

Negative control, by a temporary edit that is reverted: with the measure
removed from `done/1`, the first case of group 1 gives a `completed`
finish and the test fails.

Run `mix test pieces/workflow/graph-run/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk normal.

## Not in scope

A change of the fail-fast rule of a map, the size of the bound,
`assembly/run-engine`, `runtime/recipe-test`, the same stale sentence in
other Pieces (a documents task takes them), and any other Piece.
