# ELZ-104 — Assess RC-43 Relay and external-effect coverage

- Phase: reliability evidence closure
- Catalogue IDs: none; candidate:delivery/outbox-dispatch remains a candidate
- Dependencies: ELZ-033, ELZ-009, ELZ-010, ELZ-023, ELZ-011

## Outcome and scope

Assess RC-43 against accepted Contracts, source and executable evidence on current main. Publish a responsibility-to-evidence index for durable publication/claim/ack, duplicates, crash/restart, ambiguous external outcomes, retry, cancellation, fencing and caller responsibilities. Preserve RC-43's historical dependencies and distinguish Store atomicity, delivery and external settlement.

Owned paths: this task publication copy, docs/work/ELZ-104.md, docs/plans/release-plan.json and its generated views, and a scoped link/update in docs/plans/roadmap.md. The coordinator owns these shared edits. No runtime, provider, pin, ready manifest, registry or placeholder Piece changes. No dispatcher implementation, historical ELZ-041 or ELZ-044, or paid API calls.

## Acceptance

Read live dependency acceptance and actual current sources/tests. Link named executable scenarios for crash before dispatch, timeout after external acceptance, crash before ack, duplicate offers, cancellation and unknown reconciliation; explicitly identify missing composed evidence rather than infer a broader Contract. Existing accepted execution records may be reused with their revisions and limits; source inspection is not a fresh test run.

If accepted facilities cover the proposed responsibility, record a scoped reviewed index resolution. If a genuine gap remains, retain it explicitly with a concrete caller, missing invariant, prerequisites and acceptance scenarios for separate admission. Neither outcome promotes the candidate to ready or silently drops historical dependencies.

Independent review must inspect the actual evidence claims and corrected SHA. Dispose of every automated-review finding. Run documentation-class checkers (roadmap plain/live, claims, diff whitespace), regenerate views with scripts/check-roadmap.py --write, and adopt exact-head hosted evidence through the coordinator's serial merge queue. Verify main acceptance and clean up before issue closure.

## Grounding and limits

This is an evidence assessment, not new runtime verification. Separate selected Cure laws, actual type/schema checks, finite tests, observations and upstream/host assumptions. No general dispatcher, exactly-once effect, automatic recovered-owner authority, cross-stream discovery, liveness or provider integration follows from the index.
