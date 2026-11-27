# assembly/run-engine

`Elzoo.RunEngine` composes one checked pure pattern and one ordinary OTP
dispatcher over ready owners. It is not an agent loop, model/tool binding,
recipe loader, cluster owner or replacement for those owners. There is one
serialized engine per host identity and its DurableUnit. Old Run is unchanged;
this Assembly exclusively uses `RunApprovalRelease` on its allocated Run stream.

## Host construction

Use pinned Elixir 1.20.5/OTP 29.1.3 and the existing dependency closure. The
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

The engine opens its Unit on a fresh VM without a host warm-up. Its records
include the Aggregation join and PatternStep tracker, lifecycle decisions,
authorization decisions and Budget state. The Unit still decodes with `[:safe]`;
the host remains responsible for the atoms in its own terms, including pattern
state and binding facts.

`start_link(opts)` takes these fixed required facts (no defaults or hot changes):

- `identity`: UTF-8/no-NUL 1..160-byte Unit/stream identity; `run_id`: explicit
  allocated Run/accounting-period identity; `directory` and matching `store`.
- `run_owner`, trusted `tenant` and acting `principal`; `clock`: trusted
  zero-arity positive Unix-millisecond clock; `context`: current trusted
  authority/policy/approval/resource-grant supplier. Under `budget_rule: :pause`
  the Need is that `context` gives a `pause_deadline` after the clock each time the
  engine samples it for a record that it makes itself: a local-work outcome (sampled
  when its delivery is handled for commit, not at dispatch), an engine refusal or
  loss, and a nested start. A callback that gives a passed deadline is outside the
  Need: a first excess or a Budget exhaustion in the step of such a record still
  halts the engine.
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
`operator: {Elzoo.RunEngine, :step, %{version: 1, control: nil, slots: %{}, requests: %{}}}`
for the default protocol. Omitted `protocol_version` and explicit `1` retain
that v1 state, fingerprint and behavior. Explicit `protocol_version: 2` opts a
fresh native Unit into `%{version: 2, control: nil, slots: %{}, requests: %{}}`
and requires an `event_source` descriptor described below. Protocol selection
is fixed to the native Unit incarnation: recovery does not infer v2 from
retained state, and a v1 Unit cannot be converted to v2. The v2 fingerprint
includes source ID and version, not callback identity; replacement callbacks
with the same descriptor retain that identity.

Optional `expiry_reports: :owner` (with `protocol_version` 1 or 2) gives each slot
that the engine settles `expired` to the callable that owns it as an action
outcome ("Expiry reports" below). `:owner` is the only value. Absent, the engine
is the engine without the option, byte for byte: the same `:configure` record,
control and fingerprint, records, Unit state, pattern calls and charges. A
second `expiry_reports` key or any other value is
`{:stop, :invalid_options_or_recovery}` (`{:error, ...}` from `start_link/1`)
before any Unit starts. The option holds for the whole Run and every callable of
it. It is recorded as one more control key, `expiry_reports: :owner`, and in the
fingerprint, so a restart of the same Run with the option added or removed is
`:incompatible_recovery`, and a new Run configured on the same Unit takes the
option of its own start. The pure `step/2` reads it from the recorded control
only. The start options may gain members in a later in-place version; a caller
matches on the ones it uses.

