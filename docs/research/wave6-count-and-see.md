# Wave 6 count-and-see root acceptance

## Scope

ELZ-323 ([issue #746](https://github.com/balungpisah/elzoo/issues/746)) is the mandatory
Wave 6 root consumer acceptance. It adds no Piece, runtime, provider or generic framework. It
calls the public interfaces of `domain/metering` (with `model_totals/3`), `domain/entitlement`,
`domain/quota`, `domain/pricing`, `domain/journal`, the Run transcript of
`assembly/run-engine`, `delivery/dead-letter-store` and `workflow/eval`, together with the ready
`assembly/run-engine`, `assembly/checked-command`, `state/audit-log`, `state/tenant-isolation`,
`integration/jobs`, `state/artifact` and the PostgreSQL Store. No Piece was edited. Money uses
the compiled default registry of `domain/money`; the registry work of ELZ-319, ELZ-320 and
ELZ-321 had merged by the time this ran, and runs here unchanged.

Files: [test/wave6_count_and_see_test.exs](../../test/wave6_count_and_see_test.exs) and the
bounded fixture
[test/support/wave6_count_and_see_helper.exs](../../test/support/wave6_count_and_see_helper.exs).

## Fixture

- Two Repos on the worker's disposable PostgreSQL 16 database, both
  `DBConnection.ConnectionPool`. The owner Repo connects as `elzoo_test` (a non-superuser: the
  Store, Piece table and audit owner). It creates three random schemas per test, runs the
  migrations, grants, holds a row lock for the race and reads the audit log. The application
  Repo's `after_connect` runs `SET ROLE` to `ELZOO_TEST_APP_ROLE` (ELZ-285).
- Fail, never skip: `setup_all` flunks when `ELZOO_TEST_APP_ROLE` is unset, or when the
  application connection's `current_user` is not that role, equals the session (owner) role, is a
  superuser or `BYPASSRLS` role, or holds the owner's privileges through inheritance.
- Schema `p`: the Store tables; the metering, quota, journal and dead-letter tables, each
  installed by its Piece's `Migration.install/1` under the tenant floor; and the `state/audit-log`
  migration over `p.elzoo_log_records` into its own schema. The application role gets `USAGE` and
  exactly the grants each README lists. On the Store tables that is `SELECT, INSERT, UPDATE` on
  heads and outbox and `SELECT, INSERT` on records and checkpoints: no `TRUNCATE`, no `DELETE`,
  and nothing on the audit schema. A second schema holds unaudited Store tables for the jobs
  outbox and the eval artifact.
- Tenants T1 and T2, opaque period `2026-11`. RunEngine Runs use the RunEngine test fixture (its
  own schema on the owner connection) with the Run's tenant set to the test tenant. Each Run's
  Budget is in `output_tokens`. A model call estimates 20,000 and a nested callable 25,000.
- The counting scripted provider answers each dispatched model call with a validated
  `integration/ai-model` usage value (input and output tokens) and counts the call. The host
  routes the outcome with the output tokens as the actual. The host's Run key is the engine
  identity, unique per Run, because the RunEngine fixture names every Run `run`.
- The host meters a Run from its committed `transcript/3`: each settled model call gives one
  observation per unit, with `usage_id` = Run key / occurrence / Attempt / unit. A completed call
  takes the provider's usage; a call settled `unknown` is `amount: :unknown, source: :unknown`.
- Principals come from `integration/token-verify` API keys generated in the test (HMAC-SHA-256
  digests of random secrets, a digest key as an `Elzoo.Secrets.Credential`): `t1-admin`,
  `t1-finance`, `t1-support` and `t2-admin`. Their memberships are `domain/membership` facts
  (`billing-admin`, `finance` and `support` roles at each tenant's space). The host's
  authorization verdict for a checked command is ALLOW only when `Membership.permissions/4`
  gives the command's permission at the tenant's space; any refusal is DENY.
- Entitlement plan `team` v1 (an `output_tokens` allowance of 100,000 per `:utc_month`). Price
  card `retail`, `:price`, EUR, `:half_even`, exact decimal rates per 1,000,000 tokens: version 1
  `3` input and `15` output; version 2 `4` and `20`.
- The eval dataset is a `state/artifact` version on the PostgreSQL Store and the disposable S3
  test server (MinIO). The test fails if `ELZOO_TEST_S3_*` is not set.

## Cases

1. **Counted Runs.** A completed T1 Run, a completed T2 Run and a T1 Run whose second call is
   cut off by an engine restart. Each completed call is metered once (three provider calls, two
   observations each). Before the restart only the completed call of the cut Run is settled.
   After it, a replay records that call `:duplicate` for both units and the cut call `:applied`
   as unknown. T1's `totals/3` keeps the unknown apart: known 20,000 output and 5,000 input from
   `:provider_reported`, and one unknown observation per unit with known 0. `verify/3` is `:ok`
   for both metering tables. Under T1's scope as the application role only T1 rows are visible
   (6), `observation/3` of a T2 usage is `unknown_usage` under T1, and an INSERT of a T2 row is
   SQLSTATE 42501. `ALTER TABLE ... NO FORCE ROW LEVEL SECURITY` and `DROP POLICY
   elzoo_tenant_floor` on the observations table are 42501 for the application role. A
   `correct/3` moves the cut call's output into known (10,000, unknown count 0). The role facts
   are asserted last.
2. **Allowance.** `resolve/3` gives T1 `:entitled`; `feature/2` allows `model.chat` and denies
   `tools.web` `feature_absent`. The host gate of each Run maps the action kind to a feature and
   asks `feature/2`. On a live Run a `tool_call` is refused `{:deny, "feature_absent"}` and no
   Effect starts.
   - Every Run is reserved by its Run key before it starts, and its Budget cap equals the
     reserved estimate. A retried reserve is `{:ok, :duplicate}` and `status/3` shows the
     estimate once (30,000).
   - Settlement uses the Run's committed actual, the sum of its root settlements' actuals: 0 for
     the refused Run, 12,000 for the completed one.
   - The cut Run's committed actual is unknown. `settle/3` with `:unknown` holds 30,000, and
     the hold stays after the application pool is stopped and started again. After the metering
     correction, `reconcile/3` with `basis: :metering` and the effective sum (8,000 + 10,000)
     commits it (committed 30,000, held 0).
   - Race: two Runs reserve 40,000 against 70,000 remaining. The owner holds the counter row's
     lock until both application backends wait on it (`pg_locks`). Exactly one is `:applied` and
     starts; the other is `:insufficient`.
   - T2: a Run reserved and completed while entitled. After `valid_to_ms`, `resolve/3` gives
     `:grace`; a new reservation is `:settle_only`, and the Run's settlement is `:applied`.
3. **Price and post.** The usage value is `model_totals/3` of T1's period, which has a completed
   Run and a cut Run.
   - With two unknown observations, card version 1 gives an incomplete charge (known amounts: 2
     + 30 = 32 cents). The host holds it and the receivable account has no posting.
   - After `correct/3` makes the cut call known, the complete charge is 47 cents (6,000 input is
     1.8, so 2; 30,000 output is 45). It posts once, revenue +47 and receivable −47, under
     `charge/T1/2026-11/retail/1`; the retry is `:duplicate`.
   - Version 2 would give 62 cents. Re-pricing the period under the charge's own version 1 after
     version 2 is published gives a charge equal to the posted one.
   - Correction `dispute-1` (12,000 → 14,000 output) re-prices under version 1 to 50 cents.
     `difference/3` is 3, which posts as `charge-correction/dispute-1` with the reason
     `correction dispute-1`. The baseline total is 47 + 3.
   - Correction `dispute-2` (8,000 → 8,100 output; 48.15 cents, so 48) gives a zero difference
     against the baseline and posts nothing: the receivable keeps two postings and −50.
4. **See.** A completed T1 Run whose root calls a `nested_callable` whose child makes a model
   call and finishes. `transcript/3` gives the action tree: `nested` at `[]`, `inner-call` and
   `child-done` at `[{1, 0}]`, the root finish at `[]`, one nested start and one nested finish,
   the inner settlement `completed` with actual 9,000 at path `[{1, 0}]`, and a `completed`
   terminal entry. T2's scope is `{:error, :scope}`. The restarted Run's cut call settles
   `unknown` with actual `:unknown`, and there is no `:actual` entry for it.
5. **Failures.** A PostgreSQL outbox stream of five items under an `integration/jobs` Relay with
   limit 3. The handle stores items 1–3 as permanent failures with `put/3` (work reference = the
   item) and returns `:done`. The first pass acks 3 and the second acks 2; nothing is pending, and
   items 4 and 5 were delivered. `list/3` shows the three open failures oldest first, and
   `count/2` is 3 for T1 and none for T2. The host replays the first from its work reference and
   resolves it `:replayed`: `:applied`; the same resolve again is `:duplicate`; `:discarded` by
   another actor is `already_resolved`. The open count is 2.
6. **Audit capture.**
   - The audit roles check: no `TRUNCATE` on a Store table, no `USAGE`/`CREATE` on the audit
     schema and no privilege on its tables for `elzoo_app`. It owns no Store table. Both
     `SECURITY DEFINER` functions are owned by the non-superuser `elzoo_test`, and the pool is
     `DBConnection.ConnectionPool`. `AuditLog.verify/3` is `:ok`.
   - Each actor is a principal verified from its API key. `billing.grant` at `t1-home` is ALLOW
     for `t1-admin` and DENY for `t1-support`; `t2-admin` is DENY, its `permissions/4` at T1's
     space being `cross_tenant`.
   - The allowance grant descriptor writes the host's plan grant into resource `plan-grant`, and
     the grant fact for `resolve/3` is read back from that resource. A grant by `t1-support`
     under its DENY is retained as `{:denied, {:authorization, _}}`: resolution stays
     `:no_grant`. The grant by `t1-admin` commits; the next `resolve/3` is `:entitled`, and a
     reservation sees the 100,000 allowance. `domain/quota` has no grant write.
   - Manual credit `credit-1` (by `t1-admin`) commits its outcome and one `journal-credits` outbox item. The
     host's apply posts it with `operation_id` `credit-1` and crashes before the ack: the item
     stays pending. The next apply replays the post (`:duplicate`) and acks.
   - `credit-2` (by `t1-finance`) commits; with no apply, its item stays pending until the next apply posts it once
     (`:applied`). A further apply finds nothing, and the wallet is 800 with two postings.
   - `AuditLog.read/3` as the audit owner gives exactly four transactions, in order, with their
     actor and action: the denial, the grant and the two credits. Each holds exactly one insert
     change of its own `elzoo_log_records` row (sequences 1–4), and the stream has four records.
     The outbox holds only the two credit items, both acked.
   - The application role's `read/3` is `insufficient_privilege`. The only table in `p` with a
     trigger is `elzoo_log_records`.
7. **Plan types** (`describe "7 plan types"`):
   - pay-as-you-go: T2 observations priced by card version 1 to 78 cents and posted
     revenue +78, receivable −78;
   - quota-capped: resolve, reserve, record and settle with the observation's effective output
     (12,000); `status/3` remaining 88,000; T2 has no journal account (`unknown_account`);
   - prepaid: top-up 100 to a `allow_negative: false` wallet; the 78-cent charge leaves 22; a
     second charge is `insufficient_funds` and the wallet stays 22 (revenue 78).
8. **Spend alert.** Threshold 80% of the T1 allowance on committed plus held. At 50,000 the
   check commits nothing and the T1 stream has no record. At 85,000 it commits one
   `spend-alert/notice` command under `spend-alert/T1/2026-11/80` (expected revision 0 of its
   own resource). It has one pending `spend-alerts` outbox item naming that operation ID. A
   second check returns the first result and the record count and the pending item are
   unchanged. The notice is committed, not sent.
9. **Eval.** `Eval.load/4` reads the dataset from the artifact (hash verified). `Eval.run/2`
   with the recipe package passes its one case (`outcome_is`, `structured_matches` on
   `yes_result`, `tool_called`), and the report's dataset identity is the SHA-256 of the bytes.
   The changed package (choice links swapped) has another identity, and the case fails.

## Environment and checks

Toolchain: Elixir 1.20.4 / Erlang-OTP 29.1.2. The orb's disposable PostgreSQL 16.16 with
pgvector 0.8.7, in a database of this worker's own. The roles are those of ELZ-285, read from
`pg_roles`: `elzoo_app` `NOSUPERUSER NOINHERIT NOBYPASSRLS NOLOGIN`; `elzoo_test` `NOSUPERUSER
NOBYPASSRLS LOGIN`, granted `elzoo_app` with `SET TRUE` and without `USAGE` (inheritance). The
disposable S3 test server is MinIO `RELEASE.2025-09-07T16-13-09Z`. Carbonite 0.17.0, ecto_sql
3.14.0, postgrex 0.22.4.

```sh
ELZOO_TEST_APP_ROLE=elzoo_app mix test test/wave6_count_and_see_test.exs --warnings-as-errors --repeat-until-failure 30
```

```text
Result: 11 passed   (31 consecutive runs)
```

The affected gate (`mix check --affected origin/main`), the roadmap and claims checks
(`python3 scripts/check-roadmap.py --live`, `python3 scripts/check-claims.py`) and
`git diff --check` are recorded with their exit codes in the pull request.

## Harness negative controls

Each was a temporary edit, run, recorded and reverted with `git checkout`. Both files then
matched the committed SHA-256 (test `238ca5c8…`, helper `9d7537bd…`), on a base that includes
ELZ-319, ELZ-320 and ELZ-321. Each run exited 2. The script is a scratch file, not committed.

1. The application Repo connected without `SET ROLE` (as the owner). With the guard on,
   `setup_all` failed and invalidated all 11 tests: `the application connection is not the
   non-owner application role: %{session: "elzoo_test", super: false, current: "elzoo_test",
   bypass: false, inherits_owner: true}`. With the guard also off, group 1 passed its visibility
   and 42501 cases (forced row security filters the owner too) and failed at its first owner-only
   refusal: `ALTER TABLE <schema>.elzoo_metering_observations NO FORCE ROW LEVEL SECURITY`
   succeeded.
2. The host's usage value with every `unknown_count` set to 0 (unknown priced as zero): group 3
   failed at the held charge, `assert held.incomplete and held.unknown_count == 2` (`Expected
   truthy, got false`).
3. Each reservation under a fresh `run_id` (the Run key plus a unique suffix): group 2 failed at
   the retried reserve (`left: {:ok, :applied}`, `right: {:ok, :duplicate}`).
4. The audit migration skipped: group 6 failed at the audit roles check (`definers: []`). With
   that check and `verify/3` also removed, the commands still completed (an unbound schema
   records nothing) and group 6 failed at the capture read, `AuditLog.read/3` →
   `{:error, :unavailable}`.

These validate the harness; they do not replace the Pieces' own controls.

## Limits

- Audit capture covers only the checked-command records on `elzoo_log_records`, not the
  journal, quota or metering tables (asserted: no other table in the schema has a trigger).
  Attribution is per binding, as `state/audit-log` states; this harness binds one session per
  command.
- Identities are pinned test keys, not an identity provider. Only the checked-command actors
  are verified principals; the Wave 6 Pieces take opaque tenant, Run and actor IDs, and the
  quota, metering and journal service actors (`svc:metering`, `svc:billing`, `quota-monitor`)
  are host strings.
- Scripted providers: no real provider usage report and no live MCP endpoint. The eval uses
  scripted models through `runtime/recipe-test`.
- No invoice, payment or settlement (Wave 9). A balanced journal does not prove external
  settlement.
- The ready Store tables are not under row security, as in ELZ-286. The RunEngine Runs, their
  Run owner and Unit stores are on the owner connection (the RunEngine test fixture); only the
  Wave 6 Piece tables, the checked commands, the jobs outbox and the artifact run as the
  application role.
- Run and model metrics are not shown (Q8 A). The counted gate, the metering split, the
  committed actual, the charge hold and post, the credit apply and the spend check are this
  harness's host code (Q9 A), not Pieces.
- The spend-alert notice is committed, not delivered.
- The restart is an engine restart over its committed history and a restart of the application
  pool. No database crash or failover is tested; durability claims stay those of the Pieces.
- Finite scenarios, not proofs. No complete-Wave claim.
