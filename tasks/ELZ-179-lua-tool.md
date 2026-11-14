# ELZ-179 — A tool written in Lua, as one pure pattern step

## Scope and reuse

- Dependencies: ELZ-033, ELZ-002, ELZ-114, ELZ-136, ELZ-177, ELZ-178
- Output: `workflow/lua-tool`, one public module `Elzoo.LuaTool`; release V1B; RC-62 tool portion.
- Change class: Piece-only implementation; small local gate and hosted `check-piece`.
- Owned paths: `pieces/workflow/lua-tool/**` and its index/generated changes under AGENTS.md section 3.

Admit the tool portion of RC-62. A recipe can define a tool as a Lua
function with a schema. The registry resolves its name to a nested callable,
and this Piece is that callable: a pure step in the shapes of
`workflow/pattern-step`. It never runs Lua. It asks the engine for one
local-work action that runs the function in the sandbox from the start, with
the results of earlier module calls as a record. That run ends with the
final result, or with the first module call that has no recorded result. For
such a call the step asks for one tool-call action, keeps its result, and
asks for the run again. The state of the sandbox is never kept: only the
record is.

Implement only the acceptance groups below. Use the public functions of
`Elzoo.PatternStep`, `Elzoo.ToolRegistry` and `Elzoo.LuaBinding` as they are
on main. Add no sandbox call, no process, no retry, no options, behaviours
or hooks. Edit no ready Piece, shared path, pin or CI file. No fixtures
directory is needed: each test input is a literal neutral map.

Facts checked on main (confirm each when you start; if one differs, stop and
ask):

- `workflow/pattern-step` (ELZ-114): a request holds 1 to 64 actions; the
  kinds include `local_work`, `tool_call` and `finish`; `open/1` and
  `accept/2` settle each action once.
- `runtime/lua-sandbox` after ELZ-177: a request is `source`, `input`,
  `policy`, `limits`, `calls` (`mode`, `names`, `recorded`); the reply is
  `{:ok, %{value, identity, runtime}}`, `{:refused, reason}`,
  `{:host_outcome, reason}` or `{:pending_call, %{index, name, arguments}}`;
  at most 256 recorded calls.
- `runtime/lua-binding` (ELZ-178): `names/1`, `identity/1`,
  `check_arguments/3`, `check_result/3`, `source/2`.
- `workflow/tool-registry` (ELZ-136): `snapshot/1`, `resolve/2`; a resolved
  tool has `alias`, `source`, `tool`, `version`.
- `assembly/run-engine` installs a callable state only when it is plain data
  of at most 65,536 bytes as
  `:erlang.term_to_binary(state, [:deterministic, {:minor_version, 2}])`,
  and since ELZ-172 it gives the finish payload of a nested callable to its
  parent when the schema equals the declared result of the binding.

## Payloads

All keys are strings and each schema version is 1.

- **Start.** Key `elzoo.lua-tool.input`, payload exactly `{"input": plain}`:
  the arguments of the tool call. That the caller checked them against the
  schema of the tool is not assumed and not done here.
- **Run action.** Kind `local_work`, key `elzoo.lua-tool.run`, payload
  exactly `{"source", "input", "policy", "limits", "calls"}`: the request of
  the sandbox, with `calls` exactly `{"mode": "replay", "names", "recorded"}`.
- **Run result.** Key `elzoo.lua-tool.run-result`. A completed payload is
  exactly one of: `{"ok": {"value", "identity", "runtime"}}`,
  `{"pending_call": {"index", "name", "arguments"}}`,
  `{"refused": reason}` or `{"host_outcome": reason}`. This is the string
  form of a reply of `Elzoo.LuaSandbox.run/2`: every atom key and every atom
  reason as a string, recursively. The host's `local_work` binding makes it.
  The step accepts any non-empty string as a reason and copies it to
  `detail`; a payload with none or with more than one of the four members
  is "another form".
- **Module call.** Kind `tool_call`, key `elzoo.lua-tool.module-call`,
  payload exactly `{"alias", "source", "tool", "version", "arguments"}`: the
  four values of the tool that `resolve/2` gives for the binding name, and
  the arguments of the pending call. Its completed outcome has the key
  `elzoo.lua-tool.module-result` and the payload exactly `{"result": plain}`.
- **Finish.** Kind `finish`, key `elzoo.lua-tool.result`, payload exactly
  `{"status", "reason", "detail", "action_id", "result"}`. `completed` has
  `reason` and `detail` `null`, the identity of the run action that gave the
  value, and `result` the value. `failed` has `result` `null`, a reason from the
  list below, `detail` as that list says, and `action_id` the identity of
  the last action whose outcome was `completed` and whose payload the step
  accepted (a run result in one of the four forms, or a module result that
  passed `check_result/3`), or `null` when there is none.

