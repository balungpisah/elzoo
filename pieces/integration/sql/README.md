# integration/sql

Store-only PostgreSQL translation using a consumer-owned Ecto Repo and optional prefix: atomic append CAS, immutable records/checkpoints, outbox ack and bounded retention, which also removes the stream's checkpoints below its new low-water. Migration helper only; no shipped Repo/config/Application.

## Copy and providers

Select `integration/sql` with `mix elzoo.take`; the dependency-closed copy is
owned by the consuming application, without Elzoo.Application. See
[consuming](../../../docs/consuming.md). Piece dependencies: `state/event-log`, `state/checkpoint`, `state/outbox`.
Providers: `ecto_sql`, `postgrex`, `elixir`, `otp`; exact versions,
source lists and claim-level grounding are in [piece.json](piece.json).
Cure is a build-time compiler; the compiled replay runs without Cure.Compiler.

## Boundary and limits

Read path: `head`, `latest_checkpoint`, `read_checkpoint`, `pending`, `read_ack` and `read_maintenance` (`:retain`) send one statement, with no transaction, when the calling process holds no connection of the Repo; the store `timeout` (default 5 s) bounds that statement. `read`, `read_at` and every read on a held connection run in one repeatable-read, read-only Store transaction. The Store `timeout` (default 5 s) is passed to `Repo.transaction/2`; its SQL statements use the Repo timeout. For `read` and `read_at`, that transaction captures the head and raw rows; row mapping and digest validation happen after it returns, without another query. The Store transaction timeout does not bound later validation or the end-to-end read.

