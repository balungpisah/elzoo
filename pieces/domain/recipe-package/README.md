# domain/recipe-package

`Elzoo.RecipePackage.decode(map)` checks decoded package declarations and returns
`{:ok, checked}` or `{:error, reason}`. `encode(checked)` returns the exact original
neutral map, never serialized JSON. Checked values are opaque and caller-held;
only decode results belong in encode. No resolver, loader or side effect.

## v1 declarations and identity

The exact string keys are `format_version` (integer 1), `name`, `version`,
`identity`, `needs`, `permissions`, `graph`, `settings`, `skills`. Name and opaque
version are 1..128 UTF-8 bytes, compared by exact bytes, without normalization,
defaults or coercion. They are neither filesystem identifiers nor version ranges.

Identity is `recipe-package-v1:sha256:<64 lowercase hex>`, the SHA-256 of canonical
UTF-8 JSON of all fields except `identity`. Object keys sort recursively in
ascending **UTF-8 byte order** (Elixir binary order), not RFC 8785's UTF-16 order.
List order is preserved; there is no insignificant whitespace. Format v1 pins
Jason 1.4.5 scalar encoding, including its number and string escaping behavior.
Integers must fit signed 64 bits and floats must be finite. The BEAM cannot
represent IEEE NaN/infinity as ordinary float terms. Every declaration, schema,
rule, permission, tool, skill version and body participates; renaming or changing
version cannot preserve an old digest. Reordering object keys preserves identity;
reordering lists changes it. The checked example shows publisher-side computation.

A matching digest proves content equality only, **never trusted origin**. The host
must independently resolve and pin a trusted source. Schema checking is not
authentication, and identities or permission strings are not consent or grants.

`graph` is the complete RecipeGraph v1 map, decoded and encoded through the ready
Piece unchanged. Its root, callables, bindings and rules are authoritative; no
second root or binding list is accepted. Unused valid bindings are permitted.
`settings` is the descriptor accepted unchanged by RecipeConfig.build, never
tenant settings values. Graph and settings identities are independent; there is
no inferred schema equality, availability or execution-readiness requirement.
PayloadSchema is reused through these interfaces; no validator is duplicated.

Needs and permissions each contain at most 64 unique opaque nonempty UTF-8
strings of at most 128 bytes. Meanings are host-owned. No wildcard expansion,
registry lookup, permission evaluator, approval or credential resolution.

## Decoded skills

At most 16 exact maps `name`, `version`, `tools`, `frontmatter`, `body`, with unique
names. Version is an opaque 1..128-byte UTF-8 string. Tools are at most 64 unique
nonempty UTF-8 identities, each at most 128 bytes; their union across all skills
is at most 64. No runtime registry is consulted. These are package declarations,
not the public Agent Skills tools format.

Frontmatter is a decoded string-keyed map, with required `name` and `description`
and only the optional fields below. Name matches the skill declaration exactly:
1..64 ASCII lowercase letters, digits and hyphens, no edge or consecutive hyphens.
It is the logical folder name, though no path is accepted or accessed here.

| Field | Accepted value |
| --- | --- |
| description | 1..1,024 Unicode code points |
| license | nonempty UTF-8, at most 1,024 bytes |
| compatibility | 1..500 Unicode code points |
| metadata | at most 32 string/string pairs; keys 1..128 bytes, values 0..1,024 bytes |
| allowed-tools | UTF-8 string, 0..4,096 bytes, retained as advisory text |

Code points, not grapheme clusters, decide the description/compatibility bounds.
Allowed-tools is never parsed into tools or authority. No interpolation or YAML
alias processing occurs: this interface receives decoded data, not YAML syntax.
Markdown body is UTF-8, 0..16,384 bytes per skill and at most 32,768 total bytes.
Empty body is valid; description is required. Accepted whole or refused, never
cut or deduplicated to fit. No bundled files, scripts or archive members.

