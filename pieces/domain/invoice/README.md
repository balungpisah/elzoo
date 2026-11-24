# domain/invoice

Numbered invoices of one currency in PostgreSQL 16 over a consumer-owned Ecto Repo (ELZ-367,
Wave 9 owner answer Q11 A). An **invoice** is a document of usage, fee and adjustment
**lines** for one billing account. It is drafted, then **finalized** with the next number of
its **series** (gapless, never reused), then paid by **payment applications** up to its
payable, with **reversal** of an applied amount, **void** of an unpaid invoice and **credit
notes** that correct a finalized one.

The tables are protected by the `state/tenant-isolation` floor; PostgreSQL row locks serialize
numbering and payments. The Piece posts nothing to `domain/journal`, renders no document and
supplies no tax or discount.

## Copy and providers

Select `domain/invoice` with `mix elzoo.take`; the copy is owned by the consuming application.
See [consuming](../../../docs/consuming.md). Piece dependencies: `state/tenant-isolation` and
`domain/money` (amounts, `Elzoo.Money.Codec`). `domain/pricing` is declared so that the copied
consumer can run the tests, which build charges with `Elzoo.Pricing.price/3`; the library code
reads a charge as data. The fee line of `domain/plan` is taken as data too, and the tests build
it as a map: no `domain/plan` code is called or copied. Providers: `ecto_sql` 3.14.0 and
`postgrex` 0.22.4, `elixir` and OTP `crypto` (SHA-256); the tests also use `telemetry`. Exact
versions and claim-level grounding are in [piece.json](piece.json).

## Migration

Call `Elzoo.Invoice.Migration.install(prefix)` from the `up/0` of a consumer Ecto migration,
run by the table owner, in an existing schema `prefix`. It installs the `state/tenant-isolation`
readers in `prefix`, creates five tables and protects each with the tenant floor
(`tenant_column: "tenant"`, `space_column: nil`):

| Table | Keys | Holds |
| --- | --- | --- |
| `elzoo_invoices` | `PRIMARY KEY (tenant, invoice_id)`, `UNIQUE (tenant, series, number)` | kind, billing account, currency, series, number, state, total, paid, credited, times, `corrects`, posting, revision |
| `elzoo_invoice_lines` | `PRIMARY KEY (tenant, invoice_id, line_id)` | position, kind, description, amount, `source_ref` |
| `elzoo_invoice_applications` | `PRIMARY KEY (tenant, invoice_id, payment_ref)` | the applied amount |
| `elzoo_invoice_reversals` | `PRIMARY KEY (tenant, invoice_id, reversal_id)` | `payment_ref`, the requested amount or `remaining`, the amount taken back |
| `elzoo_invoice_series` | `PRIMARY KEY (tenant, series)` | `last_number` |

Amounts are stored as their `Elzoo.Money.Codec.encode/2` bytes; the currency of an invoice as
the bytes of its zero amount. A `reversal_id` equal to a `payment_ref` does not collide.
`prefix` must match `^[a-z_][a-z0-9_]{0,62}$`; anything else raises `ArgumentError` before any
DDL. Nothing is reversible by the Piece; a `down/0` is the consumer's.

### Grants

The minimum grants for the application role:

```sql
GRANT USAGE ON SCHEMA prefix TO app_role;
GRANT SELECT, INSERT, UPDATE ON prefix.elzoo_invoices, prefix.elzoo_invoice_lines,
  prefix.elzoo_invoice_applications, prefix.elzoo_invoice_reversals,
  prefix.elzoo_invoice_series TO app_role;
```

Nothing else: no `DELETE`. Call `Elzoo.Invoice.verify/1` at startup, connected as the
application role; it runs `Elzoo.TenantIsolation.verify/3` for each table (which also needs the
database `TEMP` privilege; see the `state/tenant-isolation` README).

## Interface

```elixir
{:ok, inv} = Elzoo.Invoice.new(repo: MyApp.Repo, prefix: "billing")
{:ok, eur} = Elzoo.Money.parse("EUR")

{:ok, :applied} =
  Elzoo.Invoice.create(inv, "t1", %{
    invoice_id: "2026-11/acct-7", billing_account: "acct-7", currency: eur, series: "INV"
  })

{:ok, :applied} =
  Elzoo.Invoice.add_line(inv, "t1", %{
    invoice_id: "2026-11/acct-7", line: {:fee, "fee", fee_line, "Pro plan, November"}
  })

{:ok, :applied} =
  Elzoo.Invoice.add_line(inv, "t1", %{
    invoice_id: "2026-11/acct-7", line: {:charge, "usage", charge, "Model usage, November"}
  })

{:ok, %{number: 42, operation_id: "invoice/2026-11/acct-7/issue", total: total}} =
  Elzoo.Invoice.finalize(inv, "t1", %{
    invoice_id: "2026-11/acct-7", issued_at_ms: now_ms, due_at_ms: now_ms + 14 * 86_400_000
  })
```

