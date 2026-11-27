# assembly/run-host

`Elzoo.RunHost` is a supervised host for the `assembly/run-engine` Runs of one node,
for one profile. It owns, once, what each consumer of the engine built for itself:
the Unit directory, the Run owner with its lease, the evidence Writer, AsyncWork, the
EffectIntent startup bindings, the AI text bindings with their outcome route,
recovery with predecessor fencing, deadline wakes, lease renewal and the confirmed
teardown of every per-Run process. Apache-2.0.

## Profile

- Model calls are text-only calls of `integration/ai-text`: the host configures no
  artifact reader, so a request with an image part is refused before an intent
  exists (AI model calls, below).
- The spec's Effect bindings are the host's AI text bindings (`ai`). The spec's own
  `bindings` may hold only `finish`, `ask_person` and `nested_callable`: a spec with
  any other kind (`tool_call`, `local_work`, a Resource kind, `wait_event`, or its
  own `model_call`) is refused at start with `{:error, :outside_profile}`. The engine
  runs protocol version 1 with no `expiry_reports` or `messages` option.
- So no asynchronous engine input bypasses the host: every input reaches the engine
  through the Run's worker (caller inputs and controls, sink outcomes, wakes), and the
  host reads the deadlines, the current Attempt and the terminal phase after each of
  them, with no periodic resampling.
- ASK model calls are outside the profile: `control/5` forwards no Approval control
  (`:approval_evidence` gives `{:error, :outside_profile}`), so such a call waits
  until the Run ends. Every other control, `:begin_attempt` included, is forwarded.

## Start

`Elzoo.RunHost.start_link(opts)` starts one host; one per node is the intended use.
Required options, with no defaults:

| Option | Value |
| --- | --- |
| `owner_id` | this node's lease owner attribution, 1..200 bytes |
| `max_runs` | positive integer: the reservation table admits a Run from its reservation (in `start_run/3` or `wake/2`) through its confirmed teardown; the Unit DynamicSupervisor has `max_children: max_runs` as a separate ceiling on live Units, and a sleeping Unit keeps its Run's reservation |
| `idle_ms` | the idle sleep of the host's `DynamicUnits` directory, 1..4,294,967,295 |
| `unit_store`, `run_store`, `evidence_store`, `intent_store`, `activation_store` | Store views of one namespace, each with the fold and limits of its owner (below) |
| `lease` | an `Elzoo.Lease` over `run_store`: `clock: :store` on PostgreSQL; on Memory one manual clock and this one backend for the whole host |
| `clock` | the engine's trusted zero-arity Unix-millisecond clock, also the EffectIntent clock (`unix-ms`) |
| `lease_ttl_ms` | 1..86,400,000 |
| `spec` | `fn run_ref -> {:ok, spec} \| {:error, reason} end`, building a Run's spec again from the caller's durable facts |

Optional: `fencing_proof` (`fn run_ref -> :fenced \| :unproven end`, Recovery),
`on_terminal` (`fn run_ref, outcome -> _ end`), `on_lost` (`fn run_ref, reason -> _
end`), `allow_volatile` (`true` passes EffectIntent's explicit `allow_volatile: true`
for a Memory namespace) and `name`. Anything else, a list that is not a keyword list,
or a missing or out-of-range option is `{:error, :invalid_options}`.

The host starts two Registries (the Unit directory's and one for the engine names: an
engine is the AsyncWork owner of its Run, which takes a Registry name), its
dedicated, initially empty Unit DynamicSupervisor, the `DynamicUnits` directory and a
Task.Supervisor for its renewals, expiry checks, teardowns and callbacks. The
Registries are named after `name`, or after `owner_id` without one, so that a host
restarted under its supervisor takes the same names (two hosts in one VM need distinct
names). When any of these processes exits, the host stops with that reason and, in
its `terminate/2`, stops every process of every Run with its group leader, then its
infrastructure. A host that is killed runs no `terminate/2`: its exit reaches each
Run's worker through their link and ends it with the host's own reason, the processes
that the worker started end with it (or with the host's Registries, whichever comes
first), the Unit supervisor ends with its Units and the task supervisor with its
callbacks, but an EffectIntent owner that the engine started unlinked can outlive the
host. The supervisor then starts the subtree again, and each Run comes back through
`wake/2` and its predecessor check (Recovery).

The views: PostgreSQL views share the Repo and prefix (the `integration/sql` tables
of migration version 1), Memory views share one Memory process. A view checks the
kinds, versions and limits of its records; the owners replay with their own folds,
and the engine replays the Unit view with that view's fold to read a sleeping Unit.

