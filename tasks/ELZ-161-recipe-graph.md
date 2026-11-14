# ELZ-161 — Versioned recipe callables as plain data

## Scope and reuse

- Dependencies: ELZ-033, ELZ-115, ELZ-026, ELZ-024, ELZ-114
- Output: `domain/recipe-graph`; release V1B; RC-61 graph portion.
- Owned paths: `pieces/domain/recipe-graph/**` and its index/generated changes under AGENTS.md section 3.

Draft only; not published or claimable. The concrete data shape and bounds
below are admission proposals for owner review.

Owner decision, 2026-11-14: callable kinds v1 are graph, agent and typed decision;
node kinds v1 are call, tool, ask, decision, map and loop. Map and loop re-run a
named callable within a bound, never via a back-edge. The handle stays
`domain/recipe-graph` even when the root callable is an agent or a decision.

One pure data/validation boundary. Nothing executes. Implement only the named
acceptance groups below. Add no extra features, DSL, scheduler, registry lookup,
Lua runtime, package reader, settings checker, adapters, options or hooks.
Change no ready Piece, shared source, dependency pin or CI file. No fixtures
directory is needed: use small literal neutral maps in tests.

Reuse ready `workflow/dependency-graph` validation for cycles and unknown
dependencies (at most 1,000 nodes, 10,000 edges), not its readiness decisions.
Reuse `core/payload-schema` for schema/Port declarations. Keep the existing
`domain/authorization` policy identity and `workflow/approval` requirement and
exact-action binding semantics; invent no policy evaluator or approval format.
Use the nine v1 outcome classes of `workflow/pattern-step`, not new words.
No dependency on recipe-config or the later recipe-package is needed.

## Interface: `Elzoo.RecipeGraph`

Two functions: `decode(map)` returns `{:ok, checked}` or `{:error, reason}`;
`encode(checked)` returns the original neutral map. Checked values are opaque
and caller-held. Encode is translation, not JSON text serialization; it accepts
only this module's checked values. Decode does not repair or normalize input.

The v1 neutral map has exactly `version`, `id`, `revision`, `root`, `callables`,
`bindings`, `rules` (all keys are strings). `version` is 1, `revision` is
1..2^31-1. The explicit identity is `(id, revision, version)`; the host owns
immutable meaning for that tuple. No digest, latest-version negotiation or
global registry. IDs/names are nonempty UTF-8, at most 128 bytes, compared by
exact bytes. Unknown keys and versions fail closed. No functions, structs,
references, atoms except JSON booleans/null, or nonfinite numbers are data.

`callables` is a list of unique declarations. Each has `name`, `kind`, `input`,
`output`; kind is `graph`, `agent` or `decision` (decision means typed decision).
Input/output are exact maps `{port, schema}`: Port's existing four-field neutral
declaration and a host-approved decoded JSON Schema object. Validate with
`PayloadSchema.build/2`, requiring input/output directions respectively. No
schema inference or static claim that two schemas are equivalent.

- Graph additionally has `nodes` and `links`, both lists, with unique node IDs.
- Agent additionally has `binding`, naming an entry of the separate bindings list.
- Decision additionally has `binding` and `choices`, 1..64 unique choice names.
  Bindings are data references, not executable agent/model configurations here.

Each node has `id`, `kind`, `needs`, `gives`. Needs/gives are unique lists of
named data slots (at most 64 each); each slot is exactly `{name, schema_id,
schema_version}` with a positive version and the same identity semantics as
Port. A graph additionally declares `input_slots` with that same shape, under
the reserved source `$input`; the host vouches their relationship to its input
schema. Each give/need connection must name an exact matching schema identity.
The task does not infer compatibility or slots from JSON Schema text. Input
slots are declarations, never defaults or authority; `$input` is not a node ID.

Kind-specific fields:

- `call`: `callable`, an existing package-local callable name.
- `tool`: `tool`, an opaque registry tool identity; no tool discovery/execution.
- `ask`: no extra fields; person identity and answers are runtime inputs later.
- `decision`: `callable`, naming a decision-kind callable.
- `map`, `loop`: `callable` and `max_iterations` in 1..256. Map applies to an
  ordered input collection and loop repeats; these are data declarations only.
  Collection semantics, stop evaluation and actual execution belong to RC-63.

Each link has `from`, `to`, `kind`; endpoints name nodes in that graph, except
`$input` may be a source of a data link only. Kinds and additional fields:
`order` (none), `data` (`give`, `need` slot names), `choice` (`choice`),
`outcome` (`outcome`). Choice source must be a decision node and must have
exactly one choice link per declared choice, no missing/unknown/duplicate
choice. Outcome is exactly one of `completed`, `failed`, `refused`, `late`,
`unknown`, `out_of_budget`, `retries_exhausted`, `expired`, `resource_lost`.
No duplicate `(from, outcome)` route. Outcome routes are optional; an omitted
class is not silently mapped to completed. Links add only dependency/order,
data flow or routing; no arbitrary conditions, code or back-edges.
Every need has exactly one giver via a data link (node or `$input`). Give names
are unique per source; reject missing, ambiguous and mismatched connections.

