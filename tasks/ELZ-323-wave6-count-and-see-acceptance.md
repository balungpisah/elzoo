# ELZ-323 — Count, price, post and see tenant Runs end to end on PostgreSQL as a non-owner application role

- Phase: Wave 6 Level 3 (sub-level 3b), mandatory root consumer acceptance
- Dependencies: ELZ-055, ELZ-127, ELZ-249, ELZ-267, ELZ-268, ELZ-269, ELZ-270, ELZ-281, ELZ-285, ELZ-297, ELZ-298, ELZ-299, ELZ-300, ELZ-301, ELZ-302, ELZ-303, ELZ-304, ELZ-312, ELZ-313, ELZ-314, ELZ-316, ELZ-318, ELZ-322
- Release: V2
- Output: none
- Change class: shared root consumer acceptance; full/affected gate

## Admission and scope

This mirrors ELZ-252, ELZ-266 and ELZ-286, and is Level 3 of
`docs/plans/bot-platform-wave6.md`. It is not ready until every dependency
has merged. It exercises the public interfaces of the Wave 6 Pieces
(`domain/metering`, `domain/entitlement`, `domain/quota`, `domain/pricing`,
`domain/journal`, the Run transcript of `assembly/run-engine`,
`delivery/dead-letter-store`, `workflow/eval`) together with ready
`assembly/run-engine`, `assembly/checked-command`, `state/audit-log`,
`state/tenant-isolation`, the Wave 5 identity Pieces and the PostgreSQL
Store. No new production Piece, runtime, provider or generic test framework.
A failure of an owning Piece's Contract is a separately scoped repair, not
permission to edit that Piece here or to weaken an assertion.

Money uses the compiled default registry of `domain/money`. The registry
work of ELZ-319, ELZ-320 and ELZ-321 is not a dependency: if any of them has
merged when this is built, this acceptance runs over it unchanged.

The application connection runs as the fixed role of ELZ-285: the test
Repo's `after_connect` runs `SET ROLE` to `ELZOO_TEST_APP_ROLE`, and an owner
Repo runs migrations. If the variable is unset, or the connected role is an
owner, superuser or `BYPASSRLS` role, the test **fails**. It does not print
`NOT EXERCISED` and does not skip.

