# domain/journal

A balanced money journal in PostgreSQL 16 over a consumer-owned Ecto Repo. Accounts keep a
stored balance in their own currency. An operation posts 2..64 postings in one currency whose
sum is zero, all or nothing, under one operation identity. A reversal posts the negation of an
earlier operation once, linked to it. An account opened with `allow_negative: false` is a
wallet: its balance never goes below zero.

Amounts are `domain/money` values. The tables are protected by the `state/tenant-isolation`
floor. Account identity is not principal identity: `account_id` and `actor_ref` are opaque host
labels. There is no platform or default currency: each account has any `domain/money` registry
currency with an integer numeric code and an integer minor unit.

A balanced journal does not prove external settlement. No Float, exchange rate, payment,
invoice or settlement claim.

## Copy and providers

Select `domain/journal` with `mix elzoo.take`; the copy is owned by the consuming application.
See [consuming](../../../docs/consuming.md). Piece dependencies: `domain/money` and
`state/tenant-isolation`. Providers: `ecto_sql` 3.14.0 and `postgrex` 0.22.4, `cure` (the pure
zero-sum and balance decisions), `elixir` and OTP `crypto` (SHA-256); the tests also use
`telemetry`. Exact versions and claim-level grounding are in [piece.json](piece.json).

## Migration

Call `Elzoo.Journal.Migration.install(prefix)` from the `up/0` of a consumer Ecto migration, run
by the table owner, in an existing schema `prefix`. It installs the `state/tenant-isolation`
readers in `prefix` (`CREATE OR REPLACE`), creates three tables and protects each with the
tenant floor (`space_column: nil`):

| Table | Columns | Keys |
| --- | --- | --- |
| `elzoo_journal_accounts` | `tenant`, `account_id`, `currency_alpha`, `currency_numeric`, `currency_minor_unit`, `allow_negative`, `balance numeric(38,0)`, `version bigint` | `PRIMARY KEY (tenant, account_id)` |
| `elzoo_journal_operations` | `tenant`, `operation_id`, `actor_ref`, `reason`, `reverses`, `request_digest bytea` | `UNIQUE (tenant, operation_id)`, `UNIQUE (tenant, reverses)` |
| `elzoo_journal_postings` | `tenant`, `operation_id`, `account_id`, `minor_units numeric(38,0)`, `version bigint`, `balance numeric(38,0)` | `PRIMARY KEY (tenant, account_id, version)`, foreign keys to both other tables |

There is no sequence. `numeric(38,0)` holds every `domain/money` amount (`abs < 10^38`).
`prefix` must match `^[a-z_][a-z0-9_]{0,62}$`; anything else raises `ArgumentError` with the
fixed message `"invalid journal prefix or options"` before any DDL. Nothing is reversible by
the Piece; a `down/0` is the consumer's.

### Grants

The minimum grants for the application role:

```sql
GRANT USAGE ON SCHEMA prefix TO app_role;
GRANT SELECT, INSERT ON prefix.elzoo_journal_operations, prefix.elzoo_journal_postings TO app_role;
GRANT SELECT, INSERT, UPDATE ON prefix.elzoo_journal_accounts TO app_role;
```

Nothing else. The Piece never updates or deletes a posting or an operation.

Call `Elzoo.TenantIsolation.verify/3` for each table at startup, connected as the application
role, with `prefix: prefix, tenant_column: "tenant", space_column: nil`. `verify/3` also needs
the database `TEMP` privilege for its rolled-back rebuild of the floor; PUBLIC has it by default
(see the `state/tenant-isolation` README). Where PUBLIC lacks it, grant `TEMP` on the database to
the application role; the journal itself does not use it.

## Interface

