# delivery/circuit-breaker

`Elzoo.CircuitBreaker` serializes volatile local circuit permits over unmodified
fuse 2.5.0. One classified failure trips; one current healthy recovery probe
closes probation. It performs no Effect, task spawning, waiting or retry.
Apache-2.0; fuse remains MIT with its upstream notices.

The [published ELZ-100 Contract](https://github.com/balungpisah/elzoo/issues/186)
is the admission authority. The historical RC-26 title includes resource
bulkheads, but its body assigns capacity to the pool; the later disposition
excludes bulkheads/pools. This bundle implements circuit policy only. Its
bounded permit ledger uses unchanged `delivery/backpressure`; this does not
bound physical requests, release a Runner slot or cancel an Effect.

## Use and Needs

The consumer starts `:fuse` (including OTP `:sasl`, default `fuse_stats_ets`)
and `:telemetry`, and owns supervision. No Elzoo.Application is needed.
Choose a finite deployment-defined static atom for each dependency/failure
domain, never atomized user input. Exactly one owner may mutate that fuse.
Fuse has VM-wide processes/configuration; no per-call global changes are made.

```elixir
{:ok, owner} = Elzoo.CircuitBreaker.start_link(
  name: :object_store_circuit, role: :object_store,
  cooldown_ms: 1000, observation_timeout_ms: 5000, max_tracked: 128)
{:ok, permit} = Elzoo.CircuitBreaker.admit(owner)
# This same process now performs one bounded Adapter attempt, then reports
# its translated observation; do not transfer/cache permits.
{:ok, :applied} = Elzoo.CircuitBreaker.finish(owner, permit, :healthy)
```

Every API targets the original **pid**, not the registered name. Child spec:
`restart: :temporary`. Registration precedes upstream install, so duplicate
startup cannot reset the existing owner's history. Explicit replacement
reinstalls `{:elzoo_circuit_breaker, name}` and starts cold probation with a
fresh incarnation. Callers must account for old work before replacement if
they need physical capacity bounds spanning owners.

Needs also include a trusted local monotonic-ms clock, truthful finite health
observations, caller-owned operation bounds/timeouts and Adapter translation.
Optional telemetry handlers must be trusted/nonblocking; the consumer owns
export/buffering/drop policy. This Piece holds no provider credentials and
has no network or storage Need. Wrapped Adapters retain all their Needs.

## API

- `start_link(opts)` returns `{:ok, pid}` or `{:error, reason}`.
- `admit(pid)` returns `{:ok, opaque_permit}` or `{:refused, reason}`.
  Reasons: `:open`, `:probe_busy`, `:tracking_saturated`, `:clock_unavailable`,
  `:provider_unavailable`. A refusal attests no permit was issued by that call.
- `finish(pid, permit, observation)` and `abandon(pid, permit)` return
  `{:ok, :applied}` for one local bookkeeping application. Abandon means
  unknown health and retirement, never business cancellation or no Effect.
- `status(pid)` returns `{:ok, snapshot}` with `mode`, `epoch`, `tracked`,
  `recovery_probe_held`, `cooldown_remaining_ms`, `settings`. An unavailable
  owner remains inspectable as mode `:unavailable`. No holder, token, name,
  endpoint, failure payload or upstream health certainty is returned.

Validation/availability errors use `{:error, reason}`: `:invalid_options`,
`:invalid_permit`, `:wrong_holder`, `:invalid_observation`, `:stale_permit`,
`:clock_unavailable`, `:provider_unavailable`, `:owner_unavailable`.
The public helper rejects malformed token shapes and non-observation terms
before sending them to the owner; internal raw BEAM calls remain trusted-host
code outside this protection. Malformed/foreign-incarnation permits are invalid; consumed/untracked refs
are stale. Only the original holder can report. An unrecognized observation
is rejected unchanged and must be followed by literal `:unknown` or expiry.

All operational call timeouts use `{:unknown, :owner_call_timeout}` (5000 ms).
Processing may still occur. A timed-out admission is not permission to send;
a report timeout does not erase an already known Adapter result. Neither is
an attested refusal or evidence that an Effect did not happen. Do not retry
an Effect because of a circuit bookkeeping failure.

## Construction Config

| Setting | Default / bounds |
| --- | --- |
| `name` | Required static atom; exclusive local registration |
| `role` | `:other`; one of `:object_store`, `:notification`, `:model`, `:other` |
| `cooldown_ms` | 1000; integer 1..60000, minimum local reopen delay |
| `observation_timeout_ms` | 5000; integer 1..60000, observation freshness |
| `max_tracked` | 128; integer 1..4096, including any retained probe |
| `clock` | `fn -> System.monotonic_time(:millisecond) end`; trusted zero-arity capability |

Unknown/duplicate options and invalid types/bounds fail before install.
Settings are construction-only; no hot update or threshold/probe-count API.
Upstream configuration is fixed at `{{:standard, 0, 1000}, {:reset, cooldown_ms}}`:
MaxR=0 trips on the first actual melt. Snapshot also names effective
`failure_threshold: 1`, `recovery_probes: 1`, `history_ms: 1000`.
This supplies no rolling-window, ratio or consecutive-failure interface.

## Observation policy and composition

The owner accepts exactly four atoms; no arbitrary classifier runs inside it.

| Observation | Policy |
| --- | --- |
| `:healthy` | Validated dependency success; only a current recovery probe closes |
| `:unhealthy` | Declared availability failure; trip/retrip with one actual melt |
| `:neutral` | Caller validation, credentials/auth/access denial, saturation, unsupported feature, pre-dispatch expiry, explicitly identified throttling; retire, never rehabilitate |
| `:unknown` | Unclassified reply, crash, uncertain dispatch, death or expiry; pessimistically trip without asserting unhealthy dependency or absent Effect |

Consumer-owned S3 read translation used in the root fixture: found/absent are
healthy; unknown{deadline,transport,server_error} unhealthy; remaining unknowns
unknown; refusals neutral. The unchanged S3 Adapter loses explicit throttling:
HTTP 429 becomes unknown{unexpected}; HTTP 503 including SlowDown becomes
unknown{server_error}. Those paths may trip. SMTP connect failure for a fixed
relay is unhealthy; identified throttling, auth and recipient refusals neutral;
unclassifiable transaction outcomes unknown. Never equate retry permission,
HTTP response, permanent error and health/no-send.

An actual pre-dispatch refusal may map to the existing DeliveryResult
`rejected/not_dispatched/unavailable` with correlation. A circuit call timeout
cannot. RetryTimeout's default redispatch-forbidden policy, deadlines,
attempts and unknown-dispatch refusal remain unchanged. The root-only
composition test exercises the real S3 and SMTP boundaries and Runner/pool
saturation. A copied composition must select every participating Piece;
Adapters are deliberately outside this bundle's source dependency closure.

## State, freshness and recovery

Modes: `:closed`, `:open`, `:half_open`, `:unavailable`. Startup is half-open
with no probe even when fuse says ok. Closed admission synchronously asks
fuse; cooldown reset permits only probation, never automatic close. Open
before the local target refuses without granting. After it, upstream blown
still refuses; ok permits at most one probe. Neutral recovery leaves
probation; unhealthy/unknown retrips. There is no waiting queue or eviction.

A trip advances epoch, removes old ordinary permits and cancels their timers
and monitors. Stale ordinary health never reaches fuse. An expired recovery
probe retains its exclusive fence, monitor and ledger slot until its original
holder finishes/abandons or is observed DOWN. Its stale health is discarded;
authenticated retirement returns applied without changing health/cooldown,
even if a subsequent clock sample would fail (already-invalidated retirement
needs no new clock or provider interaction).
Wrong-holder/duplicate reports and old timer/DOWN messages cannot free a new
probe. A hung holder can stall recovery indefinitely.

Expiry is `now >= admitted_at + observation_timeout_ms`, including equality.
Negative absolute monotonic samples are valid. Invalid/raising/regressing
clock input refuses admission and cannot accept healthy completion or invent
expiry. A later valid nonregressing sample can resume evaluation. Following
a clock failure after a successful melt, the owner conservatively begins the
full local cooldown at the next valid sample. Timers are tokenized wakeups;
observations re-evaluate time, including after provider calls. Wall-clock,
NTP and DST supply no policy input. Fake clock progress alone does not advance
fuse's real reset timer; the injected clock must track local monotonic progress.

The owner binds/monitors the original registered fuse_server pid, checks it
around provider interactions, after initialization and immediately before
grants. A changed/dead server, missing fuse or failed/invalid interaction
permanently latches unavailable. Melt is followed by synchronous ask because
missing-name melt returns ok. No blind reinstall/rebind occurs. These are
observed decision points, not an atomic guarantee against the next crash.
Fuse uses name-only reset messages: local cooldown and probe fencing prevent
an old reset from granting early recovery, including name reuse; upstream's
timers are **not** generation-fenced.

## Operations and limits

Telemetry is supported through pinned telemetry directly, not through the
unchanged runtime/telemetry Piece's different schema. Event:
`[:elzoo, :circuit_breaker, :transition]`. Measurements are nonnegative
`tracked`, `epoch`, `cooldown_remaining_ms`. Metadata is exactly `role`,
`from`, `to`, `cause`; modes and role are the finite enums above. Causes:
`:startup`, `:unhealthy`, `:unknown`, `:observation_expired`, `:holder_down`,
`:cooldown_ready`, `:probe_healthy`, `:provider_unavailable`. Application
precedes emission. Loss is possible; this is neither a health attestation
nor durable accounting/audit. A failing handler is detached upstream; a slow
synchronous handler delays the owner. No observer latency/isolation guarantee.
Consumer Logger/OTP and upstream stats/alarms remain outside this redaction
contract. Never put secrets in static names or observations.

Config is supported at construction only. Control inherits consumer-supervised
OTP stop and explicit replacement; no business pause/drain/reset, forced stop
of work, authenticated endpoint or durable control receipt is supplied.

State/tokens/history are volatile, local and single-node. Normal cleanup
removes only the owner's fuse; correctness survives kill without cleanup.
Default fuse stats retain per-name counters after remove; use finite names,
never private ETS deletion. Bounded retained state is not a bound on OTP
mailboxes, VM memory or upstream timers under lifecycle churn. Old Effects
can overlap a probe or replacement. No resource bulkhead, delivery guarantee,
replay safety, provider idempotency, durability or cross-owner physical-work
bound follows from a health permit or its retirement.

## Grounding

Four selected **production Cure decision laws**:
`stale_observation_cannot_change_health`, `busy_probe_never_admits`,
`open_before_target_never_admits` (explicit comparison hypothesis),
`neutral_probe_never_closes`. Audit, false-law, hole and four production
mutations run with the shipped tests. These laws do not prove token identity,
time arithmetic, concurrency, fuse or complete runtime invariants.

Finite C1–C23 scenarios cover the decision table, runtime fences, concurrency,
expiry, provider identity/restarts/timeouts in a separate BEAM, operational
schema, real root Adapter composition, and original/renamed independent source
consumers. The copied-source scenario runs all other circuit tests from freshly
compiled source, then a compiler-free VM with its own supervisor/clock and
fuse startup. It reuses pinned upstream dependency artifacts, not catalogue
BEAMs; no cold dependency download or consumer release-assembly claim.
Upstream contracts: fuse 2.5.0 API/stats/reset behavior, telemetry 1.4.2 and
Elixir 1.20.4 / OTP 29.1.2 supervision, monitors, timers and monotonic clock;
Cure commit 208248063d64e621782cd26dd30698ee42850a89. Assumptions remain truthful
observations, trusted host/clock, bounded static names and exclusive mutation.

Copy with the [source-consumption instructions](../../../docs/consuming.md).
Evidence applies to these source bytes/selected claims; rename modules and
public record tags before redistributing copies and rerun checks after edits.

During a clock outage, failed expiry wakeups disarm rather than retry from stale
time. A later API or monitor operation samples time and checks expiry; no automatic
clock-health polling is supplied. An applied trip still emits its transition when
the post-melt sample fails; remaining time is zero until a valid cooldown target
can be established, not permission to admit a probe.
