# ELZ-183 — The recipe test runs Lua tools and graphs that a model gives, and restarts

## Scope and reuse

- Dependencies: ELZ-033, ELZ-169, ELZ-177, ELZ-178, ELZ-179, ELZ-180, ELZ-181
- Output: none. This task changes `runtime/recipe-test` (ELZ-181) in place; the Piece ID stays. Second and last portion of RC-66.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Owned paths: `pieces/runtime/recipe-test/**` and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and `note` of its row, and the generated files).

Owner decision, 2026-11-14: Elzoo is not released yet, so a Piece that
lacks something which clearly belongs to it is extended in place, with the
same Piece ID (AGENTS.md section 4). Coordinator decision, 2026-11-14:
RC-66 is published as two tasks; ELZ-181 made the harness with agent,
decision and graph callables and adapter tools. This task adds the rest of
the RC-66 acceptance: a tool written in Lua with a module call, a graph
that the scripted model gives, and a restart after which the recorded
graph is read again and the model is not asked again. With this task RC-66
is complete.

Implement only what is below. Keep everything of the task ELZ-181 that
this text does not change. Add no option, no retry, no second restart, no
behaviour or hook. Edit no other Piece, shared path, pin or CI file. No
fixtures directory is needed.

## Facts checked

Confirm each when you start. The tasks ELZ-177, ELZ-178, ELZ-179, ELZ-180
and ELZ-181 are read from their task text and must be confirmed after they
merged; if one differs, stop and ask.

- The task ELZ-181: `run/1` with `spec` of exactly the atom keys
  `package`, `facts`, `sources`, `agents`, `decisions`, `script`,
  `effects`, `adapters`, `input` (`:invalid_spec` otherwise), its start
  checks 1 to 8 (check 7 is `{:unsupported_tool, alias}`), the host built
  with `fixture/1` and the `effect_bindings` override of ELZ-180, the
  bindings `"finish"`, `"model_call"`, `"tool_call"` (schema map of
  `elzoo.agent-loop.tool-call` and `elzoo.graph-run.tool-call`) and
  `"nested_callable"` (schema map of `elzoo.graph-run.call`, class
  `compute`), the depth and id rules (`d<k>x<24 hex>`, nested estimate
  `2^max(0, 62 - 7k)`), the driver (held calls, stable point, occurrence
  order, rule 1 that ends the Run only when nothing is held and every slot
  is settled), the record `%{outcome, steps, asked, unused}`, canonical
  JSON, `text(v)` and `marked(t)`, and `Glue` with the kinds `:agent`,
  `:graph`, `:decision` and `to` `:root` or `:node`.
- `assembly/run-engine`, `lib/elzoo/run_engine.ex`: `local_work` runs the
  MFA of `binding.work.(action)` in AsyncWork; `work` is called inside the
  engine process; `{:completed, value}` becomes a completed outcome with
  the schema of `binding.result` and `actual` equal to the estimate (about
  lines 1657-1671). The AsyncWork controller sends to the engine's
  registered name, so a restarted engine of the same name receives it.
  `binding.nested.(action)` is called once, at dispatch; its facts and the
  child state are committed in the `:nested` record (about lines
  1725-1745), and a restarted engine reads that record and does not call
  `nested.(action)` again. A nested child's start reaches the child by an
  asynchronous send (engine test helper about lines 261-264).
- The engine test helper: `fixture/1` gives `c.host_mode`, an Agent at
  `:fresh` read by the EffectIntent host's `authorize`; `:recover` makes it
  answer `{:recovered, generation}`, which
  `Elzoo.EffectIntent.StoreHost.activate/2` accepts for any head revision,
  a fresh stream included (`host.ex` about lines 74-75). `c.directory` and
  `c.prefix` are the DynamicUnits directory and the Unit identity. The
  engine looks up any `effect_intent` key in recovery (`recover_intents`
  and `intent/3`, about lines 1885-1913).
- Engine tests restart a Run with `GenServer.stop(engine)`,
  `DynamicUnits.stop(directory, prefix)` (`:ok`) and `start/2` again after
  `Agent.update(c.host_mode, fn _ -> :recover end)`. An Effect that was in
  flight is then `unknown` (`lost_outcome`) at once and is never sent
  again (`run_engine_test.exs` about line 1478); a local work in flight is
  recorded as lost before a late completion (about line 1642). A work MFA
  that holds the test process as an argument is the precedent of
  `run_engine_test.exs` about lines 1640-1650.
