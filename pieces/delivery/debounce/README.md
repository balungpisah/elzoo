# delivery/debounce

A pure, bounded trailing-edge debounce policy for one caller-owned partition.
The caller supplies the epoch, quiet interval, time samples, timer delivery,
serialization and volatile state. This Piece owns no process, timer, registry,
store or persistence.

## API

```elixir
{:ok, state} = Elzoo.Debounce.new("partition-7", 250)
{:ok, pending, {:schedule, {"partition-7", 1}, 300}} =
  Elzoo.Debounce.transition(state, {:put, 50, "latest"})
{:ok, emitted, {:emit, "latest"}} =
  Elzoo.Debounce.transition(pending, {:timeout, 300, {"partition-7", 1}})
```

`new/2` returns `{:ok, state}` or a fixed error. `transition/2` returns
`{:ok, next_state, outcome}` for an accepted command and
`{:error, reason, original_state}` for a refusal. State is opaque; callers
should retain and pass it back unchanged.

Commands are `{:put, now, value}`, `{:timeout, now, token}` and `:clear`.
Outcomes are `{:schedule, token, due_at}`, `{:emit, value}`,
`{:cancel, token}`, `:ignored` and `:unchanged`. Tokens are `{epoch, generation}`.

- Epochs are UTF-8 binaries of 1–160 bytes without NUL. The host chooses an
  epoch and changes it after a reset; this Piece does not generate or persist
  epochs.
- `quiet_ms` is 1–86,400,000. `now` is an integer from 0 through
  `2^63 - 1`; accepted put and timeout samples cannot regress. The host must
  translate any negative raw monotonic sample into a nonnegative origin.
- Values are binaries of 0–65,536 bytes and need not be UTF-8.
- Every accepted put increments the generation, replaces the pending value
  and deadline, and requests one timer for `now + quiet_ms`. A deadline that
  exceeds `2^63 - 1`, or a put beyond the maximum generation, is refused
  without changing state. The maximum generation itself is reachable and
  usable.
- A matching early timeout records its sample and requests the same token at
  the original deadline. A matching due timeout emits the latest accepted
  value once and clears pending state. Well-formed stale, wrong-epoch, empty
  state and duplicate-after-emission timeouts are ignored; accepted timeout
  samples still update the last-observed time.
- `:clear` cancels a pending token and preserves time and generation. With no
  pending value it returns `:unchanged` and preserves state.
- Errors are fixed reasons and do not echo supplied values. Malformed state,
  commands, times and tokens are refused with the exact original state.

## Host operations

The host owns monotonic time and its nonnegative origin, command serialization
for the partition, timer scheduling and best-effort cancellation, and epoch
changes across reset. Timer cancellation is not a correctness guarantee:
matching the epoch and generation is what prevents stale timer delivery from
emitting. Feed each delivered timeout back through `transition/2` with its
original token. A matching early timeout can request a reschedule.

This Piece has no leading edge, maximum-wait policy, persistence or guarantee
of eventual emission. Continual puts can defer emission forever.

## Timer example

[`examples/elzoo/debounce_timer.exs`](examples/elzoo/debounce_timer.exs)
shows a host scheduling a tagged timer message and matching its token. It does
not demonstrate cancellation or stand-alone pure transitions. `run(epoch,
value)` takes its epoch from the caller, which can supply a new epoch after a
reset.

## Dependencies and providers

- Pieces: `core/operator`
- Providers: Cure, Elixir and OTP

## Grounding

- **Proof**: Selected laws in `cure/elzoo/debounce.cure` cover the ignored
  timeout helper, the emitted pending value, cleared-generation duplicate
  handling and the refusal helper. They do not prove Elixir validation or
  timer delivery.
- **Type check**: Cure checks the production source; the listed ExUnit test
  checks the audit has no holes, unresolved declarations or opaque assumptions.
- **Test**: `test/elzoo/debounce_test.exs` exercises the named finite contract
  scenarios, including public boundaries, stale/reordered deliveries and
  exact unchanged-state refusals. These scenarios are not universal proofs.
- **Upstream**: Cure, Elixir and OTP references are pinned in `piece.json`.

## Limits

- Time and timer delivery are caller supplied; timer delivery is not exact.
- State is volatile and scoped to one caller-owned partition.
- There is no leading edge, maximum wait, persistence, background timer,
  registry, store, remote effect or eventual-emission guarantee.

Copied source is Apache-2.0. External providers retain their own licenses.
