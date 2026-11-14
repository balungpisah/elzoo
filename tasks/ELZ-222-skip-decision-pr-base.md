# ELZ-222 — The push run accepts a pull request run as evidence only when GitHub says that its pull request targets `main` and never changed its base

- Dependencies: ELZ-033, ELZ-223
- Output: none. A CI evidence rule; no Piece Contract changes.
- Change class: CI, workflow or queue change. Relevant guard tests, `mix check --affected origin/main` and `git diff --check`; full hosted check. Never docs-only.
- Allowed implementation path: `scripts/ci-skip-decision.py`, `scripts/test-ci-skip.py`, `.github/workflows/symbolic-check.yml` (one line: `pull-requests: read` in the `permissions` of the job `check-plan`; nothing else), `scripts/check-ci-runners.py` and `scripts/test-ci-runners.py` (only what pins the permissions of `check-plan`), and `docs/development/10-symbolic-ci.md` (section "Redundant push runs and duplicate pull request checks": the rule list, the trust model paragraph and its limits). No `runs-on`, no new job, no new step, no write permission, no `scripts/merge-queue.py`, no `scripts/ci-change-class.py`.

Why. After a merge, the push run of `main` may skip the full check when
a green run already tested the same tree. For a `pull_request` run the
script checks only that the head holds the whole first parent. It never
reads which base that run merged. A pull request of this repository
into another branch makes a run on the same head, and the run with the
highest ID decides. Such a run tested the merge with another base:
another tree. The merge queue refuses such a pull request before it
merges. A merge by hand (a publication) has no such check.

A first text of this task let the plan job print its base as a log
line. The review refused it: the plan job runs the scripts of the pull
request merge checkout, so a pull request head can print any line. The
base must come from data that the pull request head cannot write. This
text reads it from the GitHub API.

Facts checked on `main` and through the API on 2026-11-14 (confirm each
when you start, and if one differs, stop and ask):

- `scripts/ci-skip-decision.py`, about 254 to 259: for `run.get("event")
  == "pull_request"` the only extra rule is `rev-list --count
  <second>..<first parent> == 0`. No rule of the file reads a base.
- The same file, about 214 to 221 (`evidence_event`): a `pull_request`
  run is a candidate only when `head_repository.full_name` is this
  repository. A run from a fork is never a candidate. This is decided
  before any other read of the run.
- The same file, about 125 to 150 (`Api`): `json(path)` makes one GET
  with the job token and raises `Full` for every status but 200 and for
  invalid JSON. `main()` turns `Full` and every other exception into
  `skip=false`. The script never fails the job.
- `.github/workflows/symbolic-check.yml`, about 6: `pull_request:` has
  no branch filter. About 20 to 22: the job `check-plan` has
  `permissions: actions: read, contents: read`. About 62 to 66: the
  decision step gets `GITHUB_TOKEN: ${{ github.token }}` and runs in
  every event; the script refuses everything but a push to `main`
  before any request.
- `scripts/check-ci-runners.py`, about 20 to 29 (`HOSTED_PLAN_HEADER`)
  and about 779 to 786, pins the permissions of `check-plan` exactly.
  `scripts/test-ci-runners.py`, about 504 to 541 and 754 to 769, tests
  that pin. So one more permission line needs a change of both.
- The run listing gives no base after the merge. Read for two merged
  pull requests (#474, run 43640772675, and #473, run 43639328307,
  both event `pull_request`): the member `pull_requests` of the run is
  `[]`. A rule "the list is not empty and each base is `main`" would
  end every skip. Do not build that rule.
- `GET /repos/{owner}/{repo}/pulls?head={owner}:{branch}&state=all`
  works after the merge and after the branch is deleted. For the head
  branch of #474 it returned one entry with `number` 474, `base.ref`
  `main`, `base.repo.full_name` and `head.repo.full_name` of this
  repository, and `head.sha` equal to the `head_sha` of the run. For a
  branch name that never existed it returned `[]` with status 200.
- The `head_branch` of the two runs is the head branch of their pull
  requests.
- `GET /repos/{owner}/{repo}/issues/{number}/timeline` for #474 and
  #473 returned no base-change event. The count and the kinds of
  the other events grow with later comments and references; a
  different count is not a difference of this fact.
