# integration/sql

Store-only PostgreSQL translation using a consumer-owned Ecto Repo and optional prefix: atomic append CAS, immutable records/checkpoints, outbox ack and bounded retention. Migration helper only; no shipped Repo/config/Application.

## Copy and providers

Select `integration/sql` with `mix elzoo.take`; the dependency-closed copy is
owned by the consuming application, without Elzoo.Application. See
[consuming](../../../docs/consuming.md). Piece dependencies: `state/event-log`, `state/checkpoint`, `state/outbox`.
Providers: `ecto_sql`, `postgrex`, `elixir`, `otp`; exact versions,
source lists and claim-level grounding are in [piece.json](piece.json).
Cure is a build-time compiler; the compiled replay runs without Cure.Compiler.

## Boundary and limits

- Subset only: no general SQL API, CDC, SQLite, migration framework, database-per-service, replication or disk/fsync guarantee.
- Atomic append capability; torn-tail repair always rejected as torn_repair_unsupported.
- PostgreSQL transaction/locking/storage behavior is upstream; finite local tests do not establish universal durability or exactly-once effects.
- Consumers own the Repo, schema deployment, access control, fsync/synchronous_commit, backups and operational recovery.

## Evidence and operations

- `test/elzoo/durable_log_postgres_test.exs`: K1–K11 plus D11/D15/D17/D19 on a disposable PostgreSQL database: restart, late commits, backend termination, unavailable service, corruption, FK and lock ordering. Missing/unreachable URL fails closed.

- telemetry: **inherited** — Consumer Ecto Repo emits upstream events; Elzoo adds no telemetry events.
- config: **supported** — Consumer Repo module and optional SQL prefix; no global Repo/config shipped.
- control: **not_applicable** — Consumer owns Repo lifecycle; no separate Elzoo database control process.

See [ELZ-009](../../../docs/work/ELZ-009.md) for the binding result tables,
operator reconciliation paths, selected laws, provider comparisons and limits.
Proofs, finite tests, local monitored observations, upstream contracts and
consumer assumptions are distinct; no disk durability or exactly-once claim.
