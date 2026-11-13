# workflow/typed-decision

`Elzoo.TypedDecision` is a pure pattern step in the shapes of
`workflow/pattern-step`: a model gives one answer of a fixed set, or an answer
that matches a schema. `workflow/output-repair` decides accept, repair or fail.
The step calls no model, reads no clock, stores no value and starts no
process. The engine performs each action.

## `new(spec)`

`spec` is a map with exactly `id`, `request`, `port`, `answer` and `repairs`:

- `id`: UTF-8 text of 1 to 128 bytes, unique in the Run (caller's duty).
- `request`: the base ai-text request object, with a `"messages"` list and no
  `"output_schema"`.
- `port`: the output Port of the answer (`core/port` map, direction `output`).
- `answer`: `{:set, members}` (two or more different nonempty UTF-8 texts) or
  `{:schema, schema}`. A set becomes the schema
  `{"type": "object", "properties": {"answer": {"enum": members}}, "required": ["answer"], "additionalProperties": false}`.
- `repairs`: the bound of output-repair, 0 to 8.

Errors: `:invalid_set` (one member, no member, a repeated or non-text member),
`:invalid_schema` (`PayloadSchema.build/2` refuses), otherwise `:invalid_spec`.

The state is an atom-keyed plain map, owned by the copying application:
`%{phase: :new | :waiting | :closed, id:, request:, port:, answer: :set | :schema,
schema: schema_object, repairs: bound, used: repairs_made}`. It holds no
struct, function or compiled schema; `step/2` builds the checked schema again
from the stored object. The open call is `id <> ":call:" <> used`.

## `step(state, input)`

Returns `{:Transition, new_state, :none | {:some, request}}` (`core/operator`).
`input` and `request` are neutral PatternStep v1 maps; each request passes
`PatternStep.decode/1` and holds exactly one action.

| State | Input | Result |
| --- | --- | --- |
| new | `start` | call 0; waiting |
| waiting | `action_outcome` of the open call, `completed` | by `OutputRepair.decide/5`: accept gives finish `decided`; repair gives the next call; fail gives finish `failed` |
| waiting | `action_outcome` of the open call, `late` | no change, no request |
| waiting | `action_outcome` of the open call, each other class | finish `failed`, reason `call_not_completed`; never a second try |
| new, waiting | `cancel`, `run_ended` | closed, no request |
| any | each other input, an outcome for another action, an input that `PatternStep.decode/1` refuses | no change, no request |

After a finish the state is closed. `at_ms` and the `start` payload are not read.

- Call `n`: action `id:call:n`, kind `model_call`, schema
  `elzoo/ai-text-request` version 1, payload the base request with
  `"output_schema"` added. A repair call adds two messages at the end:
  `{"role": "assistant", "text": content}` (the last output, unchanged) and
  `{"role": "user", "text": OutputRepair.render(violations)}`; only the last
  output and violations.
- A completed outcome must have schema `elzoo.ai-text.result` version 1 and a
  payload with `"content"`, `"structured"` (`null`, `{"valid": v}` or
  `{"invalid": "missing" | "schema_mismatch" | "invalid_json"}`) and `"finish"`
  (`"stop"`, `"length"`, `"tool_calls"`, `"content_filter"`, `"refusal"` or
  `{"other": text}`); other members are not read. Otherwise, or when `decide/5`
  gives `:invalid_input`, the step fails with `malformed_result`.
- Finish: action `id:finish`, kind `finish`, schema
  `elzoo.typed-decision.result` version 1, payload
  `{"status": "decided", "value", "repairs", "action_id"}` or
  `{"status": "failed", "reason", "violations", "outcome", "repairs", "action_id"}`.
  For a set the value is the member text; for a schema, the value ai-text
  validated. Reasons: `length`, `no_answer`, `validator_disagreement`,
  `invalid_at_bound`, `call_not_completed`, `malformed_result`. A violation is
  `{"path", "code"}` with `"*"` for a key segment and the integer for an index.

## Grounding, Needs and Limits

Tests only: `mix test pieces/workflow/typed-decision/test` runs the groups
`outside_the_set`, `valid_after_one_repair`, `invalid_at_bound`,
`refusal_or_empty`, `finish_length`, `validators_disagree`,
`repair_calls_visible`, `single_member_set_refused`, `deterministic_replay` and
`laws_and_example` (the checked example `examples/typed_decision.exs`: a set
decision with one repair). The Cure laws are those of `workflow/output-repair`.
Finite scenarios, not a universal proof.

Needs: an engine that records each input before the step reads it and charges
and checks each action; the model-call boundary above, performed through
`integration/ai-text` (the host binding gives the JSON view of the completed
map and changes none of the three members); a Run-wide unique `id`; one meaning
for each answer Port pair; a base request that leaves room, inside the ai-text
bounds, for one echoed output and one repair text.

Limits: an answer that matches the schema is not a correct answer. A call that
did not complete is never tried again here; a repair request over a bound of
ai-text or of the engine comes back refused and ends as `call_not_completed`.
No provider is called or tested. No tools. A `failed` finish is not evidence of
completion. No engine claim: with the ready `assembly/run-engine`, a nested
callable outcome does not carry the child finish payload, so a parent pattern
that needs the value calls `step/2` inside its own step. Telemetry, Config and
Control are not applicable.

Module application-owned under `Elzoo.TypedDecision`. Apache-2.0; no new
dependency or pin.
