# ELZ-052 — Emit one bounded, redacted telemetry event family from the ready job and effect Adapters

- Phase: demand-led runtime observation
- Catalogue IDs: runtime/telemetry
- Dependencies: ELZ-010, ELZ-011

## Outcome

Make the existing `assembly/durable-job` and `assembly/http-job` Adapters observable through
one declared family of `telemetry` events with fixed names, declared measurement units and a
metadata allowlist, so that an operator can attach handlers or an exporter without reading
code. Adopt the pinned `telemetry` library already in `mix.lock`; author only the event
schema, the redaction allowlist and the emission points. No audit record, usage meter,
billing input or control receipt is created. This is the first task of the owner's batch
(decision record: `docs/plans/catalogue-dispositions.md#runtime-telemetry`).

## Admission record

1. **Responsibility and caller.** Own the event family `[:elzoo, :effect | :job, :start |
   :stop | :exception]` with its measurements and metadata contract. Callers: the ELZ-010
   job worker and Relay (`integration/jobs`) and the ELZ-011 HTTP job Adapter
   (`assembly/http-job`) emit at dispatch, completion and failure; C2 report runs and C7
   scheduled runs need these observations; C6 agent runs will reuse the family.
2. **Interface and invariant.** Inputs: an emission point in an Adapter with the operation
   identity it already holds (tenant, Adapter ID, operation kind, logical request
   reference, attempt) and a measurement (`duration` in native time units converted to
   microseconds, `queue_wait`, `payload_bytes` as integers). Outputs: `:telemetry.execute/3`
   calls with the documented event names and a metadata map containing only allowlisted keys
   with bounded value sizes. Invariants: event names and units are fixed and listed in the
   README; metadata passes an allowlist and never contains payload bytes, credentials,
   URLs with credentials, or free-form error messages (errors are reduced to a declared
   reason atom); handlers are synchronous, may be absent, and a handler failure never
   changes the Adapter's result; an event is an observation that may be missing. Non-goals:
   metrics aggregation, export, tracing, persistence, audit, metering.
3. **Reuse check.** `telemetry` 1.4.2 (Apache-2.0) is pinned transitively through Oban,
   Ecto and Req; it becomes a direct dependency with the same version. `telemetry_metrics`
   is not added unless a consumer needs metric definitions. Elzoo owns only the schema and
   the allowlist; a thin wrapper around `:telemetry.execute/3` earns no slot by itself, so
   the Piece is the schema module, the redaction function and its tests.
4. **Split test.** Emission belongs with the Adapter that holds the identity; the schema and
   allowlist are one shared module so two Adapters cannot drift. Export and aggregation are
   separate provider choices (`integration/observability`, planned).
5. **Failure and evidence.** Dangerous paths: a secret or payload byte in metadata; a
   handler that raises or blocks changing an Adapter result; an event name typo splitting
   a series; a unit mismatch between Adapters. Proofs: none required; the allowlist and
   unit table are finite data. Type/contract check: the schema module validates metadata
   against the allowlist at emission in test and dev environments. Tests: each emission
   point fires the documented event with the documented keys; a credential-shaped and a
   payload-shaped value are rejected or redacted; a raising handler and a slow handler do not
   change the Adapter result; a missing handler is silent; the full `mix check` still passes
   with the Adapters instrumented. Upstream: `telemetry`'s synchronous dispatch and
   handler-detach-on-failure behavior is named, not proved.
6. **Composition record.** Consumed by operators of every Assembly on the owner's host;
   `integration/observability` later attaches an exporter. Declared Telemetry applicability of `assembly/durable-job` moves from `planned` to `supported` with test references; `assembly/http-job` stays `supported` and its Telemetry contract and evidence are extended to the event family; Config `supported` for the allowlist only if it is configurable,
   otherwise `not_applicable`; Control `not_applicable`. No delivery or durability claim.

## Scope

- add `pieces/runtime/telemetry/` with the schema module, the redaction allowlist, README,
  `piece.json` and tests;
- add the emission points to the ELZ-010 and ELZ-011 Adapters without changing their
  results or their existing tests' assertions (new tests may be added);
- make `telemetry` a direct dependency at the already-locked version and record it in
  `registry/providers.json`; update the two Adapters' operational applicability;
- promote `runtime/telemetry` in its own catalogue row and release-plan entry, regenerate
  `LEDGER.md` and the roadmap views.

## Acceptance

- [ ] Each documented event fires at its documented emission point with the documented keys and units: job events at the durable-job worker, durable-job Relay, and http-job runner; effect events only at the http-job Adapter.
- [ ] Credential-shaped and payload-shaped metadata is redacted or rejected, with tests.
- [ ] A raising handler and a slow handler leave the Adapter result unchanged.
- [ ] Operational applicability is declared per docs/operational-contracts.md for the new
      Piece and updated for the two Adapters.
- [ ] Full `mix setup` and `mix check` pass at the PR head on the pinned toolchain.

## Evidence and limits

Finite tests over listed scenarios; upstream contract of `telemetry` 1.4.2; no proof is
claimed. Observations are not audit, metering or control; missing observations are
possible. No exporter, dashboard or SLO is delivered.

## Out of scope

OpenTelemetry export, metrics aggregation, tracing, log formatting, audit log, metering.

## Reference

Decision record `runtime/telemetry` (ADOPT; owner answer 1 and product fact 8);
ranking R03; awesome-elixir report rows `telemetry`, `telemetry_metrics`.
