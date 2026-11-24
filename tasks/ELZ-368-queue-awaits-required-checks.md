# ELZ-368 — The merge queue waits for every required check on the exact head before it merges

- Dependencies: ELZ-277

## Outcome and scope

Defect #887. When `scripts/merge-queue.py` judges that the Gleam run is not
required for a pull request (no Gleam path changed), it merges once the
evidence of the backend run is complete. But `gleam-hosted` is a required
status check on `main`, and that job still runs on every pull request. While
it runs, branch protection refuses the merge with "the base branch policy
prohibits the merge". This happened on PR #877 at head f02dfea4 (merge
evidence from `check-hosted` at 06:20:52Z, `gleam-hosted` green only at
06:23:28Z) and on PR #881 at head 65d099b5. A second queue run on the
unchanged head merged each one.

After this task, before it calls `gh pr merge`, the queue waits until each
required status check of `main` has completed on the exact head, including
`gleam-hosted` when the Gleam run is not required. If one does not pass, the
queue stops with a clear message and does not merge.

This is a CI/queue change: a coordinator-owned non-Piece change on the
one-PR path (`AGENTS.md` section 1). Publication and implementation share
one `task/ELZ-368` pull request. It takes the full/affected local gate and
the full hosted check.

Owned paths:

- `scripts/merge-queue.py`
- `scripts/test-merge-queue.py`
- `docs/development/10-symbolic-ci.md` (the paragraph "Gleam gate only for
  Gleam paths", which says that the queue does not wait for `gleam-hosted`)

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `docs/plans/views.md` and
`docs/plans/dependencies.mmd`. No Piece, manifest, catalogue entry,
dependency, pin, workflow file or runner label changes.

## Required behavior

1. Before the merge, the queue reads the required status checks of `main`
   from the branch of the canonical repository
   (`GET repos/balungpisah/elzoo/branches/main`,
   `protection.required_status_checks.checks`, each a `context` and an
   `app_id`). Today they are `check-hosted` and `gleam-hosted` of the GitHub
   Actions app. An unreadable or malformed list refuses the merge.
2. For each required check, the queue lists the check runs of that name on
   the exact head SHA (of that app when the check names one; a null or -1
   app ID means any source). The newest check run (highest ID) decides.
   While there is none, or the newest has not completed, the queue waits,
   within the existing per-PR deadline; at the deadline it stops with
   `Timed out: required check <name> ...`.
3. When the newest check run has completed with a conclusion other than
   `success`, the queue stops with a message that names the check, the
   check run, the head and the conclusion, and does not merge.
4. The wait comes before the existing pre-merge checks (the re-read of the
   pull request, the fetch against `main`, the re-classification, the newer
   run check and the freeze check), so the merge never rests on a state
   read before a long wait.
5. Unchanged: which runs and jobs are evidence, the full, docs-only, Piece
   and spike modes, the Gleam evidence when a Gleam path changed, the
   dispatch fallback, the merge command and `runs-on`.

## Acceptance and evidence

1. Guard tests in `scripts/test-merge-queue.py`: with no Gleam path and a
   `gleam-hosted` check run in progress, the queue waits and merges only
   after it completes, with the pre-merge checks read after the wait; a
   check that has not started is awaited; a red, cancelled, skipped or other
   non-success conclusion of either required check stops without a merge; a
   check that never completes times out without a merge; the newest check
   run decides; check runs of another head, name or app do not count; the
   list comes from the protection of `main`; an unreadable list or listing
   refuses.
2. A negative control by a temporary edit (the wait removed), with the
   failing tests recorded and the edit reverted.
3. A read-only run of the new wait against the real API on the heads of
   #877 and #881.
4. The full local gate for scripts (`mix check --affected origin/main`,
   which selects everything for scripts) and `git diff --check`, on a
   disposable database.
5. One independent review; exact-head hosted full check green; the
   automated reviewer's gate; mark ready. The coordinator runs the queue.