- Subset only: no general SQL API, CDC, SQLite, migration framework, database-per-service, replication or disk/fsync guarantee.
- Atomic append capability; torn-tail repair always rejected: torn_repair_unsupported, or caller_transaction inside the caller's open Ecto transaction.
- Calls inside the caller's open Ecto transaction on the same Repo are refused before any statement: writes return {:rejected, :caller_transaction}, reads {:error, :caller_transaction} (ELZ-032 bug fix, same ID). Transactions opened outside Ecto on the same connection are not detected.
- The caller-transaction check is per process: Repo.in_transaction?/0 sees only the calling process's checked-out connection.
- A Store-owned checkout is released when the snapshot transaction returns, before `read`/`read_at` validate rows. When the caller owns a `Repo.checkout/2`, the Store transaction ends but the caller-owned checkout remains checked out until the caller returns it.
- Under Ecto.Adapters.SQL.Sandbox, outside an explicit Repo.transaction, in_transaction? is false: the Store's transaction becomes a savepoint, a write can return {:committed, n} after only RELEASE SAVEPOINT and the sandbox rollback erases it, so the refusal does not apply there (inside an explicit Repo.transaction it still refuses). Consumer test suites using the Sandbox must not treat committed as a real COMMIT.
- A raw BEGIN inside Repo.checkout/2 is not detected; writes then return indeterminate(:unavailable) and reads :unavailable, and DBConnection disconnects that connection, so the caller's raw transaction is aborted (read from the DBConnection source, not tested).
- The direct read is taken only when Repo.checked_out?/0 is false: it sees a connection held through Repo.checkout/2, Repo.transaction/2 or Repo.transact/2, not a connection owned through an ownership pool (Ecto.Adapters.SQL.Sandbox, DBConnection.Ownership); under such a pool a one-statement read can run on the caller's owned connection, also inside a raw BEGIN on it (read from the Ecto SQL source, not tested). No detection is built for it.
- Calls from another process, including every Writer call, are never refused; they commit on their own connection independently of the caller's transaction, so there is no transaction-scoped atomicity.
- Static, I/O-free validation runs before the caller-transaction check, so invalid input inside a caller transaction keeps its existing result (a write's rejection or indeterminate(:malformed_reply), {:error, :malformed} from a read with an I/O-free pre-check such as read_ack key parsing or an unknown read_maintenance operation; reads that validate input during the query, such as head/read with an invalid stream, return {:error, :caller_transaction} instead); no SQL is issued in either case.
- PostgreSQL transaction/locking/storage behavior is upstream; finite local tests do not establish universal durability or exactly-once effects.
- Consumers own the Repo, schema deployment, access control, fsync/synchronous_commit, backups and operational recovery.
- Retention deletes the checkpoints it leaves unusable (ELZ-427, same ID): a committed retain deletes, in the same transaction as its record and acked-outbox deletes, every elzoo_checkpoints row of the stream with a sequence below through, of every fold version; rows at or above through and of other streams stay, and a refused, conflicting or rolled-back retain, including an exact retry of a committed one, deletes none. put_checkpoint below the locked head's low_water returns {:rejected, :checkpoint_below_low_water} and inserts nothing. A deleted checkpoint reads {:ok, :absent} and latest_checkpoint no longer returns it; confirm_checkpoint/2 then returns {:unknown, :unfenced}, which does not prove that the put failed, so a checkpoint receipt needed for Writer reconciliation must be resolved before retaining past its anchor. Checkpoints that a retention before this change left below low_water stay until the stream's next committed retain.
- The role that calls retain needs DELETE on elzoo_checkpoints (ELZ-427); without it a retain returns indeterminate(:unavailable) and commits nothing (read from the code path, not tested).
- A put_checkpoint below through that races a retain either commits first and is then deleted by it, or waits for the head-row lock and is refused after it. This assumes the Store's own transactions run at PostgreSQL's default READ COMMITTED isolation, where each statement after the lock wait sees the other transaction's commit; a server or role default of REPEATABLE READ or SERIALIZABLE is outside this guarantee.

## Evidence and operations

- `test/elzoo/durable_log_postgres_test.exs`: K1–K11 plus D11/D15/D17/D19 on a disposable PostgreSQL database: restart, late commits, backend termination, unavailable service, corruption, FK and lock ordering; ELZ-032 caller-transaction refusal for every write callback and every read callback except the static capabilities, with outer COMMIT and ROLLBACK, the outer transaction still usable, and the shell results through Outbox/Checkpoint/confirm. Missing/unreachable URL fails closed. ELZ-193 groups: one_statement_reads_are_one_query, multi_statement_reads_keep_one_snapshot, refusals_are_unchanged, held_connection_keeps_the_wrapper. ELZ-262 groups: validation after transaction with Store/caller checkout state, captured rows retained across append and retention, empty/absent/pruned results, invalid-row maps, and normalized mapping exceptions without partial results. ELZ-427 tests: committed retention deletes the stream's checkpoints below through and keeps the rest; a retention rolled back after its deletes keeps every checkpoint; an exact retry keeps its conflict, deletes nothing more and its receipt confirms; refused or conflicting retention deletes none; a put below low-water is refused through Store.write; a put racing retention commits first and is deleted, or is refused after it, with the head-lock order recorded.

- telemetry: **inherited** — Consumer Ecto Repo emits upstream events; Elzoo adds no telemetry events.
- config: **supported** — Consumer Repo module and optional SQL prefix; no global Repo/config shipped.
- control: **not_applicable** — Consumer owns Repo lifecycle; no separate Elzoo database control process.

See [ELZ-009](../../../docs/work/ELZ-009.md) for the binding result tables,
operator reconciliation paths, selected laws, provider comparisons and limits.
Proofs, finite tests, local monitored observations, upstream contracts and
consumer assumptions are distinct; no disk durability or exactly-once claim.

## Changes

- ELZ-427 (2026-11-26): a committed retain now also deletes, in its
  transaction, the stream's rows of `elzoo_checkpoints` with a sequence below
  `through`, of every fold version; before, every checkpoint was kept.
  `put_checkpoint` below the locked head's `low_water` now returns
  `{:rejected, :checkpoint_below_low_water}` and inserts nothing; before, it
  committed, or conflicted on an existing key. `read_checkpoint` of a deleted
  checkpoint returns `{:ok, :absent}`, `latest_checkpoint` no longer returns
  it, and `confirm_checkpoint/2` returns `{:unknown, :unfenced}`, which does
  not prove that the put failed. The stored format is unchanged. How to move:
  grant DELETE on `<prefix>.elzoo_checkpoints` to the role that calls `retain`
  (without it a retain returns `indeterminate(:unavailable)` and commits
  nothing); resolve any checkpoint receipt that Writer reconciliation still
  needs before retaining past its anchor; keep the Store's transactions at
  PostgreSQL's default READ COMMITTED isolation. Checkpoints that earlier
  retentions left below `low_water` go at the stream's next committed retain;
  to remove them at once, run
  `DELETE FROM <prefix>.elzoo_checkpoints c USING <prefix>.elzoo_log_heads h WHERE c.stream = h.stream AND c.sequence < h.low_water`.
