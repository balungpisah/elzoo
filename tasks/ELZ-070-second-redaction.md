# ELZ-070 — Second redaction pass: local paths, host and runner names, session ids, test database name

- Phase: P0 harness (docs only)
- Catalogue IDs: none
- Dependencies: ELZ-065 (#114) merged (the MUST pass); ELZ-069 (#127, the cleanup PR) merged first, because it rewrites `docs/development/10-symbolic-ci.md`; this task then removes the runner and host names that remain in the measurement history of that guide.
- Review: one independent review of the whole diff (comment-only edits in three protected test files are in scope, see item 6); Devin Review findings dispositioned in the PR.

## Outcome

The MUST pass (ELZ-065) removed secrets, addresses and third-party personal data before publication. The SHOULD class remains: strings that identify the owner's machines, accounts and sessions but are not secrets. The repository is public now, so this pass removes them from the current tree. Git history and published run logs keep the old text (owner decision 2026-11-09).

## Scope (done; inventory on main at a557b04)

1. **Local paths** (`/Users/<user>/...`, `/home/<user>/...`): about 30 files (`PLAN.md`, `docs/plans/**`, `tasks/ELZ-033`, 25 `docs/work` records) now use placeholders (`<worktrees>/...`, `<repository root>`, `<artifact directory>`). The two third-party research JSON files (quoted package documentation) are unchanged.
2. **Machine-derived names**: the agent id derived from a host name in `docs/plans/release-plan.json` and `docs/work/ELZ-013.md` becomes a role; the owner nickname in the title of issue #70 is removed.
3. **Runner and machine names**: `symbolic-elzoo`, `macbook-ubuntu-elzoo-candidate`, `contabo-elzoo-1` and `symbolic-elzoo-gleam` become role words ("the first fast runner", "the second fast runner", "the slow VPS runner", "the Gleam runner"); the machine nicknames `symbolic` and `macbook-ubuntu` become "machine A" and "machine B" in the files where they name the machine (never where "symbolic" means Cure's symbolic values). The vendor name Contabo and workflow file names (`symbolic-check.yml`, `symbolic-gleam.yml`, `10-symbolic-ci.md`) stay. Script test fixtures use neutral runner names (`self-hosted-1`, `self-hosted-gleam-1`). The workflows' display names `Check on user-owned CI` and `Gleam on symbolic` become `Check` and `Gleam` (job names, which the required checks use, are unchanged).
4. **Orca session, thread, task, dispatch and message ids** in `docs/work`, `docs/plans`, `tasks`: replaced by "an independent review session", `<session id>`, `<dispatch id>`, `<task id>`, `<message id>` and `<thread link redacted>`.
5. **Test database name and role** (`elzoo_pieces_test`, `elzoo_elz024`): 21 files, as `<test database>` / `<test role>` in commands and "the disposable test database" in prose. `elzoo_test` in the workflow and `docs/work/ELZ-012-evidence/initial.json` (evidence data) stay.
6. **Protected files.** Comment-only edits in four test files (`pieces/workflow/approval/test/elzoo/approval_test.exs`, `test/export_test.exs`, `test/support/cure_consumer_case_test_helper.exs`, `test/test_helper.exs`); script test fixtures (`scripts/test-ci-skip.py`, `scripts/test-merge-queue.py`) change runner-name values only. One independent review covers the whole diff.
7. **Consumer repository**: it is private, so the three links in `docs/architecture.md` and `docs/cure-notes.md` become plain text ("commit `ffd64a4` of the consumer repository").
8. **Checked and left unchanged on purpose:** `ELZOO_AGENT` wording (role-based since ELZ-067); commit author e-mail addresses (owner decision); the local-only `refs/t3` warning; the GitHub login `sabrang-mdp`.
9. **Pins and live issues.** `docs/plans/release-plan.json` and `docs/plans/views.md` regenerated with `scripts/check-roadmap.py --write` (this also corrects the stale count of current ready manifests on `main`). The body of issue #55 (ELZ-033) held a local path and is hash-pinned and must equal `tasks/ELZ-033-product-led-roadmap.md`: the issue body is edited to the redacted text and the pin `issue_body_sha256` of ELZ-033 is updated. The titles of #26, #28 and #70 are edited because the plan mirrors them. Other closed task issues keep their text (old edit revisions stay in GitHub in any case). Each changed `docs/work` file carries a one-line note (ELZ-070); hashes and byte-equality records in those files refer to the unredacted text.

## Acceptance

- [ ] `git grep -nE '/Users/[a-z]|/home/[a-z]+/|orca_session|elzoo_pieces_test|elzoo_elz024|symbolic-elzoo|macbook-ubuntu|contabo-elzoo|Sabrangs-|Kinhin|laptopdp'` on the PR head returns only the listed exceptions (the vendor name Contabo, workflow and guide file names, `ELZ-012-evidence/initial.json`, this task file and ELZ-065's).
- [ ] `check-roadmap.py` and `check-claims.py` exit 0; link check green.
- [ ] Hosted PR run and queue exact-head run green (docs only: no local full check).
- [ ] Devin findings dispositioned; every touched test file listed in the PR.

## Limits

Redaction of the current tree does not remove the strings from git history, edit revisions of issues and comments, or run logs. The test database name and runner names stay in older commits.
