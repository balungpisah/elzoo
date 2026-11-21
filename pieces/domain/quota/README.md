# domain/quota

A durable tenant allowance in PostgreSQL 16 over a consumer-owned Ecto Repo. Counters are kept
per tenant, window and unit. The amount of a unit is derived at each reservation from the
tenant's current `domain/entitlement` resolution and is not stored as authority. A Run
reservation reserves all of its units or none and is idempotent by `run_id`. A settlement
commits a known actual, or holds the estimate when the actual is `:unknown`; unknown usage
never counts as zero. `reconcile/3` ends a held amount with an attributable actual.

The tables are protected by the `state/tenant-isolation` floor. PostgreSQL row locks serialize
the decisions: there is no process and no volatile owner. A Run's `workflow/budget` cap is the
host's share of its reservation; this Piece does not start, stop or read Runs, read
`domain/metering`, price, post or read a clock, and it does not call `workflow/budget`.

## Copy and providers

Select `domain/quota` with `mix elzoo.take`; the copy is owned by the consuming application.
See [consuming](../../../docs/consuming.md). Piece dependencies: `state/tenant-isolation` and
`integration/ai-model` (the unit set, `Elzoo.AiModel.Usage.units/0` and `ttls/0`).
`domain/entitlement` is declared only so that the copied consumer can run the tests, which
build resolutions with `Elzoo.Entitlement.resolve/3`; the library code does not call it.
Providers: `ecto_sql` 3.14.0 and `postgrex` 0.22.4, `cure` (the per-unit counter decisions),
`elixir` and OTP `crypto` (SHA-256); the tests also use `telemetry`. Exact versions and
claim-level grounding are in [piece.json](piece.json).

## Migration

Call `Elzoo.Quota.Migration.install(prefix)` from the `up/0` of a consumer Ecto migration, run
by the table owner, in an existing schema `prefix`. It installs the `state/tenant-isolation`
readers in `prefix` (`CREATE OR REPLACE`), creates three tables and protects each with the
tenant floor (`tenant_column: "tenant"`, `space_column: nil`):

| Table | Columns | Keys |
| --- | --- | --- |
| `elzoo_quota_counters` | `tenant`, `window_tag`, `window_id`, `unit`, `committed`, `held`, `reserved` (each `numeric(38,0)`, `>= 0`) | `PRIMARY KEY (tenant, window_tag, window_id, unit)` |
| `elzoo_quota_reservations` | `tenant`, `run_id`, `window_tag`, `window_id`, `expiry_ms bigint`, `request_digest bytea`, `state` (`open`, `released`, `settled`) | `PRIMARY KEY (tenant, run_id)` |
| `elzoo_quota_units` | `tenant`, `run_id`, `unit`, `estimate numeric(38,0)`, `settled_unknown`, `actual numeric(38,0)` (`NULL` while open or held), `basis`, `actor_ref`, `reason` | foreign key to the reservation, index `(tenant, run_id, unit)` |

A unit is stored as its atom name, or `cache_write_tokens:<ttl>`; a window `{:period, id}` as
`window_tag` `period` and `window_id` `id`. The unit rows of a reservation are written once,
with its reservation row, so the reservation key decides their uniqueness. `prefix` must match
`^[a-z_][a-z0-9_]{0,62}$`; anything else raises `ArgumentError` with the fixed message
`"invalid quota prefix or options"` before any DDL. Nothing is reversible by the Piece; a
`down/0` is the consumer's.

### Grants

The minimum grants for the application role:

```sql
GRANT USAGE ON SCHEMA prefix TO app_role;
GRANT SELECT, INSERT, UPDATE ON prefix.elzoo_quota_counters, prefix.elzoo_quota_reservations, prefix.elzoo_quota_units TO app_role;
```

Nothing else: no `DELETE`. Call `Elzoo.TenantIsolation.verify/3` for each table at startup,
connected as the application role, with `prefix: prefix, tenant_column: "tenant",
space_column: nil` (it also needs the database `TEMP` privilege; see the
`state/tenant-isolation` README).

## Interface

```elixir
quota = Elzoo.Quota.new(repo: MyApp.Repo, prefix: "billing")
{:entitled, resolution} = Elzoo.Entitlement.resolve(facts, "t1", now_ms)

{:ok, :applied} =
  Elzoo.Quota.reserve(quota, "t1", %{
    run_id: "run-42", window: {:period, "2026-11"},
    estimates: [%{unit: :input_uncached_tokens, amount: 2_000}, %{unit: :output_tokens, amount: 1_000}],
    expiry_ms: now_ms + 600_000, now_ms: now_ms, resolution: resolution
  })

{:ok, :applied} =
  Elzoo.Quota.settle(quota, "t1", %{
    run_id: "run-42",
    actuals: [%{unit: :input_uncached_tokens, actual: 1_870}, %{unit: :output_tokens, actual: :unknown}]
  })

{:ok, :applied} =
  Elzoo.Quota.reconcile(quota, "t1", %{
    run_id: "run-42", unit: :output_tokens, actual: 640, basis: :metering,
    actor_ref: "svc:metering", reason: "provider usage correction"
  })

{:ok, rows} = Elzoo.Quota.status(quota, "t1", %{window: {:period, "2026-11"}, resolution: resolution})
```

