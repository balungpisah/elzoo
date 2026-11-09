# ELZ-039 — Run the full check before merge with a coordinator merge queue

- Phase: P0 harness (CI; `scripts/`, `.github/workflows/symbolic-check.yml`, `docs/development/10-symbolic-ci.md`)
- Catalogue IDs: none
- Dependencies: ELZ-038 (#68, merged as `1d3f1f9`), serial on CI policy files
- Must land before ELZ-041 (#70) changes the same workflow files.

## Outcome

Since ELZ-038, a PR runs only the affected consumer checks. The full check (all 26 per-ID
consumers and the aggregate) first runs on the merge commit, after the merge. A PR that
breaks an unselected consumer turns `main` red, and the fix comes later.

GitHub's merge queue is not available: the organisation is on the free plan, and branch
protection and rulesets return 403. So we keep our own small queue.

There is also a gap on `main` now. The workflow has `concurrency: check-${{ github.ref }}`
with `cancel-in-progress: true`. Two merges close together cancel the full check of the
first merge commit. Then that merge commit has no full CI result, and the acceptance step
"verify merge-commit CI" cannot pass.

## Design (coordinator-side, no CI write key)

The queue is a local tool that the coordinator runs with its own `gh` login. CI keeps
`permissions: contents: read`. No new workflow, job, runner, label or token. This keeps the
ELZ-044 (#76) threat-model work out of this task.

`python3 scripts/merge-queue.py <PR>...` handles PRs in the given order, one at a time:

1. Refuse a PR that is a draft, from a fork, not targeting `main`, not mergeable, or not
   `task/ELZ-###` (exact branch name rule from AGENTS.md).
2. Read main’s SHA from `gh api repos/balungpisah/elzoo/git/ref/heads/main`
   (or verify origin is the canonical repository). If the PR head does not contain it, run
   `gh pr update-branch <PR>` (merge commit, never `--rebase`, never force). Then use the
   new head SHA.
3. Start the full check on that head: `gh workflow run symbolic-check.yml --ref <branch>`.
   `workflow_dispatch` already runs the full mode. Find the run by event, branch and
   `head_sha` (not by "latest run").
4. Wait for the run. Accept it only when every condition is true:
   - conclusion `success`, and `head_sha` equals the PR head;
   - the backend job's `runner_name` is the first fast runner or the second fast runner;
   - the job log contains `ELZOO CHECK PASSED` and not the affected-mode marker.
   Also require a successful `symbolic-gleam.yml` pull_request run on the same
   exact head SHA, with its successful Gleam job on the Gleam runner.
   The synchronize event after update-branch supplies that run; wait for it.
   Without an update, require Gleam success on the current head too.
5. Before merge, fetch again and re-read canonical main. If main moved and the PR head no longer contains it,
   go back to step 2. Then merge with
   `gh pr merge <PR> --merge --match-head-commit <SHA>`.
6. Print the run ID, job ID, runner, head SHA and merge SHA as the evidence line.
   On any failure, stop the queue for that PR, print the reason, and go to the next PR only
   when the user passes `--continue-on-failure`. Default: stop.

The script does not delete branches, close issues or post acceptance records. The
coordinator still does those steps by hand.

Use of both x64 runners: the merge-commit check for PR A (push to `main`) and the full
pre-merge check for PR B (`workflow_dispatch`) run at the same time. GitHub gives each to a
free backend runner. No per-runner route is added. Speculative checks of stacked PRs are out
of scope.

## Workflow change

Apply the concurrency policy below to both `symbolic-check.yml` and
`symbolic-gleam.yml` (coordinator-approved review correction).

- `concurrency.cancel-in-progress` must not cancel runs on `main` or `workflow_dispatch`
  runs. Cancel only superseded `pull_request` runs. Keep the ref-based group for
  PR runs; use a unique per-run group for main and `workflow_dispatch` so pending
  runs cannot replace one another (owner-approved correction).
- `scripts/check-ci-runners.py` must still pass. If it reads `concurrency:`, extend its
  tests; do not loosen any other rule.

## Tests

- `scripts/test-merge-queue.py`: stdlib `unittest` with a fake `gh`/`git` runner (no
  network). Negative controls at minimum: stale `main` triggers update; run on wrong SHA,
  wrong event, unapproved runner, missing `ELZOO CHECK PASSED`, affected-mode marker,
  failed or cancelled run; `main` moves during the check; draft, fork or non-task branch;
  the rebase flag is never passed; the merge always uses `--match-head-commit`.
- Review controls: missing/failed/wrong-SHA Gleam runs, canonical main identity,
  and malformed API responses respect stop/continue while never merging on error.
- Run it in CI next to `scripts/test-ci-runners.py`.

## Acceptance

- [ ] Guard tests, the new queue tests and full `mix check` pass; CI on the PR head and on
      the merge commit, with runner identity shown.
- [ ] One real queue run on a real PR (this PR may be merged by the queue itself): show
      the dispatched run, its runner and the merge SHA.
- [ ] Evidence that a second push to `main` no longer cancels the first full check (a
      config read plus one observed pair of runs, or say plainly that it was not observed).
- [ ] Update `docs/development/10-symbolic-ci.md` and `docs/development/01-workflow.md`
      (coordinator merge step). Add this body at `tasks/ELZ-039-merge-queue.md`.
- [ ] Independent review of the actual diff.

## Limits

- The queue is serial. It does not make one full check faster (about 35 min now).
- It is a coordinator convenience, not an enforced gate: someone can still merge by hand.
  Free-plan branch protection cannot enforce it.
- No claim about host isolation or a hostile PR (see ELZ-044, #76).
