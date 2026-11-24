# ELZ-367 — Numbered invoices of one currency: usage, fee and adjustment lines, gapless numbers per series, payment application and reversal, void and credit notes

- Phase: Wave 9 Level 1
- Dependencies: ELZ-031, ELZ-033, ELZ-270, ELZ-285, ELZ-304
- Release: V2
- Output: new `domain/invoice` Piece
- Change class: Piece-only
- Owned paths: `pieces/domain/invoice/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (including `domain/money`, `domain/pricing`, `domain/journal`, `domain/plan` and `state/tenant-isolation`), `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One durable Piece in plain Elixir, Ecto and Postgrex over a consumer-owned Ecto Repo on PostgreSQL 16: an **invoice** is a document of **lines** in one currency for one billing account, drafted, then **finalized** with the next number of its **series** (gapless, never reused), then paid by **payment applications** up to its total, with **reversal** of an applied payment, **void** of an unpaid invoice and **credit notes** that correct a finalized one. The Contract source is the `domain/invoice` section of [the Wave 9 plan](../docs/plans/bot-platform-wave9.md) ("Level 1"), under owner answer Q11 A (2026-11-24; "Owner answers (2026-11-24)" there) and the owner's plan-types decision of 2026-11-21.

The Piece posts nothing to the journal: `finalize/3` names the `domain/journal` operation ID that the host posts, and `mark_posted/3` records the host's journal result. It renders no document and supplies no tax or discount (Q11 A).

This task carries the PR #853 review answer on a reversal after a partial refund: `reverse_payment/3` takes an **amount** of one applied payment, up to the amount of it still applied, and is idempotent by its own reversal ID, so after a partial refund the host reverses the refunded part, and a later compensation of the checkout reverses only what remains; the invoice never shows less owed than the payments still applied.

The Piece keeps durable state and serializes concurrent numbering and payments, so this task keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk"; `AGENTS.md` sections 5 and 6).

## Facts on `main` that this task builds on

Checked at `main` `2face3fc`. Confirm each before you start; if one differs, stop and comment on the issue.

- `domain/money`: `%Elzoo.Money.Amount{currency, minor_units}`; one currency when `{alpha, numeric, minor_unit}` are equal; `add/3`, `subtract/3`, `compare/3`, `negate/2` return `{:ok, v}` or a fixed error (`{:currency_mismatch, _}` among them); `Elzoo.Money.Codec.encode/2` and `decode/2` give canonical bytes; the bundle is pure.
- `domain/pricing` (`pieces/domain/pricing/README.md`, lines 126–142): `price/3` returns `{:ok, charge}` with `charge` `%{tenant, period, card, lines, total, incomplete, unknown_count}`; `card` is `%{card_id, version, content_hash, kind}`; each line is `%{provider_id, model_id, unit, quantity, unknown_count, count, sources, charge}` with `charge` an amount; `incomplete` is `true` exactly when `unknown_count` is above zero, and an incomplete line's charge is of its known amounts only. One currency per card.
- `domain/journal` (`pieces/domain/journal/README.md`, lines 92–130): `post(journal, tenant, %{operation_id, actor_ref, reason, postings})` returns `{:ok, :applied}`, `{:ok, :duplicate}` for the same `operation_id` with an equal digest, or `:conflict`; `operation_id` is 1..128 bytes of valid UTF-8 without a control character; the journal opens its own transaction and never joins a caller's. This Piece calls no journal function, so it does not depend on ELZ-297.
- The fee line of `domain/plan` (ELZ-366, published with this task) is `%{subscription_id, period: %{index, start_ms, end_ms}, plan: %{plan_id, version}, amount}`. This Piece takes that shape as data and calls no `domain/plan` function, so it does not depend on ELZ-366.
- The durable-Piece pattern is `domain/quota`'s (`Migration.install/1`, `transact/3`, the READ COMMITTED check, `log: false`, `:unavailable`); ELZ-285's application role is `ELZOO_TEST_APP_ROLE`.

## Interface

Module `Elzoo.Invoice`. Every function after `new/1` takes the binding, the tenant and one request map.

