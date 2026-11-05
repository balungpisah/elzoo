# runtime/adapter

`Elzoo.UnitAdapter.deliver(unit_lookup, wiring, edge_id, envelope, codec)` makes
one synchronous call to an unchanged `Elzoo.Unit`. Lookup is a pid or a zero-arity
function returning a pid, `:restarting`, `:undefined` or `nil`.

`Elzoo.UnitAdapter.Codec` specifies consumer-owned `decode_payload/3`,
`encode_output/1` and `value_schema/0`. These trusted callbacks perform runtime
value validation, not descriptor type proofs. Per-call codec and wiring choices
are Config; there is no configurable timeout or retry policy.

## Contract

Envelope decode failure returns `{:error, {:envelope, reason}}`; invalid wiring
returns `{:error, {:wiring, reason}}`. Otherwise `{:ok, result}` is a neutral
string-keyed DeliveryResult. It echoes message ID, correlation ID (message ID
fallback), attempt ID and deadline when present. Envelope metadata is not used
as the Unit's dedup key. First failure wins:

| Observation | outcome | dispatch | error_class |
| --- | --- | --- | --- |
| Route unknown or producer/schema/version mismatch | rejected | not_dispatched | permanent |
| Payload codec rejects | rejected | not_dispatched | permanent |
| Lookup returns `:restarting`, `:undefined`, `nil` | rejected | not_dispatched | unavailable |
| Call exits `{:timeout, _}` | timed_out | dispatched | unclassified |
| Call exits `{:noproc, _}`, including dead pid | unknown | unknown | unclassified |
| Other call exit | unknown | dispatched | unclassified |
| Output not `:none` or `{:some, _}` | failed | dispatched | unclassified |
| Output codec rejects | failed | dispatched | unclassified |
| `:none` | completed | dispatched | absent |
| `{:some, v}` | completed | dispatched | absent |

Completed results include the codec's value schema; suppression has `value: nil`,
fresh output has its encoded value. Failure results contain no value or raw
error data. The Adapter emits no raw payload, exception or Jason error data in
its results/errors/own logs; successful output is explicitly codec-owned.

## Grounding and limits

Tests in `test/elzoo/unit_adapter_test.exs` cover each row and validate every
successful result map through `Elzoo.Envelope.validate_result/1`. No new Cure
proof is claimed. Relies on pinned Elixir/OTP GenServer behavior, including call
aliases dropping late replies. State may already have advanced after failure.

`dispatched` means message submitted, not receiver execution. A noproc exit
cannot establish non-execution: a callback can perform an effect then exit
`:noproc`. There is no `Process.alive?` decision in the Adapter.
`timed_out` is the observed OTP call-timeout exit reason, not proof that 5000 ms
elapsed (a callback can exit with the same reason). The actual default call
timeout is 5000 ms.

Single-host, volatile, unbounded mailbox; no ack, redelivery, durability,
ordering, deadline enforcement or exactly-once claim. Telemetry is planned;
Control inherits only runtime/unit OTP lifecycle, not business drain. Upstream
OTP crash reports from the unchanged Unit may log the last request/state, an
inherited limitation controlled by the consumer's Logger configuration.
