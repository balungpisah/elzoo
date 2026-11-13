# ELZ-141 — Typed decision with bounded output repair

## Scope and reuse

- Dependencies: ELZ-033, ELZ-002, ELZ-115, ELZ-079, ELZ-114
- Output: `workflow/output-repair` (module `Elzoo.OutputRepair`) and `workflow/typed-decision` (module `Elzoo.TypedDecision`); release V1B; bot-platform wave 2. One task, two Piece directories.
- Owned paths: `pieces/workflow/output-repair/**`, `pieces/workflow/typed-decision/**` and their index/generated changes under AGENTS.md section 3.

Admit RC-55. `workflow/output-repair` is a pure policy. It owns the repair bound, the violation list and the names of the failures. `workflow/typed-decision` is a pure pattern step in the shapes of `workflow/pattern-step` (ELZ-114): a model gives one answer of a fixed set, or an answer that matches a schema. `integration/ai-text` decides valid or invalid. `core/payload-schema` (ELZ-115) gives the violation list. Neither Piece calls a model, reads a clock, stores a value or starts a process. The engine performs each action.

Implement only the acceptance groups below. Build `output-repair` first; `typed-decision` depends on it. Reuse `Elzoo.PayloadSchema`, `Elzoo.PatternStep` and Jason as they are on main. Add no options, layers, behaviours, generic helpers or future hooks. Edit no ready Piece, shared path, pin or CI file. Ask the coordinator before any expansion. The independent reviewer flags unrequested features for removal.

Reuse facts, checked on main (`pieces/integration/ai-text/lib/elzoo/ai_text/adapter.ex` and the two provider Pieces): ai-text gives `structured` as `nil`, `{:valid, value}` or `{:invalid, :missing | :schema_mismatch | :invalid_json}`, with no paths. Both ready providers put the raw text in `content` and give the same text to that check. So an empty output arrives as empty `content` with `{:invalid, :invalid_json}`, not with `:missing`. Both ready providers refuse structured output together with tools.

## Model-call boundary

No Piece on main says how a pattern sees a model call. This task fixes the part that it reads. Each wave-2 task that asks for a model call uses the same values.

- The action: kind `model_call`, `schema_id` `elzoo/ai-text-request`, `schema_version` 1 (the command schema of ai-text). The payload is the request object of `Elzoo.AiText.Request`, as a decoded JSON object.
- The completed outcome: `schema_id` `elzoo.ai-text.result`, `schema_version` 1. The payload is the JSON view of the completed map of ai-text. This task reads three members and no other:
  - `"content"`: a string.
  - `"structured"`: `null`, `{"valid": value}` or `{"invalid": "missing" | "schema_mismatch" | "invalid_json"}`.
  - `"finish"`: `"stop"`, `"length"`, `"tool_calls"`, `"content_filter"`, `"refusal"` or `{"other": text}`.
- The model-call binding of the host makes this view from the outcome that ai-text gives to its sink, and changes none of the three values. That translation is a host Need, not a part of this task.

## `workflow/output-repair`: the bound, the violation list, the failures

`Elzoo.OutputRepair.decide(checked_schema, port, completed, used, bound)`:

- `checked_schema` and `port`: the value of `Elzoo.PayloadSchema.build(port, schema)` and its output Port, for the same schema object that the request carried as `output_schema`.
- `completed`: a map with `content`, `structured` and `finish` in the terms of ai-text. `structured` is `{:valid, value}` or `{:invalid, :missing | :schema_mismatch | :invalid_json}`. `finish` is `:stop | :length | :tool_calls | :content_filter | :refusal | {:other, text}`. Other members are not read.
- `bound`: the largest number of repair requests, an integer 0 to 8, required, with no default. `used`: the repair requests already made, 0 to `bound`.

It returns the result of the first rule that holds:

1. An operand outside these shapes, `structured: nil` included: `{:error, :invalid_input}`.
2. `finish` is `:length`: `{:fail, :length, []}`, also when the cut text parses.
3. `finish` is not `:stop`, or `structured` is `{:invalid, :missing}`, or `content` is empty or only whitespace: `{:fail, :no_answer, []}`.
4. Let A be: `structured` is `{:valid, value}`. Let B be: `content` decodes with Jason, and `Elzoo.PayloadSchema.check(checked_schema, port, decoded)` is `:ok`. A and B: `{:accept, value}`. Exactly one of them: `{:fail, :validator_disagreement, []}`.
5. Neither A nor B. The violation list is: the list of the `{:violations, list}` error of the check, unchanged; or `[%{path: [], code: :invalid_json}]` when `content` does not decode; or `[]` for any other error of the check. With `used < bound`: `{:repair, violations}`. Otherwise: `{:fail, :invalid_at_bound, violations}`.

