# ELZ-054 — Specify the email notification Adapter with one SMTP provider through Swoosh

- Phase: demand-led integration Adapter
- Catalogue IDs: integration/notification
- Dependencies: ELZ-011, ELZ-023

## Outcome

Own an Adapter that dispatches one email through Swoosh's SMTP transport and translates
the provider's response into accepted, refused or unknown, with a dispatch identity that is
stable across retries. Adopt `swoosh` 1.29.3 (MIT) with its SMTP adapter and the transport
it requires; Bamboo stays an alternative and Pigeon is admitted only when a push caller
exists. Provider acceptance is not inbox delivery. This is the third task of the owner's
batch (decision record: `docs/plans/catalogue-dispositions.md#integration-notification`;
owner answer 4).

## Admission record

1. **Responsibility and caller.** Translate a notification request to one SMTP dispatch
   and the response to a typed outcome. Callers: C1 invitation email (membership, deferred,
   is the business caller; the Adapter is tested with a fixture request), C5 task notices,
   C7 digest delivery.
2. **Interface and invariant.** Inputs: a dispatch identity (tenant, logical request
   reference, attempt), sender identity from configuration, recipients, subject, text body
   and optional HTML body with bounded sizes, a deadline; the ELZ-011 Effect declaration and
   the ELZ-023 intent record. Outputs: `accepted{provider_id}`, `refused{invalid_address |
   rejected_recipient | too_large | throttled | authentication_failed |
   credentials_unavailable | connect_failed}` (the last two are attested no-send outcomes
   before any transaction command), `unknown{reason}` when the connection was lost after
   the message was handed over or the Adapter cannot safely classify a transaction-stage
   provider response into a listed refusal, mapped to the ELZ-011
   delivery result. Invariants: the same dispatch identity never produces a second send
   without an explicit reconciliation decision; an accepted provider ID is recorded as
   acceptance, not delivery; a lost connection after `DATA` is `unknown`, never `refused`;
   bodies and recipients never appear in logs or events; credentials never leave the Adapter.
   Non-goals: templates, inbox delivery or receipt tracking, bounce processing, push or
   SMS, deduplication policy (the caller's), content redaction policy (the caller's).
3. **Reuse check.** `swoosh` 1.29.3 supplies composition and the SMTP transport; Elzoo owns
   the outcome mapping, the unknown-outcome rule and the binding to the Effect and intent
   boundaries. Bamboo is comparable but not adopted by default; no second email framework.
4. **Split test.** Request translation and outcome classification stay together; intent,
   retry policy and dedup live in the ready `delivery/effect-intent` and `delivery/*`
   Pieces and are used, not redefined.
5. **Failure and evidence.** Dangerous paths: a blind resend after an unknown outcome; a
   lost connection reported as refused; an invalid address accepted; throttling retried
   without backoff; credentials or recipients in a log line. Proofs: none required.
   Tests against an in-process SMTP test server started by the test suite (for example the
   server behaviour of `gen_smtp` as a pinned, recorded test-only dependency), so CI needs no
   new service; if an in-process server proves unworkable, fall back to a CI provisioning
   item under ELZ-064 and say so in the PR. Scenarios: accepted path with provider ID; invalid address; rejected
   recipient; too-large body refused before dispatch; authentication failure; throttling
   response; connection dropped after `DATA` reported unknown; the same identity dispatched
   twice without a reconciliation decision is refused by the intent boundary; redaction in
   logs and telemetry. Upstream: SMTP semantics and Swoosh's adapter behavior are named,
   not proved.
6. **Composition record.** Depends on `core/effect`, `delivery/effect-intent` (ready);
   `integration/secrets` is deferred, so SMTP credentials are an explicit injected Need
   reviewed in this Contract, as the record's disagreement note states. Telemetry
   `inherited` from the ELZ-052 family if merged first, otherwise `planned`; Config
   `supported` for host, port, sender, size bounds and deadline; Control `not_applicable`.
   No delivery guarantee.

## Scope

- add `pieces/integration/notification/` with the Adapter, outcome schema, README,
  `piece.json` and tests that start an in-process SMTP test server (pinned test-only
  dependency recorded with its license); `ELZOO_TEST_SMTP_URL` is then unnecessary, or
  points at that server; fall back to CI provisioning under ELZ-064 only if the in-process
  server proves unworkable, and record that choice;
- add `swoosh` 1.29.3 and the SMTP transport dependency it requires at pinned versions,
  recorded in `registry/providers.json` with licenses;
- promote `integration/notification` in its own catalogue row and release-plan entry,
  regenerate `LEDGER.md` and the roadmap views.

## Acceptance

- [ ] Accepted, invalid-address, rejected-recipient, too-large, authentication, throttling
      and dropped-connection scenarios pass against the in-process SMTP test server.
- [ ] A lost connection after handover is reported `unknown`; a second dispatch of the same
      identity without reconciliation is refused.
- [ ] No credential, recipient or body appears in logs or telemetry metadata, with a test.
- [ ] Operational applicability is declared per docs/operational-contracts.md.
- [ ] Full `mix setup` and `mix check` pass at the PR head on the pinned toolchain.

## Evidence and limits

Finite tests against a local SMTP test server; upstream contracts for SMTP and Swoosh; no
proof is claimed. No inbox delivery, bounce handling, receipt, templates or a second
provider.

## Out of scope

Push and SMS, templates, bounce processing, dedup and redaction policy, a hosted email
provider.

## Reference

Decision record `integration/notification` (ADOPT; owner answer 4); ranking R20;
awesome-elixir report rows `swoosh`, `bamboo`, `pigeon`; disagreement note on the
`integration/secrets` prerequisite.
