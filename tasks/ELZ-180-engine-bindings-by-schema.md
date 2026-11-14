# ELZ-180 — The run engine chooses a binding by the schema of the action

## Scope and reuse

- Dependencies: ELZ-033, ELZ-127, ELZ-172
- Output: none. This task changes the ready Piece `assembly/run-engine` in place; the Piece ID stays. It is a prerequisite of RC-66 (`runtime/recipe-test`).
- Change class: Piece-only implementation; small local gate and hosted `check-piece`.
- Owned paths: `pieces/assembly/run-engine/**`, the test helper `pieces/assembly/run-engine/test/support/run_engine_test_helper.exs` included, and its index/generated changes under AGENTS.md section 3 (the `manifest_sha256` and `note` of its row, and the generated files).

Owner decision, 2026-11-14: Elzoo is not released yet, so a Piece that lacks
something which clearly belongs to it is extended in place, with the same
Piece ID (AGENTS.md section 4). This task changes how `assembly/run-engine`
finds the binding of an action, its Contract text, and one override of its
test helper. Reviewers do not flag the unchanged ID.

Why: the engine has one binding for each action kind, and a binding has one
static `result` and one static `effect_class`. Each pattern reads its own
result form. So one Run cannot hold two patterns that ask for the same
action kind: an agent-loop tool call and a graph-run tool node share the one
`tool_call` binding and its one result schema, and a graph-run node that
calls a nested callable and an agent-loop tool that is a nested callable
share the one `nested_callable` binding; an agent-loop ask
(`elzoo.agent-loop.ask`) and a graph-run ask node (`elzoo.graph-run.ask`)
share the one `ask_person` binding. After this task the host can give,
for an action kind, a map from the schema ID of the action to a binding, and
the engine uses the binding of that schema ID.

The test helper override is needed by RC-66 (ELZ-181): the recipe-test
harness runs the engine through this helper and registers its own scripted
Adapter bindings. Today it cannot give them to the Run owner (see the facts).

Facts checked on main (`lib/elzoo/run_engine.ex`, README, `piece.json`, the
test helper, and the ready pattern Pieces):

- `start_link/1` takes `bindings`, a map from action kind (`"local_work"`,
  `"ask_person"`, `"finish"`, `"nested_callable"`, `"tool_call"`,
  `"model_call"`, and the three resource kinds) to one binding. A binding is
  a map with atom keys: `id`, `version`, `effect_class`, `result:
  {schema_id, version}`, `facts`, `proposal`, and `work`, `person` or
  `nested` for their kinds. The functions `facts`, `proposal`, `work`,
  `person` and `nested` already receive the action; `id`, `version`,
  `effect_class` and `result` are fixed values.
