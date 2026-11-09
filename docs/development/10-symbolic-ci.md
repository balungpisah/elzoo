# CI on GitHub-hosted runners

Elzoo CI runs on GitHub-hosted runners: every job uses the one label `ubuntu-24.04`, the repository is public (owner
decision 2026-11-09), and GitHub provides the compute, the scheduling and the check reporting. From ELZ-019 to ELZ-066 CI ran on the
owner's own machines; "History" at the end summarises that period. ELZ-069 removed its jobs, its guard rules, the runner
roles and the lane variable. "Hosted CI" below has the job shapes, the flip record, the measured figures and the fallback.

## Redundant push runs and duplicate pull request checks (ELZ-058, ELZ-059)

A merge cost several full checks of the same content: the queue's exact-head run, then the push run on
the merge commit (23 to 29 minutes on a former self-hosted runner), and, after every `update-branch`, a pull request check
that duplicated the queue run. ELZ-058 removed two of these without weakening the evidence; ELZ-059 removed the duplicate
in the other direction: the pull request run is the exact-head run (see "Coordinator merge queue").

**Push run skip.** The `check-hosted` job on a push to `main` runs
`scripts/ci-skip-decision.py` after the guard tests. It prints `skip=true` only when all of these hold:
the event is a push to `refs/heads/main`; the pushed commit is a two-parent merge commit; its tree equals
the tree of its second parent (the pull request head that the queue merged with `--match-head-commit`);
the latest run of `symbolic-check.yml` on that second parent (branch `task/ELZ-###`, found by `head_sha`; since ELZ-059 the
same-repository `pull_request` run, or the queue's `workflow_dispatch` fallback; a fork pull request run is never evidence;
a `pull_request` run counts only when the second parent holds the whole first parent, because that run tests the merge of
the head with its base and only then has the tree of the head; a `workflow_dispatch` run tests the head itself; the run with the highest ID decides, so a run of a sibling pull request
from the same branch that is newer than the queue's evidence run could decide in its place. The queue closes this on
both paths: it refuses to adopt a run when a sibling exists, and right before the merge it lists the runs of the head
the same way (by `head_sha`, without an event filter) and refuses to merge when a same-repository `pull_request` run
with a higher ID than its evidence run exists. A newer `workflow_dispatch` run is not counted: it tests the head itself,
and this script accepts it only as a completed success with the full marker, else the full check runs. Only a
`pull_request` run that is created after that listing, and that is green before the decision step of the push job
(about 20 minutes of check time), could still decide)
is a completed success whose exact attempt has exactly one job, a successful `check-hosted` job on a
GitHub-hosted runner (group `GitHub Actions`, label `ubuntu-24.04`, runner name `GitHub Actions <number>`), a successful
runner identity step, a successful `Run mix check` step, the full `ELZOO CHECK PASSED` log line and no
`ELZOO AFFECTED CHECK PASSED` marker (or, for a documentation-only merge, the short check of ELZ-071: see
"Documentation-only pull requests (ELZ-071)");
and that run is unchanged when read again. The same evidence rules as the queue apply (`scripts/merge-queue.py`).
Then the steps after the decision (`setup-beam`, cache, `mix setup`, `mix check`) are skipped, the job ends green
and its log shows `ELZOO PUSH CHECK SKIPPED (identical tree; exact-head full run passed): second_parent=...
tree=... run=<id> job=<id> runner=<name>`. That line is not `ELZOO CHECK PASSED`, which stays reserved for a run that
executed `mix check`. In every other case, including a fast-forward, squash or octopus push, a moved main (the
trees differ), a missing, red, cancelled, ambiguous or newer-failed run, an API, Git or parse error and a missing
token, the script prints `skip=false` with the reason and the full check runs. It never fails the job because it
cannot decide. A later run is not hidden by an older success: the run with the highest ID decides.
`workflow_dispatch` runs (the queue's), pull requests and anything that
is not a push to `main` are never skipped.

Why it is the same evidence: an identical tree is identical content, and the full check of that content passed on
a hosted runner at the exact head, with its run and job IDs in the push log. What it does not prove: the push run
no longer observes the merge commit itself (its path, runner, cache or toolchain state). A runner or cache fault
at merge time is invisible to a skipped push run; the next full run of `main` catches it. Acceptance on the
merge commit is therefore either its own green full run or this logged skip (see `AGENTS.md`).

Trust model: `check-hosted` gets `permissions: actions: read` and `contents: read` at job level (to read the exact-head
run, its jobs and its log); the top level keeps `contents: read`. The decision step and the S3 test server start step
are the only steps that receive `GITHUB_TOKEN`, and the script refuses everything but a push to `main` before any request. The token is never sent to
the log storage redirect, which is accepted only for `github.com`, `*.github.com`, `*.githubusercontent.com` and
`productionresultssa<N>.blob.core.windows.net/actions-results/...`. `scripts/check-ci-runners.py` pins the
`permissions` lines (and rejects any `write` scope), the checkout step with `persist-credentials: false` (the default
would leave the job token in `.git/config`, readable by every later step, including dependency code, and with this change
that token carries `actions: read` on `check-hosted`), the exact decision step and its position after
`scripts/test-ci-skip.py`, the token on that line only, and the complete list of step-level `if:` conditions:
every step after the decision, except the resource report, carries `steps.skip.outputs.skip != 'true'`
(the cache save combines it with `cache-hit != 'true'`) and the resource report keeps `always()`. A different `if:` on
`Run mix check`, or on any other step, fails the guard. Like the other guard rules this is a source-convention
check, not proof against every YAML form.

**Duplicate pull request check (retired by ELZ-059).** ELZ-058 had the queue cancel the `pull_request` run that GitHub
starts after `gh pr update-branch`, because the queue dispatched its own exact-head run. The cancel and its tests are
removed: that `pull_request` run is now the merge evidence, the queue waits for it and never cancels it (see
"Coordinator merge queue"). A `pull_request` run that a newer push supersedes is still cancelled by the `concurrency`
group of the workflow (see "Cancellation and overlap").

Cache effect: a skipped push run saves no main-scoped dependency cache, so after a `mix.lock` or `mix.exs` change
task branches restore an older entry by prefix key until a full run of `main` saves a new one (time, not correctness).

**Transient failures of the queue's reads (ELZ-058 item 4).** On 2026-11-08 the queue stopped twice (PRs #104 and #113) on
`net/http: TLS handshake timeout` from `gh api` while waiting on a run that was still in progress. Read-only calls
(`gh api` without `-X`/`--method`, `gh pr view`, `git fetch`) are now retried on transport and gateway errors (TLS handshake
timeout, connection reset, connection refused, i/o timeout, unexpected EOF, HTTP 500, 502, 503, 504) in five attempts with waits of
10, 20, 40 and 50 seconds (two minutes in all), never past the PR deadline; each retry is logged (`Transient failure of ...
retrying in N s`). Writes are never retried by the queue (dispatch, update-branch, merge): a repeated dispatch would create
a second run. Other errors (404, 401, 403, 422, mergeability, evidence mismatches) stop at once. When evidence collection
fails it prints `Stopped while awaiting run <id> for PR #N head=<sha>` (the `Adopted ...` or `Dispatched ... run=<id>` line
names the run too), so the run can be inspected; the queue adopts it again on the next start. Only the tool's own message is
matched against the transient patterns, not the arguments of the command; `gh api` with any field, input or method flag counts
as a write and is never retried. The retry does not change what counts as evidence.

Measurement over the next five merges (runner minutes per merge: queue run, push run, pull request runs, with
run IDs) is recorded in issue #96, not here. Live observations of the decision script against real merge commits
(run locally with a read token, 2026-11-08): `ade0e45` skipped, naming run 42482549411 and job 128737440624;
`665d3e0` skipped, naming run 42484386191 and job 128742976143; `b62c26a` ran the full check, because its exact-head
run predates the job name that the evidence rule of that time accepted.

## Affected consumer checks (ELZ-038)

`mix check` defaults to the full check. Every run of the backend workflow uses that default since ELZ-059: the
`pull_request` run, every `workflow_dispatch` run and every push to `main` that is not skipped under ELZ-058. The
default runs all root tests, all 26 existing per-ID
consumers, the separate OTP-only consumer, and the aggregate over every ready
ID (40 at ELZ-038). The aggregate and per-ID consumers are tests inside the
root suite, not additional phases to add to its reported duration. The fixed
per-ID list does not cover every ready Piece independently.

Until ELZ-059 the backend workflow invoked `mix check --affected BASE` on `pull_request`. It does not any more: the
`pull_request` run is the merge evidence, so it runs the full check. Affected mode stays available as a local opt-in
(the workflow does not use it, and the guard rejects an affected step). The selector compares the base commit with the
checked-out tree, including any working changes and non-ignored
untracked files. Renames are read as deletion plus addition. Git paths are
NUL-delimited, so filenames are not split at spaces. The local opt-in is:

```sh
mix check --affected origin/main
```

`Elzoo.CheckSelection` maps paths below known ready `pieces/<family>/<name>/`
directories to IDs, including their manifests, README and test files. It
follows reverse `piece.json` dependencies transitively across all ready IDs,
then selects from the existing 26 per-ID consumers. A dependency without its
own fixed consumer still selects its dependants. The selector uses
`Registry.select!`, the same dependency closure as the exporter, to check which
affected IDs those selected consumers actually copy. If any affected ready ID
is outside those closures, it also runs the full aggregate and logs the
uncovered IDs and reason. For example, `workflow/approval` selects no fixed
consumer but still runs the aggregate on the PR. A change confined to
`delivery/transformation` and its covered dependants can omit the aggregate.
Changing a covered Piece still runs the aggregate if an affected dependant is
uncovered: currently `core/operator` affects `workflow/dependency-graph`,
`integration/json` affects `integration/cure-json`, and `runtime/unit` affects
`workflow/budget` and `workflow/dependency-graph`.
The 26 fixed consumers currently cover 31 of the 40 ready IDs through their
dependencies; 14 lack a standalone consumer, but only nine lack coverage in
every fixed consumer's closure.

Every shared harness, toolchain, `mix.exs`/`mix.lock`, registry, workflow or
unknown/unmapped path selects all 26 **and the aggregate**. There is no docs-only
exception. Missing Git history, failed Git commands, malformed paths and an empty diff also
select all 26 and the aggregate with a logged fallback reason. Shared changes
cannot rule out effects on IDs outside the fixed consumers' closures, or on
aggregate composition. A dependency or registry validation failure still fails
`mix check`; selection does not suppress it.

Affected mode excludes only unaffected tagged per-ID consumer tests and, when
every affected ID has selected-consumer closure coverage, the aggregate. It
retains all other root proofs, runtime tests, negative controls, export
assertions, the OTP-only consumer, the Ash spike,
formatting, compilation and ledger checks. No test body or time limit changes.
The log names the mode/comparison, affected ready IDs, selected/skipped consumer
IDs, ready IDs without a standalone consumer, uncovered affected IDs, and
aggregate/OTP disposition with the aggregate selection reason.
The success marker is `ELZOO AFFECTED CHECK PASSED (not full consumer acceptance; see selected consumer scope)`;
only the default full run emits `ELZOO CHECK PASSED`.

A local subset does not validate unselected consumer checks or an omitted
aggregate. Merge acceptance needs the full run (the full `pull_request` run since ELZ-059). A failure found there
is a regression to fix forward, not justification to reduce the full run.
The ELZ-038 implementation PR itself changes the shared harness and must select
all 26 consumers and the aggregate; a later genuine covered one-Piece PR supplies
the narrow-subset CI observation. Compare wall times with runner, cache state and commit differences
visible, rather than treating unrelated runs as a controlled speed experiment.
Cure source-scan caching, registry parse reuse, incremental Cure compilation
and test partitioning remain separate work.

## Coordinator merge queue (ELZ-039)

Run `python3 scripts/merge-queue.py <PR>...` from a checkout of this repository
with `origin` pointing at `balungpisah/elzoo`. It uses the coordinator's own
`gh` authentication, not CI credentials. Obtain independent review first.
No workflow, job, runner, label or token is added; CI keeps `contents: read`.
The queue only handles same-repository, open, non-draft, mergeable PRs targeting
`main` with an exact `task/ELZ-###` branch. Unknown mergeability is polled for
up to one minute, then refused if it remains unknown.

For each PR, the queue fetches main and the task branch, then reads main’s SHA
from `gh api repos/balungpisah/elzoo/git/ref/heads/main`. The canonical GitHub
repository owns the base; a misconfigured origin cannot substitute a different
main SHA. Missing commit objects fail closed. If main is not an ancestor of the
head, `gh pr update-branch` creates a merge update; it never
rebases or force-pushes. The new head must become visible before continuing.
It then **adopts the `pull_request` run of the exact head** (ELZ-059): the latest run of `symbolic-check.yml` with
event `pull_request`, the task branch, the exact `head_sha`, the workflow's ID and path, and a head repository equal to
this repository. The run must also list this pull request (its number) with the base branch `main` of this repository.
That list shows the pull requests that are open for the head now, not the one that triggered the run, so two more
rules apply: this pull request must be the only pull request (any state) from the task branch, and its base must
never have changed (timeline events `base_ref_changed`, `automatic_base_change_succeeded`, `automatic_base_change_failed`,
or an entry that the queue cannot read). When one rule fails, the queue logs why and dispatches the fallback. A
timeline or pull request listing that is not a list of lists refuses the merge. Both rules are checked again right before the merge (on the adopted run only); when a sibling pull request or a base change has appeared since, the queue refuses to merge on that run. On both paths, the queue also refuses to merge when a same-repository `pull_request` run of the workflow on the exact head has a higher ID than the evidence run (see "Push run skip"). After such a refusal, start the queue again: it adopts the newer run when that run belongs to this pull request, and it dispatches a fresh run when it belongs to a sibling pull request. The refusal repeats only when the newer run comes from another branch at the same commit; then push a commit to the branch, so that the new head gets its own run. After `update-branch` it waits (up to 300 seconds, bounded by the PR deadline) for the run that GitHub
starts on the new head. It logs `Adopted pull_request run <id> for PR #N head=<sha>` and **never cancels that run**.
The pull request job runs the full check (no affected mode), so the run is the exact-head full run, and it counts as a
pull request status for branch protection. Only when GitHub started no such run within the wait does the queue
dispatch `symbolic-check.yml` on that branch (no input) as a fallback, logs why (`No pull_request run for PR #N
head=<sha> within 300 s; dispatching ...`), records the existing run IDs before the dispatch, never chooses an old or
merely latest green run, and refuses an ambiguous match. A dispatch run is valid merge evidence but not a pull request
status. A run for another head, another branch, another workflow, a dispatch, push or fork run is never adopted.

The completed run must succeed. Its exact attempt must have exactly one job, a successful
`check-hosted` job on a GitHub-hosted runner (group `GitHub Actions`, label `ubuntu-24.04`, runner name
`GitHub Actions <number>`), on the same head, with a successful runner identity step and a successful `Run mix check` step. The job log must contain the full
`ELZOO CHECK PASSED` output line and no `ELZOO AFFECTED CHECK PASSED` marker. A run of the short documentation-only shape is
accepted instead only under the rules of "Documentation-only pull requests (ELZ-071)".
Missing logs, API/command failures, cancelled runs and reruns during evidence
collection fail closed. This validates observed evidence from trusted workflow
code, not authenticity against a hostile PR or administrator.

**Freeze rule (ELZ-059).** Before it starts a pull request and again right before the merge, the queue reads the
latest completed push run of `symbolic-check.yml` on `main`. A success (a logged skip included) leaves `main` open. Any
other conclusion (`failure`, `timed_out`, `cancelled`, and every other one) freezes the queue: it stops with `Main is
frozen: ...` and names the run, until a comment on issue #98 by the authenticated login of the queue classifies that
run. The comment is exactly `CI main status: freeze classification run=<run id> class=<class>` with the class
`infrastructure` (rerun), `defect` (fix-forward task) or `conflict` (two separately tested merges; fix-forward task). A
fix-forward pull request goes through the queue after the classification. A later green push run of `main`
unfreezes. A re-run of a run keeps its ID: while a run newer than the latest completed one has not completed and is a re-run (attempt 2 or later), or has an
attempt number that is not a plain integer, it counts as red, so an older green run does not open `main`. A first
attempt in progress does not freeze. A classification names a run ID, not an attempt, so it also covers a later failure of a re-run of that run. No revert and no force push are involved. An API failure, an unreadable listing or a missing completed push
run fails closed.

**Gleam gate only for Gleam paths (ELZ-059).** The queue asks Git for the paths of the pull request
(`git diff --name-only -z --no-renames <main SHA>...refs/remotes/origin/<branch>`, with the main SHA read from the
canonical repository through the API, so a rename lists both paths). It requires the Gleam run only when a path is under `spikes/gleam_ui/`, or is
`.github/workflows/symbolic-gleam.yml`, `scripts/check-ci-runners.py` or `scripts/test-ci-runners.py` (the guard cannot be
split by content). An empty, failed or odd path list (absolute, parent, newline, backslash) requires the Gleam run. When it is
not required the queue logs `Gleam run not required for PR #N: ...` and prints `ELZOO GLEAM GATE not required pr=N
head=<sha> (...)` instead of the `ELZOO GLEAM EVIDENCE` line. `gleam-hosted` has no job-level `if:`: it always runs and
reports, so branch protection can require both checks. Protection and the queue can differ. When no Gleam
path changes, the queue does not wait for `gleam-hosted`, but protection (when it requires that check) still waits for the
run that GitHub starts for the pull request. The fallback is a `workflow_dispatch` run, and **a dispatch fallback run does not satisfy branch protection**: GitHub
does not count it as a status of the pull request (reported by the coordinator for PR #122, see "Branch protection change"),
so the merge can be refused even though the queue accepts the run. The queue says so whenever it falls back, with the log line
`Fallback for PR #N: a workflow_dispatch run is valid evidence for this queue but does NOT satisfy branch protection ...`.

When the Gleam run is required, the queue waits for a successful `symbolic-gleam.yml` **pull_request**
run on the exact same head SHA, including after `update-branch`. That update
triggers the synchronize event; no extra Gleam dispatch is added. The latest
matching run must succeed, have one successful `gleam-hosted` job on a GitHub-hosted
runner (same identity rule), a successful identity step and a successful `Run ./scripts/check.sh` step. An old
head’s green Gleam run, a missing run, or a failed/cancelled run cannot satisfy
this gate. It rechecks run identity and attempt after collecting the job.

Before merging, it re-reads the PR and fetches again. A changed head stops the
queue. Main advancing beyond the checked head triggers another merge update
and another full run of the new head. The merge command is always:

```sh
gh pr merge <PR> -R balungpisah/elzoo --merge --match-head-commit <checked-head-SHA>
```

After confirming the merge, it prints an `ELZOO GLEAM EVIDENCE` (or `ELZOO GLEAM GATE not required`) line and an
`ELZOO MERGE EVIDENCE` line with PR, run/job IDs, runner names, checked head SHA
and merge SHA. Preserve those lines in the coordinator's acceptance record.
No branch deletion, issue closure or
acceptance posting is performed. A transport failure during a merge can leave
an unknown result: inspect the PR before retrying; an already merged PR is
refused rather than merged again.

`--continue-on-failure` explicitly allows the next supplied PR after a failure;
the overall exit status still fails. Malformed API object shapes are per-PR
failures too; they never authorize a merge. Default behavior stops immediately.
`--timeout SECONDS` defaults to 10800 seconds per PR, including queue time.
Run discovery is bounded to five minutes; individual commands to two minutes;
main-update/check passes to ten. Interrupting the CLI stops local processing,
but does not cancel an already dispatched run or undo a merge request.

### Cancellation and overlap

Both workflows use this policy (the Gleam group starts with `gleam-`):

```yaml
concurrency:
  group: check-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

PR runs share their ref group and cancel superseded PR checks. Main and manual
runs each have their own run-ID group, so they cannot replace each other's
running **or pending** checks through concurrency. Merely setting
`cancel-in-progress: false` with a shared main group would still replace a
pending run when a newer run arrived; see [GitHub concurrency semantics](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).
This corrects the original issue's request to keep the group for all events,
with owner approval. The review correction applies it to both workflows,
so Gleam merge-commit evidence is retained too.

A's merge-commit backend check can overlap B's full pre-merge run on
two hosted runners. There is no speculative stack checking, or guarantee of
immediate capacity. Preserving pending checks
can increase queue length; this does not speed up an individual full check.

### Limits and acceptance

The queue is a serial coordinator convenience, not enforced branch protection.
It does not enforce independent review or replace merge-commit acceptance.
It requires the exact-head full backend run (the adopted `pull_request` run, or the dispatch fallback) and, when a Gleam
path changed, the current-head Gleam PR run, without a separate Gleam dispatch. The coordinator checks any other
PR checks and review before invoking it. The final fetch and GitHub merge
are separate operations: another coordinator/manual merge can advance main
between them. `--match-head-commit` protects the head, not an atomic base SHA.
Use one integration coordinator and retain full merge-commit checks; no atomic
base guard or multi-coordinator locking is claimed.

`scripts/test-merge-queue.py` uses a fake gh/git command runner and stdlib
`unittest` to exercise refusals and races without network or merges. It runs
next to `scripts/test-ci-runners.py` in backend CI. Existing runner tests and
source convention rules stay unchanged. These tests are scenario evidence,
not a proof of GitHub behavior. Acceptance additionally needs one real queue
merge with run/runner/merge SHA, and an observed pair of overlapping main
checks (or an explicit statement that the pair was not observed). Those live
observations and independent review belong to the coordinator; a local fake
run does not satisfy them.

## Documentation-only pull requests (ELZ-071)

A pull request that changes only documentation (many recent merges were documentation, task bodies and plan views) does
not need the 18 to 33 minutes of `mix check`: nothing that `mix check` tests changed. ELZ-071 gives such a pull request a
short check, and lets the queue and the push-run skip accept it only when they classify the change themselves.

**The allowlist** is `scripts/ci-change-class.py`, one file for the workflow, the queue and the skip decision. A change
is documentation only when it has at least one changed path and every changed path is a regular file under `docs/` or
`tasks/`, or one of the root files `README.md`, `GOAL.md` and `PLAN.md`, **except `docs/consuming.md`**: `Elzoo.Export`
copies that file into every export (`lib/elzoo/export.ex`), so the export tests and the copied consumers read it. These
are never documentation: `.github/`, `scripts/`, `lib/`, `test/`, `pieces/` (their READMEs too), `config/`,
`registry/`, `mix.*`, `AGENTS.md` and the generated `LEDGER.md` (`test/registry_test.exs` and the `ledger` stage read it).
Git is asked with `diff --raw -z --no-renames --no-abbrev`, so a rename counts both paths; a symlink or submodule entry on
either side is never documentation; an empty list, a failed Git command, malformed output and an odd path (`..`, absolute,
backslash, a look-alike such as `docs-x/`, a trailing space) mean "not documentation only". Git shortens object names in
`--raw` output unless `--no-abbrev` is given; the parser reads full names only. The first draft of this task named only
`LEDGER.md` as read by tests; a scan of `lib/` found `docs/consuming.md`.

**The guard test for the allowlist** (`scripts/test-ci-change-class.py`) scans the Elixir sources (`lib/`, `test/`,
`config/`, `pieces/*/*/lib`, `pieces/*/*/test`, `mix.exs`, `.formatter.exs`) for path literals of `docs/`, `tasks/`,
`GOAL.md`, `PLAN.md` and `"README.md"`. A literal that is not in the reviewed list of that test fails it, so a future test
or module that reads a documentation file cannot silently become unchecked on a documentation-only pull request: take the
file out of the allowlist (`READ_BY_CODE`) in the same change. The reviewed list names every present hit with the reason
(comments, messages and fixtures, and the one read, `docs/consuming.md`).

**Workflow** (`check-hosted`): the step `Classify the change` runs `python3 scripts/ci-change-class.py github` right after
the checkout. On a `pull_request` run the checkout is the merge of the head into the base, so `HEAD^1...HEAD^2` is the
change of the head; any other event, or a `HEAD` that is not a two-parent merge, is not documentation only. When
`docs_only` is `true`, every heavy step (S3 binary restore, start and save, `setup-beam`, BEAM report, dependency cache,
hex, rebar, `mix setup`, cache save, `mix check`, the roadmap step of ELZ-059) is skipped, and the step `Docs-only check`
runs `check-claims.py` and `check-roadmap.py` (links and generated views included) and prints `ELZOO DOCS-ONLY CHECK
PASSED`. The claims check, the guard and the tests of the guard, the queue, the S3 test server, the classifier and the skip
decision, which run before the heavy steps, keep running. The Postgres
service container still starts (a job-level `services:` block cannot be conditional); only its use is skipped. The guard
(`scripts/check-ci-runners.py`) pins the classify step, the classifier test step, the docs-only step and every
step-level condition, and allows the marker on one line of the workflow only.

**Queue.** A run whose `Run mix check` step was skipped is accepted only as the docs-only shape: `Classify the change`
and `Docs-only check` green, the log line `ELZOO DOCS-ONLY CHECK PASSED` as a line of its own (not an echoed command), no
`ELZOO CHECK PASSED` and no `ELZOO AFFECTED CHECK PASSED` line. It still needs the one `check-hosted` job on a
GitHub-hosted runner, the green identity step and all other rules. Then the **queue's own classification** decides:
`git diff --raw -z --no-renames --no-abbrev <main SHA>...refs/remotes/origin/<branch>` with the main SHA of the canonical
repository, through the queue's own copy of `scripts/ci-change-class.py`, the file next to `scripts/merge-queue.py`; the
queue never reads a file of the pull request head for this. The classification runs once after the evidence and again
right before the merge. When it does not say "documentation only" (a code path, an empty or failed list, a missing
classifier file), the queue logs `Run <id> passed the docs-only check, but the queue's own classification ... is not
documentation only; dispatching a full run` and takes the dispatch run as evidence, which must be a full run. A pull request
that changes `scripts/` (the classifier included) or `docs/consuming.md` is therefore never documentation only. The merge line
gets ` mode=docs-only` for a merge on the short check. **Stage the classifier with the queue**: when the coordinator copies
`scripts/merge-queue.py` elsewhere, it copies `scripts/ci-change-class.py` next to it; without it the queue still works
and requires the full run for every pull request.

**Push run.** `scripts/ci-skip-decision.py` accepts the same short shape for a `pull_request` run (never a dispatch run:
a dispatch run is not classified and runs the full check) when its own copy of the classifier says that the merge commit's
change against its first parent is documentation only. The log line then reads `ELZOO PUSH CHECK SKIPPED (identical tree;
exact-head docs-only check passed): ...`. Everything else of the skip decision is unchanged.

**Limits.** A documentation-only pull request is not checked by `mix test`: documentation that tests read must stay out of
the allowlist (the guard test above enforces it). The marker proves that the docs-only steps ran on the merge of the head
into the base; the queue's path check decides acceptance. The runtime libraries and the disposable database are still
prepared before the checkout, and the Postgres service container still starts, so a documentation-only run costs about
the start of the job plus the short check, not zero.

## Timing lines in CI logs (ELZ-045)

`mix check` prints `ELZOO STAGE <name> start|end utc=... elapsed=...` around format, compile,
ledger, Ash spike, registry load and the root suite. The consumer harness (`Elzoo.CureConsumerCase`
since ELZ-049; `test/export_test.exs` before) prints
`ELZOO TIMING consumer=<id|aggregate(N)> <step> seconds=...` for each copied consumer. Steps are
`plan_write`, `consumer_mix_test`, `runtime_vm` and `total`.

Mix compiles the project before it loads the `mix check` task, and runs each task once, so the
`compile` stage brackets a no-op and reads about 0 s. The pre-task work (VM boot, `deps.loadpaths`
and the compile) is the gap between the `Run mix check` step `started_at` in the jobs API and the
`format start` stamp: 110 s on machine A, run 42404495544. The OTP-only `runtime/unit` test prints
one `consumer_mix_test` line only. Timing lines can share a line with ExUnit progress dots, so
match them without a `^` anchor.

These lines are monitored behavior from a monotonic clock. They prove nothing about correctness.
They add no stage, test or assertion. Queue time is not part of any line. Compare runs only on the
same SHA and the same runner.

## Concurrent database-free consumers (ELZ-049)

The copied-consumer tests share one harness, `Elzoo.CureConsumerCase` in
`test/support/cure_consumer_case_test_helper.exs`. The 23 consumers whose copy closure names no PostgreSQL
provider (`postgrex`, `ecto_sql`, `oban`) are defined in three modules with `async: true`:
`test/consumer_group_a_test.exs`, `_b_` and `_c_`. ExUnit runs async modules at the same time
and tests inside one module in sequence. `test/test_helper.exs` sets `max_cases` to
`System.schedulers_online()`; this caps every async module in `test/` and `pieces/`, not only the
consumer groups. With `+S 4:4` on machine A the cap is 4, so all three consumer group modules run
at once (the module count is the bound there); with `+S 2:2` on machine B the cap is 2, so
at most two consumer VMs run at once (the cap is shared with the other async modules). The groups are explicit lists balanced by the
measured `total` seconds on main `0a42370`. The three
PostgreSQL consumers (`integration/sql`, `integration/jobs`, `assembly/durable-job`) and the
aggregate consumer stay in `test/export_test.exs` with `async: false`, because the CI job prepares
one disposable database. The OTP-only consumer and the plan/write tests stay there too; they
were not moved.

Each per-ID test keeps its name and its `consumer_id` tag, so the affected mode (ELZ-038)
filters them with the same `--exclude consumer_id:<id>` arguments. The 23 concurrent tests have a
240 s limit (`Elzoo.CureConsumerCase.concurrent_timeout/0`); the sequential consumers keep 120 s.
Measured basis for 240 s: on machine B with three concurrent VMs, after about 30 minutes of
sustained load, `assembly/request-route-retry` rose from 35.8 s (sequential) to 99.1 s in the last
completed repeat, and two later repeats went over 120 s by an unknown amount (PR #90, run
42454973591, repeats 6 and 7). 240 s is 2x that 120 s lower bound. The same series on machine A
stayed at 123 to 125 s per repeat with 35.7 s for that consumer, which is consistent with a
slowdown of the two-core host under sustained load. The two-VM setup is to be measured by a later
repeat series, recorded in the PR. The selection test in
`test/export_test.exs` counts the per-ID tests over the four modules (still 26, plus one
aggregate), checks that the groups plus the PostgreSQL list equal
`Elzoo.CheckSelection.consumer_ids/0`, and checks that no database-free group ID copies a Piece
with a PostgreSQL provider. That test needs the four modules loaded: run the whole suite, or name
the four files together.

Measured basis before the change, main `0a42370` on the first fast runner (job 128581094645): the 23
database-free consumers took 189.5 s in sequence; the root suite reported `Finished in 862.2
seconds`. Locally on the implementation branch, the three group files ran in 100.7 s wall time
for 205.0 s of summed consumer `total` time. Under concurrency a per-consumer `total` includes
contention, so it is not comparable with a sequential `total`; compare the root suite `Finished
in` and the stage elapsed on the same SHA and runner. CI before/after figures and the repeat
series are recorded in the ELZ-049 PR. The repeat series runs the three group files alone; in
`mix check` they also overlap the other async root and piece test modules, so the per-test
margin under full load is shown only by whole-suite runs. Three concurrent consumer VMs add
memory: compare the cgroup peak before and after on the same runner. The concurrency bound is
the module count, not a measured CPU budget; a passing repeat series is a finite sample.

## Owned Cure compile fingerprint (ELZ-046)

`Mix.Tasks.Compile.Cure` writes `elzoo.cure.manifest` (format 2) with a sha256 fingerprint over
named inputs: the path and content of every owned `.cure` source, the nearest `Cure.toml` of each
source, the sorted source roots, the whole `mix.lock`, every file in the loaded Cure `ebin`, the
compiler module's own BEAM md5, and the Elixir, OTP and ERTS versions. The compile is skipped only
when the fingerprint matches, every listed BEAM exists and `--force` was not given; the log then
says `Cure sources unchanged (...); skipping N modules`. A mismatch on any named input, a missing
or malformed manifest, a missing BEAM, or `mix compile --force` recompiles everything.

Copied consumers carry the same compiler. Their first build starts from an empty `_build` and
always compiles; a later build in the same consumer skips under the same rule. The fingerprint
covers the named inputs only. It is not a proof that no other input exists. Negative controls live
in `test/compile_cure_fingerprint_test.exs`.

## Cure pin on the balungpisah fork (ELZ-047)

`mix.lock` pins Cure to `balungpisah/cure-lang` commit `208248063`, which is upstream `a004c335`
plus one import-resolution fix (see `docs/dependencies/forks/cure.md`). The first CI run on each
backend runner after this change restores the previous cache by prefix key, then `mix deps.get`
refetches Cure because `mix.lock` changed and Cure compiles from source once per runner; that run
saves a new cache. Later runs are warm. Compare consumer timings only between warm runs.

### Dependency cache (ELZ-043, ELZ-066)

The backend job restores with `actions/cache/restore` and saves with
`actions/cache/save`, both pinned at `0057852bfaa89a56745cba8c7296529d2fc39830`
(tag v4.3.0). The key is `elzoo-hosted-v1-<OS>-<ImageOS>-otp29.1.2-elixir1.20.4-<hash of the two
mix.lock/mix.exs pairs>`; the restore-keys prefix is the same without the hash. The key has no runner name: hosted
runners are interchangeable. The save step runs immediately after `mix setup`
succeeds and before `mix check`, only when the restore had no exact
primary-key hit (`cache-hit != 'true'`), using the restore step's
`cache-primary-key`. It runs on the same events as the job itself (push to
`main`, same-repository PRs, `workflow_dispatch`). A `mix check` failure, cancellation or timeout keeps the saved state;
a failed `mix setup` saves nothing. GitHub scopes caches by ref: a PR save is
visible to that PR only, while a `main` save is visible to every branch.

What is saved is the post-`mix setup` state (`deps`, `_build` and the spike's
`deps`/`_build`, `test` env). Files that `mix check` adds later are not in
a newly saved entry. Compiled Mix and Cure artifacts, including the root
application's BEAMs in `_build`, are restored only for the same OS image, OTP and Elixir versions; they are not a
substitute for the source-copy boundary.

Observed on the hosted runner (`mix setup` step; the cache restore itself took 1 to 2 s):

| Restore | Runs | `mix setup` |
|---|---|---|
| no entry for the prefix (first run after the key change) | 42517023581 (job 128842174590) | 617 s (10 min 17 s) |
| exact hit | 42520133125, 42521924097, pull request run 42518583815 | 2 s, 2 s, 5 s |

These are observations from listed runs, not a timing guarantee. A change of `mix.lock` or `mix.exs` makes one run take the
restore-keys prefix hit and pay an incremental `mix setup` plus one save (not measured here); a changed key prefix (`v1`)
or an evicted entry costs one cold run (about 10 minutes of `mix setup`).

Coordinator check after a lock change: `gh api
'repos/balungpisah/elzoo/actions/caches?per_page=50' --jq '.actions_caches[] |
select(.ref=="refs/heads/main") | {id,key,created_at}'` must list one `elzoo-hosted-v1-...` entry with the current hash
(and the pinned `elzoo-minio-...` entry of the S3 test server).

### Gleam compiler download (ELZ-060)

The Gleam job installs the pinned compiler (v1.19.2) with `spikes/gleam_ui/scripts/setup_gleam.py`, called
by `scripts/setup.sh` in the step `Install the pinned Gleam compiler` of `symbolic-gleam.yml`.
`setup-beam` installs only OTP there. Since ELZ-060 the archive comes from the release-asset API,
`GET https://api.github.com/repos/gleam-lang/gleam/releases/assets/<id>` with
`Accept: application/octet-stream` and the job's `github.token` (step `env`, read-only; the guard allows
`github.token` on that one step only, pins the step text, its position (right after `setup-node`) and its end, and
rejects `secrets`, `github.token`, `github[...]` and `toJSON(github|secrets)` spelled in any case and spacing
anywhere else in either workflow; this is a source-convention check, not proof against every YAML form;
`setup.sh` unsets `GITHUB_TOKEN` right after the download so `npm ci` and the Playwright install do not see it).
The API answers with a redirect to a
signed storage URL; the script follows it by hand, refuses any redirect that is not plain HTTPS (no user info, no
other port, no percent or backslash tricks) to `github.com`, `*.github.com` or `*.githubusercontent.com`, and sends
no `Authorization` header to the storage host. It checks
the pinned size and SHA-256 and stops on any mismatch or error; only HTTP 500, 502, 503 and 504 are retried (three
attempts, 2 s and 4 s waits). The API route can fail the same way as the browser URL: a reviewer saw HTTP 500 or
504 on about 9 of 10 requests from one machine between about 17:35 and 17:45 WIB on 2026-11-08, so a job can
still fail closed; a second source (a hash-verified mirror) is planned as ELZ-061.

| Platform | Asset ID | Size (bytes) | SHA-256 |
|---|---|---|---|
| Linux x86_64 (CI) | 633423401 | 10565692 | `2ba2afb66ca9f6dcc01a4a6e9169b6942963bad6483bec9571ddc078cfe6f41f` |
| Linux aarch64 | 633423257 | 10126116 | `d1d1a9d53f6b317c0563a4806873c8ccace54291ead023373728af379402d4f1` |
| macOS arm64 | 633423162 | 9234148 | `fa7c6113e162ab1d979f72e7dde3e907b87e4b30c518af178768e577d180324d` |
| macOS x86_64 | 633423317 | 9702221 | `c578192530507b868c4a6c8cb7ad5d2ab0830890257f41036f17c82853f19d05` |

The hashes are unchanged from the earlier browser-URL version; the asset IDs, sizes and hashes were read
from `GET /repos/gleam-lang/gleam/releases/tags/v1.19.2` on 2026-11-08 (the API `digest` fields equal the pins),
and the Linux x86_64 archive downloaded through the API had exactly the pinned size and hash.

Reason: from about 16:20 WIB on 2026-11-08 the browser URL
`https://github.com/gleam-lang/gleam/releases/download/v1.19.2/...` answered `HTTP Error 504: Gateway Time-out`
from the job container (Gleam run 42467133717, job 128689127890, step `Run ./scripts/setup.sh`). That is the first
step of every Gleam job, and the merge queue needs a green Gleam run, so no pull request could merge. The same
URL answered 200 after 12 s from a developer machine at about 16:50 WIB, so the outage is intermittent or slow,
not proven fixed. `spikes/gleam_ui/scripts/test_setup_gleam.py` (21 tests, run by `check.sh`) covers the script with a fake
HTTP layer and a loopback redirect server (the target is never contacted): success, token only to the API host, checksum and size mismatch, 504 retries, no retry on other
errors, refused redirect hosts, network errors, archive shape and unsupported platforms.

Limits: this depends on `api.github.com` and the storage host that the redirect names; it does not show that the
browser URL works again. Without `GITHUB_TOKEN` the unauthenticated API rate limit (60 requests per hour per
address) applies. A changed pin (new Gleam version) needs new asset IDs, sizes and hashes in the script, this
table and the README. Platforms other than the four above stay unsupported.

## Hosted CI (ELZ-066, ELZ-069)

The owner decided on 2026-11-09 that the repository becomes public and that CI moves to GitHub-hosted
runners; both happened on that day (see "Flip record"). ELZ-066 added the hosted jobs next to the self-hosted ones,
chosen by a repository variable; ELZ-069 removed the self-hosted jobs, the runner roles, the `tier` input of the manual
run and the variable. There is one lane.

**Jobs.** `symbolic-check.yml` has one job, `check-hosted`; `symbolic-gleam.yml` has one job, `gleam-hosted`. Both run
on the one label `ubuntu-24.04`, without a job container, and run for a push to `main`, a manual run
(`workflow_dispatch`, no inputs) and a pull request from the same repository (a fork pull request skips them).
`scripts/check-ci-runners.py` pins their `if:` lines and their header lines exactly: token permissions, time limit,
`ERL_FLAGS`, and for `check-hosted` the Postgres service container (image pinned by digest, health check). It rejects
every other label (`ubuntu-latest`, larger runners, expressions), any `self-hosted` text, any `labels:` list on a job,
any workflow input, any use of `vars` or of the former variable name `ELZOO_CI_LANE` (in any letter case, also in script
text and comments), a job container, and a second job of any name, so the removed shapes cannot return silently. The
`check-hosted` job ends with `python3 scripts/check-roadmap.py` (plain, offline), so a stale generated roadmap view fails
the check; the guard pins that step and the `Run mix check` step by their exact text. The
first step of each job checks `RUNNER_ENVIRONMENT`, `RUNNER_OS`, `RUNNER_ARCH` and `/etc/os-release`. The dependency
cache key has no runner name: `elzoo-hosted-v1-<OS>-<ImageOS>-<OTP>-<Elixir>-<lock files hash>`.

**Evidence.** The merge queue (`scripts/merge-queue.py`) and the push skip decision (`scripts/ci-skip-decision.py`)
accept a run when its job list holds exactly one job, `check-hosted` with `runner_group_name` = `GitHub Actions`,
`labels` = `["ubuntu-24.04"]`, a `runner_name` of the form `GitHub Actions <number>`, a green identity step and a green
`Run mix check` step. The Gleam gate accepts exactly one `gleam-hosted` job under the same rule. A run of the former
shape (a job named `check-fast`, `check-any` or `gleam`, or any second job) is not evidence. Since ELZ-059 the evidence run is
the `pull_request` run of the exact head, which runs the full check; the queue dispatches (without an input) only when
GitHub started no such run.

**Flip record (executed by the coordinator on 2026-11-09 WIB, after hosted run 2 was green).** Order: the
public-surface scrub (ELZ-065) was merged first; all four self-hosted runners were unregistered, because a fork can
change a workflow file and target a runner that stays attached; the repository was made public with
`ELZOO_CI_LANE=hosted` kept set; one verification run was dispatched on `main` (run 42521924097). The coordinator
reported the flip at about 03:40 WIB; the GitHub API does not record the time of the visibility change. Settings read
back from the GitHub API on 2026-11-08 20:49 UTC (2026-11-09 03:49 WIB), except the protection row, which was read
again at 20:56 UTC (03:56 WIB) after the change described below:

| Setting | Value |
| --- | --- |
| Repository visibility | public |
| Self-hosted runners | 0 |
| `ELZOO_CI_LANE` | `hosted` at the flip; no workflow reads it after ELZ-069; deleted by the coordinator on 2026-11-09 at 08:12 WIB, after the push run on the ELZ-069 merge commit was green (reading it now returns 404) |
| Default workflow token | `read`; workflows cannot approve pull request reviews |
| Fork pull request approval | `all_external_contributors` (every outside contributor needs approval before a workflow runs) |
| Branch protection on `main` | required status checks `check-hosted` and `gleam-hosted`, strict (up-to-date) off; re-enabled by the coordinator after PR #132 (ELZ-059) merged on 2026-11-09, see below; no force pushes; no deletions; not enforced for administrators; no review requirement |

**Branch protection change (2026-11-09, between 03:49 and 03:56 WIB).** At the flip, branch protection required
`check-hosted` and `gleam-hosted` (read at 20:49 UTC). The coordinator removed that rule a short time later; the protection read at 20:56 UTC
(03:56 WIB) shows no required checks. The coordinator reported "about 04:05 WIB" for the removal; the API shows no
later time and does not record the removal itself. PR #122 was merged at 20:52:00 UTC (03:52 WIB); the API does not
show whether the rule was already gone then (administrators are not enforced). The
reason, as the coordinator reported it (the refusal is not recorded in the pull request timeline): the merge queue
cancels the duplicate `pull_request` run and relies on a `workflow_dispatch` run on the exact head as evidence, and
GitHub does not count a `workflow_dispatch` run as a status of the pull request, so the queue's merge of PR #122 was
refused with "the base branch policy prohibits the merge". ELZ-059 (#99) makes the `pull_request` run the evidence that the
queue adopts. PR #132 (ELZ-059) was merged at 04:59:22 UTC (11:59 WIB) on 2026-11-09, and the coordinator then
re-enabled branch protection requiring `check-hosted` and `gleam-hosted`. Read back through the API shortly after the
merge (before 05:02 UTC): required checks `check-hosted` and `gleam-hosted`, strict (up-to-date) off, because the queue
merges `main` into the branch itself. Between the removal (03:49 to 03:56 WIB) and the re-enabling, `main` had no
required checks, and the merge queue with its evidence rules was the only gate. Administrators are not enforced
either way. The API does not record the time of the re-enabling.

**Organisation runners.** The organisation `balungpisah` still has 2 offline self-hosted runners in its Default runner
group. The group does not allow public repositories (`allows_public_repositories: false`), which keeps them away from this
repository. Do not switch that setting on.

**Fallback (decided 2026-11-09; order corrected after the independent review).** There is no switch back: ELZ-069 removed
the self-hosted jobs. If the hosted lane fails and cannot be repaired quickly, three steps, in this order:
1. Make the repository private (the owner's action). A self-hosted runner must never be registered while the repository is
   public: a fork pull request can change a workflow and reach an attached runner.
2. Register the self-hosted runners with the roles that the documentation before ELZ-069 describes (git history), and create
   the repository variable `ELZOO_CI_LANE` with the value `self` (it was deleted on 2026-11-09).
3. Merge a revert PR of the ELZ-069 change (it restores the self-hosted jobs, the guard rules and the lane variable). Run the
   merge queue from the revert's own checkout, because the queue on `main` accepts hosted-job evidence only and would send
   no `tier` input; the revert's own `scripts/merge-queue.py` matches its workflow.
The revert is the rare path: the hosted lane carried every merge from 2026-11-09 WIB. If required checks are set again
(ELZ-059), they name the hosted jobs, so a return to the self-hosted lane also needs the required checks changed.

**Required checks.** `check-hosted` and `gleam-hosted` are not required checks at present (see "Branch protection
change"). When they are set again, a skipped job counts as passing, and a pull request from a fork skips them. The merge queue is the gate: it needs a run on the exact
head with the one job and the identity rules above, and no fork pull request is queued.

**Time limit.** `check-hosted` has `timeout-minutes: 120`. A cold-cache run on a comparable 4 to 5 vCPU machine took
72 minutes (see "History"), and the first run on `main` starts with an empty `elzoo-hosted-v1` cache.

**Resource report.** On a hosted runner there is no job container, so `scripts/sample-ci-cpu.py` reads the cgroup of
the whole VM (Postgres included) and its "job container cgroup" label is not exact; `memory.peak` is not available
there and the report prints "cgroup memory peak unavailable". Use the host lines (`/proc/meminfo`, load, `nproc`) for
hosted numbers.

**Measured figures (rehearsal and verification in this repository, 2026-11-09 WIB; times in UTC from the job records).**
All hosted jobs ran on `ubuntu-24.04`. The backend job reported `BEAM schedulers=4 online=4`; the Gleam job is set to `+S 2:2` in `symbolic-gleam.yml`.

| Run | Job | Caches | Job time | `mix setup` | `mix check` | Root suite | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Run 1, dispatch on `main` at 48462d4: run 42517023581 | `check-hosted` 128842174590 | cold (S3 binary and dependencies) | 33 min 7 s | 10 min 17 s | 21 min 14 s | 1139.0 s | 641 of 642 passed; `http_job_test.exs:472` failed |
| Run 2, same commit: run 42520133125 | `check-hosted` 128851610565 | warm | 18 min 38 s | 2 s | 17 min 28 s | 932.0 s | 642 passed, `ELZOO CHECK PASSED` |
| Verification run after the flip, dispatch on `main`: run 42521924097 | `check-hosted` 128857085850 | warm | 13 min 39 s | 2 s | 12 min 46 s | 695.2 s | passed, `ELZOO CHECK PASSED` |
| Pull request check of PR #123 (affected mode): run 42518583815 | `check-hosted` 128846911946 | dependency cache warm | 22 min 19 s | 5 s | 21 min 5 s | 1132.7 s | passed (`ELZOO AFFECTED CHECK PASSED`) |
| Run 1 and run 2 Gleam: runs 42517027888, 42520136422 | `gleam-hosted` 128842186520, 128851620715 | none | 59 s, 60 s | | `./scripts/check.sh` 7 s and 5 s | | passed |

The S3 test server step took 1 s in all three dispatch runs (restore of the pinned binary 1 s on a cache hit; the cold run
saved it in 2 s). Before `mix setup` the cold run spent 1 min 26 s on the job start, service containers, runner
identity gate, host report, libraries, PostgreSQL role and database, checkout, six check and test scripts, the decision
step, the S3 steps, setup-beam, the BEAM report, the dependency cache restore and `mix local.hex`/`mix local.rebar`. The
root suite took 1139.0 s, 932.0 s and 695.2 s in the three full runs on the same commit, so expect a wide spread (the fastest was 61 percent of the slowest).
A job started 3 s after its dispatch (run 2). The self-hosted figures (see "History" and git history) were measured
in different modes and are not directly comparable.

**Limits.** The first two rows come from the rehearsal before the flip (the repository was private, as the coordinator
reported; the API does not record the time of the change), the third from the first run after the flip, all on the same
commit of `main` (48462d4); a public repository may differ. `http_job_test.exs:472` ("real Oban job completion and cancellation are job
control, not provider rollback") failed once in run 1 and passed in run 2 on the same commit: it looks timing-dependent
(one failure and two passes; not measured further) and not like a lane defect. Hosted minutes are free for public repositories. Self-hosted runners must never stay attached
to a public repository.

## Disposable S3 test server (ELZ-064)

The export tests need an S3-compatible server. The workflow starts one per job with `scripts/ci-minio.py`
and passes it to `mix check` through these variables: `ELZOO_TEST_S3_URL`, `ELZOO_TEST_S3_BUCKET`
(`elzoo-test`), `ELZOO_TEST_S3_ACCESS_KEY_ID`, `ELZOO_TEST_S3_SECRET_ACCESS_KEY` (random per job, masked) and
`ELZOO_TEST_S3_REGION` (`us-east-1`). The server listens on the loopback address only; port 9000 is used when
it is free, otherwise a free port.

The Docker image is no longer published (the Docker Hub repository is gone and no Quay tag exists), so the
script runs a pinned binary: MinIO release `RELEASE.2025-09-07T16-13-09Z`, release asset id 404655976,
110,989,496 bytes, SHA-256 `7c5bd8512c6e966455b1d198209358b2d191c77a83ab377c4073281065fb855f`. The script gets
the file from the Actions cache, then from the release-asset API (job token; the redirect is followed by hand and
the token is never sent to the redirect host), then from the browser URL. `dl.min.io` answers HTTP 410 and is
not used. Every route checks the size and the SHA-256 before the file runs. The upstream project is archived
and licensed AGPL-3.0; CI runs the binary unchanged and does not redistribute it. The start step is the only
backend step besides the skip decision that receives the job token; the guard pins it.

Limit: the step duration on a hosted runner is not measured yet.

## Per-test limits of two slow tests (ELZ-062)

Owner approval 2026-11-08 ("1.", relayed by the coordinator): raise the per-test limit of the two tests that timed out on
the slow VPS runner to 300 s, so that machine can take `any`-tier runs. That runner was unregistered at the flip on
2026-11-09; the coordinator's decision rule for the changed situation was: if both tests stay under 60 percent of 120 s (72 s) on
the hosted runner, close the task with no code change; otherwise raise only these two limits to 300 s (see "Hosted
measurement" below). Time limits only: no assertion, scenario or proof
changed, and no other limit changed (not the 120 s default in `test/test_helper.exs`, not the 240 s of the concurrent
consumer groups, not the inner consumer limits).

- `pieces/workflow/approval/test/elzoo/approval_test.exs`: `@tag timeout: 300_000` on "negative control: dropping g_self
  from the gate list is rejected inside self_approval_refused" (a Cure proof check).
- `test/export_test.exs`: `Elzoo.CureConsumerCase.consumer_tests/2` takes one `timeout:` for all IDs of a call, so the three
  PostgreSQL consumers are defined by two calls: `integration/sql` and `integration/jobs` keep 120 s, `assembly/durable-job`
  gets `timeout: 300_000`. The selection test "affected selection only filters the existing consumer tests" asserts the
  limits exactly (120 s, 300 s for `assembly/durable-job` in `Elzoo.ExportTest`, 240 s for the concurrent groups); it was
  updated for the one new value and fails if that value or an ID's limit is wrong (checked locally by expecting 120 s).

Measured basis. CI logs print no per-test times, so a measurement branch (`measure/ELZ-062`, never merged) ran the full root
suite as `mix check` does in full mode with `--slowest 60` and every per-test limit raised to 900 s, one run per machine on
the same tree (`main` at `f4e3283`):

| Test | the first fast runner | the second fast runner | the slow VPS runner (8 cores) |
|---|---|---|---|
| approval negative control | 39.1 s | 45.3 s | 93.1 s |
| `assembly/durable-job` consumer | 77.6 s | 91.3 s | 128.7 s |
| `integration/sql` consumer | 18.8 s | 26.1 s | 52.8 s |
| `integration/jobs` consumer | 13.9 s | 17.0 s | 37.6 s |
| root suite | 1266.5 s | 1492.2 s | 3136.7 s |

Runs 42500718766, 42497402091 and 42497486307 (jobs 128792642738, 128782613975, 128782875563). On the slow VPS the approval test
exceeded 120 s in the two earlier full runs (42484236992 and 42492726966) and took 93.1 s here, so the spread on one
machine is large; 300 s is 2.3 times the slowest measured time (128.7 s) and 3.2 times the approval test's 93.1 s. It is a
margin, not a performance target. A hung test now costs up to 300 s instead of 120 s before it fails. The measurement
runs of that branch failed two tests each, as expected there (the selection test's 120 s expectation and the test that reads
`scripts/run-ci-check.sh`, which the branch changes). Host readings on the slow VPS: no throttling in 99 samples, host load
average (1 minute) at most 2.94, cgroup memory peak 2.89 GB; peaks on the fast runners 3.45 GB (machine A) and 2.75 GB (machine B).

Hosted measurement (2026-11-09). The same measurement branch, merged with `main` at 48462d4 (the later commits of `main`
change only docs), ran once on the GitHub-hosted runner (run 42522317222, job 128858289534; the default per-test limits
raised to 900 s, the explicit tags unchanged; line numbers are those of the measurement commit): approval negative control 40.8 s (34 percent of
the 120 s default); `assembly/durable-job` consumer test 79.0 s (66 percent; inner `consumer_mix_test` 71.2 s; 74.8 s, 67.5 s and
61.9 s in the full hosted runs 42517023581, 42520133125 and 42521924097); `integration/sql` 19.0 s; `integration/jobs` 14.9 s; root
suite 1307.8 s (the two failures of that run are the two expected on the branch). The decision rule needs both tests under 72 s
(60 percent of 120 s) to close the task without a change: the durable-job test is above it, so the two limits are raised
to 300 s as approved.

## History

CI ran on GitHub-hosted machines before ELZ-019, on the owner's machines from ELZ-019 to ELZ-066, and runs on GitHub-hosted
runners again since 2026-11-09.

- ELZ-019 moved CI from hosted machines to the first self-hosted runner. ELZ-020 measured BEAM scheduler settings and
  split the backend and Gleam roles. ELZ-034 admitted a second backend runner (PR #61, merge `9890dee`); ELZ-040 removed its
  one-time route and hardened the guard; ELZ-042 closed the flow-style job and missing-container gaps found in the
  ELZ-040 review; ELZ-043 split the dependency cache so it is saved after `mix setup`, and added the action SHA-pin check.
- ELZ-056 added a slow rented VPS as an unrouted candidate runner. Its cold full run took 72 min 42 s (`mix setup` 22 min 2 s,
  `mix check` 47 min 16 s), and two tests exceeded the 120 s per-test default there, which led to ELZ-062. ELZ-057 added the
  fast tier (pull request and queue runs on the fast runners only) and the runner budget rules.
- ELZ-058 skipped redundant push runs; ELZ-060 moved the Gleam compiler download to the release-asset API after the
  browser URL answered 504; ELZ-064 added the disposable S3 test server; ELZ-065 removed private details before
  publication.
- ELZ-066 added the hosted jobs next to the self-hosted ones, chosen by a repository variable; the rehearsal runs, the flip
  and the verification run are in "Hosted CI". ELZ-069 removed the self-hosted jobs, the runner roles, the tier input of the
  manual run and the variable. The full text of the removed sections (runner roles and routing, runner tiers and budget, machine
  and container setup, the slow VPS runner) is in git history: `git log -- docs/development/10-symbolic-ci.md` and the version
  before ELZ-069. Published logs of past runs keep the old runner names (owner decision 2026-11-09).

### Publishing refs (ELZ-065)

Push only named branches from the owner's checkout (`git push origin <branch>`). Never use `git push --all`, `--mirror`
or `refs/t3/*`: the local-only refs `refs/t3/orchestration-v2/*` hold agent session files with local paths and a test
password, and they must stay off the remote. Git history is not rewritten for publication (owner decision 2026-11-09); older
commits keep the older text of files that were redacted later, so a secret that ever reaches a commit must be rotated, not
edited away.