Action identities derive from `id` of the spec: run `N` (from 1) is
`id <> ":r:" <> N`; module call `K` (from 0, the index of the pending call)
is `id <> ":c:" <> K`; the finish is `id <> ":finish"`.

## Interface

`Elzoo.LuaTool.new(spec)` returns `{:ok, state}` or `{:error, reason}`.
`spec` is a map with exactly these atom keys:

- `id`: UTF-8 text of 1 to 64 bytes without `":"`, unique in the Run.
- `source`: the Lua source of the tool. It is part of the state, so its
  size is bounded by the state bound.
- `policy`: the policy identity of the sandbox that the host built.
- `limits`: the limits of a sandbox request as a string-keyed map
  (`"steps"`, `"call_depth"`, `"value_bytes"`, `"memory_bytes"`,
  `"wall_ms"`): the run payload is neutral data.
- `bindings`: the value of `Elzoo.LuaBinding.resolve/2` for the functions
  that the recipe declared for this tool.
- `sources`: the operand of `ToolRegistry.snapshot/1` that holds the source
  of `Elzoo.LuaBinding.source/2`; `{:error, {:sources, reason}}` holds its
  refusal.
- `source_id`: the `id` that was given to `LuaBinding.source/2`. The
  registry looks a tool up by its alias, `source_id <> "_" <> name`: for
  each name of `LuaBinding.names(bindings)`, `ToolRegistry.resolve/2` of
  that alias must give `{:resolved, tool}`, else
  `{:error, {:unbound_function, name}}`.
- `max_calls`: 0 to 256, the largest number of module calls of one tool run.

A `spec` in another shape is `:invalid_spec`; a first state over the bound
is `:state_too_large`.

`Elzoo.LuaTool.step(state, input)` returns
`{:Transition, new_state, :none | {:some, request}}`. Each request holds
exactly one action and passes `PatternStep.decode/1`. The state is opaque
plain data; it holds the spec, the start input, the run counter, the
pending call (its name and arguments) while its module call is open, the
record of module calls so far and the tracker of the open request, and
never anything of the sandbox. After every transition, a next state over
the bound gives the finish `failed`, `state_over_bound`.

| Phase | Input | Result |
| --- | --- | --- |
| new | `start` with the input payload | run 1, with an empty record |
| new | `start` in another form | finish `failed`, `invalid_input` |
| running | completed run result `ok` | finish `completed` with the value |
| running | completed run result `pending_call` | "A pending call" |
| running | completed run result `refused` or `host_outcome` | finish `failed`, `sandbox_refused` or `sandbox_host_outcome` |
| running | run outcome of another class, or a completed payload in another form | finish `failed`, `run_not_completed` |
| calling | completed module result | "A module result" |
| calling | module outcome of another class, or a completed payload in another form | finish `failed`, `module_call_not_completed` |
| new, running, calling | `cancel`, `run_ended` | closed; no request |
| any | each other input (a `message`, a `wake`, a `resource_event`, a `person_answer`, a second `start`, a `late` outcome, an outcome of an action that is not open, a map that `PatternStep.decode/1` refuses) | no change, no request |
| closed | every input | no change, no request |

**A pending call** `{"index", "name", "arguments"}`, the first rule that
holds:

1. `index` is not the number of recorded calls, or `name` is not a name of
   the bindings: finish `failed`, `call_mismatch`.
2. The number of recorded calls equals `max_calls`: finish `failed`,
   `call_limit`.
3. `LuaBinding.check_arguments/3` refuses: finish `failed`,
   `invalid_arguments`. The finish holds no argument value.
4. Otherwise one module-call action for that name.

**A module result** `{"result": value}`: `LuaBinding.check_result/3` refuses
it: finish `failed`, `invalid_module_result`. Otherwise the call is added to
the record as `{"name", "arguments", "result"}` and the next run action is
asked for, with the whole record.

Finish reasons: `invalid_input`, `sandbox_refused`, `sandbox_host_outcome`,
`run_not_completed`, `module_call_not_completed`, `call_mismatch`,
`call_limit`, `invalid_arguments`, `invalid_module_result`,
`state_over_bound`. The reason of the sandbox (for example `steps` or
`call_mismatch`) is the member `"detail"` of the finish only for
`sandbox_refused` and `sandbox_host_outcome`; for the other reasons it is
`null`.

No action is asked for twice, and no outcome starts a second try: a run or a
module call that did not complete ends the tool as failed. A module call
with an `unknown` outcome is never repeated.

## Host Needs and Limits

Fixed bounds: 256 module calls; state 65,536 bytes in the measure above
(the source, the bindings, the input and the record are inside it); one
action for each request.

Needs: an engine that records each input before the step reads it and
checks payload, budget, authority and approval for every action; a
`local_work` binding that runs exactly the given request with
`Elzoo.LuaSandbox.run/2` on an executable that the host built, and returns
the run-result form; a `tool_call` binding for each alias of the binding
source that calls the real Adapter of the module and returns the
module-result form; the host's `nested.(action)` for the parent's tool
call, which starts this step with `{"input": arguments}`; a recipe whose declared functions and
permissions passed `workflow/recipe-check`; a Run-wide unique `id`; results
small enough for the state bound.

