# Fork record: Cure (`balungpisah/cure-lang`)

Kept per [docs/development/08-upstream-and-forks.md](../../development/08-upstream-and-forks.md).

## Problem and owner

- Issue: [ELZ-047 (#84)](https://github.com/balungpisah/elzoo/issues/84), from the CI speed
  assessment of 2026-11-08, item 4, and the ELZ-038 investigation (#68).
- Failing scenario: `Cure.Elab.Program.user_source_path/1` at upstream `a004c335` globs, lexes and
  parses every `.cure` file under the source roots on every `use` import lookup. A 40-ID copied
  consumer did 474 lookups and 13,533 lexer calls in 82 s. Compiling the 25 owned Elzoo sources took
  82.3 s / 79.8 s without the fix and 13.2 s / 13.4 s with it (same laptop, upstream `main`, two
  samples each). Every copied consumer repeats this compile, 27 times per full CI run.
- Why no extension point: the scan is a private function with no option or hook; the existing
  `ModuleIndex` is not consulted on this path.
- Maintainer: the Elzoo CI/harness owner (the same role that owns `mix.lock`).

## Upstream

- URL: https://github.com/cure-lang/cure-lang
- Base revision consumed before this fork: `a004c335cc4e9f2203ba6f51fc31e8540b66378d` (release line v0.35.0).
- License: MIT, `LICENSE` at the repository root ("Copyright (c) 2026 Aleksei Matiushkin and the
  Cure contributors"). The fork keeps that file and every upstream notice unchanged. Elzoo does
  not relabel any Cure source as Apache-2.0.
- Upstream PR with the same change against `main`: fork branch `elzoo/user-source-index`
  (commit `da3c9379e`): https://github.com/cure-lang/cure-lang/pull/82. Full upstream suite on that branch: 6940 tests, 0 failures.

## Fork

- URL: https://github.com/balungpisah/cure-lang (GitHub fork, ancestry preserved, `upstream` =
  cure-lang/cure-lang).
- Consumed revision (immutable): `208248063d64e621782cd26dd30698ee42850a89` on branch
  `elzoo/pin-a004c335-user-source-index` = `a004c335` + exactly one commit (cherry-pick `-x` of
  `da3c9379e`).
- Patch summary (3 files, +164/−15): `lib/cure/elab/program.ex` — `user_source_path/1` answers from
  the process `ModuleIndex` when present, otherwise scans the roots but caches each file's declared
  module name by content digest (`:erlang.md5`) for one compilation; duplicate identities still
  reported; `lib/cure/compiler.ex` — `with_source_roots/3` drops that cache when the outermost
  compilation ends; `test/cure/elab/user_source_path_cache_test.exs` — 4 tests (edit between
  lookups seen; duplicate identity; index consulted first; cache dropped).
- No kernel, type checker, totality checker, codegen or stdlib change. Import resolution results
  are identical for identical inputs; only the number of parses differs.

## Consumers and records

- `mix.exs` `@cure_revision`, `mix.lock` `cure` entry, `registry/providers.json` `cure`
  (url, revision, reference) and every Piece manifest `upstream` reference now name the fork URL
  and revision. `mix elzoo.ledger --check` rejects drift between them.
- Every ready Piece with Cure sources consumes it (see `registry/catalogue.json`). Copied consumers
  receive the same `{:cure, git: <fork>, ref: <revision>, runtime: false}` line in their install
  instructions.

## Tests and responsibility

- Fork tests: `mix test test/cure/elab/user_source_path_cache_test.exs
  test/cure/elab/imported_module_dup_test.exs test/cure/elab/canonical_module_loader_test.exs`
  (12 tests) pass at `da3c9379e` on upstream `main`; the same at `208248063` is recorded on #84.
  `mix format --check-formatted` and `mix credo --strict` pass on the changed files.
- Elzoo: full `mix check` on the new pin (recorded on the ELZ-047 PR); selected Cure proofs are
  re-run by `mix check` on every run, so proof evidence is re-established on the fork, not
  inherited.
- Modified behavior is Elzoo's responsibility: import resolution caching. Known limit: the
  content-digest cache lives for one compilation in one process; an unreadable file is treated as
  declaring no module, as upstream does.
- Known incompatibilities: none observed.

## Monitoring and return

- Monitoring owner: the CI/harness owner watches upstream releases and the upstream PR monthly
  and on any Cure security notice.
- Return upstream when a tagged upstream release includes the fix (or an equivalent): move the pin
  to that release in its own reviewed task, re-run full checks, then retire this record's fork
  revision. Retire the fork if upstream rejects the change and a different fix lands upstream.