- `bindings` is read in eleven places of `lib/elzoo/run_engine.ex`. Two are
  at start, in `init/1`:
  - S1: `is_map(opts[:bindings])` in the `with` chain. It is the only check
    of `bindings` at start. A failed check of that chain gives
    `{:stop, :invalid_options_or_recovery}`, so `start_link/1` returns
    `{:error, :invalid_options_or_recovery}`.
  - S2: `binding_identities/1` maps each kind to `{value.id,
    value.version}`. The result is part of the `fingerprint` digest. A
    restart whose fingerprint differs from the recorded one gives
    `{:error, :incompatible_recovery}`. A value without `:id` raises there
    today.

  Nine read the binding of one action, as `s.opts.bindings[kind]`, in the
  order in which an action meets them:
  - B1, `progress/3` in phase `:checking`: `Map.has_key?(s.opts.bindings,
    action["kind"])`. The precheck gives the first of `"payload_schema"`
    (`check_payload/2`), `"invalid_identity"` (`action_ids?/1`: `id` and
    `schema_id` are UTF-8 text of 1 to 200 bytes with no NUL) and
    `"missing_binding"`. A precheck refusal is committed as a `:precheck`
    record; the occurrence is refused with class `refused`, the refusal
    schema `elzoo.run-engine.refusal` and that reason, with no gate call and
    no reservation. No test of the suite gives `missing_binding` today.
  - B2, `sample_gate/2`: `effect_class` of the binding is given to the gate.
  - B3, `progress/3` in phase `:allowed`: `binding.facts.(action)`, and
    `binding.id` and `binding.version` as `binding_id` and `binding_version`
    in the facts of the committed `:admission` record. On a successful
    reservation the admission merges these facts, `action` included, into
    the slot. Precheck, gate and `out_of_budget` refusals leave the slot
    without `:action`.
  - B4, `action_context/3`: `binding.proposal.(action)` and
    `binding.effect_class` for `Authorization.decide/3`. It is called in
    the `progress/3` phases `:authorizing` and `:ready`, in
    `release_waiting/3` and in `resource_effects/4`. A denial at
    `:authorizing` gives the reason `"authority"`.
  - B5, `dispatch/3` of `local_work`: `binding.work.(action)` gives the MFA,
    and `binding.result` is the schema that the engine writes on the
    completed outcome of that work.
  - B6, `dispatch/3` of `ask_person`: `binding.person.(action)`.
  - B7, `dispatch/3` of `nested_callable`: `binding.nested.(action)` gives
    the child facts: Budget identity and incarnation, `mfa`,
    `initial_state`, and `schema_id`, `schema_version` and `payload` of the
    child's start input. A nested callable gets no binding map of its own:
    the actions of every callable, root and nested, are bound by the one
    `bindings` of the engine.
  - B8, `checked_ingress/3`: `s.opts.bindings[slot.kind][:result]` is the
    expected `{schema_id, version}` of an `action_outcome` or
    `person_answer` for the occurrence (for a `local_work` loss it is the
    refusal schema; for a kind with no binding it is `nil`). An outcome
    whose schema differs from an expected one that is not `nil` is
    replaced by `invalid_outcome/4`: class `failed` for `local_work`,
    `unknown` for other kinds, reason `"invalid_outcome"`.
  - B9, `nested_outcome/4` (ELZ-172): the kept finish of a child is
    compared with `s.opts.bindings[state.slots[parent].kind].result`, the
    `result` of the binding of the parent's kind. Equal: the parent action
    completes with the finish; different: it fails with
    `"nested_result_invalid"`.

  The `model_call`, `tool_call`, `finish` and resource dispatches read no
  binding: they use the intent, the resource name or the action that B3 put
  in the slot. A `finish` still meets B1 to B4 and B8.
- `action/2` gives `slot[:action]` when the slot holds it (after admission),
  else it decodes the action from `state.requests`. A request leaves
  `state.requests` when each of its slots is `:running`, `:waiting`,
  `:settled` or `:reconcile`. So for a slot that was refused before
  admission and whose request is gone, `action/2` raises.
- `effect_intent` holds the startup bindings of EffectIntent (a binding
  reference and digest). They are another thing and are not changed.
- The ready patterns use one schema ID for each action form:
  `workflow/agent-loop` asks for tools with `elzoo.agent-loop.tool-call`
  (kind `tool_call` or `nested_callable`) and for stores with
  `elzoo.tool-result-limit.store` (`tool_call`), and reads
  `elzoo.agent-loop.tool-result`; `workflow/graph-run` asks with
  `elzoo.graph-run.call` (`nested_callable`) and `elzoo.graph-run.tool-call`
  (`tool_call` or `nested_callable`), and reads
  `elzoo.graph-run.node-result`; `workflow/typed-decision` and
  `workflow/agent-loop` ask models with `elzoo/ai-text-request` and read
  `elzoo.ai-text.result`. The published task ELZ-179 asks with
  `elzoo.lua-tool.module-call` and reads `elzoo.lua-tool.module-result`.
- No other Piece on main depends on `assembly/run-engine`.
- `fixture(overrides \\ [])` in `test/support/run_engine_test_helper.exs`
  builds one EffectIntent startup map, `%{"effect" => startup}`, where
  `startup` is the keyword list `binding: TestBinding`, `store:` (a
  `Postgres.store/2` of `TestRepo` in the fixture's schema with
  `fold: Elzoo.EffectIntent.fold(TestBinding)` and
  `limits: Elzoo.EffectIntent.limits()`), `clock: now`, `host:
  {StoreHost, %{store: host_store, authorize: fn}}` (the `authorize`
  function reads the `host_mode` Agent), `task_supervisor:` and
  `adapter_context: self()`. It starts the Run owner with
  `RunApprovalRelease.start_link(store:, lease:, held:, effect_intent:
  intents)` and puts the same map in the engine options as `effect_intent`.
  The overrides are merged into the engine options only at the end
  (`Keyword.merge(opts, overrides)`), after the Run owner started: an
  `effect_intent` override reaches the engine and never the Run owner.
