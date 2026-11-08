# ELZ-031 proposed Contract and scope amendments

Status: proposed by the author for the main coordinator's decision. Not applied.
The live issue #48 body and `tasks/ELZ-031-money-amounts.md` are unchanged.
Source of each finding: [early review](ELZ-031-early-review.md) (BLOCKING 1, BLOCKING 2,
REQUIRED 3, REQUIRED 4, REQUIRED 5, REQUIRED 6). Design that each amendment supports:
[ELZ-031.md](ELZ-031.md) sections 3 to 6.

Rules followed: the reviewer's proposed wording is used where it exists (A1, A2, A3). Each
"after" keeps every existing law; additions only, except where marked. "Before" text is
quoted exactly from the live body, including its line breaks.

## A1 — rejection vocabulary (REQUIRED 3; reviewer wording plus four variants)

Reason for the four extra variants beyond the reviewer's three: the versioned registry in
BLOCKING 1 and REQUIRED 4 needs `no_minor_unit` (ISO itself gives `N.A.`), `forged_currency`
(a currency value that is not a registry member), `unknown_registry_version` (a persisted
value from a registry version this copy does not hold), and `unknown_placement` (an
allocation residual placement outside the declared set). ELZ-031.md section 4 lists which
operation returns each one.

Before (issue item 2):

```text
   for parse. Outputs: amounts, typed rejections (`currency_mismatch{left,
   right}`, `unknown_currency`, `malformed_code`, `retired_currency`,
   `scale_overflow`). State owner: none (pure). Invariants: a currency is a
```

After:

```text
   for parse. Outputs: amounts, typed rejections (`currency_mismatch{left,
   right}`, `unknown_currency`, `malformed_code`, `retired_currency`,
   `scale_overflow`, `malformed_amount`, `invalid_ratios`,
   `unknown_rounding_mode`, `unknown_placement`, `no_minor_unit`,
   `forged_currency`, `unknown_registry_version`). The Contract defines which
   operations return each rejection; it does not silently coerce floats.
   State owner: none (pure). Invariants: a currency is a
```

## A2 — retirement, versioned identity and replay (BLOCKING 1, REQUIRED 4; reviewer wording)

Before (issue item 2):

```text
   the canonical registry value; a code retired by ISO stays decodable as
   `retired` on the parsed value (whether a posting context accepts it is
   domain/journal's decision), retirement never deletes an entry; mixed-currency arithmetic is a typed
```

After:

```text
   the canonical registry value; a code retired by ISO stays decodable as
   `retired` on the parsed value (whether a posting context accepts it is
   domain/journal's decision), retirement never deletes an entry; the
   registry version and any disambiguation required for reused identifiers
   are explicit, and old recorded values retain their original identity and
   exponent across registry updates; a minor-unit exponent is never invented:
   where ISO publishes `N.A.` or the registry never recorded one, the entry
   says so and no amount is constructed for it; mixed-currency arithmetic is a typed
```

## A3 — dataset law: rows, reuse, updates (BLOCKING 1, G5; reviewer wording plus row scope)

Reason for the added row-scope sentence: the pinned list-one file (`Pblshd="2026-09-17"`)
has 280 rows; 3 of them (ANTARCTICA, PALESTINE, STATE OF, SOUTH GEORGIA AND THE SOUTH
SANDWICH ISLANDS) name "No universal currency" and carry no alpha code, numeric code or
minor unit. A row with no code cannot "parse by alpha and numeric code". The addition
states that the law covers every row that carries a currency code, and that the test
asserts the other rows carry no currency field, so the universe is not reduced silently.
The historic list (`Pblshd="2026-01-01"`) carries no minor units; its 169 rows are covered
by alpha and by version-qualified numeric history.

Before (issue item 5):

```text
   limitation recorded. Tests: every row of a pinned, dated ISO dataset parses
   by alpha and numeric code with equal minor units and every registry entry
   appears in that dataset or is marked retired (both directions); `JPY 1000`
```

