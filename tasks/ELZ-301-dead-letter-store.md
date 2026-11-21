# ELZ-301 — Retained dead-letter records with an open-to-resolved lifecycle

- Phase: Wave 6 Level 1
- Dependencies: ELZ-033, ELZ-006, ELZ-010, ELZ-270, ELZ-285
- Release: V1B
- Output: new `delivery/dead-letter-store` Piece
- Change class: Piece-only
- Owned paths: `pieces/delivery/dead-letter-store/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece, `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One small durable Piece in plain Elixir, Ecto and Postgrex over a consumer-owned Ecto Repo on PostgreSQL 16 (owner Q1 A, 2026-11-21): it retains ready `delivery/dead-letter` records (ELZ-006) once per `(tenant, source, message_id)`, each open until it is resolved once as replayed or discarded, with bounded listing, counts and purge. The table is protected by `state/tenant-isolation` (ELZ-270). The concrete caller is an `integration/jobs` (ELZ-010) Relay `handle` that stores a permanent failure and returns `:done`, so a full page of failures no longer blocks later items. The Piece stores no payload (a dead-letter record has none) and dispatches nothing: the host keeps the original work under its own storage keyed by `message_id` or `work_ref`, and does the replay itself.

## Interface

- `Elzoo.DeadLetterStore.Migration.install(prefix)`, called from a consumer migration's `up/0` by the table owner, installs the `state/tenant-isolation` readers in `prefix`, creates one table in the existing schema `prefix` with `PRIMARY KEY (tenant, source, message_id)`, the record as its canonical `Elzoo.DeadLetter.encode/1` JSON, `work_ref`, `put_at_ms`, the resolution fields and an index for `(tenant, source, state, put_at_ms, message_id)`, and protects it with `Elzoo.TenantIsolation.Migration.protect/2` (`space_column: nil`). `prefix` follows the tenant-isolation identifier rule; anything else raises `ArgumentError` with one fixed message before any DDL.
- `Elzoo.DeadLetterStore.new(opts)` takes exactly `repo:` and `prefix:`, or raises the same `ArgumentError`.
- `put(store, tenant, %{source, record, work_ref, at_ms})`: `record` is validated with `Elzoo.DeadLetter.validate/1`; its `message_id` is the key. `Elzoo.DeadLetter.validate/1` bounds no text, so this Piece also refuses, as `:record`, a `message_id` over 256 bytes, a record whose canonical encoded bytes are over 16,384, and a record any of whose texts contains U+0000 (PostgreSQL text cannot hold it), so every valid key fits the primary-key index and a stored failure can always be acked. The record is stored as `text` (its canonical JSON), not `jsonb`. `work_ref` is `nil` or an opaque 1..256-byte binary. Returns `{:ok, :applied}`, `{:ok, :duplicate}` for the same key with equal canonical record bytes and `work_ref`, or `{:error, :conflict}` for others. A put of a resolved key with equal bytes is still `:duplicate` and does not reopen it.
- `resolve(store, tenant, %{source, message_id, resolution, actor_ref, at_ms})`: `resolution` is `:replayed` or `:discarded`. It sets it once. Returns `{:ok, :applied}`, `{:ok, :duplicate}` when the record is already resolved with equal fields, `{:error, :already_resolved}` when it is resolved with others, or `{:error, :unknown_record}`.
- `list(store, tenant, %{source, after, limit})` returns `{:ok, %{entries, next}}`: open records of one tenant and source, oldest first by `(put_at_ms, message_id)`, at most `limit` (1..1000) after the cursor `after` (`nil` or the opaque cursor that `next` gave; `next` is `nil` when no entry follows); each entry is `%{message_id, record, work_ref, put_at_ms}`.
- `count(store, tenant)` returns `{:ok, [%{source, open}]}` for the sources that have at least one open record, sorted by source bytes, at most 1,000 sources (else `{:error, :read_limit}`).
- `purge(store, tenant, %{before_ms, limit})` deletes up to `limit` (1..1000) resolved records with `resolved_at_ms < before_ms`, oldest `resolved_at_ms` first, and returns `{:ok, deleted_count}`; open records are never purged.