- The engine reads `effect_intent` for an allowed Effect: `intent/3` takes
  `Map.fetch!(s.opts.effect_intent, descriptor.binding)` and
  `check_binding/2` requires the digest of the loaded binding to equal the
  `binding_digest` of the intent and the first member of the identity to
  equal the engine's `tenant`. The Run owner reads its own map only for
  an approved (ASK) intent: `intent_binding/2` of
  `workflow/run-approval-release` requires `s.bindings[binding_ref]` and an
  identity `[_, account, adapter, operation, _]` equal to
  `{provider_account, id, operation}` of that binding, else
  `{:refused, :intent_binding}`; its `dispatch/3` then starts the intent
  owner with those startup options.
- `Elzoo.EffectIntent.fold/1` takes the binding module, so each binding
  module needs a Store of its own. The helper already defines the binding
  module `Elzoo.RunEngine.ChangedAccountBinding` (Adapter `TestAdapter`, id
  `effect`, provider account `changed-account`, operation `publish`).
  `TestAdapter.send_effect/1` sends `{:effect_started, self(), request}` to
  `request.context`, the `adapter_context` of the startup entry, and waits
  for `{:result, value}` or `:unknown`.

Implement only what is below. Change nothing else of the engine: not the
precheck order, the gate, the Budget, the authority and approval checks, the
records, the bounds, the reasons, `status/1`, the nested finish rule of
ELZ-172 or the EffectIntent startup bindings. Add no option, no hook, no
default entry, no new action kind and no new reason. In the test helper,
change only what "The test helper override" below says. Edit no other
Piece, shared path, pin or CI file. No fixtures directory is needed.

## The change

**Two forms of a binding entry.** The value of `bindings` for an action
kind is one of:

- a **binding**: a map that has the atom key `:id` and no key that is a
  binary. This is the form of today, unchanged.
- a **schema map**: a map with at least one entry, whose every key is UTF-8
  text of 1 to 200 bytes with no NUL (the bound of `action_ids?/1` on a
  `schema_id`), and whose every value is a binding.

A start whose `bindings` holds a value of neither form returns
`{:error, :invalid_options_or_recovery}` and starts no Unit: the check is in
the `with` chain of `init/1`, beside S1, before `DynamicUnits.start/2`. So
a map that has `:id` and also a binary key is refused, not read as a
binding. A binding, also inside a schema map, is checked no further than
today: a binding with `:id` and no `:version` passes this check and then
raises in S2, as today. A value without `:id` raises in S2 today and now
gets the defined error: name this change of behaviour in `Contract:` of the
pull request body.

**The choice.** The binding of an action is:

- for a kind whose entry is a binding: that binding, as today;
- for a kind whose entry is a schema map: the value under the action's
  `schema_id`, or none when the map has no such key;
- for a kind with no entry: none, as today.

The choice uses `schema_id` only, never `schema_version`, the payload or the
callable. The action of an occurrence is the one that `action/2` gives:
`slot[:action]`, or, while the request is still in `state.requests`, the
action decoded from it, and the chosen binding's `result` is expected. For
a schema map and an occurrence whose slot holds no `:action` and whose
request is no longer in `state.requests`, the binding is none (B8 then
expects `nil`, as for a kind with no entry), and `action/2` is not called.
B8 runs before the input is recorded, so the choice is the same on replay.
For a kind whose entry is a binding, no action is read, as today.

**Every read uses the choice.** Each of B1 to B9 uses the binding chosen
for its action, and no read keeps `s.opts.bindings[kind]`:

- B1: `"missing_binding"` when the action has no binding, also for a schema
  map without its `schema_id`. The order of the precheck stays
  `"payload_schema"`, `"invalid_identity"`, `"missing_binding"`: an action
  whose schema is not in `schemas` is `"payload_schema"`, whatever the map.
  As today for `missing_binding`, the refused action counts against the
  lifetime limit and, until it settles, against the open limit.
- B2 to B7: the fields and functions of the chosen binding.
- B8: the `result` of the binding chosen for the occurrence's action; none
  gives `nil`, as today.
- B9: the `result` of the binding chosen for the parent's
  `nested_callable` action.

**Fingerprint.** In S2, a kind whose entry is a binding keeps the term
`{id, version}`, so a durable Unit written before this change recovers with
the same options. A kind whose entry is a schema map gives the map from each
`schema_id` to `{id, version}` of its binding. So a restart with the same
`bindings` recovers. A restart with the same `run_id` over a non-empty
snapshot whose schema map differs (a key added or removed, an `id` or
`version` changed, a binding replaced by a schema map, or a schema map
replaced by a binding) gives `{:error, :incompatible_recovery}`. A terminal
Unit started with a new `run_id` is configured again with no comparison,
as today.

**Durable state.** No new record kind and no new field. The choice is a pure
function of the fixed options and the recorded action, so replay chooses
the same binding. The `:admission` record already holds `binding_id` and
`binding_version` of the chosen binding.

