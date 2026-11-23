# ELZ-352 — The domain/quota role guard refuses any membership in the session role

- Dependencies: ELZ-303
- Release: V1B
- Output: none
- Change class: test-only repair of the ready Piece `domain/quota`; coordinator-owned one-PR path

## Problem and scope

The same defect as #838 (repaired in the root acceptances by ELZ-350, PR
#840), in the tests of the ready Piece `domain/quota`. `role_guard!/1` in
`pieces/domain/quota/test/support/quota_test_helper.exs` reads whether the application role is tied to the session (owner)
role with `pg_has_role(current_user, session_user, 'USAGE')`. `USAGE` tests
inherited privilege, not membership. A role that is a member of the session
role with `INHERIT FALSE` and `SET TRUE` passes the guard and can still
`SET ROLE` back to the owner. The role of ELZ-285 is not such a member on the
hosts checked, so current runs are not affected.

Coordinator decision: `role_guard!/1` tests `pg_has_role(current_user, session_user,
'MEMBER')` (direct or indirect, with or without `INHERIT`), and names the fact
`member_of_owner` as ELZ-349 and ELZ-350 do; its docstring says membership.
Nothing else changes: no other guard fact, fixture, grant, scenario or
assertion. This is a coordinator one-PR test-only repair (`AGENTS.md` section
1): only the Piece's listed `test/` file changes; the Piece's Contract,
`lib/`, `cure/`, `examples/`, README, `piece.json`, Piece ID and catalogue and
ready entries stay unchanged.

## Acceptance and validation

1. `role_guard!/1` reads `pg_has_role(current_user, session_user, 'MEMBER')` as
   `member_of_owner` and fails on it as it failed on the old fact. No
   `'USAGE'` membership probe is left in the Piece's tests.
2. Negative control, a temporary edit reverted and never committed: on a
   disposable database whose session (owner) role is a disposable login, with
   `elzoo_app` granted that role `WITH INHERIT FALSE, SET TRUE`, the old
   predicate lets the guard's test pass and the new one fails it. Record the
   commands and results.
3. The Piece's tests as `elzoo_app` on the worker's own disposable PostgreSQL
   16 with pgvector: exit 0. The small gate `mix check --piece
   "$(git merge-base origin/main HEAD)"`, `git diff --check`,
   `scripts/ci-change-class.py` and the index step 3 checks.
4. One independent light review, a green exact-head hosted `check-piece`, the
   PR marked ready, and the automated reviewer's gate of `AGENTS.md`
   section 6. The PR closes this task's issue.

## Owned paths

`pieces/domain/quota/test/support/quota_test_helper.exs`, `tasks/ELZ-352-quota-role-guard-membership.md`, this task's no-output job row in
`docs/plans/release-plan.json`, and the generated `LEDGER.md`,
`docs/plans/views.md` and `docs/plans/dependencies.mmd`. No shared path,
manifest, README, dependency or pin. Publish and implement in one
coordinator-owned `task/ELZ-352` PR; create the issue without `task` and claim
with the API branch lock.