Texts (`tenant`, `source`, `actor_ref`): 1..128 bytes of valid UTF-8 without a C0 or C1 control character, compared by exact bytes. Times: integers 0..2^63−1, host-supplied, not read from a clock. Errors are fixed atoms that never echo an ID: `:invalid`, `:record` (the record fails `Elzoo.DeadLetter.validate/1` or the bounds above), `:in_transaction`, `:isolation`, `:conflict`, `:already_resolved`, `:unknown_record`, `:read_limit`, `:unavailable`. The resolution and error sets and the returned maps may gain members and keys in a later in-place version; a caller matches on the members and keys it uses.

Piece dependencies: `delivery/dead-letter` and `state/tenant-isolation`. `integration/jobs` and its closure (Oban among its providers) are used only by the tests; declare them in `piece.json` so the copied consumer can run the tests, and say in the README that the library code does not call them.

## Rules

Each function checks shape (`:invalid`, then `:record` for `put/3`), then `repo.in_transaction?()` (`:in_transaction`), both before any query, then runs one transaction through `Elzoo.TenantIsolation.transact/3`; the Piece's first query inside it reads `current_setting('transaction_isolation')` and refuses any level but `read committed` as `:isolation` (a consumer Need the Piece checks but cannot set). `put/3` inserts with `ON CONFLICT DO NOTHING` and compares bytes on a conflict. `resolve/3` updates only a row whose state is open (`UPDATE ... WHERE state = 'open'`), so of two concurrent resolves one commits and the other reads the result and is `:duplicate` or `:already_resolved`. A database failure is `{:error, :unavailable}` and says nothing about whether the write committed; a retry with the same request is safe. The README states the minimum grants for the application role (`USAGE` on `prefix`; `SELECT, INSERT, UPDATE, DELETE` on the table) and declares in `piece.json` telemetry and control `not_applicable` and the config of the store value and bounds.

## Acceptance

Tests run on the worker's disposable PostgreSQL 16 (`ELZOO_TEST_DATABASE_URL`) with a `DBConnection.ConnectionPool` Repo, not the Sandbox, in random schemas dropped afterwards.

1. An `integration/jobs` Relay (test composition only, over the Memory or Postgres Store of `state/outbox`) re-offers an item after a crash between the `put/3` and the ack (simulated by a `handle` that stores, then raises once): the record is stored once and the second offer is `:duplicate`.
2. The same key with another record or `work_ref` is `:conflict`.
3. `resolve/3` once; a repeat with equal fields is `:duplicate`; with another resolution `:already_resolved`; two concurrent resolves, held behind a row lock that another connection holds until both wait (seen in `pg_locks`), commit one.
4. `list/3` order and paging: records put in a known order come back oldest first, every open record once across pages, resolved ones absent; `count/2` matches.
5. Cross-tenant isolation as `elzoo_app` (ELZ-285: `SET ROLE` to `ELZOO_TEST_APP_ROLE` on every connection, only the README grants; the test fails, not skips, when the variable is unset): `verify/3` passes; under T1 no T2 record is listed or counted, a resolve of a T2 key is `:unknown_record`, and a direct SQL insert of a T2 row fails with SQLSTATE 42501.
6. A caller's open transaction gives `:in_transaction` for every function before any query.
7. A malformed record (for example a payload key, or a last-result triple with one member missing) is `:record`, refused through `Elzoo.DeadLetter.validate/1`.
8. `purge/3` deletes only resolved records older than the cutoff, at most `limit`, and leaves open ones.
9. An `integration/jobs` Relay over a stream whose first full page (`limit` items) fails permanently: its `handle` stores each failure and returns `:done`, so a later pass delivers the later items. Without the store (a `handle` that returns `{:skip, :permanent}`) the later items stay undelivered, the stated limit of `integration/jobs`.
10. Bounds: texts at 0, 1, 128 and 129 bytes and a C1 character; `work_ref` 0, 1, 256 and 257 bytes; `limit` 0, 1, 1000 and 1001; `message_id` at 256 and 257 bytes, an encoded record at 16,384 and 16,385 bytes, and a `message_id` and a `reason` that hold a NUL byte, each `:record`.
11. Negative control, restored before the final gates: drop the primary key (case 1 must store two rows and fail).

Run the Piece tests and the new-Piece small gate locally (durable state with concurrency), the roadmap and claims checks and the diff check. The full review of the coordinator guide ("Reviewer by risk"), the exact-head hosted check and the merge queue are required.

## Limits to state

The `state/tenant-isolation` limits apply. No payload storage, replay dispatch, alerting or retention policy beyond `purge/3`; the host chooses when to purge. Times are host-supplied.
