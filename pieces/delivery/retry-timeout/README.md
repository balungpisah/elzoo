# delivery/retry-timeout

Pure Cure policy + OTP runner. Apache-2.0. A new ready subset; existing
delivery/time, core/envelope, request-reply and runtime/adapter are unchanged.
Depends on core/envelope, request-reply, backpressure, dead-letter and time.
Uses OTP Task.Supervisor, GenServer and tokenized send_after/cancel_timer.

## Pure policy

`Elzoo.RetryTimeout.policy(opts)` returns {:ok, policy} or fixed errors.
Defaults: max_attempts=3, base_backoff_ms=10, max_backoff_ms=1000,
mode=:redispatch_forbidden, jitter=:none, max_failure_delay_ms=3600000.
Max attempts positive integer; backoff integers 0 <= base <= cap. jitter is
:none or :full (else :invalid_jitter); max_failure_delay_ms is an integer in
0..4294967295 (else :invalid_max_failure_delay). Checks run in that order,
after the existing max_attempts, backoff and mode checks. Mode also allows :redispatch_idempotent, an **unverified
caller assertion** that the provider deduplicates by unchanged idempotency_key
or is naturally idempotent. No durable intent/reconcile protocol is supplied.

`classify(result)` validates core/envelope then returns {:ok, class}:
completed -> :completed; any permanent error -> :permanent; other valid
not_dispatched -> :retryable; other rows -> :dispatched (possible Effect).
`decide(policy, attempts_made, class)` returns {:ok, decision}: completed
settles, permanent dead-letters, retryable retries below max else exhausts;
dispatched is unresolved in default mode, or retries/exhausts only in
idempotent mode. Error labels alone never authorize possibly-dispatched retry.
`backoff(policy, attempts_made)` returns capped base * 2^(n-1), no jitter;
jitter belongs to delay/4.

`delay(policy, attempts_made, class, %{failure_delay_ms: fd, random: r})`
returns {:ok, ms}. fd is nil or a non-negative integer (a wait the caller read
from a not-dispatched refusal, such as a rate-limit retry_after_ms); r is an
integer in 0..4294967295 supplied by the caller. With b = backoff and, under
:full, j = (r * (b + 1)) div 2^32 (0 <= j <= b; at r = 4294967295, j = b
when b <= 4294967295 and j < b above that), else j = 0: a :retryable delay is b (:none) or j (:full) when fd is nil, and
max(min(fd, max_failure_delay_ms), b) (:none) or that plus j (:full) when fd is
an integer. A possibly dispatched result's delay is exactly backoff/2:
:dispatched, :completed and :permanent ignore fd, r and jitter. Errors in
order: :invalid_policy, :invalid_attempt, :invalid_class, :invalid_delay_input
(not a map of exactly those two keys in range). delay/4 does not decide whether
to retry (decide/3 does) and may pass the deadline; the caller checks it.
Cure RetryPolicy erases to {:RetryPolicy, max, base, cap, mode, jitter,
max_failure_delay_ms} with jitter :JitterNone | :JitterFull; nullary sums erase
to atoms. The pre-ELZ-357 5-tuple is refused as :invalid_policy. Validating
Elixir APIs reject malformed foreign values.

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
start; no hot updates. For a :retry decision the runner calls delay/4 with
the result's class, failure_delay_ms nil (a DeliveryResult has no delay
member) and a random value it draws in its own process with :rand (not a
cryptographic source); under jitter :none every timer equals backoff/2. Positive capacity/timeout, valid policy and callbacks
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
attempt_id derives from message_id, not the effective correlation_id: open
operations that reuse a message_id under distinct correlation_ids get equal
attempt_ids. Replies are matched by task, so settlement is unaffected, but
producers should keep message_id unique.
Results must pass Envelope validation and RequestReply.correlate for the
current attempt. Invalid/mismatched results and task exits become
unknown/unknown/unclassified; timeout becomes timed_out/unknown/unclassified,
never a claim of non-execution. An exit reason cannot prove no Effect.

Deadline is translated once at admission from wall clock into local monotonic
elapsed timers. No wall-clock decision is in Cure; later wall-clock changes
are ignored. Delays larger than OTP's 4294967295 ms timer limit re-arm in
bounded chunks against the monotonic target. Timer delivery can be late.
Deadline wins at subsequent runner observations/retry execution when elapsed.
No cross-host clock-skew guarantee. Attempts start with child shutdown
:brutal_kill. Whenever the runner stops tracking an attempt (reply, crash,
attempt timeout, deadline expiry or settlement) it removes the child with
Task.Supervisor.terminate_child/2, which kills it with an untrappable :kill
and returns once the supervisor has removed it. A task that traps exits
therefore cannot hold the runner for the 5000 ms default shutdown, and with a
responsive supervisor the child's max_children slot is free before any retry,
resubmission or settlement. This is a synchronous call with no timeout, not a
latency bound: the runner waits for the supervisor to reply, so a busy or
unresponsive Task.Supervisor delays or blocks the runner, including admission.
Give the runner its own Task.Supervisor, or share one only with children that
also use :brutal_kill. If the supervisor has died, or a restarted named
supervisor no longer owns the child, the runner sends the original task an
untrappable :kill and does not wait for it. Task cleanup code does not run; a
later reply or DOWN is ignored as late. An external Effect may persist and cannot be undone. A task that
cannot start (supervisor down, or max_children taken by children the runner
does not own) is recorded as unknown/unknown/unclassified, never
not_dispatched.

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

Pinned Cure checks the production types and thirteen selected helper laws
across backpressure/retry policy (ten here: permanent_never_retried,
completed_never_retried, dispatched_not_retried_when_forbidden,
delay_completed_is_backoff, delay_permanent_is_backoff,
delay_dispatched_is_backoff, delay_retryable_none_without_failure_is_backoff,
delay_retryable_none_with_failure_is_max,
delay_retryable_full_without_failure_is_spread,
delay_retryable_full_with_failure_is_max_plus_spread). Laws constrain
production retry_permitted and the delay equalities by class and jitter kind,
not the full decide/runner invariant, the jitter ranges or boundary
validation. Audits reject
axioms/holes/unresolved/unaudited/opaque/not_proven_total. False-law, production
mutation and hole negatives run in mix check. ExUnit covers the full valid
result matrix, decision table, capped backoff, a golden backoff/decide table
recorded before ELZ-357, delay/4 cases and a jitter sweep with its range
bounds, the runner's class and random use, named OTP terminal paths,
concurrent conservation traces, stale tokens, long timers, sink failures,
restart and copied-source consumers. These are finite tests, not universal
proofs. Root tests exercise the unchanged UnitAdapter.

Local single-node volatile policy only: no durability, network-wide delivery,
at-least-once, exactly-once Effect, distributed credit, shedding, circuit
breaker, provider-idempotency proof or durable dead-letter storage. Assumes
truthful Adapter observations, caller-selected idempotency, clock agreement
at admission and external sink durability.

delay/4 returns a number; this Piece sleeps only in its runner, and a caller
that waits elsewhere owns its timer. A failure delay is the caller's reading of
the failure; this Piece does not check that the failure named it. The clamp
bounds the wait a failure can ask for; a delay above the deadline is still
returned, and the runner's deadline wins as before. Full jitter can give 0 for
a retryable result without a failure delay. The jittered range bounds are
finite test evidence, not laws.
