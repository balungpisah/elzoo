# domain/pricing

Exact charges from the usage totals of one tenant and period under one
immutable rate-card version. `Elzoo.Pricing` is three pure functions: no I/O,
clock, storage, journal post, exchange rate, invoice or Float. A charge is a
`domain/money` amount, rounded once per line with the card's declared mode,
and says when it is incomplete. Unknown usage is never priced as zero.

Provider cost and customer price are separate card kinds (`:cost` and
`:price`) that never combine: `difference/3` refuses two charges of different
cards.

## Card

A card is exactly `%{card_id, version, content_hash, kind, currency, rounding,
lines}`:

- `kind` is `:cost` or `:price`;
- `currency` is an `%Elzoo.Money.Currency{}` member of the registry with an
  integer minor unit (any `domain/money` registry currency; one per card);
- `rounding` is one of `Elzoo.Money.rounding_modes/0`, applied once per priced
  line per period;
- `lines` is a proper list of 1..1024 lines sorted by `{provider_id, model_id,
  unit}` in Erlang term order and unique on it.

A line is exactly `%{provider_id, model_id, unit, rate, per, minimum}`:

- `rate` is an owner-authored decimal string `(0|[1-9][0-9]*)(\.[0-9]+)?` with
  at most 18 significant digits (leading zeros trimmed, trailing zeros
  counted, as `domain/money` counts them) and at most 18 fractional digits: a
  price per `per` units in major units of the card's currency, for example
  `"3"` per `1_000_000` tokens. Zero is allowed; no sign, exponent or Float.
- `per` is one of 1, 10, 100, …, 10^9.
- `minimum` is `nil` or a non-negative decimal string that
  `Elzoo.Money.from_decimal_string/3` accepts for the card's currency (no
  fraction finer than its minor unit).

`unit` is one of `Elzoo.AiModel.Usage.units/0` or `{:cache_write_tokens, ttl}`
with `ttl` in `Elzoo.AiModel.Usage.ttls/0`, the unit set of `domain/metering`.
Texts (`card_id`, `provider_id`, `model_id`, `tenant`, `period`) are 1..128
bytes of valid UTF-8 without a C0 or C1 control character, compared by exact
bytes. `version` is an integer `1..2^31-1`.

**Lines stand alone.** A line's charge depends only on its own fields and its
own rows, never on another line. No volume tiers in this version; an optional
`tiers` field can be added to a line in place.

## Content hash

`content_hash(card)` is `{:ok, hash}`, the 32-byte SHA-256 of this encoding of
the card (a `content_hash` key is ignored), or `{:error, :card}`:

    text(b)     = <<byte_size(b)::32, b::binary>>
    int(n)      = <<n::64>>                      (unsigned, big-endian)
    list(xs)    = <<length(xs)::32>> <> xs
    field(k, v) = text(k) <> v

    card     = text("elzoo/pricing/card")
               <> field("card_id", text(card_id))
               <> field("version", int(version))
               <> field("kind", text(kind name))
               <> field("currency", text(field("alpha", text(alpha))
                                         <> field("numeric", int(numeric))
                                         <> field("minor_unit", int(minor_unit))))
               <> field("rounding", text(rounding name))
               <> field("lines", list(map(lines, line)))
    line     = text(field("provider_id", text(provider_id))
                    <> field("model_id", text(model_id))
                    <> field("unit", unit)
                    <> field("rate", text(rate))
                    <> field("per", int(per))
                    <> field("minimum", text(minimum)))   (only when minimum is set)
    unit     = list([text(name)])  or  list([text("cache_write_tokens"), text(ttl)])

