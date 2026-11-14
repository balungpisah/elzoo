# ELZ-219 — Each ready Piece with no fixed consumer has run once in a copied consumer of its own

- Dependencies: ELZ-033
- Output: none. A measurement; no code and no Piece Contract changes.
- Change class: documents only (one short paragraph under `docs/development/`); roadmap checks and the docs-only hosted check. The numbers are in the pull request body; each failure is an issue of its own.
- Allowed implementation path: `docs/development/10-symbolic-ci.md` (section "Small gate for Piece-only pull requests", paragraph "Limits") only.

Why. `test/export_test.exs` holds one test for each ready ID that has no
per-ID consumer. The test copies the dependency closure of the Piece into
a new Mix project, compiles it, and runs the Piece's own tests there. The
tag `new_piece_consumer` is excluded by default. Only the small gate runs
such a test, and only for an ID that the change adds. So a Piece that was
ready before ELZ-153, or that changed after it was added, never ran in a
copy of its own closure. A fault of this kind is seen today only inside
the aggregate consumer, mixed with all other sources.

Facts checked on `main` (confirm each when you start):

- 108 catalogue entries are ready. `Elzoo.CheckSelection.consumer_ids/0`
  (`lib/elzoo/check_selection.ex:7`) names 28. So 80 IDs have such a
  test (`test/export_test.exs:198-206`).
- `test/test_helper.exs:18` excludes the tag. `test_args/1` of piece mode
  (`lib/elzoo/check_selection.ex:311-315`) includes
  `new_piece_consumer:<id>` for added IDs only.
- Each such test has a limit of 300 s (`test/export_test.exs:197`,
  owner decision on issue #328). The comment above it records five
  measured IDs on a developer host (90.7 s the largest).
- The tests are in one module with `async: false`: they run one after
  another in one launch.

## Task

1. On a fresh worker database (`python3 scripts/worker-services.py up`),
   at `origin/main`, run once:

       mix test test/export_test.exs --only new_piece_consumer

   This is one Mix launch and one database server. Run nothing else on
   that server at the same time, and keep to three Mix workers on the
   host. Expect 80 tests; the other tests of the file are excluded by
   `--only`. If the command does not select exactly 80 tests, stop and
   comment on the issue with the output.
2. Record for each ID: passed or failed, and the `total` seconds of its
   line `ELZOO TIMING consumer=<id> total seconds=...`.
3. For each failure open one issue: the ID, the failing test, the output,
   and whether `mix test pieces/<family>/<name>/test` passes in the root
   project on the same commit. Run a failed ID a second time alone
   (`--only new_piece_consumer:<id>`) and record both results. Do not
   repair it here.
4. An ID that passes the 300 s limit is reported to the coordinator on
   the issue of this task. The limit is not changed.
5. Add one short paragraph to the "Limits" of the small gate in the CI
   guide: the date, the commit, how many of the 80 passed, the largest
   time, and the issue numbers of the failures.

## Acceptance

- The pull request body holds a table of 80 rows (ID, result, seconds),
  the command, its exit code, the commit and the host class (developer
  host; not evidence of a hosted time).
- Each failure has its own issue, linked from the body. No failure is
  hidden by a rerun: both results are in the table.
- The paragraph in the CI guide states only what was measured.
- `python3 scripts/check-roadmap.py` and `git diff --check` exit 0;
  `python3 scripts/ci-change-class.py range origin/main HEAD` prints
  `true`; the docs-only hosted check is green.
- One independent review: the reviewer compares the table with the log.

## Review risk

Low. No code changes. The risk is a wrong reading of the result: a pass
here is one run on one host, not a proof of the copy.

## Not in scope

A repair of any failure; a new per-ID consumer in the inventory; the
300 s limit; a hosted run of these tests; the stale count in the comment
of `test/export_test.exs` (about line 196) ("the other 61 IDs"), which is a `test/`
change and belongs to the first repair task that touches that file.
