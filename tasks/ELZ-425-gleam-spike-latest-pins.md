# ELZ-425 — spikes/gleam_ui: every pin to its latest stable release

- Dependencies: ELZ-416

## Outcome and scope

Owner decision of 2026-11-26: each pinned version moves to its latest stable
release. ELZ-416 moved the root and kept the Gleam UI spike's pins. The spike
pins Gleam `== 1.19.2`, `gleam_stdlib`, `gleam_json`, `lustre` and `gleeunit`
in `spikes/gleam_ui/gleam.toml` and `manifest.toml`, Node 24.16.0 in
`spikes/gleam_ui/scripts/setup.sh`, `.agents/setup` and
`.github/workflows/symbolic-gleam.yml`, its npm packages (Playwright and the
rest) in `package.json` and `package-lock.json`, and OTP 29.1.2 and its
actions in `symbolic-gleam.yml`.

- Each pin moves to its latest stable release: Gleam, each Gleam package, the
  latest Node release of the current LTS line, each npm package, OTP (as in
  ELZ-416), and each action by full commit SHA with its version comment. The
  checksums that the setup scripts verify are recomputed from the exact
  artifacts they download.
- The pull request lists each package that cannot reach its latest release,
  with the package whose requirement holds it.
- A code or test change of the spike that a new version forces is allowed and
  named file by file.

Paths: `spikes/gleam_ui/**`, `.github/workflows/symbolic-gleam.yml`, and the
Node lines of `.agents/setup`. New external dependencies: none.

## Acceptance

- The spike's setup and check scripts (`spikes/gleam_ui/scripts/`) exit 0 on
  the new pins, or the pull request records the exact reason a command cannot
  run on the host.
- `npm audit` reports no advisory that a newer release fixes.
- `python3 scripts/check-roadmap.py`, `git diff --check` and
  `git diff --check origin/main...HEAD` exit 0.
- The hosted Gleam workflow is green on the exact head.
- One independent review, and the exact-head automated review with its threads
  answered and resolved, or the authorized replacement review under
  `AGENTS.md` section 6.
