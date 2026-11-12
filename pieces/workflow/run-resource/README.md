# workflow/run-resource

One Run's live resource, with a serialized owner, one active use, a bounded
FIFO, a deadline, retained usage and one immutable cleanup intent. Run identity
and outcome are opaque. No real provider or Run engine is supplied.

## Host boundary and use

The supported public interface is `Elzoo.RunResource.start_link/1`, `command/2`
and `read/2`; GenServer callbacks are implementation plumbing, not alternate
admission interfaces. Start with exactly `%{lease: lease, held: held,
clock: clock, resource: resource}`. The existing Lease claim must exclusively
own this resource's stream, separate from the Run log. Configure its Store with:

```elixir
%{initial: nil, versions: [1], destinations: [],
  kinds: Map.merge(%{"run_resource_state" => :state_bearing}, Elzoo.Lease.kinds()),
  reduce: fn _, _, _, payload -> payload end}
```

`resource` has `run_id`, `name`, `deadline_ms`, `rate_per_minute`, required
nonnegative `max_waiting`, `budget` and `close_intent`; only `pause_policy`
may be omitted (default `:stay`, alternative `:close`). These settings are
lifetime-static and recovery requires exact equality. Names are nonempty
UTF-8 text, compared exactly. Deadlines and command times are nonnegative
signed-bigint Unix milliseconds. Rate is a positive integer. Budget is exactly
`%{budget_id: text, unit: text, cost_ref: text, generation: {text, positive_integer}}`,
identifying the host's already admitted reservation, not a new reservation.

An intent is exactly `%{identity: five_texts, arguments: canonical_binary,
binding: stable_text_reference, binding_digest: digest32, deadline_ms: ms}`.
Identity bounds and the 65,536-byte argument limit follow EffectIntent.
Open, use and cleanup identities are distinct and cannot be rebound. Cleanup
targets the stable open/resource reference, never a volatile handle, and its
deadline must extend beyond the resource deadline. Expired cleanup remains
pending in closing; no replacement identity is invented.

`command(pid, %{id: text, at_ms: ms, body: body})` accepts only:

- `{:action, action_map, trusted_context, intent}` for `resource_open`,
  `resource_use`, `resource_close` (close uses nil and the recorded cleanup).
  PatternStep validates a one-action request; action ID equals command ID.
  Schema `elzoo.run-resource.action` v1 payload is exactly string-keyed
  `run_id`, `resource_name`, `data`. Context is exactly `%{run_id: text,
  scope: :owner | :nested, resource_names: [text]}`. Run equality is required;
  nested use also requires the exact outer-supplied name. Payload grants do
  not supply authority, nor can a child Run borrow the owning Run's resource.
- `{:input, checked_run_ended}`: schema `elzoo.run-resource.run-ended` v1,
  exactly string-keyed `run_id`, `outcome`, matching Run and command time.
- `:pause`, `:continue`, `:tick`: trusted lifecycle controls, not new pattern kinds.
- `{:dispatch, identity, effect_owner}`: renew, recheck current dispatchability,
  record the decision, then call unchanged `EffectIntent.advance(owner, :dispatch)`.
  The host supplies the exact descriptor's owner and its startup activation;
  no command calls rearm. PID is excluded from durable command identity.
- `{:observed, identity, observation}`: authenticated host evidence, completed
  data, failed with `:not_dispatched | :dispatched | :unknown`, or unknown data.
  Completed open data is `%{opened_at_ms: ms}`; close additionally requires
  `closed_at_ms`, with `0 <= opened <= closed <= command time` and agreement
  with recorded opening time. Use results are portable JSON-domain data.
- `{:event, event_id, data}`: provider events retain their ID on redelivery.

Results distinguish `{:ok, %{seq: seq, disposition: :accepted | :queued |
:applied | :late}}`, `{:refused, reason}`, `{:error, reason}` and
`{:unknown, %{command_id: id}}`. Acceptance/dispatch is not provider completion.
Exact committed repeats return their original receipt; changed contents/time
under a tagged action/event/observation/dispatch/control key are `:id_conflict`.
Pre-admission refusals are not committed. A post-decision read-only refusal
is retained; a new host-granted owner may use the original cleanup descriptor
under a new dispatch command. Unknown reservations never authorize resend.
Caller timeout is unknown, not cancellation.

`read(pid, after_seq)` returns `{:ok, %{state: view, entries: entries}}`.
View fields: phase, paused, run_ended, active_action_id, waiting_action_ids,
opened_at_ms, observed_through_ms, closed_at_ms, accrued_ms, final_actual.
Entries after the Store cursor skip lease records and expose seq, tagged
command_id, receipt, effects, inputs, budget_command. Historical descriptors
are suppressed when obsolete; **read is not a dispatch permit**. Inputs are
neutral v1 PatternStep maps; decode before accept. Resource identity stays in
the result payload (`run_id`, `resource_name`, `reason`, `data`, plus event_id
for events). Lifecycle event IDs derive from stream/sequence/input index.

