# runtime/recipe-test

A recipe author tests a recipe in ExUnit with no provider. `Elzoo.RecipeTest.run/1`
checks a recipe package with `workflow/recipe-check`. Then it runs the recipe end
to end through the real `assembly/run-engine` and the real pattern Pieces
`workflow/agent-loop`, `workflow/graph-run` and `workflow/typed-decision`. The
Run is on disposable PostgreSQL. The model calls and the tool calls go to a
scripted Adapter. There is no network. The clock stays at 2,000 ms. The function
gives back the record of every step.

A tool written in Lua runs in the real sandbox of `runtime/lua-sandbox`, with its module
calls scripted. A graph that the scripted model gives is checked by `workflow/runtime-graph`
and run by `workflow/graph-run`. One restart of the engine can be asked for. With the spec
member `skills`, the two tools of the skill source are answered by `workflow/skill`, so a skill
load reaches the agent as a declaration, and a graph node can start an agent with a skill.
With the spec member `gate`, a test gives the gate of the engine, so the engine can refuse a call.

Compiled modules: `Elzoo.RecipeTest.ScriptedAdapter`, `Elzoo.RecipeTest.ModelBinding`,
`Elzoo.RecipeTest.ToolBinding` and `Elzoo.RecipeTest.Glue`. `run/1` itself is in the
test helper `test/support/recipe_test_helper.exs`, because it builds the host with
the `.exs` helper of `assembly/run-engine`. Only Adapters in the list of the caller
are accepted.

## Use

The test module loads the helper and starts the repository and the two Registries
of the engine helper. `run/1` starts and stops none of them. It runs inside a test,
because it starts its processes with `ExUnit.Callbacks.start_supervised!`.

    Code.require_file("../support/recipe_test_helper.exs", __DIR__)

    defmodule MyRecipeTest do
      use ExUnit.Case, async: false

      setup_all do
        pid = Elzoo.RunEngine.TestHelper.database()
        {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.TestRegistry)
        {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.UnitRegistry)
        for p <- [registry, units], do: Process.unlink(p)

        on_exit(fn ->
          for p <- [registry, units, pid], Process.alive?(p), do: Supervisor.stop(p)
        end)

        :ok
      end

      test "my recipe" do
        assert {:ok, record} = Elzoo.RecipeTest.run(spec)
        assert record.unused == %{}
      end
    end

`run/1` returns `{:ok, record}` or `{:error, reason}`. Assert on `record.unused`:
an entry of the script that no call used is not an error, and only `unused` shows it.

The path in `Code.require_file` is relative to the test file. In a copied consumer
the engine helper is a sibling of this helper; in the repository it is
`../../../../assembly/run-engine/test/support/` from `test/support/`. The helper
finds either.

## The spec

`spec` is a map with exactly these atom keys.

| Key | Meaning |
| --- | --- |
| `package` | the neutral recipe package map of `domain/recipe-package` |
| `facts` | the facts of `RecipeCheck.check/2` without `"tools"`; the harness adds `"tools"`, the snapshot of `sources` |
| `sources` | the operand of `ToolRegistry.snapshot/1`: the tools of every agent and graph callable |
| `agents` | a map from the binding target of each `agent` callable to exactly `model`, `max_output_tokens`, `role_instructions`, `window`, `max_request_bytes`, `max_image_refs`, `result_limits`, `turn_limit`; the harness adds `id`, `sources` and `ask: nil` |
| `decisions` | a map from the binding target of each `decision` callable to exactly `request` and `repairs`; the harness adds `id`, `port` and `answer: {:set, choices}` |
| `script` | a map from a key to an ordered list of results (below) |
| `effects` | exactly `%{model: module, tool: module}`, the EffectIntent binding modules of model calls and tool calls |
| `adapters` | the allow-list: a list of Adapter modules |
| `input` | the input of the Run: an object for a `graph` or `decision` root, non-empty text for an `agent` root |
| `tools` | a map from the alias of each nested tool of the snapshot to its entry (below); `%{}` when there is none |
| `executable` | the path of a sandbox executable of `LuaSandbox.build/2`; it must be text when `tools` has a `:lua` entry, and it can be `nil` or text otherwise (the harness does not use it then) |
| `restart_after` | `nil`, or a positive integer: the number of deliveries after which the engine restarts once (below) |
| `skills` | `nil`, or exactly `%{id: id, files: files, descriptors: descriptors}`: `id` a text, `files` a map from a skill name to the `files` that `Skill.read/4` gave, `descriptors` a list (see "Skills") |
| `gate` | `nil`, or a function of arity 2: the gate of the engine (see "The engine gate") |

