# ELZ-136 — Tool registry: one callable for a proposed tool name

## Scope and reuse

- Dependencies: ELZ-033, ELZ-115, ELZ-083, ELZ-079
- Output: `workflow/tool-registry`, one public module `Elzoo.ToolRegistry`; release V1B; bot-platform wave 2.
- Owned paths: `pieces/workflow/tool-registry/**` and its index/generated changes under AGENTS.md section 3.

Admit RC-52. The registry is pure functions over a snapshot of tool listings that the caller passes in. It owns three things: the model-facing alias of a tool, the version of a descriptor, and the resolution of a proposed name to one callable. It lists nothing, dispatches nothing and has no process, clock or storage. Finding a tool grants no permission: the engine checks authority, approval and budget for every action. First caller: the agent loop (ELZ-142, RC-56).

Implement only the acceptance groups below. Reuse `core/payload-schema` (ELZ-115), `integration/ai-text` (ELZ-079) and Jason as they are on main. Add no options, layers, behaviours, generic helpers, future hooks or tool framework. Edit no ready Piece, shared path, pin or CI file. Ask the coordinator before any expansion. The independent reviewer flags unrequested features for removal.

## Sources and descriptors (caller data)

A source is a string-keyed map with exactly four members:

- `"id"`: 1 to 32 bytes of `[a-zA-Z0-9_-]`, unique in the snapshot.
- `"kind"`: `"pinned_skill"`, `"host_listing"` or `"other"`. The caller takes it from its own captured source set. This member is the only origin of the source kind. No descriptor member, tool name, description, annotation or tool result changes it, and `refresh/3` cannot change it.
- `"callable"`: `"adapter"` (an Adapter call) or `"nested"` (a nested callable by name, for example a tool written in Lua).
- `"tools"`: a list of descriptors. It can be empty.

A descriptor has the five-member shape of `integration/mcp-client` discovery, for every source kind: exactly `"trust"`, `"name"`, `"description"`, `"input_schema"`, `"annotations"`.

- `"trust"` is the text `untrusted`. Any other value is refused. The stamp says that descriptor text is data. It gives and removes no authority, and it is not the source kind.
- `"name"`: 1 to 128 bytes of `[A-Za-z0-9_.-]` (the grammar of mcp-client), unique in its source. A source keeps its own names.
- `"description"`: `nil` or UTF-8 text. `"annotations"`: `nil` or a JSON object. Both are carried and never interpreted.
- `"input_schema"`: a JSON object that `Elzoo.PayloadSchema.build/2` accepts for the argument Port below.

## Alias, version, description and Port (derived, deterministic)

**Alias.** A function of the source id and the tool name only, never of other entries or of the order of a listing. Let `plain = id <> "_" <> name`. If `plain` matches `[a-zA-Z0-9_-]{1,64}`, the alias is `plain`. If not, the alias is: the first 55 bytes of `plain` with each byte outside `[a-zA-Z0-9_-]` replaced by `_` (all of it when it is shorter), then `_`, then the first 8 characters of the lowercase hex SHA-256 of `id <> <<0>> <> name`. So each alias is inside the tool-name grammar of ai-text and has at most 64 bytes. Two tools with one alias are a collision: the call is refused and no entry wins.

**Version.** 64 lowercase hex characters: the SHA-256 of `Elzoo.AiText.Request.canonical/1` over the descriptor without its `"trust"` member. That is the object with exactly `annotations`, `description`, `input_schema` and `name`, as listed; an absent value is JSON `null`. That function sorts object keys bytewise at each depth, writes no whitespace and encodes scalars with Jason. Write no second encoder. The trust stamp and the filled or cut description never enter the digest.

**Model-facing description.** ai-text needs text of at most 4,096 bytes. A description that is `nil` or empty becomes the own name of the tool. A longer one is cut to its longest prefix of whole UTF-8 characters that fits 4,096 bytes. Each other description passes unchanged.

**Argument Port.** `%{"id" => alias, "direction" => "input", "schema_id" => "elzoo.tool-registry.arguments." <> version, "schema_version" => 1}`. The schema identity changes with the version, so one pair has one meaning.

## Interface

The snapshot is an opaque value of plain data (maps, lists, tuples, atoms, numbers, binaries; no struct, function or compiled schema), so that a pattern can keep it in its state. Document its form for source-copy ownership. Each refusal is a fixed atom and echoes no value. A refused call changes nothing: the caller still holds its old snapshot.