Only rule 5 leads to a repair. A refusal, an empty output, a cut output and a disagreement fail at once. No rule returns a value that both checks did not accept: no nearest member, no default, no trimmed or case-folded text.

`Elzoo.OutputRepair.render(violations)` gives the text that a repair request carries. Lines are joined by one newline: first `The last output did not match the required schema.`; then one line `<path>: <code>` for each violation, in list order; last `Answer again with one JSON value that matches the schema and nothing else.` A path is `$`, then `.*` for each `:key` segment and `[n]` for each index `n`. The text holds no part of the output.

## `workflow/typed-decision`: the pattern step

`Elzoo.TypedDecision.new(spec)` returns `{:ok, state}` or `{:error, :invalid_set | :invalid_schema | :invalid_spec}`. `spec` is a map with exactly these members:

- `id`: UTF-8 text of 1 to 128 bytes. The caller keeps it unique in the Run. Action identities derive from it.
- `request`: the base request object of ai-text, with a `"messages"` list and no `"output_schema"`. It holds the question.
- `port`: the output Port of the answer (a `core/port` map). The caller keeps one meaning for each `(schema_id, schema_version)`.
- `answer`: `{:set, members}` or `{:schema, schema}`. A set has two or more members, each a different nonempty UTF-8 text. A set with one member, with no member or with a repeated member is `:invalid_set`. The step turns a set into the schema `{"type": "object", "properties": {"answer": {"enum": members}}, "required": ["answer"], "additionalProperties": false}`. A schema that `PayloadSchema.build(port, schema)` refuses is `:invalid_schema`.
- `repairs`: the `bound` of output-repair, 0 to 8.

Any other fault is `:invalid_spec`. The state is opaque plain data (maps, lists, tuples, atoms, numbers, binaries; no struct, function or compiled schema), so that an engine can keep it. Document its form for source-copy ownership. `step/2` builds the checked schema again from the stored schema object.

`Elzoo.TypedDecision.step(state, input)` returns `{:Transition, new_state, :none | {:some, request}}`: the `core/operator` shape. `input` and `request` are the neutral maps of `Elzoo.PatternStep`. Each request passes `PatternStep.decode/1` and holds exactly one action.

| State | Input | Result |
| --- | --- | --- |
| new | `start` | call 0; waiting |
| waiting | `action_outcome` of the open call, `completed` | by `OutputRepair.decide/5`: accept gives finish `decided`; repair gives the next call; fail gives finish `failed` |
| waiting | `action_outcome` of the open call, `late` | no change, no request |
| waiting | `action_outcome` of the open call, each other class | finish `failed` with reason `call_not_completed`; never a second try |
| new, waiting | `cancel`, `run_ended` | closed, no request |
| any | each other input, an outcome for another action, an input that `PatternStep.decode/1` refuses | no change, no request |

After a finish request the state is closed. The step reads neither `at_ms` nor the payload of `start`.

- Call `n` (0 for the first call, then one for each repair) is the action `%{"id" => id <> ":call:" <> n, "kind" => "model_call", "schema_id" => "elzoo/ai-text-request", "schema_version" => 1, "payload" => request}`. The first request is the base request with `"output_schema"` added. A repair request is the same, with two messages added at the end: `%{"role" => "assistant", "text" => content}` (the last output, unchanged) and `%{"role" => "user", "text" => OutputRepair.render(violations)}`. It carries the last output and the last violations only.
- Each repair is one `model_call` action, alone in its own request, with a new identity. The step makes no call itself and never puts two calls in one request. So the engine charges each call and can refuse each call.
- A completed outcome has the schema pair and the three members of the boundary above. If it does not, or if `decide/5` returns `:invalid_input`, the step finishes with reason `malformed_result`.
- The finish action is `%{"id" => id <> ":finish", "kind" => "finish", "schema_id" => "elzoo.typed-decision.result", "schema_version" => 1, "payload" => result}`. `result` is exactly `%{"status" => "decided", "value" => value, "repairs" => used, "action_id" => call_id}` or `%{"status" => "failed", "reason" => reason, "violations" => list, "outcome" => class, "repairs" => used, "action_id" => call_id}`.
  - `value`: for a set, the member text; for a schema, the value that ai-text validated.
  - `reason`: `"length"`, `"no_answer"`, `"validator_disagreement"`, `"invalid_at_bound"`, `"call_not_completed"` or `"malformed_result"`.
  - `violations`: maps with exactly `"path"` and `"code"`. A path segment is `"*"` for a `:key` and the integer for an index. A code is `"schema_mismatch"` or `"invalid_json"`.
  - `outcome`: the outcome class of the last call. `call_id`: the identity of the last call.

