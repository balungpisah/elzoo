# ELZ-049 — Run the database-free copied consumers concurrently

- Phase: P0 harness (`test/export_test.exs`, new `test/support/cure_consumer_case.exs`, new consumer group test files)
- Catalogue IDs: none
- Dependencies: ELZ-045 (#80) for the per-consumer timing lines that measure this. Merged.
- Source: CI speed assessment 2026-11-08, item 3. Design option A, chosen by the owner on 2026-11-08 ("A").

## Outcome

Today every copied consumer test runs in one ExUnit module with `async: false`, one after the
other. On main `0a42370` the 23 consumers that do not use PostgreSQL took about 190 s in
sequence on `symbolic-elzoo` (job 128581094645) and about 215 s on
`macbook-ubuntu-elzoo-candidate` (job 128568158091). After this task those 23 consumers run in
three ExUnit modules with `async: true`, so up to three consumers run at the same time. The three
PostgreSQL consumers (`integration/sql`, `integration/jobs`, `assembly/durable-job`), the
aggregate consumer and the OTP-only consumer stay in sequence in `test/export_test.exs`.

## Scope

- Move the shared consumer helpers (`assert_cure_consumer`, `timed`, the consumer `mix.exs`
  template, the runtime script, the provider closure) from `test/export_test.exs` into an
  `ExUnit.CaseTemplate` under `test/support/`, loaded by `test/test_helper.exs`. The helper code
  moves; it does not change.
- Add three test files, one module each, `async: true`. Each module defines the same per-ID test
  (same name, same `consumer_id` tag, same 120 s limit) for its group of database-free consumer
  IDs. The groups are explicit lists in the case module, balanced by the measured per-consumer
  times on main `0a42370`. The union of the groups plus the PostgreSQL list equals
  `Elzoo.CheckSelection.consumer_ids/0`.
- `test/export_test.exs` keeps the five plan/write tests, the OTP-only consumer, the aggregate
  consumer, the three PostgreSQL consumers and the affected-selection test. The selection test
  counts per-ID tests over the four consumer modules instead of one module; the counts stay 26 and 1.
  It also asserts that no database-free group ID has a PostgreSQL provider in its copy closure.
- No workflow, database or `Elzoo.CheckSelection` change. The `--exclude consumer_id:<id>`
  filters of the affected mode (ELZ-038) keep the same tags.
- `docs/development/10-symbolic-ci.md`: what runs concurrently, what stays in sequence, and the
  measured before/after.

## Acceptance

- [ ] Full `mix setup` and `mix check` pass locally.
- [ ] 20 repeats of the three database-free group files on `macbook-ubuntu-elzoo-candidate`
      (dispatch runs on the branch head) with no failure and no time limit hit; the largest
      observed per-consumer `total` recorded.
- [ ] Root suite `Finished in` and the `ELZOO STAGE root_suite` elapsed on the same SHA before and
      after, both runners, run and job IDs recorded.
- [ ] Root test count unchanged (564 on main `0a42370`); no assertion weakened.
- [ ] Independent review of the actual diff (shared test harness; evidence claims).

## Limits

Concurrency is bounded by module count (three), not by a measured CPU budget. The gain is
hypothetical until measured on both runners. Three concurrent consumer VMs add memory; the cgroup
peak before and after is recorded, not guaranteed. A passing repeat series is a finite sample.
