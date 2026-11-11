# ELZ-101 — Bound one Anthropic text stream and its local delivery

- Phase: bounded delivery Adapter
- Catalogue IDs: delivery/data-stream
- Dependencies: ELZ-033, ELZ-006, ELZ-011, ELZ-023, ELZ-079, ELZ-091, ELZ-093, ELZ-099
- Change class: P after ELZ-099 acceptance

New opt-in subset, namespace `Elzoo.DataStream`. Independent admission review
found two final corrections (source-complete usage and exact nested schema);
this publication incorporates both. Coordinator owns shared metadata, implementation
dispatch and acceptance. No implementation starts before ELZ-099 merge acceptance.

## Outcome and admission

For C7 scheduled research, let one authorized application process start one
bounded, potentially charged Anthropic Messages POST and deliver its text
incrementally to one trusted local sink. Own admission, reception bounds,
ordered acknowledgements, source-versus-delivery completion and cleanup together.
There is no assumed GET output service. The application still owns research
policy, authentication, retained results and notification.

This separately selected Piece does not implement `Elzoo.AiText.Provider` or
change `integration/ai-model`, `integration/ai-text`, either synchronous provider,
their Bindings or their sinks. Its Anthropic-specific Adapter and protocol helpers
are private parts of this one Piece, not a general provider interface. Existing
core Usage/Provenance/StreamChunk validators are reused with stricter local bounds.

Reuse Req 0.7.5's synchronous function-`into:` HTTP/1.1 path and unmodified
`server_sent_events` 1.1.0. Elixir/OTP owns processes, clocks and monitors;
ready Cure Backpressure owns the count decision. ReqLLM 1.30.0's high-level
streaming path is unsuitable here: the inspected version accumulates output,
does not cap raw event blocks, can flush synthetic separators and has different
completion rules. No fork, GenStage, new transport or dependency upgrade.

## 1. Construction, caller and API

`start_link(settings) -> {:ok, owner_pid} | {:error, :configuration | :unavailable}`
starts the supplied local owner and its owned temporary execution resources.
Construction is fixed until restart; unknown or duplicate settings fail. Settings:

| Setting | Admissible value/default |
| --- | --- |
| `tenant` | Required bounded ID, as below; host-derived |
| `binding` | Required module built with this Piece's EffectIntent Binding helper; fixes provider account, Adapter ID, operation `generate_stream`, clock `unix-ms`, replay `:none`, revision `:forbidden`, recovery grace `:none` |
| `store`, `host` | Required existing EffectIntent Store and trusted activation callback/context; Store configured with that binding's `fold/1` and `limits/0`; no hidden Memory fallback |
| `allow_volatile` | Default false; true explicitly permits the existing Memory double for tests/examples only |
| `authorized_callers` | 1..64 distinct local pids; default the actual process invoking construction |
| `credentials` | Required zero-arity injected Need, returning `{:ok, key}`; key 1..1,024 ASCII bytes `0x21..0x7E`; failure/invalid return/raise/throw/exit fails closed |
| `models` | Required 1..16 distinct Anthropic model IDs, 1..128 ASCII `[A-Za-z0-9._-]`; only models documented to accept `thinking: disabled`; no automatic model discovery/default/fallback |
| `capacity` | 1..64, default 4; one shared bound for preparing, active, finishing, stopping **and retained** entries |
| `total_timeout_ms` | 1..300,000, default 60,000 |
| `receive_timeout_ms` | 1..30,000, default 5,000; at most total timeout; transport inactivity only |
| `ack_timeout_ms` | 1..10,000, default 1,000; at most total timeout |

No endpoint, method, headers, Req steps/adapter, proxy, TLS override, pool name,
retry, completion marker or provider-options slot is accepted. Production is
fixed `POST https://api.anthropic.com/v1/messages`, `anthropic-version: 2026-10-21`,
`content-type: application/json`, `accept: text/event-stream`,
`accept-encoding: identity`, injected key in `x-api-key` only. This subset requires
a workspace-scoped API key; no OAuth exchange or workspace-selection header.
No key from environment, application config or `.env`. A private test seam may
substitute only loopback HTTP/HTTPS origin with fixed `/v1/messages`, never a
caller URL or arbitrary request function; it is not a production setting.

Public calls (no caller/owner pid supplied as an argument):

| Call | Normal result |
| --- | --- |
| `start(owner, effect, sink)` | `{:ok, handle}`: accepted/pending, not a provider acknowledgement; or `{:refused, local_reason}` |
| `lookup(owner, message_id)` | `{:ok, handle}` for this actual caller's retained admission; `{:error, :not_found}` otherwise |
| `status(owner, handle)` | `{:ok, safe_snapshot}`: phase, closed reason, booleans and counts only |
| `result(owner, handle)` | `{:pending, phase}` or `{:ok, terminal}`; same bounded terminal as owner notification |
| `cancel(owner, handle)` | `{:ok, :pending}` or `{:ok, :already_terminal}`; pending is not cleanup applied |
| `close(owner, handle)` | Live entry: requests cancellation, returns `{:ok, :pending}`; retained entry: removes it and releases capacity, returns `{:ok, :closed}` |

The owner derives caller identity from the actual `GenServer.call` sender.
Only configured callers may start; only the submitting caller may inspect,
read the result or control its handle. A handle is a fresh process-local opaque
reference scoped to this owner generation; possession does not grant authority.
Host authentication/business authorization precedes this local API; Effect
classification is not authorization. This is a trusted-BEAM boundary, not a sandbox.

