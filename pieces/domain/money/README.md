# domain/money

Exact currency amounts and the closed, versioned ISO 4217 registry behind them
(ELZ-031, issue #48). A currency is a registry member, never a bare string. An
amount is an integer count of minor units scaled by that currency's exponent
(JPY 0, EUR 2, BHD 3), never a fixed hundredth. No Float is accepted or
produced.

Status: ready (subset). Kind: owned. Providers: Cure (pinned), Elixir,
Decimal 3.2.0. Piece dependencies: none. The bundle is pure: no process, no
Repo and no `Elzoo.Application`.

## Interface

`Elzoo.Money` (all functions return `{:ok, value}` or `{:error, {reason, detail}}`):

| Function | Purpose |
| --- | --- |
| `parse/2`, `parse_numeric/2` | Untrusted alpha code (three ASCII letters, no trimming) or three-digit numeric code to a registry member. `parse_numeric` resolves only among codes active in the stated version. |
| `numeric_candidates/2` | An enumeration, not a parse: every alpha that any held version links to a numeric code. It never chooses among reused codes. |
| `current_status/2` | The code's status in the newest held version. |
| `from_minor_units/3` | An amount from an integer number of minor units. |
| `from_decimal_string/3`, `from_decimal/4` | Exact decimal string, or a `%Decimal{}` rounded with a declared mode. |
| `add/3`, `subtract/3`, `compare/3`, `negate/2` | Same-currency arithmetic (Cure). |
| `allocate/4` | Ratio allocation with stated residual placement (Cure). |
| `round/4` | Round to a declared scale with a declared mode. |
| `to_decimal/2`, `to_decimal_string/2` | Exact output: `JPY 1000` is `"1000"`, `BHD 1234` is `"1.234"`. |

`Elzoo.Money.Codec.encode/2` and `decode/2` write and read canonical bytes,
for example `elzoo-money/1 2026-09-17 BHD 048 3 1234`: format tag, registry
version, alpha, numeric, exponent, minor units. `Elzoo.Money.Registry` holds
the compiled registry and `build!/1` for other extract sets.

Options on every call: `registry:` (default the compiled registry) and
`version:`. For `parse` and `parse_numeric`, `version:` selects the version to
resolve under (default the newest held version); for `numeric_candidates` it
limits the enumeration to that version; for every function that takes a
currency, an amount or codec bytes it is a check: each value must belong to that
version, else `forged_currency`. A `version:` the registry does not hold is
`unknown_registry_version`.

### Rejections

| Reason | Returned by |
| --- | --- |
| `malformed_code` | `parse`, `parse_numeric`, `numeric_candidates`: input is not three ASCII letters or three digits. |
| `unknown_currency` | `parse`, `parse_numeric`; `Codec.decode` for an alpha held in no version. |
| `unknown_registry_version` | any call naming a version the registry does not hold, including in bytes. |
| `forged_currency` | any call whose currency is not the member in effect at its own version (identity and status), or is not a `%Currency{}`; `Codec.decode` for an identity of another version. |
| `no_minor_unit` | construction for an ISO `N.A.` code (XAU, XXX, XTS and others). |
| `retired_currency` | construction for a retired code whose exponent no held version recorded (for example HRK). |
| `malformed_amount` | a non-integer minor-unit value, a malformed decimal string or `%Decimal{}`, a non-integer scale, non-canonical codec bytes (including a value outside the amount range). |
| `scale_overflow` | a decimal string finer than the exponent; a rounding scale outside `-18..exponent`; any amount, constructed or computed, outside the declared range `abs(minor_units) < 10^38`. |
| `currency_mismatch` | `add`, `subtract`, `compare` on different identities; detail names both alpha codes. |
| `invalid_ratios` | `allocate` with ratios that are not 1 to 1000 non-negative integers with a positive sum. |
| `unknown_placement`, `unknown_rounding_mode` | a placement or mode outside the declared atoms. |

## Contract

- **Registry.** Folded at compile time from the dated extracts in
  `lib/elzoo/money/iso4217/` by `Elzoo.Money.Registry.Source`. Each current
  row with a code is an active identity `{alpha, numeric, minor_unit}`; `N.A.`
  stays `:not_applicable`. A historic-only code is retired with its latest
  withdrawal text verbatim, and keeps an exponent recorded by a prior version,
  else `:not_recorded`. A code known before and absent from a new version is
  retained as retired. A code that was active before and is retired now takes
  its withdrawal text only from historic rows the earlier version did not hold;
  without such a row it is `{:retired, :not_recorded}`, never an older
  country-level date. No entry is ever removed. Active numeric codes are unique
  within a version.
- **Identity and membership.** Two amounts are the same currency when
  `{alpha, numeric, minor_unit}` are equal. A `%Currency{}` also carries its
  status and the version it was resolved under; it is a member only when both
  equal the registry entry at that version.
- **Allocation.** Share i is `trunc(total * ratio_i / sum)`. The residual,
  `total - sum(shares)`, is zero or has the total's sign. `:first` places it on
  the first positive-ratio part, `:last` on the last, `:spread` adds one minor
  unit of its sign to each positive-ratio part in order until it is used. The
  result is `%{parts: [Amount], residual_placed: integer}`; the residual is
  already inside the parts, so adding it again double counts.
- **Amount range.** Every amount satisfies `abs(minor_units) < 10^38`
  (`Elzoo.Money.bound/0`), checked at construction and after every add,
  subtract and rounding step (`scale_overflow` beyond it). Every accepted amount
  therefore encodes in at most 75 bytes and decodes again; `Codec.decode/2`
  rejects bytes longer than 128 or with a value outside the range.
- **Rounding.** `round/4` and `from_decimal/4` use integer arithmetic for the
  seven Decimal mode names; the process Decimal context never applies.
- **Replay.** Bytes encoded under one version decode to the same identity
  after a later version is added; the decoded currency carries the status at
  its own version, and `current_status/2` shows a later retirement.

## Dataset and derivation

`lib/elzoo/money/iso4217/2026-09-17.tsv` is a derived factual extract (codes,
numeric codes, minor units, withdrawal text, fund flag; no names). Its header
records the source URLs, publication dates (current list 2026-09-17, historic
list 2026-01-01), download date (2026-11-08) and the SHA-256 of both source
files. No SIX file is committed. To check the extract against a fresh download
(exit 0 equal; 1 hash or row difference or missing hash; 2 unreadable input or
parse failure):

```sh
elixir pieces/domain/money/test/support/iso4217_derive_test_helper.exs \
  list-one.xml list-three.xml \
  --check pieces/domain/money/lib/elzoo/money/iso4217/2026-09-17.tsv
```

Without `--check` (and with `--downloaded YYYY-MM-DD`) it prints a new extract.
A new ISO publication is added as a new dated `.tsv`; the fold keeps older
identities. Run that check on 2026-11-08: exit 0, `EXTRACT MATCHES: 449 rows`.

Dataset disposition (G5, disposed by recorded decision, not verified):

> The committed extract reproduces factual currency data (alphabetic codes, numeric codes, minor units, withdrawal dates) derived from the ISO 4217 lists published by the maintenance agency; no publisher file is redistributed; the source URLs, publication dates, download dates and SHA-256 of the source files are recorded with a re-derivation command that fails on drift. The coordinator took this as a prudence decision on 2026-11-09 and reported it to the owner; the applicable redistribution terms of the publisher were not legally verified and remain a recorded residual.

## Grounding

- **Proof (pinned Cure):** the 13 laws in `cure/elzoo/money.cure`, listed in
  `piece.json`: decision-split closure and mismatch for add, subtract and
  compare; negate keeps the currency; invalid ratios allocate nothing; one part
  per ratio and the total's currency on every part, for every placement.
- **Type/contract check:** pinned Cure checks the result schema and the
  production module with a clean audit; mutated copies are rejected at the
  named law.
- **Test:** `test/elzoo/money_test.exs` and `test/elzoo/money_registry_test.exs`
  (listed scenarios, a bounded exhaustive allocation range, negative controls
  for a dropped residual, fixed-hundredth scaling, a Float path and a deleting
  fold). The repository test `test/elz031_money_persistence_test.exs` runs the
  codec round trip through `integration/sql`; it is not part of this bundle.
- **Upstream contract:** Decimal 3.2.0 struct fields, `Decimal.new/3` and mode
  names; pinned Cure; Elixir 1.20.4 integer arithmetic.
- **Monitored behavior:** none.

## Limits

- The allocation sum, the residual bound and the Elixir boundaries are finite
  tests, not proofs. Pinned Cure keeps native `Int` addition and
  `Std.Builtin.struct_eq` neutral on symbolic values, so arithmetic laws take
  the currency and validity decisions as evidence. A test records that a copy
  which drops the residual still checks.
- The registry is current only as of the held extract. Codes retired before the
  first held version construct no amount (`retired_currency`).
- No exchange rates, locale formatting, journal posting or payment semantics.
  Whether a posting context accepts a retired currency is `domain/journal`'s
  decision.
- Calling `Cure.Elzoo.Money` directly bypasses the membership check.
- The registry is only as faithful as the extract: `mix check` compares the
  registry with the committed extract, not with the publisher's files.

## Provider choice

ex_money 6.3.0 and Decimal 3.2.0 were compared on construction from untrusted
strings, allocation residuals, 0- and 3-exponent currencies and an
`integration/sql` round trip (`docs/work/ELZ-031-sql-probe.md`). Decimal was
selected: ex_money does not distinguish malformed from unknown codes, accepts
sub-minor-unit strings, has no ratio allocation, and persists equal values as
different bytes. ex_money remains a reasonable choice for formatting or
exchange rates, which are out of scope. AshMoney applies only where an Ash
resource owns the amount.
