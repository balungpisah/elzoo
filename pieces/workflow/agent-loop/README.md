# workflow/agent-loop

The agent loop as one pure pattern step, in the shapes of `workflow/pattern-step`:
state and one recorded input give a new state and zero or one request. A model
proposes tool calls; the step resolves each one through the registry snapshot in
its state (`workflow/tool-registry`), puts all calls of one model turn in one
request, bounds each result (`workflow/tool-result-limit`) and builds each model
request with `Elzoo.PromptAssembly.build/2`. It calls no model and no tool, reads
no clock, stores nothing and starts no process. It checks neither budget nor
authority: the engine does that for every action.

## Interface

`Elzoo.AgentLoop.new(spec)` returns `{:ok, state}` or `{:error, :invalid_spec |
{:sources, reason} | :state_too_large}`. `spec` is a map with exactly these atom keys:

| Key | Value |
| --- | --- |
| `id` | UTF-8 text of 1 to 128 bytes, unique in the Run (the caller keeps it so) |
| `model`, `max_output_tokens`, `role_instructions`, `window`, `max_request_bytes`, `max_image_refs` | members of the `build/2` input, given to it unchanged; `build/2` checks them at the first model call |
| `sources` | the operand of `ToolRegistry.snapshot/1`, captured at Run start; its refusal is `{:sources, reason}` unchanged |
| `result_limits` | the `limits` of `ToolResultLimit.decide/3`: `%{max_bytes: 1_024..1_048_576, artifact_max_bytes: pos_integer}` |
| `ask` | `nil`, or the alias (`[a-zA-Z0-9_-]{1,64}`) of the one listed tool whose calls are questions to a person; an alias that `resolve/2` does not resolve in the first snapshot is `:invalid_spec` |
| `turn_limit` | 1 to 256, the largest number of model calls; no default |

A spec that is not plain data (a struct, a pid, a function) is `:invalid_spec`.

`Elzoo.AgentLoop.step(state, input, estimate)` returns `{:Transition, new_state,
:none | {:some, request}}`, the `core/operator` shape. `input` and `request` are
neutral maps of `Elzoo.PatternStep`; each request passes `PatternStep.decode/1`.
`estimate` is the arity-1 function of `build/2`; it is never stored. The engine
calls a function of two arguments, so the host gives it a function of its own that
supplies `estimate`.

## Payloads

All keys are strings; each schema version is 1.

| Use | Kind | Schema key | Payload |
| --- | --- | --- | --- |
| model call | `model_call` | `elzoo/ai-text-request` | the `request` of `build/2` |
| model result (completed) | | `elzoo.ai-text.result` | JSON view of ai-text; only `content`, `finish` and `tool_proposals` (each with `id`, `name`, `arguments`, `malformed`) are read |
| message, start | | `elzoo.agent-loop.message` | exactly `{"text": text}`, not empty |
| start that names a skill | | `elzoo.agent-loop.message` | exactly `{"text": text, "skill": {"tool": alias, "name": name}}`: `text` not empty, `skill` exactly these two members, all three texts; a `message` with a `skill` member is refused |
| tool action | `tool_call` (callable `{:adapter, _, _}`) or `nested_callable` (`{:nested, _, _}`) | `elzoo.agent-loop.tool-call` | exactly `alias`, `source`, `tool`, `version`, `arguments` |
| ask action | `ask_person` | `elzoo.agent-loop.ask` | exactly `{"person_id": 1..256 bytes, "question": not empty}` from the validated arguments |
| answer | (`person_answer`) | `elzoo.agent-loop.answer` | exactly `{"text": text}` |
| store action | `tool_call` | `elzoo.tool-result-limit.store` | the payload of `ToolResultLimit.decide/3`; no tool list shows it |
| tool and store result | | `elzoo.agent-loop.tool-result` | a result of ELZ-139 (`content` a marked map), a declaration `{"declaration": {"skill": S, "listing": L}}`, or a receipt of ELZ-139 |
| finish | `finish` | `elzoo.agent-loop.result` | exactly `status`, `reason`, `action_id`, `turns` |

