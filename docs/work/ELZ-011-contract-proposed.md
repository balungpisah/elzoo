# ELZ-011 — Integrate one representative external Effect

- Phase: P3 edge integration
- Catalogue IDs: core/effect, runtime/adapter, integration/http,
  integration/json, assembly/http-job boundary
- Dependencies: ELZ-004, ELZ-006, ELZ-010, ELZ-013, ELZ-023

## Outcome

Exercise one maintained Elixir/OTP or HTTP boundary with an explicit Adapter
and translate success, failure, timeout and cancellation into the flow's
declared result. Keep Cure pure and choose the library by executable comparison.

ELZ-013 already supplies a tested direct Req client recipe at
`pieces/integration/http/`. Reuse it; this task adds the actual application
Effect/job policy, limits and failure translation, not another HTTP client.

The selected Effect publishes one bounded JSON object under an immutable logical key at a consumer-controlled HTTP endpoint. Reuse delivery/effect-intent and integration/jobs; never call HTTP through assembly/durable-job's pure handler. Job retries inspect or poll the existing intent; only its durable permitted ground can authorize a later dispatch. This subset records only attested typed local no-send as a ground; final provider no-effect and provider replay are excluded. Every recovered intent remains read-only until the bound host grant required by its ready Contract. Cancellation stops future job wake-ups only and never retracts a dispatched request. Evidence is loopback/provider-double and real PostgreSQL/Oban composition, not a live vendor integration.

## Scope

- core/effect is a data-only declaration (capability_id, operation, classification) carried in an Envelope command. It reuses Envelope identity, schema and payload fields. It adds no executor, dispatcher or authorization.

- define request/result/error ports and the Unit's Needs;
- compare at least one realistic maintained candidate at the boundary and pin
  the selected version;
- provide deterministic test doubles plus integration checks;
- validate JSON/schema at the boundary and redact sensitive payloads from
  telemetry/logs;
- include idempotency/retry handling where an Effect can repeat;
- treat every message crossing the Adapter as untrusted input: never mint
  an atom from a wire string, drop undeclared fields from the provider
  payload (Envelope decoding itself still fails on unknown keys, per the
  ready core/envelope Contract), never upgrade an input's trust
  classification through normalization, and reject rather than guess a
  field that decides durability or acknowledgement; unknown provider
  kinds become opaque values rather than failures of the whole flow
  (ELZ-021 reference study).
- cite a second observed source for the wire-key atom-minting failure when
  writing the normalization test (ELZ-025 study, pluggy_ai key transform); no
  new Contract text.

## Acceptance

- [ ] No Cure Operator performs I/O; all Effects go through the Adapter.
- [ ] Success, expected failure, timeout/cancellation and retry behavior are
      executable.
- [ ] Candidate choice and upstream contract/version are recorded; the
      comparison is not replaced by a documentation link.
- [ ] mix check exercises the Adapter and negative controls.
- [ ] Contract limits the claim to the selected Effect and environment.
- [ ] Listed malformed inputs are rejected or made opaque without raising,
      and normalizing twice equals normalizing once (selected law or test).

- [ ] Every HTTP and transport outcome maps to a frozen Envelope or typed failure row;
      cancellation is job-control only and is never reported as no-send.
- [ ] No second dispatch occurs without a durable permitted ground; HTTP is never
      called from assembly/durable-job's handler.
- [ ] The total request time, response size bound and slow-drip stall are executable
      with negative controls; redirect, retry, atom-minting, trust-upgrade,
      field-retention and ack-guessing mutants of the real code fail.
- [ ] Read-only recovery, job exhaustion while Dispatched and the unique-key re-wake
      path are exercised with real PostgreSQL and Oban.

## Evidence and limits

Tests ground translation and listed failures. Upstream contracts ground the
library/runtime. No proof of external implementation is required or claimed.

## Out of scope

No catalogue of HTTP clients, deployment, secrets, native-code sandbox or
generic integration framework.
