# ELZ-023 — Specify dispatched-effect intent with unknown-outcome recovery

- Phase: demand-led delivery policy
- Catalogue IDs: delivery/effect-intent (new handle); consumes state/checkpoint
- Dependencies: ELZ-006, ELZ-009

## Outcome

Make "a timeout after dispatch is an unknown outcome" executable. Before an
irreversible external Effect is dispatched, its intent is checkpointed under
a key derived from the logical request; on resume the intent is found and
polled or reconciled instead of re-dispatched. The lifecycle is a pure state
machine; the store and the provider poll are Adapters.

## Admission record

1. **Responsibility and caller.** Own the lifecycle of one outward effect
   intent: `none → intended → dispatched → confirmed | failed_definite |
   stranded`, and decide whether dispatch may be (re-)armed. Callers: C3 refund/provider call,
   C6 publish Effect, C9 provider charge. The same shape serves a
   deterministic email or webhook sender.
2. **Interface and invariant.** Inputs: logical request identity, provider
   idempotency contract (present/absent), the core/envelope delivery result
   observed for an attempt (`outcome` × `dispatch` as fixed by the ready
   Contract: `completed/dispatched`, `rejected/not_dispatched`,
   `failed/dispatched`, `timed_out` or `unknown` with `dispatch` one of
   `not_dispatched`, `dispatched`, `unknown`), a poll or reconciliation
   result (`confirmed`, `pending`, `unknown_to_provider`, `failed`), and the
   deadline. Outputs: the next state plus one of `dispatch`, `poll`,
   `reconcile`, `stop`. State owner: one owner per derived intent key (the
   workflow Run or a dedicated intent owner) that serializes transitions;
   the ELZ-009 checkpoint store is its durability provider, not the owner.
   Invariant: `intended` is written before any send; the owner writes
   `dispatched` before the Adapter sends, so a crash between that write and
   the send is an unknown outcome resolved by `poll`, never by a second
   dispatch from `intended`; the first dispatch is not a re-arm;
   `rejected/not_dispatched` and `timed_out/not_dispatched` return to
   `intended`; `failed/dispatched` reaches `failed_definite` only when the
   provider confirmed that no effect happened (a provider idempotency
   contract is present, or a `reconcile` answered `failed`), because the
   ready delivery-result Contract allows partial external Effects under
   `failed`; otherwise `failed/dispatched`, `timed_out` and `unknown` with
   `dispatch` `dispatched` or `unknown` stay `dispatched` and require `poll`
   or `reconcile`; `failed_definite` is the only state out of `dispatched`
   that re-arms dispatch; a poll answering `unknown_to_provider` returns to
   `intended` only when a provider idempotency contract is present,
   otherwise it is `stranded`; a crash or deadline by itself never re-arms;
   the key is a function of the logical request, not a client-minted id;
   `stranded` is a terminal, visible outcome requiring reconciliation, not
   a retry.
3. **Reuse check.** Oban uniqueness and retry bound job execution, not the
   external effect's outcome; delivery/idempotency suppresses duplicate
   inbound deliveries only. Provider idempotency keys are reused when the
   provider offers them; this Piece owns the local intent record and the
   re-arm decision. A missing store is a hard error in a deployed release.
4. **Split test.** Checkpoint-before-dispatch and the re-arm decision share one
   invariant and stay behind one interface. Poll cadence, deadline policy and
   the provider Adapter are separate choices.
5. **Failure and evidence.** Dangerous paths: re-dispatch after timeout
   (double refund/publish); a crash between checkpoint and dispatch leaving an
   intent that was never sent (it is already `dispatched`; resume polls,
   and poll must distinguish `unknown_to_provider` from `pending`); a crash
   after the send but before any acknowledgement (same record, same poll
   path, never a second send); a `failed/dispatched` result with a partial
   effect re-sent as if definite; store unavailable at dispatch time.
   Proofs: the state-machine laws that the only transition out of
   `dispatched` that re-arms dispatch passes through `failed_definite`,
   that `failed_definite` is reachable only with provider confirmation of
   no effect, that `stranded` admits none, and that `unknown_to_provider`
   without a provider idempotency contract never reaches `dispatch`. Tests: crash/restart at each boundary with a provider
   double; webhook duplicate/out-of-order after confirmation. Upstream:
   provider idempotency and store durability are named contracts.
6. **Composition record.** Depends on ELZ-006 failure classes and deadlines,
   ELZ-009 checkpoint storage and core/envelope result schema. Ordering with
   the business state change (C3 payment lifecycle) is an outbox concern.
   Data classification: may carry payment references; redact in telemetry.

## Scope

- define the intent record, derived key and pure transition;
- define the store behaviour and a test double; bind to the ELZ-009 provider;
- select the no-re-arm law; test the listed crash/restart boundaries;
- document how a product reconciles `stranded` intents.

## Acceptance

- [ ] A simulated timeout after dispatch never re-dispatches without a definite
      failure or reconciliation result.
- [ ] Restart at each boundary resumes the existing intent by derived key.
- [ ] `stranded` is a distinct, tested outcome with a documented operator path.
- [ ] Selected law and scenarios run through mix check.
- [ ] Contract labels provider idempotency and store durability as upstream.

## Evidence and limits

The selected law grounds the re-arm rule; tests ground listed restart and
duplicate scenarios. No exactly-once external effect is claimed.

## Out of scope

No payment provider integration, outbox implementation or distributed lock.

## Reference

Shape observed in Raxol's payments checkpoint and `stranded` failure; see
docs/research/orchestration-references.md. No code is copied.
