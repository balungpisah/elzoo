# ELZ-181 — Run a recipe against scripted models and tools, through the real engine

## Scope and reuse

- Dependencies: ELZ-033, ELZ-114, ELZ-127, ELZ-136, ELZ-137, ELZ-139, ELZ-141, ELZ-142, ELZ-161, ELZ-164, ELZ-167, ELZ-168, ELZ-172, ELZ-180
- Output: `runtime/recipe-test`: the compiled modules `Elzoo.RecipeTest.ScriptedAdapter`, `Elzoo.RecipeTest.ModelBinding`, `Elzoo.RecipeTest.ToolBinding` and `Elzoo.RecipeTest.Glue`, and the test helper module `Elzoo.RecipeTest` with one public function `run/1`; release V1B; first portion of RC-66.
- Change class: Piece-only implementation; small local gate and hosted `check-piece`.
- Owned paths: `pieces/runtime/recipe-test/**` and its index/generated changes under AGENTS.md section 3.

Admit the first portion of RC-66. A recipe author tests a recipe in ExUnit
without a provider. `Elzoo.RecipeTest.run/1` takes a recipe package, a
script of model and tool results and the host configuration of the
callables. It checks the recipe with `workflow/recipe-check`, runs it end to
end through the real `assembly/run-engine` and the real pattern Pieces
`workflow/agent-loop`, `workflow/graph-run` and `workflow/typed-decision`
on disposable PostgreSQL, with scripted Adapters, no network and a clock
that does not move, and gives back the record of every step. Only Adapters
from the allow-list of the caller are accepted.

Coordinator decision, 2026-11-14: RC-66 is published as two tasks. This
task is the host, the driver, the script, the record, the Adapters and the
glue of agent, decision and graph callables. ELZ-183 changes this Piece in
place after this task merges (AGENTS.md section 4) and adds the glue of a
tool written in Lua, of a graph that a model gives, and a restart. RC-66 is
complete only when ELZ-183 merges. The harness is also the host glue that
a mixed recipe needs and that no ready Piece has: the engine bindings, a
wrapper step that turns the finish of a nested child into the result form
of its parent, and the `estimate` function of the agent loop.

Implement only the acceptance groups below. Use the public functions of the
reused Pieces as they are on main. Add no option, no retry, no person
answer, no store of large tool results, no moving clock, no restart, no
behaviour or hook. Edit no ready Piece, shared path, pin or CI file. No
fixtures directory is needed: each test writes its package and script as
literals.

## Facts checked on main

Confirm each when you start. A fact marked "the task ELZ-180" is read from
that task's text and must be confirmed after it merged; if one differs,
stop and ask.

- `assembly/run-engine` (ELZ-127, ELZ-172), `lib/elzoo/run_engine.ex`:
  - `start_link/1` checks its options in `init/1` (about line 994); unknown
    keyword keys are not read. `pattern` is `{module, function,
    initial_state}`; each callable is called as `apply(module, function,
    [state, input])` (`invoke/3`, about line 713). A next state over 65,536
    bytes or not plain data is classified `:invalid_pattern_state` and the
    request is not admitted. Plain data includes atoms and tuples. A
    request is admitted only while the Run has at most 64 active
    occurrences and 256 lifetime actions (about line 801).
  - `input/4` refuses a neutral input that already holds `"at_ms"` (about
    line 1189); it adds `at_ms` from the clock. An outcome input holds
    `"type"`, `"version": 1`, `"kind": "action_outcome"`, `"action_id"`,
    `"outcome"`, `"schema_id"`, `"schema_version"`, `"payload"`.
  - Every action goes through the precheck, the gate and Budget
    reservation; the estimate must be a positive integer (`amount?/1` of
    `workflow/budget`; there is no upper bound). The `:admission` record
    holds the binding facts merged with `action: action` (about line 1586).
  - `nested_callable`: `binding.nested.(action)` gives `budget_id`,
    `incarnation`, `mfa: {module, function}`, `initial_state` (at most
    65,536 bytes, else refused `nested_input`), `schema_id`,
    `schema_version` and `payload` of the child's start input; these facts
    are committed in a `:nested` record (about line 1721) and the engine
    reads `mfa` and `initial_state` from it (about line 318). The child's
    Budget cap is the estimate of the parent action (about line 315); the
    parent slot is `:running` while the child runs. The child's start input
    reaches the child by an asynchronous send of the Outbox item, so for a
    moment the parent slot is `:running` and the child has asked for
    nothing yet.
  - `model_call` and `tool_call` are Effects: `intent/3` takes
    `Map.fetch!(s.opts.effect_intent, descriptor.binding)` (about line
    1887), `check_binding/2` checks the digest of the loaded binding and
    the tenant, and the engine calls `EffectIntent.advance(owner,
    :dispatch)` (about line 1813); an EffectIntent that does not arm is
    refused `not_sent`. The outcome reaches the pattern only when the host
    gives it with `input/4` and the context fields `occurrence`, `actual`
    and `dispatch`; `input/4` settles the slot before it replies.
  - `checked_ingress/3`: an outcome whose schema differs from the `result`
    of the binding, or whose payload is over 65,536 bytes of JSON, becomes
    `invalid_outcome` with class `unknown` for an Effect (about lines
    1277-1282); an input over 262,144 bytes is refused at ingress.
    `settle_budget/4` takes an integer `actual` >= 0; 0 releases the
    reservation. The join sees a `failed` outcome as failed only with
    `dispatch: "dispatched"`, else as unknown (`envelope_class/2`). A
    `refused` or `unknown` outcome of an Effect settles like a completed
    one (`bot_run_lifecycle.ex` about 158-166; `run_engine.ex` 607-645).
  - A root `finish` completes the Run only when its payload `action_id`
    names a settled completed action of the same Attempt; otherwise it is
    refused `completion_evidence`. A nested finish reaches the parent when
    its `{schema_id, schema_version}` equals the `result` of the parent's
    binding, else the parent fails `nested_result_invalid` (about line
    1947).
  - `status/1` gives `%{run_id, attempt_id, phase, outcome, request_cap,
    request_count, generation_closed, stop_pending, classification, slots,
    joins, reconciliation}`; `slots` maps an occurrence `{request, index}`
    to `action_id`, `kind`, `phase`, `outcome`, `verdict`,
    `reconciliation`. The request ordinal is shared by all callables.
