# ELZ-350 — The Wave 5, 6 and 7 role guards refuse any membership in the session role

- Dependencies: ELZ-286, ELZ-323, ELZ-338
- Release: V2
- Output: none
- Change class: non-Piece root test-harness repair; coordinator-owned one-PR path

## Problem and scope

Defect #838, found in the review of ELZ-349 (PR #837). The role guards of the
Wave 5, 6 and 7 root acceptances read whether the application role is tied to
the session (owner) role with `pg_has_role(current_user, session_user,
'USAGE')`:

- `test/support/wave5_tenancy_helper.exs`, `role_facts/1`
- `test/support/wave6_count_and_see_helper.exs`, `role_facts/1`
- `test/support/wave7_remember_and_know_helper.exs`, `role_facts/1`

`USAGE` tests inherited privilege, not membership. A role that is a member of
the session role with `INHERIT FALSE` and `SET TRUE` passes the guard and can
still `SET ROLE` back to the owner. The tasks ask for an application role that
is neither the owner nor tied to it, and ELZ-338 names "no membership in the
session role". ELZ-349's helper (`test/support/wave8_bots_talk_helper.exs`)
already tests `'MEMBER'`. The role of ELZ-285 is not such a member on the hosts
checked, so current runs are not affected.

Coordinator decision: in each of the three `role_facts/1`, test
`pg_has_role(current_user, session_user, 'MEMBER')` (direct or indirect, with
or without `INHERIT`), and name the fact `member_of_owner` as ELZ-349 does, in
the helpers and in the assertions of `test/wave5_tenancy_test.exs` and
`test/wave6_count_and_see_test.exs` that read it. The docstrings of
`role_facts/1` and `role_guard!/1` say membership, not privileges. Nothing
else changes: no other guard fact, no fixture, grant, scenario or assertion,
no Piece. The same pattern in the test helpers of the ready Pieces
`domain/quota`, `domain/journal` and `delivery/dead-letter-store` is in Piece
lanes and is left for its own task. The research notes under `docs/research/`
record earlier runs and stay as they are.

## Acceptance and validation

1. Each of the three helpers reads `pg_has_role(current_user, session_user,
   'MEMBER')` as `member_of_owner`, and its `role_guard!/1` fails on it as it
   failed on the old fact. No `'USAGE'` membership probe is left in `test/`.
2. Negative control for each helper, a temporary edit reverted and never
   committed: on a disposable database whose session (owner) role is a
   disposable login, with `elzoo_app` granted that role `WITH INHERIT FALSE,
   SET TRUE`, the old predicate lets the guard pass and the new one fails it.
   Record the commands and results.
3. Each of the three acceptance modules, and the module of ELZ-349, as
   `elzoo_app` on the worker's own disposable PostgreSQL 16 with pgvector and
   MinIO: exit 0.
4. `mix check --affected origin/main` on the one database slot and
   `git diff --check`. If a wall-clock test this change cannot touch fails on
   the host, record the command and reason; the exact-head hosted full check
   is then the evidence (`AGENTS.md` section 5). `check-roadmap.py` (plain,
   `--write`, `--live`), `check-claims.py` and `mix elzoo.ledger`.
5. One independent review, an exact-head hosted full check, the PR marked
   ready, and the automated reviewer's gate of `AGENTS.md` section 6. The PR
   closes #838 and this task's issue.

## Owned paths

`test/support/wave5_tenancy_helper.exs`,
`test/support/wave6_count_and_see_helper.exs`,
`test/support/wave7_remember_and_know_helper.exs`,
`test/wave5_tenancy_test.exs`, `test/wave6_count_and_see_test.exs`,
`tasks/ELZ-350-role-guard-membership.md`, this task's no-output job row in
`docs/plans/release-plan.json`, and the generated plan views. No Piece,
dependency, workflow or queue change. Publish and implement in one
coordinator-owned `task/ELZ-350` PR; create the issue without `task` and claim
with the API branch lock.
