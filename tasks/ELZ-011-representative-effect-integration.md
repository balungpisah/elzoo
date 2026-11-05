# ELZ-011 — Integrate one representative external Effect

- Phase: P3 edge integration
- Catalogue IDs: core/effect, runtime/adapter, integration/http,
  integration/json, assembly/http-job boundary
- Dependencies: ELZ-004, ELZ-006, ELZ-010

## Outcome

Exercise one maintained Elixir/OTP or HTTP boundary with an explicit Adapter
and translate success, failure, timeout and cancellation into the flow's
declared result. Keep Cure pure and choose the library by executable comparison.

## Scope

- define request/result/error ports and the Unit's Needs;
- compare at least one realistic maintained candidate at the boundary and pin
  the selected version;
- provide deterministic test doubles plus integration checks;
- validate JSON/schema at the boundary and redact sensitive payloads from
  telemetry/logs;
- include idempotency/retry handling where an Effect can repeat.

## Acceptance

- [ ] No Cure Operator performs I/O; all Effects go through the Adapter.
- [ ] Success, expected failure, timeout/cancellation and retry behavior are
      executable.
- [ ] Candidate choice and upstream contract/version are recorded; the
      comparison is not replaced by a documentation link.
- [ ] mix check exercises the Adapter and negative controls.
- [ ] Contract limits the claim to the selected Effect and environment.

## Evidence and limits

Tests ground translation and listed failures. Upstream contracts ground the
library/runtime. No proof of external implementation is required or claimed.

## Out of scope

No catalogue of HTTP clients, deployment, secrets, native-code sandbox or
generic integration framework.
