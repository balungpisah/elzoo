# assembly/request-route-retry

Apache-2.0. An opt-in, ready subset composing existing Pieces without changing
their Contracts. The exact implementation Contract and S1–S22 scenario table
are in `docs/work/ELZ-008.md` in the source repository.

## Owned versus reused

| Owned here | Reused unchanged |
| --- | --- |
| Cure labelled window answer, fused worker | WindowedIdempotency.classify/step; Core.accumulate; Composition records |
| Exact integer codecs; hop result combination; outer identity translation | UnitAdapter.deliver; Unit; Envelope; Transformation |
| Visible topology, fixed selection-to-delivery table, request/reply assembly | Wiring/Edge/Port; Assembly; Selection; Routing; RequestReply |
| No private retry/queue/timer/counter | RetryTimeout.Runner, Backpressure, DeadLetter, Time |

`topology(:fused | :hop)` exposes wiring, routes, requirement, candidates and
interfaces. `check_topology/1` checks Wiring, Routing, Assembly then Selection;
first failures are tagged `{:topology, phase, reason}`. Selection validates
compatibility but does not choose placement or certify the implementation.
The gateway/result.in descriptor is the logical decoded value receipt, not an
extra mailbox. Only `example/rr-result` v1 is a final completed value.
**Fused delivery labels the internal dedup→accumulate seam; work crossing into
the worker is a volatile Adapter entry over the work hop.** Unconnected ports
are optional routes. Hop dedup→accumulate crosses two volatile Units.

## Construction and API

Call `initial_state(placement, window, max_senders)` with positive integers.
For fused, supervise `Elzoo.Unit` with
`{:"Cure.Elzoo.RequestRouteRetry", :worker, states["worker"]}`. For hop,
supervise dedup with `{:"Cure.Elzoo.RequestRouteRetry", :labelled_dedup,
states["dedup"]}` and accumulate with `{:"Cure.Elzoo.Core", :accumulate, 0}`.
Caller owns Unit and Task.Supervisor lifetimes; root Application is unnecessary.

`start_link/1` returns the unchanged Runner pid. Pass `placement`, `units`
(exactly worker or dedup/accumulate lookup map), `window`, `max_senders`,
`capacity`, validated `policy` from `Elzoo.RetryTimeout.policy/1`,
`attempt_timeout_ms`, `task_supervisor`, `dead_letter`, optional `now_ms`.
Lookups are pids, zero-arity functions, nil, :undefined or :restarting.
Config is fixed at start; there is no hot reconfiguration. Validation starts
no child on failure. `submit(runner, request)` routes before Runner admission.

Requests are unchanged Envelope v1 maps: command, producer client/request,
schema example/rr-request v1. Payload has exactly sender, incarnation, sequence,
value string keys with integer values. Optional correlation, idempotency key,
deadline, reply_to retain their unchanged meaning. No wire atoms are created.
Malformed payload is permanently rejected before worker execution. Other kinds
and foreign producers are synchronous routing refusals with zero dispatch.

Worker results label every input: fresh/advance/reorder/new_incarnation carry
an integer total; duplicate/stale/superseded/full carry nil. No suppression is
an unlabelled success. WindowInvalid is rejected by codecs. Hop intermediate
dedup-outcome and total schemas never escape as completed final values.
`direct(state, payloads)` returns `{values, next_state}` without OTP for valid
payload traces. `reply(request, settlement, reply_message_id)` builds a reply
or error Envelope carrying a client-identity DeliveryResult, no attempt_id,
and the exact request deadline Option. Caller owns delivery to reply_to;
`RequestReply.accept_reply/3` checks it. A reply is not an acknowledgement.

Every submit returns either a synchronous error (nothing admitted) or an ok
ref followed by exactly one unchanged Runner settlement while the Runner
lives: `{Elzoo.RetryTimeout, ref, {:completed, result} | {:dead_lettered,
record} | {:unsettled, record}}`. DOWN before settlement is unknown. Submit
call timeout means unknown admission. Sink non-ok/raise/exit is unsettled;
blocking sinks block the Runner. Capacity includes backoff, queue length zero;
the OTP mailbox remains unbounded. No ordering across operations is promised.

## Delivery classes and limits

Default redispatch_forbidden gives local at-most-once possibly-dispatched
attempt per admitted operation and Runner lifetime: only explicit
not_dispatched absence can retry. Dead pid, exit, timeout or unknown execution
never establishes non-execution. Opt-in redispatch_idempotent permits
at-least-once attempting under caller assertion, grounded here by the payload
sender/incarnation/sequence window, **not Envelope idempotency_key**. A retry
after application reports duplicate/nil: it cannot recover the earlier total.
The key must remain inside the surviving volatile window.

**S17:** hop partial failure can advance dedup without accumulating. A
second-hop rejection, even not_dispatched, is conservatively dispatched and
unresolved; there is no atomicity or placement equivalence under failure.
**S22:** Unit restart resets the window; an earlier key is accepted again.
No durable log, dead-letter storage, attempt budget/deadline across restart,
crash-spanning at-least-once guarantee, broker/network transport or exactly-once
Effects. No generalized wiring engine. OTP crash logging can expose Unit state;
consumer owns Logger policy. Callback exceptions retain dependency Contracts.

Assumptions (unverified): truthful Adapter observations, sender sequence
discipline, admission clock agreement, sink durability, caller supervision.

## Grounding and operations

Proof: pinned Cure checks labelled_duplicate_keeps_state,
labelled_duplicate_not_accepted, labelled_full_keeps_state for supplied
decisions in label_step only; not classify, worker, Runner or traces.
Type/contract: real Cure imports, exact codecs and unchanged connection
validators. Tests: finite bundle checks, false-law/production-mutation/wrong-type
negatives; root S1–S22 and isolated copied-source consumers. Upstream: Cure
a004c335, Elixir 1.20.4, OTP 29.1.2. Monitored behavior: none.
Telemetry planned (snapshot is inspection); Config supported at start only;
Control inherited from Runner (OTP stop, not business drain).