Every function after `new/1` takes the binding, the tenant and one request map with exactly
the listed keys.

- `new(opts)`: exactly `repo:` and `prefix:`; `{:ok, binding}` or `{:error, :invalid}`.
- `create(inv, tenant, %{invoice_id, billing_account, currency, series})`: a `:draft` invoice;
  `{:ok, :applied}`, `{:ok, :duplicate}` for equal bytes, `:conflict` for others.
- `add_line(inv, tenant, %{invoice_id, line})`, `line` one of:
  - `{:charge, line_id, charge, description}`: a `domain/pricing` charge; `:incomplete_charge`
    when `incomplete` is `true`, else one `:usage` line of its `total`, `source_ref`
    `<card_id>/<version>/<period>` (at most 256 bytes);
  - `{:fee, line_id, fee_line, description}`: a `domain/plan` fee line
    `%{subscription_id, period: %{index, start_ms, end_ms}, plan: %{plan_id, version}, amount}`;
    one `:fee` line of its `amount`, `source_ref` `<subscription_id>/<index>`;
  - `{:adjustment, line_id, amount, description, source_ref}`.

  `:usage` and `:fee` amounts are zero or positive, `:adjustment` amounts non-zero; a negative
  amount only on a credit note (`:invalid` on an invoice). A draft credit note takes lines of
  any kind and sign here too; its `finalize/3` refuses a total that is not negative
  (`:invalid_total`) and checks its magnitude against the payable again. Another currency is `:currency`; a
  document that is not `:draft` is `{:state, state}`; at most 256 lines. Idempotent by
  `line_id`.
- `finalize(inv, tenant, %{invoice_id, issued_at_ms, due_at_ms})`, `due_at_ms ≥ issued_at_ms`,
  a draft with a line: `{:ok, %{number, operation_id, total, duplicate}}`. See Rules.
- `mark_posted(inv, tenant, %{invoice_id, operation_id, result})`, `result` `:applied` or
  `:duplicate` from the journal: the posting becomes `:posted`; another operation ID (or a
  document without a posting) is `:conflict`; a repeat is `{:ok, :duplicate}`.
- `apply_payment(inv, tenant, %{invoice_id, payment_ref, amount})`: a positive amount on an
  `:open` invoice, `paid + amount ≤ payable` else `:over_payment`; idempotent by
  `payment_ref`. At the payable the invoice is `:paid`.
- `reverse_payment(inv, tenant, %{invoice_id, reversal_id, payment_ref, amount})`: see Rules.
- `void(inv, tenant, %{invoice_id, expected_revision})`: see Rules.
- `credit_note(inv, tenant, %{invoice_id, corrects, lines})`: a draft `:credit_note` in the
  corrected invoice's billing account, currency and series; `lines` are 1..256 `:adjustment`
  lines with negative amounts. Idempotent by `invoice_id`.
- `get(inv, tenant, %{invoice_id})`: `{:ok, invoice}`.
- `verify(inv)`: `:ok` or the first table's `{:error, reason}` from
  `Elzoo.TenantIsolation.verify/3`.

An invoice from `get/3` is `%{invoice_id, kind, billing_account, currency, series, number,
state, lines, total, credited, payable, paid, credit_balance, issued_at_ms, due_at_ms, corrects,
posting, revision}`: `kind` `:invoice` or `:credit_note`; `state` `:draft`, `:open`, `:paid` or
`:void` for an invoice and `:draft`, `:issued` or `:void` for a credit note; `number` `nil`
until finalized; `total` the exact sum of the lines; `credited` the sum of the magnitudes of the
issued credit notes that correct it; `payable` `total − credited`; `paid` the applications
minus the reversals; `credit_balance` `paid − payable` when it is positive, else zero;
`posting` `nil` or `%{operation_id, state: :pending | :posted}`; `revision` grows with each
write. A line is `%{line_id, kind, description, amount, source_ref}` in the order added.

Texts (`tenant`, `billing_account`, `series`, `line_id`) are 1..128 bytes, `invoice_id`
1..100, `source_ref`, `payment_ref` and `reversal_id` 1..256 bytes of valid UTF-8 without a C0
or C1 control character, compared by exact bytes; `description` is 1..1,024 bytes of valid
UTF-8 without NUL. Times are integers 0..2^63−1 that the Piece only compares.

