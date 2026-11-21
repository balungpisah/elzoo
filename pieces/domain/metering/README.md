# domain/metering

Retained usage observations with attributable corrections, and bounded totals per period, unit
and source, or per period, provider, model, unit and source, in which an unknown amount is
counted apart and never added as zero. One durable Piece in plain Elixir, Ecto and Postgrex
over a consumer-owned Ecto Repo on PostgreSQL 16; its two tables are protected by the
`state/tenant-isolation` floor.

Usage comes from `integration/ai-model` usage values that the host splits into observations,
one per unit; the host owns that split. No pricing, cost, quota, admission or provider call.

Every ID is an opaque host value. The period is an opaque host ID too (for example `2026-11` for
a UTC calendar month): the Piece never derives a period from a time, so a tenant-local month or
a rolling window needs no change here. Each observation keeps `observed_at_ms`, recorded and
never interpreted, so a later in-place addition can give totals over a time range.

## Copy and providers

Select `domain/metering` with `mix elzoo.take`; the dependency-closed copy is owned by the
consuming application. See [consuming](../../../docs/consuming.md). Piece dependencies:
`state/tenant-isolation` (the floor, its migration helper and `transact/3`) and
`integration/ai-model` (`Elzoo.AiModel.Usage.units/0` and `ttls/0`). No Cure source.
Providers: `ecto_sql` 3.14.0 and `postgrex` 0.22.4, `elixir`, `otp` (`:crypto` SHA-256); the
tests also use `telemetry`. Exact versions and claim-level grounding are in
[piece.json](piece.json).

## Migration

Call `Elzoo.Metering.Migration.install(prefix)` from the `up/0` of a consumer Ecto migration,
run by the table owner, in an existing schema `prefix`. It installs the tenant-isolation
readers in `prefix` (`CREATE OR REPLACE`), creates two tables and protects each with
`Elzoo.TenantIsolation.Migration.protect/2` (`tenant_column: "tenant"`, `space_column: nil`):

- `elzoo_metering_observations`: `PRIMARY KEY (tenant, usage_id)`, the request fields, the
  recorded `amount`, the request `digest`, the `effective` amount and the correction
  `revision` (the number of corrections). An index on `(tenant, period, unit, source)` serves
  the totals.
- `elzoo_metering_corrections`: `PRIMARY KEY (tenant, correction_id)`, a foreign key
  `(tenant, usage_id)` to the observation, `UNIQUE (tenant, usage_id, revision)`, the amount,
  `reason`, `actor_ref` and `digest`.

Amounts are `bigint`, `NULL` for unknown; sums are computed as `numeric`. `prefix` must match
`^[a-z_][a-z0-9_]{0,62}$`; anything else raises `ArgumentError` with the fixed message
`"invalid metering repo or prefix"` before any DDL is queued. Nothing is reversible by the
Piece; a `down/0` is the consumer's.

### Grants

The application role needs exactly these, and nothing else:

```sql
GRANT USAGE ON SCHEMA prefix TO app_role;
GRANT SELECT, INSERT ON prefix.elzoo_metering_corrections TO app_role;
GRANT SELECT, INSERT, UPDATE ON prefix.elzoo_metering_observations TO app_role;
```

With no `DELETE` grant, and no `UPDATE` on corrections, the application role cannot remove an
observation or rewrite a correction (SQLSTATE 42501). Connect it as a non-owner role that does
not bypass row security, and call `Elzoo.TenantIsolation.verify/3` for both tables at startup.

## Interface

```elixir
meter = Elzoo.Metering.new(repo: MyApp.Repo, prefix: "billing")

Elzoo.Metering.record(meter, "tenant-1", %{
  usage_id: "run-7/op-2/attempt-1/output",
  run_id: "run-7", operation_id: "op-2", attempt_id: "attempt-1",
  provider_id: "anthropic", model_id: "model-a",
  unit: :output_tokens, amount: 512, source: :provider_reported,
  period: "2026-11", observed_at_ms: 1_795_000_000_000
})
#=> {:ok, :applied}
```

