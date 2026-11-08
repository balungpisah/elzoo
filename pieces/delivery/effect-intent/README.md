# Dispatched effect intent

`delivery/effect-intent` owns one bounded outward-effect intent for refund,
publish or charge callers. A local send follows acknowledged intended and
dispatched append **and checkpoint** barriers. Timeout, task death and recovery
are unknown outcomes, never permission to send again. This is a source bundle,
not a provider integration or an exactly-once service.

## Interface and identity

Use `Elzoo.EffectIntent` as the supported boundary. Internal Model/Policy and
Cure functions are implementation details, not alternate admission interfaces
or BEAM security boundaries. The consumer starts its own Store, Task.Supervisor
and ephemeral owner; no catalogue Application or global registry is required.
The [example](examples/effect_intent.exs) runs with an explicitly acknowledged
volatile Memory double. Production supplies a durable Store such as the
`integration/sql` Adapter, its Repo, migrations and storage configuration.

`start_link/1` accepts trusted host options:

- `binding`: a module using `Elzoo.EffectIntent.Binding`;
- `identity`: five nonempty UTF-8 binaries, each at most 256 bytes, in order
  tenant, provider account, Adapter ID, operation kind, logical request reference;
- `arguments`: canonical application-owned binary, at most 65,536 bytes;
- `deadline`: nonnegative signed-bigint Unix milliseconds;
- `clock`: trusted zero-argument function returning milliseconds in the binding's
  named clock domain; no cross-host clock guarantee;
- `store`: existing Store tuple configured with `fold(binding)` and `limits()`;
- `host`: `{TrustedCallback, context}`, described below;
- `task_supervisor` and `adapter_context`: caller-owned effect execution boundary;
- `allow_volatile: true`: mandatory only when explicitly using Memory.

The derived key is lowercase SHA-256 of versioned length-framed identity fields.
Attempt number does not enter it. Exact admission recovers the existing intent;
same identity with different current arguments or binding refuses startup.
Arguments, hashes and identity remain classified durable data; access control,
canonicalization and stable identity are host Needs. Binding revisions cannot
silently change recovered intent semantics.

`advance(owner, :dispatch | :rearm | :poll | :expire)` serializes commands.
`:dispatch` returns `{:ok, :dispatched}` only after both barriers and scheduling
one task; it does not acknowledge a provider effect. `:rearm` returns
`{:ok, :Stop}` after the new intended barrier, with a separate explicit dispatch.
`:poll` schedules a provider observation and returns `{:ok, :polling}`.
There is no automatic timer, retry, polling cadence, business drain or network
cancellation. The host bounds command/task/mailbox rates and callback duration.
`observe(owner, envelope)` accepts authenticated correlated provider results;
`revise(owner, canonical_arguments)` revalidates schema and allowed history.
`status/1` exposes key, phase, revision, attempt/evidence counts, flags and active
mode without argument/result payloads. It is inspection, not a durable receipt.
Synchronous call timeout is unknown. An unavailable/indeterminate write makes the
owner read-only; recover and reconcile instead of retrying the local send.

## Binding and provider Needs

The Binding macro checks the Adapter's callback exports and total exact mapping
of `failure_tags/0` at build time. Required callbacks are `schema/0`,
`validate(arguments, schema)`, `send_effect(request)`, `poll(request)`,
`authenticate(observation, request)` and `validate_result(envelope, request)`.
Validation/authentication success is `:ok`; exceptions/refusals fail closed.
The request contains operation key, attempt ID/number, checked schema, argument
bytes/digest, binding digest and Adapter context. Historical observations carry
the historical digest; bytes are nil if arguments have since changed.

A send returns the unchanged core/envelope result map or
`{:error, declared_tag, detail}`. The descriptor maps every tag to
`{outcome, dispatch, error_class}` in the seven valid failure pairs; successful
`completed/dispatched` is the eighth pair. Every not-dispatched tag has an
explicit `no_send_attestations` entry: no request bytes reached transport.
That assertion is an upstream Need, not a local proof. Completed results must
pass the binding's output-schema and exact-request checks. Envelope alone does
not validate the provider payload or authenticate anything.

Only `poll/1` can return `{:pending | :unavailable | :unknown_to_provider |
:no_effect, evidence}`; the binding authenticates it against the exact request.
Poll can also return a completed Envelope. A send cannot mint these poll-only
certificates. No caller-supplied Boolean is reconciliation authority.
`provider_no_effect` must be final and fence delayed processing of that attempt.
Generic failure, timeout, absence, partial effect and permanent labels on a
possibly-dispatched result are not that certificate.

