# assembly/run-host

`Elzoo.RunHost` is a supervised host for the `assembly/run-engine` Runs of one
node, for one profile. It owns, once, what each consumer of the engine built for
itself: the Unit directory, the Run owner with its lease, the evidence Writer,
AsyncWork, the EffectIntent startup bindings, the AI text bindings with their
outcome route, recovery with predecessor fencing, deadline wakes, lease renewal and
the confirmed teardown of every per-Run process. Apache-2.0.

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
  through the Run's worker (caller inputs and controls, sink outcomes, wakes), and
  the host reads the deadlines and the terminal phase after each of them, with no
  periodic resampling.
- ASK model calls are outside the profile: `control/5` forwards no Approval control
  (`:approval_evidence` gives `{:error, :outside_profile}`), so such a call waits
  until the Run ends. `:begin_attempt` gives the same: a Run keeps the spec's stable
  Attempt.

## Start

`Elzoo.RunHost.start_link(opts)` starts one host; one per node is the intended use
(the optional `name` is ordinary OTP registration, so the tests run two hosts in one
VM to stand for two nodes). Required options, with no defaults:

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
for a Memory namespace) and `name`. Anything else, or a missing or out-of-range
option, is `{:error, :invalid_options}`.

The views: PostgreSQL views share the Repo and prefix (the `integration/sql` tables
of migration version 1), Memory views share one Memory process. A view checks the
kinds, versions and limits of its records; the owners replay with their own folds.

| View | Fold and limits |
| --- | --- |
| `unit_store` | `Elzoo.DurableUnit.fold/1` and `limits/1` of the engine's Unit options (`operator: {Elzoo.RunEngine, :step, %{version: 1, control: nil, slots: %{}, requests: %{}}}`, `retention_count`, `max_record_bytes: 16_777_216`, `max_checkpoint_bytes: 33_554_432`) |
| `run_store` | `Elzoo.RunApprovalRelease.fold/0` and `limits/0` |
| `evidence_store` | kind `"completion"`, version 1; `max_record_bytes: 131_072, max_batch_size: 1, max_checkpoint_bytes: 1_048_576` |
| `intent_store` | `Elzoo.EffectIntent.fold/1` of an AI binding module and `Elzoo.EffectIntent.limits/0` (every binding's fold has the same kind and version) |
| `activation_store` | `Elzoo.EffectIntent.StoreHost.fold/0` and `limits/0` |

A Memory process cannot take a view's fold, so for a full Memory host the one Memory
namespace's fold holds the kinds of every owner (`input`, `result`, `run`, the four
lease kinds, `completion`, `intent`, `intent_host`) and its limits the largest that
any owner needs (`max_record_bytes: 16_777_216, max_batch_size: 4,
max_checkpoint_bytes: 33_554_432`). The evidence Writer writes into the namespace
where the Run owner reads evidence, so a completed or failed finish passes the
owner's evidence check.

The host starts its own Registry and its dedicated, initially empty DynamicSupervisor
for the `DynamicUnits` directory, a second Registry for the engine names (an engine
is the AsyncWork owner of its Run, which takes a Registry name), and a Task.Supervisor
for its renewals, teardowns and callbacks.

## The spec

A spec is a map with exactly these keys:

| Key | Value |
| --- | --- |
| `run_id`, `operation_id`, `attempt_id` | the stable Run, operation and Attempt IDs, 1..200 bytes |
| `unit` | the Unit identity and stream, 1..160 bytes; the Run owner's stream (the lease key, one per Run) is `"run/" <> unit` and the evidence stream `"evidence/" <> unit` |
| `provider_refs` | the Run's provider references (`RunApprovalRelease` `create`) |
| `tenant`, `principal` | the engine's trusted tenant and acting principal |
| `pattern`, `schemas`, `gate`, `context`, `budget`, `budget_rule`, `request_cap`, `run_deadline` | the engine's start options of the same names |
| `bindings` | the engine bindings of the profile's other kinds |
| `ai` | the AI binding descriptors: model_call schema ID to descriptor (AI model calls) |
| `retention` | the result reader's retention, which is also the Unit's `retention_count` |

## Runs

