# workflow/output-repair

`Elzoo.OutputRepair` is a pure policy. It owns the repair bound, the violation
list and the names of the failures after a model call with a structured output
schema. `integration/ai-text` decides valid or invalid; `core/payload-schema`
gives the violation list. This Piece calls no model, reads no clock, stores no
value and starts no process.

## `decide(checked_schema, port, completed, used, bound)`

- `checked_schema`, `port`: the value of `Elzoo.PayloadSchema.build(port, schema)`
  and its output Port, for the same schema object that the request carried as
  `output_schema`.
- `completed`: a map with `content` (UTF-8 text), `structured`
  (`{:valid, value}` or `{:invalid, :missing | :schema_mismatch | :invalid_json}`)
  and `finish` (`:stop | :length | :tool_calls | :content_filter | :refusal |
  {:other, text}`), in the terms of ai-text. Other members are not read.
- `bound`: the largest number of repair requests, an integer 0 to 8, required.
  `used`: the repair requests already made, 0 to `bound`.

The result is that of the first rule that holds:

1. An operand outside these shapes, `structured: nil` included:
   `{:error, :invalid_input}`.
2. `finish` is `:length`: `{:fail, :length, []}`, also when the cut text parses.
3. `finish` is not `:stop`, or `structured` is `{:invalid, :missing}`, or
   `content` is empty or only whitespace: `{:fail, :no_answer, []}`.
4. A: `structured` is `{:valid, value}`. B: `content` decodes with Jason and
   `PayloadSchema.check(checked_schema, port, decoded)` is `:ok`. A and B:
   `{:accept, value}`. Exactly one: `{:fail, :validator_disagreement, []}`.
5. Neither: the violations are the list of the `{:violations, list}` error of
   the check, unchanged; or `[%{path: [], code: :invalid_json}]` when `content`
   does not decode; or `[]` for any other error of the check. With
   `used < bound`: `{:repair, violations}`; otherwise
   `{:fail, :invalid_at_bound, violations}`.

Only rule 5 leads to a repair. No rule returns a value that both checks did not
accept: no nearest member, no default, no trimmed or case-folded text.

## `render(violations)`

The text that a repair request carries, lines joined by one newline:
`The last output did not match the required schema.`; one line
`<path>: <code>` for each violation in list order; then
`Answer again with one JSON value that matches the schema and nothing else.`
A path is `$`, then `.*` for each `:key` segment and `[n]` for each index. The
text holds no part of the output.

## Grounding

Cure owns the decision table (`cure/elzoo/output_repair.cure`, `decide/5`) over
supplied classifications: finish class (stop, length, other), answered, A, B
and repairs left. The Elixir function computes these and calls the production
Cure decision. Selected laws on that decision: `length_fails`,
`other_finish_no_answer`, `unanswered_no_answer`, `valid_only_disagrees`,
`decoded_only_disagrees`, `invalid_at_bound` and `no_repair_at_bound`. The
pinned compiler checks types and totality; the source audit finds no axioms,
holes, unresolved, unaudited, opaque or unproved-total definitions and zero
absurd. Compiler soundness is upstream grounding.

JSON decoding, the schema check, operand validation and the render rule are
Elixir and have tests only: `mix test pieces/workflow/output-repair/test`.
Negative controls (temporary edits, never committed): a repair at
`used == bound` fails `invalid_at_bound`; accepting decoded content when only B
holds fails `validators_disagree`. The checked example
`examples/output_repair.exs` shows a repair, the failure at the bound and an
accept. Finite scenarios, not a universal proof.

Upstream: Jason 1.4.5; jsv 0.27.0 through `core/payload-schema`. Assumptions:
the caller passes the ai-text result unchanged, the checked schema of the same
schema object and a truthful `used`. An answer that matches the schema is not a
correct answer. Telemetry, Config and Control are not applicable: pure
functions over intrinsic operands.

Modules are application-owned under `Elzoo.OutputRepair` and
`Cure.Elzoo.OutputRepair`; redistributors rename both. Apache-2.0; no new
dependency or pin.
