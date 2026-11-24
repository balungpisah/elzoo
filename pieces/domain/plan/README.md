# domain/plan

A tenant's subscription to one plan version in PostgreSQL 16 over a consumer-owned Ecto Repo:
a fee of one `domain/money` amount per period, periods that are UTC calendar months or years
counted from an anchor and clamped to the month's last day, an optional trial, a renewal that
advances exactly one period when it is due and returns that period's fee line and its
`domain/entitlement` grant, a plan change that takes effect at the next renewal, and a cancel at
period end or now.

The table is protected by the `state/tenant-isolation` floor, and PostgreSQL row locks serialize
the writes: there is no process and no timer. The Piece prices nothing beyond the declared fee
(no proration, refund, tax or dunning) and writes no grant, invoice or journal row. The host
calls `renew/3` with its trusted time (for example from a `state/scheduler` tick), stores the
grants that each call returns with its `domain/entitlement` facts, applies the returned
revocations to them, and puts each fee line on a `domain/invoice` invoice.

## Copy and providers

Select `domain/plan` with `mix elzoo.take`; the copy is owned by the consuming application. See
[consuming](../../../docs/consuming.md). Piece dependencies: `state/tenant-isolation` (the
floor and `transact/3`), `domain/money` (the fee, stored as its `Elzoo.Money.Codec` bytes) and
`domain/entitlement` (the consumer of the grant shape; the tests resolve the returned grants
with `Elzoo.Entitlement.resolve/3`, and the library code does not call it). Providers:
`ecto_sql` 3.14.0 and `postgrex` 0.22.4, `cure` (the period rule), `elixir` and OTP (`:calendar`
for the UTC civil date of a time); the tests also use `telemetry`. Exact versions and
claim-level grounding are in [piece.json](piece.json).

## Migration

Call `Elzoo.Plan.Migration.install(prefix)` from the `up/0` of a consumer Ecto migration, run
by the table owner, in an existing schema `prefix`. It installs the `state/tenant-isolation`
readers in `prefix` (`CREATE OR REPLACE`), creates the table `elzoo_plan_subscriptions` with
`PRIMARY KEY (tenant, subscription_id)` and the unique partial index `elzoo_plan_one_open` on
`tenant` for rows whose `state` is not `canceled` (one open subscription per tenant), and
protects it with the tenant floor (`tenant_column: "tenant"`, `space_column: nil`). `prefix`
must match `^[a-z_][a-z0-9_]{0,62}$`; anything else raises `ArgumentError` with the fixed
message `"invalid plan prefix"` before any DDL. Nothing is reversible by the Piece.

A row keeps the create request (`created_plan_id`, `created_version`, `created_fee`,
`start_ms`, `trial_end_ms`, `interval`), the current subscription, `renewed_from` (the
`from_index` of the renewal that made the current period, `NULL` when create made it) and the
result of the cancel that committed last (`last_cancel_grant_ids`, `last_cancel_revoked_at`,
and `last_cancel_withdrawn`, which is `NULL` when no cancel committed). Amounts are stored as
their `Elzoo.Money.Codec.encode/2` bytes.

### Grants

The minimum grants for the application role:

```sql
GRANT USAGE ON SCHEMA prefix TO app_role;
GRANT SELECT, INSERT, UPDATE ON prefix.elzoo_plan_subscriptions TO app_role;
```

Nothing else: no `DELETE`. Call `Elzoo.Plan.verify/1` at startup, connected as the application
role; it calls `Elzoo.TenantIsolation.verify/3` for the table (which also needs the database
`TEMP` privilege; see the `state/tenant-isolation` README).

## Interface

```elixir
{:ok, plan} = Elzoo.Plan.new(repo: MyApp.Repo, prefix: "billing", renew_ahead_ms: 3_600_000)
{:ok, usd} = Elzoo.Money.parse("USD")
{:ok, fee} = Elzoo.Money.from_minor_units(usd, 2_900)

{:ok, %{subscription: s, fee_line: nil, grants: [trial_grant]}} =
  Elzoo.Plan.create(plan, "t1", %{
    subscription_id: "sub-1", plan: %{plan_id: "pro", version: 3}, fee: fee,
    interval: :month, start_ms: now_ms, trial_end_ms: now_ms + 14 * 86_400_000
  })

# From the host's scheduler tick, with its trusted time, due from the trial's end minus
# renew_ahead_ms:
tick_ms = s.period.end_ms - 3_600_000

{:ok, %{fee_line: line, grants: [grant], duplicate: false}} =
  Elzoo.Plan.renew(plan, "t1", %{subscription_id: "sub-1", from_index: s.period.index, now_ms: tick_ms})

{:ok, %{subscription: s}} =
  Elzoo.Plan.change(plan, "t1", %{subscription_id: "sub-1", expected_revision: 2,
    plan: %{plan_id: "team", version: 1}, fee: team_fee})

# A day into period 1 (inside the ahead window it would withdraw period 1 instead):
{:ok, %{revocations: [], withdrawn_fee_line: nil}} =
  Elzoo.Plan.cancel(plan, "t1", %{subscription_id: "sub-1", expected_revision: 3,
    at: :period_end, now_ms: line.period.start_ms + 86_400_000})
```

