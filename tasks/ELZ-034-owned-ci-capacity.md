# ELZ-034 — Add macbook-ubuntu as an independently verified backend CI runner

- Phase: development CI capacity
- Dependencies: ELZ-019, ELZ-020, ELZ-033
- Catalogue IDs: none; no Piece Contract changes

## Outcome

Add the user-owned macbook-ubuntu Linux/x64 machine as a second repository-scoped
backend GitHub Actions runner while preserving symbolic and all active work.
The owner explicitly requested a trial of another user-owned machine. Hosted
GitHub runners remain prohibited. Do not run untrusted code on either machine.

## Scope and ownership

- Change the CI machine policy in AGENTS.md, docs/development/10-symbolic-ci.md,
  and directly dependent runner-policy documentation to allow only the named
  user-owned symbolic and macbook-ubuntu machines for their documented roles.
- Modify the backend workflow and scripts/check-ci-runners.py together, with
  explicit reviewed role selectors, safe routing, and meaningful negative
  controls. Preserve the symbolic Gleam role, exact image digest, Cure/OTP/
  Elixir pins, actual full mix setup/check and isolated PostgreSQL behavior.
- Update the existing test/ci_runner_guard_test.exs fixtures to exercise the
  current approved workflow files and retain their negative controls.
- Add a same-repository PR gate to both backend and Gleam workflows so a fork
  cannot cause untrusted code to run on either user-owned machine. A skipped
  fork check is not positive validation. Preserve Gleam's symbolic-only role.
- For this task's own PR, route the backend check to the new candidate and
  verify GitHub's actual runner_name and labels. Other branches continue to use
  the established symbolic-only workflow until this task is merged.
- Once the candidate passes the full task check and independent review, let
  the existing and new repository-scoped backend runners accept backend jobs.
  Use a common explicit user-owned/backend role label; do not label the new
  machine symbolic or register it under a misleading identity.
- Assign conservative per-machine BEAM scheduler settings and document actual
  CPU, RAM, resource limitations, Docker version, runner identity, service,
  maintenance and rollback. Measure a full real run on the candidate; an image
  pull or superficial smoke check is not evidence that mix check passes.
- Coordinate any shared workflow edits against active PRs. Do not change their
  branches, claim status, checks or existing runner registrations. Do not stop
  an active runner, requeue unrelated jobs, weaken tests or use hosted fallback.
- Add this task's source body at tasks/ELZ-034-owned-ci-capacity.md. Leave the
  roadmap catalogue and Piece metadata unchanged.

## Acceptance

- [ ] Actual CI job on this PR runs on macbook-ubuntu's named runner, inside the
      exact pinned Ubuntu image, with the pinned toolchain; mix setup and full
      mix check pass, including selected Cure proofs, runtime tests, negative
      controls, copied-source consumers and disposable PostgreSQL scenarios.
- [ ] GitHub API runner_name and role labels are recorded for the passing run;
      symbolic remains online and existing unrelated work is not interrupted.
- [ ] Runner-policy checks reject hosted, unauthorized-machine and wrong-role
      selectors, missing policies and unexpected workflows. Tests exercise both
      positive routing and explicit negative controls.
- [ ] The candidate machine's observed peak memory/CPU, elapsed time, relevant
      limits and risks to its other workloads are documented. If it cannot
      reliably run the workload, leave it candidate-only and record the blocker;
      do not claim increased CI capacity.
- [ ] Independent review inspects the exact workflow, trust model, guards,
      evidence and runner identity before merge.
- [ ] Acceptance is rechecked on the merge commit, and issue/branch/worktree
      cleanup follows AGENTS.md; no hosted runner fallback is introduced.

## Evidence and limits

The existing successful container pull only demonstrates the pinned image can
start. It does not establish a full CI pass, sustainable resource usage, or
identical host behavior. Docker group membership is root-equivalent; keep the
runner in a dedicated account scoped to this private repository. A runner
registration token must never be printed, committed, or included in a PR.

## Out of scope

No changes to Piece implementations, current task ownership, Cure/OTP/Elixir
pins, GitHub-hosted runners, or previously accepted delivery guarantees.
