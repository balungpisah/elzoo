# ELZ-162 — Schema-checked tenant settings with credential references

## Scope and reuse

- Dependencies: ELZ-033, ELZ-115, ELZ-105
- Output: `domain/recipe-config`; release V1B; RC-61 settings portion.
- Owned paths: `pieces/domain/recipe-config/**` and its index/generated changes under AGENTS.md section 3.

Draft only; not published or claimable. The concrete descriptor and fixed
bounds below are admission proposals for owner review.

Check tenant settings against an explicit caller-supplied schema descriptor,
the same descriptor a later recipe-package declares. Secret settings hold only
credential references, never credential values. One pure boundary, independent
of recipe-graph and recipe-package: package loading is not needed to call it.

Implement only the named acceptance groups below. Add no extra features,
settings store, environment lookup, defaults, coercion, merge layers, secret
resolver, package reader, new schema engine, options or hooks. Change no ready
Piece, shared source, dependency pin or CI file. Use literal maps, no fixtures.

Reuse `core/payload-schema` build/check unchanged, including Port identity,
host-approved schema restrictions and redacted validation. Reuse the exact
request shape of `integration/secrets` for references: ref/scope identifiers
1..128 bytes, exact byte equality, no hierarchy. It has no public reference-only
validator; check that small transport shape here, do not call `Secrets.resolve`
to validate settings and do not add an API to that ready Piece.

## Interface: `Elzoo.RecipeConfig`

Two functions: `build(descriptor)` returns `{:ok, checked_schema}` or
`{:error, reason}`; `check(checked_schema, settings)` returns
`{:ok, settings}` with the exact original value or `{:error, reason}`.
Checked schemas are opaque, immutable, caller-held; check accepts only values
returned by build. No serialization, caching or third public function is needed.

Descriptor is an exact string-keyed map with `version`, `id`, `revision`, `port`,
`schema`, `secrets`. Version is 1; identity is `(id, revision, version)`, id is
1..128 UTF-8 bytes and revision 1..2^31-1. The host preserves immutable meaning
per identity; no digest or registry is invented. Port is the existing four-field
input Port declaration; schema is a host-approved decoded draft-2020-12 JSON
Schema object. Use `PayloadSchema.build/2`, then its `check/3` on each settings
value with this exact Port, not a second validator.

V1 settings are a flat object of named setting values; ordinary values may be
nested JSON data within PayloadSchema's bounds. Schema must declare root
`type: "object"`, `properties` and `additionalProperties: false`; declared
settings are only those properties. `required` decides which are mandatory.
Refuse descriptor forms which permit an unlisted top-level key (including
root patternProperties or unevaluatedProperties); do not silently rewrite the
schema. Nested property validation remains upstream-owned. No implicit optional
value, truncation, coercion or unknown-field dropping.

`secrets` is a unique list of declared top-level property names, at most 64.
Each such property's schema must be exactly the reference shape: object with
required `ref` and `scope`, no extra keys, both strings with minLength 1 and
maxLength 128. That JSON character limit is supplemented by the byte limit
below, never substituted for it. No inline secret default, enum, const,
credential wrapper or arbitrary secret schema is allowed there. Nonsecret
property schemas have no defaults applied by this Piece. The later package
declares this descriptor unchanged; there is no package dependency here.

In settings, a present secret property is exactly `{"ref": binary,
"scope": binary}` with each binary 1..128 bytes, matching the existing Secrets
request identifiers after string-to-fixed-atom-key translation by trusted
injection code. No arbitrary atom creation. Do not resolve, reveal or verify
existence, authority, expiry or current value. A raw string, `value` member,
extra key, struct or malformed ref/scope is refused. Presence of a well-shaped
reference does not authenticate anyone. A caller can lie by putting credential
bytes in a reference identifier; secret exclusion and truthful labels remain
host Needs, not a content detector.

Build failures use fixed tags `:invalid_descriptor`, `:unsupported_version`,
`:invalid_schema`. Check failures use `:invalid_settings`, `:invalid_secret`,
`:too_large`, `:too_deep`, `:validation_failed`; map inherited schema violations
to `:invalid_settings`, never echo key names or values. No partial result.
Build validates descriptor shape/version before schema compilation. Check first
enforces plain-data/depth/size bounds, then secret reference shape, then the
ready PayloadSchema check. Missing and extra keys are schema failures, including
missing required secrets. An empty object succeeds only if the schema allows it.

## Host Needs and Limits

At most 64 top-level settings and 64 secret declarations; setting names are
nonempty UTF-8, at most 128 bytes, compared exactly. Descriptor compact JSON
at most 65,536 bytes, depth 32, checked before compilation. Settings inherit
PayloadSchema's 65,536 compact-byte and container-depth-32 bounds; accept the
boundary, refuse the first excess, never truncate. Secret identifiers have
the stricter inherited 128-byte bound, independent of Unicode character count.

Needs: host-approved schema complexity, immutable truthful schema identity,
secret-free nonsecret values and reference identifiers, and a trusted host that
later resolves exact scope under fresh authority. No I/O, resolver, clock,
credential release, authority grant, tenant authentication or persistence.
Bounds are not a schema CPU/memory isolation guarantee. Telemetry, Config and
Control are not applicable: this is a check of data operands, not ambient
configuration or a running service. It adds no settings execution lifecycle.

## Named acceptance groups

1. **`declared_settings_only`**: valid ordinary/nested values and optional/required properties; wrong type, missing required field and extra top-level field refused; unknown fields never dropped. Empty settings accepted under an empty/optional schema and refused under required declarations. Invalid/unknown-version descriptor, undeclared/duplicate secret name and open-object schema refused.
2. **`secret_reference_not_value`**: a valid ref/scope pair is retained byte-for-byte; raw secret text, `value` field, missing/extra member, empty/overlong identifier and Credential struct refused. UTF-8 multibyte identifiers exercise 128/129 bytes. A mock resolver which fails if called is never called; no resolution/reveal path is present.
3. **`identity_and_ready_schema_reuse`**: exact caller Port/schema identity retained; malformed Port, wrong direction, unsafe/external schema reference and invalid schema refused through ready PayloadSchema; identical independently built descriptors give equal results without coercion, defaults or secret lookup. A small checked example passes returned references to host injection code only, never a resolver inside this Piece.
4. **`fixed_bounds_and_redacted_failure`**: 64/65 properties and secret declarations, exact byte and depth limits, malformed/nonplain values and overbounds refused without partial output; success is exactly the original settings. Distinct secret/value/key sentinels never appear in errors, logs or telemetry, including upstream compilation/validation faults.

## Evidence and gate

Tests only; no new Cure law is selected for JSON Schema or a duplicate reference
shape check. Upstream/reused Piece grounding remains scoped to PayloadSchema,
JSV and Secrets; this Piece does not claim to prove schema semantics or secret
origin. Negative controls: temporarily accept a string in a secret property,
then permit an extra top-level setting; groups 2 and 1 must fail respectively.
Restore both. Report commands, exits, scenarios and host assumptions separately.

Run `mix test pieces/domain/recipe-config/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`.
One independent review checks the body and exact diff, including extra features.