Validate each graph's projected needs/order/routing edges with DependencyGraph,
mapping `to` waits for `from` to its dependant-to-prerequisite orientation.
Use no externals to conceal a missing node. A self-edge or any cycle, including
an outcome/choice cycle, is invalid. Validate the package-local callable
reference graph too: recursive names are invalid, including unreachable ones.
Maximum callable nesting is 16, counting root as 1; check every declared chain,
not just the chosen root. A map/loop's named call adds one nesting level;
its iteration count does not add a call-graph back-edge.

`bindings` is a separate list of exact `{name, target}` string-keyed maps;
target is an opaque host binding identity, not code, authority or a credential.
Names are unique; binding lookup is local only. `rules` is a list of exact
`{callable, node, policy, requirement}` maps targeting an existing node. Policy
is the existing identity `(id, version, content_hash)`, represented as an exact
string-keyed map with a 64-lowercase-hex SHA-256 for lossless JSON transport;
convert it to the existing 32-byte form when composing the example. Requirement
is exactly the existing `{name, version, scope}` descriptor (`once`, `run`,
`root` as transport strings), not evidence or an ALLOW verdict. Identity/name
bounds are the narrower limits here, versions 1..2^31-1. At most one rule per
node: multi-requirement approval is not admitted by workflow/approval.

Rules add an approval requirement only; they contain no policy rules, authority,
verifier, approval evidence, exemption or relaxed requirement. At runtime the
consumer must still call the existing authorization/approval boundaries using
current trusted context and the exact normalized action/escrow binding. Recipe
identity or a rule is never an approval. Static checking cannot authenticate
a policy hash or pre-bind an action that has not happened. A checked composition
example uses existing APIs to show a recipe requirement cannot turn DENY into
ALLOW, bypass ASK or reuse approval for changed action/escrow/policy.

## Host Needs and Limits

Fixed bounds: 1..64 callables; at most 1,000 total nodes and 10,000 total links;
64 bindings and 256 rules; nesting 16; 256 map/loop iterations; 64 slots per
needs/gives/input_slots list. The full neutral value is at most 1 MiB compact
JSON and container depth 32; check representation/depth before encoding, never
truncate. Per schema/Port the inherited PayloadSchema restrictions apply.
Check bounds before traversing references. Counts also cover unreachable data.

Reasons are fixed atoms: `:invalid_shape`, `:unsupported_version`, `:too_large`,
`:invalid_schema`, `:unknown_name`, `:cycle`, `:depth_exceeded`,
`:missing_giver`, `:invalid_branch`, `:invalid_outcome`, `:invalid_rule`.
No input fragments, paths, schemas or library prose in errors, logs or telemetry.
An empty callable list or missing root is refused. No partial checked result.

Needs: host-approved schema complexity, truthful schema/policy/binding identities,
secret-free data and immutable revisions. Limits bound accepted data, not
upstream schema compilation CPU/memory. No I/O, clock, persistence, execution,
authorization grant, tool availability, schema subtyping or runtime readiness.
Telemetry, Config and Control are not applicable; operands and fixed v1 bounds
are not ambient configuration. Agent and decision behavior remains elsewhere.

## Named acceptance groups

1. **`three_callable_six_node_kinds`**: round-trip graph-, agent- and decision-root maps; one graph with all six nodes; bindings separate; explicit identity unchanged; unknown kind/version/field, duplicate name, empty declarations, malformed schema and dangling root/call/binding refused.
2. **`dependencies_and_data_slots`**: valid ordered/data links; missing giver, duplicate giver, mismatched schema ID/version and unknown source/target/slot refused; all link kinds participate in cycle checks; self-edge and multi-node cycles refused through ready DependencyGraph. No execution/readiness call.
3. **`branches_and_outcomes`**: every declared decision choice has exactly one route; missing/extra/duplicate branches refused; all nine outcome names accepted individually; unknown outcome, missing target and duplicate class route refused. No implicit completed fallback.
4. **`bounded_named_nesting`**: 16 levels accepted, 17 refused; direct/indirect recursive named call refused, also unreachable recursion; bounded map/loop accepted without legalizing a back-edge; 0/257 iterations refused; 1,000/1,001 nodes and 10,000/10,001 links exercise exact limits, alongside callable/slot/byte/depth bounds.
5. **`requirements_never_grant`**: malformed or relaxing rules refused; one recipe requirement composes with actual authorization and approval APIs, preserving DENY/ASK and exact-action binding. Changed action, escrow or policy does not reuse consent. No authority/evidence accepted from recipe data.
6. **`stable_data_and_redaction`**: encode/decode preserves map/list values and order, independent equal inputs agree; empty/malformed/nonplain values refused; secret-bearing sentinels never appear in returned errors or captured logs/events. One small checked example covers the public API.

## Evidence and gate

Tests ground validation, round-trip, depth and composition; upstream/reused
Piece claims stay scoped to their existing Contracts. Cure owns a new pure
decision if a meaningful law is selected; do not add a Boolean restatement
or claim that reused proofs prove this whole data format. Record assumptions
and test results separately. Negative controls: temporarily omit a decision
branch check, then omit a nesting check; the corresponding groups must fail.
Restore both before the final gate.

Run `mix test pieces/domain/recipe-graph/test`, then
`mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`.
One independent review checks the body and exact diff, including extra features.
