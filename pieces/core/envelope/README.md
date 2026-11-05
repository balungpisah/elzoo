# core/envelope

Minimal version-1 neutral message and delivery-result declarations. Cure checks
metadata decisions; Elixir validates foreign representations and translates
nominal Strings/Options. No payload codec, timer, Effect or transport executes.

## Envelope Contract

`Elzoo.Envelope.decode/1` accepts an exact string-keyed map with required keys:

- `version`: integer `1` (format version, not a Piece Contract version).
- `message_id`, `schema_id`: nonempty UTF-8 text, exact equality, no normalization.
- `schema_version`: positive integer; compatibility is exact, like core/port.
- `kind`: `command`, `event`, `reply`, `error` or `control`.
- `producer`: exact `{unit_id, port_id}` map with nonempty UTF-8 text values.
- `payload`: any BEAM term, including nil; opaque and never validated here.

Optional keys, absent rather than null: `correlation_id`, `causation_id`,
`idempotency_key`, `trace_id`, `attempt_id` (nonempty UTF-8 text), `sequence`
(nonnegative integer), `deadline_unix_ms` (nonnegative absolute wall-clock Unix
epoch milliseconds), and `reply_to` (exact `{unit_id, port_id}` named endpoint
map, nonempty UTF-8 text, never a pid). No arbitrary metadata extension bag.
Unknown keys, invalid UTF-8/types, missing required keys or explicit null
metadata fail. Payload nil is distinct from an absent payload key.

No default deadline or expiry decision exists. ELZ-006 owns expiry decisions
and conversion to relative/monotonic OTP timers in an Adapter. Cross-host clock
skew is an execution assumption, not resolved by storing a wall-clock deadline.

`decode/1` returns `{:ok, cure_record}` or `{:error, reason}`. `encode/1`
reverses a validated record; it is not an arbitrary-term validator. Generic
Cure `EnvelopeMessage(a)`, `DeliveryResult(a)` and `ReplyEndpoint` record field
orders are in the source. `validate/1` checks a neutral map and returns the
original map on success. Payloads need a separate application codec/schema
checker. Version 1 defines a BEAM/neutral-map representation, not canonical
JSON bytes or a network serialization standard.

## Shared delivery result (ELZ-006 / ELZ-007)

`decode_result/1`, `encode_result/1` and `validate_result/1` require keys
`version` (=1), `message_id`, `correlation_id` (both nonempty text), `outcome`,
`dispatch`. Optional `deadline_unix_ms` echoes the request's deadline, not the
observation time. Optional `attempt_id` echoes the request attempt.

| outcome | dispatch | additional keys | meaning |
| --- | --- | --- | --- |
| completed | dispatched | `value`, `value_schema_id`, `value_schema_version` required | completion reported by the named boundary |
| rejected | not_dispatched | `error_class` required | boundary reports no dispatch |
| failed | dispatched | `error_class` required | definitive boundary failure; partial external Effects remain possible |
| timed_out | not_dispatched | `error_class` required | timeout reported before dispatch |
| timed_out | dispatched | `error_class` required | **unknown external outcome**, not proof that no Effect happened |
| timed_out | unknown | `error_class` required | dispatch itself and external outcome unknown |
| unknown | dispatched or unknown | `error_class` required | non-timeout loss of observation, external outcome unknown |

`error_class` is one of `retryable`, `permanent`, `unavailable`, `unclassified`.
Those are labels, not a classification or retry policy; even `retryable` never
authorizes blind retries of an unknown external outcome. Inspect/reconcile it.
Completed `value` is any term including nil; its schema ID is nonempty UTF-8
text and version a positive integer: declarations, not payload validation.
Error results cannot contain `value` or either `value_schema_*` key; completed
results cannot contain `error_class`. Cure Option distinguishes a completed
nil value from a missing value. No free-form exception text in error metadata.

Result `message_id` names the **request** Envelope's message ID. Its required
`correlation_id` echoes request.correlation_id if present, otherwise the request
message ID. A retrying caller must assign distinct `attempt_id` values while
keeping operation/correlation identity; late-result matching is ELZ-006/007
policy, not established by shape validation. Both attempt fields are optional
for non-retrying consumers. A result is standalone data, or the payload of a
`reply`/`error` Envelope with schema `elzoo/delivery-result` version 1. That
outer Envelope has its own message ID/producer; completed.value's separate
schema does not replace the wrapper schema. The shared examples show layering.

Changing this ready behavioral Contract requires a new Piece ID and reviewed
prerequisite, not a private ELZ-006/007 extension. Both tasks consume the same
checked examples in `examples/shared.exs`.

## Boundaries and grounding

IDs are caller supplied: no uniqueness, authenticity, authorization,
deduplication or correlation matching follows from well-formed text. Kind is
only a tag, not permission to execute control commands. Trace IDs are diagnostic
references, never business payloads, credentials or personal data; no IDs
should be derived from sensitive data. Completed values have the same redaction
rules as payloads. Pure checks emit no telemetry/logs; a runtime/Adapter owns
redaction and must not emit decoded payloads or completed values by default.
Errors return fixed reason atoms, never supplied field values.

Strings and nonnegative numbers are unbounded by this shape (BEAM integers);
callers must bound untrusted ingress/resource use. Pids/refs/functions may be
payload terms but are not portable wire values; cross-host representation and
payload size belong to a separate codec Contract.

Type: pinned Cure compilation checks the generic records and decision code.
Test: listed shape, ABI, Unicode, result-matrix and negative scenarios, plus
independent copied-source consumers. No new quantified proof is claimed.
Upstream: pinned Cure String/Option/Result/structural-equality erasure. No
compiler soundness, transport ordering, durable delivery, exactly-once,
cancellation, error-classification or external success guarantee is claimed.

Telemetry and Control: not applicable, pure data checks with no lifecycle.
Config: not applicable; fields are intrinsic data, not ambient settings.
