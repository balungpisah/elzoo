# ELZ-066 — GitHub-hosted CI lane, selected by a repository variable

- Phase: P0 harness (CI; `.github/workflows/symbolic-check.yml`, `.github/workflows/symbolic-gleam.yml`,
  new `scripts/ci-minio.py`, `scripts/ci-skip-decision.py`, `scripts/merge-queue.py`, `scripts/check-ci-runners.py`
  and their tests, `docs/development/10-symbolic-ci.md`, the CI policy sentence of `AGENTS.md`)
- Catalogue IDs: none (the S3 test server part replaces ELZ-064 and unblocks ELZ-053)
- Dependencies: ELZ-058 (#96) and ELZ-065 (#114) merged. Supersedes ELZ-064 (#112, folded in) and drops ELZ-061 (mirror).
  ELZ-059 (#99) is rescoped after this task (light PR mode and freeze rule stay; the hourly staggered run is dropped).
- Review: independent review required (workflow, guard, queue and trust model), plus Devin Review findings
  dispositioned in the PR.

## Outcome

Owner decision 2026-11-09: the repository becomes public, and CI moves to GitHub-hosted runners (minutes are free for a
public repository). The four self-hosted runners are unregistered before the visibility change, because a fork can
change a workflow file and target them. CI must never go dark during the move, so one workflow selects its lane from
the repository variable `ELZOO_CI_LANE`:

1. While the repository is private, the variable is unset (or `self`): today's self-hosted jobs run; the hosted job is skipped.
2. This PR is checked and queued on the self-hosted lane and merged.
3. The coordinator changes the visibility, sets `ELZOO_CI_LANE` to `hosted`, verifies one hosted full run on `main`, then
   unregisters the self-hosted runners and protects `main`.
4. A later cleanup PR removes the self lane.

## Scope

- **Workflows.** `symbolic-check.yml`: `check-fast` and `check-any` get `vars.ELZOO_CI_LANE != 'hosted'` in their `if:`
  lines. New job `check-hosted`: `runs-on: ubuntu-24.04`, no job container (the runner VM), `if:` lane is `hosted` and
  (same-repository pull request, push to `main`, or `workflow_dispatch`); `timeout-minutes: 60`; permissions
  `contents: read` and `actions: read` (the ELZ-058 decision step); hosted identity gate (first step, pinned): the step fails unless
  `RUNNER_ENVIRONMENT` is `github-hosted`, `RUNNER_OS` is `Linux`, `RUNNER_ARCH` is `X64` and `/etc/os-release` names Ubuntu 24.04.
  Same Elixir, OTP and Cure pins through `setup-beam`; `ERL_FLAGS` sized for 4 vCPUs. `symbolic-gleam.yml` gets the
  same pattern (`gleam` skipped in the hosted lane, new `gleam-hosted`), because the queue requires a Gleam pull request run.
  The `tier` input stays; the hosted lane ignores it.
- **PostgreSQL.** A service container `postgres` at a pinned digest (`postgres:16-bookworm@sha256:5264710b...`, digest read
  from the registry on 2026-11-09) with a health check; one step creates the same non-superuser role and database the self
  lane creates today and exports `ELZOO_TEST_DATABASE_URL` (tests still fail closed without it).
- **S3 test server (folds in ELZ-064).** The MinIO container image is no longer published (Docker Hub repository gone, no
  tag on Quay), so a service container is not possible. `scripts/ci-minio.py` (stdlib, fail closed) obtains the pinned
  binary of release `RELEASE.2025-09-07T16-13-09Z` (the production release; asset id 404655976, 110,989,496 bytes,
  SHA-256 `7c5bd851...fb855f`) from, in order, an `actions/cache` entry keyed by the SHA-256, the release-asset API with the
  job token (no token to the redirect), the browser URL; verifies size and SHA-256 for every source; starts it loopback-only
  with random masked credentials and the bucket `elzoo-test`; waits for health; checks credentials and bucket with a signed
  `HEAD`; exports `ELZOO_TEST_S3_URL`, `ELZOO_TEST_S3_BUCKET`, `ELZOO_TEST_S3_ACCESS_KEY_ID`, `ELZOO_TEST_S3_SECRET_ACCESS_KEY`,
  `ELZOO_TEST_S3_REGION` (`us-east-1`). The same step is added to the self-lane jobs so that ELZ-053 can merge while private.
  Upstream MinIO is archived (AGPL-3.0, no security updates); it runs only in the disposable job, loopback-only.
- **Cache.** Hosted key without the runner name: `elzoo-hosted-v1-<os>-<ImageOS>-<otp>-<elixir>-<hash of the lock files>`;
  the same restore, save-after-`mix setup` split as ELZ-043.
- **Merge queue.** `scripts/merge-queue.py` accepts evidence from exactly one non-skipped job, either `check-fast` on a fast
  runner (self lane) or `check-hosted` with `runner_group_name` = `GitHub Actions`, `labels` = `["ubuntu-24.04"]` and a runner
  name starting `GitHub Actions ` (fields observed on a real hosted job); the same for the Gleam job. The duplicate-run
  cancel stays. Ships the two Devin fixes from ELZ-058 (retry patterns for timeouts; no retry for the best-effort lookup;
  commit `e6726a5`, cherry-picked from the ELZ-058 follow-up branch).
- **Push skip (ELZ-058).** `scripts/ci-skip-decision.py` accepts exact-head evidence from `check-hosted` as well.
- **Guard.** `scripts/check-ci-runners.py` pins the three backend jobs and two Gleam jobs, the lane conditions, the hosted
  gate, the service image digests, the permission lines (`actions: read` on the push-capable jobs only), the token lines
  (decision step, `ci-minio.py` step, Gleam step) and the step conditions. Existing tests are not weakened; forced edits are
  listed in the PR for the owner's approval. The guard test with `ubuntu-latest` and similar names stays: a hosted label other
  than `ubuntu-24.04` is rejected.
- **Policy and docs.** The CI policy sentence of `AGENTS.md` changes by owner decision (hosted runners allowed once the
  repository is public; no hosted runner while private; no hosted fallback for the self lane); `docs/development/10-symbolic-ci.md`
  is rewritten around the lanes (hosted lane first; the self lane documented as retiring; the Contabo and MacBook sections
  condensed to a history note); the flip sequence and the required checks for branch protection are written down.
- **Measurement.** Duration and cgroup-equivalent resource use of the hosted job on the first hosted run (steps, queue time,
  `mix check` time); speed levers (splitting the suite into parallel jobs) are a follow-up with data.

## Acceptance

- [ ] The PR is checked and merged on the self lane (`ELZOO_CI_LANE` unset); `check-hosted` shows as skipped.
- [ ] `actionlint` and the guard accept the workflows; negative controls for each pinned part.
- [ ] A hosted run is observed once after the coordinator's flip (run, job and runner IDs, duration, queue time) with
      `ELZOO CHECK PASSED`; it is the evidence for the flip, not for the merge.
- [ ] The merge queue accepts a hosted run and refuses an unexpected runner group, label or name (tests).
- [ ] `scripts/ci-minio.py` tests (fake HTTP, fake server) and one real run of the step in the PR's own self-lane check.
- [ ] Independent review (separate agent session, reviewed SHA on the PR); Devin Review: findings dispositioned.

## Limits

The hosted job cannot be exercised before the visibility change (the owner has no hosted minutes while the repository is
private). The first hosted run is therefore the real test; the variable allows an immediate return to the self lane until the
runners are unregistered. Published logs of past runs keep host names (owner decision 2026-11-09). Hosted runner capacity and
performance (4 vCPUs) are unmeasured.

## Existing tests edited (for the owner's approval)

`scripts/test-ci-runners.py` pins the exact workflow shape, so its expectations changed with the workflows. No assertion
was removed or weakened; every edit adds the new jobs or the lane condition to a number or a string:

- the two gate strings in `test_fork_pr_job_gate_cannot_be_removed` and `test_gleam_fork_pr_job_gate_cannot_be_removed`
  now contain `vars.ELZOO_CI_LANE != 'hosted' && `;
- three job-list messages now name `check-hosted` (`exactly the jobs check-fast, check-any, check-hosted are required`) and
  the Gleam message names `gleam-hosted`;
- counts: Gleam setup step 1 to 2, `github.token` in the Gleam file 1 to 2, decision step 2 to 3, `ANY_PERMS` 1 to 2,
  `github.token` in the backend file 2 to 6 (three decision and three S3 steps), `permissions:` 2 to 3, checkout 2 to 3,
  `actions: read` 1 to 2, `test-ci-skip.py` step 2 to 3.

`scripts/test-merge-queue.py` and `scripts/test-ci-skip.py` only gain tests and fixtures.
