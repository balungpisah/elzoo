# ELZ-318 — domain/quota: a database uniqueness rule on the unit rows

- Dependencies: ELZ-303

## Outcome and scope

Owner decision of 21 November 2026, before the first release: today
`elzoo_quota_units` has only a plain index on `(tenant, run_id, unit)`, so
the reservation's `PRIMARY KEY (tenant, run_id)` alone keeps a reservation's
unit rows unique. Add a second layer in the database: a unique constraint on
the unit rows that matches what the reservation key already guarantees (one
row per reserved unit of a reservation).

This changes `domain/quota` in place (same Piece ID, before the first
release): the installed schema gains the constraint. Every result of every
public function is unchanged, because with the reservation key in place
`reserve/3` never writes a second row for a `(tenant, run_id, unit)`:
it writes the unit rows once, one per unit of its sorted, unique estimates,
only after it inserted the reservation row, and no other function inserts or
deletes a unit row. Owned
paths: `pieces/domain/quota/**`; then, in the last commit, the Piece's
`docs/plans/release-plan.json` entry (`manifest_sha256`) and the generated
views (`AGENTS.md` section 3). No other Piece changes. An installed schema is
not upgraded: nothing is released yet, and `Elzoo.Quota.Migration.install/1`
creates new tables.

## Required behavior

1. `Elzoo.Quota.Migration.install/1` creates `elzoo_quota_units` with
   `UNIQUE (tenant, run_id, unit)`. The constraint's own index replaces the
   plain index `elzoo_quota_units_run`; there is no second index on the same
   columns. Every other column, check, foreign key, grant and row-security
   step is unchanged.
2. The README table row and the sentence that says the reservation key
   decides the uniqueness of the unit rows state both layers: the
   reservation key, and the database rule on the unit rows. The migration
   comment says the same.
3. Every public function returns what it returns today for every input. A
   unique violation on the unit rows can arise only when the reservation key
   is missing. It is a database error like any other: `reserve/3` returns
   `{:error, :unavailable}` (the existing mapping of `Postgrex.Error`), and
   its transaction rolls back, so no reservation row, unit row or counter
   change is stored.
4. `piece.json`: the scenario test claim in `grounding` names the new schema
   test; `contract` and `limits` do not describe the unit rows' uniqueness
   and stay unchanged, so the release-plan `note` stays unchanged. Refresh
   `manifest_sha256`.

## Acceptance and evidence

1. A schema test: the installed `elzoo_quota_units` has a unique constraint
   on exactly `(tenant, run_id, unit)`, read from the catalog
   (`pg_constraint`/`pg_index`), and no other index on those columns.
2. Negative controls, each a temporary edit reverted and never committed,
   each run against case 3's duplicate reserve, with its result recorded in
   the PR body:
   - Reservation key removed, new rule kept (drop the reservation primary
     key and the foreign key that depends on it): the second reserve of the
     same `run_id` must be refused by the database rule and roll back. It
     returns `{:error, :unavailable}`, and afterwards there is one
     reservation row, one unit row per unit and counters equal to the first
     reserve alone. The probe asserts this through the test file's existing
     `refused/3` helper (state unchanged), and the PR records the SQLSTATE
     (`23505`) and the constraint name of the refusal, so that another
     database error in the temporary DDL cannot pass for it. This replaces the first negative control of case 14 in
     #704 (ELZ-303), whose expected result ("must store a second
     reservation") the new rule now prevents.
   - Both layers removed (the reservation key as above, and the new unique
     constraint): a second reservation is stored and case 3 fails. This
     shows that the test still depends on the uniqueness the two layers
     give.
   The other three case-14 controls of #704 are unchanged; the new
   constraint does not touch the code they edit, so this task does not rerun
   them.
3. `mix test pieces/domain/quota/test` passes with every existing case
   unchanged; the local small gate (`mix check --piece`), `git diff --check`
   and the index step 3 checks. The Piece holds durable state, so the hosted
   substitution for the small gate does not apply.
4. The copied consumer: `domain/quota` has no per-ID consumer, and the small
   gate copies only a newly ready ID into a consumer of its own, so run that
   copied-consumer test explicitly and record its command and exit code:
   `mix test test/export_test.exs --only new_piece_consumer:domain/quota`
   (the `new_piece_consumer` tests of `test/export_test.exs`, excluded by
   default). It passes at the PR head.
5. One full independent review under "Reviewer by risk" in the coordinator
   guide, a green exact-head hosted `check-piece`, the PR marked ready, and
   the automated reviewer's gate of `AGENTS.md` section 6.
