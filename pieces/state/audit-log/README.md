# state/audit-log

Attributable audit log for records appended through the ready `integration/sql` Store. Each
committed change of `elzoo_log_records` made through a binding gets one audit transaction
(actor, action, reason, transaction identity, timestamp) and one change row (operation, record
identity, non-excluded columns), written by Carbonite 0.17.0 triggers **inside the Store's own
transaction**: the audit row and the mutation commit or roll back together. The first audited
mutation is the ELZ-023 effect-intent decision record.

This is a new wrapper Piece. It does not change `integration/sql`, `state/event-log` or
`delivery/effect-intent`: their inputs, Needs, replies and transaction contract are unchanged.
The refusal of unattributed writes is **this** Piece's Contract and holds only where its
migration is installed; a consumer that does not install it sees those Pieces behave exactly as
before (opt-in).

## Copy and providers

Select `state/audit-log` with `mix elzoo.take`; the dependency-closed copy is owned by the
consuming application, without Elzoo.Application. See
[consuming](../../../docs/consuming.md). Piece dependencies: `integration/sql` (the Store it
wraps) and `delivery/effect-intent` (the first audited caller, exercised by the tests).
Providers: `carbonite` 0.17.0 (Apache-2.0), `ecto_sql`, `postgrex`, `jason`, `elixir`, `otp`;
exact versions, source lists and claim-level grounding are in [piece.json](piece.json).
No Cure source; nothing here needs the Cure compiler.

## Interface

- `Elzoo.AuditLog.bind(store, %{actor:, action:, reason:})` — `store` must be an
  `Elzoo.DurableLog.Postgres` Store whose Repo is running with `DBConnection.ConnectionPool`.
  Returns `{:ok, bound_store}` or a typed refusal before any database I/O:
  `{:error, {:attribution, :shape | :actor | :action | :reason}}`,
  `{:error, {:store, :unsupported}}`, `{:error, {:store, :unsupported_pool}}`. The bound
  Store is used wherever the Store was (for example an effect-intent owner's `store` and its
  `StoreHost` store) and returns exactly the inner Store's replies.
- **Session attribution.** The attribution is fixed for the binding's lifetime. `actor` is an
  opaque reference and `action` the session's initiating business action (for example
  `refund.request`), not the action of each later command: every audited change made through
  the binding, including a settlement the effect-intent owner appends after an asynchronous
  provider result, carries it. `actor` and `action`: 1..256 bytes of UTF-8 without control
  characters; `reason`: 0..1024 bytes of the same shape. Per-command attribution would need
  new IDs of the ready Pieces and is not offered.
- `Elzoo.AuditLog.Migration.up(store_prefix:, carbonite_prefix:, excluded_columns:)` inside a
  consumer-owned Ecto migration, run by the audit owner role, without a migrator `prefix:` or
  with `prefix:` equal to `carbonite_prefix`. `Elzoo.AuditLog.Migration.secure(carbonite_prefix)`
  must run after any later Carbonite migration (Carbonite recreates `capture_changes()` and that
  resets `SECURITY DEFINER` and the fixed `search_path`). `down/1` retains the audit schema,
  because it can contain the Ecto migrator's own `schema_migrations` table; drop it yourself if
  wanted.
- `Elzoo.AuditLog.verify(repo, store_prefix, carbonite_prefix)` — call at startup: `:ok`, or
  `{:error, :not_installed | :trigger_disabled | :not_secured | :unavailable}`. `bind/2` does
  no I/O, so a binding over a schema without the migration records nothing; `verify/3` is how
  the consumer finds out.
- `Elzoo.AuditLog.read(repo, carbonite_prefix, stream:, limit:, after:)` — audit transactions
  with their changes as plain maps. `repo` must connect as the audit owner or as an audit
  reader role (`USAGE` on the audit schema, `SELECT` on `transactions` and `changes`); the
  application role gets `{:error, :insufficient_privilege}` by design. The same holds for
  `Retention.expired/5`.
- `Elzoo.AuditLog.Retention` — rule `%{keep_days: 1..36_500, effective_from: Date}`. From the
  UTC date `effective_from` on, a transaction inserted more than `keep_days` days before `now`
  is past the rule; before that date nothing is. `expired?/3` is the pure decision; `expired/5`
  is a caller-invoked query that **selects** transaction IDs. No deletion, job, Oban worker or
  scheduler; deletion is the consumer's, under the audit owner role.

## How the attribution reaches the Store's transaction

The ready Store refuses calls inside a caller transaction and opens its own. The bound Store pins
one connection with `repo.checkout/2` (inside it `in_transaction?/0` is false, so the Store's own
transaction runs on that pinned connection), sets the session setting `elzoo_audit.attribution` to
the attribution plus what it covers — the stream and the exact record digests for an append, the
stream and `through` for a retention — calls the inner Store and resets the setting. A
`BEFORE` trigger on `elzoo_log_records` refuses any INSERT or DELETE the setting does not cover,
any UPDATE (records are insert-only) and any write while Carbonite's `override_mode` is set, and
inserts the Carbonite transaction row; Carbonite's `AFTER` constraint trigger captures the change
and itself refuses a change without that row. A database refusal surfaces as the inner Store's
existing `indeterminate(:unavailable)`, never as a recorded anonymous mutation; an effect-intent
owner then stays read-only.