- The task ELZ-180: the value of `bindings` for an action kind is one
  binding (a map with the atom key `:id` and no binary key) or a schema
  map (at least one entry; each key a `schema_id`, UTF-8 text of 1 to 200
  bytes with no NUL; each value a binding); the engine chooses by the
  action's `schema_id` only; an unmapped schema is refused
  `missing_binding`; the precheck refuses a schema that is not in
  `schemas` first, as `payload_schema`. `fixture/1` takes the override
  `effect_bindings`, a map from a binding reference (UTF-8 text) to
  `{binding_module, adapter_context}`, merged into the default
  `%{"effect" => {TestBinding, self()}}`; for each entry it builds the
  startup options as for `"effect"` (`binding:` the module, a Store of
  `TestRepo` in the fixture's schema with `EffectIntent.fold(module)` and
  `EffectIntent.limits()`, the one `clock`, `host` and `task_supervisor`,
  and the given `adapter_context`), gives the one map to the Run owner and
  to the engine as `effect_intent`, and removes `effect_bindings` from the
  overrides.
- The engine test helper `test/support/run_engine_test_helper.exs` (listed
  in the `files` of the Piece) requires the SQL test helper with a
  sibling-or-repository fallback. `database/0` matches `{:ok, pid} =
  TestRepo.start_link(...)` from `ELZOO_TEST_DATABASE_URL` (about line
  220) and fails when it is missing or unreachable. `fixture/1` creates a
  schema `engine_<16 hex>`, the DurableUnit Store, DynamicUnits,
  Task.Supervisor, AsyncWork, the Run owner with one Attempt, the evidence
  Writer, a clock Agent at 2,000 ms that nothing moves, an allow-all gate,
  a context whose policy allows the effect classes `compute` and
  `publish`, and the default `bindings` and `schemas`. Its `on_exit` drops
  the schema. It needs the Registries `Elzoo.RunEngine.TestRegistry` and
  `Elzoo.RunEngine.UnitRegistry`. The engine's own test module starts
  `database/0` and both Registries in `setup_all` with `{:ok, _} =` and
  stops them in `on_exit` (`run_engine_test.exs` 19-25). `start/2` starts
  the engine with `c.opts` merged with the overrides; `verified/1` gives
  the context `run_id: "run"`, `attempt_id: "attempt"`, `pause_deadline:
  50_000`. The completed envelope of its test Adapter holds `"version"`,
  `"message_id"`, `"correlation_id"`, `"attempt_id"`, `"outcome"`,
  `"dispatch"`, `"value"`, `"value_schema_id"`, `"value_schema_version"`.
  The full check runs every Piece's tests in one VM (`test_paths: ["test",
  "pieces"]`).
- On the allow path the engine checks only the digest and the tenant of an
  intent; the Run owner reads its EffectIntent map only for an approved
  (ASK) intent (`run_approval_release.ex` 478-494).
- `delivery/effect-intent`: a binding module `use`s
  `Elzoo.EffectIntent.Binding` with `adapter`, `id`, `provider_account`,
  `operation`, `clock` and `failures` (the failure mapping belongs to the
  binding, `binding.ex` 39-57; its keys equal the Adapter's
  `failure_tags/0`); the Adapter exports `failure_tags/0`, `schema/0`,
  `validate/2`, `send_effect/1`, `poll/1`, `authenticate/2`,
  `validate_result/2`. Arming needs `schema/0` to give the recorded schema
  text and `validate/2` to give `:ok` (`effect_intent.ex` 177-180).
  `Binding.load/1` gives `{:ok, descriptor}` (with `adapter`, `id`,
  `provider_account`, `operation`, `digest`) or `{:error, :binding}`.
  `send_effect/1` runs in a Task; its request holds `key`, `attempt_id`,
  `arguments` and `context` (the `adapter_context` of the startup entry).
  Arguments are at most 65,536 bytes; an identity is 5 texts of 1 to 256
  bytes.
- `state/event-log`: `Elzoo.DurableLog.read(store, stream, from, limit)`
  gives `{:ok, rows, head}`. The engine commits each record with
  `DurableUnit.step/3` (`commit/3`), so it is a row of kind `"input"` that
  holds `{1, {id, record}}` as ETF; the engine tests read it with
  `:erlang.binary_to_term(payload, [:safe])`. A retained duplicate input
  id appends nothing (`durable_unit.ex` 135-142).
- `workflow/agent-loop` (ELZ-142): `new/1` takes exactly `id`, `model`,
  `max_output_tokens`, `role_instructions`, `window`, `max_request_bytes`,
  `max_image_refs`, `sources`, `result_limits`, `ask`, `turn_limit`, and
  gives `{:ok, state}` or `{:error, :invalid_spec | {:sources, reason} |
  :state_too_large}`. `step/3` takes `estimate`, the arity-1 function of
  `PromptAssembly.build/2`, which gives `{:ok, %{size, unit: :tokens,
  direction, estimator_id, estimator_version}}` whose estimator fields
  equal those of `window`. Payload keys: model call `elzoo/ai-text-request`
  (the request holds `"model"`), model result `elzoo.ai-text.result`,
  start `elzoo.agent-loop.message` `{"text"}`, tool action
  `elzoo.agent-loop.tool-call` `{alias, source, tool, version, arguments}`
  (kind `tool_call` for an adapter tool, `nested_callable` for a nested
  one), tool result `elzoo.agent-loop.tool-result`, store action
  `elzoo.tool-result-limit.store`, ask `elzoo.agent-loop.ask`, finish
  `elzoo.agent-loop.result` `{status, reason, action_id, turns}`. An
  `answered` finish names the model call whose `content` is the answer; the
  content is not copied. A tool outcome that is not completed is read only
  for its class and an optional `"reason"` in `[a-z0-9_]{1,64}`. Model
  call `N` is `id:m:N`; a malformed proposal is left out with a note line.
  A skill is loaded only from a declaration of a `pinned_skill` source.
- `workflow/tool-result-limit` (ELZ-139): a tool result is exactly
  `{"content": marked_map, "media_type", "encoding"}`.
  `workflow/untrusted-content` (ELZ-137): a marked map is exactly
  `schema_id` `elzoo.untrusted-content.marked`, `schema_version` 1,
  `sources` (1 to 16 texts of `[A-Za-z0-9._:/@-]`), `trust`, `max_bytes`
  (1 to 16,777,216) and `content`.
- `workflow/graph-run` (ELZ-168): `new/1` takes exactly `id` (1 to 64
  bytes, no `":"`), `recipe`, `callable`, `sources`, `maps` (an entry
  `%{concurrency: 1..64, on_item_failure: :fail | :partial}` for each map
  node) and `max_open` (1 to 64); errors `{:recipe, reason}`,
  `:unknown_callable`, `{:sources, reason}`, `{:unknown_tool, node}`,
  `:invalid_spec`, `:state_too_large`. Start `elzoo.graph-run.input`
  `{"input": object}`; call action `nested_callable`
  `elzoo.graph-run.call` `{"callable", "input"}`; tool action
  `elzoo.graph-run.tool-call` (kind `tool_call` or `nested_callable`); ask
  `elzoo.graph-run.ask`; every node result `elzoo.graph-run.node-result`,
  version 1: a completed payload whose `"gives"` is a map that holds every
  give name of the node (`graph_run.ex` 422-431), `"choice"` for a
  decision action, `"continue"` for a loop iteration; another form makes
  the node `failed`. Finish `elzoo.graph-run.result` `{status, reason,
  node, action_id, gives}`. Node action `id:n:N`.
- `workflow/typed-decision` (ELZ-141): `new/1` takes exactly `id`,
  `request` (a map with a `"messages"` list and no `"output_schema"`; a
  `"model"` member is not required, `typed_decision.ex` 227-230), `port`,
  `answer` (`{:set, members}` or `{:schema, schema}`), `repairs` (0 to 8);
  errors `:invalid_set`, `:invalid_schema`, `:invalid_spec`. It does not
  read the start payload. Calls `id:call:0`, `id:call:1`, ... of kind
  `model_call`; a repair adds `{"role": "assistant", "text"}` and
  `{"role": "user", "text"}` messages. A completed result is read for
  `content`, `structured` (`null`, `{"valid": v}` or `{"invalid":
  "missing" | "schema_mismatch" | "invalid_json"}`) and `finish`. A repair
  needs finish `"stop"`, non-blank content, `structured` not valid,
  content that is not schema-valid JSON and repairs left; a valid
  `structured` with other content is `validator_disagreement`;
  `structured: null` ends as `malformed_result` (`output_repair.ex`
  10-31, 80-85). A set answer is `{"answer": member}`
  (`typed_decision.ex` 97-106). Finish `elzoo.typed-decision.result`:
  `{"status": "decided", "value", "repairs", "action_id"}` or
  `{"status": "failed", "reason", ...}`; its id is `id:finish`.
- `workflow/recipe-check` (ELZ-167): `check(package, facts)` with the facts
  keys `tools`, `provided_needs`, `granted_permissions`,
  `tool_requirements`, `unit`, `costs`, `cap` gives `{:ok, verdict}`,
  `{:refused, reasons}` or `{:error, :invalid_facts}`.
- `domain/recipe-package` (ELZ-164): `graph` is the recipe-graph map of
  the package. `domain/recipe-graph` (ELZ-161): a callable has `name`,
  `kind` (`graph`, `agent`, `decision`), `input`, `output` (each `{port,
  schema}`); `agent` and `decision` add `binding`, `decision` adds
  `choices`; `bindings` are `{name, target}` maps; `root` names a
  callable; a node has `gives`, a list of slots with a `name`; a `tool`
  node holds the alias of its tool; nesting is at most 16
  (`recipe_graph.ex` 345-360).
- `workflow/tool-registry` (ELZ-136): `snapshot/1` gives `{:ok, snapshot}`
  or `{:error, reason}`; `resolve/2` takes an alias and a resolved tool has
  `callable: {:adapter | :nested, source_id, name}`.

## Interface: `Elzoo.RecipeTest.run(spec)`

The caller is an ExUnit test module (`async: false`) that loads the helper
file of this Piece with `Code.require_file`. Its `setup_all` starts
`database/0` of the engine helper and the Registries
`Elzoo.RunEngine.TestRegistry` and `Elzoo.RunEngine.UnitRegistry` (`keys:
:unique`), unlinked, and stops them in `on_exit`, as `run_engine_test.exs`
19-25 does: the engine suite runs in the same VM and starts them itself.
`run/1` neither starts nor stops them. `run/1` runs inside a test, because
it starts its processes with `ExUnit.Callbacks.start_supervised!`; it links
no process to the test process, so the caller need not trap exits. It
returns `{:ok, record}` or `{:error, reason}`.

`spec` is a map with exactly these atom keys:

- `package`: the neutral recipe package map of `domain/recipe-package`.
- `facts`: the facts of `RecipeCheck.check/2` without `"tools"`; the
  harness adds `"tools"`, the snapshot of `sources`.
- `sources`: the operand of `ToolRegistry.snapshot/1`: the tools of every
  agent and graph callable of the recipe.
- `agents`: a map from the binding target of each `agent` callable to
  exactly `model`, `max_output_tokens`, `role_instructions`, `window`,
  `max_request_bytes`, `max_image_refs`, `result_limits`, `turn_limit`.
  The harness adds `id`, `sources` and `ask: nil`. The `window` names the
  estimator `recipe-test-bytes`, version 1, unit `:tokens`; another window
  ends the agent with `request_not_built`, as the agent loop decides.
- `decisions`: a map from the binding target of each `decision` callable
  to exactly `request` and `repairs`. The harness adds `id`, `port` (the
  `port` of the callable's `output`) and `answer: {:set, choices}`.
- `script`: a map from a key to an ordered list of results (below).
- `effects`: exactly `%{model: module, tool: module}`, the EffectIntent
  binding modules of model calls and of tool calls.
- `adapters`: the allow-list, a list of Adapter modules.
- `input`: the input of the Run: an object for a `graph` or `decision`
  root, non-empty text for an `agent` root.

### The script

A key is `{:model, model}` (the `"model"` of the request of the call) or
`{:tool, alias}` (the `"alias"` member of the tool call's payload). Each
entry is exactly one of:

- `{:completed, value}`. For a model call `value` is the payload of the
  outcome, in the form `elzoo.ai-text.result` that the patterns read
  (`content`, `finish`, `tool_proposals`, `structured`); it must be a map
  and is given unchanged. For a tool call `value` is the plain value that
  the tool gave; the harness puts it in the form of the caller (below).
  For a graph tool node it must be an object that holds each give name of
  the node, else the node is `failed`.
- `{:failed, reason}`, `{:refused, reason}`, `{:unknown, reason}`, with a
  reason that matches `[a-z0-9_]{1,64}`. `{:unknown, "timeout"}` is a call
  that timed out; no time passes.

The entries of a key are used in order, one for each call of that key, in
the order in which the harness delivers calls. A call whose key has no
entry left is an explicit failure: `run/1` stops and returns
`{:error, {:unscripted_call, key, record}}`. No call ever gets a default.
An entry that no call used is not an error: it is counted in
`record.unused`, and the README tells the author to assert on it.

An outcome payload over 65,536 bytes of JSON reaches the pattern as
`invalid_outcome` with class `unknown`; an outcome input over 262,144
bytes is refused by the engine and `run/1` returns `input_refused`.

### Checks at start

Before any process starts, in this order; the first that fails is the
result:

1. `:invalid_spec`: `spec` in another shape.
2. For `:model`, then `:tool`: `{:invalid_binding, which}` when
   `Binding.load/1` of the module is not `{:ok, _}`, and
   `{:adapter_not_allowed, which}` when its `adapter` is not in
   `adapters`.
3. `{:invalid_script, key}` for the first key, in ascending term order,
   that is not a key of the form above, whose list holds an entry of
   another form, or whose entry holds a value that is not JSON data
   (string-keyed maps, lists, texts, numbers, booleans, `nil`).
4. `{:sources, reason}`: the `{:error, reason}` of
   `ToolRegistry.snapshot(sources)`.
5. `:invalid_facts` and `{:recipe_refused, reasons}`: the results of
   `RecipeCheck.check(package, facts)` that are not `{:ok, _}`.
6. For each callable of the recipe, in recipe order:
   `{:unbound_callable, name}` when an `agent` or `decision` callable has
   no entry for its binding target; `{:invalid_callable, name, reason}`
   when `AgentLoop.new/1`, `TypedDecision.new/1` or `GraphRun.new/1` (with
   the id `d1`, and `recipe` the package's `graph`) refuses its spec;
   `{:invalid_callable, name, :invalid_spec}` when the `request` of a
   decision has no text `"model"`; `{:invalid_callable, name, :gives}` for
   a `graph` callable with a `call` or `decision` node that calls an agent
   callable and has a give other than `text`, or that calls a decision
   callable and has a give other than `value`.
7. `{:unsupported_tool, alias}` for the first alias, ascending, of a tool
   of the snapshot whose callable is `{:nested, _, _}`: this task binds
   adapter tools only.
8. `:invalid_input`: `input` not in the form of the root kind.

### The host

`run/1` calls `fixture/1` with exactly the override `effect_bindings:
%{"recipe-test-model" => {model_module, self()}, "recipe-test-tool" =>
{tool_module, self()}}` (the modules of `effects`; `self()` is the test
process, the driver), so the fixture's `"effect"` entry stays beside them.
It starts the engine with `start/2` and exactly these overrides:

- `pattern: {Elzoo.RecipeTest.Glue, :step, root_state}`.
- `schemas`: those of the fixture and, each at version 1 with the JSON
  Schema `{"type": "object"}` built as the fixture builds its own:
  `elzoo/ai-text-request`, `elzoo.ai-text.result`,
  `elzoo.agent-loop.message`, `elzoo.agent-loop.tool-call`,
  `elzoo.agent-loop.tool-result`, `elzoo.agent-loop.result`,
  `elzoo.graph-run.input`, `elzoo.graph-run.call`,
  `elzoo.graph-run.tool-call`, `elzoo.graph-run.node-result`,
  `elzoo.graph-run.result`, `elzoo.typed-decision.result`,
  `elzoo.recipe-test.input`.
- `bindings`: `"finish"` is the fixture's binding, unchanged. Each other
  binding has `version: 1`, the `proposal` of the fixture's `"finish"`
  binding and the `facts` below:
  - `"model_call"`: id `recipe-test.model`, class `publish`, result
    `elzoo.ai-text.result`.
  - `"tool_call"`: a schema map, class `publish`:
    `elzoo.agent-loop.tool-call` (id `recipe-test.tool.agent`, result
    `elzoo.agent-loop.tool-result`) and `elzoo.graph-run.tool-call` (id
    `recipe-test.tool.graph`, result `elzoo.graph-run.node-result`).
  - `"nested_callable"`: a schema map, class `compute`:
    `elzoo.graph-run.call` (id `recipe-test.nested.call`, result
    `elzoo.graph-run.node-result`), with `nested` below.
  No `local_work`, `ask_person`, resource or store binding exists: such an
  action is refused by the engine's precheck.
- `request_cap: 256`; `budget: %{cap: 2^62, unit: "credits", id:
  "budget", incarnation: "sealed"}`.

Then `run/1` gives the start: `RunEngine.input(engine, "rt:start", start,
verified())` with `start` = `{"type": "input", "version": 1, "kind":
"start", "schema_id", "schema_version": 1, "payload"}` in the form of the
root pattern (below). A reply other than `{:ok, :applied}` is
`{:error, {:input_refused, reply, record}}`.

**Facts of an action.** `%{estimate: e, unit: "credits", deadline_ms:
40_000}`; for `model_call` and `tool_call` also `intent: %{identity:
["tenant", provider_account, binding_id, operation, action_id], arguments:
json, binding: reference, binding_digest: digest, deadline_ms: 40_000}`
from the descriptor of the binding module and its reference, with `json`
the compact JSON of `{"action_id", "key", "schema_id"}` (`key` as
`["model", m]` or `["tool", alias]`). `e` is 1, except for a
`nested_callable` action of a callable at depth `k`: `2^max(0, 62 - 7k)`.
So a child of depth `k + 1` has the cap `2^(62 - 7k)`, which holds 64
children of its own and every action they make, down to depth 8.

**Depth and ids.** The root callable has the id `d1`. A child of an action
of a callable at depth `k` has the id `"d" <> (k + 1) <> "x" <>` the first
24 lowercase hex characters of the SHA-256 of the parent action id. Every
action id of a pattern begins with the id of its callable and `":"`, so the
depth of an action is the number after `d` in its id. A child's Budget is
`"b" <>` the same 24 characters, incarnation `"sealed"`. Two runs of one
spec give the same ids.

**The `nested` function** (`elzoo.graph-run.call`): `nested.(action)`
gives `budget_id` and `incarnation` as above, `mfa: {Elzoo.RecipeTest.Glue,
:step}`, `initial_state` the Glue state of the named callable of the
recipe with `to: :node`, `schema_version: 1`, and by the kind of that
callable: a `graph` gets `schema_id` `elzoo.graph-run.input` and payload
`{"input": input}`; an `agent` gets `elzoo.agent-loop.message` and
`{"text": canonical JSON of input}`; a `decision` gets its base `request`
with one more message `{"role": "user", "text": canonical JSON of input}`
and the start `elzoo.recipe-test.input` `{"input": input}`. The root gets
the same forms from `spec.input` with `to: :root`, except that a root
agent gets `{"text": input}`. Canonical JSON is the compact Jason text
with object keys sorted by bytes (a private function; no shared one
exists). Each `graph` gets `recipe` the package's `graph`, `maps` with
`%{concurrency: 1, on_item_failure: :fail}` for each map node and
`max_open: 64`.

### The Adapter and the binding modules

`ScriptedAdapter`: `failure_tags/0` gives `[:timeout]`; `schema/0` gives
`"recipe-test-v1"`; `validate/2`, `authenticate/2` and
`validate_result/2` give `:ok`; `poll/1` gives `{:unavailable,
"scripted"}`. `send_effect(request)` sends `{:recipe_test_call, self(),
request}` to `request.context` and waits. On `{:recipe_test_reply,
:completed}` it gives the envelope `%{"version" => 1, "message_id" =>
request.key, "correlation_id" => request.key, "attempt_id" =>
request.attempt_id, "outcome" => "completed", "dispatch" => "dispatched",
"value" => %{}, "value_schema_id" => "elzoo.recipe-test.ack",
"value_schema_version" => 1}`; on `{:recipe_test_reply, :other}` it gives
`{:error, :timeout, :unavailable}`.

`ModelBinding`: `use Elzoo.EffectIntent.Binding` with `adapter:
Elzoo.RecipeTest.ScriptedAdapter`, `id: "recipe-test-model"`,
`provider_account: "scripted"`, `operation: "call"`, `clock: "unix-ms"`,
`failures: %{timeout: {"timed_out", "unknown", "unavailable"}}`.
`ToolBinding`: the same with `id: "recipe-test-tool"`.

### The driver

A call is **held** from its message until the harness answers it. A slot
of `status/1` is quiet when its phase is `:settled`, when it is a
`nested_callable` slot in phase `:running`, or when its action is held.
The Run is **stable** when every slot is quiet. The harness polls
`status/1` every 5 ms; not stable or not done after 2,000 polls is
`{:error, {:stalled, record}}`, and a `reconciliation` that is not `nil`
is `{:error, {:halted, reason, record}}`.

The loop, at each stable point:

1. If the `outcome` of `status/1` is not `nil`, or nothing is held and
   every slot is `:settled`, the Run is done: `{:ok, record}`. If nothing
   is held and a `nested_callable` slot is `:running` (a child whose start
   has not arrived yet), poll again.
2. Else take the held call with the smallest occurrence and the next entry
   of its key (none: `:unscripted_call`). Give the outcome with
   `RunEngine.input/4`, id `"rt:" <>` 32 hex of the SHA-256 of the action
   id, context `verified/1` with `occurrence`, `actual: 0` and `dispatch`
   `"dispatched"` (completed, failed), `"not_dispatched"` (refused) or
   `"unknown"` (unknown). A reply other than `{:ok, :applied}` is
   `{:error, {:input_refused, reply, record}}`. `input/4` settles the slot
   before it replies. Then answer the Adapter.

The outcome is the neutral outcome input with `"version": 1`, the action
id, the class as `"outcome"`, the `result` schema of the action's binding
(version 1) and the payload: for a completed model call the entry's value;
for a completed tool call, by the action's schema, `{"gives": value}`
(graph tool node) or the tool result `{"content": marked(text(value)),
"media_type": "text/plain", "encoding": "utf8"}` (agent tool); for another
class `{"reason": reason}`. `marked(t)` is the marked map with `sources
["recipe-test:tool"]`, `trust "untrusted"`, `max_bytes 16_777_216` and
`content t`; `text(v)` is `v` for text, else its canonical JSON.

The scripted calls cost nothing (`actual: 0`).

### The record

`%{outcome: outcome, steps: [step], asked: %{key => n}, unused: %{key =>
n}}`. `outcome` is that of `status/1` at the end. `asked` counts the calls
that reached the harness for each key. `unused` counts the entries of each
key that were not used (keys with 0 are left out). `steps` reads every row
of kind `"input"` of the Unit stream (`DurableLog.read/4` in pages of
1,000, in sequence order) and keeps, in that order:

- `%{step: :input, input: input}` for a `:protocol` record (`input` the
  neutral input with `at_ms`);
- `%{step: :action, occurrence: {r, i}, action: action}` for an
  `:admission` record;
- `%{step: :nested, occurrence: {r, i}, schema_id: id, schema_version: v,
  payload: p}` for a `:nested` record.

No record id, digest, schema name or process appears. An error after
start carries the record as far as it got.

## Interface: `Elzoo.RecipeTest.Glue`

`step(state, input)` returns `{:Transition, state, :none | {:some,
request}}`. The state is plain data:

- `%{kind: :agent, to: to, inner: agent_state, content: nil | text}`,
- `%{kind: :graph | :decision, to: to, inner: state}`,

with `to` `:root` or `:node`. The inner step is `AgentLoop.step(inner,
input, &Glue.estimate/1)`, `GraphRun.step/2` or `TypedDecision.step/2`.
For `:agent`, a completed `action_outcome` of schema
`elzoo.ai-text.result` whose `content` is text sets `content` before the
inner step.

With `to: :root` the inner request is given unchanged. With `to: :node`
each action of kind `finish` keeps its `id` and gets the schema
`elzoo.graph-run.node-result`, `schema_version` 1 and this payload; other
actions are unchanged:

| Child finish | Payload |
| --- | --- |
| agent `answered` | `{"gives": {"text": content}}` |
| graph `completed` | `{"gives": gives}` |
| decision `decided` | `{"gives": {"value": v}}`, and `"choice": v` when `v` is text |
| any other status | `{"failed": reason}` |

A `failed` payload holds no `gives`, so the graph node is `failed`.

`estimate(bytes)` gives `{:ok, %{size: byte_size(bytes), unit: :tokens,
direction: :upper_bound, estimator_id: "recipe-test-bytes",
estimator_version: 1}}`.

## Host Needs and Limits

Fixed bounds: those of the engine (256 requests and 256 actions in a Run,
64 active occurrences, payloads of 65,536 bytes, callable states of 65,536
bytes); the Budget rule above; 2,000 polls of 5 ms.

Needs: PostgreSQL through `ELZOO_TEST_DATABASE_URL` (fail closed; a test
that needs it is never skipped); a test module that starts and stops the
repository and the Registries as above; the engine test helper with the
override of ELZ-180: in a copied consumer it is a sibling of this Piece's
helper (the export writes each Piece file at its Piece-relative path), in
the repository it is `../../../../assembly/run-engine/test/support/` from
this Piece's `test/support/`; an allowed Adapter that speaks the message
protocol of the driver; a script that names every call.

Limits: `run/1` is a function of this Piece's test helper
(`test/support/recipe_test_helper.exs`), loaded with `Code.require_file`,
because it builds the host with the `.exs` helper of `assembly/run-engine`;
only the Adapter, the binding modules and the glue are compiled. No
network and no provider: a scripted model result is written by the author,
so `structured` and `tool_proposals` are what the script says, not what a
provider or `integration/ai-text` would make. The clock stays at 2,000 ms:
no deadline, Budget expiry or time-based stop is tested. No nested tool
(ELZ-183), no `ask_person`, no approval, no store of a cut tool result (an
agent tool result over its `max_bytes` gets the note `store_refused`, as
the agent loop decides), no resource, no restart (ELZ-183). A skill load
is delivered as marked tool text, not as a declaration: skills are not
tested through this harness. A `loop` node fails at its first iteration,
because no wrapper gives `"continue"`. A recipe may nest 16 deep, but with
the Budget rule a callable at depth 9 has the cap 64 and one at depth 10
or deeper the cap 1, so it cannot make a call and also finish. The same
record for the same spec is observed, not proven: every commit happens
inside the engine process and deliveries come one at a time in occurrence
order. The record is read from the engine's version-1 records; a later
record form needs a change here. The wrapper keeps the last model content
beside the agent state, inside the engine's state bound. Telemetry, Config
and Control are not applicable: a test harness with no observation, no
ambient settings and no lifecycle beyond one call.

The manifest declares `kind: owned`, the providers that the reuse needs,
and the Piece dependencies `assembly/run-engine`, `workflow/agent-loop`,
`workflow/graph-run`, `workflow/typed-decision`, `workflow/recipe-check`,
`workflow/tool-registry`, `workflow/pattern-step`,
`delivery/effect-intent`, `state/event-log` and `integration/sql`. Its
`files` list the compiled modules, the helper
`test/support/recipe_test_helper.exs` and the test files.

## Named acceptance groups

The database groups run on PostgreSQL with `ELZOO_TEST_DATABASE_URL`, fail
closed and are never skipped. The suite starts at most 9 Runs; groups 1
and 8 start none.

1. **`start_refusals`** (no database): each start error of the list, from
   one valid spec changed in one place; with both an Adapter outside the
   list and an invalid script, the result is `adapter_not_allowed`; with
   both an unknown tool in the recipe and an unbound callable, it is
   `recipe_refused`.
2. **`adapter_allow_list`**: `adapters: []` gives
   `{:adapter_not_allowed, :model}`; `adapters:
   [Elzoo.RecipeTest.ScriptedAdapter]` with a tool binding module of the
   test over another Adapter gives `{:adapter_not_allowed, :tool}`; in both
   the count of `engine_` schemas in PostgreSQL is the same before and
   after and `Registry.count(Elzoo.RunEngine.TestRegistry)` is 0; the same
   spec with the scripted bindings runs to `completed`.
3. **`agent_with_tools`**: a root agent. Model turn 1 proposes four tools
   and one proposal with `malformed: "schema_mismatch"`; the tools give
   `completed`, `{:failed, "broken"}`, `{:unknown, "timeout"}` and
   `{:refused, "denied"}`; turn 2 answers. The Run is `completed`; the
   steps hold four tool actions (none for the malformed proposal), their
   outcomes with those four classes, and model call 2 whose payload holds
   `[tool call not completed: unknown: timeout]` and the note of the left-
   out proposal; `unused` is empty.
4. **`decision_repair`**: a root decision with the choices `yes` and `no`
   and `repairs: 1`. Turn 1: finish `stop`, content `{"answer":"maybe"}`,
   `structured` `{"invalid":"schema_mismatch"}`; turn 2: finish `stop`,
   content `{"answer":"yes"}`, `structured` `{"valid":{"answer":"yes"}}`.
   The finish is `decided` with `yes` and `repairs` 1; call `d1:call:1`
   holds the two repair messages; the Run is `completed`.
5. **`graph_with_children`**: a root graph whose first node calls an agent
   callable (give `text`), whose decision node calls a decision callable
   with two routes (give `value`), and whose chosen branch is a tool node
   with an adapter tool whose value is an object with the node's gives.
   The agent child's answer reaches the decision as the give `text`; the
   decision's `choice` picks the branch; the tool value becomes the node's
   gives; the Run is `completed` with the gives of the graph; the other
   branch has no action.
6. **`same_spec_same_record`**: the spec of group 3 run twice gives two
   equal records.
7. **`unscripted_call`**: a model that proposes a tool whose key has no
   entry gives `{:error, {:unscripted_call, {:tool, alias}, record}}`; the
   record has the tool action and no outcome for it; a model key with one
   entry and a second model call gives the error with `{:model, m}`. A
   spec with one entry more than the calls ends `{:ok, record}` with that
   entry in `unused`.
8. **`glue_forms`** (no database): `Glue.step/2` folded over literal
   traces gives each row of the conversion table, the content of the last
   model result for `answered`, and the unchanged root request;
   `estimate/1` gives its value.

## Evidence and gate

Test: the eight groups, with the database groups named as such in
`piece.json`. Upstream: the Contracts of the reused Pieces, scoped as they
state them; this Piece proves nothing about them. No Cure module: the
harness holds no pure decision with a meaningful law. Negative controls:
temporarily give an unscripted call the outcome `{:completed, %{}}`
(group 7 must fail), then temporarily give a nested finish to the parent
without conversion (group 5 must fail with `nested_result_invalid`).
Restore both before the final gate.

Run `. .elzoo-services/env.sh`, `mix test pieces/runtime/recipe-test/test`,
then `mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. The copied consumer of the small gate must finish
within its existing 300 seconds (the engine suite, with 62 fixtures, took
about 90 seconds in its own); if it does not, or if it cannot find the
engine helper, stop and report the measured time or the path to the
coordinator. One independent review checks the body and the exact diff,
including extra features.

## Not in scope

A nested tool, a tool written in Lua, a graph that a model gives and a
restart (all ELZ-183); a person answer, an approval, a skill load, a
moving clock, a real or MCP Adapter, a store of large tool results, loop
iterations of a nested child, retries, a change of `assembly/run-engine`
or its test helper, of any pattern Piece or of any shared file, and the
load of a recipe file.
