# core/wiring

Minimal local unit/port/edge declaration checking for the P0 binding shape.
Depends on `core/edge` and `core/envelope`, and transitively core/port.

## Interface and Contract

`Elzoo.Wiring.validate/1` accepts the exact string-keyed map
`{version: 1, units: [...], edges: [...]}`. Each unit is exactly `{id, ports}`;
ID is nonempty UTF-8 text, ports is a list of exact maps
`{port, delivery, required_route}` defined by core/edge (without `unit_id`,
which is supplied by the owning unit). Empty lists are legal. Unit IDs are
unique in the wiring, Port IDs unique within a unit, and edge IDs unique in
the wiring. Every edge reference must resolve; each edge must pass
`Elzoo.Edge.connect/3`. Repeating the same source/target route is rejected.
Every binding with `required_route: true` must have at least one incident edge
in the direction core/port declares (outgoing for output, incoming for input).
Optional unrouted ports are allowed. Success returns `{:ok, original_map}`;
errors name the declaration position/ID and a finite reason, never a payload.
Error order: unit/port declarations in list order, then edges in list order,
then required routes sorted by `(unit_id, port_id)`. An invalid edge reports
its edge error before any missing-route check. An intra-unit compatible edge
satisfies its incident ports; recursive execution and graph cycles are not
certified. Fan-in from different outputs and fan-out to different inputs are
legal declarations only; repeated endpoint pairs are not.

`accept/3` takes wiring, a caller-selected edge ID and an Envelope map. It
validates the declarations and envelope, requires an existing route, matches
producer unit/port to that route's source, and checks exact schema ID/version
against its output descriptor (the checked edge already matches the input).
Success returns `{:ok, envelope_map}`. This does not select a route, deliver,
decode a payload, enforce a deadline, or prove the claimed producer identity.
Caller chooses the route explicitly. ELZ-006/007 own execution/selection.
Errors are `{:error, {phase, reason}}`: `:wiring` wraps declaration errors
from `validate/1`, `:route` names an unknown selected edge or producer/schema
mismatch, and `:envelope` wraps Envelope decoding errors. Checks run in that
order: wiring, selected edge, Envelope, then route producer/schema acceptance.
Thus callers can distinguish declaration faults from malformed messages and
route mismatches without inspecting overlapping reason atoms.

`examples/p0.exs` is an executable declaration for the existing ingest → dedup
→ accumulate shape, including fused placement and a volatile hop variant.
It uses the existing operator message contract by name but does not change
the ready bootstrap Assembly or claim runtime payload/ABI integration (ELZ-004).
No wiring CLI or generated runtime manifest is required.

## Deliberate limits and grounding

This is **not** a full graph validator: no reachability, cycle/liveness,
fan-out execution, capacities, required-kind/metadata policies, Needs,
authorization, persistence, process lookup or state/function certification.
Multiple different routes on a port are legal declarations, not a broadcast
or deterministic selection guarantee. Reuse Enum/Map for finite structural
traversal; Cure owns edge decisions and the required-route predicate. Kind and
schema descriptors do not inspect live payloads. A successful declaration has
no effect on OTP supervision or mailboxes.
Selecting core/wiring includes core/envelope because accept/3 checks envelopes.

Type: Cure checks the consumed required-route decision. Tests exercise named
legal bindings, required-route/schema/identity negatives, examples and copied
source consumers; no universal graph proof or monitored behavior is claimed.
Upstream assumptions: pinned Cure and core/edge/core/envelope dependencies.
Telemetry/Control are not applicable: pure checks, no runtime lifecycle or
observations. Config is inherited from core/edge's per-check policy operands;
no hot-reconfiguration or dynamic rewiring guarantee.
