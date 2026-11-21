# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PricingTest do
  use ExUnit.Case, async: true
  alias Elzoo.Money
  alias Elzoo.Money.{Amount, Registry}
  alias Elzoo.Pricing

  # Every expected amount below is written out by hand from the README rule
  # (quantity × rate ÷ per, rounded once per line), not computed by the Piece.

  @errors [
    :invalid,
    :card,
    :content_hash,
    :usage,
    :unpriced_unit,
    :amount_range,
    :charge,
    :card_mismatch
  ]
  @modes [:down, :half_up, :half_even, :ceiling, :floor, :half_down, :up]

  # ---------------------------------------------------------------- builders

  defp currency(alpha) do
    {:ok, c} = Money.parse(alpha)
    c
  end

  defp line(rate, per, overrides \\ %{}) do
    Map.merge(
      %{
        provider_id: "anthropic",
        model_id: "claude-a",
        unit: :output_tokens,
        rate: rate,
        per: per,
        minimum: nil
      },
      overrides
    )
  end

  # A card with its content hash; overrides replace body fields.
  defp card(lines, overrides \\ %{}) do
    body =
      Map.merge(
        %{
          card_id: "retail",
          version: 1,
          kind: :price,
          currency: currency("EUR"),
          rounding: :half_up,
          lines: lines
        },
        overrides
      )

    assert {:ok, hash} = Pricing.content_hash(body)
    Map.put(body, :content_hash, hash)
  end

  # A card that content_hash/1 refuses, with a stand-in hash.
  defp raw_card(lines, overrides \\ %{}) do
    Map.merge(
      %{
        card_id: "retail",
        version: 1,
        content_hash: :binary.copy(<<0>>, 32),
        kind: :price,
        currency: currency("EUR"),
        rounding: :half_up,
        lines: lines
      },
      overrides
    )
  end

  defp row(source, known, overrides \\ %{}) do
    Map.merge(
      %{
        provider_id: "anthropic",
        model_id: "claude-a",
        unit: :output_tokens,
        source: source,
        known: known,
        unknown_count: 0,
        count: 1
      },
      overrides
    )
  end

  defp usage(rows, overrides \\ %{}),
    do: Map.merge(%{tenant: "acme", period: "2026-11", rows: rows}, overrides)

  defp units(charge), do: Enum.map(charge.lines, & &1.charge.minor_units)

  defp price!(card, rows) do
    assert {:ok, charge} = Pricing.price(card, usage(rows))
    charge
  end

  # ---------------------------------------------------------------- 1 exact charges

  describe "exact charges" do
    test "EUR, JPY and BHD cards, an 18-fractional-digit rate, per 1 and per 10^6" do
      # 3 EUR per 10^6 tokens × 2,500,000 = 7.50 EUR.
      eur = card([line("3", 1_000_000)])
      charge = price!(eur, [row(:provider_reported, 2_500_000)])
      assert charge.total == %Amount{currency: currency("EUR"), minor_units: 750}
      assert units(charge) == [750]
      assert charge.incomplete == false and charge.unknown_count == 0

      # 0.123456789012345678 EUR per token × 1000 = 123.456789012345678 EUR:
      # 12345.6789... cents, half_up 12346, down 12345.
      fine = [line("0.123456789012345678", 1)]
      assert units(price!(card(fine), [row(:estimated, 1000)])) == [12_346]
      assert units(price!(card(fine, %{rounding: :down}), [row(:estimated, 1000)])) == [12_345]

      # 0.000000000000000001 EUR per token × 123456789012345678901 = 123.456789012345678901 EUR.
      tiny = card([line("0.000000000000000001", 1)], %{rounding: :up})
      assert units(price!(tiny, [row(:estimated, 123_456_789_012_345_678_901)])) == [12_346]

      # JPY (exponent 0): 0.15 JPY per token × 1001 = 150.15 -> 150; × 1010 = 151.5 -> 152.
      jpy = card([line("0.15", 1)], %{currency: currency("JPY")})
      assert price!(jpy, [row(:estimated, 1001)]).total.minor_units == 150
      assert price!(jpy, [row(:estimated, 1010)]).total.minor_units == 152
      assert price!(jpy, [row(:estimated, 1010)]).total.currency == currency("JPY")

      # BHD (exponent 3): 2.5 BHD per 1000 tokens × 1234 = 3.085 BHD = 3085 fils.
      bhd = card([line("2.5", 1000)], %{currency: currency("BHD")})
      assert price!(bhd, [row(:estimated, 1234)]).total.minor_units == 3085
    end

    test "a cache-write line and lines of two providers and two models stay apart" do
      cache = {:cache_write_tokens, "5m"}

      c =
        card([
          line("15", 1_000_000),
          line("3.75", 1_000_000, %{unit: cache}),
          line("5", 1_000_000, %{model_id: "claude-b"}),
          line("10", 1_000_000, %{provider_id: "openai", model_id: "gpt-x"})
        ])

      charge =
        price!(c, [
          row(:provider_reported, 1_000_000, %{provider_id: "openai", model_id: "gpt-x"}),
          row(:provider_reported, 2_000_000, %{unit: cache}),
          row(:provider_reported, 1_000_000, %{model_id: "claude-b"}),
          row(:provider_reported, 1_000_000)
        ])

      # 15.00, 7.50 (3.75 × 2), 5.00 and 10.00 EUR in the card's line order.
      assert Enum.map(charge.lines, &{&1.provider_id, &1.model_id, &1.unit}) == [
               {"anthropic", "claude-a", :output_tokens},
               {"anthropic", "claude-a", cache},
               {"anthropic", "claude-b", :output_tokens},
               {"openai", "gpt-x", :output_tokens}
             ]

      assert units(charge) == [1500, 750, 500, 1000]
      assert charge.total.minor_units == 3750

      assert charge.card == %{
               card_id: "retail",
               version: 1,
               content_hash: c.content_hash,
               kind: :price
             }

      assert {charge.tenant, charge.period} == {"acme", "2026-11"}
    end
  end

  # ---------------------------------------------------------------- 2 rounding

  describe "rounding" do
    # EUR, 1 token: rate 0.005 is exactly half a cent; 0.0051 and 0.0049 just
    # above and below it; 0.015 is 1.5 cents (an odd neighbour for half_even);
    # 0.07 is a whole 7 cents.
    @cases [
      {"0.005", %{down: 0, half_up: 1, half_even: 0, ceiling: 1, floor: 0, half_down: 0, up: 1}},
      {"0.015", %{down: 1, half_up: 2, half_even: 2, ceiling: 2, floor: 1, half_down: 1, up: 2}},
      {"0.0051", %{down: 0, half_up: 1, half_even: 1, ceiling: 1, floor: 0, half_down: 1, up: 1}},
      {"0.0049", %{down: 0, half_up: 0, half_even: 0, ceiling: 1, floor: 0, half_down: 0, up: 1}},
      {"0.07", %{down: 7, half_up: 7, half_even: 7, ceiling: 7, floor: 7, half_down: 7, up: 7}}
    ]

    test "each of the seven modes at, above and below half a minor unit and on a whole value" do
      for {rate, expected} <- @cases, mode <- @modes do
        charge = price!(card([line(rate, 1)], %{rounding: mode}), [row(:estimated, 1)])
        assert units(charge) == [Map.fetch!(expected, mode)], "#{rate} #{mode}"
      end
    end

    test "a caller's Decimal context does not apply" do
      context = %Decimal.Context{precision: 2, rounding: :floor}

      Decimal.Context.with(context, fn ->
        # 0.123456789012345678 × 1000 = 12345.6789... cents, half_up 12346.
        c = card([line("0.123456789012345678", 1)])
        assert units(price!(c, [row(:estimated, 1000)])) == [12_346]
      end)
    end

    test "once per line: two rows of 0.4 cents give the charge of their 0.8 cent sum" do
      c = card([line("0.004", 1)])
      charge = price!(c, [row(:estimated, 1), row(:provider_reported, 1)])
      assert units(charge) == [1]
      assert hd(charge.lines).quantity == 2
      assert hd(charge.lines).sources == [:estimated, :provider_reported]
      assert hd(charge.lines).count == 2
    end
  end

  # ---------------------------------------------------------------- 3 zero and minimum

  describe "zero usage and the minimum" do
    test "rows with known 0 are charged the minimum, or zero without one" do
      rows = [row(:provider_reported, 0)]
      assert units(price!(card([line("1", 1, %{minimum: "0.50"})]), rows)) == [50]
      charge = price!(card([line("1", 1)]), rows)
      assert units(charge) == [0]
      assert charge.incomplete == false
      assert charge.total == %Amount{currency: currency("EUR"), minor_units: 0}
    end

    test "a card line with no row is absent, also with a minimum" do
      c = card([line("1", 1, %{minimum: "5"}), line("1", 1, %{model_id: "claude-b"})])
      charge = price!(c, [row(:estimated, 3, %{model_id: "claude-b"})])
      assert Enum.map(charge.lines, & &1.model_id) == ["claude-b"]
      assert charge.total.minor_units == 300
    end

    test "a rounded charge at or above the minimum keeps its value; below it is raised" do
      c = card([line("1", 1, %{minimum: "0.50"})])
      # 2 EUR, 0.50 EUR exactly, and 0.10 EUR raised to 0.50 EUR.
      assert units(price!(c, [row(:estimated, 2)])) == [200]
      assert units(price!(card([line("0.5", 1, %{minimum: "0.50"})]), [row(:estimated, 1)])) == [50]
      assert units(price!(card([line("0.1", 1, %{minimum: "0.50"})]), [row(:estimated, 1)])) == [50]
    end

    test "a usage with no rows is an empty, complete charge with a zero total" do
      assert {:ok, charge} = Pricing.price(card([line("1", 1, %{minimum: "1"})]), usage([]))
      assert charge.lines == []
      assert charge.total == %Amount{currency: currency("EUR"), minor_units: 0}
      assert charge.incomplete == false and charge.unknown_count == 0
    end
  end

  # ---------------------------------------------------------------- 4 unknown

  describe "unknown" do
    test "known and unknown rows give the known amount's charge, its unknown count and incomplete" do
      c = card([line("2", 1)])

      charge =
        price!(c, [
          row(:unknown, 0, %{unknown_count: 2, count: 2}),
          row(:provider_reported, 3, %{count: 3}),
          row(:estimated, 4, %{unknown_count: 1, count: 3})
        ])

      # 2 EUR × (3 + 4) = 14.00 EUR; 3 unknown observations of 8.
      assert [line] = charge.lines
      assert line.quantity == 7 and line.unknown_count == 3 and line.count == 8
      assert line.sources == [:estimated, :provider_reported, :unknown]
      assert line.charge.minor_units == 1400
      assert charge.total.minor_units == 1400
      assert charge.incomplete == true and charge.unknown_count == 3
    end

    test "a line whose rows are all unknown is charged its minimum or zero and is incomplete" do
      rows = [row(:unknown, 0, %{unknown_count: 4, count: 4})]
      with_minimum = price!(card([line("2", 1, %{minimum: "1.00"})]), rows)
      assert units(with_minimum) == [100]
      assert with_minimum.incomplete == true and with_minimum.unknown_count == 4

      without = price!(card([line("2", 1)]), rows)
      assert units(without) == [0]
      assert without.incomplete == true and without.unknown_count == 4
    end

    test "one incomplete line makes the charge incomplete" do
      c = card([line("1", 1), line("1", 1, %{model_id: "claude-b"})])

      charge =
        price!(c, [
          row(:estimated, 1),
          row(:estimated, 1, %{model_id: "claude-b", unknown_count: 1, count: 2})
        ])

      assert Enum.map(charge.lines, & &1.unknown_count) == [0, 1]
      assert charge.incomplete == true and charge.unknown_count == 1
    end

    test "a row with no card line is unpriced_unit, also when it is all unknown" do
      c = card([line("1", 1)])
      other = %{model_id: "claude-z"}
      assert Pricing.price(c, usage([row(:estimated, 1, other)])) == {:error, :unpriced_unit}

      all_unknown = row(:unknown, 0, Map.merge(other, %{unknown_count: 1}))
      assert Pricing.price(c, usage([row(:estimated, 1), all_unknown])) == {:error, :unpriced_unit}
    end
  end

  # ---------------------------------------------------------------- 5 immutability

  describe "card versions" do
    test "a newer card leaves an earlier charge equal; difference refuses other identities" do
      rows = [row(:provider_reported, 1_000_000)]
      v1 = card([line("3", 1_000_000)])
      before = price!(v1, rows)
      v2 = card([line("4", 1_000_000)], %{version: 2})
      later = price!(v2, rows)

      assert price!(v1, rows) == before
      assert before.total.minor_units == 300 and later.total.minor_units == 400
      assert Pricing.difference(before, later) == {:error, :card_mismatch}

      cost = price!(card([line("3", 1_000_000)], %{kind: :cost}), rows)
      assert Pricing.difference(before, cost) == {:error, :card_mismatch}

      other_tenant = Pricing.price(v1, usage(rows, %{tenant: "globex"}))
      other_period = Pricing.price(v1, usage(rows, %{period: "2026-12"}))

      for {:ok, other} <- [other_tenant, other_period] do
        assert other.total == before.total
        assert Pricing.difference(before, other) == {:error, :card_mismatch}
        assert Pricing.difference(other, before) == {:error, :card_mismatch}
      end
    end

    test "a card whose content_hash does not match is content_hash" do
      c = card([line("3", 1_000_000)])
      changed = %{c | lines: [line("2", 1_000_000)]}
      assert Pricing.price(changed, usage([])) == {:error, :content_hash}
      assert Pricing.price(%{c | version: 2}, usage([])) == {:error, :content_hash}
    end

    test "content_hash ignores its own key and every body field changes it" do
      body = Map.delete(card([line("3", 1_000_000)]), :content_hash)
      {:ok, hash} = Pricing.content_hash(body)
      assert byte_size(hash) == 32
      assert Pricing.content_hash(Map.put(body, :content_hash, "anything")) == {:ok, hash}

      changes = [
        card_id: "retail-2",
        version: 2,
        kind: :cost,
        currency: currency("USD"),
        rounding: :half_even,
        lines: [line("3", 1_000_000, %{minimum: "0"})],
        lines: [line("3.0", 1_000_000)],
        lines: [line("3", 100_000)],
        lines: [line("3", 1_000_000, %{unit: :input_uncached_tokens})]
      ]

      hashes = for {k, v} <- changes, do: elem(Pricing.content_hash(%{body | k => v}), 1)
      assert length(Enum.uniq([hash | hashes])) == length(changes) + 1
      assert Pricing.content_hash(:card) == {:error, :card}
      assert Pricing.content_hash(%{body | lines: []}) == {:error, :card}
    end

    test "the documented encoding gives fixed expected bytes for one card" do
      body = %{
        card_id: "c1",
        version: 1,
        kind: :price,
        currency: currency("JPY"),
        rounding: :half_up,
        lines: [
          %{
            provider_id: "p",
            model_id: "m",
            unit: :output_tokens,
            rate: "0.5",
            per: 1000,
            minimum: "10"
          },
          %{
            provider_id: "p",
            model_id: "m",
            unit: {:cache_write_tokens, "1h"},
            rate: "2",
            per: 1,
            minimum: nil
          }
        ]
      }

      # Written by hand from the README: text = <<size::32>> <> bytes,
      # int = <<n::64>>, list = <<count::32>> <> items, field = text(key) <> value.
      line_1 =
        <<0, 0, 0, 11>> <>
          "provider_id" <>
          <<0, 0, 0, 1>> <>
          "p" <>
          <<0, 0, 0, 8>> <>
          "model_id" <>
          <<0, 0, 0, 1>> <>
          "m" <>
          <<0, 0, 0, 4>> <>
          "unit" <>
          <<0, 0, 0, 1>> <>
          <<0, 0, 0, 13>> <>
          "output_tokens" <>
          <<0, 0, 0, 4>> <>
          "rate" <>
          <<0, 0, 0, 3>> <>
          "0.5" <>
          <<0, 0, 0, 3>> <>
          "per" <>
          <<0, 0, 0, 0, 0, 0, 3, 232>> <>
          <<0, 0, 0, 7>> <> "minimum" <> <<0, 0, 0, 2>> <> "10"

      line_2 =
        <<0, 0, 0, 11>> <>
          "provider_id" <>
          <<0, 0, 0, 1>> <>
          "p" <>
          <<0, 0, 0, 8>> <>
          "model_id" <>
          <<0, 0, 0, 1>> <>
          "m" <>
          <<0, 0, 0, 4>> <>
          "unit" <>
          <<0, 0, 0, 2>> <>
          <<0, 0, 0, 18>> <>
          "cache_write_tokens" <>
          <<0, 0, 0, 2>> <>
          "1h" <>
          <<0, 0, 0, 4>> <>
          "rate" <>
          <<0, 0, 0, 1>> <>
          "2" <>
          <<0, 0, 0, 3>> <> "per" <> <<0, 0, 0, 0, 0, 0, 0, 1>>

      expected =
        <<0, 0, 0, 18>> <>
          "elzoo/pricing/card" <>
          <<0, 0, 0, 7>> <>
          "card_id" <>
          <<0, 0, 0, 2>> <>
          "c1" <>
          <<0, 0, 0, 7>> <>
          "version" <>
          <<0, 0, 0, 0, 0, 0, 0, 1>> <>
          <<0, 0, 0, 4>> <>
          "kind" <>
          <<0, 0, 0, 5>> <>
          "price" <>
          <<0, 0, 0, 8>> <>
          "currency" <>
          <<0, 0, 0, 57>> <>
          <<0, 0, 0, 5>> <>
          "alpha" <>
          <<0, 0, 0, 3>> <>
          "JPY" <>
          <<0, 0, 0, 7>> <>
          "numeric" <>
          <<0, 0, 0, 0, 0, 0, 1, 136>> <>
          <<0, 0, 0, 10>> <>
          "minor_unit" <>
          <<0, 0, 0, 0, 0, 0, 0, 0>> <>
          <<0, 0, 0, 8>> <>
          "rounding" <>
          <<0, 0, 0, 7>> <>
          "half_up" <>
          <<0, 0, 0, 5>> <>
          "lines" <>
          <<0, 0, 0, 2>> <>
          <<0, 0, 0, 113>> <> line_1 <> <<0, 0, 0, 105>> <> line_2

      assert byte_size(line_1) == 113 and byte_size(line_2) == 105
      assert Pricing.content_hash(body) == {:ok, :crypto.hash(:sha256, expected)}

      assert Base.encode16(:crypto.hash(:sha256, expected), case: :lower) ==
               "b7307c384591d1f8dcac2a31e8e07d0e87dbc9960e6a45803f6db620b862984f"
    end
  end

  # ---------------------------------------------------------------- 6 corrections

  describe "corrections" do
    setup do
      # 0.02 EUR per token.
      {:ok, card: card([line("0.02", 1)])}
    end

    test "a known amount raised and an unknown made known give the hand difference", %{card: c} do
      before =
        price!(c, [
          row(:provider_reported, 1000),
          row(:estimated, 0, %{unknown_count: 1})
        ])

      after_correction =
        price!(c, [
          row(:provider_reported, 1500),
          row(:estimated, 250)
        ])

      # 20.00 EUR (incomplete) then 35.00 EUR: +15.00 EUR.
      assert before.total.minor_units == 2000 and before.incomplete
      assert after_correction.total.minor_units == 3500 and not after_correction.incomplete

      assert Pricing.difference(before, after_correction) ==
               {:ok, %Amount{currency: currency("EUR"), minor_units: 1500}}
    end

    test "a correction down is negative; equal totals give zero", %{card: c} do
      before = price!(c, [row(:provider_reported, 1000), row(:estimated, 0, %{unknown_count: 1})])
      down = price!(c, [row(:provider_reported, 900), row(:estimated, 0, %{unknown_count: 1})])

      # 20.00 then 18.00 EUR: -2.00 EUR.
      assert Pricing.difference(before, down) ==
               {:ok, %Amount{currency: currency("EUR"), minor_units: -200}}

      assert Pricing.difference(before, before) ==
               {:ok, %Amount{currency: currency("EUR"), minor_units: 0}}

      assert Pricing.difference(before, down, registry: Registry.default()) ==
               {:ok, %Amount{currency: currency("EUR"), minor_units: -200}}
    end

    test "a currency re-read under a newer registry version keeps the card and the difference" do
      dir = Registry.module_info(:compile)[:source] |> to_string() |> Path.dirname()
      v1 = Registry.latest(Registry.default())
      extract = File.read!(Path.join([dir, "iso4217", v1 <> ".tsv"]))

      next =
        extract
        |> String.replace("# version\t#{v1}", "# version\t2027-01-01")
        |> String.replace("# current_published\t#{v1}", "# current_published\t2027-01-01")

      newer = Registry.build!([extract, next])
      {:ok, eur_2} = Money.parse("EUR", registry: newer, version: "2027-01-01")
      assert eur_2.version == "2027-01-01"

      earlier = card([line("0.02", 1)])
      later = card([line("0.02", 1)], %{currency: eur_2})
      assert later.content_hash == earlier.content_hash

      assert {:ok, a} = Pricing.price(earlier, usage([row(:estimated, 1000)]), registry: newer)
      assert {:ok, b} = Pricing.price(later, usage([row(:estimated, 1500)]), registry: newer)

      # 20.00 then 30.00 EUR: +10.00 EUR in the later charge's currency.
      assert Pricing.difference(a, b, registry: newer) ==
               {:ok, %Amount{currency: eur_2, minor_units: 1000}}
    end
  end

  # ---------------------------------------------------------------- 7 mixed units

  describe "mixed units" do
    test "a row is not priced by a line of another unit or another model" do
      c = card([line("1", 1)])

      assert Pricing.price(c, usage([row(:estimated, 1, %{unit: :input_uncached_tokens})])) ==
               {:error, :unpriced_unit}

      assert Pricing.price(c, usage([row(:estimated, 1, %{model_id: "claude-b"})])) ==
               {:error, :unpriced_unit}

      assert Pricing.price(c, usage([row(:estimated, 1, %{unit: {:cache_write_tokens, "1h"}})])) ==
               {:error, :unpriced_unit}
    end

    test "duplicate or unsorted lines are card" do
      a = line("1", 1)
      b = line("1", 1, %{model_id: "claude-b"})
      assert Pricing.price(raw_card([a, a]), usage([])) == {:error, :card}
      assert Pricing.price(raw_card([b, a]), usage([])) == {:error, :card}
      assert Pricing.price(raw_card([a, %{a | rate: "2"}]), usage([])) == {:error, :card}
      assert Pricing.content_hash(Map.delete(raw_card([b, a]), :content_hash)) == {:error, :card}
    end
  end

  # ---------------------------------------------------------------- 8 validation

  describe "validation" do
    test "checks run in the fixed order" do
      bad_card = raw_card([], %{})
      bad_usage = %{tenant: "acme"}
      good = card([line("1", 1)])
      assert Pricing.price(bad_card, bad_usage, registry: :none) == {:error, :invalid}
      assert Pricing.price(bad_card, bad_usage) == {:error, :card}
      assert Pricing.price(%{good | version: 2}, bad_usage) == {:error, :content_hash}

      unpriced_and_bad = usage([row(:estimated, 1, %{model_id: "x"}), row(:estimated, -1)])
      assert Pricing.price(good, unpriced_and_bad) == {:error, :usage}

      # The huge line's own row alone is amount_range; the unpriced row is checked first.
      range_and_unpriced = [
        row(:estimated, Integer.pow(10, 37)),
        row(:estimated, 1, %{model_id: "x"})
      ]

      huge = card([line("100000000000000000", 1)])
      assert Pricing.price(huge, usage(Enum.take(range_and_unpriced, 1))) == {:error, :amount_range}
      assert Pricing.price(huge, usage(range_and_unpriced)) == {:error, :unpriced_unit}
    end

    test "options" do
      c = card([line("1", 1)])
      assert {:ok, _} = Pricing.price(c, usage([]), registry: Registry.default())

      for opts <- [
            [registry: :none],
            [registry: %{}],
            # The four keys of a built registry with forged contents.
            [registry: %{versions: ["bogus"], snapshots: %{}, active_numeric: %{}, sources: %{}}],
            [registry: %{Registry.default() | versions: []}],
            [foo: 1],
            [registry: Registry.default(), foo: 1],
            %{},
            nil
          ] do
        assert Pricing.price(c, usage([]), opts) == {:error, :invalid}
        {:ok, charge} = Pricing.price(c, usage([]))
        assert Pricing.difference(charge, charge, opts) == {:error, :invalid}
      end
    end

    test "rates, per and minimums" do
      for rate <- [
            "-1",
            "01",
            "1.",
            ".5",
            "1e3",
            "1,5",
            " 1",
            "",
            1.5,
            1,
            "1234567890123456789",
            "1.000000000000000000",
            "0.0000000000000000001",
            "0.1234567890123456789"
          ] do
        assert Pricing.price(raw_card([line(rate, 1)]), usage([])) == {:error, :card},
               inspect(rate)
      end

      for rate <- [
            "0",
            "123456789012345678",
            "0.123456789012345678",
            "0.000000000000000001",
            "1.00"
          ] do
        assert {:ok, _} = Pricing.price(card([line(rate, 1)]), usage([])), rate
      end

      for per <- [0, 3, 10_000_000_000, -10, 1.0, "1"] do
        assert Pricing.price(raw_card([line("1", per)]), usage([])) == {:error, :card}
      end

      for per <- [1, 10, 100, 1000, 1_000_000_000] do
        assert {:ok, _} = Pricing.price(card([line("1", per)]), usage([]))
      end

      for minimum <- ["0.001", "-1", "-0", "1.", "", 1, 0.5] do
        assert Pricing.price(raw_card([line("1", 1, %{minimum: minimum})]), usage([])) ==
                 {:error, :card}
      end

      jpy = %{currency: currency("JPY")}

      assert Pricing.price(raw_card([line("1", 1, %{minimum: "0.5"})], jpy), usage([])) ==
               {:error, :card}

      bhd = %{currency: currency("BHD")}
      assert {:ok, _} = Pricing.price(card([line("1", 1, %{minimum: "0.125"})], bhd), usage([]))
    end

    test "currencies, kinds, roundings, versions and line counts" do
      eur = currency("EUR")
      {:ok, xdr} = Money.parse("XDR")

      for overrides <- [
            %{currency: %{eur | minor_unit: 3}},
            %{currency: %{eur | numeric: 979}},
            %{currency: %{eur | version: "1999-01-01"}},
            %{currency: xdr},
            %{currency: "EUR"},
            %{kind: :invoice},
            %{rounding: :nearest},
            %{version: 0},
            %{version: 2_147_483_648},
            %{card_id: ""},
            %{content_hash: <<0>>}
          ] do
        assert Pricing.price(raw_card([line("1", 1)], overrides), usage([])) == {:error, :card},
               inspect(overrides)
      end

      for mode <- @modes,
          do: assert({:ok, _} = Pricing.price(card([line("1", 1)], %{rounding: mode}), usage([])))

      assert {:ok, _} = Pricing.price(card([line("1", 1)], %{version: 2_147_483_647}), usage([]))

      many = fn n ->
        for i <- 1..n, do: line("1", 1, %{model_id: "m" <> String.pad_leading("#{i}", 4, "0")})
      end

      assert {:ok, _} = Pricing.price(card(many.(1024)), usage([]))
      assert Pricing.price(raw_card(many.(1025)), usage([])) == {:error, :card}
      assert Pricing.price(raw_card([]), usage([])) == {:error, :card}
      assert Pricing.price(raw_card([line("1", 1) | line("1", 1)]), usage([])) == {:error, :card}

      assert Pricing.price(raw_card([Map.put(line("1", 1), :tiers, [])]), usage([])) ==
               {:error, :card}

      assert Pricing.price(Map.put(card([line("1", 1)]), :extra, 1), usage([])) == {:error, :card}
      assert Pricing.price(:card, usage([])) == {:error, :card}
    end

    test "usage shape and row bounds" do
      c = card([line("1", 1)])

      # A line has at most three rows (one per source), so 4096 rows reach the line check.
      rows =
        for i <- 1..1366, source <- [:estimated, :provider_reported, :unknown] do
          r = row(source, 0, %{model_id: "m" <> Integer.to_string(i)})
          if source == :unknown, do: %{r | unknown_count: 1}, else: r
        end

      rows = Enum.take(rows, 4096)
      assert Pricing.price(c, usage(rows)) == {:error, :unpriced_unit}
      assert Pricing.price(c, usage([row(:estimated, 1) | rows])) == {:error, :usage}

      for bad <- [
            row(:estimated, 1, %{count: 0}),
            row(:estimated, 0, %{count: 0, unknown_count: 0}),
            row(:estimated, 1, %{unknown_count: 2, count: 1}),
            row(:estimated, 1, %{unknown_count: 1, count: 1}),
            row(:estimated, -1),
            row(:estimated, Integer.pow(10, 38)),
            row(:estimated, 1, %{unknown_count: -1}),
            row(:corrected, 1),
            row(:estimated, 1, %{unit: :tokens}),
            row(:estimated, 1, %{unit: {:cache_write_tokens, "2h"}}),
            row(:estimated, 1.0),
            Map.delete(row(:estimated, 1), :count),
            Map.put(row(:estimated, 1), :usage_id, "u1")
          ] do
        assert Pricing.price(c, usage([bad])) == {:error, :usage}, inspect(bad)
      end

      assert Pricing.price(c, usage([row(:estimated, 1), row(:estimated, 2)])) == {:error, :usage}
      assert Pricing.price(c, usage([row(:estimated, 1) | row(:estimated, 2)])) == {:error, :usage}
      assert Pricing.price(c, %{tenant: "acme", period: "p"}) == {:error, :usage}
      assert Pricing.price(c, Map.put(usage([]), :extra, 1)) == {:error, :usage}
      # known 10^38 - 1 at 1 EUR per 10^9 tokens is about 10^29 EUR: accepted.
      per_billion = card([line("1", 1_000_000_000)])

      assert {:ok, _} =
               Pricing.price(per_billion, usage([row(:estimated, Integer.pow(10, 38) - 1)]))
    end

    test "each 128-byte text at 0, 128 and 129 bytes, invalid UTF-8 and C0 and C1 characters" do
      ok = String.duplicate("a", 128)

      bad = [
        "",
        String.duplicate("a", 129),
        <<0xFF>>,
        "a\u0085b",
        "a\u009Fb",
        "a\nb",
        "a\u007Fb",
        :acme
      ]

      assert {:ok, _} =
               Pricing.price(
                 card([line("1", 1, %{provider_id: ok, model_id: ok})], %{card_id: ok}),
                 usage([])
               )

      for t <- bad do
        assert Pricing.price(raw_card([line("1", 1)], %{card_id: t}), usage([])) == {:error, :card}

        for field <- [:provider_id, :model_id] do
          assert Pricing.price(raw_card([line("1", 1, %{field => t})]), usage([])) ==
                   {:error, :card}
        end
      end

      c = card([line("1", 1)])

      for field <- [:tenant, :period] do
        assert {:ok, _} = Pricing.price(c, usage([], %{field => ok}))
        for t <- bad, do: assert(Pricing.price(c, usage([], %{field => t})) == {:error, :usage})
      end

      long = card([line("1", 1, %{provider_id: ok, model_id: ok})])

      assert {:ok, %{lines: [_]}} =
               Pricing.price(long, usage([row(:estimated, 1, %{provider_id: ok, model_id: ok})]))

      for field <- [:provider_id, :model_id], t <- bad do
        assert Pricing.price(c, usage([row(:estimated, 1, %{field => t})])) == {:error, :usage}
      end
    end

    test "exact values beyond domain/money are amount_range, never truncated" do
      max = Integer.pow(10, 38) - 1
      # 3 × (10^38 - 1) = 299999999999999999999999999999999999997: 39 digits, no trailing zero.
      c39 = card([line("0.000000000000000003", 1)])
      assert Pricing.price(c39, usage([row(:estimated, max)])) == {:error, :amount_range}

      # 11 × (3 × 10^36 + 1) = 33000000000000000000000000000000000011 (38 digits), × 10^-18:
      # 33000000000000000000.000000000000000011 EUR -> 3300000000000000000000 cents (half_up).
      c38 = card([line("0.000000000000000011", 1)])
      known = 3 * Integer.pow(10, 36) + 1
      assert units(price!(c38, [row(:estimated, known)])) == [3_300_000_000_000_000_000_000]

      # 10^37 × 10^17: coefficient 1, exponent 54.
      huge = card([line("100000000000000000", 1)])

      assert Pricing.price(huge, usage([row(:estimated, Integer.pow(10, 37))])) ==
               {:error, :amount_range}

      # 10^37 EUR is 10^39 cents: outside the domain/money range.
      one = card([line("1", 1)])

      assert Pricing.price(one, usage([row(:estimated, Integer.pow(10, 37))])) ==
               {:error, :amount_range}

      # Two lines of 6 × 10^37 cents each: the total is outside the range.
      two = card([line("1", 1), line("1", 1, %{model_id: "claude-b"})])
      known_6 = 6 * Integer.pow(10, 35)

      assert Pricing.price(
               two,
               usage([row(:estimated, known_6), row(:estimated, known_6, %{model_id: "claude-b"})])
             ) == {:error, :amount_range}

      # A trailing-zero coefficient is trimmed before the bound: (10^38 - 1) × 10 has 39 digits,
      # trimmed to 10^38 - 1 at exponent -8 (38 digits): 99999999999999999999999999999999.999999
      # cents, half_up 10^32 cents.
      trimmed = card([line("10", 1_000_000_000)])

      assert units(price!(trimmed, [row(:estimated, max)])) == [
               100_000_000_000_000_000_000_000_000_000_000
             ]
    end

    test "difference refuses malformed charges, including a negative total" do
      c = card([line("1", 1)])
      charge = price!(c, [row(:estimated, 1)])
      negative = %{charge | total: %Amount{currency: currency("EUR"), minor_units: -1}}
      assert Pricing.difference(charge, negative) == {:error, :charge}
      assert Pricing.difference(negative, charge) == {:error, :charge}

      eur = currency("EUR")

      for bad <- [
            Map.delete(charge, :total),
            %{charge | tenant: ""},
            %{charge | card: Map.put(charge.card, :version, 0)},
            %{charge | total: %Amount{currency: %{eur | minor_unit: 3}, minor_units: 1}},
            %{charge | total: %Amount{currency: eur, minor_units: Integer.pow(10, 38)}},
            %{charge | incomplete: true},
            %{charge | unknown_count: -1},
            %{
              charge
              | lines: [
                  %{hd(charge.lines) | charge: %Amount{currency: currency("JPY"), minor_units: 1}}
                ]
            },
            %{charge | lines: :none},
            :charge
          ] do
        assert Pricing.difference(charge, bad) == {:error, :charge}, inspect(bad)
      end

      jpy = price!(card([line("1", 1)], %{currency: currency("JPY")}), [row(:estimated, 1)])
      assert jpy.card != charge.card
      assert Pricing.difference(charge, jpy) == {:error, :card_mismatch}
    end

    test "errors are fixed atoms and junk does not raise" do
      junk = [nil, 1, "x", [], %{}, {:a}, :card, %Amount{currency: nil, minor_units: 1}]

      for a <- junk, b <- junk do
        assert {:error, reason} = Pricing.price(a, b)
        assert reason in @errors
        assert {:error, reason} = Pricing.difference(a, b)
        assert reason in @errors
      end
    end
  end

  # ---------------------------------------------------------------- 9 Cure

  describe "Cure" do
    test "the production decisions" do
      cure = :"Cure.Elzoo.Pricing"
      assert apply(cure, :line, [false, true, 0, 50]) == :LineAbsent
      assert apply(cure, :line, [true, true, 10, 50]) == {:LineCharged, 50}
      assert apply(cure, :line, [true, true, 50, 50]) == {:LineCharged, 50}
      assert apply(cure, :line, [true, true, 51, 50]) == {:LineCharged, 51}
      assert apply(cure, :line, [true, false, 10, 50]) == {:LineCharged, 10}
      assert apply(cure, :complete, [[]]) == true
      assert apply(cure, :complete, [[0, 0]]) == true
      assert apply(cure, :complete, [[0, 1, 0]]) == false
    end

    test "selected Cure laws, a clean audit and the checked example" do
      source = File.read!(Path.expand("../../cure/elzoo/pricing.cure", __DIR__))
      roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
      assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
      assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
      audit = Cure.Audit.Ledger.audit_env(env)

      for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
          do: assert(Map.fetch!(audit, key) == [])

      {result, _} = Code.eval_file(Path.expand("../../examples/pricing.exs", __DIR__))
      # 3.75 EUR input and 0.30 EUR output raised to 0.50; then 0.75 EUR output; +0.25 EUR.
      assert result == [{[375, 50], 425, true}, {450, false}, 25]
    end
  end
end
