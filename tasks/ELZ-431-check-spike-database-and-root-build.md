# ELZ-431 — check-spike: the Ash spike gets the database and root build its tests need

- Dependencies: none

## Outcome and scope

The hosted `check-spike` job runs the Ash spike's tests without two inputs
that they require. `spikes/ash_foundation/test/support/durable_log_comparison.exs`
calls `Elzoo.DurableLog.PostgresHarness.database_url!/0`, which fails closed
without `ELZOO_TEST_DATABASE_URL`, and it loads `Cure.Elzoo.Replay` from the
root test build (`_build/test/lib/elzoo/ebin`). On the ELZ-424 pull request
(#1038), `check-spike` failed with "ELZOO_TEST_DATABASE_URL is required" at
`test/durable_log_postgres_test.exs`. `docs/development/10-symbolic-ci.md`
says that `check-spike` needs no PostgreSQL service and does not compile the
root project; with the current spike tests, both statements are wrong.
`check-root` runs the same spike correctly after `mix setup`, with the
PostgreSQL service.

- `check-spike` gets the PostgreSQL service and the "Prepare disposable
  PostgreSQL database" step of the work jobs, unchanged: the same digest-pinned
  image, roles, extension check and role check.
- Before the spike commands, it restores the dependency cache that
  `check-piece` restores, without saving it, and runs `mix setup`.
- When Ash changed, it then runs `mix elzoo.ash_spike`.
- It starts no S3 service.
- Each other property of the job is unchanged: the runner checks, the pinned
  actions, the `ash` condition and the one `ELZOO SPIKE CHECK PASSED` marker.
- `scripts/check-ci-runners.py` pins the new shape of `check-spike`.
- `scripts/test-ci-runners.py` adds two cases that the guard refuses:
  a `check-spike` without the service, and one without the database step.
- `docs/development/10-symbolic-ci.md` states what `check-spike` provides.

Paths: the `check-spike` job of `.github/workflows/symbolic-check.yml`,
`scripts/check-ci-runners.py`, `scripts/test-ci-runners.py`,
`docs/development/10-symbolic-ci.md`, and `test/ci_runner_guard_test.exs` only
where it pins the text of `check-spike`. This is a CI change (`AGENTS.md`
section 1). New external dependencies: none.

## Acceptance

- `python3 scripts/check-ci-runners.py`, `python3 scripts/test-ci-runners.py`,
  `python3 scripts/test-ci-change-class.py`, `python3 scripts/check-roadmap.py`,
  `python3 scripts/check-claims.py` and `git diff --check origin/main...HEAD`
  exit 0.
- A negative control, a temporary edit that removes the service from
  `check-spike`, makes `python3 scripts/check-ci-runners.py` fail. It is
  reverted.
- Locally, the commands of the new job pass the Ash spike's tests when run in
  order against a disposable database. Without `ELZOO_TEST_DATABASE_URL`, the
  tests fail closed.
- The full local gate passes (`mix check --affected origin/main`). The pull
  request records each command that cannot run and the exact reason.
- The full hosted check is green on the exact head.
- After the merge, the next exact-head run of the ELZ-424 pull request shows
  `check-spike` green; that pull request records it.
- One independent review, and the exact-head automated review with its threads
  answered and resolved, or the authorized replacement review under
  `AGENTS.md` section 6.
