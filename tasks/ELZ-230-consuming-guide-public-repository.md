# ELZ-230 — The consuming guide no longer says that the repository is private

- Dependencies: ELZ-033
- Output: none. No Piece Contract changes.
- Change class: non-Piece root/shared change. `docs/consuming.md` is not a document for the classifier: `Elzoo.Export` copies it into every export, and the export tests and copied consumers read it (`scripts/ci-change-class.py`, `READ_BY_CODE`). Local gate `mix check --affected origin/main` and `git diff --check`; full hosted check.
- Allowed implementation path: `docs/consuming.md` (one sentence) only.

Facts checked on `main` (confirm when you start):

- `docs/consuming.md:178-180`: "Upstream libraries retain their own
  licenses; provider metadata identifies them, and Mix fetches their
  original packages. The repository is private; source licensing does
  not change GitHub access permissions."
- The repository is public (GitHub API, 2026-11-14).
- `scripts/ci-change-class.py:48` lists the file as read by code.

## Task

Delete the sentence "The repository is private; source licensing does
not change GitHub access permissions." Change nothing else in the file.
Before you start, search the tests for a comparison with the bytes or
the hash of this file (`grep -rn "consuming.md" lib test pieces
scripts`), and name each hit in the pull request body with why it stays
green.

## Acceptance

- The sentence is gone; the paragraph still reads as one.
- `mix check --affected origin/main` exits 0 (the one slot of the
  database server); `git diff --check` exits 0; `python3
  scripts/test-ci-change-class.py` exits 0; `python3
  scripts/ci-change-class.py range origin/main HEAD` prints `false`; the
  full hosted check is green on the exact head.
- One independent review.

## Review risk

Low. The cost is one full hosted run for one sentence. The coordinator
may hold this task until another change of `docs/consuming.md` is due
and do both in that task.

## Not in scope

Any other sentence of the guide; the root README (ELZ-227).
