# ELZ-223 — The hosted check runs the tests of `worker-services.py`, and `down` always holds a lock

- Dependencies: ELZ-033
- Output: none. A CI and tool repair; no Piece Contract changes.
- Change class: CI, workflow or queue change. Relevant guard tests, `mix check --affected origin/main` and `git diff --check`; full hosted check. Never docs-only.
- Allowed implementation path: `.github/workflows/symbolic-check.yml` (one `run:` line in the job `check-plan`; nothing else), `scripts/worker-services.py`, `scripts/test-worker-services.py`, `scripts/check-ci-runners.py` and `scripts/test-ci-runners.py` only if a guard pins the list of steps and must name the new line, and `docs/development/01-workflow.md` (the paragraph on `down`) and `docs/development/10-symbolic-ci.md` if it lists the script suites. No `runs-on`, no `permissions`, no new job.

Why. Two findings of the automated review of pull request #220 (the
worker services script) are still open.

1. The suite of the worker services script runs in no hosted job. A
   change that breaks the script merges green.
2. `down` takes its lock from a file inside the state directory. When the
   directory does not exist, `down` takes no lock and still removes
   containers, volumes and the network. An `up` of the same worktree that
   runs at that moment can lose what it just made.

Facts checked on `main` (confirm each when you start):

- `.github/workflows/symbolic-check.yml:53-60` runs six script suites in
  `check-plan`: `test-ci-runners.py`, `test-ci-install-runtime.py`,
  `test-merge-queue.py`, `test-ci-minio.py`, `test-ci-change-class.py`,
  `test-ci-skip.py`. `scripts/test-worker-services.py` is not among them.
- `python3 scripts/test-worker-services.py` needs no Docker, no network
  and no Mix (a fake Docker and Git, its own header says so). On a
  developer host it ran 58 tests in 0.3 s, exit 0.
- `scripts/check-ci-runners.py:664` requires that the step "Decide
  whether the full check is redundant" follows the line of
  `test-ci-skip.py` directly. So the new line goes before that line.
- `scripts/worker-services.py:570-583` (`_locked`): when
  `_state_stat(create)` gives `None` it yields `False` with no lock.
  `down` (`:752-760`) then calls `_down`, and `_remove_own` removes the
  Docker objects of the worktree. The lock file is
  `.elzoo-services/lock`, and `_down` unlinks it and removes the
  directory (`:762-771`).
- `cache_dir/1` (`:148-150`) already names a directory outside the
  worktree that the script owns.

## Change

1. Workflow: add `      - run: python3 scripts/test-worker-services.py`
   to `check-plan`, before the line of `test-ci-skip.py`.
2. Lock: `up` and `down` take one lock whose
   file is not inside `.elzoo-services/` and is not removed by `down`:
   one file for each worktree identity, in the directory that the script
   already owns outside the worktree. `down` holds it also when the state
   directory is absent. Keep every existing refusal (a symbolic link as
   state directory or as lock file, a replaced directory).
3. `docs/development/01-workflow.md`: one sentence on where the lock is.

Build nothing else: no new command, no option, no cleanup of old lock
files beyond what `down` did before.

## Acceptance (named scenarios in `scripts/test-worker-services.py`)

- `down_without_a_state_directory_holds_the_lock`: while one caller holds
  the lock of a worktree, `down` for that worktree with no state
  directory waits (or reports the lock) and removes nothing until the
  lock is free.
- `up_and_down_of_one_worktree_do_not_overlap`: an `up` that waits for a
  running `down` starts only after `down` ended, with no error "removed
  or replaced while this command waited".
- `two_worktrees_do_not_share_a_lock`.
- `down_twice_is_harmless` and the existing tests of `down` stay green
  with unchanged assertions on what is removed.
- Negative control: with the lock of `down` taken only when the state
  directory exists (the code of today, by a temporary edit), the first
  scenario fails; revert.
- The hosted `check-plan` log of the pull request shows the suite ("Ran
  <n> tests", `OK`). Negative control for the workflow line, local: with
  one assertion of the suite broken by a temporary edit the command exits
  1; revert.
- Commands, each exit 0: `python3 scripts/test-worker-services.py`,
  `python3 scripts/check-ci-runners.py`, `python3
  scripts/test-ci-runners.py`, `python3 scripts/test-ci-change-class.py`,
  `mix check --affected origin/main`, `git diff --check`. Full hosted
  check green on the exact head.
- One real `up`, `status`, `down`, `down` on the worker's own worktree:
  exit codes recorded in the pull request body.
- One independent review.

## Review risk

Low to medium. The script is a developer-host tool and is never merge
evidence. A wrong lock can block `up` or `down` on a host: the reviewer
checks that a crashed holder does not leave a lock that stays held
(`flock` ends with the process).

## Not in scope

The services themselves, their images and pins; the database role (see
ELZ-220); any other job of the workflow.
