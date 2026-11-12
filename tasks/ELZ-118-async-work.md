# ELZ-118 — Bounded async local work

- Dependencies: ELZ-033, ELZ-004, ELZ-013, ELZ-006, ELZ-098
- Output: `runtime/async-work` (new Piece ID).
- Lane: `pieces/runtime/async-work/**` and its own index rows/generated files under AGENTS.md section 3. No ready Piece, root test, dependency pin or shared runtime edits. RC-45 is not a prerequisite.

## Responsibility and scope

Own bounded local computation, cancellation, deadlines and named-owner delivery. First caller: RC-50's `local_work` action for RC-62's bounded local Lua computation. Outside writes and model/tool provider calls remain Effects handled by delivery/effect-intent; durable jobs remain with integration/jobs. Implement no Lua runtime, engine or action protocol.

Implement acceptance only. Use existing upstream/repo facilities first. Add no extra options, layers, behaviours, generic helpers or future hooks. Keep tests to the named scenarios below. Ask the coordinator before expansion. Reviewers flag needless abstractions and features for removal.

## Shared runtime boundary (copy unchanged to RC-46 and RC-47)

RC-45 owns exactly one business info-message form: `{:durable_unit_input, input_id, input}`. `input_id` is a caller-stable UTF-8 binary of 1..160 bytes without NUL, scoped to one durable stream; `input` is caller-owned data. A direct sender constructs that tuple; no second intake wrapper or Envelope is introduced. RC-45 applies the same intake semantics to `step(server, input_id, input)` and this tuple. Sending the tuple is not an acknowledgement or evidence of commit; mailbox delivery is volatile. Only the synchronous step's applied/duplicate reply establishes that the input's result is committed. The caller owns resubmission with the same identity after an uncertain outcome, and identity collisions are errors inside the retained window.

RC-46 routes that tuple unchanged to the current local Unit for the identity. It must not report a successful send as durable acceptance, and must explicitly refuse a stop/wake race it cannot resolve; no durable mailbox or exactly-once delivery is promised. RC-47 owns no durable-unit tuple: it calls the supplied `wrap.(work_ref, outcome)` and sends that returned term to the owner's registered name, resolved when sending rather than retaining an owner PID. RC-47 tests use a receiver process, not RC-45. RC-50 supplies the wrap that builds the RC-45 tuple with an RC-68 input inside; it supplies stable input identity and engine-read time. A result for an action no longer open is late and is never applied, including after durable-unit input deduplication has expired. On engine recovery RC-50 records a failed outcome with a loss class for an open volatile local-work action before admitting subsequent results; a later result is late. Neither RC-45 nor RC-47 implements this engine policy.

An append returning `{:conflict, observed}` causes RC-45 to stop with `{:shutdown, :durable_unit_conflict}`. The ready Writer normally reloads and returns conflict; RC-45, not the Writer or RC-46, owns the stop policy. No losing candidate state or outbox is installed or offered. A pure transition may already have been evaluated before a result-append conflict; “applies nothing” means no committed losing result, not that no CPU work occurred. RC-46 uses this exact stop reason for the losing Unit on another node. Local Registry uniqueness is not cluster ownership.

## API

`Elzoo.AsyncWork.start_link(opts)` creates one caller-supervised controller, independently supervised from its owner. Required settings: `owner: {:via, Registry, {registry, key}}`, `task_supervisor` and positive integer `max_concurrency`; optional `name` is ordinary OTP registration. Use standard OTP startup results. Caller supplies one controller per owner, a unique-key Registry and Task.Supervisor; no queue or supervisor factory. The cap is local to that controller/owner, not global.

- `start(server, fun, timeout_ms, wrap)` takes a zero-arity computation, arity-2 wrap and timeout in milliseconds in 1..4_294_967_295. Return `{:ok, work_ref}` or `{:error, :invalid_work | :capacity | :unavailable}`. `work_ref` is an opaque ordinary OTP reference, volatile and never an engine action ID. Each work's wrap closes over any engine action/input identity; add no durable identity store or mutable lookup callback.
- Deadline is runtime monotonic admission time plus timeout_ms, including task startup. Missing/full Task.Supervisor returns unavailable without an accepted ref or result message; a full admission table returns capacity before dispatch. A call/startup timeout after sending is uncertain, not proof of non-dispatch.
- `cancel(server, work_ref)` returns `:ok` if it wins while active. Cancel the timer, brutally terminate the task (including trap-exit tasks), then release capacity and offer `{:lost, :killed}` once. Unknown, settled and previous-controller refs return `{:error, :late}` without another message. The owner closes its action and rejects any already-sent result; cancellation cannot recall delivery and has no durable receipt.
- Return value becomes `{:completed, value}`; raise/throw/non-kill abnormal exit becomes `{:lost, :unavailable}` without exception text/stack; kill/killed/shutdown becomes `{:lost, :killed}`; deadline kills survivors and yields `{:lost, :timed_out}`. Reuse aggregation's loss vocabulary, not its Runner. No retry, synthetic Envelope or result schema layer.