- `scripts/merge-queue.py`, about 83: `BASE_CHANGES =
  ("base_ref_changed", "automatic_base_change_succeeded",
  "automatic_base_change_failed")`. About 307 to 327: the queue lists
  the pull requests of the head branch with the same `pulls?head=`
  read, and it refuses a pull request whose timeline holds any of the
  three events. Its comment says why it does not compare times: a run
  can have tested the old base, and the time of the event does not tell
  which one.
- Both reads answer 200 with no token (the repository is public).
  Whether the job token of `check-plan`, which has no `pull-requests`
  permission, may make them was not tested: it cannot be tested from
  outside a workflow run. This task therefore adds the permission.

## The change

1. For evidence of the event `pull_request`, after the rule on the
   first parent, `ci-skip-decision.py` reads the pull request of the
   run through the API and continues only when all of this holds:

   a. The run has a `head_branch` that is a string and not empty.
      `GET pulls?head=<owner>:<head_branch>&state=all&per_page=100`
      (owner from `GITHUB_REPOSITORY`, the query URL-encoded) answers
      a list of objects with fewer than 100 entries.
   b. Exactly one entry of that list has `head.sha` equal to the second
      parent. None means that GitHub knows no pull request for the
      evidence head. Two or more means that the run cannot be assigned
      to one pull request.
   c. That entry has `base.ref == "main"`, and `base.repo.full_name`
      and `head.repo.full_name` are this repository, and `number` is a
      positive integer.
   d. `GET issues/<number>/timeline?per_page=100&page=<n>`, page by
      page until a page has fewer than 100 entries, at most 10 pages.
      Every page is a list and every entry is an object. No entry has
      an `event` of the three names of `BASE_CHANGES`.

   In every other case the full check runs, with a reason that names
   the failed part: the lookup answered another status than 200 or no
   JSON, a member is missing or has another type, the listing is full
   (100 entries), the timeline has more than 10 pages, no pull request,
   more than one, another base, another repository, a base change.
   There is no retry and no second way to find the pull request.

2. A base change at any time refuses the skip, also one before the
   evidence run. This is the rule of the queue, for the reason in its
   comment. Do not compare the time of the event with the time of the
   run.

3. Evidence of the event `workflow_dispatch` makes no such read: that
   run tests the head itself and has no base. Evidence from a fork is
   refused as today, before any read of a pull request.

4. The rule holds for full evidence and for the short check of a
   documentation-only merge. Both go through the same branch of the
   code.

5. The three event names are written once more in
   `ci-skip-decision.py` (the two scripts share no module). A test
   compares them with `BASE_CHANGES` of `scripts/merge-queue.py`.

6. Workflow: add `pull-requests: read` to the `permissions` of
   `check-plan`. It is read only. It is the permission that both reads
   name. The token already goes only to the decision step. Change the
   pin in `scripts/check-ci-runners.py` and its tests to the three
   lines, and keep every refusal that they test today (a write
   permission, another permission, the permission on another job).

7. The CI guide: the rule in the list of the push-run skip; the new
   permission in the trust model paragraph; and under the limits: a
   pull request whose base ever changed, a pull request with 1,000 or
   more timeline events, and a head branch with 100 or more pull
   requests each cost one full run after the merge.

Build nothing else: no cache of the answer, no option, no environment
variable, no log line of the plan job as evidence, no change of what
the queue checks.

## Named acceptance groups (in `scripts/test-ci-skip.py`)

The fake API of the test script (`FakeApi.json`, about 142 to 164)
answers the two new reads. Its default answer is one pull request of
the second parent with base `main` and a timeline with no base change,
so that the existing tests of `pull_request` evidence stay as they are.
The nearest existing tests are
`test_pull_request_run_is_accepted_as_evidence` and
`test_pull_request_run_needs_a_head_that_holds_the_first_parent` (about
566 to 582).

1. **`pull_request_evidence_with_base_main_skips`**: a `pull_request`
   run, one pull request of the second parent with base `main`, a
   timeline with no base change: `skip=true`. The calls of the fake API
   hold one `pulls?head=` read with the owner, the `head_branch` of the
   run and `state=all`, and one timeline read of that number.
2. **`another_base_runs_the_full_check`**: the same, with `base.ref`
   `release`: `Full`, and the reason names the base. Also `base.repo`
   or `head.repo` of another repository.