### The test helper override

`fixture/1` takes one more override, `effect_bindings`: a map from binding
reference (UTF-8 text) to `{binding_module, adapter_context}`.

- The default is `%{"effect" => {TestBinding, self()}}`, so a fixture with
  no `effect_bindings` builds exactly the map of today.
- A given map is merged into the default (`Map.merge(default, given)`): its
  entries are added, and an entry under `"effect"` replaces the default
  one.
- For each entry the helper builds the startup options as it builds
  `"effect"` today: `binding:` the module; `store:` a `Postgres.store/2` of
  `TestRepo` in the fixture's schema with
  `fold: Elzoo.EffectIntent.fold(module)` and
  `limits: Elzoo.EffectIntent.limits()`; `clock:`, `host:` and
  `task_supervisor:` the same as those of `"effect"` (one `StoreHost` for
  all entries); `adapter_context:` the given value.
- The one resulting map is given to `RunApprovalRelease.start_link/1` as
  `effect_intent` and is the engine option `effect_intent`.
- `fixture/1` removes `effect_bindings` from the overrides before it merges
  them into the engine options: the key never reaches `start_link/1`.

Nothing else of the helper changes: not its bindings, schemas, policy,
patterns, the other overrides, or the keys of the returned map `c`.

## Contract text

Update `README.md` (rewrite the line "`bindings`: fixed v1 action-kind map
described below" and the binding paragraph "Each binding has stable
`id`/`version` ..." of "Host construction") and `piece.json` (`contract`,
`limits`, `grounding`) so that they state the two forms, the choice by
`schema_id`, `missing_binding` for an unmapped schema and the fingerprint
rule. Name the new groups in
`grounding`. The `note` of the Piece row in `docs/plans/release-plan.json`
equals `contract` in `piece.json`, and `manifest_sha256` is computed again,
in the one last commit of the index files. The README states in one
sentence that the test helper's `fixture/1` takes `effect_bindings` and
gives the same map to the engine and the Run owner.

## Host Needs and Limits

Needs: for each schema map, a binding for each action schema that a pattern
of the Run asks for under that kind, whose `result` is the schema that the
pattern reads; each action schema in `schemas`; the same `bindings` on each
restart of a Run.

Limits: the choice is by `schema_id` alone: two versions of one schema ID
under one kind share one binding. A schema map has no default entry: an
unmapped schema is `missing_binding`. A nested child must still finish with
the `result` of the binding chosen for its parent's action: when a child
pattern finishes with another schema (for example a graph node that calls
an agent loop), the host wraps the child, as ELZ-172 and ELZ-179 state.
Bindings are fixed for the Run; a changed schema map is an incompatible
restart. As today, a lost `local_work` outcome carries the refusal schema
with the `result` version of the chosen binding (`dispatch/3` of
`local_work` sets `schema_version` on both forms), while B8 expects the
refusal schema at version 1: a `local_work` binding gives its `result` at
version 1. The tests use version 1 for every `local_work` result.

## Named acceptance groups

Add these to the existing suite, on the ready PostgreSQL fixture of the
Piece, with the scripted test pattern and the clock of the helper. Each
test adds the schemas that it needs to `schemas` and starts the engine with
its own `bindings`. Each existing group stays green with no change of its
assertions and no change of the bindings that the helper builds. The
helper has no builder of a schema entry (`PayloadSchema.build/2` and the
digest are inline in `fixture/1`), no counting gate, no work MFA that
reports which work ran, no `nested_setup/2` for a schema map and no view of
`state.requests` (tests read `DurableUnit.snapshot/1`). The worker may add
these as private functions or small modules in the test files under
`test/elzoo/`, not in the helper.

1. **`binding_by_schema`**: `local_work` is a schema map of two bindings A
   and B (keys `a.work` and `b.work`) with distinct `id`, `work` and
   `result` (`a.result` and `b.result`, version 1); the other kinds keep the
   helper's bindings. One request holds an action of each schema. The work
   of A runs once for the A action only and that of B once for the B action
   only; the pattern receives the completed outcome of the A action with
   schema `a.result` and of the B action with `b.result`; the `:admission`
   row of each holds `binding_id` and `binding_version` of its own binding.
2. **`outcome_schema_by_binding`**: `tool_call` is a schema map of A
   (result `result`) and B (result `b.result`). An outcome given through
   `input/4` to the B occurrence with schema `result` settles it with class
   `unknown` and reason `invalid_outcome`; an outcome with `b.result`
   completes the B occurrence; an outcome with `result` completes the A
   occurrence.