Snapshot has exactly `phase`, `reason`, `source_complete`, `delivery_complete`,
`offered_frames`, `acknowledged_frames`, `received_body_bytes`, `raw_blocks`.
Phase is `preparing | streaming | finishing | stopping | retained`; absent
reason is `:absent`. Counts are nonnegative; offered/acknowledged <=65,537,
acknowledged <=offered, raw_blocks <=65,536. Received bytes can include the
overflowing current chunk. Frames, terminals, handles, Config and internal
session state are local structs with redacted Inspect implementations; their
declared data fields remain explicitly accessible to the authorized consumer.
Do not return a plain secret-bearing map as an Inspect-safe public value.

All calls additionally return fixed `{:error, :invalid_argument | :unauthorized |
:not_found | :unavailable}` as applicable. Malformed handles/IDs are invalid;
unknown/expired handles are not found; a known handle's wrong caller is
unauthorized. No hidden entries or results accompany these errors. Calls have a
fixed 1,000 ms reply wait. Start timeout returns `{:unknown, :admission}`;
cancel/close timeout returns `{:unknown, :control}`; read timeout returns
`{:error, :timeout}`. Owner loss returns unavailable and does not attest no-send.
Timeout is not refusal: the queued command may have applied. Inspect by stable
message ID/handle if the owner survives; absence after loss/expiry is not resend
authority. No wrapper automatically repeats a timed-out mutation.

## 2. Exact request and serialized start

Preflight exact key sets, bounded metadata and payload bytes before unchanged
`Effect.decode/1`/Envelope validation, then enforce this narrower schema:
classification `untrusted`, capability `delivery/data-stream`, operation
`generate_stream`; command kind `command`, schema ID
`elzoo/anthropic-text-stream-request`, version 1. Required command keys are
`version`, `message_id`, `schema_id`, `schema_version`, `kind`, `producer`,
`payload`, `idempotency_key`, `deadline_unix_ms`; optional `correlation_id` only.
Producer is exactly `{unit_id, port_id}`. All variable IDs here and `tenant`
are ASCII `[A-Za-z0-9._:-]{1,64}`; deadline is Unix-ms integer 0..2^63-1.
No caller-supplied attempt, authorization, credential or delivery metadata.

Payload is a UTF-8 JSON binary, at most 65,536 bytes, exactly:
`{model, messages, max_tokens, system?}`. Messages: 1..32 exact
`{role, content}` objects, role `user | assistant`, alternating, first and last
`user`, content nonempty UTF-8 string at most 16,384 bytes. Optional system is
one nonempty UTF-8 string at most 16,384 bytes. `max_tokens` is integer
1..4,096. Model must be in Config. No tools/tool results, thinking controls,
images/documents, structured output, caching controls, stop sequences, sampling,
batch, server tools, fallback or extra fields. Recognized excluded features
return `unsupported_feature`; unknown fields/types/malformed declarations return
`invalid_request`; byte/count ceilings return `too_large`; expiry returns
`expired`. No silent truncation or ignored request option.

Before constructing **any map from JSON**, use Jason 1.4.5 ordered-object
decoding, recursively reject duplicate decoded keys (including escaped spellings),
then validate and convert. Apply this also to event JSON. A string/escape-aware
precheck limits JSON nesting to 16 and number lexemes to 19 integer digits;
no floats/exponents in this subset. Never intern wire atoms. Syntax/decode
exceptions become fixed reasons, never Jason exception data. Check payload bytes
before decoding and the exact prepared provider-body bytes before admission.
Canonical objects use lexicographically ordered keys and fixed JSON encoding.
Wire body is the admitted request plus fixed `stream: true` and
`thinking: {type: "disabled"}`; total at most 65,536 bytes. Canonically encode
once; those exact bytes are EffectIntent arguments and the only bytes sent.

The **shipped owner** serializes validation, duplicate lookup,
`Backpressure.admit` and creation/registration of one temporary session. No
external permit/grant service and no reusable admission object exist. Saturation
returns `{:refused, :saturated}` without queuing, credential lookup or intent.
Session-creation failure before permitting dispatch is `{:refused, :unavailable}`;
uncertain later setup remains unknown. Exact duplicate declaration/intent identity
and sink function from the same caller returns the existing handle without another
start; changed arguments/deadline/correlation/sink or binding returns
`{:refused, :identity_conflict}`, another caller `{:error, :unauthorized}`.
The complete local refusal set is `invalid_request | unsupported_feature |
too_large | expired | saturated | unavailable | identity_conflict`.
Keep these indexes within the same capacity-bound table.
After local forgetting, the durable intent, not this index, fences dispatch.

Capture wall/monotonic time at public start entry, before waiting for the owner.
Effective monotonic deadline D is the earlier of that instant + total timeout
and the Envelope's remaining lifetime converted once. Validation, admission,
Store/host setup, credentials, pool/connect, reception and every sink callback
spend that same lifetime. Recheck D before every start/offer/ack commit. A timer
only wakes the owner; no timer message or sender-supplied timestamp proves that
an operation occurred on time. Host clock correctness/skew is an assumption.

## 3. Charged Effect boundary: one dispatch, no blind resend