```elixir
journal = Elzoo.Journal.new(repo: MyApp.Repo, prefix: "ledger")
{:ok, eur} = Elzoo.Money.parse("EUR")
{:ok, :applied} = Elzoo.Journal.open_account(journal, "t1", %{account_id: "wallet:alice", currency: eur, allow_negative: false})
{:ok, :applied} = Elzoo.Journal.open_account(journal, "t1", %{account_id: "revenue", currency: eur, allow_negative: true})
{:ok, amount} = Elzoo.Money.from_minor_units(eur, 500)
{:ok, minus} = Elzoo.Money.negate(amount)
{:ok, :applied} =
  Elzoo.Journal.post(journal, "t1", %{
    operation_id: "topup-1", actor_ref: "svc:billing", reason: "top-up",
    postings: [%{account_id: "wallet:alice", amount: amount}, %{account_id: "revenue", amount: minus}]
  })
{:ok, %Elzoo.Money.Amount{minor_units: 500}} = Elzoo.Journal.balance(journal, "t1", "wallet:alice")
```

- `new(opts)`: exactly `repo:` and `prefix:`, optionally `registry:` (an
  `Elzoo.Money.Registry` value; default `Elzoo.Money.Registry.default/0`). Else the fixed
  `ArgumentError`.
- `open_account(journal, tenant, %{account_id, currency, allow_negative})`: `currency` is a
  registry member with an integer numeric code and minor unit. The account stores the identity
  `{alpha, numeric, minor_unit}`, not its registry version or status. Order: shape
  (`:invalid`), `:in_transaction`, then in one transaction the isolation check (`:isolation`),
  an existing account (`{:ok, :duplicate}` when identity and flag are equal, also after its
  currency retired; else `:conflict`), a currency retired in the newest held version
  (`:retired_currency`), else created with balance zero (`{:ok, :applied}`).
- `post(journal, tenant, %{operation_id, actor_ref, reason, postings})`: `postings` is a list of
  2..64 `%{account_id, amount}`, each account at most once, no zero amount, one currency
  identity and a zero sum. `{:ok, :applied}` or `{:ok, :duplicate}`.
- `reverse(journal, tenant, %{operation_id, reverses, actor_ref, reason})`: posts, as
  `operation_id` linked to `reverses`, the negation of every posting of that operation.
- `balance(journal, tenant, account_id)`: `{:ok, %Elzoo.Money.Amount{}}`.
- `history(journal, tenant, %{account_id, after, limit})`: `{:ok, %{entries, next}}`, at most
  `limit` (1..1000) postings after version `after` (`nil` or a version) in ascending version,
  each `%{version, operation_id, reverses, amount, balance}` (`balance` is the stored balance
  after that posting); `next` is the last version returned, or `nil` when no entry follows.

Every returned amount is built under the newest held registry version whose entry has the
stored identity; when the journal's registry holds the identity in no version, `balance/3` and
`history/3` return `{:error, :registry}`.

Texts (`tenant`, `account_id`, `operation_id`, `reverses`, `actor_ref`) are 1..128 bytes of
valid UTF-8 without a C0 or C1 control character, compared by exact bytes; `reason` is 1..256
bytes under the same rule.

Errors are `{:error, reason}` with a fixed atom that never echoes an ID or amount:
`:invalid`, `:currency_mismatch`, `:unbalanced`, `:in_transaction`, `:conflict`,
`:retired_currency`, `:unknown_account`, `:unknown_operation`, `:already_reversed`,
`:not_reversible`, `:insufficient_funds`, `:amount_range`, `:isolation`, `:registry`,
`:unavailable`. The error set and the returned maps may gain members and keys in a later
in-place version; match on the members and keys you use.

## Posting rules

`post/3` stops at the first failure:

1. Before any query: shape and bounds and registry membership of every amount (`:invalid`),
   more than one currency identity (`:currency_mismatch`), a nonzero sum (`:unbalanced`).
2. `repo.in_transaction?()` is `:in_transaction`: the journal opens its own transaction
   through `Elzoo.TenantIsolation.transact/3` and never joins a caller's.
3. Inside it, before any table query, `current_setting('transaction_isolation')` other than
   `read committed` is `:isolation`.