An entry of `tools` is exactly one of:

- `%{kind: :lua, source, limits, declaration, manifests, source_id, max_calls}`: a tool written
  in Lua. `declaration` and `manifests` are the operands of `LuaBinding.resolve/2`; `source_id`
  is the one of `LuaBinding.source/2`; `source`, `limits` and `max_calls` are those of
  `LuaTool.new/1`. The harness uses the policy identity of `LuaSandbox.policy/0`.
- `%{kind: :graph, sources, callables, tool_costs, max_nodes, max_depth, cap}`: a tool whose
  arguments are a graph that the model gives, exactly `{"graph": proposal, "input": object}`.
  `RuntimeGraph.accept/2` decides the graph with these operands; `sources` are the tools of
  that graph and each must be a tool of the `sources` of the Run, with the same source id and
  name.

The `window` of an agent names the estimator `recipe-test-bytes`, version 1, unit
`:tokens`. Another window ends the agent with `request_not_built`, as the agent
loop decides. The `request` of a decision holds a text `"model"`.

## The script

A key is `{:model, model}` (the `"model"` of the request of the call) or
`{:tool, alias}` (the `"alias"` of the payload of the tool call). A module call of a Lua
tool is keyed `{:tool, alias}` by the `"alias"` member of its payload, as
`ToolRegistry.tools/1` lists it; the harness never builds an alias. A module function is thus
scripted by its alias, and an alias that equals a tool of the Run shares its script list.
Each entry is exactly one of:

| Entry | Meaning |
| --- | --- |
| `{:completed, value}` | for a model call, `value` is a map in the form `elzoo.ai-text.result` (`content`, `finish`, `tool_proposals`, `structured`), given unchanged; for a tool call, `value` is the plain value that the tool gave |
| `{:failed, reason}` | the call failed |
| `{:refused, reason}` | the call was refused; the dispatch is `not_dispatched` |
| `{:unknown, reason}` | the result is unknown; `{:unknown, "timeout"}` is a call that timed out, and no time passes |

A `reason` matches `[a-z0-9_]{1,64}`. A value is JSON data: string-keyed maps,
lists, texts, numbers, booleans and `nil`.

The entries of a key are used in order, one for each call of that key, in the
order in which the harness delivers calls. A call whose key has no entry left is an
explicit failure: `run/1` stops and returns `{:error, {:unscripted_call, key, record}}`.
No call gets a default. The scripted calls cost nothing.

A tool value reaches its caller in this form:

- an agent tool (but for the two tools that `skills` answers, see "Skills"): the tool result
  `{"content": marked text, "media_type": "text/plain", "encoding": "utf8"}`, where the text is
  the value if it is text, else its canonical JSON (compact, object keys in byte order);
- a graph tool node: `{"gives": value}`, so `value` must be an object that holds each
  give name of the node, else the node is `failed`;
- a module call of a Lua tool: `{"result": value}`; another class gets `{"reason": reason}`.
  A completed call with another payload ends the tool with `module_call_not_completed`.

An outcome payload over 65,536 bytes of JSON reaches the pattern as class `unknown`
with the reason `outcome_too_large`.

## Skills

With `skills` set, the package is the value of `RecipePackage.decode(spec.package)` (the recipe
check has already refused a package that it refuses). Two kinds of call are answered by
`Elzoo.Skill` and use no script entry. They are held calls of the schema
`elzoo.agent-loop.tool-call` whose alias is `skills.id <> "_load_skill"` or
`skills.id <> "_read_skill_file"`; `arguments` is the `arguments` member of the tool call
payload, which the harness carries in the intent arguments of these two calls only:

| Call | Answer |
| --- | --- |
| `<id>_load_skill` | `Skill.load(id, package, descriptors, arguments)` |
| `<id>_read_skill_file` | `Skill.read_file(package, files, arguments)` |

`{:ok, payload}` is a `completed` outcome under `elzoo.agent-loop.tool-result` with the payload
unchanged (dispatch `dispatched`). So a load gives the agent the declaration of `Elzoo.Skill`,
not marked text. `{:error, reason}` is a `refused` outcome with `{"reason": reason}` (dispatch
`not_dispatched`). Such a call counts in `asked` and is one delivery, as every call is. A script
entry for these two keys is never used and shows in `unused`. Every other call, including the
tools that a loaded skill declares, takes the next entry of its key as before; the tools of the
per-skill sources are scripted by their aliases.

The test author puts the list of `Skill.sources(id, package, descriptors)` into `sources`, with
the same `id`, package and descriptors as `skills` and the other tool sources of the Run.

