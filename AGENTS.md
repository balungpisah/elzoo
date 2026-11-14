# AGENTS.md

Elzoo is a catalogue of reusable Cure/Elixir Pieces. A developer copies a Piece
into an application and owns the copy. This file is the whole workflow for an
agent. If a file under `docs/development/` disagrees with it, this file wins.

The tools are Git, Git worktrees, GitHub issues, pull requests and Mix.

    pick -> claim -> build -> local gate -> pull request -> one review -> merge

One task is one branch, one worktree, one worker and one pull request.

## 1. Read this, and no more

1. This file.
2. [CONTEXT.md](CONTEXT.md): the vocabulary.
3. Your task: the GitHub issue body. It is the Contract of the task.
4. `piece.json` and `README.md` of each Piece that the task names.

Open one of these only when the task touches its subject:

| Subject | Document |
| --- | --- |
| Proof, test and evidence wording | [claims and evidence](docs/development/03-claims-and-evidence.md) |
| Ports, Envelopes, delivery semantics | [architecture](docs/architecture.md) |
| Telemetry, Config and Control declarations | [operational contracts](docs/operational-contracts.md) |
| Copied source, namespaces, receipts | [consuming](docs/consuming.md) |
| A new capability, or a split of one | [capability model](docs/capability-model.md) |
| Cure language traps | [Cure notes](docs/cure-notes.md) |
| A fork of a library | [upstream and forks](docs/development/08-upstream-and-forks.md) |
| Local test services | "Verify" in [workflow](docs/development/01-workflow.md), and `.agents/setup` |
| CI, workflows, the merge queue | [CI guide](docs/development/10-symbolic-ci.md) |

Do not read `PLAN.md`, `GATES.md` or `gates/` (the one-time bootstrap) or
`docs/work/` (old task logs). Do not read `LEDGER.md` or
`docs/plans/release-plan.json` from top to bottom: search them for your Piece ID.

### Choose the flow

Classify paths with `scripts/ci-change-class.py`; mixed or unclear changes take
the heavier gate. Every implementation PR keeps one independent review
(section 6), an exact-head hosted check and the merge queue (section 7).
Separate publication PRs keep the coordinator merge path (section 9).

| Change | Publication and claim | Local gate → hosted check |
| --- | --- | --- |
| New or changed Piece Contract | New capability: coordinator publishes the new Piece ID first; then claim (sections 2–4, 9). Changed Contract of a ready Piece before the first release: a published task on the same ID (section 4) | Piece gate below; from the first release never reuse an old ID for a new Contract |
| Piece-only implementation | Published task, claim, implementation PR (sections 2–3) | Small gate (section 5) → `check-piece`; full check on main covers omitted tests |
| Documents only | Published task or coordinator one-PR path below; claim | Roadmap/claims checks and diff check → docs-only check; no executable inputs changed |
| Spike only, including dependencies or pins confined to the spike's own files (`mix.exs`, `mix.lock`, etc.) | Own task; published or coordinator one-PR path; claim | Changed spike's own checks and roadmap/diff checks → `check-spike` and Gleam when applicable; root tests do not consume spike contents, full check on main |
| Non-Piece root/shared dependency, advisory or harness repair | Own task; published or coordinator one-PR path; claim | Full/affected gate as section 5 requires → full hosted check; no selected-gate shortcut |
| CI, workflow or queue change | Same non-Piece flow; never docs-only | Relevant guard tests plus full/affected gate → full hosted check; no spike shortcut |

For a coordinator-owned non-Piece change with no output Piece ID or Piece
Contract change, publication and implementation may share one PR: create the
issue from the task file without `task`, claim with the section 2 API lock,
and commit the task, its published job row with live body hash and the change
on `task/ELZ-###`. Close the task issue and the reporting issue if any.
Do not offer it to another worker. All review, gate and queue rules remain.
See the coordinator guide for publication details.

If a local service is unavailable, record the command and reason; the hosted
substitution in section 5 applies, not a lighter change class.

## 2. Pick and claim

    gh issue list -R balungpisah/elzoo --state open --label task --limit 100 --json number,title,body
    git ls-remote --heads origin 'task/ELZ-*'
    gh pr list -R balungpisah/elzoo --state merged --head task/ELZ-098 --json number