- `new(opts)` takes exactly `repo:` (a started Ecto Repo module) and `prefix:` and returns a
  meter value, or raises the fixed `ArgumentError`.
- `record(meter, tenant, observation)`: `observation` is exactly `%{usage_id, run_id,
  operation_id, attempt_id, provider_id, model_id, unit, amount, source, period,
  observed_at_ms}`. `{:ok, :applied}`; `{:ok, :duplicate}` when `usage_id` is stored with an
  equal request digest; `{:error, :conflict}` for another.
- `correct(meter, tenant, correction)`: `correction` is exactly `%{correction_id, usage_id,
  amount, reason, actor_ref}`. Appends a correction to an existing observation and makes
  `amount` its effective amount. The effective amount is the latest correction by commit
  order, else the recorded amount. `{:ok, :applied}`, `{:ok, :duplicate}` (same
  `correction_id`, equal digest), `{:error, :conflict}` (same `correction_id`, another
  request, including another `usage_id`), `{:error, :unknown_usage}` (no such observation of
  this tenant) or `{:error, :read_limit}` for a 1,025th correction.
- `totals(meter, tenant, %{period, max_rows})`, `max_rows` in 1..1000: `{:ok, rows}`, one
  `%{unit, source, known, unknown_count, count}` per `{unit, source}` with an observation in
  the period, sorted by unit then source in Erlang term order (atoms before
  `{:cache_write_tokens, ttl}` tuples). `known` is the sum of the known effective amounts,
  `unknown_count` the number of observations whose effective amount is `:unknown`, `count`
  all observations. More groups than `max_rows` is `{:error, :read_limit}`, never a
  truncated list.
- `model_totals(meter, tenant, %{period, max_rows})`, `max_rows` in 1..1000: `{:ok, rows}`,
  one `%{provider_id, model_id, unit, source, known, unknown_count, count}` per `{provider_id,
  model_id, unit, source}` with an observation in the period, sorted by those four in Erlang
  term order (IDs by their bytes). `known`, `unknown_count` and `count` mean what they mean in
  `totals/3`, so over the same observations each `totals/3` row is the sum of its provider and
  model rows. More groups
  than `max_rows` is `{:error, :read_limit}`, never a truncated list. These rows are the
  `rows` of a `domain/pricing` usage value `%{tenant, period, rows}`.
- `observation(meter, tenant, usage_id)`: `{:ok, %{usage_id, run_id, ..., observed_at_ms,
  effective, corrections}}` with the corrections (each the five correction fields) in commit
  order, at most 1,024, or `{:error, :unknown_usage}` for an absent or another tenant's
  observation.

### Fields

| Field | Rule |
| --- | --- |
| `tenant`, `usage_id`, `provider_id`, `model_id`, `period`, `correction_id`, `actor_ref` | 1..128 bytes of valid UTF-8 without a C0 or C1 control character (U+0000–U+001F, U+007F–U+009F), compared by exact bytes |
| `run_id`, `operation_id`, `attempt_id` | 1..200 bytes under the same rule; the run engine's IDs fit when they hold no control character (it refuses only NUL; another control character is `:invalid` here) |
| `reason` | 1..256 bytes under the same rule |
| `unit` | one of `Elzoo.AiModel.Usage.units/0`, or `{:cache_write_tokens, ttl}` with `ttl` one of `Elzoo.AiModel.Usage.ttls/0` |
| `amount` | an integer 0..9_223_372_036_854_775_807 or `:unknown` |
| `source` | `:estimated`, `:provider_reported` or `:unknown` |
| `observed_at_ms` | an integer 0..2^63−1, recorded and never interpreted |

The unit set is read from `integration/ai-model` at each call. No host unit (such as `runs`)
is in it yet; a later unit is a new member added in place.

