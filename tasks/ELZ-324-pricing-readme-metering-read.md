# ELZ-324 — domain/pricing documents: the metering read for its rows and the checked registry's code lifetime

- Dependencies: ELZ-321, ELZ-322

## Outcome and scope

Two documentation faults in `domain/pricing`, both found after their changes
merged:

- ELZ-322 (PR #751) added `Elzoo.Metering.model_totals/3`: per tenant and
  period it returns `{:ok, rows}`, one row `%{provider_id, model_id, unit,
  source, known, unknown_count, count}` per `{provider_id, model_id, unit,
  source}`; `rows` (not the tagged tuple) is the `rows` field of a
  `domain/pricing` usage value. Its `max_rows` is 1..1000, and a period with
  more groups than `max_rows` is `{:error, :read_limit}`, while pricing takes
  up to 4096 rows: the read covers a period of at most 1,000 groups, and the
  host still builds the rows of a larger one. The pricing README (the "Usage"
  section, the limits paragraph and the Needs line) and the `piece.json`
  limit and assumption still say that the host builds these per-provider and
  per-model rows, the first two until `domain/metering` has a read for them.
- ELZ-321 (PR #749) says in the README `opts` paragraph that a host that
  prices many cards under one custom registry can check it once itself and
  pass the checked value. It does not say how long that checked value is
  accepted. The `domain/money` limits state it: a checked value works only
  with the `Elzoo.Money.Registry` code that made it, and the host checks
  again after a code upgrade. `price/3` and `difference/3` pass every
  `registry:` to `Elzoo.Money.Registry.check/1`, so a checked value that
  `check/1` refuses, for example after a purge of the build that made it, is
  `{:error, :invalid}`. A new build loaded while the old one is still loaded
  as old code does not by itself make the old value refused.

This is a documentation repair of a ready Piece. No code, test, example or
Contract change: `contract` in `piece.json` stays byte for byte the same.
Owned paths: `pieces/domain/pricing/README.md` and
`pieces/domain/pricing/piece.json`; then, in the last commit, the Piece's
`docs/plans/release-plan.json` entry (`manifest_sha256`; `note` stays equal to
`contract`) and the generated views (`AGENTS.md` section 3). No other Piece
changes, and `domain/pricing` still does not depend on metering code.

## Required behavior

1. README "Usage" section: the sentence that the rows are host-built until
   metering has that read says instead that `Elzoo.Metering.model_totals/3`
   of `domain/metering` returns `{:ok, rows}` with these rows for a period of
   at most 1,000 groups (`max_rows` 1..1000, `{:error, :read_limit}` above
   it), and that the host builds the rows of a larger period (up to the 4096
   rows this Piece takes). Keep that `totals/3` groups by unit and source
   only, and that this Piece does not depend on metering code.
2. README limits paragraph: the same change, with the same 1,000-group
   bound, to "The per-provider and per-model rows are host-built until
   `domain/metering` has a read for them." The rest of the paragraph (the
   host owns the period and the card choice; the Piece does not check that
   the rows are a complete period) is unchanged.
3. `piece.json` `limits`: the same change, with the same bound, to the
   entry that begins "The per-provider and per-model rows are host-built".
   Its other clauses are unchanged.
4. README "Needs" line ("builds the per-provider and per-model rows of a
   complete period") and the `piece.json` assumption ("builds complete
   per-provider and per-model rows for the period"): the host supplies the
   complete per-provider and per-model rows of the period, read with
   `model_totals/3` or built. The rest of each is unchanged.
5. README `opts` paragraph, after "can check it once itself and pass the
   checked value": the checked value is accepted only while the
   `Elzoo.Money.Registry` build that made it is loaded, so the host checks
   again after a code upgrade (see the `domain/money` limits); a checked value
   that `check/1` refuses, for example after a purge of that build, is
   `:invalid`. Do not state that loading a new build alone refuses it.
6. The example comment "Host-built rows" in `examples/pricing.exs` stays: the
   example builds its rows inline.

## Acceptance and evidence

1. `grep -n "has that read\|has a read for them"
   pieces/domain/pricing/README.md pieces/domain/pricing/piece.json` prints
   nothing, and the three sentences of requirements 1 to 3 (the README Usage
   sentence, the README limit and the `piece.json` limit) each name the
   1,000-group bound of `model_totals/3`.
2. `contract` in `piece.json` is unchanged, and the release-plan entry has the
   new `manifest_sha256` of `piece.json` at the head and `note` equal to
   `contract`.
3. `mix test pieces/domain/pricing/test`, the local small gate (`mix check
   --piece "$(git merge-base origin/main HEAD)"`), `git diff --check`, and the
   index step 3 checks (`mix elzoo.ledger`, `python3
   scripts/check-roadmap.py --write`, `python3 scripts/check-roadmap.py`).
   Pricing checks card hashes and registry identity, so the hosted
   substitution for the small gate does not apply, although no code changes.
4. One full independent review under "Reviewer by risk" in the coordinator
   guide, a green exact-head hosted `check-piece`, the PR marked ready, and
   the automated reviewer's gate of `AGENTS.md` section 6.