## Host Needs and Limits

Needs: an engine that records each input before the step reads it, and that charges and checks each action; the model-call boundary above, performed through `integration/ai-text`; a Run-wide unique `id`; one meaning for each answer Port pair; a base request that leaves room, inside the bounds of ai-text, for one echoed output and one repair text.

Limits: an answer that matches the schema is not a correct answer. A model call that did not complete is never tried again here. A repair request that passes a bound of ai-text or of the engine comes back as a refused outcome and ends as `call_not_completed`. No provider is called or tested: each input of a test is a literal neutral map. No tools in a typed decision. A finish with status `failed` is not evidence of completion. No engine claim: with the ready `assembly/run-engine`, the outcome of a nested callable does not carry the finish payload of the child, so a parent pattern that needs the value calls `step/2` inside its own step and reads the finish request. Telemetry, Config and Control are not applicable: pure functions over intrinsic operands.

## Named acceptance groups

1. **`outside_the_set`**: an answer that is not a member, a member in another letter case included. With a repair left: one repair request with the violation list. At the bound: `failed`, `invalid_at_bound`. No member is returned as the value in either case.
2. **`valid_after_one_repair`**: an invalid output, then a valid one: status `decided`, `repairs` 1. The second request holds the first output and the rendered violations.
3. **`invalid_at_bound`**: two invalid outputs with different violations and `repairs: 1`: status `failed`, `invalid_at_bound`, with the violations of the last output. An output that is not JSON gives the one `invalid_json` violation. With `repairs: 0` the first invalid output fails.
4. **`refusal_or_empty`**: finish `refusal`; finish `content_filter`; finish `stop` with empty content and `{"invalid": "invalid_json"}` (what the ready providers give); `{"invalid": "missing"}`. Each is `failed`, `no_answer`, with no repair request, also when repairs are left.
5. **`finish_length`**: finish `length` is `failed`, `length`, with no repair request, also when the cut text is valid for the schema.
6. **`validators_disagree`**: `{"valid": value}` with content that the schema check refuses, and `{"invalid": "schema_mismatch"}` with content that the schema check accepts. Each is `failed`, `validator_disagreement`, with no value and no repair request.
7. **`repair_calls_visible`**: with `repairs: 2`, two invalid outputs and one valid output give exactly three requests, each with one `model_call` action and the identities `…:call:0`, `…:call:1`, `…:call:2`, then one finish request. A repair call that comes back `out_of_budget` gives `failed`, `call_not_completed`, outcome `out_of_budget`, and no further call. The same holds for `refused` and `unknown`.
8. **`single_member_set_refused`**: `new/1` refuses a set with one member, with no member and with a repeated member as `:invalid_set`; a schema that does not build as `:invalid_schema`; a bound of 9 and a request that holds `"output_schema"` as `:invalid_spec`.
9. **`deterministic_replay`**: the same recorded inputs from the same state give equal states and equal requests on a second run, compared as terms. Each input kind of pattern-step v1 has a defined result (the table). Each state is plain data.
10. **`laws_and_example`**: the selected Cure laws below and their source audit pass. One small checked example in each Piece; the example of typed-decision shows a set decision with one repair.

Negative controls, each a temporary edit that is never committed: (a) rule 5 of `decide/5` returns a repair when `used` equals `bound`: `invalid_at_bound` must fail; (b) rule 4 accepts the decoded content when only B holds: `validators_disagree` must fail.

## Evidence

- Proof: Cure owns the decision table of output-repair over supplied classifications: the finish class (stop, length, other), answered, A, B and repairs left. Selected laws on that production decision: an output cut by length fails for every value of the other operands; no answer fails for every value of A, B and repairs left; a disagreement fails for both values of repairs left; with no repair left, an invalid output is `invalid_at_bound` and never a repair. If the pinned compiler cannot express a selected law, ask the coordinator; do not weaken it silently.
- Type: the pinned Cure compiler checks that source.
- Test: the ten named groups and the two negative controls. JSON decoding, the schema check, the render rule and the whole of typed-decision are Elixir and have tests only. Finite scenarios, not a universal proof.
- Upstream: jsv 0.27.0 through `core/payload-schema`; Jason 1.4.5; the ready Contracts of `workflow/pattern-step` and `integration/ai-text`.
- Assumptions: the Needs above. No monitored claim.

Run the tests of both Pieces, then `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`. Record laws, scenarios, upstream facts and assumptions apart. One independent review checks the body against the exact diff.
