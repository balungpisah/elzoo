# delivery/rate-limit

One pure Policy that admits work per tenant and per principal. An admission
takes `cost` tokens from a per-tenant bucket and from a per-principal bucket,
and one in-flight slot from a global bound and from a per-tenant fair-share
bound, or it takes nothing. A refusal names the bound that refused it and, for
a rate bound, the exact milliseconds until a retry could pass. Nothing is
dropped silently and nothing waits.

The Piece is plain Elixir over a state that the caller holds. It reads no
clock (`now_ms` is injected), owns no queue, scheduler or process, and emits no
telemetry or log. The slot counts use the ready `delivery/backpressure` Piece
through `Elzoo.Backpressure.new/1`, `admit/1` and `release/1`: one state for
the global bound and one for each tenant. Apache-2.0.

## Interface

- `Elzoo.RateLimit.new(opts)` returns `{:ok, state}` or `{:error, :config}`.
  `opts` is a keyword list with exactly these keys, each once:
  - `tenant_rate` and `principal_rate`: each a map with exactly `capacity`
    (1..1,000,000 tokens), `refill` (1..`capacity` tokens) and `interval_ms`
    (1..86,400,000);
  - `max_in_flight`: 1..1,000,000;
  - `tenant_in_flight`: 1..`max_in_flight`;
  - `max_keys`: 1..65,536 buckets of each kind.
- `Elzoo.RateLimit.admit(state, %{tenant: t, principal: p}, cost, now_ms)`
  returns `{:ok, ticket, state}`, `{:refused, reason, retry_after_ms, state}`
  or `{:error, :malformed}`. On a refusal the returned state equals the input.
- `Elzoo.RateLimit.release(state, ticket)` returns `{:ok, state}` or
  `{:error, :unknown_ticket}`. It frees exactly the global and the tenant slot
  of that admission. A second release of a ticket, a forged ticket and a
  forged state are `:unknown_ticket`; no count underflows.

`tenant` and `principal` are 1..128 bytes of valid UTF-8 without C0 or C1
control characters (the `domain/principal` text rule). A principal bucket is
keyed by `{tenant, principal}`. `cost` is an integer from 1 to the smaller
capacity. `now_ms` is an integer in `0..9_223_372_036_854_775_807`. Anything
else, or a state that `new/1` and these functions could not have produced, is
`:malformed`.

### Refusal order

The first reason that holds is returned:

1. `:keys`: a new tenant or principal bucket is needed and there is no room,
   even after dropping an idle bucket. `retry_after_ms` is `nil`.
2. `:slots`: the global bound is saturated. `retry_after_ms` is `nil`.
3. `:tenant_slots`: the tenant holds `tenant_in_flight` slots.
   `retry_after_ms` is `nil`.
4. `:tenant_rate`, then `:principal_rate`: the bucket holds fewer than `cost`
   tokens. `retry_after_ms` is the least positive number of milliseconds after
   which the refill rule gives the bucket `cost` tokens.

Every check reads the input state; the next state is built only after all of
them pass. So a principal refusal after the tenant bucket passed takes no
tenant token and no slot.

## Refill rule

A bucket starts full at its first use and keeps `tokens` and `last_ms`. At
`now_ms >= last_ms` it adds `refill * div(now_ms - last_ms, interval_ms)`
tokens, capped at `capacity`, and advances `last_ms` by whole intervals only,
so a fractional interval is kept for the next call. At `now_ms < last_ms` (a
clock that went back) it adds nothing and keeps `last_ms`. With `missing =
cost - tokens`, the wait is
`last_ms + ceil(missing / refill) * interval_ms - now_ms`, in integers. A
clock that went back therefore waits until `last_ms` plus whole intervals.

## Key bound and eviction

At most `max_keys` tenant buckets, `max_keys` principal buckets and `max_keys`
per-tenant Backpressure states exist. A bucket that would be full at `now_ms`
and whose tenant has no live ticket is idle. When a new bucket of a kind is
needed and that kind is at `max_keys`, the idle bucket of that kind with the
oldest stored `last_ms` is dropped, ties in byte (Erlang term) order of the key.
A tenant's Backpressure state is dropped with its tenant bucket (it is at zero,
since the tenant has no live ticket) and is created again at the tenant's next
admission. If no bucket is idle, the admission is `:keys`.

A dropped bucket that is created again starts full with `last_ms = now_ms`.
That gives it the same tokens as the kept bucket, but its next refill can come
up to one interval later than the kept bucket's would have.

## Tickets and slots

`Elzoo.Backpressure` exposes no in-flight count, so whether a tenant holds a
slot is read from the state's live tickets, which name their tenant. Tickets
are unique within a state, and at most `max_in_flight` are live. Each call
checks that every Backpressure count equals the live tickets it covers; this
reads the erased `{:CapacityState, capacity, in_flight}` term that the
Backpressure README documents.

## Limits

- One caller-held state that the host serializes. No distributed or
  multi-node limit, no persistence across restarts (a restart starts full),
  no queue or waiting, no weighted fairness and no priority. Fair queuing of
  Oban jobs stays Oban queue and partition configuration of the consumer.
- Costs are the host's estimate. The host releases each ticket when its work
  ends; a ticket that is never released holds its slots.
- The key cap fails closed with `:keys`, so a flood of new principals in one
  tenant can refuse new principals of other tenants once `max_keys` is
  reached. Set it above the expected active set.
- Each call revalidates the state in time linear in its buckets and live
  tenants.
- Config is construction-time; there is no hot update.

## Grounding

The listed scenarios in `test/elzoo/rate_limit_test.exs` pass, including a
seeded 10,000-step admit/release trace (seed `{280, 644, 2026}`) over three
tenants and three principals, with times that go back, that agrees step by step
with an independent reference model in the test. Three negative controls fail
under temporary edits: keeping a tenant token on a principal refusal, moving
`last_ms` to `now_ms` on refill, and skipping the per-tenant slot bound. This
is finite evidence, not a proof. See `examples/elzoo/rate_limit.exs`.
