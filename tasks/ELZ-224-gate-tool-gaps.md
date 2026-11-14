# ELZ-224 — Four small gaps of the gate tools are closed: the small gate runs the classifier guard, `--live` reads every issue, the queue names its `gh` need, and recorded `.sse` files pass `git diff --check`

- Dependencies: ELZ-033
- Output: none. A harness and tool repair; no Piece Contract changes.
- Change class: non-Piece root/shared harness repair with a script of the plan job: full/affected local gate and full hosted check. No selected-gate shortcut, never docs-only.
- Allowed implementation path: `lib/mix/tasks/check.ex`, `lib/elzoo/check_selection.ex`, `test/check_selection_test.exs`, `scripts/check-roadmap.py`, `.gitattributes` (new, repository root), `docs/development/10-symbolic-ci.md` (sections "Small gate for Piece-only pull requests" and "Coordinator merge queue"), and `AGENTS.md` section 5 only for the one sentence of part 1. No workflow file, no `scripts/merge-queue.py`, no `scripts/ci-change-class.py`, no file under `pieces/`.

Four parts, one pull request. If a reviewer asks to split, part 1 is its
own task and parts 2 to 4 are another.

## Part 1 — the small gate runs `scripts/test-ci-change-class.py`

Why. The hosted job `check-plan` runs this guard on every pull request.
It scans the sources for a literal that looks like a read of a document
(`"docs"`, `docs/...`, `README.md`, `File.ls`). The small gate does not
run it, so a Piece task sees the failure only after a push. Four pull
requests record a lost hosted run for this in their bodies: #372, #376,
#379 and #419 (the sweep also named #299; its body does not say so).

Facts checked on `main`:

- `lib/mix/tasks/check.ex:62-100` runs the stages `format`, `compile`,
  `ledger`, the Registry load and the test stage. No stage runs a Python
  guard. `lib/elzoo/check_selection.ex:283` already calls `python3` for
  the classifier (`piece-paths`).
- `python3 scripts/test-ci-change-class.py` took 5.5 s on a developer
  host (78 tests), with no Mix and no network.
- `AGENTS.md` section 5 lists what the small gate runs.

Change: in piece mode only, `mix check --piece` runs `python3
scripts/test-ci-change-class.py` as a stage of its own before the test
stage, prints its output, and fails when it exits non-zero. The report of
the small gate names the stage. Add the stage to the list in `AGENTS.md`
section 5 and in the CI guide. The full check and the parts are
unchanged: the plan job runs the guard there.

## Part 2 — `check-roadmap.py --live` reads every issue

Facts checked on `main`:

- `scripts/check-roadmap.py:118` lists issues with `--limit 200`.
- The repository has more than 200 issues (2026-11-14). `python3
  scripts/check-roadmap.py --live` on `main` exits 1 with the whole
  message `ROADMAP CHECK FAILED: 1`: issue #1 (ELZ-001) is not in the
  newest 200, and the `KeyError` prints only the number.
- The script has no test file; `--self-test` holds in-memory negative
  controls for the plan, none for the live listing.

Change: read all issues (a paginated call, or a limit that the script
checks: fewer rows than the limit, else fail with a clear message). A
published job whose issue is not in the listing fails with the job ID
and the issue number.

## Part 3 — the queue names its `gh` need (document, no code)

Facts checked on `main`:

- `scripts/merge-queue.py:465` calls `gh api --allow-escape-sequences`;
  other calls use `gh api --paginate --slurp`. A `gh` that lacks one of
  these flags fails in the middle of a queue run.
- No document names a `gh` version. The sweep named "2.104 or newer" at
  line 240; that was not confirmed: `gh` 2.103.3 lists both flags, and
  line 240 is the pull request field list, which 2.103.3 also answers.

Change: one sentence in the CI guide, section "Coordinator merge queue":
the queue needs a `gh` whose `gh api --help` lists
`--allow-escape-sequences` and `--slurp`; checked with 2.103.3 and
2.104.0. No code change in the queue.

## Part 4 — recorded `.sse` fixtures and `git diff --check`

Facts checked on `main`:

- Four recorded files end with an empty line, which ends the last event
  of the recording: one under
  `pieces/delivery/data-stream/test/fixtures/anthropic-direct-data-stream/`
  and three under `pieces/delivery/provider-stream/test/fixtures/`.
- `git diff --check <empty tree> HEAD -- '*.sse'` exits 2 with "new blank
  line at EOF" for each. With `core.whitespace=-blank-at-eof` it exits 0.
- The repository has no `.gitattributes`.

Change: a root `.gitattributes` with one rule, `*.sse
whitespace=-blank-at-eof`, and one comment line with the reason. Do not
change the bytes of a fixture.

## Acceptance

- `small_gate_runs_the_classifier_guard` (`test/check_selection_test.exs`
  or the test that covers the stages of piece mode): the stage is in
  piece mode and in no other mode.
- Negative control, part 1: with a line `File.read!("docs/x.md")` added
  to a test file of one Piece by a temporary edit, `mix check --piece
  "$(git merge-base origin/main HEAD)"` on a Piece-only scratch change
  fails in the new stage and before the test stage; revert. Record the
  output.
- Part 2: `python3 scripts/check-roadmap.py --live` exits 0 on the head
  (or fails only for a real body difference, which is then reported, not
  repaired here). Negative control: with the listing cut to one issue by
  a temporary edit, the message names a job ID and an issue number;
  revert. `python3 scripts/check-roadmap.py --self-test` exits 0.
- Part 4: `git diff --check "$(git hash-object -t tree /dev/null)" HEAD
  -- '*.sse'` exits 0, and the same command without the path still
  reports the old findings in other files (the rule is narrow). `git
  ls-files -s '*.sse'` shows the same object IDs as on `main`.
- Commands, each exit 0: `python3 scripts/test-ci-change-class.py`,
  `python3 scripts/test-ci-runners.py`, `python3
  scripts/check-ci-runners.py`, `python3 scripts/test-merge-queue.py`,
  `python3 scripts/check-roadmap.py`, `mix check --affected origin/main`,
  `git diff --check`. Full hosted check green on the exact head.
- One small gate run on a real Piece-only branch after the change: exit
  0, and the added time of the stage is recorded.
- One independent review.

## Review risk

Low to medium. Part 1 adds a refusal to the small gate: a guard that
fails for a reason outside the change (a stale reviewed line) would stop
every Piece task, so the reviewer runs it on current `main` first. Parts
2 to 4 change no merge evidence.

## Not in scope

The rules of the guard itself (for example that every `File.ls` is a hit
while only a `Path.wildcard` over the root is); a run of Piece examples
in the small gate; a version check inside `scripts/merge-queue.py`; a
test file for `check-roadmap.py`.
