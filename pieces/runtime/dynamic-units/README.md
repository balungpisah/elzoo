# runtime/dynamic-units

One durable Unit per local binary identity, with bounded live children and idle
sleep. DynamicSupervisor remains OTP-owned; runtime/dynamic-units supplies only
bounded local identity and idle-lifecycle policy for assemblies that need it.
Assemblies retain business orchestration.

## Construction and Needs

`Elzoo.DynamicUnits.start_link(opts)` starts one serialized directory controller.
Required settings are `registry` (caller-owned, named unique-key Registry),
`supervisor` (caller-owned dedicated local DynamicSupervisor PID or name),
`unit_options` (arity-1 function of identity returning DurableUnit options), and
`idle_ms` (integer 1..4_294_967_295 milliseconds). Optional `name` is ordinary
OTP registration. There are no defaults, extra settings or hot configuration.
Invalid options return `{:error, :invalid_options}`; absent infrastructure or a
nonempty initial child supervisor returns `{:error, :unavailable}`.

Configure the dedicated DynamicSupervisor with `:one_for_one`, a positive
`max_children` and ordinary OTP restart intensity. It is the only capacity
authority; there is no second limit/counter. The caller must reset directory,
Registry and child supervisor together on infrastructure loss. No adoption or
reconstruction of surviving children is supplied. The [sleep/wake example](examples/sleep_wake.exs)
uses ordinary Supervisor with `:one_for_all`, not a new pool factory.

Identity is UTF-8 binary, 1..160 bytes, without NUL. It is both durable stream
and Registry key; there is no atom conversion or per-identity supervisor.
`unit_options.(identity)` supplies matching deterministic Store/operator,
retention, size and offer settings, **never** `stream` or `name`. The directory
sets `stream: identity` and `name: {:via, Registry, {registry, identity}}`.
Use one directory/Registry namespace per logical identity domain on the node.
Do not admit external children into its dedicated supervisor or namespace.

Direct Piece dependencies are `runtime/durable-unit`, `runtime/registry` and
`runtime/supervision`. Ready `runtime/host` is a reference, not a modified
service. Needs include the caller-owned subtree and finite supervisor cap,
matching options per durable identity, DurableUnit's Store/transition/dispatcher
Needs, and runtime monotonic timers. Providers are pinned Elixir 1.20.4 and
OTP 29.1.2. No package/pin change or new Cure law is supplied for this OTP shell.

## API and idle lifecycle

- `start(server, identity)` returns `{:ok, pid}` for its existing or newly
  recovered child. Duplicate start preserves state and refreshes idle time.
- `find(server, identity)` returns `{:ok, pid}` or `:not_found` without creation
  or idle refresh. A PID is a snapshot, not a lease.
- `stop(server, identity)` is explicit sleep: `:ok` means the owned child has
  terminated and its specification is removed, or it was already absent.
  It uses `DynamicSupervisor.terminate_child/2` with the Unit's published shutdown
  policy. There is no tombstone, drain, deletion or checkpoint-before-stop.
- `route(server, identity, {:durable_unit_input, input_id, input})` validates
  identity/tuple/ID, wakes if absent, and sends the tuple unchanged. It then
  calls `DurableUnit.snapshot(pid)` from the same controller. Every normally
  returned term is opaque application state, including error-shaped tuples:
  discard it and reply `{:ok, :routed}`. Barrier exit/timeout returns
  `{:indeterminate, :delivery}`, without resend or replacement wake in that call.

Invalid identity is `{:error, :invalid_identity}`; malformed route tuple/ID is
`{:error, :invalid_message}`, without sending. Exhausted supervisor capacity is
`{:error, :capacity}`; known start/stop/restart uncertainty is `{:error, :busy}`.
Callback or child-init failure is `{:error, :start_failed}`, without arbitrary
provider diagnostics. Lost infrastructure is `{:error, :unavailable}` and needs
a fresh caller-owned subtree. No child is stolen or failed recovery retried.
These pre-send errors refuse without delivery; after a send, barrier failure
is indeterminate, not safe rejection. Ordinary GenServer timeouts remain
uncertain for any mutating operation, including waiting in the controller mailbox.

The processing barrier uses OTP same-sender ordering, not application acceptance.
A Unit-rejected input may still be routed; only synchronous DurableUnit step's
applied/duplicate reply establishes a committed result. No second intake form,
acknowledgement protocol, persistence or duplicate step invocation is added.