`start_run(host, run_ref, spec)` reserves a slot (`{:error, :capacity}` at
`max_runs`), claims the Run's lease key, provisions the EffectIntent startup
bindings, starts the Run owner, `create`s the Run and begins its Attempt with the
spec's IDs, and starts the evidence Writer, AsyncWork and the engine (with
`result_reader`). It returns `:ok`; starting the engine does not start the pattern
(for AgentLoop the caller sends the typed `start` through `input/5`). An interrupted
start is retried by the same call with identical IDs: the owner answers
`{:unchanged, :duplicate, _}` to both commands and no new Attempt begins. A retry
that opens an existing Run or Unit journal passes the predecessor check (Recovery)
before any engine starts. A lease that another owner holds gives `{:error,
{:lease_refused, refusal}}` (the refusal of `Elzoo.Lease.claim/4`) and no engine
starts.

`input/5`, `control/5`, `status/2`, `deadlines/2`, `result/4` and `transcript/4` take
the host and the `run_ref` before the engine's operands and give the engine's own
results; a Run that is not live on this host gives `{:error, :not_running}`. Inputs
and controls go through the Run's worker, which serializes them with the host's own
inputs; an engine call that ends by the engine's call limit gives the caller the
same exit. Reads go to the engine directly.

On a terminal outcome the host stops business input (`input/5` and `control/5` give
`{:error, :terminal}`) and calls `on_terminal.(run_ref, outcome)` in a host task,
once per incarnation of the Run. The engine stays live with its scoped result reader
until `reap(host, run_ref)`, which stops every per-Run process, confirms that each is
gone, releases the lease and frees the reservation, then returns `:ok` (`{:error,
:not_running}` for a Run that is not live). A terminal Run that is not reaped counts
against `max_runs`.

### Processes and teardown

Per Run the host starts one worker (`Elzoo.RunHost.Runner`, linked to the host),
which starts and links a Task.Supervisor (the tasks of the Run's EffectIntent owners
and of AsyncWork), the Run owner, the evidence Writer, AsyncWork and the engine; the
engine starts the Unit under the directory and its EffectIntent owners unlinked. The
host tracks each process from its start: the worker reports its own, and every
EffectIntent owner is reported by the activation callback inside it. A teardown
(reap; an exit of the worker, the engine, the Run owner, the evidence Writer, AsyncWork
or the task supervisor of a live Run; a lost lease; a failed start)
runs in a host task: it kills the engine first (so it starts nothing more), then the
EffectIntent owners, AsyncWork, the task supervisor with its tasks, the Run owner, the
evidence Writer and the worker, stops the Unit through its directory (a confirmed
`:ok`) and waits until each of them and every process the Unit started is gone. Until
then the Run keeps its reservation; an unconfirmed teardown runs again every second.
A `start_run/3` or `wake/2` of a Run that is being torn down waits for the end of the
teardown.

## AI model calls

An AI binding descriptor has exactly `id` and `version` (the engine binding's
identity, part of the fingerprint), `effect_class` and `proposal` (Authorization),
`estimate` (Budget units per call), `call_ms` (1..86,400,000: the call's slot and
intent deadline is the clock plus `call_ms`), `usage` (below) and `ai_text`: the
options of `Elzoo.AiText.configure/1` without `tenant`, `sink`, `artifacts` and
`image_bounds`, which the host sets (the spec's tenant, its own sink, no artifact
reader). The action's payload is the ai-text request (`elzoo/ai-text-request`
version 1, AgentLoop's first model call); the binding's result is
`elzoo.ai-text.result` version 1.

- **Key.** The AI idempotency key of an action is the lowercase hex SHA-256 of the
  ETF of `{run_id, attempt_id, action_id}` with the spec's stable IDs and the
  engine's non-reused action ID, so the intent key is ai-text's key of
  `[tenant, provider_account, binding_id, "generate", key]`.
- **Admission.** The host's gate runs `Elzoo.AiText.admission/2` before the spec's
  gate. A refusal (`{:error, {:refused, reason}}`, for example `:unsupported_feature`
  for an image part or `:too_large`) is a gate denial with that reason: the engine
  records it before any intent exists, the action settles refused (actual 0), no
  intent starts and the provider is not called. `facts/1` repeats the admission
  that the gate passed, so it returns no admission error, and does no I/O. The
  EffectIntent startup bindings are provisioned once at the Run's start.
