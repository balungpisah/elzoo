# workflow/lua-tool

A tool written in Lua, as one pure pattern step in the shapes of
`workflow/pattern-step`. A recipe defines a tool as a Lua function with a
schema; the registry resolves its name to a nested callable, and this Piece is
that callable. It never runs Lua. It asks the engine for one `local_work`
action that runs the function in the sandbox from the start, with the results
of earlier module calls as a record. That run ends with the final result, or
with the first module call that has no recorded result. For such a call the
step asks for one `tool_call` action, keeps its result, and asks for the run
again. The state of the sandbox is never kept: only the record is.

Reused unchanged: `workflow/pattern-step` (decode, open, accept),
`workflow/tool-registry` (snapshot, tools, resolve) and `runtime/lua-binding`
(names, check_arguments, check_result). The Piece does not depend on
`runtime/lua-sandbox`: it holds only the request and reply forms.

## Interface

`Elzoo.LuaTool.new(spec)` returns `{:ok, state}` or `{:error, :invalid_spec |
{:sources, reason} | {:unbound_function, name} | :state_too_large}`, in this
order. `spec` is a map with exactly these atom keys:

| Key | Value |
| --- | --- |
| `id` | UTF-8 text of 1 to 64 bytes without `":"`, unique in the Run |
| `source` | the Lua source of the tool (part of the state) |
| `policy` | the policy identity of the sandbox that the host built, not empty |
| `limits` | a string-keyed map with exactly `steps`, `call_depth`, `value_bytes`, `memory_bytes`, `wall_ms`, each a positive integer |
| `bindings` | the value of `LuaBinding.resolve/2` for the functions of the tool |
| `sources` | the operand of `ToolRegistry.snapshot/1` that holds the source of `LuaBinding.source/2`; its refusal is `{:sources, reason}` |
| `source_id` | the `id` given to `LuaBinding.source/2` |
| `max_calls` | 0 to 256, the largest number of module calls of one run |

The alias of a long name is a cut form, so the step builds none: it resolves
each alias of `ToolRegistry.tools(snapshot)` with `resolve/2` and keeps, for the
tools whose `source` equals `source_id`, `alias`, `source`, `tool` and `version`
under the binding name. Each name of `LuaBinding.names(bindings)` must have one,
else `{:unbound_function, name}` (the first, sorted). The state keeps this
plain map, not the snapshot.

`Elzoo.LuaTool.step(state, input)` returns `{:Transition, new_state, :none |
{:some, request}}`. Each request holds exactly one action and passes
`PatternStep.decode/1`. The state is opaque; it holds the spec values, the start
input, the run counter, the pending call while its module call is open, the
record, the tracker of the open request and the last accepted action, and never
anything of the sandbox. A closed state holds only its `id`.

## Payloads

All keys are strings; each schema version is 1. Identities derive from `id`:
run `N` (from 1) is `id:r:N`; module call `K` (the index of the pending call,
from 0) is `id:c:K`; the finish is `id:finish`.

| Use | Kind | Schema key | Payload |
| --- | --- | --- | --- |
| start | | `elzoo.lua-tool.input` | exactly `{"input": plain}` |
| run | `local_work` | `elzoo.lua-tool.run` | exactly `source`, `input`, `policy`, `limits`, `calls`; `calls` exactly `{"mode": "replay", "names": sorted names, "recorded": [{"name", "arguments", "result"}, ...]}` |
| run result | | `elzoo.lua-tool.run-result` | exactly one of `{"ok": {"value", "identity", "runtime"}}`, `{"pending_call": {"index", "name", "arguments"}}`, `{"refused": reason}`, `{"host_outcome": reason}`; a reason is any non-empty string and is copied to `detail` |
| module call | `tool_call` | `elzoo.lua-tool.module-call` | exactly `alias`, `source`, `tool`, `version`, `arguments` |
| module result | | `elzoo.lua-tool.module-result` | exactly `{"result": plain}` |
| finish | `finish` | `elzoo.lua-tool.result` | exactly `status`, `reason`, `detail`, `action_id`, `result` |

`completed` has `reason` and `detail` `null`, `action_id` the run action that
gave the value and `result` the value. `failed` has `result` `null`, a reason,
`detail` the sandbox reason for `sandbox_refused` and `sandbox_host_outcome` and
`null` otherwise, and `action_id` the last action whose outcome was `completed`
and whose payload the step accepted (a run result in one of the four forms, or a
module result that passed `check_result/3`), or `null`.

## Step table

