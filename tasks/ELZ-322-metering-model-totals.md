# ELZ-322 — domain/metering: period totals per provider and model, the rows domain/pricing takes

- Phase: Wave 6 Level 3 (sub-level 3a), prerequisite of ELZ-323
- Dependencies: ELZ-299, ELZ-312
- Release: V1B
- Output: none (in place on `domain/metering`, same Piece ID, before the first release)
- Change class: Piece-only

## Why

`domain/pricing` prices `%{tenant, period, rows}` whose rows are
`%{provider_id, model_id, unit, source, known, unknown_count, count}`, unique
on `{provider_id, model_id, unit, source}`. `domain/metering` `totals/3`
groups by unit and source only, so the pricing README says those rows are
host-built until metering has that read. The Wave 6 plan
(`docs/plans/bot-platform-wave6.md`, Level 2 status) leaves this read to the
coordinator before the Level 3 root acceptance, which prices metering totals.

## Required change

Add one read to `Elzoo.Metering`, next to `totals/3`, which stays unchanged:

- `model_totals(meter, tenant, %{period, max_rows})`, `max_rows` in 1..1000:
  `{:ok, rows}`, one `%{provider_id, model_id, unit, source, known,
  unknown_count, count}` per `{provider_id, model_id, unit, source}` with an
  observation of the tenant in the period. `known`, `unknown_count` and
  `count` mean what they mean in `totals/3` (effective amounts, so the latest
  correction counts, and an unknown effective amount is counted in
  `unknown_count`, never added as zero). Rows are sorted by `{provider_id,
  model_id, unit, source}` in Erlang term order. More groups than `max_rows`
  is `{:error, :read_limit}`, never a truncated list.
- Shape and bounds, then the caller's open transaction, are refused before any
  query with the same atoms and order as `totals/3` (`:invalid`,
  `:in_transaction`), and the read runs through the same tenant-scoped path, so
  `state/tenant-isolation` applies as it does to `totals/3`.
- One grouped query, bounded as `totals/3` is (at most `max_rows + 1` groups
  read).

The README, `piece.json` (`contract`, claims, limits) and the Piece's index
rows follow:
the README states that these rows are the `rows` of a `domain/pricing` usage
value, and the limits keep the `totals/3` scan note for the new read. No
other function, table, index, migration or Contract term changes.

`domain/pricing` calls these rows host-built in its README and in a
`piece.json` limit. That is another Piece's directory and is not edited here;
the coordinator files it after this merges as its own Piece-only task (the
`piece.json` edit changes pricing's manifest hash).

## Acceptance and evidence

1. Metering tests, on real PostgreSQL as the application role of ELZ-285:
   - A fixture with two providers, two models of one provider, two units and
     all three sources, including an observation recorded `:unknown` and one
     corrected from unknown to known: every row has the expected values, and
     for each `{unit, source}` the rows' sums of `known`, `unknown_count` and
     `count` equal that `totals/3` row.
   - A correction from unknown to known moves the observation from
     `unknown_count` into `known` of its own provider and model row only.
   - The sort order, including two `provider_id` values that differ only in
     a byte that a case-insensitive or locale order would place the other way.
   - Exactly `max_rows` groups returns them all; `max_rows + 1` is
     `:read_limit`.
   - Malformed queries and a call inside the caller's transaction are refused
     before any query (no query counted); another tenant's observations give
     no row.
2. Negative controls, each a temporary edit reverted and never committed,
   with its failing test recorded: group without `model_id` (two models of one
   provider merge), and sum the raw `amount` instead of the effective amount
   (the correction case fails).
3. `mix test pieces/domain/metering/test`, the local small gate (`mix check
   --piece`) on the worker's own disposable database, `git diff --check` and
   the index step 3 checks. The hosted substitution for the small gate does
   not apply (durable state and tenant isolation).
4. One full independent review under "Reviewer by risk" in the coordinator
   guide, a green exact-head hosted `check-piece`, the PR marked ready, and
   the automated reviewer's gate of `AGENTS.md` section 6.

## Owned paths

`pieces/domain/metering/**`, this task's catalogue and release-plan entry rows
(`manifest_sha256`, and the entry `note`, which equals the new
`contract`), and the generated `LEDGER.md`, `docs/plans/views.md` and
`docs/plans/dependencies.mmd`.

## Limits

No time-range totals, no other grouping and no price. The read scans every
observation of the period for the tenant, as `totals/3` does; the bound is on
returned groups.
