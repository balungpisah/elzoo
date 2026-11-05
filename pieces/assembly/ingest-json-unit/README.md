# assembly/ingest-json-unit

New opt-in Piece ID: adds JSON, Adapter and Host Needs to the unchanged
`assembly/ingest-dedup-accumulate`. Its Cure operators are reused through that
dependency, never copied. Existing consumers keep the old Piece unchanged;
opt in by selecting this ID and supplying supervised Units plus JSON envelopes.

`Elzoo.IngestBoundary.handle(placement, units, json, opts \\ [])` returns
`{:ok, result_json}`, `{:error, :invalid_json}`, `{:error, :invalid_envelope}`,
or `{:error, {:wiring, reason}}`. Placement is `:fused` or `:hop`.
Units is `%{"pipeline" => lookup}` or `%{"dedup" => lookup, "accumulate" => lookup}`;
each lookup follows runtime/adapter's pid/zero-arity callback contract. Use the
consumer-owned runtime/host recipe to supervise operators:

* pipeline: `Cure.Elzoo.Core.assembly/2`, initial `Cure.Elzoo.Core.empty/0`;
* dedup: `Cure.Elzoo.Idempotency.receiver/2`, initial `[]`;
* accumulate: `Cure.Elzoo.Core.accumulate/2`, initial `0`.

## Wiring and codecs

`wiring/1` owns both declarations. Fused ingress connects pipeline's
`ingress.request` output to `dedup.input`, schema `example/ingest-message` v1.
The GenServer.call into pipeline is Adapter/Host entry, NOT traversal of the
fused edge. That edge is an internal seam inside the single transition, checked
by the Boundary on behalf of the pipeline/ingress.request producer.
Hop ingress connects client.request to dedup.input; dedup.accepted connects to
accumulate.input using `example/accepted-message` v1, both volatile hop edges.
The external producer must match; it is never rewritten.

Count and Accepted decode exactly sender/incarnation/sequence/value keys, all
BEAM integers (unbounded; no range claim). Floats including 1.0, bools, null,
strings, extra/missing keys are rejected. Wrong schema/version is unsupported.
Total checks the internal Message tuple and integer fields. Count/Total encode
integer totals or suppressed nil; Accepted carries a Message only internally.
No tuple appears in outer JSON. Value schema is `example/optional-count` v1.
`opts[:codecs]` is a map with optional `:count`, `:accepted`, `:total` codec
module overrides; these are trusted application-owned boundary callbacks.

## Hop results

First-hop rejection, timeout, unknown (including unknown dispatch), or failure
passes through unchanged without calling accumulate. Duplicate suppression is
completed/dispatched with nil. A fresh Message produces an inner Envelope:
outer ID plus `/dedup-accumulate`, producer dedup/accepted, kind event,
causation outer ID, echoed correlation/attempt/deadline, internal Message payload.
All final JSON results retain outer identity.

| Second-hop result after fresh dedup | Outer result |
| --- | --- |
| completed | completed/dispatched with total |
| rejected/not_dispatched | failed/dispatched/unclassified |
| timed_out | timed_out/dispatched/unclassified |
| unknown, any dispatch | unknown/dispatched/unclassified |
| failed or internal error | failed/dispatched/unclassified |

JSON decode errors are redacted. An unencodable result uses a fixed
failed/dispatched/unclassified fallback with outer IDs and no value. The
Boundary never echoes payload, exception or Jason error data in errors or logs.
Successful values are codec-owned. Upstream OTP crash reports from unchanged
Units may log last request/state, controlled by consumer Logger configuration.

## Evidence and limits

Named crash-free trace and seeded random model tests compare direct
`Elzoo.Runtime.fused/1` to JSON through supervised Units for both placements.
Equivalence holds ONLY for these named crash-free traces; no general
call-versus-hop equivalence is claimed. Tests cover strict codecs, redaction,
fallback, composite outcomes, duplicates and restart re-acceptance. Relies on
pinned Cure, Elixir, OTP and Jason contracts; no new Cure law is claimed.

The second-hop Adapter `{:error, _}` row is a defensive mapping: it cannot be
reached from public inputs and is not directly tested. The transient
`:restarting` lookup state is handled, but tests do not force it deterministically.

Volatile single-host synchronous exemplar, unbounded history/mailbox, not
durable, not exactly-once, not ordered across hosts, not a complete old Zoo
receiver. Hop partial failure may mark a key seen without accumulating it;
no partial-failure atomicity or retry/redelivery guarantee.
After a partial hop failure (outer failed: dedup advanced, accumulator output
lost), a retry of the same key reports completed with a nil value, the same as
duplicate suppression, without recovering the lost accumulator output. Callers
must not read that nil as "already counted".
The inner hop Envelope intentionally does not carry trace_id, idempotency_key
or reply_to, and dedup keys on the payload Message fields.
Deadlines are echoed, not enforced. Telemetry is planned; per-call placement/codec
Config is supported; Control inherits runtime/host lifecycle only, not business drain.
Codec and lookup callback exceptions (raising callbacks) are a caller contract
and out of scope. Final results, including duplicate and combined results, are
checked by `Elzoo.Envelope.validate_result/1` before JSON encoding.