Errors are `{:error, reason}` with a fixed atom that never echoes an ID or amount: `:invalid`,
`:in_transaction`, `:isolation`, `:conflict`, `:unknown_usage`, `:read_limit`, `:unavailable`.
The unit, source and error sets, and the maps returned, may gain members and keys in a later
in-place version; match on the members and keys you use.

## Rules

Each write checks, in order: shape and bounds (`:invalid`), then `repo.in_transaction?()`
(`:in_transaction`), both before any query; then one transaction through
`Elzoo.TenantIsolation.transact/3` with scope `%{tenant: tenant}`. Its first query reads
`current_setting('transaction_isolation')` and refuses anything but `read committed` as
`:isolation`: READ COMMITTED is a consumer Need that the Piece checks but cannot set.

- `record/3` inserts with `ON CONFLICT (tenant, usage_id) DO NOTHING` and on a conflict
  compares digests, so two concurrent records of one `usage_id` store one: the second waits
  for the first, then is `:duplicate` or `:conflict`.
- `correct/3` locks the observation row (`FOR UPDATE`; none is `:unknown_usage`), looks up
  the `correction_id` (equal digest `:duplicate`, another `:conflict`), refuses a 1,025th
  correction (`:read_limit`), then inserts the correction with the next revision and sets
  the effective amount. Two concurrent corrections with one `correction_id` are ordered by
  the lock and the second is `:duplicate`; concurrent corrections are ordered by their commit.
- A database failure is `{:error, :unavailable}` and says nothing about whether the write
  committed; a retry with the same ID and request is safe.

Reads take the shape check, then `:in_transaction`, then one statement under the tenant scope;
they do not check the isolation level.

### Request digest

The digest is SHA-256 over `"elzoo.metering." <> kind <> <<0>>` followed by each request field,
sorted by its name, as `<<byte_size(name)::32, name::binary, byte_size(value)::32,
value::binary>>`: each length is a 32-bit unsigned big-endian integer, and the name is the
field's map key as text (for example `usage_id`). `kind` is `observation` or `correction`.
Values: text as its bytes; integers as ASCII decimal without sign or leading zeros;
`:unknown` as `unknown`; a unit as its atom name, or `cache_write_tokens:` and the TTL; a
source as its atom name. The tenant is not encoded: it is part of every key. A field that a
later in-place version adds as optional is encoded only when present, so existing digests,
and the duplicates they decide, stay equal.

## Limits

- The `state/tenant-isolation` limits apply: the table owner can turn forcing off or drop the
  policies, and a superuser or `BYPASSRLS` role ignores them.
- The host chooses the period and splits a usage value into observations; this Piece does not
  check that a split is complete or that a period matches `observed_at_ms`.
- No price, cost or allowance. Totals over a time range and other period kinds are later
  in-place additions.
- `totals/3` and `model_totals/3` read every observation of the period for the tenant (served
  by the index); the bound is on returned groups, not on rows scanned.
- The `UPDATE` grant on observations lets code that runs its own SQL as the application role
  overwrite an observation's columns (including `amount`, `effective` and `digest`) without a
  correction; only calls through this Piece keep the correction record.
- The Repo must be a started Ecto Repo: an unstarted Repo or another module raises from
  `in_transaction?/0` instead of returning an error atom.
- A stored `unit` or `source` the running copy does not know (a row written outside the
  Piece, or a copy whose set lost a member) raises at read; the sets only gain members in place.
- The Piece emits no telemetry and no log, and its queries pass `log: false`; the consumer
  Repo's query telemetry still receives their parameters (tenant and IDs).

## Evidence

[test/elzoo/metering_test.exs](test/elzoo/metering_test.exs) runs on the worker's own
disposable PostgreSQL 16 database (`ELZOO_TEST_DATABASE_URL`) with
`DBConnection.ConnectionPool` Repos, in random schemas dropped afterwards. Every Piece call
runs as the ELZ-285 application role (`SET ROLE` to `ELZOO_TEST_APP_ROLE` on every connection)
with only the grants above; the tests fail, not skip, without that variable. Finite
scenarios, not proofs.
