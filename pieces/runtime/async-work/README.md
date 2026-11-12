# runtime/async-work

Bounded volatile local computation, cancellation, monotonic deadlines and
plain-info result offers through an owner's Registry name.

## Architecture decision and reuse

Bounded, tracked local computation may use Task outside Adapter work; the
business state machine remains in its owner. OTP already supplies task
supervision, monitors, brutal termination, registration and timers. This Piece
adds cancellation/deadline arbitration and named delivery with a per-owner cap,
not a durable execution framework. Aggregation supplies the loss vocabulary,
not its Runner or an Envelope. Ready Contracts remain unchanged.

Outside writes and model/tool calls remain Effects handled by
delivery/effect-intent; durable jobs remain with integration/jobs. The first
caller is RC-50's local-work action for RC-62's bounded computation. This
bundle implements no engine, Lua runtime or durable Unit protocol.

## Use and API

Run `mix run pieces/runtime/async-work/examples/elzoo/async_work.exs` for local
work, ordinary owner input and cancellation. Copy the bundle following
[consuming](../../../docs/consuming.md). Providers are Elixir 1.20.4 / OTP
29.1.2; direct Piece dependencies are runtime/registry and delivery/time.

`Elzoo.AsyncWork.start_link(opts)` returns ordinary OTP startup results.
Required settings are `owner: {:via, Registry, {registry, key}}`, an injected
`task_supervisor`, and positive integer `max_concurrency`. Optional `name`
uses ordinary OTP registration. Start one controller per owner, supervised
independently of the owner, with a caller-owned unique-key Registry and
Task.Supervisor. There is no queue or supervisor factory. Invalid required
settings return `{:error, :invalid_options}`.

`start(server, fun, timeout_ms, wrap)` accepts a zero-arity computation, arity-2
wrap and integer timeout in 1..4_294_967_295 milliseconds. It returns
`{:ok, work_ref}` or `{:error, :invalid_work | :capacity | :unavailable}`.
Refs are ordinary opaque OTP references, volatile and not engine action IDs.
Full controller capacity refuses before dispatch; missing/full Task.Supervisor
returns unavailable with no accepted ref or result. Call/startup timeout after
sending is uncertain, not proof of non-dispatch. The default OTP call timeout
is not the work deadline.

The deadline is runtime monotonic admission time plus timeout, including task
startup. The controller serializes result, DOWN, cancel and deadline messages.
First terminal decision wins, except success processed at or after its deadline
is timed out. Outcomes are:

| Observation | Outcome |
| --- | --- |
| Return value | `{:completed, value}` |
| Raise, throw, non-kill abnormal exit | `{:lost, :unavailable}` |
| kill / killed / shutdown | `{:lost, :killed}` |
| Deadline | `{:lost, :timed_out}` |

`cancel(server, work_ref)` returns `:ok` if active: cancel the timer, brutally
terminate the task (including trap-exit tasks), release capacity and offer
`{:lost, :killed}` once. Unknown, settled and previous-controller refs return
`{:error, :late}` with no new offer. Capacity counts work through actual
termination. Normal stop/supervised shutdown kills tracked tasks without
stopping the injected supervisor; untrappable controller/VM kill has no cleanup
guarantee.

Each terminal decision calls the supplied `wrap.(work_ref, outcome)` once,
then resolves the owner's Registry name and sends that returned term as plain
info, not a cast. Each wrap closes over its own caller action/input identity;
there is no mutable lookup or durable identity store. A trusted, prompt,
nonblocking wrap is required. Wrap failure, absent owner and death racing
send can lose the offer. There is no retry, acknowledgement, absent-owner
buffer, synthetic Envelope or substitute message form.

## Restart, Needs and limits

A surviving controller keeps its task monitors/deadlines across an owner-only
restart and offers to the replacement process under the same name. The new
owner lacks volatile action knowledge and must reject unknown results as late.
The AW5 receiver startup fixture illustrates recording the prior open action
failed with loss before intake; that is RC-50's responsibility, not recovery
implemented by this Piece. A cancelled owner's action also rejects an offer
already sent before cancellation. Sending is neither durable acceptance nor
evidence of application; there is no cancellation receipt and delivery cannot
be recalled.

Controller restart loses tracking; old refs are unknown, and completion to a
dead controller is not recoverable. Before reestablishing a cap, the host must
tear down the predecessor's task subtree. Terminal refs are removed, with no
tombstones/history. The cap does not bound mailboxes, closures, work/result
memory, caller-created descendants or orphans after untrappable controller
kill. Trusted bounded non-Effect computation is a Need, not an OTP sandbox
guarantee. Loss neither proves that work never ran nor undoes an Effect.
Monotonic time is local to the runtime, not durable or distributed.

## Operations and grounding

- Config: required start-time settings, optional OTP name and per-work timeout/
  wrap as above; no hot changes.
- Control: cancel only; no pause, drain or retry.
- Telemetry: planned; no events supplied. The library emits no diagnostics
  containing payloads, wrapped terms or exception contents. Consumer functions
  own their logging.
- Test: AW1 free owner/completion, AW2 cancellation/racing result/open-ref gate,
  AW3 sanitized worker losses and legitimate completed values, AW4 deadline and
  queued late success, AW5 owner/controller restart distinction, AW6 capacity,
  refusal/concurrent admission/shutdown, AW7 lost offers and duplicate signals.
  Run `mix test pieces/runtime/async-work/test`. These are finite scenarios,
  not universal cancellation/delivery proofs.
- Upstream: pinned Task.Supervisor.async_nolink, Task.shutdown(:brutal_kill),
  OTP monitors, GenServer serialization, unique Registry lookup and absolute
  Process.send_after/cancel_timer with runtime monotonic time. No Cure proof,
  independent type-check or production monitoring is claimed.

Copied source is Apache-2.0. External providers retain their own licenses.
Evidence describes this source and these scenarios; rerun/adapt after changes.
