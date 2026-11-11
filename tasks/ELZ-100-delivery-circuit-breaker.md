# ELZ-100 — Bound circuit admission and recovery probes over fuse

- Phase: delivery policy
- Catalogue IDs: delivery/circuit-breaker
- Dependencies: ELZ-006, ELZ-033, ELZ-099
- Change class: P after the separately merged class-X prerequisite

Independent Contract review accepted the first-failure/one-probe scope after corrections
to classification, timeout taxonomy, stale-probe retirement, provider identity and exported
test closure. Four selected production Cure laws are required below. Implementation waits
for ELZ-099 merge acceptance. No other Piece behavior is changed.

## Admitted scope

ADOPT unmodified **fuse 2.5.0**, with a narrow Elzoo permit/result fence.
The first subset trips on **one** classified dependency failure, permits **one** recovery
probe, has no waiting queue and performs no Effect, task spawning or retry itself.
Use `{{:standard, 0, 1000}, {:reset, cooldown_ms}}`: upstream MaxR=0 means first-melt
trip, not zero tolerated failures followed by an extra local threshold. The 1000 ms
upstream history parameter is fixed implementation configuration; no rolling-window,
failure-ratio or consecutive-failure API is offered by this subset.

`fuse` supplies the actual trip/reset mechanism. Elzoo supplies the missing serialized
recovery gate, one-use observations, epoch/owner fencing, bounded bookkeeping and explicit
classification. A direct `:fuse.run/3` Recipe cannot meet the half-open/stale-result Contract.
Do not implement a replacement circuit engine or fork merely because upstream is old.
A configurable threshold, more than one probe, or cross-owner recovery guarantee is a
reviewed later Contract decision, not an undocumented extension during implementation.

## Responsibility, caller and split

For P09, an application calling a ready provider Adapter can refuse attempts while its
local circuit is open and cautiously sample recovery. Primary concrete exercise: an
object-store HEAD/GET against a local failing/recovering S3-compatible fixture. Challenge
generality with SMTP connect-failure classifications; no live email or model API is needed.
An existing Adapter's source and accepted output mapping are unchanged.

The historical RC-26 title is **“Circuit admission and resource bulkheads”**; its own body
says “pool capacity owns bulkhead enforcement”. The later disposition says “Not a bulkhead
or pool”. Retain both facts in admission reconciliation; admit circuit policy only:

| Responsibility | Owner in this admission |
| --- | --- |
| Failure admission, recovery observations, stale circuit results | This new Piece |
| Actual concurrent operations and saturation | Unchanged `delivery/backpressure`, and the caller's actual pool/Task.Supervisor |
| Attempts, deadlines, backoff, settlement, unknown-dispatch retry refusal | Unchanged `delivery/retry-timeout` |
| External Effect and provider outcome/dispatch truth | The selected existing Adapter |
| Resource isolation, bulkheads, waiting pools, distributed capacity | Excluded; existing provider/pool contracts must be named by callers |

A permit-bookkeeping limit is not a resource bulkhead. Retiring a circuit permit never
releases the retry Runner's slot or a provider connection, cancels work, or establishes
that an external Effect stopped. No new Assembly, broker, identity, payments or agent runtime.

## Public API and data boundary

Module: `Elzoo.CircuitBreaker`; one consumer-supervised local GenServer per circuit.
These signatures define this new Piece Contract:

- `start_link(opts) -> {:ok, owner_pid} | {:error, reason}`. Child specification uses
  `restart: :temporary`. Required `name` is a caller-declared static atom; registering that
  GenServer name must succeed **before** any upstream install. Duplicate start must not
  reinstall/reset another owner's fuse. API operations target the **pid**, not a name
  that can silently resolve to a replacement. No Elzoo.Application is required.
- `admit(owner_pid) -> {:ok, permit} | {:refused, reason} | {:error, reason} | {:unknown, :owner_call_timeout}`.
  Admission commits in the owner's serialized callback. A successful permit is an opaque,
  volatile token bound to owner incarnation, epoch, reference and actual calling pid.
  It represents one already-admitted attempt, not a reusable credential or a durable lease.
- `finish(owner_pid, permit, observation) -> {:ok, :applied} | {:error, reason} | {:unknown, :owner_call_timeout}`.
  Only the holder may report, once. Observation is exactly `:healthy | :unhealthy |
  :neutral | :unknown`. No payload, exception, URL, envelope or provider response enters
  this process. An unrecognized or malformed observation is rejected unchanged; literal `:unknown` is accepted. the caller
  must then submit `:unknown` or let the observation expire. It must not become healthy.
