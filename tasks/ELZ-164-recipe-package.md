# ELZ-164 — Bounded recipe package manifest as plain data

## Scope and reuse

- Dependencies: ELZ-033, ELZ-115, ELZ-161, ELZ-162
- Output: `domain/recipe-package`; release V1B; RC-61 package portion.
- Change class: Piece-only; small local gate and hosted `check-piece`.
- Owned paths: `pieces/domain/recipe-package/**` and its index/generated changes under AGENTS.md section 3.

Coordinator decision, 2026-11-14: skill input is decoded frontmatter plus
Markdown body; raw YAML/SKILL.md syntax and folder provenance belong to the
later reader (RC-67). The package identity digest, opaque versions,
declarative needs/permissions, frontmatter field set and all bounds below
are admitted as written.
No fixture directory is needed; use small literal neutral maps and text.

Reuse `Elzoo.RecipeGraph.decode/1` and `encode/1` unchanged for callable/root/
binding validation, and `Elzoo.RecipeConfig.build/1` unchanged for the package's
settings descriptor. Reuse `core/payload-schema` through those interfaces;
declare it in the Piece dependencies, with recipe-graph and recipe-config.
Do not duplicate their validators or invoke authorization/approval/secrets.
Transitive validation dependencies do not add new task dependencies here.
Manifest providers are `elixir`, `jason`, `otp` for SHA-256 plus the providers
actually used by tests; no new library, YAML parser, provider or pin.

One pure checking boundary. The trusted caller supplies decoded schema and
decoded skill frontmatter, not a directory, archive, YAML text or executable
loader. The boundary validates decoded declarations:
malformed raw YAML remains the reader's responsibility, while this Piece
refuses malformed decoded skill declarations before returning a checked package.
Do not claim to validate raw SKILL.md bytes or authenticate their provenance.

## Interface: `Elzoo.RecipePackage`

`decode(map)` returns `{:ok, checked}` or `{:error, reason}`;
`encode(checked)` returns the exact original neutral map, not serialized JSON.
Checked values are opaque and caller-held. No resolver, loader or side effect.

The v1 neutral map has exactly string keys `format_version`, `name`, `version`,
`identity`, `needs`, `permissions`, `graph`, `settings`, `skills`.
`format_version` is integer 1. Name is 1..128 UTF-8 bytes, version is an opaque
1..128 UTF-8 bytes, exact-byte comparison; neither is a filesystem identifier
or version range. No normalization, coercion, defaults or unknown keys.

Identity is `recipe-package-v1:sha256:<64 lowercase hex>`, SHA-256 of canonical
UTF-8 JSON for every field except `identity`, with recursively sorted object
keys, preserved list order, no insignificant whitespace and Jason scalar
encoding. Descriptor format v1 pins that scalar encoding; reject nonfinite
numbers and integers outside signed 64 bits. Every schema, permission, graph,
skill version/tool declaration and body participates. Wrong identity refuses;
changing name/version alone cannot preserve it. No host-controlled claim of
immutability substitutes for this check. Do not infer trust from a matching
digest: the host must resolve/pin a trusted package source independently.

`graph` is the complete unchanged RecipeGraph v1 map. Its `root`, callables,
bindings and rules are authoritative within this package; no second root or
binding list is accepted. Decode it through RecipeGraph; reject unknown roots,
missing or duplicate bindings, invalid references/cycles and recursive named
calls using its Contract. Unused valid bindings remain permitted as upstream
permits; do not add an execution-readiness or registry-availability check.
`settings` is the unchanged descriptor accepted by RecipeConfig.build, never
tenant settings values. No equality between graph and settings identities is
invented; both are independent explicit descriptors owned by the package.

`needs` and `permissions` are each at most 64 unique opaque nonempty UTF-8
strings of at most 128 bytes. They are declarations only, not authority,
authorization policy, consent, credentials or grants. No wildcard expansion,
registry resolution or permission evaluator. Their meaning is host-owned.

`skills` is a list of at most 16 exact maps `name`, `version`, `tools`,
`frontmatter`, `body`. Names are unique; version is an opaque 1..128-byte UTF-8
string. Tools is a unique list of at most 64 nonempty UTF-8 tool identities,
each at most 128 bytes. The union of tools across this package's skills is at
most 64; do not consult or expand the runtime registry. These are package
declarations, not the public Agent Skills format's tools field.

Frontmatter is a decoded string-keyed map with required `name`, `description`;
optional `license`, `compatibility`, `metadata`, `allowed-tools` only. Name
matches the skill declaration, is 1..64 ASCII lowercase letters/digits/hyphens,
no leading/trailing or consecutive hyphens. It is also the logical folder
name, though no path is accepted or accessed here. Description is 1..1024
Unicode code points. License is nonempty UTF-8 at most 1,024 bytes,
compatibility 1..500 code points, metadata at most 32 string/string pairs,
keys 1..128 bytes and values at most 1,024 bytes; allowed-tools is a UTF-8
string at most 4,096 bytes, stored unchanged as advisory text. It grants no
authority and is not parsed into `tools`. Unknown keys, malformed field types
and missing required fields refuse the skill. No interpolation or YAML aliases.

