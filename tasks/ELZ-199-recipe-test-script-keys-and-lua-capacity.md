# ELZ-199 — The recipe test refuses each invalid script key and runs more than four held Lua runs

- Dependencies: ELZ-181, ELZ-183
- Output: none. A repair of the ready Piece `runtime/recipe-test`: one refusal restored to its stated form and one unstated bound removed; the Piece ID stays.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/runtime/recipe-test/test/**` only. No file of `lib/`, no `piece.json`, no README, no index file, and no file of `pieces/assembly/run-engine/`.

The automated review of pull request #421 found that `check_script/1`
accepts a script whose first invalid key is `nil`. The review of pull
request #434 found that a fifth Lua run that is held at the same time
fails with `local_unavailable`.

Facts checked on `main` (confirm each when you start, and if one differs,
stop and ask):

- `check_script/1` (`test/support/recipe_test_helper.exs`, about 129 to
  137) sorts the keys, takes the first invalid one with `Enum.find/2`
  and compares the result with `nil`. `Enum.find/2` gives `nil` both for
  "none found" and for the key `nil`. An atom sorts before a tuple, so
  `%{nil => 1, {:bogus, 1} => 2}` is accepted whole.
- The README (about line 140) says: `{:invalid_script, key}` is "the
  first key, in ascending term order, that is not a key of the form
  above, whose list holds an entry of another form, or whose entry holds
  a value that is not JSON data". The test "the first invalid script key
  in term order is invalid_script"
  (`test/elzoo/recipe_test_test.exs`, about line 347) has no `nil` key.
- `Elzoo.RecipeTest.Glue.lua_run/4` (`lib/elzoo/recipe_test/glue.ex`,
  about 107 to 115) is local work: it tells the driver, waits for
  `:recipe_test_go` and then runs the sandbox. The driver releases one
  held call or Lua run at a stable point (helper, about 818 to 832).
- The harness builds its host with `TestHelper.fixture/1` of
  `assembly/run-engine`
  (`pieces/assembly/run-engine/test/support/run_engine_test_helper.exs`,
  about 228), which starts one `Elzoo.AsyncWork` with
  `max_concurrency: 4` (about 250 to 254) and puts it into the options as
  `async_work` (about line 506). `Elzoo.AsyncWork` answers
  `{:error, :capacity}` at its limit, and the engine settles that action
  `failed` with `local_unavailable` (`run_engine.ex`, about 1777 to
  1787). So four Lua runs can be held at once; the fifth fails. The
  README Limits do not state four; they state 64 active occurrences.
- The fixture map holds `prefix`, and the name of the engine is
  `{:via, Registry, {Elzoo.RunEngine.TestRegistry, prefix}}` (about line
  240). `Elzoo.AsyncWork` takes that name as `owner`.
- `TestHelper.start/2` (about 547 to 553) merges its overrides into the
  options, and the harness gives the same `overrides` to every start of
  the engine, the one after a restart included (helper, about 421 to 434
  and 805 to 811). So the harness can give its own `async_work` there.
- The restart half, settled by reading: `restart/1` of the driver stops
  the engine and starts it again; the `Elzoo.AsyncWork` of the fixture is
  not restarted, and the engine has no `terminate/2` that cancels its
  work. The task of a dropped Lua run still waits for `:recipe_test_go`
  and keeps its place until its deadline or the end of the test (the
  README says: "A dropped call's task waits until the test ends"). So
  after a restart with one dropped Lua run, only three places are left.

## Task

1. `check_script/1` finds the first invalid entry by the pair of key and
   list, so that the key `nil` is reported as
   `{:error, {:invalid_script, nil}}` and no later invalid key is hidden.
   The order (ascending term order of the keys) and every other result
   stay.
2. The harness starts one `Elzoo.AsyncWork` of its own for a run, with
   the engine name of the fixture as `owner`, a task supervisor of its
   own and `max_concurrency: 128`, and gives it to the engine as
   `async_work` in the `overrides` of `execute/3`. 128 is 64 active
   occurrences before the one restart plus 64 after it, since a dropped
   task keeps its place. Start both processes under the test supervisor,
   as the fixture does. Change nothing of `assembly/run-engine`: its
   fixture keeps 4 for its own tests.
   With 128 the bound cannot be reached: the engine admits at most 64
   active occurrences, and there is one restart at most. So no new Limit
   is stated.

Contract unchanged; the README and `piece.json` do not change. If you
find that a held Lua run can keep a place in a way that this count does
not cover, stop and comment on the issue. Add no option to the spec, no
new start error and no layer: the two changes are in `check_script/1`
and in `execute/3`.

## Named acceptance groups

The new tests go into existing groups, named below, so the test claims
of `piece.json` stay true as they are. Add no new `describe` group.

1. **`each_invalid_script_key`** (in `start_refusals`): a script with
   the key `nil` is `{:invalid_script, nil}`; a script with `nil` and a
   later invalid key reports `nil`; a script whose only invalid key
   sorts last is reported with that key; a valid script passes.
2. **`five_lua_runs_together`** (in `lua_tool_module_call` of
   `test/elzoo/recipe_test_lua_test.exs`): an agent
   whose one model result proposes five calls of the Lua tool gets five
   completed results, the record holds no `local_unavailable`, and the
   Run completes.
3. **`lua_runs_after_restart`** (in `lua_tool_module_call`): a spec
   with `restart_after` that drops one held Lua run and then asks for
   four more at once: the dropped run is `failed` with `local_restart`,
   the four later ones complete, and the record holds no
   `local_unavailable`.
4. **`existing_behaviour`**: every existing test of the Piece passes
   unchanged, and two runs of the spec of group 2 give equal records.

Negative controls, each by a temporary edit that is reverted: with
`Enum.find/2` on the keys again, the first case of group 1 fails; with
`max_concurrency: 4` in the harness, groups 2 and 3 fail with
`local_unavailable`. Record the three failures.

Run `mix test pieces/runtime/recipe-test/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. The Lua tests need the `lua_source` checkout and a C
compiler; if the host has none, record the command and the reason under
`Local gate:`. One independent review, risk normal.

## Not in scope

The fixture of `assembly/run-engine` and its capacity of 4, a restart
that frees the places of dropped tasks, more than one restart,
`Elzoo.AsyncWork`, and any other Piece.
