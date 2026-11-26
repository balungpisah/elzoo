# ELZ-425 — spikes/gleam_ui: every pin to its latest stable release

- Dependencies: ELZ-416

## Outcome and scope

Owner decision of 2026-11-26: each pinned version moves to its latest stable
release. ELZ-416 moved the root and kept the Gleam UI spike's pins.
`spikes/gleam_ui/gleam.toml` pins Gleam `== 1.19.2` and the direct packages
`gleam_stdlib`, `gleam_json`, `lustre` and `gleeunit`; `manifest.toml` locks
the resolved Gleam packages. Node 24.16.0 is declared in `package.json`,
`scripts/setup.sh`, `scripts/check.sh`, `.agents/setup` and
`.github/workflows/symbolic-gleam.yml`. `package.json` pins Playwright,
`package-lock.json` locks its dependency tree, and the workflow pins OTP
29.1.2 and its actions.

- Each pin moves to its latest stable release: Gleam, each Gleam package, the
  latest Node release of the current LTS line, each npm package, OTP (as in
  ELZ-416), and each action by full commit SHA with its version comment. The
  checksums that the setup scripts verify are recomputed from the exact
  artifacts they download.
- The pull request lists each package that cannot reach its latest release,
  with the package whose requirement holds it.
- A code or test change of the spike that a new version forces is allowed and
  named file by file.

Paths: `spikes/gleam_ui/**`, `.github/workflows/symbolic-gleam.yml`, the Node
lines of `.agents/setup`, the Gleam pin assertions in
`scripts/check-ci-runners.py` (and `scripts/test-ci-runners.py` where it
mirrors them), and the current Gleam compiler pin and asset table in
`docs/development/10-symbolic-ci.md`. The workflow and shared setup paths make
this a CI change (`AGENTS.md` section 1), not a spike-only change. New
external dependencies: none.

## Acceptance

- The spike's setup and check scripts (`spikes/gleam_ui/scripts/`) exit 0 on
  the new pins, or the pull request records the exact reason a command cannot
  run on the host.
- `npm audit` reports no advisory that a newer release fixes.
- `python3 scripts/check-ci-runners.py`, `python3 scripts/test-ci-runners.py`,
  `python3 scripts/check-roadmap.py`, `python3 scripts/check-claims.py`,
  `git diff --check` and `git diff --check origin/main...HEAD` exit 0. The
  full local `mix check` runs, and the pull request records each command that
  cannot run and the exact reason (`AGENTS.md` section 5).
- The full hosted `check-hosted` check and `gleam-hosted` are both green on the
  exact head; no spike shortcut.
- One independent review, and the exact-head automated review with its threads
  answered and resolved, or the authorized replacement review under
  `AGENTS.md` section 6.