Start, route, stop and idle expiry serialize in the controller. Deadlines reset
after successful creation, explicit start of an existing child, completed route
barrier and successful abnormal replacement. Find, refusal and failed route do
not refresh them. **Idle measures directory operations**, not Unit activity:
direct step/info sends, outbox work and external async work are unobserved.
Callers needing sleep coordination must route through this directory. Timers
use monotonic deadlines and per-incarnation/admission tokens; stale idle, DOWN
and startup notifications cannot remove a replacement. If stop/expiry wins,
route wakes only after confirmed termination or refuses before send. Slow
recovery, transition or termination may block this small directory; there is
no throughput or exact wall-clock sleep guarantee.

The one Piece-local child-start seam calls published DurableUnit.start_link
and announces each successful PID. Only the child spec's start MFA changes;
transient restart and shutdown fields remain OTP-owned. Replacement is monitored
and checked against registration/supervisor ownership before active accounting.
Restarting identities stay reserved, even while Registry is empty. A local DOWN
does not free capacity: removal requires supervisor confirmation. Named shutdowns,
including conflict and transition failure, do not cause directory retry loops.
A later explicit start is fresh admission and retains the Unit's reconciliation
Need after uncertain Store writes.

Monitor/timer/identity bookkeeping is bounded by admitted child slots and removed
after confirmed terminal stop. Sleeping identities leave no directory record.
This bound excludes mailbox backlog, Store history and application state.
Sleep stops a process; it does not cancel business actions or prove an external
Effect did not run. No durable directory/mailbox, arbitrary child types, cluster
lease/discovery, authorization, sandbox, exactly-once or partition guarantee.
Memory tests demonstrate process recovery, not disk durability. Lost direct async
delivery retains RC-50's recovery and late-outcome responsibility.

## Shared runtime boundary

RC-45 owns exactly one business info-message form: `{:durable_unit_input, input_id, input}`. `input_id` is a caller-stable UTF-8 binary of 1..160 bytes without NUL, scoped to one durable stream; `input` is caller-owned data. A direct sender constructs that tuple; no second intake wrapper or Envelope is introduced. RC-45 applies the same intake semantics to `step(server, input_id, input)` and this tuple. Sending the tuple is not an acknowledgement or evidence of commit; mailbox delivery is volatile. Only the synchronous step's applied/duplicate reply establishes that the input's result is committed. The caller owns resubmission with the same identity after an uncertain outcome, and identity collisions are errors inside the retained window.

RC-46 routes that tuple unchanged to the current local Unit for the identity. It must not report a successful send as durable acceptance, and must explicitly refuse a stop/wake race it cannot resolve; no durable mailbox or exactly-once delivery is promised. RC-47 owns no durable-unit tuple: it calls the supplied `wrap.(work_ref, outcome)` and sends that returned term to the owner's registered name, resolved when sending rather than retaining an owner PID. RC-47 tests use a receiver process, not RC-45. RC-50 supplies the wrap that builds the RC-45 tuple with an RC-68 input inside; it supplies stable input identity and engine-read time. A result for an action no longer open is late and is never applied, including after durable-unit input deduplication has expired. On engine recovery RC-50 records a failed outcome with a loss class for an open volatile local-work action before admitting subsequent results; a later result is late. Neither RC-45 nor RC-47 implements this engine policy.

An append returning `{:conflict, observed}` causes RC-45 to stop with `{:shutdown, :durable_unit_conflict}`. The ready Writer normally reloads and returns conflict; RC-45, not the Writer or RC-46, owns the stop policy. No losing candidate state or outbox is installed or offered. A pure transition may already have been evaluated before a result-append conflict; “applies nothing” means no committed losing result, not that no CPU work occurred. RC-46 uses this exact stop reason for the losing Unit on another node. Local Registry uniqueness is not cluster ownership.

## Grounding and operations

The seven named tests DY1–DY7 cover concurrent/independent identity admission
and validation; route/stop/expiry and death interleavings with opaque snapshots;
capacity through startup/termination/recovery barriers; abnormal recovery and
named shutdown/intensity; sleep/wake and idle refresh; independent local domains
contending through Store CAS; and bounded binary lifecycle/infrastructure reset.
They use real OTP infrastructure, DurableUnit, volatile Memory and Piece-local
barriers. The negative control temporarily bypasses the route processing barrier
in the actual production file; DY2 must fail, then the edit is reverted.
Finite scenario results are tests, not universal recovery or exactly-once proofs.
Same-sender ordering, Registry, supervisor capacity/transient restart/intensity
and monotonic timers are upstream contracts, not locally proved laws.

Telemetry is **planned**, with no new events or payload logs. Config is
**supported** for construction settings, caller supervisor cap and idle
milliseconds, with no live changes. Control is **supported** for start/stop/route
with the results above; find is inspection, not monitoring. Inherited OTP crash
diagnostics remain caller Logger policy and may include payloads. Copied source
is Apache-2.0; rerun/adapt evidence after customization.
