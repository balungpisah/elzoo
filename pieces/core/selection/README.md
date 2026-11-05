# core/selection

Pure interface/delivery selection, not lookup, placement or implementation
certification. Each selected implementation retains its own grounding.

## Inputs and validation

Candidate exact shape: `%{"piece_id" => nonempty_text, "interface" =>
core_assembly_interface, "delivery" => core_edge_delivery, "rank" => nonneg_int}`.
Lower rank means higher explicit priority. The interface is decoded by unchanged
`Elzoo.Assembly.decode/1`.

Requirement exact shape: `%{"upstream" => output_port_descriptor,
"downstream" => input_port_descriptor, "delivery" => core_edge_delivery}`.
Descriptors are decoded by unchanged core/port. Malformed/wrong-direction
upstream/downstream produce `{:requirement, :invalid_upstream | :invalid_downstream}`.

Delivery is validated by unchanged `Elzoo.Edge.decode_binding/1`, **using the
candidate interface's input Port descriptor** with `unit_id = piece_id`,
`delivery = candidate.delivery`, `required_route = false`. Requirement delivery
uses its downstream input Port descriptor, constant unit_id `"requirement"`,
and required_route false. These are validation-only bindings; no unit identity
matching or fused/hop/same-unit placement check occurs. The accepted delivery
set is exactly `{"fused", "volatile"}`; a drift test checks the upstream
declaration and named accepted/rejected boundary samples. Selection adds no
parallel delivery vocabulary.

Phase order: requirement; all candidate shapes in list order (first bad index);
duplicate IDs (smallest duplicate ID); compatibility. Errors are wrapped in
`{:error, ...}`. Shape errors are `{:requirement, :invalid_shape}`,
`{:candidate, :invalid_shape}` for a non-list, or
`{:candidate, index, reason}`; invalid rank/ID shape uses `:invalid_shape`.
Interface and delivery errors preserve dependency reasons. Duplicate IDs use
`{:candidate, :duplicate_id, smallest_id}`. Errors may carry declaration IDs
or indices, never payload or metadata values.

## API and selection

`Elzoo.Selection.select(requirement, candidates)` returns `{:ok, piece_id}`
only for a unique compatible candidate at the best rank. Empty input yields
`{:error, {:selection, :missing}}`. No compatible candidates yields
`{:error, {:selection, {:incompatible, [{piece_id, reason}]}}}` sorted by ID.
A best-rank tie yields `{:error, {:selection, {:ambiguous, sorted_ids}}}`;
there is no ID/list-order tie-break.

`rank/2` returns `{:ok, [{rank, sorted_ids}]}` of compatible candidates,
rank ascending. Empty or wholly incompatible sets yield `{:ok, []}`;
validation errors still propagate. ID order within groups is presentation only.

`Cure.Elzoo.Selection.compatible/2` calls unchanged Cure Port.compatible on
upstream to candidate input, then candidate output to downstream, then compares
delivery. Translation exposes reasons `{:input, reason}`, `{:output, reason}`
and `:delivery_mismatch`. The Cure boundary uses `{:delivery,
:delivery_mismatch}` for the last case to retain a uniform tuple error type.
Records erase to `{:SelectionCandidate, piece_id, interface, delivery, rank}`
and `{:SelectionRequirement, upstream, downstream, delivery}`.

Permutation invariance applies only to well-formed, duplicate-free sets.
Malformed-candidate index selection is deliberately list-order dependent.
No registry/filesystem/network lookup, payload validation, runtime scheduling,
placement, delivery execution or chosen-implementation correctness guarantee.

## Operations and grounding

Config is supported by explicit per-call requirement delivery and candidate
rank, exercised in bundled tests; no ambient or hot reconfiguration.
Telemetry and Control are not_applicable: no observations or lifecycle;
invoking Unit/Assembly owns instrumentation. Pinned Cure compilation checks
the pure decision types. Finite tests cover compatibility, permutations,
ambiguity, error order, drift, per-call config and record ABI; source audit
is not a quantified proof. Upstream Cure structural equality and unchanged
Assembly/Port/Edge contracts are assumptions, as are truthful declarations.
Independent export consumers need no Elzoo.Application or runtime Cure compiler.
