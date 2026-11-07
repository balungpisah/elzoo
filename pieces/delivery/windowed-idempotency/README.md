# delivery/windowed-idempotency

Volatile, bounded per-sender duplicate **and stale-input** suppression. This
separate ID does not change `delivery/idempotency` (unbounded exact-key history)
or switch any existing Assembly to a new policy.

## Use and Contract

```elixir
{:ok, state} = Elzoo.WindowedIdempotency.new(3, 20)
message = {:Message, 1, 1, 9, 42}
{:ok, {state, {:some, ^message}}, :fresh} = Elzoo.WindowedIdempotency.receive(state, message)
{:ok, {^state, :none}, :duplicate} = Elzoo.WindowedIdempotency.receive(state, message)
```

`new(window, max_senders)` requires positive integers, checking window first;
errors are `:invalid_window` and `:invalid_max_senders`. `classify(state, message)`
returns `{:ok, decision}`. `receive/2` returns
`{:ok, {next_state, :none | {:some, message}}, decision}`. Both validate state
before message and return fixed `:invalid_state` / `:invalid_message` errors,
never echoing invalid values. Messages are `{:Message, s, i, q, v}` with four
integers (including negative integers). States are opaque; construct via `new/2`
or Cure `initial/2`, not foreign tuples. The boundary rejects malformed tuples,
improper sender/accepted lists before traversal, duplicate senders, capacity
overflow, and inconsistent/duplicate/empty accepted histories.

In Cure, `use Elzoo.WindowedIdempotency`; `initial(window, max_senders)` creates
`WindowedState`. `classify`, `step(state, input, decision)` and
`receiver(state, input)` use the unchanged `Elzoo.Idempotency.Message` and
`Elzoo.Composition.Transition` seam. The receiver composes as a first operator
with `compose`. Direct erased BEAM callers must supply correctly shaped,
well-formed values; Cure types are not foreign-data validation.

Each `SenderWindow` retains incarnation, highest sequence `high`, and accepted
sequences in `(high - window, high]`, at most `window` distinct integers.
At most `max_senders` entries exist, bounding entry counts, **not bytes**.
Configuration is fixed in the state at construction (no hot reconfiguration).
Sender/list ordering is internal, not contractual.

First matching rule wins:

| Condition | Decision | Result |
| --- | --- | --- |
| nonpositive config (direct Cure initial only) | WindowInvalid | unchanged, None |
| unknown sender, full capacity | full | unchanged, None; no eviction |
| unknown sender otherwise | fresh | remember singleton, emit input |
| lower incarnation | superseded | unchanged, None |
| higher incarnation | new_incarnation | replace old history with singleton, emit |
| sequence > high | advance | update high; prepend sequence and prune <= sequence - W, emit |
| sequence <= high - W | stale | unchanged, None even if never seen |
| sequence already accepted | duplicate | unchanged, None regardless of value |
| otherwise | reorder | add sequence without changing high, emit immediately |

The accepting advance path stores production
`advance_accepted(state.window == 1, state.window, input.sequence, entry.accepted)`.
W=1 replaces prior history with a singleton; wider windows use `prune_after`.

## Dependencies and standalone copying

Pieces: `delivery/idempotency`, `core/operator`. Providers: pinned Cure and
Elixir/OTP. Copy this source bundle with its dependencies using
[the consumption instructions](../../../docs/consuming.md). Isolated consumer
tests compile and run without `Elzoo.Application`; runtime needs no Cure compiler.
No process, Adapter, Effect, I/O, timer or Application is supplied here.

## Grounding and limits

- **Proof:** `duplicate_emits_nothing`, `duplicate_keeps_state`,
  `stale_emits_nothing`, `stale_keeps_state`, `superseded_keeps_state`,
  `full_keeps_state`, `reorder_preserves_message`, `advance_preserves_message`
  cover `step` with an already supplied decision, not `classify` or `receiver`.
  Superseded/full laws include both unchanged state and None output.
- **Proof, helper/W=1 only:** `singleton_advance_window` checks
  `advance_accepted(True(), window, sequence, previous) = singleton(sequence)`
  for every integer window/sequence and proper integer history. The singleton
  equality implies one retained entry in `(sequence - 1, sequence]` for W=1;
  no separate arithmetic/length theorem is claimed. It does **not** prove flag
  selection, storage of the helper result in step, preservation of other
  senders, W>1 pruning bounds or an inductive receiver invariant. These
  connections have finite tests, not receiver/general window-bound proofs.
- **Type/contract check:** pinned Cure compiles production source and typed
  composition. Production-source false duplicate law and retained-singleton
  mutation fail by conversion_failure; an unfinished hole is rejected. The
  audit checks empty axioms/holes/unresolved/unaudited/opaque/not_proven_total
  and zero absurd. Elixir boundary validation is executable, not a Cure proof.
- **Tests:** named first/duplicate/reorder/boundary/stale/incarnation/capacity,
  W=1 and W>1 helper-storage/retention, large-gap, negative-integer, malformed
  boundary and invalid-initial scenarios, decision/transition agreement,
  seeded independent map/set reference traces and downstream composition.
- **Upstream:** Cure 208248063d64e621782cd26dd30698ee42850a89 compiler/kernel,
  Elixir 1.20.4 and OTP 29.1.2. No compiler soundness proof is claimed.
- **Assumptions (unverified):** senders assign increasing sequences per
  incarnation and use strictly greater incarnations after restart. Reusing a
  sequence for different content suppresses it. Caller retains volatile state;
  losing it permits duplicates again. No durable storage, replay, replication,
  network transport or exactly-once Effects. No clock or time expiry: window
  means sequence distance. No cross-sender ordering or reordering buffer;
  accepted reorders emit late in arrival order. Stale suppression is not
  loss-free delivery. Output suppression is not an ack/retry/dead-letter policy
  (ELZ-006). Not the complete historical Zoo receiver.

## Operational applicability

- Telemetry: `not_applicable`; invoking Unit/Assembly owns instrumentation.
- Config: `supported`; construction-time validated window/max_senders only,
  tested in-bundle; no ambient configuration or hot reconfiguration.
- Control: `not_applicable`; no lifecycle to pause/drain/resume.

Apache-2.0 covers this copied source; upstream packages retain their licenses.
Evidence concerns these recorded bytes and named claims, not downstream edits.
