# ELZ-222 — The push run accepts a pull request run as evidence only when that run says its base was `main`

- Dependencies: ELZ-033
- Output: none. A CI evidence rule; no Piece Contract changes.
- Change class: CI, workflow or queue change. Relevant guard tests, `mix check --affected origin/main` and `git diff --check`; full hosted check. Never docs-only.
- Allowed implementation path: `scripts/ci-skip-decision.py`, `scripts/test-ci-skip.py`, `scripts/ci-change-class.py`, `scripts/test-ci-change-class.py`, and `docs/development/10-symbolic-ci.md` (section "Redundant push runs and duplicate pull request checks"). No workflow file, no `permissions`, no `runs-on`, no `scripts/merge-queue.py`.

Why. After a merge, the push run of `main` may skip the full check when a
green run already tested the same tree. For a `pull_request` run the
script checks only that the head holds the whole first parent. It never
reads which base that run merged. A pull request of the same repository
into another branch produces a run on the same head, and the run with the
highest ID decides. Such a run tested the merge with another base: another
tree. The merge queue refuses a sibling pull request before it merges; a
merge by hand (a publication) has no such check.

Facts checked on `main` (confirm each when you start; if one differs,
stop and comment on the issue):

- `scripts/ci-skip-decision.py:253-259`: for `run.get("event") ==
  "pull_request"` the only extra rule is `rev-list --count
  <second>..<first parent> == 0`. The word `base` occurs in no rule of
  the file.
- `.github/workflows/symbolic-check.yml:6`: `pull_request:` has no
  branch filter.
- The listing of runs gives no usable base after the merge. Read on
  2026-11-14 for two merged pull requests (runs 43631309038 and
  43629689589, event `pull_request`): the member `pull_requests` of the
  run is `[]`. So a rule "the list is not empty and each base is `main`"
  would refuse every run and end every skip. Do not build that rule.
- The decision already reads lines of the plan job log
  (`has_line(plan, ...)`, `:309-320`), for example `ELZOO PLAN:
  run=true ...`. The step "Classify the change" of the plan job runs
  `python3 scripts/ci-change-class.py github`, which prints `ELZOO CHANGE
  CLASS: docs_only=...` (`scripts/ci-change-class.py:255-262`).
- On a `pull_request` event GitHub Actions sets `GITHUB_BASE_REF` to the
  name of the base branch (GitHub documentation; not set for a push).
- `main` is never force-pushed (branch protection: force pushes off). So
  a base that was `main` at the time of the run is an ancestor of the
  first parent, and the existing ancestor rule then gives the tree
  argument.

## Change

1. The plan job states its base. `ci-change-class.py github` prints one
   more line on a `pull_request` event: `ELZOO PR BASE: <GITHUB_BASE_REF>`
   (only a value that is a plain branch name; any other value prints
   nothing). No workflow change: the step exists.
2. `ci-skip-decision.py`: for evidence of the event `pull_request`, the
   plan job log must hold exactly one line `ELZOO PR BASE: main`, and no
   other `ELZOO PR BASE:` line. Otherwise the reason is "the pull_request
   run did not test the base main" and the full check runs. A
   `workflow_dispatch` run needs no such line (it has no base). The rule
   holds for full evidence and for the short check of documents.
3. The CI guide: one sentence in the list of rules of the push-run skip,
   and one in "Limits": a run from before this task has no such line, so
   the push run of a pull request whose evidence run is older does the
   full check once.

## Acceptance (named scenarios in `scripts/test-ci-skip.py`)

- `pull_request_run_with_base_main_skips`: the existing fake run plus the
  line; `skip=true`.
- `pull_request_run_with_another_base_is_refused`: a fake run whose plan
  log says `ELZOO PR BASE: release`; `skip=false` with the reason.
- `pull_request_run_without_a_base_line_is_refused`, and
  `two_base_lines_are_refused`.
- `dispatch_run_needs_no_base_line`: unchanged result.
- `docs_only_short_check_needs_the_base_line`.
- In `scripts/test-ci-change-class.py`: the line is printed for
  `pull_request` with `GITHUB_BASE_REF=main`, and not for `push`, for an
  empty value or for a value with a space or a slash-dot shape.
- Negative control: with the new rule removed by a temporary edit,
  `pull_request_run_with_another_base_is_refused` fails; revert.
- Commands, each exit 0: `python3 scripts/test-ci-skip.py`, `python3
  scripts/test-ci-change-class.py`, `python3 scripts/test-ci-runners.py`,
  `python3 scripts/check-ci-runners.py`, `python3
  scripts/test-merge-queue.py`, `mix check --affected origin/main`, `git
  diff --check`. Full hosted check green on the exact head.
- Monitored, after the merge: the plan log of the pull request run of
  this task holds `ELZOO PR BASE: main`, and the push run of its merge
  prints its decision with a reason. Record both lines on the issue.
- One independent review by a strong reasoning model.

## Review risk

Medium. It changes an evidence rule. A fault in the direction "refuse"
costs one full run for each merge (about 17 minutes of five jobs). A
fault in the direction "accept" is the hole of today, not a new one. The
line comes from the pull request's own code, as the other markers do; the
script takes evidence only from runs of the same repository.

## Not in scope

A branch filter on the `pull_request` trigger; a new token permission; a
lookup of pull requests through the API; the queue's own sibling and
base-change rules.
