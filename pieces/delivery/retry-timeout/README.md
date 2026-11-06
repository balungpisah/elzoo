# delivery/retry-timeout

Pure Cure policy + OTP runner. Apache-2.0. A new ready subset; existing
delivery/time, core/envelope, request-reply and runtime/adapter are unchanged.
Depends on core/envelope, request-reply, backpressure, dead-letter and time.
Uses OTP Task.Supervisor, GenServer and tokenized send_after/cancel_timer.

## Pure policy

`Elzoo.RetryTimeout.policy(opts)` returns {:ok, policy} or fixed errors.
Defaults: max_attempts=3, base_backoff_ms=10, max_backoff_ms=1000,
mode=:redispatch_forbidden. Max attempts positive integer; backoff integers
0 <= base <= cap. Mode also allows :redispatch_idempotent, an **unverified
caller assertion** that the provider deduplicates by unchanged idempotency_key
or is naturally idempotent. No durable intent/reconcile protocol is supplied.

`classify(result)` validates core/envelope then returns {:ok, class}:
completed -> :completed; any permanent error -> :permanent; other valid
not_dispatched -> :retryable; other rows -> :dispatched (possible Effect).
`decide(policy, attempts_made, class)` returns {:ok, decision}: completed
settles, permanent dead-letters, retryable retries below max else exhausts;
dispatched is unresolved in default mode, or retries/exhausts only in
idempotent mode. Error labels alone never authorize possibly-dispatched retry.
`backoff(policy, attempts_made)` returns capped base * 2^(n-1), no jitter.
Cure RetryPolicy erases to {:RetryPolicy, max, base, cap, mode}; nullary sums
erase to atoms. Validating Elixir APIs reject malformed foreign values.

## Runner

Caller supervises a Task.Supervisor and runner; no Elzoo.Application needed:

    {:ok, policy} = Elzoo.RetryTimeout.policy(max_attempts: 3)
    {:ok, tasks} = Task.Supervisor.start_link()
    {:ok, runner} = Elzoo.RetryTimeout.Runner.start_link(
      capacity: 4, policy: policy, attempt_timeout_ms: 1000,
      task_supervisor: tasks, attempt: attempt_fun,
      dead_letter: sink_fun)
    {:ok, ref} = Elzoo.RetryTimeout.Runner.submit(runner, envelope)

attempt_fun maps an attempt Envelope to a DeliveryResult map (not {:ok, map});
sink_fun maps a redacted record to :ok or failure. now_ms/0 defaults to
System.os_time(:millisecond), injectable at construction. All Config fixed at
start; no hot updates. Positive capacity/timeout, valid policy and callbacks
required; invalid start options return :invalid_options.

submit/2 returns {:ok, ref}, {:error, {:saturated, result}} (rejected/
not_dispatched/unavailable), {:error, {:expired, result}} (timed_out/
not_dispatched/permanent), or fixed validation errors (:attempt_id_present,
:operation_in_flight, {:envelope, reason}). Admission never dead-letters.
Capacity is admitted in-flight operations **including backoff**, queue length
zero; no shedding. The OTP mailbox is unbounded. GenServer.call default
5000 ms caller timeout means **unknown admission**, not rejection; a settlement
may still arrive later. The caller must not blindly retry it.

Operation identity is effective correlation_id (message_id if absent).
:operation_in_flight applies only while open; resubmission after settlement is
allowed and can execute again. This is **not dedup** (ELZ-005 owns it).
Attempts keep correlation, idempotency_key and deadline; runner sets
attempt_id="<message_id>/attempt/<n>". Caller-supplied attempt_id is refused.
Results must pass Envelope validation and RequestReply.correlate for the
current attempt. Invalid/mismatched results and task exits become
unknown/unknown/unclassified; timeout becomes timed_out/unknown/unclassified,
never a claim of non-execution. An exit reason cannot prove no Effect.

Deadline is translated once at admission from wall clock into local monotonic
elapsed timers. No wall-clock decision is in Cure; later wall-clock changes
are ignored. Delays larger than OTP's 4294967295 ms timer limit re-arm in
bounded chunks against the monotonic target. Timer delivery can be late.
Deadline wins at subsequent runner observations/retry execution when elapsed.
No cross-host clock-skew guarantee. A timeout terminates the local task; an
external Effect may persist and cannot be undone.

The submitting pid receives exactly one local settlement per accepted ref:
{Elzoo.RetryTimeout, ref, {:completed, result} | {:dead_lettered, record} |
{:unsettled, record}}. Completed means only a validated, correlated Adapter
report, **not durable Effect proof**. Dead-lettered means sink returned :ok;
durability is its upstream Contract. Every terminal path cancels timers and
releases exactly one slot. Sink non-ok/raise/throw/exit yields unsettled
without crashing runner. **A blocking sink blocks this runner**, including
admission/settlement/deadline processing; no sink timeout is supplied.

Late/stale task/timer messages never change a settled decision. Late task
replies/mismatched results increment late_or_mismatched; no payload retained
in that counter. snapshot/1 returns capacity/in_flight/open/settled/
dead_lettered/late_or_mismatched as test-observed inspection, **not telemetry
or durable accounting**. Telemetry and business pause/drain/recovery are
planned, not supplied; OTP stop is not business cancellation.

Monitor the runner: DOWN before settlement is **unknown**, never success.
Restart loses all state, starts at full capacity, does not resume work or send
settlements for lost refs. Tasks/Effects may outlive a runner; supervise and
reconcile them at the application boundary. Upstream OTP/Task crash logging
is not redacted by this Piece; consumers own Logger policy.

## Grounding and limits

Pinned Cure checks the production types and six selected helper laws across
backpressure/retry policy (three here: permanent_never_retried,
completed_never_retried, dispatched_not_retried_when_forbidden). Laws constrain
production retry_permitted, not the full decide/runner invariant. Audits reject
axioms/holes/unresolved/unaudited/opaque/not_proven_total. False-law, production
mutation and hole negatives run in mix check. ExUnit covers the full valid
result matrix, decision table, capped backoff, named OTP terminal paths,
concurrent conservation traces, stale tokens, long timers, sink failures,
restart and copied-source consumers. These are finite tests, not universal
proofs. Root tests exercise the unchanged UnitAdapter.

Local single-node volatile policy only: no durability, network-wide delivery,
at-least-once, exactly-once Effect, distributed credit, shedding, circuit
breaker, provider-idempotency proof or durable dead-letter storage. Assumes
truthful Adapter observations, caller-selected idempotency, clock agreement
at admission and external sink durability.