- `abandon(owner_pid, permit) -> {:ok, :applied} | {:error, reason} | {:unknown, :owner_call_timeout}`. The holder retires an
  unfinished attempt as `:unknown`; it asserts that it will not use that permit again.
  This does not stop another task or undo an Effect. No permit transfer API.
- `status(owner_pid) -> {:ok, snapshot} | {:error, reason} | {:unknown, :owner_call_timeout}`. Snapshot contains only mode,
  epoch, tracked count, recovery-probe-held flag, cooldown remaining in milliseconds and
  effective fixed settings. It never returns holder pids, permits, raw failures or a
  claim of upstream health. Inspection is not a durable receipt or a telemetry event.

The caller obtains a permit immediately before the bounded Adapter attempt and reports
its observed result; waiting/caching and delegation of permits are unsupported. Other
permits admitted before a trip may already have dispatched and can finish. There is no
atomic transaction between admission and network I/O, and no claim of revoking those Effects.

No new `core/envelope` fields, classes or result tags. A caller composing an **actual
pre-dispatch circuit refusal** into the unchanged DeliveryResult may map it to
`rejected/not_dispatched/unavailable` with existing correlation. A permit/report/control
call timeout is not that refusal and must not be translated as attested no-send.

## Fixed Config and Needs

| Setting | Type, bounds and default | Application point |
| --- | --- | --- |
| `name` | Required existing atom selected in application code; finite deployment-defined names, never atomized user input | Exclusive local owner registration; stable upstream name `{:elzoo_circuit_breaker, name}` |
| `role` | `:object_store | :notification | :model | :other`; default `:other` | Bounded observation label only |
| `cooldown_ms` | Integer 1..60000; default 1000 | Construction; minimum local reopen delay |
| `observation_timeout_ms` | Integer 1..60000; default 5000 | Construction; freshness of each admitted observation |
| `max_tracked` | Integer 1..4096; default 128 | Construction; permit ledger via unchanged Backpressure |
| `clock` | Zero-arity trusted monotonic-ms capability; default `System.monotonic_time(:millisecond)` | Sampled by shell on state-changing operations and expiry handling; explicitly passed into pure decisions |

Unknown options, invalid types and invalid bounds are rejected before upstream install.
There is no hot reconfiguration, desired/effective lag, threshold option or probe-count
option. Changing these settings requires explicitly replacing the owner, accounting for
old in-flight Effects first. Replacement loses all local history and starts in probation.

Needs are more explicit than the disposition's shorthand **“None”**:

1. Consumer-owned supervision and a bounded set of static circuit names; exactly one owner
   for each named dependency/failure domain. No dynamic per-request/tenant circuit creation.
2. Started `:fuse` application 2.5.0, its standard OTP `:sasl` dependency, and its unmodified
   default `fuse_stats_ets` plugin. `:fuse` has VM-wide registered processes and configuration;
   it is not an isolated per-Piece supervisor. No per-call global environment changes.
3. Trusted local monotonic clock and truthful finite health observations. The circuit has
   no provider credential, storage or network Need of its own; wrapped Adapters retain theirs.
4. Caller-owned operation bounds/timeouts and current Adapter failure translation; the Piece
   does not replace resource admission or reconcile an unknown Effect.
5. Optional observer handlers must be nonblocking and trusted. Their export/drop/buffering
   policy belongs to the consumer. No exporter, audit sink or health polling service is added.
6. Only this owner mutates its upstream fuse name. Direct `reset/install/remove/enable/disable`
   by another process is outside the Contract. Trusted BEAM code can bypass it; no sandbox.

## Classification: health evidence is distinct from retry permission

This Piece accepts a finite observation, not an arbitrary classifier executed inside the
owner. The consumer's Adapter translation must record the following explicit policy:

