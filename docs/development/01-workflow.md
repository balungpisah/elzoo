# Development workflow

Elzoo uses a small visible workflow made from Git, GitHub and Mix. There is no
custom task engine, lease database or Zoo lifecycle to operate. The GitHub
issue body is the task Contract; the remote task branch is the claim.

## Pick and claim

Select from the [product-led roadmap](../plans/roadmap.md). A published,
admitted Piece can serve a concrete product aim before a new Assembly example
exists. This changes selection, not acceptance: caller/invariant/failure paths,
reuse-first boundaries, explicit Needs and evidence still apply. The canonical
planning manifest owns planning statuses and dependencies; generated views
replace manually edited status boards. Live issue Contracts override snapshots.

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
208248063d64e621782cd26dd30698ee42850a89, Elixir 1.20.4 and OTP 29.1.2.

mix check also needs a disposable PostgreSQL database for the
`integration/sql` tests (ELZ-009). Point `ELZOO_TEST_DATABASE_URL` at a
throwaway local database, never a production or personal one:

    export ELZOO_TEST_DATABASE_URL=ecto://elzoo_test:…@localhost/elzoo_test

Use your own throwaway local role and password; no password is recorded in this repository. The CI jobs create
their own role and database for each job.

Without it, or when it is unreachable, those tests fail closed; they are never
skipped.
mix check must compile real Cure, execute selected Cure proofs, meaningful
runtime tests and negative controls. It is not documentation or formatting
lint. Targeted tests are feedback; report the full mix check before review.
The default retains every independent consumer, including the full aggregate.
For explicit PR-style iteration, `mix check --affected origin/main` selects
affected fixed per-ID consumers; the aggregate also runs if any affected ready
ID is outside their dependency closures. All other root checks remain.
Shared/unknown changes or unavailable comparison data select all fixed
consumers and the aggregate. This subset is not full acceptance; see the selection policy and
limits in [CI on user-owned machines](10-symbolic-ci.md#affected-consumer-checks-elz-038).

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

After checks and required independent review, the coordinator runs the local
[merge queue](10-symbolic-ci.md#coordinator-merge-queue-elz-039) from this
repository with the coordinator's own `gh` login:

```sh
python3 scripts/merge-queue.py 79 80
```

Use the actual reviewed PR numbers, in integration order. The tool merges main
into an out-of-date task branch, dispatches a full backend check on the exact
head, validates its result and runner, also requires Gleam PR success on that
exact head, and rechecks canonical main before a head-guarded merge. A changed
head needs review of the new diff; this tool does not inspect
or replace independent review. It stops on failure by default. A PR affected
check, even green, is not the queue's full pre-merge evidence.

The coordinator still checks acceptance on the merge SHA (including backend
and Gleam CI), deletes the merged remote/local branch, removes the worktree,
checks a clean status and closes the issue with PR/SHA. The tool performs none
of these cleanup/acceptance steps. Retain unmerged branches with a precise
resume note. Manual merging remains possible; the queue is not enforced
branch protection.

## Blocked work

Comment exact blocker, command/output, environment, last green commit and the
decision needed. Keep the branch available for handoff. Do not mark an
unmerged dependency as an implementation failure or lower the Contract to
obtain green output.

“Coordinator” is a role for the active task, not a required permanent service
or person. If no separate coordinator is assigned, the worker performs the
integration steps after obtaining the required independent review.
