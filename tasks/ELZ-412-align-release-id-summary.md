# ELZ-412 — Align the Piece ID summary with the first-release mark

- Dependencies: ELZ-411

## Outcome and scope

Resolve [#1005](https://github.com/balungpisah/elzoo/issues/1005) after the [first-release attestation](https://github.com/balungpisah/elzoo/issues/1002#issuecomment-7181545136). In `docs/choices.md`, update only the ID rule under “How a change works.” Align it with `AGENTS.md` section 4 and “The first release” in `docs/consuming.md`: from the release commit on, a changed ready Contract gets a new Piece ID and migration notes, the old ID stays usable, and a fix that restores the Contract keeps its ID.

This is a coordinator-owned documents-only task on the one-PR path (`AGENTS.md` section 1), release V2, stage `later`. It changes no Piece, Contract, release selector, or executable input. New external dependencies: none.

- Commit this task file, its new job row with the live issue-body hash in `docs/plans/release-plan.json`, and the resulting generated view changes.

## Acceptance

- The summary no longer says Elzoo is unreleased and states all three post-release ID rules. No other content in `docs/choices.md` changes.
- `mix elzoo.ledger`, `python3 scripts/check-roadmap.py --write`, plain and `--live` roadmap checks, `python3 scripts/check-claims.py`, `git diff --check` and `git diff --check origin/main...HEAD` exit 0. `python3 scripts/ci-change-class.py range origin/main HEAD` prints `true`.
- One light independent review, a green exact-head docs-only hosted check, and a successful exact-head Devin Review with all threads answered and resolved before the coordinator takes over.