3. **`unbound_schema_refused`**: an action whose schema is in `schemas` and
   not in the schema map of its kind is refused with class `refused` and
   reason `missing_binding`, with no gate call (a counting gate) and no
   reservation, while its sibling of a mapped schema is gated and runs; an
   action of a kind with no entry is refused with `missing_binding` too; an
   action whose schema is in neither `schemas` nor the map is
   `payload_schema`. After the request of a refused action has left
   `state.requests`, an outcome given through `input/4` for that occurrence
   leaves the engine alive and `status/1` gives the same slots before and
   after.
4. **`nested_binding_by_schema`**: `nested_callable` is a schema map of NA
   (key `a.call`, result `a.result`) and NB (key `b.call`, result
   `b.result`) whose `nested` functions start different scripted children.
   Each parent action starts the child of its own binding (the counting
   pattern shows which child got which start input); the child of NA
   finishes with `a.result` and its parent action completes with that
   finish; the child of NB finishes with `a.result` and its parent action
   fails with `nested_result_invalid`.
5. **`person_and_authority_by_schema`**: `ask_person` is a schema map whose
   two bindings give different persons: each action settles only on the
   verified answer of the person of its own binding. Under a schema map of a
   binding with `effect_class` `compute` and one with `publish`, the gate
   receives the `effect_class` of each action's own binding; with a context
   policy that has no rule for `publish`, the action of the `publish`
   binding is refused with `authority` and the other runs.
6. **`restart_keeps_choice`**: an engine with schema maps is stopped after
   the admission of two actions of different schemas and started again with
   the same options: it recovers, each action completes with its own
   binding's result, and no work starts twice. Started again with a changed
   schema map (an entry added, and separately a `version` changed) it gives
   `{:error, :incompatible_recovery}`. A start with an empty schema map, a
   key that is not text of 1 to 200 bytes, a value without `:id`, or a map
   that has `:id` and also a binary key gives
   `{:error, :invalid_options_or_recovery}`.
7. **`effect_bindings_override`**: `fixture/1` with no `effect_bindings`
   gives `c.opts[:effect_intent]` with exactly the key `"effect"`, whose
   `binding` is `TestBinding` and `adapter_context` the test process, and
   the existing suite runs on it unchanged. With `effect_bindings: %{"other"
   => {ChangedAccountBinding, forwarder}}` (a process of the test that tags
   and forwards each message it gets), `c.opts[:effect_intent]` has the
   keys `"effect"` and `"other"`, and `effect_bindings` is not an engine
   option. A `tool_call` whose binding `facts` give an intent with binding
   `"other"`, the digest of `ChangedAccountBinding` and the identity
   `["tenant", "changed-account", "effect", "publish", action_id]` is
   dispatched through the `"other"` entry (the forwarder gets
   `{:effect_started, _, _}`, the test process gets none directly). In a
   second fixture under `require_approval/1`, a `tool_call` of the same
   form is dispatched after the consent by the Run owner through
   `"other"`: the forwarder gets the start and the
   Run's status holds the effect of that action, with no refusal
   `:intent_binding`.

## Evidence and gate

Test: the seven groups and the unchanged suite. Upstream: none new. Record in
`Limits:` of the pull request body what this task does not change (the
choice ignores `schema_version`; no default entry; the nested child still
finishes with its parent's result schema). Negative controls: temporarily
make a schema map give the binding of its first key, whatever the action's
schema (group 1 must fail); then temporarily keep
`s.opts.bindings[slot.kind][:result]` in `checked_ingress/3` (group 2 must
fail: the wrong-schema outcome completes). Restore both before the final
gate.

Run `. .elzoo-services/env.sh`, `mix test pieces/assembly/run-engine/test`,
then `mix check --piece "$(git merge-base origin/main HEAD)"` and
`git diff --check`. One independent review checks the body and the exact
diff, including extra features, and checks in the diff that S2 keeps the
term `{id, version}` for a binding.

## Not in scope

A choice by `schema_version`, by payload or by callable; a default or
fallback entry; a binding map per callable; a new refusal reason; the
wrapper of a nested child (RC-66 glue); the EffectIntent startup bindings;
`workflow/agent-loop`, `workflow/graph-run`, `workflow/typed-decision`,
`workflow/lua-tool` and their READMEs; the text of a published task file;
any other change of the test helper (no compiled helper module, no new
fixture for another Piece, no other override); `runtime/recipe-test` and
its scripted Adapters; any other Piece.
