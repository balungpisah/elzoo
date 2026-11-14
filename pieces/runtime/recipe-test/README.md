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
and run by `workflow/graph-run`. One restart of the engine can be asked for.

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
| `executable` | the path of a sandbox executable of `LuaSandbox.build/2`, or `nil` when `tools` has no `:lua` entry |
| `restart_after` | `nil`, or a positive integer: the number of deliveries after which the engine restarts once (below) |

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

- an agent tool: the tool result `{"content": marked text, "media_type": "text/plain",
  "encoding": "utf8"}`, where the text is the value if it is text, else its canonical
  JSON (compact, object keys in byte order);
- a graph tool node: `{"gives": value}`, so `value` must be an object that holds each
  give name of the node, else the node is `failed`;
- a module call of a Lua tool: `{"result": value}`; another class gets `{"reason": reason}`.
  A completed call with another payload ends the tool with `module_call_not_completed`.

An outcome payload over 65,536 bytes of JSON reaches the pattern as class `unknown`
with the reason `outcome_too_large`.

## Start errors

Before any process starts, in this order; the first that fails is the result.

| Error | When |
| --- | --- |
| `:invalid_spec` | `spec` is in another shape, an `executable` that is not text while `tools` has a `:lua` entry, an entry of `tools` in another form, or a `restart_after` that is neither `nil` nor a positive integer |
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

Start forms that the harness chooses: a Lua child starts with `elzoo.lua-tool.input`
`{"input": arguments}`; a refused child with `elzoo.graph-run.input` `{"input": arguments}`; an
accepted graph child with `elzoo.graph-run.input` `{"input": object}`. A `:graph` tool that a
graph node reaches gets the refused child with `{"failed": "graph_tool_in_graph"}`. A graph
that is not accepted, or arguments in another form, gets the refused child with the text of
`RuntimeGraph.render/1`, or `[graph not run: REASON]`.

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
- A script that names every call.
- For a Lua tool: the `lua_source` checkout and a C compiler. The caller builds the sandbox
  once per test module (for example in `setup_all`, with `LuaSandbox.build/2` in a disposable
  directory) and passes the path as `executable`. Manifests must be ones that a module really
  offers.
- For a `:graph` entry: each tool of its `sources` is a tool of the `sources` of the Run, with
  the same source id and name.

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
  result over its `max_bytes` gets the note `store_refused`). A skill load is delivered as
  marked tool text, not as a declaration. A `loop` node fails at its first iteration,
  because no wrapper gives `continue`.
- A Lua run is real: its `wall_ms` is real time, not the clock of the harness. At most 256
  module calls of a Lua tool in a Run, and one restart.
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