In the model result, a proposal has `id` and `name` (a string or `null`),
`arguments` (an object, or `null` when the tag is set) and `malformed` (`null`,
`undeclared_tool`, `schema_mismatch`, `not_an_object` or `invalid_json`); `finish`
is `stop`, `length`, `tool_calls`, `content_filter`, `refusal` or `{"other": text}`.
In a declaration `S` is `null` or exactly `{"name": 1..64 bytes, "instructions":
not empty}`, `L` is `null` or exactly `{"source": id, "tools": [descriptor]}`, and
at least one is set. An outcome that is not completed is read only for its class
and an optional `"reason"` member in `[a-z0-9_]{1,64}`.

A finish is `answered` with `reason` `null` and `action_id` the completed model
call that gave the answer (the answer is the `content` of that recorded outcome; it
is not copied), or `stopped` with `action_id` `null` and the reason `turn_limit`,
`model_call_not_completed`, `model_stopped`, `request_not_built` or
`state_over_bound`. `turns` counts the model calls made.

Identities derive from `id`: model call `N` (from 1) is `id:m:N`; call `I` of turn
`N` (the position of the proposal, from 1, also for a proposal that makes no action)
is `id:t:N:I`, its store action `id:s:N:I`; the start load (see "Start load") is the
action `id:t:0:1`; the finish is `id:finish`. History
entries (ELZ-140) use the same: the `:assistant` entry of turn `N` is `id:m:N`, the
`:tool_result` entry of proposal `I` is `id:t:N:I`, the note of turn `N` is
`id:n:N`, the note of the start load is `id:n:0`, and `:user` entry `K` (in order of
arrival over the Run, the start is 1) is `id:u:K`. An entry that changes its kind keeps
its `id`.

## Step table

| Phase | Input | Result |
| --- | --- | --- |
| new | `start` | one `:user` entry; model call 1 |
| new | `start` that names a skill | one `:user` entry; "Start load": one tool action `id:t:0:1`, or a notice and model call 1 |
| model | outcome of the open model call | "One model result" |
| tools | outcome of an open tool or ask action; `person_answer` of an open ask | "One turn", step 3 |
| tools | outcome of the open start load `id:t:0:1` | "Start load" |
| stores | outcome of an open store action | "One turn", step 4 |
| model, tools, stores | `message` | the text waits; no request |
| new, model, tools, stores | `cancel`, `run_ended` | closed; no request |
| any | every other input (`resource_event`, `wake`, a later `start`, a `late` outcome, an outcome or answer of an action that is not open or is settled, an answer to no ask, a `completed` outcome of an ask, another payload shape, a map that `decode/1` refuses) | no change, no request |
| closed | every input | no change, no request |

Outcomes and answers are settled through `PatternStep.open/1` and `accept/2` on the
open request, and only an applied one is read.

## One model result

The first rule that holds decides; no rule reads the words of the content.

1. The class is not `completed`: `stopped`, `model_call_not_completed`. No second try.
2. Another key, or a read member not in the form above: `stopped`, `model_stopped`.
3. `finish` is `stop`, no proposal and no message waits: `answered` when the content
   is not empty, else `stopped`, `model_stopped`.
4. `finish` is neither `stop` nor `tool_calls`, or `tool_calls` with no proposal:
   `stopped`, `model_stopped`.
5. The turn count equals `turn_limit`: `stopped`, `turn_limit`. No tool runs.
6. Otherwise the turn runs.

## One turn

1. Each proposal is kept or left out by the Cure decision `keep`, first rule first:
   name not in `[a-zA-Z0-9_-]{1,64}` (`name_outside_grammar`); `malformed` set (its
   tag); `id` not 1 to 256 bytes (`missing_id`); an earlier kept proposal of the
   turn has the same `id` (`repeated_id`); 64 already kept (`over_call_bound`). A
   proposal left out is never echoed, never run and gets no tool result.
