# delivery/dead-letter-store

Retained `delivery/dead-letter` records in one Piece-owned table under the
`state/tenant-isolation` floor, over a consumer-owned Ecto Repo on PostgreSQL 16. A record
is stored once per `(tenant, source, message_id)` and stays open until it is resolved once as
`:replayed` or `:discarded`. Open records are read through bounded pages and counts. Resolved
records are deleted later by `purge/3`. The Piece stores no payload (a dead-letter record has
none) and dispatches nothing. The host keeps the original work in its own storage, keyed by
`message_id` or `work_ref`, and does the replay itself.

The concrete caller is an `integration/jobs` Relay `handle`. It stores a permanent failure
and returns `:done`, so a full page of failures no longer blocks later items.

## Copy and providers

Select `delivery/dead-letter-store` with `mix elzoo.take`. The copy is owned by the consuming
application. See [consuming](../../../docs/consuming.md). Piece dependencies:
`delivery/dead-letter` and `state/tenant-isolation`. `integration/jobs` and its closure
(`state/outbox`, `state/event-log`, with Oban among its providers) are declared only so that
the copied consumer can run the tests. The library code does not call them. Providers:
`ecto_sql` 3.14.0 and `postgrex` 0.22.4 (the Repo, transactions and migrations), `jason`
(it encodes the canonical record bytes) and `otp` (its `:json` decoder reads them back, with
integers of any length), plus `elixir`. The tests also use `telemetry`. Exact
versions and claim-level grounding are in [piece.json](piece.json).

## Migration

Call `Elzoo.DeadLetterStore.Migration.install(prefix)` from the `up/0` of a consumer Ecto
migration, run by the table owner, in an existing schema `prefix`. It installs the
`state/tenant-isolation` readers in `prefix` and creates `prefix.elzoo_dead_letters` with
`PRIMARY KEY (tenant, source, message_id)`. The record is stored as its canonical JSON `text`,
not `jsonb`, with `work_ref` (`bytea`), `put_at_ms`, `state` and the resolution fields
`resolution`, `actor_ref` and `resolved_at_ms`. It adds the index
`(tenant, source, state, put_at_ms, message_id COLLATE "C")` and protects the table with
`Elzoo.TenantIsolation.Migration.protect/2` (`tenant_column: "tenant"`,
`space_column: nil`). The prefix follows the tenant-isolation identifier rule
`^[a-z_][a-z0-9_]{0,62}$`. Anything else raises `ArgumentError` with the fixed message
`"invalid dead letter store prefix or options"` before any DDL. A `down/0` is the consumer's.

The table owns a noncycling `bigint` identity sequence that assigns a positive `generation`
on insert. For an existing installation, run this in a consumer-owned migration as the
table owner **before serving the revised Piece** (substitute the installed schema):

```sql
ALTER TABLE <prefix>.elzoo_dead_letters
  ADD COLUMN generation bigint GENERATED ALWAYS AS IDENTITY (NO CYCLE);
```

The statement locks the table and populates every existing row, open or resolved, without
changing its other fields. Do not reinstall the table. Never reset the sequence or reuse
generation values while outstanding resolves can still reach the table, including after a
restore. Treat generation as an equality token, not a secret or count: gaps can reflect
table-wide allocations across tenants, not just committed rows.

Minimum grants for the application role, which must not own the table or bypass row
security:

```sql
GRANT USAGE ON SCHEMA <prefix> TO <app role>;
GRANT SELECT, INSERT, UPDATE, DELETE ON <prefix>.elzoo_dead_letters TO <app role>;
```

Run `Elzoo.TenantIsolation.verify(repo, {prefix, "elzoo_dead_letters"}, prefix: prefix,
tenant_column: "tenant", space_column: nil)` as that role at startup.

## Interface

`store = Elzoo.DeadLetterStore.new(repo: MyApp.Repo, prefix: "app")` takes exactly `repo:`
and `prefix:`. Anything else raises the same `ArgumentError`.

| Call | Result |
| --- | --- |
| `put(store, tenant, %{source, record, work_ref, at_ms})` | `{:ok, :applied}`; `{:ok, :duplicate}` for the same key with equal canonical record bytes and `work_ref`, whether open or resolved (a duplicate never reopens a record); `{:error, :conflict}` for the same key with others |
| `resolve(store, tenant, %{source, message_id, resolution, actor_ref, at_ms})` | `{:ok, :applied}` once; `{:ok, :duplicate}` when already resolved with equal resolution, actor and time; `{:error, :already_resolved}` with others; `{:error, :unknown_record}` |
| `list(store, tenant, %{source, after, limit})` | `{:ok, %{entries, next}}`: open records of one source, oldest first by `(put_at_ms, message_id bytes)`, at most `limit` (1..1000) after the opaque cursor `after` (`nil` or a `next`); `next` is `nil` when no entry follows. Each entry is `%{message_id, record, work_ref, put_at_ms, generation}` |
| `count(store, tenant)` | `{:ok, [%{source, open}]}` for sources with at least one open record, sorted by source bytes; `{:error, :read_limit}` over 1,000 sources |
| `purge(store, tenant, %{before_ms, limit})` | `{:ok, deleted_count}`: up to `limit` (1..1000) resolved records with `resolved_at_ms < before_ms`, oldest `resolved_at_ms` first; open records are never purged |

