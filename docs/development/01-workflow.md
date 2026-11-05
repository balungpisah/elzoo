# Development workflow

Elzoo uses a small visible workflow made from Git, GitHub and Mix. There is no
custom task engine, lease database or Zoo lifecycle to operate. The GitHub
issue body is the task Contract; the remote task branch is the claim.

## Pick and claim

The coordinator publishes tasks/ELZ-*.md as issues in the configured private
remote. A task is ready only when every dependency ID in its body is merged.
Labels task, ready, claimed, blocked and P0 through P3 are advisory. Read the
body and current issue/PR state before acting.

Claim a deterministic branch, never an agent-suffixed branch:

    export ELZOO_AGENT="$(hostname -s)-$(od -An -N2 -tx1 /dev/urandom | tr -d ' ')"
    git fetch origin --prune
    git worktree add ../elzoo-ELZ-003 -b task/ELZ-003 origin/main
    cd ../elzoo-ELZ-003
    mkdir -p .claims
    # write .claims/ELZ-003.md with ID, issue, ELZOO_AGENT, UTC and base SHA
    git add .claims/ELZ-003.md
    git commit -m "claim ELZ-003"
    git push --set-upstream origin HEAD:refs/heads/task/ELZ-003

The first successful branch-create push wins. A rejection is a lost race;
never force-push or reset the winner's branch. Comment on the issue only after
the push succeeds, naming branch and claim SHA. Remove the marker in a later
commit before the PR; retain its claim commit in history.

If a branch already exists, request a handoff or choose another issue. Stale
work uses docs/development/05-stale-claims.md, not a silent takeover.

## Work and sync

Read the task, dependency issues and architecture Contract. Keep a Piece's
interface and assumptions explicit. Pure transitions do not perform I/O;
Effects go through Adapters with declared Needs. Preserve existing behavior
and evidence. A wrong Contract is an issue finding requiring deliberate
correction, not a reason to weaken a law.

Use targeted tests while iterating:

    mix test test/path/to/relevant_test.exs

When main advances, merge rather than rewrite the task branch:

    git fetch origin --prune
    git merge --no-ff origin/main
    git push

Push progress commits and comment on the issue at least every 24 hours with
latest SHA, last green command, current limits and next action. A pushed branch
or draft PR publishes work for coordination; only a merged PR changes main and
satisfies task acceptance.

## Verify

On a new checkout or after dependency/config changes:

    mix setup
    mix check

The project runtime/tooling path owns these public commands. They must use Cure commit
a004c335cc4e9f2203ba6f51fc31e8540b66378d, Elixir 1.20.4 and OTP 29.1.2.
mix check must compile real Cure, execute selected Cure proofs, meaningful
runtime tests and negative controls. It is not documentation or formatting
lint. Targeted tests are feedback; report the full mix check before review.

The task decides which proofs and scenarios are selected. No finite test set
silently becomes a universal proof, and no external library is required to
carry a Cure proof. Record versions, commands, output and limits in the PR.

## Review, merge and cleanup

PR bodies include stable ID, dependency status, changed Contract, exact checks,
an evidence table and limits. The author cannot be the sole reviewer. GitHub
self-approval may be unavailable when workers share an account; a separate
agent/session records its agent ID, reviewed SHA and findings in a PR comment.
Independent review is required for Cure Contracts/proofs, typed composition,
Effects/Adapters, durability, delivery or backpressure, toolchain pins and
evidence claims. Low-risk prose or mechanical test changes may use ordinary
maintainer review. Review must inspect the diff; a ceremonial approval is not
grounding. When no dedicated coordinator is active, the worker coordinates
independent review and the integration handoff rather than waiting idle for an
owner.

After checks and required review, the coordinator merges through GitHub, checks
acceptance on the merge SHA, deletes the merged remote/local branch, removes
the worktree, checks a clean status and closes the issue with PR/SHA. Retain
unmerged branches with a precise resume note.

## Blocked work

Comment exact blocker, command/output, environment, last green commit and the
decision needed. Keep the branch available for handoff. Do not mark an
unmerged dependency as an implementation failure or lower the Contract to
obtain green output.

“Coordinator” is a role for the active task, not a required permanent service
or person. If no separate coordinator is assigned, the worker performs the
integration steps after obtaining the required independent review.