The controller owns task monitors and serializes result, DOWN, cancel and deadline processing. First terminal decision wins, except success processed at or after deadline is timed_out. Ignore later signals for unknown refs. Use Task.Supervisor async_nolink, OTP monitors, Process.send_after/cancel_timer and monotonic time directly. Normal stop/supervised shutdown kills tracked tasks without stopping the injected supervisor; untrappable controller/VM kill has no cleanup guarantee.

For each terminal decision call `wrap.(work_ref, outcome)` once and send the returned term through the owner's Registry name as plain info, not a cast. Wrap must be trusted, prompt and nonblocking. Catch wrap failure without leaking values or crashing the controller: the offer is lost. Missing owner or death racing send can also lose it. No retry, acknowledgement, absent-owner buffering or substitute message form.

## Restart, Needs and limits

A surviving controller retains monitors/deadlines across owner-only restart and sends to the replacement Unit under the same name. That Unit lacks volatile action knowledge and treats unknown results as late. Controller restart instead loses tracking: old refs are unknown and completion to the dead controller is not recoverable. No persistence or recovery reporter layer.

The cap counts work through actual termination. It does not bound mailboxes, closures, work/result memory, caller-created descendants or orphan work after untrappable controller kill. Before reestablishing a cap across controller restart, the host tears down its predecessor's task subtree. Terminal refs are removed; no tombstones or result history. Trusted bounded computations are a Need, not an OTP sandbox guarantee.

Needs: caller-owned Task.Supervisor and unique Registry name, one independently supervised controller per owner, bounded non-Effect computation, runtime monotonic time/timers, prompt wrap and owner-side late-result gate. Direct Piece dependencies: runtime/registry and delivery/time; providers: pinned Elixir/OTP. Aggregation supplies vocabulary only. No RC-45 dependency or package/pin change.

Record the narrow architecture decision in the README: bounded, tracked local computation may use Task outside adapter work; the business state machine remains in its owner. This Piece adds cancellation/deadline arbitration and named delivery with a per-owner cap, not a durable execution framework. Ready Contracts remain unchanged.

Operations: Config supported for start-time settings and per-work timeout/wrap, no hot changes. Control supported for cancel, no pause/drain. Telemetry planned, no events supplied; library diagnostics contain no payloads, wrapped messages or exception contents. Consumer functions own their logging.

## Named acceptance scenarios

1. AW1 — Free owner and completed work: hold a real supervised task at a barrier; a registered test receiver handles another input; release the task and receive exactly the supplied wrap's term containing its ref and value. No durable Unit, RC-68 or engine implementation is required.
2. AW2 — Cancel during work and result after cancel: cancel an active task, observe killed loss and actual termination, then release/deliver a racing late result. No second terminal outcome and no application by the test receiver's open-ref gate. If completion wins first, cancel returns late; a previously queued result still cannot reopen a receiver-cancelled action.
3. AW3 — Worker loss: raise, throw and abnormal exit produce unavailable; kill/killed/shutdown produce killed. Capture library logs and all observed event/message fields with sentinel payloads: no exception/result payload in diagnostics or telemetry. Do not suppress the test receiver's legitimate completed value.
4. AW4 — Deadline kill: work still running at expiry, including a task trapping exits, is killed and produces timed_out. A result processed at the deadline or later cannot win as completed. Time is runtime-local, not durable or distributed.
5. AW5 — Owner restart while work runs: kill only the receiver, register a new receiver under the same name before releasing work, and show the offer reaches that new PID rather than the dead one. The new receiver has no open ref, marks it late and applies nothing. A test-receiver startup fixture marks its prior open local action failed with loss before intake, illustrating (not implementing) RC-50's recovery responsibility. Separately restart the controller and show old refs are unknown; claim no recovered task result.
6. AW6 — Bound/refusal: with max_concurrency 2, hold two different tasks, refuse the third before dispatch, finish/cancel one, verify termination and admit another. Invalid work/timeout, missing or full supervisor refuse explicitly. Concurrent admission never exceeds the declared active bound. Normal controller shutdown kills its tracked tasks without stopping the injected supervisor.
7. AW7 — Offer unavailable: missing owner at completion or a raising wrap loses the offer without payload leakage, retry, controller failure or retained terminal history. Registry name replacement race is not durable delivery. Duplicate DOWN/result/timer messages after settlement apply nothing; unknown cancel returns late.

Use real Task.Supervisor/Registry and Piece-local receiver/barrier fixtures, not production hooks or a generic harness. One example shows local work, ordinary owner input and cancel. Temporarily permit a post-cancel result offer; AW2 must fail, then revert. These are finite tests, not universal cancellation/delivery proofs. Loss does not prove work never ran or undo an Effect.

Run Piece tests, `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`. Record commands/exit codes, named scenarios and upstream assumptions separately. Use a private disposable database if selected checks need one. One independent review checks the Contract, evidence and needless features.

## Delivery gates

The shared boundary is fixed for ELZ-117/118 and RC-46 before implementation. Parallel level-1 work uses separate orbs and disjoint lanes. Merges remain serial; no other small-gate PR merges before RC-68's six-point proof is accepted; at most three small-gate merges occur between green main runs. Level-2 publication may proceed when that task's prerequisites are merged and main is green, without waiting for the whole level.
