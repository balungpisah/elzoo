# core/edge

Pure named endpoint, placement and delivery-policy checks. Depends on
`core/port` unchanged. It binds declarations, not functions or processes.

## Interface and Contract

`Elzoo.Edge.decode_binding/1` validates the exact map
`{unit_id, port, delivery, required_route}` (all keys are strings).
`unit_id` is nonempty UTF-8 text; `port` is the unchanged four-key core/port
descriptor; `delivery` is `fused` or `volatile`; `required_route` is a boolean.
It is an endpoint's declared policy, not an addition to the stable Port map.

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
No calls or sends happen during validation, so success does not establish
execution placement or certify the operator implementation. An OTP mailbox
can lose queued work on process failure. Cross-sender ordering, crash gaps,
delivery, payload validation and Effect outcomes remain runtime assumptions.

## Grounding and operations

Pinned Cure checks records and pure placement/compatibility decisions. Named
positive/negative ExUnit checks and copied-source consumer checks exercise
translation; no new quantified proof or monitored runtime behavior is claimed.
Cure type checking/erasure and structural equality are upstream assumptions.
Telemetry/Control are not applicable: no I/O or lifecycle. Config is supported
only as per-check `delivery` and `required_route` declaration choices: no
defaults, only the values above, no ambient/hot reconfiguration or runtime
rewiring. Edges and operand IDs themselves are data.
