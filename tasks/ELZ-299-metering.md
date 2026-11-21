# ELZ-299 — Retained usage observations whose unknown amounts never count as zero

- Phase: Wave 6 Level 1
- Dependencies: ELZ-033, ELZ-079, ELZ-270, ELZ-285
- Release: V1B
- Output: new `domain/metering` Piece (from RC-21)
- Change class: Piece-only
- Owned paths: `pieces/domain/metering/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece, `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One durable Piece in plain Elixir, Ecto and Postgrex over a consumer-owned Ecto Repo on PostgreSQL 16 (owner Q1 A, 2026-11-21): idempotent retained usage observations, attributable corrections that never delete, and bounded totals per period, unit and source in which an unknown amount is counted apart and never added as zero. The tables are protected by `state/tenant-isolation` (ELZ-270). Usage comes from `integration/ai-model` usage values (ELZ-079) that the host splits into observations; the host owns that split. No pricing, quota, admission, provider call or new dependency.

Every ID is an opaque host value. The period is an opaque host ID (for example `2026-11` for the UTC calendar month of owner Q6 A); this Piece never derives a period from a time, so another period kind (a tenant-local month, a rolling window) needs no change here. Each observation keeps `observed_at_ms`, so a later in-place addition can give totals over a time range.

## Interface

- `Elzoo.Metering.Migration.install(prefix)`, called from a consumer migration's `up/0` by the table owner, installs the `state/tenant-isolation` readers in `prefix` (`Elzoo.TenantIsolation.Migration.install/1` uses `CREATE OR REPLACE`), creates two tables in the existing schema `prefix` and protects each with `Elzoo.TenantIsolation.Migration.protect/2` (`space_column: nil`): observations with `PRIMARY KEY (tenant, usage_id)`, the request digest, the effective amount (`NULL` for unknown) and a correction revision; corrections with `PRIMARY KEY (tenant, correction_id)` and a reference to the observation. Amounts are `bigint`; sums are computed as `numeric`. `prefix` follows the tenant-isolation identifier rule; anything else raises `ArgumentError` with one fixed message before any DDL. Nothing is reversible by the Piece.
- `Elzoo.Metering.new(opts)` takes exactly `repo:` and `prefix:` and returns a meter value, or raises the same fixed `ArgumentError`.
- `record(meter, tenant, observation)`: `observation` is exactly `%{usage_id, run_id, operation_id, attempt_id, provider_id, model_id, unit, amount, source, period, observed_at_ms}`. Returns `{:ok, :applied}`, `{:ok, :duplicate}` for the same `usage_id` with an equal request digest, or `{:error, :conflict}` for another.
- `correct(meter, tenant, correction)`: `correction` is exactly `%{correction_id, usage_id, amount, reason, actor_ref}`. It appends a correction to an existing observation and makes `amount` its effective amount: the effective amount is the latest correction by commit order, else the recorded amount. Returns `{:ok, :applied}`, `{:ok, :duplicate}` for the same `correction_id` with an equal request digest, or `{:error, :conflict}` for another. An observation of another tenant, or none, is `{:error, :unknown_usage}`.
- `totals(meter, tenant, %{period, max_rows})` returns `{:ok, rows}`: at most `max_rows` (1..1000) rows, one per `{unit, source}` that has an observation in the period, sorted by unit then source in Erlang term order, each `%{unit, source, known, unknown_count, count}`. `known` is the sum of the known effective amounts; `unknown_count` is the number of observations whose effective amount is `:unknown`; `count` is all observations. When more groups exist than `max_rows` the result is `{:error, :read_limit}`, never a truncated list.
- `observation(meter, tenant, usage_id)` returns `{:ok, %{observation fields, effective, corrections}}` with the corrections in commit order, at most 1,024 of them (a 1,025th correction is refused `:read_limit` at `correct/3`), or `{:error, :unknown_usage}` for an absent or other tenant's observation.

Fields. `tenant`, `usage_id`, `provider_id`, `model_id`, `period`, `correction_id`, `actor_ref`: 1..128 bytes of valid UTF-8 without a C0 or C1 control character, compared by exact bytes. `run_id`, `operation_id` and `attempt_id`: 1..200 bytes under the same rule, so the run engine's Run, operation and Attempt IDs fit. `reason`: 1..256 bytes under the same rule. `unit`: one of `Elzoo.AiModel.Usage.units/0` (the counter units of `integration/ai-model`) or `{:cache_write_tokens, ttl}` with `ttl` one of `Elzoo.AiModel.Usage.ttls/0`, so every amount of a usage value, cache writes included, can be recorded. `amount`: an integer 0..9_223_372_036_854_775_807 or `:unknown`. `source`: `:estimated`, `:provider_reported` or `:unknown`. `observed_at_ms`: an integer 0..2^63-1, recorded and never interpreted. Under owner Q2 A the unit set gains no host unit in this task; a host unit such as `runs`, and any later unit, is a new member added in place.

