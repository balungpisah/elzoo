# assembly/run-engine

`Elzoo.RunEngine` composes one checked pure pattern and one ordinary OTP
dispatcher over ready owners. It is not an agent loop, model/tool binding,
recipe loader, cluster owner or replacement for those owners. There is one
serialized engine per host identity and its DurableUnit. Old Run is unchanged;
this Assembly exclusively uses `RunApprovalRelease` on its allocated Run stream.

## Host construction

Use pinned Elixir 1.20.4/OTP 29.1.2 and the existing dependency closure. The
host creates ordinary Registry/DynamicSupervisor/DynamicUnits infrastructure,
a durable conforming Store, RunApprovalRelease with its exclusive Lease, an
allocated Run and current execution Attempt, AsyncWork/Task.Supervisor, fixed
EffectIntent startup bindings and any RunResource owners. No new runtime,
supervisor factory, Budget owner, Approval owner or storage service is supplied.
The host serializes Run cancellation/Attempt changes and engine admission;
status polling is not a concurrency fence.

`start_link(opts)` takes these fixed required facts (no defaults or hot changes):

- `identity`: UTF-8/no-NUL 1..160-byte Unit/stream identity; `run_id`: explicit
  allocated Run/accounting-period identity; `directory` and matching `store`.
- `run_owner`, trusted `tenant` and acting `principal`; `clock`: trusted
  zero-arity positive Unix-millisecond clock; `context`: current trusted
  authority/policy/approval/resource-grant supplier.
- `pattern: {module, function, initial_plain_state}`. The prompt deterministic
  Operator accepts the exact neutral PatternStep input and returns
  `{:Transition, next_state, :none | {:some, request}}`.
- `schemas`: map from `{schema_id, version}` to
  `%{compiled: compiled_token, port: checked_port_map, digest: digest32}` where
  `PayloadSchema.build/2` returned `{:ok, compiled_token}`.
  Only schema identities/digests, not compiled schemas, enter durable state.
- `gate: %{id: utf8_no_nul_1_to_128_bytes, version: positive_int32, call: arity2}`;
  `bindings`: fixed v1 action-kind map described below.
- `async_work`, `resources`: name-to-owner map (may be empty), `effect_intent`:
  binding-reference-to-ready-startup-options map (may be empty).
- `request_cap`: sealed integer 1..256; `budget`: ready Budget construction
  facts `%{id, incarnation, cap, unit}`; `budget_rule: :pause | :finish`;
  `run_deadline`: positive Unix milliseconds. Pause exhaustion requires a
  verified future `pause_deadline` before evaluating the driving input.
- `evidence: %{writer: existing_writer, stream: evidence_stream}` for canonical
  completed-outcome evidence readable by Run. Ordinary OTP `name` registration
  gives AsyncWork a stable receiver, normally a Registry name rather than PID.

The directory's Unit options use
`operator: {Elzoo.RunEngine, :step, %{version: 1, control: nil, slots: %{}, requests: %{}}}`,
`retention_count: 1024`, `max_record_bytes: 16777216`,
`max_checkpoint_bytes: 33554432`, matching Store fold/limits and a prompt offer
callback that only sends each Outbox.Item to the dispatcher and returns `:ok`.
Call `DurableUnit.fold/1` and `limits/1` to construct that Store. Never run gate,
DU calls or outbox acknowledgement inside the offer callback or transition.

Each binding has stable `id`/`version`, trusted `effect_class`, `result:
{schema_id, version}`, `facts.(action)` and `proposal.(action)`. Facts supply
`estimate`, `unit`, `deadline_ms`; Effects additionally supply the immutable
`intent` with five-field identity, canonical arguments, binding reference/digest
and deadline. Resources add `resource_name`; `resource_close` has nil intent
because Resource owns its original cleanup. Local work supplies `work.(action)`
returning a bounded non-Effect MFA. Person asks supply `person.(action)`.
Nested bindings supply `nested.(action)` with typed payload/schema, pure MFA,
initial state and distinct Budget identity/incarnation; their cap is exactly
the parent's reserved share and their authority is narrowed. Payload cannot
select arbitrary modules, tenants, provider accounts or grants.

