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
The engine and Run owner must receive the same fixed binding mapping. The
engine checks recorded Effect digests against its supplied startup bindings,
including ASK before Run dispatch; it does not attest Run's private mapping.
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
  `bindings`: map from action kind to a binding or to a schema map, described
  below.
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

A `bindings` entry for an action kind is either a binding, or a schema map from
`schema_id` (UTF-8 text of 1 to 200 bytes, no NUL) to a binding, with at least
one entry. A binding is a map with the atom key `:id` and no binary key. A start
with any other entry value returns `{:error, :invalid_options_or_recovery}` and
starts no Unit. The engine chooses the binding of an action by its kind and,
for a schema map, by the `schema_id` of the action alone, never by
`schema_version`, payload or callable: a binding entry serves every action of
its kind, and a schema map has no default entry, so an action whose `schema_id`
is not a key is refused with `missing_binding` (after `payload_schema` and
`invalid_identity`). Every read of the binding of an occurrence, including the
expected `result` of an outcome or answer and the result that a nested finish
must match, uses the binding chosen for that action. The restart fingerprint
holds `{id, version}` of a binding entry and, for a schema map, the map from
each `schema_id` to `{id, version}`, so a changed schema map is an incompatible
restart. The test helper's `fixture/1` takes `effect_bindings`, a map from
binding reference to `{binding_module, adapter_context}` merged into the default
`"effect"` entry, and gives the same map to the engine and to the Run owner.

Each binding has stable `id`/`version`, trusted `effect_class`, `result:
{schema_id, version}`, `facts.(action)` and `proposal.(action)`. Facts supply
`estimate`, `unit`, `deadline_ms`; Effects additionally supply the immutable
`intent` with five-field identity, canonical arguments, binding reference/digest
and deadline. Resources add `resource_name`; `resource_close` has nil intent
because Resource owns its original cleanup. Local work supplies `work.(action)`
returning a bounded non-Effect MFA. Person asks supply `person.(action)`.
Nested bindings supply `nested.(action)` with typed payload/schema, pure MFA,
initial state and distinct Budget identity/incarnation; their cap is exactly
the parent's reserved share and their authority is narrowed. A nested binding
may give `state_bytes`, the state bound of the child: an integer from 1 to
65,536. With no `state_bytes` the bound is 65,536. The bound of the root is
65,536. A nested action whose `state_bytes` is outside 1 to 65,536, or whose
initial state is larger than its bound, is refused with `nested_input`. Payload cannot
select arbitrary modules, tenants, provider accounts or grants.

The host owns checked provisioning, authentication, schema/binding compatibility,
full retained history, physical fencing and confirmation of outstanding writes
before replacement. Pure pattern/gate callbacks must terminate promptly and
avoid hostile allocation; byte bounds are not a sandbox. A receiver-only
restart keeps its AsyncWork controller; replacing that controller requires
tearing down the predecessor task subtree first.

An Effect intent process is started unlinked and has no supervisor, so it
outlives the engine and can still append its result or `Lost` to its store
after the engine is gone. The engine has no `terminate/2` that would stop
its intents, and stopping them there would not run on a kill anyway. A new
start begins with no intent process and can start a second owner for the
same identity while the old one is still alive. The host fences the old
engine and its intent owners before a new start, as it already must for the
engine itself.

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

A begin-Attempt or Approval-evidence control whose Run command is applied runs
the release and then drains the engine, as `input/4` and pause/continue do, and
replies only after that drain. So an approved root `finish` with a completed
source ends the Run before the reply, and an approved `finish` of a nested child
gives its parent the outcome before the reply. When the drain ends in a halt, the
control replies with that error, as `input/4` does. A control whose Run command is
refused or unchanged replies `{:error, {:run_control, _}}` and does not drain. A
pause or continue control whose ID is the ID of a recorded input of another kind
gives `{:error, :input_id_conflict}`, commits nothing, and the engine goes on.

