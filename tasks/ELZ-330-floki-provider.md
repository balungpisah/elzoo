# ELZ-330 — Pin floki 0.38.5 as a direct dependency

- Dependencies: none

## Outcome and scope

Wave 7 Level 1 provider prerequisite
([bot-platform-wave7.md](../docs/plans/bot-platform-wave7.md), "Provider
prerequisite: adopt `floki`"). The owner answered Q1 with A on 2026-11-22:
`integration/document-parse` reads plain text, Markdown and HTML, and HTML
through `floki`; PDF is later. This task makes `floki` a direct, pinned
dependency of the root project and records it as a provider, so that the
document-parse task can name it. It builds no Piece and no Elzoo API.

This is a coordinator one-PR change of a root dependency (`AGENTS.md`
section 1). Owned paths:

- `mix.exs` (one entry in `deps/0`, with its comment);
- `registry/providers.json` (one provider row);
- `docs/dependencies.md` (one row in "Direct dependencies of `mix.exs`");
- this task file, its no-output job row in `docs/plans/release-plan.json`,
  and the generated `LEDGER.md`, `docs/plans/views.md` and
  `docs/plans/dependencies.mmd`.

No Piece, `lib/`, `config/`, `test/`, `scripts/`, CI workflow, `.agents/setup`,
catalogue or `entries` change. No other dependency, pin or toolchain change.

Facts checked on 2026-11-22 on `main` `75202491`:

- `mix.lock` already locks `floki` 0.38.5 (outer checksum
  `c8c5b04455f01b076cd489fee7dc26b49edf9851ef61146e743f4676114bf6b0`, no
  requirements), only as a transitive dependency: `md` 0.12.2, a dependency
  of `cure`, requires `floki ~> 0.33`. It is not in `mix.exs` or
  `registry/providers.json`, no `config/` file sets `:floki`, and no Piece
  names it.
- On hex.pm, 0.38.5 is the latest stable `floki` release (2026-10-29), not
  retired, with the same checksum and no requirements; the package license
  is MIT, as are the package metadata and the `LICENSE` file of the locked
  source.
- `floki`'s application has no supervision tree (`extra_applications:
  [:logger]` only). It chooses its HTML parser from the application
  environment (`:floki, :html_parser`); unset, it uses its bundled
  pure-Erlang mochiweb parser.
- `mix.exs` pins each Hex dependency exactly, for example
  `{:crontab, "== 1.2.1"}`. A Hex provider row has `source` `hex`,
  `package`, `version`, `reference` and `license`, and
  `Elzoo.Registry.load!/1` checks the version against the `mix.lock` entry.

## Required change

1. Add `{:floki, "== 0.38.5"}` to `deps/0` of `mix.exs`, after the last
   entry, with a short comment that names this task, the license, the
   transitive lock and its later caller.
2. Add the provider `floki` to `registry/providers.json` in the existing Hex
   shape: `source` `hex`, `package` `floki`, `version` `0.38.5`, `reference`
   `https://hexdocs.pm/floki/0.38.5/Floki.html`, `license` `MIT`. No
   `runtime`, `compile` or `app` key.
3. Add one row for `floki` to the table "Direct dependencies of `mix.exs`" of
   `docs/dependencies.md`, in `mix.exs` order; "Used by" says that no Piece
   uses it yet and names the planned `integration/document-parse`.
4. `mix.lock` does not change. If `mix deps.get` changes it, stop and report.
   Add no `config :floki`.

## Acceptance

- `mix.lock` is byte-equal to the one on the base; `mix deps.get` leaves it
  unchanged.
- `mix deps.tree` shows `floki 0.38.5` as a direct dependency of `elzoo`.
- `Elzoo.Registry.load!/1` accepts the provider row (its version equals the
  lock), and `mix elzoo.ledger` and `python3 scripts/check-roadmap.py` pass.
- `mix check` with no flag passes locally on a disposable PostgreSQL 16 with
  pgvector, with `ELZOO_TEST_APP_ROLE=elzoo_app`; `git diff --check` passes.
- The exact-head full hosted check is green.

## Evidence, Needs and Limits

Upstream: `floki` 0.38.5 at its pinned version; no behavior of it is claimed
here. The document-parse task records the behavior it relies on. Test: none
new; the change adds no behavior. Needs: Hex access during `mix setup`.
Limits: this task pins and declares a dependency only. It is not adoption
in the sense of `docs/dependencies.md`: no Elzoo runtime check exercises
`floki` yet. The document-parse task adds the check of the API and the
failure path that it relies on, and that completes the adoption. This task
makes no claim that `floki` is safe for hostile HTML, adds no parser, reader
or wrapper, and promotes no Piece. Telemetry, Config and Control are not
applicable.
