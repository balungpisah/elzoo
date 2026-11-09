# ELZ-040 — Harden the CI runner guard and close the ELZ-034 review follow-ups

- Phase: P0 harness (CI policy; `.github/workflows/`, `scripts/check-ci-runners.py`, `scripts/test-ci-runners.py`, `docs/development/10-symbolic-ci.md`)
- Catalogue IDs: none
- Dependencies: ELZ-034 (merged, PR #61 as 9890dee)

## Outcome

Close the should-fix findings from the ELZ-034 final review (PR #61 comment 6702174711) before
any later CI task (ELZ-038 affected checks, ELZ-039 merge queue) adds new jobs or write
permissions.

## Scope

1. The guard checks workflow triggers. Reject `pull_request_target` and any trigger other than
   the approved set (`push` to main, `pull_request`, `workflow_dispatch`), with negative controls.
2. Remove the one-time `task/ELZ-034` candidate route from workflows, guard and docs now that
   the second fast runner is in the backend pool.
3. `docs/development/10-symbolic-ci.md`: record the passing candidate run 42335711837 and the
   admission state (runner 23 has `backend`), and the machine A Docker registry mirror
   (`/etc/docker/daemon.json` `{"registry-mirrors": ["https://mirror.gcr.io"]}`, added 2026-11-07
   after registry-1.docker.io timed out from machine A; digest pins unchanged).
4. Optional, if cheap: reject quoted-key `"runs-on":` and container-image changes without a digest.
- Add this task's source body at `tasks/ELZ-040-ci-guard-hardening.md`.
5. Scope addition (owner-approved, recorded on PR #71): raise the backend job
   `timeout-minutes` in `.github/workflows/symbolic-check.yml` from 45 to 90.
   Basis: PR #71 run 42342334978 attempt 1 exceeded 45m0s on
   the second fast runner (05:20:51Z–06:06:03Z, cancelled); attempt 2
   passed on the first fast runner (06:07:51Z–06:36:38Z, 28m47s) and does not replace
   attempt 1. Main `94df396` run 42340251145 passed on the first fast runner in 44m17s. `symbolic-gleam.yml` (30) and test time limits
   are unchanged.

## Acceptance

- [ ] New negative controls fail on the old guard and pass on the new one; record both.
- [ ] `python3 scripts/test-ci-runners.py`, `check-ci-runners.py`, full `mix check` pass.
- [ ] Symbolic/user-owned CI passes on the PR head and the merge commit; runner identity shown.
- [ ] Independent review of the actual diff.

## Limits

The guard stays a source convention, not a hostile-YAML parser.
