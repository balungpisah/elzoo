# ELZ-285 — Provision a fixed non-owner, non-bypass application role for the test databases

- Phase: Wave 5 Level 3 (sub-level 3a), prerequisite of ELZ-286
- Dependencies: ELZ-033
- Output: none
- Change class: CI and shared setup; full gate, never docs-only

## Why

The Wave 5 root acceptance (ELZ-286) must show the `state/tenant-isolation` floor from the production posture: a role that neither owns the protected tables nor bypasses row security. The hosted test role `elzoo_test` owns its database and has no `CREATEROLE`. So `state/tenant-isolation` and `state/audit-log` print `NOT EXERCISED` for their non-owner boundary in every hosted run.

Giving `elzoo_test` `CREATEROLE` would widen the test role for every test and let tests create cluster-wide roles. Instead, the superuser step that already creates `elzoo_test` also creates one fixed role and lets `elzoo_test` switch to it. `elzoo_test` gains no attribute.

A coordinator probe on PostgreSQL 16.16 (the orb's local cluster) ran the statements below under a scratch role name. Then `elzoo_test`, as table owner, granted `SELECT, INSERT, UPDATE, DELETE` and schema `USAGE` to the role and ran `SET ROLE` to it. Under it:

- a restrictive policy filtered rows by the transaction-local tenant setting;
- `ALTER TABLE ... NO FORCE ROW LEVEL SECURITY` and `DISABLE ROW LEVEL SECURITY` failed with "must be owner of table";
- `DROP POLICY` failed with "must be owner of relation";
- `SET row_security = off` and a read failed with "query would be affected by row-level security policy";
- `RESET ROLE` returned to `elzoo_test`;
- `pg_has_role('elzoo_app', 'elzoo_test', 'MEMBER')` was false.

## Required change

In every place that creates `elzoo_test` as the superuser, run these statements idempotently, after the role and before the tests:

```sql
CREATE ROLE elzoo_app NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
GRANT elzoo_app TO elzoo_test WITH INHERIT FALSE, SET TRUE;
```

Then export `ELZOO_TEST_APP_ROLE=elzoo_app` beside `ELZOO_TEST_DATABASE_URL`. Afterwards, connected as `elzoo_test`, check that both roles have `rolsuper`, `rolcreaterole` and `rolbypassrls` false, that `pg_has_role('elzoo_test', 'elzoo_app', 'SET')` is true and that `pg_has_role('elzoo_app', 'elzoo_test', 'MEMBER')` is false. Any other result fails the step.

Owned paths:

- `.github/workflows/symbolic-check.yml`: the "Prepare disposable PostgreSQL database" step of each job that has one. Do not change `runs-on`, images, digests or any other step;
- `.agents/setup` (the existing idempotent role block);
- `scripts/worker-services.py` and `scripts/test-worker-services.py` (the setup script and its assertion of the statements);
- `scripts/check-ci-runners.py` and `scripts/test-ci-runners.py`, only if their guard pins the changed step text;
- `docs/development/01-workflow.md` ("Verify") and `docs/development/10-symbolic-ci.md` (the PostgreSQL image section).

No Piece, root test, dependency, pin, `mix.exs` or `mix.lock` change. The tests of `state/tenant-isolation` and `state/audit-log` are not edited here. Switching their `NOT EXERCISED` branches to this role is its own later task if wanted.

The role is cluster-wide while grants are per database. Tests grant privileges only on their own random schemas, which `DROP SCHEMA ... CASCADE` removes. They never run `DROP OWNED BY elzoo_app` or alter the role. The docs state this rule.

## Acceptance and evidence

1. A hosted run on the exact head prints the role check for each job and is green. `scripts/test-worker-services.py` asserts both statements and the export. `.agents/setup` run twice on a fresh orb leaves one role and one grant.
2. A local scratch check (not committed), as `elzoo_test` with `SET ROLE elzoo_app` on a forced, protected table, repeats the probe above: the owner-only DDL fails and `row_security = off` fails. Record the output.
3. Negative control: temporarily grant with `INHERIT TRUE` or add `BYPASSRLS` to the role in the setup. The role check must fail. Restore before the final gates.
4. Gate: the relevant guard tests (`python3 scripts/test-worker-services.py`, `python3 scripts/test-ci-runners.py`, `python3 scripts/test-ci-change-class.py`), then `mix check --affected origin/main` and `git diff --check`, the full hosted check, one independent review and the merge queue. This is a coordinator-owned non-Piece change, so the one-PR publication path of `AGENTS.md` section 1 applies if the coordinator does it.
