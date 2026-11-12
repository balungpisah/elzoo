# runtime/durable-unit

One Unit's input-before-transition log, recovery, FIFO input-identity retention
and committed outbox offers. Ready `runtime/unit` remains volatile and unchanged.

## Use and Needs

Select `runtime/durable-unit` with `mix elzoo.take`; see
[consuming](../../../docs/consuming.md). Direct Piece dependencies are
`core/operator`, `state/event-log`, `state/checkpoint` and `state/outbox`.
Providers are pinned Elixir 1.20.4 and OTP 29.1.2; the dependency closure uses
the existing pinned Cure compiler. No new Cure law is supplied for this shell.

`Elzoo.DurableUnit.start_link(opts)` and `child_spec(opts)` use ordinary OTP
startup, optional `name` registration and a **transient** restart policy.
Required fixed-at-start settings, with no defaults:

- `store`: conforming `{module, config}` Store configured using `fold(opts)`
  and `limits(opts)`; batch size is fixed at one record per append.
- `stream`: UTF-8 binary of 1..200 bytes without NUL.
- `operator: {module, function, initial_state}`: pure deterministic terminating
  `apply(module, function, [state, input])`, returning
  `{:Transition, next_state, :none | {:some, output}}`.
- `retention_count`: positive integer counting completed distinct inputs.
- `max_record_bytes`, `max_checkpoint_bytes`: positive integer byte bounds,
  inclusive. The record bound covers the encoded record payload and each
  encoded output; the checkpoint bound is the ready Checkpoint's full size.
- `offer`: prompt, nonblocking arity-1 callback receiving `Elzoo.Outbox.Item`;
  only `:ok` is a successful offer. Destination is fixed to `"outputs"`.

Needs: caller supervision, exclusive matching stream configuration, conforming
Store, pure terminating deterministic operator, trusted serializable plain BEAM
data, prompt offer callback and caller-owned dispatcher. Inputs, state and
outputs exclude processes, references, funs, resources and secrets. The fixed
v1 encoding is an OTP external term `{1, data}`, minor version 2, deterministic
encoding and safe decoding. Record kinds are `"input"` and `"result"`, schema
version 1, carrying `{input_id, input}` and `{input_id, next_state}`. Operator,
initial state, retention and format interpretation remain fixed for the stream's
lifetime. Application-data compatibility is the caller's responsibility; no
hostile-data, implicit migration or rolling-upgrade guarantee.

## Intake, commit and failure

`step(server, input_id, input)` returns `{:ok, :applied | :duplicate}`,
`{:error, reason}` or `{:indeterminate, info}`. The **only** business info
message is `{:durable_unit_input, input_id, input}`, with identical intake
semantics but no acknowledgement. IDs are caller-stable UTF-8 binaries of
1..160 bytes without NUL, scoped to one stream. Mailbox delivery is volatile;
only the synchronous applied/duplicate reply establishes the committed result.
The caller owns resubmission after uncertainty. Unrelated messages are ignored.

Validation errors are `:invalid_input`, `:input_too_large` and
`:input_id_conflict`, with no append/transition for refused admission. Retained
same-ID/same-digest duplicates append and offer nothing new; a different input
digest is a collision. Distinct completion evicts the oldest completed ID;
duplicates do not refresh FIFO. **An evicted ID can apply again.** Unresolved
input is never evicted, and is finished before new admission after recovery.

Input commits before pure evaluation. Result and zero/one output commit in one
Store append before application state changes or offers. Completed transitions
are folded from results, not rerun. `snapshot(server)` returns last committed
application state; it is inspection, not monitoring.

- `{:error, {:rejected, store_reason}}`: before input commit the Unit remains
  usable; after input commit it stops with
  `{:shutdown, :durable_unit_storage_rejected}`, retaining unresolved input.