| View | Fold and limits |
| --- | --- |
| `unit_store` | `Elzoo.DurableUnit.fold/1` and `limits/1` of the engine's Unit options (`operator: {Elzoo.RunEngine, :step, %{version: 1, control: nil, slots: %{}, requests: %{}}}`, `retention_count`, `max_record_bytes: 16_777_216`, `max_checkpoint_bytes: 33_554_432`) |
| `run_store` | `Elzoo.RunApprovalRelease.fold/0` and `limits/0` |
| `evidence_store` | kind `"completion"`, version 1; `max_record_bytes: 131_072, max_batch_size: 1, max_checkpoint_bytes: 1_048_576` |
| `intent_store` | `Elzoo.EffectIntent.fold/1` of an AI binding module and `Elzoo.EffectIntent.limits/0` (every binding's fold has the same kind and version) |
| `activation_store` | `Elzoo.EffectIntent.StoreHost.fold/0` and `limits/0` |

A Memory process has one fold for all its streams, so for a full Memory host the one
namespace's fold holds the kinds of every owner (`input`, `result`, `run`, the four
lease kinds, `completion`, `intent`, `intent_host`), starts from the Unit fold's
initial value and folds `input` and `result` records with the Unit fold (other records
are kept as bytes; their owners use their own folds), and its limits are the largest
that any owner needs (`max_record_bytes: 16_777_216, max_batch_size: 4,
max_checkpoint_bytes: 33_554_432`). The evidence Writer writes into the namespace where
the Run owner reads evidence, so a completed or failed finish passes the owner's
evidence check.

**Store Need.** Every write of every view is a compare-and-set on its stream head
(the ready `integration/sql` PostgreSQL Store and the Memory Store are), and every
EffectIntent send follows its committed arm (`delivery/effect-intent`). The host
fences processes, not writes: a Store write that a predecessor submitted can still
commit after every process of that predecessor is gone, also after this host's own
confirmed teardown. Whether such a write can still commit is what the caller's
`fencing_proof` attests before an engine starts on an existing journal (Recovery); the
host claims nothing about outstanding writes beyond that attestation.

## The spec

A spec is a map with exactly these keys:

| Key | Value |
| --- | --- |
| `run_id`, `operation_id`, `attempt_id` | the stable Run and operation IDs and the first Attempt, 1..200 bytes |
| `unit` | 1..155 bytes; the Run's streams are `"unit/" <> unit` (the Unit identity and journal), `"run/" <> unit` (the Run owner's stream, the lease key, one per Run) and `"evidence/" <> unit`; with the EffectIntent streams (`"intent/"`, `"intent-host/"`) no two of them can be one stream |
| `provider_refs` | the Run's provider references (`RunApprovalRelease` `create`) |
| `tenant`, `principal` | the engine's trusted tenant and acting principal |
| `pattern`, `schemas`, `gate`, `context`, `budget`, `budget_rule`, `request_cap`, `run_deadline` | the engine's start options of the same names |
| `bindings` | the engine bindings of the profile's other kinds |
| `ai` | the AI binding descriptors: model_call schema ID to descriptor (AI model calls) |
| `retention` | the result reader's retention, which is also the Unit's `retention_count` |

## Runs

`start_run(host, run_ref, spec)` reserves a slot (`{:error, :capacity}` at `max_runs`),
claims the Run's lease key, provisions the EffectIntent startup bindings, starts the
Run owner, `create`s the Run and begins its Attempt with the spec's IDs, and starts the
evidence Writer, AsyncWork and the engine (with `result_reader`). It returns `:ok`;
starting the engine does not start the pattern (for AgentLoop the caller sends the
typed `start` through `input/5`). An interrupted start is retried by the same call with
identical IDs: the owner answers `{:unchanged, :duplicate, _}` to both commands and no
new Attempt begins (a Run that a `:begin_attempt` control already moved on keeps its
current Attempt). A retry that opens an existing Run or Unit journal passes the
predecessor check (Recovery) before any engine starts. A lease that another owner holds
gives `{:error, {:lease_refused, refusal}}` (the refusal of `Elzoo.Lease.claim/4`) and no
engine starts.

