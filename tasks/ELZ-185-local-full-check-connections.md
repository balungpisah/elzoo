# ELZ-185 — The local full check stays inside the connection limit of the worker database

- Dependencies: ELZ-033
- Output: none. A harness repair; no Piece Contract changes.
- Change class: non-Piece root/shared harness repair; full local gate and full hosted check.
- Allowed implementation path: `test/**`, `lib/elzoo/check*.ex` and the Mix task files of the check, `docs/development/01-workflow.md`. No file under `pieces/`, no CI workflow, no change of `runs-on`, and no change of `scripts/worker-services.py`.

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
  percent; record both times.
- The hosted full check is green on the exact head.
- `docs/development/01-workflow.md` states the measured peak and what
  bounds it.
- One independent review.

## Not in scope

The hosted workflow, the worker services script, the connection limit of
the server, and any Piece.
