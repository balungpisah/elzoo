# ELZ-392 — assembly/ledger-checkout: cover an existing payment with a different recipient

- Dependencies: ELZ-378
- Release: V2
- Output: no new Piece ID; add evidence and correct wording for #918.
- Change class: Piece-only tests and wording; no library code change.
- Owned paths: `pieces/assembly/ledger-checkout/test/elzoo/ledger_checkout_test.exs`, `pieces/assembly/ledger-checkout/README.md`, `pieces/assembly/ledger-checkout/piece.json`; its manifest hash and note in `docs/plans/release-plan.json` and generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`.

## Contract

Unchanged. Add the recipient case to case 5. The payment uses the checkout's payment ID and approved terms, with the same amount as the requested charge but a different recipient. The checkout does not adopt it. Add the README's existing rule to the manifest assumption grounding: the host binds a `grant_id` to its first `checkout_id` and refuses a grant of that ID for another checkout. Re-wrap the parallel-group bullet without changing its meaning.

## Acceptance

- Seed an already succeeded payment with the checkout's approved terms and approval ref. Ask the checkout for a different recipient but the same amount, keeping the approved fields unchanged so `PaymentLifecycle.create/3` finds a duplicate, not a conflict. `resume/3` returns `{:ok, %{state: :compensated, wait: nil}}`; the stored charge step failed with `:approval_mismatch` and no compensation. There is no new charge, refund or wallet post.
- On disposable PostgreSQL as the application role, extend the existing assertions and keep the amount and conflict cases. Negative control: temporarily compare only the amount in `same_terms?/2`; the recipient case must fail. Restore the comparison; no library diff remains.

Durable state, money and external effects: local small gate and full review. No new dependency.
