# core/edge

Pure named endpoint, placement and delivery-policy checks. Depends on
`core/port` unchanged. It binds declarations, not functions or processes.

## Interface and Contract

`Elzoo.Edge.decode_binding/1` validates the exact map
`{unit_id, port, delivery, required_route}` (all keys are strings).
`unit_id` is nonempty UTF-8 text; `port` is the unchanged four-key core/port
descriptor; `delivery` is `fused` or `volatile`; `required_route` is a boolean.
It is an endpoint's declared policy, not an addition to the stable Port map.
`decode_port/2` takes the owning unit ID and exact three-key
`{port, delivery, required_route}` declaration, so Wiring shares this decoder.

`decode/1` validates an exact edge map `{id, placement, source, target}`.
`id` is nonempty UTF-8 text, `placement` is `fused` or `hop`; each endpoint
reference is the exact map `{unit_id, port_id}` with nonempty text values.
`decode*` returns a validated Cure record or an error. `connect/3` takes an
edge and its source/target binding maps, checks references, then delegates to
core/port for output-to-input schema ID/version compatibility. It returns
`{:ok, true}` or an explicit error; source/target decode errors are tagged.

- Fused requires the same unit ID and both policies `fused`: a declared direct
  pure call within one transition, no interleaving from this edge itself.
- Hop requires distinct unit IDs and both policies `volatile`: a declared
  message crossing units, separate commit points, best effort, duplicates
  possible after retry, no durable acknowledgement or exactly-once promise.

These two policies are the only accepted values. Durable/at-least-once policy
requires a different Contract and evidence; it is not silently accepted as a
string. Fused and volatile bindings cannot be connected interchangeably.
This couples placement to a binding: one binding cannot mix fused and hop
edges. Replacing placement uses a separate declaration, not runtime rewiring.
An intra-unit output-to-input edge declares a direct call seam, not recursive
re-entry into a Unit. Cycle/feedback meaning is not checked or executed here.
No calls or sends happen during validation, so success does not establish
execution placement or certify the operator implementation. An OTP mailbox
can lose queued work on process failure. Cross-sender ordering, crash gaps,
delivery, payload validation and Effect outcomes remain runtime assumptions.

`examples/elzoo/edge.exs` shows the public `connect/3` calls; the test "the example file evaluates to the documented results" in `test/elzoo/edge_test.exs` evaluates it.

## Grounding and operations

Pinned Cure checks records and pure placement/compatibility decisions. Named
positive/negative ExUnit checks and copied-source consumer checks exercise
translation; no new quantified proof or monitored runtime behavior is claimed.
Cure type checking/erasure and structural equality are upstream assumptions.
Telemetry/Control are not applicable: no I/O or lifecycle. Config is supported
only as per-check `delivery` and `required_route` declaration choices: no
defaults, only the values above, no ambient/hot reconfiguration or runtime
rewiring. Edges and operand IDs themselves are data.

Per-port required kinds/metadata are deliberately deferred. The generic shape
checker accepts each documented optional Envelope field as absent; products
must enforce stronger requirements separately. Adding such a policy to this
exact binding Contract requires a new Piece ID and explicit consumer migration.