- The task ELZ-179 (`workflow/lua-tool`): `new/1` takes exactly `id` (1 to
  64 bytes, no `":"`), `source`, `policy`, `limits` (string keys),
  `bindings`, `sources`, `source_id`, `max_calls`; errors `:invalid_spec`,
  `{:sources, reason}`, `{:unbound_function, name}`, `:state_too_large`.
  Start `elzoo.lua-tool.input` `{"input"}`; run action `local_work`
  `elzoo.lua-tool.run` `{source, input, policy, limits, calls}` with
  `calls` `{"mode": "replay", "names", "recorded"}`, result
  `elzoo.lua-tool.run-result`: exactly one of `{"ok": {"value",
  "identity", "runtime"}}`, `{"pending_call": {"index", "name",
  "arguments"}}`, `{"refused": reason}`, `{"host_outcome": reason}`;
  module call `tool_call` `elzoo.lua-tool.module-call` `{alias, source,
  tool, version, arguments}` whose `alias` is that of the resolved tool,
  result `elzoo.lua-tool.module-result` exactly `{"result": plain}`
  (another form ends the tool `module_call_not_completed`); finish
  `elzoo.lua-tool.result` `{status, reason, detail, action_id, result}`.
  Ids `id:r:N`, `id:c:K`, `id:finish`.
- The task ELZ-178 (`runtime/lua-binding`): `resolve(declaration,
  manifests)` gives `{:ok, bindings}`, `{:refused, reasons}` or
  `{:error, :invalid_input}`; `source(bindings, id)` gives `{:ok, source}`
  or `{:error, :invalid_input}`. The alias of a function is
  `id <> "_" <> name` only when that matches `[a-zA-Z0-9_-]{1,64}`, else a
  cut form with a hash, as `workflow/tool-registry` makes it.
- The task ELZ-177 (`runtime/lua-sandbox`; `main` has policy version 2
  with a four-key request until it merges): policy version 3, `build/2`,
  `policy/0` (`%{identity, descriptor}`), and `run/2` with a request of the
  five atom keys `source`, `input`, `policy`, `limits` (`steps`,
  `call_depth`, `value_bytes`, `memory_bytes`, `wall_ms`) and `calls`
  (`mode`, `names`, `recorded` of `%{name, arguments, result}`); the
  replies `{:ok, %{value, identity, runtime}}`, `{:refused, reason}`,
  `{:host_outcome, reason}`, `{:pending_call, %{index, name,
  arguments}}`. Its tests build the executable once per module from
  `Mix.Project.deps_paths()[:lua_source]` into a disposable directory; no
  build time is recorded anywhere (module timeouts of 120,000 and 180,000
  ms only). `wall_ms` is real time, at most 1,000.
- `workflow/runtime-graph` (ELZ-169): `accept(proposal, context)` with a
  string-keyed `context` of the keys `recipe`, `name`, `callables`,
  `agent_tools`, `declared`, `facts`, `tool_costs`, `ask_cost`,
  `max_nodes`, `max_depth`, `depth` gives `{:ok, %{recipe, callable, unit,
  upper_cost}}`, `{:refused, reasons}` or `{:error, :invalid_context}`;
  `render(reasons)` gives text that begins with `graph refused:`. Stage 2
  checks tool nodes against `agent_tools`; stage 3 checks the new graph
  with `check_graph/3` against `facts["tools"]`, the Run's snapshot.
- `workflow/agent-loop`: a tool whose callable is `{:nested, _, _}` is
  asked for as `nested_callable` with `elzoo.agent-loop.tool-call`.
  `workflow/graph-run`: a nested tool node is `nested_callable` with
  `elzoo.graph-run.tool-call`.
- AGENTS.md section 5: a copied consumer runs only for a Piece that is
  newly ready; `runtime/recipe-test` is ready at the base of this task.

## The change

**Spec.** `spec` gains exactly three atom keys:

- `tools`: a map from the alias of each nested tool of the snapshot to
  `%{kind: :lua, source, limits, declaration, manifests, source_id,
  max_calls}` (a tool written in Lua) or `%{kind: :graph, sources,
  callables, tool_costs, max_nodes, max_depth, cap}` (a tool whose
  arguments are a graph that the model gives).