| Phase | Input | Result |
| --- | --- | --- |
| new | `start` with the input payload | run 1, with an empty record |
| new | `start` in another form | finish `failed`, `invalid_input` |
| running | completed `ok` | finish `completed` with the value |
| running | completed `pending_call` | "A pending call" |
| running | completed `refused` or `host_outcome` | finish `failed`, `sandbox_refused` or `sandbox_host_outcome` |
| running | outcome of another class, or a completed payload in another form | finish `failed`, `run_not_completed` |
| calling | completed module result | "A module result" |
| calling | outcome of another class, or a completed payload in another form | finish `failed`, `module_call_not_completed` |
| new, running, calling | `cancel`, `run_ended` | closed; no request |
| any | every other input (`message`, `wake`, `resource_event`, `person_answer`, a second `start`, a `late` outcome, an outcome of an action that is not open, a map that `decode/1` refuses) | no change, no request |
| closed | every input | no change, no request |

Outcomes are settled through `PatternStep.open/1` and `accept/2` on the one open
request; only an applied one is read. An outcome is read as a run result or a
module result only with its schema key and version 1; a completed outcome with
another schema is "a completed payload in another form". A value of a payload
is plain when it is JSON data (`null`, booleans, numbers, UTF-8 text, lists, maps
with text keys), else the payload is in another form.

**A pending call**, the first rule that holds: (1) `index` is not the number of
recorded calls, or `name` is not a name of the bindings: `call_mismatch`; (2) the
number of recorded calls equals `max_calls`: `call_limit`; (3)
`check_arguments/3` refuses: `invalid_arguments`, with no argument value in the
finish; (4) otherwise one module-call action.

**A module result**: `check_result/3` refuses it: `invalid_module_result`;
otherwise the call is added to the record and the next run action is asked for,
with the whole record.

Finish reasons: `invalid_input`, `sandbox_refused`, `sandbox_host_outcome`,
`run_not_completed`, `module_call_not_completed`, `call_mismatch`, `call_limit`,
`invalid_arguments`, `invalid_module_result`, `state_over_bound`. After a
transition, a next state over 65,536 bytes (as `term_to_binary(state,
[:deterministic, {:minor_version, 2}])`, the measure of the run engine) gives
the finish `failed`, `state_over_bound` instead. After a finish, `cancel` or
`run_ended` the state is closed. No action is asked for twice and no outcome
starts a second try; a module call with an `unknown` outcome is never repeated.

## Evidence

- Test: nine named groups over recorded traces of literal neutral maps
  (`no_module_call`, `two_module_calls_in_order`, `restart_between_calls`,
  `call_order_differs`, `undeclared_and_wrong_arguments`,
  `sandbox_stops_are_tool_failures`, `module_call_not_completed`,
  `limits_and_closed`, `forms_agree`) and the checked example
  `examples/lua_tool.exs`. Negative controls: skipping the index test of a
  pending call fails `call_order_differs`; starting a second run after a failed
  run fails `sandbox_stops_are_tool_failures`.
- `state_is_plain_data` is outside the nine groups. It checks that the state is
  plain data (no struct) within 65,536 bytes after every transition of the
  trace of `two_module_calls_in_order`, by the measure of the ready run engine.
- Upstream: the Contracts of `workflow/pattern-step`, `workflow/tool-registry`
  and `runtime/lua-binding`, and the OTP `term_to_binary` measure of the run
  engine.
- No Cure law is selected; the step has finite tests only.

## Needs and limits

Needs: an engine that records each input before the step reads it and checks
payload, budget, authority and approval for every action; a `local_work` binding
that runs exactly the given request with `Elzoo.LuaSandbox.run/2` on an
executable that the host built and returns the run-result form; a `tool_call`
binding for each alias of the binding source that calls the real Adapter of the
module and returns the module-result form; the host's `nested.(action)` for the
parent's tool call, which starts this step with `{"input": arguments}`; a recipe
whose declared functions and permissions passed `workflow/recipe-check`; a
Run-wide unique `id`; results small enough for the state bound.

Limits: the step runs no Lua and calls no module. No ready parent reads
`elzoo.lua-tool.result`, so the host wraps the step in a function of its own that
turns the finish into the form of the parent. The ready engine has one binding
for each action kind: a Run in which another pattern also makes tool calls needs
the engine to choose a binding by the schema of the action, else each module call
ends as `module_call_not_completed`. A run payload over the payload bound of the
engine is refused by the engine, which the step sees as `run_not_completed`. A
memory or wall-time stop is a host outcome and ends the tool as failed. Each
module call costs one more sandbox run from the start, so a tool with `n` calls
runs `n + 1` times; the `steps` limit applies to each run. A replay whose call
order differs from the record is a failure, never a repair.

Telemetry, Config and Control are not applicable: pure functions over intrinsic
operands. The module is application-owned under `Elzoo.LuaTool`; redistributors
rename it. Apache-2.0; no new dependency or pin.
