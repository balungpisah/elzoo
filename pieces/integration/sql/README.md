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
- Atomic append capability; torn-tail repair always rejected: torn_repair_unsupported, or caller_transaction inside the caller's open Ecto transaction.
- Calls inside the caller's open Ecto transaction on the same Repo are refused before any statement: writes return {:rejected, :caller_transaction}, reads {:error, :caller_transaction} (ELZ-032 bug fix, same ID). Transactions opened outside Ecto on the same connection are not detected.
- The caller-transaction check is per process: Repo.in_transaction?/0 sees only the calling process's checked-out connection.
- Under Ecto.Adapters.SQL.Sandbox in_transaction? is false: the Store's transaction becomes a savepoint, a write can return {:committed, n} after only RELEASE SAVEPOINT and the sandbox rollback erases it, so the refusal does not apply. Consumer test suites using the Sandbox must not treat committed as a real COMMIT.
- A raw BEGIN inside Repo.checkout/2 is not detected; writes then return indeterminate(:unavailable) and reads :unavailable.
- Calls from another process, including every Writer call, are never refused; they commit on their own connection independently of the caller's transaction, so there is no transaction-scoped atomicity.
- Static, I/O-free validation runs before the caller-transaction check, so invalid input inside a caller transaction keeps its existing rejection or indeterminate(:malformed_reply) result; no SQL is issued in either case.
- PostgreSQL transaction/locking/storage behavior is upstream; finite local tests do not establish universal durability or exactly-once effects.
- Consumers own the Repo, schema deployment, access control, fsync/synchronous_commit, backups and operational recovery.

## Evidence and operations

- `test/elzoo/durable_log_postgres_test.exs`: K1–K11 plus D11/D15/D17/D19 on a disposable PostgreSQL database: restart, late commits, backend termination, unavailable service, corruption, FK and lock ordering; ELZ-032 caller-transaction refusal for every write callback and every read callback except the static capabilities, with outer COMMIT and ROLLBACK, the outer transaction still usable, and the shell results through Outbox/Checkpoint/confirm. Missing/unreachable URL fails closed.

- telemetry: **inherited** — Consumer Ecto Repo emits upstream events; Elzoo adds no telemetry events.
- config: **supported** — Consumer Repo module and optional SQL prefix; no global Repo/config shipped.
- control: **not_applicable** — Consumer owns Repo lifecycle; no separate Elzoo database control process.

See [ELZ-009](../../../docs/work/ELZ-009.md) for the binding result tables,
operator reconciliation paths, selected laws, provider comparisons and limits.
Proofs, finite tests, local monitored observations, upstream contracts and
consumer assumptions are distinct; no disk durability or exactly-once claim.
