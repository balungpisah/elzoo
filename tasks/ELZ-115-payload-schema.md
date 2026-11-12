# ELZ-115 — Typed payload check at a Port

- Dependencies: ELZ-033, ELZ-002, ELZ-079, ELZ-083

## Responsibility and scope

Implement RC-44 as `core/payload-schema`: Port-bound payload checking with bounded redacted violations, shared by P13 module functions, recipe nodes, tool arguments (RC-52) and model outputs (RC-55). Upstream validators do not supply this Port binding/result Contract.

Own only `pieces/core/payload-schema/**` and its index rows/generated files under AGENTS.md section 3. Ready callers, validators, results and dependencies stay unchanged. No shared runtime, root tests, pins, `mix.exs`, `mix.lock` or CI edits. Depend on `core/port`; use JSV 0.27.0/Jason 1.4.5 directly. ex_json_schema 0.11.5 is comparison-only; declare copied-test providers using existing conventions.

Implement only the acceptance below. Use existing upstream/repository facilities first. Add no extra options, layers, behaviours, generic helpers or future hooks. Keep tests to named scenarios. Ask the coordinator before scope expansion. The independent reviewer flags unrequested features and needless abstractions for removal.

## Interface and invariants

One public module, `Elzoo.PayloadSchema`, with two functions:

- `build(port, schema)` returns `{:ok, checked_schema}` or `{:error, :invalid_port | :invalid_schema}`. Reuse `Elzoo.Port.decode/1` for the exact four-field string-keyed Port map. Schema is a decoded JSON Schema object, not a module, callback, struct or raw JSON document. The opaque, immutable, caller-owned value binds `(direction, schema_id, schema_version)`, not local Port `id`. Different named Ports can share the same Contract; input and output have separate bindings.
- `check(checked_schema, port, payload)` returns `:ok`, `{:error, :invalid_port | :port_mismatch | :version_mismatch | :invalid_payload | :too_large | :too_deep | :validation_failed}`, or `{:error, {:violations, list}}`. Decode the supplied Port, compare direction/schema ID, then version, before inspecting payload. Wrong direction/schema ID is `:port_mismatch`; unequal positive versions give `:version_mismatch`. No fallback, registry or version negotiation. Checked schemas must come from `build/2`; forged internals are outside the Contract.

Retain the original payload: unknown fields pass/fail as declared, never disappear. No defaults, coercions or codec. JSV's docs and a pinned probe show `validate(3.0, integer_schema, cast: false)` returns `{:ok, 3}`: discard the successful value.

## Fixed bounds and redaction

- Payloads: null/booleans, integers, finite floats, UTF-8 strings, proper lists and non-struct maps with UTF-8 string keys. No atom-key conversion or automatic JSON parsing: a binary payload is a string, not a document.
- Maximum size: **65,536 bytes**, inclusive, in Jason's default compact JSON encoding. Check representation/nesting before encoding and size before JSV; return `:invalid_payload` or `:too_large`. Reuse Jason, not a custom serializer.
- Maximum container depth: **32**, inclusive. Scalar root depth is 0; each map/list adds 1, including the root container. Reject the first container exceeding 32 as `:too_deep`, before descending further. No configurable limits.
- At most **16 violations**, each exactly `%{path: segments, code: :schema_mismatch}`. Root path is `[]`; replace every object-key segment with `:key`, retaining array positions as nonnegative integers. A failure in an object's property inside the first element of a root property's array has path `[:key, 0, :key]`. Paths have at most 32 segments. These structural paths are not dereferenceable JSON Pointers; repetitions are possible. No exhaustive-list, total-count or ordering guarantee. Truncation never means success.
- Emit no logs or telemetry. Return no library messages, exceptions, payload fragments, key names, schema locations, required/additional-property arguments or raw JSV errors. Redact all object keys, including schema-declared names. Use JSV's existing error representation/normalizer internally and project only admitted path/code fields. If validation cannot produce the admitted result, return fixed `:validation_failed`, not a fabricated success.

JSV errors hold `data`, `args`, `data_path` (`deps/jsv/lib/jsv/validator/error.ex`); normalized messages/locations also expose keys. Bounds cover accepted data/results, **not** encoding allocation, JSV errors, regex/schema complexity, CPU or memory. Add no isolation, timeout or complexity engine.

## Reuse, Needs and limits

Use `JSV.build` with `resolver: [], formats: false, atoms: false, warnings: :silence`, and validate with `cast: false`, following `pieces/integration/ai-text/lib/elzoo/ai_text/schema.ex` but silencing schema warnings. Default dialect is 2020-12; explicit `$schema` must be `https://json-schema.org/draft/2020-12/schema`.

