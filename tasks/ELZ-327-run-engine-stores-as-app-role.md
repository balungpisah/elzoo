# ELZ-327 — Run the RunEngine stores of the root acceptances as the application role

- Dependencies: ELZ-285, ELZ-286, ELZ-323

## Outcome and scope

The root acceptances `test/wave5_tenancy_test.exs` (ELZ-286) and
`test/wave6_count_and_see_test.exs` (ELZ-323) run their RunEngine Runs through
the RunEngine test fixture,
`pieces/assembly/run-engine/test/support/run_engine_test_helper.exs`. Today the
fixture creates its schema, runs its migration and then makes every runtime
Store call on its own owner Repo (`Elzoo.RunEngine.TestRepo`): the Run owner
and its Lease, the Unit store, the Effect intent and host stores, the evidence
Writer and the transcript's reader. So both acceptances run those stores as
the owner, and ELZ-323 accepted that as a stated limit (review finding B1;
`docs/choices.md`, "RunEngine Runs on the owner connection").

After this task both acceptances run those Store calls as the fixed
application role `elzoo_app` of ELZ-285 and assert it.

This is a coordinator one-PR change of shared root test paths. Owned paths:

- `pieces/assembly/run-engine/test/support/run_engine_test_helper.exs` (the
  `fixture/1` options and `resource/3` only);
- `test/wave5_tenancy_test.exs` and `test/support/wave5_tenancy_helper.exs`;
- `test/support/wave6_count_and_see_helper.exs`;
- `docs/choices.md` (the Wave 5 entry "RunEngine Runs on the owner
  connection" and any Wave 6 limits line about the RunEngine fixture);
- the Limits of `docs/research/wave5-tenancy.md` and
  `docs/research/wave6-count-and-see.md`, and their fixture lines about the
  RunEngine fixture;
- the sentence about the RunEngine stores in the Wave 5 completion note of
  `docs/plans/bot-platform-wave5.md`, and any such line that ELZ-326 adds to
  the Wave 6 closure of `docs/plans/bot-platform-wave6.md`;
- this task file, its no-output job row in `docs/plans/release-plan.json`, and
  the generated `LEDGER.md`, `docs/plans/views.md` and
  `docs/plans/dependencies.mmd`.

No Piece Contract, `lib/`, `cure/`, `examples/`, README, `piece.json`,
catalogue or index entry changes. No CI workflow, `.agents/setup`, root
dependency or pin changes.

## Required behavior

1. **Fixture.** `Elzoo.RunEngine.TestHelper.fixture/1` takes two optional
   options, both removed before the engine options are built:
   - `store_repo`: the Repo of every runtime Store binding that the fixture
     makes (the Unit store through `PostgresHarness.attach/5`, the Run store
     and its Lease, the Effect intent and `StoreHost` stores, the evidence
     store and so the transcript's reader). Default `Elzoo.RunEngine.TestRepo`.
   - `grant`: a function of the new schema name, called once after the
     migration and before the first Store call. Default: does nothing.

   `CREATE SCHEMA`, the migration and the teardown's `DROP SCHEMA` stay on
   `TestRepo`. The fixture map records the Repo as `repo`, and `resource/3`
   uses it for its Store. Without the options the fixture behaves as before,
   so the RunEngine Piece's own tests are unchanged.
2. **Grants.** Each root acceptance passes its application Repo (its
   `after_connect` runs `SET ROLE` to `ELZOO_TEST_APP_ROLE`) as `store_repo`.
   Its `grant` is run by its owner Repo and gives the role, in the engine
   schema only, exactly the Store-table grants the acceptance already gives
   on its own Store tables: `USAGE` on the schema, `SELECT, INSERT, UPDATE` on
   `elzoo_log_heads` and `elzoo_outbox`, `SELECT, INSERT` on
   `elzoo_log_records` and `elzoo_checkpoints`. No `DELETE` and no
   `TRUNCATE`: no Store retention runs in these acceptances.
3. **Assertion.** For every RunEngine fixture that an acceptance allocates,
   the acceptance asserts:
   - each Store binding of the fixture (Unit, Run, evidence, every Effect
     intent and host store) is a PostgreSQL Store whose connection's
     `current_user` is the application role, not the session (owner) role, and
     is no superuser, no `BYPASSRLS` role and holds no owner's privileges
     through inheritance (ELZ-323 also: no `LOGIN`, `INHERIT`, `CREATEROLE` or
     `CREATEDB`);
   - as the owner reads it, the role holds no `TRUNCATE` and no `DELETE` on,
     and owns no table of, the engine schema (its four Store tables and Ecto's
     `schema_migrations`).
4. Every existing assertion of both acceptances stays unchanged, including
   ELZ-323's role guard, its audit role check (no `TRUNCATE` on a Store table,
   no audit-schema privilege, no Store table owned by the role) and ELZ-286's
   role facts.

## Acceptance and evidence

- Both root acceptances pass on a disposable PostgreSQL 16 database with
  pgvector and `ELZOO_TEST_APP_ROLE=elzoo_app`; the RunEngine Piece tests pass
  unchanged.
- Negative controls, each a temporary edit, reverted and never committed:
  route the fixture's Store calls back to `TestRepo` (the role assertion of
  item 3 must fail for every test that allocates a Run); withhold one Store
  grant from the engine schema (a Run's first Store append must fail).
- Local gate: `mix check --affected origin/main` and `git diff --check`.
- `docs/choices.md`, the two reports and the wave notes state that the
  RunEngine Run, Unit, evidence and transcript stores run as the application
  role; the remaining
  limit that the ready Store tables are not under row security stays.
- One full independent review, an exact-head green full hosted check, the
  PR marked ready, the automated reviewer's gate of `AGENTS.md` section 6
  and the merge queue on a green `main`.
