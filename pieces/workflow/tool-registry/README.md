# workflow/tool-registry

`Elzoo.ToolRegistry` resolves a tool name that a model proposed to one callable,
over a snapshot of tool listings that the caller passes in. It owns three things:
the model-facing alias of a tool, the version of a descriptor and the resolution.
It lists nothing, dispatches nothing and has no process, clock or storage.
Finding a tool grants no permission: the engine checks authority, approval and
budget for every action. Ready `core/payload-schema` and `integration/ai-text`
are reused unchanged.

## Sources and descriptors

A source is a string-keyed map with exactly `"id"` (1 to 32 bytes of
`[a-zA-Z0-9_-]`, unique), `"kind"` (`"pinned_skill"`, `"host_listing"` or
`"other"`), `"callable"` (`"adapter"` or `"nested"`) and `"tools"` (a list of
descriptors, possibly empty). The kind comes only from the caller's own captured
source set; no descriptor content and no `refresh/3` changes it.

A descriptor has the discovery shape of `integration/mcp-client` for every kind:
exactly `"trust"` (must be `"untrusted"`), `"name"` (1 to 128 bytes of
`[A-Za-z0-9_.-]`, unique in its source), `"description"` (nil or UTF-8 text),
`"annotations"` (nil or a JSON object) and `"input_schema"` (a JSON object that
`Elzoo.PayloadSchema.build/2` accepts for the argument Port). Description and
annotations are carried, never interpreted. The trust stamp says that descriptor
text is data; it is not the source kind and gives no authority.

## Derived values

- **Alias.** `plain = id <> "_" <> name` when it matches `[a-zA-Z0-9_-]{1,64}`;
  otherwise the first 55 bytes of `plain` with each other byte replaced by `_`,
  then `_`, then the first 8 lowercase hex characters of
  SHA-256(`id <> <<0>> <> name`). It depends on the id and name only, never on
  other entries or listing order. Two tools with one alias refuse the call.
- **Version.** Lowercase hex SHA-256 of `Elzoo.AiText.Request.canonical/1` over
  the descriptor without `"trust"` (exactly `annotations`, `description`,
  `input_schema`, `name`; absent values are `null`).
- **Model-facing description.** nil or empty becomes the tool's own name; text
  over 4,096 bytes is cut to its longest whole-character prefix within 4,096
  bytes; other text passes unchanged. Neither the stamp nor this text enters
  the version.
- **Argument Port.** `%{"id" => alias, "direction" => "input", "schema_id" =>
  "elzoo.tool-registry.arguments." <> version, "schema_version" => 1}`.

## Interface

- `snapshot(sources)`: `{:ok, snapshot}` or the first failing reason in this
  order: `:invalid_source`, `:invalid_descriptor`, `:invalid_trust`,
  `:too_many_tools` (more than 64 tools in all sources; never cut),
  `:alias_collision`.
- `refresh(snapshot, source_id, descriptors)`: replaces the listing of one
  declared source (`:unknown_source` otherwise; it never adds or removes a
  source). The aliases the previous listing held and the fresh one does not
  become the removed set of that source, replacing its older removed set.
- `tools(snapshot)`: `%{"name" => alias, "description" => text, "input_schema" =>
  schema}` maps sorted by alias, the tool shape of ai-text.
- `resolve(snapshot, name)` / `resolve(snapshot, name, version)`: the first rule
  that holds: a listed alias is `{:resolved, tool}`, or `{:changed,
  listed_version}` when the held version differs; a name in a removed set is
  `:removed`; a name that is the own name of tools on two or more sources is
  `{:ambiguous, sorted_aliases}`, never the first match; otherwise `:unknown`
  (an own name on one source too). `tool` is `%{alias:, source:, source_kind:,
  callable: {:adapter | :nested, source_id, name}, tool:, version:,
  input_schema:}`.
- `check(tool, arguments)`: `:ok`, or `{:error, {:validator_disagreement,
  reason}}` with the unchanged error of `Elzoo.PayloadSchema.check/3`. It runs on
  arguments that the ai-text proposal check passed, so any error means the two
  checks disagree and the caller dispatches nothing. A `malformed` proposal has
  `arguments: nil` and is never checked here.
- `outcome_note(outcome)`: `:validator_disagreement` for mcp-client
  `{:refused, :invalid_arguments}` (its ex_json_schema admission refused what
  `check/2` passed; the refusal stays the outcome and the caller records the
  note), `:none` for every other outcome, `{:unknown, {:server_error,
  :invalid_arguments}}` included. No outcome becomes `:removed` or `:changed`.

Each refusal is a fixed atom and echoes no value; a refused call leaves the
caller's snapshot as it was.

## Snapshot form (for source-copy owners)

`{:ToolRegistry, sources, entries, removed}`, plain data only: `sources` is the
list of accepted source maps as given (the current listing in `"tools"`);
`entries` maps each alias to `{tool, model_facing_description}`; `removed` maps a
source id to its sorted removed aliases. A pattern can keep it in its state.
Values not produced by `snapshot/1` or `refresh/3`, and forged `tool` maps, are
outside the Contract.

## Grounding

- Proof: `Cure.Elzoo.ToolRegistry.decide/4` in `cure/elzoo/tool_registry.cure` is
  the production decision over four supplied Booleans (`live`, `differs`,
  `removed`, `many`). Selected laws: `live_differs_changed`, `not_live_removed`,
  `not_live_ambiguous`, `not_live_unknown`; so no not-live row is `Resolved`.
  They cover the decision only, not lookup or validation.
- Type: the pinned Cure compiler checks types and totality; the source audit
  finds no axioms, holes or unproved-total definitions.
- Test: `mix test pieces/workflow/tool-registry/test` runs seven named groups:
  `unknown_and_source_kind`, `same_name_two_sources`, `alias_grammar_and_bound`,
  `fresh_listing`, `one_validation_result`, `descriptor_rules`,
  `laws_and_example`. Lookup, alias, digest, description rule and map validation
  are Elixir with tests only. Finite scenarios, not a universal proof.
- Upstream: JSV 0.27.0 through `core/payload-schema`; the canonical encoding of
  `integration/ai-text`; Jason 1.4.5; SHA-256 of OTP `:crypto`.
- Example: `examples/tool_registry.exs` shows two sources, a fresh listing, one
  resolved call and one changed call.

## Needs and limits

Needs: a truthful source set and kinds; complete listings (a cut listing looks
like removals; the `truncated` flag of mcp-client discovery is the caller's to
read); host approval of each listed source, since a discovery schema is not
reviewed and `core/payload-schema` assumes approved schema complexity; a record
of each listing and outcome before use; the map from `{:adapter | :nested,
source, tool}` to a real Adapter binding or nested callable; authority, approval
and budget checks for every action.

Limits: no claim about the current tool set of a source. A change or removal
after the last listing is not detected: the tool still resolves and the
dispatched call's outcome stands. `:removed` covers the latest listing of a
source only; an older removal is `:unknown`. One refused descriptor refuses the
whole call. No bound on schema complexity, validation time or snapshot bytes. The
digest is stable for the pinned Jason and OTP; it is not RFC 8785. No content
mark, tool-result handling or instruction loading. Telemetry, Config and Control
are not applicable: pure functions over intrinsic operands.

Modules are application-owned under `Elzoo.ToolRegistry` and
`Cure.Elzoo.ToolRegistry`; redistributors rename them and the `:ToolRegistry`
tag. Apache-2.0; no new dependency or pin.
