# runtime/telemetry

One bounded, redacted family of synchronous `telemetry` events for the ready
job and effect Adapters. The library is `telemetry` 1.4.2 (Apache-2.0);
Elzoo owns only the event names, the measurement units, the metadata allowlist
and the redaction function in `Elzoo.Telemetry`. Dispatch, handler attachment
and detach-on-failure are `telemetry`'s.

Observation only. An event may be missing. It is not an audit record, a usage
meter, a billing input or a control receipt. No exporter, aggregation,
tracing, logging format or persistence is delivered; a consumer attaches its
own handlers (for example a later `integration/observability` exporter).

## Events

<!-- elzoo-telemetry:events -->
| Event | Measurements |
| --- | --- |
| `[:elzoo, :job, :start]` | `queue_wait` |
| `[:elzoo, :job, :stop]` | `duration` |
| `[:elzoo, :job, :exception]` | `duration` |
| `[:elzoo, :effect, :start]` | `payload_bytes` |
| `[:elzoo, :effect, :stop]` | `duration` |
| `[:elzoo, :effect, :exception]` | `duration` |

A measurement may be absent when its source is absent (for example a Relay
pass has no `queue_wait`). No other measurement exists.

## Units

<!-- elzoo-telemetry:units -->
| Measurement | Unit | Definition |
| --- | --- | --- |
| `queue_wait` | microsecond | Oban `attempted_at − scheduled_at`, clamped at 0 |
| `duration` | microsecond | `System.monotonic_time/0` difference, converted once from native units |
| `payload_bytes` | byte | byte size of the request arguments; never the bytes |

## Metadata allowlist

Every value is checked against a positive grammar. All strings are ASCII by
grammar; JSON punctuation, whitespace, controls, `/`, `@`, `?`, `#`, `=`, `+`
and `%` are refused by every string grammar, so a payload, URL, header value
or base64 token cannot pass.

<!-- elzoo-telemetry:keys -->
| Key | Grammar |
| --- | --- |
| `adapter` | `"assembly/durable-job"` or `"assembly/http-job"` |
| `operation` | `:perform`, `:relay` (job); `:send`, `:poll` (effect) |
| `request_ref` | `\A[0-9a-f]{64}\z` |
| `attempt` | integer `1..1_000_000` |
| `queue` | `\A[a-z][a-z0-9_]{0,31}\z` |
| `tenant` | `\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z` |
| `outcome` | declared atom per operation (stop events) |
| `reason` | `:raise`, `:throw`, `:exit` (exception events) |

`request_ref` is always a digest, never caller bytes: the http-job derived
intent key, or the SHA-256 hex of a durable-job `job_key` (`Elzoo.Telemetry.ref/1`).

Required (R), optional (O) and absent (—) keys per operation; stop events add
`outcome` (R), exception events add `reason` (R):

<!-- elzoo-telemetry:operations -->
| Adapter | Operation | Family | adapter | operation | request_ref | attempt | queue | tenant |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `assembly/durable-job` | `perform` | job | R | R | R | R | R | — |
| `assembly/durable-job` | `relay` | job | R | R | O | — | R | — |
| `assembly/http-job` | `perform` | job | R | R | O | R | O | O |
| `assembly/http-job` | `send` | effect | R | R | O | O | — | O |
| `assembly/http-job` | `poll` | effect | R | R | O | O | — | O |

<!-- elzoo-telemetry:outcomes -->
| Operation | Outcomes |
| --- | --- |
| `perform` | `ok`, `snooze`, `cancel`, `error` |
| `relay` | `done`, `skip_indeterminate`, `skip_contended`, `skip_foreign_run`, `skip_rejected`, `skip_insert`, `skip_unique_lock_held`, `skip_malformed`, `skip_damaged`, `skip_unavailable`, `skip_other` |
| `send` | `completed`, `pending`, `unavailable`, `preflight_unavailable`, `request_rejected`, `http_4xx`, `http_5xx`, `http_redirect`, `not_acknowledged`, `receipt_invalid`, `transport_timeout`, `transport_error` |
| `poll` | `completed`, `pending`, `unavailable`, `preflight_unavailable`, `request_rejected`, `http_4xx`, `http_5xx`, `http_redirect`, `not_acknowledged`, `receipt_invalid`, `transport_timeout`, `transport_error` |

An outcome is the head of a result only; a reason term, an exception message
or a stack trace is never carried.

## Redaction and modes

`Elzoo.Telemetry.metadata/2` is the pure check: `{:ok, clean}` or
`{:error, {:invalid, keys}}` (missing or invalid required keys, unknown keys).
An optional key whose value fails its grammar is dropped, never an error.

`Elzoo.Telemetry.emit/4` checks measurements and metadata, then calls
`:telemetry.execute/3` with the clean subset:

- `:production` omits every failing key and still emits; it never raises.
- `:strict` raises `ArgumentError` naming only the failing keys, never values.

`emit/3` uses `default_mode/0`, fixed at compile time: `:strict` when Mix is
loaded and `Mix.env()` is `:dev` or `:test`, otherwise `:production` (a copy
compiled in `:prod` never raises). An invalid emission is an instrumentation
defect of the emission point, outside every Adapter's result Contract.

**Limit.** An opaque alphanumeric secret is lexically indistinguishable from
an identifier and passes the `tenant` grammar. Secrets are kept out by source:
each key is filled from one named identity field of the Adapter (credentials,
arguments, receipts, URLs and exceptions are never read at an emission point);
the grammar is a second layer. A host that names a tenant or queue with a
secret is outside this Contract.

## Handlers

`telemetry` runs handlers synchronously in the emitting process. A handler
that raises, throws or exits is detached by `telemetry` (upstream contract)
and does not change the Adapter result. A slow handler adds its time to the
emitting process; see each Adapter's README for where emission sits relative
to its timers and deadlines. No emission point sits inside a bounded Adapter
timer.

Limit: a handler's run time is elapsed time; a handler slower than the remaining deadline makes the operation expire exactly as any other delay would.

Operator advice: handlers must be fast and non-blocking; offload export or any
slow work to another process (`docs/operational-contracts.md`,
Telemetry contract).

## Operations

Telemetry supported (this is the event family). Config not applicable: the
allowlist is fixed data and the mode is a compile-time build property. Control
not applicable.