- `executable`: the path of a sandbox executable of `LuaSandbox.build/2`,
  or `nil` when `tools` has no `:lua` entry.
- `restart_after`: `nil` or a positive integer `n` (below).

Each spec literal of the ELZ-181 tests gains `tools: %{}, executable: nil,
restart_after: nil`. This is the only change to those tests, besides the
`unsupported_tool` case below.

**Start checks.** Check 1 also gives `:invalid_spec` for an `executable`
that is not text while `tools` has a `:lua` entry, and for a
`restart_after` that is neither `nil` nor a positive integer. Check 7 is
replaced; for each alias, ascending: `{:unbound_tool, alias}` when a
nested tool of the snapshot has no `tools` entry or a `tools` key is not
the alias of a nested tool; `{:invalid_tool, alias, reason}` when, for
`:lua`, `LuaBinding.resolve/2`, `LuaBinding.source/2` or `LuaTool.new/1`
(id `d1`) does not give `{:ok, _}` (`reason` is its result), or for
`:graph` the snapshot of its `sources` is refused (`{:sources, reason}`).
The start error `{:unsupported_tool, alias}` no longer exists; its case in
the ELZ-181 group `start_refusals` becomes the `unbound_tool` case of
group 1.

**Schemas** gain, as in ELZ-181: `elzoo.lua-tool.input`,
`elzoo.lua-tool.run`, `elzoo.lua-tool.run-result`,
`elzoo.lua-tool.module-call`, `elzoo.lua-tool.module-result`,
`elzoo.lua-tool.result`.

**Bindings** gain, each with `version: 1`, the `proposal` and the facts
rule of ELZ-181:

- in the `"tool_call"` map: `elzoo.lua-tool.module-call` (id
  `recipe-test.tool.lua`, class `publish`, result
  `elzoo.lua-tool.module-result`). The script key of a module call is
  `{:tool, alias}`, where `alias` is the `"alias"` member of the
  `elzoo.lua-tool.module-call` payload, as `ToolRegistry.tools/1` lists
  it (a cut form for a long name). The harness never builds an alias.
- in the `"nested_callable"` map, class `compute`:
  `elzoo.graph-run.tool-call` (id `recipe-test.nested.graph-tool`, result
  `elzoo.graph-run.node-result`) and `elzoo.agent-loop.tool-call` (id
  `recipe-test.nested.agent-tool`, result `elzoo.agent-loop.tool-result`);
- `"local_work"`: id `recipe-test.lua-run`, class `compute`, result
  `elzoo.lua-tool.run-result`. `work.(action)` gives `{Elzoo.RecipeTest.
  Glue, :lua_run, [driver, executable, action["id"],
  action["payload"]]}`, where `driver` is the test process, captured by
  `run/1` when it builds the bindings (`work` runs in the engine process,
  where `self()` is the engine).

**Nested starts of tools.** The child id, depth, Budget and `nested`
output form are those of ELZ-181.

- `elzoo.graph-run.tool-call` with a `:lua` tool: the Lua tool, `to:
  :node`, start `{"input": arguments}` under `elzoo.lua-tool.input`, with
  the spec `id` the child id, `policy` `LuaSandbox.policy().identity`,
  `bindings` and `sources` (`[source]`) as checked at start, and the other
  members of the entry. A `:graph` tool here gets the refused child with
  the schema `elzoo.graph-run.node-result` and the payload `{"failed":
  "graph_tool_in_graph"}`.
- `elzoo.agent-loop.tool-call` with a `:lua` tool: as above, `to: :tool`.
- `elzoo.agent-loop.tool-call` with a `:graph` tool: `RuntimeGraph.accept/2`
  runs inside `binding.nested.(action)`. The arguments must be exactly
  `{"graph": proposal, "input": object}`. The context is the string-keyed
  map with `"recipe"` the package `graph`, `"name"` `"model-graph-" <>` the
  24 characters of the child id, `"callables"`, `"tool_costs"`,
  `"max_nodes"`, `"max_depth"` of the entry, `"agent_tools"` the snapshot
  of its `sources`, `"declared"` the `needs` and `permissions` of the
  package, `"facts"` the facts with `"tools"` and with `"cap"` set to the
  entry's `cap`, `"ask_cost"` `nil`, `"depth"` the depth of the agent.
  `{:ok, accepted}`: a graph child of `GraphRun.new/1` with the `recipe`
  and `callable` of `accepted`, the entry's `sources`, `maps` and
  `max_open` as in ELZ-181, `to: :tool`, start `{"input": object}` under
  `elzoo.graph-run.input`. Arguments in another form, `{:refused,
  reasons}`, `{:error, :invalid_context}` or an error of `GraphRun.new/1`:
  the refused child with the schema `elzoo.agent-loop.tool-result` and the
  content `RuntimeGraph.render(reasons)`, or `[graph not run: REASON]`
  (`REASON` `invalid_arguments`, `invalid_context` or the error atom).

