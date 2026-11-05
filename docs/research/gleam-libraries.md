# Gleam library reuse: ELZ-017

**Decision: conditional go for Lustre as an optional browser-component choice;
defer ready catalogue promotion.** The isolated
[quantity-component experiment](../../spikes/gleam_ui/README.md) demonstrates
reuse in a plain HTML host and a pure model tested on BEAM and JavaScript.
It does not justify replacing Cure/Elixir/Ash or imposing another toolchain on
backend consumers. Telemetry / Config / Control contracts are a separate
architecture concern; this evaluation neither implements nor requires them.

## Pinned candidates, checked 2026-11-05

| Library | Source / license | Target and distinctive value | Evidence and decision |
| --- | --- | --- | --- |
| Lustre 5.7.1 | [Hex release](https://hex.pm/packages/lustre/5.7.1), MIT; checksum in spike manifest | Browser JS components; upstream also provides BEAM HTML/server-component facilities. Elm-style model/update/view. | Installed upstream, compiled both targets; browser registration and host interaction exercised on Chromium. Optional go for embedded/browser-local UI; server components/LiveView integration not evaluated. |
| Nibble 1.1.4 | [source cd49760](https://github.com/hayleigh-dot-dev/nibble/tree/cd49760e24305c6be7ea8931129b86f1c4670207), MIT | Upstream describes a pure Gleam lexer/parser for BEAM and JS. One actual shared grammar could support browser feedback and authoritative backend parsing. | Source/package research only, not installed. Defer until a real grammar needs two targets. Its stdlib requirement is >=0.62 and <1.0, incompatible with this experiment's exact 1.0.5 pin; do not claim drop-in compatibility. |
| Squirrel 4.7.0 | [source d4c0f54](https://github.com/giacomocavalieri/squirrel/tree/d4c0f54b66d698c9be757af5fff6925462726bd1), Apache-2.0 | PostgreSQL query inspection generates Gleam functions/decoders using `pog`; documented backend/BEAM route, not a browser database layer. | Source/package research only; no DB connection, generated-query or target-compatibility test. Lower priority until a concrete Gleam SQL workload earns the boundary. |

Candidate release checksums from the Hex release API:

- Nibble: `06397501730ff486ae6f99299982a33f5ea9f8945b5a25920c82c8f924cea481`.
- Squirrel: `dd7d42f5efe5e0ff597cf6d8e770c6327a7b10589bfcd3144edc852ae2f6f0de`.
- Lustre: `663a2d1a3458914ca537a42ac07e601dd3fd85415ebdaf4717f2dff6e86f90f9`.

Nibble's README advertises target portability; that is an upstream claim, not
our integration evidence. Its backend-only alternative can remain NimbleParsec
where sharing source adds no value. Squirrel requires database access during
generation and matching schema/runtime decoders; its pinned README maps
PostgreSQL `numeric` to Gleam `Float`, which is not an exact-decimal money
contract. Ash/Ecto or existing SQL tooling remain candidates for Elixir needs.
No benchmark or superiority claim is made for any library.

## What the experiment establishes

The shared pure model is handwritten Gleam. Lustre supplies component runtime,
DOM/event mechanics and shadow DOM; we use upstream APIs directly. The model's
three finite tests pass on each target. A separate plain-HTML host loads the
packaged ES modules and exercises independent instances, validated attributes,
bounded updates, event payloads, keyboard activation and form isolation. None
of this establishes arbitrary framework composition or backend authorization.

Gleam's compiler checks the owned model/view/update types. The browser boundary
still accepts strings and emits runtime JSON, so it needs validation and host
checks. Gleam [foreign declarations](https://tour.gleam.run/advanced-features/externals/)
trust declared types; a Gleam type is not automatically an Elixir/Cure proof.
We did not implement or verify such an FFI bridge. The BEAM test does not invoke
browser registration (Lustre reports `NotABrowser` outside a browser).

The experiment pins Gleam 1.19.2, stdlib 1.0.5, gleam_json 3.1.0, gleeunit 1.11.0,
Node 24.16.0 and Playwright 1.64.1, plus transitive packages in `manifest.toml`
and `package-lock.json`. The verified compiler installer and separate CI job
make the additional build cost visible. Root Mix checks remain unchanged.
The [work report](../work/ELZ-017.md) records commands and bounded results.

## Adoption boundary

Lustre earns evaluation for independently embedded UI with browser-local
interaction, especially when its pure logic is also needed on BEAM. Prefer the
host application's existing UI approach where this distinct value is absent.
This is not a recommendation to migrate existing UI or to prescribe an Elzoo
frontend framework.

The ledger's `ui/component` remains deferred. It links this evidence rather
than claiming a ready source bundle. Before promotion, select a real consumer,
version the DOM interface, support language assets in source export/provenance,
and test that consumer's lifecycle, themes, accessibility and browser needs.
The current unoptimized module directory (~1 MB) is a packaging demonstration,
not a bundle-size/performance result. No automatic build task for Nibble or
Squirrel follows from listing them.

Use upstream releases. All three licenses permit reuse/forking under their own
terms, but no modification need arose, so no fork was created. Future modified
forks follow [the upstream policy](../development/08-upstream-and-forks.md).

## Lessons

- A shared language does not erase DOM/FFI/JSON validation boundaries.
- Check candidate dependency ranges before promising shared-package reuse:
  Nibble's current stdlib cap differs from this Lustre experiment's pin.
- Package licenses and module paths are part of the consumption check. Upstream
  package metadata may declare a license without shipping a standalone text.
