# ELZ-220 — `state/audit-log` claims as tested only what the checks exercise

- Dependencies: ELZ-033
- Output: none. This task changes the ready Piece `state/audit-log` in place: the wording of one Limit and of one grounding claim. The Piece ID stays; no behavior changes.
- Change class: Piece-only implementation, in place on a ready Piece; small local gate and hosted `check-piece`.
- Allowed implementation path: `pieces/state/audit-log/piece.json`, `pieces/state/audit-log/README.md`, and the index and generated changes of `AGENTS.md` section 3 for this row (`manifest_sha256` and `note`). No test file, no `lib/`.

Why. Two tests of this Piece have a part that runs only when the
connected database role has a right. Without the right the part prints
"NOT EXERCISED" and the test passes. The role of every check lacks both
rights, so no check ever ran these parts. `piece.json` still says
"tested".

Facts checked on `main` (confirm each when you start):

- `pieces/state/audit-log/test/elzoo/audit_log_postgres_test.exs`:
  - T9 (`:435`): the part with `SET session_replication_role = replica`
    runs only when `Harness.superuser?/1` is true (`:446`); else it prints
    `ELZOO AUDIT T9 session_replication_role NOT EXERCISED` (`:461-463`).
  - T14/T10 (`:489`): `application_role!/1` runs only when
    `Harness.role_capable?/1` is true, that is superuser or `CREATEROLE`
    (`:516-521`, helper `test/support/audit_log_test_helper.exs:170-177`);
    else it prints `ELZOO AUDIT T10 application role NOT EXERCISED`.
- The hosted jobs create the test role with `CREATE ROLE elzoo_test LOGIN
  PASSWORD ...` and no other attribute
  (`.github/workflows/symbolic-check.yml:147` and the same line in the
  other jobs). `scripts/worker-services.py:665` does the same, and
  `docs/development/01-workflow.md` states "a test role that is not a
  superuser". So both parts are skipped in the hosted check and on a
  worker database.
- `piece.json` line 26 (a Limit): "TRUNCATE, table-owner trigger disable,
  superuser session_replication_role and audit-owner edits bypass capture
  (disclosed, tested); ...".
- `piece.json`, grounding of `test/elzoo/audit_log_postgres_test.exs`,
  ends: "... application-role boundary and reader-role reads where roles
  can be created, checkout failure returning the conservative Store
  result."
- The README is already exact in its test list ("and
  `session_replication_role` where the role is superuser", "where the
  connected role may create roles") but says in Limits that the bypasses
  are "disclosed limits shown by tests" (`README.md:109-112`).

## Task

Reword, and change nothing else:

1. `piece.json`, the Limit: keep the four bypasses as disclosed. Say
   "tested" only for TRUNCATE and the trigger disable by the table owner.
   Say that the `session_replication_role` bypass is shown only when the
   test role is a superuser, and that no check of this repository runs
   with such a role.
2. `piece.json`, the grounding claim: say that the application-role
   boundary and the reader-role reads run only when the test role may
   create roles, and that the hosted check and the worker database give a
   role that may not; there the test prints `NOT EXERCISED`.
3. `README.md` Limits: the same distinction in one sentence.
4. Add an `assumption` grounding entry, or extend the existing one, for
   the two parts that no check runs: the boundary of the application role
   and the `session_replication_role` bypass rest on the PostgreSQL
   contract and on a run by a developer with a capable role, when one is
   recorded in the pull request body.
5. Last commit: the hash and the `note` of the row, then step 3 of the
   index files.

Run the two tests on your worker database and quote the two
`NOT EXERCISED` lines in the pull request body as the evidence of what
the checks see.

## Acceptance

- No sentence of `piece.json` or the README calls a part "tested" that
  prints `NOT EXERCISED` under the role of the hosted check.
- The diff holds no test file and no `lib/` file. `contract` in
  `piece.json` is unchanged, so `note` is unchanged; `manifest_sha256` is
  new.
- `mix test pieces/state/audit-log/test` exits 0; the small gate exits 0;
  `python3 scripts/check-roadmap.py` and `git diff --check` exit 0.
- One independent review: it compares each reworded sentence with the
  test file.

## Review risk

Low for code (none changes). Medium for meaning: the application-role
boundary is a stated Need of the Contract, and after this task the
record says plainly that no check exercises it.

## Not in scope

A test role with `CREATEROLE` or superuser in the workflow or in
`scripts/worker-services.py`; any change of the two tests; the Contract.