- `new(opts)`: exactly `repo:` and `prefix:`, and optionally `renew_ahead_ms:` (an integer
  0..86,400,000, default 0); `{:ok, binding}` or `{:error, :invalid}`.
- `create(p, tenant, %{subscription_id, plan, fee, interval, start_ms, trial_end_ms})`: `plan`
  is `%{plan_id, version}`, `fee` a non-negative `%Elzoo.Money.Amount{}`, `interval` `:month`
  or `:year`, `trial_end_ms` `nil` or greater than `start_ms`. The anchor is `trial_end_ms`, or
  `start_ms` without a trial. With a trial the subscription is `:trialing` in period 0
  (`start_ms` to the anchor) and the result is `%{subscription, fee_line: nil, grants:
  [grant_of_period_0], duplicate: false}`; without one it is `:active` in period 1 and the
  result holds that period's fee line and grant. A create with equal bytes (plan, fee bytes,
  interval, `start_ms`, `trial_end_ms`) returns the first result, rebuilt from the stored
  request, with `duplicate: true`, also after later renewals and changes; other bytes are
  `:conflict`; a tenant that holds a subscription that is not `:canceled` gets
  `:subscription_exists`.
- `renew(p, tenant, %{subscription_id, from_index, now_ms})`:
  `{:ok, %{subscription, fee_line, grants, duplicate, withdrawn_fee_line}}` (rules below).
- `change(p, tenant, %{subscription_id, expected_revision, plan, fee})`: sets
  `pending_change`, which the next advancing renewal takes as the plan and fee (no proration);
  a later change replaces it. `{:ok, %{subscription}}`.
- `cancel(p, tenant, %{subscription_id, expected_revision, at: :period_end | :now, now_ms})`:
  `{:ok, %{subscription, revocations, withdrawn_fee_line}}` (rules below).
- `mark_past_due(p, tenant, %{subscription_id, expected_revision})` from `:active`, and
  `mark_paid(p, tenant, %{subscription_id, expected_revision})` from `:past_due` to `:active`:
  the host's reading of the invoice. `{:ok, %{subscription}}`.
- `get(p, tenant, %{subscription_id})`: `{:ok, %{subscription, last_cancel}}`, `last_cancel`
  `nil` or the stored `%{revocations, withdrawn_fee_line}` of the cancel that committed last.
- `verify(p)`: `Elzoo.TenantIsolation.verify/3` for the table: `:ok` or `{:error, reason}`.

A **subscription** is `%{subscription_id, plan: %{plan_id, version}, fee, interval, anchor_ms,
state, period: %{index, start_ms, end_ms}, trial_end_ms, cancel_at_period_end, cancel_ms,
pending_change, revision}`. `state` is `:trialing`, `:active`, `:past_due` or `:canceled`.
Period 0 is the trial; period `k ≥ 1` runs from boundary `k − 1` to boundary `k` (boundary 0
is the anchor). `pending_change` is `nil` or `%{plan, fee}`; `cancel_ms` is `nil` or the end
that a period-end cancel fixed; `revision` starts at 1 and every write adds 1.

A **fee line** is `%{subscription_id, period: %{index, start_ms, end_ms}, plan: %{plan_id,
version}, amount}`, the shape `domain/invoice` takes; period 0 has none. A **grant** is the
`domain/entitlement` grant `%{grant_id: "<subscription_id>/<index>", tenant, plan_id, version,
valid_from_ms: start_ms, valid_to_ms: end_ms, grace_until_ms: nil, revoked_at_ms: nil}`, and a
**revocation** is `%{grant_id, revoked_at_ms}`, which the host sets on its stored grant.

`tenant` and `plan_id` are 1..128 bytes, `subscription_id` 1..100 bytes, of valid UTF-8 without
a C0 or C1 control character (the `domain/entitlement` text rule), compared by exact bytes;
`version` is an integer 1..2^31−1; times, `from_index` and `expected_revision` (from 1) are
integers 0..2^63−1. A period that would end after 2^63−1 ms is `:invalid`.