`input/4`, `control/4` and `status/1` each wait for the engine process for at most
60,000 ms (one fixed limit; the functions take no limit operand or option).
`status/1` is a call to the same process, so it replies only after an input that
the engine is working on. An input at the bounds of this Piece (64 active, 256
lifetime actions) took about 4.2 to 5.0 s alone and beside the Piece suite in 10
runs each on a shared worker host, most of it the journal write path of the
owners below this Piece, so the 5,000 ms default of `GenServer.call/2` would be
too near for any caller. A caller that needs a shorter wait runs the call in a
process of its own and gives up the wait there (`Task.async/1`, then
`Task.yield/2` and `Task.shutdown/2`). When a call ends by the limit, or its
caller stops waiting, the exit says nothing about whether the input was applied,
and the engine goes on with it. The existing rule above is the only guidance:
send the same ID again, never another; `{:ok, :applied}` or `{:ok, :duplicate}`
means the result committed, and changed bytes are `{:error, :input_id_conflict}`.

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
A settled action has a final unknown cost when the Budget of its callable
still holds its entry (open, or expired at its deadline) with no settle or
release, the action has no actual, and no later record can give it one. These
are a model call, tool call, person ask, local work or finish settled with no
actual (no later outcome settles a settled action), and a nested callable
settled with no actual whose child is closed, has every action settled and has
a final unknown cost. A Resource action (its cursor can still settle the cost)
and a nested callable whose child can still give a known total are not final:
the engine waits for them as before. A local work closed by a cancel or an
Attempt change keeps its Budget entry and is final unknown. Child finish does
not settle the parent's share while a child cost can still come. When the child
is closed, every child action is settled and each cost is known or final
unknown: if all are known, `actual` is the committed child Budget amount, as
before (and a parent settled earlier with no actual gets it later); if one or
more is final unknown, the parent gets its outcome by the same finish rules and
reasons with no actual, nothing of its share is released or committed, and no
later actual follows for it. The Budget then keeps the share reserved in the
parent Budget until the deadline of the parent action; from that deadline on
the Budget no longer counts it in `reserved` (each Budget step first sweeps
open entries whose expiry has passed to expired), and nothing is ever committed
for it. The same holds for each entry of the child Budget. Unknown is not zero
at every level: nothing releases it as zero. A parent that can no longer take
an outcome is not handed one: a parent of a terminal Run is handed an outcome
only when the request-cap stop retains it and its deadline has not passed (the
engine clock is read, as the fold reads the time of the record); after its deadline
it is not selected, and the first protocol input of the current Attempt at or after
that deadline closes it (the end of the Run, below). A parent of an older Attempt is
settled at the change of Attempt (below), not handed an outcome. No record is
written for it, and `drain` goes on. A round of `drain` that changes no durable
state ends the drain. This also covers a child whose
costs are all known; before, the engine could repeat that hand-over without
end. Only a nested callable's first admitted `finish` is kept in
its closing continuation record and given to the parent when the child settles:
a finish whose `{schema_id, schema_version}` equals the `result` of the parent's
`nested_callable` binding completes the parent action with that schema and the
exact payload; any other schema fails it with the refusal schema and reason
`nested_result_invalid`, without the child payload; a child that settles with no
admitted finish keeps `completed` with reason `nested_completed`. The kept
finish is durable and replays after
restart. The payload is recipe content within the existing payload bounds: the
engine neither validates nor interprets it, and `status/1` does not expose it.
The kept finish leaves the durable control state once the parent action settles.
A nested callable's first finish is admitted only when control, with that finish
placed in it, still satisfies the bound (the control bytes, the receipt and active
reserves, at most 2,097,152): the bytes of the finish are held in the reserve from
its admission until the continuation keeps it, so no other admission between the
two can take that room. With no room, the finish is refused with the reason
`record_size`: the child pattern gets an ordinary refusal, the parent action is not
completed by it, and the child callable stays open. A root finish and every other
action kind are admitted as before.

Each callable has a state bound. A pattern state over the bound of its callable is
not stored (`invalid_pattern_state`; for an output over the request cap the answer
stays `over_cap`). While a callable is open, control reserves its whole state bound,
so an open callable can store any state within its bound at any later input: no
input fails for the size of a pattern state. A nested start is kept only when the
state after it satisfies the bound, with the state bound of the child, its Budget and
its authority counted. With no room, the parent action is refused with `record_size`,
actual 0, nothing dispatched; no child and no Budget exist; the evaluation of the
child is dropped and charges nothing; the reservation of the parent is released; the
engine goes on. The state of a callable leaves control when the callable closes: when
its finish is kept, when the slot of its nested parent settles (the child callable
and every callable below it close in the same fold step), at a change of Attempt,
and when a terminal Run closes it. Its room comes back then. The Budget, the join
and the receipts of a closed child stay.

An input that settles no slot (a `wake`, a Resource event, and each other kind that
is neither an action outcome nor a person answer) is given to the root pattern only
when control, with the invocation entry of that input placed in it, still satisfies
the bound. With no room, what the expiry of waits, the protocol step and the close
of a terminal Run did stays, while no invocation entry, no pattern call, no charge,
no receipt and no request is kept. Its classification in `status/1` is `record_size`,
`input/4` answers as for every committed input, and the engine goes on. An input
that settles a slot is given to its pattern as before. An invocation entry stays in
control until a new Run is configured on the unit, so room comes back only when
other state leaves control. `cancel` needs no entry.

Paused accepted results retain their pattern input until
continue, without dispatch while paused; monetary exhaustion still takes
lifecycle precedence below the request-count cap.

At a change of Attempt the engine settles, in the same fold step and at the
time of the view record, every slot of the older Attempt that is not settled,
in the root and in each nested child, deepest callable first; every nested child
callable is closed. After the change no slot of an older Attempt is open: the
wake of the new Attempt reaches the pattern, all 64 active places are free, and
after a terminal Run a new Run configures on the unit. A slot that nothing can
have left the engine for is `refused` with reason `attempt_closed` and actual 0,
and its reservation is released. These are the phases checking, allowed,
authorizing, refusing, approval without a request key, approval with a request
key for a kind other than model/tool call, ready for every kind except the
Resource kinds, and a child finish that is running. A slot that may have been
sent is settled with outcome `unknown`, reason `attempt_closed` and no actual,
and its Budget entry stays held: unknown is not zero. Its cost is final unknown
by the rule above, except a Resource action, whose cursor still settles its
Budget. These are a model call or tool call in approval with a request key,
running or in reconcile; a Resource action ready, running or in reconcile; an
`ask_person` that waits; and a nested callable whose child was started (running,
or refusing after the over-cap deny of its child). The join records outcome
`unknown` with dispatch `unknown` (`dispatched` for a nested parent), never
`not_dispatched`. Running local work keeps its rule: `failed`, `local_closed`,
no Budget step. A nested parent settled at the change gets the committed child
amount as its actual when every child cost is known, else no actual; a child
cost that can still come (a Resource cursor) gives the parent its actual later
by `:nested_actual`. The finish that the child kept is given to no pattern and
leaves the control state. A settled slot keeps its reservation, Resource name and
intent digest, so a later cursor finds it. First settlement wins: a later outcome
of the old or the new Attempt and an expiry change nothing, and a reserved
intent is never sent again, also after a restart.