Errors are `{:error, reason}` with a fixed atom that never echoes an ID or amount: `:invalid`,
`:in_transaction`, `:isolation`, `:conflict`, `:unknown_invoice`, `{:state, state}`,
`:currency`, `:incomplete_charge`, `:invalid_total`, `:over_payment`, `:over_reversal`,
`:nothing_applied`, `:unknown_payment`, `:paid_amount`, `:credited`, `:over_credit`,
`:stale_revision`, `:unavailable`. The line kind, state and error sets and the returned maps
may gain members and keys in a later in-place version (tax and discount lines, an
issue-with-incomplete option); match on the members and keys you use.

## Rules

Every write checks shape and bounds (`:invalid`), then `repo.in_transaction?()`
(`:in_transaction`) before any query, then runs in its own transaction through
`Elzoo.TenantIsolation.transact/3`, checks READ COMMITTED (`:isolation`), and takes the
invoice row with `SELECT ... FOR UPDATE` before it reads lines or payments. Every statement
passes `log: false`; a database failure, including a lost connection, is `:unavailable` and
says nothing about whether the write committed, so retry with the same request. A refusal that
depends on stored state comes after those checks and the row lock, `:invalid` among them: a
negative line on an invoice, a 257th line, a finalize with no line, or a sum outside the
`domain/money` range.

**Numbering.** `finalize/3` locks the invoice row (for a credit note, first the corrected
invoice's row, then its own), then inserts the series row on its first use (`ON CONFLICT DO
NOTHING`) and locks it with `SELECT ... FOR UPDATE`, takes `last_number + 1`, and sets the
series' last number and the document's number in the same transaction. Two concurrent
finalizations of one series get consecutive numbers, a rolled-back finalization uses no number,
and a number is never reused: a void keeps its number. A repeat on a finalized document
returns the same number and operation ID with `duplicate: true`.

**Finalize.** An invoice's total must not be negative and a credit note's must be negative
(`:invalid_total`). An invoice becomes `:open`, or `:paid` when its payable is zero. A credit
note's corrected invoice must still be `:open` or `:paid` (else `{:state, state}`), and its
magnitude must still fit the corrected invoice's payable (`:over_credit`), so two drafts cannot
together pass it; it becomes `:issued`, and in the same transaction the corrected invoice's
`credited` grows by its magnitude and the invoice becomes `:paid` when `paid ≥ payable`.

**Reversal.** `reverse_payment/3` takes back `amount` (positive, in the invoice's currency) of
the application `payment_ref`, up to what of it is still applied (its amount minus its earlier
reversals), else `:over_reversal`. `:remaining` is that rest at this call, fixed in the row, and
`:nothing_applied` when it is zero. It is idempotent by `reversal_id` (equal `payment_ref` and
requested amount `{:ok, :duplicate}`, else `:conflict`); an unknown `payment_ref` is
`:unknown_payment`. A `:paid` invoice becomes `:open` again when `paid` drops below `payable`.
After a partial refund the host reverses the refunded amount; a checkout's compensation is
`%{reversal_id: "<checkout key>", payment_ref, amount: :remaining}` and reverses only what
remains, so the invoice never shows less owed than the payments still applied.

**Void.** A `:draft` or `:open` document at `expected_revision` (else `:stale_revision`) with
`paid` zero (else `:paid_amount`) and `credited` zero (else `:credited`) becomes `:void`; any
other state, an issued credit note among them, is `{:state, state}`. A finalized invoice keeps
its number.

**Credit balance.** When an issued credit note leaves `paid` above `payable`, `get/3` shows the
excess as `credit_balance`; the host refunds or carries it. This Piece moves no money.

## Posting to `domain/journal`

The host posts each finalized document whose total is not zero as one `domain/journal`
`post/3` operation with the `operation_id` that `finalize/3` returns (`invoice/<invoice_id>/issue`,
so a repeated post is `{:ok, :duplicate}`), with two postings of `total` and its negation
between the receivable of the billing account and a revenue account; the host chooses the
accounts and the sign convention. A credit note posts its negative total the same way, under its
own `invoice/<invoice_id>/issue`. A zero total posts nothing (the journal refuses a zero
posting) and names no operation. Then the host calls `mark_posted/3` with the journal's result. `void/3` takes an `:open`
invoice whose posting is pending or posted and keeps the posting as it was: the host reverses a
posted operation with `domain/journal` `reverse/3`, or does not post a pending one.
An `invoice_id` of at most 100 bytes keeps the operation ID within the journal's 128 bytes.

## Limits

The host decides the accounts, the billing account and the series, posts the journal
operations, and reads payment and refund outcomes from `domain/payment-lifecycle`; this Piece
records what it is given. A gapless number means no gap among committed finalizations of one
series. No tax, discount, rendering, delivery to a customer or multi-currency invoice. The
`state/tenant-isolation` limits apply, and READ COMMITTED is a consumer Need that the Piece
checks and cannot set. Concurrency and row-security evidence are finite scenarios on one local
PostgreSQL 16, not proofs. The full list is in [piece.json](piece.json).