- `new(opts)`: exactly `repo:` and `prefix:`; else the fixed `ArgumentError`.
- `reserve(quota, tenant, %{run_id, window, estimates, expiry_ms, now_ms, resolution})`:
  `estimates` is a list of 1..16 `%{unit, amount}` sorted by `unit` in Erlang term order and
  unique, `amount` an integer 1..2^63−1 (the unit set has 15 members, so 16 is reachable only
  after a unit is added). `resolution` is the value inside `{:entitled, resolution}` or
  `{:grace, resolution}` from `Elzoo.Entitlement.resolve/3`. `{:ok, :applied}` or
  `{:ok, :duplicate}`.
- `settle(quota, tenant, %{run_id, actuals})`: `actuals` lists exactly the reserved units,
  sorted, each `%{unit, actual}` with an integer 0..2^63−1 or `:unknown`.
- `reconcile(quota, tenant, %{run_id, unit, actual, basis, actor_ref, reason})`: for a unit
  settled `:unknown`; `basis` is `:metering` (an actual from a `domain/metering` correction) or
  `:write_off` (an operator's decision, which may be 0). `basis`, `actor_ref` and `reason` are
  kept on the unit row.
- `release(quota, tenant, %{run_id, now_ms})`: frees an open reservation whose Run did not start,
  before its expiry.
- `status(quota, tenant, %{window, resolution})`: `{:ok, rows}`, one
  `%{unit, amount, settle_only, committed, held, reserved, remaining}` for each unit with an
  allowance of the window's kind in the resolution or a counter row in the window, sorted by
  unit; `remaining` is `max(amount − committed − held − reserved, 0)`. `resolution` may be
  `nil` (for example after a revocation): then each counter row of the window is listed with
  `amount` 0 and `settle_only: false`.

Texts (`tenant`, the window ID, `actor_ref`) are 1..128 bytes of valid UTF-8 without a C0 or C1
control character, compared by exact bytes; `run_id` is 1..200 bytes and `reason` 1..256 bytes
under the same rule. `unit` is one of `Elzoo.AiModel.Usage.units/0` or
`{:cache_write_tokens, ttl}` with `ttl` one of `Elzoo.AiModel.Usage.ttls/0`. Times are integers
0..2^63−1, host-supplied Unix milliseconds that the Piece only compares.

Errors are `{:error, reason}` with a fixed atom that never echoes an ID or amount: `:invalid`,
`:resolution`, `:in_transaction`, `:isolation`, `:conflict`, `:no_allowance`, `:settle_only`,
`:expiry`, `:insufficient`, `:unknown_reservation`, `:not_held`, `:expired`,
`:already_settled`, `:unavailable`. The window tag, `basis`, unit and error sets, and the
returned maps, may gain members and keys in a later in-place version; match on the members and
keys you use.

## Windows and allowances

A window is a tagged term, in this version exactly `{:period, id}` with an opaque host period
ID (for example `"2026-11"` for a UTC calendar month); the Piece never derives a window from a
time. The entitlement `period_kind` `:utc_month` maps to the tag `:period`. A new window is a
new allowance: nothing carries over and there is no reset.

The amount of a unit for a window is the sum of the `amount`s of the resolution's allowances of
that unit whose `period_kind` maps to the window's tag and whose `settle_only` is `false`. The
unit is settle-only when the resolution lists allowances of that unit and kind and every one is
`settle_only`. An allowance whose `unit` or `period_kind` this version does not map is ignored
after its `grant_id` check.

## Rules

`reserve/3` stops at the first failure:

1. Shape and bounds of every field (`:invalid`); a window tag other than `:period` is
   `:invalid`.
2. The resolution (`:resolution`): `tenant` equal to `tenant`; `grants` a non-empty proper list
   of maps with a `grant_id` (unique) and `status` `:entitled` or `:grace`; `allowances` a
   proper list of maps with `unit`, `amount` (1..2^63−1), `period_kind`, `settle_only` (a
   boolean) and `grant_id`; every allowance's `grant_id` one of the listed grants and its
   `settle_only` `true` exactly when that grant's `status` is `:grace`. Other keys are ignored.
3. `repo.in_transaction?()` is `:in_transaction`. Steps 1–3 run before any query.
4. One transaction through `Elzoo.TenantIsolation.transact/3` with scope `%{tenant: tenant}`;
   its first query refuses a `transaction_isolation` other than `read committed` as
   `:isolation`.
5. Insert the reservation row (`ON CONFLICT DO NOTHING`). On a conflict, an equal request
   digest is `{:ok, :duplicate}` and changes nothing, whatever the resolution, `now_ms` or
   counters are now; another digest is `:conflict`. `:duplicate` reports the first result, not
   the current state: after `release/3` or `settle/3` of that `run_id` a retry is still
   `:duplicate` and reserves nothing, so the host must not start a Run whose reservation it has
   released or settled.
6. A unit without an allowance of the window's kind in the resolution is `:no_allowance`.
7. `expiry_ms <= now_ms` is `:expiry`.
8. Create each missing counter row and lock it with `SELECT ... FOR UPDATE`, one unit at a time
   in the order of `estimates`. Every function that locks counter rows uses this unit order.
9. Per unit, the Cure decision: a settle-only unit is `:settle_only` (grace reserves nothing
   new); else admitted only when `committed + held + reserved + estimate <= amount`; else
   `:insufficient`.
10. Insert the unit rows and add each estimate to `reserved`.

`settle/3`: shape, `:in_transaction`, the isolation check, then lock the reservation row (none
is `:unknown_reservation`); `actuals` must name exactly the reserved units (`:invalid`); an
already settled reservation with equal actuals is `{:ok, :duplicate}` and with others
`:conflict`. Then, per unit in unit order, a known actual leaves `reserved` and is committed in
full (so `committed` may pass `amount`), and `:unknown` moves the estimate from `reserved` to
`held`. Settlement needs no resolution: it is accepted in grace, after a revocation and after
the expiry, and it lands in the reservation's own window. After `release/3` the estimate is no
longer in `reserved`, so only the actual is committed, or the estimate is added to `held` for
`:unknown`.

`reconcile/3`: shape, `:in_transaction`, the isolation check, the reservation row
(`:unknown_reservation`); a unit that is not reserved, or whose settlement was not `:unknown`,
is `:not_held`; for a unit already reconciled, equal fields are `{:ok, :duplicate}` and others
`:conflict`; else the estimate leaves `held` and `actual` is committed.

`release/3`: shape, `:in_transaction`, the isolation check, the reservation row
(`:unknown_reservation`); a settled reservation is `:already_settled`, also one settled after
its release; a released one is `{:ok, :duplicate}`; an open one with `expiry_ms <= now_ms` is
`:expired` and stays counted (its Run may have started); else each estimate leaves `reserved`.
An open reservation is never freed by time: an operator ends a lost one by settling `:unknown`
and reconciling with `basis: :write_off`.

`status/3` checks the shape and, when `resolution` is not `nil`, the resolution, then
`:in_transaction`, then runs one read under the tenant scope (no isolation check).

A refusal commits nothing, so a retry of a refused request is evaluated again. A database
failure, including a lost connection, is `{:error, :unavailable}` and says nothing about whether
the write committed; a retry with the same request is safe.

### Request digest

The stored digest is the SHA-256 of the canonical encoding below. A field is
`<<byte_size(name)::32, name, byte_size(value)::32, value>>` (big-endian lengths). The encoding
is the ASCII tag `elzoo-quota-reservation/1` followed by the fields `run_id`, `window_tag`
(`period`), `window_id`, `estimates` and `expiry_ms`. The value of `estimates` is the
concatenation of one `estimate` field per estimate in unit order, whose value is the fields
`unit` (the stored unit text) and `amount`; integers are decimal ASCII. `now_ms` and the
resolution are not encoded, so a retry is a duplicate. A field that a later in-place version
adds as optional is appended only when present, so existing digests, and the duplicates they
decide, stay equal.

## Consumer Needs

- PostgreSQL 16 and READ COMMITTED, the server default. The Piece checks the level and refuses
  every write with `:isolation` under another level, but cannot set it.
- The migration runs as the table owner; the application connects as a non-owner role without
  `BYPASSRLS` or superuser, with the grants above.
- The host chooses the window and supplies a current resolution for each reservation.

## Limits

- The `state/tenant-isolation` limits apply: the table owner can turn forcing off or drop the
  policies, and a superuser or `BYPASSRLS` role ignores them. The consumer Repo's query
  telemetry still receives the scope parameters (the tenant).
- READ COMMITTED is a consumer Need that the Piece checks but cannot set.
- The host chooses the window and supplies a current resolution: a resolution resolved before
  a revocation still admits until the host resolves again.
- Allowance is permission to spend, not the total charge: an actual can exceed its estimate.
- A Repo that is not running (never started, or stopped as during a restart) is not a
  database failure: `repo.in_transaction?()` raises Ecto's `RuntimeError` before any query, as
  in `domain/journal` and `domain/metering`. Call the Piece only while the Repo runs; a failed
  query or a lost connection on a running Repo is `{:error, :unavailable}`.
- Held and expired amounts stay counted until settled or reconciled; there is no timer.
- No rolling window, local month, carry-over, per-principal allowance, pricing or posting.
- No audit capture of the quota tables (`state/audit-log` does not capture them).
- The Piece emits no telemetry event and has no process; the consumer owns the Repo, the
  migrations and the roles.
