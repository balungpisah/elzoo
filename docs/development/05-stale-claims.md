# Stale claims and handoff

The deterministic task branch is the claim. GitHub labels/comments do not
replace it. A claimant posts a heartbeat at least every 24 hours with the
latest commit and next action.

After 48 hours with no heartbeat:

1. the coordinator comments STALE-CHECK and mentions the claimant;
2. the coordinator checks for an open PR, recent remote commits and a handoff;
3. the claimant gets at least another 24 hours to respond;
4. a response records a handoff and the next worker continues the existing
   branch;
5. with no response, the coordinator first adopts the existing branch: the
   new worker fetches its tip, records the handoff in an issue comment
   (branch, tip SHA, new agent identifier) and continues the branch with
   normal fast-forward pushes.

No worker force-pushes or silently deletes a claimed branch. Deleting an
unmerged branch is not the default. If a branch truly cannot be adopted, the
coordinator first creates and verifies a real archive ref on the same remote
from the exact remote tip, records that archive ref and reason in the issue,
and only then deletes the task branch. If the remote tip changes while
archiving, abort and reconcile rather than deleting concurrent work. Only
after the archive ref is verified may a new task/ELZ-### claim start from main.

For the exceptional archive path, fetch the branch, capture its exact remote
tip, push a new archive ref at that commit, verify the archive ref, and compare
the task branch again before deletion. For example, with the task ID and UTC
stamp filled in explicitly:

    git fetch origin task/ELZ-001
    tip=$(git rev-parse refs/remotes/origin/task/ELZ-001)
    git push origin "$tip:refs/heads/archive/ELZ-001-UTC-$tip"
    git ls-remote origin refs/heads/archive/ELZ-001-UTC-$tip
    git ls-remote origin refs/heads/task/ELZ-001

The coordinator must confirm the archive ref resolves to tip and that the task
branch still resolves to the captured tip. If either check differs, stop and
reconcile; do not delete. The issue records the archive ref before the final
delete. The deletion must also compare the expected tip atomically, closing
the race between inspection and deletion:

    git push --force-with-lease=refs/heads/task/ELZ-001:$tip origin :refs/heads/task/ELZ-001

This exact-tip lease is only for the documented archive-and-delete exception;
it never authorizes rewriting task history. A refusal means the branch moved:
keep it, inspect the new work, and repeat the handoff decision.

A technical blocker is not stale work. Report the command/output, environment,
last green commit and decision needed; keep the branch for a future worker. A
task waiting on an unmerged dependency is not ready.
