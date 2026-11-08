# ELZ-023 — Specify dispatched-effect intent with unknown-outcome recovery

- Phase: demand-led delivery policy
- Catalogue IDs: delivery/effect-intent (new handle); consumes state/checkpoint
- Dependencies: ELZ-006, ELZ-009

## Outcome

Make "a timeout after dispatch is an unknown outcome" executable. Before an
irreversible external Effect is dispatched, its intent is checkpointed under
a key derived from the logical request; on resume the intent is found and
polled or reconciled instead of re-dispatched. The lifecycle is a pure state
machine; the store and the provider poll are Adapters.

## Admission record

1. **Responsibility and caller.** Own the lifecycle of one outward effect
   intent: `none → intended → dispatched → confirmed | failed_definite |
   stranded`, and decide whether dispatch may be (re-)armed. Callers: C3 refund/provider call,
   C6 publish Effect, C9 provider charge. The same shape serves a
   deterministic email or webhook sender.
2. **Interface and invariant.** Inputs are host-derived logical request identity,
   a binding-declared provider replay contract, a correlated core/envelope
   delivery result, trusted poll/reconciliation evidence and evaluation time.
   Consume exactly the eight ready outcome/dispatch pairs:
   `completed/dispatched`, `rejected/not_dispatched`, `failed/dispatched`,
   `timed_out/{not_dispatched,dispatched,unknown}` and
   `unknown/{dispatched,unknown}`. `unknown/not_dispatched` is invalid.
   Require attempt_id matching a recorded attempt, matching request/correlation
   identity and the binding's output schema; the ready Envelope remains unchanged.
   Outputs are next state and `dispatch`, `poll`, `reconcile` or `stop`.
   One host-controlled intent owner serializes operations; Store CAS arbitrates
   expected revisions. Every local send requires its own newly committed
   dispatched reservation; a recovered reservation can only poll.
   Both intended and dispatched barriers require acknowledged append AND
   checkpoint before the first local send. Preflight their projected capacity
   before append; rejected, conflicting or indeterminate writes never authorize
   a send. The first dispatch is not rearm. Every path from dispatched to a
   later dispatch passes through durable failed_definite carrying exactly one
   of three grounds: adapter_no_send, provider_no_effect, provider_replay_safe.
   A correlated rejected/not_dispatched or timed_out/not_dispatched after a
   reservation first records failed_definite(adapter_no_send). A permanent
   rejection additionally disarms it until a permitted argument/schema revision.
   Argument/schema failure before reservation creates no attempt and leaves
   intended disarmed. Capacity refusal never authorizes a send.
   The binding attests per typed failure variant that adapter_no_send means no
   request bytes were handed to transport; that truth is an upstream Need,
   not a proof. A provider_no_effect certificate must be authenticated, bound
   to the exact operation/attempt and final: delayed processing of that attempt
   cannot later produce the effect. Generic failed, partial failure, transport
   error and absence at a point in time do not certify no effect.
   NARROW replay applies: provider_replay_safe arises only from poll/reconcile
   unknown_to_provider under a valid binding-declared replay capability.
   Failed/dispatched, timed_out, unknown, pending and unavailable observations
   alone never create it, even under a replay-capable binding. Bare permanent
   or retryable labels on possibly-dispatched results still require poll or
   reconcile; do not reuse RetryTimeout.classify's permanent-first rule here.
   unknown_to_provider never proves no effect; without valid replay capability
   it is stranded. A crash, expiry or task death alone never rearms.
   Rearm is explicit and bounded; provenance Intended(Fresh | After(ground))
   and attempt state are carried inside the pure policy's state. Stranded
   remains terminal for dispatch, visible and requiring operator reconciliation.
3. **Reuse check.** Oban uniqueness and retry bound job execution, not the
   external effect's outcome; delivery/idempotency suppresses duplicate
   inbound deliveries only. Provider idempotency keys are reused when the
   provider offers them; this Piece owns the local intent record and the
   re-arm decision. A missing store is a hard error in a deployed release.
4. **Split test.** Checkpoint-before-dispatch and the re-arm decision share one
   invariant and stay behind one interface. Poll cadence, deadline policy and
   the provider Adapter are separate choices.
5. **Failure and evidence.** Dangerous paths: re-dispatch after timeout
   (double refund/publish); a crash between checkpoint and dispatch leaving an
   intent that was never sent (it is already `dispatched`; resume polls,
   and poll must distinguish `unknown_to_provider` from `pending`); a crash
   after the send but before any acknowledgement (same record, same poll
   path, never a second send); a `failed/dispatched` result with a partial
   effect re-sent as if definite; store unavailable at dispatch time.
   Proofs: the state-machine laws that the only transition out of
   `dispatched` that re-arms dispatch passes through `failed_definite`,
   that `failed_definite` is reachable only on one of its three recorded
   grounds, that `stranded` admits none, and that `unknown_to_provider`
   without a provider idempotency contract never reaches `dispatch`. Tests: crash/restart at each boundary with a provider
   double; webhook duplicate/out-of-order after confirmation. Upstream:
   provider idempotency and store durability are named contracts.
