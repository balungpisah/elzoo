# ELZ-426 — runtime/lua-sandbox: PUC Lua 5.5.1

- Dependencies: ELZ-416

## Outcome and scope

Owner decision of 2026-11-26: each pinned version moves to its latest stable
release. ELZ-416 kept the `lua_source` provider at PUC Lua 5.4.9 (revision
`312b9efaa1061c2c4cad08554dbc1351c3270eef`), because `runtime/lua-sandbox`
states Lua 5.4.9 and checks that revision and its exact source bytes. The
latest stable release is Lua 5.5.1. This task moves the provider and the
Piece to it, in place under the same ID (the rule of ELZ-415).

- `lua_source` in `mix.exs` pins the commit of the Lua 5.5.1 release by full
  SHA; `mix.lock` and `registry/providers.json` follow. The source identity
  that `runtime/lua-sandbox` checks (`lib/elzoo/lua_sandbox/source_identity.ex`)
  is recomputed from that revision, and the pull request shows that its source
  files equal those of the 5.5.1 release archive of lua.org.
- Each statement of the sandbox policy (version 3: the refused libraries and
  functions, the ten helpers, the limits, the determinism and replay rules) is
  rechecked against Lua 5.5.1, including the incompatibilities that its
  reference manual lists against 5.4. A statement that 5.5.1 changes is
  corrected in `piece.json` and the README, with a test that pins the new
  behavior. If the policy descriptor changes, the policy version and its
  identity prefix change with it, and the README says so.
- A record made under Lua 5.4.9 is refused at replay by the existing
  source-identity check. The README `## Changes` entry names this, and the
  migration step for a consumer: record again under 5.5.1.
- The README `## Changes` entry of each changed Piece names the move and each
  behavior change; each changed `piece.json` gets a new `manifest_sha256` in
  its `entries` row, with `note` equal to a changed `contract`.

Paths: `mix.exs` (the `lua_source` entry only), `mix.lock`,
`registry/providers.json` (`lua_source`), `registry/catalogue.json` (a summary
that names the Lua version), `docs/dependencies.md`,
`pieces/runtime/lua-sandbox/**`, `pieces/runtime/recipe-test/**` (its Lua
fixture `test/fixtures/recipe-test/lua_module_call.etf` and any statement of
the Lua version), `test/elz160_lua_provider_test.exs`, the `entries` rows of
the changed Pieces in `docs/plans/release-plan.json`, and the generated
`LEDGER.md` and `docs/plans/views.md`. This is a root dependency change with a
Piece Contract change: the full gate applies. New external dependencies:
none.

## Acceptance

- `mix check` exits 0, or the pull request records each command that cannot
  run on the host and the exact reason (`AGENTS.md` section 5).
  `python3 scripts/check-roadmap.py`, `python3 scripts/check-claims.py`,
  `git diff --check` and `git diff --check origin/main...HEAD` exit 0.
- The sandbox tests pass on Lua 5.5.1, and each policy refusal keeps a test
  that shows the refused function or library is unreachable under 5.5.1, with
  a negative control (a temporary edit that opens one refused function makes
  its test fail; recorded and reverted).
- A replay of a record made under 5.4.9 is refused with the existing error,
  and a test shows it.
- The full hosted check is green on the exact head.
- One independent review by the strongest available reviewer of another model
  family (the sandbox runs untrusted code), and the exact-head automated
  review with its threads answered and resolved, or the authorized replacement
  review under `AGENTS.md` section 6.