2. Each kept call: `ToolRegistry.resolve(snapshot, name)`, then `check(tool,
   arguments)`. Resolved and `:ok`: one action (the ask action for the `ask` alias,
   whose arguments must hold the two texts, else the notice `[tool call not run:
   invalid_ask]`; a tool action otherwise). `check/2` not `:ok`: `[tool call not run:
   validator_disagreement]`. Any other resolution: `[tool call not run: not_resolved]`.
3. All actions go into one request in proposal order; with none, step 5. The step
   gives no request until every action is settled, and reduces each applied outcome
   when it arrives: not `completed` gives `[tool call not completed: CLASS]` or
   `[tool call not completed: CLASS: REASON]` (no `is_error` member is ever written);
   another key gives `[tool result not readable]`; exactly `declaration` gives
   "Declarations"; otherwise `ToolResultLimit.decide(payload, result_limits,
   action_id)` (`{:error, _}` is not readable). A `person_answer` in the answer form
   becomes a `text/plain`, `utf8` result whose content is marked with the one source
   `person-answer`, class `untrusted`, bound 65,536, and is bounded the same way.
4. The store actions, if any, go into one request in call order; each applied
   outcome gives `ToolResultLimit.settle(pending, class, payload)` (`nil` unless
   `completed`).
5. The turn closes into the history: the `:assistant` entry (content and kept calls;
   none when both are empty), one `:tool_result` entry per kept call in proposal
   order (`ref_media_type` the `media_type` of the cut, if any), the note when a
   proposal was left out, then one `:user` entry per waiting message. Then the next
   model call.

The note has one line per proposal left out, in order: `[tool call left out: NAME:
TAG]`, with no name for `name_outside_grammar`, and for `undeclared_tool` one more
word from `resolve/2`: `: removed`, `: ambiguous` or `: unknown`. A notice and the
note are marked maps (source `agent-loop`, class `untrusted`, bound 65,536) that the
step writes itself; ELZ-139 and ELZ-140 check them.

**Each model call.** An echoed call whose name `resolve/2` no longer resolves is
taken out of its `:assistant` entry and its `:tool_result` entry becomes a `:content`
entry behind the other results of that turn; an `:assistant` entry left with no text
and no call is removed. Then `build/2` gets the spec members, `skill_instructions`
(loaded texts in load order), `memory: []`, the history and
`ToolRegistry.tools(snapshot)`. An error is `stopped`, `request_not_built`; on
success the entries in `dropped` leave the history of the state.

## Declarations

Read only from the outcome of a tool action and permitted only by the `source_kind`
of the called tool, through the Cure decision `permit`. First rule first:
`invalid_declaration` (form); `declaration_not_permitted` (kind `other`, or
`host_listing` with a skill; `pinned_skill` may give a skill, a listing or both);
`already_loaded`; `instructions_over_bound`; the refusal of
`ToolRegistry.refresh/3` unchanged (`too_many_tools`, `unknown_source`, ...);
`state_over_bound`; otherwise accepted: the instructions join the loaded skills
with no mark and no cut, and the snapshot is replaced. A refusal changes nothing.
The result of the call is `[declaration accepted]` or `[declaration refused:
REASON]`. A declaration never goes to `ToolResultLimit`.

## Start load

A start that names a skill makes its `:user` entry `id:u:1`, then reads the alias
in the snapshot of the state, in this order: `ToolRegistry.resolve(snapshot,
alias)`; the source kind of the tool must be `pinned_skill`; `check(tool,
{"name": name})` must be `:ok`. Then the request is one action, the tool action of
that tool with the arguments `{"name": name}` and the id `id:t:0:1`; no model call
yet. No other kind can make it. With no action, the notice is one of `[skill not
loaded: not_resolved]` (any resolution but a resolved tool), `[skill not loaded:
not_permitted]` (a resolved tool of another kind; this is read before the check, so
it does not depend on the schema of that tool) or `[skill not loaded:
validator_disagreement]` (a `pinned_skill` tool whose check is not `:ok`), and the
loop goes straight to model call 1.