Lines are encoded in their required order; `rate` and `minimum` are encoded as
their given strings (`"3"` and `"3.0"` are different cards). A field that a
later in-place version adds as optional (for example a line's `tiers`) is
encoded only when present, so existing hashes stay equal. The host computes
the hash when it stores a card version; `price/3` refuses a card whose stored
hash differs.

## Functions

| Call | Result |
| --- | --- |
| `price(card, usage, opts \\ [])` | `{:ok, charge}` or `{:error, reason}` |
| `difference(earlier, later, opts \\ [])` | `{:ok, amount}` (`later.total − earlier.total`, may be zero or negative) or `{:error, reason}` |
| `content_hash(card)` | `{:ok, hash}` or `{:error, :card}` |

`opts` is `[]` (the compiled `Elzoo.Money.Registry.default/0`) or
`[registry: registry]`, where `registry` is the compiled default, a raw
`Elzoo.Money.Registry` value or a checked value from
`Elzoo.Money.Registry.check/1`. A raw registry is checked once per call with
`check/1`, and that checked value is passed to every `Elzoo.Money` call the
call makes, so it is walked once per call, not once per line; a checked value
is passed on as it is. A host that prices many cards under one custom
registry can check it once itself and pass the checked value. That checked
value is accepted only while the `Elzoo.Money.Registry` build that made it is
loaded, so the host checks again after a code upgrade (see the `domain/money`
limits); a checked value that `check/1` refuses, for example after a purge of
that build, is `:invalid`. A registry that `check/1` refuses, a forged
checked value included, and any other `opts` are `:invalid`.

### Usage

`usage` is exactly `%{tenant, period, rows}`, `rows` a proper list of 0..4096
`%{provider_id, model_id, unit, source, known, unknown_count, count}`: the
rows of `domain/metering` `totals/3` with `provider_id` and `model_id` added,
unique on `{provider_id, model_id, unit, source}`. A usage prices only when
each row's key `{provider_id, model_id, unit}` has a card line, so at most
3 × the card's lines rows (one per source), 3072 with the 1024-line ceiling;
a larger usage is `:unpriced_unit`. `source` is `:estimated`,
`:provider_reported` or `:unknown`; `count` is an integer ≥ 1;
`unknown_count` an integer `0..count`; `known` an integer `0..10^38-1`, and 0
when `unknown_count == count`.

`totals/3` of `domain/metering` groups by unit and source only.
`Elzoo.Metering.model_totals/3` of `domain/metering` returns `{:ok, rows}`
with these per-provider and per-model rows for a period of at most 1,000
groups (`max_rows` 1..1000; more groups than `max_rows` is
`{:error, :read_limit}`); the host builds the rows of a larger period, up to
the 4096 rows this Piece takes, of which at most 3 × the card's lines (3072
with the 1024-line ceiling) can be priced. This Piece does not depend on
metering code.

### Charge

`charge` is `%{tenant, period, card, lines, total, incomplete,
unknown_count}`:

- `card`: `%{card_id, version, content_hash, kind}`, the identity the host
  stores with the charge;