The caller supplies decoded frontmatter and schema. A future reader must validate
raw YAML/SKILL.md syntax and folder provenance before this boundary. This Piece
does not claim to validate raw bytes or authenticate their provenance. Skill
instructions from a trusted pinned package are role instructions, not marked
tool-result content; this Piece neither assigns runtime trust nor builds prompts.
Later instruction loading must enforce its own total byte bound without cutting
or double-counting already loaded skills. The package body cap does not claim that
a loaded request fits ai-text's 65,536-byte request cap.

## Evaluation order, bounds and fixed errors

First check plain JSON representation, container depth and compact JSON byte size
incrementally; then the exact package shape/version, declaration counts and skill
fields. Only afterward call RecipeGraph and RecipeConfig, then generate/compare
the digest. No partial checked package is returned. No caller-controlled text,
schema, credential marker, body or path appears in errors, logs or telemetry.

Plain data is null, booleans, finite numbers, valid UTF-8 strings, proper lists and
non-struct string-keyed maps. No tuples, arbitrary atoms, functions or references.
The package cap, including identity, is **2,097,152 compact JSON bytes** and **32
container levels**, inclusive. A scalar adds no level; each map/list adds one,
including the package root. Package depth 32 leaves **31 levels** for the nested
graph or descriptor. Outer checks can therefore refuse their nesting before the
upstream depth-32 check. The byte cap is an outer ceiling, not a promise that valid
subdocuments can fill it: their smaller caps still apply.

| Refusal | Reason |
| --- | --- |
| Nonplain data anywhere, invalid UTF-8, out-of-range integer, wrong package shape, empty/malformed name/version or needs/permissions | `invalid_shape` |
| Present format version other than integer 1 | `unsupported_version` |
| Package bytes/depth cap+1, declaration count cap+1, string byte/code-point cap+1, tool union or body total cap+1 | `too_large` |
| Duplicate needs/permissions | `invalid_shape` |
| Malformed decoded skill/frontmatter, empty required text, name mismatch/syntax, duplicates, wrong field types or unknown fields | `invalid_skill` |
| Any RecipeGraph refusal, including upstream `too_large`/`depth_exceeded` | `invalid_graph` |
| Any RecipeConfig.build refusal, including its descriptor byte/depth/count limits | `invalid_settings_descriptor` |
| Malformed, uppercase or mismatched content digest after valid declarations | `invalid_identity` |

The first refusal in that order wins. Graph bounds remain 64 callables, 1,000
nodes, 10,000 links, nesting 16 and 1 MiB, with all its other rules unchanged.
Settings retains its 65,536-byte descriptor/64-setting limits. Host-approved
schema complexity remains a Need: byte caps do not bound schema compilation
CPU or memory, encoding allocation or total work. No timeout or isolation claim.

## Evidence and consumption

The five named test groups are `manifest_identity_and_roundtrip`,
`ready_graph_and_settings_reuse`, `skill_refusal_before_load`, `trust_and_bounds`,
and `redaction_and_no_effects`. They cover exact caps and cap+1, multibyte text,
content mutations, actual upstream calls, fixed errors, captured logs, traced
effect absence and the checked descriptor-only example. Temporary production
mutations bypassing skill validation and identity comparison are negative
controls. These are finite tests, not universal proofs. No new Cure law, type
checker result or monitored runtime claim. Crypto/Jason and the unchanged ready
Pieces supply upstream grounding; trusted source pinning/schema complexity are
explicit host assumptions.

Run `mix test pieces/domain/recipe-package/test` or run the example with
`mix run pieces/domain/recipe-package/examples/recipe_package.exs`.
Use `mix elzoo.take domain/recipe-package --to <consumer>` and follow the existing
copy/install/receipt instructions. Providers include OTP crypto for hashing and
telemetry for tests only; no new pin or library. Application-owned modules and
the checked tuple tag require deliberate renaming before library redistribution.
Apache-2.0. Telemetry, Config and Control are not applicable: pure operands,
fixed bounds, no logging, telemetry, process or lifecycle.
