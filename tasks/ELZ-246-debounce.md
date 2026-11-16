# ELZ-246 — Add a pure trailing-edge debounce policy

- Dependencies: ELZ-033
- Release: V1B
- Output: delivery/debounce
- Change class: Piece-only

## Scope and reuse

Create one new pure Piece for a single caller-owned partition. It decides a trailing-edge, latest-binary-value debounce policy; it does not run a timer, own a process, registry, partition store or durable state. Cure owns the decision. Elixir validates foreign data and maps bounded failures.

The public API is:

~~~elixir
Elzoo.Debounce.new(epoch, quiet_ms)
Elzoo.Debounce.transition(state, command)
~~~

new/2 returns {:ok, state} or {:error, reason}. State is opaque and starts with no pending value, generation 0 and no last-observed time. transition/2 returns {:ok, next_state, outcome} for an accepted command or {:error, reason, original_state} for a rejected command. The rejected result must contain the exact unchanged input state.

new/2 rejects an invalid epoch or quiet_ms with a bounded error and creates no state. transition/2 rejects malformed state, invalid command/value/time, time regression, deadline overflow and generation exhaustion with the exact input state unchanged.

Commands are {:put, now, value}, {:timeout, now, token}, and :clear. Outcomes are {:schedule, token, due_at}, {:emit, value}, {:cancel, token}, :ignored and :unchanged. Use token {epoch, generation}. A matching early timeout returns the identical schedule outcome and original due_at. A stale or duplicate timeout returns :ignored and schedules or emits nothing.

## Contract

- epoch is trusted host-supplied UTF-8, contains no NUL, and is 1..160 bytes. The host supplies a new epoch across reset; the Piece does not generate or persist epochs.
- quiet_ms is an integer from 1 through 86,400,000.
- now is an integer from 0 through 2^63-1 in a nonnegative origin chosen by the host. A raw System.monotonic_time/0 sample may be negative; the host must translate it to this origin. Accepted put and timeout samples are nondecreasing. A regressing sample rejects without changing state.
- value is a binary of 0..65,536 bytes; it need not be UTF-8.
- Every accepted put checks now + quiet_ms for overflow, increments generation, replaces the pending value and absolute deadline, and returns exactly one schedule request with the new token. Generation 2^63-1 may be reached and used; only a put that would increment beyond it is rejected. Clear is allowed at maximum generation.
- Generation starts at 0 and is bounded by 2^63-1. A timeout token must be exactly {epoch, generation}, where epoch satisfies the epoch text bound and generation is an integer 1..2^63-1. A malformed token is rejected unchanged. A well-formed token with a nonmatching epoch or generation is ignored.
- Every accepted put and every accepted timeout sample, including a timeout ignored for a well-formed nonmatching token, records now as last_observed_now. A regressing timeout rejects unchanged. A matching timeout before due emits nothing and returns the same token and original due_at for scheduling. A matching timeout at or after due emits the latest accepted value once and clears pending state. A duplicate delivery after emission never emits.
- Clear invalidates a pending token and returns its cancellation request. It preserves last_observed_now and generation; with no pending value it returns :unchanged and still preserves both. Timer cancellation is best effort; token matching, not cancellation, guarantees correctness.
- Serialized simultaneous order is explicit: put first postpones the prior deadline; timeout first may emit the old value, and a later put starts a new pending value.
- Rejections return bounded reasons without echoing input. No leading edge, max-wait, persistence or guarantee of eventual emission is provided; continual puts may defer forever.

The existing windowed-idempotency Piece is a sequence-window policy, not a debounce. Reuse the time recipe only for host timer scheduling/cancellation; do not copy its timer into this Piece. The example demonstrates scheduling and matching a tagged timer message; it does not demonstrate cancellation or a pure transition.

## Acceptance

1. **Normal and empty:** new state is empty; one put returns the exact due time/token; early matching timeout returns the same schedule request; a matching due timeout emits the most recent value once; an accepted well-formed timeout in empty state and a duplicate well-formed delivery after emission are ignored, produce no emission or scheduling, and still record their accepted time sample.
2. **Latest value, clear and order:** successive puts replace the value and due time; clear invalidates its token; put-first and timeout-first serialized orders produce their specified results; an old token never matches a later generation, including after clear.
3. **Boundaries and errors:** cover both valid endpoints and rejection just outside each epoch, quiet_ms, now, value-size and generation range; test invalid UTF-8/NUL epoch, deadline overflow, regressing time, malformed/unknown commands and malformed versus well-formed nonmatching tokens. Seed an internal validated fixture state at generation 2^63-2 to test the final allowed put, at-max clear and over-max refusal without a production import/mutation API or 2^63 operations. Every rejection returns the exact original state.
4. **Laws and tests:** where expressible, name and run Cure laws for no stale emission, at most one emission per generation, latest accepted value and unchanged state on rejection. If a property is not expressible as a Cure law, cover it with finite named tests and report only that those tests pass; do not call tests proofs. Include adversarial duplicate/reordered timer delivery.
5. **Negative control:** temporarily bypass token matching; the stale-generation test must fail for an unexpected emission. Restore only this Piece's source before completion.

Run the Piece tests and the repository's normal Piece gate:

~~~sh
mix test pieces/delivery/debounce/test
mix check --piece "$(git merge-base origin/main HEAD)"
git diff --check
~~~

## Owned paths and deliverables

Own only pieces/delivery/debounce/**. Include piece.json with the full copied source closure and no new providers, Cure source, Elixir validation/source, tests, README, operations guidance and one host-timer example. The README and example state that the host owns monotonic time, serialization, timer scheduling/cancellation and epoch changes.

## Not in scope

No timer process, GenServer, registry, store, persistence, leading edge, max-wait, remote effect or new dependency. Do not modify the time recipe or any shared path.