After local admission, compose the **actual** `Elzoo.EffectIntent` owner with
identity `[tenant, provider_account, adapter_id, "generate_stream", logical_ref]`
using command.idempotency_key as logical_ref. No attempt number in the key.
Only its acknowledged intended and dispatched append/checkpoint barriers may
schedule this Piece's Adapter. Adapter checks binding, schema, arguments digest,
session generation and attempt before requesting credentials or HTTP. Store or
activation uncertainty halts, never authorizes a send. Recovery remains read-only
under the accepted host activation protocol; recovered dispatched work cannot
start another stream. This introduces no new activation/grant protocol.

No automatic rearm, retry, reconnect, redirect, authentication refresh or second
POST, including after credentials failure. Same identity/different arguments is
a conflict. `poll/1` returns authenticated `{:unavailable, :no_status_query}`;
no provider idempotency/replay or final-no-effect certificate is claimed.
No cancellation, timeout, HTTP rejection, empty result, worker DOWN or missing
terminal is such a certificate. A deliberately new logical request is an
application decision with possible additional cost, never recovery supplied here.

The new Binding has a total static failure table checked by its compiler:

| Typed Adapter tag(s) | Existing outcome / dispatch / error_class |
| --- | --- |
| `credentials_unavailable` | timed_out / not_dispatched / unavailable; **only** attested no-send tag, normal Need failure before HTTP handoff |
| `provider_invalid_request`, `authentication_failed`, `permission_denied`, `not_found`, `provider_too_large`, `billing_error`, `conflict` | failed / dispatched / permanent |
| `throttled`, `overloaded` | failed / dispatched / retryable; retryability grants no dispatch |
| `provider_timeout` | timed_out / dispatched / unclassified |
| `timeout` (including credentials/setup/sink lifetime expiry) | timed_out / unknown / unclassified; no timer-derived no-send |
| `transport`, `adapter_error`, `caller_cancelled`, `disconnected`, `sink_timeout`, `sink_failed`, `session_lost`, `intent_unavailable` | unknown / unknown / unclassified |
| `provider_error`, `stream_error`, `malformed_response`, `unsupported_response`, `missing_completion`, `receive_limit`, `block_limit`, `event_limit` | unknown / dispatched / unclassified when HTTP response is observed; pre-response failure uses `adapter_error`/`transport` instead |

These tags belong to this new Contract, not AiText's reason sets. Public local
refusals happen before an intent and do not fabricate Adapter no-send evidence.
Provider HTTP failures may have incurred usage. A post-200 SSE `error` is always
partial/unknown, including `overloaded_error`; it is never a local refusal.

On local delivery completion only, return the existing completed/dispatched
Envelope to EffectIntent with exact value `{response_id, outcome_digest, seal}`,
schema `elzoo/anthropic-text-stream-delivery`, version 1. Digest and seal are
lowercase 64-hex SHA-256/HMAC-SHA-256, authenticated against exact intent key,
attempt and this local generation; validate IDs and exact keys. No prompt,
output, credential or raw body enters that result. This seal is local integrity,
not provider authentication. Track intent confirmation separately from local
delivery: a lost/indeterminate settlement write stays unconfirmed. Neither sink
ack nor local complete status is a durable intent receipt or permits resend.

## 4. Transport, framing and selected Anthropic protocol

Build a fresh Req request with function `into:`, `retry: false`,
`redirect: false`, `raw: true`, `decode_body: false`. Fixed connection options
`[protocols: [:http1], timeout: 5_000]`, fixed pool idle timeout 60,000 ms;
finite pool/receive waits, independently cut short by D. Do not vary pool
construction options with remaining lifetime or identities. No HTTP/2 upgrade,
async `into: :self`, Collectable fallback, output accumulator or decompression.
Req's application owns its Finch resources; pool/socket/kernel buffering is
upstream, not an Elzoo bounded queue. Do not accept global Req customizations
that replace this path or add request-capturing steps as part of checked use.

Before processing the first data callback, validate status and headers; repeat
the same validation on the returned response when there was **no data callback**.
Only HTTP 200 with one `text/event-stream` media type (optional sole UTF-8
charset parameter), absent/identity content-encoding, enters SSE parsing.
Reject duplicate/conflicting protocol headers. Optional single `request-id`
is `[A-Za-z0-9_-]{1,128}`; missing is `:absent`, malformed/oversized is a protocol
failure. Header allocation before Req presents it is upstream, not body-capped.
Non-200 never parses as SSE or calls the sink; stop at the first body callback,
discard the body, and classify by status even for an empty body: 400 invalid
request, 401 authentication, 402 billing, 403 permission, 404 not found, 409
conflict, 413 too large, 429 throttled, 504 provider timeout, 529 overloaded;
500/other statuses including 3xx and other 2xx are provider error. A single
valid `retry-after` integer 0..86,400 seconds is optional metadata only; invalid
or absent is unknown. No raw error message/body is exposed or required for this
status-only mapping (thus a 500 `timeout_error` body remains provider error).
Non-200 status classification takes precedence over a discarded body's size;
no overflowing callback is decoded in either case.
HTTP 200 empty body is missing completion after header checks, never success.