A task is ready when no remote branch `task/ELZ-###` exists for it, and each
ID on the `- Dependencies:` line of its body is merged on `main`. The third
command shows that: it must return a pull request for the dependency, or the
issue of the dependency is closed as completed. An open pull request is not
merged. Labels other than `task` are hints only. A task that asks for
something that this file forbids is not ready: comment on the issue and pick
another.

    git fetch origin --prune
    git worktree add ../elzoo-ELZ-123 -b task/ELZ-123 origin/main
    cd ../elzoo-ELZ-123
    gh api -X POST repos/balungpisah/elzoo/git/refs \
      -f ref=refs/heads/task/ELZ-123 -f sha="$(git rev-parse origin/main)"
    git fetch origin --prune
    git branch --set-upstream-to=origin/task/ELZ-123 task/ELZ-123

The `gh api` call is the lock: it refuses a branch that exists. HTTP 422 means
that another worker won. Then remove your worktree and local branch and pick
another task. Do not claim with `git push`: it is not a lock. Write no claim
file (CI rejects `.claims/`), no claim commit and no claim comment.

A claim must show work. Until your pull request is marked ready, push at
least every three hours, unfinished work included. A push starts CI only when
a pull request is open.

## 3. Lanes: how many workers stay safe

**Your lane.** `pieces/<family>/<name>/**` of your Piece, and each path that
the task body lists.

**Shared paths.** `mix.exs`, `mix.lock`, `config/`, `lib/`, the root `test/`,
`pieces/test_helper.exs`, `scripts/`, `.github/`, the directory of another
Piece, and this file. Do not edit a shared path that the task body does not
list. If you need one, stop that part and comment on the issue with the path
and the reason. The coordinator then makes a prerequisite task. A new
dependency or a changed pin is always its own task, and it merges first.
For a spike-local dependency or pin, that task uses the spike-only gate above;
it still merges before any task that depends on it.
Never add a self-hosted runner and never change `runs-on`: the repository is
public.

**Index files.** Change them in one last commit, immediately before you ask
for the merge. This keeps the conflict window short. A later commit that does
not change `piece.json` (for example a format fix) is allowed. The rule is:
`manifest_sha256` equals the SHA-256 of the bytes of `piece.json` at the head.

1. `registry/catalogue.json`, your row: `"status": "ready"` and
   `"manifest": "pieces/<family>/<name>/piece.json"`.
2. `docs/plans/release-plan.json`, your row in `entries`: the same `manifest`,
   `manifest_sha256` (the SHA-256 of the bytes of `piece.json`), `note` (equal
   to `contract` in `piece.json`) and `"disposition": "ready-contract"`. Each
   later edit of `piece.json` needs a new hash.
3. Generate, then check:

       mix elzoo.ledger
       python3 scripts/check-roadmap.py --write
       python3 scripts/check-roadmap.py

If your Piece ID has no row in the two files, stop. The coordinator adds the
rows first (section 9).

`LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd` are
generated. Do not edit or hand-merge them. On a conflict, take the version of
`main`. After each merge of `main` into your branch, run step 3 again, also
when Git reports no conflict.

**Live state.** GitHub holds it. Do not write "claimed", "PR pending" or a
pull request number into `release-plan.json`.

**Local services.** Each worker uses its own disposable PostgreSQL database
through `ELZOO_TEST_DATABASE_URL`. Never share it between two runs. Never use
a personal or production database. At most three workers run Mix on one host
at the same time, and only one full check runs on one database server at a
time (the limit is database connections).

**Git.** Do not force-push. Do not rewrite history. Do not commit on `main`.
When `main` moves and you have a conflict, merge it:
`git fetch origin && git merge --no-ff origin/main`.

**Subagents.** A worker can use subagents to read and to review. Only one
agent writes in a worktree at a time.

- Use a strong reasoning model for coordination, admission, Contract decisions and independent review; a general coding model for implementation; and a fast, low-cost model for mechanical work. Replace an implementation worker that overbuilds with the low-cost model.

## 4. Build

- The issue body decides scope and acceptance. If it is wrong or incomplete,
  stop and comment on the issue. Do not weaken a Contract or a test to get a
  green result.
- Cure owns new pure decisions when it fits. Elixir/OTP and maintained
  libraries own runtime and integration work. A pure Operator does no I/O.
  Effects go through Adapters with declared Needs.
