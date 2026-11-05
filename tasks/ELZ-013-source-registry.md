# ELZ-013 — Make pieces independently consumable with a checked provenance ledger

- Phase: P0 distribution foundation
- Dependencies: ELZ-001
- User-directed architecture refinement; precedes further shared-interface work.

## Outcome

Developers take selected source pieces into their own Mix project, inspect the
implementation/library provenance and claim-level grounding, and compose there.
Retain Zoo's operator/unit/assembly idea without requiring the Elzoo host.

## Scope

- piece-local source, contracts, examples and evidence metadata;
- a machine-readable ledger for every catalogue ID, distinguishing ready,
  planned and deferred entries and own/adapter/upstream implementation;
- selective source export with dependency closure, provenance/checksums,
  dependency instructions, safe conflict handling and no mandatory runtime;
- exercise direct OTP/Enum/Stream/Jason reuse and one narrow Req HTTP recipe;
- preserve the current sample's selected Cure proofs, types and OTP scenarios;
- validate ledger consistency in mix check; generate the human ledger;
- document copying/customization, updates and limits; align autonomous tasks.

## Acceptance

- [ ] A developer can inspect origins, dependencies, evidence and limits per ID.
- [ ] Ready entries have real files and executable evidence; unimplemented IDs
      are visible but cannot be exported as implemented.
- [ ] A minimal source bundle builds/runs in a separate project without an
      Elzoo dependency or access to its checkout.
- [ ] Export resolves transitive pieces/packages, preserves provenance, and
      refuses conflicting writes before changing a target.
- [ ] Direct library recipes are locked and tested without replacing upstream
      implementations with wrapper-only modules.
- [ ] mix check, negative controls and independent review pass; PR merged.

## Limits

No public hosting/service, remote package resolver, silent updates to copied
code, licensing grant invented for upstream code, blanket proof badge, or
implementation of every planned catalogue capability. ELZ-002/003 still own
named/versioned port contracts; later assemblies retain their own scope.