Errors are `{:error, reason}` with a fixed atom that never echoes an ID or amount: `:invalid`, `:in_transaction`, `:isolation`, `:conflict`, `:unknown_usage`, `:read_limit`, `:unavailable`. The unit, source and error sets, and the maps returned, may gain members and keys in a later in-place version; a caller matches on the members and keys it uses.

## Rules

Each write checks, in order: shape and bounds (`:invalid`), then `repo.in_transaction?()` (`:in_transaction`), both before any query; then one transaction through `Elzoo.TenantIsolation.transact/3`, whose first check reads `current_setting('transaction_isolation')` and refuses anything but `read committed` as `:isolation` (READ COMMITTED is a consumer Need that the Piece checks but cannot set, as in `domain/journal`). `record/3` inserts with `ON CONFLICT DO NOTHING` and on a conflict compares digests, so two concurrent records of one `usage_id` store one. `correct/3` first looks up its `correction_id` (an equal digest is `:duplicate`, another `:conflict`), then locks the observation row (`FOR UPDATE`; none is `:unknown_usage`), refuses a 1,025th correction (`:read_limit`), then inserts the correction with the next revision and sets the effective amount, so concurrent corrections are ordered by their commit. The request digest is the SHA-256 of a documented canonical encoding of all request fields. A field that a later in-place version adds as optional is encoded only when present, so existing digests, and the duplicates they decide, stay equal. A database failure is `{:error, :unavailable}` and says nothing about whether the write committed; a retry with the same ID and request is safe. Reads take the shape check, then `:in_transaction`, then one read under the tenant scope.

The README states the minimum grants for the application role: `USAGE` on `prefix`, `SELECT, INSERT` on corrections, `SELECT, INSERT, UPDATE` on observations, nothing else. `piece.json` declares telemetry and control `not_applicable` and the config of the meter value and fixed bounds.

## Acceptance

Tests run on the worker's disposable PostgreSQL 16 (`ELZOO_TEST_DATABASE_URL`) with a `DBConnection.ConnectionPool` Repo, not the Sandbox, in random schemas dropped afterwards.

1. Exact duplicate and conflicting duplicate of `record/3` and of `correct/3`.
2. Two concurrent records of one `usage_id`: another connection, as the table owner, holds `LOCK TABLE ... IN SHARE MODE` on the observations table until both inserts wait on it (seen in `pg_locks`), then commits; one row is stored and the other call returns `:duplicate`.
3. An interrupted stream recorded with `amount: :unknown` stays out of `known` and is in `unknown_count`; a late correction to a known amount moves it into `known`; a correction back to `:unknown` moves it out again; the observation keeps every correction in order.
4. A correction of an absent `usage_id`, and of another tenant's, is `:unknown_usage`.
5. Mixed units (including a cache-write unit) and the three sources stay in separate rows of `totals/3`; two periods do not mix.
6. Row security as `elzoo_app` (ELZ-285: `SET ROLE` to `ELZOO_TEST_APP_ROLE` on every connection, only the README grants on the random schema; the test fails, not skips, when the variable is unset): `Elzoo.TenantIsolation.verify/3` passes for both tables; under T1 no T2 observation is visible and a direct SQL insert of a T2 row fails with SQLSTATE 42501; `DELETE` of an observation or a correction fails with 42501.
7. A caller's open transaction gives `:in_transaction` for every function before any query; a Repo whose connections default to `repeatable read` gets `:isolation` from `record/3` and `correct/3`.
8. Bounds at their edges: each 128-byte text at 0, 1, 128 and 129 bytes, `run_id`, `operation_id` and `attempt_id` at 200 and 201 bytes, invalid UTF-8, a C0 and a C1 character; `amount` −1, 0, 2^63−1 and 2^63; `max_rows` 0, 1, 1000 and 1001; exactly `max_rows` groups succeed and one more is `:read_limit`; an unknown unit or source is `:invalid`.
9. Negative controls, one at a time, each restored before the final gates: drop the unknown branch from `totals/3` so unknown counts as zero (case 3 must fail); drop the primary key on `(tenant, usage_id)` (case 2 must fail).

Run the Piece tests and the new-Piece small gate locally (durable state with concurrency, so the hosted `check-piece` does not replace the local run), the roadmap and claims checks and the diff check. The full review of the coordinator guide ("Reviewer by risk"), the exact-head hosted check and the merge queue are required.

## Limits to state

The `state/tenant-isolation` limits apply (the table owner can turn forcing off or drop the policies; a superuser or `BYPASSRLS` role ignores them). The host chooses the period and splits a usage value into observations; this Piece does not check that a split is complete. No price, cost or allowance. Totals over a time range and other period kinds are later in-place additions.
