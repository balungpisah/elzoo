# assembly/http-job

Publish one bounded immutable JSON object at a consumer-controlled HTTP origin.
The Adapter uses Req 0.7.5 and Jason 1.4.5; the runner composes existing
`delivery/effect-intent` and `integration/jobs` with Oban 2.24.2. HTTP is never
called through `assembly/durable-job`'s pure handler. This is a tested loopback
publication protocol, not integration with a named vendor.

## Admission and ownership

Define a binding with `use Elzoo.HttpJob.Binding, id: "publication-v1",
origin: "https://publication.example", recovery_grace_ms: 60_000`.
The origin is part of `provider_account` and therefore the binding digest and
intent identity. A different origin requires a binding for that origin.
Runtime origin must match it at configuration and every send. No query,
credentials, path or fragment is allowed in the origin. DNS/TLS/network policy
and authenticated provider behavior remain host Needs. Plain HTTP is accepted
for loopback/provider fixtures; the host must require HTTPS for credentials
that must not travel in clear text.

`Elzoo.HttpJob.configure/1` checks trusted construction options: binding, origin,
tenant, queue, separate transport and caller Task.Supervisors, credentials/0,
authenticate/2, resolve_intent/1; optional observer/1 and bounds. No hot update.
Use bounded Task.Supervisors, e.g. `task_spec(name, max_children)`; host owns
these children and the separate EffectIntent supervisor (one Adapter at a time).
Transport and caller pools must differ, and transport must differ from the
owner's one-slot pool. Consumers must not replace them with unbounded pools.
Configuration is trusted in-process data, not a wire API or authority token.

`admission(config, declaration)` consumes `core/effect`. It requires untrusted
classification, capability `integration/http`, operation `publication`, command
kind, schema `elzoo/publication` version 1, explicit `idempotency_key`, and
`deadline_unix_ms`. The fifth identity field is **idempotency_key**, never
message_id. Tenant comes from trusted config; the other fields are binding
provider_account, id and operation. The absolute Unix-ms deadline is copied
unchanged; no default is guessed. Payload must be binary exact UTF-8 JSON bytes
and is persisted/sent unchanged. The returned map contains key, identity,
arguments and deadline; it does not create an owner or enqueue a job.

The host creates/checkpoints the existing EffectIntent using that admission,
its Store/StoreHost, trusted clock/grant callback and `adapter_context: config`
before enqueueing. It registers `runner(config)` with Elzoo.Jobs for its queue
and enqueues `Elzoo.Jobs.changeset(queue, admission.key, provider_attempts)`.
Job args are exactly v/queue/job_key; no payload, origin or credentials.
`resolve_intent(key)` returns `{:ok, existing_owner_pid}`; it must never recreate
absent history, invent a key or grant recovered authority. The runner checks
status.key. Queue registration is host-owned and must be removed at shutdown;
Jobs without registration snooze per its existing Contract. Host cannot infer
business drain from OTP stop.

## Protocol and authority

PUT `/publications/<64-hex-derived-key>` sends the exact arguments; GET the same
path polls. Provider binds key to those immutable bytes and rejects changed
arguments. This is an upstream Need, not a consequence of the HTTP verb.
Req retries, redirects, decoding and compression are disabled. Credentials/0
returns `{:ok, authorization_header}` or an explicit pre-Req typed failure.
Only `{:error, :preflight_unavailable}` and `{:error, :request_rejected}`
attest no send; the host must keep that attestation truthful. The latter is
permanent and disarms. Exceptions, pool failures and ALL outer timer expiries
are unknown, including expiry while preparing credentials. No timer guesses
whether transport was entered. No generic request options escape the boundary.

Publication JSON has exact fields version=1, kind="publication", text (UTF-8,
<=8192 bytes). Request/response bytes <=16384; decoded depth <=8, nodes <=128,
object entries <=32, keys <=128 bytes. Jason ordered objects preserve duplicate
keys for rejection before map construction; no custom parser or atom keys.
Unknown request fields are refused; unknown provider fields are dropped.

Receipt fields: version=1, key and digest lowercase 64-hex, kind nonempty UTF-8
<=64 bytes without controls, ack an actual Boolean. Unknown kinds remain opaque
strings and never gain trust. Normalization is idempotent in tested scenarios
and always untrusted. Successful 2xx uses the same rules including 202. Header
`x-elzoo-signature` must be one bounded nonempty value. A host authenticator
validates the normalized receipt (including status, signature, ack and kind)
against the trusted request. Fixture HMAC covers key/digest/ack/kind/status.
Production authenticity, credential policy and clock skew remain Needs.

A structurally valid ack=true receipt returns a completed Envelope; the owner
validates identity/digest/schema and authenticates it, retaining bounded refusal
for bad key/digest/MAC. Validation and authentication never accept a caller's
Boolean assertion. Ack=false becomes pending after authentication. Invalid,
encoded or oversize response is unknown. Nonidentity Content-Encoding is refused;
parser/header/chunk allocations remain upstream, not whole-process memory bounds.

