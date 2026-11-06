# Elzoo study — money arithmetic and currency (money_pattern, dime, pricing)

Reviewed 2026-11-06 against elzoo `bf16422dbc741de5c3ff3d86f3af9b14d7eb19ef`. Read-only source study in the
shape of the Raxol section of docs/research/orchestration-references.md. Nothing was executed, vendored or
added as a dependency. Each package was pinned from the Hex release tarball and its repository; the three Hex
API checksums are `ec69d0ec…283222` (money_pattern 1.0.0), `99bdb609…80ed0107` (dime 1.2.0) and
`777007bb…43ab32` (pricing 0.6.9). Compared against `domain/money`, `domain/journal`, `domain/pricing`
(all deferred in registry/catalogue.json), coverage cases C3/C4/C9 and the ex_money/Decimal candidates named
in docs/capability-coverage.md.

## Summary table

| Package | Pinned SHA | License | Last commit | Verdict | One line |
| --- | --- | --- | --- | --- | --- |
| money_pattern 1.0.0 (Gleam) | [4eb85e5](https://github.com/Kelvin-Jesus/Money/tree/4eb85e5f4ef4f727058676e3251b6d9ac3a7894e) = tag v1.0.0; `.gleam` source byte-identical to the tarball, but the repo gleam.toml still says `name = "money"` | **Conflict**: Hex and gleam.toml declare Apache-2.0, the shipped LICENSE file is MIT (Kelvin Jesus 2026) | 2026-02-18 (6 commits, one author) | skip | 49 lines: opaque `(Int cents, String currency)`, `add` with a mismatch error, float-based `to_string`; no currency validation, hard-wired 2 minor units; nothing `domain/money` does not already state |
| dime 1.2.0 (Gleam) | [9c3e35e](https://github.com/horvathandris/dime/tree/9c3e35e734fda715bef4b645ac99f8ee17bf0565) = tag v1.2.0; source matches tarball | Apache-2.0 (full text shipped) | tag 2025-10-28; HEAD [7c6b0b7](https://github.com/horvathandris/dime/commit/7c6b0b70fd36f580b2543acacbd3af438ec519e9) 2026-06-30 (27 commits, one human author + dependabot) | distill | ISO-4217 registry as an opaque closed type with alpha/numeric parse and minor-unit exponent, tested against the standard maintainer's dataset; 1.2.0 still ships retired HRK, the fix is unreleased |
| pricing 0.6.9 (Elixir) | [4989d40](https://github.com/arthurcolle/pricing/tree/4989d40c3180e1745d6ba8933370c3c77e20845f) = HEAD, no tag; `lib/` identical to tarball, tarball mix.exs differs by one `files` entry | Hex says `"Colle"` (non-SPDX); LICENSE.md is MIT text retitled "Collé Group License" | 2023-01-31 (47 commits) | skip | Black-Scholes option pricing by shelling out to a C/GSL binary; unrelated to usage-to-price templates; tests do not compile; declared applications are not in deps |

## money_pattern 1.0.0

### Observations (2026-11-06, at 4eb85e5)

| Observed source | What it exposes | Bearing on Elzoo |
| --- | --- | --- |
| [money.gleam#L7-L9](https://github.com/Kelvin-Jesus/Money/blob/4eb85e5f4ef4f727058676e3251b6d9ac3a7894e/src/money/money.gleam#L7-L9) | `pub opaque type Money { Money(amount_in_cents: Int, currency: String) }` | Integer minor units is the right direction for `domain/money`, but the currency is a free `String` and the unit is fixed to cents |
| [money.gleam#L19-L21](https://github.com/Kelvin-Jesus/Money/blob/4eb85e5f4ef4f727058676e3251b6d9ac3a7894e/src/money/money.gleam#L19-L21) | `new(amount, currency)` constructs without any check | Contradicts the Hex description "strict currency validation"; `new(1, "")` and `new(1, "usd")` are distinct valid values |
| [money.gleam#L13-L16, #L25-L34](https://github.com/Kelvin-Jesus/Money/blob/4eb85e5f4ef4f727058676e3251b6d9ac3a7894e/src/money/money.gleam#L25-L34) | `add` returns `Error(CurrencyMismatch(expected, received))` on unequal strings | Fail-closed addition carrying both currencies; this is the only mechanism, and it is already a C3 design test ("reject currency mismatch") |
| [money.gleam#L42-L49](https://github.com/Kelvin-Jesus/Money/blob/4eb85e5f4ef4f727058676e3251b6d9ac3a7894e/src/money/money.gleam#L42-L49) | `to_string` divides by `100.0` as a Float and calls `float.to_precision(_, 2)` | Goes through binary floating point and assumes two minor units for every currency (JPY has 0, BHD 3); a negative example for C4 "rounding/allocation residuals are explicit" |
| [money_test.gleam#L9-L33](https://github.com/Kelvin-Jesus/Money/blob/4eb85e5f4ef4f727058676e3251b6d9ac3a7894e/test/money_test.gleam#L9-L33) | Three finite cases: format, add, mismatch | No subtraction, negation, allocation, comparison or multiplication exists |
| Repo vs release | Repo gleam.toml `name = "money"`; tarball `name = "money_pattern"`; README usage block is the generator placeholder | The tag is not byte-identical to the published package metadata; Hex shows 172 total downloads |

### Overlap and verdict

`domain/money` already asks for "explicit units, currency mismatch and allocation residual policy"
(registry/catalogue.json). money_pattern covers only the mismatch error and omits units and allocation.
ex_money (docs/capability-coverage.md candidate table) covers all three plus rounding, so upstream reuse of
money_pattern fills no gap. It would also add a Gleam runtime dependency, which
docs/operational-contracts.md says the contracts do not imply.

**Verdict: skip** (2026-11-06): single-author six-commit package whose shipped LICENSE (MIT) contradicts its
declared license (Apache-2.0), whose only arithmetic is addition, and whose formatting path contradicts the
unit and residual requirements of `domain/money`. The license conflict alone blocks adoption under
docs/development/08-upstream-and-forks.md until the author resolves it. Its L42-L49 is kept only as the
negative example in the dangerous-failure list below.

## dime 1.2.0

### Observations (2026-11-06, at 9c3e35e)

| Observed source | What it exposes | Bearing on Elzoo |
| --- | --- | --- |
| [dime.gleam#L492-L505](https://github.com/horvathandris/dime/blob/9c3e35e734fda715bef4b645ac99f8ee17bf0565/src/dime.gleam#L492-L505) and the constants at L4-L328 | `pub opaque type Currency(alpha, numeric, display name, symbol, minor_units)`; 159 public constants such as [`jpy` … `0`](https://github.com/horvathandris/dime/blob/9c3e35e734fda715bef4b645ac99f8ee17bf0565/src/dime.gleam#L140) and [`bhd` … `3`](https://github.com/horvathandris/dime/blob/9c3e35e734fda715bef4b645ac99f8ee17bf0565/src/dime.gleam#L36) | Currency identity is a closed enumerated registry value, not a string; opacity means a consumer cannot mint an unknown currency |
| [dime.gleam#L550-L553](https://github.com/horvathandris/dime/blob/9c3e35e734fda715bef4b645ac99f8ee17bf0565/src/dime.gleam#L544-L553) | `minor_units` documented as the exponent: 1, 2, 3 mean 10:1, 100:1, 1000:1 | The scale an integer-minor-unit amount must carry; what money_pattern hard-codes |
| [dime.gleam#L510-L513](https://github.com/horvathandris/dime/blob/9c3e35e734fda715bef4b645ac99f8ee17bf0565/src/dime.gleam#L510-L513), [#L563-L573](https://github.com/horvathandris/dime/blob/9c3e35e734fda715bef4b645ac99f8ee17bf0565/src/dime.gleam#L563-L573), [#L739-L744](https://github.com/horvathandris/dime/blob/9c3e35e734fda715bef4b645ac99f8ee17bf0565/src/dime.gleam#L739-L744), [#L914-L919](https://github.com/horvathandris/dime/blob/9c3e35e734fda715bef4b645ac99f8ee17bf0565/src/dime.gleam#L914-L919) | `from_alpha_code` / `from_numeric_code`: 3-grapheme length check → `InvalidFormat`, else exhaustive match → `UnrecognizedCode`; alpha parse upper-cases its input | Two distinct rejections for malformed versus unknown; case-normalising parse with canonical upper-case output |
| [iso_4217_test.gleam#L36-L46](https://github.com/horvathandris/dime/blob/9c3e35e734fda715bef4b645ac99f8ee17bf0565/test/iso_4217_test.gleam#L36-L46) with [extract_data.sh#L9, #L36-L40](https://github.com/horvathandris/dime/blob/9c3e35e734fda715bef4b645ac99f8ee17bf0565/scripts/extract_data.sh#L9-L41) | Test dataset is pulled from the standard maintainer's `list-one.xml` (SIX), dropping funds and `N.A.` minor units; the test asserts every dataset row parses by alpha and numeric code with matching minor units | Compliance evidence is a dated external dataset, not hand-typed expectations |
| [dime_test.gleam#L27-L47](https://github.com/horvathandris/dime/blob/9c3e35e734fda715bef4b645ac99f8ee17bf0565/test/dime_test.gleam#L27-L47) | A `glance` AST pass over `src/dime.gleam` checks every public `Currency` constant is named by its alpha code and present in `known_currencies` | Static integrity check over the registry source itself |
| Dataset gap at the tag | At 9c3e35e the dataset has 158 unique alpha codes while the library defines 159: [`hrk`](https://github.com/horvathandris/dime/blob/9c3e35e734fda715bef4b645ac99f8ee17bf0565/src/dime.gleam#L118) (Croatian kuna, retired 2023) is still released; [`bgn`](https://github.com/horvathandris/dime/blob/9c3e35e734fda715bef4b645ac99f8ee17bf0565/src/dime.gleam#L34) was retired by ISO after the release. Commit [078c333](https://github.com/horvathandris/dime/commit/078c333) (2026-03-11) removes both and adds the reverse assertion ("all known currencies are in the ISO list"); no release carries it as of 2026-11-06 | The 1.2.0 test suite is one-directional, so a retired code survived; removing a retired code outright would break decoding of historical journal lines |
| gleam.toml at the tag; [matrix-test.sh](https://github.com/horvathandris/dime/blob/9c3e35e734fda715bef4b645ac99f8ee17bf0565/scripts/matrix-test.sh) | Only `gleam_stdlib >= 0.34.0 and < 2.0.0` at runtime; CI runs erl, node, deno and bun targets | Light dependency; no amount type, arithmetic, rounding, allocation or exchange is provided |

### Overlap check

- `domain/money` reason text: "explicit units, currency mismatch and allocation residual policy". dime supplies
  the unit exponent and the identity half; it has no amount type, so it cannot be the money Piece.
- ex_money carries its own currency metadata (via ex_cldr); if ex_money is the provider exercised for
  `domain/money`, a second registry is a duplicate (AGENTS.md: "do not duplicate that contract behind a second
  generic implementation", `domain/value-types` reason).
- Elzoo backend consumers are Cure/Elixir; docs/operational-contracts.md says "No UI language or Gleam
  dependency is implied by these contracts", and docs/research/gleam-libraries.md refuses to impose a Gleam
  toolchain on backend consumers. dime would only be a candidate for a Gleam-target consumer such as the
  spikes/gleam_ui model, where none handles money today.
- Upstream reuse as-is is licence-clean (Apache-2.0) but the released artefact is stale on retirements.

**Verdict: distill.** No handle is proposed for adoption. The registry shape and the dataset-driven,
bi-directional compliance test become Contract text and acceptance for `domain/money`, whichever provider is
exercised.

### Proposals (Elzoo-authored; not package behaviour)

Contract sentences for `domain/money` (C3, C4, C9):

1. A currency is a value from a closed, versioned registry carrying ISO-4217 alpha code, numeric code and
   minor-unit exponent; it is never a bare string, and an amount is an integer count of minor units scaled by
   that exponent (JPY 0, EUR 2, BHD 3), never a fixed hundredth. (C4; dime L492-L505, L550-L553.)
2. Parsing a code from untrusted input (webhook, model output, CSV) distinguishes malformed from unknown and
   returns the canonical upper-case registry value; an `Adapter` never constructs a currency another way. (C3;
   dime L510-L513, L563-L573.)
3. The registry version (dataset date) is part of the Contract. A code retired by ISO stays decodable as
   `retired` for historical postings and is refused for new postings; retirement never deletes a registry
   entry. (C4 "corrections preserve history"; the negative example is dime 078c333 deleting HRK/BGN.)
4. Mixed-currency arithmetic is a typed rejection naming both currencies; no implicit conversion. (C3; already
   in the coverage text, money_pattern L25-L34 is a minimal instance.)

Design tests / dangerous failures to attach to the `domain/money` task when it is published:

- Every row of the pinned ISO dataset parses by alpha and by numeric code with equal minor units, **and**
  every registry entry appears in that dataset or is explicitly marked retired (both directions; the 1.2.0
  one-directional suite let HRK through).
- `JPY 1000` formatted and re-parsed round-trips without a decimal point; `BHD 1.234` keeps three places; an
  implementation that divides by 100.0 fails this test (money_pattern L42-L49).
- Allocating `EUR 1.00` three ways yields integer minor units summing exactly to 100 with the residual
  placement stated; no Float appears in the path (C4 residual test).
- A C9 charge computed in one currency cannot be posted into a journal account denominated in another
  (`domain/journal` same-currency postings, C4 flow).

Evidence rule: registry compliance is grounded by a test over an externally sourced, dated dataset committed
beside the test (dime's extract_data.sh pattern), not by hand-written expectations; the dataset date is
recorded in the Piece's evidence.

#### Draft admission record — `domain/money` (existing deferred handle; no new Piece ID)

1. **Responsibility and caller.** Own exact currency amounts: construction from minor units, same-currency
   add/subtract/compare, allocation with explicit residual placement, rounding at a declared scale, and
   currency-registry lookup. Callers: C4 internal transfer (balanced postings) and C3 refund validation;
   C9 price-template output challenges generality with 0- and 3-exponent currencies and sub-minor-unit rates.
2. **Interface and invariant.** Inputs: `{currency, minor_units: Int}` values, registry version, rounding
   mode, allocation ratios. Outputs: amounts, typed rejections (`currency_mismatch{left,right}`,
   `unknown_currency`, `malformed_code`, `retired_currency`, `scale_overflow`). State owner: none (pure).
   Invariants: sum of an allocation equals the input exactly; add/subtract are closed under one currency;
   no Float in any path. Non-goals: exchange rates, formatting for locales, journal posting, payment provider
   semantics, token or usage units (those are `workflow/budget`/`domain/metering`).
3. **Reuse check.** ex_money 6.3.0 (and AshMoney where the consumer already chose Ash, docs/dependencies.md)
   are the candidates; Decimal 3.2.0 underlies both. dime's registry is a Gleam-only duplicate of ex_cldr
   currency data. Elzoo's remaining policy is the Contract above (retired-code handling, residual placement,
   rejection vocabulary) and the Cure-typed result schema at the Port; a wrapper alone earns no slot.
4. **Split test.** Currency registry and amount arithmetic stay behind one interface: an amount without its
   registry exponent cannot be rounded or allocated correctly. Formatting/locale and exchange are separable
   provider choices and stay out.
5. **Failure and evidence.** Dangerous paths: fixed-hundredth scaling for a 0/3-exponent currency; silent
   float conversion; a retired code deleted from the registry breaking historical replay; allocation residual
   dropped. Proofs: selected Cure laws over the pure minor-unit arithmetic (closure, allocation sum) if the
   pin's Int reasoning permits; otherwise finite tests and the memory note that symbolic Int equality does not
   reduce under Cure a004c335. Tests: the dataset round-trip and residual cases above. Upstream: ex_money
   rounding/allocation documented behaviour, named not proved.
6. **Composition record.** Consumed by `domain/journal` (same-currency postings), `domain/pricing` (template
   output currency and scale), `assembly/ledger-checkout`. Provider pins recorded in the provider registry on
   adoption; data classification: financial amounts, not secrets; no delivery or durability claim.

A future task must exercise the exact ex_money/Decimal boundary (construction from untrusted strings,
allocation residuals, 0/3-exponent currencies, persistence round-trip through `integration/sql`) before
`domain/money` leaves deferred; nothing here says it is ready.

## pricing 0.6.9

### Observations (2026-11-06, at 4989d40)

| Observed source | What it exposes | Bearing on Elzoo |
| --- | --- | --- |
| [pricing.ex#L11-L15](https://github.com/arthurcolle/pricing/blob/4989d40c3180e1745d6ba8933370c3c77e20845f/lib/pricing.ex#L11-L15), [#L21-L43](https://github.com/arthurcolle/pricing/blob/4989d40c3180e1745d6ba8933370c3c77e20845f/lib/pricing.ex#L21-L43) | Formats six Floats to strings, `Porcelain.exec("./pricing.x", …)` and `Poison.decode!`s the stdout into `%{call:, put:}` | Out-of-process C binary with a relative path, float in/float out; no currency, scale, rounding or version |
| [pricing.c#L33-L38](https://github.com/arthurcolle/pricing/blob/4989d40c3180e1745d6ba8933370c3c77e20845f/pricing.c#L33-L38) | Black-Scholes call/put with GSL `gsl_cdf_ugaussian_P` | Derivatives valuation, not usage-to-price templates; `domain/pricing` is about "versioned rate/template … tier and minimum-charge rules" (C9) |
| [option.ex#L10-L11](https://github.com/arthurcolle/pricing/blob/4989d40c3180e1745d6ba8933370c3c77e20845f/lib/pricing/instruments/option.ex#L10-L11), bond.ex, swap.ex | `EuropeanOption.price/2` returns `0`; bond is commented out; swap returns `Time.now()` | Stubs |
| [pricing_test.exs#L18](https://github.com/arthurcolle/pricing/blob/4989d40c3180e1745d6ba8933370c3c77e20845f/test/pricing_test.exs#L18), [#L26](https://github.com/arthurcolle/pricing/blob/4989d40c3180e1745d6ba8933370c3c77e20845f/test/pricing_test.exs#L26) | Missing comma in a keyword list (syntax error) and a call to the non-existent `Pricing.option/1` | The test file cannot compile; no executable evidence |
| [mix.exs#L8, #L20, #L28, #L35](https://github.com/arthurcolle/pricing/blob/4989d40c3180e1745d6ba8933370c3c77e20845f/mix.exs#L8-L38) | `elixir: "~> 1.14.0"`; `applications:` lists `:tzdata` and `:yahoo_finance_elixir` that are not in `deps`; `timex ~> 1.0.0`, `poison ~> 3.1.0`, `plug`, `porcelain`; `licenses: ["Colle"]` | Incompatible with the Elzoo pin (Elixir 1.20.4); the OTP application cannot start as declared; license identifier is not SPDX |
| Repository tree | Committed `pricing.exe`, `pricing.o`, `pricing.x`, `Elixir.Pricing.beam`, `_build/`, `deps/` | Binaries without provenance in the source tree |

### Overlap and verdict

`domain/pricing` (deferred) requires "currency/precision/rounding and immutable rate/template versions" for
C9. pricing provides none of these and touches no Elzoo capability; `domain/journal` and `domain/money` are
likewise untouched.

**Verdict: skip** (2026-11-06): abandoned since 2023-01-31, a Black-Scholes shell-out rather than usage pricing,
non-compiling tests, mis-declared OTP applications, and a non-SPDX license name. No idea is distilled; its
"format Float with `decimals:` then parse JSON" boundary is the kind of path the C9 design test "currency/units
cannot mix" and the `domain/money` "no Float" sentence exclude.

## Skipped mechanisms and why

- money_pattern `to_string` (L42-L49): presentation through Float; carried only as a negative example.
- dime `symbol` and `display_name` (L531-L542): presentation/locale data; Elzoo leaves formatting to the
  product and ex_cldr already owns it for Elixir consumers.
- dime multi-target (erl/node/deno/bun) CI: packaging property of a Gleam library; no backend Piece needs it.
- dime at HEAD (7c6b0b7): unreleased; observed only to date the HRK/BGN retirement handling.
- pricing in its entirety: no mechanism bears on C3/C4/C9.
- Exchange rates, locale formatting and precious-metal codes (dime's extractor drops `N.A.` minor units):
  outside `domain/money`'s stated scope.

## Open questions

1. Provider choice for `domain/money`: ex_money directly or AshMoney behind the ADR-0005 foundation? This
   study pinned neither; the admission record names both as the boundary a future task must exercise.
2. Retired-currency policy: does the owner want `retired` as a registry state (proposed here) or a
   product-level mapping? It affects `domain/journal` replay of historical postings.
3. Is any Gleam-target consumer (spikes/gleam_ui) expected to handle money? Only then does dime become an
   adoption candidate, for that target alone, and still without an amount type.
4. Whether to raise money_pattern's LICENSE/metadata mismatch with its author is outside this study's
   authorization (external messages need session approval per docs/development/08-upstream-and-forks.md).

## Limits

Nothing was compiled or run (no Gleam toolchain, no Elixir build of pricing); maintenance signals are from
`git log` and the Hex API on 2026-11-06; download counts are Hex-reported. ex_money/Decimal were not pinned
or read here, so statements about their coverage repeat docs/capability-coverage.md and the ex_money
documentation, not inspected source. Line links point at the pinned revisions and were checked with
`grep -n`/`cat -n` on the clones.