- Use upstream releases and ordinary `Enum`/`Stream` first. Write only the
  policy that is missing. Make no wrapper around an ordinary upstream API and
  no placeholder for a planned entry. Build only what the acceptance scenarios need: no extra layers, frameworks or hooks. Reviewers flag extra layers as findings.
- Take a discovered defect or regression as its own small, scoped task without asking whether to fix it. Follow the claim and shared-path rules; do not fold the repair into unrelated work.
- Layout: `pieces/<family>/<name>/` with `lib/`, `cure/`, `test/`, `examples/`,
  `README.md` and `piece.json`. `piece.json` owns the source list, the
  dependencies, the grounding of each claim and the Telemetry, Config and
  Control declarations.
- Elzoo is not released yet. Until the first release, when a ready Piece
  lacks something that clearly belongs to it, extend, refactor or cut it clean
  in place: same Piece ID, no second Piece for the same job. The task body
  states the changed Contract, and `piece.json`, the README and the index
  rows follow it. A separate capability still gets its own Piece.
- From the first release, a ready Piece ID is a stable Contract. A change of
  accepted inputs, outputs, state, delivery, failure guarantees or Needs gets
  a **new Piece ID**. The old ID stays usable. A bug fix that restores the
  Contract keeps the ID.
- The toolchain pins are in `.tool-versions` and `mix.exs`. Do not change them
  in a Piece task.
- The repository is public. Write no hostname, address, local path, database
  name, credential, session identifier or person's name in a file, a commit,
  an issue or a pull request. Use roles.
- Write a file under `docs/work/` only when the task body names that file as a
  deliverable. The pull request body is the record of the task.
- Test named Contract boundaries adversarially; a first green run alone is not
  enough. Make a negative control by a temporary edit in the worktree, run the
  test, record the failure, then revert the edit. Never commit the edit. A
  scratch copy does not work when the test finds the file by its path.

## 5. Local gate, then pull request

While you build, run the tests of your Piece:

    mix test pieces/<family>/<name>/test

Before you open the pull request, and before each later push to it, run the
local gate. For a Piece task, the local gate is the small gate:

    mix check --piece "$(git merge-base origin/main HEAD)"
    git diff --check

A Piece task changes only files in Piece directories, the index and generated
files of section 3, and documents. `scripts/ci-change-class.py` decides this.
The small gate runs format, compile, the ledger and Registry checks, the tests
of each changed Piece and of each ready Piece that depends on it, the root
tests that read the index, and the per-ID consumers of those IDs. One of the
root tests plans the export of every ready Piece together. A ready Piece that
the change adds (ready at the head, not a ready ID at the base) and that has
no per-ID consumer runs once in a copied consumer of its own: its dependency
closure is copied and compiled, and only its own tests run there, with a limit
of 300 s for that test. The gate still does not see two things. A changed
Piece that was ready at the base and has no per-ID consumer is not exported on
its own before the merge. The tests of the dependencies do not run in the
consumer of the new Piece. It is a selected check, not the full check. It
refuses a change with any other path.

For a change of shared paths, the local gate is:

    mix check --affected origin/main
    git diff --check

For shared paths, `--affected` selects everything. Then it runs each test of
the full check, but its marker still says `AFFECTED`: take the one slot of the
database server (section 3). After a change of `mix.exs`, `mix.lock`,
`config/` or a toolchain pin, run `mix check` with no flag. On a new checkout,
run `mix setup` first.

If a required local command cannot run on the host (for example PostgreSQL 16
with pgvector or MinIO is unavailable), record the command and exact reason
in `Local gate:`. The hosted check is the evidence for that command.

For spike-only changes, run the changed spike's own checks (Ash:
`MIX_ENV=test mix deps.get`, `mix format --check-formatted` and
`mix test --warnings-as-errors` with `MIX_ENV=test`, from its directory;
Gleam: its setup/check scripts), roadmap checks and `git diff --check`.
This exception does not change the root `--affected` fallback for spike paths.

Each push to a pull request starts the hosted check on the new head:

- a Piece-only change: the small gate, in the job `check-piece`;
- a change of documents only: about 1 minute;
- a spike-only change: `check-spike` (Ash checks only when Ash changed), with
  the Gleam workflow for Gleam paths; root work jobs and `check-piece` skipped;
- each other change: the full check, about 20 minutes.

