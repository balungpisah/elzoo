# runtime/recipe-test

A recipe author tests a recipe in ExUnit with no provider. `Elzoo.RecipeTest.run/1`
checks a recipe package with `workflow/recipe-check`. Then it runs the recipe end
to end through the real `assembly/run-engine` and the real pattern Pieces
`workflow/agent-loop`, `workflow/graph-run` and `workflow/typed-decision`. The
Run is on disposable PostgreSQL. The model calls and the tool calls go to a
scripted Adapter. There is no network. The clock stays at 2,000 ms. The function
gives back the record of every step.

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

The `window` of an agent names the estimator `recipe-test-bytes`, version 1, unit
`:tokens`. Another window ends the agent with `request_not_built`, as the agent
loop decides. The `request` of a decision holds a text `"model"`.

## The script

A key is `{:model, model}` (the `"model"` of the request of the call) or
`{:tool, alias}` (the `"alias"` of the payload of the tool call). Each entry is
exactly one of:

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
  give name of the node, else the node is `failed`.

An outcome payload over 65,536 bytes of JSON reaches the pattern as class `unknown`
with the reason `outcome_too_large`.

## Start errors

Before any process starts, in this order; the first that fails is the result.

| Error | When |
| --- | --- |
| `:invalid_spec` | `spec` is in another shape |
| `{:invalid_binding, :model \| :tool}` | `Binding.load/1` of the module is not `{:ok, _}`; model first |
| `{:adapter_not_allowed, :model \| :tool}` | the `adapter` of the binding is not in `adapters`; model first |
| `{:invalid_script, key}` | the first key, in ascending term order, that is not a key of the form above, whose list holds an entry of another form, or whose entry holds a value that is not JSON data |
| `{:sources, reason}` | the refusal of `ToolRegistry.snapshot/1` |
| `:invalid_facts` | `RecipeCheck.check/2` gave `{:error, :invalid_facts}` |
| `{:recipe_refused, reasons}` | `RecipeCheck.check/2` refused the recipe |
| `{:unbound_callable, name}` | an `agent` or `decision` callable has no entry for its binding target |
| `{:invalid_callable, name, reason}` | `AgentLoop.new/1`, `TypedDecision.new/1` or `GraphRun.new/1` refuses its spec; `:invalid_spec` when the `request` of a decision has no text `"model"`; `:gives` for a graph with a `call` or `decision` node that calls an agent callable and has a give other than `text`, or calls a decision callable and has a give other than `value` |
| `{:unsupported_tool, alias}` | the first alias, ascending, of a tool of the snapshot whose callable is nested: only adapter tools are bound |
| `:invalid_input` | `input` is not in the form of the root kind |

After the start, an input that the engine refuses gives
`{:error, {:input_refused, reply, record}}`. Also `{:error, {:stalled, record}}`
(not stable or not done after 2,000 polls of 5 ms) and
`{:error, {:halted, reason, record}}` (the engine reports a reconciliation).
An error after the start carries the record as far as it got.

## The record

    %{outcome: outcome, steps: [step], asked: %{key => n}, unused: %{key => n}}

| Field | Meaning |
| --- | --- |
| `outcome` | the `outcome` of `RunEngine.status/1` at the end |
| `asked` | the number of calls that reached the harness, for each key |
| `unused` | the number of entries of each key that no call used; a key with 0 is left out |
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
Its state is plain data: `%{kind: :agent, to: to, inner: state, content: nil | text}` or
`%{kind: :graph | :decision, to: to, inner: state}`, with `to` of `:root` or `:node`.
With `to: :root` the request of the inner step is given unchanged. With `to: :node`
each `finish` action keeps its `id` and gets the schema `elzoo.graph-run.node-result`,
version 1, and this payload; other actions are unchanged.

| Child finish | Payload |
| --- | --- |
| agent `answered` | `{"gives": {"text": content}}`, with `content` of the last model result |
| graph `completed` | `{"gives": gives}` |
| decision `decided` | `{"gives": {"value": v}}`, and `"choice": v` when `v` is text |
| any other status | `{"failed": reason}`; no `gives`, so the graph node is `failed` |

`estimate/1` gives `{:ok, %{size: bytes, unit: :tokens, direction: :upper_bound,
estimator_id: "recipe-test-bytes", estimator_version: 1}}`.

## Needs

- PostgreSQL through `ELZOO_TEST_DATABASE_URL`. A test that needs it fails closed and
  is never skipped.
- A test module that starts and stops the repository and the two Registries as above.
- The engine test helper of `assembly/run-engine` with its `effect_bindings` override.
- An allowed Adapter that speaks the message protocol of the driver: the scripted one.
- A script that names every call.

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
- Later change in place: ELZ-183 adds a nested tool, a tool written in Lua, a graph that a
  model gives and a restart.
- The record is read from the version-1 records of the engine; a later record form needs a
  change here.
