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
`idempotency_key`, `trace_id` (nonempty UTF-8 text), `sequence` (nonnegative
integer), `deadline_unix_ms` (nonnegative absolute Unix epoch milliseconds).
No default deadline or expiry decision exists. Cross-host clock skew and
monotonic timer conversion belong to the executing Adapter. No return-address
or arbitrary metadata extension bag is supported in this minimal Contract.
Unknown keys, invalid UTF-8/types, missing required keys or explicit null
metadata fail. Payload nil is distinct from an absent payload key.

`decode/1` returns `{:ok, cure_record}` or `{:error, reason}`. `encode/1`
reverses a validated record; it is not an arbitrary-term validator. The generic
Cure `Message(a)` record and its field order are in the source. `validate/1`
checks a neutral map and returns the original map on success. Payloads need a
separate application codec/schema checker. Version 1 defines a BEAM/neutral-map
representation, not canonical JSON bytes or a network serialization standard.

## Shared delivery result (ELZ-006 / ELZ-007)

`decode_result/1`, `encode_result/1` and `validate_result/1` use required keys
`version` (=1), `message_id`, `correlation_id` (both nonempty text), `outcome`,
`dispatch`. Optional `deadline_unix_ms` has exactly the Envelope units. The
outcome-specific exact shapes are:

| outcome | dispatch | additional keys | meaning |
| --- | --- | --- | --- |
| completed | dispatched | `value` required, any term including nil | completion reported by the named boundary |
| rejected | not_dispatched | `error_class` required | boundary reports no dispatch |
| timed_out | not_dispatched | `error_class` required | deadline/timeout reported before dispatch |
| timed_out | dispatched | `error_class` required | **unknown external outcome**, not proof that no Effect happened |

`error_class` is one of `retryable`, `permanent`, `unavailable`, `unclassified`.
Those are labels, not a classification or retry policy. Error results cannot
contain `value`; completed results cannot contain `error_class`. The distinct
presence bit uses Cure Option so a completed nil value is not a missing value.
No free-form exception text or payload is placed in error metadata. This
minimal shape does not yet represent an Effect that definitively failed after
dispatch; do not mislabel it rejected. Changing this ready behavioral Contract
requires a new Piece ID and reviewed prerequisite, not a private ELZ-006/007
extension. Both tasks consume the same checked examples in `examples/shared.exs`.

## Boundaries and grounding

IDs are caller supplied: no uniqueness, authenticity, authorization, deduplication
or correlation matching is established by well-formed text. Kind is a tag, not
permission to execute control commands. Trace IDs are diagnostic references,
never a place to copy business payloads, credentials or personal data. These
pure checks emit no telemetry or logs. A runtime/Adapter owns redaction and
must not emit the decoded payload by default.

Type: pinned Cure compilation checks the generic records and decision code.
Test: listed shape, ABI, Unicode, result-matrix and negative scenarios, plus
independent copied-source consumers. No new quantified proof is claimed.
Upstream: pinned Cure String/Option/Result/structural-equality erasure. No
compiler soundness, transport ordering, durable delivery, exactly-once,
cancellation, error-classification or external success guarantee is claimed.

Telemetry and Control: not applicable, pure data checks with no lifecycle.
Config: not applicable; fields are intrinsic data, not ambient settings.