**Raw guard before parser:** count all received body bytes first on every
callback/status, including ignored text, comments and suffix bytes. Fixed total
4,194,304; reject the overflowing callback before parsing any of it. A separate
raw framer caps **each whole event block at 65,536 bytes**, including comments,
unknown fields, line endings, blank separator and an initial BOM. Check while
accumulating, before every parser call; unfinished and comment-only blocks use
the same cap. Never rely on the parser's pending-data size or decoded count.

Recognize LF, CR and CRLF across arbitrary splits. A boundary CR's optional LF
must be resolved/count-checked before emitting its block; EOF can establish a
real CR terminator, never synthesize one. At stream start hold up to three
prefix bytes to recognize one UTF-8 BOM across splits; count it, ignore it only
once, and present it whole with the first bounded block to the parser. Interior
BOM bytes receive no special treatment. A partial BOM at EOF is malformed.
Feed the maintained incremental parser **one complete bounded raw block at a
time**, using one state for the stream. Its result is zero or one event; handle
it before scanning/parsing another block. No list of decoded pending events.
Copy bounded retained fields so they cannot pin a larger current chunk.
Count every delimited block, including empty/comment-only blocks: maximum
65,536. Wire/UTF-8/JSON faults or a parser result outside this shape fail closed.

Only named SSE events with JSON-object `data` whose `type` matches the event
name enter the following state machine. Multi-line SSE data follows the parser;
SSE id/retry fields never reconnect or grant authority. Duplicate JSON keys
are rejected before projection. Known-event fixtures/schema must specify exact
required/optional fields, including nested objects; unknown fields/variants
return `unsupported_response`, malformed values `malformed_response`.

| Event | Accepted shape and transition |
| --- | --- |
| `message_start` | Exactly `{type, message}` once; message `{id,type:"message",role:"assistant",model,content:[],stop_reason:null,stop_sequence:null,usage?}`. IDs/model bounded below. Establish provenance; translate optional raw usage. |
| `content_block_start` | Exactly `{type,index,content_block:{type:"text",text}}`, after start/before message deltas; next contiguous index 0..63, at most one block open. Initial text may be empty; nonempty text is offered as a partial text chunk. |
| `content_block_delta` | Exactly `{type,index,delta:{type:"text_delta",text}}` for the open index; text UTF-8, possibly empty. Offer exactly that text as a partial chunk, without accumulating output. |
| `content_block_stop` | Exactly `{type,index}` closes the matching block. No text is synthesized. |
| `message_delta` | Exactly `{type,delta,usage?}` after all blocks close, at least one before stop. Delta has only optional `stop_reason` and `stop_sequence`; absent/null reason permits another delta; one nonnull supported reason is required for stop; stop_sequence absent/null only. Usage is cumulative, not summed. No further content blocks. |
| `message_stop` | Exactly `{type:"message_stop"}`, after start, all blocks closed and nonnull finish established. **Control only:** enter finishing, discard same-callback suffix/pending input and halt transport; never forward as a normal chunk. |
| `ping` | Exactly `{type:"ping"}`, permitted before source stop; counts toward bytes/blocks/deadline, no sink call or lifetime extension. |
| `error` | `{type:"error",error:{type,message},request_id?}` at any pre-stop stage; type ASCII 1..64 bytes, message UTF-8 at most 16,384 bytes, optional request_id uses the HTTP ID grammar. Discard message/ID, retain only closed error tag; stop partial, no sink finish. |

Supported final reasons: `end_turn -> :stop`, `max_tokens -> :length`,
`refusal -> :refusal`, `model_context_window_exceeded -> :context_limit`.
No tools/thinking/fallback/citation/JSON deltas, `tool_use`, `pause_turn`,
`stop_sequence` or unknown finish/event can produce complete. Unknown additions
fail partial explicitly; this is deliberately a strict documented subset, not
acceptance of every valid Anthropic response. Zero text blocks are allowed with
an otherwise valid final sequence; empty HTTP/EOF is not that sequence.
SSE error types map to fixed subreasons: invalid_request_error,
authentication_error, billing_error, permission_error, not_found_error,
conflict_error, request_too_large, rate_limit_error, api_error, timeout_error,
overloaded_error; unknown error type becomes `provider_error`, never an atom
from the wire. Their charged-outcome category remains `stream_error`.

EOF without a valid delimited stop is `missing_completion`; unfinished
UTF-8/JSON/control data is malformed. Discard unfinished bytes on every failed
path. Never call a flush helper, append a blank line, execute a fragment, or use
HTTP EOF, `message_delta`, Req success or worker exit as source completion.

## 5. Sink, finish authority, cleanup and finite retention

The sink is a trusted unary callback. It receives an exact frame struct
`{handle_ref, callback_ref, seq, completeness: :partial, chunk}` where `chunk`
passes core StreamChunk validation with the same seq, kind `text_delta`, binary
payload at most 65,536 bytes. Seq starts at 0, advances on **offer** (not ack),
never reused. One isolated sink worker/call at a time. No next raw block is
parsed and the Req callback does not continue while that offer is unresolved. Outstanding work is
one frame, not an unbounded mailbox/decoded-output buffer.

Return `{:ack, callback_ref, seq}`, `{:cancel, :caller_cancelled}` or
`{:error, :disconnected}`. Other returns/raise/throw/exit are `sink_failed`;
Missing ack expires at min(invocation + ack timeout, D). The owner
uses no timer timestamp as authority: if D is already reached, it records
`timeout`; otherwise an expired callback wait records `sink_timeout`. The sink
supplies no usage or completion truth. An ack is local acceptance of that one
call, not display, persistence, research correctness or billable settlement.

