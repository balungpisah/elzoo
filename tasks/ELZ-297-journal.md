# ELZ-297 — Balanced money journal whose no-negative accounts are wallets

- Phase: Wave 6 Level 1
- Dependencies: ELZ-033, ELZ-031, ELZ-270, ELZ-285
- Release: V2
- Output: new `domain/journal` Piece (from RC-22; it absorbs the `domain/wallet` handle: a wallet is a journal account that may not go negative)
- Change class: Piece-only
- Owned paths: `pieces/domain/journal/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece, `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One durable Piece in plain Elixir, Ecto and Postgrex over a consumer-owned Ecto Repo on PostgreSQL 16: accounts with stored balances, operations that post 2..64 same-currency postings with a zero sum all or nothing under one operation identity, immutable linked reversals, and an account flag that forbids a negative balance. Amounts are `domain/money` (ELZ-031) values. The tables are protected by `state/tenant-isolation` (ELZ-270). `ash_double_entry` is not adopted (no Ash in core, owner 2026-11-20). Cure where a pure decision fits (for example the zero-sum and no-negative decisions); any Cure law is a named selected law. No new provider, pin or root change.

Account identity is not principal identity: `account_id` and `actor_ref` are opaque host labels. No Float, exchange rate, payment, invoice or settlement claim: a balanced journal does not prove external settlement. The journal tables are Piece-owned and are not captured by `state/audit-log`.

## Interface

- `Elzoo.Journal.Migration.install(prefix)`, called from a consumer migration's `up/0` by the table owner, installs the `state/tenant-isolation` readers in `prefix` (`Elzoo.TenantIsolation.Migration.install/1` uses `CREATE OR REPLACE`), creates the tables below in the existing schema `prefix`, and protects each with `Elzoo.TenantIsolation.Migration.protect/2` (`space_column: nil`). Tables: accounts `{tenant, account_id, currency identity, allow_negative, balance, version}` with `PRIMARY KEY (tenant, account_id)`; operations `{tenant, operation_id, actor_ref, reason, reverses, request digest}` with `UNIQUE (tenant, operation_id)` and `UNIQUE (tenant, reverses)`; postings `{tenant, operation_id, account_id, minor units, account version}` with `PRIMARY KEY (tenant, account_id, version)`; no sequence. Minor units and balances are `numeric(38,0)`, which holds every `domain/money` amount (`abs < 10^38`). `prefix` follows the tenant-isolation identifier rule; anything else raises `ArgumentError` with one fixed message before any DDL. Nothing is reversible by the Piece.
- `Elzoo.Journal.new(opts)` takes exactly `repo:`, `prefix:` and optionally `registry:` (an `Elzoo.Money.Registry` value; default `Elzoo.Money.Registry.default/0`) and returns a journal value, or raises the same fixed `ArgumentError`.
- `open_account(journal, tenant, %{account_id, currency, allow_negative})`: `currency` is an `%Elzoo.Money.Currency{}` member of the registry with an integer minor unit. Returns `{:ok, :applied}`, `{:ok, :duplicate}` for the same `account_id` with equal fields, or `{:error, :conflict}` for other fields. A currency that is retired in the newest held version (`Elzoo.Money.current_status/2`) is `{:error, :retired_currency}`.
- `post(journal, tenant, %{operation_id, actor_ref, reason, postings})`: `postings` is a list of 2..64 `%{account_id, amount}` with `amount` an `%Elzoo.Money.Amount{}`, each account at most once, no zero amount, every amount in one currency identity, and a sum of zero. Returns `{:ok, :applied}` or `{:ok, :duplicate}`.
- `reverse(journal, tenant, %{operation_id, reverses, actor_ref, reason})` posts, as the new operation `operation_id` linked to `reverses`, the negation of every posting of that earlier operation. Returns `{:ok, :applied}` or `{:ok, :duplicate}`.
- `balance(journal, tenant, account_id)` returns `{:ok, %Elzoo.Money.Amount{}}` in the account's currency.
- `history(journal, tenant, %{account_id, after, limit})` returns `{:ok, %{entries, next}}`: the postings of one account in ascending account `version`, each `%{version, operation_id, reverses, amount, balance}` (`balance` after that posting), at most `limit` (1..1000) entries after the cursor `after` (`nil` or a version), and `next` the last version returned or `nil` when no entry follows.