- `record` must pass `Elzoo.DeadLetter.validate/1`; its `message_id` is the key. Because that
  validator bounds no text, `put/3` also refuses as `:record` a `message_id` over 256 bytes,
  a record whose canonical bytes exceed 16,384 and a record any of whose texts holds U+0000
  (PostgreSQL text cannot hold it). The canonical bytes are `Elzoo.DeadLetter.encode/1` of
  the decoded record as JSON, keys in byte order, no white space.
- `work_ref` is `nil` or an opaque binary of 1..256 bytes.
- `resolve/3` accepts an optional `generation` key: supply the integer from `list/3`
  to bind both the update and the duplicate/already-resolved lookup to that insertion.
  A missing row or a generation mismatch gives `:unknown_record`. A supplied value other
  than an integer in 1..2^63−1 (including `nil`) is `:invalid` before any query.
- Texts (`tenant`, `source`, `actor_ref`) are 1..128 bytes of valid UTF-8 without a C0 or C1
  control character, compared by exact bytes. Times are integers 0..2^63−1 supplied by the
  host. The Piece reads no clock.
- Errors are fixed atoms that never echo an ID: `:invalid`, `:record`, `:in_transaction`,
  `:isolation`, `:conflict`, `:already_resolved`, `:unknown_record`, `:read_limit`,
  `:unavailable`. The resolution and error sets and the returned maps may gain members and
  keys in a later in-place version. Match on the members and keys you use.

## Rules

Each function checks shape (`:invalid`, then `:record` for `put/3`), then
`repo.in_transaction?()` (`:in_transaction`), both before any query. It then runs one
transaction through `Elzoo.TenantIsolation.transact/3` with the scope `%{tenant: tenant}`.
Its first query reads `current_setting('transaction_isolation')` and refuses any level other
than `read committed` as `:isolation`. Read committed is a consumer Need that the Piece checks
but does not set.

- `put/3` inserts with `ON CONFLICT DO NOTHING`. On a conflict it reads the row and compares
  bytes. A duplicate leaves the row's generation unchanged. A concurrent insert of the same
  key waits for that insert's commit.
- `resolve/3` updates only an open row (`UPDATE ... WHERE state = 'open'`). Of two concurrent
  resolves one commits. The other re-reads the result and is `:duplicate` or
  `:already_resolved`.
- A database or Repo failure is `{:error, :unavailable}`. It says nothing about whether the
  write committed. Until that record is purged, retrying the same `put/3` or `resolve/3`
  request is safe: a committed put or resolve returns `:duplicate` on retry. After a purge,
  a retried put stores the record again as open. A resolve retried with its original generation
  returns `:unknown_record`, even when another record now has its key. Retry an unconfirmed
  put or a resolve **without** a generation before purging that record.
- `purge/3` has no write-retry guarantee. After an unknown outcome, the same request can
  delete up to another `limit` records for that tenant resolved strictly before `before_ms`.
  It never deletes open records. The retry reports only its own deletion count; it cannot
  recover the first call's result.
- Queries run with `log: false`.

## Limits

- The `state/tenant-isolation` limits apply, including that the consumer Repo's query
  telemetry receives the tenant and every parameter (record bytes, `work_ref`, `actor_ref`).
- No payload storage, replay dispatch, alerting or retention policy beyond `purge/3`. The
  host chooses when to purge and supplies every time.
- `list/3` pages by position. A record put later with an earlier `put_at_ms` than the cursor
  is not returned by the remaining pages of that walk.
- A key purged and put again is a new open record. An unguarded resolve identifies it only by
  `(tenant, source, message_id)`: a retried unconfirmed resolve after that record was purged
  and its key put again can resolve the new record.

## Evidence

[test/elzoo/dead_letter_store_test.exs](test/elzoo/dead_letter_store_test.exs) runs on the
worker's own disposable PostgreSQL 16 database (`ELZOO_TEST_DATABASE_URL`) behind a
fail-closed target guard. It uses `DBConnection.ConnectionPool` Repos, not the Sandbox, in
random schemas dropped afterwards. The application connections `SET ROLE` to
`ELZOO_TEST_APP_ROLE` with only the grants above. The tests fail, not skip, when that variable
is unset. These are finite scenarios, not proofs. Row security, `ON CONFLICT`, row locks and
read-committed re-reads are PostgreSQL's.
