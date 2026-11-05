# Review, merge and cleanup

The Pull Request is the review boundary. Its body names the ELZ task ID,
dependency status, changed interface/Contract, evidence table, exact commands,
limits and upstream assumptions. The coordinator checks acceptance on the
merged commit.

## Independent review

Independent review is required for:

- Cure interfaces, laws or proof fixtures;
- typed composition, ports, envelopes or wiring;
- Effects, Adapters or external-library translation;
- durability, replay, storage or delivery;
- retries, backpressure or error classification;
- toolchain pins, mix check behavior or evidence labels.

Routine prose, formatting and a mechanical test addition may use ordinary
maintainer review. This is risk-based, not a ceremony. The author cannot be
the sole reviewer. When GitHub workers share an account, do not require a
second-account approval or attempt self-approval: a separate agent/session
records its agent ID, reviewed SHA and findings in a PR comment. A review must
inspect the actual diff and whether wording matches evidence; a ceremonial
approval is not evidence. If no dedicated coordinator is active, the worker
coordinates this independent review and the integration handoff.

## Reviewer questions

1. Does implementation satisfy the issue Contract without widening it?
2. Are pure decisions separated from Effects and Adapters?
3. Does the typed boundary reject the named incompatible case?
4. Do selected proofs exercise the transition actually used?
5. Do tests cover named success, replay/restart, overflow and errors?
6. Are upstream assumptions version-pinned and honestly labelled?
7. Does the PR preserve behavior and avoid upgrading evidence in prose?
8. Is the task narrow enough to reuse and merge?

## Cleanup

After checks and review, the coordinator merges through GitHub, records the
merge SHA on the issue, then removes the merged worktree and branches:

    git switch main
    git pull --ff-only origin main
    git worktree remove ../elzoo-ELZ-003
    git branch -d task/ELZ-003
    # GitHub normally auto-deletes the merged remote branch. If still present:
    if git ls-remote --exit-code --heads origin task/ELZ-003 >/dev/null; then
      git push origin --delete task/ELZ-003
    fi
    git status --short

Deletion is only for a merged task. A rejected or paused PR keeps its branch
and receives a precise resume note.

Use a merge commit, preserving claim and implementation history. The repository
disables squash/rebase merging so normal `git branch -d` can recognize accepted
work. Run cleanup from the main checkout after its fast-forward update.

“Coordinator” is a role for the active task, not a required permanent service
or person. If no separate coordinator is assigned, the worker performs the
integration steps after obtaining the required independent review.
