# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.MoneyTest do
  use ExUnit.Case, async: true
  alias Elzoo.Money, as: M
  alias Elzoo.Money.Amount

  @cure :"Cure.Elzoo.Money"
  @source File.read!(Path.expand("../../cure/elzoo/money.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

  @laws ~w(add_same_currency add_mismatch_names_both subtract_same_currency
           subtract_mismatch_names_both compare_mismatch_names_both negate_keeps_currency
           invalid_ratios_rejected shares_count shares_currency distribute_count
           distribute_currency allocate_count allocate_currency)

  defp currency!(code) do
    {:ok, c} = M.parse(code)
    c
  end

  defp amount!(code, minor) do
    {:ok, a} = M.from_minor_units(currency!(code), minor)
    a
  end

  defp units(%{parts: parts}), do: Enum.map(parts, & &1.minor_units)

  describe "Cure laws" do
    test "selected laws compile with a clean audit" do
      assert {:module, @cure} = Code.ensure_loaded(@cure)
      assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
      report = Cure.Audit.Ledger.audit_env(env)

      for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
          do: assert(Map.fetch!(report, key) == [], "#{key}: #{inspect(Map.fetch!(report, key))}")

      assert report.absurd == 0
      for law <- @laws, do: assert(@source =~ ~r/^  fn #{law}\(/m, "missing law #{law}")
    end

    @no_currency ~s|MoneyCurrency{alpha: "XXX", numeric: 0, exponent: 0}|

    # {what the mutation breaks, proof expected to reject it, [{anchor, replacement}]}
    @mutations [
      {"placement adds a part", "distribute_count",
       [
         {"  fn distribute(parts: List(MoneyAmount), ratios: List(Int), remaining: Int, placement: MoneyPlacement) -> List(MoneyAmount) =\n    match parts\n      [] -> []",
          "  fn distribute(parts: List(MoneyAmount), ratios: List(Int), remaining: Int, placement: MoneyPlacement) -> List(MoneyAmount) =\n    match parts\n      [] -> [amount(#{@no_currency}, 0)]"}
       ]},
      {"a share changes currency", "shares_currency",
       [
         {"[r | rest] -> [amount(currency, (total * r) / sum)",
          "[r | rest] -> [amount(#{@no_currency}, (total * r) / sum)"}
       ]},
      {"add keeps the right currency", "add_same_currency",
       [
         {"MoneyResult = MoneyOk(amount(left.currency, left.minor_units + right.minor_units))",
          "MoneyResult = MoneyOk(amount(right.currency, left.minor_units + right.minor_units))"}
       ]},
      {"add ignores the mismatch", "add_mismatch_names_both",
       [
         {"      True() -> summed(left, right)\n      False() -> MoneyRejected(mismatch(left, right))",
          "      True() -> summed(left, right)\n      False() -> summed(left, right)"}
       ]},
      {"mismatch swaps the currencies", "add_mismatch_names_both",
       [
         {"MoneyCurrencyMismatch(left.currency, right.currency)",
          "MoneyCurrencyMismatch(right.currency, left.currency)"}
       ]}
    ]

    defp mutate(edits) do
      Enum.reduce(edits, String.replace(@source, "mod Elzoo.Money", "mod Elzoo.WrongMoney"), fn
        {from, to}, acc ->
          assert length(String.split(acc, from)) == 2, "mutation anchor not unique: #{from}"
          String.replace(acc, from, to)
      end)
    end

    @tag timeout: 300_000
    test "negative controls: each broken decision is rejected by Cure at its law" do
      for {what, law, edits} <- @mutations do
        assert {:error, error} = Cure.Compiler.check_source(mutate(edits), source_roots: @roots),
               "mutation accepted: #{what}"

        assert inspect(error, limit: :infinity, printable_limit: :infinity) =~ "checking: :#{law}",
               "#{what} not rejected at #{law}"
      end
    end

    # Recorded limitation, executable: no selected law states the allocation
    # sum, so a copy that drops the residual, with its count and currency proofs
    # restated for the copy, still checks. The finite test "bounded exhaustive
    # allocation" below is the control that rejects it.
    @tag timeout: 300_000
    test "limitation: Cure accepts a dropped residual (sum law not provable on this pin)" do
      dropped =
        mutate([
          {"MoneyAllocation{parts: distribute(total_shares(total, ratios), ratios, residual_of(total, ratios), placement)",
           "MoneyAllocation{parts: distribute(total_shares(total, ratios), ratios, 0, placement)"},
          {"Std.Equivalent.trans(distribute_count(total_shares(total, ratios), ratios, residual_of(total, ratios), placement)",
           "Std.Equivalent.trans(distribute_count(total_shares(total, ratios), ratios, 0, placement)"},
          {"Std.Equivalent.trans(distribute_currency(total_shares(total, ratios), ratios, residual_of(total, ratios), placement)",
           "Std.Equivalent.trans(distribute_currency(total_shares(total, ratios), ratios, 0, placement)"}
        ])

      assert {:ok, _} = Cure.Compiler.check_source(dropped, source_roots: @roots)
    end
  end

  describe "allocation" do
    # {total, ratios, first, last, spread}; residual is implied by the shares.
    @cases [
      {100, [1, 1, 1], [34, 33, 33], [33, 33, 34], [34, 33, 33], 1},
      {200, [1, 1, 1], [68, 66, 66], [66, 66, 68], [67, 67, 66], 2},
      {-100, [1, 1, 1], [-34, -33, -33], [-33, -33, -34], [-34, -33, -33], -1},
      {100, [1, 2], [34, 66], [33, 67], [34, 66], 1},
      {100, [0, 1, 1], [0, 50, 50], [0, 50, 50], [0, 50, 50], 0},
      {5, [1, 0, 1, 0], [3, 0, 2, 0], [2, 0, 3, 0], [3, 0, 2, 0], 1},
      {-5, [1, 0, 1, 0], [-3, 0, -2, 0], [-2, 0, -3, 0], [-3, 0, -2, 0], -1},
      {0, [1, 1], [0, 0], [0, 0], [0, 0], 0}
    ]

    test "EUR exact parts and residual per placement" do
      for {total, ratios, first, last, spread, residual} <- @cases do
        a = amount!("EUR", total)

        for {placement, expected} <- [first: first, last: last, spread: spread] do
          assert {:ok, result} = M.allocate(a, ratios, placement)
          assert units(result) == expected, "#{total} #{inspect(ratios)} #{placement}"
          assert result.residual_placed == residual
          assert Enum.all?(result.parts, &(&1.currency == a.currency))
        end
      end
    end

    test "EUR 1.00 three ways sums to 100 minor units; JPY 1000 and BHD 1.234" do
      for {code, total, first} <- [
            {"EUR", 100, [34, 33, 33]},
            {"JPY", 1000, [334, 333, 333]},
            {"BHD", 1234, [412, 411, 411]}
          ] do
        assert {:ok, result} = M.allocate(amount!(code, total), [1, 1, 1], :first)
        assert units(result) == first
        assert Enum.sum(units(result)) == total
      end
    end

    # The allocation properties over a stated finite range. Returns the failures.
    defp allocation_failures(allocate) do
      lists = for n <- 1..3, ratios <- combos(n), Enum.sum(ratios) > 0, do: ratios

      for total <- -60..60,
          ratios <- lists,
          placement <- [:first, :last, :spread],
          failure = check(allocate.(total, ratios, placement), total, ratios, placement),
          do: failure
    end

    defp combos(0), do: [[]]
    defp combos(n), do: for(r <- 0..3, rest <- combos(n - 1), do: [r | rest])

    defp check({parts, residual}, total, ratios, placement) do
      sum = Enum.sum(ratios)
      shares = Enum.map(ratios, &div(total * &1, sum))
      changed = Enum.count(Enum.zip(parts, shares), fn {p, s} -> p != s end)

      ok =
        Enum.sum(parts) == total and length(parts) == length(ratios) and
          residual == total - Enum.sum(shares) and
          Enum.all?(Enum.zip(parts, ratios), fn {p, r} -> r > 0 or p == 0 end) and
          Enum.all?(Enum.zip(parts, shares), fn {p, s} -> abs(p - s) <= abs(residual) end) and
          if(placement == :spread, do: changed == abs(residual), else: changed <= 1)

      if ok, do: nil, else: {total, ratios, placement, parts}
    end

    defp production(total, ratios, placement) do
      {:ok, result} = M.allocate(amount!("EUR", total), ratios, placement)
      {units(result), result.residual_placed}
    end

    @tag timeout: 300_000
    test "bounded exhaustive allocation: totals -60..60, ratio lists 1..3 of 0..3, all placements" do
      assert allocation_failures(&production/3) == []
    end

    test "negative control: an allocation that drops the residual fails the same test" do
      dropped = fn total, ratios, _placement ->
        sum = Enum.sum(ratios)
        shares = Enum.map(ratios, &div(total * &1, sum))
        {shares, total - Enum.sum(shares)}
      end

      assert allocation_failures(dropped) != []
    end

    test "invalid ratios and placements" do
      a = amount!("EUR", 100)

      for bad <- [[], [0, 0], [-1, 2], [1.0, 1], [1 | 2], "1", nil, List.duplicate(1, 1001)],
          do: assert({:error, {:invalid_ratios, _}} = M.allocate(a, bad, :first), inspect(bad))

      assert {:ok, _} = M.allocate(a, List.duplicate(1, 1000), :first)

      for bad <- [:middle, :half_odd, "first", nil, 1],
          do: assert(M.allocate(a, [1, 1], bad) == {:error, {:unknown_placement, bad}})
    end
  end

  describe "arithmetic" do
    test "same-currency add, subtract, compare and negate" do
      a = amount!("EUR", 150)
      b = amount!("EUR", -50)
      assert {:ok, %Amount{minor_units: 100}} = M.add(a, b)
      assert {:ok, %Amount{minor_units: 200}} = M.subtract(a, b)
      assert M.compare(a, b) == {:ok, :gt}
      assert M.compare(b, a) == {:ok, :lt}
      assert M.compare(a, a) == {:ok, :eq}
      assert {:ok, %Amount{minor_units: -150} = n} = M.negate(a)
      assert n.currency == a.currency
    end

    test "mixed-currency arithmetic is a typed rejection naming both currencies" do
      eur = amount!("EUR", 100)
      usd = amount!("USD", 100)
      expected = {:error, {:currency_mismatch, %{left: "EUR", right: "USD"}}}
      assert M.add(eur, usd) == expected
      assert M.subtract(eur, usd) == expected
      assert M.compare(eur, usd) == expected
      assert M.add(usd, eur) == {:error, {:currency_mismatch, %{left: "USD", right: "EUR"}}}
    end

    # C9 boundary fixture (test-only; not domain/journal): an account holds a
    # balance in one currency and refuses a charge in another.
    defp post_charge(account, charge) do
      case M.add(account.balance, charge) do
        {:ok, balance} -> {:ok, %{account | balance: balance}}
        {:error, _} = error -> {error, account}
      end
    end

    test "a charge in one currency cannot post into an account of another" do
      account = %{id: "acct-1", balance: amount!("JPY", 5000)}
      charge = amount!("BHD", 1234)

      assert {{:error, {:currency_mismatch, %{left: "JPY", right: "BHD"}}}, ^account} =
               post_charge(account, charge)

      assert {:ok, %{balance: %Amount{minor_units: 6000}}} =
               post_charge(account, amount!("JPY", 1000))
    end
  end

  describe "construction and decimal boundary" do
    test "minor units scale by the registry exponent, never a fixed hundredth" do
      for {code, text, minor, back} <- [
            {"JPY", "1000", 1000, "1000"},
            {"BHD", "1.234", 1234, "1.234"},
            {"EUR", "1.00", 100, "1.00"},
            {"EUR", "1.0", 100, "1.00"},
            {"EUR", "-0.05", -5, "-0.05"},
            {"CLF", "1.2345", 12345, "1.2345"},
            {"UYW", "0.0001", 1, "0.0001"},
            {"JPY", "0", 0, "0"}
          ] do
        assert {:ok, %Amount{minor_units: ^minor} = a} =
                 M.from_decimal_string(currency!(code), text)

        assert M.to_decimal_string(a) == {:ok, back}
      end

      refute M.to_decimal_string(amount!("JPY", 1000)) |> elem(1) |> String.contains?(".")
    end

    test "finer scale is scale_overflow; malformed strings are malformed_amount" do
      assert M.from_decimal_string(currency!("BHD"), "1.2345") ==
               {:error, {:scale_overflow, %{alpha: "BHD", exponent: 3, scale: 4}}}

      assert M.from_decimal_string(currency!("EUR"), "1.005") ==
               {:error, {:scale_overflow, %{alpha: "EUR", exponent: 2, scale: 3}}}

      assert {:error, {:scale_overflow, _}} = M.from_decimal_string(currency!("JPY"), "1.5")

      for bad <- [
            "1e3",
            "+1",
            " 1",
            "1 ",
            "1,00",
            "",
            "NaN",
            "Infinity",
            ".5",
            "1.",
            "01",
            "--1",
            "١",
            1.5,
            100,
            nil
          ],
          do:
            assert(
              M.from_decimal_string(currency!("EUR"), bad) == {:error, {:malformed_amount, bad}},
              inspect(bad)
            )
    end

    test "35 to 38 significant digits convert exactly; 39 are rejected" do
      eur = currency!("EUR")

      for n <- 35..38 do
        text = String.duplicate("9", n - 2) <> ".99"
        assert {:ok, a} = M.from_decimal_string(eur, text)
        assert a.minor_units == String.to_integer(String.duplicate("9", n))
        assert M.to_decimal_string(a) == {:ok, text}
        assert {:ok, d} = M.to_decimal(a)
        assert M.from_decimal(eur, d, :down) == {:ok, a}
      end

      assert {:error, {:malformed_amount, _}} =
               M.from_decimal_string(eur, String.duplicate("9", 37) <> ".99")
    end

    test "from_decimal rounds a sub-minor-unit value with every declared mode" do
      eur = currency!("EUR")
      rate_total = Decimal.new(1, 861, -4)

      for {mode, minor} <- [
            down: 8,
            up: 9,
            half_up: 9,
            half_down: 9,
            half_even: 9,
            ceiling: 9,
            floor: 8
          ],
          do: assert({:ok, %Amount{minor_units: ^minor}} = M.from_decimal(eur, rate_total, mode))

      negative = Decimal.new(-1, 1005, -3)

      for {mode, minor} <- [
            down: -100,
            up: -101,
            half_up: -101,
            half_down: -100,
            half_even: -100,
            ceiling: -100,
            floor: -101
          ],
          do:
            assert(
              {:ok, %Amount{minor_units: ^minor}} = M.from_decimal(eur, negative, mode),
              "#{mode}"
            )

      assert {:ok, %Amount{minor_units: 1_230_000}} =
               M.from_decimal(eur, Decimal.new(1, 123, 2), :down)
    end

    test "the caller's Decimal context does not change any result" do
      eur = currency!("EUR")
      big = Decimal.new(1, String.to_integer(String.duplicate("7", 38)), -4)

      inputs = [
        {big, :half_even},
        {Decimal.new(1, 861, -4), :half_down},
        {Decimal.new(-1, 1005, -3), :half_up}
      ]

      default = Enum.map(inputs, fn {d, m} -> M.from_decimal(eur, d, m) end)

      narrow =
        Decimal.Context.with(%Decimal.Context{precision: 5, rounding: :half_down}, fn ->
          Enum.map(inputs, fn {d, m} -> M.from_decimal(eur, d, m) end)
        end)

      assert narrow == default
      assert {:ok, %Amount{minor_units: m}} = hd(default)
      assert m == div(String.to_integer(String.duplicate("7", 38)) + 50, 100)
    end

    test "malformed Decimal structs and inputs are malformed_amount" do
      eur = currency!("EUR")

      for bad <- [
            %Decimal{sign: 0, coef: 1, exp: 0},
            %Decimal{sign: 1, coef: -1, exp: 0},
            %Decimal{sign: 1, coef: 1.5, exp: 0},
            %Decimal{sign: 1, coef: 1, exp: 0.5},
            %Decimal{sign: 1, coef: :NaN, exp: 0},
            %Decimal{sign: 1, coef: :inf, exp: 0},
            %Decimal{sign: 1, coef: 1, exp: 39},
            %Decimal{sign: 1, coef: Integer.pow(10, 38), exp: 0},
            1.5,
            "1.00",
            %{sign: 1, coef: 1, exp: 0}
          ],
          do:
            assert({:error, {:malformed_amount, _}} = M.from_decimal(eur, bad, :down), inspect(bad))

      assert {:error, {:malformed_amount, %{magnitude: _}}} =
               M.from_decimal(eur, %Decimal{sign: 1, coef: 1, exp: 38}, :down)
    end

    test "rounding at a declared scale with every mode" do
      eur = currency!("EUR")

      table = [
        {1050, 0,
         [
           down: 1000,
           up: 1100,
           half_up: 1100,
           half_down: 1000,
           half_even: 1000,
           ceiling: 1100,
           floor: 1000
         ]},
        {-1050, 0,
         [
           down: -1000,
           up: -1100,
           half_up: -1100,
           half_down: -1000,
           half_even: -1000,
           ceiling: -1000,
           floor: -1100
         ]},
        {1150, 0, [half_even: 1200, half_down: 1100]},
        {1051, 0, [half_down: 1100, down: 1000]},
        {1005, 1, [half_even: 1000, half_up: 1010, down: 1000, up: 1010]},
        {1005, 2, [down: 1005, up: 1005]}
      ]

      for {minor, scale, modes} <- table, {mode, expected} <- modes do
        {:ok, a} = M.from_minor_units(eur, minor)

        assert {:ok, %Amount{minor_units: ^expected}} = M.round(a, scale, mode),
               "#{minor} #{scale} #{mode}"
      end

      jpy = amount!("JPY", 1250)
      assert {:ok, %Amount{minor_units: 1200}} = M.round(jpy, -2, :half_even)
      assert {:ok, %Amount{minor_units: 1300}} = M.round(jpy, -2, :half_up)

      a = amount!("EUR", 1005)

      assert M.round(a, 3, :down) ==
               {:error, {:scale_overflow, %{alpha: "EUR", exponent: 2, scale: 3}}}

      assert {:error, {:scale_overflow, _}} = M.round(a, -19, :down)
      assert {:ok, _} = M.round(a, -18, :down)
      assert M.round(a, 1.0, :down) == {:error, {:malformed_amount, 1.0}}

      for bad <- [:half_odd, "half_up", nil],
          do: assert(M.round(a, 0, bad) == {:error, {:unknown_rounding_mode, bad}})

      assert M.from_decimal(eur, Decimal.new(1, 1, 0), :middle) ==
               {:error, {:unknown_rounding_mode, :middle}}

      assert M.rounding_modes() == [:down, :half_up, :half_even, :ceiling, :floor, :half_down, :up]
    end

    test "floats and wrong types are never coerced at any public function" do
      eur = currency!("EUR")
      a = amount!("EUR", 100)
      assert M.from_minor_units(eur, 1.0) == {:error, {:malformed_amount, 1.0}}
      assert M.from_minor_units(eur, "100") == {:error, {:malformed_amount, "100"}}
      float_amount = %Amount{currency: eur, minor_units: 1.0}

      for result <- [
            M.add(a, float_amount),
            M.subtract(float_amount, a),
            M.compare(a, float_amount),
            M.negate(float_amount),
            M.allocate(float_amount, [1], :first),
            M.round(float_amount, 0, :down),
            M.to_decimal(float_amount),
            M.to_decimal_string(float_amount),
            Elzoo.Money.Codec.encode(float_amount)
          ],
          do: assert({:error, {:malformed_amount, ^float_amount}} = result)

      assert M.add(a, 1.5) == {:error, {:malformed_amount, 1.5}}
    end

    test "per-call options: an unknown registry version is rejected" do
      assert M.parse("EUR", version: "1999-01-01") ==
               {:error, {:unknown_registry_version, "1999-01-01"}}

      assert M.parse_numeric("978", version: nil) == {:error, {:unknown_registry_version, nil}}
    end
  end

  describe "fixed-hundredth and Float negative controls" do
    # Wrong implementations, run through the scaling assertion used above.
    defp scaling_failures(from_string) do
      for {code, text, minor} <- [
            {"JPY", "1000", 1000},
            {"BHD", "1.234", 1234},
            {"EUR", "1.00", 100}
          ],
          from_string.(code, text) != {:ok, minor},
          do: code
    end

    test "the production scaling passes; a fixed hundredth fails JPY and BHD" do
      production = fn code, text ->
        with {:ok, a} <- M.from_decimal_string(currency!(code), text), do: {:ok, a.minor_units}
      end

      hundredth = fn _code, text ->
        {:ok,
         Decimal.new(text) |> Decimal.mult(100) |> Decimal.round(0, :down) |> Decimal.to_integer()}
      end

      assert scaling_failures(production) == []
      assert scaling_failures(hundredth) == ["JPY", "BHD"]
    end

    test "a Float path is caught: Float input is rejected and Float math loses minor units" do
      float_path = fn _currency, text -> {:ok, trunc(String.to_float(text) * 100)} end
      assert float_path.(:eur, "1.15") == {:ok, 114}

      assert M.from_decimal_string(currency!("EUR"), "1.15") |> elem(1) |> Map.get(:minor_units) ==
               115

      assert M.from_minor_units(currency!("EUR"), 1.15) == {:error, {:malformed_amount, 1.15}}
    end
  end
end
