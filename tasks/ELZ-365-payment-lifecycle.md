# ELZ-365 — One payment's charge and refunds through a provider Need, with unknown outcomes reconciled, verified events applied forward only, and the compensation of a succeeded charge

- Phase: Wave 9 Level 1
- Dependencies: ELZ-023, ELZ-031, ELZ-033, ELZ-270, ELZ-285
- Release: V2
- Output: `domain/payment-lifecycle` (moved from RC-24; RC-24 keeps `integration/payments`, which waits under Q9 D)
- Change class: Piece-only
- Owned paths: `pieces/domain/payment-lifecycle/**`, the `domain/payment-lifecycle` rows of `registry/catalogue.json` and `docs/plans/release-plan.json`, and the generated views only. Do not edit root/shared code, another Piece (including `delivery/effect-intent`, `domain/money`, `workflow/approval` and `state/tenant-isolation`), `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One durable, provider-neutral Piece in plain Elixir, Ecto and Postgrex over a consumer-owned Ecto Repo on PostgreSQL 16: one **payment**'s charge and its **refunds**, each sent to the payment provider through a host **provider Need** as one `delivery/effect-intent` intent whose provider-side idempotency key derives from the logical payment or refund ID, never from an Attempt (the ELZ-025 rule of the `integration/payments` row); provider **events** checked by the provider Need and applied only forward; and, for a charge that succeeded, the **compensation** that undoes it. The Contract source is the `domain/payment-lifecycle` section of [the Wave 9 plan](../docs/plans/bot-platform-wave9.md) ("Level 1") and RC-24, under owner answers Q9 D and Q10 A (2026-11-24; "Owner answers (2026-11-24)" there) and settled decision 1 (the saga rules) with the plan's reading of it (one saga log, in `assembly/ledger-checkout`).

Under Q9 D no provider is named: this Piece names none, and `integration/payments` waits. The provider Need is a behaviour that the later provider Piece implements; this task's tests use a scripted provider. Under Q10 A and the reading of decision 1, this Piece keeps no saga log: the result of the step that makes a charge succeed holds its compensation, which the caller registers.

This task carries the PR #853 review answer on reversal after a partial refund into this Piece: a compensation refunds **what is still refundable when it runs**, not the charged amount, so a compensation after a partial refund is not refused as an over-refund.

The Piece keeps durable state, serializes concurrent refunds, takes untrusted provider events and has unknown outcomes, so this task keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk"; `AGENTS.md` sections 5 and 6).

## Facts on `main` that this task builds on

Checked at `main` `2face3fc`. Confirm each before you start; if one differs, stop and comment on the issue.

- `domain/money`: an amount is `%Elzoo.Money.Amount{currency: %Elzoo.Money.Currency{alpha, numeric, minor_unit, status, version}, minor_units}`; two amounts are of one currency when `{alpha, numeric, minor_unit}` are equal; `add/3`, `subtract/3`, `compare/3` (`:lt | :eq | :gt`) return `{:ok, v}` or `{:error, {:currency_mismatch, _}}` and the like; `Elzoo.Money.Codec.encode/2` and `decode/2` give canonical bytes (`elzoo-money/1 <version> <alpha> <numeric> <minor_unit> <minor_units>`). The bundle is pure.
- `delivery/effect-intent`: the host starts one owner per intent (`Elzoo.EffectIntent.start_link/1` with `binding`, `identity` of five texts — tenant, provider account, Adapter ID, operation kind, logical request reference — `arguments`, `deadline`, `clock`, `store`, `host`, `task_supervisor`, `adapter_context`). The derived key is SHA-256 of the identity, and the attempt number does not enter it. A later dispatch needs a recorded definite failure with one ground: an Adapter no-send (a declared, attested not-dispatched send failure), a provider no-effect, or a poll-derived replay-safe ground. "Only `poll/1` can return `{:pending | :unavailable | :unknown_to_provider | :no_effect, evidence}`; ... Poll can also return a completed Envelope. A send cannot mint these poll-only certificates." ([README](../pieces/delivery/effect-intent/README.md), lines 81–84.) The Binding callbacks are `failure_tags/0`, `schema/0`, `validate/2`, `send_effect/1`, `poll/1`, `authenticate/2`, `validate_result/2`. `integration/ai-text` is the pattern of a Piece that gives the host an admission (`%{key, identity, arguments, deadline}`) and an Adapter.
- `workflow/approval` has no approval digest: a binding is compared structurally (README line 29) and its exact-action check is `release/4`. So this Piece takes the approved terms from the host and keeps its own digest of them; it calls no approval function, and it does not depend on ELZ-024 (a coordinator check of the plan's dependency list).
- The durable-Piece pattern is `domain/quota`'s (`Migration.install/1`, `transact/3`, the READ COMMITTED check, `log: false`, `:unavailable` for a database failure); ELZ-285's application role is `ELZOO_TEST_APP_ROLE`, as `domain/journal`'s test helper uses it.
- The catalogue row `domain/payment-lifecycle` exists (`deferred`); this task's last commit sets it `ready` with its manifest.

## Interface

Module `Elzoo.PaymentLifecycle`. Every function after `new/1` takes the binding, the tenant and one request map.

- `Elzoo.PaymentLifecycle.Migration.install(prefix)` installs the tenant-isolation readers and three protected tables: payments, `PRIMARY KEY (tenant, payment_id)`; refunds, `PRIMARY KEY (tenant, payment_id, refund_id)`; events, `PRIMARY KEY (tenant, event_id)`. A bad `prefix` raises `ArgumentError` before any DDL.
- `new(opts)` takes exactly `repo`, `prefix`, `provider` (a module implementing `Elzoo.PaymentLifecycle.Provider`), `provider_account` (1..128 bytes), `deadline_ms` (the intent deadline after now, 1..86,400,000) and `clock`. It returns `{:ok, binding}` or `{:error, :invalid}`.
- `Elzoo.PaymentLifecycle.Provider`, the provider Need, has four callbacks, each called by this Piece at most once per call:
  - `charge(%{idempotency_key, payment_id, amount, recipient})` and `refund(%{idempotency_key, payment_id, refund_id, provider_ref, amount})` return `{:ok, %{provider_ref, state: :succeeded | :pending | :failed}}`, `{:declined, code}` (the provider refused it), `{:not_sent, reason}` (no byte reached the provider; an attestation of the implementation) or `{:unknown, :timeout | :transport}`;
  - `poll(%{idempotency_key, kind: :charge | :refund})` returns `{:ok, %{provider_ref, state}}`, `:no_effect` (the provider holds no operation with that key, final), `:pending` or `:unavailable`;
  - `verify_event(raw_body, headers)` returns `{:ok, event}` or `{:error, :invalid}`, with `event` `%{event_id, operation: {:charge, payment_id} | {:refund, payment_id, refund_id}, state: :succeeded | :pending | :failed, amount, provider_ref}`. It checks the provider's signature over the raw body before any parsing.

  `idempotency_key` is the intent's derived key. Codes, refs and event IDs are 1..256 bytes of valid UTF-8 without a control character.
- `Elzoo.PaymentLifecycle.Adapter` is the effect-intent Adapter: the logical reference of a charge is `<payment_id>/charge` and of a refund `<payment_id>/refund/<refund_id>`, the operation kind `charge` or `refund`; `send_effect/1` calls `charge` or `refund` with the request's key as `idempotency_key`, and maps `{:ok, _}` to a completed envelope holding the canonical bytes of `%{provider_ref, state}`, `{:declined, _}` to `failed / dispatched / permanent`, `{:not_sent, _}` to an attested not-dispatched failure, and `{:unknown, _}` to `timed_out / unknown` or `unknown / unknown`; `poll/1` calls `poll` and maps `{:ok, _}` to a completed envelope and `:no_effect`, `:pending` and `:unavailable` to the poll certificates of the same names.
- A **payment** is `%{payment_id, amount, recipient, approval_digest, state, provider_ref, refunded, revision}`: `payment_id` 1..100 bytes; `amount` a positive `domain/money` amount; `recipient` 1..256 bytes; `state` `:created`, `:pending`, `:unknown`, `:succeeded` or `:failed`; `refunded` the sum of its refunds that are not `:failed`. A **refund** is `%{refund_id, amount, state, provider_ref}` with `refund_id` 1..64 bytes and the same states without `:created`.
- `create(lc, tenant, %{payment_id, approved: %{amount, recipient}, approval_ref})` stores the payment `:created` with the approved amount and recipient and `approval_digest`, the SHA-256 of the canonical bytes of the approved amount's `Codec.encode/2` bytes, the recipient and `approval_ref` (1..256 bytes, the host's reference of the released approval). Idempotent by `payment_id`: equal bytes `{:ok, :duplicate}`, others `:conflict`.
- `charge(lc, tenant, %{payment_id, amount, recipient})` takes the action about to be sent. Its digest with the stored `approval_ref` must equal `approval_digest`, else `:approval_mismatch` (a changed amount, currency or recipient) with nothing written. From `:created` it sets `:pending` and returns `{:ok, admission}` (`%{key, identity, arguments, deadline}`); from `:pending` or `:unknown` it returns the same admission again, so the host recovers the same intent; from `:succeeded` or `:failed` it is `{:error, {:state, state}}`.
- `record(lc, tenant, %{operation, result})` takes the settled result of an intent as the host observed it from its owner: `operation` `{:charge, payment_id}` or `{:refund, payment_id, refund_id}`, `result` `{:completed, %{provider_ref, state}}` (from a send or a poll), `{:declined, code}`, `:no_effect` or `{:unknown, reason}`. Under the payment row lock it applies the transition below and returns `{:ok, %{state, compensation}}`; a result that is not a forward transition is `{:ok, %{state: current, compensation: nil}}` with nothing written.
- `apply_event(lc, tenant, %{raw_body, headers})`: `raw_body` at most 65,536 bytes, `headers` 0..64 pairs. `verify_event` runs before any query; `{:error, :invalid}` (or a raise) is `:verification_failed` with nothing written. A verified event is stored once by `event_id` (a repeat with equal bytes is `{:ok, :duplicate}`, others `:conflict`); under the payment row lock it applies the event's state to the operation as a transition, and returns `{:ok, %{applied, state, compensation}}`. An event for an unknown payment or refund, a state that is not a forward transition, or an amount or currency other than the operation's is stored with `applied: false` and changes nothing.
- `refund(lc, tenant, %{payment_id, refund_id, amount})`, `amount` a positive amount or `:remaining`. Under the payment row lock: the payment must be `:succeeded` (`{:state, s}` otherwise); a refund ID already stored with an equal request returns its admission again (`{:ok, admission}`), another request is `:conflict`. `held` is `refunded` (every refund not `:failed`, so a pending or unknown refund is held). `:remaining` is the payment's amount minus `held` at this call, fixed in the refund row, and `:nothing_to_refund` when it is zero; an explicit amount of another currency is `:currency`, and one with `held + amount` over the payment's amount is `:over_refund`. Otherwise the refund is stored `:pending` and its admission returned.
- `get(lc, tenant, %{payment_id})` returns `{:ok, %{payment, refunds}}`; `verify(lc)` checks the three tables with `Elzoo.TenantIsolation.verify/3`.

Errors are fixed atoms that never echo an ID, a recipient, a provider code or a body: `:invalid`, `:in_transaction`, `:isolation`, `:conflict`, `:unknown_payment`, `:approval_mismatch`, `{:state, state}`, `:currency`, `:over_refund`, `:nothing_to_refund`, `:verification_failed`, `:unavailable`.

## Rules

**Transitions** of a charge or a refund, from a send result, a poll result or a verified event; nothing else changes a state:
- `:created` or `:pending` or `:unknown` → `:succeeded` or `:failed` by a completed result or an event of that state, or by `{:declined, _}` (`:failed`);
- `:created` or `:unknown` → `:pending` by a completed result or an event with `state: :pending`;
- `:pending` → `:unknown` by `{:unknown, _}`; `:no_effect` changes nothing, because the intent may then be dispatched again with the same key;
- `:succeeded` and `:failed` are final: a later result or event is recorded (an event) and changes nothing.

So a verified success event settles the payment row while its intent stays dispatched until the host polls it: only `poll/1` reports provider state to an intent. A dispatch after a recorded definite failure keeps the same intent, so the provider gets the same `idempotency_key`.

**Compensation (settled decision 1, Q10 A).** The transition that makes a charge `:succeeded`, by `record/3` or `apply_event/3`, returns `compensation: %{kind: :refund, payment_id, refund_id: "comp/charge", amount: :remaining}`; every other result returns `compensation: nil`. The caller registers it with the step (in `assembly/ledger-checkout`, in the same transaction as the step's recorded result). Running it is `refund/3` with those values; running it twice is one refund, by its refund ID. Its amount is what is still refundable when it first runs, so after a partial refund it refunds the rest. A failed compensation is that refund's own recorded `:failed` or `:unknown` state.

Writes check shape and bounds (`:invalid`), then `repo.in_transaction?()` (`:in_transaction`) before any query, then run in `Elzoo.TenantIsolation.transact/3` with the READ COMMITTED check; every statement passes `log: false`; a database failure is `:unavailable`. `refund/3` takes the payment row with `SELECT ... FOR UPDATE` before it sums the refunds, so two concurrent refunds are serialized. Amounts are stored as their `Codec.encode/2` bytes and compared with `domain/money` only.

`piece.json` declares telemetry and control `not_applicable`, the config of the binding, and the dependencies `state/tenant-isolation`, `delivery/effect-intent` and `domain/money`; the README states the provider Need's Contract (the attestation of `{:not_sent, _}`, the key rule, signature verification before parsing) for the later provider Piece, and the minimum grants of the application role.

## Kept open (owner's "no corner" rule)

The provider Need may gain callbacks and the payment, refund, event and result maps optional keys, and the state and error sets members, in place before the first release.

- *Authorize, capture and void* as members of the operation set (a two-step card flow).
- *Split settlement* to sub-accounts (the pruned row's preference); *disputes and chargebacks*; *multi-currency settlement*.
- *The provider Piece* `integration/payments` under a named provider (Q9 A, B or C), behind this provider Need.

## Acceptance

Tests run on the worker's disposable PostgreSQL 16 with a `DBConnection.ConnectionPool` Repo in random schemas dropped afterwards, with the ready `delivery/effect-intent` owner over a volatile Store acknowledged for the tests, and a scripted provider that records every call with its `idempotency_key`.

1. RC-24, timeout after charge: the scripted charge times out, `record/3` makes the payment `:unknown`, `poll/1` reports `succeeded`, and `record/3` makes it `:succeeded` with the compensation; the provider saw one charge.
2. A verified success event before any poll settles the row `:succeeded` with the compensation, while the intent's `status/1` still shows it dispatched; a later poll result is recorded and changes nothing.
3. A dispatch after a definite failure (a `{:not_sent, _}` send, then `:rearm` and `:dispatch`; and a poll `:no_effect`, then a new dispatch) carries the same `idempotency_key`, equal to the key of the first dispatch.
4. Two concurrent refunds behind a barrier (another connection holds the payment row lock until both are seen waiting in `pg_locks`) that together pass the amount: one is stored, the other is `:over_refund`. A pending and an unknown refund are held.
5. A duplicate event (`{:ok, :duplicate}`, no change), an out-of-order event (`failed` after `succeeded`, recorded with `applied: false`), an event of another amount (recorded, no change) and an event for an unknown payment.
6. An event that fails verification (`verify_event` refuses a changed body) changes nothing and stores nothing.
7. A changed approved amount, currency or recipient at `charge/3` is `:approval_mismatch` with nothing written and no intent admitted.
8. The compensation run twice is one refund; after a partial refund of 30 of 100, the compensation refunds 70; after a full refund it is `:nothing_to_refund`; a compensation whose refund fails leaves that refund `:failed`, with the payment `:succeeded`.
9. `create/3` and `refund/3` idempotency and conflict; `refund/3` of a payment that is not `:succeeded`; an explicit refund in another currency.
10. Row security as `elzoo_app` (ELZ-285): `verify/1` passes; another tenant's payment is `:unknown_payment` for every function; a direct insert of a T2 row into each table fails with SQLSTATE 42501; every function succeeds with only the README grants. A caller's open transaction gives `:in_transaction` before any query; a `repeatable read` Repo gets `:isolation`.
11. Negative controls, one at a time, each restored before the final gates: derive the idempotency key per Attempt (put the attempt number in the logical reference; case 3's second dispatch carries another key and the key-equality case fails); drop the payment row lock of `refund/3` (case 4 stores both); apply an event that is not a forward transition (case 5's out-of-order case changes the state).

Run the Piece tests and the new-Piece small gate locally (`mix check --piece "$(git merge-base origin/main HEAD)"`), the roadmap and claims checks and the diff check. The full independent review of the coordinator guide, the exact-head hosted check and the merge queue are required.

## Limits to state

No provider is named or exercised: the evidence is a scripted provider, so no claim about a provider's settlement, idempotency or event semantics; the ELZ-025 key rule must be checked against the named provider's documented idempotency in `integration/payments`. The approved terms, the approval reference, the provider Need's attestations and signature check, and the host's report of each intent's settlement are host Needs. A balanced ledger does not prove settlement. The `state/tenant-isolation` limits apply; READ COMMITTED is a consumer Need. No authorize/capture, split settlement, disputes or multi-currency settlement.