Texts (`tenant`, `account_id`, `operation_id`, `reverses`, `actor_ref`): 1..128 bytes of valid UTF-8 without a C0 or C1 control character, compared by exact bytes, the `domain/principal` and tenant-isolation rule. `reason`: 1..256 bytes under the same rule. Errors are `{:error, reason}` with a fixed atom that never echoes an ID or amount: `:invalid`, `:currency_mismatch`, `:unbalanced`, `:in_transaction`, `:conflict`, `:retired_currency`, `:unknown_account`, `:unknown_operation`, `:already_reversed`, `:not_reversible`, `:insufficient_funds`, `:amount_range`, `:unavailable`.

## Posting rules

`post/3` checks, in this order, and stops at the first failure:

1. shape and bounds of the journal, tenant and operation, and registry membership of every amount (`:invalid`); postings in more than one currency identity (`:currency_mismatch`); a nonzero sum (`:unbalanced`). These run before any query.
2. `repo.in_transaction?()` (`:in_transaction`): the journal opens its own transaction through `Elzoo.TenantIsolation.transact/3` and never joins a caller's.
3. In one READ COMMITTED transaction under the tenant scope: insert the operation row. A committed row with the same `operation_id` and an equal request digest returns `{:ok, :duplicate}` and changes nothing, also when its currency has retired since; another digest is `:conflict`. The request digest is the SHA-256 of a documented canonical encoding of the request, with amounts as `Elzoo.Money.Codec` bytes.
4. A currency retired in the newest held version is `:retired_currency`.
5. Read the accounts: an account that the tenant scope does not show is `:unknown_account` (another tenant's account is invisible under row security); an account whose currency identity `{alpha, numeric, minor_unit}` differs from the postings is `:currency_mismatch`.
6. Lock the account rows with `SELECT ... FOR UPDATE` one at a time in byte order of `account_id` (`COLLATE "C"`), never in posting order.
7. A balance outside the `domain/money` range is `:amount_range`; an `allow_negative: false` account whose new balance would be below zero is `:insufficient_funds`.
8. Insert the postings, add each amount to its account's balance and increment its `version` by one.

A refusal commits nothing, so a retry of a refused operation is evaluated again. A database failure, including a lost connection, is `{:error, :unavailable}` and says nothing about whether the operation committed; a retry with the same `operation_id` and request is safe.

`reverse/3` checks its shape (`:invalid`), then `:in_transaction`, then, in one transaction as above, its own operation identity as in step 3 (its digest covers its own four fields). Then: `reverses` unknown to the tenant is `:unknown_operation`; an operation that is itself a reversal is `:not_reversible`; an operation already reversed by another `operation_id` is `:already_reversed` (the unique `reverses` key decides a race). It skips step 4: a reversal of a posting in a now-retired currency is accepted, which is the decision `domain/money` leaves to the journal. Steps 5–8 then apply to the negated postings, so a reversal that would take a no-negative account below zero is `:insufficient_funds`. A reversal is never itself reversible.

`balance/3` and `history/3` run the shape check, then `:in_transaction`, then one read under the tenant scope; an account the scope does not show is `:unknown_account`.

The README states the minimum grants for the application role: `USAGE` on `prefix`, `SELECT, INSERT` on operations and postings, `SELECT, INSERT, UPDATE` on accounts, nothing else. Postings and operations are never updated or deleted by the Piece.

`piece.json` declares telemetry `not_applicable` (the Piece emits no event; the consumer Repo's query telemetry still receives the scope parameters, the tenant-isolation limit), config (the journal value and the fixed bounds) and control `not_applicable` (no process; the consumer owns the Repo, migrations and roles).

## Acceptance

Tests run on the worker's disposable PostgreSQL 16 (`ELZOO_TEST_DATABASE_URL`) with a `DBConnection.ConnectionPool` Repo, not the Sandbox, in random schemas dropped afterwards. Every case asserts afterwards that each stored balance equals the sum of its account's postings and that every operation's postings sum to zero.

1. A balanced post across a receivable, a revenue and a wallet account, with exact balances and history. Refused, each with nothing committed: one posting; 65 postings; a repeated account; a zero amount; a forged currency; mixed currencies; a nonzero sum; a posting whose account has another currency; an unknown account; each text at 0, 128 and 129 bytes, invalid UTF-8, a C0 and a C1 character; `reason` at 256 and 257 bytes; a balance one minor unit past the money range.
2. Two concurrent debits of a wallet (`allow_negative: false`) whose balance covers one: another connection holds the wallet's row lock until both posts wait on it (seen in `pg_locks` or `pg_stat_activity`), then releases it. Exactly one commits; the other is `:insufficient_funds`; the balance is never negative.
3. Lock order: another connection holds the row lock of account A; operation 1 lists its postings A then B and waits on A; operation 2 lists B then A and waits; the lock is released. Both commit with the summed balances.
4. Replay and conflict: the same request twice gives `:applied` then `:duplicate`; the same `operation_id` with another amount is `:conflict`. Two concurrent posts of one request, held behind a lock as in case 2, commit once and the second returns `:duplicate`.
5. A reversal restores the balances and is linked in history; its replay is `:duplicate`; a second reversal with another ID is `:already_reversed`, also when two race; a reversal of a reversal is `:not_reversible`; an unknown operation is `:unknown_operation`; a reversal of a wallet credit that was spent is `:insufficient_funds`.
6. Retired currency, with a test registry built by `Elzoo.Money.Registry.build!/1` in which a currency is active in one version and retired in a newer one (the `domain/money` registry tests show the form). Accounts opened and posted through a journal value on the older registry are then read through a second journal value whose registry holds the newer version: `open_account` and a new post in that currency are `:retired_currency`; the replay of an operation committed before the retirement is `:duplicate`; a reversal of it is accepted.
7. A connection killed inside the transaction: another connection holds an account row lock so the post waits after its operation insert; the test ends the post's backend with `pg_terminate_backend`. The post returns `:unavailable`; no operation row, posting or balance change remains; the same request then applies once.
8. A caller's open transaction gives `:in_transaction` for every function before any query.
9. Row security as `elzoo_app` (ELZ-285: `SET ROLE` to `ELZOO_TEST_APP_ROLE` on every connection, with only the README grants on the random schema; the test fails, not skips, when the variable is unset): `Elzoo.TenantIsolation.verify/3` passes for each table; under tenant T1 no T2 account, operation or posting is visible, `balance` and a post naming a T2 account are `:unknown_account`, and a direct SQL insert of a T2 row fails with SQLSTATE 42501; `UPDATE` and `DELETE` of a posting fail with 42501.
10. Bounds of `history/3`: `limit` 0, 1, 1000 and 1001; paging by `after` returns every posting once in version order.
11. Negative controls, one at a time, each restored before the final gates: lock in posting order instead of `account_id` order (case 3 must fail with a deadlock); drop the zero-sum check (case 1's nonzero sum must commit and the test must fail).

Run the Piece tests and the new-Piece small gate locally (this Piece holds durable money state with concurrency, so the hosted `check-piece` does not replace the local run), the roadmap and claims checks and the diff check. The full review of the coordinator guide ("Reviewer by risk"), the exact-head hosted check and the merge queue are required.

## Limits to state

The `state/tenant-isolation` limits apply (the table owner and a bypass role see every row; production connects as a non-owner, non-bypass role). One currency per operation and no exchange. History and balances are bounded reads, not reports. No audit capture of the journal tables. A database failure leaves the outcome to a retry with the same ID.
