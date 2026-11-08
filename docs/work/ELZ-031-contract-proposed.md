# ELZ-031 proposed Contract and scope amendments (revision 3)

Status: A6 approved in advance; A1–A5 proposed for the main coordinator's decision. Nothing applied yet. The live issue #48 body
and `tasks/ELZ-031-money-amounts.md` are unchanged.

Sources: [early review](ELZ-031-early-review.md) (BLOCKING 1–2, REQUIRED 3–6) and
[early re-review](ELZ-031-early-rereview.md) (verdicts per amendment). The re-review verdicts
were A1 ACCEPTABLE, A2–A6 REWORD; this revision uses the re-reviewer's exact replacement text
for A2, A3, A4, A5 and the main coordinator's decided Scope text for A6.

Rules followed: "Before" text is quoted exactly from the live body, including line breaks.
Where the re-reviewer's text is a clause rather than wrapped lines, it is wrapped at the
issue's line width without a change of words.

**Explicit statement for review.** A2 and A3 are not additive. A2 changes the value law
("a currency ... carrying alpha code, numeric code and minor-unit exponent") so that numeric
code and exponent may be explicitly absent. A3 replaces the all-row test universe with the
currency-bearing-row law plus the historic-row law. Neither amendment claims that the
original universal law remains unchanged. A4 keeps the allocation-sum law and adds its rule.

## A1 — rejection vocabulary (re-review: ACCEPTABLE, unchanged from revision 2)

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

## A2 — value law, retirement and versioned identity (re-review: REWORD, reviewer text)

This replaces the existing currency-field clause (a change to the value law) and keeps the
revision 2 retirement and replay addition. The words "a currency is a" stay at the end of
the line that A1 also touches, so this before-text starts on the next line. The revision 2
sentence "a minor-unit exponent is never invented ..." is removed, because the new
currency-field clause states it.

Before (issue item 2):

```text
   value from a closed, versioned registry carrying alpha code, numeric code
   and minor-unit exponent, never a bare string; an amount is an integer
   count of minor units scaled by that exponent (JPY 0, EUR 2, BHD 3), never
   a fixed hundredth; parse distinguishes malformed from unknown and returns
   the canonical registry value; a code retired by ISO stays decodable as
   `retired` on the parsed value (whether a posting context accepts it is
   domain/journal's decision), retirement never deletes an entry; mixed-currency arithmetic is a typed
```

After:

```text
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
```

## A3 — dataset test law (re-review: REWORD, reviewer text)

This replaces the test clause. It is a deliberate, reviewable replacement of the test
universe and the value representation, not a preservation of the original all-row law. No
version-qualified historical numeric parse is claimed: for historic numeric codes the
Contract asks only for an enumeration that never selects (see ELZ-031.md §3.4).

Before (issue item 5):

```text
   limitation recorded. Tests: every row of a pinned, dated ISO dataset parses
   by alpha and numeric code with equal minor units and every registry entry
   appears in that dataset or is marked retired (both directions); `JPY 1000`
```

After:

```text
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
```

## A4 — allocation definition (re-review: REWORD, reviewer text)

Keeps the existing allocation-sum law.

Before (issue item 2):

```text
   rejection naming both currencies; an allocation sums exactly to its input
   with the residual placement stated; no Float in any path. Non-goals:
```

After:

```text
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
```

## A5 — scope: shared paths (re-review: REWORD, reviewer text)

Main coordinator decision (2026-11-08): these shared paths are AUTHORIZED, conditional on
G3 selecting Decimal. They are added only after CLEAR and after G3 selects Decimal; the
worker reports whether `mix.lock` changes. The final independent review must name these
provider-pin and storage boundaries.

Before (Scope, last bullet):

```text
- select laws or record why finite tests stand in.
```

After:

```text
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
```

## A6 — dataset evidence rule (main coordinator decision: option 2, derived extract)

Main coordinator decisions of 2026-11-08: option 2 as a prudence decision (the owner may
override), and this Scope wording APPROVED in advance. It is applied together with A1–A5 in
one commit only after the next re-review verdict on revision 3, by the usual procedure
(exact diff comment on #48, `gh issue edit`, task copy synced, release-plan hash, roadmap
check plain and `--live` green). The option 2 decision is: commit no SIX file; commit a dated,
source-attributed derived factual extract (alpha codes, numeric codes, minor units,
withdrawal dates), the SHA-256 of the two source files with URL, publication date and
download date, and a documented re-derivation command that fails on drift. Replacement text
is the re-reviewer's.

Before (Scope, second bullet):

```text
- define the result schema and the registry version evidence rule (an
  externally sourced, dated dataset committed beside the test);
```

After:

```text
- define the result schema and the registry version evidence rule (an
  externally sourced, dated dataset is used to create a source-attributed,
  dated derived extract committed beside the test; source URLs, source
  hashes and a reproducible derivation and comparison method are recorded);
```

The Acceptance line "Dataset round-trip test in both directions passes against a dated
registry file." needs no change: the dated registry file is the committed extract.

### Rights note (not Contract wording)

Re-review option texts, recorded for the owner:

1. Commit the verbatim files only after permission or an applicable license authorizing the
   intended copying, redistribution and uses has been established; record the
   permission/license, provenance and hashes separately from Elzoo-owned Apache-2.0.
2. Subject to verifying the applicable terms for creating and redistributing the extract,
   commit the reviewed derived extract and source hashes; amend the Scope to say a dated,
   source-attributed derived extract is committed beside the test rather than an externally
   sourced dataset file. Document independent derivation and its evidence limitation.

Facts on record: the SIX [terms of use](https://www.six-group.com/en/services/legal/terms-and-conditions/terms-of-use.html)
(read 2026-11-08) say "The entire content of the SIX website is protected by copyright law",
that "presentations, brochures, flyers, graphics, texts, designs, charts, etc., may not be
reproduced or reused in any way or used for commercial purposes", and that information is
provided "exclusively for personal use as well as information purposes". They do not name
the list files or a derived factual extract. No permission for the list files was found. No
legal conclusion is made here. The verification of terms for the extract, which option 2
requires, is still open and belongs to the owner or the main coordinator. Implementation
commits no extract before that is recorded.

Evidence limitation of option 2: `mix check` compares the registry with the committed
extract, not with the SIX files. Fidelity of the extract to the SIX files rests on the
re-derivation command, run on a fresh download, with its hashes and output recorded in
`docs/work/ELZ-031.md`.