**The start of an agent at a node.** An agent at a `call` node starts with `{"text":
canonical(input)}`. With `skills` set and a text member `"skill"` in the `input` of the node, it
starts with `{"text": canonical(input), "skill": {"tool": id <> "_load_skill", "name":
input["skill"]}}`, the start form of `workflow/agent-loop`. The agent loop then makes the load
call `<child>:t:0:1`, and the harness answers it as above; it decides alone what an unknown
skill does ("Start load" of that Piece). The start of a root agent does not change. A `decision`
node can give the skill (a `value` give to the need `skill`) and a tool node can give it, so a
decision or a tool result chooses the skill of a child.

**Restart.** The load outcome is an applied input of the Run. After the restart of the harness
the engine reads the record again, so the declaration is applied again from it and the load is
not asked again. The group `skill_load_after_restart` shows it with `restart_after` set so that
the restart falls while the call of a declared skill tool is held: one load action and one load
outcome, `asked` holds the load once, the dropped call of the skill tool is `unknown`, and the
model call after the restart holds the instructions in its system message and the skill tool in
its tools. A refusal of a declared tool at use is scripted with a `{:refused, reason}` entry
(`declared_tool_refused_at_use`), or comes from the gate of the engine (next section,
`declared_tool_denied_by_gate`).

## The engine gate

With `gate: nil` the engine runs with the gate of the engine test helper, which allows every
action, and a Run gives the same record as it did before this member existed.

With `gate: f` (`f` of arity 2), every start of the engine, the one after the restart included,
gets `gate: %{id: "recipe-test", version: 1, call: f}`. The harness passes `f` on unchanged: it
does not call it, wrap it or read its result. The engine calls it as the README of
`assembly/run-engine` says: for each checked action of a request, before Budget, Authorization
and Approval, with the checked action (`{:PatternStep, %{"actions" => [action]}}`) and
`%{proposer: principal, effect_class: class, tenant: tenant}`. The principal is the one of the
engine test helper, `"principal"`; the spec has no member for it. Every agent tool call has one
binding here, with the effect class `publish`, so the gate tells one tool from another by the
alias in the payload of the action, and one principal from another by `proposer`.

A denial `{:deny, reason}` is a `refused` outcome of the engine for that action: its schema is
`elzoo.run-engine.refusal` and its payload holds the `reason` of the gate and the `gate_id`
`"recipe-test"` and `gate_version` `1`. The call never reaches the harness: it uses no script
entry and is not counted in `asked`. An agent reads it as
`[tool call not completed: refused: reason]`. The group `declared_tool_denied_by_gate` shows it
for a declared skill tool: the instructions of the skill stay in the system message and the tool
stays in the tools, the call is refused by the gate for the principal `"principal"`, and the same
rule for another principal lets the tool run and complete. The Authorization step of the engine
is not what refuses here: the gate is.

## Start errors

Before any process starts, in this order; the first that fails is the result.

| Error | When |
| --- | --- |
| `:invalid_spec` | `spec` is in another shape, an `executable` that is not text while `tools` has a `:lua` entry, an entry of `tools` in another form, a `restart_after` that is neither `nil` nor a positive integer, `skills` in another form, or a `gate` that is neither `nil` nor a function of arity 2 (a spec with no `gate` key is in another shape) |
| `{:invalid_binding, :model \| :tool}` | `Binding.load/1` of the module is not `{:ok, _}`; model first |
| `{:adapter_not_allowed, :model \| :tool}` | the `adapter` of the binding is not in `adapters`; model first |
| `{:invalid_script, key}` | the first key, in ascending term order, that is not a key of the form above, whose list holds an entry of another form, or whose entry holds a value that is not JSON data |
| `{:sources, reason}` | the refusal of `ToolRegistry.snapshot/1` |
| `:invalid_facts` | `RecipeCheck.check/2` gave `{:error, :invalid_facts}` |
| `{:recipe_refused, reasons}` | `RecipeCheck.check/2` refused the recipe |
| `{:unbound_callable, name}` | an `agent` or `decision` callable has no entry for its binding target |
| `{:invalid_callable, name, reason}` | `AgentLoop.new/1`, `TypedDecision.new/1` or `GraphRun.new/1` refuses its spec; `:invalid_spec` when the `request` of a decision has no text `"model"`; `:gives` for a graph with a `call` or `decision` node that calls an agent callable and has a give other than `text`, or calls a decision callable and has a give other than `value` |
| `{:unbound_tool, alias}` | the first alias, ascending, of a nested tool of the snapshot that has no entry in `tools`, or a key of `tools` that is not the alias of a nested tool |
| `{:invalid_tool, alias, reason}` | the entry of that alias is refused: for `:lua`, `LuaBinding.resolve/2`, `LuaBinding.source/2` or `LuaTool.new/1` (id `d1`) did not give `{:ok, _}` and `reason` is its whole result; for `:graph`, `{:sources, reason}` of `ToolRegistry.snapshot/1` |
| `:invalid_input` | `input` is not in the form of the root kind |

