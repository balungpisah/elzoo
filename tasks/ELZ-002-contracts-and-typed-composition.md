# ELZ-002 — Define contracts and the typed composition boundary

- Phase: P0 foundation
- Catalogue IDs: core/operator, core/port, core/assembly
- Dependencies: ELZ-001, ELZ-013, ELZ-014, ELZ-015, ELZ-016, ELZ-018

## Outcome

Define the smallest reusable interface for a pure Operator and its Ports so
compatible Pieces compose while an incompatible connection is rejected before
runtime execution within these two distinct checks: Cure compilation rejects
incompatible Cure-to-Cure function types; a language-neutral descriptor check
rejects incompatible declared Port schema ID/version and direction before
wiring execution, including descriptors for Elixir/OTP and Ash adapters.
Descriptor checks do not prove foreign implementations honor their declarations
or validate live payloads. Runtime payload/ABI validation belongs to each
Adapter (the first actual integration is ELZ-004). Arbitrary Elixir inference,
Ash action introspection, Gleam/JS FFI and remote schema negotiation are out of
scope. State ownership and unspecified behavior belong in the Contract.

The bootstrap already has generic `compose` and nested Cure operators with
typed negative controls owned by `pieces/core/operator/` and an exemplar in
`pieces/assembly/ingest-dedup-accumulate/`. Extend that working baseline into
the reusable Contract/Port boundary; do not recreate the harness or exemplar.

Read docs/capability-model.md and docs/capability-coverage.md before choosing
public contracts. Use the cross-domain cases to expose assumptions; do not add
all domain fields to a universal envelope or implement every deferred entry.
Keep Work Item/Run/Attempt identities, authority, delivery and state ownership
semantically distinct even when a library reuses a common representation.

Read ADR-0005 before implementation. Ash is the preferred application-framework
candidate; this task defines pure composition and must not invent a competing
resource/action/authorization framework or require Ash for pure source bundles.

Read docs/operational-contracts.md. Preserve operational applicability without
requiring effects, a process or runtime controls on pure composition Pieces.

## Scope

- choose the public data shape for state, input, output and port compatibility;
- place pure decisions in Cure and keep Effects out of this boundary;
- expose an Elixir-facing boundary only where runtime translation is required;
- add one legal composition and one incompatible typed connection;
- own Port descriptor identity/direction, payload schema ID/version and the
  pure transition/state/output-cardinality Contract; ELZ-003 alone owns delivery
  policy, Envelope fields and common delivery-result/error/deadline data shapes;
- expose those descriptors for reuse by ELZ-007, which alone owns candidate
  identity/ranking/selection metadata; do not define a second Port schema;
- preserve ready core/operator behavior under the new-ID Contract evolution
  rule in AGENTS.md; build new Port/Assembly behavior under their planned IDs.
  A changed operator Contract requires a separately named Piece, not replacement;
- follow the application-owned namespace policy in docs/consuming.md: one
  coordinated revision per module in a release, no automatic namespacing or
  record-tag isolation. Library distribution requires consumer-owned renaming
  of modules/MFAs and a deliberate decision about public record tags.

## Acceptance

- [ ] Interface and Contract are documented and have no hidden I/O.
- [ ] A legal connection checks and preserves declared types.
- [ ] The named incompatible connection is rejected by an executable negative
      control wired into mix check.
- [ ] Contract names state ownership and unspecified cases; delivery field ownership is explicitly deferred to ELZ-003.
- [ ] Both Cure-type and declared-descriptor positive/negative controls pass in
      mix check at this merge; later tasks must retain them in mix check.
- [ ] PR has a short public-interface section with the owned fields, both check
      scopes, erased-runtime boundary, namespace policy and compatibility limits.
      Independent review must accept that section before ELZ-003 starts.

## Evidence and limits

Use a selected type/compatibility proof only if Cure supports it cleanly; the
negative control is a test of this boundary. This does not prove arbitrary type
inference or external library behavior.

## Out of scope

No window policy, persistence, network Effect or complete catalogue migration.
