# ELZ-049 — Run the database-free copied consumers concurrently

- Phase: P0 harness (`test/export_test.exs`, new `test/support/cure_consumer_case_test_helper.exs`, new consumer group test files)
- Catalogue IDs: none
- Dependencies: ELZ-045 (#80) for the per-consumer timing lines that measure this. Merged.
- Source: CI speed assessment 2026-11-08, item 3. Design option A, chosen by the owner on 2026-11-08 ("A").

## Outcome

Today every copied consumer test runs in one ExUnit module with `async: false`, one after the
other. On main `0a42370` the 23 consumers that do not use PostgreSQL took 189.5 s in
sequence on `symbolic-elzoo` (job 128581094645); on `macbook-ubuntu-elzoo-candidate` they took
224.3 s on main `97456c8` (job 128568158091, one merge earlier). After this task those 23 consumers run in
three ExUnit modules with `async: true`, so up to three consumers run at the same time. The three
PostgreSQL consumers (`integration/sql`, `integration/jobs`, `assembly/durable-job`), the
aggregate consumer and the OTP-only consumer stay in sequence in `test/export_test.exs`.

## Scope

- Move the shared consumer helpers (`assert_cure_consumer`, `timed`, the consumer `mix.exs`
  template, the runtime script, the provider closure) from `test/export_test.exs` into an
  `ExUnit.CaseTemplate` under `test/support/`, loaded by `test/test_helper.exs`. The helper code
  moves; it does not change.
- Add three test files, one module each, `async: true`. Each module defines the same per-ID test
  (same name, same `consumer_id` tag) for its group of database-free consumer IDs, with a 240 s
  limit. Measured basis in the PR: 99.1 s in the last completed repeat and two later repeats over
  120 s under three concurrent VMs on the two-core runner; 240 s is 2x that lower bound.
  `test/test_helper.exs` bounds `max_cases` to `System.schedulers_online()` for every async
  module: at most three concurrent consumer VMs on symbolic, at most two on macbook-ubuntu. The groups are explicit lists in the case module, balanced by the measured per-consumer
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
      (a measurement branch with the same test tree) with no failure and no time limit hit; the
      largest observed per-consumer `total` recorded. The repeats run the group files alone, so
      they do not sample the overlap with other async modules inside `mix check`. Record: the
      first 20 (three VMs, 120 s limit) gave 18 passes and 2 timeouts; after the fix (two VMs on
      that runner, 240 s limit) a new series of 20 on that runner, in two jobs of 10 because of the
      90-minute job limit, must pass with no time limit hit.
- [ ] Root suite `Finished in` and the `ELZOO STAGE root_suite` elapsed on the same SHA before and
      after, both runners, run and job IDs recorded; the after-runs are on the final tip, since
      `max_cases` changes the whole async phase.
- [ ] Root test count unchanged (564 on main `0a42370`); no assertion weakened.
- [ ] Independent review of the actual diff (shared test harness; evidence claims).

## Limits

Concurrency is bounded by module count (three) and online schedulers, not by a measured CPU budget. The gain is
hypothetical until measured on both runners. Three concurrent consumer VMs add memory; the cgroup
peak before and after is recorded, not guaranteed. A passing repeat series is a finite sample.