| Observation | Meaning and examples | Circuit consequence |
| --- | --- | --- |
| `healthy` | A successfully validated response from the selected dependency, e.g. successful S3 HEAD/GET or declared NoSuchKey on a read | Retire permit; successful **current recovery probe** closes probation |
| `unhealthy` | Declared availability failure: transport connect/loss, provider timeout, selected 5xx/overload; SMTP connect failure where the scope is the fixed relay | Trip/retrip |
| `neutral` | Caller validation, missing local credential, denied access/auth, rejected recipient, caller saturation, unsupported feature, pre-dispatch expiry; throttling excluded from shared-provider health in this subset | Retire; never rehabilitate probation |
| `unknown` | No reliable health observation: Adapter crash, unclassified reply/result, indeterminate dispatch, holder death, observation expiry | Pessimistically trip/retrip; do not assert the dependency was unhealthy or the Effect absent |

For the S3 fixture, `found/absent` are healthy; `unknown{deadline,transport,server_error}`
are unhealthy; other unknowns remain unknown; refusals are neutral. A local test composition
must translate the real selected Adapter result, not just feed synthetic atoms to the owner.
Do not classify every retryable error as unhealthy, every HTTP response as healthy, or every
permanent error as no-send. Explicitly identified throttling is neutral. The selected S3 Adapter does not preserve
that distinction: HTTP 429 becomes unknown{unexpected}, and HTTP 503 including SlowDown
becomes unknown{server_error}; these follow the declared unknown/unhealthy policy and may
trip the circuit. Exercise both actual Adapter paths without changing that Adapter.
Permission failures and invalid requests are neutral where the Adapter identifies them. No inference of replay safety,
provider idempotency, acknowledged delivery or cost from a health observation.

## State, transitions and invariants

State is volatile and single-node. It owns `mode`, fresh incarnation, monotonically advancing
epoch, bounded permit ledger (max_tracked includes any retained recovery probe), optional recovery-holder fence, local cooldown target, and
last accepted clock sample. Modes are `:closed`, `:open`, `:half_open`, `:unavailable`.
Upstream fuse state is separate and never mislabeled as public health certainty.

- Startup installs the named fuse and enters **half_open with no probe** (cold probation),
  even though upstream starts `ok`. One healthy probe is needed before ordinary admission.
- Closed admission checks `:fuse.ask(name, :sync)` and the ledger bound. `:async_dirty` and
  `:fuse.run/3` are excluded. Each successful admission records one token and expiry.
- Current unhealthy/unknown completion, current observation expiry, or current holder DOWN
  invalidates that epoch, invokes **one actual upstream `melt`**, and opens the circuit.
  After melt, confirm that the named fuse still exists with a synchronous ask: missing-name
  `melt` itself returns `ok` upstream and must not be treated as successful installation.
  `blown` confirms a trip; `ok` can mean reset already occurred with a short cooldown.
  Local `open_until = monotonic_now + cooldown_ms` is recorded after successful interaction.
  No synthetic repeated melts to manufacture a threshold. Failure/timeout of provider
  interaction enters unavailable instead of guessing the fuse state.
- Open admits nothing before `open_until`. At/after it, a synchronous upstream `blown`
  still refuses; upstream `ok` changes the public mode to half_open, never directly closed.
  A retained unfinished recovery holder still prevents a new probe.
- Half-open admission is serialized: **at most one recovery permit is outstanding**.
  Healthy current finish closes; unhealthy/unknown opens; neutral finish leaves half_open
  without a holder. Normal completions from an older epoch never close probation.
- A valid completion consumes the permit exactly once. Malformed, duplicate, foreign-owner,
  wrong-holder and stale-epoch reports cannot mutate health or cooldown. After trip,
  ordinary old permits are removed with their timers, monitors and bookkeeping retired; later reports are stale and never forwarded to fuse.
- Observation expiry is `now >= admitted_at + observation_timeout_ms`. It is a freshness
  deadline, not an assertion of execution termination. Expired **recovery** permits retain
  their exclusive recovery-holder fence until the original holder finishes/abandons or
  is observed DOWN; an elapsed timer alone never recycles that fence. An authenticated original holder finish or abandon on that invalidated retained probe
  retires its fence, timer and monitor exactly once and returns {:ok, :applied}; it discards
  the old health observation and changes neither health nor cooldown. Matching DOWN does
  the same retirement. If the call first discovers expiry, apply expiry once before retiring.
  Wrong-holder and duplicate reports cannot retire the fence. Subsequent old messages cannot
  retire a new probe. This is the explicit exception to ordinary stale-permit rejection. A hung holder can
  therefore stall recovery indefinitely; progress is conditional, not a bounded-liveness law.