6. **Composition record.** Depends on ELZ-006 failure classes and deadlines,
   ELZ-009 checkpoint storage and core/envelope result schema. Ordering with
   the business state change (C3 payment lifecycle) is an outbox concern.
   Data classification: may carry payment references; redact in telemetry.

## Scope

- define the intent record, derived key and pure transition;
- reuse Elzoo.DurableLog.Store and its Memory double; define the intent-specific
  codec/fold/binding and conformance fixtures over them and integration/sql;
  no parallel CAS/uncertainty behavior or storage engine;
- select the no-re-arm law; test the listed crash/restart boundaries;
- document how a product reconciles `stranded` intents.
- require the Adapter binding to supply a total mapping from its typed
  failures to the ready delivery-result classes when the Assembly is built;
  an absent or partial mapping is refused at build, not at the first failure;
- revalidate admitted arguments against the Adapter's current schema before
  reservation; a mismatch is rejected/not_dispatched/permanent, creates no
  attempt and disarms intended, host-visible rather than proposer-visible;
  pass the checked schema revision to the Adapter so later schema drift is
  rejected before sending; revisions obey the identity rules below;
- one decisive settlement wins by durable CAS per attempt; pending, timeout
  and unknown are observations, not winning settlements; an authenticated
  older completion may confirm a nonterminal intent only when every intervening
  rearm was provider_replay_safe and operation key, payload and binding match,
  including intended-after-rearm and failed_definite as well as dispatched;
  completion contradicting adapter_no_send or provider_no_effect records a
  contradiction and freezes rearm pending operator reconciliation, never merely
  an ordinary stale result; confirmed/stranded remain terminal for dispatch;
- unavailable/indeterminate evidence writes halt active ownership and are
  unknown, never reported as retained; inability to retain a contradiction
  cannot leave rearm enabled; after an uncertain halt, restart is read-only
  until host/operator reconciliation re-establishes an authoritative outcome
  and valid ground; the host must preserve/deliver this recovery obligation
  across restart, because an in-memory flag is not durable quarantine;
- make replay a declared Adapter capability (provider idempotency contract
  keyed by the logical request), never a per-call flag; list as dangerous
  paths a transport-layer plugin (auth refresh, redirect, library retry) that
  re-sends a dispatched non-idempotent request without a second recorded
  Attempt, an exception-keyed step retry, and an agent-runner idle timeout
  after a durable output or tool record (that is `dispatched`/unknown; a
  retry is admissible only on a durable predicate that no such record exists,
  which is the `provider_no_effect` ground with the runner's record store
  as the provider confirming no effect) (ELZ-025 study).

## Identity, replay capability and host Needs

The host supplies stable `(tenant, provider_account, adapter_id, operation_kind,
logical_request_ref)` identity. Derive the operation key by SHA-256 of a
versioned length-framed encoding; attempt identity never enters this key.
Exact duplicate admission finds the existing intent; same identity/different
argument digest conflicts. Argument revision requires all previous attempts
durably certified never sent, plus a binding declaration of same-key changed-
argument semantics; cached-result semantics refuse revision. No revision erases
possibly-sent history, changes provider scope or mints a new operation key.

Replay capability names provider/account scope, same-key/same-argument semantics,
clock and validity horizon anchored at the earliest possibly-sent attempt's
dispatched record. A new send's maximum in-flight lifetime plus stated clock
allowance must fit inside that horizon; absent a usable bound, refuse replay.
The host retains the intent or a refusal tombstone through both the provider-key
horizon and business duplicate-request horizon; deletion is not replay authority.

CAS reserves a send, but does not retract a paused old owner's future network
call. The host controls live ownership; replay safety or a final certificate
fencing the old attempt must cover pause-after-reservation/delayed-send cases.
Authenticated observations, Adapter no-send truth, provider idempotency and
storage durability remain external Needs. If wrapping the ready retry Runner,
use one attempt and redispatch_forbidden; no hidden transport re-send is allowed.
Memory is volatile and cannot silently stand in for deployed durability.
Keep owners ephemeral, not a new registry service. The consumer owns storage
access control and classification for persisted arguments. Declare actual
Telemetry/Config/Control applicability at readiness; redact payment references.

