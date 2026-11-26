# ELZ-416 — Every pin to its latest stable release

- Dependencies: ELZ-415

## Outcome and scope

Owner decision of 2026-11-26: there is no consumer yet, so each pinned version
of the root moves to its latest stable release. Versions checked on
2026-11-26:

| Pin | Now | Target |
| --- | --- | --- |
| OTP | 29.1.2 | 29.1.3 |
| Elixir | 1.20.4 | 1.20.5 |
| PostgreSQL (CI service image and `.agents/setup`) | 16 | 19. The CI image keeps pgvector 0.8.7; `.agents/setup` installs the pgvector package for the selected server major |
| MinIO | `RELEASE.2025-09-07T16-13-09Z` | Unchanged: the last release, `RELEASE.2025-10-15T17-29-55Z`, has no binary asset, and upstream is archived |
| Cure | the pinned fork commit `20824806`, which adds the source-import fix to `v0.35.0` | Unchanged, unless upstream has a newer release tag |
| Lua source (`lua_source`) | PUC Lua 5.4.9, revision `312b9efa` | Unchanged here: `runtime/lua-sandbox` states Lua 5.4.9 and checks the pinned revision and its exact source bytes; ELZ-426 moves it to 5.5.1 |
| GitHub Actions of `symbolic-check.yml` | pinned SHAs | The latest release of each, pinned by full SHA with its version comment |
| Hex packages | `mix.lock` | The newest release that the dependency graph allows |

Paths: `.tool-versions`, `mix.exs`, `mix.lock`, `registry/providers.json`,
`.github/workflows/symbolic-check.yml`, `.agents/setup`, `AGENTS.md` (the
PostgreSQL version that section 5 names), the generated `LEDGER.md`, and each
document outside `docs/plans/`, `docs/work/` and `tasks/` that names a changed
version as the current one. Also the changes that a new version forces, each
named in the pull request:

- `state/lease`: since PostgreSQL 18 the catalog keeps each NOT NULL column as
  a constraint row, which its Store schema check refuses. On a server of
  version 18 or later the check accepts exactly one such row for each NOT NULL
  column of each tracked table, with definition `NOT NULL <column>` and the
  name that PostgreSQL generates (`<table>_<column>_not_null`, with the
  numeric suffix it appends when that name is taken in the schema). It still
  fails closed on every other difference.
- The Pieces whose `contract`, `limits` or README state PostgreSQL 16, or a
  moved provider version (req_llm, llm_db, telemetry, OTP), state the new
  version. Their tests that pin the server major move to 19.
- A new version may change what a Piece accepts or returns (for example a
  newer model catalogue admits more models). The package still moves to its
  latest release, as the rule of ELZ-415 allows: the Piece states the new
  behavior where its `contract` or `limits` enumerate it, its README
  `## Changes` entry names the change, and a test pins it.
- Each Piece whose `contract`, `limits`, README or module documentation
  changes in this task gets an ELZ-416 entry in its README `## Changes`
  section, and each changed `piece.json` a new `manifest_sha256` in its
  `entries` row, with `note` equal to a changed `contract`. A Piece whose only
  change is its provider version in `registry/providers.json` gets no entry.
- README sentences and `registry/catalogue.json` summaries that present a
  moved pin as current; the manifest entries in `docs/plans/release-plan.json`
  and the regenerated `docs/plans/views.md`. Shared implementation paths:
  `lib/elzoo/export.ex` (the export's toolchain text),
  `test/fixtures/install/integration-cure-json.txt` (its byte fixture),
  `test/examples/elz099_provider_consumer/mix.exs`,
  `test/wave7_remember_and_know_test.exs`, `test/wave8_bots_talk_test.exs`,
  `test/wave9_tools_doors_models_money_test.exs`,
  `scripts/check-ci-runners.py` and `scripts/test-ci-runners.py` (they mirror
  the workflow), and `scripts/worker-services.py` and
  `scripts/test-worker-services.py` (PostgreSQL 18+ images keep their data
  under `/var/lib/postgresql`).
- `spikes/ash_foundation/mix.exs` and one README line: its exact Elixir
  requirement would refuse the new toolchain. Its own dependency pins move in
  ELZ-424.

Upstream grounding claims, reference URLs and dated observations keep the
versions their evidence cited when it was recorded. A statement about the
current test suite (the server it runs on now) states PostgreSQL 19.

- Each direct `==` pin in `mix.exs` moves to its latest release. A `~>`
  requirement is widened only where the latest release is outside it. Then
  `mix deps.update --all`.
- The pull request lists each package that cannot reach its latest release,
  with the package whose requirement holds it (`mix hex.outdated --all`).
- `registry/providers.json` records each changed registered provider;
  `mix.lock` records the complete resolved dependency graph. `mix elzoo.ledger`
  regenerates `LEDGER.md`.
- A code change that a new version forces is allowed, and the pull request
  names it file by file.
- `symbolic-gleam.yml` and the Gleam spike move in ELZ-425.

This is a coordinator-owned task, release V2, stage `later`. It changes Piece
Contract texts, so it is published before its implementation merges (not the
one-PR path of `AGENTS.md` section 1). It merges before each later task that
builds on the root (`AGENTS.md` section 3: a changed pin is its own task, and
it merges first). New external dependencies: none.

- The publication pull request commits this task file and its job row with
  the live issue-body hash. The implementation branch merges `main` after
  that, so its exact head holds both.

## Acceptance

- `mix hex.outdated --all` shows each package up to date, or named in the pull
  request with the requirement that holds it. `mix hex.audit` reports no
  retired package.
- `mix check` exits 0 on OTP 29.1.3 and Elixir 1.20.5, or the pull request
  records each command that cannot run on the host and the exact reason (for
  example PostgreSQL 19 with pgvector, or MinIO, is unavailable).
  `git diff --check` and `git diff --check origin/main...HEAD` exit 0.
- The full hosted check is green on the exact head, on PostgreSQL 19.
- One independent review, and the exact-head automated review with all threads
  answered and resolved before the coordinator takes over.