At the end of the Run the step of the terminal view, at the time of the view and
after the close of a change of Attempt in the same view, settles every open slot of
the current Attempt that the request-cap stop does not retain; in every other ending
that is every open slot. The request-cap stop retains a slot while the time of the
record is before its deadline, or while it has no deadline yet (the drain then refuses
it as before). Each later protocol input of the current Run and Attempt that is not a
duplicate settles, at its own time and after its own effect is folded, every slot that
is no longer retained. The settlement is the one of the change of Attempt, by the same
closer and the same phases, with the reason `run_closed`: refused with actual 0 and
the reservation released when nothing can have been sent; `unknown` with no actual and
the reservation held when something may have been sent; running local work `failed`
`local_closed` with no Budget step; deepest callable first; every nested child
callable is closed. A parent past its deadline whose child still holds a retained slot
is settled; the child slot keeps its own retention and settles by its own outcome or
at its own deadline; the parent gets the committed child amount once, when every child
cost is known (at the close, or later by `:nested_actual`). After this close in an
ending that is not a request-cap stop no slot is open, the drain writes no refusal and
asks no gate, and a new Run configures on the unit; in a request-cap stop the drain
works on the retained slots as before. The engine has no timer: a host that wants to
configure a new Run after a request-cap stop sends one input (a wake) at or after the
last deadline. First settlement wins as above; a Resource cursor after the close still
settles the Budget of its action.

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
ASK Effects use Run's approval/dispatch protocol; non-Effect ASK actions use
`release_approved` followed by their existing kind dispatch, with Resources
retaining Resource-owned lifetime/FIFO dispatch. A released
reply is no cached send permit. Recovery never resends a reserved intent or
replaces its identity. Read-only owners expose reconciliation; lost raw sink
values become unknown, not a fabricated completion. The trusted Adapter/host
sink routes the full outcome through `input/4` and acknowledges only after its
applied reply; EffectIntent status is not a replayable raw outcome mailbox.

A reply of the Run to an approval request that is not `{:ok, _, key}` is followed by
one read of the status view of the Run, and the engine decides in this order. (1) The
view lists a request of this Run for the action of the slot, with the name and version
of the requirement of its decision, that is not superseded: the engine records that
key as after `ok` and goes on as after `ok`. This covers a `duplicate` after a death
between the commit of the Run and the continuation of the engine, and a reply lost
after the Run wrote the request. (2) The reply was `{:refused, :conflict}`,
`{:error, :unavailable}` or `{:indeterminate, _}` and the view lists no such request:
the engine writes nothing, the slot stays in approval with no key and its reservation
held, and the next drain asks again; the same drain does not ask again and the engine
does not halt. (3) Every other reply settles the slot `refused` with reason
`approval_refused` and actual 0, and releases its reservation. The Run derives the
request from the decision, so a second ask makes no second request.

AsyncWork wraps exact `{:durable_unit_input, stable_id, record}` messages to the
registered dispatcher. Startup/replacement records ordinary local loss before
queued results; late completion cannot settle again. Resources retain their
own grants, FIFO, pause/deadline, usage and immutable cleanup. A Resource that
refuses a dispatch as not open, paused, closing or closed leaves the action
with the Resource; every other reply of the dispatch halts the engine with
`resource_dispatch_unknown`. Resource cursor advance follows destination
input/Budget commit (or stable-ID dedup). All five Run endings drive that
cleanup; unknown/read-only is not closed. Completed Run evidence is an actual
Writer-appended canonical map correlating Run, operation, Attempt and completed
action, never DU's tuple or an invented sequence.

At recovery a running or reconcile `resource_open` or `resource_use` slot with
no request key keeps the decision of the first dispatch and never moves to
ready: a durable running slot proves the Resource accepted the action command,
which is never sent again. The intent owner alone decides — an intent with
attempts stays untouched and open for its cursor; an untried active intent
gets only the `{:dispatch, ...}` under its deterministic ID, with the same
harmless refusals; an inactive one moves to reconcile with `read_only`. The
slot keeps a phase the drain does not select, so the outcome comes through the
Resource cursor as for a slot that was never restarted.

## Failure, size and audit limits

Definitive pre-input rejection closes intake and calls DynamicUnits.stop;
only confirmed `:ok` establishes termination/spec removal. Result rejection
leaves unresolved input and a stopped Unit. Corrected, explicit host startup
scans/drains before external intake; no incoming result, wake or outbox silently
reopens a halted engine. Repeated rejection stops again. A state read never
halts the engine for a dead Unit: when the Unit is gone — already stopped, or
stopped between the liveness check and the read — the engine answers the last
committed durable state, the same recovery read a restarted Unit replays, and
the next `current/1` performs the replacement recovery; only an uncertain
write ends in the `delivery_unknown`, `ownership_unknown` or storage halts.
Unknown append/timeout,
uncertain stop/start or ownership conflict require write confirmation and
fencing, never blind append/resampling. Transition defect/oversize needs repair,
not a skip or a storage-only retry. A live caller timeout keeps the same ID.
The 60,000 ms call limit is fixed and not a bound on the work: a call that ends
by it, or a caller that stops waiting earlier, leaves the engine working on the
input. This Piece states no other way to learn what happened to the first call
than sending the same ID again, no bound on how long the engine then continues,
and no time guarantee: the measured 4.2 to 5.0 s of an input at the bounds is one
observation on one shared worker host, not a bound.

