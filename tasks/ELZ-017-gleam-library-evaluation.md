# ELZ-017 — Evaluate Gleam library reuse independently

- Phase: P0 independent library evaluation
- Dependencies: ELZ-014

## Outcome

Evaluate Gleam's distinctive reuse value, independently of telemetry/config/control
and without replacing the Ash/Cure/Elixir backend foundation.

## Scope and acceptance

- [ ] Record pinned source/package findings for Lustre, Nibble and Squirrel, target support, licenses, boundary costs and adoption status.
- [ ] Build an isolated Lustre reusable Web Component with a small domain-neutral UI example and no runtime control API dependency.
- [ ] Pin compiler/package tooling, provide reproducible setup/check commands, compile JavaScript and exercise component behavior and host integration in meaningful automated tests.
- [ ] Verify the example's pure shared model on JavaScript and BEAM where supported; distinguish shared model claims from browser-only effects and foreign boundaries.
- [ ] State consumer packaging limits and return a go/defer recommendation based on evidence. No ready source export or fork is claimed without checking that exact boundary.
- [ ] Run the existing mix check plus the independent Gleam check, obtain independent review and Linux CI, then integrate/clean up.

Nibble remains a candidate for a concrete shared parser; Squirrel remains a lower-priority
candidate for a concrete Gleam SQL need. No speculative parser/pricing engine or database layer.
