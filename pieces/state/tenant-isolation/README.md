# state/tenant-isolation

A database-enforced tenant floor under consumer tables in PostgreSQL 16. A query that forgets
its tenant filter returns no other tenant's row, and a write of another tenant's row fails with
SQLSTATE 42501. It is one Adapter over a consumer-owned Ecto Repo with three parts: a migration
helper that installs two setting readers and protects a table, a transaction helper that sets
the tenant and the space list, and a startup check.

Hierarchy is the host's: it resolves which spaces a caller may see (for example with
`domain/membership`) and passes the exact list of space IDs. The database sees only that list:
no recursive SQL, no hierarchy and no membership lookup in a policy.

## Copy and providers

Select `state/tenant-isolation` with `mix elzoo.take`; the copy is owned by the consuming
application. See [consuming](../../../docs/consuming.md). No Piece dependencies and no Cure
source. Providers: `ecto_sql` 3.14.0 and `postgrex` 0.22.4 (the Repo, transactions and
migrations), `elixir`; the tests also use `jason` (Postgrex decodes JSON `EXPLAIN`) and
`telemetry`. Exact versions and claim-level grounding are in [piece.json](piece.json).

## Migration

Call these from the `up/0` of a consumer Ecto migration, run by the table owner. Nothing here is
reversible by the Piece; a `down/0` is the consumer's.

- `Elzoo.TenantIsolation.Migration.install(prefix)` creates `prefix.elzoo_tenant_id()`
  (`NULLIF(current_setting('elzoo.tenant_id', true), '')`, a `text`) and
  `prefix.elzoo_space_ids()` (`COALESCE(NULLIF(current_setting('elzoo.space_ids', true),
  '')::text[], '{}')`), both `LANGUAGE sql STABLE`.
- `Elzoo.TenantIsolation.Migration.protect(table, prefix:, tenant_column:, space_column:)`
  enables and forces row-level security on `table` (`"name"`, resolved by the migration's
  `search_path`, or `{schema, name}`) and creates two policies:
  - `elzoo_tenant_floor`, `AS RESTRICTIVE FOR ALL TO PUBLIC`, with USING and WITH CHECK equal
    to `tenant_column = (SELECT prefix.elzoo_tenant_id())` and, when `space_column` is set,
    `AND space_column = ANY ((SELECT prefix.elzoo_space_ids())::text[])`;
  - `elzoo_tenant_allow`, permissive, `USING (true) WITH CHECK (true)`. Replace it with
    narrower permissive policies if you want; with no permissive policy at all nothing is
    visible or writable.

  Use `space_column: nil` for a flat table. A restrictive policy is ANDed with every permissive
  one, so no later permissive policy widens the floor.

Every identifier (`prefix`, both columns, the table and its schema) must match
`^[a-z_][a-z0-9_]{0,62}$` and is quoted. Anything else, and options other than exactly those
three keys, raise `ArgumentError` with the fixed message
`"invalid tenant isolation identifier or options"` before any DDL is queued.

Declare the space column `NOT NULL`: a `NULL` space is neither visible nor writable.

## Transactions

```elixir
Elzoo.TenantIsolation.transact(MyApp.Repo, %{tenant: "t1", spaces: ["s1", "s2"]}, fn ->
  {:ok, MyApp.Repo.all(Document)}
end)
```

`scope` is exactly `%{tenant: t}` (a flat scope: the space list is empty, so a spaced table
shows nothing) or `%{tenant: t, spaces: list}`. `tenant` and each space ID are 1..128 bytes of
valid UTF-8 without a C0 or C1 control character (U+0000–U+001F, U+007F–U+009F), the text rule
of `domain/principal`. `spaces` is a proper list of 0..1024 IDs; duplicates are harmless. IDs
match by exact bytes, including IDs such as `NULL`, `{a}`, `"q"`, `b\s` and `,`.

The order of the checks:

1. scope shape and `fun` of arity 0, else `{:error, {:tenant_isolation, :scope}}`;
2. options: omit them, pass `[]`, or pass exactly `[timeout: ms]` with an integer from 1 to
   600,000 inclusive; otherwise `{:error, {:tenant_isolation, :timeout}}`;
3. an open transaction returns `{:error, {:tenant_isolation, :in_transaction}}`: a
   transaction-local setting would outlive the call inside an outer transaction;
4. only with an explicit timeout, an existing `Repo.checkout/2` returns
   `{:error, {:tenant_isolation, :in_checkout}}` before SQL or the callback, because the
   transaction would inherit the checkout's deadline;
5. inside `repo.transact/2` the helper sets both settings with `set_config(..., true)` and
   bind parameters (the space list as a `text[]` parameter, `log: false`), runs `fun`, and when
   `fun` returns `{:ok, value}` sets both settings to `''` before the commit (`log: false`).