- Reuse `delivery/backpressure` unchanged for tracked permit admission/release. Saturation
  queues/evicts nothing. Clearing invalidated ordinary permits concerns this ledger only,
  not the caller's actual capacity. Internal timer/monitor messages are keyed by incarnation
  and permit reference; stale messages do not retire a newer permit or change its decision.

The probe bound concerns local permits for this owner, **not concurrent external requests**.
Old normal Effects, Effects surviving a timeout/dead caller, or work from a previous owner
may overlap a recovery probe. Enforcing a physical resource bound is the pool's responsibility.

## Clock semantics and upstream reset limitations

Time units are milliseconds; absolute monotonic samples can be **negative**. Compare only
samples from the same local runtime/clock. Never persist or compare them across VM boots.
An invalid/raising/regressing clock refuses new admission and cannot produce a healthy
transition or invented expiry. A later valid nonregressing sample may resume evaluation.
Pure Cure sees explicit sampled data; it does not read a clock or arm timers.

OTP timers may arrive late. At every relevant observation, recompute expiry/cooldown from
the sampled clock; tokenized timers are wakeups, not authority to accept stale success.
Large forward monotonic progress expires observations and permits cooldown evaluation;
it does not fabricate recovery. Wall-clock/NTP/DST changes supply no circuit input.
The injected clock must correspond to actual local monotonic progress: advancing only a
fake owner clock cannot advance fuse's private real timers. No shared-host wall-clock
mutation or cross-host clock guarantee is required for tests.

Upstream 2.5.0 uses **name-only reset messages**; it has no timer-generation API. Therefore
this subset retains its own minimum cooldown target and never trusts upstream `ok` alone
to authorize early recovery, including after name reuse. This is missing fence policy,
not a duplicate rolling-window circuit implementation. A stale reset may change upstream's
internal state, but must not bypass the local target or the one-probe fence. Test this
explicitly; do not claim that upstream's own timer messages are generation-fenced.

## Refusals, unknowns, ownership and restart

`admit` reasons: `:open`, `:probe_busy`, `:tracking_saturated`, `:clock_unavailable`,
`:provider_unavailable`. Refusal means no permit issued by that call. Validation/report
errors: `:invalid_options`, `:invalid_permit`, `:wrong_holder`, `:invalid_observation`,
`:stale_permit`, `:clock_unavailable`, `:provider_unavailable`, `:owner_unavailable`.
For admit, open/probe_busy/tracking_saturated/clock_unavailable/provider_unavailable use
{:refused, reason}; invalid calls and owner_unavailable use {:error, reason}. For finish,
abandon and status, validation/availability failures use {:error, reason}. All operational
call timeouts use {:unknown, :owner_call_timeout}. Only a received admission refusal
attests that the call issued no permit. An unavailable owner/provider fails closed; it never grants a fallback permit.

A completed `finish` acknowledges **local health bookkeeping only**, not the business
operation. If the Adapter outcome is already known, a report failure does not erase it.
If a GenServer call times out (default 5000 ms), processing may still occur; the public
helper must distinguish `{:unknown, :owner_call_timeout}` from refusal. Do not retry an
Effect based on that timeout. A timed-out permit call is not permission to dispatch;
its unobserved token expires conservatively. No exactly-once control/request receipts.

Bind and monitor the original upstream `fuse_server` pid. Check its registered identity
before and after initialization/provider interactions and immediately before every permit
grant, including half-open grants. Any mismatch, DOWN or failed interaction permanently
latches this owner unavailable. Sample the clock again after provider calls so their delay
is included before granting a permit or setting cooldown. This checks observed decision
points; it is not atomic against a crash immediately after the final check.
Monitor the bound upstream `fuse_server` incarnation. Its death or replacement, missing
fuse, invalid provider return or provider-call failure makes this owner **unavailable**.
Do not silently reinstall on `not_found` or attach to a restarted global server.
Provider failure during an in-progress health update is conservatively unavailable,
even if a melt may have applied. Only an explicitly new owner can reinitialize.

Normal stop releases local state; it does not stop business operations. The owner is
`temporary`; no automatic reset-to-closed restart. Explicit replacement registers the
same bounded static name, gets a fresh permit incarnation, reinstalls and starts cold
probation. Late tokens cannot affect it. Prior work/Effects can outlive any owner;
the host must account for them before replacement if it needs a bound spanning owners.
There is no durable circuit state, recovery adoption, cross-VM authority or forced drain.