That run is the merge evidence. For a Piece-only change, the full check runs
on `main` after the merge (section 7). So push finished batches, not each
small commit.

A hosted job can fail on a test that your change cannot affect. Then rerun
the run on the same head, with no push:
`gh run rerun <run ID> -R balungpisah/elzoo`. Rerun all jobs: the queue
refuses a partial rerun (`--failed`), because the green jobs keep the start
time of the earlier attempt. Record the first failure in the pull request
body. Open an issue for the flaky test, or comment on its open issue. A second
failure of the same test is a real failure.

Open the pull request as a draft when the branch is complete in itself. Use
this body, and leave out a line that does not apply:

    ELZ-###: <outcome in one sentence>
    Closes #<issue number>
    Contract: <unchanged | what changed>
    Local gate: <each command and its exit code>
    Proof: <named Cure laws that Cure checked>
    Type check: <the checker and what it checked>
    Test: <named scenarios and negative controls>
    Monitored: <the observation and its environment>
    Upstream: <pinned library behavior that the claim relies on>
    Assumptions: <what is not verified>
    Limits: <claims that this task does not make>
    Shared paths: <each path outside the Piece directory, or none>
    Friction: <a step that cost time and gave nothing, or none>

Keep the five kinds of grounding apart. A test is not a proof. A monitor is
not a proof. An upstream contract is not our proof. Write "selected law
passes" or "listed scenarios pass", not "verified".

## 6. Review: one round

Every change gets one independent review, including documents, index files and test repairs. Do not repeat a review of unchanged code.

Freeze the diff for review; the local gate can run alongside that review.
When the reviewed delta is unchanged, avoid repeated main chasing and local
gate runs; this does not waive section 5's required local gates, base and
exact-head requirements, or hosted checks on a new head.

- The reviewer is a different agent session, and a different model where one
  is available. Give it the issue body and the diff, not your summary. The
  review comment names the model of the reviewer. When no different model is
  available, a different session is accepted, and the comment says so.
- The reviewer reports all findings in one pass. Each finding is a `BLOCKER`
  (wrong behavior, a broken Contract, a claim with no evidence) or a `NOTE`.
- Correct all blockers in one batch. The second pass reads only the commits
  made after the first pass: the range `<first reviewed SHA>..<head>`, which
  its comment names. Re-review only when the reviewed code changed; do not start another loop for an unchanged open blocker.
- A reviewer that cannot run the tests says so. Then you run the tests that it
  names, and you record each command and its exit code in the review comment.
- For a `NOTE`: correct it if that is quick. If not, open a follow-up issue or
  decline it in one line.
- The record is one pull request comment for each pass. Write no review file.
  Use these five lines:

      Reviewer: <role>; <model> | same model, different session (no other model available)
      Reviewed: <SHA> | second pass <first reviewed SHA>..<head>
      Findings: <BLOCKER or NOTE, each with file and line> | none
      Tests: <commands that the reviewer ran, and exit codes> | reviewer could not run tests; worker ran <command>: exit <code>
      Verdict: <no blocker open | blockers open>
- Answer each finding of the automated reviewer in its thread, and resolve
  the thread.

A local command can be impossible on your host, for example when a service is
missing. Then record the command and the reason in `Local gate:`. The hosted
check is the evidence for that command.

When the required local checks (or recorded hosted substitution), the hosted check and the review are green, mark the pull
request ready for review. That is the request to merge. From then the
coordinator owns the branch: do not push to it unless the coordinator gives it
back. You can claim the next task.

## 7. Merge and cleanup

The coordinator merges, one queue run at a time. A worker does not merge. A
worker with no coordinator takes the coordinator role for its own pull request.

- Mark a pull request ready before merging it; a draft is not eligible to merge.

    python3 scripts/merge-queue.py <PR number> [<PR number> ...]

The queue takes only a pull request that is not a draft, from a branch named
`task/ELZ-###`. It updates the branch from `main` if necessary, waits for the
hosted check on the exact head and then merges with a merge commit. The
required checks on `main` are `check-hosted` and `gleam-hosted`. A red push run on `main` freezes all merges except the classified repair path in the coordinator guide.