## Lifetime, recovery and accounting

Lease renewal occurs at startup, before commands and after dispatch returns,
and halfway through the initial TTL. Microsecond lease stamps yield TTL in
milliseconds; each returned fence replaces the previous one. Revision fencing
alone does not detect lease expiry. Delegated-clock sampling commits expiry
before new admission/dispatch even when timer delivery or command time is old.
Timers use ordinary Process.send_after; no clock, delivery-latency or mailbox
bound is claimed. Byte-identical receipt replay does not renew or dispatch.

Unknown/possibly-sent open reports lost and enters closing, never reopens.
Unknown/possibly-sent use retains its occupied slot until authoritative
completion or cleanup; later evidence does not settle its action twice.
Stay pauses admission/dequeue, not active work or time. Close, Run end,
close-on-pause and deadline stop admission and share one cleanup descriptor.
Queued uses are refused (expired at deadline); confirmed close settles open
ordinary actions as resource_lost and open close actions as completed.
Already settled outcomes remain unchanged. Never-opened closure releases
without provider work. Continue cannot resurrect closed/lost resources.

Version-1 Jason JSON records contain complete state, normalized command,
receipt and delivery entry in one fenced Lease write before acknowledgement.
Objects have string keys, tags are strings, tuple fields are arrays, argument
and digest bytes are base64. No lease handle, function, PID, provider context or opaque
checked tuple is persisted. Recovery validates Store replay and reconstructs
PatternStep trackers through decode/open/accept. Admitted open resources
report lost once and retain original cleanup, never replay open/use. Unknown
writes stop the temporary owner for Store/Lease confirmation and deliberate recovery.
No checkpoint, retention, pruning, subscription or ownership-transfer API.
State and history grow until existing Store capacity refuses them, fail closed.

Provisional usage includes pause and empty-budget time. Confirmed close freezes
the authenticated physical lifetime, excluding observation lag. Round total
milliseconds once: `div(total_ms + 59_999, 60_000) * rate_per_minute`.
Emit one original-generation settle (including late overage), or release for
known zero duration. Unknown lifetime is never released as zero. The host
retains/applies pure Budget state, never restarts Budget.Owner to reset spend.

## Grounding, operations and limits

`mix test pieces/workflow/run-resource/test` runs exactly seven named groups:
serial_use_and_bounded_wait, same_run_typed_name_grant,
open_unknown_never_reopens, run_end_close_and_late_event,
orphan_cleanup_requires_host_grant, pause_stay_close_and_deadline,
paused_usage_survives_empty_budget. One controllable test provider uses the
existing Binding/Adapter and StoreHost activation boundaries. Memory recovery,
host crash/replay consumption, physical-fence simulation and accounting edges
are finite tests, **not production durability or universal proofs**. The small
checked close example is exercised in the deadline group. Temporarily removing
the nested grant check makes the named grant test fail; the mutation is not shipped.

Upstream grounding: Elixir 1.20.4 / OTP 29.1.2 mailbox serialization, call and
timer semantics; Jason 1.4.5 JSON encoding/decoding; unchanged Lease, Store,
EffectIntent, PatternStep and Budget contracts. Backpressure's zero-waiting
in-flight counter does not implement this resource's FIFO lifetime policy.
No new Cure law, type-checker or monitored production claim is made.

- Telemetry **planned**: no telemetry events, metrics or traces emitted;
  durable business inputs/receipts are exposed through read, not monitoring.
- Config **supported**, lifetime-static settings above; no hot updates.
- Control **supported**, only the authorized commands above, serialized and
  durably receipted; no cancel/drain/transfer or implicit retry authority.

Host Needs remain explicit: authenticated caller context and outer typed grants;
current exact-action authorization/approval; canonical arguments and exact
binding/digest/owner resolution; Run-wide action uniqueness; authenticated
provider timestamps/results; retained pure Budget state and generation;
recorded-clock domain; exclusive current resource-stream claim; reconciliation
and **physical fencing of delayed old provider work** before confirming close.
A lease map, handle, read entry or dispatch acknowledgement proves none of these.
The host durably consumes each (resource stream, sequence, input index) once
with destination updates/cursor, or destination deduplication before cursor;
it repeats the same observation after lost acknowledgement and applies Budget
commands at positive host time without rewriting input timestamps.

No authentication engine, RC-50 implementation, real provider, cross-node
clock guarantee, disk/fsync/replication guarantee or total mailbox bound.
Apache-2.0 application-owned source bundle; see [consuming](../../../docs/consuming.md).