Errors are `{:error, reason}` with a fixed atom that never echoes an ID: `:invalid`,
`:in_transaction`, `:isolation`, `:conflict`, `:subscription_exists`, `:unknown_subscription`,
`:not_due`, `:stale_period`, `:stale_revision`, `{:state, state}`, `:unavailable`. The interval,
state and error sets, and the subscription, request and result maps, may gain members and
optional keys in a later in-place version; match on the members and keys you use.

## The period rule

The Cure module `Cure.Elzoo.PlanPeriod` (`cure/elzoo/plan_period.cure`) holds the pure rule over
civil dates: `days_in_month(year, month)` by the Gregorian rule (February has 29 days in a year
divisible by 4 and not by 100, or by 400), and `boundary(anchor_year, anchor_month, anchor_day,
interval, k)` for `k ≥ 0`, the date `k` months (`Month()`) or `12k` months (`Year()`) after the
anchor's month, with day `min(anchor_day, days_in_month(...))`. A boundary is always computed
from the anchor, never from the boundary before it: a 31 January 2027 anchor gives 28 February,
31 March and 30 April; a 29 February 2024 yearly anchor gives 28 February 2025 and 29 February
2028. `Elzoo.Plan` converts a Unix millisecond time to and from a UTC civil date and time of day
with OTP `:calendar`; a boundary keeps the anchor's UTC time of day.

## Rules

Every function checks the shape and bounds of its request (`:invalid`), then
`repo.in_transaction?()` (`:in_transaction`) before any query, and runs in its own transaction
through `Elzoo.TenantIsolation.transact/3` with scope `%{tenant: tenant}`. In every write the
first query refuses a `transaction_isolation` other than `read committed` as `:isolation`
(`get/3` reads without that check). `renew/3` and every transition take the subscription row
with `SELECT ... FOR UPDATE`; a subscription that the tenant does not hold is
`:unknown_subscription`. Every statement passes `log: false`.

`renew/3`, under the row lock:

1. When the current period's index is `from_index + 1` and a renewal from `from_index` made
   it: the stored result of that renewal again, with `duplicate: true`, and nothing is written.
   Its fee line and grant are those of the current period (no later write changes the period,
   plan or fee of a period until the next renewal, and no renewal advances after a cancel), and
   `subscription` is the current one. When a cancel has since withdrawn that period, the repeat
   holds `fee_line: nil`, `grants: []` and that period's fee line as `withdrawn_fee_line`, so a
   retried renewal never bills a withdrawn period.
2. Otherwise a current index other than `from_index` is `:stale_period`, and a canceled
   subscription is `{:state, :canceled}`.
3. With `cancel_at_period_end` the renewal is `:not_due` until `now_ms ≥ cancel_ms`, also
   inside the ahead window (a cancel at period end is never taken ahead); then the subscription
   becomes `:canceled` in the same period, and the result has no fee line and no grant.
4. Otherwise `now_ms < end_ms − renew_ahead_ms` is `:not_due`. Else the pending change, if any,
   becomes the plan and fee, the period advances exactly one (period `from_index + 1`, also from
   the trial), a `:trialing` subscription becomes `:active` (a `:past_due` one stays
   `:past_due`), and the result holds the new period's fee line and grant.

A renewal far past its due time still advances one period; the host calls again for the next
one, so every period gets its fee line. A period is due at `end_ms − renew_ahead_ms`, so the host
can store the next period's grant before the boundary: that grant is not valid until `end_ms`,
so it never overlaps the current one, and the tenant has no gap at the boundary. After a renewal
ahead, `period` is the next period (its `start_ms` is still in the future) until `end_ms` of the
one before it passes. With `renew_ahead_ms` 0 the grant of the next period exists only once the
host's renewal at or after `end_ms` commits: the time between `end_ms` and that renewal is a gap
in the tenant's entitlement, which the host decides.

Each transition names the expected revision. It locks the row, then another revision is
`:stale_revision`, then a transition not allowed from the state is `{:state, state}`; a
canceled subscription takes none. `change/3` and `cancel/3` are allowed from `:trialing`,
`:active` and `:past_due`.

`cancel/3`:

- `:period_end` sets `cancel_at_period_end` and fixes `cancel_ms`, the end of the period running
  at `now_ms`: the current period's `end_ms`, or, when the current period has not started
  (`now_ms < start_ms`, after a renewal ahead), its `start_ms`. In that case the result also
  holds the revocation of the current period's grant at its `start_ms` and the current period's
  fee line as `withdrawn_fee_line`, which the host removes from what it bills (the period is
  never served). A `:period_end` cancel of a subscription whose `cancel_ms` is set keeps it,
  writes nothing and returns what follows from the row: when `cancel_ms` equals the current
  period's `start_ms`, the same revocation and `withdrawn_fee_line` as the cancel that fixed it,
  so a host that retries after `:unavailable` still gets both; otherwise no revocation and no
  fee line.
