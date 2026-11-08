# ELZ-031 — Specify exact money amounts and the currency registry

- Phase: demand-led domain policy
- Catalogue IDs: domain/money
- Dependencies: ELZ-003

## Outcome

Own exact currency amounts and the closed, versioned currency registry behind
them, naming ex_money/Decimal as the boundary a future worker must exercise
before the handle leaves deferred. No new Piece ID: this is the admission
record for the existing deferred handle.

## Admission record

1. **Responsibility and caller.** Construction from minor units,
   same-currency add/subtract/compare, allocation with explicit residual
   placement, rounding at a declared scale, registry lookup and parse.
   Callers: C4 internal transfer (balanced postings) and C3 refund
   validation; C9 price-template output challenges generality with 0- and
   3-exponent currencies and sub-minor-unit rates.
2. **Interface and invariant.** Inputs: `{currency, minor_units: Int}`,
   registry version, rounding mode, allocation ratios, untrusted code strings
   for parse. Outputs: amounts, typed rejections (`currency_mismatch{left,
   right}`, `unknown_currency`, `malformed_code`, `retired_currency`,
   `scale_overflow`, `malformed_amount`, `invalid_ratios`,
   `unknown_rounding_mode`, `unknown_placement`, `no_minor_unit`,
   `forged_currency`, `unknown_registry_version`). The Contract defines which
   operations return each rejection; it does not silently coerce floats.
   State owner: none (pure). Invariants: a currency is a
   value from a closed, versioned registry carrying an alpha code, a numeric
   code when recorded by the source (otherwise an explicit absent marker),
   and a minor-unit exponent when recorded and applicable (otherwise an
   explicit not-recorded or not-applicable marker), never a bare string; an
   amount may be constructed only when a numeric exponent is recorded, and is
   an integer count of minor units scaled by that exponent (JPY 0, EUR 2,
   BHD 3), never a fixed hundredth; parse distinguishes malformed from unknown
   and returns the canonical registry value; a code retired by ISO stays
   decodable as `retired` on the parsed value (whether a posting context
   accepts it is domain/journal's decision), retirement never deletes an
   entry; the registry version and any disambiguation required for reused
   identifiers are explicit, and old recorded values retain their original
   identity and exponent across registry updates; mixed-currency arithmetic is a typed
   rejection naming both currencies; an allocation sums exactly to its input
   with the residual placement stated (ratios are a list of 1 to 1000
   non-negative integers with a positive sum; each share is the total times
   its ratio divided by the ratio sum, truncated toward zero; the residual is
   the total minus the sum of shares and is zero or has the total's sign; the
   caller chooses to place it on the first positive-ratio part, the last
   positive-ratio part, or to distribute one minor unit of the residual's sign
   to successive positive-ratio parts in list order until it is exhausted;
   the result reports the residual already placed in the parts, never an
   extra amount); no Float in any path. Non-goals:
   exchange rates, locale formatting, journal posting, provider semantics,
   usage units (workflow/budget, domain/metering).
3. **Reuse check.** ex_money 6.x (AshMoney where the consumer chose Ash) over
   Decimal are the candidates; the studied Gleam registry (dime) duplicates
   ex_cldr currency data for Gleam only. Elzoo's remaining policy is the
   Contract above (retired-code handling, residual placement, rejection
   vocabulary) and the Cure-typed result schema at the Port; a wrapper alone
   earns no slot.
4. **Split test.** Registry and amount arithmetic stay behind one interface:
   an amount without its registry exponent cannot be rounded or allocated
   correctly. Formatting and exchange are separable provider choices.
5. **Failure and evidence.** Dangerous paths: fixed-hundredth scaling for a
   0/3-exponent currency; silent float conversion; a retired code deleted from
   the registry breaking historical replay; a dropped allocation residual.
   Proofs: selected Cure laws over minor-unit arithmetic (closure, allocation
   sum) if the pin's Int reasoning permits, otherwise finite tests with the
   limitation recorded. Tests: every currency-bearing row of the pinned,
   dated current ISO dataset resolves by alpha and numeric to the same
   canonical value, preserving the published minor-unit integer or N.A.
   marker; each other current row is asserted to contain no alpha code,
   numeric code or minor-unit value. Every row of the pinned historic dataset
   is retained and resolves by alpha with its published numeric code or
   explicit absence and withdrawal text; where a numeric code is present,
   numeric history includes the row and never silently selects among reused
   identifiers. Every registry entry is represented by a source row or
   retained from a prior version as retired; tests cover both directions,
   explicit version-qualified active lookup, reused identifiers, and
   preservation of prior identities and exponents across updates; `JPY 1000`
   round-trips without a decimal point and `BHD 1.234` keeps three places;
   `EUR 1.00` split three ways sums to 100 minor units; a C9 charge in one
   currency cannot post into a journal account of another. Upstream: ex_money
   rounding/allocation behaviour is named, not proved.
6. **Composition record.** Consumed by domain/journal (same-currency
   postings; refuses `retired` currencies for new postings), domain/pricing (output currency and scale) and
   assembly/ledger-checkout; provider pins recorded on adoption; financial
   amounts are not secrets; no delivery or durability claim.

## Scope

- decide between ex_money and Decimal-only by exercising construction from
  untrusted strings, allocation residuals, 0/3-exponent currencies and
  persistence round-trip through integration/sql;
- define the result schema and the registry version evidence rule (an
  externally sourced, dated dataset is used to create a source-attributed,
  dated derived extract committed beside the test; source URLs, source
  hashes and a reproducible derivation and comparison method are recorded);
- select laws or record why finite tests stand in;
- shared paths, exactly: `mix.exs` adds the direct dependency
  `{:decimal, "== 3.2.0"}` (currently present transitively in mix.lock at
  3.2.0; keep the lock consistent with the resolved dependency);
  `registry/providers.json` adds the `decimal` provider (hex, package
  `decimal`, version 3.2.0, Apache-2.0,
  https://hexdocs.pm/decimal/3.2.0/Decimal.html); the repository test
  `test/elz031_money_persistence_test.exs` runs the integration/sql round
  trip, so the copied `domain/money` bundle stays pure and does not depend on
  integration/sql; the `domain/money` row of `registry/catalogue.json`, its
  `docs/plans/release-plan.json` entry, regenerated `LEDGER.md`, and only the
  generated roadmap views that this authorized metadata change requires.

## Acceptance

- [ ] Dataset round-trip test in both directions passes against a dated
      registry file.
- [ ] 0- and 3-exponent currencies and the allocation residual case pass.
- [ ] Retired codes decode with the `retired` mark and never disappear.
- [ ] Operational applicability is declared per docs/operational-contracts.md.

## Evidence and limits

Tests over a pinned dataset and listed scenarios; selected laws where Cure
Int reasoning permits. No exchange-rate or payment claim.

## Out of scope

Exchange rates, invoicing, formatting, payment providers.

## Reference

Shapes observed in dime 1.2.0 (registry, parse, dataset test) and the
money_pattern 1.0.0 negative example; see docs/research/ecosystem-round-2.md.
No code is copied.