- `snapshot(sources)` returns `{:ok, snapshot}` or `{:error, reason}`. The first failing check, in this order, gives the reason: `:invalid_source` (shape, id, kind, callable, a repeated id); `:invalid_descriptor` (shape, name, a repeated name in one source, description, annotations, a schema that `PayloadSchema.build/2` refuses, a value that is not JSON data); `:invalid_trust`; `:too_many_tools` (more than 64 tools in all sources together: refused, never cut); `:alias_collision`.
- `refresh(snapshot, source_id, descriptors)` replaces the listing of one declared source. It returns `{:ok, snapshot}` or `{:error, reason}`: the reasons above, or `:unknown_source` for an id that `snapshot/1` did not declare. It never adds or removes a source. The aliases that the previous listing of this source held and the fresh one does not hold become the removed set of the source. That set replaces the older removed set of the source. Other sources are unchanged.
- `tools(snapshot)` returns the listed tools in the tool shape of ai-text, sorted by alias: maps with exactly `"name"` (the alias), `"description"` (by the rule above) and `"input_schema"` (as listed).
- `resolve(snapshot, name)` and `resolve(snapshot, name, version)` return the result of the first rule that holds:
  1. `name` is the alias of a listed tool: `{:resolved, tool}`. With a `version` argument that differs from the listed version: `{:changed, listed_version}` instead. `version` is the version that the caller holds for that name, from an earlier resolution or from a recorded action.
  2. `name` is in a removed set: `:removed`.
  3. `name` is no alias and is the own name of tools on two or more sources: `{:ambiguous, aliases}`, sorted. Never the first match.
  4. Otherwise `:unknown`. An own name on one source only is also `:unknown`: the alias is the only model-facing name.

  `tool` is `%{alias: alias, source: id, source_kind: kind, callable: {:adapter | :nested, id, name}, tool: name, version: version, input_schema: schema}`. `kind` is the text of the source.
- `check(tool, arguments)` gives the one validation result of the arguments before dispatch. It builds the schema with the argument Port and returns `:ok` or `{:error, {:validator_disagreement, reason}}`, where `reason` is the unchanged error of `Elzoo.PayloadSchema.check/3`. `tool` comes from `resolve`; a forged map is outside the Contract.
- `outcome_note(outcome)` takes the Contract outcome of `integration/mcp-client` for a call: `{:completed, _}`, `{:refused, reason}` or `{:unknown, reason}`. It returns `:validator_disagreement` for `{:refused, :invalid_arguments}` and `:none` for each other outcome, `{:unknown, {:server_error, :invalid_arguments}}` included (the answer of a server after the send is not a local validator).

## Which check decides

`core/payload-schema` chose jsv 0.27.0, draft 2020-12, without casting. That is the validator of ai-text, with a stricter admission: an explicit `$schema` must be 2020-12, a reference must be a fragment, and a payload has at most 65,536 bytes and 32 levels.

- For a tool that an ai-text request declares, the proposal check of ai-text decides valid or invalid. A proposal with a `malformed` tag has `arguments: nil` and is never checked here.
- `check/2` runs on arguments that ai-text passed. A result other than `:ok` means that the two checks disagree. It is the explicit failure above, and the caller dispatches nothing.
- `integration/mcp-client` checks the same arguments again with ex_json_schema when it admits the call (`admission/3`, before an intent exists). The README of `core/payload-schema` lists schemas on which the two validators differ. An `invalid_arguments` refusal there, after `check/2` passed, stays the tool-call outcome. `outcome_note/1` names the disagreement, and the caller records it.
- The registry never turns an outcome into `:removed` or `:changed`. Those results come from a listing only.

## Host Needs and Limits