Stranded never rearms. An operator verifies at the provider and the host records
the business resolution; optional bounded operator evidence does not change the
terminal phase. Only a verified no-effect resolution permits a separately
authorized new logical request. Creating a new key for an unverified stranded
operation risks a duplicate effect and is not recovery supplied by this Piece.

## Bounded priority evidence and deadlines

Owner decision R-D deliberately replaces the former unbounded promise that
every refused late result is retained with **bounded priority retention**:
finite Store/checkpoint limits cannot support unbounded evidence. Reserve before
dispatch capacity for each admitted attempt's decisive settlement, first
contradictory completion and first refused result; these priority records must
be retained when storage commits, not displaced by routine observations.
An unavailable/indeterminate priority write halts ownership and is never reported
as retained. Routine pending/unavailable observations use bounded counters;
anything else that cannot be retained returns explicit host-visible not-retained.

Provisional numeric ceilings, requiring an encoding/reservation probe and focused
review before implementation: identity fields 256 UTF-8 bytes; arguments 64 KiB;
combined attempts/revisions 256; evidence 1024 records of at most 512 encoded
bytes each; committed events 4096; append records 128 KiB; encoded checkpoints
1 MiB each, including model, cursor, identity witnesses, framing and digest;
Store max_batch_size at least 1. Reserve three evidence slots (1536 payload
bytes) per attempt plus actual event/framing/seen-index growth. Start-time Store
limits must meet these requirements. Preflight projected append and both
checkpoint barriers with reservations before append. Count immutable snapshots
as cumulative disk use: the 1 MiB limit is per checkpoint, not total storage;
at most one checkpoint per event and no automatic pruning. Smaller proven
ceilings are preferred; no capacity claim is admitted solely from these numbers.
Capacity exhaustion while dispatched freezes dispatch and keeps reconciliation
available; it cannot erase the settlement reserve or rearm permission rules.

The request's deadline_unix_ms blocks new dispatch/rearm at now >= deadline.
Trusted binding recovery_grace_ms is none (default) or a nonnegative integer;
finite grace derives a recovery deadline by checked signed-bigint addition to
the request deadline, rejecting overflow. Dispatched becomes stranded at that
recovery deadline; none permits host-driven polling within other bounds.
Neither expiry creates a rearm ground. Late completion after stranded follows
the operator-evidence path, never automatic reopening. Time is trusted host
input; no cross-host clock-skew guarantee is inferred.

## Acceptance

- [ ] A simulated timeout after dispatch never re-dispatches without a definite
      failure or reconciliation result.
- [ ] Restart at each boundary resumes the existing intent by derived key.
- [ ] `stranded` is a distinct, tested outcome with a documented operator path.
- [ ] Build-time total failure mapping, late-settlement-once and the
      transport re-send negative case are listed, executable scenarios.
- [ ] Selected law and scenarios run through mix check.
- [ ] Contract labels provider idempotency and store durability as upstream.

- [ ] All eight result pairs and missing/mismatched attempt identity are tested;
      no-send rearm passes failed_definite, pre-reservation failure has no attempt,
      permanent rejection disarms, and a positive first dispatch succeeds.
- [ ] Narrow replay, partial effect, pending/unavailable observations, capability
      horizon/lifetime/clock bounds, argument revision and duplicate terminal
      admission have explicit scenarios; absent capability never treats not-found
      as no-effect proof.
- [ ] Race late completion and reconciliation in both orders; test old replay-safe
      completion before/after a new reservation, contradictory completion, failed
      evidence writes and read-only restart; pause an old owner after reservation
      while a new owner recovers, then release its delayed send.
- [ ] Probe actual encoding at every numeric boundary and limit+1, worst-case
      reserved priority evidence and witnesses, undersized Store startup,
      saturation, refused evidence writes and cumulative snapshot storage.
- [ ] Admission expiry, recovery none/finite grace, checked overflow and late
      completion after stranded never authorize a new send.
- [ ] The strengthened policy probe carries provenance and attempt state, asserts
      its initial state and positive dispatch, and keeps deadline/disarm/capability
      guards in Cure; silent-return Pending/Expired/Resume/Lost/timeout/failed
      mutants and groundless rearm must be rejected, and always-stop must fail
      a positive scenario; the earlier four-law probe is not the no-rearm law.
- [ ] Restart's host reconciliation interface and numeric reservation arithmetic
      receive focused independent clearance before production implementation.

## Evidence and limits

The production selected law must ground the re-arm rule; tests ground listed restart and
duplicate scenarios. No exactly-once external effect is claimed.

## Out of scope

No payment provider integration, outbox implementation or distributed lock.

## Reference

Shape observed in Raxol's payments checkpoint and `stranded` failure; see
docs/research/orchestration-references.md. No code is copied.
