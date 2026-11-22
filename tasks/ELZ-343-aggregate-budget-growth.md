# ELZ-343 — Give the aggregate consumer a 45-minute budget for the next waves

- Dependencies: ELZ-253
- Release: V1B
- Output: none
- Change class: non-Piece root test-harness repair; coordinator-owned one-PR path

## Problem and scope

Defect #814. The aggregate consumer in `test/export_test.exs` ("all
selected sources compile and run outside Elzoo with only upstream code
paths") has the 1,500,000 ms outer limit that ELZ-253 set. On the hosted
`check-aggregate` push runs of `main` on 22 Nov 2026 it took 1,012 to
1,374 s (`ELZOO TIMING consumer=aggregate(<n>) total`), and a local 4-CPU run
took 1,471 s. Almost all of it is the consumer's own `mix test`
(`consumer_mix_test`). The time grows with each ready Piece, and a run on a
slower hosted runner takes about 1.3 times as long as one on a fast runner
for the same Pieces. A green change can fail the full check on time alone.

Where the time goes (local profile of the inner run, 137 ready Pieces):
the inner suite took 1,306 s, 981 s of it in the sync phase. 137 of the 195
copied Piece test modules declare `async: false` and run one at a time; the
58 `async: true` modules (324 s) may already run concurrently (`max_cases` 8).
`Elzoo.RunEngineTest` alone takes 271 s. Sampled every 10 s over the last
17 minutes of the run, the host used 0.81 of its four cores on average
(at most 1.82). The `async: false` modules give their own reasons for
running synchronously (shared database locks, captured logs, named
processes, application environment). Running them at the same time would
take either an edit of each Piece's tests or several consumer VMs on the
one disposable database (a split of the aggregate consumer). Neither is a
small repair, so this task keeps one consumer and sets the budget from the
measured growth. A split is a possible later task, decided separately.

Coordinator decision: raise only the aggregate outer limit to 2,700,000 ms
(45 minutes), its existing guard assertion and the nearby explanation. The
basis:

- Hosted, fast runner: 964 s at 114 ready Pieces (20 Nov) and 1,079 to
  1,085 s at 137 (22 Nov), a mean of about 5 s per added Piece. The steepest
  recent stretch, 133 to 137 Pieces (about 1,005 s to 1,082 s), is about
  19 s per Piece.
- Slower runner: up to 1.32 times a fast run with the same Pieces: 1,291 s at
  126 Pieces (978 s on a fast runner, 1.32 times); 1,274 s at 133 (1.24 to
  1.29 times the fast runs at 133); 1,330 and 1,374 s at 136 (1.23 and 1.27
  times the fast runs at 137). A local 4-CPU orb takes 1.29 to 1.36 times the
  fast hosted run (1,391 s and 1,471 s at 137).
- Projection for 20 more Pieces at 20 s each (the steepest recent rate, four
  times the mean): fast hosted 1,085 + 400 = 1,485 s; on a slow runner or a
  local orb, at 1.36 times, about 2,020 s. 2,700 s leaves about 680 s
  (25 percent of the limit) above that projection. It is a measured margin,
  not a worst-case guarantee.
- The `check-aggregate` job keeps `timeout-minutes: 120`; its other steps
  take about 3 minutes (run 45072346027: a 21-minute job around an 18-minute
  aggregate test), so a 45-minute test stays well inside the job limit.

Keep the copied consumer's 300,000 ms inner per-test default, the per-ID
consumer limits (240 s concurrent, 120 s sequential, 300 s for
`assembly/durable-job`, 300 s for the consumer of an added Piece), the
complete ready-Piece selection, every assertion, the default filters and the
post-child configuration and compiler-free runtime checks unchanged. Do not
skip, split or reorder tests, change a Piece, a production deadline, a
workflow, `runs-on` or a CI job budget. #670 is a separate flake and stays
as decided.

## Acceptance and validation

1. The aggregate outer tag and its guard assertion in the partition test of
   `test/export_test.exs` agree on exactly 2,700,000 ms. The inner default
   stays exactly 300,000 ms; the per-ID limit assertions are unchanged.
2. The explanation next to the tag names the measured basis above and the
   date.
3. Run `mix check --affected origin/main` on the worker's own disposable
   PostgreSQL 16 with pgvector and MinIO, with `ELZOO_TEST_APP_ROLE=elzoo_app`,
   plus `git diff --check` and the live roadmap check. If a host time limit
   blocks the local gate, record the exact reason; the exact-head hosted full
   check is then the evidence (`AGENTS.md` section 5). Record the aggregate
   consumer's `total` and `consumer_mix_test` before and after, locally and
   hosted. A child that fails, or a partial log, is not a passing wrapper.
4. One independent review, an exact-head hosted full check, the PR marked
   ready, and the automated reviewer's gate of `AGENTS.md` section 6. The PR
   closes #814 and this task's issue.

## Owned paths

`test/export_test.exs`, `tasks/ELZ-343-aggregate-budget-growth.md`, this
task's no-output job row in `docs/plans/release-plan.json`, and the generated
plan views. No Piece, other root test or helper, dependency, workflow or
queue change. Publish and implement in one coordinator-owned `task/ELZ-343`
PR; create the issue without `task` and claim with the API branch lock.
