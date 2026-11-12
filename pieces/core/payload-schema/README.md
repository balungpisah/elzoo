# core/payload-schema

Check a JSON payload at a Port without replacing the payload or exposing
validator diagnostics. The missing policy is Port binding and the bounded,
redacted result; JSV owns schema compilation and validation.

## Interface and Contract

`Elzoo.PayloadSchema.build(port, schema)` returns `{:ok, checked_schema}` or
`{:error, :invalid_port | :invalid_schema}`. The schema is a host-approved,
decoded JSON Schema object: no modules, callbacks, structs or raw JSON document.
The opaque immutable value belongs to the caller; do not inspect, forge or
persist its internals. Only values from `build/2` are admitted to `check/3`.

`Elzoo.PayloadSchema.check(checked_schema, port, payload)` returns `:ok`,
`{:error, :invalid_port | :port_mismatch | :version_mismatch | :invalid_payload |
:too_large | :too_deep | :validation_failed}`, or
`{:error, {:violations, list}}`.

Both calls reuse `Elzoo.Port.decode/1` for its exact four-field string-keyed
map. Checks compare direction and schema ID, then the positive version, before
inspecting the payload. Direction/schema ID disagreement is `:port_mismatch`;
unequal versions are `:version_mismatch`. Local Port IDs do not bind: different
named Ports may share the same direction/schema pair. Input and output remain
separate bindings. There is no fallback, registry or latest-version guess.

Payloads are null, booleans, integers, finite floats, UTF-8 strings, proper
lists, and non-struct maps with UTF-8 string keys. No atom-key conversion or
automatic parsing: a binary is a string, not a JSON document. Representation
and nesting are checked before Jason encodes, and size before JSV validates.
Default compact encoding must be at most **65,536 bytes**, inclusive. Container
depth is at most **32**, inclusive: scalar root depth is 0, and each map/list
adds 1, including the root container. The first container beyond 32 is refused
before descending into it. Limits are fixed, not options.

Unknown fields pass or fail as the schema declares; they never disappear.
No defaults, coercions or codec are supplied. JSV can return `{:ok, 3}` for
integer-schema `3.0` even with `cast: false`; this checker discards that value
and returns only `:ok`, leaving the caller's original value intact.

Each violation is exactly `%{path: segments, code: :schema_mismatch}`. At most
16 entries are returned, with paths of at most 32 segments. Root is `[]`;
every object key becomes `:key`, including declared names; array indices stay
nonnegative integers. A property inside the first element of a root property's
array has `[:key, 0, :key]`. These are structural paths, **not dereferenceable
JSON Pointers**; repetitions are possible. There is no exhaustive-list,
total-count or ordering guarantee. Truncation never converts failure to success.
If an admitted result cannot be produced, the result is `:validation_failed`.
No library messages, raw errors, exceptions, payload fragments, key names,
schema locations or required/additional-property arguments are returned.
No logs or telemetry are emitted.

## Reuse, trust and limits

JSV 0.27.0 is used with `resolver: [], formats: false, atoms: false,
warnings: :silence` and `cast: false` validation. Default dialect is 2020-12;
explicit `$schema` must be `https://json-schema.org/draft/2020-12/schema`.
Local fragment references and the embedded standard meta-schema work.
Because JSV always appends its Embedded/Internal resolvers, `resolver: []`
alone does not exclude executable `jsv:module:` references. A recursive map/list
scan refuses every non-fragment `$ref`/`$dynamicRef` before build, including
module references. It conservatively refuses these reserved keys inside literal
schema data too. No custom resolver, vocabulary or executable schema input is
accepted. Schema data is host-approved, not unreviewed discovery data.

The host owns truthful identities, consistent schema meaning per ID/version
pair and approved schema complexity. There is no digest or global identity
registry. Bounds cover accepted data and returned results, **not** encoding
allocation, JSV error allocation, regex/schema complexity, CPU or memory. There
is no timeout, isolation or complexity engine. No injected runtime Need or
external I/O; no process, cache, persistence, effects or delivery guarantee.
Telemetry, Config and Control are `not_applicable`.

Ready ai-text still decides structured outputs/tool proposals; ready mcp-client
still decides pre-send admission. RC-52/RC-55 own disagreement outcomes. None
of those callers, their results or their validators is changed here.
`examples/elzoo/payload_schema.exs` checks values for module-function, recipe-node,
tool-argument and model-output roles through the same API with explicit input
and output bindings; it executes none of those boundaries.

## Pinned validator fit and evidence

The test `pinned validator fit cases and integer controls have the documented
divergence` exercises JSV 0.27.0 with the settings above and ex_json_schema
0.11.5 using direct resolve/validate. The repository-only Snapshot probe uses
the unchanged `Elzoo.McpClient.Snapshot.check/3` with a single-tool snapshot.
Scalar/array rows concern that helper, not full MCP argument admission.
`invalid` means validation refusal; all builds succeed except the stated Ex
dialect refusal. Snapshot reports policy/validation refusal as `invalid_arguments`.

| Schema JSON | Payload JSON | JSV | Ex | Snapshot |
| --- | --- | --- | --- | --- |
| `{"type":"integer"}` | `3` | valid | valid | valid |
| `{"type":"integer"}` | `"3"` | invalid | invalid | invalid_arguments |
| `{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object"}` | `{}` | valid | UnsupportedSchemaVersionError at build | invalid_arguments |
| `{"type":"object","properties":{"ok":{"type":"integer"}},"unevaluatedProperties":false}` | `{"ok":1,"extra":2}` | invalid | valid | valid |
| `{"type":"array","prefixItems":[{"type":"integer"}]}` | `["wrong"]` | invalid | valid | valid |
| `{"type":"string","format":"email"}` | `"not-an-email"` | valid | invalid | invalid_arguments |
| `{"$id":"urn:example:payload","type":"object"}` | `{}` | valid | valid | invalid_arguments |

Integer control `3.0` validates in all three; JSV returns integer `3`, which this
Piece discards. String `"3"` is refused, not coerced. Dialect differs at build;
unevaluated properties/prefix items omit `$schema` to expose defaults; JSV
disables format assertions. `$id` differs only in Snapshot policy. These finite
observations support JSV here, not a compatibility theorem or broad benchmark.

`test/elzoo/payload_schema_test.exs` covers declared types, malformed shapes,
local/reference refusal, unknown fields, size/depth boundaries, violation bound,
version/binding refusal, redaction and the checked example. Redaction uses
distinct value/dynamic/declared key sentinels (including `/` and `~`), captures
logs and traces telemetry execution during the calls. A temporary production
mutation retaining object keys makes that scenario fail; restored code passes.
Tests ground this boundary; Port's Cure policy and pinned validators/Jason are
upstream grounding, not a new Cure law or universal proof. No monitored runtime
claim is made.

## Consumption

Use `mix elzoo.take core/payload-schema --to ../my_app` and the existing source
copy/install/receipt checks. The closure includes `core/port` and its Cure build
support. Declare recorded providers from the install snippet: ex_json_schema
and telemetry are for copied tests, not production validation. The Snapshot
comparison is repository-only; it adds no mcp-client runtime dependency.
The copied example/test paths follow the existing bundle layout.

The application owns one coordinated revision of `Elzoo.PayloadSchema` and the
Port modules. Redistributing libraries must rename modules/MFAs and the opaque
module tag, and deliberately rename/translate Port's erased `:Descriptor` tag.
No automatic namespace isolation is supplied. Source is Apache-2.0; pins and
upstream licenses are recorded in the catalogue. See [consuming](../../../docs/consuming.md).
