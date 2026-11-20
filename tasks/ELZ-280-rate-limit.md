# ELZ-280 — Admit work per tenant and principal within rate and fair-share slot bounds, refusing with a retry time

- Phase: Wave 5 Level 3 (sub-level 3a)
- Dependencies: ELZ-033, ELZ-006
- Release: V1B
- Output: new `delivery/rate-limit` Piece (absorbing the `delivery/fair-queue` handle)
- Change class: Piece-only
- Owned paths: `pieces/delivery/rate-limit/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (`delivery/backpressure`), `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One pure Policy over a caller-held state, in plain Elixir with Cure where it fits; no new provider. One admission takes a token from a per-tenant bucket and from a per-principal bucket, and one in-flight slot from a global bound and from a per-tenant fair-share bound, or it takes nothing. A refusal names the bound that refused it and, for a rate bound, the exact milliseconds until a retry could pass. Nothing is dropped silently and nothing waits.

For the slot counts, reuse the ready `delivery/backpressure` (ELZ-006) public API (`Elzoo.Backpressure.new/1`, `admit/1` and `release/1`): one state for the global bound and one for each tenant. Only the token bucket and the all-or-nothing combination are new policy. Fair queuing of Oban jobs stays Oban queue and partition configuration of the consumer. This Piece builds no queue, scheduler or process, and reads no clock: `now_ms` is injected.

## Interface

- `Elzoo.RateLimit.new(opts)` returns `{:ok, state}` or `{:error, :config}`. `opts` is a keyword list with exactly:
  - `tenant_rate` and `principal_rate`: each a map with exactly `capacity` (1..1,000,000 tokens), `refill` (1..`capacity` tokens) and `interval_ms` (1..86,400,000);
  - `max_in_flight`: 1..1,000,000;
  - `tenant_in_flight`: 1..`max_in_flight`;
  - `max_keys`: 1..65,536 buckets of each kind.
- `Elzoo.RateLimit.admit(state, %{tenant: t, principal: p}, cost, now_ms)` returns `{:ok, ticket, state}`, `{:refused, reason, retry_after_ms, state}` or `{:error, :malformed}`. `state` is unchanged on a refusal. `reason` is the first that holds, in this order:
  1. `:keys`: a new tenant or principal bucket is needed and there is no room, even after dropping idle buckets. `retry_after_ms` is `nil`.
  2. `:slots`: the global bound is saturated. `retry_after_ms` is `nil`.
  3. `:tenant_slots`: the tenant holds `tenant_in_flight` slots. `retry_after_ms` is `nil`.
  4. `:tenant_rate`, then `:principal_rate`: the bucket holds fewer than `cost` tokens. `retry_after_ms` is the least positive number of milliseconds after which the refill rule gives the bucket `cost` tokens.

  `tenant` and `principal` follow the `domain/principal` text rule (1..128 bytes of valid UTF-8 without C0 or C1 control characters). A principal bucket is keyed by `{tenant, principal}`. `cost` is an integer from 1 to the smaller capacity. `now_ms` is an integer `0..9_223_372_036_854_775_807`. Anything else, or a forged state, is `:malformed`.
- `Elzoo.RateLimit.release(state, ticket)` returns `{:ok, state}` or `{:error, :unknown_ticket}`. It frees exactly the two slots that the admission took. A second release of one ticket is `:unknown_ticket`, and no count ever underflows. Tickets are unique within the state; at most `max_in_flight` are live.

## Refill rule and bounds

- A bucket starts full at its first use and keeps `tokens` and `last_ms`. At `now_ms >= last_ms` it adds `refill * div(now_ms - last_ms, interval_ms)` tokens, capped at `capacity`, and advances `last_ms` by whole intervals only. At `now_ms < last_ms` (a clock that went back) it adds nothing and keeps `last_ms`. No float is used.
- A bucket that would be full at `now_ms`, whose tenant holds no slot, is the same as an absent bucket. It may be dropped to make room, oldest `last_ms` first, with ties in byte order of the key.
- Errors are fixed atoms that never echo a tenant or principal. The Piece emits no telemetry and no log.

## Acceptance

1. Config: each option at its bounds and one past them, `refill > capacity`, `tenant_in_flight > max_in_flight`, and a missing, extra or string key are each `:config`.
2. Buckets: with capacity 3, refill 1 and interval 1,000, three admissions at t=0 pass and the fourth is `:tenant_rate` with `retry_after_ms` 1,000. At t=999 the retry is still refused with 1. At t=1,000 one passes. At t=10,000 the bucket is full again (the cap holds). A cost of 2 with 1 token left gives the exact wait. A `now_ms` that goes back adds nothing and does not rewind `last_ms`.
3. All or nothing: a refusal at each of the five reasons leaves the returned state equal to the input (`==`), with no token taken and no slot held, including when the tenant bucket passed and the principal bucket refused.
4. Fair share: with `max_in_flight` 4 and `tenant_in_flight` 2, tenant A holds 2 slots and its third is `:tenant_slots`. Tenant B still gets 2. A fifth for tenant C is `:slots`. A release frees exactly A's slot, and a double release is `:unknown_ticket`. A noisy tenant that has spent all its tokens does not reduce another tenant's admissions.
5. Keys: with `max_keys` 2, a third tenant is `:keys` while both buckets are non-full or hold slots. It is admitted once one of them is idle and full at `now_ms`, which drops the oldest idle bucket.
6. Model check: a seeded sequence of 10,000 random `admit`/`release` operations with random times (including times that go back) over 3 tenants and 3 principals agrees, step by step, with an independent reference model written in the test from the rules above. Record the seed.
7. Shape: texts at 0, 1, 128 and 129 bytes, invalid UTF-8, NUL, DEL and U+0085; cost 0, cost above a capacity and a float; a negative `now_ms` and 2^63; a forged state. Each is `:malformed`.
8. Negative controls, one at a time: take the tenant token before checking the principal bucket and keep it on refusal; let `last_ms` move to `now_ms` on refill (the fractional interval is lost); skip the per-tenant slot bound. Each must make a case of groups 2–4 or 6 fail. Restore before the final gates.

Limits to state: one caller-held state that the host serializes; no distributed or multi-node limit, no persistence across restarts (a restart starts full), no queue, no weighted fairness and no priority. Costs are the host's estimate. The key cap fails closed with `:keys`, so a flood of new principals in one tenant can refuse new principals of other tenants once `max_keys` is reached; set it above the expected active set. Run the Piece tests and the new-Piece small gate (including the copied consumer), the roadmap and claims checks and the diff check. One independent review, the exact-head hosted check and the merge queue are required.
