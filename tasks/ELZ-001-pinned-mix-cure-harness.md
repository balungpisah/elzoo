# ELZ-001 — Pin and exercise the Mix/Cure harness

- Phase: P0 foundation
- Catalogue ID: core/grounding
- Dependencies: none
- Suggested owner: runtime

## Outcome

Provide one Mix application that can be set up from a clean checkout and
compiles the real Cure source at the exact project pin. The public commands are
mix setup and mix check.

## Scope

- pin Cure commit a004c335cc4e9f2203ba6f51fc31e8540b66378d (Cure v0.35.0;
  never use a bare same-named tag or branch);
- pin/document Elixir 1.20.4 and OTP 29.1.2;
- make setup reproducible without the old Zoo checkout;
- make mix check compile Cure, run a selected proof/check path and provide
  places for runtime and negative-control tests;
- record environment and the ELZOO CHECK PASSED marker.

## Acceptance

- [ ] In a clean checkout, mix setup succeeds with the pinned toolchain.
- [ ] mix check compiles real Cure at the exact SHA and exits non-zero on a
      deliberately broken check fixture.
- [ ] mix check is not only formatting/documentation lint and has a
      deterministic success marker.
- [ ] A clean clone can run the commands using only documented inputs.

## Evidence and limits

Record command output and version reports. This task proves the harness can
exercise selected checks; it does not prove a future Piece or all Cure
behavior. Runtime owns external implementation assumptions.

## Out of scope

No catalogue family, durable storage, OTP product flow or old Zoo CLI.
