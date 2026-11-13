# ELZ-131 — Admit the fixed split CI evidence shape

- Dependencies: none
- Allowed implementation paths: `scripts/merge-queue.py`, `scripts/ci-skip-decision.py`, `scripts/test-merge-queue.py`, `scripts/test-ci-skip.py` only.

Prepare the trusted validators for ELZ-129 without changing the legacy workflow. Recognize exactly either the complete existing legacy six-job unit or the fixed new eight-job unit: `check-plan`, `check-piece`, `check-hosted`, `check-root`, `check-root-b`, `check-aggregate`, `check-consumers-db`, and `check-consumers`, each once. Do not create a generic versioned framework.

The new work jobs require their own `Run mix check` steps and matching parts and markers: `check-root` / `root-a` / `ELZOO ROOT A SUITE PASSED`; `check-root-b` / `root-b` / `ELZOO ROOT B SUITE PASSED`; `check-aggregate` / `aggregate` / `ELZOO AGGREGATE CONSUMER PASSED`; `check-consumers-db` / `consumers-db` / `ELZOO CONSUMERS DB PASSED`; `check-consumers` / `consumers` / `ELZOO CONSUMERS PASSED`. Full runs require all five successes and Piece skipped; docs runs skip all five and Piece; Piece runs skip all five. Only aggregate `check-hosted` prints the full marker after required results.

## Acceptance

- Accept both complete shapes only with the matching shape's work steps and markers. Reject mixed, subset, extra and duplicate units, including negative controls in both existing test files.
- Retain every existing provenance, mode, latest-attempt, GitHub-hosted, marker, base, tree and main guard and existing negative checks. Leave the workflow, main-green and merge-window guards unchanged.
- Run both validator test files, the required shared-path local gate and `git diff --check`; obtain independent review. ELZ-129 uses these scripts only after this task is merged and green.
