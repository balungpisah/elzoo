# ELZ-424 — spikes/ash_foundation: every pin to its latest stable release

- Dependencies: ELZ-416

## Outcome and scope

Owner decision of 2026-11-26: each pinned version moves to its latest stable
release. ELZ-416 moved the root and changed only the Ash spike's exact Elixir
requirement, which the new toolchain forced. The spike's own direct pins in
`spikes/ash_foundation/mix.exs` (`ash`, `ash_postgres`, `ash_ai`,
`simple_sat`, `telemetry`, `ash_state_machine`, `ash_oban`, `oban`) and its
`mix.lock` stay older, and Hex reports advisories in that lock (among them
`ash`, `db_connection`, `phoenix` and `plug`).

- Each direct `==` pin of the spike moves to its latest release; a `~>`
  requirement is widened only where the latest release is outside it. Then
  `mix deps.update --all` in the spike.
- The pull request lists each package that cannot reach its latest release,
  with the package whose requirement holds it, and the advisories that
  `mix hex.audit` reported before and after.
- A code or test change of the spike that a new version forces is allowed and
  named file by file. The spike's findings in its README are rechecked: a
  finding that no longer holds is corrected, not kept.

Paths: `spikes/ash_foundation/**` only. This is a spike-only change
(`scripts/ci-change-class.py`: `SPIKE_PREFIXES`). New external dependencies:
none.

## Acceptance

- From `spikes/ash_foundation`: `MIX_ENV=test mix deps.get`,
  `mix format --check-formatted`, `MIX_ENV=test mix test --warnings-as-errors`
  and `mix hex.audit` exit 0, or the pull request records the exact reason a
  command cannot run on the host. `mix hex.outdated --all` shows each package
  up to date or named with its holder.
- `python3 scripts/check-roadmap.py`, `git diff --check` and
  `git diff --check origin/main...HEAD` exit 0.
- The hosted `check-spike` job is green on the exact head.
- One independent review, and the exact-head automated review with its threads
  answered and resolved, or the authorized replacement review under
  `AGENTS.md` section 6.
