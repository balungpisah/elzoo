# ELZ-057 — Route backend checks by runner tier; add the runner budget rule

- Phase: P0 harness (CI; `.github/workflows/symbolic-check.yml`, `scripts/check-ci-runners.py`,
  `scripts/test-ci-runners.py`, `scripts/merge-queue.py`, `scripts/test-merge-queue.py`,
  `docs/development/10-symbolic-ci.md`, the CI sentence of `AGENTS.md`)
- Catalogue IDs: none
- Dependencies: ELZ-056 (#92, merged at `452caa1`) and ELZ-049 (#89, concurrent consumers), which
  must merge first. ELZ-058 (#96) follows this task. ELZ-044 (#76, structural guard) comes after
  both and is not a dependency.
- Review: independent review of the actual workflow, guard and merge-queue diff is required.

## Outcome

`contabo-elzoo-1` (runner id 24) is registered and documented with no `backend` label (owner
decision 2026-11-08, ELZ-056). It passed one full trial but took about twice as long as the
MacBook on the same tree (root suite 2625.6 s against 1340.4 s; `symbolic` 1116.3 s on a
different tree). The CPU is slower per thread (worker benchmark: about 1.8 times slower than
`symbolic`); the 5-core cap, the disk and CPU steal do not explain it. GitHub gives a job to any
idle runner with matching labels and cannot prefer a faster one.

Owner decision 2026-11-08 ("go"): pull request checks and merge-queue exact-head runs run only
on the fast runners (`symbolic-elzoo`, `macbook-ubuntu-elzoo-candidate`); `main` push runs and
measurement dispatches may use any backend runner, including `contabo-elzoo-1`. Only after this
task merges does `contabo-elzoo-1` receive the routing label.

## Scope

- Tier label: `fast` on the two fast runners (account-level label assignment by the
  coordinator, as for `backend`). `contabo-elzoo-1` never gets `fast`.
- Workflow (coordinator decision): two jobs, `check-fast` and `check-any`, with `if:` on the event
  and the `tier` input. The merge queue and a measurement run are both `workflow_dispatch`, so
  a `tier` input (`fast` default, `any`) separates them: the queue always dispatches `fast`, and
  only a person sets `any`. `check-fast` runs for `pull_request` and for dispatch with `fast`;
  `check-any` runs for `push` to `main` and for dispatch with `any`. The guard pins each job
  exactly. Keep on both jobs the container digest pin, the fork-PR gate, the first-step identity gate and per-runner
  `ERL_FLAGS` on every job; no hosted fallback; no `pull_request_target`; no `if:` or
  `continue-on-error:` that can disable the identity gate.
- Guard: update `scripts/check-ci-runners.py` to accept exactly the chosen shape, and nothing
  wider. The `workflow_dispatch:` trigger lines change (the input), so the pinned trigger block
  and the job-count rule change deliberately. New negative controls: a pull request or queue
  path without `fast`, `tier: any` reachable from `pull_request`, an extra label, a missing or
  edited identity gate on either job. Existing tests are not edited or weakened.
- Merge queue (coordinator decision): `scripts/merge-queue.py` always dispatches `fast`, accepts only
  the fast runners as queue evidence, and its job-name check follows the new job names; tests in
  `scripts/test-merge-queue.py`.
- Docs: `docs/development/10-symbolic-ci.md` (roles, tier rule, Contabo status) and the CI
  machine policy sentence of `AGENTS.md` stay accurate. Add a short **runner budget** section:
  1. Measurement series (repeat loops, benchmarks) run on the slow or an idle runner and never
     more than one at a time while a merge queue is pending.
  2. A measurement job states its expected duration and stays under the 90-minute limit.
  3. A coordinator does not dispatch by hand while a queue run is being identified (the queue
     identifies its run by workflow, event, branch and exact head SHA; a hand dispatch on the
     same head makes it ambiguous).
- Labels, in this order (the coordinator, account-level; not part of the diff): (1) add `fast` to the
  two fast runners before the workflow with `check-fast` merges, otherwise pull request checks queue
  without a runner; (2) after the merge, add `backend` to `contabo-elzoo-1` and confirm it with one
  `tier` = `any` dispatch that lands there (run and job IDs, duration, cgroup peak, sampled CPU,
  `cpu.max` reading). Remove the label if that run fails.

## Acceptance

- [ ] Tier rule and runner budget documented; chosen workflow shape and reasons recorded.
- [ ] Guard and tests pass with new negative controls; the old guard rejects the new shape.
- [ ] A pull request run and a queue run land only on `fast` runners (run and job IDs, runner names).
- [ ] After the merge and the `backend` label: a `tier` = `any` dispatch lands on `contabo-elzoo-1` and passes (observed once).
- [ ] Independent review of the actual diff (separate agent session, reviewed SHA on the PR).
- [ ] Full `mix check` on the PR head and on the merge commit, runner identity shown.
- [ ] The coordinator asks the queue question before any merge; no hand dispatch while the queue runs.

## Limits

Routing does not make Contabo faster and does not isolate job containers from the production
containers on that host (shared Docker daemon). Label assignment stays an account-level control the
guard cannot prove. Two fast runners mean less capacity for pull requests; compare queue wait
before and after. The two fast runners are the capacity for pull request checks until ELZ-058 lands. ELZ-049 (concurrent consumers) may change the speed gap: re-measure on Contabo
before the label is added, and record it.