Use stable finite upstream names because fuse's default stats table retains per-name
counters after remove. Replacing an owner may preserve/reset upstream counters differently
from its local epoch; they are diagnostic observations, not per-epoch receipts. Do not
promise globally bounded memory for arbitrary creation of new names, or delete upstream
private ETS rows. Graceful cleanup may remove only the owner's fuse; correctness must not
depend on cleanup running after kill. The local cooldown and incarnation guards still apply.

## Telemetry / Config / Control applicability

- **Telemetry: supported (proposed)** for one Piece-owned event
  `[:elzoo, :circuit_breaker, :transition]`. Measurements: nonnegative `tracked`,
  `epoch`, `cooldown_remaining_ms`. Metadata: `role` from the finite enum above,
  `from/to` from the four modes, and cause from `:startup | :unhealthy | :unknown |
  :observation_expired | :holder_down | :cooldown_ready | :probe_healthy |
  :provider_unavailable`. No circuit name, permit, pid, endpoint, payload, tenant,
  credentials or exception terms. Emit after state application; loss is possible.
  Use pinned `:telemetry` directly: the existing **runtime/telemetry** Piece accepts
  a different fixed event schema and is NOT broadened or inherited by implication.
  A throwing handler is upstream-detached; a slow handler can delay the owner.
  There is no hard fast-response/observer-isolation claim, exporter or audit durability.
  Consumer Logger/OTP reports and upstream alarm/stats plugins remain outside this
  redaction guarantee; never put secrets into names or observations.
- **Config: supported**, construction-only settings in the table, tested at their bounds;
  no hot updates or rollback API. Inherited upstream globals are stated, never changed
  temporarily inside an operation. Any root config change belongs to class X first.
- **Control: inherited from OTP**, consumer-supervised process stop and explicit replacement
  only. No business pause/resume, drain, manual force-close, reset, authenticated operational
  endpoint or durable command receipt. `abandon` is attempt retirement, not business cancel.

If the coordinator requires all new events to go through a centralized telemetry schema,
admit a separate new-ID prerequisite; do not widen the ready runtime/telemetry Contract.

## Evidence required before readiness (all planned, not claimed here)

The selected pure admission/recovery decision table must use production Cure helpers for the four selected laws below. Keep
provider calls, clock reads, registration, tokens, monitoring and emission in the shell.
Do not duplicate fuse's failure-history algorithm. Required selected production Cure laws:
`stale_observation_cannot_change_health`, `busy_probe_never_admits`,
`open_before_target_never_admits`, `neutral_probe_never_closes`. Check the production
helpers, including false-law/mutation controls; these do not prove the provider, token
identity tests, timer arithmetic or complete runtime invariant. If a selected law cannot
be checked, record the limitation for deliberate Contract review, not a disconnected model.

| Dangerous scenario | Required concrete observation |
| --- | --- |
| Cold startup; upstream initially ok | Exactly one probe, ordinary admission follows only its healthy current finish |
| 32 simultaneous recovery requests | One permit; all others refuse, including with a deliberately delayed first probe |
| First classified failure and later cooldown | Actual fuse melts; open issues no permit; upstream reset leads only to probation |
| Failed recovery / neutral recovery | One failed/unknown probe retrips immediately; neutral never closes |
| Prior epoch success or failure after trip/recovery | Neither rehabilitates nor retrips; no upstream melt for stale health |
| Duplicate, foreign owner, wrong holder, forged token | No health/cooldown/capacity corruption; legitimate holder still works |
| Observation deadline, late timer, exact equality | Expired success cannot close; stale timer cannot change a newer permit |
| Expired but still-live probe | No second recovery permit until retirement/DOWN, even after cooldown |
| Caller exits without finish; arbitrary secret exit reason | Unknown policy; raw reason discarded; no false success/secret in Piece observations |
| Saturated permit ledger / existing Runner or pool exhausted | Typed refusal, zero queue; no hidden task, retry, eviction or capacity release |
| Duplicate owner startup | Original fuse/options/history untouched; registration precedes install |
| Upstream kill/restart or missing name; melt timeout | Old owner unavailable, no blind reinstallation or permit; explicit fresh owner in probation |
| Old name-only reset arriving after new melt/name reuse | Cannot bypass the local cooldown/probe fence (injection is a regression scenario, not race-frequency evidence) |
| Backward/invalid/failing and large-forward clock input | Fail closed without invented time/health; no stale success after time advances |
| Deliberate wall-clock discontinuities in local test model | No effect on monotonic circuit policy; do not change host time |
| Typed outcome matrix at a real provider boundary | Local S3 HEAD/GET fixture: success, 5xx, transport close, recovery; SMTP classification challenge; no paid API |
| Retry composition and unknown dispatch | Existing retry policy/default mode retained; open refusal invokes no Adapter; unknown Effect is not made replay-safe |
| Telemetry absent/failing/slow; secret-bearing invalid inputs | Exact allowlist; business state not undone by optional observation failure; slow-handler latency limit disclosed |
| Stop/replacement while old work exists | New incarnation rejects old tokens; explicitly demonstrate absence of cross-owner physical-work guarantee |
| Independent copied-source consumer | Pin closure, local fuse application startup, own supervisor/clock, all selected tests, no root Elzoo.Application |