4. Insert the operation row. A committed row with the same `operation_id` and an equal request
   digest is `{:ok, :duplicate}` (nothing changes, also after its currency retired); another
   digest is `:conflict`.
5. A currency retired in the newest held version is `:retired_currency`.
6. An account the tenant scope does not show is `:unknown_account`; an account in another
   currency identity is `:currency_mismatch`.
7. Lock the account rows with `SELECT ... FOR UPDATE` one at a time in byte order of
   `account_id` (Elixir binary order, the order of `COLLATE "C"`), never in posting order.
8. A balance outside the `domain/money` range is `:amount_range`; a wallet whose new balance
   would be below zero is `:insufficient_funds`.
9. Insert the postings, add each amount to its account's balance, increment its `version` by
   one and store the new balance on the posting.

`reverse/3` checks its shape (`operation_id` equal to `reverses` is `:invalid`), then
`:in_transaction`, then in one transaction the isolation check and its own identity (steps
3–4). Then `reverses` unknown to the tenant is `:unknown_operation`, a reversal is
`:not_reversible`, and an operation already reversed by another ID is `:already_reversed` (the
unique `reverses` key decides a race; the insert names no conflict target, so an equal request
racing on both keys is still `{:ok, :duplicate}`). It skips step 5: a reversal of postings in a now-retired
currency is accepted. Steps 6–9 apply to the negated postings, so a reversal that would take a
wallet below zero is `:insufficient_funds`.

`balance/3` and `history/3` check the shape, then `:in_transaction`, then run one read under
the tenant scope (no isolation check).

A refusal commits nothing, so a retry of a refused operation is evaluated again. A database
failure, including a lost connection, is `{:error, :unavailable}` and says nothing about whether
the operation committed; a retry with the same `operation_id` and request is safe.

### Request digest

The stored digest is SHA-256 of the canonical encoding below. A field is
`<<byte_size(name)::32, name, byte_size(value)::32, value>>` (big-endian lengths). The encoding
is the ASCII tag `elzoo-journal-request/1` followed by fields in this order:

- post: `kind` = `post`, `operation_id`, `actor_ref`, `reason`, `postings`. The value of
  `postings` is the concatenation of one `posting` field per posting in byte order of
  `account_id`, whose value is the fields `account_id`, `alpha`, `numeric`, `minor_unit` and
  `minor_units` (integers as decimal ASCII, `-` for a negative).
- reverse: `kind` = `reverse`, `operation_id`, `reverses`, `actor_ref`, `reason`.

Amounts enter as their currency identity and minor units, not their registry version or
status, so a retry re-parsed under a newer registry version is still a duplicate; posting order
does not change the digest. A field that a later in-place version adds as optional is appended
only when present, so existing digests, and the duplicates they decide, stay equal.

## Consumer Needs

- PostgreSQL 16 and READ COMMITTED, the server default. `transact/3` takes no isolation option
  and runs `set_config` first, so the Piece cannot set the level: it checks it and refuses
  every write with `:isolation` under another level (for example a role or database whose
  `default_transaction_isolation` is `repeatable read`).
- The migration runs as the table owner; the application connects as a non-owner role without
  `BYPASSRLS` or superuser, with the grants above.

## Limits

- The `state/tenant-isolation` limits apply: the table owner can turn forcing off, disable row
  security or drop the policies, and a superuser or `BYPASSRLS` role ignores them, so
  production connects as a non-owner, non-bypass application role. The consumer Repo's query
  telemetry still receives the scope parameters (the tenant).
- READ COMMITTED is a consumer Need that the Piece checks but cannot set.
- One currency per operation and no exchange; a cross-currency transfer is two operations
  through accounts the host chooses.
- History and balances are bounded reads, not reports.
- The journal tables are Piece-owned and are not captured by `state/audit-log`.
- A database failure leaves the outcome to a retry with the same ID.
- The Piece emits no telemetry event and has no process; the consumer owns the Repo, the
  migrations and the roles.