The applied outcome of `id:t:0:1` is reduced as in "One turn", step 3: a declaration
goes to "Declarations" unchanged and gives `[declaration accepted]` or
`[declaration refused: REASON]`; an outcome that is not `completed` gives its
notice; another key gives `[tool result not readable]`; any other completed result
gives `[skill not loaded: not_a_declaration]` and goes to no `ToolResultLimit` and
makes no store action. A skill is loaded only by that declaration rule, so the
trust rule is the same as for a turn: the source kind of the tool and nothing else.

The history of the start load is the `:user` entry `id:u:1`, one `:content` entry
`id:n:0` that holds the notice, then each message that waited, then model call 1.
No `:assistant` entry and no `:tool_result` entry is written, and `turns` counts
model calls only, so the load is not a turn. A `message` that arrives during the
load waits as in any open phase; `cancel` and `run_ended` close the loop as in any
phase.

## Bounds

Two fixed numbers, not Config. State: 65,536 bytes of
`:erlang.term_to_binary(state, [:deterministic, {:minor_version, 2}])`, the measure
of the ready engine; `step/3` never returns a larger state (a declaration over it is
refused; each other such transition is `stopped`, `state_over_bound`), `new/1`
refuses `:state_too_large`. Loaded instructions: 16,384 bytes in all, because they
are held in the state and sent in every request whole.

## State form (for source-copy owners)

Plain data. While open: `%{phase: :new | :model | :tools | :stores, spec:
spec_without_sources, snapshot: tool_registry_snapshot, skills: [{name,
instructions}], history: [prompt_assembly_entry], waiting: [user_entry], users: k,
turns: n, open: nil | open}`. `open` holds the `PatternStep` tracker, `actions` (the
open action ids to the turn number or proposal position) and, in a turn, `turn: %{n:,
content:, slots:}`, one slot per proposal: `%{index:, left_out: line}`, or `%{index:,
echo:, action:, source_kind:, result:}` where `result` is `nil`, `{:result,
marked_map, ref_media_type}`, `{:store, pending, payload}` or `{:stored, pending}`.
The start load is an open turn with `n: 0` and one slot whose `echo` is `nil`.
Closed: `%{phase: :closed, id: id, turns: n}`. Values that `new/1` and `step/3` did
not make are outside the Contract.

## Grounding

- Proof: `cure/elzoo/agent_loop.cure` holds the production decisions
  `keep(name_ok, well_formed, has_id, new_id, in_bound)` and `permit(kind,
  has_skill, has_listing)`. Selected laws: `name_outside_left_out`,
  `malformed_left_out` and `missing_id_left_out` (not `Kept` when that operand is
  false, for every value of the others); `other_refused` (kind `Other` refused for
  both flags); `host_listing_skill_refused` (kind `HostListing` with a skill refused
  for both values of `has_listing`). They cover the decisions over supplied
  classifications only.
- Type: the pinned Cure compiler checks that source; the source audit finds no
  axioms, holes or unproved-total definitions.