- **Route.** The sink of every binding sends each delivery to the Run's worker. The
  worker resolves the key to the exact Run, Attempt, action and occurrence from the
  committed `model_call` actions that `transcript/3` gives (Attempt, action ID,
  occurrence, schema ID) and the stable binding configuration, never from
  `status/1` alone, and then calls `RunEngine.input/4`. At a start or a wake the
  deliveries are held until that route is verified (built once the engine has
  started); a key that is not in the route makes the worker read the transcript
  again.
- **Input.** Each received outcome is one engine `action_outcome` input under the ID
  `"ai:"` and the hex SHA-256 of the ETF of `{run_id, attempt_id, occurrence}` (67
  bytes for any action ID). Under `budget_rule: :pause` the host samples the spec's
  trusted `context` for a `pause_deadline` after the clock before it first submits
  the input. The first submission fixes the frame and the whole context, that pause
  operand included; a retry (the engine's `{:error, :unavailable}` or an exit, at
  most 20 times) and a duplicate delivery send them again, so the engine answers a
  duplicate, never a second settlement. A context with no future pause deadline is
  outside the engine's Need: the host reports it and submits nothing.
- **Sink.** ai-text sends `{:outcome, attempt_id, outcome}` or `{:sink_failed,
  attempt_id}` before the intent owner commits its own settlement. The host
  translates only outcomes received at the sink. `{:sink_failed, _}` gives no input:
  the host reports it, and the slot waits for reconciliation or the end of the Run.
  A missing delivery gives no settlement.

Reports are one `Logger` warning that names the Run reference and the action or
key, never a payload: a sink failure, an outcome with no route, no future pause
deadline, and an input that the engine refused or did not take.

### Translation and `elzoo.ai-text.result` version 1

| Outcome at the sink | `outcome` | `dispatch` | `actual` | Payload |
| --- | --- | --- | --- | --- |
| `{:completed, body}` | `"completed"` | `"dispatched"` | the usage conversion, or none | completed view |
| `{:refused, reason, meta}`, reason `credentials_unavailable` or `input_unavailable` (sent nothing) | `"refused"` | `"not_dispatched"` | 0 | refusal view |
| `{:refused, reason, meta}`, any other reason | `"refused"` | `"dispatched"` | none | refusal view |
| `{:unknown, :malformed_response}` (always reached the provider) | `"unknown"` | `"dispatched"` | none | refusal view |
| `{:unknown, reason}`, `timeout`, `transport` or `provider_error` | `"unknown"` | `"unknown"` | none | refusal view |
| `{:sink_failed, _}` | no input | | | |

A delivered `:provider_error` does not prove dispatch (a provider error and an
adapter error both deliver it), and the host never infers zero or a dispatch that the
outcome does not establish. An unknown outcome has no actual, so its reservation stays
reserved.

- The completed view is exactly `{"content": text, "finish": finish, "tool_proposals":
  [proposal]}`: `finish` is `"stop"`, `"length"`, `"tool_calls"`, `"content_filter"`,
  `"refusal"` or `{"other": text}`, and a proposal is exactly `{"id", "name",
  "arguments", "malformed"}` (`malformed` null or the tag as text), the form that
  AgentLoop reads. The structured output and the usage are not in it.
- The refusal view is exactly `{"reason": text, "retry_after": seconds | null,
  "candidate": null}`: the reason of the outcome, the provider's `retry_after` for a
  refusal (null for an unknown) and no routing candidate.
- The usage conversion is the descriptor's trusted `usage` callback: for a completed
  body whose `usage` (an `Elzoo.AiModel.Usage` value) has source
  `:provider_reported`, `{:ok, amount}` (a non-negative integer in the spec's Budget
  unit) is the `actual`; any other answer, a raise, or a usage with source `:unknown`
  (no usage reported) gives no `actual`. The tests convert the reported
  `input_uncached_tokens` and `output_tokens` to the Budget unit `tokens` and give no
  actual when one is unknown.

The engine's committed slot is the Run's record of the call. The intent's durable
settlement is separate and can differ: the sink is called before the intent owner
commits, so after a crash right after the offer the slot can hold the outcome while
the intent is unknown, and with a lost delivery the intent can be settled while the
slot waits.

## Recovery

