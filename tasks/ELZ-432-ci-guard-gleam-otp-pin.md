# ELZ-432 — CI guard: pin the OTP version of the Gleam job

- Dependencies: ELZ-425

## Outcome and scope

`scripts/check-ci-runners.py` pins the Gleam workflow's setup step and the
`node-version` line before it (`check-ci-runners.py:816`). It does not pin
the `otp-version` that `.github/workflows/symbolic-gleam.yml` passes to
`erlef/setup-beam`. An edit could therefore change or drop the Gleam job's
OTP version without the guard noticing. The independent review of ELZ-425
found this gap; it predates that task.

- The guard requires exactly one `erlef/setup-beam` step in the Gleam job,
  pinned by full commit SHA. Its `with:` block must be exactly
  `otp-version: '<OTP pin>'`, and the `<OTP pin>` must equal the OTP version
  that the root jobs pin (`check-ci-runners.py:138`; 29.1.3 after ELZ-425).
- `scripts/test-ci-runners.py` adds refusal cases: a changed OTP version, a
  removed `otp-version` line, and an extra key in that `with:` block.
- No workflow behavior changes.

Paths: `scripts/check-ci-runners.py`, `scripts/test-ci-runners.py`. This is a
CI change (`AGENTS.md` section 1). New external dependencies: none.

## Acceptance

- `python3 scripts/check-ci-runners.py`, `python3 scripts/test-ci-runners.py`,
  `python3 scripts/test-ci-change-class.py`, `python3 scripts/check-roadmap.py`,
  `python3 scripts/check-claims.py` and `git diff --check origin/main...HEAD`
  exit 0.
- A negative control, a temporary edit of the Gleam job's `otp-version`,
  makes `python3 scripts/check-ci-runners.py` fail. The edit is reverted.
- `mix check --affected origin/main` exits 0, or the pull request records
  each command that cannot run and the exact reason. The full hosted check is
  green on the exact head.
- One independent review, and the exact-head automated review with its threads
  answered and resolved, or the authorized replacement review under
  `AGENTS.md` section 6.
