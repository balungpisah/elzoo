# domain/recipe-graph

`Elzoo.RecipeGraph` validates v1 recipe callables as plain data. Nothing runs.
`decode(map)` returns `{:ok, checked}` or `{:error, reason}`. `encode(checked)`
returns the original map, not JSON text. Checked values are opaque, caller-held
`{:RecipeGraph, map}` values; forging them or passing unchecked values to encode
is outside the interface.

## Neutral declarations

The exact top-level string keys are `version` (1), `id`, `revision`, `root`,
`callables`, `bindings`, `rules`. Identity is explicitly `(id, revision, version)`.
IDs and names are nonempty UTF-8 strings of at most 128 bytes, compared by exact
bytes. Revisions and schema/policy/requirement versions are 1..2^31-1.
No coercion, normalization, defaults or unknown fields are accepted.

Each callable has `name`, `kind`, `input`, `output`. Each input/output is exactly
`{port, schema}`: the existing four-field Port declaration and a host-approved
decoded JSON Schema object, checked by `PayloadSchema.build/2` with the matching
direction. No schema inference or equivalence is claimed.

- `graph` adds `nodes`, `links`, `input_slots`.
- `agent` adds `binding`.
- `decision` adds `binding`, `choices` (1..64 unique names).

Bindings are separate exact `{name, target}` maps. Names are unique and target
is an opaque host identity, not executable configuration or authority.

Nodes have `id`, `kind`, `needs`, `gives` plus only these fields:

| kind | additional fields |
| --- | --- |
| call | callable |
| tool | tool |
| ask | none |
| decision | callable (decision-kind) |
| map, loop | callable, max_iterations (1..256) |

Callable references are package-local. Map and loop name a bounded repeated
call; they never permit graph back-edges. Collection/stop/runtime semantics are
not defined here. A slot is exactly `{name, schema_id, schema_version}`; slot
names are unique per needs/gives/input_slots list. Every need requires exactly
one data link with an exactly matching schema ID/version. Input slots declare
the reserved `$input` source; the host vouches for their relation to input.

Links have `from`, `to`, `kind` and only these additional keys:
`order`: none; `data`: `give`, `need`; `choice`: `choice`; `outcome`: `outcome`.
Endpoints must exist locally. Choice sources must be decision nodes with one
route per declared choice, no missing/extra/duplicate routes. Outcome classes
are `completed`, `failed`, `refused`, `late`, `unknown`, `out_of_budget`,
`retries_exhausted`, `expired`, `resource_lost`, unchanged from PatternStep v1.
At most one route per `(from, outcome)`; omitted outcomes have no fallback.
Every node-to-node link projects to `to` waits for `from` and is checked by
`DependencyGraph.validate/1`, with no externals or readiness call. Self-edges,
cycles and recursive named calls (even unreachable ones) are refused.

Rules are exact `{callable, node, policy, requirement}` maps targeting a graph
node, at most one per node. Policy is `{id, version, content_hash}` with a
64-lowercase-hex SHA-256. Requirement is `{name, version, scope}`, scope one of
`once`, `run`, `root`. They add a requirement only: no policy evaluator, ALLOW,
authority, exemption, verifier or approval evidence. Consumers must call actual
authorization and approval APIs with trusted current context and exact action,
escrow and policy bindings. Recipe identity is never consent. The checked
example converts policy hex to the existing 32-byte identity and composes
authorization/approval without relaxing DENY or ASK or reusing changed bindings.

## Bounds and errors

1..64 callables, 1,000 total nodes, 10,000 total links, 64 bindings, 256 rules,
64 slots per list, nesting at most 16 counting each chain's first callable as 1,
including unreachable chains. Iterations do not add call depth. All accepted
data is plain JSON (finite numbers, strings, booleans/null, lists, string-keyed
maps), at most 1 MiB compact JSON and 32 container levels. Representation,
depth, bytes and counts are checked before reference traversal. Per-Port/schema
PayloadSchema restrictions also apply. Bounds do not bound schema compiler CPU
or memory; the host must approve schema complexity.

Errors contain only a fixed atom: `invalid_shape`, `unsupported_version`,
`too_large`, `invalid_schema`, `unknown_name`, `cycle`, `depth_exceeded`,
`missing_giver`, `invalid_branch`, `invalid_outcome`, `invalid_rule`.
No input fragments, paths, schema prose, logs or telemetry are emitted.

## Assumptions and decisions

- Every entry of `links`, including `$input` data links, counts toward 10,000.
  `$input` links do not project to DependencyGraph edges: they impose no order
  between nodes. No externals are passed to DependencyGraph.
- A node ID equal to `$input` is refused with `invalid_shape`.
- Tool identity is a nonempty UTF-8 string of at most 128 bytes, compared by
  exact bytes, with no further structure.
- The host owns immutable meaning of explicit identities, truthful schema,
  policy and binding declarations, approved schema complexity and secret-free
  data. Static validation cannot authenticate a policy hash or pre-bind an
  action that has not happened.
- No new Cure module: no meaningful new law is selected beyond finite map
  validation and composition tests. Reused Cure laws do not prove this format.

## Grounding and limits

`mix test pieces/domain/recipe-graph/test` exercises the exact groups
`three_callable_six_node_kinds`, `dependencies_and_data_slots`,
`branches_and_outcomes`, `bounded_named_nesting`, `requirements_never_grant`,
`stable_data_and_redaction`. These are finite scenarios, not a universal proof.
The last group evaluates `examples/recipe_graph.exs`; it also runs with
`mix run pieces/domain/recipe-graph/examples/recipe_graph.exs`.
Branch and nesting checks have temporary negative controls, never shipped.
There is no monitored claim. Reused Piece Contracts stay scoped to those Pieces.

No I/O, clock, persistence, execution, scheduling, tool availability, schema
subtyping, runtime readiness, authorization grant or authentication. Agent and
decision behavior remains elsewhere. Telemetry, Config and Control are not
applicable: pure operands, fixed bounds and no independent lifecycle.
Application-owned module, Apache-2.0; no new dependency or pin.
