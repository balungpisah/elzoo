# ELZ-410 — Record the first-release refreeze after the run-engine repairs

- Dependencies: ELZ-408, ELZ-409

## Outcome and scope

Record the owner's decision on [#990](https://github.com/balungpisah/elzoo/issues/990), option A: refreeze at `71e5f2b9` (ELZ-408, #992, PR #995) because the cold-VM recovery repair changed a frozen record-writing path. Admit ELZ-409 (#996, PR #997, merge `5ed6b662`) as a test-only repair to run the fresh-VM reader in the copied consumer. Keep F's original frozen job set; both repairs use stage `release`.

This is a coordinator-owned documents-only task on the one-PR path (`AGENTS.md` section 1), release V2, stage `release`. It changes no Piece, Contract, fixture, provider or executable input. New external dependencies: none.

- `docs/plans/first-release.md`: record the new X1–X3 record-writing baseline in the freeze rules and Level 4, update the V1B `assembly/run-engine` manifest hash to `6376b6f4317e7d9fad3a2f11968735d0a4b2a77e57072106acc276a539dd94c7`, and admit both repairs in the Level 5 change check.
- `docs/research/first-release-acceptance.md`: record both repairs with issue, PR and merge references and the run-engine manifest hash after ELZ-408; leave the existing audit rows intact.
- `tasks/ELZ-405-pattern-step-record-fixtures.md`, `tasks/ELZ-406-run-engine-record-fixtures.md` and `tasks/ELZ-407-recipe-test-record-fixtures.md`: update only the drift guards to use `71e5f2b9` and name the base checked against it. Mirror the text exactly to issues #985–#987, retaining their `task` labels.
- Commit this task file, the new job row and three updated live issue-body hashes in `docs/plans/release-plan.json`, and any resulting generated view changes.

## Acceptance

- At the base checked for this task, compare `lib/` and `cure/` (where present) in `workflow/pattern-step`, `assembly/run-engine`, `runtime/durable-unit` and `runtime/recipe-test`, plus `pieces/runtime/recipe-test/test/support/recipe_test_helper.exs`, against `71e5f2b9`: no differences. From F to the checked base only run-engine files changed under `pieces/`.
- `mix elzoo.ledger`, `python3 scripts/check-roadmap.py --write`, plain and `--live` roadmap checks, `python3 scripts/check-claims.py`, `git diff --check` and `git diff --check origin/main...HEAD` exit 0. `python3 scripts/ci-change-class.py range origin/main HEAD` prints `true`.
- One independent review and a green exact-head docs-only hosted check. The coordinator runs the merge queue only after the automated review gate and a green `main` push run on `5ed6b662` or later.
