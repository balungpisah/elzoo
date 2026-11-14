# ELZ-198 — `NodeOutcome.decide/2` gives `{:error, :invalid_input}` for a struct operand

- Dependencies: ELZ-166
- Output: none. A repair of the ready Piece `workflow/node-outcome` that restores its Contract; the Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/workflow/node-outcome/lib/**` and `pieces/workflow/node-outcome/test/**` only. No `piece.json`, no README, no index file.

The automated review of pull request #368 found that `decide/2` raises
when `routes` is a struct.

Facts checked on `main` (confirm each when you start):

- `decide/2` (`lib/elzoo/node_outcome.ex`, about 19 to 33) has the guard
  `is_map(routes) and outcome in @classes`. A struct is a map, so it
  passes. `Enum.all?(routes, fn {class, target} -> ... end)` then raises:
  `FunctionClauseError` for a Range (its elements are integers) and
  `Protocol.UndefinedError` for a struct that is not enumerable, such as
  a `Date`.
- The README (about lines 32 and 76) and `piece.json` (about line 12)
  say that the only error is `invalid_input`.
- The group `invalid_input_and_redaction`
  (`test/elzoo/node_outcome_test.exs`, about line 202) has no struct.
- `routes/2` (about 9 to 11 and 36 to 53) refuses a `node_id` that is
  not a text, and matches each link against a map with text keys, which
  no struct has. So it does not raise for a struct: a struct in `links`
  is passed over like any other map that is not an outcome link of the
  node.

## Task

Add `not is_struct(routes)` to the guard of `decide/2`, so that a struct
falls to the clause that returns `{:error, :invalid_input}`. Change
nothing else. Contract unchanged.

## Acceptance

- **`struct_operand_is_invalid_input`** (new cases of the group
  `invalid_input_and_redaction`): `decide(1..2, "failed")`,
  `decide(~D[2026-01-01], "completed")` and `decide(MapSet.new(),
  "completed")` return `{:error, :invalid_input}`. `routes/2` with a
  struct as `node_id` returns `{:error, :invalid_input}`, and with a
  struct as an element of `links` it does not raise: the struct is passed
  over like any other map that is not an outcome link of the node.
- Every existing test of the Piece passes unchanged.
- Negative control, by a temporary edit that is reverted: without the
  guard the first two cases raise; record both exceptions.
- `mix test pieces/workflow/node-outcome/test`, then
  `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0.
- One independent review, risk low.

## Not in scope

The Cure rule, `routes/2` apart from the new test cases,
`workflow/graph-run`, and any other Piece.