## Needs (unverified assumptions, owned by the consumer)

- The host supplies a truthful actor reference; Elzoo validates its shape only, until
  `domain/principal` exists. The attribution is not authenticated: any code that holds the
  application role's Store-table privileges can set the session setting itself and record any
  actor (or bind with any actor). The audit log records what the trusted host stated, not a
  verified identity; keep untrusted code away from the application role.
- **Production pool: `DBConnection.ConnectionPool`.** When a process dies holding a checked-out
  connection, that pool disconnects it, so a set attribution never reaches another checkout.
  Together with the operation/stream/digest binding this closes a stale setting for that pool.
  Other pools (`Ecto.Adapters.SQL.Sandbox`, `DBConnection.Ownership`) and dynamic repos are not
  supported; `bind/2` refuses a Repo whose pool is not `DBConnection.ConnectionPool`.
- A **dedicated non-superuser audit owner role** owns the audit schema, its tables and both
  `SECURITY DEFINER` trigger functions (`search_path = pg_catalog, pg_temp`). Do not own them
  with a superuser.
- The **application role** gets `USAGE` on the Store schema and only the Store-table privileges
  the Store needs (`SELECT, INSERT, UPDATE, DELETE`), **no** `TRUNCATE`, no ownership of the
  Store tables and **no privilege on the audit schema** (the migration revokes PUBLIC's).
  Capture then works through the definer functions while direct audit-table writes are refused.
- Audit readers (`read/3`, `Retention.expired/5`) use the audit owner or a separate reader role
  granted `USAGE` on the audit schema and `SELECT` on `transactions` and `changes`.
- `inserted_at` is the database host's clock at transaction start, stored as UTC.

## Boundary and limits

- Audited surface: `elzoo_log_records` INSERT (append) and DELETE (Store retention).
  Checkpoints, heads and outbox state are outside it; denied actions and no-mutation decisions
  are not captured (no mutation, no row; a separate path).
- Exclusions (default `payload`, `nonce`) are removed from every change row; `stream` and
  `sequence` identify the record and cannot be excluded; the kept `digest` binds the audit row to
  the exact record without disclosing it. Changing exclusions is a new migration.
- **TRUNCATE** is not captured (row triggers only): a role holding TRUNCATE on the Store tables
  removes records without an audit row. **Privileged bypass**: the table owner can disable the
  triggers, a superuser can set `session_replication_role = replica`, and the audit owner can
  edit audit rows. These are disclosed limits shown by tests, not detected.
- No universal tamper-proof, completeness or non-repudiation claim; no telemetry or metering.
- Carbonite's `insert_transaction/3`, outbox and purge APIs are not used; Carbonite's outbox is
  not a second `state/outbox`.

## Evidence and operations

- `test/elzoo/audit_log_test.exs`: attribution shape and typed refusal at `bind/2` without I/O,
  unsupported Store and pool, migration option validation, dated retention boundaries.
- `test/elzoo/audit_log_postgres_test.exs` (own disposable PostgreSQL database, fail-closed
  target guard): commit pairs record and audit row; CAS conflict and an injected failure inside
  the Store transaction leave neither; unbound, other-stream, other-record, malformed and
  `override_mode` writes and UPDATE refused; configured exclusions; 16 concurrent bindings
  attributed to their own actor; six concurrently held connections carry no setting after bound
  writes; a holder killed between write and reset on the commit and the rollback path (new
  backend, empty setting, the dead holder's own record not insertable unbound); retention DELETE
  audited and a narrower setting refused; retention query; TRUNCATE and disabled-trigger limits
  (and `session_replication_role` where the role is superuser); without the migration nothing is
  installed and the Store behaves as before; both definer functions with the exact `search_path`
  owned by the named non-superuser audit owner after the initial migration, after a Carbonite
  re-migration plus `secure/1`, and after down/up; the application-role boundary (no audit-schema
  privilege; captured append works; direct audit DML, TRUNCATE, trigger configuration, disable
  and schema creation refused) where the connected role may create roles.
- `test/elzoo/audit_log_effect_intent_test.exs`: the real `Elzoo.EffectIntent` owner and
  `StoreHost` over bound Stores — each decision record is exactly one insert change in its own
  audit transaction with the requester's attribution, host markers carry the operator's,
  checkpoints are written and not audited; an owner over the audited schema without a binding
  stays read-only and nothing is recorded.

- telemetry: **not_applicable** — audit rows are durable accountability records, not observations; no events are emitted.
- config: **supported** — `carbonite_prefix` and `excluded_columns` at migration time; attribution per binding; retention rule per call; no hot reconfiguration.
- control: **not_applicable** — no process or lifecycle is shipped; the consumer owns the Repo, migrations and any deletion.

See [ELZ-055](../../../docs/work/ELZ-055.md) for the provider comparison (Carbonite adopted;
`ash_paper_trail` 0.8.1 exercised and not fit for this caller), the probes and the Contract
amendment. Proofs: none. Tests, upstream contracts and Needs are distinct; finite tests over the
listed scenarios do not establish universal behavior.
