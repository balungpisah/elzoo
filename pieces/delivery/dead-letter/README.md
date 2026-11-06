# delivery/dead-letter

Redacted failure data, not a queue/store. Apache-2.0. Depends on core/envelope;
that ready Contract/schema is unchanged.

`Elzoo.DeadLetter.from_result(request, result_or_nil, attempts, reason)`
validates request and optional failure result identity/deadline, then returns
`{:ok, map}` or a fixed-atom error. `validate/1` returns the same valid map,
`decode/1` a Cure record and `encode/1` the neutral map. Never pass untrusted
erased tuples to encode. No dynamic atoms are created.

Exact required string keys: version (1), message_id, correlation_id, attempts
(integer >= 0), reason. Optional: last_outcome/last_dispatch/last_error_class
(**all three or none**, a valid core/envelope failure row), last_attempt_id,
deadline_unix_ms (nonnegative integer). No payload, value, trace, exception or
unknown keys. Reasons: permanent, retries_exhausted, deadline_expired,
dispatched_unresolved, deadline_before_dispatch. The caller produces
deadline_before_dispatch after the runner's refused-expired admission, with
attempts=0; this path is tested. A completed DeliveryResult is not a failure
record. Nil result supports a record with no last-result triple.

Cure DeadLetterRecord field order is documented in the source; Strings erase
to {:String, charlist}, Options to :none/{:some, value}. Cure validates record
version/identity/attempt count/reason/deadline; Elixir validates foreign shape
and reuses Envelope for failure-row compatibility. Finite roundtrip/redaction
and malformed-input tests are test evidence, not a proof.

Sink/storage/retention and reconstructability are caller Needs. A caller may
keep the original work under its own storage Contract keyed by message_id.
No persistence, durability, telemetry, Config or Control supplied.