- Test: `mix test pieces/workflow/agent-loop/test` runs the twenty-eight named groups
  `final_answer`, `one_turn_one_request`, `unknown_tool`, `malformed_proposals`,
  `listing_changes_snapshot`, `outside_set_listing`, `declarations_by_source_kind`,
  `instruction_bound`, `proposal_without_id`, `engine_refusal_as_content`,
  `result_after_cancel`, `turn_limit`, `done_is_not_evidence`, `ask_and_answer`,
  `declaration_over_state_bound`, `repeated_id`, `over_call_bound`,
  `validator_disagreement`, `not_resolved`, `request_not_built`, `run_ended`,
  `start_loads_skill`, `start_load_refused`, `start_load_not_pinned_skill`,
  `start_load_not_run`, `start_load_survives_refold`, `model_repeat_after_start_load`,
  `existing_behaviour`, plus `new_refusals` and `laws_and_example` (law check, source audit and the checked
  example `examples/agent_loop.exs`: a start, one tool turn, the answer). Each
  request passes `PatternStep.decode/1`, each model call payload `Request.decode/2`
  with 65,536 bytes, and each state is plain data within the state bound. The step
  table, history, notices, bounds and calls into the composed Pieces have tests
  only. Negative controls: `permit` that permits `Other` fails the law check; a next
  model call at the first tool outcome fails `one_turn_one_request`; a start load
  that skips the source-kind check fails `start_load_not_pinned_skill`; a start load
  that puts the skill into the state without the declaration rule fails
  `start_load_refused`; a notice of the start load written as a `:tool_result` entry
  instead of `:content` fails `start_loads_skill`. Finite
  scenarios, not a universal proof.
- Upstream: the Contracts of `workflow/tool-registry`, `workflow/tool-result-limit`,
  `workflow/prompt-assembly`, `workflow/pattern-step`, `workflow/untrusted-content`
  and `integration/ai-text`; the pure `translate/2` of `integration/ai-text-anthropic`
  and `integration/ai-text-openai` (used by `engine_refusal_as_content` and
  `start_loads_skill` only, which is why they are dependencies); OTP `term_to_binary`.

## Needs and limits

Needs: an engine that records each input before the step reads it, gives only
inputs of its Attempt, and checks payload, budget, authority and approval for every
action; the model-call binding of ELZ-141 with `tool_proposals`; a tool binding that
maps `source` and `tool` to a real Adapter call or nested callable, marks each result
truthfully and gives a declaration only for a skill load or a listing; a `tool_call`
binding for `elzoo.tool-result-limit.store` with the receipt as the whole payload;
for an ask, a listed ask tool whose schema requires `person_id` and `question` and
admits only persons who may be asked, an `ask_person` binding whose `person` function
returns `person_id` of the payload, with the result key `elzoo.agent-loop.answer`,
verification of the person before the answer reaches the step, and an `extract` that
reads a stored answer as a `text/plain`, `utf8` result; a truthful source set with
truthful kinds captured at Run start; complete listings; a pure `estimate` that tells
its direction truthfully; a Run-wide unique `id`; `max_request_bytes`,
`result_limits` and `turn_limit` that fit the state bound and the bounds of the
engine.

Limits: no provider is called; each test input is a literal neutral map, and that the
providers accept the refusal rule, and the notice of a start load as a `user`
message after the start message, is shown on `Request.decode/2` and the pure
`translate/2` only. The step verifies no person and gives an answer no authority. No
memory, compaction or member message. A call that did not complete is never tried
again; no rule for a second Attempt. `answered` is not evidence that the work is
done. No engine claim: the ready `assembly/run-engine` completes a Run with a root
`finish` only when it names a completed action (a `stopped` finish comes back
refused), gives a pattern no `cancel`, late outcome or `message` while an action is
open, and gives the first admitted finish of a nested callable to the parent action
only when its schema key equals the `result` of the parent's `nested_callable`
binding (a completed outcome under another schema than
`elzoo.agent-loop.tool-result` version 1 gets `[tool result not readable]`). A
result over the outcome bound of the engine never arrives.
No claim that marking prevents prompt injection.

Telemetry, Config and Control are not applicable: pure functions over intrinsic
operands. Modules are application-owned under `Elzoo.AgentLoop` and
`Cure.Elzoo.AgentLoop`; redistributors rename them. Apache-2.0; no new dependency
or pin.