After:

```text
   limitation recorded. Tests: every row of a pinned, dated ISO dataset parses
   by alpha and numeric code with equal minor units and every registry entry
   appears in that dataset or is marked retired (both directions);
   version-qualified lookup distinguishes identifiers reused between rows, and
   update tests retain previously admitted values and their original exponent;
   "every row" means every row carrying a currency code, and the test asserts
   that each other row carries no code, numeric code or minor unit; every
   historic-list row decodes by alpha to a retired or active entry carrying
   that row; `JPY 1000`
```

## A4 — allocation definition (REQUIRED 5)

Reason: the review asks for one bound rule for ratios, sign, truncation, residual and
placement. The rule is the one ELZ-031.md section 5 tests with exact parts.

Before (issue item 2):

```text
   rejection naming both currencies; an allocation sums exactly to its input
   with the residual placement stated; no Float in any path. Non-goals:
```

After:

```text
   rejection naming both currencies; an allocation sums exactly to its input
   with the residual placement stated (ratios are 1 to 1000 non-negative
   integers with a positive sum; each share is the total times its ratio over
   the ratio sum, truncated toward zero; the residual, total minus the shares,
   has the total's sign and is placed by the caller's choice of first
   positive-ratio part, last positive-ratio part, or one minor unit per
   positive-ratio part in order; the result reports the residual already
   placed, never an extra amount); no Float in any path. Non-goals:
```

## A5 — scope: shared paths this task needs (BLOCKING 2, G2)

The live issue has no file list, so this is an addition to Scope. The worker brief already
authorizes the `domain/money` row of `registry/catalogue.json`, its
`docs/plans/release-plan.json` entry, `LEDGER.md` regeneration and the roadmap views.

Before (Scope, last bullet):

```text
- select laws or record why finite tests stand in.
```

After:

```text
- select laws or record why finite tests stand in;
- shared paths, exactly: `mix.exs` adds the direct dependency
  `{:decimal, "== 3.2.0"}` (already locked transitively at 3.2.0);
  `registry/providers.json` adds the `decimal` provider (hex, 3.2.0,
  Apache-2.0, https://hexdocs.pm/decimal/3.2.0/Decimal.html); the
  repository test `test/elz031_money_persistence_test.exs` runs the
  integration/sql round trip, so the copied `domain/money` bundle stays pure
  and does not depend on integration/sql; the `domain/money` row of
  `registry/catalogue.json`, its `docs/plans/release-plan.json` entry,
  regenerated `LEDGER.md` and roadmap views.
```

## A6 — dataset redistribution (REQUIRED 6, G5) — owner decision, not Contract wording

The Contract requires "an externally sourced, dated dataset committed beside the test".
The SIX Group terms of use (https://www.six-group.com/en/services/legal/terms-and-conditions/terms-of-use.html,
read 2026-11-08) say "The entire content of the SIX website is protected by copyright law"
and that content "may not be reproduced or reused in any way or used for commercial
purposes"; content is provided "exclusively for personal use as well as information
purposes". I found no licence that names the list files. A third-party data package of the
same lists says: "No licence was found for the underlying ISO 4217 lists; their reuse terms
are unclear."

Options for the owner:

1. Commit the two files verbatim under the Piece's `test/support/iso4217/` with source URL,
   publication date, download date and SHA-256, after the owner accepts the redistribution
   risk or obtains permission from the maintenance agency (contact on the SIX page). The
   Contract stays as written. Recommended if the owner accepts it, because the test then
   reads the external file itself.
2. Commit no SIX file. Commit a derived factual extract (codes, numeric codes, minor units,
   withdrawal dates) plus the SHA-256 of the source files; a documented command re-derives
   the extract from a fresh download and fails on drift. This needs a Contract amendment of
   the Scope bullet "an externally sourced, dated dataset committed beside the test", and
   the test then compares against our extract, which is weaker evidence.

Implementation waits for this decision; no SIX file is committed before it.
