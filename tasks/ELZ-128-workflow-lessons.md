# ELZ-128 — Fold cycle lessons into agent workflow

- Dependencies: none
- Allowed implementation paths: `AGENTS.md`, `CLAUDE.md` only.

Fold short, general lessons from the completed cycle into the existing workflow sections. Do not add a retrospective document, repeat existing rules, or turn task logs, identities or benchmarks into rules. `CLAUDE.md` imports the workflow: add only an applicable Claude-specific note or cross-reference there.

## Acceptance

- The existing sections cover overlapping one review of a frozen diff with the local gate to avoid serial wait; first green alone is insufficient without adversarial checks of named boundaries and actual negative controls; fixes-only subsequent reviews remain narrow.
- Avoid repeated main chasing or local gate work when the reviewed delta is unchanged, while retaining exact-head and base qualifiers, new-head hosted checks, and all current merge and main-green guards. Reuse already delivered qualifying publication evidence safely, without weakening those guards.
- Use the smallest changes that express these behaviors without duplicating existing rules. One independent review is required; do not run an evaluation experiment unless requested. Run applicable documentation checks and `git diff --check`.