The host owns checked provisioning, authentication, schema/binding compatibility,
full retained history, physical fencing and confirmation of outstanding writes
before replacement. Pure pattern/gate callbacks must terminate promptly and
avoid hostile allocation; byte bounds are not a sandbox. A receiver-only
restart keeps its AsyncWork controller; replacing that controller requires
tearing down the predecessor task subtree first.

## Input and controls

`input(engine, stable_id, neutral_input_without_at_ms, verified_context)` reads
the clock once. Context contains `run_id`, execution `attempt_id`, and where
applicable `occurrence: {request_ordinal, action_index}`, authenticated
`verified_person`, truthful actual cost/dispatch/loss or Resource correlation.
The same admitted ID retains its original data and time on retry. Changed bytes
are a conflict, not another invocation. Applied/duplicate means the DU result
committed, not merely that a message was sent. Other results are bounded error
or indeterminate classifications; never choose another ID to evade uncertainty.

`control(engine, id, command, context)` routes begin-Attempt, Approval evidence
or revocation through Run; pause/verified-person continue through lifecycle;
targeted cancellation closes local tracking before AsyncWork cancellation.
Run allocation/start coordination stays with the host. No reset, rearm, retry,
generic router or child-Run action exists. `status/1` exposes committed phase,
charge count, occurrence classifications/joins and reconciliation, not payloads,
credentials, raw consent or opaque work references.

The pure `step/2` is exported only for the directory's fixed Operator binding.
Its tagged version-1 plain records distinguish protocol, configuration, gate,
admission, authorization, continuation, Run/lifecycle and Resource-cursor facts.
DU wire remains `{1, {input_id, record_or_next_state}}`; no PID, reference,
function or compiled schema is durable.

## Recorded cycle and obligations

DU appends input before pure evaluation. Charge every actual pattern output
before request validation; `:none` charges nothing. Persist a <=1024-byte receipt
per output, including invalid/over-cap disposition and driving ID/digest/callable.
Root and nested callables share one sealed count. Invalid output cannot open
actions. The first excess closes generation in the same result, calls lifecycle
on the recorded input's checked content-free wake view and creates no request,
gate, join, action outcome or new pattern input for that excess. Exactly cap
still owes its entire ordinary cycle; without another output, exhaustion waits
for an explicit host wake. Continue/Attempt/restart cannot replenish the count.

A charge stop retains prior within-cap trackers, joins, identities, denial work
and actual already-started outcomes under both pause and finish. Their first
compatible settlement does not reopen generation or change the immutable Run
outcome. Ordinary stale Attempt, actual deadline, cancellation, explicit late,
restart loss and prior settlement rules still apply. A new room period needs
explicit host start of a distinct Run after terminal state and all obligations
settle. The per-Unit 256 lifetime-action limit is not reset by that period.

Within-cap requests run payload schema, Run-wide identity, gate, Budget,
Authorization, Approval in that order. Occurrence is `{request, index}` (0..63)
and keeps its originating execution Attempt. IDs from schema-refused actions
remain used. Reusing an ID settles only the new occurrence's refusal. Authentic
per-request PatternStep trackers classify before Aggregation's bounded joins.
Only first applied compatible settlement contributes; losses use `mark_lost`.
Monetary Budget state/generations persist; known zero releases, positive actual
settles once, unknown is not zero. Estimates are not provider-enforced charges.

Gate receives the checked action and trusted proposer/effect-class/tenant.
Malformed return/raise/throw/catchable exit denies with `gate_failure`, never
diagnostic text. One committed bounded verdict batch precedes any admission.
First installed verdict survives DU dedup eviction and restart. Denials produce
their own declared five-field refusal and no reservation/approval/intent.
Request outbox acknowledgement waits for committed refusals or durable allowed
continuations; ack is not business completion. Logical IDs use deterministic
ETF SHA-256: gate digests `{1, {host_identity, run_id}, request}` with `gate:`;
refusal digests `{1, {host_identity, run_id}, request, index, :gate_refusal}`
with `out:`. Answers, payloads and newly sampled time do not change these IDs.

