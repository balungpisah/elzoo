# delivery/routing

Pure selection among declared core/wiring edges, not execution or delivery.

## Contract

`Elzoo.Routing.validate(wiring, table)` returns `{:ok, table}`. The exact table
is `%{"version" => 1, "source" => %{"unit_id" => text, "port_id" => text},
"routes" => [%{"edge_id" => text, "match" => match}]}`. Match is an exact map
with optional nonempty UTF-8 `kind`, `schema_id`, positive integer
`schema_version`; conjunction and exact equality, empty matches all.
It decodes to `{:RoutingMatch, kind, schema_id, schema_version}` with Options;
`Cure.Elzoo.Routing.matches/2` decides matching without inspecting payloads.

Checks: Wiring first (`:wiring` phase); table shape (`{:table, :invalid_shape}`);
declared output source (`{:table, :unknown_source | :invalid_source}`); then
routes in declaration order, each existing edge, same source, no duplicate.
Route errors are `{:route, edge_id, :unknown_edge | :source_mismatch | :duplicate_route}`.

`route(wiring, table, envelope)` validates, decodes Envelope (`:envelope`
phase), then checks producer and schema/version against the declared source
**before** matching, even for an empty table. Source errors are
`{:source, :producer_mismatch | :schema_mismatch | :version_mismatch}`.
Success is `{:ok, edge_ids}` sorted by edge ID, independent of route declaration
order; `[]` explicitly means filtered. Every matched edge passes unchanged
`Wiring.accept/3`; the first failure in sorted order is
`{:edge, edge_id, reason}`. All errors are wrapped in `{:error, ...}`.
`route_one/3` returns `{:ok, edge_id}`, or `{:error, {:route, :no_route}}`
or `{:error, {:route, :ambiguous_route}}`, propagating validation errors.

Schema predicates are effectively constant per table because Wiring fixes the
single source schema/version; kind is the discriminating predicate. No payload
content routing, invented targets, splitter, ordering, dispatch, expiry or
delivery guarantees. Deadlines are preserved data, never clock comparisons.
No lookup, I/O, timers, processes or ID generation.

Errors may include declaration identifiers/indices, never payload or metadata
values. Callers own truthful identities, payload validation and runtime behavior.

## Operations and evidence

Config is supported solely as the explicit per-call route table, tested in the
bundle; no ambient or hot reconfiguration. Telemetry/Control are not_applicable:
no observations or lifecycle; the invoking Unit/Assembly owns instrumentation.
Pinned Cure compilation is type evidence and source audit; bundled scenarios
cover permutations, filters, source-before-match and errors. No quantified
proof is claimed. With immutable validated inputs, matched-edge acceptance
failures are defensive propagation, not a separately reachable normal scenario.
Independent exported consumers run without Elzoo.Application or a Cure compiler
at runtime. Shared examples come unchanged from core/wiring and core/envelope.