- `lines`: one entry for each card line that has at least one row, in the
  card's order: `%{provider_id, model_id, unit, quantity, unknown_count,
  count, sources, charge}`, where `quantity` is the sum of `known` over the
  line's rows of every source, `unknown_count` and `count` their sums,
  `sources` the sorted sources of those rows and `charge` an
  `%Elzoo.Money.Amount{}`;
- `total`: the exact sum of the line charges, a zero amount in the card's
  currency when there is none;
- `unknown_count`: the sum over lines; `incomplete` is `true` exactly when it
  is above zero.

## Rules

**Line charge.** For each card line with at least one row, the exact value
`quantity × rate ÷ per` is built in integer arithmetic with trailing zeros
removed from its coefficient (a zero value is coefficient 0, exponent 0). It
is passed once, as a `%Decimal{}`, to `Elzoo.Money.from_decimal/4` with the
card's currency and `rounding`, so the one rounding is `domain/money`'s integer
arithmetic and no process Decimal context applies. The exponent is at least
−27; a coefficient of more than 38 digits or an exponent above 38 is
`:amount_range` before the call, and a result outside the `domain/money` range
is `:amount_range` too, never truncated. Then, when `minimum` is set and the
rounded charge is below it, the charge is the minimum.

A minimum applies only to a line with at least one row in the period, also
when every row's `known` is 0 or every observation is unknown. A card line
with no row is not charged and is absent from `lines`. Every source's known
amount is charged: `source` is provenance, and a corrected estimate keeps its
source in `domain/metering`.

**Unknown.** An unknown observation adds nothing to `quantity` and its count
to `unknown_count`, and the charge is `incomplete`. The charge of an
incomplete line is the charge of its known amounts only, and says so.

**Checks.** `price/3` checks, in this order, and stops at the first failure:
`opts` (`:invalid`); the card's shape and bounds, currency membership and each
minimum (`:card`); its `content_hash` against `content_hash/1`
(`:content_hash`); `usage` (`:usage`); that every row has a card line with its
`{provider_id, model_id, unit}` (`:unpriced_unit`, also for a row whose
observations are all unknown); then the line charges and the total
(`:amount_range`).

`difference/3` checks `opts` (`:invalid`), then both charges' shape and
membership, including a non-negative `total` below 10^38 (`:charge`), then
that both have the same `tenant`, `period`, `card` and total currency
identity `{alpha, numeric, minor_unit}` (`:card_mismatch`). The amount it
returns carries the later charge's currency value, including its registry
version.

Errors are `{:error, reason}` with a fixed atom that never echoes an ID or
amount: `:invalid`, `:card`, `:content_hash`, `:usage`, `:unpriced_unit`,
`:amount_range`, `:charge`, `:card_mismatch`.

**Immutability.** A charge depends only on the card version and rows passed.
The host stores each card version unchanged, and the card identity with each
charge; an earlier charge is re-priced only under its own card version, never
by a newer card.

## Posting to `domain/journal`

The Piece posts nothing. A host turns a charge into one `domain/journal`
`post/3` operation of two postings, `total` and its negation, in the card's
currency, between the account that pays (a receivable for postpaid, a
no-negative wallet for prepaid) and a revenue account for a `:price` card or
a cost account for a `:cost` card. The host chooses the accounts and the sign
convention and derives the `operation_id` from its own charge record, so a
retry is a journal duplicate. A zero total posts nothing (the journal refuses
a zero posting).

A correction re-prices the period under the card version of the original
charge; `difference/3` gives the amount. When it is nonzero the host posts it
as a new operation whose `operation_id` and `reason` it derives from the
correction (`post/3` has no link field; only `reverse/3` links), not as a
`reverse/3`, which negates a whole operation. An incomplete charge is the
host's to hold, or to post with its difference later.

## Growth

The kind, error and source sets, and the maps returned, may gain members and
keys in a later in-place version (for example a line's `tiers`, a per-line
charge of an unused line, or another usage source). A caller matches on the
members and keys it uses.

## Example

`examples/pricing.exs` prices an input line and an output line raised to its
minimum with one unknown output observation (incomplete), re-prices the period
after the unknown observation becomes known under the same card version, and
takes the difference the host would post.

## Grounding

- Proof: Cure owns the minimum and completeness decisions over integer minor
  units and counts. Selected laws, in decision-split form (pinned Cure keeps
  native `Int` comparison neutral on symbolic values, so a law takes the
  decision `rounded < minimum` as an argument): `minimum_floor` (a line with a
  row and a minimum whose rounded charge is below it is charged the minimum),
  `minimum_keeps_larger` (a rounded charge not below the minimum is
  unchanged), so a charged line with a minimum is at least the minimum given
  that Cure's `is_below` decision is `rounded < minimum`, which rests on the
  pinned Cure `Int` comparison and the production-decision tests, not a law;
  `no_minimum_keeps`, `no_row_absent`, `incomplete_when_unknown` (for all
  earlier and later lines, one line whose unknown count is not zero makes the
  charge incomplete; induction on the earlier lines) and
  `complete_without_lines`.
- Type: pinned Cure checks types and totality; the audit reports no axiom,
  hole, unresolved, unaudited, opaque or unproved-total definition.
- Test: `mix test pieces/domain/pricing/test` runs the acceptance scenarios
  with hand-written expected amounts: EUR, JPY and BHD cards, 18-digit rates,
  every rounding mode at, above and below half a minor unit and on a whole
  value, once-per-line rounding, minimums, unknown and incomplete lines,
  card versions and identity, the fixed encoding bytes, corrections, mixed
  units, the listed validation bounds and the error order, and a checked
  registry pricing and differencing like its raw registry. Arithmetic and
  rounding are `domain/money`'s; that Elixir passes the exact value is
  test-grounded. Negative controls: pricing unknown as zero and reporting the
  charge complete fails the unknown cases; rounding each row before summing a
  line fails the once-per-line case; letting a below-minimum charge keep its
  rounded value fails `minimum_floor` at compile; letting an unknown flag pass
  fails `incomplete_when_unknown` at compile; taking any checked struct
  unchecked fails the options case; pricing a checked value under the default
  fails the checked-registry case. Finite scenarios, not universal proofs.
- Upstream: pinned Cure; `domain/money` (`from_decimal/4`, `add/3`,
  `subtract/3`, registry membership); Decimal 3.2.0 `Decimal.new/3` struct
  fields; pinned Elixir/OTP term order, `String.valid?/1` and `:crypto`
  SHA-256.

## Needs and limits

Needs: a host that stores each card version unchanged with its content hash,
stores the card identity with each charge, supplies the complete
per-provider and per-model rows of the period, read with `model_totals/3` of
`domain/metering` or built, and chooses the card.

Limits: no tiers, exchange rate, tax, discount, invoice, payment or journal
post. One currency per card; a tenant billed in two currencies uses two
cards, and a tenant with two plans whose cards cover different usage prices
each subset with its own card. Rates are owner-authored; `llm_db` prices are
a reference only. The charge of an incomplete line covers its known amounts
only. An exact line value must fit 38 significant digits (with an
18-fractional-digit rate per unit, a quantity below about 10^20); a larger one
is `:amount_range`, never truncated. The per-provider and per-model rows come
from `Elzoo.Metering.model_totals/3` of `domain/metering` for a period of at
most 1,000 groups (`max_rows` 1..1000; more groups than `max_rows` is
`{:error, :read_limit}`); the host builds the rows of a larger period, up to
4096 rows, and a usage prices only when each row's key has a card line, so at
most 3 × the card's lines rows (3072 with the 1024-line ceiling). The Piece
does not check that the rows are a complete period; the host owns the period
and the card choice. Telemetry, Config and Control are not applicable.

Registry cost per call, `price/3` of one unchanged 1024-line card and usage
with a row and a minimum on every line, accepted by all three forms with equal
charges, three runs in one local session on the pinned toolchain (ELZ-321;
mean of 30 calls after 5 warm-up; local timings, not a bound). The custom
registry is the default's extract with only its `downloaded` header changed:
the same version and entries (one version, 307 entries), not `===` the
default.

| `registry:` | Registry cost | Runs (ms) |
| --- | --- | --- |
| none (the compiled default) | one `===` comparison where each money call resolves its `registry:` option | 16.74, 18.39, 18.28 |
| a checked value of the custom registry | one constant-time test where each money call resolves its `registry:` option, and one in each unwrap of the positional lookups `member/2` makes (`held?/2`, `entry/3`) | 20.84, 18.96, 19.50 |
| the same registry as a raw map | one `check/1` walk per call (about 65–80 µs, `domain/money`), then as a checked value | 19.40, 17.58, 19.10 |

An explicit compiled default is sealed by `check/1` after one `===`
comparison and then costs as a checked value. Passing the raw map to every
money call again measured 203.97, 206.64 and 201.59 ms in that session. That
the walk is once per call is grounded by this measurement, not by a test.

Modules are application-owned under `Elzoo.Pricing` and `Cure.Elzoo.Pricing`;
the Piece depends on `domain/money` and on `integration/ai-model` for the unit
set. Apache-2.0; no dependency beyond pinned Cure, Decimal, Elixir and OTP.