Binding configuration fixes `id`, `provider_account`, `operation`, `clock`,
`failures`, no-send attestations, `revision` (default `:forbidden`),
`recovery_grace_ms` (default `:none`) and `replay` (default `:none`). Replay is
`%{window_ms: w, max_flight_ms: f, clock_allowance_ms: a,
semantics: :same_key_same_arguments}` with nonnegative signed-bigint values and
`f+a <= w`. It relies on the provider honoring the same key and arguments in
that account/operation scope. The horizon is anchored at the earliest reserved
possibly-sent attempt, conservatively including a later no-send result.
Arm and rearm must fit the new send's lifetime and allowance inside the horizon.
The actual Adapter must obey that bound; this Piece does not time out or kill a
network request to manufacture such a guarantee. Native arithmetic is upstream.

Revision requires `:same_key_changed_arguments`, every earlier attempt certified
no-send, and no replay dependence. Permanent rejection disarms until a permitted
revision; pre-reservation schema failure creates no attempt. Revisions and sends
share the 256-entry bound. No revision clears possibly-sent/replay history.
`recovery_grace_ms` is none or nonnegative; checked addition to admission deadline
refuses overflow. Admission expiry blocks sends/rearms; finite recovery expiry
strands a dispatched intent. Neither expiry authorizes rearm.

## Recovery, history and trusted activation

Every recovery startup is potentially uncertain and read-only until host/operator
reconciliation re-establishes authoritative outcomes/grounds and grants activation.
There is no clean-release path in this subset; a later such Contract needs a new
Piece ID. The host preserves this obligation across restart. An in-memory halt
flag is not durable quarantine.

`Host.activate(context, request)` is synchronous, trusted and configured at startup.
The request has exactly `key`, fresh 16-byte `nonce`, recovered `revision` and
32-byte snapshot `digest`. It returns `{:active, generation, grant}` with the
same four fields plus matching `generation`, or `{:read_only, reason}`. Owner
checks every field, generation 1..4096, rereads the Store head and recovers the
snapshot again before admission/mutation. Digest is SHA-256 of version byte,
64-bit revision and canonical model encoding. A marker with no admitted intent
uses the explicit `{:empty_intent, 1, key}` model sentinel at revision zero.
A recovered dispatched reservation **never** schedules a local send.

`StoreHost` is a reference callback using a separate existing Store view with
`StoreHost.fold/0`, `limits/0`, and `stream(key)`. Its trusted
`authorize(request, observed_generation)` returns `:fresh` only for zero marker
and intent revisions, or `{:recovered, observed_generation}` only after host
verification. It appends a CAS activation marker before returning the grant.
A losing, rejected or unknown marker write grants nothing. Both Memory and real
SQL tests exercise this protocol. It is not a distributed ownership service:
the host authenticates reconciliation and controls/fences old owners and pending
writes. A paused old task can still perform its reserved send; provider replay
semantics or a final fencing certificate must cover that delayed send. Restart
alone is never proof of absence.

Every later dispatch passes durable `failed_definite` with exactly one ground:
Adapter no-send, provider no-effect, or narrowly poll-derived provider replay-safe.
Replay dependence is monotone, including after a later no-send. Authenticated old
completion can confirm through exclusively replay-safe intervening history with
matching operation, payload and binding. Completion contradicting no-send/no-effect
freezes rearm and records the first contradiction. Mixed history freezes
conservatively. One decisive settlement wins per attempt through serialized Store
CAS; duplicates do not replace it. Stranded is terminal for dispatch. Operators
verify provider state and record business resolution outside this Piece; bounded
late evidence can be retained without reopening. Only verified no-effect resolution
permits a separately authorized new logical request. A new key otherwise risks a
duplicate; no automatic operator override is supplied.

## Capacity, evidence and storage accounting

R-D deliberately replaced unbounded refused-result retention with bounded priority
retention. Every attempt reserves its decisive settlement, first contradictory
completion and first refused result. Routine pending/unavailable observations use
bounded counters. Other evidence can return `{:not_retained, reason}` when full;
critical observations that cannot commit halt ownership and are never reported
retained. Retained evidence is a bounded event/attempt/time plus SHA-256 summary of
the raw result, not the raw provider value. The consumer retains authenticated
source material if its audit/reconciliation obligations require it.

