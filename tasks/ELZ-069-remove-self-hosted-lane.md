# ELZ-069 — Remove the self-hosted lane: workflows, guard, queue, skip decision and docs

- Phase: P0 harness (CI; `.github/workflows/symbolic-check.yml`, `.github/workflows/symbolic-gleam.yml`,
  `scripts/check-ci-runners.py`, `scripts/test-ci-runners.py`, `test/ci_runner_guard_test.exs`,
  `scripts/merge-queue.py`, `scripts/test-merge-queue.py`, `scripts/ci-skip-decision.py`, `scripts/test-ci-skip.py`,
  `docs/development/10-symbolic-ci.md`, `docs/development/06-toolchain.md`, the CI policy section of `AGENTS.md`)
- Catalogue IDs: none
- Dependencies: ELZ-066 (#115), ELZ-068 (#124) and ELZ-062 (#106) merged. ELZ-059 (#99) comes after and builds on the result.
- Review: independent review required (workflow, guard and queue are protected surfaces); Devin Review findings dispositioned in the PR.

## Outcome

The repository is public and CI runs on the hosted lane; all self-hosted runners are unregistered. The self-hosted jobs, the lane variable and the runner roles are dead code and a trust risk (a self-hosted job in a public repository is a fork-attack path if a runner is ever registered again). This task removes them and leaves one lane.

## Scope

1. **Workflows.** `symbolic-check.yml` keeps only `check-hosted`; `symbolic-gleam.yml` keeps only `gleam-hosted`. Remove `check-fast`, `check-any`, `gleam`, their job containers, runner identity gates, tier conditions and `actions: read` pairs that belonged only to them. The `if:` of the two hosted jobs loses `vars.ELZOO_CI_LANE == 'hosted' &&` and keeps the event conditions (push, `workflow_dispatch`, same-repository pull request). Job names stay (`check-hosted`, `gleam-hosted`: ELZ-059 makes them required checks). The `tier` input of `workflow_dispatch` is removed.
2. **The lane variable goes away.** No workflow reads `vars` any more; the guard rejects `vars` and `ELZOO_CI_LANE` anywhere (stricter than today). The coordinator deletes the repository variable `ELZOO_CI_LANE` after the merge (not part of the diff).
3. **Guard** (`scripts/check-ci-runners.py`) accepts exactly the new shape: two workflows, one job each, label `ubuntu-24.04` only, no job container, the pinned hosted header and identity gate, S3 and decision steps, token lines, permissions, step conditions, checkout pins, the generic YAML-form, escape, trigger and action-SHA rules. Everything that only the self-hosted jobs needed is deleted from the guard (runner-role specs, container digest rule for job containers, `REQUIRED_GATE`, body-identity of two jobs, `ANY_PERMISSIONS`); the digest rule for `services:` images stays.
4. **Guard tests** (`scripts/test-ci-runners.py`, `test/ci_runner_guard_test.exs`): every still-meaningful rejection is kept and ported to the hosted jobs (labels, container, header pin, gate, token, secrets, escapes, `vars`, late keys, S3 pins, YAML forms, triggers, `pull_request_target`, action SHAs). Tests that exercise only removed self-hosted behaviour are deleted; the PR lists every deleted or changed merged test with the reason, for the owner's approval (as in ELZ-057 and ELZ-066). New controls: the removed jobs, the `tier` input and the lane variable are each rejected if they come back; the guard also rejects `runs-on: self-hosted`, any `self-hosted` label, and any `labels:` list on a job, so the shape cannot return silently.
5. **Merge queue** (`scripts/merge-queue.py`, `scripts/test-merge-queue.py`): evidence rules keep only `check-hosted` / `gleam-hosted` with the hosted identity; `FAST_RUNNERS`, `check-fast`, `check-any` and the `tier=fast` dispatch input are removed (the dispatch fallback sends no input). **Skip decision** (`scripts/ci-skip-decision.py`, `scripts/test-ci-skip.py`): same.
6. **Docs.** `docs/development/10-symbolic-ci.md`: remove "Roles and routing", "Runner tiers and the runner budget", "Machine and container setup" except the parts still true on hosted runners (dependency cache, Gleam compiler download), the Contabo section and "Operation and rollback" (rewritten); keep ELZ-058, 038, 039, 045, 049, 046, 047, 064, 062 and the flip record; "Lanes" becomes "Hosted CI" with the flip record kept. Add a short history paragraph (self-hosted period ELZ-019 to ELZ-066, why it ended, where the old numbers are in git history). `docs/development/06-toolchain.md` line 41 and the CI policy section of `AGENTS.md`: hosted only.
7. **Fallback (decided).** The fallback is a revert of this change plus runner registration; `docs/development/10-symbolic-ci.md` states it as three steps: (1) a revert PR of this change goes through the queue; (2) register self-hosted runners (only after the repository is private, never on a public repository); (3) change the repository visibility only if the first two cannot be done on a private repository first.

## Decisions (coordinator, 2026-11-09)

- D1: the lane variable goes away entirely; the coordinator deletes it after the merge.
- D2: the fallback needs a revert PR plus runner registration (item 7); there is no switch back.
- D3: the `tier` input and `-f tier=fast` are removed here, not in ELZ-059.
- D4: the job names `check-hosted` and `gleam-hosted` do not change.

## Acceptance

- [ ] `check-hosted` and `gleam-hosted` green on the PR head (pull_request run) and on the queue's exact-head run; no self-hosted runner is involved.
- [ ] Guard and its tests pass; each removed behaviour has a control that fails if it returns; deleted or changed merged tests listed and approved.
- [ ] `git grep -nE "check-fast|check-any|ELZOO_CI_LANE|tier=|runs-on: \[self"` outside `docs/work`, `tasks`, the guard and its tests, the "Hosted CI" and "History" sections of `docs/development/10-symbolic-ci.md` returns nothing. Runner and host names in the measurement history of that guide are removed by ELZ-070 (#128), not here.
- [ ] `check-roadmap.py`, `check-claims.py` exit 0; independent review of the actual diff (separate agent session, reviewed SHA on the PR).
- [ ] No local full `mix check` is needed (workflow, scripts and docs only); the hosted PR run and the queue's exact-head run are the acceptance evidence.

## Limits

Removing the self-hosted lane removes the only fallback that does not need a revert. The first push run after the merge is the first run of the new shape on `main`. Published logs of past runs keep the runner names (owner decision 2026-11-09).