- `Elzoo.Invoice.Migration.install(prefix)` installs the tenant-isolation readers and five protected tables: invoices, `PRIMARY KEY (tenant, invoice_id)` and `UNIQUE (tenant, series, number)`; lines, `PRIMARY KEY (tenant, invoice_id, line_id)`; applications, `PRIMARY KEY (tenant, invoice_id, payment_ref)`; reversals, `PRIMARY KEY (tenant, invoice_id, reversal_id)` (so a `reversal_id` equal to a `payment_ref` does not collide); series, `PRIMARY KEY (tenant, series)` with the last number. A bad `prefix` raises `ArgumentError` before any DDL.
- `new(opts)` takes exactly `repo` and `prefix`; `{:ok, binding}` or `{:error, :invalid}`.
- An **invoice** is `%{invoice_id, kind, billing_account, currency, series, number, state, lines, total, paid, issued_at_ms, due_at_ms, corrects, posting, revision}`: `invoice_id` 1..100 bytes; `kind` `:invoice` or `:credit_note`; `billing_account` and `series` 1..128 bytes; `currency` a `domain/money` currency; `number` `nil` until finalized; `state` `:draft`, `:open`, `:paid` or `:void` for an invoice, and `:draft`, `:issued` or `:void` for a credit note; `total` the exact sum of the lines (a zero amount when empty); `credited` the sum of the magnitudes of the issued credit notes that correct it; `payable` `total − credited`; `paid` the sum of applications minus reversals; `corrects` `nil` or the `invoice_id` that a credit note corrects; `posting` `nil` or `%{operation_id, state: :pending | :posted}`.
- A **line** is `%{line_id, kind, description, amount, source_ref}`: `line_id` 1..128 bytes; `kind` `:usage`, `:fee` or `:adjustment`; `description` 1..1,024 bytes of UTF-8; `amount` an amount in the invoice's currency (zero or positive for `:usage` and `:fee`, any non-zero for `:adjustment`; negative only on a credit note); `source_ref` 1..256 bytes.
- `create(inv, tenant, %{invoice_id, billing_account, currency, series})` stores a `:draft` invoice; idempotent by `invoice_id` (equal bytes `{:ok, :duplicate}`, others `:conflict`).
- `add_line(inv, tenant, %{invoice_id, line})` with `line` one of:
  - `{:charge, line_id, charge, description}`, a `domain/pricing` charge: refused `:incomplete_charge` when `incomplete` is `true`; otherwise one `:usage` line of the charge's `total` with the given `description` and `source_ref` `card_id/version/period` from the charge (`period` as the host gave it to `price/3`, its canonical bytes at most 256 with the rest);
  - `{:fee, line_id, fee_line, description}`, a plan fee line: one `:fee` line of its `amount`, `source_ref` `<subscription_id>/<index>`;
  - `{:adjustment, line_id, amount, description, source_ref}`.

  An amount of another currency is `:currency`; an invoice that is not `:draft` is `{:state, state}`; at most 256 lines. Idempotent by `line_id`.