The production codec uses canonical deterministic **uncompressed ETF**, rejects
compressed input before decoding, uses safe decoding and checks a roundtrip.
It validates the model/history and replays the actual Cure policy for event folds.
Store limits at startup must be at least 128 KiB payload per record, batch size 1,
and 1 MiB per encoded checkpoint. Canonical append framing/digest is additional
to the payload limit. There are at most 4096 intent events, 1024 evidence entries
of at most 512 encoded bytes, and 256 combined attempts/revisions. Capacity is
preflighted before appending, including outstanding priority slots, witness-index
growth and a planned send. Optional capacity refusal preserves reconciliation;
reserved slots cannot be borrowed by routine writes.

The maximal-field production fixture measures model 706,230 bytes, full 4096-entry
checkpoint 870,232 bytes, conservative reservation envelope 870,758 bytes and
largest tested delta 66,376 bytes. These are actual codec measurements over named
bounded layouts, not a formal serialization-size proof. The strict per-checkpoint
hard limit is 1,048,576 bytes. At most one checkpoint per intent event and no
pruning gives an unconditional encoding cap of **4,294,967,296 bytes** across
4096 checkpoints; the measured maximal-model/witness-growth calculation gives
3,229,007,872 bytes. SQL/index/append/replica overhead is additional. StoreHost has
its own separate maximum 4096 activation records, each at most 512 payload bytes,
plus canonical framing; it takes no checkpoints. Neither total is a disk quota.
The host must retain intent/tombstone and host marker through provider-key and
business duplicate-request horizons; deletion/pruning is not replay authority.

## Grounding, operations and limits

The Cure file checks unconditional step-label laws for fresh/after origins,
dispatch actions, definite grounds, attempt counts, preserved replay/possibly-sent
history, revision and quarantine. Separate helper laws cover completion history
and guard structure. The actual `step` instantiates arbitrary-Boolean lemmas with
its Cure guards; runtime `decide` classifies per-attempt history before that step.
Together with the initial state they support the no-rearm reachable-trace argument:
Empty cannot be recreated, Fresh only originates at admission, After originates
only from Definite, and dispatch only follows Arm. Trace induction itself is not
separately mechanized. Law predicates are explicit case specifications, closely
related to runtime cases; mutation negatives and positive scenarios are additional
evidence, not stronger proof. Elixir validation/codec/CAS translation is tested.
No law proves authenticity, physical sends, storage durability or compiler soundness.

The policy test audits no axioms, holes, opaque, unresolved, unaudited or non-total
definitions and zero absurd; genuine production silent-return/groundless/history
mutations fail conversion, while always-stop and removed-horizon variants fail
named scenario gates. Runtime tests cover Memory and PostgreSQL boundaries,
read-only restart, host-grant mismatch, delayed sends, all result pairs,
contradiction orders, saturation and schema/revision controls. Source-copy tests
run original and renamed modules/record tags in a separate VM; the aggregate
consumer also runs the exported tests. Dependency closure includes core/envelope,
state/checkpoint and integration/sql (thus event-log/outbox); ELZ-006 failure
semantics are consumed without importing its retry Runner.

Pinned Cure 208248063d64e621782cd26dd30698ee42850a89, Elixir 1.20.4, OTP29.1.2,
ETF, crypto SHA-256, task/process semantics and PostgreSQL durability remain
upstream contracts. Adapter authentication, final certificates, physical retry
configuration, identity, trusted clocks, live-owner fencing and storage retention
are Needs. Hidden auth-refresh/redirect/transport retries must be disabled; when
wrapping Runner use one attempt and redispatch_forbidden. The physical-send
negative deliberately demonstrates two network sends with one recorded attempt.

Config is binding/startup plus validated revision, with no hot binding changes.
Control is the explicit synchronous owner commands under trusted host activation;
no business drain, cancellation reversal or durable command-receipt service.
Telemetry is inherited OTP task/process diagnostics; no custom payload telemetry
or exporter is installed. Consumer logger configuration must redact Adapter error
values and context; status deliberately omits them. This is not a hostile-BEAM-code
sandbox. Source copies use one application-owned namespace; redistributed libraries
must rename modules/MFAs and bare Cure record tags (`State`, `Config`, `Decision`
and dependency tags), as exercised by the copy test.