Limits: the step runs no Lua and calls no module. No ready parent reads
`elzoo.lua-tool.result`: `workflow/agent-loop` reads only its own tool-result
form and `workflow/graph-run` only its node-result form, and the engine
gives a parent the finish of a child only when its schema equals the
declared result of the parent's binding. So the host wraps this step in a
function of its own that turns the finish into the form of the parent, and
gives that function to the engine as the nested callable. The ready engine
has one binding for each action kind: a Run in which another pattern also
makes tool calls needs the engine to choose a binding by the schema of the
action (ELZ-180), or the module results arrive under the other pattern's
result schema and each module call ends as `module_call_not_completed`. A
run payload whose JSON is over the payload bound of the engine is refused
by the engine, which this step sees as `run_not_completed`. The tool is pure between
module calls only as far as the sandbox is: a memory or wall-time stop is a
host outcome and ends the tool as failed. Each module call costs one more
sandbox run from the start, so a tool with `n` calls runs `n + 1` times; the
`steps` limit applies to each run. A replay whose call order differs from
the record is a failure, never a repair. Telemetry, Config and Control are
not applicable: pure functions over intrinsic operands.

The manifest declares `kind: owned`, providers `cure` and `elixir` (Cure
only if a law is selected), and the Piece dependencies
`workflow/pattern-step`, `workflow/tool-registry` and `runtime/lua-binding`.
It does not depend on `runtime/lua-sandbox`: the step holds only the request
and reply forms, and group 9 shows that they agree with the sandbox task.

## Named acceptance groups

Each test folds `step/2` over a recorded trace of literal neutral inputs,
with the expected requests written by hand.

1. **`no_module_call`**: start, one run action with an empty record, a
   completed `ok` result, a completed finish with the value and the identity
   of that run action.
2. **`two_module_calls_in_order`**: the run gives pending call 0; the step
   gives one module-call action; its result gives run 2 with a record of one
   call; that run gives pending call 1; then run 3 with two calls gives the
   value. The step never gives two actions in one request, and the actions
   are run 1, call 0, run 2, call 1, run 3, finish, in this order.
3. **`restart_between_calls`**: the trace of group 2 cut after each input
   and folded again from the start gives the same states and requests; the
   same final result; no action identity appears in two requests.
4. **`call_order_differs`**: a pending call whose index is not the record
   length ends in the finish `failed`, reason `call_mismatch`, detail
   `null`; a run result `refused` with the sandbox reason `call_mismatch`
   ends in the finish `failed`, reason `sandbox_refused`, detail
   `call_mismatch`. The two are separate tests.
5. **`undeclared_and_wrong_arguments`**: a pending call for a name outside
   the bindings is `call_mismatch`; arguments that the schema refuses are
   `invalid_arguments` with no module-call action and no argument value in
   the finish; a module result that the schema refuses is
   `invalid_module_result`.
6. **`sandbox_stops_are_tool_failures`**: run results `refused` with
   `steps` (a tool that loops) and `host_outcome` with `wall_time` each give
   a failed finish with reason and detail; a run outcome of the class
   `failed`, `unknown` and `expired` is `run_not_completed`; none starts a
   second run.
7. **`module_call_not_completed`**: each outcome class other than
   `completed` for the module call ends the tool as failed, and `unknown`
   starts no second call.
8. **`limits_and_closed`**: `max_calls` 0 with a pending call is
   `call_limit`, and with a source that makes no call the tool completes;
   with `max_calls` n, call n-1 is asked for and call n is `call_limit`;
   `state_over_bound` from a large start input, from large pending
   arguments and from a large module result; each refusal of
   `new/1`; `cancel` and `run_ended` close the step; each input of the "no
   change" row.
9. **`forms_agree`**: the run payload that the step gives equals, member
   for member, a literal request in the form of ELZ-177 that the test writes
   (exact keys, mode `replay`, names sorted, at most 256 records), and each
   of the four run-result forms equals a literal string form of one reply.
   No sandbox is run and the Piece does not depend on it. One small checked example covers the
   public API.

## Evidence and gate

Test: the nine groups. Cure owns a pure decision when a meaningful law is
selected, for example "the record grows by one call for each module result
and never otherwise"; do not add a Boolean restatement. Negative controls:
temporarily skip the index test of a pending call (group 4 must fail), then
temporarily start a second run after a failed run (group 6 must fail).
Restore both before the final gate.

Run `mix test pieces/workflow/lua-tool/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`.
One independent review checks the body and the exact diff, including extra
features.

## Not in scope

The sandbox, the bindings of the engine, the Adapters of modules, the load
of a recipe file, `runtime/recipe-test`, retry and timeout policy, and any
change of a ready Piece.
