# Ledger checkout

`assembly/ledger-checkout` is the saga of a **checkout**: it pays one invoice or tops up one
wallet through steps that each belong to a ready Piece, `domain/payment-lifecycle` (the charge),
`domain/invoice` (the invoice payment) and `domain/journal` (the posts), plus an optional host
**allowance** step for a top-up. It keeps its own durable log in plain Ecto and Postgrex tables
on PostgreSQL 16 under the `state/tenant-isolation` floor (owner answer Q10 A: there is no
`workflow/saga` Piece). It names no payment provider (Q9 D): the charge's provider is
payment-lifecycle's provider Need, which the host gives.

Each step is recorded before it starts and is idempotent by its key. A succeeded step's
**compensation** is written in the same checkout transaction as its result. After a step fails
definitely, the compensations of the succeeded steps run in reverse order. A step whose outcome
is unknown records nothing and is never compensated blindly: the checkout waits at it.

Dependencies: `domain/payment-lifecycle`, `domain/invoice`, `domain/journal`, `domain/money`,
`state/tenant-isolation`, and `delivery/effect-intent` for the host's intents in the tests.

## Install

`Elzoo.LedgerCheckout.Migration.install(prefix)` from a consumer migration's `up/0`, as the
table owner, installs the tenant-isolation readers and two tables in the existing schema
`prefix`, each protected with the floor (`space_column: nil`). Install the three reused Pieces'
tables with their own `install/1` (the tests put all four in one schema):

| Table | Key | Rows |
| --- | --- | --- |
| `elzoo_checkout_checkouts` | `PRIMARY KEY (tenant, checkout_id)` | kind, the canonical declaration bytes, state, failure reason, revision |
| `elzoo_checkout_steps` | `PRIMARY KEY (tenant, checkout_id, step)` | position, group, state, recorded result, compensation bytes, failure reason, revision |

A `CHECK` ties a step row's columns to its state: a `started` or `failed` row has no result and
no compensation, and every row with a result has its compensation. No row is deleted. A bad
`prefix` (not `^[a-z_][a-z0-9_]{0,62}$`) raises `ArgumentError` with a fixed message before any
DDL.

The step keys (`checkout.<id>`, `checkout/<id>`, `checkout/<id>/settle`, ...) are not
namespaced by the checkout's prefix, while the lock key is. So use one checkout prefix per set
of reused Piece tables: two checkout prefixes over the same payment, invoice or journal tables
would share one payment, application and journal operation for an equal `checkout_id`.

### Grants

The minimum grants for the application role, beside those of the reused Pieces' READMEs:

```sql
GRANT USAGE ON SCHEMA prefix TO app_role;
GRANT SELECT, INSERT, UPDATE ON prefix.elzoo_checkout_checkouts, prefix.elzoo_checkout_steps
  TO app_role;
```

Nothing else: no `DELETE`. `UPDATE` on checkouts is also what `SELECT ... FOR UPDATE` needs.
Connect as a non-owner, non-`BYPASSRLS` role at READ COMMITTED.

## Interface

```elixir
{:ok, checkout} =
  Elzoo.LedgerCheckout.new(
    repo: MyApp.Repo, prefix: "billing", payments: lifecycle, invoices: invoices, journal: journal,
    allowance: %{grant: &MyApp.Allowance.grant/1, revoke: &MyApp.Allowance.revoke/1}
  )

{:ok, :applied} =
  Elzoo.LedgerCheckout.open(checkout, "t1", %{
    checkout_id: "order-42", kind: :invoice_payment, invoice_id: "2026-11/acct-7",
    amount: amount, recipient: "merchant-1",
    approved: %{amount: amount, recipient: "merchant-1"}, approval_ref: "appr-7",
    settle: %{to: "cash", from: "receivable:acct-7"}, actor_ref: "svc:checkout"
  })

{:ok, %{state: :running, wait: %{step: :charge, for: :charge_intent, admission: admission}}} =
  Elzoo.LedgerCheckout.resume(checkout, "t1", %{checkout_id: "order-42"})
```

- `new(opts)` takes exactly `repo`, `prefix`, `payments` (an `%Elzoo.PaymentLifecycle{}`),
  `invoices` (an `%Elzoo.Invoice{}`), `journal` (an `%Elzoo.Journal{}`) and optionally
  `allowance`, `%{grant, revoke}` of one-arity functions. `{:ok, binding}` or
  `{:error, :invalid}`. The reused Pieces may be bound to the same Repo or to others.