Payload/outcome JSON <=65536 bytes and depth <=32; ingress <=262144 bytes;
DU record/output <=16777216 bytes; complete active slot <=131072 bytes;
64 active/256 lifetime actions; control <=2097152 bytes (including 4096 bytes
reserved per active action and cap+1 receipt reservations); complete compact
request map <=4456448 bytes; slot map <=8 MiB; callable state within its state bound (<=65536 bytes), reserved in control while the callable is open;
an input that settles no slot needs room in control for its invocation entry (its ID
and 42 bytes: 43 bytes for a 1-byte ID and 202 bytes for a 160-byte ID), else it is
classified `record_size` and not given to a pattern.
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
groups and the eight nested-result groups `nested_result_reaches_parent`,
`nested_result_wrong_schema`, `nested_without_finish`, `nested_result_bounds`,
`nested_result_survives_restart`, `first_finish_only`, `two_levels` and
`payload_not_exposed`, and the group `call_waits_past_the_default` (its test
`every_call_waits`: an input that sleeps 5,500 ms once in the gate returns
`{:ok, :applied}`, and `status/1` and `control/4` sent during it each reply after
it, more than 5,000 ms after they were sent), and the ten nested-cost groups
`nested_lost_effect_reaches_parent` (a lost Effect in a child: the parent gets
the finish with no actual and the root finishes), `unknown_is_not_zero` (both
Budgets keep their entries, committed amounts do not move, a parent with no room
refuses the next action), `known_costs_are_exact` (journal rows with no loss and
with a refused parent equal rows recorded on the unrepaired engine),
`no_second_outcome` (more inputs and a second restart write no second outcome),
`loss_two_levels_down` (a lost cost two levels down reaches both parents),
`still_waits_for_a_cost_that_can_come` (a Resource action or an open child slot
holds the parent), `local_work_closed_without_a_budget_step` (a closed running
local work is final unknown, and a late or expired parent gets no record and
`drain` goes on), `finish_rules_hold` (`nested_result_invalid` and
`nested_completed` with no actual), `expired_reservation_is_still_unknown` (an
entry swept to expired still counts as unknown at two clock values) and
`no_loop_for_a_parent_that_cannot_settle` (a parent of a terminal Run is not
handed an outcome and the call returns; the end of the Run closes it `unknown` with
actual 0 for a child of known cost 0; a parent of an older Attempt is settled at the
change), the five groups of the close of a child callable when its nested parent
settles: `expired_parent_closes_its_child` (a parent past its deadline settles
`expired` and its child callable and every callable below it close in the same
step; the child's open slot stays open and its pattern gets no more inputs),
`child_cost_still_reaches_the_parent` (the child's open slot then settles by its
own outcome and the parent gets its actual once as `nested_actual`, or none when a
cost is final unknown), `two_levels_close` (a grandchild callable closes with its
parent and the top parent in the same step, deepest first),
`over_cap_parent_closes_its_child` (a running parent refused `out_of_budget` while
its child is open closes the child callable with it) and `room_comes_back` (the
state bounds of the closed callables leave control, so a later nested start that
needed the room is admitted and a restart replays an equal state), the five groups
of the retained parent past its deadline in a Run
that the request-cap stop made terminal,
`start_returns_with_an_expired_retained_parent` (a restart after the deadline
returns inside a bounded wait; the parent is closed `unknown` with no actual and the
lost tool call is `unknown` with no actual),
`input_returns_with_an_expired_retained_parent` (the real result of the child tool
call after the deadline returns `{:ok, :applied}` inside a bounded wait; the parent is
closed `unknown` with the child amount 5 as its actual, in the same step), `nothing_more_is_written`
(after each of those two states one more input and one more restart leave the journal
records of the parent as they were, and the view equal apart from `classification`,
which names the last input; the parent stays `unknown`), `retained_parent_before_its_deadline_settles` (the same Run with the
clock before the deadline: the parent settles `completed` with the committed child
amount) and `other_work_goes_on` (two parents in one request, the first past its
deadline: the second settles `completed` with its actual and the first is closed
`unknown` with its actual 3), and the eight change-of-Attempt groups
`sent_slot_becomes_unknown` (a dispatched tool call, a slot in reconcile, a
waiting person ask and an approved slot with a request key become `unknown` with
no actual, the Budget keeps its reservation and the committed amount does not
move, no second dispatch follows after a restart, and a late result with an
actual changes nothing), `unsent_slot_is_released` (each phase in which nothing
was sent is `refused` with actual 0 and a released reservation, with no dispatch
after the change or a restart), `nested_parent_and_child_close` (every slot of
the child and the parent settle, a kept finish is given to no pattern and leaves
the control state, the parent actual is exact when every child cost is known and
absent when one is not), `new_attempt_works` (a wake of the new Attempt gets a new
request that runs to its outcome, the 64 places are free, and a second change
leaves the earlier settlements as they were), `run_ends_and_unit_configures` (the
Run ends and a new Run with another run id configures on the same unit),
`resource_cost_still_arrives` (a Resource cursor after the change settles the
Budget of its action, also inside a nested child, and the parent actual follows),
`replay_is_equal` (a restart after the change gives an equal view, equal Budgets
and an equal count of journal records, and writes nothing more) and
`first_settlement_wins` (an outcome with the old Attempt, one with the new
Attempt and an expiry leave a closed slot as settled), the six groups of a settled
parent whose child asks over the request cap: `settled_parent_stays_settled` (the
parent settled `expired` stays equal term for term, no outcome record is written
for it, the Budgets do not move and the Run stops), `unit_configures_after_the_stop`
(the stop ends the Run with no open slot, and a new Run with another run id
configures on the same unit and runs one action), `running_parent_is_still_refused`
(the two existing tests `charge-stopped child propagates later actual without
changing its settled parent outcome` and `nested denial chain uses shared charge and
settles its previously admitted parent` pass unchanged: a running parent is refused
`out_of_budget`), `later_actual_reaches_the_settled_parent` (a child cost that is
still open at the stop reaches the parent once as `nested_actual`, its outcome
`expired` is kept and the root Budget commits the amount),
`replay_is_equal (settled parent over the cap)` (two restarts after the stop give an
equal view, equal slots, equal Budgets and an equal count of journal records, and
start no Effect) and `recorded_defect_is_closed_at_a_change` (a state that already
holds a refusing parent, as the unrepaired engine recorded it, is settled again by
`step/2` at a change of Attempt with its first outcome, actual and reservation, and
the Budgets stay equal), the ten groups of the end of the Run:
`waiting_parent_closes_with_the_run` (a root finish while a nested parent runs: the
parent and every slot of its child are settled, the parent has the exact child amount
when every child cost is known and no actual with its share held when one is not, the
child callable and the join are closed, and no outcome record is written for the parent
or the unknown child), `sent_slot_becomes_unknown_at_the_end` (a dispatched tool call, a
slot in reconcile and a waiting person ask become `unknown` with no actual and the
reservation held, no outcome record is written, no Effect starts after a restart, and a
late result or answer changes nothing), `unsent_slot_is_released_at_the_end` (a slot in
checking, allowed, authorizing, refusing, approval with no request key, and a ready tool
or model slot is `refused` with actual 0 and its reservation released, no outcome record
is written, the gate of the new engine is not asked for the slot in checking, and nothing
changes after a restart), `retained_slot_stays_until_its_deadline` (in a request-cap stop
a local action and a nested parent with its tool call stay `running` at a wake before
their deadlines, and their results settle them `completed`),
`retained_slot_closes_after_its_deadline` (the first input at or after the deadline closes
a running local action `failed`, a dispatched tool call `unknown` with no actual and its
reservation held, and a retained parent with its tool call `unknown`, with no outcome
record, and a late result changes nothing), `retained_slot_closes_after_its_deadline (one
step)` (the result of a retained child after the deadline of its parent gives the parent
the exact amount in the same step, with no `nested_actual` record),
`child_keeps_its_own_deadline` (a parent past its deadline closes alone, the child result
later gives it its actual once, and after one more wake and one restart the journal holds
one `nested_actual` record for it), `unit_configures_after_the_end` (after a root finish
with a running parent, and after a request-cap stop whose retained slots closed at their
deadlines, a new Run with another run id configures on the unit and runs one action),
`resource_cost_arrives_after_run_close` (a root Resource action that is open at the end
becomes `unknown`; the cursor settles its Budget and its actual, also after a restart) and
`replay_is_equal (run close)` (for a root finish with a running parent, a sent tool action
and a request-cap stop closed at its deadlines, two restarts give an equal view apart from
`classification`, equal slots, equal Budgets and an equal count of journal records, and
start no Effect), and the four groups of the
room of a child finish: `finish_without_room_is_refused` (28 parents are open
together, each with a child that holds an open tool cost and finishes with a payload of
65,536 JSON bytes: 25 of the finishes are kept and the other 3 are refused with
`record_size`, each child gets the refusal, its parent stays open and its callable
stays open, the engine answers the next input, the bound is recomputed from the unit
state and holds after each input, and an input at the deadline of the parents settles
each open parent as `expired`), `room_comes_back` (after one parent settles, a finish
of the size that was refused is admitted and kept whole), `smaller_finish_fits`
(after the refusal a small finish of the same child is admitted and reaches the parent
once the child cost is known) and `replay_is_equal (finish without room)` (a restart
gives an equal view and an equal count of journal records, and the refused finish is
not asked again), the nine groups of the state bound:
`nested_start_without_room_is_refused` (32 nested starts of the default bound in one
request of the root, children that wait, request cap 100: 27 are kept with their exact
state and the bound 65,536, the 5 after them are refused `record_size` with actual 0
and `not_dispatched`, the root gets each refusal, no callable or Budget exists for
them, the root Budget holds 10 for each kept parent and commits nothing, and the bound
holds before and after the next input), `declared_bound_decides` (with no `state_bytes`
and with 65,536 declared the same 27 starts are kept and the first refusal is at the
same place; with 1,024 declared all 32 are kept; beside refused children of 65,536 a
child with 1,024 is kept and runs its action), `root_state_can_grow` (with less than
131,072 bytes of room the root stores a state of exactly 65,536 bytes and the step
passes), `state_over_its_bound_is_not_stored` (a child with `state_bytes` 1,024 that
returns 1,025 bytes keeps its old state and the step is classified
`invalid_pattern_state`; a state of exactly 1,024 bytes is stored), `bound_is_validated`
(`state_bytes` 0, 65,537, a string, and an initial state one byte over its bound are
each refused `nested_input` with no child, no Budget and no `:nested` record; an
initial state of exactly the bound is kept), `refusal_leaves_no_trace_of_the_child`
(the states just before and just after the `:nested` record of a refused start have
equal counts, receipts, invocations, callables, requests and other slots, the parent
Budget changes only by the release of its 10, and no later input reaches the dropped
child), `state_grows_after_start` (31 children of the default bound that each ask a
tool call: 26 are kept, 25 hold their call and grow to exactly 65,536 bytes on its
outcome, in ascending and in descending order; the bound holds after every input, no
step fails and the unit answers the next input), `room_comes_back_at_close` (a child
that grew to its bound finishes: its node is closed with no state, its room comes
back, and a nested start of the bound that was refused, asked by another open child,
is kept; after a change of Attempt and after the end of the Run no node but the root
holds a state) and `replay_is_equal (state bound)` (after the refusals a change of
Attempt and two restarts give an equal view, slots, Budgets and count of journal
records; after the growth the unit started alone on its journal gives an equal state
and record count; after the room came back a second restart changes nothing; the
refused starts are not asked again), and the four groups of the control path:
`approved_root_finish_ends_the_run` (an approved root `finish` with a completed source:
the consent control replies `{:ok, :applied}`, and with no further input the view is
`:terminal` with outcome `:completed` and no pending stop, and the Run has the outcome
`completed`), `approved_child_finish_reaches_its_parent` (an approved `finish` of a
nested child: after the reply the parent slot is settled `completed` with the payload
of the finish and its actual), `begin_attempt_leaves_nothing_to_drain` (the three
tests of `replay_is_equal` pass unchanged with the drain in place: a restart after the
change of Attempt gives an equal view, slots, Budgets and count of journal records) and
`control_id_of_a_protocol_input_is_a_conflict` (a pause and then a continue control
with the ID of an applied input each give `{:error, :input_id_conflict}`; the engine
is the same process, the count of journal records and the phase do not move and the
next input is applied; a pause control sent twice with equal bytes gives
`{:ok, :applied}` twice), and the five groups of the replies to an approval request:
`request_survives_a_death` (the engine dies after the Run wrote the request and before
its continuation: after the restart the slot is in approval with the key that the Run
lists, no outcome record exists, the Run holds one request, and consent dispatches the
action once and its result settles it `completed`), `lost_reply_is_recovered` (the Run
wrote the request and the reply was replaced by `{:error, :unavailable}`: the slot
holds the key in the same input), `uncertain_reply_is_no_refusal` (a reply
`{:refused, :conflict}` or `{:error, :unavailable}` that the Run never received: the
input is applied, the slot is in approval with no key, no outcome record exists and
the reservation is held; the next input asks again and the slot holds the key),
`definite_refusal_still_refuses` (a reply `{:refused, :intent_mismatch}` settles the
slot `refused` with reason `approval_refused`, actual 0, and releases its reservation)
and `replay_is_equal (approval request)` (after a death the first restart adds only
the Run view record and the result row that a restart of an uninterrupted Run adds,
with an equal view, and the next restart adds nothing; a restart after the second ask
gives an equal view and an equal count of journal records; the Run still holds one
request), and the eight groups of the room for invocation entries:
`wake_without_room_is_not_given` (a `wake` with a 160-byte ID at 64 bytes of
headroom, less than its 202-byte entry: `step/2` returns `:none` with classification
`record_size`, keeps `control.invocations`, callables, request count, receipts,
trackers, slots and requests equal, and the bound holds), `the_switch_is_one_place`
(sweeping headroom from 64 to 266 bytes one byte at a time: below S = 207 every step
is refused as above, from S on the pattern is called, the entry is added, and the
bound holds), `each_kind_without_a_slot` (the same refusal at 64 bytes and single
switch S for a granted `resource_event` from a Run that opened a Resource, S = 201,
and for `start` and `message`, S = 207), `settling_input_is_given_as_today` (an
active slot at 64 bytes of headroom takes its `action_outcome`, settles, calls the
pattern, keeps the entry, and the 4,096-byte slot reserve covers it),
`request_after_the_check` (at S a `wake` whose pattern answers with a request
classifies `record_size` in `admit_request/5`, and with room admits it, with the
bound holding in both), `engine_goes_on` (after a refusal, a second `wake` refuses
identically in the fields that group 1 lists, a `cancel` updates the lifecycle, and
the first `wake` with padding removed reaches the pattern rather than classifying
`duplicate`), `decision_is_pure` (for groups 1, 2 and 4 two calls of `step/2` on
equal state and record return equal results) and `unit_stays_alive` (a durable unit
started on its journal at 64 bytes of headroom applies a 160-byte `wake` with
`{:ok, :applied}`, classification `record_size`, no pattern call, stays alive and
restarts with an equal state); every earlier test of the Piece passes unchanged, except the tests whose
assertion that a parent of a terminal Run stays `running` is now that it is closed `unknown`
(`no_loop_for_a_parent_that_cannot_settle`, one test; `start_returns_with_an_expired_retained_parent`;
`input_returns_with_an_expired_retained_parent`; `nothing_more_is_written`, both tests; and
`other_work_goes_on`), the test helper `resource_cursor`, which takes the Attempt as an
optional argument, the six tests of the room of a child finish, whose children declare
`state_bytes` 1,024 in the binding override of their Run (one line; every assertion
unchanged), and the test helper `control_headroom/1`, which counts the new reserve. The tests run
with disposable PostgreSQL, existing ready owners,
ordinary OTP barriers and counting fake providers. Actual temporary engine
mutations bypassing the committed gate boundary and first settlement, giving a
finished child the old `nested_completed` outcome and skipping the result
schema comparison are negative controls, never shipped; so are the old
selector that skips a closed child with a lost cost (`nested_lost_effect_reaches_parent`
fails by the stall), an unknown cost handed to the parent as actual 0
(`unknown_is_not_zero` fails), a count of open entries only
(`expired_reservation_is_still_unknown` fails) and the selector without the
Attempt and terminal condition (`no_loop_for_a_parent_that_cannot_settle`
fails: the call does not return); so are the drain without the unchanged-state
end and the selector without the deadline term, both reverted
(`start_returns_with_an_expired_retained_parent` and
`input_returns_with_an_expired_retained_parent` fail: the start and the call do not
return in their bounded wait), and the drain with the unchanged-state end but the
selector without the deadline term (`other_work_goes_on` fails: the second parent
is not settled); so is the default
5,000 ms limit of the three calls (`call_waits_past_the_default` ends with the
time-out exit). For the change of Attempt, the release of the reservation of a
sent slot as zero (`sent_slot_becomes_unknown` fails) and the old
`close_local` alone (`run_ends_and_unit_configures` fails: the start of the new
Run is refused as `:incompatible_recovery`) are negative controls; so are a
refused slot that keeps its reservation (`unsent_slot_is_released` fails),
callables closed shallowest first (`nested_parent_and_child_close` fails: the
parent has no actual) and a hard match in the fallback of the closer
(`recorded_defect_is_closed_at_a_change` fails in `step/2`). For the over-cap request
of a child, the deny with no look at the phase of the parent is a negative control
(`settled_parent_stays_settled` fails: the slot is refusing;
`unit_configures_after_the_stop` fails: the slot of the stopped Run stays refusing and
the start of a new Run is refused as `:incompatible_recovery`;
`later_actual_reaches_the_settled_parent` and `recorded_defect_is_closed_at_a_change`
fail on the same slot). For the end of the Run, `close_run` that returns the state unchanged is a negative
control (`unit_configures_after_the_end` fails: the start of the new Run is refused as
`:incompatible_recovery` in the first test and the slots are not settled in the second;
each of the six tests of `unsent_slot_is_released_at_the_end` fails because the drain
writes an outcome record for the slot, with the reason `run_terminal`, `run_or_authority`
or `restricted`); so are the release as zero of a sent slot when the reason is
`run_closed` (`sent_slot_becomes_unknown_at_the_end` fails in its three tests: the actual
is 0 and not absent), a close that also takes the slot that the request-cap stop retains
before its deadline (`retained_slot_stays_until_its_deadline` fails in both tests: the
slot is already settled), a selector that never closes a retained slot
(`retained_slot_closes_after_its_deadline` and `child_keeps_its_own_deadline` fail: the
slot is still `running`) and the close before the effect of the input instead of after
it (`retained_slot_closes_after_its_deadline (one step)` fails: a `nested_actual` record
is written; no other group notices the order). For the room of a
child finish, the admission without the room check (`finish_without_room_is_refused`
fails: the step of the kept finish raises, the durable unit stops, and the wait for the
28 finishes ends in the test time-out) and the reserve without the bytes of the
pending finishes (`finish_without_room_is_refused` fails in the same way) are negative controls.
For the state bound, the reserve without its term for open callables
(`state_grows_after_start` fails: the bound recomputed from the unit state is broken
after the first growth; with that check only printed, the step of a later growth fails,
the unit stops with `durable_unit_transition_failed` and a new start of the unit
fails), the `:nested` fold without its check (`nested_start_without_room_is_refused`
fails: the reply is `{:error, :durable_unit_transition_failed}` and a new start of the
unit fails), the close that keeps the state (`room_comes_back_at_close` fails: the
closed node holds its state, and the later start is refused) and the checks of
`invoke/3` at 65,536 in place of the bound (`state_over_its_bound_is_not_stored` fails:
no step is classified `invalid_pattern_state`) are negative controls. For the control path, the control without the drain after the
release is a negative control (`approved_root_finish_ends_the_run` fails: the view has
no outcome after the reply; `approved_child_finish_reaches_its_parent` fails: the parent
slot is still running; the three tests of `replay_is_equal` pass), and so is the
protocol clause of the original-record match without the guard on the kind of the
candidate (`control_id_of_a_protocol_input_is_a_conflict` fails: the control call ends
with an exit and the engine process is gone). For the replies to an approval request,
the old clause that refuses every reply other than `ok` is a negative control
(`request_survives_a_death`, `lost_reply_is_recovered` and
`uncertain_reply_is_no_refusal` fail: the slot is settled where it should wait;
`definite_refusal_still_refuses` passes). For the room of invocation entries, the
fold without the check (`wake_without_room_is_not_given` fails at `step/2`'s size
assertion) and the check on the state without the entry placed
(`wake_without_room_is_not_given` and `the_switch_is_one_place` fail at the same
assertion) are negative controls; making the check on `action_outcome` still passes
`settling_input_is_given_as_today` because settling the active slot frees its
4,096-byte reserve before the check, so that point is covered by reading. These finite scenarios are not a universal proof, production monitor,
physical no-send guarantee or proof of arbitrary callbacks/providers. Reused
Cure laws retain their dependency-local scope; no new Cure proof is claimed.

The later checked-command composition may reuse the documented schema/identity/
gate/authority/approval order and existing pure APIs, not this Run-bound engine
unchanged. Engine Budget, no-reuse action IDs and post-work outcomes do not
provide Run-free command idempotency or atomic caller change/outcome persistence.
No future API or shared checking layer is added. Copies are application-owned;
retain one coordinated namespace/revision and the declared Needs.

Limits of the change of Attempt. A Run recorded before this repair, with a
change of Attempt and open slots, folds to another state after it (Elzoo is not
released). The settlement is part of the `run_view` fold step: it writes no
protocol record, and the reason `attempt_closed` is in the outcome given to the
request tracker and the join, not in a separate journal record. A Run recorded
before the repair of the over-cap deny that already holds such a slot (a settled parent that an over-cap
deny turned back to refusing) keeps it until a change of Attempt sets it settled
again with its first settlement untouched (no Budget step, no join change); Elzoo is
not released. Some rows cannot be held by a test: a running child finish
and ready for local work, `ask_person`, nested callable and finish are covered by
the code path only.

Limits of the end of the Run. A Run recorded before this repair, with a terminal
view and open slots, folds to another state after it (Elzoo is not released). The
settlement is part of the fold step of the view or of the input: it writes no protocol
record; the reason `run_closed` is in the outcome given to the request tracker and the
join, and neither keeps it (the tracker keeps a done flag, the join keeps the class), so
no state shows the reason and no test asserts it. The settlement is less exact than the
drain was, on the safe side: a Resource slot in `ready` and a model or tool slot in
approval with a request key are settled `unknown` with the reservation held, also when
the Run lists no Effect for it. A refusal that was decided but not recorded when the Run
ended loses its own reason and class (`run_closed`, `refused`). The engine has no timer:
a retained slot past its deadline stays open until the next protocol input of the
current Attempt. Some rows cannot be held by a test of the end of the Run and are
covered by the code path only: a slot in approval with a request key (a model or tool
call becomes `unknown`, any other kind `refused`), ready with an approved request key
for local work, `ask_person`, nested callable and finish, a ready Resource slot, a
refusing nested parent that has a child, and a running child finish.

Limits of the room of a child finish. A child that never sends a finish that fits
leaves its parent action waiting. Three rules settle that parent: its deadline,
only when an input of the current Attempt reaches the engine at or after the deadline
while the Run is not terminal (the engine has no timer for the deadline of a slot), a
change of Attempt, and the end of the Run with the other open slots (above).
A Run recorded before this repair, with a finish that was
admitted and not yet kept, can meet the refusal on replay where the old code had none
(Elzoo is not released).

Limits of the replies to an approval request. While the Run gives a reply of case (2),
each drain ends at that slot, so slots after it in the order of the drain wait for the
next drain; a slot whose Run never answers stays open until its deadline (reached by
an input, as above) or a change of Attempt. Case (1) is tried for every reply that is
not `ok`; a key read from the view is used only through `release_approved` and
`dispatch_approved`, which the Run accepts only for a request of its current Attempt.
When the Run owner stops after an indeterminate write, the read of the view exits, as
each other call of the engine to a gone owner does. A Run recorded before this repair
that already holds the false refusal keeps it (Elzoo is not released).

Limits of the state bound. With every child at the bound of 65,536, 27 children can
be open at once in the scenario of `nested_start_without_room_is_refused`; a binding
that gives a smaller `state_bytes` allows more, up to the 64 active actions. When the
slot of a `nested_callable` settles, its child callable and every callable below it
close in the same fold step — `closed`, without state, so their state bounds leave
control and their room comes back. The open slots of a closed child settle by their
own rules and their costs still reach the parent Budget; nothing of the child is
handed to the parent twice. The last bytes
of the bound are not reserved for small growth: every refusal adds its reason to its
slot, so a slot within a few bytes of its own bound of 131,072 can pass it; and the
refusal of a nested start releases the reservation of the parent, which turns its
Budget entry from the open form (13 bytes encoded for an expiry up to 255, at least 16 bytes
above it) into the released form (15 bytes), so control becomes 2 bytes larger only
when the expiry of the parent is below 256 ms, and smaller otherwise; such a refusal can
pass the bound only when control is within 2 bytes of it. A Run recorded before this
repair can fold to another state: a larger reserve can refuse a nested start or a
request that fitted, and the state of a closed callable is gone (Elzoo is not
released).

Limits of the invocation entries. The entries of one Run are never removed. The
entry of an input that settles a slot is taken to be covered by the 4,096 bytes of
that slot. A state at the exact byte of the control bound can still fail a step by
a change of a few bytes. A Run recorded before this repair can fold to another state
(Elzoo is not released).