`input/5`, `control/5`, `status/2`, `deadlines/2`, `result/4` and `transcript/4` take the
host and the `run_ref` before the engine's operands and give the engine's own results;
a Run that is not live on this host gives `{:error, :not_running}`. Inputs and controls
are admitted by a sample of the lease clock taken for each of them (Leases: an expired
or lost lease gives `{:error, :lease_lost}`, a lease clock that cannot be read
`{:error, :unavailable}`), then go through the Run's worker, which serializes them with
the host's own inputs. After a control the worker reads the Run's current Attempt again
before it forwards any other input or control (AI model calls, Key); while that read
fails, they give `{:error, :unavailable}`. An engine call that ends by the engine's
call limit gives the caller the same exit. Reads go to the engine directly.

On a terminal outcome the host stops business input (`input/5` and `control/5` give
`{:error, :terminal}`) and calls `on_terminal.(run_ref, outcome)`, once per incarnation
of the Run. The engine stays live with its scoped result reader until
`reap(host, run_ref)`, which stops every per-Run process, confirms that each is gone,
releases the lease and frees the reservation, then returns `:ok`. When the release can
be confirmed neither by the Lease (`{:free, _}`) nor by a reading that shows the key
free or held by another owner, `reap/2` returns `{:error, :release_unconfirmed}` and
the Run keeps its reservation; a later `reap/2` tries the release again. A start that
fails after its claim releases the lease the same way; when that release is not
confirmed, the start's caller gets its start error and the Run keeps its reservation,
and with it the responsibility for the lease: the host tries the release again every
second until it is confirmed. A `start_run/3` or `wake/2` of the Run, also one that
was waiting on the release, takes the key over instead: the reservation is freed and
the request goes on at once. A Run that is not live gives `{:error, :not_running}`. A
terminal Run that is not reaped counts against `max_runs`.

The confirmed teardown governs the reservation, not recovery: `reap/2`, the lease release
and freeing the reservation need no attestation (no `fencing_proof` is asked), and a
fresh Run can take the freed slot at once. A start or wake that opens the reaped Run's
journal again passes the predecessor check (Recovery).

### Processes and teardown

Each Run has a group leader of its own (a process of the host that relays I/O to the
host's group leader). The Run's worker (`Elzoo.RunHost.Runner`, linked to the host)
sets it first, so every process that the Run starts, at any depth, inherits it: the
Task.Supervisor of the Run's EffectIntent tasks and AsyncWork, every task, the Run
owner, the evidence Writer, AsyncWork, the keep-alive, the engine and every
EffectIntent owner (also one that the engine started unlinked and whose activation
stayed read-only). The Unit and its Writer are the directory's, under the host's Unit
supervisor.

A teardown (reap; an exit of the worker, the keep-alive, the engine, the Run owner, the
evidence Writer, AsyncWork or the task supervisor of a live Run; a lost lease; a failed
start) runs in a host task: it kills the engine first (so it starts nothing more), then
every process whose group leader is the Run's, again until none is left (a task whose
supervisor died, or one that traps exits, included), stops the Unit through its
directory (a confirmed `:ok`) and waits until the Unit and every process that it
started are gone; last it stops the group leader and waits until it is gone. Until then
the Run keeps its reservation; an unconfirmed teardown runs again every second. A
`start_run/3` or `wake/2` of a Run that is being torn down waits for the end of the
teardown.

The Run's renewals and expiry checks (Leases) run in host tasks. A teardown waits for
one that is still running before it frees the reservation (a renewal's call ends once
the owner is stopped), so that no task of the Run outlives it, and an indeterminate
receipt that such a task brings back is still kept.

`on_terminal` and `on_lost` run as tasks of the Run, tracked by the host, and start only
for a Run that is live (or starting): once a teardown began, no callback starts. A reap
stops a callback that is still running before it frees the reservation; a callback that
calls `reap/2` for its own Run is stopped by that reap (it gets no reply, and nothing
waits on it). After a teardown that is not a reap, the reservation is freed when the
Run's callbacks have ended.

## AI model calls