Valid source stop -> **finishing**, not terminal. All previous offers are
already acknowledged. Use a distinct HTTP worker inside the still-live EffectIntent Adapter task.
HTTP result/DOWN precedes the finish acknowledgement; then the Adapter returns
its Envelope for settlement. Adapter DOWN alone does not confirm the later Store
settlement. The owner must receive the matching request worker's
normal halted-result **and DOWN**, then (only while D remains and no failure
won) invoke exactly one final sink worker with exact map
`{handle_ref,callback_ref,seq,completeness: :source_complete,source_complete:true,
chunk: %{seq: seq,kind: :finish,payload: %{reason: finish}}}`.
This says source complete; it cannot announce its own delivery as complete.
Commit complete only on this worker's matching ref/seq ack processed before both
deadlines. A late, duplicate, spoofed, wrong-worker or prior-generation reply
does not count. Internal request, intent-attempt, worker and timer refs fence
all observations. The owner checks its clock/state, not timer arrival order.

Cancel/disconnect/timeout/failure before finish acknowledgement wins partial;
source_complete may remain true. Once a valid finish ack commits, later cancel
is already terminal. No text/usage/finish after the winning terminal transition.
**No terminal/partial/error sink callback on failure**, and no retry of a failed
finish callback. A lost ack leaves delivery unknown even if the sink acted.
Only the surviving submitting caller gets the local terminal notification.

Owner/session processes remain responsive: credentials, Store/host operations,
EffectIntent dispatch/settlement, HTTP and sink work run on tracked workers.
Each session owns a linked Task.Supervisor; its live bootstrap worker parents
the EffectIntent process and remains alive through that operation. Adapter
tasks use that same supervisor. Register the supervisor/worker custody with the
admission owner **before** permitting any HTTP/sink work. Session monitors the
actual caller and admission owner. On either DOWN it stops. Session death also
shuts down its linked supervisor and tasks through OTP parent/link ownership,
including abrupt `:kill`; cleanup must not depend on its `terminate/2` running.
No default-restarted session, detached task or supervisor may resend.

On any failed path revoke launch/offer authority, stop/kill all owned outstanding
workers and the intent/bridge as appropriate, observe their monitors, and only
then retain a terminal/release resources. Use shutdown grace 1,000 ms, then
`:kill` for remaining owned processes; this is a cleanup action, not a promise
of real-time scheduling or proof of socket closure. The admission owner must
also observe registered execution-supervisor DOWN on abnormal session death.
If cleanup is unresolved, keep the entry stopping and count it against capacity;
do not manufacture release or complete. A late Store/credential result cannot
obtain a launch grant from a stopped/expired session. Workers recheck D and
live custody immediately before HTTP handoff; an already authorized handoff can
race cancellation until worker termination is observed. No physical-send fence
or instantaneous deadline scheduling is claimed. Store writes already accepted
may still commit; their outcome remains unknown.

For successful/failed normal execution the owner sends once
`{:data_stream_terminal, handle_ref, terminal}` after local cleanup. All terminal
entries logically expire 5,000 ms after the summary is retained following cleanup,
or earlier on authorized
close/caller death. Expiry is checked on lookup/admission as well as timer wake;
release Backpressure once after cleanup and removal, not at source stop or
callback timeout. Active + stopping + retained <= capacity; no terminal registry
outside that bound. Session/owner/VM loss may lose this notification and all
local output/usage. Owner death triggers owned cleanup, not replay/recovery.

Worker DOWN proves process death only. Require loopback HTTP/1.1 peer-close
observations for halt/cancel/kill scenarios; do not infer them from DOWN. Local
read shutdown neither retracts text nor cancels Anthropic generation/billing.
Req/Finch connection cleanup and real Internet peer behavior remain upstream;
no general HTTP/2, TLS/socket timing, remote cancellation or drain guarantee.

## 6. Bounded owner result and accounting

Terminal has exactly `status`, `reason`, `provider_reason`, `source_complete`,
`delivery_complete`, `offered_frames`, `acknowledged_frames`,
`received_body_bytes`, `raw_blocks`, `last_usage`, `incurred_usage`, `provenance`,
`correlation`, `intent_confirmation`, `retry_after`. Status is
`complete | partial | refused`; complete's reason is `completed`. Refused is
credentials unavailable or one of the non-200 rejection statuses
400/401/402/403/404/409/413/429/529; all other failures are partial.
Reason is one table tag above, provider_reason the closed SSE
subreason or `:absent`. Offered/acknowledged counts include the finish call;
source stop itself is not offered. No prompt/output/raw error/HTTP headers in
terminal. `intent_confirmation` is `confirmed | unconfirmed | no_attempt`;
unknown write is unconfirmed, never inferred from a local ack. Complete denotes
the scoped source/delivery fact only, even when confirmation is unconfirmed.