Audit roles check (coordinator, recorded at publication): `state/audit-log`'s
role Needs hold with the ELZ-285 roles, so no setup task precedes this. The
connected `elzoo_test` role is the non-superuser audit owner (the audit-log
fixture's hosted form) and owns the Store and audit schemas; `elzoo_app`,
reached through `SET ROLE`, is the application role with only the Store-table
privileges the Store needs, no `TRUNCATE` and no audit-schema privilege. The
audited Store Repo uses `DBConnection.ConnectionPool`, never the Sandbox. The
test asserts the role attributes it reads, and fails if `elzoo_app` holds
`TRUNCATE` on a Store table, holds any privilege on the audit schema or owns
a Store table; the report records them. This is the first run of audit-log
under that role, whose own application-role case prints `NOT EXERCISED` in
hosted runs.

## Fixture

Two tenants, T1 and T2, with principals from `integration/token-verify` API
keys generated in the test and memberships from `domain/membership`. RunEngine
Runs use a counting scripted model provider whose calls return
`integration/ai-model` usage. Plan versions and grants for
`domain/entitlement`, two `domain/pricing` cards (`:price`, one currency,
exact decimal rates, a required `rounding`), journal accounts, and a
`workflow/eval` dataset stored as a `state/artifact` version. The period is an
opaque `:utc_month` ID such as `2026-11`.

## Acceptance

1. **Counted Runs.** Each completed model call of a T1 or T2 Run gives one
   usage that the host records with `Elzoo.Metering.record/3`, its `usage_id`
   derived from Run, occurrence and Attempt. Under T1's scope as the
   application role no T2 usage row is visible, and a write of a T2 row gives
   SQLSTATE 42501. As the application role, `ALTER TABLE ... NO FORCE ROW
   LEVEL SECURITY` and `DROP POLICY` on the metering observations table are
   refused (owner-only). A replay after an engine restart records once
   (`:duplicate`). A call cut off by the restart is recorded `:unknown`: it is
   in `unknown_count`, not in `known`. A later `correct/3` moves it.
2. **Allowance.** `Elzoo.Entitlement.resolve/3` resolves T1's plan; a feature
   the plan lacks is denied at the host gate with `feature/2`.
   `Elzoo.Quota.reserve/3` reserves by `run_id` before each Run starts and the
   reserved estimate is the Run's Budget cap. A retried reserve of one Run is
   `{:ok, :duplicate}` and holds its estimate once. Two Runs race behind a
   controlled barrier for the last allowance and exactly one starts. Settlement
   uses the Run's committed actual; a unit settled `:unknown` stays held across
   a restart until `reconcile/3` with `basis: :metering`. A grace resolution
   refuses a new reservation and accepts a settlement.
3. **Price and post.** `Elzoo.Metering.model_totals/3` (ELZ-322) gives the
   rows of the `domain/pricing` usage value. Card version 1 prices the period;
   version 2, published later, leaves that charge equal.
   - While an observation of the period is unknown, the charge is
     incomplete; the host holds it and posts nothing. After `correct/3` makes
     it known, the re-priced complete charge is the period's first posted
     charge.
   - A complete charge posts with `Elzoo.Journal.post/3` as one balanced
     operation whose `operation_id` the host derives from its charge record,
     so a retry is `:duplicate`.
   - A later correction of a known observation of that posted period
     re-prices under the original card version. The fixture's correction is
     chosen so that `difference/3` of the posted charge and the re-priced one
     is nonzero after rounding (the test asserts that), and it posts as a new
     operation whose ID and reason derive from the correction. The host
     keeps the latest charge it has posted for the period (the original plus
     each posted difference) as the baseline. A second correction that leaves
     the rounded charge equal to that baseline gives a zero `difference/3`
     against it and posts nothing.
4. **See.** `transcript/3` of a completed T1 Run with a nested callable shows
   its tree; T2's scope is refused `{:error, :scope}`; the restarted Run shows
   its Effect as unknown with no actual.
5. **Failures.** An `integration/jobs` Relay over a page of permanently
   failing outbox items whose handle stores each failure with
   `Elzoo.DeadLetterStore.put/3` and returns `:done` delivers the later items.
   A stored failure is replayed by the host and resolved once; a second
   resolve with other values is `already_resolved`.
6. **Audit capture.** The allowance grant and a manual credit are
   `assembly/checked-command` descriptors on the PostgreSQL Store with
   `state/audit-log` installed and bound.
   - Each command that appends a record has exactly one Carbonite
     transaction with its actor attribution. That includes an authorization
     denial, which checked-command retains as a record; its transaction holds
     only that record, and it has no outbox item and no effect.
   - The allowance grant writes the host's plan grant in the command's
     resource. The grant fact that `Elzoo.Entitlement.resolve/3` reads comes
     from that resource, so the next reservation sees the new allowance.
     `domain/quota` has no grant write.
   - The manual credit is command first, then effect. The command commits
     its outcome and one outbox item. The host then posts it once with
     `Elzoo.Journal.post/3`, reusing the command's `operation_id` as the
     journal operation ID, so a retried apply replays. A crash between
     commit and apply leaves the item pending, and the next apply posts it
     once.
   - The journal, quota and metering tables are not audited (a stated
     limit).
7. **Plan types** (owner, 2026-11-21; `docs/choices.md`, "Composing plan
   types"), one named group each:
   - pay-as-you-go: metering, pricing, and a post from a receivable account
     to revenue;
   - quota-capped: entitlement, quota and metering, with no charge;
   - prepaid: a top-up to an `allow_negative: false` wallet account and
     charges against it; an overdraw is refused `insufficient_funds` and
     leaves the balance unchanged.
8. **Spend alert.** When `Elzoo.Quota.status/3` crosses a host threshold, the
   host commits one checked command with one outbox notice under the
   operation ID `(tenant, period, threshold)`; a second check of the same
   crossing commits none (replay). The notice is committed, not sent.
9. **Eval.** `Elzoo.Eval.load/4` reads the dataset artifact and
   `Elzoo.Eval.run/2` passes it; a changed recipe package fails its case.
10. **Negative controls**, one at a time, each restored before the final
    passing run: connect the application Repo without `SET ROLE`, with the
    role guard of "Admission and scope" off for that run only, and group 1's
    owner-only refusals must fail (forced row security still filters the
    owner's reads, so the visibility cases alone would not fail); price
    unknown usage as zero (host side), and group 3's held incomplete charge
    must fail; reserve each Run
    under a fresh `run_id`, and group 2's duplicate reserve must fail; skip
    the audit installation, and group 6 must fail. These validate the harness;
    they do not replace the Pieces' own controls.

## Owned paths and validation

- `test/wave6_count_and_see_test.exs` and an optional bounded fixture
  `test/support/wave6_count_and_see_helper.exs`;
- `docs/research/wave6-count-and-see.md`;
- the Wave 6 completion note in `docs/plans/bot-platform-wave6.md`;
- this task file and this task's row in `docs/plans/release-plan.json`;
- the generated `LEDGER.md`, `docs/plans/views.md` and
  `docs/plans/dependencies.mmd`.

No Piece, root dependency or pin, export, registry, CI, workflow or queue
change. The short report records the exact cases, commands, environment
versions, the audit role attributes, negative-control failures and their
restoration, and limits. It makes no complete-Wave claim beyond this
acceptance.

Limits to state: audit capture covers only the checked-command records on
`elzoo_log_records`, not the journal, quota or metering tables; identities are
pinned test keys, not an identity provider; scripted providers, so no real
provider usage report or live MCP endpoint; no invoice, payment or
settlement (Wave 9); the ready Store tables are not under row security, as in
ELZ-286; Run and model metrics are not shown (Q8 A); the counted gate is
harness code (Q9 A); the spend-alert notice is committed, not delivered.

Run the new root acceptance with real disposable PostgreSQL and the role of
ELZ-285, then `mix check --affected origin/main`, the live roadmap and claims
checks and the diff check. No selected-Piece shortcut. One independent review,
exact-head hosted checks and the coordinator merge queue are required. Never
turn a skipped database test or a mocked protocol into integration evidence.