`transact(repo, scope, fun, timeout: ms)` passes the timeout to the outer transaction only.
If the deadline prevents begin, scope setup or clearing, or commit, the call returns
`{:error, :unavailable}`, including expiry after clearing and before commit. The callback's
errors, raised exceptions and explicit rollbacks pass through unchanged even after expiry;
this includes driver errors from its own queries. An unavailable result is
not a guarantee of rollback or permission to retry a write. The timeout does not stop Elixir
callback code or configure PostgreSQL `statement_timeout` or `lock_timeout`. Omitting options
or passing `[]` keeps the Repo default and does not translate connection exceptions.

Otherwise the result is `repo.transact/2`'s: `{:ok, value}`, `{:error, reason}`, a
`repo.rollback/1` value, or a raise. One exception: when `fun` caught a failed statement and
still returns `{:ok, value}`, the clearing query fails in the aborted transaction and the call
raises; the transaction is rolled back either way.

When `fun` swallowed a failed nested `repo.transact` and still returns `{:ok, value}`, the call
returns `{:error, :rollback}`, as `transact/2` does. DBConnection 2.10.2 refuses the clearing
query on such an aborted transaction by disconnecting that connection (it logs an error and the
pool reconnects); the helper then rolls back with `repo.rollback(:rollback)`. Under Sandbox the
disconnect also ends the sandbox's own transaction, so the test's earlier writes are gone; the
reconnected connection starts a new sandbox transaction.

Why the clearing: under `Ecto.Adapters.SQL.Sandbox` the helper's transaction is a savepoint,
and a transaction-local setting survives `RELEASE SAVEPOINT` into the outer transaction.

Only statements that `fun` runs through `repo` on the transaction's connection see the scope. A
statement from another process sees none unless it shares that connection (Sandbox shared mode
or an allowance).

Without the helper both readers are `NULL` and `'{}'`, so a protected table shows no row and
refuses every write: fail closed.

## Startup check

`Elzoo.TenantIsolation.verify(repo, table, prefix:, tenant_column:, space_column:)` takes the
same arguments and identifier rule as `protect/2` (else the same `ArgumentError`) and returns
`:ok` or the first of:

| Reason | Meaning |
| --- | --- |
| `:unavailable` | a query failed (for example an unreachable Repo) |
| `:bypass_role` | `current_user` is a superuser or has `BYPASSRLS` |
| `:not_enabled` | row-level security is disabled on the table, or no such table exists |
| `:not_forced` | row-level security is not forced |
| `:floor_missing` | no policy `elzoo_tenant_floor` that is restrictive, `FOR ALL` and `TO PUBLIC` |
| `:floor_changed` | the floor's server deparse of USING or WITH CHECK differs from what `protect/2` creates for these arguments |

`:floor_changed` compares `pg_get_expr` of the table's floor with the same policy rebuilt on a
temporary table whose columns copy the protected columns' types (`format_type`), in one
transaction under one `search_path`; the rebuild runs in a savepoint that is always rolled
back, so `verify/3` also works inside a caller's transaction, except that an `:unavailable`
result there marks the caller's transaction for rollback. A column or readers schema that
does not exist gives `:floor_changed`. The rebuild needs the `TEMP` privilege, which PUBLIC has
by default. `Elzoo.TenantIsolation.decide/1` is the pure decision over the read facts.

Run `verify/3` connected as the application role, for each protected table, before serving.
That role needs `USAGE` on the `prefix` schema (the readers keep PostgreSQL's default `EXECUTE`
for PUBLIC); without it every query of a protected table fails with 42501 and `verify/3` gives
`:unavailable`.

## Limits

- A floor against a forgotten filter, not against code that runs its own SQL: any code holding
  the connection can call `set_config` and pick a tenant.
- The table owner can `NO FORCE`, `DISABLE` or drop policies, and a superuser or `BYPASSRLS`
  role ignores them. Production should connect as a non-owner, non-bypass application role.
  The tests exercise that boundary with the ELZ-285 application role (`ELZOO_TEST_APP_ROLE`).
- `verify/3` checks the table and its floor, not the bodies of the two readers: the owner of
  the `prefix` schema can replace them.
- Policies of a partitioned table do not apply when a partition is queried directly: protect
  each partition the application can name.
- Revocation applies at the next call: a running call keeps the list it started with.
- No per-command read/write split: the floor is one `FOR ALL` policy.
- Ready Store tables (`elzoo_log_records` and the others) are not protected by this Piece.
- The Piece emits no telemetry and no log, and its errors never echo a tenant or space ID. But
  `log: false` only silences the Logger: the consumer Repo's `[..., :query]` telemetry event
  still fires for the set and clear queries, and its metadata `params` holds the tenant and the
  space list. A telemetry handler that records params records them.

## Evidence

[test/elzoo/tenant_isolation_test.exs](test/elzoo/tenant_isolation_test.exs) runs on the
worker's own disposable PostgreSQL 16 database (`ELZOO_TEST_DATABASE_URL`) behind a fail-closed
target guard, in random schemas dropped afterwards, connected as the owner with `FORCE`, as a
role that must not bypass row security. Finite scenarios, not proofs; row-level security,
`set_config` and savepoint semantics are PostgreSQL's.