The four selected production Cure laws are: stale observations preserve health and request
no melt; a held recovery probe denies admission; open-before-target denies admission under
an explicit comparison hypothesis; a neutral probe never closes. These are decision laws,
not token-authentication, timer-arithmetic, concurrency or OTP proofs. Retained permit state
is bounded; OTP mailboxes, total VM memory and upstream reset timers under lifecycle churn
are not covered by that bound.

Exported circuit tests must be self-contained under the declared circuit dependency closure.
Authorize one root composition test using unchanged object-store (including 429/503),
notification classification and retry APIs. That test is root-only; any copied composition
exercise must explicitly select every participating Piece. No test-only metadata fields
or undeclared fixture dependencies.

Full acceptance still requires the published reviewed issue, dependency reconciliation,
source-copy and negative controls, claim-level metadata, independent implementation/evidence
review, exact-head hosted checks, coordinator merge/merge-commit acceptance and cleanup.
The coordinator owns publication, shared metadata integration, acceptance and merge.

## Separate prerequisites and scope ownership

**Class X prerequisite, before Piece implementation:** ELZ-099 admits `{:fuse, "== 2.5.0"}` into
mix.exs/mix.lock and registry/providers.json with release/checksum/license/provenance.
It is absent at this baseline; an optional ex_mcp requirement is not installation.
Do not combine this with the Piece implementation under current change-class rules.
Dependency acceptance must include the local full `mix check` required for X, independent
pin review and exact-head hosted evidence. Pin remains Cure `208248063d64e621782cd26dd30698ee42850a89`,
Elixir 1.20.4, OTP 29.1.2. No root global fuse config change is requested by this draft.

**Dependency closure recommendation:** retain `delivery/backpressure`,
`delivery/retry-timeout` and `delivery/time` as named Piece dependencies for production
ledger admission and shipped composition tests. Backpressure and clock/timer contracts
are used directly; RetryTimeout is the unchanged semantic/composition prerequisite.
Its closure already supplies core/envelope/request-reply/dead-letter. This is explicit
retention of the disposition prerequisites, not a requirement to start a Runner.
The direct providers proposed are fuse 2.5.0, telemetry 1.4.2, Cure at its existing pin,
Elixir 1.20.4 and OTP 29.1.2. No new pool or Adapter provider is selected.

**Class P after admission/prerequisites:** `pieces/delivery/circuit-breaker/`, one root circuit composition test, scoped
Contract/work record and final coordinator-owned metadata integration. Reuse ready
Backpressure and time contracts. Test composition with existing Adapter/retry interfaces;
do not edit their code or accepted behavior. Any discovered shared schema/toolchain/CI
defect is separately admitted. A library compatibility smoke result is not the full X gate.

**Class C/admission reconciliation:** preserve RC-26 -> ELZ-033 and ELZ-006 prerequisites;
record circuit-only resolution of bulkhead wording, actual Needs, fixed first-failure/probe
scope, provider prerequisite and new operational schema before publication. The historical
registry summary still says “Circuit breaker and bulkhead policy”; the coordinator must
explicitly reconcile it, not silently delete its responsibility. No new Assembly requirement.

Upstream reference: https://github.com/jlouis/fuse/tree/2.5.0 .
ELZ-006 acceptance: https://github.com/balungpisah/elzoo/issues/6#issuecomment-6677696966 .
ELZ-033 acceptance: https://github.com/balungpisah/elzoo/issues/55#issuecomment-6693646277 .
The admission research smoke is not implementation acceptance. Record actual gates and
independent exact-SHA implementation review in the task work record before merge.
