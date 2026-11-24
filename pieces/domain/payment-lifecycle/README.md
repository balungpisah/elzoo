# Payment lifecycle

`domain/payment-lifecycle` keeps one **payment**'s charge and its **refunds** in plain Ecto and
Postgrex tables on PostgreSQL 16, under the `state/tenant-isolation` floor. It names no
provider (owner answer Q9 D). The provider is a host **provider Need**,
`Elzoo.PaymentLifecycle.Provider`, that a later provider Piece (`integration/payments`)
implements. Each provider call is one `delivery/effect-intent` intent. Unknown outcomes are
reconciled through that intent, verified provider events apply only forward, and a charge that
succeeded returns its **compensation**, which the caller registers. This Piece keeps no saga
log (Q10 A): the one saga log is `assembly/ledger-checkout`'s.

Dependencies: `state/tenant-isolation`, `delivery/effect-intent`, `domain/money`.

## Install

`Elzoo.PaymentLifecycle.Migration.install(prefix)` from a consumer migration's `up/0`, as the
table owner, installs the tenant-isolation readers and four tables in the existing schema
`prefix`, each protected with the floor (`space_column: nil`):

| Table | Key | Rows |
| --- | --- | --- |
| `elzoo_payment_payments` | `PRIMARY KEY (tenant, payment_id)` | the payment: amount (its `Codec.encode/2` bytes), recipient, `approval_ref`, `approval_digest`, state, provider ref, revision, intent deadline |
| `elzoo_payment_refunds` | `PRIMARY KEY (tenant, payment_id, refund_id)` | a refund: the request (`remaining` or the amount's bytes), the fixed amount, state, provider ref, intent deadline |
| `elzoo_payment_events` | `PRIMARY KEY (tenant, event_id)` | a verified event's canonical bytes and its `applied` flag |
| `elzoo_payment_observations` | `PRIMARY KEY (tenant, payment_id, operation_ref, seq)` | one row per provider answer that an Adapter received, send or poll, in order (`seq` from 1 per operation), with the intent's attempt number, `source`, the answer and `applied` |

No row is replaced; only states, provider refs, revisions and `applied` flags change. The
observation rows of an operation are bounded by the host's send and poll count: at most 256
attempts per intent (effect-intent's bound), and one row per poll the host makes. Nothing is
pruned. A bad `prefix` (not `^[a-z_][a-z0-9_]{0,62}$`) raises `ArgumentError` with a fixed
message before any DDL.

### Grants

The minimum grants for the application role:

```sql
GRANT USAGE ON SCHEMA prefix TO app_role;
GRANT SELECT, INSERT, UPDATE ON prefix.elzoo_payment_payments, prefix.elzoo_payment_refunds,
  prefix.elzoo_payment_observations TO app_role;
GRANT SELECT, INSERT ON prefix.elzoo_payment_events TO app_role;
```

Nothing else; the Piece never deletes a row. `UPDATE` on payments is also what
`SELECT ... FOR UPDATE` needs. Connect as a non-owner, non-`BYPASSRLS` role at READ COMMITTED
and call `verify/1` at startup (it uses `Elzoo.TenantIsolation.verify/3`, which needs the
database `TEMP` privilege that PUBLIC has by default).

## Interface

```elixir
{:ok, lc} =
  Elzoo.PaymentLifecycle.new(
    repo: MyApp.Repo, prefix: "payments", provider: MyApp.PaymentProvider,
    provider_account: "acct-1", deadline_ms: 600_000, clock: fn -> System.os_time(:millisecond) end
  )

{:ok, :applied} =
  Elzoo.PaymentLifecycle.create(lc, "t1", %{
    payment_id: "inv-42", approved: %{amount: amount, recipient: "merchant-1"}, approval_ref: "appr-7"
  })

{:ok, admission} =
  Elzoo.PaymentLifecycle.charge(lc, "t1", %{payment_id: "inv-42", amount: amount, recipient: "merchant-1"})
# The host starts Elzoo.EffectIntent with admission.identity, .arguments, .deadline,
# binding: MyApp.ChargeBinding and adapter_context: lc, then advances it.
{:ok, %{state: state, compensation: compensation}} =
  Elzoo.PaymentLifecycle.record(lc, "t1", %{operation: {:charge, "inv-42"}, attempt: 1, fallback: nil})
```

- `new/1` takes exactly `repo`, `prefix`, `provider` (a module exporting the four callbacks),
  `provider_account` (1..128 bytes), `deadline_ms` (1..86,400,000) and `clock` (zero-arity,
  Unix ms); `{:ok, lifecycle}` or `{:error, :invalid}`. The value holds a process-local seal
  key and its `inspect` omits it.
- `create(lc, tenant, %{payment_id, approved: %{amount, recipient}, approval_ref})` stores the
  payment `:created`. `approval_digest` is the SHA-256 of the framed (32-bit length and bytes)
  fields `elzoo-payment-approval/1`, the approved amount's `Codec.encode/2` bytes, the
  recipient and `approval_ref`. Equal bytes again are `{:ok, :duplicate}`, others `:conflict`.
  The approved terms and `approval_ref` are the host's, from a released approval; this Piece
  calls no approval function.
- `charge(lc, tenant, %{payment_id, amount, recipient})` takes the action about to be sent; its
  digest with the stored `approval_ref` must equal `approval_digest`, else `:approval_mismatch`
  with nothing written. From `:created` it sets `:pending` and fixes the intent deadline (now
  plus `deadline_ms`); from `:pending` or `:unknown` it returns the same admission again; from
  `:succeeded` or `:failed` it is `{:error, {:state, state}}`.
- `refund(lc, tenant, %{payment_id, refund_id, amount})`, `amount` a positive amount or
  `:remaining`, runs under the payment row lock (`SELECT ... FOR UPDATE` before it sums the
  refunds). The payment must be `:succeeded`. `held` is every refund that is not `:failed`, so
  a pending or unknown refund is held. `:remaining` is the payment's amount minus `held` now,
  fixed in the row, and `:nothing_to_refund` when zero; an explicit amount of another currency
  is `:currency`, and one with `held + amount` over the amount is `:over_refund`. A stored
  refund ID with an equal request returns its admission again; another request is
  `:conflict`. `comp/charge` takes only `:remaining`.
- `record(lc, tenant, %{operation, attempt, fallback})` applies, under the payment row lock and
  in `seq` order, the operation's observation rows not yet applied whose attempt is at most
  `attempt` (the latest attempt number from the owner's `status/1`), and marks them applied.
  With `fallback: :unknown` and no row of attempt `attempt` (the host read from `status/1` that
  the intent is dispatched, stranded or recovered read-only with no result), the operation then
  takes the `{:unknown, _}` transition. Returns `{:ok, %{state, compensation}}`, `state` the
  operation's (the payment's for a charge, the refund's for a refund).
- `apply_event(lc, tenant, %{raw_body, headers})` (body at most 65,536 bytes, 0..64 binary
  pairs) calls `verify_event` before any query; a refusal, a raise or an event outside the
  Contract's shape is `:verification_failed` with nothing written. The event is stored once by
  `event_id`; a repeat with equal canonical bytes returns `{:ok, %{duplicate: true, applied,
  state, compensation}}`, other bytes `:conflict`. Under the payment row lock it applies the
  event's state as a transition. An event for an unknown payment or refund (also one of another
  tenant), with a state that is not a forward transition, or with another amount or currency is
  stored `applied: false` and changes nothing. `state` is the operation's current state, `nil`
  for an unknown operation.
- `get(lc, tenant, %{payment_id})` returns `{:ok, %{payment, refunds, compensation}}`;
  `payment` is `%{payment_id, amount, recipient, approval_digest, state, provider_ref, refunded,
  revision}` with `refunded` the sum of the refunds that are not `:failed`, and each refund
  `%{refund_id, amount, state, provider_ref}`.
- `verify(lc)` checks the four tables with `Elzoo.TenantIsolation.verify/3`.

IDs: `payment_id` is 1..100 and `refund_id` 1..64 bytes of `[A-Za-z0-9._-]`, or the reserved
`comp/charge`, so distinct operations have distinct logical references. Tenants are 1..128 and
recipients, refs, codes and event IDs 1..256 bytes of valid UTF-8 without a control character.

Errors are fixed atoms that never echo an ID, a recipient, a provider code or a body:
`:invalid`, `:in_transaction`, `:isolation`, `:conflict`, `:unknown_payment`,
`:approval_mismatch`, `{:state, state}`, `:currency`, `:over_refund`, `:nothing_to_refund`,
`:verification_failed`, `:unavailable`. Every write checks shape and bounds, then
`repo.in_transaction?()` before any query, then runs in `Elzoo.TenantIsolation.transact/3`
after checking READ COMMITTED; every statement passes `log: false`; a database failure is
`:unavailable` and says nothing about whether the write committed.

## Transitions

A charge or a refund changes state only by an observation (a send or poll answer), the
fallback or a verified event:

- `:created`, `:pending` or `:unknown` → `:succeeded` or `:failed` by a completed result or an
  event of that state, or by `{:declined, _}` (`:failed`);
- `:created` or `:unknown` → `:pending` by a completed result or event with `state: :pending`;
- `:pending` → `:unknown` by `{:unknown, _}` or the fallback; `:unavailable`, `:pending` and
  `{:not_sent, _}` change nothing; `:no_effect` changes nothing for a charge (its intent may be
  rearmed and dispatched again with the same key) and makes a refund `:failed`, which releases
  its hold;
- `:succeeded` and `:failed` are final.

A verified success event settles the row while the intent stays dispatched until the host polls
it: only `poll/1` reports provider state to an intent.

## Compensation

Whenever the charge is `:succeeded`, `record/3`, `apply_event/3` (also for a duplicate or an
event with `applied: false`) and `get/3` return
`%{kind: :refund, payment_id: id, refund_id: "comp/charge", amount: :remaining}`, else `nil`.
So a caller that crashed after the transition, retried after `:unavailable`, or whose step was
settled first by an event still gets it. The caller registers it with its step (in
`assembly/ledger-checkout`, in the same transaction as the step's recorded result). Running it
is `refund/3` with those values; running it twice is one refund, by its refund ID. Its amount is
what is still refundable when it first runs, so after a partial refund it refunds the rest. A
failed compensation is that refund's own recorded `:failed` or `:unknown` state; a
`comp/charge` refund that is `:failed` is final, and the host refunds the rest under a new
`refund_id`.

## The provider Need

`Elzoo.PaymentLifecycle.Provider` has four callbacks; this Piece calls each at most once per
call of its own and never retries:

- `charge(%{idempotency_key, payment_id, amount, recipient})` and
  `refund(%{idempotency_key, payment_id, refund_id, provider_ref, amount})` (`provider_ref` the
  charge's) return `{:ok, %{provider_ref, state: :succeeded | :pending | :failed}}`,
  `{:declined, code}`, `{:not_sent, reason}` or `{:unknown, :timeout | :transport}`;
- `poll(%{idempotency_key, kind: :charge | :refund})` returns `{:ok, %{provider_ref, state}}`,
  `:no_effect`, `:pending` or `:unavailable`;
- `verify_event(raw_body, headers)` returns `{:ok, %{event_id, operation, state, amount,
  provider_ref}}` (`operation` `{:charge, payment_id}` or `{:refund, payment_id, refund_id}`)
  or `{:error, :invalid}`.

What the implementation must guarantee:

- **Key rule (ELZ-025).** `idempotency_key` is the intent's derived key, which derives from the
  tenant, provider account, Adapter ID, operation and logical reference, never from an Attempt.
  The provider must deduplicate the operation by it, across every retry of the intent; check
  this against the named provider's documented idempotency.
- **`{:not_sent, _}` is an attestation** that no byte of the request reached the provider. It
  lets the intent dispatch again. Hidden retries, auth refreshes and redirects must be off.
- **`:no_effect` is final:** the provider holds no operation with that key and will not create
  one from a delayed request.
- **Signature first:** `verify_event` checks the provider's signature over the raw body before
  it parses anything, and returns `{:error, :invalid}` for any doubt.
- Codes, refs and event IDs are 1..256 bytes of valid UTF-8 without a control character; an
  answer outside these shapes, or a raise, is treated as unknown.

## Adapters and Bindings

A Binding fixes one operation, so there are two Adapters. The host declares one Binding of each
for its provider account:

```elixir
defmodule MyApp.ChargeBinding do
  use Elzoo.PaymentLifecycle.Binding, operation: :charge, provider_account: "acct-1"
end

defmodule MyApp.RefundBinding do
  use Elzoo.PaymentLifecycle.Binding, operation: :refund, provider_account: "acct-1"
end
```

`provider_account` must equal the lifecycle's. Each Binding has Adapter
`Elzoo.PaymentLifecycle.ChargeAdapter` or `RefundAdapter`, ID `elzoo/payment-lifecycle/charge`
or `elzoo/payment-lifecycle/refund`, operation `charge` or `refund`, clock `unix-ms`, no replay,
no revision and no recovery grace. The intent identity is `[tenant, provider_account, Adapter
ID, operation, logical reference]`, the logical reference `<payment_id>/charge` or
`<payment_id>/refund/<refund_id>` (also the observations' `operation_ref`). `arguments` are the
framed canonical bytes of `elzoo-payment-arguments/1`, the tenant, the logical reference, the
amount's `Codec` bytes and the recipient. Start the owner with `adapter_context:` the lifecycle
value.

`send_effect/1` calls `charge` or `refund` once with the request's key as `idempotency_key`,
stores the answer as the next observation row of its operation (its own transaction under the
tenant scope, with the payment row lock) and returns:

| Answer | Result |
| --- | --- |
| `{:ok, %{state: :succeeded \| :failed}}` | completed envelope holding the canonical bytes of `%{provider_ref, state}` |
| `{:ok, %{state: :pending}}` | `provider_pending`, `unknown / dispatched / unclassified` (pollable) |
| `{:declined, _}` | `declined`, `failed / dispatched / permanent` |
| `{:not_sent, _}` | `not_sent`, `timed_out / not_dispatched / retryable` (attested no-send) |
| `{:unknown, :timeout}` / `{:unknown, :transport}` | `timeout`, `timed_out / unknown`; `transport`, `unknown / unknown` |
| a raise or another shape | `adapter_error`, `unknown / unknown` |

When the observation write of a completed or declined answer fails, `send_effect/1` returns
`observation_unrecorded`, `unknown / dispatched / unclassified`, instead, so the intent stays
dispatched and a later poll asks the provider again. `fallback: :unknown` then applies, since no
row holds that attempt.

The RefundAdapter's `send_effect/1` first reads the refund row and its observation rows under the
tenant scope. When the refund is `:failed` or an observation of it holds a poll `:no_effect`
(applied or not), it returns `refund_closed`, `rejected / not_dispatched / permanent`, which
disarms the intent, and calls no provider. When that read fails it returns `store_unavailable`,
`timed_out / not_dispatched / retryable`, and calls no provider. Both are attested no-sends:
the Adapter made no provider call.

`poll/1` calls `poll` once, stores the answer the same way, and returns a completed envelope for
`{:ok, %{state: :succeeded | :failed}}`, the `pending` certificate for `{:ok, %{state:
:pending}}` and `:pending`, and the `no_effect` and `unavailable` certificates for those
answers. When the write of a completed answer, or of a refund's `:no_effect`, fails, it returns
the `pending` certificate instead. Completed envelopes and certificates carry an HMAC seal with
the lifecycle value's process-local key; `authenticate/2` checks it. That is the Adapter's own
integrity, not provider authentication, and a value from before a restart fails it.

## Limits

- No provider is named or exercised; the evidence is a scripted provider, so this Piece makes
  no claim about a provider's settlement, idempotency or event semantics.
- The approved terms and approval reference, the provider Need's attestations and signature
  check, and the host's `fallback` reading of an intent with no observation are host Needs.
- After `:no_effect` with the intent's deadline passed, or a stranded intent, the payment stays
  `:pending` or `:unknown`: this Piece makes no new intent, and an operator resolves it outside
  it.
- A balanced ledger does not prove settlement. No authorize/capture, split settlement,
  disputes, chargebacks or multi-currency settlement.
- The `state/tenant-isolation` limits apply; READ COMMITTED is a consumer Need that the Piece
  checks but cannot set. The Repo's query telemetry receives the tenant.

Kept open before the first release: the provider Need may gain callbacks, the maps optional
keys, and the state and error sets members (authorize, capture and void; split settlement;
disputes; the provider Piece under a named provider).

Telemetry: none (`log: false`). Config: the value from `new/1` and the Bindings, fixed. Control:
none of its own; the host owns the intent owners and their commands.