The child state is committed in the nested record; after a restart the
engine reads it and the harness does not decide it twice.

**Module call outcome.** A completed module call gets `{"result": value}`
from its script entry; another class `{"reason": reason}`, as in ELZ-181.

**Held Lua runs.** `Glue.lua_run/4` sends `{:recipe_test_work, task,
action_id}` to the driver and waits for `:recipe_test_go`. A Lua run is
held from its message until then; the quiet rule of ELZ-181 counts it.
Step 2 of the loop releases the held call or Lua run with the smallest
occurrence: a call as in ELZ-181; a Lua run with `:recipe_test_go` (it
uses no script entry), and the harness then waits until its slot is
`:settled`, because AsyncWork gives its result after the release. A
release counts as one delivery, as a call does.

**Restart.** If `restart_after` is `n`, the harness restarts at the first
stable point after `n` deliveries at which at least one call or Lua run is
held, and before it releases anything there; this is checked before rule 1
of ELZ-181, which therefore does not end the Run in that window. A restart
is `GenServer.stop(engine)`, `:ok = DynamicUnits.stop(c.directory,
c.prefix)`, `Agent.update(c.host_mode, fn _ -> :recover end)` and
`start/2` again with the same overrides. Every call and Lua run that is
held at that moment is dropped and never answered: the engine records it
as `unknown` (a call) or lost (a Lua run), and it uses no script entry. At
most one restart. A Run that is done before such a point is not restarted.
`asked` counts dropped calls too.

**Record.** It gains `restarted: boolean`.

**Glue.** The state gains `%{kind: :lua, to: to, inner: lua_state}`,
`%{kind: :refused, id: id, schema_id: s, payload: p}` and
`%{kind: :closed}`, and `to` gains `:tool`. The inner step of `:lua` is
`LuaTool.step/2`. `:refused` answers `start` with one request of the
finish `id <> ":finish"` (schema `s`, version 1, payload `p`) and becomes
`:closed`; every other input, and every input of `:closed`, is no change
and no request. The conversion table gains:

| Child finish | `to: :node` | `to: :tool` (`elzoo.agent-loop.tool-result`) |
| --- | --- | --- |
| lua `completed` | `{"gives": result}` | content `text(result)` |
| lua other | `{"failed": reason}` | content `[lua tool failed: REASON]` |
| graph `completed` | as ELZ-181 | content `text(gives)` |
| graph other | as ELZ-181 | content `[graph failed: REASON]` |

A tool content is the tool result `{"content": marked_map, "media_type":
"text/plain", "encoding": "utf8"}` with the marked map of ELZ-181 whose
`sources` is `["recipe-test:lua"]` or `["recipe-test:graph"]`; the refused
child of a graph tool uses `"recipe-test:graph"`.

`lua_request(payload)` gives the sandbox request of a run payload: atom
keys, `limits` with the five atom keys, and `calls` with `mode`, `names`
and `recorded` entries `%{name, arguments, result}`. `lua_reply(reply)`
gives the run result payload: each of the four replies with every atom key
and every atom other than `nil`, `true` and `false` as a string,
recursively. `lua_run(driver, executable, action_id, payload)` is the held
work: after `:recipe_test_go` it returns `lua_reply(LuaSandbox.run(
executable, lua_request(payload)))`.

**Contract text.** Update `README.md` and `piece.json` (`contract`,
`limits`, `dependencies` with `workflow/lua-tool`, `runtime/lua-binding`,
`runtime/lua-sandbox` and `workflow/runtime-graph`, the provider
`lua_source` that the sandbox needs, `grounding` with the new groups). The
`note` of the Piece row in `docs/plans/release-plan.json` equals
`contract`, and `manifest_sha256` is computed again, in the one last commit
of the index files.

## Host Needs and Limits

Fixed bounds: those of ELZ-181; 256 module calls of a Lua tool; one
restart.