| Send observation | Typed tag / outcome, dispatch, class |
| --- | --- |
| Explicit pre-Req temporary refusal | preflight_unavailable / timed_out, not_dispatched, unavailable |
| Explicit pre-Req permanent refusal | request_rejected / rejected, not_dispatched, permanent |
| HTTP 4xx (including 401/403/409/422/429) | http_4xx / failed, dispatched, permanent |
| HTTP 5xx | http_5xx / failed, dispatched, retryable |
| Redirect | http_redirect / failed, dispatched, unclassified |
| Valid authenticated ack=false | not_acknowledged / unknown, dispatched, unclassified |
| Invalid receipt | receipt_invalid / unknown, dispatched, unclassified |
| Receive/total timeout | transport_timeout / timed_out, unknown, retryable |
| Other transport loss/exit | transport_error / unknown, unknown, unavailable |

Error-class labels never authorize a send. Poll 404/HTTP errors/transport loss
are unavailable; ack=false pending. Both `no_effect` and `unknown_to_provider`
are rejected by authentication. Replay is none; this subset has no provider
no-effect certificate. Absent evidence cannot rearm. Adding those semantics
later requires a new Piece ID. A late authenticated completion may confirm or
quarantine under the existing owner's history rules.

## Runner and limits

Every wake resolves/checks the existing owner, calls expiry, rereads status,
then takes at most one dispatch/poll/rearm action through the owner. Cure owns
the pure action decision. Inactive/unavailable/error/unknown replies return a
fixed error consuming provider attempts; no blind retry of a timed-out command.
Caller timeout does not cancel a queued owner operation. Confirmed returns :ok;
Stranded or quarantined Intended/Dispatched returns cancel/operator_required,
without polling. Definite quarantine/disarm also cancels. Intended dispatch
refusal cancels/not_dispatchable; Definite rearm refusal or persisted attempt
maximum cancels/exhausted. A dispatch/rearm refusal can race with another live
execution advancing the owner. The runner rereads status once: if the same action
is still selected it keeps that refusal; a new actionable phase snoozes for the
normal poll delay, and a terminal phase returns its terminal result. It sends no
second owner command in that wake. This prevents a stale refusal from cancelling
healthy Dispatched work. Owner CAS guards still decide actual permission.

Maximum persisted attempts 1..16 (default 3). Dispatch/poll success or poll
start-capacity refusal snoozes poll_seconds; rearm success snoozes one second.
Every scheduled poll delay is ceil(total_ms/1000)+1 .. 30 seconds. Defaults:
total=3000 ms, connect=receive=1000 ms, poll=4 seconds, control=35000 ms,
observer=100 ms. Total <=3000, connect/receive <=1000, control <=60000,
observer <=1000. Inner linked tasks enforce outer total time, including request
preparation/authentication; killing a local task does not retract wire bytes.
Pool capacity is finite and may refuse without authorizing send.

Finite recovery grace is mandatory, and ceil(grace/poll_delay_ms)<=512. This
arithmetic DOES NOT bound concurrent/rescued wakes or pre-deadline polling.
Oban error backoff can start at one second; unlike scheduled polls, an error
retry can overlap an existing send/poll and consume a counted Lost observation.
Completion authentication also uses the bounded transport pool: contention can
retain a refusal for an otherwise valid completion; later polling or host
reconciliation is required. Neither condition supplies a rearm ground.
The existing owner's event/evidence limits may saturate; saturation must fail
closed. Clocks, store availability and scheduling fairness remain Needs.
Host must continue expiry/operator reconciliation when a job exhausts or is
cancelled while the intent is Dispatched; quarantine requires operator work
and does not become Stranded by expiry. No background maintenance loop is added.

Every recovery is read-only until the bound trusted host grant. Re-wake the
existing unique Oban ID after reconciliation; duplicate enqueue cannot override
terminal uniqueness. Pinned Basic retry_job accepts scheduled/retryable/completed/
discarded/cancelled, ignores available/executing, raises max_attempts if needed,
and returns :ok even for absent ID. Host must inspect persisted state. Orphan
executing rows need Lifeline; retry_job alone cannot rescue them. Lifeline can
rescue live workers; owner serialization/CAS, not Oban uniqueness, fences sends.

`cancel(config, oban, key)` reports cancelled_jobs count and external_outcome
unknown. Zero means no job was cancelled. Control timeout is unknown. It stops
job wake-ups best-effort, cannot kill/retract the owner's HTTP transport and
never establishes a no-send ground. The retained intent is inspected separately.

## Grounding and operations

Tests run real PostgreSQL/Oban and loopback Req; finite cases include success,
forged receipts, timeout/lost ack, duplicate/concurrent/rescued wakes, quarantine,
preflight, expiry, cancellation, recovery, bounds and source mutations. Cure
checks declaration/action types and owned-source audits; no new quantified
external-effect or no-I/O proof is claimed. Maintained Req/Finch comparison is
recorded in docs/work/ELZ-011-focused-probes.md and the initial proposal (catalogue
research; not required by copied consumers). Pinned provider behavior and
truthful host/provider assertions are separate from tests.

The observer runs only through a bounded job-caller task with fixed event,
outcome and elapsed_ms; no key, URL, body, credential or raw exception is emitted.
Observer throw/hang is dropped and cannot cause a repeat. This is observation,
not durable audit. Upstream Oban events, network/provider logging and host
Logger policy are inherited host concerns. No direct telemetry dependency,
hot reconfiguration or business drain is claimed. Root Elzoo.Application is
not required; the consumer supplies Repo/Oban and explicit bounded supervisors.