3. **`a_changed_base_runs_the_full_check`**: base `main`, and the
   timeline holds one of the three events; one sub-test for each name,
   one with the event dated after `run_started_at` and one dated before
   it: `Full` each time. Also an event on the second page of a timeline
   whose first page has 100 entries.
4. **`an_empty_or_failed_lookup_runs_the_full_check`**: the listing is
   `[]`; the listing has only pull requests with another `head.sha`;
   the listing read fails (status 500, status 403, invalid JSON); the
   timeline read fails; the listing is an object and not a list; an
   entry is not an object; `head_branch` is `None` or empty; the
   listing has 100 entries; the timeline has an eleventh page: `Full`
   each time, and `main()` prints `skip=false` and exits 0.
5. **`two_pull_requests_for_one_head_run_the_full_check`**: two entries
   with `head.sha` equal to the second parent, both with base `main`,
   and then one with base `main` and one with another base: `Full`. A
   second entry of the same branch with another `head.sha` does not
   count: `skip=true`.
6. **`dispatch_and_fork_evidence_make_no_lookup`**: a `workflow_dispatch`
   run skips as today and the calls hold no `pulls` and no `timeline`
   read; a `pull_request` run from a fork is refused as today and the
   calls hold none either.
7. **`the_short_check_needs_the_same_base`**: in `DocsOnlyDecision`,
   the short check with base `main` skips, and with another base it
   does not.
8. **`base_change_names_match_the_queue`**: the tuple of the skip
   script equals `BASE_CHANGES` of `scripts/merge-queue.py`, loaded
   the way `scripts/test-merge-queue.py` loads it.
9. **`existing_behaviour`**: every existing test of the file passes
   with unchanged assertions. A changed line of an existing test is
   only a fake answer that the new reads need.

In `scripts/test-ci-runners.py`: the pinned header of `check-plan` has
the three permission lines; the workflow without `pull-requests: read`
is refused; `pull-requests: write` is refused; `pull-requests: read` on
another job is refused.

Negative controls, each by a temporary edit that is reverted and never
committed:

- With the base comparison of 1c removed,
  `another_base_runs_the_full_check` fails.
- With the timeline rule of 1d removed,
  `a_changed_base_runs_the_full_check` fails.
- With "exactly one" of 1b changed to "at least one",
  `two_pull_requests_for_one_head_run_the_full_check` fails.
- With the permission line removed from the workflow,
  `python3 scripts/check-ci-runners.py` exits 1.

## Evidence and gate

Commands, each exit 0: `python3 scripts/test-ci-skip.py`, `python3
scripts/test-ci-runners.py`, `python3 scripts/check-ci-runners.py`,
`python3 scripts/test-merge-queue.py`, `python3
scripts/test-ci-change-class.py`, `mix check --affected origin/main`,
`git diff --check`. The full hosted check is green on the exact head.

Monitored, after the merge, recorded on the issue of this task: the
decision line of the push run of the merge of this task. Its evidence
is the full `pull_request` run of this task, so the expected line is
`ELZOO PUSH CHECK SKIPPED`. This is the first run in which the job
token makes the two reads. If the line is `ELZOO PUSH CHECK DECISION:
full check runs` with a reason that names a lookup (for example a
status 403), the rule fails closed on every merge: report it on the
issue at once, with the line. It is then a defect with its own task.

Write in the pull request body, under `Assumptions`, that the two reads
with the job token were not observed before the merge, and under
`Upstream` the behaviour of the two GitHub endpoints that the rule
relies on.

## Review risk

High for a CI task: it changes an evidence rule and a token permission.
One independent review by a strong reasoning model. The reviewer checks
in the source that every value of the rule comes from an API answer or
from Git, and none from a job log or from a file of the checkout; that
every failure of a read ends in `skip=false`; and that the token still
goes only to the API host. A fault in the direction "refuse" costs one
full run for each merge (about 17 minutes of five jobs) and is seen in
the monitored line. A fault in the direction "accept" is the hole of
today, not a new one.

## Not in scope

A branch filter on the `pull_request` trigger. The queue's own rules
for a sibling pull request and a base change. A check that the pull
request of the evidence is the one that the push merged. The rule of
the highest run ID. Evidence of `workflow_dispatch`. Any other job or
step of the workflow.
