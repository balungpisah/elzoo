# ELZ-002 — Define contracts and the typed composition boundary

- Phase: P0 foundation
- Catalogue IDs: core/operator, core/port, core/assembly
- Dependencies: ELZ-001, ELZ-013

## Outcome

Define the smallest reusable interface for a pure Operator and its Ports so
compatible Pieces compose while an incompatible connection is rejected before
runtime execution. State ownership, delivery metadata and unspecified behavior
in a Contract.

The bootstrap already has generic `compose` and nested Cure operators with
typed negative controls in `pieces/core/operator/` and `pieces/assembly/ingest-dedup-accumulate/`. Extend that working baseline into
the reusable Contract/Port boundary; do not recreate the harness or exemplar.

## Scope

- choose the public data shape for state, input, output and port compatibility;
- place pure decisions in Cure and keep Effects out of this boundary;
- expose an Elixir-facing boundary only where runtime translation is required;
- add one legal composition and one incompatible typed connection;
- make metadata sufficient for later deterministic reuse selection.

## Acceptance

- [ ] Interface and Contract are documented and have no hidden I/O.
- [ ] A legal connection checks and preserves declared types.
- [ ] The named incompatible connection is rejected by an executable negative
      control wired into mix check.
- [ ] Contract names ownership, delivery and unspecified cases.
- [ ] Positive and negative checks remain passing after the boundary is used by
      later tasks.

## Evidence and limits

Use a selected type/compatibility proof only if Cure supports it cleanly; the
negative control is a test of this boundary. This does not prove arbitrary type
inference or external library behavior.

## Out of scope

No window policy, persistence, network Effect or complete catalogue migration.