Body is UTF-8 Markdown text at most 16,384 bytes per skill; total skill body
bytes at most 32,768 across the package, accepted whole or refused, never cut.
Empty body is valid: the public specification requires description, not a
nonempty instruction body. No bundled script/file members are accepted in
this first subset. The larger product may later store/read scripts, but never
execute them in v1; accepting a directory bundle is not this interface.

Package data is plain JSON: null, booleans, finite numbers, valid UTF-8 strings,
lists, string-keyed maps. No structs, tuples, arbitrary atoms, references or
functions. Cap container depth at 32, entire compact JSON including identity
at 2,097,152 bytes. Perform representation/depth/size/count checks before
schema compilation, cross-reference traversal and digest generation. Preserve
RecipeGraph's 64 callables, 1,000 nodes, 10,000 links, depth-16 nesting and
1-MiB graph cap, and RecipeConfig's 65,536-byte descriptor/64-setting bounds.
Host-approved schema complexity remains a Need; these byte caps do not bound
schema compiler work. Schema checking is not authentication.

Reasons are fixed atoms `invalid_shape`, `unsupported_version`, `too_large`,
`invalid_identity`, `invalid_graph`, `invalid_settings_descriptor`,
`invalid_skill`. Wrap upstream refusals without their prose or input fields.
No caller-controlled name, body, schema, credential marker or path in errors,
logs or telemetry. No partial checked package is returned on any failure.

## Acceptance groups

1. **manifest_identity_and_roundtrip** — Accept the smallest package with a
   valid graph, settings descriptor and zero skills/needs/permissions; encode
   equals the original input. Graph, agent and typed-decision roots each work.
   Correctly recomputed identity accepts; one-byte body, graph, schema, version,
   permission or tool change without updating it refuses. Reordered object keys
   keep identity, reordered lists change it. Reject wrong version, unknown key,
   invalid UTF-8, nonplain/nonfinite data and malformed/uppercase digest.
2. **ready_graph_and_settings_reuse** — Observe actual RecipeGraph.decode and
   RecipeConfig.build calls for valid operands. Unknown root, missing binding,
   duplicate binding, unknown callable, cycle and overdepth graph return only
   invalid_graph. Wrong settings version, malformed schema, extra descriptor
   field and raw secret defaults return invalid_settings_descriptor according
   to RecipeConfig's Contract. A valid credential-reference declaration is
   retained; tenant values and secret resolution are not accepted by this API.
   No schema equality inference or extra binding rule beyond RecipeGraph.
3. **skill_refusal_before_load** — Accept required and supported optional
   frontmatter; compare exact logical name. Refuse missing description,
   uppercase/consecutive/edge-hyphen names, name mismatch, wrong types,
   malformed metadata, duplicate skills and tool declarations, unknown field
   or malformed version. Empty Markdown accepts; invalid UTF-8 refuses.
   A would-be loader/resolver that raises if called is never invoked. No
   partial checked package on the first or last malformed skill. A temporary
   negative control bypassing skill validation must fail this group.
4. **trust_and_bounds** — Exact cap and cap+1 tests for package bytes/depth,
   needs/permissions 64, skills 16, per-skill tools 64, union tools 64,
   body 16,384 and total body 32,768, names/version bytes, frontmatter code
   point limits and metadata counts. Count multibyte text correctly. The
   package accepts declarations only; allowed-tools cannot add a tool/grant,
   permission strings cannot relax graph rules or mint approval. Assert graph
   rule data survives exactly, and a matching digest proves content equality
   only, never trusted origin. No truncation or deduplication to fit a bound.
5. **redaction_and_no_effects** — Poison all error sites with a synthetic
   private marker and confirm fixed reasons, empty logs/telemetry, no file,
   network, process, registry, Lua or secret calls. A checked example shows
   graph and settings descriptor composition only. Repeated decode has equal
   results and no hidden state. Tests of settings values remain upstream-owned.

Evidence is the named finite tests, direct upstream/ready-Piece reuse and
explicit assumptions about trusted source pinning and schema complexity; no
new Cure proof or monitor claim. README records that skill instructions from
the trusted pinned package are role instructions, not marked tool-result
content; this Piece neither assigns runtime trust nor builds a prompt. Later
instruction loading must refuse its own total byte bound without cutting or
double-counting already loaded skills; the 32,768 package-body cap is not a
claim about a loaded request fitting ai-text's 65,536-byte request cap.

Declare operations not applicable: pure operands, fixed bounds, no lifecycle,
logging or telemetry. Run `mix test pieces/domain/recipe-package/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`.

## Not in scope

Add no extra features. No package reader, raw YAML parser, file/archive assets,
script execution, Lua, scheduler, recipe store, secret/settings resolution,
schema inference, skill-source discovery, registry tool availability, runtime
trust assignment, prompt loading, dynamic grants, new provider/pin or shared
source change. A future raw Skill folder reader must validate syntax/folder
provenance before handing decoded declarations to this boundary.