Needs: those of ELZ-181; the `lua_source` checkout and a C compiler for a
test that uses a Lua tool; a caller that builds the sandbox once per test
module and passes its path; manifests that a module really offers; each
tool of the `sources` of a `:graph` entry is a tool of the `sources` of
the Run, with the same source id and name (stage 3 checks against the
Run's snapshot, stage 2 and `GraphRun.new/1` use the entry's sources).

Limits: a Lua run is real: its `wall_ms` is real time, not the clock of
the harness. A restart drops every call and Lua run in flight; it shows
that the record is read again and that no recorded call is asked again,
not a restart without loss. A dropped call's task waits until the test
ends. The harness does not reserve the `upper_cost` of an accepted graph:
the child's Budget is the depth rule of ELZ-181. A `:graph` tool reached
from a graph node gets `{"failed": "graph_tool_in_graph"}`. Module
functions are scripted by their alias: an alias that equals a tool of the
Run shares its script list.

## Named acceptance groups

The database groups run on PostgreSQL with `ELZOO_TEST_DATABASE_URL`, fail
closed and are never skipped. The Lua groups are in one test module that
builds the sandbox once in `setup_all`; no other module builds it. Each
group starts at most three Runs. Every group of ELZ-181 stays green with
the spec change above.

1. **`tool_start_refusals`** (no database): `unbound_tool` for a nested
   tool with no entry and for an entry that names no nested tool;
   `invalid_tool` for each of `resolve/2`, `source/2`, `LuaTool.new/1` and
   the snapshot of a `:graph` entry; `invalid_spec` for a `:lua` entry with
   `executable: nil` and for `restart_after: 0`.
2. **`lua_tool_module_call`**: a Lua tool with a short name whose source
   makes one module call, so its alias is `<source_id>_<name>`. Through a
   root agent: the steps hold run 1, the module call (key `{:tool,
   alias}`), run 2 with a record of one call, and model call 2 whose
   payload holds the tool result with the canonical JSON of the value (a
   map in this test). Through a root graph tool node: the Lua value is an
   object that holds each give name of the node, and the node gives it.
   Both Runs `completed`.
3. **`model_graph_after_restart`**: a root agent with a `:graph` tool.
   Turn 1 gives a graph of a tool node and a second tool node joined by an
   `outcome` link for `unknown`; `restart_after: 1`. The first node's call
   is held at the restart and becomes `unknown`; after the restart the
   second node runs from the recorded graph and its call is delivered; turn
   2 answers. `restarted` is true; `asked[{:model, m}]` is 2 (turn 1 is not
   asked again); `asked` of the tool is 2 and `unused` is empty; the steps
   hold one `:nested` step for the graph and one outcome of model call 1;
   the Run is `completed`.
4. **`model_graph_refused`**: turn 1 gives a graph with a tool node whose
   tool is not in the entry's `sources`; model call 2 holds the content
   that begins with `graph refused:`; the child's only action is its
   finish (no node action exists); the Run is `completed`.
5. **`same_lua_spec_same_record`**: the agent spec of group 2 run twice
   gives two equal records.
6. **`glue_tool_forms`** (no database): `Glue.step/2` folded over literal
   traces gives each new row of the conversion table and the refused
   child; `lua_request/1` and `lua_reply/1` give the forms of ELZ-177 and
   ELZ-179 written as literals in the test.

## Evidence and gate

Test: the six groups and the groups of ELZ-181. Upstream: the Contracts of
the reused Pieces, scoped as they state them. No Cure module. Negative
controls: temporarily give a completed module call its raw value instead
of `{"result": value}` (group 2 must fail with
`module_call_not_completed`), then temporarily keep the held calls at a
restart and deliver them after it (group 3 must fail). Restore both
before the final gate.

Run `. .elzoo-services/env.sh`, `mix test pieces/runtime/recipe-test/test`,
then `mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. Measure the `setup_all` build of the sandbox host and
the total time of the Lua test module and report both in the pull request
body; no copied consumer runs for this in-place change. One independent
review checks the body and the exact diff, including extra features.

## Not in scope

A second restart, a restart without loss, a person answer, an approval, a
moving clock, a real or MCP Adapter, a reservation of `upper_cost`, a
`:graph` tool in a graph node (it gets `graph_tool_in_graph`), an alias
built by the harness, and any change of another Piece or shared file.
