# delivery/data-stream

An opt-in, text-only Anthropic Messages streaming Adapter, namespace
`Elzoo.DataStream`. Its complete selected Contract is [ELZ-101](https://github.com/balungpisah/elzoo/issues/187).
It does not implement or change either synchronous AiText provider.

## Use and construction

Define an application binding once:

```elixir
defmodule Research.StreamBinding do
  use Elzoo.DataStream.Binding,
    id: "research-stream", provider_account: "workspace-account"
end
```

Configure the existing EffectIntent Store with
`Elzoo.EffectIntent.fold(Research.StreamBinding)` and
`Elzoo.EffectIntent.limits()`. Supply its existing trusted activation host
(`Elzoo.EffectIntent.StoreHost` with a separately configured host Store is one
option). There is no default Store. Memory requires explicit `allow_volatile:
true` and is only a volatile test/example double. A production host must
reconcile old owners and uncertain writes under EffectIntent's accepted
activation protocol; the example's fresh-only authority is not recovery policy.

Call `start_link/1` with `tenant`, `binding`, `store`, `host`, a zero-arity
`credentials` Need returning `{:ok, key}`, and `models`. Models must be explicitly
chosen from models documented to accept `thinking: disabled`; there is no
discovery/fallback. Credentials are printable non-space ASCII, 1..1,024 bytes;
they are used only as `x-api-key`, never read from ambient configuration.

Construction-only optional settings are `authorized_callers` (1..64 distinct
local PIDs; defaults to the actual constructor), `capacity` (1..64, default 4),
`total_timeout_ms` (1..300,000, default 60,000), `receive_timeout_ms` (1..30,000,
default 5,000) and `ack_timeout_ms` (1..10,000, default 1,000). The latter two
must not exceed total timeout. Tenant, binding ID and account have the bounded
ELZ-101 ID grammar. Unknown/duplicate settings fail configuration. No URL,
HTTP/TLS/plugin/retry/provider-options setting is exposed. The private loopback
entry is exclusively for trusted tests, with an optional CA file and fixed path;
production always verifies TLS at the fixed Anthropic endpoint.

`start(owner, effect, sink)` accepts the exact untrusted Effect/Envelope and
JSON request schema of ELZ-101. Payload: model, alternating user/assistant
messages beginning/ending in user, max_tokens and optional text system. Bounds:
65,536 payload and canonical wire bytes; 32 messages; 16,384 bytes per nonempty
content/system; max_tokens 1..4,096. Tools, thinking, caching controls, nontext,
sampling and all other options are excluded. Duplicate decoded JSON keys,
floats/exponents, nesting above 16 and integer lexemes above 19 digits are
refused before constructing maps. One canonical body, with `stream: true` and
`thinking: {type: disabled}`, is both the intent arguments and exact POST bytes.

The actual GenServer caller owns its handle. Only configured callers may start;
only the submitting caller can read/control it. `lookup/2` uses stable message
ID, `status/2` returns safe phase/reason/counts, `result/2` returns pending or the
bounded terminal, `cancel/2` requests cancellation, and `close/2` cancels live
work or forgets a retained result. Calls wait 1,000 ms: timed-out start/control
is **unknown**, never refusal. No wrapper retries. A missing local admission
is not resend authority. This is a trusted BEAM boundary, not a sandbox.

## Ownership and delivery

The shipped owner serializes validation, duplicate/conflict lookup and actual
Cure Backpressure admission. Preparing, active, finishing, stopping and retained
entries share one capacity. Retention is 5,000 ms after observed cleanup, with
expiry checked on reads/admission as well as timers. Close/caller death may
remove earlier. Capacity releases only once, after cleanup and removal.

A session owns its linked Task.Supervisor. Its bootstrap worker parents the
actual EffectIntent and lives through dispatch/settlement. Credentials, HTTP,
Store/host and sink work do not block session controls. Custody is registered
with the owner before launch. Abrupt owner/caller/session loss shuts owned
workers down; a 1,000 ms cleanup grace precedes kill. Cleanup unresolved means
stopping and capacity retained, not successful release. A previously authorized
HTTP handoff can race cancellation until termination; no physical-send fence.

Sinks get one redacted Frame struct at a time. Return
`{:ack, frame.callback_ref, frame.seq}`, `{:cancel, :caller_cancelled}` or
`{:error, :disconnected}`. Every other return/exception is sink_failed. Sequence
advances on offer. A block is processed before scanning another block, and the
Req callback waits for each ack. No decoded backlog or text history exists.

A valid delimited message_stop freezes source completion and provider usage,
then halts HTTP. Only its matching normal halted result **and** request-worker
DOWN authorize a single FinishFrame with `completeness: :source_complete`.
This frame cannot claim its own delivery. Only a matching final ack processed
before both deadlines commits delivery complete. Failure has no terminal/error
sink callback. Final ack loss can mean the sink acted; no finish retry occurs.
Only the surviving submitting caller receives
`{:data_stream_terminal, handle.ref, terminal}` after cleanup.

## Protocol and accounting

Req 0.7.5 synchronous function-into is configured with retry/redirect off, raw
and decode_body false. Fixed connection options select only HTTP1, connect
5,000 ms and pool idle 60,000 ms. They pass through Req.Finch.pool_options to
the current Finch options interface, avoiding deprecated request options.
Req's application owns the pools. No global Req defaults/plugins are imported.
The one monotonic lifetime includes validation, setup, credentials, pool/connect,
reception, every callback and ack commit. Receive timeout is inactivity only.

Validate 200 protocol headers even with no data callback. Non-200 classification
is status-only and takes priority over discarded-body size. Total bytes cap:
4,194,304 plus one observed overflowing chunk. Each **whole raw block**, including
comments, unknown fields, BOM, line endings and separator, is capped at 65,536
before the maintained server_sent_events 1.1.0 parser. At most 65,536 delimited
blocks; one incremental parser state; LF/CR/CRLF and split BOM/UTF8 are handled.
Boundary CR's possible LF is resolved before emitting. EOF resolves real CR;
it never appends a separator or flushes unfinished data into an event.

Exact schemas live in Protocol: message_start; contiguous one-open text blocks;
text_delta; block_stop; message_delta; message_stop; ping; error. Nested exact
keys are checked as well. Unknown variants/fields fail unsupported_response;
malformed shape/order fails malformed_response. Four finish reasons map to stop,
length, refusal, context_limit. Zero text is allowed with the valid final sequence.
Post-200 errors are partial/stream_error, even overloaded_error. No raw error
message survives translation. HTTP EOF/Req success is not completion.

Raw cumulative usage is translated independently of sink returns, with unknown
preserved under the exact nested omission/null rules. Values replace, never sum
successive reports. Cache-write TTL bases replace together; incomplete or
inconsistent totals remain unknown. Derived sums also obey signed-64-bit bounds.
An interim start-only output count stays in last_usage but becomes unknown in
final usage. Before valid source stop incurred_usage is unknown. At source stop
it freezes as provider_reported, surviving later finish/cleanup/settlement failure.
This is provider observation, not an invoice, price, metering or Budget receipt.

Terminals contain only the 16 declared fields. IDs, core provenance, usage and
correlation are bounded; their recursively struct-stripped, uncompressed,
deterministic ETF size is at most 4,096 bytes. Construction preflights a maximal
schema representation. Inspect/format_status hide payloads, keys, IDs, closures,
worker context and usage. Status contains only the eight declared safe fields.

## Needs, evidence and limits

Direct Pieces: core/effect, delivery/backpressure, delivery/effect-intent,
integration/ai-model. The inherited Store/checkpoint/SQL closure remains real.
Direct providers: Req 0.7.5, Jason 1.4.5, server_sent_events 1.1.0, Elixir 1.20.4,
OTP 29.1.2; inherited Cure commit 208248063d64e621782cd26dd30698ee42850a89.
Consumer applications include req (starts Finch), jason, server_sent_events,
crypto, cure and the inherited ecto_sql/postgrex closure. No catalogue Application,
ReqLLM, fuse, synchronous provider or ambient dotenv is needed.

Needs: authenticated host authority/stable identities, workspace-scoped API key,
TLS/network egress, accurate host clocks, durable Store/activation/retention and
a trusted sink that keeps its work in custody. Host owns durable result/usage
retention and bounds API traffic/mailboxes. Telemetry is planned: no Elzoo event.
Req/Finch emit their own upstream telemetry (including transport request
metadata); consumer-installed handlers are trusted and must redact it.

Tests are finite protocol, ownership, copied-source and actual PostgreSQL/HTTP1
scenarios. No new Cure proof is claimed; inherited laws retain their scope.
Schema fixtures are hand-derived, not an official machine-readable specification.
Primary docs fetched 2026-11-11: [Messages](https://platform.claude.com/docs/en/api/messages/create),
[streaming](https://platform.claude.com/docs/en/build-with-claude/streaming),
[errors](https://platform.claude.com/docs/en/api/errors),
[versioning](https://platform.claude.com/docs/en/api/versioning),
[authentication](https://platform.claude.com/docs/en/api/overview#authentication),
[thinking](https://platform.claude.com/docs/en/build-with-claude/thinking#turning-thinking-off).
Run `mix test pieces/delivery/data-stream/test` in the catalogue; the independent
consumer test runs the copied boundary tests in a separate VM with only the
selected upstream application closure.

No paid/live conformance calls; no automatic rearm, retry, reconnect, redirects,
provider status query, idempotency/replay certificate, provider authentication,
remote cancellation, delivery durability, billing reconciliation, universal RSS
bound or exactly-once claim. DOWN is process-death evidence; only the selected
loopback observations establish peer close in those scenarios. TLS/Finch/kernel
buffers, current receive chunks, decoded term overhead and sink-retained data
are outside the retained-input bound. Copying/redistributing source still obeys
the catalogue namespace and provenance rules.
