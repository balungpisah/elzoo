# delivery/transformation

`Elzoo.Transformation.translate(envelope, target, fun)` validates the source
Envelope, then the exact target `%{"unit_id" => nonempty_text, "message_id" =>
nonempty_text, "port" => core_port_descriptor}`. Target Port must decode and
have output direction (`{:error, {:target, :invalid_direction}}`).

It applies the caller's payload function, returning `{:ok, new_envelope}` with
target producer/schema/version and caller-supplied message ID, causation ID set
to the source message ID. It explicitly sets correlation_id to the source's
correlation_id when present, otherwise the source message_id, preserving the
effective conversation identity across the new message ID. It preserves kind, trace_id,
attempt_id, reply_to, deadline_unix_ms and **idempotency_key**, including
absence for those fields. It drops producer-stream sequence. Idempotency is not producer-scoped
by ELZ-003; a fresh message ID must not silently break downstream deduplication.
The resulting Envelope is validated; payload remains opaque, not target-schema
validated. Deadlines remain data, never evaluated.

Errors are `{:error, {:envelope, reason}}` for source/result Envelope decoding
and `{:error, {:target, reason}}` for target shape/Port errors.
Malformed target shape/identity is `:invalid_shape`. Checks precede callback
invocation. Errors may include declaration identifiers/indices in the catalogue,
but this Piece returns only fixed atoms, never payload or metadata values.
**Caller callback exceptions/throws propagate unchanged**, outside that error
contract; function purity/correctness and its failures are caller assumptions.

No Cure module or new erased record is needed: this is an Elixir re-wrap using
unchanged core/envelope and core/port validation. Use Enum/Stream directly for
batch/lazy map/filter/scan via the unchanged delivery/stream-combinators recipe.
Enrichment requiring lookup is a separate request/reply Effect followed by pure
merge, never inline I/O here. No lookup, timers, processes, telemetry, ID
generation, dispatch or payload-validation guarantee is provided.

Telemetry, Config and Control are not_applicable: intrinsic data/caller function,
no ambient settings, hot reconfiguration, lifecycle or observations. Invoking
Unit/Assembly owns instrumentation. Bundled finite tests cover preservation,
absence, opaque payloads, failures, output-only targets and callback propagation;
no quantified proof is claimed. Upstream Elixir Map/Enum/Stream and dependency
Contracts are relied upon. Shared Envelope examples are reused unchanged.
Export tests run copied sources without Elzoo.Application or a Cure compiler
at runtime (Cure is needed only to compile the dependency checks).