Usage comes directly from validated raw Anthropic `message_start.message.usage`
and `message_delta.usage`, before any sink can change it. Optional usage objects
accept only `input_tokens`, `output_tokens`, `cache_read_input_tokens`,
`cache_creation_input_tokens`, `cache_creation`, and `output_tokens_details`.
All these keys are optional. A usage object may be absent or null: absent
preserves the previous observation, null records unknown for its components.
An object has no required counters; unknown keys are unsupported.
`cache_creation` is absent, null, or an object with only optional
`ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens`.
`output_tokens_details` is absent, null, or an object with only optional
`thinking_tokens`. Nested absent objects preserve the previous group, null
objects replace the group with unknown, and present objects replace their group
with omitted/null members unknown. Nonobject nonnull containers are malformed.
No other nested keys are allowed. Scalar counters absent/null are unknown,
present invalid/negative/noninteger/>2^63-1 are malformed, never clamped to zero.
Thinking amount must be absent/unknown/0 in this text-only subset. Other usage
fields/variants are unsupported in this initial strict schema.

Input excludes cached tokens. Translate input/cache/write components and their
unknown-preserving prompt total as the accepted AiModel convention requires;
when total and TTL breakdown disagree or the breakdown cannot establish the
total, cache writes stay unknown, never a partial sum/double count. Each reported
cumulative component replaces its earlier value: 2 then 5 is 5, not 7. Omitted
top-level components preserve prior observations; explicit null replaces that
component with unknown. The nested-group replacement rules above take precedence.
No synthetic zero. New cache-write
reports replace that group together rather than merging incompatible TTL bases.
Reject a known derived sum exceeding 2^63-1 as malformed; it cannot escape the
local amount bound through the more permissive shared validator.
Do not import the synchronous provider's internal helper or ReqLLM normalized
zero-filled usage into this closure.

Use `last_usage: :absent` until an event contains a usage key (including null).
Thereafter keep at most one exact map `%{usage: merged_usage, event_index: index,
stage: stage}`. Usage is the merged bounded observation after applying that event;
stage is `:message_start | :message_delta`. Index is zero-based across validated
named protocol events, including ping, before source stop; comment/empty raw blocks
do not increment it. It is bounded by the raw-block ceiling. This is independent of Req's returned accumulator,
and bounded provenance; retain it on every later failure. At source stop, a
reported message-delta output count is the final cumulative output observation;
an output count seen only at message_start is interim: retain it in last_usage
but set output to unknown in the final usage value, not that interim count.
Before validated source completion, `incurred_usage` is `:unknown`, even with
a last observation. At validated source completion freeze
`{:provider_reported, final_usage}`. Later delivery, cleanup or intent-confirmation
failure does not erase it. Unreported final components remain unknown; absent
final output stays unknown. With no usage observation, freeze the bounded
all-unknown usage value; this does not assert the provider reported any counter.
This is provider-reported usage, not a reconciled invoice or charge. Missing
usage is allowed even for complete delivery. No bytes-as-tokens, price estimate,
meter write, Budget settlement/release or durable usage reconciliation.

Provenance is `:absent` until a validated start, otherwise the unchanged core
value: model_ref `{provider:"anthropic",model_id:requested,wire_surface:"messages"}`,
provider_model from start, response_id from start, optional request_id from HTTP,
provider_piece `delivery/data-stream`. Response ID is `[A-Za-z0-9_-]{1,128}`,
provider model uses the 128-byte model grammar. Correlation is exactly bounded
original `{message_id,correlation_id,logical_ref,intent_key,attempt_id}`; absent
correlation defaults to message_id; key is 64 lowercase hex; attempt ID follows
the actual EffectIntent format (64 hex + `/attempt/` + decimal 1..256). Before an attempt it is
`:absent`. Total terminal encoding at most 4,096 bytes: recursively turn local structs into
plain field maps (remove only __struct__), retain fixed atom keys/tags and UTF-8
binary values, and measure `byte_size(:erlang.term_to_binary(value, [:deterministic]))`
without compression on pinned OTP. This is a size-accounting representation, not a
persistent/wire interchange format. Canonically order usage counter/TTL lists by
their unit/TTL names; this slice emits only input_uncached_tokens, cache_read_tokens,
output_tokens and reasoning_tokens, plus at most two 5m/1h cache-write entries
(or one provider_default unknown/total entry when the split is unknown).
Preflight the maximal schema, never drop a required observation to fit. No unbounded amount, ID or
arbitrary provenance bag. Sensitive IDs, usage/provenance/correlation appear
only in the authorized owner result/notification, never status/Inspect/logs.

Status, custom Inspect and OTP format_status show safe phases, fixed reasons,
booleans and numeric counts only. Redact Config, handles, request/worker state,
exceptions and callback contexts; no payload, credential, arbitrary exception,
ID, secret-bearing closure or full Req term in errors, logs or telemetry.
Host bounds API traffic/mailboxes; Backpressure does not bound those. Trusted
callbacks must not detach work from the supplied custody. Host-installed
upstream handlers/raw BEAM debugging are trusted, not a hostile
inspection boundary. Document Req/Finch upstream telemetry separately.

The resource claim is retained raw input <=65,536 plus the current received
chunk, one bounded decoded event/frame and bounded owner summaries, with no
output history/backlog. The total-byte limit can be exceeded by one observed
receive chunk before halt. Binary copies/decoded term overhead, BEAM heaps,
TLS/Finch/kernel buffers and sink-retained data are not a total RSS law.

## 7. Prerequisite reconciliation and source-copy closure

