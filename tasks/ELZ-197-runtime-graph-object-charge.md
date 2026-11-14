# ELZ-197 — The proposal scan of the runtime graph charges two bytes for each object

- Dependencies: ELZ-169
- Output: none. A repair of the ready Piece `workflow/runtime-graph` that restores a stated property of its scan; Contract unchanged, the Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/workflow/runtime-graph/lib/**` and `pieces/workflow/runtime-graph/test/**` only. No `piece.json`, no README, no index file.

The automated review of pull request #379 found that the byte budget of
the proposal scan charges nothing for an object itself, so a list of
empty objects costs one byte in all and is walked to its end.

Facts checked on `main` (lines of `lib/elzoo/runtime_graph.ex` at the
time of writing; confirm each when you start):

- `walk/2` for a map (about 186 to 191) refuses when `map_size * 4` is
  over the budget and then calls `walk_map/2` (about 202 to 210), which
  charges each key and each value. It charges nothing for the braces, so
  `%{}` costs 0.
- A list charges one byte (about 182 to 184) and then its elements.
- `sized/2` (about 145 to 152) still refuses such a proposal as
  `:too_large` by the exact size of `Jason.encode!/1`, so no result is
  wrong today. The work before that refusal is not bounded by 65,536
  bytes: for a term from a JSON decoder it is linear in the data; for a
  term built in the process, where one long list of empty objects is
  held by many list cells, the scan and the encoder visit it once for
  each reference.
- The README (about 96 to 100) says: "Each charge is at most the compact
  JSON size of the part ... A bound is thus reached before a long list or
  map is walked to its end."

## Task

`walk/2` charges 2 for each object before its entries. An object is at
least `{}` in compact JSON, so each charge stays at most the compact JSON
size of the part, and a proposal of exactly 65,536 bytes still passes
the scan. Change nothing else: no reason, no order of the stages, no
other charge. Contract unchanged; the README sentence is true again and
does not change.

## Named acceptance groups

The new tests go into the existing group `data_only` of
`test/elzoo/runtime_graph_test.exs`, beside the test of the byte bound.
No new `describe` group is added, so the test claim of `piece.json`
stays true as it is.

1. **`empty_objects_are_charged`**: `links` that hold 100,000 empty
   objects are refused as `:too_large`; the same for one list of 1,000
   empty objects that 1,000 cells of `links` hold (one shared term). For
   the second case the call uses fewer reductions of the calling process
   than a fixed count that you state (`Process.info(self(),
   :reductions)` before and after; no wall time).
2. **`byte_bound_stays_exact`**: the existing test "an over-long text is
   refused; the byte bound is exact" passes unchanged (65,536 bytes pass
   the scan, 65,537 are `:too_large`), and one more case shows a proposal
   of exactly 65,536 bytes that holds nested empty objects.
3. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged.

Negative control, by a temporary edit that is reverted: with the charge
removed, the shared case of group 1 passes its reduction count and the
test fails.

Run `mix test pieces/workflow/runtime-graph/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review, risk low.

## Not in scope

The bound itself, the charge of a list, stages 2 and 3,
`runtime/recipe-test`, and any other Piece.
