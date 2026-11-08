# AGENTS.md

Elzoo is a fresh Cure/Elixir catalogue. It is not a port of the old Zoo
command set or task lifecycle. Use ordinary Git, GitHub issues, Git worktrees,
Pull Requests and Mix.

## Read order

For ongoing task work, read from the repository root:

1. CONTEXT.md for the locked vocabulary.
2. GOAL.md and docs/development/01-workflow.md.
3. docs/development/02-task-dag.md, docs/plans/roadmap.md and its canonical
   manifest, then the selected tasks/ELZ-*.md body and live issue Contract.
4. docs/capability-model.md, docs/capability-coverage.md and docs/operational-contracts.md,
   docs/adr/0005-ash-foundation-and-upstream-first.md, then LEDGER.md,
   docs/consuming.md, docs/architecture.md and relevant ADRs.
5. The selected piece.json and README; mix.exs and the relevant pieces/, lib/
   and test/ sources only as needed.

PLAN.md, GATES.md and gates/*.md describe the one-time bootstrap and are
required when integrating or checking bootstrap work. They are not a
permanent lifecycle or a prerequisite for every later task; the selected task
body defines ongoing scope, ownership and acceptance.

## Mission and boundaries

Build only the next reusable Piece or Assembly admitted by a published issue
for a concrete product aim. A useful Piece need not wait for a new Assembly
example; selection follows docs/plans/roadmap.md and its canonical manifest.
Cure owns new pure decisions when suitable. Elixir/OTP and maintained
libraries own runtime and integration work. Effects happen in explicit
Adapters; pure Operators do not perform I/O. Keep Needs, delivery and storage
assumptions, and unspecified behavior visible in the Contract.

The bootstrap established one honest exemplar and its supporting pieces. The
product-led roadmap selects further independently useful Pieces with explicit
callers, invariants and failure evidence; new integration examples may follow
later. It does not promise all of the old Zoo catalogue or all 402 historical
patterns. Open new batches for admitted product needs, not to fill a quota.
Use Enum/Stream for ordinary transformations and reuse maintained storage or
job providers before considering a new implementation. Stay on upstream releases
unless a concrete modification is needed. Maintained MIT-library forks belong
under balungpisah, preserve upstream notices/provenance and carry tests for our
changes; follow docs/development/08-upstream-and-forks.md. Do not fork merely
because a library is MIT-licensed.

Each published task body defines its scope and reviewer/merge responsibility.
Keep edits within that scope; include a necessary shared change explicitly in
the issue and coordinate overlapping work before editing the same boundary.

## Pick a task

The coordinator publishes each tasks/ELZ-*.md file as a GitHub issue whose
title starts with its stable ID. The issue body is the task contract and source
of truth for dependencies and acceptance. Use the configured private remote,
normally balungpisah/elzoo:

    gh issue list -R balungpisah/elzoo --state open --label task \
      --json number,title,labels,body

Choose an issue only when every dependency is merged and there is no active
claim. Labels task, ready, claimed, blocked and phase labels P0 through P3 are
status signals, not the lock. A dependency that is merely in a PR is not
complete.

## Claim: the Git push is the lock

There is one deterministic branch per task: task/ELZ-001 for ELZ-001. Never
add an agent suffix and never force-push a task branch. Two agents may prepare
locally, but only the first branch-create push can succeed.

1. Fetch the base and check the remote branch:

       git fetch origin --prune
       if git show-ref --verify --quiet refs/remotes/origin/task/ELZ-001; then
         echo "claimed"
         exit 1
       fi

2. Make an isolated worktree and deterministic branch from origin/main:

       git worktree add ../elzoo-ELZ-001 -b task/ELZ-001 origin/main
       cd ../elzoo-ELZ-001

3. Before implementation, create .claims/ELZ-001.md containing the stable ID,
   issue number, GitHub login, a distinct per-session agent ID, UTC time and
   base SHA. Generate the session ID once before any claim:

       export ELZOO_AGENT="$(hostname -s)-$(od -An -N2 -tx1 /dev/urandom | tr -d ' ')"

   Commit the marker as claim ELZ-001 and push:

       git add .claims/ELZ-001.md
       git commit -m "claim ELZ-001"
       git push --set-upstream origin HEAD:refs/heads/task/ELZ-001

   A rejected push means another worker won. Do not retry with force; remove
   the losing worktree and choose another ready issue. The winner comments on
   the issue with branch and claim SHA.

4. Remove .claims/ELZ-001.md in a later commit before opening the PR, while
   retaining the claim commit in history. Claim metadata must not merge to
   main. CI runs `python3 scripts/check-claims.py` and rejects any tracked
   file under `.claims/`, including hidden markers.

The claim commit is not implementation evidence. If a branch already exists,
request a handoff in the issue and use it only after a handoff is recorded under the stale-work protocol.

## Work, sync and progress

Read the whole task and dependencies. Preserve existing behavior and claims.
Clearer wording is not stronger evidence: do not upgrade a finite test into a
universal proof or an upstream contract into a local proof. If the Contract is
wrong or incomplete, stop and record the finding; change the Contract and
acceptance deliberately with review rather than weakening a law.

Keep changes scoped and use small explanatory commits. When main advances,
fetch and merge origin/main into the task branch without rewriting history:

    git fetch origin --prune
    git merge --no-ff origin/main
    git push

Push implementation commits and leave an issue comment with the latest SHA,
last green command and next action at least every 24 hours. A draft PR is a
useful resume note; it is not acceptance on main. The task branch publishes
work for coordination, while only a merged PR changes main and satisfies the
task.

For unsafe effects, storage, delivery, backpressure and typed boundaries,
request independent review early. Do not edit generated files or unrelated
ownership areas.

## CI machine policy

CI must run only on the owner's machines: the user-owned symbolic and
macbook-ubuntu, and the user-rented Contabo VPS runner contabo-elzoo-1 (owner
decision 2026-11-08; unrouted, for measurement runs a person steers), with pull request
checks and queue runs on the fast runners only, in the roles defined in
docs/development/10-symbolic-ci.md. Use the explicit
self-hosted selectors and runner identity checks documented there.
While the repository is private, never use or fall back to GitHub-hosted runners:
the owner does not have hosted minutes available. Once the repository is public
(owner decision 2026-11-09), CI runs on the GitHub-hosted lane that the
repository variable ELZOO_CI_LANE selects (docs/development/10-symbolic-ci.md,
"Lanes"); the self-hosted lane is retiring, and self-hosted runners must never
stay attached to a public repository. If a runner is offline, diagnose its
service/queue; do not change runs-on to a hosted image outside the documented lane. Verify actual job runner identity when
changing workflows. GitHub still provides repository/PR/check orchestration.

## Verify the actual claim

On a clean checkout or after dependency/configuration changes, run:

    mix setup
    mix check

The project runtime/tooling path owns these public commands. mix setup must use Cure commit
208248063d64e621782cd26dd30698ee42850a89, Elixir 1.20.4 and OTP 29.1.2.
mix check must compile real Cure, run selected Cure proofs, meaningful runtime
tests and negative controls. It is not a formatter or documentation badge.
Targeted mix test commands are iteration feedback; report full mix check before
review. Do not claim a pass if the command was not run or a moving Cure ref
was used.

Every PR separates its grounding:

- Proof: a selected quantified or exhaustive Cure law checked by Cure's
  machinery. Only laws named by the task are required.
- Type/contract check: the actual Cure type or schema validation performed by
  a named checker. An unchecked Elixir typespec is documentation.
- Test: an executable ExUnit/OTP or boundary check over named scenarios.
  Tests are not automatically proofs.
- Monitored behavior: telemetry, logs or an observation in a named environment.
  A monitor is not a proof of all executions.
- Upstream contract: pinned Cure, Elixir, OTP or library behavior relied upon.
  External implementation remains upstream's work; test our translation.

Record unverified assumptions separately; naming one does not prove it.

Use scoped wording such as selected law passes, listed scenarios pass, or
relies on OTP's documented contract. Unqualified verified is not evidence.

## Review, merge and cleanup

Open a PR from task/ELZ-001 only after the branch is self-contained. Include
the issue ID, dependency state, changed Contract, proof/test/upstream evidence,
exact commands and outputs, and limits. The author cannot be the sole
reviewer. GitHub may reject self-approval when workers share an account; use a
separate agent/session to inspect the diff and record its agent ID, reviewed
SHA and findings in a PR comment instead of trying to self-approve.

Independent review is required for Cure Contracts/proofs, typed composition,
Effects/Adapters, durability/storage, delivery/backpressure, toolchain pins or
evidence claims. It is optional for straightforward prose or mechanical test
changes. Reviews must inspect the actual diff and claim scope; a ceremonial
looks-good is not grounding. When no dedicated coordinator is active, the
worker coordinates an independent agent review and the integration handoff
instead of waiting idle for an owner.

The coordinator merges only after checks and required review:

1. resolve findings and rerun relevant checks;
2. merge through GitHub, never rewrite main;
3. verify acceptance on the merge commit (including its CI result: its own green full run, or a push run that
   logs `ELZOO PUSH CHECK SKIPPED` with the passed exact-head run and job IDs, see docs/development/10-symbolic-ci.md);
4. delete the merged remote and local task branch;
5. remove the worktree and confirm git status --short is empty;
6. close the issue with PR and merge SHA.

Do not delete an unmerged branch merely to make the list clean. Leave a
precise issue note with last green command and next action.

## Blocked and stale work

For a technical blocker, comment the exact command, output, environment,
last green commit and decision needed. Do not weaken the Contract. An
unmerged dependency is not an implementation failure; the task is not ready.

The branch is the claim. Post a progress heartbeat every 24 hours. After 48
hours without one, the coordinator comments STALE-CHECK, mentions the claimant
and waits at least another 24 hours. A stale notice alone does not authorize
force-push or deletion.

If the claimant responds, record a handoff and continue the existing branch.
If there is no response, the coordinator first adopts the existing branch: the
new worker fetches its tip, updates the claim marker in a handoff commit and
pushes that commit as a normal fast-forward. Deleting an unmerged branch is
not the default. If a branch truly cannot be adopted, the coordinator must
first create and verify a real archive ref on the same remote from the exact
remote tip, record that archive ref and reason in the issue, and only then
delete the task branch. If the remote tip changes while archiving, abort and
reconcile rather than deleting concurrent work. A new worker chooses another
issue while handoff is unresolved.

## Report format

    ELZ-###: <short outcome>
    Branch/PR: <name and link>
    Checks: <exact commands and pass/fail>
    Grounding: <proofs; tests; monitored behavior; upstream contracts>
    Limits: <claims deliberately not made>
    Open work: <issue IDs or none>

Do not report complete until merged commit and cleanup are visible.

“Coordinator” is a role for the active task, not a required permanent service
or person. If no separate coordinator is assigned, the worker performs the
integration steps after obtaining the required independent review.

## Source catalogue rules

Use pieces/<family>/<name>/ with conventional lib/, cure/, test/ and examples/
paths. Per-piece JSON owns ready source lists, dependencies and claim-level
grounding; registry/catalogue.json also records planned/deferred gaps. Do not
create placeholder implementations for planned entries or wrappers around
ordinary upstream APIs just to fill directories.

After changing metadata, run mix elzoo.ledger; mix check rejects stale output,
missing evidence/source, provider-pin drift and invalid dependencies. Keep the
copying contract tested: the root Application must never be required by a
consumer. A renamed/moved source needs corresponding import, export-manifest,
proof/test and documentation changes. Apache-2.0 covers Elzoo-owned source;
record upstream licenses separately. Evidence applies to the recorded source
and named claims, not arbitrary downstream edits.

## Evolving a ready Contract

A ready Piece ID identifies a stable behavioral Contract. A change to accepted
inputs, outputs/data shape, state/lifecycle, delivery or failure guarantees, or
required Needs must use a **new Piece ID** with its own Contract and evidence.
Keep the old ID usable, document the difference/migration in both README and
ledger metadata, and make consumers opt in by changing dependency IDs. An
implementation bug fix that restores the existing Contract, or a correction to
evidence wording without changing behavior, keeps the ID and records the reason.
Do not silently broaden or weaken a ready Contract under an existing ID.
`schema_version` versions the metadata format, not a Piece Contract. Receipts
already retain the Piece IDs, Contracts, origin revision and file hashes.

Pure source copies use an application-owned namespace; follow docs/consuming.md.
Libraries redistributing copies must rename modules/MFAs and resolve public
record-tag collisions before shipping. Distinct IDs do not automatically make
conflicting BEAM modules or erased records safe to load together.

## Before expanding the catalogue

Declare Telemetry, Config and Control applicability for every ready Piece in
piece.json; follow docs/operational-contracts.md. Supported, inherited,
not_applicable and planned are distinct. A static or per-call setting does not
establish hot reconfiguration; an OTP stop does not establish business drain.
Keep observations separate from durable control receipts and accounting data.
No UI language or Gleam dependency is implied by these contracts.

Use the admission/split rules in docs/capability-model.md. Choose a concrete
coverage case or equally explicit new workflow, state its invariant and failure
paths, and check upstream reuse before authoring new policy. Inventory coverage
is not a build queue: deferred domain handles have no implicit implementation
order. Do not promote a library candidate to ready without exercising its exact
boundary. Work Items, Runs and Attempts are distinct; shared schemas do not
establish matching authority, durability or delivery semantics. Agent orchestration
is an Assembly of capabilities, not a privileged execution kernel.
