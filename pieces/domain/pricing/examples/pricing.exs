# SPDX-License-Identifier: Apache-2.0
alias Elzoo.Pricing

# A customer price card the host stores unchanged; it computes the hash once.
{:ok, eur} = Elzoo.Money.parse("EUR")

body = %{
  card_id: "retail",
  version: 1,
  kind: :price,
  currency: eur,
  rounding: :half_even,
  lines: [
    %{
      provider_id: "anthropic",
      model_id: "claude-a",
      unit: :input_uncached_tokens,
      rate: "3",
      per: 1_000_000,
      minimum: nil
    },
    %{
      provider_id: "anthropic",
      model_id: "claude-a",
      unit: :output_tokens,
      rate: "15",
      per: 1_000_000,
      minimum: "0.50"
    }
  ]
}

{:ok, hash} = Pricing.content_hash(body)
card = Map.put(body, :content_hash, hash)

# Host-built rows per provider, model, unit and source (domain/metering totals
# shape plus provider_id and model_id). One output observation is unknown.
row = fn unit, source, known, unknown_count, count ->
  %{
    provider_id: "anthropic",
    model_id: "claude-a",
    unit: unit,
    source: source,
    known: known,
    unknown_count: unknown_count,
    count: count
  }
end

usage = %{
  tenant: "acme",
  period: "2026-11",
  rows: [
    row.(:input_uncached_tokens, :provider_reported, 1_250_000, 0, 40),
    row.(:output_tokens, :provider_reported, 20_000, 0, 39),
    row.(:output_tokens, :unknown, 0, 1, 1)
  ]
}

# 3.75 EUR of input; 0.30 EUR of output raised to its 0.50 EUR minimum.
{:ok, charge} = Pricing.price(card, usage)

# The unknown observation is later reported as 30,000 tokens: 0.75 EUR of
# output. The host re-prices under the same card version and posts the difference.
corrected = %{
  usage
  | rows: [
      row.(:input_uncached_tokens, :provider_reported, 1_250_000, 0, 40),
      row.(:output_tokens, :provider_reported, 20_000, 0, 39),
      row.(:output_tokens, :unknown, 30_000, 0, 1)
    ]
}

{:ok, recharge} = Pricing.price(card, corrected)
{:ok, difference} = Pricing.difference(charge, recharge)

[
  {Enum.map(charge.lines, & &1.charge.minor_units), charge.total.minor_units, charge.incomplete},
  {recharge.total.minor_units, recharge.incomplete},
  difference.minor_units
]