ALLOW Effects use recorded descriptor bytes and existing EffectIntent activation.
ASK Effects use Run's approval/dispatch protocol; ASK Resources use only
`release_approved` followed by Resource-owned lifetime/FIFO dispatch. A released
reply is no cached send permit. Recovery never resends a reserved intent or
replaces its identity. Read-only owners expose reconciliation; lost raw sink
values become unknown, not a fabricated completion. The trusted Adapter/host
sink routes the full outcome through `input/4` and acknowledges only after its
applied reply; EffectIntent status is not a replayable raw outcome mailbox.

AsyncWork wraps exact `{:durable_unit_input, stable_id, record}` messages to the
registered dispatcher. Startup/replacement records ordinary local loss before
queued results; late completion cannot settle again. Resources retain their
own grants, FIFO, pause/deadline, usage and immutable cleanup. Resource cursor
advance follows destination input/Budget commit (or stable-ID dedup). All five
Run endings drive that cleanup; unknown/read-only is not closed. Completed Run
evidence is an actual Writer-appended canonical map correlating Run, operation,
Attempt and completed action, never DU's tuple or an invented sequence.

## Failure, size and audit limits

Definitive pre-input rejection closes intake and calls DynamicUnits.stop;
only confirmed `:ok` establishes termination/spec removal. Result rejection
leaves unresolved input and a stopped Unit. Corrected, explicit host startup
scans/drains before external intake; no incoming result, wake or outbox silently
reopens a halted engine. Repeated rejection stops again. Unknown append/timeout,
uncertain stop/start or ownership conflict require write confirmation and
fencing, never blind append/resampling. Transition defect/oversize needs repair,
not a skip or a storage-only retry. A live caller timeout keeps the same ID.

Payload/outcome JSON <=65536 bytes and depth <=32; ingress <=262144 bytes;
DU record/output <=16777216 bytes; complete active slot <=131072 bytes;
64 active/256 lifetime actions; control <=2097152 bytes (including 4096 bytes
reserved per active action and cap+1 receipt reservations); complete compact
request map <=4456448 bytes; slot map <=8 MiB; callable state <=65536 bytes.
Whole encoded candidates remain authoritative, including JSON-to-ETF expansion
and framing. Oversized outcomes become bounded failure/loss, never truncation,
payload logging or resend. Future settlement capacity cannot fund new requests.
Checkpoints cap complete model/IDs/witnesses/framing at 33554432 bytes; a refusal
is nonfatal and full retained-log recovery remains possible. FIFO dedup does
not bound journal/witness memory or promise perpetual checkpoints.

`examples/document_publication.exs` supplies the checked non-agent flow with
typed nested validation, person material, genuine publication consent and real
completion evidence. Its `audit/2` uses only `DurableLog.read/4`, canonical row
validation and paired committed DU results. It counts first installed verdicts,
first applied occurrence settlements and committed charge dispositions, ignores
marked staged tail/unresolved input and returns explicit errors for pruned,
damaged or incompatible history. Gate/refusal JSON schemas describe the JSON
view of the version-1 plain data; runtime additionally enforces UTF-8 byte bounds.

## Grounding and limits

`mix test pieces/assembly/run-engine/test` exercises the published 13 named
groups with disposable PostgreSQL, existing ready owners, ordinary OTP barriers
and counting fake providers. Actual temporary engine mutations bypassing the
committed gate boundary and first settlement are negative controls, never
shipped. These finite scenarios are not a universal proof, production monitor,
physical no-send guarantee or proof of arbitrary callbacks/providers. Reused
Cure laws retain their dependency-local scope; no new Cure proof is claimed.

The later checked-command composition may reuse the documented schema/identity/
gate/authority/approval order and existing pure APIs, not this Run-bound engine
unchanged. Engine Budget, no-reuse action IDs and post-work outcomes do not
provide Run-free command idempotency or atomic caller change/outcome persistence.
No future API or shared checking layer is added. Copies are application-owned;
retain one coordinated namespace/revision and the declared Needs.
