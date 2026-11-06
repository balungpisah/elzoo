# ELZ-011 — Integrate one representative external Effect

- Phase: P3 edge integration
- Catalogue IDs: core/effect, runtime/adapter, integration/http,
  integration/json, assembly/http-job boundary
- Dependencies: ELZ-004, ELZ-006, ELZ-010

## Outcome

Exercise one maintained Elixir/OTP or HTTP boundary with an explicit Adapter
and translate success, failure, timeout and cancellation into the flow's
declared result. Keep Cure pure and choose the library by executable comparison.

ELZ-013 already supplies a tested direct Req client recipe at
`pieces/integration/http/`. Reuse it; this task adds the actual application
Effect/job policy, limits and failure translation, not another HTTP client.

## Scope

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

## Evidence and limits

Tests ground translation and listed failures. Upstream contracts ground the
library/runtime. No proof of external implementation is required or claimed.

## Out of scope

No catalogue of HTTP clients, deployment, secrets, native-code sandbox or
generic integration framework.