**Task dependencies:** ELZ-033, ELZ-006, ELZ-011, ELZ-023, ELZ-079,
ELZ-091, ELZ-093, **ELZ-099**. Recheck their acceptance at publication/dispatch.
Live issues #55/#6/#11/#37/#153/#165/#171 were read closed on 2026-11-11;
their ready source boundaries were inspected at the baseline. Historical
roadmap "claimed/PR pending" observations do not override those live states.
ELZ-099 [#185](https://github.com/balungpisah/elzoo/issues/185) is open and being
implemented; this task is not implementation-ready until it is merged/accepted.

| Earlier record | Explicit disposition |
| --- | --- |
| RC-14 -> ELZ-033, ELZ-006 | Preserve both task edges: admission policy and ready Backpressure/deadline semantics. Count policy is not a transport/mailbox byte bound. |
| ELZ-050 -> core/effect, delivery/backpressure | Preserve direct Piece dependencies; owner actually serializes admit/release. Replace inaccurate `Needs: None` with the Needs here. |
| ELZ-011, ELZ-023 | Add explicit task/EffectIntent composition grounding for the charged POST. Existing declaration/barrier/recovery Contracts unchanged; no new GET assumption or local resend ground. |
| ELZ-079 / RC-16 | Add accepted family values and synchronous-boundary inspection. RC-16's only output was superseded; it is not a second task or a source of streaming guarantees. No silent extension of its accepted text Pieces. |
| ELZ-091, ELZ-093 | Accepted source-copy/config closure and bounded reception precedents; neither implements this stream. Add explicit task edges for that composition review. |
| ELZ-099 | Sole pending package prerequisite: fuse 2.5.0 and direct server_sent_events 1.1.0, preserving existing parser lock/provider entry. ELZ-101 uses no fuse/circuit behavior; ELZ-100 is not a prerequisite. No further dependency/config/toolchain change without a justified separately admitted finding. |
| GenStage / ReqLLM candidate disposition | Retain candidate history, select direct Req + maintained SSE parser for this topology for the source reasons above; no copied/forked SDK. |
| RC-05 / credentials | No implemented secrets Piece assumed; credential is an injected Need, matching accepted provider practice. |
| ELZ-025 completion/flush findings | Explicit partial frames, separate acknowledged source-complete finish, real delimiters and failure discard satisfy this selected slice; no fabricated EOF event. |
| C8, C9, other RC-14 promises | Upload/multipart/integrity, reusable provider-neutral streaming, replay/durable delivery, routing, pricing and reconciliation remain unimplemented here. This is only the C7 Anthropic text-output slice. |

**Direct Piece dependencies:** `core/effect`, `delivery/backpressure`,
`delivery/effect-intent`, `integration/ai-model`. Req and Jason are used directly
as in the inspected integration/http and integration/json recipes; no wrapper
dependency required. EffectIntent carries its actual checkpoint/event-log/SQL
closure; a Memory fixture does not erase that dependency. Do not depend on
ai-text or either synchronous provider. Direct provider record: Req 0.7.5,
Jason 1.4.5, server_sent_events 1.1.0, Elixir 1.20.4/OTP 29.1.2; inherited Cure
pin `208248063d64e621782cd26dd30698ee42850a89`. Finch 0.24.0/Mint 1.11.0 remain
Req's recorded transitive transport, not new direct dependency changes.

Needs: host current authority/stable identity, workspace-scoped credential,
verified TLS/network egress to the fixed endpoint, configured Store/activation
host and its durability/retention, trusted bounded sink/callback behavior, clock
and local OTP supervision. The Piece supplies local concurrency ownership and
worker cleanup. Host supplies business auth, egress policy and durable result/
usage retention; no root catalogue Application or globally named Elzoo process.
Telemetry **planned** (no Elzoo event); Config **supported**, construction only;
Control **supported**, caller-scoped cancel/close/status/result with pending,
unknown and applied distinctions. No pause/resume, hot update or business drain.

Scope of the eventual task: own `pieces/delivery/data-stream/` source, README,
manifest, in-bundle tests/support/fixtures/examples; scoped catalogue/provider
references and coordinator-owned roadmap/ledger integration. Provider records
reuse accepted pins. No ready source/Contract or dependency/config/workflow edit.
Any necessary shared consumer registration is listed and coordinated before
editing; the isolated copy test itself belongs in this Piece.

## 8. Acceptance required of implementation (none claimed run here)

1. Capture one real loopback HTTP/1.1 POST; assert exact endpoint/path, version,
   injected credential, forced stream/thinking settings, canonical admitted body,
   request and wire-byte ceilings and every excluded feature refused before
   credentials/intent. Document-format schemas are hand-derived with sources/
   fetch date; require positive fixtures and targeted negative controls.
2. Exercise the actual EffectIntent barriers/Binding, not a call-shaped mock:
   blocked/failed/indeterminate Store or activation causes no HTTP start; timeout
   after dispatch, crash-before/after-send, same-identity re-admission/recovery,
   credential failure and every provider failure cause no automatic second POST.
   Scope Memory evidence as volatile; exercise durable SQL barrier composition
   against a disposable DB for the deployed no-resend claim.
3. Concurrent starts at capacity 1 and larger: one serialized admission winner,
   no start after saturation, no reuse/forgery of handles, actual caller auth for
   every API, duplicate/conflict cases, admission/control reply lost to timeout
   is unknown, not refusal. Active/stopping/retained entries share capacity;
   retention 5,000 ms/early close, stale refs and single release are exercised.
4. Boundary/split matrix: complete and partial BOM, UTF-8, CR/LF/CRLF; raw block
   cap exact/+1 **including separator**, huge comments/unknown fields, endless
   unfinished block, empty blocks and many events in one receive chunk, total
   4 MiB exact/+1, no decoded backlog under slow sink. Include a mutation that
   caps only decoded/unfinished data and prove the comment/block test catches it.
5. Real selected sequence and state negatives: start/closed indices, initial
   text, zero text, cumulative usage, each finish, duplicated/out-of-order events,
   mismatched type, missing reason/start/stop, EOF mid-event and a stop without a
   real separator. Unknown/tool/thinking/fallback variants and post-200 errors
   stay partial. EOF/flush-is-success mutation must fail. Duplicate JSON keys at
   every nesting (also escaped equivalents), huge amounts/IDs and bad headers
   fail; malformed provider text is never exposed. All status mappings tested,
   including empty-body statuses/200, duplicate content type and encoded body.
6. Source stop alone stays finishing; withhold request DOWN and prove **zero**
   finish calls; after normal halted-result/DOWN, exactly one source-complete
   call. Matching final ack before D alone commits complete. Test cancel/deadline/
   ack in both serialized orders, delayed timers, wrong worker/seq/ref/generation,
   late/duplicate acks, failed/hung finish and no failure-terminal sink callback.
7. Block credentials, pool/connect/headers, continuous pings, request and sink;
   independent deadline/control stays responsive. Kill submitting caller,
   session and admission owner abruptly while work is blocked. Assert actual
   owned task/intent/supervisor termination, no detached/restarted request, no
   release before cleanup, and separately observe loopback peer close for
   unfinished HTTP/1.1 halt/kill/cancel. DOWN alone is not that observation.
8. Raw provider usage 2 then 5, omitted final output, absent/null cache fields,
   valid cold/warm/mixed TTL reports, inconsistent/partial cache reports,
   interruption after usage and after source stop: prior observation survives,
   incurred total stays unknown before source completion. Explicit acceptance pair:
   final output count 5 + valid stop + failed finish ack yields partial delivery,
   source_complete true and provider-reported output 5; the same usage without
   valid stop yields incurred_usage unknown. Sink-supplied usage is an invalid
   return. Bound maximal terminal/provenance/correlation encoding; no raw data,
   secret or IDs in status/Inspect/format_status/error/log/telemetry captures.
9. Export only this selection and its declared Piece/provider closure into an
   independent Mix consumer/BEAM. Start only its documented applications, own
   Store, local owner and support. Req application actually starts Finch;
   server_sent_events has no ReqLLM registry/.env Need; :crypto and inherited
   Cure compiler/app registration and SQL deps are explicit. No Elzoo.Application,
   root test helpers, sibling fixtures, ai-text/Anthropic synchronous source,
   ReqLLM, fuse, or undeclared support/module is loaded to make the test pass.
   Root-level unrelated dependency presence cannot be evidence for closure.
10. Copied tests repeat real callback transport and cleanup, not just Req.Test.
    Assert explicit `protocols: [:http1]` reaches the constructed pool and test
    TLS ALPN against a loopback server offering h2 and http/1.1: actual selected
    protocol/request is HTTP/1.1, cert verification preserved, h2 not used. Loopback
    CA configuration remains a private test seam; never weaken production TLS.
    No external paid calls or environment-dependent live conformance tests.

Grounding separates schema/Binding checks, finite runtime/protocol tests, narrow
peer-close/monitor observations and the named upstream Contracts. No new Cure
proof is required; inherited Backpressure/EffectIntent laws keep their original
scope. No universal memory, provider authenticity, billing, remote cancellation,
delivery durability or exactly-once proof. Required worker checks for the later
task are `mix check --affected <accepted-base>` and
`mix test pieces/delivery/data-stream/test`, with exported-consumer evidence and
required exact-head hosted checks/review under AGENTS. This design task ran no
mix setup/check, implementation test, dependency build or paid request.

## Primary references and publication decisions

Current primary docs read 2026-11-11: [Messages create](https://platform.claude.com/docs/en/api/messages/create),
[streaming](https://platform.claude.com/docs/en/build-with-claude/streaming),
[errors](https://platform.claude.com/docs/en/api/errors),
[versions](https://platform.claude.com/docs/en/api/versioning),
[authentication/headers](https://platform.claude.com/docs/en/api/overview#authentication),
[thinking/model differences](https://platform.claude.com/docs/en/build-with-claude/thinking#turning-thinking-off).
Pinned source inspected: Req function-into/status/Finch pool option path,
server_sent_events Parser (BOM/CR/framing), Jason ordered objects. The coordinator
retains the prior RC-14 private research/probes as upstream feasibility
observations, not tests of this proposed API. Mint 1.11.0's forced HTTP/1 path
does not negotiate ALPN; the TLS test records that fact and the actual HTTP/1.1
request rather than demanding an invented ALPN negotiation result.

Coordinator adopts this exact strict subset, defaults, failure table and task/source
ownership. Reconcile RC-14/dependency metadata, showing ELZ-099 as an unmet
prerequisite until its acceptance. Implementation waits for that acceptance. No unresolved
package-change request is proposed. Actual credential, model allowlist and
durable Store/authorization are deployment Needs, not invented services. A new
material incompatibility with the pinned transport/parser or accepted intent
boundary must stop implementation for deliberate Contract/prerequisite review.