After the start, an input that the engine refuses gives
`{:error, {:input_refused, reply, record}}`. Also `{:error, {:stalled, record}}`
(not stable or not done after 2,000 polls of 5 ms) and
`{:error, {:halted, reason, record}}` (the engine reports a reconciliation).
An error after the start carries the record as far as it got.

## The driver

The driver holds each model call, tool call and Lua run until it is quiet: every slot is
settled, held or a running nested callable. Then it releases the held one with the smallest
occurrence: a call gets its next script entry; a Lua run is sent `:recipe_test_go` and runs in
the sandbox (it uses no script entry), and the driver waits until its slot is settled. A
release is one delivery.

When `restart_after` is `n`, the driver restarts the engine once, at the first quiet point
after `n` deliveries at which at least one call or Lua run is held, before it releases
anything there. A restart is `GenServer.stop/1` of the engine, `DynamicUnits.stop/2` of its
Unit, a host that answers `:recover`, and a new start with the same options. Every call and
Lua run that is held at that moment is dropped and never answered, and it uses no script entry.
The engine records a dropped Effect (a model or tool call) as `unknown` and a dropped Lua run
as `failed` with the reason `local_restart`. At most one restart happens. A Run that is done
before such a point is not restarted.

## The record

    %{outcome: outcome, steps: [step], asked: %{key => n}, unused: %{key => n}, restarted: boolean}

| Field | Meaning |
| --- | --- |
| `outcome` | the `outcome` of `RunEngine.status/1` at the end |
| `asked` | the number of calls that reached the harness, for each key; a call that a restart dropped is counted |
| `unused` | the number of entries of each key that no call used; a key with 0 is left out |
| `restarted` | `true` after the restart of the driver, else `false` |
| `steps` | every record of the Run stream, in order, of three kinds |

The steps:

- `%{step: :input, input: input}`: the neutral input, with `at_ms`;
- `%{step: :action, occurrence: {r, i}, action: action}`: an admitted action;
- `%{step: :nested, occurrence: {r, i}, schema_id: id, schema_version: v, payload: p}`:
  the start of a nested callable.

No record id, digest, schema name or process appears. The same spec gives the same
record: observed in the tests, not proven.

## The Glue

`Elzoo.RecipeTest.Glue.step/2` is the pattern of the Run and of each nested callable.
Its state is plain data: `%{kind: :agent, to: to, inner: state, content: nil | text}`,
`%{kind: :graph | :decision | :lua, to: to, inner: state}`,
`%{kind: :refused, id: id, schema_id: s, payload: p}` or `%{kind: :closed}`, with `to` of
`:root`, `:node` or `:tool`. With `to: :root` the request of the inner step is given
unchanged. With `to: :node` each `finish` action keeps its `id` and gets the schema
`elzoo.graph-run.node-result`, version 1, and the payload of the first column below. With
`to: :tool` it gets `elzoo.agent-loop.tool-result` and a tool result; other actions are
unchanged. The inner step of `:lua` is `LuaTool.step/2`.

| Child finish | `to: :node` | `to: :tool` |
| --- | --- | --- |
| agent `answered` | `{"gives": {"text": content}}`, with `content` of the last model result | (not used) |
| graph `completed` | `{"gives": gives}` | content `text(gives)` |
| graph other | `{"failed": reason}` | content `[graph failed: REASON]` |
| decision `decided` | `{"gives": {"value": v}}`, and `"choice": v` when `v` is text | (not used) |
| lua `completed` | `{"gives": result}` | content `text(result)` |
| lua other | `{"failed": reason}` | content `[lua tool failed: REASON]` |
| any other status | `{"failed": reason}`; no `gives`, so the graph node is `failed` | |

A tool result is `{"content": marked, "media_type": "text/plain", "encoding": "utf8"}`; the
marked content has `sources` `["recipe-test:lua"]` or `["recipe-test:graph"]`. `refused`
answers `start` with one request of the finish `id <> ":finish"` (schema `s`, version 1,
payload `p`) and becomes `closed`; every other input, and every input of `closed`, is no change
and no request.