- Reuse qualifying push-check evidence, including for non-task plan-only and publication merges; branch name does not decide reuse. Require the exact head and tree, the current base for PR evidence, the latest successful complete attempt and GitHub-hosted identity. A docs-only short check also requires local docs-only classification and a completed green push run on the first parent; selected Piece evidence never skips the full main check. Keep the coordinator's main-green guards and merge paths unchanged (see [CI guide](docs/development/10-symbolic-ci.md)).

For a spike-only pull request, the queue accepts the spike marker only when
its own classifier agrees, with hosted exact-head evidence, no other marker
and no work job or Piece job running. The same freeze rule and first-parent
window below apply. The full check runs on main after the merge.

For a Piece-only pull request, the queue accepts the small gate only when its
own classification also says Piece-only. It does not wait for the push run of
`main`. The push run on `main` after the merge is the full check. Before a small-gate merge, the queue permits at most four outstanding first-parent commits after the newest covering green push run of `main`; at five it refuses until a newer covering green run. The coordinator also waits for a green `main` at the end of each level of tasks
([coordinator](docs/development/13-coordinator.md)).

If the queue stops on a conflict, or on a red check of the index files after
it updated the branch, the coordinator repairs the branch or gives it back to
its worker: merge `origin/main`, take the generated files of `main`, run step
3 of the index files again, push, wait for the hosted check and start the
queue again. A coordinator that repairs a branch comments the repair SHA on
the issue.

After the merge, GitHub deletes the remote branch and closes the issue
(`Closes #...`). Clean up from the main checkout. Remove the branch only when
the second command succeeds:

    git fetch origin --prune
    git merge-base --is-ancestor task/ELZ-123 origin/main
    git worktree remove ../elzoo-ELZ-123
    git branch -D task/ELZ-123

A task is done when its pull request is merged. Do not delete a branch that
holds work that is not merged.

## 8. Blocked, refused or stale

- If a write is refused for permissions, branch protection or policy, stop and report the refusal. Do not bypass it with another identity, token, endpoint or merge method. The push-conflict recovery below applies only to a non-fast-forward conflict, not a policy refusal.
- **Blocked.** Comment on the issue: the exact command, its output, the last
  green commit and the decision that you need. Keep the branch. A dependency
  that is not merged is not a blocker: the task is not ready.
- **Push refused.** Fetch, then list the commits that another agent made on
  your branch:

      git fetch origin
      git log --first-parent --no-merges --oneline HEAD..origin/task/ELZ-123

  No output means that only the queue merged `main` into the branch: merge
  `origin/task/ELZ-123` and push again. Do the same when a coordinator comment
  on the issue names the listed commits as a repair. If not, another worker
  holds the claim. Do not discard your work and do not merge. Push your commits
  to a salvage branch, comment on the issue with its name, and pick another
  task:

      git push origin "HEAD:refs/heads/salvage/ELZ-123-$(git rev-parse --short HEAD)"

- **Stale.** A claim is stale when no pull request is marked ready and the
  last push to its branch is more than six hours old. This shows the last push
  (or the creation of the branch):

      gh api 'repos/balungpisah/elzoo/activity?ref=refs/heads/task/ELZ-123&per_page=1' --jq '.[0].timestamp'

  Read the issue comments first. If one reports work that is not pushed, the
  claim is not stale until 24 hours after that comment: ask on the issue for a
  push, and pick another task. If not, adopt the claim with an empty commit. The random token makes the
  commit unique, so only the first push succeeds. That push is the lock:

      git fetch origin
      git worktree add ../elzoo-ELZ-123 -b task/ELZ-123 origin/task/ELZ-123
      git -C ../elzoo-ELZ-123 commit --allow-empty \
        -m "ELZ-123: adopt $(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
      git -C ../elzoo-ELZ-123 push origin task/ELZ-123

  If that push is refused, another worker holds the claim: remove your
  worktree, run `git branch -D task/ELZ-123` (it holds only your empty commit)
  and pick another task. If it succeeds, comment "adopt" with the new
  tip SHA on the issue and continue the branch.
- Only the coordinator deletes a branch that is not merged, and only after it
  pushes an archive ref of the exact tip
  ([stale claims](docs/development/05-stale-claims.md)).

## 9. Coordinator

"Coordinator" is a role, not a person or a service. It sizes and publishes
tasks, adds the rows of a new Piece ID, and merges. Its steps are in
[coordinator](docs/development/13-coordinator.md). A worker does not need them.
