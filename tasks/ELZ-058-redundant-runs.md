# ELZ-058 — Remove redundant full CI runs without weakening the evidence

- Phase: P0 harness (CI; `.github/workflows/symbolic-check.yml`, `scripts/merge-queue.py`,
  `scripts/test-merge-queue.py`, `scripts/check-ci-runners.py`, `scripts/test-ci-runners.py`,
  `docs/development/10-symbolic-ci.md`, the acceptance sentence of `AGENTS.md`)
- Catalogue IDs: none
- Dependencies: ELZ-057 (#95, merged at `ade0e45`), ELZ-049 (#89, merged) and ELZ-039 (#78, merge
  queue) merged; serial on the same files. ELZ-044 (#76, structural guard) comes after this task
  and is not a dependency.
- Review: independent review of the workflow, guard and queue diff is required.

## Outcome

One merge costs several full checks on the same content. Run 42458730941 (queue exact-head run,
success), then the push run 42461141823 on the merge commit `452caa1` (23 min 01 s on `symbolic`)
checked a tree that is identical to the exact head that already passed. Owner decision
2026-11-08 ("go"): remove the redundant runs, keep the evidence.

## Scope

Dropped on 2026-11-08 by the coordinator: the earlier item 2 (the queue adopts a green full-mode
`pull_request` run instead of dispatching), because ELZ-059 makes pull request runs light, so a
pull request run is never exact-head full evidence. The queue keeps dispatching as today.

1. Main push job. For a push to `main` whose head commit is a merge commit, compare
   `git rev-parse HEAD^{tree}` with `git rev-parse HEAD^2^{tree}`. If they are equal, and the
   second parent's exact-head run by the queue is a passed `check-fast` run (workflow, event, branch and
   `head_sha` identified as the queue identifies it), the job records that run ID and job ID in its
   log and ends green without `mix check`. Every other case runs the full check exactly as today:
   not a merge commit, trees differ (main moved), no matching passed run, any API or Git failure.
   Fail closed: an ambiguity means a full run, never a skip.
2. Workflow permissions. Step 1 needs to read check runs of the second parent. Accept the least
   that works (expected: `actions: read` on the push job `check-any` only; the pull request job and
   the top-level block keep `contents: read`). A `permissions:` change is a trust-model change and
   goes through the guard and review.
3. Queue cancels the duplicate pull request check (coordinator addition, owner-driven; observed cost 20
   minutes of `symbolic-elzoo` per queue update, run 42478439366 cancelled by hand). When
   `scripts/merge-queue.py` updates a PR branch by merging main (`gh pr update-branch`), GitHub starts a
   `pull_request` check on the new head; the queue then dispatches its exact-head run on that same head, so
   the PR check is a duplicate. Right after the update, and before or alongside its dispatch, the queue
   cancels that run (same head SHA, `pull_request` event, this workflow, nothing else) and logs the
   cancelled run ID. Tests: only the exact head is cancelled, never another PR, another head, a dispatch or a
   push run; a failed cancel is logged and does not block the queue. Note: with ELZ-059 the pull request
   run is light, so the cancelled run is only an early signal; the queue's exact-head dispatch stays the
   merge gate.
4. Guard and tests. Update `scripts/check-ci-runners.py` and `scripts/test-ci-runners.py` to accept
   exactly the new steps and permissions. Existing tests are not edited or weakened; edits forced by
   the new shape are listed in the PR for the owner's approval.
5. Docs. `docs/development/10-symbolic-ci.md` explains what is skipped, why the evidence is the same
   (identical tree plus a passed exact-head full run, with run and job IDs in the push log) and
   what it does not cover (the push run no longer observes the merge commit's environment or a
   different runner or cache state). The merge-commit acceptance sentence in `AGENTS.md` states the
   new rule.
6. Measure. Fast-runner minutes per merge before and after, over the next five merges: queue run
   minutes, push run minutes, pull request run minutes, with run IDs. Record the table in the issue.

## Acceptance

- [ ] A merge whose tree equals the second parent's tree skips `mix check` on the push run and logs
      the run ID and job ID of the passed exact-head run (live observation, run IDs recorded).
- [ ] A merge where main moved still runs the full check (negative control, observed or tested).
- [ ] A queue update of a pull request branch cancels the duplicate `pull_request` run of the exact head
      (live observation, run ID logged) and cancels nothing else; queue tests cover it.
- [ ] Guard tests pass with the new controls; the old guard rejects the new workflow.
- [ ] Independent review of the actual diff (separate agent session, reviewed SHA on the PR).
- [ ] Full `mix check` on the PR head; the five-merge measurement table in the issue before close.

## Limits

An identical tree is not an identical environment: a skipped push run proves nothing about the
runner, cache or toolchain state at merge time. The queue still depends on the coordinator's
`gh` authentication. Missing logs or API errors always lead to a full run or a refusal.