- `finalize(inv, tenant, %{invoice_id, issued_at_ms, due_at_ms})`, `due_at_ms ≥ issued_at_ms`, a draft with at least one line. For an invoice the total must not be negative (else `:invalid_total`); for a credit note it must be negative (else `:invalid_total`), its corrected invoice must still be `:open` or `:paid` (else `{:state, state}`, so a credit note of an invoice voided meanwhile is never issued), and its magnitude must still fit (below). Under the invoice row lock (for a credit note, first the corrected invoice's row lock, then its own) and then the series row lock it takes the series' next number (from 1) and freezes the lines. An invoice becomes `:open`, or `:paid` when its payable is zero. A credit note becomes `:issued`; in the same transaction the corrected invoice's `credited` grows by its magnitude, and the corrected invoice becomes `:paid` when `paid ≥ payable`. A non-zero total sets `posting` `%{operation_id: "invoice/<invoice_id>/issue", state: :pending}`; a zero total leaves `posting` `nil`, since the journal takes no zero posting. A repeat on a finalized document returns the same number and operation ID with `duplicate: true`. It returns `{:ok, %{number, operation_id, total}}`, `operation_id` `nil` for a zero total.
- `mark_posted(inv, tenant, %{invoice_id, operation_id, result})` with `result` `:applied` or `:duplicate` (the journal's) sets `posting.state` `:posted`; another `operation_id` is `:conflict`; a repeat is `{:ok, :duplicate}`.
- `apply_payment(inv, tenant, %{invoice_id, payment_ref, amount})`: an `:open` invoice; `amount` positive in its currency; `paid + amount` at most `payable`, else `:over_payment`. Idempotent by `payment_ref` (1..256 bytes): equal bytes `{:ok, :duplicate}`, others `:conflict`. When `paid` reaches `payable` the invoice is `:paid`.
- `reverse_payment(inv, tenant, %{invoice_id, reversal_id, payment_ref, amount})`: `amount` positive, or `:remaining`; `reversal_id` 1..256 bytes. It takes back that amount of the application `payment_ref`, up to what of it is still applied (its amount minus its earlier reversals), else `:over_reversal`; `:remaining` is that rest at this call, fixed in the row, and `:nothing_applied` when it is zero. Idempotent by `reversal_id` (equal bytes `{:ok, :duplicate}`, others `:conflict`). A `:paid` invoice becomes `:open` again when `paid` drops below `payable`. It is the compensation of a checkout's invoice step (`%{reversal_id: "<checkout key>", payment_ref, amount: :remaining}`) and the host's call after a refund outside a checkout (the refunded amount). An unknown `payment_ref` is `:unknown_payment`.
- `void(inv, tenant, %{invoice_id, expected_revision})`: a `:draft` or `:open` invoice with `paid` zero (else `:paid_amount`) and `credited` zero (else `:credited`) becomes `:void`; a draft credit note may be voided, an issued one may not (`{:state, :issued}`); a finalized invoice keeps its number.
- `credit_note(inv, tenant, %{invoice_id, corrects, lines})`: `corrects` an `:open` or `:paid` invoice of the tenant; `lines` 1..256 `:adjustment` lines whose amounts are negative, whose sum's magnitude is at most the corrected invoice's `payable` (else `:over_credit`), checked here and again at its `finalize/3` under the corrected invoice's row lock, so two drafts cannot together pass it. When an issued credit note leaves `paid` above `payable`, `get/3` shows the excess as `credit_balance`, which the host refunds or carries; this Piece moves no money. It creates a `:credit_note` in the same billing account, currency and series as a draft; `finalize/3` numbers it from the same series. Its posting operation ID is `invoice/<invoice_id>/issue` as well, and the host posts its negative total.
- `get(inv, tenant, %{invoice_id})`; `verify(inv)` checks the five tables with `Elzoo.TenantIsolation.verify/3`.

Errors are fixed atoms that never echo an ID or an amount: `:invalid`, `:in_transaction`, `:isolation`, `:conflict`, `:unknown_invoice`, `{:state, state}`, `:currency`, `:incomplete_charge`, `:invalid_total`, `:over_payment`, `:over_reversal`, `:nothing_applied`, `:unknown_payment`, `:paid_amount`, `:credited`, `:over_credit`, `:stale_revision`, `:unavailable`.

## Rules

Writes check shape and bounds (`:invalid`), then `repo.in_transaction?()` (`:in_transaction`) before any query, then run in `Elzoo.TenantIsolation.transact/3` with the READ COMMITTED check; every statement passes `log: false`; a database failure is `:unavailable`. Each write takes the invoice row with `SELECT ... FOR UPDATE` before it reads lines or payments. `finalize/3` takes the series row with `SELECT ... FOR UPDATE` (inserting it on the first use with `ON CONFLICT DO NOTHING`, then locking it) and sets the series' last number and the invoice's number in the same transaction, so two concurrent finalizations of one series get consecutive numbers, a rolled-back finalization uses no number, and a number is never reused. Amounts are stored as their `Codec.encode/2` bytes and summed with `domain/money` only.

`piece.json` declares telemetry and control `not_applicable`, the config of the binding, and the dependencies `state/tenant-isolation`, `domain/money` and `domain/pricing` (its tests build charges with `Elzoo.Pricing.price/3`, and the copied consumer of a new Piece holds only its declared closure), and names `domain/plan` as the shape of a fee line, which its tests build as data; the README states the posting rule for the host (the operation ID, two postings of `total` between the receivable and revenue accounts, a zero total posts nothing, a credit note posts its negative total) and the minimum grants of the application role.

## Kept open (owner's "no corner" rule)

The line kind, state and error sets may gain members and the invoice, line and request maps optional keys in place before the first release.

- *Tax and discount lines* (Q11 B), as line kinds.
- *Several currencies per billing account* through several invoices (already possible: one currency per invoice).
- *An issue-with-incomplete option* that takes an incomplete charge with a marker; *a document rendering*.

## Acceptance

1. Numbering: two concurrent finalizations of two invoices of one series behind a barrier (another connection holds the series row lock until both are seen waiting in `pg_locks`) get numbers 1 and 2; a finalization that fails after taking a number (a forced error in its transaction in a test-only Repo wrapper) uses no number; series are independent; a void keeps its number.
2. An incomplete charge is `:incomplete_charge`; a complete charge gives one `:usage` line of its total; a plan fee line gives one `:fee` line; a line of another currency is `:currency`.
3. A repeated finalize returns the same number and operation ID with `duplicate: true`; `mark_posted/3` with `:applied`, then `:duplicate`, then another operation ID (`:conflict`).
4. Payments: a partial payment leaves `:open`, the rest makes it `:paid`, an over-payment is `:over_payment`, a repeated `payment_ref` is `:duplicate`.
5. Reversal: a payment reversed twice with one `reversal_id` is reversed once; a reversal of a `:paid` invoice makes it `:open`; after a partial reversal of 30 of a 100 payment (the host's call after a partial refund), a `:remaining` reversal takes back 70, and a third is `:nothing_applied`; a reversal over what is still applied is `:over_reversal`.
6. Void with nothing paid (`:void`); a draft credit note of an invoice that is voided meanwhile is `{:state, :void}` at its `finalize/3`; with a payment (`:paid_amount`) and after a credit note (`:credited`). Credit notes: one over the payable is `:over_credit`; one within it is finalized `:issued`, numbered from the same series, with a negative total and a pending posting; two drafts that each fit but together pass the payable: the second `finalize/3` is `:over_credit`; a 100 invoice with an issued −40 credit note becomes `:paid` at a payment of 60, and a payment of 61 is `:over_payment`; a credit note on a paid 100 invoice shows `credit_balance` 40. A zero-total invoice finalizes `:paid` with no posting; a zero `:fee` line is accepted.
7. Row security as `elzoo_app` (ELZ-285): `verify/1` passes; another tenant's invoice is `:unknown_invoice`; a direct insert of a T2 row into each table fails with SQLSTATE 42501; every function succeeds with only the README grants. A caller's open transaction gives `:in_transaction` before any query; a `repeatable read` Repo gets `:isolation`.
8. Negative controls, one at a time, each restored before the final gates: take the number outside the series lock (read the last number before locking; case 1 gives a duplicate number, refused by the unique index as `:unavailable`, so the concurrent case fails); allow a line of another currency (case 2's currency case fails); reverse the whole application instead of the amount (case 5's partial case fails).

Run the Piece tests and the new-Piece small gate locally (`mix check --piece "$(git merge-base origin/main HEAD)"`), the roadmap and claims checks and the diff check. The full independent review of the coordinator guide, the exact-head hosted check and the merge queue are required.

## Limits to state

The host posts the journal operations, decides the accounts, the billing account and the series, and reads payment and refund outcomes from `domain/payment-lifecycle`; this Piece records what it is given. A gapless number means no gap among committed finalizations of one series. No tax, discount, rendering, delivery to a customer or multi-currency invoice. The `state/tenant-isolation` limits apply; READ COMMITTED is a consumer Need.