- Transition raise/throw/exit, malformed return or oversized result/output:
  `{:error, :durable_unit_transition_failed}` and matching shutdown, with no
  result/outbox. Deliberate restart retries unresolved input once; persistent
  failure fails startup. Transient supervision does not loop on that shutdown.
- Append conflict: `{:error, :durable_unit_conflict}` and exactly
  `{:shutdown, :durable_unit_conflict}`. No losing state/outbox is installed or
  offered. Result-stage evaluation may already have run. Writer remains
  unchanged; no follower promotion or conflict retry is supplied.
- Indeterminate: Store's unchanged payload-free receipt, or `:storage_unknown`
  for a Writer call exit without one, and
  `{:shutdown, :durable_unit_indeterminate}`. A normal GenServer timeout/exit
  without reply is uncertain, not a safe rejection. No timeout policy layer.
  Reconcile using the existing Store confirmation contract before reopening;
  absence never proves non-commit. There is no automatic reconciliation loop.
- Unavailable storage, unknown schema version, damaged replay, or a needed
  pruned prefix without a usable checkpoint fail startup with
  `{:shutdown, :durable_unit_recovery_failed}`. Public errors exclude payloads
  and exception text. No poison skip or repair record is supplied.

## Explicit controls and limits

`checkpoint(server)` uses ready `Checkpoint.take/4` on the Writer, fold version
1, and returns its result unchanged (`{:committed, revision}`,
`{:conflict, info}`, `{:rejected, reason}`, `{:error, reason}` or
`{:indeterminate, receipt}`). Indeterminate stops as above, with no retry.
Incompatible fold versions are skipped for full log replay.

`offer_pending(server)` reads at most 64 items with ready `Outbox.pending/3`,
offering once each, and returns `{:ok, offered_count}` or
`{:error, :offer_unavailable}`. Read/callback failure or a non-`:ok` callback
ends the pass. One pass runs after recovery and each result commit; failure
does not undo state or prevent an applied reply. The caller drives further
passes and acks directly using `Outbox.ack(store, item.idempotency_key, nonce)`
with a fresh 16-byte nonce **after the dispatcher's documented commit point**.
Pending offers keep their derived idempotency key until ack CAS commits.
No timer, queue, retry scheduler, ack wrapper or external-effect confirmation.

Input retention does **not** bound log/witness memory or recovery time. Ready
recovery accumulates its 1,000-row pages, and checkpoints preserve the complete
cursor/seen witnesses. Nothing prunes the log or trims witnesses to the input
window. Oversize checkpoints refuse without truncation; ordinary log recovery
remains usable. Persistence inherits Store guarantees: Memory demonstrates
process restart, not disk durability. No exactly-once effects or delivery claim.
Destination idempotency, acknowledgement and availability remain external.

## Grounding and operations

`test/elzoo/durable_unit_test.exs` exercises exactly DU1–DU8: both intake forms
and validation; pre-input crash; interrupted evaluation/unresolved restarts;
post-result recovery/offers/ack/64-item passes; checkpoint faults/version/pruned
prefix/size limits; FIFO retention across restart; input/result conflicts;
poison/unknown format/storage uncertainty/transient shutdown. Piece-local
instrumented fixtures place failures; production has no test hooks. The DU6
negative control temporarily bypasses deduplication and must fail, then is
reverted. These finite scenarios are not universal recovery/exactly-once proofs.
The [example](examples/restart.exs) shows apply, restart, duplicate, offer and ack.

Telemetry is **planned**: no events or payload logging are supplied. Config is
**supported** for the fixed-at-start settings above, not hot updates. Control
is **supported** for checkpoint and explicit offer passes; OTP lifecycle is
inherited, with no pause/drain/resume. Upstream assumptions are OTP GenServer,
links/monitors, transient supervision, SHA-256 and external-term encoding, plus
the ready Store CAS, Writer, Checkpoint and Outbox contracts; none is proved by
these tests. Copied source is Apache-2.0; rerun/adapt evidence after edits.