`wake(host, run_refs)` returns `[{run_ref, :woken | {:error, reason}}]`, one per Run
in the order given. It opens only a Run that already has a current Attempt: it
rebuilds the spec through the `spec` callback, claims the lease, starts the Run
owner, checks the predecessors and starts the engine on the Run's journal. The other
Runs of a batch go on whatever one of them gives.

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
| `:incompatible_recovery` | the engine refused the journal for another fingerprint (another gate version, request cap, binding, schema, pattern, ...), or the current Attempt is not the spec's |
| `:fencing_unproven` | no confirmed teardown and no fresh `:fenced` (below) |
| `:lease_lost` | the lease was lost during the start |
| `{:start_failed, {role, reason}}` | a process of the Run did not start (`:tasks`, `:owner`, `:evidence`, `:async`, `:engine`) or a Run command answered otherwise (`:create`, `:begin_attempt`, `:status`); `{:start_failed, reason}` when the worker ended otherwise |

After an `:incompatible_recovery` the engine may already have started its Unit: the
teardown stops it through the directory and confirms it. Every failed start ends in
the same confirmed teardown and releases a lease that it claimed.

**Predecessor fencing.** A replacement lease is necessary but not sufficient: taking
over the Run lease fences the compare-and-set writes on the Run stream, not the old
Unit, an EffectIntent stream or a task between its durable arm and the provider send,
and an old process can resume after the takeover. Engine startup recovers intents
and drains work before it returns, so after the lease and before any engine (for
`wake/2`, and for a `start_run/3` retry that opens an existing Run or Unit journal)
the host requires one of:

- **confirmed teardown**: this host incarnation stopped and confirmed every process
  of the Run's last tenure, that tenure began clean (fresh, or after a passed check),
  and nothing was written to the Run stream since. At the end of that teardown the
  host takes the stream's revision when the latest lease record is this owner's own
  (its claim or renewal, or its release right after it); the new claim must come
  directly after it. Another owner's claim between them, a new host incarnation, or
  a teardown after the key moved to another owner leaves no such marker;
- **a fresh `:fenced`** from `fencing_proof.(run_ref)`, asked again at each check
  (never a cached attestation keyed by `run_ref`); the caller's proof must cover every
  predecessor that could still act or write, also on another node.

Absent, invalid or unproven evidence gives `{:error, :fencing_unproven}`: no engine
starts, and no activation is granted. The activation callback of the EffectIntent
owners (`StoreHost`'s `authorize`) answers `:fresh` (an intent and marker at revision
0) or `{:recovered, generation}` only for the current incarnation of a Run whose check
passed, and `:refused` otherwise.

At a wake the engine recovers each running model call: an intent with a recorded
attempt settles its slot `unknown` (`lost_outcome`, dispatch unknown, no actual) and
is never sent again; an untried one is dispatched once, its outcome held until the
route is verified; an intent whose activation stays read-only (the activation Store's
marker write lost or failed) leaves its slot in reconciliation (`reconciliation:
:read_only` in `status/2`) until the Run ends.

## Time

The worker keeps one correlated wake timer per Run from `RunEngine.deadlines/1`: while
paused at `min(run_deadline, pause_deadline)` (a paused Run can reach its Run deadline
first), otherwise at `run_deadline`. It reads the committed deadlines again after a
start, a wake and each host, sink or caller input and control, and again before the
timer fires; a replaced timer gives no input. At or after the deadline it sends one
`wake` input under `"wake:"` and the hex SHA-256 of the ETF of `{run_id, attempt_id,
deadline}`, with the context `%{run_id, attempt_id}` and, under `budget_rule: :pause`,
a future `pause_deadline` from the spec's trusted context (when the context gives none
the wake is reported and tried again a second later). The timer counts the engine
clock's milliseconds on the node's timer service, so a Run deadline is reached on
time only with an engine clock that runs in real time.

## Leases

