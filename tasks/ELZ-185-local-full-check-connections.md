# ELZ-185 — The local full check stays inside the connection limit of the worker database

- Dependencies: ELZ-033
- Output: none. A harness repair; no Piece Contract changes.
- Change class: non-Piece root/shared harness repair; full local gate and full hosted check.
- Allowed implementation path: `test/**`, `lib/elzoo/check*.ex` and the Mix task files of the check, `docs/development/01-workflow.md`, and, for the repair of step 2 only, files under `pieces/*/*/test/**` that start a database Repo or connection (test files and test helpers). No other file under `pieces/` (no `lib/`, `cure/`, `examples/`, `piece.json` or README of a Piece), no CI workflow, no change of `runs-on`, and no change of `scripts/worker-services.py`.

Evidence, from the pull request of ELZ-176 (#395, lines `Local gate:` and
`Friction:`): on one host, `mix check` with no flag failed twice, the second
time on a database server that was made new for the run. 2,139 of 2,141
tests passed. Both failures were consumer tests of `test/export_test.exs`
(the all-sources consumer and the durable-job consumer). The server logged
more than 1,000 `FATAL 53300` (`too_many_connections`) lines, and the count
of `pg_stat_activity` reached 103. The server has `max_connections` 100,
the documented value (`docs/development/01-workflow.md`). The hosted check
does not fail in this way: it splits the root suite over several jobs, each
with a database server of its own.

`AGENTS.md` section 3 says that only one full check runs on one database
server at a time, because the limit is database connections. So one full
check must fit. Today it does not, on this evidence.

Amended 2026-11-14 after the first measurement (the comments of the issue
of this task hold the numbers). On unchanged `main` one full check exited 2
with a peak of 103. Before any copied consumer ran, the root test process
alone held 79 connections (85 in total), all idle. The cause that was found:
test helpers of Pieces start a named Repo, unlink it, accept
`{:already_started, _}` and never stop it, so the Repo and its whole pool
live until the test process exits. Found by reading: the helpers of
`assembly/durable-job` (pool 20), `integration/jobs` (10),
`state/scheduler` (10) and `state/audit-log` (8 and 1): 49 of 69. The other
20 are not yet attributed. The copied consumer of all sources runs the same
tests in its own process and holds connections in the same way. ExUnit
gives no synchronous hook between two test modules, so the harness alone
cannot release them. So the allowed paths now include the test files and
test helpers of Pieces, for this repair only. ELZ-187 changes files of
`assembly/run-engine`: change a file under `pieces/assembly/run-engine/`
only when ELZ-187 is merged on `main`; before that, leave that Piece out
and say so in the pull request body.

## Task

1. Find where the connections come from. While `mix check` runs on a fresh
   worker database (`python3 scripts/worker-services.py down && ... up`),
   sample `pg_stat_activity` (count by `application_name`, `datname`,
   `usename` and `state`, each few seconds) and record the peak and which
   test processes hold the connections at the peak: the root suite, the
   copied consumers that run at the same time, repos that tests start and
   do not stop.
2. Repair the cause in the harness so that the peak stays at or below 80:
   for example a pool size that a consumer run sets too high, consumers that
   run in parallel on one server, or a repo that a test leaves running. Do
   not raise `max_connections`, do not skip or weaken a test, do not make a
   database test optional, and do not change what the hosted jobs run.
   For a Repo that a test helper leaves running: the test module that
   starts it stops it when the module ends (for example `on_exit` of
   `setup_all`, or a start that is supervised by the test), so that an idle
   pool does not outlive its module. First attribute every connection that
   the root test process holds at its peak (a one-off listing of
   `Ecto.Repo.all_running/0` with each pool size, and of connection
   processes that belong to no Repo; never committed). Repair each holder
   that outlives its module. Change no assertion, no test name, no tag and
   no pool size that a test needs for what it asserts; a pool size changes
   only with a reason that the pull request body states for that file.
3. If the only sound repair needs a path outside the allowed ones, stop and
   comment on the issue of this task with the path and the reason.

## Acceptance

- `mix check` with no flag exits 0 twice in a row on a fresh worker database
  with `max_connections` 100; the recorded peak of `pg_stat_activity` is at
  or below 80 in both runs. Record each command, its exit code, the two
  peaks and the run times in the pull request body.
- The same test set runs as before: the count of tests and of excluded tests
  of the full check is unchanged, and the pull request body shows both
  numbers before and after.
- The run time of the local full check does not grow by more than 20
  percent against a full check that exits 0; record both times. The first
  measurement (2,201 s) was a failing run and is not that baseline: when no
  green run of unchanged `main` exists, record the time of the first green
  run of this task and say so.
- The pull request body lists each changed file under `pieces/` with the
  holder that it stops, and the tests of each changed Piece pass.
- The hosted full check is green on the exact head.
- `docs/development/01-workflow.md` states the measured peak and what
  bounds it.
- One independent review.

## Not in scope

The hosted workflow, the worker services script, the connection limit of
the server, and the library code, Contract, manifest or README of any Piece.
