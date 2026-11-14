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

Read path: `head`, `latest_checkpoint`, `read_checkpoint`, `pending`, `read_ack` and `read_maintenance` (`:retain`) send one statement, with no transaction, when the calling process holds no connection of the Repo; the store `timeout` (default 5 s) bounds that statement. `read`, `read_at` and every read on a held connection run in one repeatable-read, read-only transaction, whose statements run under the Repo timeout.

- Subset only: no general SQL API, CDC, SQLite, migration framework, database-per-service, replication or disk/fsync guarantee.
- Atomic append capability; torn-tail repair always rejected: torn_repair_unsupported, or caller_transaction inside the caller's open Ecto transaction.
- Calls inside the caller's open Ecto transaction on the same Repo are refused before any statement: writes return {:rejected, :caller_transaction}, reads {:error, :caller_transaction} (ELZ-032 bug fix, same ID). Transactions opened outside Ecto on the same connection are not detected.
- The caller-transaction check is per process: Repo.in_transaction?/0 sees only the calling process's checked-out connection.
- Under Ecto.Adapters.SQL.Sandbox, outside an explicit Repo.transaction, in_transaction? is false: the Store's transaction becomes a savepoint, a write can return {:committed, n} after only RELEASE SAVEPOINT and the sandbox rollback erases it, so the refusal does not apply there (inside an explicit Repo.transaction it still refuses). Consumer test suites using the Sandbox must not treat committed as a real COMMIT.
- A raw BEGIN inside Repo.checkout/2 is not detected; writes then return indeterminate(:unavailable) and reads :unavailable, and DBConnection disconnects that connection, so the caller's raw transaction is aborted (read from the DBConnection source, not tested).
- The direct read is taken only when Repo.checked_out?/0 is false: it sees a connection held through Repo.checkout/2, Repo.transaction/2 or Repo.transact/2, not a connection owned through an ownership pool (Ecto.Adapters.SQL.Sandbox, DBConnection.Ownership); under such a pool a one-statement read can run on the caller's owned connection, also inside a raw BEGIN on it (read from the Ecto SQL source, not tested). No detection is built for it.
- Calls from another process, including every Writer call, are never refused; they commit on their own connection independently of the caller's transaction, so there is no transaction-scoped atomicity.
- Static, I/O-free validation runs before the caller-transaction check, so invalid input inside a caller transaction keeps its existing result (a write's rejection or indeterminate(:malformed_reply), {:error, :malformed} from a read with an I/O-free pre-check such as read_ack key parsing or an unknown read_maintenance operation; reads that validate input during the query, such as head/read with an invalid stream, return {:error, :caller_transaction} instead); no SQL is issued in either case.
- PostgreSQL transaction/locking/storage behavior is upstream; finite local tests do not establish universal durability or exactly-once effects.
- Consumers own the Repo, schema deployment, access control, fsync/synchronous_commit, backups and operational recovery.

## Evidence and operations

- `test/elzoo/durable_log_postgres_test.exs`: K1–K11 plus D11/D15/D17/D19 on a disposable PostgreSQL database: restart, late commits, backend termination, unavailable service, corruption, FK and lock ordering; ELZ-032 caller-transaction refusal for every write callback and every read callback except the static capabilities, with outer COMMIT and ROLLBACK, the outer transaction still usable, and the shell results through Outbox/Checkpoint/confirm. Missing/unreachable URL fails closed. ELZ-193 groups: one_statement_reads_are_one_query, multi_statement_reads_keep_one_snapshot, refusals_are_unchanged, held_connection_keeps_the_wrapper.

- telemetry: **inherited** — Consumer Ecto Repo emits upstream events; Elzoo adds no telemetry events.
- config: **supported** — Consumer Repo module and optional SQL prefix; no global Repo/config shipped.
- control: **not_applicable** — Consumer owns Repo lifecycle; no separate Elzoo database control process.

See [ELZ-009](../../../docs/work/ELZ-009.md) for the binding result tables,
operator reconciliation paths, selected laws, provider comparisons and limits.
Proofs, finite tests, local monitored observations, upstream contracts and
consumer assumptions are distinct; no disk durability or exactly-once claim.