The schema is host-approved application data, not an unreviewed tool-discovery descriptor. The host owns truthful identities, consistent schema meaning per pair and approved schema complexity. No global registry or digest. No injected runtime Need or external I/O.

`resolver: []` still appends JSV's Embedded/Internal resolvers; `deps/jsv/lib/jsv/resolver/internal.ex` documents that `jsv:module:...` invokes `json_schema/0`. Reject non-fragment `$ref`/`$dynamicRef` values before build, including module references, as `:invalid_schema`. A conservative recursive map/list scan following `pieces/integration/mcp-client/lib/elzoo/mcp_client/snapshot.ex` suffices; document that it also refuses those reserved keys inside literal schema data. Allow local references and the embedded standard meta-schema. No custom resolvers, vocabularies or executable schema inputs.

ai-text still decides structured outputs/tool proposals; mcp-client decides pre-send admission. RC-52/RC-55 own disagreement outcomes; do not implement/bypass them. Reuse Port's Cure descriptor policy and the direct Jason usage of `integration/json`, not another wrapper/provider evaluation.

Only caller-owned immutable schema state; no process, cache, persistence, effects or delivery guarantee. Telemetry, Config and Control are `not_applicable`: no observations, selectable settings or lifecycle. Tests ground the boundary; pinned libraries/Port are upstream grounding, not a new Cure law or universal proof.

## Pinned validator fit

Exercised at the pins above: JSV uses ai-text settings, Ex direct resolve/validate, Snapshot the ready helper. Scalar/array cases concern the helper, not full MCP argument admission. `invalid` means validation refusal.

| Schema JSON | Payload JSON | JSV | Ex | Snapshot |
| --- | --- | --- | --- | --- |
| `{"type":"integer"}` | `3` | valid | valid | valid |
| `{"type":"integer"}` | `"3"` | invalid | invalid | invalid_arguments |
| `{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object"}` | `{}` | valid | UnsupportedSchemaVersionError at build | invalid_arguments |
| `{"type":"object","properties":{"ok":{"type":"integer"}},"unevaluatedProperties":false}` | `{"ok":1,"extra":2}` | invalid | valid | valid |
| `{"type":"array","prefixItems":[{"type":"integer"}]}` | `["wrong"]` | invalid | valid | valid |
| `{"type":"string","format":"email"}` | `"not-an-email"` | valid | invalid | invalid_arguments |
| `{"$id":"urn:example:payload","type":"object"}` | `{}` | valid | valid | invalid_arguments |

Dialect differs at build; unevaluated properties/prefix items omit `$schema` to expose defaults; JSV disables format assertions. `$id` differs only in snapshot policy. These cases support JSV here, not general equivalence or ready-caller changes.

## Acceptance and evidence

1. **Declared types:** one valid and one wrong-type payload for string, number, integer, boolean, null, array and object. Include integer-schema `3.0` without replacement and rejection of `"3"`. Malformed Port/schema/payload shapes return fixed errors. Local references work; external/module references fail without invoking a target. One checked example binds input/output values and uses the same checking API for the four boundary roles, without executing functions, recipes, tools or models.
2. **Unknown fields:** the same extra-key object passes when allowed and fails with `additionalProperties: false`; preserve the original object in both cases, without defaults/coercion.
3. **Size/depth:** 65,536 encoded bytes pass the size gate; 65,537 fail. Depth 32 passes and 33 fails, covering map/list nesting, before JSV validation. Claim no upstream time/memory bound.
4. **Violation bound:** more than 16 independently invalid array positions produce 1..16 admitted entries, each path at most 32 segments. Check the nested object/array redacted path. Truncation must not turn a mismatch into success.
5. **Version refusal:** version 1 rejects version 2 despite an otherwise valid payload. Distinguish schema ID/direction mismatch. Different Port IDs with equal direction/schema pair work; no guessed/latest version.
6. **Redaction:** distinct secret sentinels in a value and dynamic key (including `/` and `~`) appear in neither errors nor captured logs/events. Cover additional properties, a missing required property and nested validation. Temporarily remove production key redaction, show this scenario fails, restore and rerun. No committed mutant or private-helper test.
7. **Divergence:** run the exact fit-table cases and integer controls against pinned libraries/settings; record schemas, payloads and build/validation/policy outcomes in README. No broad benchmark or compatibility theorem.

Use existing source-copy/export checks, not a new harness. Run `mix test pieces/core/payload-schema/test`, `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`. Follow AGENTS.md for index timing, evidence categories and one independent review of this task/exact diff. Record unavailable local checks and reasons; hosted CI supplies that evidence.

Parallel level-1 admission is allowed. Other small-gate merges wait for the RC-68 proof run; do not treat local tests as satisfying it. The coordinator owns serialized metadata/publication and the merge queue.