- `open(b, tenant, request)` stores the checkout `:running`, idempotent by `checkout_id`: an
  equal request is `{:ok, :duplicate}`, another `{:error, :conflict}`. `checkout_id` is 1..64
  bytes of `[A-Za-z0-9._-]`. Every field is checked against the bound of the Piece that takes
  it before anything is stored, so a shape fault costs no charge: `amount` and the approved
  amount are positive `domain/money` amounts that payment-lifecycle encodes and the journal
  accepts; `recipient`, the approved recipient and `approval_ref` are payment-lifecycle's
  1..256 bytes; `invoice_id` invoice's 1..100; account IDs, `actor_ref` and `grant_id` 1..128
  bytes of printable UTF-8; the two accounts differ. A fault is `{:error, :invalid}`. Either
  - `%{checkout_id, kind: :invoice_payment, invoice_id, amount, recipient, approved: %{amount,
    recipient}, approval_ref, settle: %{to, from}, actor_ref}`: steps `charge`, `invoice`,
    `settle`; or
  - `%{checkout_id, kind: :top_up, amount, recipient, approved, approval_ref, wallet: %{to,
    from}, allowance: nil | %{grant_id}, parallel: boolean, actor_ref}`: steps `charge`,
    `wallet` and, when `allowance` is set, `allowance`. `parallel: true` (only with an
    allowance) declares `wallet` and `allowance` one parallel group. An allowance with no
    `allowance` Needs in the binding is `:invalid`.

  `amount` may differ from the approved amount: payment-lifecycle refuses that drift at the
  charge (`:approval_mismatch`), a definite failure before any intent.