An AI binding descriptor has exactly `id` and `version` (the engine binding's identity,
part of the fingerprint), `effect_class` and `proposal` (Authorization), `estimate`
(Budget units per call), `call_ms` (1..86,400,000: the call's slot and intent deadline is
the clock plus `call_ms`), `usage` (below) and `ai_text`: the options of
`Elzoo.AiText.configure/1` without `tenant`, `sink`, `artifacts` and `image_bounds`,
which the host sets (the spec's tenant, its own sink, no artifact reader). The action's
payload is the ai-text request (`elzoo/ai-text-request` version 1, AgentLoop's first
model call); the binding's result is `elzoo.ai-text.result` version 1.

- **Key.** The AI idempotency key of an action is the lowercase hex SHA-256 of the ETF
  of `{run_id, attempt_id, action_id}`: the stable Run ID, the Attempt that the engine
  committed for that action (the current Attempt when the engine admits it; the worker
  keeps it in a table that the gate and `facts/1` read, updated from `status/1` after
  every input and control; after a control it forwards no input or control until that
  read has succeeded, so no action is admitted under an Attempt that it has not
  confirmed) and the engine's non-reused action ID. The intent key is ai-text's key of
  `[tenant, provider_account, binding_id, "generate", key]`.
- **Admission.** The host's gate runs `Elzoo.AiText.admission/2` before the spec's gate.
  A refusal (`{:error, {:refused, reason}}`, for example `:unsupported_feature` for an
  image part or `:too_large`) is a gate denial with that reason: the engine records it
  before any intent exists, the action settles refused (actual 0), no intent starts and
  the provider is not called. `facts/1` repeats the admission that the gate passed, so it
  returns no admission error, and does no I/O. The EffectIntent startup bindings are
  provisioned once at the Run's start.
- **Route.** The sink of every binding sends each delivery to the Run's worker. The
  worker resolves the key to the exact Run, Attempt, action and occurrence from the
  committed `model_call` actions that `transcript/3` gives (each action's own Attempt,
  action ID, occurrence and schema ID) and the stable binding configuration, never from
  `status/1` alone, and then calls `RunEngine.input/4`. At a start or a wake the
  deliveries are held until that route is verified (read once the engine has started),
  and the start or wake is answered only then. A key that is not in the route makes the
  worker read the transcript again. A read that fails for a moment
  (`{:error, :unavailable}` or an exit) keeps the deliveries, in order, and is read again
  200 ms later; a read that cannot succeed (`:read_limit`, `:history` or another error of
  `transcript/3`) fails a start or wake with `{:error, {:route, reason}}`, also when reads
  that failed for a moment came first (the start or wake is never answered `:ok` or
  `:woken` before), and on a live Run reports each delivery that it cannot route. Once the
  route is read, each held delivery is handled by its kind: an outcome as below, a sink
  failure as one (Sink).
- **Input.** Each received outcome is one engine `action_outcome` input under the ID
  `"ai:"` and the hex SHA-256 of the ETF of `{run_id, attempt_id, occurrence}` (67 bytes
  for any action ID), with the action's own Attempt in its context. Under
  `budget_rule: :pause` the host samples the spec's trusted `context` for a
  `pause_deadline` after the clock before it first submits the input. The first
  submission fixes the frame and the whole context, that pause operand included; a retry
  (the engine's `{:error, :unavailable}` or an exit, at most 20 times, 200 ms times the
  attempt) sends them again. Only when the engine refuses the input before appending
  anything for its passed pause operand (`{:error, :pause_deadline_required}`) is a fresh
  operand taken for the next try. The worker keeps the IDs that the engine acknowledged
  (`{:ok, _}`): a later delivery of the same outcome, and a retry that was already due,
  give no input at all (also after the ID has left the Unit's retention). A context with
  no future pause deadline is outside the engine's Need: the host reports it and submits
  nothing.
- **Sink.** ai-text sends `{:outcome, attempt_id, outcome}` or `{:sink_failed,
  attempt_id}` before the intent owner commits its own settlement. The host translates
  only outcomes received at the sink. `{:sink_failed, _}` gives no input: the host
  reports it, and the slot waits for reconciliation or the end of the Run. A missing
  delivery gives no settlement.
- **Unit kept awake.** `DynamicUnits` measures idle time from directory operations, not
  from a provider call, and a Unit reopened under a model call in flight would make its
  recovery settle the call `lost_outcome`. Each Run has a keep-alive, a process of the
  Run beside its worker: every quarter of `idle_ms` it calls `DynamicUnits.start/2` for
  the Unit while the worker has an engine start, input or control in progress (an
  engine input can wait seconds, for example while the adapter loads its model catalog
  for the first model call on a node) or a model call is ready or running by the
  worker's last `status/1`. It never waits on the worker, so a worker held by an engine
  call (a long input, a transcript read) does not let the Unit sleep under a call; a Run
  with neither sleeps after `idle_ms` as any idle Unit does.

Reports are one `Logger` warning that names the Run reference and the action, key or
input ID, never a payload: a sink failure, an outcome with no route or that cannot be
routed, no future pause deadline, and an input that the engine refused or did not take.

### Translation and `elzoo.ai-text.result` version 1

| Outcome at the sink | `outcome` | `dispatch` | `actual` | Payload |
| --- | --- | --- | --- | --- |
| `{:completed, body}` within the bound | `"completed"` | `"dispatched"` | the usage conversion, or none | completed view |
| `{:completed, body}` whose completed view is over the engine's payload bound (65,536 bytes of compact JSON or 32 levels) | `"refused"` | `"dispatched"` | none | refusal view, reason `too_large` |
| `{:refused, reason, meta}`, reason `credentials_unavailable` or `input_unavailable` (sent nothing) | `"refused"` | `"not_dispatched"` | 0 | refusal view |
| `{:refused, reason, meta}`, any other reason | `"refused"` | `"dispatched"` | none | refusal view |
| `{:unknown, :malformed_response}` (always reached the provider) | `"unknown"` | `"dispatched"` | none | refusal view |
| `{:unknown, reason}`, `timeout`, `transport` or `provider_error` | `"unknown"` | `"unknown"` | none | refusal view |
| `{:sink_failed, _}` | no input | | | |

A delivered `:provider_error` does not prove dispatch (a provider error and an adapter
error both deliver it), and the host never infers zero or a dispatch that the outcome
does not establish. An unknown outcome has no actual, so its reservation stays reserved.

- The completed view is exactly `{"content": text, "finish": finish, "tool_proposals":
  [proposal]}`: `finish` is `"stop"`, `"length"`, `"tool_calls"`, `"content_filter"`,
  `"refusal"` or `{"other": text}`, and a proposal is exactly `{"id", "name",
  "arguments", "malformed"}` (`malformed` null or the tag as text), the form that
  AgentLoop reads. The structured output and the usage are not in it.
- **The bound.** ai-text and the Anthropic provider bound no response content in bytes
  (the provider keeps up to 4 MiB of body), while the engine checks every outcome payload
  against its result schema with `core/payload-schema`: at most 65,536 bytes of compact
  JSON and 32 levels. A completed view over that bound (more than 65,536 bytes or more
  than 32 levels, checked with the same function and the spec's schema of
  `elzoo.ai-text.result` version 1 before it is submitted) cannot be an engine input and
  is never truncated: it is submitted as `"refused"` with the refusal view of reason
  `too_large`, `dispatch` `"dispatched"` (the call reached the provider) and no `actual`,
  so its reservation stays reserved.
- The refusal view is exactly `{"reason": text, "retry_after": seconds | null,
  "candidate": null}`: the reason of the outcome, the provider's `retry_after` for a
  refusal (null for an unknown) and no routing candidate.
- The usage conversion is the descriptor's trusted `usage` callback: for a completed body
  whose `usage` (an `Elzoo.AiModel.Usage` value) has source `:provider_reported`,
  `{:ok, amount}` (a non-negative integer in the spec's Budget unit) is the `actual`; any
  other answer, a raise, or a usage with source `:unknown` (no usage reported) gives no
  `actual`. The tests convert the reported `input_uncached_tokens` and `output_tokens` to
  the Budget unit `tokens` and give no actual when one is unknown.

The engine's committed slot is the Run's record of the call. The intent's durable
settlement is separate and can differ: the sink is called before the intent owner
commits, so after a crash right after the offer the slot can hold the outcome while the
intent is unknown, and with a lost delivery the intent can be settled while the slot
waits.

## Recovery

`wake(host, run_refs)` returns `[{run_ref, :woken | {:error, reason}}]`, one per Run in
the order given (a `run_ref` given twice gets the same disposition twice). It opens only
a Run that already has a current Attempt (any Attempt: a `:begin_attempt` control can
have moved it on): it rebuilds the spec through the `spec` callback, claims the lease,
starts the Run owner, checks the predecessors and starts the engine on the Run's journal.
The other Runs of a batch go on whatever one of them gives.

| Reason (`start_run/3` gives the same, but `:no_current_attempt`) | When |
| --- | --- |
| `:capacity` | `max_runs` Runs are reserved |
| `:running` | the `run_ref` is already reserved on this host |
| `{:spec, reason}` | the `spec` callback gave `{:error, reason}` (`{:spec, :invalid}` for any other answer or a raise) |
| `:invalid_spec`, `:outside_profile` | the spec's shape or an AI descriptor is wrong; a binding of another kind |
| `:identity_in_use` | another Run of this host has the same `unit` |
| `{:lease_refused, refusal}` | another live owner holds the Run's lease key |
| `{:lease, result}` | any other result of the lease claim |
| `:no_current_attempt` | the Run owner has no current Attempt for the Run (or no Run) |
| `:incompatible_recovery` | the engine refused the journal for another fingerprint (another gate version, request cap, binding, schema, pattern, ...) |
| `:fencing_unproven` | no fresh `:fenced` from `fencing_proof` (or no `fencing_proof`) before an engine on an existing journal (below) |
| `{:route, reason}` | the route of the Run's model calls cannot be read for good at the start or wake, also after reads that failed for a moment (AI model calls) |
| `:lease_lost` | the lease was lost during the start |
| `{:start_failed, {role, reason}}` | a process of the Run did not start (`:tasks`, `:owner`, `:evidence`, `:async`, `:engine`) or a Run command or read answered otherwise (`:create`, `:begin_attempt`, `:status`, `:unit_head`); `{:start_failed, reason}` when the worker ended otherwise |

After an `:incompatible_recovery` the engine may already have started its Unit: the
teardown stops it through the directory and confirms it. Every failed start ends in the
same confirmed teardown and releases a lease that it claimed.

**Predecessor fencing.** A replacement lease is necessary but not sufficient: taking
over the Run lease fences the compare-and-set writes on the Run stream, not the old Unit,
an EffectIntent stream or a task between its durable arm and the provider send, and an
old process can resume after the takeover. This host's own confirmed teardown is not
enough either: it stops processes, and a Store write that one of them submitted before
the teardown can still commit after it. Engine startup recovers intents and drains work
before it returns, so after the lease and before any engine starts on an existing Run or
Unit journal (for `wake/2`, and for a `start_run/3` retry that opens one) the host
requires a fresh `:fenced` from `fencing_proof.(run_ref)`: the caller's attestation that
no predecessor process can still act and no Store write that a predecessor submitted can
still commit, on this node or another. It is asked again at each check, never cached by
`run_ref`. With no `fencing_proof`, every predecessor check fails.

A start of a Run that has no Run record and an empty Unit journal is fresh: it opens no
journal and needs no check. Absent, invalid or unproven evidence gives
`{:error, :fencing_unproven}`: no engine starts, and no activation is granted. The
activation callback of the EffectIntent owners (`StoreHost`'s `authorize`) answers
`:fresh` (an intent and marker at revision 0) or `{:recovered, generation}` only for the
current incarnation of a Run whose check passed (or that is fresh), and only when a
reading of the lease taken in the callback shows it held by this owner and live by the
last confirmed `until`; a reading that shows the lease lost or expired loses the Run
(Leases). It answers `:refused` otherwise.

At a wake the engine recovers each running model call: an intent with a recorded attempt
settles its slot `unknown` (`lost_outcome`, dispatch unknown, no actual) and is never
sent again; an untried one (admitted, never armed) is activated as recovered and sent
once, its outcome held until the route is verified; an intent whose activation stays
read-only (the activation Store's head unreadable or its marker write lost) leaves its
slot in reconciliation (`reconciliation: :read_only` in `status/2`) until the Run ends.

## Time

The worker keeps one correlated wake timer per Run from `RunEngine.deadlines/1`: while
paused at `min(run_deadline, pause_deadline)` (a paused Run can reach its Run deadline
first), otherwise at `run_deadline`. It reads the committed deadlines again after a start,
a wake and each host, sink or caller input and control, and again when the timer fires: a
read that fails decides nothing (the timer and the reads are tried again 200 ms later),
and a replaced timer gives no input. At or after the deadline it sends one `wake` input
under `"wake:"` and the hex SHA-256 of the ETF of `{run_id, attempt_id, deadline}` (the
current Attempt), with the context `%{run_id, attempt_id}` and, under
`budget_rule: :pause`, a future `pause_deadline` from the spec's trusted context (with
none the wake is reported and tried again a second later; when the engine refuses it for
a pause operand that passed before it took the input, a fresh operand is taken). A wake
that the engine did not take (refused, or with no answer) is never sent again by the
input retry: only its timer sends a wake again, no sooner than a second later and after
it read the committed deadline and the current Attempt again, so a wake is sent only for
the current target and Attempt (a kept wake of another Attempt or deadline is dropped);
so is one whose target is still the committed deadline after it was sent. The timer
counts the engine clock's
milliseconds on the node's timer service, so a Run deadline is reached on time only with
an engine clock that runs in real time. A terminal phase is reported to `on_terminal` only
from a successful read of the outcome.

## Leases

Lease `until` is in the lease clock's Unix microseconds; the engine clock is never
compared with it. After a claim and after each confirmed renewal, the host samples the
lease clock (`Elzoo.Lease.status/2`) and sets an expiry check on the node's monotonic
clock at the moment by which `until` passes at the latest, for a lease clock that runs no
slower than the node's clock. **The renewal starts half the TTL before that moment**
through the live owner with `Elzoo.RunApprovalRelease.renew/2`, in a host task, so that a
renewal that waits the whole 5,000 ms caller limit of `renew/2` still ends before it for a
TTL of 10 s or more. The expiry check reads the lease clock again and declares the lease
expired only when that reading is at or past the last confirmed `until`; otherwise it waits
for the remaining time. Each input and control reads the lease clock too (Runs), against
the last confirmed `until` of the snapshot that its admission took: a reading that shows
the lease expired or lost is a loss only while that snapshot is still the Run's own;
after a renewal was confirmed it decides nothing, and the input is admitted again from a
fresh snapshot. An EffectIntent activation reads the lease in its callback and compares
its holder and its sample with this owner and the last confirmed `until`. So a lease
clock that moves faster than the node's (a Memory manual clock, for example) stops
admission and activation at once, and so does a lease that another owner seized. A
definite no-write error (`{:error, _}`) of a renewal keeps the token: the renewal is tried
again at a twelfth of the TTL. A renewal counts only when it is confirmed before the last
confirmed `until`: its task reads the lease clock after the reply (with no reading, the
node's clock is compared with the expiry moment), and a confirmation at or after that
`until` stops the Run with `:expired`, also when it reaches the host before the expiry
check's own reading.

On `{:refused, {:lease_lost, refusal}}`, `{:refused, {:fenced, facts}}`,
`{:indeterminate, receipt}` or `{:unknown, :no_receipt}` (each stops the owner), on no
confirmed renewal by the last confirmed `until` (`:expired`), and on a reading of the lease
that shows another holder or none (`{:lease_lost, %{reason, holder}}`), the host stops
admission for that Run (`input/5` and `control/5` give `{:error, :lease_lost}`, also after
the teardown), fences its processes and calls `on_lost.(run_ref, reason)` with that reason,
once, whichever of the renewal result, the owner's exit and the worker's exit it learns
first. Any exit of a `renew/2` call (its caller timeout, the owner ending, or another) is
an unconfirmed renewal, treated like `{:unknown, :no_receipt}`. A late successful renewal
reopens nothing. After a teardown began (a reap, a crash, a failed start), a renewal
result or an exit is no loss of a live Run: it calls no `on_lost` and changes no
admission answer, it adds only its receipt (an exit has none), so a reap that stops the
owner during a renewal leaves no loss. Only an indeterminate result keeps a receipt, also
then, given as `reconcile:` to the next start of the Run's owner. A host that starts or
wakes a Run whose lease another live owner holds is refused and starts no engine. The
engine treats a renewal as a fence change, not a Run transition (ELZ-429).

## Grounding

Tests (disposable PostgreSQL 19, except the Memory scenarios named below; the scripted
Req stub of `integration/ai-text-anthropic`, no network, stub keys only; no test loads
the adapter's model catalog ahead of a call). The processes of a Run are found by the
tests without the host's tracking: spawn tracing set on the host for a start or wake
(every process spawned from it, at any depth, also later), with the Run's Unit and its
Writer from the directory's Registry. Every predecessor check that a test passes is
given a proof that the test demonstrates: every such process of the predecessor has
ended (and, where a write is held, the write has landed).

- `test/elzoo/run_host_test.exs`: an AgentLoop Run answered end to end, on PostgreSQL and
  on one Memory namespace with a manual-clock Lease (the full Memory scenario, with
  `allow_volatile`, read again after its Unit slept); a model call that does not complete
  fails the Run with no host cancel; capacity with a terminal Run and a sleeping Unit
  held, and reap leaving none of the Run's processes alive, the lease free and the slot
  reused; a reap whose release is not confirmed; a start and a wake that wait on an
  unconfirmed release, answered with no third request; a failed start whose release
  fails twice, holding its reservation until the third; callbacks stopped at reap and a
  callback that reaps its own Run; options and profile refusals; Unit identities that
  would name another Run's streams; a Registry exit stopping the host; the Registry names
  of a host without `name`; a Run's group leader gone after its reap and after a normal
  stop of its host; a killed host whose link ends the Run's worker with the host's own
  exit reason, after which every process of the Run ends.
- `test/elzoo/run_host_ai_test.exs`: an image part refused with no intent and no stub
  call; the key derivation, the input ID and context, and a duplicate delivery giving no
  second input; the same under `budget_rule: :pause` after the context would give another
  pause deadline; acknowledged inputs after Unit dedup eviction and a retry due after
  success; a timeout with dispatch unknown and no actual; a 70 KiB completion, and a
  small one whose tool arguments reach 32 levels, each refused `too_large`, dispatched,
  with no actual (the deep one with its reservation still reserved), and the same deep
  completion one level shallower settled completed with its actual; a sink failure with
  no input and no settlement; an outcome kept across a failed route read; a call held
  past `idle_ms`; a `:begin_attempt` in the middle of a Run; with an `idle_ms` of 300 ms
  and no warm-up, a first model call that waits for the catalog load, and a transcript
  read that holds the worker past `idle_ms` with a call in flight, each keeping the Unit
  awake, and an idle Run whose Unit sleeps; a wake whose route cannot be read
  (immediately, and after a failed read) and a live delivery whose route cannot be read;
  a sink failure held during a wake's route verification; the translation table.
- `test/elzoo/run_host_recovery_test.exs`: a same-node restart refused without a proof
  after the host's own teardown and woken with one, and a takeover by another host after
  lease expiry whose proof stops every process of the first (found through their
  group-leader chain): one stub call, one `lost_outcome`, the Run failed with
  `model_call_not_completed`; lease expiry alone with no `fencing_proof` (no engine, no
  activation record, no new send, at a second wake too); on Memory, an EffectIntent
  settlement write held after its submission across the host's own confirmed teardown
  (no proof while it is held), then landed and read by the recovery that the proof
  allows; a `start_run/3` retry on an existing journal, and a fresh start interrupted
  after its `create`, each refused without a proof and started with one; the proof asked
  at each check; an activation after another owner seized the lease; an untried intent
  recovered at wake, sent once with its outcome held until the route is verified; a
  read-only intent owner and a trapping send task stopped at teardown; fingerprint
  changes in a batch, refused first without a proof; wake dispositions; lease refusals
  on PostgreSQL and, with one shared Lease backend, on Memory.
- `test/elzoo/run_host_time_test.exs`: the deadline wakes (idle Run, both paused
  orderings, a continue that moves the timer, a wake refused for its passed pause
  operand, a refused wake sent again only by its timer for the current Attempt); engine
  reads that end by the engine's 60 s call limit (no wake until the deadline is read, no
  input after a `:begin_attempt` until its Attempt is read); the lease clock (a Memory
  clock moved past `until`, a claim that waits a TTL before its sample, a caller whose
  reading is older than a confirmed renewal) and lease renewal (several TTLs, a seized
  lease, a renewal confirmed after the last confirmed `until`, a renewal reply delayed
  past the caller timeout, an indeterminate renewal result that comes first and one that
  comes last, a worker's report of an indeterminate owner exit that comes first, a reap
  during a renewal, and a reap that waits for the renewal job).

Negative controls (temporary edits, each failing its named test, then reverted) are
listed in the task's pull request. These are finite scenarios, not proofs. No Cure
decision is added: the host is an OTP shell whose decisions are lookups over ai-text's own
Cure outcome table and the engine's results.

## Limits

- The host fences processes of its own Runs only (by their group leader; a process that
  changes its own group leader escapes it), and no Store write: every predecessor check
  rests on the caller's `fencing_proof`, which this Piece cannot check. Two hosts in one
  VM stand for two nodes in the tests; one host per node is not enforced.
- The route is read from the whole retained transcript: a Run whose history passes
  65,536 records or 536,870,912 bytes cannot be routed.
- Sink deliveries are volatile: a delivery lost with the worker leaves its slot open; no
  reconciliation of intents is supplied.
- `{:error, :lease_lost}` is admission, not a physical fence: an input already with the
  worker can reach the engine until the teardown stops it. A renewal that commits but
  whose reply comes after the last confirmed `until` loses the Run (safe, not live).
- A provider request already on the wire is not recalled by a teardown.
- The keep-alive touches the Unit through the directory: a directory busy for longer
  than three quarters of `idle_ms` (for example while it starts a Unit that replays a
  long journal) can still let a Unit sleep under a call in flight, and its reopening
  settles that call `lost_outcome`.
- An engine call that ends only by the engine's 60 s call limit holds the worker that
  long: a due wake, and an input after a control, wait for it.
- A Run waits until a deadline on the node's timers; the engine clock must run in real
  time for the wake to come on time.
- Telemetry is OTP diagnostics and the Logger warnings above; no event, no payload.