The host renews each Run's lease through its live owner with
`Elzoo.RunApprovalRelease.renew/2`, in a host task. Lease `until` is in the lease
clock's Unix microseconds and `until - at` of every token is the TTL; the engine clock
is never compared with it. Each lease call starts after a moment `t` on the node's
monotonic clock and the lease samples `at` inside it, so `until` is no earlier than
`t + lease_ttl_ms` for a lease clock that does not run faster than the node's clock
(on Memory, the manual clock must not be moved faster than that). **The renewal
starts half the TTL before that estimate**: a renewal that waits the whole 5,000 ms
caller limit of `renew/2` still ends before the estimate for a TTL of 10 s or more.
When no renewal is confirmed by the estimate, the host stops admission for the Run and
fences it as for a lost renewal (`on_lost` reason `:expired`). A definite no-write
error (`{:error, _}`) keeps the token: the renewal is tried again at a twelfth of the
TTL, within the same estimate.

On `{:refused, {:lease_lost, refusal}}`, `{:refused, {:fenced, facts}}`,
`{:indeterminate, receipt}` or `{:unknown, :no_receipt}` (each stops the owner) the
host stops admission for that Run (`input/5` and `control/5` give `{:error,
:lease_lost}`, also after the teardown), fences its processes and calls
`on_lost.(run_ref, reason)` with that reason. A `renew/2` call that exits on its caller
timeout is an unconfirmed renewal, treated like `{:unknown, :no_receipt}` (the reason
given to `on_lost`); a late successful renewal reopens nothing. The same holds for a
Run owner that stops with one of these reasons after a command. Only the indeterminate
result keeps a receipt, given as `reconcile:` to the next start of the Run's owner.
A host that starts or wakes a Run whose lease another live owner holds is refused and
starts no engine. The engine treats a renewal as a fence change, not a Run transition
(ELZ-429).

## Grounding

Tests (disposable PostgreSQL 19, except the two Memory scenarios named below; the
scripted Req stub of `integration/ai-text-anthropic`, no network, stub keys only):

- `test/elzoo/run_host_test.exs`: an AgentLoop Run answered end to end, on PostgreSQL
  and on one Memory namespace with a manual-clock Lease (the full Memory scenario,
  with `allow_volatile`); a model call that does not complete fails the Run with no
  host cancel; capacity with a terminal Run and a sleeping Unit held, and reap with
  every process of the Run gone (counted before and after), the lease free and the
  slot reused; options and profile refusals.
- `test/elzoo/run_host_ai_test.exs`: an image part refused with no intent and no stub
  call; the key derivation, the input ID and context, and a duplicate delivery answered
  as a duplicate; the same under `budget_rule: :pause` after the context would give
  another pause deadline; a timeout with dispatch unknown and no actual; a sink failure
  with no input and no settlement; the translation table.
- `test/elzoo/run_host_recovery_test.exs`: crash and wake on one node after confirmed
  teardown, and a takeover by another host after lease expiry, with the predecessor's
  processes stopped by the test through their group leader (the stand-in for another
  node): one stub call, one `lost_outcome`, the Run failed with
  `model_call_not_completed`; lease expiry alone with no proof; a `start_run/3` retry
  on an existing journal on the same and on a new host incarnation; the proof asked at
  each check; the startup route hold; fingerprint changes in a batch; wake
  dispositions; lease refusals on PostgreSQL and, with one shared Lease backend, on
  Memory.
- `test/elzoo/run_host_time_test.exs`: the deadline wakes (idle Run, both paused
  orderings, a continue that moves the timer) and lease renewal (several TTLs, a lost
  renewal, a renewal reply delayed past the caller timeout).

Negative controls (temporary edits, each failing its named test, then reverted) are
listed in the task's pull request. These are finite scenarios, not proofs. No Cure
decision is added: the host is an OTP shell whose decisions are lookups over ai-text's
own Cure outcome table and the engine's results.

## Limits

- One node: the host fences only processes it tracked; predecessors elsewhere need
  the caller's `fencing_proof`, which this Piece cannot check. Two hosts in one VM stand
  for two nodes in the tests.
- The route is read from the whole retained transcript: a Run whose history passes
  65,536 records or 536,870,912 bytes cannot be routed, and its outcomes are reported
  and not given to the engine.
- Sink deliveries are volatile: a delivery lost with the worker leaves its slot open;
  no reconciliation of intents is supplied.
- `{:error, :lease_lost}` is admission, not a physical fence: an input already with the
  worker can reach the engine until the teardown stops it.
- A Run waits until a deadline on the node's timers; the engine clock must run in real
  time for the wake to come on time.
- Telemetry is OTP diagnostics and the Logger warnings above; no event, no payload.