Start forms that the harness chooses: an agent child of a node with a skill, as in "Skills"; a
Lua child starts with `elzoo.lua-tool.input` `{"input": arguments}`; a refused child with
`elzoo.graph-run.input` `{"input": arguments}`; an accepted graph child with
`elzoo.graph-run.input` `{"input": object}`. A `:graph` tool that a graph node reaches gets the
refused child with `{"failed": "graph_tool_in_graph"}`. A graph that is not accepted, or
arguments in another form, gets the refused child with the text of `RuntimeGraph.render/1`, or
`[graph not run: REASON]`.

`lua_request/1` gives the sandbox request of a run payload (atom keys, five atom `limits`,
`calls` with `mode`, `names` and `recorded` entries of `name`, `arguments` and `result`).
`lua_reply/1` gives the run result payload of a sandbox reply, every atom key and every atom
other than `nil`, `true` and `false` as a string. `lua_run/4` is the held work: after
`:recipe_test_go` it returns `lua_reply(LuaSandbox.run(executable, lua_request(payload)))`.

`estimate/1` gives `{:ok, %{size: bytes, unit: :tokens, direction: :upper_bound,
estimator_id: "recipe-test-bytes", estimator_version: 1}}`.

## Needs

- PostgreSQL through `ELZOO_TEST_DATABASE_URL`. A test that needs it fails closed and
  is never skipped.
- A test module that starts and stops the repository and the two Registries as above.
- The engine test helper of `assembly/run-engine` with its `effect_bindings` override.
- An allowed Adapter that speaks the message protocol of the driver: the scripted one.
- A script that names every call that `skills` does not answer.
- For a Lua tool: the `lua_source` checkout and a C compiler. The caller builds the sandbox
  once per test module (for example in `setup_all`, with `LuaSandbox.build/2` in a disposable
  directory) and passes the path as `executable`. Manifests must be ones that a module really
  offers.
- For a `:graph` entry: each tool of its `sources` is a tool of the `sources` of the Run, with
  the same source id and name.
- For `skills`: the sources of `Skill.sources(id, package, descriptors)` in `sources`, and the
  `files` and `descriptors` of the same package version in `skills`. The package must be one that
  `RecipePackage.decode/1` accepts.

## Limits

- No network and no provider. A scripted model result is what the author wrote, so
  `structured` and `tool_proposals` are not what a provider or `integration/ai-text`
  would make.
- The clock stays at 2,000 ms: no deadline, Budget expiry or time-based stop is tested.
- Fixed bounds are those of the engine: 256 requests and actions, 64 active occurrences,
  payloads and callable states of 65,536 bytes. The Budget cap of a callable at depth 9 is
  64 and at depth 10 or deeper it is 1, so such a callable cannot make a call and also
  finish.
- No `ask_person`, no approval, no resource, no store of a cut tool result (an agent tool
  result over its `max_bytes` gets the note `store_refused`). A skill load is answered by
  `Elzoo.Skill` and reaches the agent as a declaration, but only for an agent, only for the two
  tools of the `skills.id` source, and a root agent does not start with a skill. A `{:refused, reason}`
  entry for a declared tool is a scripted refusal. With `gate`, a refusal of a declared tool at use
  is the refusal of the engine gate that the test gives, for the principal of the engine test
  helper: it is not a refusal by the Authorization step, by effect class, by a policy of the
  context or by the registry, and the harness checks nothing about the gate. A file read is not
  tied to a loaded skill. A `loop` node fails at its first iteration,
  because no wrapper gives `continue`.
- A Lua run is real: its `wall_ms` is real time, not the clock of the harness. At most 256
  module calls of a Lua tool in a Run, and one restart.
- The harness accepts a text `executable` also when `tools` has no `:lua` entry and does not use
  it then; the spec form names `nil` for that case.
- A restart drops every call and Lua run in flight: an Effect becomes `unknown` and a Lua run
  `failed` with `local_restart`. It shows that the record is read again and that no recorded
  call is asked again, not a restart without loss. A dropped call's task waits until the test
  ends. The engine keeps the Budget reservation of an `unknown` Effect, and a nested child
  whose slots are all settled with such an Effect still gives its finish to its parent, with
  no actual; the group `model_graph_after_restart` shows it.
- The harness does not reserve the `upper_cost` of an accepted graph: the child's Budget is the
  depth rule of the engine. A `:graph` tool reached from a graph node gets
  `{"failed": "graph_tool_in_graph"}`.
- The record is read from the version-1 records of the engine; a later record form needs a
  change here.