- `resume(b, tenant, %{checkout_id})` runs the checkout as far as it can now and returns
  `{:ok, %{state, wait}}`. `state` is `:running`, `:compensating`, `:completed`,
  `:compensated` or `:needs_operator`; `wait` is `nil` or `%{step, for, admission}` with `for`
  `:charge_intent` or `:refund_intent` (with the intent's admission), `:retry` or `:busy`
  (admission `nil`). A checkout with an allowance resumed through a binding without the Needs
  is `{:error, :invalid}` with nothing called.
- `get(b, tenant, %{checkout_id})` returns `{:ok, %{checkout_id, kind, state, failure,
  revision, steps}}`, each step `%{step, position, group, state, result, failure,
  compensation}` in position order. A step's `state` is `:started`, `:succeeded`, `:failed`,
  `:compensated` or `:compensation_failed`; `group` is `1` for the members of the parallel
  group, else `nil`; `failure` is a fixed atom or `{:state, state}`.
- `list_running(b, tenant, %{after, limit, state})`, `after` `nil` or a `checkout_id`, `limit`
  1..256, returns `{:ok, %{checkout_ids, more}}` of the checkouts `:running` or `:compensating`
  (`state: :open`) or `:needs_operator` (`state: :needs_operator`), in byte order of
  `checkout_id`; `more` says whether one more follows.

Errors are fixed atoms that never echo an ID or amount: `:invalid`, `:in_transaction`,
`:isolation`, `:unknown_checkout`, `:unavailable`, `:conflict`. Every call checks its shape,
then `repo.in_transaction?()`, before any query; each own transaction runs through
`Elzoo.TenantIsolation.transact/3`, checks READ COMMITTED and passes `log: false`. A database
failure of its own is `:unavailable` and says nothing about whether the write committed; resume
again. The declaration, the step kinds, the wait reasons, the states and the errors may gain
members and keys in place before the first release.

## Steps

Every call to another Piece or Need runs outside the checkout's own transactions, which only
record. A step's row is written `started` before its first call. The step's result and its
compensation are written together in one checkout transaction, once: an equal recording again
changes nothing, another is `{:error, :conflict}` with nothing written.

| Step | Call | Key | Compensation recorded with the result |
| --- | --- | --- | --- |
| `charge` | payment-lifecycle `get/3`; `create/3` with the approved terms when no payment exists; `charge/3` with `amount` and `recipient` | `payment_id` `checkout.<id>` | `%{kind: :refund, payment_id, refund_id: "comp/charge", amount: :remaining}`, as `get/3` returns it |
| `invoice` | invoice `apply_payment/3` with the amount | `payment_ref` `checkout/<id>` | `%{kind: :reverse_payment, reversal_id: "checkout/<id>/c/invoice", payment_ref, amount: :remaining}` |
| `settle`, `wallet` | journal `post/3`: `to` +amount, `from` −amount, the checkout's `actor_ref` | `operation_id` `checkout/<id>/settle` or `checkout/<id>/wallet` | `%{kind: :reverse, operation_id: "checkout/<id>/c/<step>", reverses: <the step's operation_id>}` |
| `allowance` | the `grant` Need, `%{tenant, checkout_id, grant_id, amount}` | `grant_id` | `%{kind: :revoke, grant_id}` |

**Contract constants.** The journal's request digest includes `reason`, so a retry must send
the same text: the settle post's `reason` is `"elzoo.ledger-checkout settle"`, the wallet
post's `"elzoo.ledger-checkout wallet"`, and every journal reversal's
`"elzoo.ledger-checkout compensate"`.

- **The charge.** By the payment's state from `get/3`: `:created`, `:pending` or `:unknown`
  call `charge/3`, and the checkout waits `:charge_intent` with the admission; `:succeeded`
  records the step with its compensation; `:failed` is a definite failure
  (`:payment_failed`). `create/3`'s `:conflict` and `charge/3`'s `:approval_mismatch` are
  definite failures. `charge/3`'s `{:error, {:state, _}}` (the host's reconciliation settled
  the payment after the read) is not a failure: the step reads `get/3` again and acts on that
  state. A `:pending` or `:unknown` payment is never compensated: the checkout waits until the
  host's reconciliation (a verified event or a poll) makes it definite.
- **Answers.** `{:ok, :applied}` and `{:ok, :duplicate}` of the invoice and the journal record
  the step; `:ok` of `grant` records it and `{:error, :refused}` is a definite failure. After a
  crash between a Piece's commit and the record, the next `resume/3` asks again by the same
  key, gets `:duplicate` and records the result and compensation then.
- **Waits and errors.** `{:error, :unavailable}` of a Piece, and any answer of a Need other
  than `:ok` or `{:error, :refused}` (a raise, throw or exit included), waits `:retry` at that
  step with nothing recorded. `{:error, :in_transaction}` and `{:error, :isolation}` of a Piece
  record nothing and are returned as `resume/3`'s own error: the Pieces check them before their
  idempotency check, so they can follow an `:unavailable` that did commit. Any other error of a
  Piece is a definite failure, recorded with its fixed reason (`{:state, s}` included).
- **The parallel group.** With `parallel: true` the checkout starts both `wallet` and
  `allowance`, one after the other in that order in the holder's process, whatever the first
  returns; each member's definite outcome is recorded before the next member is called, so a
  crash inside the grant Need keeps a wallet refusal already read. The group is decided only when both are definite: a member waiting `:retry` keeps
  the checkout waiting at it, and its sibling is never skipped (a later `resume/3` runs only
  the member that is not definite). When one member fails, the checkout's failure is that
  member's; when both fail it is the `wallet` step's, and each member's own failure is on its
  row.

## Compensation

After a definite failure the checkout is `:compensating`. It runs the recorded compensations
of the succeeded steps one at a time in reverse order of position. The one parallel group is
the last two steps of a top-up, so a failure inside it leaves at most one succeeded member,
whose compensation runs first.

- `:refund`: payment-lifecycle `refund/3` with `comp/charge` and `:remaining`, waiting
  `:refund_intent` with its admission until `get/3` shows that refund `:succeeded`
  (compensated) or `:failed` (failed, `:refund_failed`); `:nothing_to_refund` is compensated.
  `:remaining` leaves out what other refunds hold, a host refund still `:pending` or
  `:unknown` included, so `:compensated` covers the checkout's own refund only.
- `:reverse_payment`: invoice `reverse_payment/3` as recorded; `{:ok, _}` and
  `:nothing_applied` are compensated.
- `:reverse`: journal `reverse/3` with the checkout's `actor_ref` and the reason constant;
  `{:ok, _}` and `:already_reversed` are compensated; `:insufficient_funds` (a spent wallet)
  and the other refusals fail it.
- `:revoke`: the `revoke` Need, `%{tenant, checkout_id, grant_id}`; `:ok` is compensated,
  `{:error, :refused}` fails it.

A failed compensation is recorded as that step's `compensation_failed` with its reason; no
further compensation runs and the checkout is `:needs_operator`, with the compensations not run
still recorded. When every compensation is done the checkout is `:compensated` (also when the
first step failed, with none to run). All steps succeeded makes it `:completed`.

## The host's side

- **Intents.** The checkout drives no intent. A `:charge_intent` or `:refund_intent` wait
  carries payment-lifecycle's admission `%{key, identity, arguments, deadline}`; the host starts
  `Elzoo.EffectIntent` with it, its own `use Elzoo.PaymentLifecycle.Binding` module of the
  operation and `adapter_context:` the lifecycle value, advances it, calls payment-lifecycle's
  `record/3` (or applies verified events), then calls `resume/3` again. The same admission comes
  back on every `resume/3` until the operation is definite.
- **Finding work.** `list_running/3` with `state: :open` lists every checkout not yet
  `:completed` or `:compensated` that is not waiting for an operator; the host resumes each
  after a restart and after each `:retry` wait. `state: :needs_operator` lists the stopped ones.
- **The allowance Needs.** `grant` is idempotent by `grant_id`, a refusal included (a repeated
  `grant` after `{:error, :refused}` answers it again), and grants nothing after a `revoke` of
  that `grant_id` (it answers `{:error, :refused}`). `revoke` is idempotent by `grant_id` too
  (a repeat answers `:ok`). A `grant_id` belongs to one checkout: the host binds it to the
  first `checkout_id` that the `grant` Need receives with it and answers `{:error, :refused}`
  to a grant of it for another checkout, so one checkout's revoke never takes back another's
  allowance. The host bounds both in time.
- **One holder per checkout.** `resume/3` runs inside `repo.checkout(fun, timeout: :infinity)`
  on the checkout's Repo and first takes a session advisory lock with `pg_try_advisory_lock` on
  a 64-bit key derived from the prefix, tenant and `checkout_id` (a collision only makes two
  checkouts wait for each other). It holds the lock for the whole call, every call to another
  Piece or Need included, and releases it before it returns. A caller that does not get the
  lock calls no Piece and no Need and returns the stored state with
  `wait: %{step, for: :busy, admission: nil}`; `step` is the step it would run next, the step
  whose compensation runs next, or the step whose compensation failed, and `nil` for a
  `:completed` or `:compensated` checkout. So two
  concurrent `resume/3` calls never both call another Piece for one checkout, and a refusal
  that depends on another's state (an invoice paid by another payment, a journal account
  opened or funded later) is read by one holder only. Answer `:busy` by resuming later.
- **Repo `:timeout`.** The checkout's own transactions call no Need, so they are short; the
  reused Pieces' rules are theirs. The lock holds one pool connection for the whole
  `resume/3`, Need and Piece calls included, with no checkout deadline (DBConnection's checkout
  deadline covers the whole checked-out time and ending it closes the session, and the lock
  with it). With no deadline, no query on that connection has a client deadline either (a call
  on a checked-out connection starts none), the checkout's own transactions and those of a
  reused Piece bound to the same Repo included. So set `statement_timeout` and `lock_timeout`
  for the role of the checkout's Repo, and bound your own Needs. A Piece bound to the
  checkout's Repo runs on the checked-out connection; only a Piece bound to another Repo takes
  one more connection, and the pool size must allow for it.

## Limits

- The payment provider is scripted in the tests (Q9 D): no claim about a provider's
  settlement, idempotency or events; a balanced journal does not prove external settlement.
- The host drives the charge and refund intents and the allowance Needs, and calls
  `resume/3`. A checkout it never resumes stays running and is listed; a charge or refund
  intent that the host never brings to a definite state leaves the checkout listed for ever.
- The lock is a session lock on the checkout's Repo, so it needs a connection that keeps its
  session: a transaction-mode pooler in front of that Repo breaks it. If that connection is
  lost while a call to a Need or to a Piece bound to another Repo is in flight, the lock is
  released and a second `resume/3` can run beside the first; the first caller then cannot
  record (it returns `{:error, :unavailable}`), the effect of its call in flight stays
  unrecorded by it, and a refusal that the second holder reads may disagree with that effect.
  This is not fenced.
- `resume/3` releases the lock with `pg_advisory_unlock` before it returns and does not check
  the answer. If that query fails while the connection stays open, the session lock stays on a
  pooled connection, and every other `resume/3` of that checkout answers `:busy` until that
  connection closes.
- A query that waits without end (no `statement_timeout` or `lock_timeout` on the role) holds
  the lock, and every other `resume/3` of that checkout answers `:busy`.
- `:compensated` covers the checkout's own refund, not a host refund still pending.
- A failed compensation stops the checkout for an operator, and no operator API is supplied.
  No inventory reservation, per-step timeout, quota adjustment or tax.
- The `state/tenant-isolation` limits apply; READ COMMITTED is a consumer Need that the Piece
  checks but cannot set. The Repo's query telemetry receives the tenant.

Telemetry: none (`log: false`). Config: the binding from `new/1`, fixed. Control: none of its
own; the host owns the intents, the Needs and when to resume.