Optional `messages: :while_active` (with `protocol_version` 1 or 2, with or
without `expiry_reports: :owner`) gives a `message` input to the root pattern also
while slots are active, as an input that settles no slot ("Recorded cycle and
obligations" below). `:while_active` is the only value. Absent, the engine is the
engine without the option, byte for byte: the same `:configure` record, control
and fingerprint, records, Unit state, pattern calls and charges. A second
`messages` key or any other value (`:idle`, `true` and `nil` among them) is
`{:stop, :invalid_options_or_recovery}` (`{:error, ...}` from `start_link/1`)
before any Unit starts. The option holds for the whole Run. It is recorded as one
more control key, `messages: :while_active`, and in the fingerprint, so a restart
of the same Run with the option added or removed is `:incompatible_recovery`, and
a new Run configured on the same Unit takes the option of its own start. The
fingerprint is wrapped as for `expiry_reports`, after it: the fingerprint with
`expiry_reports` applied (or without it) becomes the SHA-256 digest of the ETF of
`{:messages, :while_active, fingerprint}`. The pure `step/2` reads the option from
the recorded control only.

The native protocol is selected explicitly: authentic v2 frames decode as
`PatternStepV2` through `PatternStep.decode/2`; their
`PatternStepTrackerV2` is restored and validated as v2 history. The only
v1-to-v2 bridge is the validated RunResource-v1-to-native-v2 input envelope:
each resource input must first decode as PatternStep v1, then is tagged with the
selected native version, decoded and correlated again before ingestion. This
narrow conversion does not infer a protocol from stored frames or permit
general v1-to-v2 state conversion.

In either case, also set the Unit options `retention_count: 1024`,
`max_record_bytes: 16777216`,
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
before replacement. An indeterminate native outbox acknowledgement is reconciled
with the original item key and nonce through `Elzoo.DurableLog.confirm_ack/2`; only
a matching committed receipt resumes progress. Missing, pending, unavailable,
malformed, mismatched or superseded confirmation remains `ack_unknown`, and an
empty pending list is not proof of the original acknowledgement. Before replacement,
the host fences old tasks, owners, callers and connections; this ack reconciliation
does not replace confirmation of other outstanding writes. Pure pattern/gate
callbacks must terminate promptly and avoid hostile allocation; byte bounds are
not a sandbox. A receiver-only
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

For existing v1 inputs, `input(engine, stable_id, neutral_input_without_at_ms,
verified_context)` reads the clock once. Context contains `run_id`, execution `attempt_id`, and where
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

`deadlines(engine)` returns `{:ok, %{phase: phase, run_deadline: ms,
pause_deadline: ms | nil}}`, read from the same committed state as `status/1`,
which shows neither deadline. `phase` is the `phase` that `status/1` gives at that
point (`:active`, `:waiting`, `:paused` or `:terminal`). `run_deadline` is the
committed Run deadline in Unix milliseconds: the `run_deadline` start option until
the first `continue` that resumes the Run, then the `run_deadline` of the last
such `continue`, in every phase, also after a terminal outcome. `pause_deadline`
is the committed pause deadline when `phase` is `:paused` and `nil` in every other
phase: the `pause_deadline` of the `pause` control, or for an internal pause (a
Budget exhaustion or an expiry report under `budget_rule: :pause`) the
`pause_deadline` of the trusted `context` of the record that paused the Run; a Run
that is already paused keeps its pause deadline, and a `continue` that resumes the
Run clears it. A timely, verified `continue` can be applied (`{:ok, :applied}`)
while an exhausted Budget keeps the Run paused: it changes neither deadline, so
the read still gives the old Run deadline and the pause deadline. After a restart on
the journal both values come from the recovered state, never from the start
options (the `run_deadline` start option at a restart is the original value, part
of the fingerprint). The engine has no timer: a host that wakes a Run at its
deadline reads the current one here after a `continue`, an internal pause or a
restart.

A begin-Attempt or Approval-evidence control whose Run command is applied runs
the release and then drains the engine, as `input/4` and pause/continue do, and
replies only after that drain. So an approved root `finish` with a completed
source ends the Run before the reply, and an approved `finish` of a nested child
gives its parent the outcome before the reply. When the drain ends in a halt, the
control replies with that error, as `input/4` does. A control whose Run command is
refused or unchanged replies `{:error, {:run_control, _}}` and does not drain. A
pause or continue control whose ID is the ID of a recorded input of another kind
gives `{:error, :input_id_conflict}`, commits nothing, and the engine goes on.

`input/4`, `control/4`, `status/1` and `deadlines/1` each wait for the engine
process for at most 60,000 ms (one fixed limit; the functions take no limit
operand or option). `status/1` and `deadlines/1` are calls to the same process, so
each replies only after an input that the engine is working on. An input at the
bounds of this Piece (64 active, 256 lifetime actions) took about 4.2 to 5.0 s
alone and beside the Piece suite in 10
runs each on a shared worker host, most of it the journal write path of the
owners below this Piece, so the 5,000 ms default of `GenServer.call/2` would be
too near for any caller. A caller that needs a shorter wait runs the call in a
process of its own and gives up the wait there (`Task.async/1`, then
`Task.yield/2` and `Task.shutdown/2`). When a call ends by the limit, or its
caller stops waiting, the exit says nothing about whether the input was applied,
and the engine goes on with it. The existing rule above is the only guidance:
send the same ID again, never another; `{:ok, :applied}` or `{:ok, :duplicate}`
means the result committed, and changed bytes are `{:error, :input_id_conflict}`.

For native v2, an outside-event `wait_event` is activated from the configured
source head. The activation samples trusted time after that head read, fixes
the source cursor, ticket, source identity and deadline once committed, and is
not exposed as waiting until its input/result pair is confirmed. A fresh event
candidate is read and corroborated before its recorded time is sampled. Replay
of the original paired input ID uses retained facts and does not call the source,
clock or Operator; changed bytes conflict. Fenced restart preserves a waiting
cursor and deadline. There is no automatic source polling or new Run/Attempt on
recovery.

The v2 source descriptor has exactly `id`, `version`, `head` and `read`:
`%{id: id, version: positive_integer, head: head_fun, read: read_fun}`. `id`
is nonempty UTF-8 text without NUL, 1..200 bytes; callbacks have arities one
and two. Both receive exactly `%{tenant: configured_tenant,
principal: configured_principal, run_id: allocated_run_id}`; `head/1` returns
`{:ok, %{revision: nonnegative_integer, low_water: nonnegative_integer}}`.
`read/2` receives that scope and requested event ID and returns
`{:ok, %{head: head, event: event}}`; the event has exactly `id`, `source_id`,
`sequence`, `correlation_id`, `schema_id`, `schema_version` and canonical
`payload`. Event IDs retain
PatternStep's nonempty UTF-8 rule and native ingress bound; the source
descriptor's 200-byte ID limit is not an event-ID limit. Provider I/O is
outside Budget. The host must supply stable, prompt, read-only callbacks and
truthful scope; this interface does not authenticate a production source or
enforce callback resource bounds.

Fresh-event failures are exactly `:invalid_correlation`, `:invalid_payload`,
`:source_not_found`, `:source_unavailable` and `:source_gap`, and `:unavailable`
when the lookup of the input ID in the engine's journal fails after the source
read (see Failure, size and audit limits). They append no record of the
submitted event and do not settle its wait. A failure after the source read
keeps what `current/1` committed after the read: a Run-view synchronization and,
when it recovered a replacement Unit, the records of that recovery and its drain
(running local work settled `local_restart`, for one). The same
`{:error, :unavailable}` is also the reply when the event committed and the
drain after it halted on a failed winner read: `status/1` shows
`reconciliation: nil` after the failed lookup (the call added no record, and the
same input is sent again under the same ID) and `reconciliation: :unavailable`
after the halt. Oversized fresh candidates return `:invalid_payload`. Provider
errors are `{:error, :unavailable}` or `{:error, :gap}` from `head/1`, and
`{:error, :not_found}`, `{:error, :unavailable}` or `{:error, :gap}` from
`read/2`. `:unavailable` maps to `:source_unavailable`, `:gap` maps to
`:source_gap`, and `read/2`'s `:not_found` maps to `:source_not_found`. A malformed
head with `low_water > revision`, or an event sequence beyond its returned
head, is unavailable; an otherwise valid sequence at or behind the activation
cursor is `:invalid_correlation`. A valid sequence is positive and no greater
than the corroborated head. The first profile starts at low-water zero.
Low-water advancement or a cursor beyond the head is a gap, not an empty queue
or new baseline.

Before `read/2`, the Engine validates the v2 input envelope and native ingress
bound, the current waiting slot, Run/Attempt/occurrence/action/source/ticket
correlation, the selected binding's result schema and bounded payload. The
caller cannot supply `at_ms`, verification fields, nonzero actual or a claim
that work was dispatched: those context/input shapes are refused before source
I/O. After the read, the requested event ID, configured source ID, activation
ticket, selected result schema/version and canonical payload bytes must match
the returned event. An accepted event is paired with the original input ID;
replay after source loss does not perform a fresh read.

If an outside-event input arrives while paused, it settles once. The first
receipt, JSON pending input and pending order are retained for resume; the full
protocol record remains in durable history and is not duplicated in native
pending state. The Engine preflights the complete pending candidate and final
native state against the size bounds before append; an over-bound input is
refused without appending. The first accepted receipt is retained as its
original input ID and sequence, not replaced by replay.

An unpaired retry of an original outside-event input stops the Unit and
AsyncWork before the Engine returns `:delivery_unknown` and stops after the
reply. If either stop cannot be confirmed, `:stop_unknown` leaves the Engine
halted. The host owns fencing callers, the Run owner, source/provider and
connection trees before any replacement; this is not a general physical
cancellation guarantee.

An estimate of exactly integer zero takes a no-reservation path only for a
native v2 `wait_event`: it runs Budget's public `:status` step, retains the
returned Budget state, and stores `reservation: nil`. There is no fabricated
Budget entry or charge; settlement of that nil reservation is a no-op. A
positive wait estimate reserves; settlement, expiry, cancellation, Attempt
change and Run close release its reservation with actual zero. A source failure
leaves the wait and its positive reservation pending until an authorized close. All other
actions and versions retain their existing reserve path.
Separately dispatched work after an event is charged by its own estimate.

### Read-only event waits

`event_waits(engine, scope, limits)` is a bounded read-only API with the same
60,000 ms caller limit as `result/3`. It uses the same exact optional
`result_reader: %{evidence_store: store, retention_count: positive_integer}`
configuration. Scope and limits are validated before Run-owner or Store I/O.
`scope` has exactly `tenant`, `principal` and `run_id`, each matching the
Engine's fixed configuration. `limits` has exactly positive integer
`max_records` and `max_bytes`; maxima are 65,536 records and 536,870,912 bytes. The result is
`{:ok, %{run_id: ..., attempt_id: ..., waits: [...]}}`; each wait has exactly
`occurrence`, `action_id`, `source_id`, `correlation_id`, `cursor`,
`deadline_ms`, `status`, `outcome` and `accepted_event`. Status is `:waiting`,
`:settled` or `:closed`. `accepted_event` is nil unless an outside event settled
the wait, then exactly
`%{event_id: ..., input_id: ..., sequence: ...}`; the configured event ID is
returned verbatim. `control.stop_pending`, terminal native state or a committed
terminal Run closes an unsettled wait with nil outcome and no receipt. A
settled expiry or cancellation retains its outcome and may have no receipt;
outside-event settlement retains its accepted receipt.

The reader folds complete retained Unit history with public row validation and
the DurableUnit reducer, verifies activation/input/result and original receipt
pairing, and rechecks the stable stream heads and the Run's own owner facts:
`id`, `outcome`, `operation_id`, `current_attempt`, `completion_revision` and
`evidence_ref`, not `revision`, which is the revision of the owner's whole
stream. An owner command that leaves those six facts equal, of another Run of a
shared owner or of this Run (such as an `attach_child`), does not fail the read;
one that changes one of them (such as a `begin_attempt` or `cancel` of this
Run) during the read gives `{:error, :unavailable}`. It reads no clock and calls
no source callback, Operator, pattern, gate, schema, binding or work callback;
it does not mutate, repair, acknowledge, expire or use a private cache. At most
`64 * request_cap` waits are returned; valid waits are not truncated to
`request_cap`. A v1 Engine with configured reader returns an empty wait list.
Errors are exactly `{:error, :scope}`, `{:error, :invalid_limits}`,
`{:error, :reader_unconfigured}`, `{:error, :history}`,
`{:error, :unavailable}` and `{:error, :read_limit}`; owner/identity mismatch
is not an empty result.

### Read-only Run transcript

`transcript(engine, scope, limits)` shows what one Run did, from its committed
history in commit order. It takes the same call path, 60,000 ms caller limit,
exact `scope` and `limits`, optional `result_reader` configuration, reading,
budgets, rechecks and errors as `event_waits/3` (the owner recheck compares the
Run's own six facts, so an owner command that leaves them equal, of another Run
or of this one, does not fail it; the stream heads are rechecked as there):
`{:error, :scope}`, `{:error, :invalid_limits}`,
`{:error, :reader_unconfigured}`, `{:error, :read_limit}`,
`{:error, :history}` and `{:error, :unavailable}`. There is no completion
selection, so `:completion_mismatch` does not occur. It works for every Run state;
a running, waiting, paused or ASK Run returns its history so far. The result is
`{:ok, %{run_id: run_id, entries: [entry]}}`.

Each entry is derived from the change of the folded state that one committed
record makes, together with that record. Every entry has `type`, `sequence` (the
Unit row of the input that holds the record; its result row is the next one) and
`at_ms`, the record's own time: `input["at_ms"]` of a protocol record, `at_ms` of
a gate, admission, authorization, nested, finish, nested-actual, resource-cursor
or event-activation record, `view.at_ms` of a `:run_view` record,
`command.at_ms` of a `:lifecycle` record, and `nil` for `:configure`,
`:precheck`, `:continuation`, `:resume_input` and `:stale_stop` (ELZ-430: the drop
has no time of its own). Within one record, entries come
in this type order, then by occurrence (the engine's `{request, index}`). A `path`
lists the occurrences of the enclosing `nested_callable` actions from the root
down; it is `[]` in the root callable.

| `type` | Further fields |
| --- | --- |
| `:input` | `input_id`, `kind`: each committed protocol record of the scoped Run |
| `:gate` | `occurrence`, `verdict` (`:allow`, `:deny`), `reason`, `gate_id`, `gate_version` |
| `:action` | `occurrence`, `path`, `attempt_id`, `kind`, `action_id`, `schema_id`, `schema_version`, `payload`: the slot is admitted |
| `:authorization` | `occurrence`, `verdict` (`:allow`, `:ask`, `:deny`, or `:refused` when no decision was recorded), `policy` (`%{id, version, content_hash}` or `nil`) |
| `:nested_start` | `occurrence` of the `nested_callable` action, `schema_id`, `schema_version`, `payload` of the start |
| `:nested_finish` | `occurrence` of the `nested_callable` action, `schema_id`, `schema_version`, `payload` of the child's first admitted finish that the engine keeps |
| `:settlement` | `occurrence`, `path`, `action_id`, `outcome`, `by` (the kind of the settling record, such as `:protocol`, `:run_view` or `:finish`), `reason`, `actual` |
| `:actual` | `occurrence`, `actual`: a settled slot's actual changes later from none to an integer |
| `:terminal` | `outcome`: the Run becomes terminal |

A settlement has a `reason` only when the settling record is a protocol outcome
under the refusal schema `elzoo.run-engine.refusal` whose correlation occurrence
and `action_id` name that slot and whose own effect settled it, as the engine's
own expiry pass and protocol rule of that fold step decide (the reader reruns that
pure engine code on the folded state before the record; it calls no callback, and
like the fold it depends on the current engine code); a slot that the same
record settles by expiry (the named slot too, when its deadline had passed and the
outcome came too late) or
`run_closed`, and the closers inside a fold step (`attempt_closed`,
`run_closed`, `local_closed`), give `nil`, and `by` tells them apart. `actual` is
`0` for a `finish` action settled by its `:finish` record and `:unknown` when no
actual is recorded. Gate and precheck records settle no slot; a refusal settles
later through the engine's outcome record. A span of an action is its `:action`
entry to its `:settlement` entry in recorded time; the reader reads no clock.
A `:resume_input` record that gives a held expiry report (`expiry_reports:
:owner`) gives no entry, as for a resumed paused input: the slot's `:settlement`
entry stays in the expiring input's record with `by: :protocol` and `reason: nil`,
and the actions that the report's request opens appear from their own records.
A `message` given to the root under `messages: :while_active` adds no entry of its
own beyond its `:input` entry.
Entry types, fields and `by` kinds may gain members in a later in-place version;
a caller matches on the ones it uses.

Only the scoped Run's entries are returned: on a Unit whose history holds earlier
Runs, entries start at the record that configures the scoped `run_id`, and a
protocol record of another Run (a late input of an earlier Run) gives none. The
reader calls no Operator, pattern, gate, schema, binding, work, resource, source or
clock callback and does not start, drain, repair, append, acknowledge, checkpoint
or mutate anything; two reads of an unchanged history are equal. It is the
committed history of a running engine, not an audit record, metric, trace export
or cache, and it emits no telemetry. The payload of a host-supplied outcome is not
an entry (`result/3` gives the completion payload, `event_waits/3` the wait
receipts). The host must supply full retained history; a pruned history is
refused, not summarized.

### Read-only Run result

`result(engine, scope, limits)` uses the same 60,000 ms caller limit. A caller
timeout stops waiting; it does not cancel the queued result request or its Store
reads, which may continue after the caller has returned. The exact
scope map is `%{tenant: trusted_tenant, principal: trusted_principal,
run_id: allocated_run_id}`; each value is bounded UTF-8 text and must match the
host's fixed configuration. Limits are exactly
`%{max_records: positive_integer, max_bytes: positive_integer}`, capped at
65,536 inspected rows and 536,870,912 canonical bytes. Scope and limit
validation happens before any Run-owner or Store read. A host may omit the
optional `result_reader: %{evidence_store: store, retention_count: positive_integer}`;
existing callers then keep starting normally and a valid result request returns
`{:error, :reader_unconfigured}`. Malformed reader configuration is rejected
before DynamicUnits starts a Unit. The host supplies the configured canonical
evidence Store and the same retention count used by the Unit.

The authoritative Run owner is read first. A nonterminal Run, including paused
or waiting-for-person ASK, returns `{:pending, :not_completed}`; a terminal Run
with outcome `:cancelled`, `:out_of_budget` or `:out_of_time` returns
`{:terminal, outcome}` and reads no history, in v1 and v2 alike. A `completed` or
`failed` Run causes history reads in both versions (a `failed` Run below; before
ELZ-420 a `failed` Run returned `{:terminal, :failed}` with no read). For v2, the
selected completion source may be a directly completed `wait_event` or later
`local_work` after an outside event. In either case, the reader cross-checks the
activation record and accepted event receipt against the paired input/result
history and completion evidence. The reader scans committed Unit rows from
sequence 1 one row per Store page, folds
recorded input/result pairs with
`DurableUnit.fold/1`, and cross-checks the first accepted settlement of the
exact completion source occurrence, Run, Attempt, operation, action, slot and
canonical completion-evidence row referenced by the Run owner. It returns
`{:ok, %{run_id, attempt_id, operation_id, action_id, schema_id,
schema_version, payload, evidence_ref}}` with the original outcome payload and
schema identity. The evidence row and every inspected Unit row share the same
record and canonical-byte budgets; the 16,777,216-byte per-record limit still
applies.

A `failed` Run is read in the same way; the owner's `reason` is not read, since
it describes and proves nothing. The reader looks in the folded history for the
root failure of the owner's current Attempt: a `:finish` record with no source
(see "Recorded cycle and obligations") whose pure fold, replayed on the state
before it, gives exactly the recorded state, for a root `finish` of that Attempt
whose admitted action is exactly the action of its request frame (as terms, so
`1` and `1.0` differ) and names no action. Every other step of the history into
a pending failure (a record changed to name an action, for example) is
`{:error, :history}`. While a stop is pending (any stop, ELZ-430), a record that
changes the pending stop, its completion or the Attempt, and a Run view that ends
the Run or changes the Attempt, are replayed the same way, also in v1: the replay
must give exactly (`===`, so `1` and `1.0` differ) the recorded state under the
current fold or under the fold before ELZ-430 (for a terminal Run view also with
the close before ELZ-215, which left a waiting ask open), else `{:error, :history}`.
The recorded state cannot show which fold wrote a step, so a step is accepted only
when it equals one of them exactly; a history that the fold before ELZ-430 recorded
(a stop kept at a change of Attempt, a lifecycle stop that replaced a pending one)
reads as recorded. A `:stale_stop` record (see "Recorded cycle and obligations")
exists only in the current fold: it must name the pending stop and the Attempt that
the history read so far proves produced it, another than the current one, and
replay exactly. Protocol v2 checks each step of its event waits under the same
folds. This holds for every read of the history, the read of a `completed` Run,
`event_waits/3` and `transcript/3` included, so a completion or a root failure that
the reader selects belongs to the owner's current Attempt. With one, the Run, Attempt and
operation, the finish slot (settled `completed`, the Run's completion), the
terminal `failed` state and the canonical evidence row that the owner names (in
the configured stream, its four keys naming the finish action) must agree, and
the reply is
`{:failed, %{run_id, attempt_id, operation_id, action_id, schema_id,
schema_version, payload, evidence_ref}}` with the finish's own action ID, schema
identity and payload. Any disagreement is `{:error, :completion_mismatch}` or
`{:error, :history}`, never `{:terminal, :failed}`. With none (a failure of an
older Attempt, dropped at the change of Attempt, does not count), a history that
reads whole and whose state is the owner's Run, operation and current Attempt
gives `{:terminal, :failed}`: a failure that the owner recorded without the
pattern. A history that cannot show which (damaged, unavailable or over the
limits) gives its bounded error, never `{:terminal, :failed}`; so does a Unit that
lags an Attempt that a host began directly on the owner (`{:error, :history}`).
The evidence row and the Unit rows share the budgets as above.

This is a read-only audit path: it does not call the Operator, pattern, gate,
schema-validation, clock, binding, work or resource callbacks, use checkpoints
or state-read shortcuts, or start, drain, repair, append, acknowledge or mutate
the Unit. It refuses unavailable,
unknown, pruned, gapped, staged, unpaired, over-budget or invalid history and
rechecks the stream heads and the Run's own owner facts (the six that
`event_waits/3` compares, not the owner's stream revision) before returning, so
an owner command that leaves them equal, of another Run of a shared owner or of
this Run, does not fail it. Later duplicate,
late or otherwise non-settling records do not replace or invalidate the first
accepted outcome. The existing `status/1` remains payload-free. The host must
provide full retained history and a Store that truthfully reports committed
append visibility; this API does not repair history or create a cancellation
runtime. Bounded error results are `{:error, :scope}`,
`{:error, :invalid_limits}`, `{:error, :reader_unconfigured}`,
`{:error, :read_limit}`, `{:error, :history}`,
`{:error, :completion_mismatch}` and `{:error, :unavailable}`.

The pure `step/2` is exported only for the directory's fixed Operator binding.
Its tagged v1 and v2 plain records distinguish protocol, configuration, gate,
admission, authorization, continuation, Run/lifecycle, Resource-cursor and stale-stop
facts.
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

A root `finish` is dispatched after its schema, gate, Budget, authority and
Approval checks, and ends the Run by its payload's `action_id`. One that names an
action completes the Run only when that action is settled `completed` in the
same Attempt (the action's outcome is the Run's result); otherwise it is refused
`completion_evidence` with actual 0, and the Run stays open. One that names no
action (`"action_id": null`, no `action_id` key, or a payload that is not an
object) ends the Run `failed`: its `:finish` record has no source, and its fold
settles the finish slot `completed` with the finish's own schema, version and
payload (the failure record), its Budget entry at actual 0, at the time of the
record. The failure belongs to the Attempt of that finish. The engine then appends
the completion evidence row as for a completed Run (kind `completion`, exactly
`run_id`, the finish's `attempt_id`, `operation_id` and the finish's `action_id`)
and completes the Run owner for that Attempt with `:failed`, reason `"pattern"` and
that row's reference. The reason describes; `result/3` proves the failure from the
Unit history. A crash between the evidence row and the owner command leaves the row
unreferenced: the restart replays to the same state, appends an equal row and
completes the owner once, naming the new row. The failure, once pending, is bound to
its Attempt as every pending stop is (below). A nested finish never ends a Run
(above). Records carry the decision, so a Run recorded before this rule replays as
recorded: a root finish refused there stays refused, and one admitted but not yet
dispatched when the engine stopped is dispatched by this rule at the restart.

Every pending stop belongs to the Attempt that produced it (ELZ-430), the engine's
recorded Attempt at the step that asked for it: `:completed` and `:failed` to the
Attempt of their root finish, `:cancelled`, `:out_of_time` and `:out_of_budget` to
that of their lifecycle step. The completion evidence row of `:completed` and
`:failed` (its `attempt_id`) and the owner's `complete` command carry it. The first
pending stop wins: a lifecycle stop asked for in a later step (the Run deadline, a
cancel, a Budget or request-cap stop) does not replace it, also when a restart past
the Run deadline records the loss of local work that was running, as the input gate
already refuses new work while one is pending. A change of Attempt that the engine
takes before the owner records the stop drops it in the fold of that Run view: the
host began an Attempt on the owner while the engine was down, or after the engine
read the owner's revision for its command, which the owner then answers `stale` and
the engine follows with the new Run view (at its restart, when it stopped first).
The pending stop goes, and with it the completion and the closed generation of a
finish (a request-cap stop keeps its own) and the record of a cancel of the Attempt
that is left; an evidence row stays unreferenced, and the owner records no stop for
the older Attempt. The new Attempt is not ended by the older stop: its inputs reach
the root again after a completion, a failure, a cancel or the expiry of an older pause
deadline, and the Run-wide deadline, Budget and request cap stay as they were, so a
wake of the new Attempt past the Run deadline, with the Budget spent or at the
request cap asks for that stop again, now for the new Attempt.

A lifecycle stop asked for while a stop is pending loses and leaves no trace: a wake
at the request cap closes no generation and stops no charge (the count stays as it
is), and a cancel records no cancel and closes no local work. The pending stop alone
decides the owner's reason and what the end of the Run closes: a completion ends with
reason `"engine"` and its end closes every open slot, since only a request-cap stop
that is itself the stop retains slots. A `cancel` control cancels, after its drain,
the AsyncWork tasks of only the local work that its committed cancel closed; a
cancel that loses to a pending stop (one that the control's own `current/1` took
first, from a Resource outcome for one) cancels none, so the local work that the
winning stop retains runs on.

At a start, and when the engine takes a replacement Unit, the engine decides a
pending stop before it writes anything (before it takes the owner's Run view and
before it records the loss of running local work). It first reads the owner's
committed Run view: when the Run is terminal there, or the owner has begun an
Attempt after the engine's recorded one (the owner lists the recorded Attempt and
names another as current; it begins an Attempt ID once only), no delivery decision
is left, and the engine takes that Run view, whose fold ends the Run or drops the
stop, with no owner command for it. No other change of the owner's revision (a lease
renewal, another Run's command, a fact of this Run such as an attached child) skips
the decision. The engine then takes a pending stop only on proof of the Attempt that
produced it: a completion or root failure by its settled completion slot, with the
generation that its finish closed; any other stop, and a completion or failure that
the state cannot show, by the step of the journal that set it and the Attempt
current at it (a cancel is always proven there, since the fold before ELZ-430 let a
cancel replace a pending stop). A stop of the recorded Attempt is delivered exactly
as committed: no clock, Budget or request cap is read again. A stop of an older
Attempt (a journal recorded before ELZ-430 can keep one at a change of Attempt) is
dropped by a `:stale_stop` record, which names the stop and its Attempt, with no
owner command; the current Attempt's own inputs then decide its limits. A stop that
nothing proves (one that the fold before ELZ-430 set in place of a pending stop of
the same Attempt, or one that a Run view set) makes `start_link/1` give
`{:error, :stop_origin_unknown}`, and halts the engine with that reason at a
replacement Unit, with no write and no owner command; a journal that cannot be read
whole (a failed read, a gap, a head with low-water above zero) gives `:unavailable`
the same way. The host's fix is to end the Run or begin a new Attempt on the owner,
then start the engine again: it takes that Run view as above.

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
other state leaves control. `cancel` needs no entry. Such an input (`wake`,
`start`, `message`, granted `resource_event`) is given to the root only when no
slot is active: a slot is active while it is not settled or while it holds a
pending input (a settling input kept while paused, or a held expiry report). A
`wake`, `start` or `message` also needs the lifecycle to permit new work, which a
`:waiting` Run does not (`RemainWaiting`); the paragraph below says when a Run is
`:active` again. With `messages: :while_active` there is one exception, for a
`message` only. It is
given to the root pattern when the lifecycle permits new work or decides
`RemainWaiting`, also while a slot is active (unsettled, or holding a pending
input). Everything else above still holds: generation open, no stop pending, the
Run not paused, the root callable open and room for the invocation entry. It is
given to the root only, never to a nested callable, whichever callable owns the
active slots, as one ordinary pattern call with the input exactly as committed. It
settles no slot: no slot, join, tracker, Budget entry or lifecycle wait changes, and
the phase stays what the decision left (a `:waiting` Run stays `:waiting`). `:none`
charges nothing; `{:some, request}` charges one count of the sealed request cap with
a receipt whose `input_id` is the message's ID and runs the ordinary admission,
including the 64-active bound over the slots still open and the first-excess rule.
The root is given the message in the fold step of the message's own record, after
its own expiry pass; an outcome, answer or event that commits later is given in its
own later step, and nothing is held or reordered for the message. With the option
the root is still not given a `message` when the Run is paused (`RemainPaused`; the
message is not kept for `continue`, and the same ID again after `continue` is
`{:ok, :duplicate}`, so the host sends it again under a new input ID), paused at or
after its pause deadline, terminal, or the message is at or after the Run deadline;
when the root Budget's committed amount is at its cap (`EnterPause` or
`RequestBudget`); when the record is late or a duplicate; when generation is
closed, a stop is pending or the root callable is closed; and when control has no
room for its invocation entry (`record_size`). A `wake`, `start` or granted
`resource_event` while a slot is active is not given to the root, with or without
the option. `status/1` classifies the message by the lifecycle decision, as
without the option, so neither `status/1` nor `transcript/3` says on its own
whether the root was given it.

Paused accepted results retain their pattern input until
continue, without dispatch while paused; monetary exhaustion still takes
lifecycle precedence below the request-count cap. After `continue`, the drain gives
each retained input by a `:resume_input` record. When that leaves no slot active and
no wait listed, the fold makes a `:waiting` Run `:active` again before the pattern
call, as a settlement outside a pause does, so the next permitted `wake` reaches the
root; while another slot is active the Run stays `:waiting`. This holds for every
Run, with or without `expiry_reports`.

Expiry reports (`expiry_reports: :owner`). Without the option, the expiry pass of
an input settles each slot past its deadline `expired` and tells no pattern. With
it, after the whole pass and before the input's own rule, each slot that the pass
settled (not one that it left open as `late`) and whose callable is still open
holds a report as its `pending_input`, in ascending occurrence `{request, index}`
order, each with the next `order`, when the state with it placed still satisfies
every bound; otherwise the slot settles as without the option. A slot whose
callable the same pass closed (its `nested_callable` parent expired too) gets none.
The report is the expiry input itself: an `action_outcome` with outcome
`"expired"`, the refusal schema `elzoo.run-engine.refusal` version 1, the payload
`reason` `"expired"`, `gate_id`, `gate_version`, `request` and `index`, and
`at_ms` the time of the expiring input. It is kept under the ID of the
`:resume_input` record that gives it, `"resume:"` and the hex SHA-256 of the ETF of
`{run_id, occurrence}`, with correlation `%{occurrence: key, loss: :timed_out}` and
the `pause_deadline` of the expiring input's context. Under `budget_rule: :pause` a
report is held only when that deadline is after the input's time: an input whose
`pause_deadline` is not after its time, such as an engine-made record whose sample
from the callback has passed, settles its expired slots as without the option. The settlement itself is as
without the option: its outcome, join entry, tracker acceptance, Budget step (no
actual, entry held until the Budget expires it; a `wait_event` actual 0 with its
reservation released) and the close of an expired parent's child.

A held report counts as active (one of 64 places and 4,096 reserved control
bytes), so an input that settles no slot and whose own pass holds a report is not
given to the root: the root learns of its own expired slots from their reports.
With `messages: :while_active`, a `message` is the exception: it is given to the
root before those reports. Its own pattern call is in its own fold step, and the
drain gives the reports that its pass holds after that call, in their `order`,
before `input/4` replies, unless that step drops them (the root's request for the
message is the first excess, or the view is terminal), with no record, call or
charge. So the root can be given a message before the report of a slot that the
same message's pass expired.
The drain gives the held reports, lowest `order` first, after a pending stop and
before a finished child or any slot progress, only while the Run is neither paused
nor terminal, generation is open, no stop is pending and the owning callable is
open; `input/4` and `control/4` reply after it. Each give is one ordinary call of
that callable's pattern only, never of a parent or the root in its place: `:none`
charges nothing, `{:some, request}` charges one count of the sealed request cap
with a receipt whose `input_id` is the report ID, and its request runs the ordinary
admission. A report's output is folded before the next report, and the slots that
it opens progress after every report held at that point. At a first excess the
existing rule applies (receipt `over_cap`, generation closed, the unsettled parent
refused `out_of_budget`; under `budget_rule: :pause` the Run enters the pause with
the report's `pause_deadline`, under `:finish` it stops) and every report still held
is dropped. A held report is dropped with no record, call, charge, receipt or request
at the end of the first step after which generation is closed, the view is terminal,
its Attempt is not current or its callable is closed: a request-cap stop (including
a `wake` at the cap), a cancel, the Run deadline, a `:finish` Budget exhaustion, a
change of Attempt and the close of the owner. An expiry pass while paused holds its
reports; after `continue` they are given in `order` with the inputs retained while
paused (in one paused step, reports first, then the retained input). Only the pass of
the current Attempt holds reports. The fold of a `:resume_input` record that gives a
report switches the lifecycle as one that gives a retained paused input (above): a
`:waiting` Run with no slot active and no wait listed is `:active` again before the
pattern call, so after the last report the next permitted `wake` reaches the root.

Reports replay: the hold is part of the fold of the expiring input and the give is a
`:resume_input` record; the fold reads no clock, process or start option. If the
engine dies after the expiring input committed and before its reports were given,
the startup drain gives them before any new input, in the same order, under the same
IDs and with the same pattern inputs. A record that another owner writes at startup
(a local-work loss, a Resource cursor, an intent change) comes first. After the
reports are given, a host input with a report ID is `{:error, :input_id_conflict}`;
a host input with the ID `"expire:" <> occurrence` is ordinary. The readers that
rerun pure engine code, `transcript/3` and `event_waits/3`, project a `:resume_input`
with the same phase switch, so they reach the state of the fold.

Run views. The engine keeps the revision of the Run owner's stream that it took last
as `control.run_revision`. Each time it reads the owner's `status/2` to bring its
view up to date (at startup and recovery, before an input or a control, after a
control or a completion that it sends to the owner, and before a dispatch), it
learns the owner's held (fenced) revision from `revision` and, from
`renewed_since`, the revision of the owner's latest committed record that is not a
lease renewal (ELZ-429). An equal `revision` is no change. When its recorded
revision is at or above `renewed_since` and below `revision`, everything after it
is a renewal of the owner's lease (`RunApprovalRelease.renew/2`), which changes no
Run fact: the engine commits no record, keeps its recorded revision, settles nothing
and does not close a slot for it. Its next owner command reads `revision` afresh,
so the renewals do not make it conflict (and a live owner also accepts a revision
separated from its current one by its own renewals, ELZ-422). Every other change of
`revision` is a Run transition, as before: the engine commits one `:run_view` record
with the Run ID, operation, current Attempt, `revision` and outcome read and the
engine clock as `at_ms`, and its fold takes the new facts with the closes below.
That includes a Run record that leaves those facts as they were (an Approval
request, evidence or release, an intent or effect record, a child record, a command
of another Run of a shared owner), a release, claim or seize of the lease, and any
renewals read with them; one record covers all that the read found. An owner view
without `renewed_since` is no proof: the engine then journals every change of
`revision`, as before. The owner rebuilds `renewed_since` from its whole stream
when it starts, so a replacement owner started on the token that renewals left
gives a reopened engine the same answer, and the engine's startup commits no record
for those renewals. Not every input reads the Run: the replay of a native v2
`outside_event` that is already recorded and paired answers `{:ok, :unchanged}`
without it, and a halted engine reads nothing.

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
A lost acknowledgement reply is checked with the public confirmation API and its
original item key/nonce; every result other than a matching commit stays explicitly
unknown rather than retrying or inferring success from no pending item.

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
cleanup; unknown/read-only is not closed. Completed and pattern-failed Run
evidence is an actual Writer-appended canonical map correlating Run, operation,
Attempt and the completed source action or the failing finish action, never DU's
tuple or an invented sequence.

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
write, or a failed reconciliation of an internal record that the Unit refused
(below), ends in the `delivery_unknown`, `ownership_unknown` or storage halts.
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

A journal lookup scans the engine's own stream from its first record: the
lookup of the ID of an input or control before it is committed, the lookup of
the admission of a settled occurrence when an outcome recorded for it is sent
again, and the read of the winner when the Unit's completed-ID check refuses an
internal record with `:input_id_conflict` (before any append). A read that fails
(`{:error, :unavailable}`, `{:error, :malformed}`, which is also the Store's
answer to a gap reply, or `{:error, {:pruned, low_water}}`) or a page whose head
has `low_water` above zero cannot show the whole history, and the lookup gives
no answer. For the first two lookups, `input/4` and `control/4` (pause, continue
and cancel alike, never `:invalid_control` or `:cancel_unknown`) return
`{:error, :unavailable}`: the failed call adds no new record for the submitted
ID (an earlier record of the same ID, such as a recorded outcome sent again, stays as it was), the engine
goes on with no halt, `status/1` shows `reconciliation: nil`, and the caller
sends the same call again under the same ID, never another. What `current/1`
committed before the lookup stays committed: a Run-view synchronization and,
after a Unit replacement, the records of its recovery. A failed read of the
winner is a failed reconciliation: the engine cannot establish whether the
recorded winner matches its record, and it halts with the storage halt
`:unavailable`. A complete scan that finds no winner contradicts the Unit's
completed ID and is the halt `:integrity_failure`, as is a winner that differs
from the engine's record on `:kind`, `:request` or `:occurrence`. Such a halt
can also come in the
drain after the call's own input committed: `input/4` then returns the halt
reason, so `{:error, :unavailable}` there comes with
`reconciliation: :unavailable`, and a cancel returns `{:error, :cancel_unknown}`
with its record kept. A v2 local-work outcome whose delivery meets a halt in
`current/1` is not committed, and the halt stays in `reconciliation`; one whose
delivery meets an error of `current/1` without a halt is not committed either,
and the engine keeps its state from before the delivery, so the next call
recovers the replacement Unit again before it takes its own input. A halted
engine answers later `input/4` and `control/4` calls with its halt, with one
exception: a halted v2 engine still looks an outside-event input up in its
journal. A paired replay of a recorded event answers `{:ok, :unchanged}` and a
changed replay `{:error, :input_id_conflict}` (an input that fails its checks,
or whose lookup cannot read the journal, gets that error instead). Neither clears
the halt: `status/1` shows it as `reconciliation` until an explicit host restart
reopens the engine, so a caller reads `reconciliation`, not a replay reply, to
learn whether intake has reopened. An unpaired replay (the input recorded, its
result not) fences instead: once the stops of the Unit and AsyncWork are
confirmed, the engine replies with its halt and then stops, so no `status/1`
call follows; when a stop cannot be confirmed, it replies
`{:error, :stop_unknown}`, which becomes its halt.

Payload/outcome JSON <=65536 bytes and depth <=32; ingress <=262144 bytes;
DU record/output <=16777216 bytes; complete active slot <=131072 bytes;
64 active/256 lifetime actions; control <=2097152 bytes (including 4096 bytes
reserved per active action and cap+1 receipt reservations); complete compact
request map <=4456448 bytes; slot map <=8 MiB; callable state within its state bound (<=65536 bytes), reserved in control while the callable is open;
an input that settles no slot needs room in control for its invocation entry (its ID
and 42 bytes: 43 bytes for a 1-byte ID and 202 bytes for a 160-byte ID), else it is
classified `record_size` and not given to a pattern. With `expiry_reports: :owner`
a held report adds at most 2,909 ETF bytes (2,923 bytes of slot growth) to its slot
when `at_ms` and `pause_deadline` are below 2^53 (a larger time adds its extra
digits and bytes; the engine bounds neither): a 200-byte Run ID, a 200-byte action ID
and a 128-byte gate ID of control characters, which the JSON text of the report
escapes as `\u00XX`, six bytes each, a 200-byte Attempt ID, the bound of
`workflow/run-approval-release`'s `id?/1`, occurrence `{257, 63}`, gate version
2,147,483,647 and `order` 256 (each slot holds at most one pending input, and a Run
has at most 256 slots, so `order` is at most 256; it takes 3 bytes more than an
`order` up to 255); with ASCII letters it is 1,269 bytes. It is
held only when the slot bound and the 8,388,608-byte slot map still hold. Its
invocation entry, 113 bytes (the 71-byte report ID and 42), is placed at the give
inside the 4,096-byte reserve that leaves with the held report, and it stays until a
new Run is configured, so a Run with the option keeps up to 256 × 113 = 28,928 bytes
more control than the same Run without it.
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

The PostgreSQL-backed `native outbox acknowledgement reconciliation` tests exercise
a real acknowledgement before its reply is hidden, confirmation with the original
key and nonce, a rolled-back acknowledgement, an unavailable confirmation read,
a different winning nonce, malformed confirmation evidence after a committed ack,
and repeated offers while halted. Their completed-cut
restart stops the engine, Unit and Run owner after confirming no task is active,
reopens database connections, then compares Run, Attempt, Unit, result, work, Budget
and outbox state.
This finite fixture does not establish universal process/network cancellation or
volatile-work recovery; local work retains the existing `local_restart` semantics.

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

Limits of the stop bound to its Attempt (ELZ-430). A journal recorded before ELZ-430
keeps its records and reads as recorded when each step equals exactly the step of
this fold or of the fold before ELZ-430 (see "Read-only Run result"). Migration:
before a host takes this revision, let each engine with a pending stop deliver it
under the earlier revision, or end that Run on its owner. A pending stop that the
earlier fold set in place of another pending stop of the same Attempt has no proof
here: the start gives `{:error, :stop_origin_unknown}`, and the host's response is
to end the Run (or begin a new Attempt) on the owner and start the engine again,
which takes that Run view with no owner command for the stop. Rollback cut: once
this revision has written a `:stale_stop` record to a journal, the earlier revision
cannot fold that journal (its fold has no such record). A completion that the
earlier fold kept through a timely `:pause` wake at the request cap, which that fold
let stop the charge, is delivered as committed: the owner records `:completed` with
reason `"request_cap"`, and the end of the Run retains slots as a request-cap stop
does. The wakes after a change of Attempt are exercised for the stops of a
completion, a failure, a cancel, an older pause deadline, the Run deadline, the
monetary Budget and the request cap (Elzoo is not released).

The groups `resumed_input_reopens_the_root` and
`resumed_input_with_open_work_stays_waiting` of `test/elzoo/run_engine_test.exs`, and
the test `native_v2_resumed_input` of `test/elzoo/run_engine_v2_test.exs`, exercise
the resumed retained input without `expiry_reports` (#843): after `continue` a root
whose retained answer opens nothing is `:active`, stays so across a restart that
recovers the unit from its history, and is given the next `wake`, whose request is
admitted; with running local work or a second waiting ask the Run stays `:waiting`
and the `wake` is not given to the root; under protocol v2 `event_waits/3` and
`transcript/3` read the Run and the next `wake` reaches the root. Three temporary
negative controls each made a named test fail and were reverted: the switch kept
for `expiry_reports: :owner` only (the first group and the v2 test), no
`active_count/1` condition (the local-work test) and the event-wait projection kept
for the option only (the v2 test: `event_waits/3` returns `{:error, :history}`). A
Run recorded before this repair can fold to another phase (Elzoo is not released).

The group `local_outcome_pause_deadline` of `test/elzoo/run_engine_test.exs` and the
tests `native_v2_local_outcome_pause_deadline` and
`outcome_waiting_in_the_mailbox_takes_the_later_deadline (v2)` of
`test/elzoo/run_engine_v2_test.exs` exercise the pause deadline of a local-work
outcome under `budget_rule: :pause` without `expiry_reports` (#854): local work is
dispatched while the `context` callback gives 30,000, and its outcome comes at 35,000
while the callback gives 50,000. The committed outcome carries 50,000; a first excess
of the request cap on the outcome (`local_outcome_pauses_on_the_current_deadline`,
also across a restart) and a Budget exhaustion by its actual
(`local_outcome_exhaustion_pauses_on_the_current_deadline`: the Run pauses before
the root is given the outcome) pause the Run on 50,000, and the next input applies;
under protocol v2 `event_waits/3` and `transcript/3` read the paused Run. In
`outcome_waiting_in_the_mailbox_takes_the_later_deadline`, once in v1 and once in
v2, the engine is suspended with `:sys.suspend/1`, the work completes while the
callback still gives 30,000, and the callback gives 50,000 and the clock 36,000 before
the engine resumes: the outcome carries 50,000 and keeps the time when the work
finished (35,000). Six temporary negative controls each made a named test
fail and were reverted: the dispatch-time sample in both paths (the next input
returns `{:error, :durable_unit_transition_failed}`, and
`report_uses_the_current_deadline` holds no report), the sample in the v1 handler
only (the v2 test), the sample in the AsyncWork wrap when the work finishes (the
mailbox test in v1 and v2), that wrap sample kept in the v2 path only (the mailbox
test in v2), the outcome's `at_ms` taken from the clock when it is handled (the
mailbox test in v1 and v2) and the guard of `expire_and_report/3` removed (the
existing `:pause` test of `bound_edges` whose outcome carries a passed deadline). The deadline is the
callback's value when the delivery is handled, not when the work finished; the two
differ by the time the delivery waits in the engine's mailbox. A second delivery of
an outcome already committed has no case (only a crafted message reaches it): v1
resolves it as `:unchanged` and v2 ignores it. A Unit history that already holds a
local-work outcome with a passed dispatch-time deadline folds as before (Elzoo is
not released).

`test/elzoo/run_engine_expiry_report_test.exs` exercises `expiry_reports: :owner`
on disposable PostgreSQL with one pinned engine identity:
`default_off_is_unchanged` (a recorded scenario without the option, with a child's
three tool slots expiring while paused, a root ask, `continue`, the parent's later
expiry, one restart and the end of the Run, has the SHA-256 and byte length of its
trace, recorded on the base commit before the change; the configure control differs
only by the option key and the fingerprint; a restart with the option added or
removed is `:incompatible_recovery`; `:nested`, `true`, `nil` and a second key are
refused with no Unit started), `nested_turn_reads_its_expiries` (a child is given its
three expiries in order and finishes, charged one count; the parent completes with no
actual; the tool entries stay held; the root is not given them; three report records;
the transcript keeps the settlements in the wake's record), `several_expiries_in_one_wake`
(reports of the root, C and D in occurrence order, a request of C's first report
progressing after the last; a root whose only open slot expires gets its report and
not the wake, then the next wake), `closed_owner_gets_nothing` (a child and its parent
expiring together; reports held while paused dropped by the parent's expiry; a change
of Attempt), `ending_drops_reports` (a cancel's own step; reports held while paused
dropped by the Run deadline; an input at the Run deadline holds none), `bound_edges`
(a report's first excess under `:finish` and under `:pause`, which pauses with the
expiring input's deadline and gives no later report after `continue`; under `:pause`
a lost local work whose outcome carries a passed deadline holds no report, and the
next `wake` pauses with its own deadline; `report_uses_the_current_deadline`: a local
work dispatched while the callback gives 30,000 and lost at 35,000, after its own
deadline, while it gives 50,000 holds its report and gives it to the root; a `wake` at the cap; a give at 64 bytes of control headroom through `step/2`; a crafted slot map
within one report of its bound), `paused_reports_wait`, `replay_is_equal (expiry
reports)`, `recovery_gives_the_same_reports` (a death after a directly committed
expiring wake gives the same reports, records and Unit state as an engine that did not
die, with the clock moved 1,000 ms), `report_id_is_the_resume_id` and
`native_v2_wait_report` (also a wait held while paused and given after `continue`,
read by `event_waits/3` and `transcript/3`). Thirteen temporary negative controls each made a named test
fail and were reverted: the default flipped on, delivery to the root, descending
order, no open-owner condition, giving after generation closed (the `:pause` item; the
`:finish` item drops the report by the pending stop and the parent's deny), a held
report not counted as active, a hold with no `fits?/1` check (`step/2` raises), the
time read from the clock at the give, no lifecycle switch at `:resume_input`, the ID
`"expire:" <> occurrence` (the later host input halts the engine) and a report with an
empty context (the expiring `wake` returns `{:error, :durable_unit_transition_failed}`)
the event-wait reader without its projection of `:resume_input` (`event_waits/3`
returns `{:error, :history}`) and a hold under `:pause` whatever its deadline (the
root is given the report of the lost local work).

Limits of expiry reports. Reports come only from the expiry pass, and the engine has
no timer, so an expiry and its report need an input of the current Attempt at or after
the deadline; an input at or after the Run deadline holds none, because the lifecycle
takes the expiry itself as `Expired` and the end of the Run settles the open slots
`run_closed`. Under `:pause` an input whose `pause_deadline` is not after its time (such
as an engine-made record whose sample from the callback has passed) holds none. A report is an engine-made outcome, not a provider result: it says that
the deadline passed, not that nothing was sent, and the cost stays unknown, not zero. A
dropped report leaves no trace other than the slot's settlement. The bound edge of a
hold is shown on a crafted state through `step/2`, not on a reachable Run; the stop of a
`:finish` Budget exhaustion drops held reports by the pending-stop rule and has no case
of its own. A slot past its deadline counts as active until its report is given. A Run
with the option keeps up to 113 control bytes more per reported slot, so a later
admission can be refused `record_size` where the same Run without it fits. After a
restart, a record that another owner writes at startup comes before the held reports.
The 60,000 ms call limit covers the extra drain work (at most one pattern call and its
admission per expired slot); no time bound is claimed. The report ID is in the
engine's stable-ID space: a host that uses such an ID for an unrelated input before the
report is given is outside its Need. Per-callable choice, the expiring input given to
the root as well, reports of other closers, a report for a closed owner given to an
ancestor, more facts in the report, an engine timer, and a transcript entry or status
key for reports stay addable in place. Finite listed scenarios, not a proof.

`test/elzoo/run_engine_messages_test.exs` exercises `messages: :while_active` on
disposable PostgreSQL and through pure `step/2`: `default_off_is_unchanged` (without the option a `message`
while a tool slot runs is applied, has its `:input` entry and is not given, and the
root's inputs are its `start`, then the tool outcome; the configure control differs
only by the option key and the fingerprint, which is the wrap of the fingerprint
without it, also over `expiry_reports`; a restart with the option added or removed
is `:incompatible_recovery`; `:idle`, `true`, `nil` and a second key start no Unit;
valid with `protocol_version` 1 and 2; a new Run on the Unit takes the option of its
own start), `message_reaches_root_while_active` (the root is given the message
exactly as committed while a tool slot runs, and slots, count, receipts, Budgets,
trackers and lifecycle waits stay, the Run stays `:waiting`, the message's record
has only its `:input` entry and the tool settlement is in the outcome's record; with
only a running nested parent whose child opened nothing, `:permit_new_work`, the
child is not given it; with running local work; a duplicate and a conflict; a v2
message while a `wait_event` waits, and a v2 message whose root request is the first
excess, after which `event_waits/3` and `transcript/3` return `{:ok, _}`),
`message_opens_work` (a `local_work` request charged with the message's receipt and
admitted beside the open tool slot; at `request_cap` 1 the first excess, `over_cap`,
generation closed, `:out_of_budget`, the tool slot retained `:running`),
`root_only_message_only` (a nested child with an open tool call is not given it; a
`wake`, a later `start` and a granted `resource_event` while a slot is active are not
given, and `step/2` with the option removed from control gives the same state; a
message while paused is not given, after `continue` the same ID is a duplicate and a
new ID is given; through `step/2`, each case that stays refused, from the Run
deadline to a closed root, gives the same state as the step without the option and no
invocation entry), `ordering_with_reports` (with `expiry_reports: :owner` a message at
an ask's deadline is given before the ask's report, both before `input/4` replies,
and its record holds the ask's settlement `by: :protocol`, `reason: nil`; its
request as the first excess drops the held report, no `:resume_input` record; with
`expiry_reports` alone the root is given only the report) and `room_and_replay` (a
message without room for its invocation entry is `record_size` through `step/2`, a
sweep from 64 to 266 bytes switches at one headroom; two restarts after a message
and an outcome, and after a message and its report, give equal state, record count
and transcripts, with no pattern call and no Effect). Nine temporary negative
controls each made a named test fail and were reverted: the option ignored, the
default flipped on, the rule applied to `wake`, `start` and `resource_event`, the
accept rule in `transition/2` instead of `protocol/2` (`event_waits/3` returns
`{:error, :history}`), the message given to the owner of the newest active slot, no
room check for the message, the option left out of the fingerprint, the message
refused while a slot holds a pending input and the message accepted at every
lifecycle decision (the refused-cases case fails).

Limits of `messages: :while_active`. Root only: a bot that runs as a nested callable
is given no message while slots are active. A message while paused is not given and
not kept; the host sends it again after `continue`, under a new input ID. A pattern
whose Need is an engine that gives a message only while no action is open
(`workflow/turn-policy`, a room included) is hosted on an engine started without the
option. Neither `status/1` nor `transcript/3` says on its own whether the root was
given a message, as for `wake`; the root's request, if any, appears from its own
records. With `expiry_reports: :owner` the root can be given a message before the
report of a slot that the message's own expiry pass expired. The control key adds 24
ETF bytes to control, so at a `record_size` edge a Run with the option can be refused
where the same Run without it fits. That an agent-loop root
then takes its row "the text waits; no request" rests on agent-loop's own step
tests: these tests run the engine with a test pattern and no agent-loop composition,
and the Wave 9 acceptance harness does not turn the option on. A member for `wake`,
`start` or `resource_event`, a named nested callable, a message kept while paused,
and a transcript field or status member for it stay addable in place. Listed
scenarios on disposable PostgreSQL and pure `step/2` calls, not a proof.

`test/elzoo/run_engine_transcript_test.exs` exercises the read-only Run transcript
on disposable PostgreSQL (the bounds group on the in-memory Store): `nested_tree`
(a completed Run whose root `nested_callable` child starts its own: each action's
`path`, the nested starts and kept finishes, each settlement with its `by`, the
child cost 7 reaching both parents, the root finish with actual 0 and the terminal
entry, in commit order with the test clock's times), `ask_paused` (the `:ask`
authorization with its policy identity and no settlement), `unknown_and_attempt_closed`
(an Effect made unknown by a restart settles `unknown` with actual `:unknown`; a
change of Attempt closes a sent tool call and a waiting person ask with
`by: :run_view` and `reason: nil`), `outside_event_wait` (a native v2 wait: its
action, the outside-event input and its settlement), `gate_denial` (a denied
action has the deny verdict and its refusal reason and no action entry; an engine
refusal committed after another slot's deadline settles both in one record, and
only the refused slot has a reason), `earlier_run` (a Unit holding an earlier Run,
with a late input of that Run committed after the new configure, gives only the
new Run's entries), `scope_limits_reader` (wrong tenant, principal or Run, malformed
limits and no reader fail with no Run-owner status call and no Store read),
`later_actual` (a nested parent settled `expired` with no actual gets an `:actual`
entry from the later `:nested_actual` record when its child's tool cost arrives),
`expired_before_its_own_outcome` (local work whose timeout outcome is committed
after its deadline settles `expired` by that record with no reason, not the
late outcome's `local_lost`),
`read_bounds` (exact limits succeed, one record or one byte less is `read_limit`,
an unavailable Store is `unavailable`, pruned history is `history`) and `read_only`
(Unit, Run-owner and evidence heads and every gate, clock, binding and pattern
counter are unchanged across two reads, and the reads are equal). Temporary edits
are negative controls: a `path` without the link to the enclosing parent
(`nested_tree` fails), entries from sequence 1 regardless of the configured Run
(`earlier_run` fails), the configure check kept but a protocol record of another
Run not filtered (`earlier_run` fails), no `:actual` entry (`later_actual`
fails) and the reason taken without the own-effect check
(`expired_before_its_own_outcome` fails). Listed finite scenarios, not a proof.

`test/elzoo/run_engine_failed_finish_test.exs` exercises a root finish that names
no action on disposable PostgreSQL (the damage cases on the in-memory Store):
`null_source_fails_the_run` (`"action_id": null` beside a completed action, no
`action_id` key, and a text payload, each under a finish schema that admits it,
end the Run `failed`: `status/1` is terminal `failed`; the owner holds reason
`"pattern"` and a reference to an evidence row of exactly the four keys naming
the finish; `result/3` gives `{:failed, record}` with the finish's schema and
payload, twice, calling no gate, clock, pattern or schema check and changing no
row; the journal holds one `:finish` record with no source and no
`completion_evidence` refusal; the transcript settles the finish `completed` by
`:finish` at that record's time with actual 0, before the terminal entry; the root
Budget keeps only the other actions' actuals; the text-payload Run reads the same
after a restart; a nested finish with a text payload still completes its parent
and fails no Run), `named_source_is_unchanged` (after gate allow, admission and
authorization, a root finish naming a missing action, a gate-denied action or a
waiting ask is refused `completion_evidence` with actual 0, no evidence row,
`{:pending, :not_completed}`, and the Run stays open after a later input),
`failed_run_owner_commands` (a different `:complete` of the failed Run is
`terminal_conflict`, the exact one `{:unchanged, :duplicate, revision}`),
`plain_owner_failure` (an owner failure with reason `"pattern"` and a valid
evidence row but no root failure in the history is `{:terminal, :failed}`, also
after the engine takes the terminal view; one in an Attempt that the host began on
the owner alone is `{:error, :history}` until the engine takes it),
`failed_result_fails_closed` (a referenced row with another Run, Attempt,
operation or action ID, or a fifth key, is `completion_mismatch`; a damaged digest
is `history`, and so is the row moved to another stream with its digest made
valid; an owner reference to an equal row in another stream, to another action's
row, or no reference is `completion_mismatch`; for a plain and a journaled
failure, exact limits read, one record or byte less is `read_limit`, a damaged row,
a raised low-water or an unpaired tail is `history` and an unavailable Store is
`unavailable`; the failure record changed to name the completed action, its digest
made valid, is `history` in v1 and v2; a request frame whose finish payload `1`
became `1.0` before the failure record, its digest made valid, is `history`; after
a new Attempt begun on the owner while the engine was down and a later plain
failure of it (`{:terminal, :failed}`), the Run view that dropped the older failure
changed to name the older Attempt, its digest made valid and its recorded state
left, is `history` in v1 and v2),
`crash_before_the_owner_command` (the engine killed at its owner command after the
failure and its evidence row: the restart appends an equal row, the owner stream
holds one terminal record naming it, the journal one failure record, and
`result/3` reads the named row: an altered unreferenced row changes nothing, an
altered named row is `completion_mismatch`; the restarts change no record. A new
Attempt begun on the owner before the restart, and one begun between the evidence
row and the owner command, which the owner answers `stale`, leave the Run open in
the new Attempt with no failure pending, no terminal owner record and no other
evidence row, its wake reaches the root and the next request completes; a later
plain failure of the new Attempt is `{:terminal, :failed}`. A restart past the Run
deadline while local work runs, whose recorded loss makes the lifecycle ask for
`out_of_time`, still completes the owner `:failed` with reason `"pattern"`, naming
the retried row, and reads `{:failed, record}`, in v1 and v2; from the crashed
state, the fold of a later wake past the deadline, a cancel and a wake at the
request cap each keep the failure pending) and
`native_v2_failed_finish` (a v2 Run failed this way reads through the v2 replay
validation, `event_waits/3` and `transcript/3`, also after a restart, with no new
record). Temporary edits are negative controls: the old dispatch rule (every
failure test fails), a failed Run for every root finish without a completed source
(the `named_source_is_unchanged` tests fail), `{:terminal, :failed}` with no
history read, a reader error taken as a plain failure, the evidence row not read,
the owner's reason trusted (`plain_owner_failure` fails), the first evidence row
read instead of the named one (`crash_before_the_owner_command` fails), reason
`"engine"`, no evidence row for `:failed`, the replayed fold skipping the failure
record (the reads give `history`, v1 and v2), the history read without its check
against the owner's Run, operation and Attempt (the test of the Attempt begun on
the owner alone gets `{:terminal, :failed}`), the old payload read that raises
(the text-payload test fails: the engine process exits), the Run view that keeps
a pending failure at a change of Attempt (both new-Attempt tests fail), the owner
command that takes the owner's current Attempt (the engine halts with
`terminal_commit_pending`), the reader that also takes an older Attempt's failure
(`completion_mismatch`), no check of the steps into a pending failure (v1 gives
`{:terminal, :failed}`), no replay of the steps out of one (v1 gives
`{:terminal, :failed}` for the changed Run view; v2 alone still gives `history`
from its own replay), a lifecycle stop that replaces a pending failure (the
restart past the deadline ends the Run `:out_of_time`; the fold keeps
`out_of_time`), loose equality of the admitted and the request-frame action
(`{:failed, record}` with payload `1.0`) and the evidence row read without its
stream check (the moved row gives `{:failed, record}`). Listed finite scenarios,
not a proof.

`test/elzoo/run_engine_stop_attempt_test.exs` exercises the binding of a pending stop
to its Attempt (ELZ-430) on disposable PostgreSQL (history changes on the in-memory
Store), for seven sources of a stop: a root finish naming a completed action
(`:completed`), a root finish naming no action (`:failed`), a cancel while local work
runs (`:cancelled`), a wake past the Run deadline and a wake at the pause deadline of a
paused Run with the Run deadline ahead (`:out_of_time`), and a local-work outcome that
spends a monetary Budget of 1 and a wake at request cap 1 (`:out_of_budget`,
`budget_rule: :finish`). Each source has three cuts behind an owner seam:
`crash_before_the_owner_command` (the engine killed at its `complete` command after
the stop and, for a completion or failure, its evidence row; the host begins Attempt
`second` on the owner; the restart), `stale_answer_then_crash` (the host begins
`second` at the engine's revision read for the command, the real owner answers the
command, which names the stop's Attempt, `{:unchanged, :stale, revision}` at its
current revision, and the engine is killed at the status read that follows, before it
journals the new Run view, and restarts) and `stale_answer_syncs` (the same answer
with no kill: the engine takes the new Run view itself). In each, the Run is open in
`second` with no stop, completion or cancel record of the older Attempt pending, the
owner holds no terminal record, the evidence rows are the one row of a completion or
failure (naming Attempt `attempt`) or none, `result/3` is `{:pending,
:not_completed}`, and a wake of `second` reaches the root (completion, failure,
cancel, older pause deadline) or asks for the stop again under the unchanged limit,
which the owner records for `second` (`:out_of_time` and `:out_of_budget` with reason
`"engine"`, `:out_of_budget` with reason `"request_cap"`), with no other evidence row.

`legacy_stale_stop` builds the journals that the fold before ELZ-430 left, each
recorded state asserted to be exactly that fold's step: the engine killed at its
owner command, Attempt `second` begun on the owner, and the Run view of `second`
journaled keeping the older stop, the owner revision equal to the recorded one.
Proven older by the state: a kept cancel and a kept completion are dropped at the
start, in v1 and v2, by one `:stale_stop` record naming the stop and Attempt
`attempt`, with no new Run view, no owner command and no other evidence row;
`transcript/3` reads, and a wake of `second` reaches the root. Proven older by the
journal: a kept `out_of_budget` of a spent Budget, with the restart past the Run
deadline, is dropped and the wake of `second` asks for `out_of_time`, which the
owner records for `second`; a kept Run deadline, pause deadline and request cap are
dropped and `second`'s own wake decides. Proven by the journal: a kept cancel whose
state lost the Attempt of its record is `attempt`'s by its cancel step, and an
`out_of_time` that `second`'s own wake set in place of a kept stop is `second`'s,
which the owner records. Proven current: a committed timeout is delivered with the
clock set back before the deadline, and a completion that the earlier fold kept
through a timely `:pause` wake at request cap 2 (that fold also stopped the charge)
is delivered as committed (`:completed`, reason `"request_cap"`), with the v2
transcript, `event_waits/3` and `result/3` read. Refused
(`{:error, :stop_origin_unknown}`, no new row, no evidence row, no owner command): a
cancel, then a wake past the Run deadline that set `out_of_time` in its place; a
completion, then a wake at the request cap that set `out_of_budget` and stopped the
charge; a completion, then a wake past the deadline; a Run view whose state holds a
stop that the state before it did not. The refusal stays after owner changes that
are neither a new Attempt nor an outcome (another Run's create, a lease renewal and
a child attached to this Run); after the host cancels the Run on the owner, the next
start takes the terminal view (`:cancelled`, the owner's own record; `result/3` and
`transcript/3` read), and after it begins `second`, the next start is open in
`second`, whose wake past the deadline asks for `out_of_time`, with no `:stale_stop`
record and no evidence row. A replacement Unit whose journal holds the refused cut
halts the engine `:stop_origin_unknown` with no write.

`pending_stop_replay`: with `second` open after a completion or a cancel, the Run
view of `second` changed to name `attempt` is `history` for `transcript/3` in v1 and
v2, and its recorded state changed to keep the older stop (exactly the earlier
fold's step, and not this fold's) reads in v1 and v2; after a completed and a failed
Run, the state recorded after the terminal Run view changed to keep the stop pending
is `history` for `transcript/3`, `event_waits/3` and `result/3` in v1 and v2, and
so is that state with only its lifecycle outcome changed to `:cancelled` (v1) or
only its Run revision changed to an equal float (v2); a `:stale_stop` record changed
to name another Attempt, whose fold drops the same stop, is `history`; a
cancellation's terminal view recorded as before ELZ-215, which left a waiting ask
open, reads in v1 (`transcript/3` with its terminal entry and no settlement of the
ask, `event_waits/3`, and `{:terminal, :cancelled}`); and the state after a
completed Run's restart past the Run deadline with local work running changed to
hold `out_of_time` in place of the pending completion, as the earlier fold recorded
it, reads in v1 and v2, `result/3` included.

`completion_by_its_finish_record`: a root finish held for Approval, settled by its
correlated outcome and named as the source of another root finish, completes the
Run: the owner records `:completed` (reason `"engine"`) and `result/3` gives the
held finish's action. `losing_cancel_keeps_the_work`, through the public
`control/4`: the outcome of a Resource open, which the control's `current/1` reads
first, makes the root ask over request cap 1; the request-cap stop wins
(`out_of_budget`, reason `"request_cap"`), the cancel records no cancel, and the
retained local work `slow` keeps running, its task alive, and settles `completed`.

`first_stop_wins`, in v1 and v2: a completion pending after a crash at the owner
command while local work runs is recorded by the owner (`:completed`, naming the
retried row; `result/3` gives the completion) after a restart past the Run deadline
whose recorded loss makes the lifecycle ask for `out_of_time`, and from the crashed
state the fold of a wake past the deadline, a cancel and a wake at the request cap each
keeps it with no charge stop or cancel record (the local work still runs after the
cancel and the wake at the cap); a cancel that settled running local work in its own
step stays pending through the fold of a wake past the deadline and a wake at the
request cap with no charge stop, and the restart past the deadline records
`:cancelled`. `losing_request_leaves_no_trace`: with `:completed`, `:cancelled` and
`:failed` pending after a crash at the owner command (local work `slow` running, closed
by a pending cancel; asks `ask` and `pay` waiting), each of a wake past the Run
deadline, a cancel, an answer of `pay` whose actual 5 spends the Budget of 5 and a wake
at the request cap is journaled as the engine journals an input. The restart completes
the owner with the pending stop and its own reason (`"engine"`, `"pattern"` for a
failure), the end of the Run settles `slow`, `ask` and `pay` with no charge stop, and
the step kept the stop, its completion and its cancel record and closed no local work.

Temporary edits were negative controls, each run on this revision against this file
and `test/elzoo/run_engine_read_failure_test.exs` and reverted (counts on the 68
tests before the test of owner changes that are not a new Attempt was added; the
skip on any revision change on all 69): recovery that keeps a proven older limit
stop (1 test fails); recovery that drops a current `out_of_time` when the clock
reads before the deadline (1); the stop decided after the Run view and the loss
records (2: both refusals with a moved owner revision write first); no owner check
before the proof (1: the start after the host's end of the Run is refused again); a
skip on any change of the owner's revision (3: every refusal with a moved revision
starts); a replacement never marked (5: the three replaced-stop refusals start, and
both refusal-order tests); the owner's `:completed` taken from the source slot's
kind (1: `:failed`); a cancel control that cancels every task (1: `slow` settles by
the task's loss); v2 validation with the current fold only (4) and v1 replay with
the current fold only (6); the three stop facts compared, with `==` in v2, in place
of the whole state with `===` (2: both tampers read); a `:stale_stop` without its
proof (1); recovery that never reads the journal (11, `stop_proof_read_fails`
included); the drop of only a pending failure at a change of Attempt (24); the owner
command at the owner's current Attempt (14: every stale-answer test);
`install_lifecycle/3` replacing a pending stop other than a failure (11); and a
losing wake at the request cap that stops the charge (6). Listed finite scenarios,
not a proof.

`test/elzoo/run_engine_deadlines_test.exs` exercises `deadlines/1` in four groups
on disposable PostgreSQL, each read checked against the `phase` of `status/1`.
`deadlines_follow_the_lifecycle`: a new Run reads the start option and no pause
deadline; a `pause` control gives its `pause_deadline`, a second `pause` keeps
it, and a later `continue` gives its new Run deadline and no pause deadline; an
internal pause under `budget_rule: :pause` (the first excess at request cap 1, in
the step of a local-work outcome) gives the `pause_deadline` that the context
callback gave for that outcome record, not the start input's; a `continue` with
another Run deadline that is applied while an exhausted monetary Budget keeps the
Run paused leaves the read at the old Run deadline and the pause deadline.
`deadlines_after_restart`: after a `continue`, and separately after an internal
pause, a restart of the engine and its Unit on the same journal with the original
start options reads the committed values, also with the context callback since
changed. `deadlines_at_the_end`: a wake at the Run deadline that a `continue` set
(not the start option), and a wake at the pause deadline of a paused Run, end the
Run `:out_of_time`; the read keeps the Run deadline and gives no pause deadline.
`deadlines_wait_for_the_engine`: a read queued while the gate of an input blocks
has no reply 5,500 ms after it is queued and then gives the `:waiting` phase of
the committed input, equal to `status/1`. Four temporary negative controls each
made named tests fail and were reverted: the start option read instead of the
committed Run deadline, the pause deadline read in every phase, the pause deadline
read from a new context sample, and the 5,000 ms default call limit. Listed
finite scenarios, not a proof.

`test/elzoo/run_engine_read_failure_test.exs` exercises journal lookups that
cannot read the whole history on disposable PostgreSQL, through a Store that
only the engine reads through and that replaces one scan read on request (the
Unit writes through the plain Store): `read_fault_store` (each fault gives, for
one read, `{:error, :unavailable}`, `{:error, :malformed}` from a gap reply,
`{:error, {:pruned, 1}}` or a page whose head has low-water 1),
`input_lookup_fails` (for each fault `input/4` returns `{:error, :unavailable}`,
the journal gains only the Run view that `current/1` committed before the
lookup, the engine runs with `reconciliation: nil`, and the same input then
applies), `control_lookup_fails` (for each fault pause, continue and cancel each
return `{:error, :unavailable}` with the journal unchanged, and each applies when
sent again), `cancel_halts_after_commit` (for each fault the cancel commits,
the read of the winner of the next Run view in its drain fails, the control
returns `{:error, :cancel_unknown}`, the cancel record stays and the engine is
halted `:unavailable`), `local_work_delivery_halts` (for each fault a v2
local-work outcome whose fenced lookup reads and whose Run-view winner read in
`current/1` fails leaves the engine halted `:unavailable` with the outcome not
committed), `local_work_delivery_without_halt` (a v2 local-work outcome
delivered after the Unit was stopped: its `current/1` recovers a replacement
Unit, settles the running local work `local_restart` and ends at a `wait_event`
whose source head fails, with no halt; the outcome is not committed, and the next
input runs that recovery again and is not committed), `fresh_event_lookup_fails`
(the v2 source read arms the fault, so it meets the lookup after the read: for
each fault the outside event returns
`{:error, :unavailable}`, the journal gains only the Run view that `current/1`
committed after the read and there is no halt; then the event commits, the
winner read in its drain fails, and the same reply comes with the halt
`:unavailable`, after which a paired replay is `{:ok, :unchanged}`, a changed
one `{:error, :input_id_conflict}`, the halt stays and the source is not read
again), `settled_retry_lookup_fails` (a refused outcome sent again after
its slot settled and its request left the state: the lookup of its ID reads, the
lookup of its admission fails, and the retry returns `{:error, :unavailable}`
for each fault with the journal unchanged; then the same retry on the same
engine is `{:ok, :duplicate}`), `winner_read_fails` (the ID of the engine's next
Run view already holds another Run view: a failed read of the winner halts with
`:unavailable` for each fault, also at the next call, and writes nothing; read,
the winner is taken and the input applies), `winner_contradicts` (the whole
page and head that the Store gave just before the winner was committed, a
protocol input under the Run view's ID, a gate record naming another request
and an admission naming another occurrence each halt with `:integrity_failure`)
and `stop_proof_read_fails` (ELZ-430: a start whose pending cancel the journal must
prove gives `{:error, :unavailable}` for each fault, with no write and no owner
command; the next start proves the cancel and the owner records `:cancelled`).
Temporary edits are negative controls: the bare match restored (seven tests
fail: the engine process exits, or the local-work delivery leaves no halt), the
control error left to the existing else clause (`{:error, :invalid_control}`),
the cancel error left to `:cancel_unknown` (`control_lookup_fails` fails), the
cancel's `halted: nil` guard removed (`cancel_halts_after_commit` gets
`{:error, :unavailable}`), the halted state of a local-work delivery dropped
(`local_work_delivery_halts` sees no halt), the state that `current/1` returns
kept for a delivery error without a halt (`local_work_delivery_without_halt`:
the next input is committed), the failed admission read taken as
no admission, in its lookup or in the recheck (`{:error, :input_id_conflict}`),
a failed winner read taken as `:integrity_failure`, and a page whose head has
low-water above zero taken as whole (seven tests fail: the `:low_water` case
applies, is a duplicate, or leaves no halt). Listed finite scenarios, not a proof.

`test/elzoo/run_engine_test.exs` exercises renewals of the Run owner (ELZ-429) on
disposable PostgreSQL. A second test of
`retained_slot_closes_after_its_deadline (one step)` renews the owner through
`RunApprovalRelease.renew/2` before the child's result at 15,000 ms: the parent
gets the child amount 5 in the same step, the child Budget commits 5, no
`:nested_actual` and no outcome record is written, and the result's own record is
the one record that the input adds. The group `renewal_is_not_a_transition` has seven
tests. `several renewals between the commands of a live Run`: an ASK tool call and a
finish that names it, with two renewals after the start, the request, the consent
and the result, give the journal (record kinds, occurrences, actuals, times and
phases) of the same Run without renewals and the same kinds of owner Run records in
the same order (not equal records: the terminal record holds its completion
revision, which the renewals move); every `:run_view` follows an owner record that
is not a renewal, and the Run is completed.
`an Approval request and its evidence among renewals`: the request, with the intent
that the dispatch path binds, gets one `:run_view` at the engine's next read after
the renewals, the evidence one at its own revision right after the command, a wake
after renewals alone none, and the journal and views equal those without renewals
but for the revision read. `a release and a re-claim`: after renewals, a released
and re-claimed lease and a new owner, the reopened engine journals one `:run_view`
at the claim revision with unchanged facts, and a later wake none.
`a replacement owner after renewals`: the replacement on the renewed token reports
the revision of the last Run record before the renewals as `renewed_since`, the
reopened engine adds no row, the replacement refuses `conflict` to commands that
name the revision before the renewals or between them, and the engine's consent
applies on a freshly read revision with its `:run_view` at the evidence revision.
`a new Attempt after renewals` and `an outcome after renewals`: a `begin_attempt` or
a completion on the owner between renewals is journaled at the next wake, with the
slots, Budgets and journal of the same change without renewals (the dispatched tool
call `unknown`, no actual, its reservation held). `an owner view without
renewed_since`: through a test owner whose `status/2` replies lack the field, a
renewal before the child's result of the one-step case gives, as before ELZ-429, a
`:run_view` at the renewed revision that closes the parent, then the result's record
and a `:nested_actual` record (parent actual 5); after one more renewal a restart of
the engine against the owner itself replays that journal to an equal state with no
new row, and a wake then adds only its own record. Four temporary negative controls
each made named tests fail and were reverted: a `:run_view` committed for a
renewal-only change (the one-step test with a renewal fails: a `nested_actual`
record is written; so do the group's tests of several renewals, of the Approval
request and evidence, of the replacement owner and of the owner view without
`renewed_since`, at its restart), the owner's `renewed_since` set from its startup
floor (the replacement test fails: the reopened engine commits a record, before its
owner-status check), `renewed_since` counted from Run records only (the release test
fails: no `:run_view` after recovery, before its owner-status check) and the
suppression without its boundary check (the document publication test, both
one-step tests and every test of the group but the one without `renewed_since`
fail). Listed finite scenarios, not a proof.

## Changes

- ELZ-416 (2026-11-26): the README names the current platform pins, Elixir
  1.20.5 and OTP 29.1.3 (before 1.20.4 and 29.1.2). No code or API change.
- ELZ-420 (2026-11-26): breaking. A root `finish` whose payload names no action
  (`"action_id": null`, no `action_id` key, or a payload that is not an object)
  ends the Run `:failed` after its checks, where it was refused
  `completion_evidence` and the Run stayed open (and a payload that is not an
  object stopped the engine process). Its `:finish` record has no source and
  settles the finish slot `completed` with the finish's own schema and payload at
  actual 0; the engine appends a completion evidence row naming the finish and its
  Attempt and completes the Run owner `:failed` for that Attempt with reason
  `"pattern"`; a lifecycle stop asked for while the failure is pending (the Run
  deadline, also at a restart, a cancel or a Budget stop) does not replace it, and
  a change of Attempt before the owner records it drops the failure, so a new
  Attempt is never failed by an older finish. `result/3` for an
  owner `:failed` now reads the history: `{:failed, record}` (the keys of the
  completed record, the finish payload) for this Run's root failure,
  `{:terminal, :failed}` for a verified history without one, and a bounded error
  where the history cannot show which, where it gave `{:terminal, :failed}` with
  no read before. A host that began an Attempt directly on the owner, bypassing
  the engine, and then failed the Run reads `{:error, :history}` instead of
  `{:terminal, :failed}` until the engine takes that Attempt. A root finish that
  names an action, a nested finish, and `:cancelled`, `:out_of_budget` and
  `:out_of_time` are unchanged. How to move: a pattern ends its Run as failed with
  a finish that names no action, with no host cancel; a caller of `result/3`
  matches `{:failed, record}`; a host that fails the owner itself sends the engine
  an input of the current Attempt first. Recorded journals replay as recorded.
- ELZ-433 (2026-11-27): breaking. A journal lookup of the engine that cannot read
  the whole history (an unavailable or malformed read, a pruned history, or a page
  whose head has low-water above zero) no longer stops the engine process with a
  match error in the middle of a call. When it is the lookup of the ID of an
  input or control, or of the admission of a settled occurrence whose outcome is
  sent again, `input/4` and `control/4` return `{:error, :unavailable}` (control
  never `:invalid_control` or `:cancel_unknown` for it), the failed call adds no
  record and the engine goes on; when it is the read of the winner after the Unit
  refuses an internal record with `:input_id_conflict`, the engine halts with
  `:unavailable`. A complete scan with no winner still halts with
  `:integrity_failure`. A v2 local-work outcome whose delivery meets a halt in
  `current/1` is not committed and now leaves the engine halted, where the halt
  was dropped before. A v2 outside event can now return `{:error, :unavailable}`
  (its lookup after the source read). How to move: a caller that gets
  `{:error, :unavailable}` reads `reconciliation` in `status/1`: `nil` means the
  failed call added no new record for the submitted ID (an earlier record of the ID stays), and the caller
  sends the same ID again later, never another, as after an exit of the call;
  `:unavailable` is a storage halt, and the host restarts the engine. No stored
  format changes; recorded journals replay as recorded.
- ELZ-423 (2026-11-27): a new read, `deadlines/1`, gives the committed Run
  deadline and, while paused, the committed pause deadline with the phase of
  `status/1`, in one call to the engine process with the same 60,000 ms limit, from
  the recovered state after a restart. Not breaking: `status/1`, the control
  state, the journal format and the fingerprint are unchanged, so recorded
  journals replay as recorded and no move is needed.
- ELZ-429 (2026-11-27): breaking for a host that renews the Run owner through
  `RunApprovalRelease.renew/2` (ELZ-422). The engine took every change of the
  owner's revision as a Run transition, so a renewal added a `:run_view` record whose
  fold settled what was due at its time: a retained parent past its deadline closed
  before a child's result was folded, and a separate `:nested_actual` record
  followed. Now it reads the owner's new `renewed_since` and commits no record when
  only renewals came after its recorded revision (Run views); every other change is
  journaled as before, as is every change when the owner view has no
  `renewed_since`. Histories without renewals keep their journal, transcripts,
  results, frozen fixtures and cold-recovery results; the control state, the journal
  format and the fingerprint are unchanged, and journals recorded before, with their
  `:run_view` records of renewals, replay as recorded. How to move: nothing for a
  host that does not renew; a host that renews takes `workflow/run-approval-release`
  with `renewed_since` (ELZ-429) and expects no `:run_view` record, and nothing that
  its fold settled, for an interval of renewals alone.
- ELZ-430 (2026-11-27): breaking. Every pending stop is bound to the Attempt that
  produced it, as ELZ-420 bound a root failure. The owner's `complete` command of every
  stop now names the engine's recorded Attempt, where it named the owner's current
  Attempt, read just before the command; the `:completed` evidence row already named
  the engine's recorded Attempt. Before, an Attempt that a host began after that read
  left the command naming the older one: the owner answered it `stale` (it checks the
  Attempt before the revision), and the engine halted `terminal_commit_pending` for
  every stop but a failure. An Attempt begun before that read, or while the engine was
  down, was ended by the older stop with no run of it: a lifecycle stop at the next
  command; a completion once a restart had taken the new Attempt's Run view, with the
  older Attempt's source, which `result/3` could refuse `completion_mismatch` (before
  such a restart the owner refused the older Attempt's evidence row and the engine
  halted). Now the owner's answer `stale` makes the engine take the new Run view, and a
  change of Attempt before the owner records the stop drops it, with the completion and
  the closed generation of a finish and the cancel record of the Attempt that is left,
  where only a failure was dropped. A start, and a replacement Unit, decide a pending
  stop before any write: an owner Run view that is terminal or has begun an Attempt
  after the engine's recorded one is taken (its fold ends the Run or drops the stop);
  otherwise the stop is taken only on proof of the Attempt that produced it, from the
  state's completion slot or the journaled step that set it. A stop of the recorded
  Attempt is delivered as committed (no clock, Budget or cap is read again); a stop of
  an older Attempt (a journal recorded before can keep one at a change) is dropped by
  a new `:stale_stop` record, which names the stop and its Attempt, with no owner
  command; a stop that nothing proves (one set in place of a pending stop of the same
  Attempt, or by a Run view) gives `{:error, :stop_origin_unknown}`, and a journal
  that cannot be read whole `:unavailable`, with no write and no owner command. The
  owner's `:completed` or `:failed` comes from the stop's `:finish` record. The first
  pending stop wins: a later lifecycle stop (the Run deadline, also at a restart past
  it, a cancel, a Budget or request-cap stop) no longer replaces a pending completion
  or lifecycle stop, and leaves no trace (no charge stop, cancel record, closed local
  work or cancelled task: a `cancel` control cancels the tasks of only the local work
  that its committed cancel closed), so the pending stop decides the owner's reason
  and what the end of the Run closes. A read of the history (the read of a
  `completed` or `failed` Run, `event_waits/3`, `transcript/3`) now replays, also in
  v1, every record that changes the pending stop, its completion or the Attempt and
  every Run view that ends the Run or changes the Attempt while a stop is pending, and
  gives `{:error, :history}` unless the replay gives exactly (`===`) the recorded
  state under this fold or the fold before ELZ-430; a `:stale_stop` record must also
  name the Attempt that the history proves. A completion that the earlier fold kept
  through a `:pause` wake at the request cap that stopped the charge is delivered as
  committed, with reason `"request_cap"`. How to move: before taking this revision,
  let each engine with a pending stop deliver it under the earlier revision, or end
  that Run on its owner; a host that gets `{:error, :stop_origin_unknown}` ends the
  Run or begins a new Attempt on the owner, then starts the engine again. Once this
  revision writes a `:stale_stop` record, the earlier revision cannot fold that
  journal (rollback cut). Histories without a stale or replaced pending stop keep
  their journal, transcripts, frozen fixtures and cold-recovery results; the control
  state and the fingerprint are unchanged ("Limits of the stop bound to its
  Attempt").