- `:now` makes the subscription `:canceled` and returns one revocation at `now_ms` for each grant
  of the subscription that has not expired at `now_ms`: the period before the current one while
  the current one has not started (after a renewal ahead), and the current one, in index order;
  no refund. When the current period has not started its fee line is `withdrawn_fee_line`.
  After a period-end cancel inside the ahead window, a cancel now keeps that cancel's
  withdrawal: the current period's grant is revoked at the earlier of its `start_ms` and
  `now_ms`, also once that grant has expired, and its fee line stays `withdrawn_fee_line`.

The same transaction stores `revocations` and `withdrawn_fee_line` in the row as `last_cancel`,
which no later renewal or transition changes (a cancel now after a period-end cancel stores its
own result, which keeps the earlier revocation and withdrawal as above), so a host whose cancel committed without a reply
(`:unavailable`, or a retry refused as `:stale_revision` or `{:state, :canceled}`) reads its
result with `get/3`, before and after the renewal that ends the subscription.

A past-due subscription renews like an active one; when to cancel it is the host's dunning
policy. A refusal commits nothing. A database failure, including a lost connection, is
`{:error, :unavailable}` and says nothing about whether the write committed; a retry with the
same request is safe: create and an advancing renewal return their first result again; a
retried renewal that ended the subscription is `{:state, :canceled}`, and a transition's retry
with the old revision is `:stale_revision`, after which `get/3` shows the committed state.

## Consumer Needs

- PostgreSQL 16 and READ COMMITTED, the server default. The Piece checks the level and refuses
  every write with `:isolation` under another level, but cannot set it.
- The migration runs as the table owner; the application connects as a non-owner role without
  `BYPASSRLS` or superuser, with the grants above.
- The host supplies its trusted time, stores the returned grants and applies the returned
  revocations in its `domain/entitlement` facts, bills the fee lines and removes a withdrawn fee
  line, and reads the invoice for `mark_past_due/3` and `mark_paid/3`.

## Limits

- The trusted time, the storage of the returned grants and fee lines, and the past-due reading
  are the host's. The Piece has no timer.
- UTC only; a period boundary keeps the anchor's UTC time of day. Monthly and yearly intervals
  only.
- One open subscription per tenant (the unique partial index), so its grants never overlap in
  `domain/entitlement`. The Piece does not compare a new subscription's `start_ms` with a
  canceled one's grants: the host starts it at or after the earlier subscription's last grant
  ends (its `cancel_ms`, or the revocation time of a cancel now), or `resolve/3` reports
  `:overlap` for the time in between.
- A `grant_id` (`<subscription_id>/<index>`) is unique within a tenant only, as
  `subscription_id` is. A host that resolves the grants of several tenants from one facts list
  uses subscription IDs unique across tenants, or supplies each tenant's own grants:
  `domain/entitlement` refuses a repeated `grant_id` in one facts list.
- No proration, refund, tax, dunning, timer or invoice.
- The rule over every day is test evidence, not a proof: the selected Cure laws are equalities
  over literal dates.
- The `state/tenant-isolation` limits apply: the table owner can turn forcing off or drop the
  policies, and a superuser or `BYPASSRLS` role ignores them. The consumer Repo's query
  telemetry still receives the scope parameters (the tenant).
- A Repo that is not running is not a database failure: Ecto's Repo lookup raises, and the Piece
  does not rescue it. Call the Piece only while the Repo runs.
- The Piece emits no telemetry event and has no process; the consumer owns the Repo, the
  migrations and the roles.

## Grounding

- Proof: the selected Cure laws of `cure/elzoo/plan_period.cure`, each checked by the pinned
  Cure by reduction over literals: `days_in_month` of February 2024, 2100, 2000 and 2027 is 29,
  28, 29 and 28; the boundary of a 31 January 2027 anchor with `k` 1, 2 and 13 is 28 February
  2027, 31 March 2027 and 29 February 2028; of a 29 February 2024 yearly anchor with `k` 1 and 4,
  28 February 2025 and 29 February 2028; of a 15 March 2026 anchor with `k` 0, 15 March 2026.
  Each states `date_number(boundary(...)) == yyyymmdd` (or `days_in_month(...) == n`) equal to
  `True()`, because the pinned Cure reduces a comparison over literals but not a record equality
  whose indices are numerals.
- Type: the pinned Cure checks the module with a clean audit (no axioms, holes, unresolved,
  unaudited, opaque or unproven-total items).
- Test: `test/elzoo/plan_test.exs` on a disposable PostgreSQL 16 database as the ELZ-285
  application role with only the grants above (piece.json lists the scenarios and the negative
  controls).