Needs: a truthful source set and truthful source kinds; complete listings (a cut or partial listing looks like removals, and the `truncated` flag of mcp-client discovery is the caller's to read); host approval of each listed source, because `core/payload-schema` assumes host-approved schema complexity and a discovery schema is not reviewed; the record of each listing and outcome before use; the map from `{:adapter | :nested, source, tool}` to a real Adapter binding or nested callable; authority, approval and budget checks for every action.

Limits: no claim about the current tool set of a source. A change or removal after the last listing is not detected: the tool still resolves, the call is dispatched and its outcome stands (for mcp-client an `unknown`). `:removed` covers the latest listing of a source only; an older removal is `:unknown`. One descriptor that is refused refuses the whole call. No bound on schema complexity, validation time or snapshot bytes: a caller that keeps the snapshot in pattern state owns that bound. The digest is stable for the pinned Jason and OTP; it is not RFC 8785. No content mark (RC-51 owns it), no tool-result handling, no loading of instructions (RC-56). Telemetry, Config and Control are not applicable: pure functions over intrinsic operands.

## Named acceptance groups

1. **`unknown_and_source_kind`**: a name that no entry holds is `:unknown`. One source of each kind resolves with its own kind text. A tool on an `other` source whose name, description and annotations copy those of a skill or of a listing tool still resolves with `other`. A descriptor with a sixth member is refused. `refresh/3` leaves the kind unchanged.
2. **`same_name_two_sources`**: the same tool name on two sources gives two aliases. Each alias resolves to its own source and callable. The bare name is `{:ambiguous, aliases}` with both aliases. Source `a` with tool `b_c` and source `a_b` with tool `c` are `:alias_collision`, in `snapshot/1` and in `refresh/3`.
3. **`alias_grammar_and_bound`**: the names `repo.search` and `repo_search` on one source get two different aliases. A 128-byte name gets an alias. Each alias matches `[a-zA-Z0-9_-]{1,64}` and is the same in another snapshot and in another order of the listing. `Elzoo.AiText.Request.decode/1` accepts the Jason-encoded bytes of a request that declares `tools(snapshot)`. 64 tools pass; 65 are `:too_many_tools`, in `snapshot/1` and in `refresh/3`.
4. **`fresh_listing`**: a descriptor differs in one content field in a fresh listing: `resolve/3` with the old version is `{:changed, new_version}`, with the new version it is resolved, and `resolve/2` gives the new version. A tool absent from the fresh listing is `:removed`; when a later listing holds it again, it resolves. A listing for an undeclared source is `:unknown_source`. A removal after the last listing: with no fresh listing the tool still resolves, and `outcome_note({:unknown, {:server_error, :other}})` is `:none`. Nothing is claimed as detected.
5. **`one_validation_result`**: valid arguments give `:ok`. Invalid arguments give `{:error, {:validator_disagreement, {:violations, list}}}` with the list of `core/payload-schema` unchanged. Arguments over 65,536 bytes give `{:error, {:validator_disagreement, :too_large}}`. `outcome_note({:refused, :invalid_arguments})` is `:validator_disagreement`; each other outcome of the mcp-client outcome table is `:none`.
6. **`descriptor_rules`**: a descriptor in the discovery shape is accepted. Trust `trusted` or `nil` is `:invalid_trust`; a descriptor with no trust member is `:invalid_descriptor`. The version of one fixed descriptor equals the SHA-256 of a canonical text that the test holds as a literal, and that text has no trust member. A change of each of the four content fields changes the version. A `nil` and an empty description become the own name. 4,096 bytes pass unchanged. 4,097 bytes with a multi-byte character on the boundary are cut on a character boundary. Two descriptors that differ only after byte 4,096 have equal model-facing descriptions and different versions.
7. **`laws_and_example`**: the selected Cure laws below and their source audit pass. One small checked example shows two sources, a fresh listing, one resolved call and one changed call.

Negative controls, each a temporary edit that is never committed: (a) rule 3 of `resolve` returns the first own-name match: `same_name_two_sources` must fail; (b) the alias rule drops the hash suffix: `alias_grammar_and_bound` must fail.

## Evidence

- Proof: Cure owns the resolution decision over four supplied Booleans: `live` (the name is the alias of a listed tool), `differs` (a version was given and is not the listed one), `removed`, `many`. Selected laws on that production decision: `decide(True, True, removed, many)` is `Changed` for every `removed` and `many`; each of the three not-live rows gives `Removed`, `Ambiguous` or `Unknown` for every value of the unused operands, so no not-live row is `Resolved`. If the pinned compiler cannot express a selected law, ask the coordinator; do not weaken it silently.
- Type: the pinned Cure compiler checks that source.
- Test: the seven named groups and the two negative controls. Lookup, alias, digest, description rule and map validation are Elixir and have tests only. Finite scenarios, not a universal proof.
- Upstream: jsv 0.27.0 through `core/payload-schema`; the canonical encoding of `integration/ai-text`; Jason 1.4.5; SHA-256 of OTP `:crypto`.
- Assumptions: the Needs above. No monitored claim.

Run the Piece tests, then `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`. Record laws, scenarios, upstream facts and assumptions apart. One independent review checks the body against the exact diff.
