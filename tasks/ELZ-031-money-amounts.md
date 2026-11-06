# ELZ-031 — Specify exact money amounts and the currency registry

- Phase: demand-led domain policy
- Catalogue IDs: domain/money
- Dependencies: ELZ-003, ELZ-011

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
   `scale_overflow`). State owner: none (pure). Invariants: a currency is a
   value from a closed, versioned registry carrying alpha code, numeric code
   and minor-unit exponent, never a bare string; an amount is an integer
   count of minor units scaled by that exponent (JPY 0, EUR 2, BHD 3), never
   a fixed hundredth; parse distinguishes malformed from unknown and returns
   the canonical registry value; a code retired by ISO stays decodable as
   `retired` for historical postings and is refused for new postings,
   retirement never deletes an entry; mixed-currency arithmetic is a typed
   rejection naming both currencies; an allocation sums exactly to its input
   with the residual placement stated; no Float in any path. Non-goals:
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
   limitation recorded. Tests: every row of a pinned, dated ISO dataset parses
   by alpha and numeric code with equal minor units and every registry entry
   appears in that dataset or is marked retired (both directions); `JPY 1000`
   round-trips without a decimal point and `BHD 1.234` keeps three places;
   `EUR 1.00` split three ways sums to 100 minor units; a C9 charge in one
   currency cannot post into a journal account of another. Upstream: ex_money
   rounding/allocation behaviour is named, not proved.
6. **Composition record.** Consumed by domain/journal (same-currency
   postings), domain/pricing (output currency and scale) and
   assembly/ledger-checkout; provider pins recorded on adoption; financial
   amounts are not secrets; no delivery or durability claim.

## Scope

- decide between ex_money and Decimal-only by exercising construction from
  untrusted strings, allocation residuals, 0/3-exponent currencies and
  persistence round-trip through integration/sql;
- define the result schema and the registry version evidence rule (an
  externally sourced, dated dataset committed beside the test);
- select laws or record why finite tests stand in.

## Acceptance

- [ ] Dataset round-trip test in both directions passes against a dated
      registry file.
- [ ] 0- and 3-exponent currencies and the allocation residual case pass.
- [ ] Retired codes decode for history and are refused for new postings.
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
