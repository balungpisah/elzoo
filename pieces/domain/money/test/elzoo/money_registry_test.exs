# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.MoneyRegistryTest do
  use ExUnit.Case, async: true
  alias Elzoo.Money, as: M
  alias Elzoo.Money.{Amount, Codec, Currency, Registry}
  alias Elzoo.Money.Registry.Source

  @extract_path Path.expand("../../lib/elzoo/money/iso4217/2026-09-17.tsv", __DIR__)
  @extract File.read!(@extract_path)
  @v1 "2026-09-17"
  @v2 "2027-01-01"

  # Independent reading of the extract (not the registry's loader).
  defp rows(text) do
    for line <- String.split(text, "\n", trim: true), not String.starts_with?(line, "#") do
      [table, alpha, numeric, minor, withdrawal, fund] = String.split(line, "\t")

      %{
        table: table,
        alpha: alpha,
        numeric: numeric,
        minor: minor,
        withdrawal: withdrawal,
        fund: fund
      }
    end
  end

  defp header(text) do
    for "# " <> line <- String.split(text, "\n"),
        [k, v] <- [String.split(line, "\t", parts: 2)],
        into: %{},
        do: {k, v}
  end

  describe "dated extract" do
    test "the header records sources, publication dates, download date and SHA-256" do
      h = header(@extract)
      assert h["version"] == @v1 and h["current_published"] == @v1
      assert h["historic_published"] == "2026-01-01"
      assert h["downloaded"] == "2026-11-08"

      assert h["current_sha256"] ==
               "33139b438657d1cee116ba737807ea71d19d6de4b90f799a09c56f0cc6a1b0ff"

      assert h["historic_sha256"] ==
               "98fde2423cdb916dd59dcf5fe96222edad8fa198d865c1c83dbc464b9cc52387"

      assert h["current_source"] =~ ~r{^https://www\.six-group\.com/.+/list-one\.xml$}
      assert h["historic_source"] =~ ~r{^https://www\.six-group\.com/.+/list-three\.xml$}
      assert Registry.default().versions == [@v1]
    end

    test "row counts match the pinned sources" do
      rows = rows(@extract)
      current = Enum.filter(rows, &(&1.table == "current"))
      historic = Enum.filter(rows, &(&1.table == "historic"))
      assert {length(current), length(historic)} == {280, 169}

      assert current
             |> Enum.reject(&(&1.alpha == ""))
             |> Enum.map(& &1.alpha)
             |> Enum.uniq()
             |> length() == 178

      assert historic |> Enum.map(& &1.alpha) |> Enum.uniq() |> length() == 137
      snapshot = Registry.default().snapshots[@v1]
      assert map_size(snapshot) == 307
      assert Enum.count(snapshot, fn {_, e} -> e.status == :active end) == 178
    end
  end

  describe "dataset law, both directions" do
    test "every currency-bearing current row resolves by alpha and numeric to the same canonical value" do
      for %{table: "current", alpha: alpha} = row <- rows(@extract), alpha != "" do
        minor = if row.minor == "N.A.", do: :not_applicable, else: String.to_integer(row.minor)
        numeric = String.to_integer(row.numeric)
        assert {:ok, by_alpha} = M.parse(alpha)
        assert {:ok, by_numeric} = M.parse_numeric(row.numeric)
        assert by_alpha == by_numeric, alpha

        assert %Currency{alpha: ^alpha, numeric: ^numeric, minor_unit: ^minor, status: :active} =
                 by_alpha

        assert {:ok, ^by_alpha} = M.parse(String.downcase(alpha))
      end
    end

    test "each other current row contains no alpha, numeric or minor unit" do
      empty = for %{table: "current", alpha: ""} = row <- rows(@extract), do: row
      assert length(empty) == 3
      for row <- empty, do: assert({row.numeric, row.minor, row.withdrawal} == {"", "", ""})
    end

    test "every historic row is retained and resolves by alpha with its numeric code or absence" do
      registry = Registry.default()

      for %{table: "historic"} = row <- rows(@extract) do
        assert {:ok, c} = M.parse(row.alpha)
        entry = Registry.entry(registry, @v1, row.alpha)
        numeric = if row.numeric == "", do: nil, else: String.to_integer(row.numeric)

        assert Enum.any?(
                 entry.rows,
                 &(&1.table == :historic and &1.numeric == numeric and
                     &1.withdrawal == row.withdrawal)
               ),
               "#{row.alpha} lacks its historic row"

        case c.status do
          :active ->
            assert numeric == c.numeric

          {:retired, latest} ->
            assert c.numeric == numeric
            assert c.minor_unit == :not_recorded
            assert latest in Enum.map(entry.rows, & &1.withdrawal)
        end

        if numeric do
          assert {:ok, candidates} = M.numeric_candidates(row.numeric)
          assert Enum.any?(candidates, &(&1.alpha == row.alpha))
        end
      end
    end

    test "every registry entry is represented by a source row" do
      rows = rows(@extract)

      for {alpha, entry} <- Registry.default().snapshots[@v1] do
        table = if entry.status == :active, do: "current", else: "historic"
        assert Enum.any?(rows, &(&1.table == table and &1.alpha == alpha)), alpha
        refute entry.retained
      end
    end

    test "N.A., missing numeric, reused numeric codes and retired codes are explicit" do
      for code <- ~w(XAU XXX XTS XDR) do
        assert {:ok, %Currency{minor_unit: :not_applicable, status: :active} = c} = M.parse(code)
        assert M.from_minor_units(c, 1) == {:error, {:no_minor_unit, code}}
      end

      for code <- ~w(XFO XFU XRE),
          do: assert({:ok, %Currency{numeric: nil, minor_unit: :not_recorded}} = M.parse(code))

      assert {:ok,
              %Currency{status: {:retired, "2023-01"}, numeric: 191, minor_unit: :not_recorded} =
                hrk} =
               M.parse("HRK")

      assert M.from_minor_units(hrk, 100) == {:error, {:retired_currency, "HRK"}}
      assert {:ok, %Currency{status: {:retired, "1985-07"}}} = M.parse("ARP")
      assert {:ok, %Currency{status: {:retired, "1989 to 1990"}}} = M.parse("ARY")
      assert {:ok, %Currency{status: {:retired, "1989-1990"}}} = M.parse("VNC")
      assert M.parse_numeric("191") == {:error, {:unknown_currency, "191"}}

      assert M.numeric_candidates("191") ==
               {:ok, [%{alpha: "HRD", versions: [@v1]}, %{alpha: "HRK", versions: [@v1]}]}

      assert {:ok, peru} = M.numeric_candidates("604")
      assert Enum.map(peru, & &1.alpha) == ~w(PEH PEI PEN PES)
      assert {:ok, %Currency{alpha: "PEN"}} = M.parse_numeric("604")
    end

    test "parse distinguishes malformed from unknown" do
      for bad <- [" EUR", "EUR ", "EU", "EURO", "E$R", "", "€UR", "eu1", nil, :EUR, 978],
          do: assert(M.parse(bad) == {:error, {:malformed_code, bad}}, inspect(bad))

      assert M.parse("XYZ") == {:error, {:unknown_currency, "XYZ"}}
      assert M.parse("qqq") == {:error, {:unknown_currency, "QQQ"}}

      for bad <- ["97", "9780", " 978", "97a", 978, nil],
          do: assert(M.parse_numeric(bad) == {:error, {:malformed_code, bad}})

      assert M.parse_numeric("000") == {:error, {:unknown_currency, "000"}}
      assert {:ok, %Currency{alpha: "XXX", minor_unit: :not_applicable}} = M.parse_numeric("999")
    end
  end

  # A synthetic next version: EUR leaves the current list, ISK changes its
  # exponent, XQQ takes the retired numeric code 191, FIM is absent from both.
  defp next_version do
    lines = String.split(@extract, "\n")

    lines =
      for line <- lines,
          not String.starts_with?(line, "current\tEUR\t"),
          not String.starts_with?(line, "historic\tFIM\t") do
        line
        |> String.replace("# version\t#{@v1}", "# version\t#{@v2}")
        |> String.replace("# current_published\t#{@v1}", "# current_published\t#{@v2}")
        |> String.replace("current\tISK\t352\t0\t", "current\tISK\t352\t2\t")
      end

    lines
    |> List.insert_at(13, "current\tXQQ\t191\t2\t\tfalse")
    |> Enum.join("\n")
  end

  defp folded, do: Registry.build!([next_version(), @extract])

  describe "update rule (synthetic next version)" do
    test "previously admitted codes are retained with their identity and exponent" do
      r = folded()
      assert r.versions == [@v1, @v2]
      assert {:ok, eur2} = M.parse("EUR", registry: r)

      assert %Currency{minor_unit: 2, numeric: 978, status: {:retired, :not_recorded}, version: @v2} =
               eur2

      assert {:ok, %Amount{minor_units: 100}} = M.from_minor_units(eur2, 100, registry: r)

      assert {:ok, %Currency{status: {:retired, "2002-03"}}} = M.parse("FIM", registry: r)
      assert Registry.entry(r, @v2, "FIM").retained
      assert Map.keys(r.snapshots[@v1]) -- Map.keys(r.snapshots[@v2]) == []
    end

    test "old bytes decode to their original identity and version status after the update" do
      r = folded()
      {:ok, eur1} = M.parse("EUR", version: @v1, registry: r)
      {:ok, amount} = M.from_minor_units(eur1, 12345, registry: r)
      {:ok, bytes} = Codec.encode(amount, registry: r)
      assert bytes == "elzoo-money/1 2026-09-17 EUR 978 2 12345"
      assert Codec.decode(bytes, registry: r) == {:ok, amount}
      assert Codec.decode(bytes) == {:ok, amount}
      assert M.current_status(eur1, registry: r) == {:ok, {:retired, :not_recorded}}

      {:ok, isk1} = M.parse("ISK", version: @v1, registry: r)
      {:ok, isk2} = M.parse("ISK", version: @v2, registry: r)
      assert {isk1.minor_unit, isk2.minor_unit} == {0, 2}
      {:ok, old} = M.from_minor_units(isk1, 500, registry: r)
      {:ok, new} = M.from_minor_units(isk2, 500, registry: r)
      {:ok, old_bytes} = Codec.encode(old, registry: r)
      assert Codec.decode(old_bytes, registry: r) == {:ok, old}
      assert M.to_decimal_string(old, registry: r) == {:ok, "500"}
      assert M.to_decimal_string(new, registry: r) == {:ok, "5.00"}

      assert M.add(old, new, registry: r) ==
               {:error, {:currency_mismatch, %{left: "ISK", right: "ISK"}}}

      {:ok, eur2} = M.parse("EUR", registry: r)
      {:ok, later} = M.from_minor_units(eur2, 5, registry: r)
      assert {:ok, %Amount{minor_units: 12350}} = M.add(amount, later, registry: r)
    end

    test "a newly retired code takes its withdrawal only from new historic rows" do
      r = folded()
      # EUR's only historic row (a country-level withdrawal) was already held
      # while EUR was active; it is not the code's retirement date.
      assert Registry.entry(r, @v1, "EUR").status == :active
      assert {:ok, %Currency{status: {:retired, :not_recorded}}} = M.parse("EUR", registry: r)

      with_row =
        next_version() <> "\nhistoric\tEUR\t978\t\t2026-12\tfalse\n"

      r2 = Registry.build!([with_row, @extract])
      assert {:ok, %Currency{status: {:retired, "2026-12"}}} = M.parse("EUR", registry: r2)
      # A code already retired keeps the latest of all its rows.
      assert {:ok, %Currency{status: {:retired, "2023-01"}}} = M.parse("HRK", registry: r2)
    end

    test "an explicit version option is validated by every value function" do
      r = folded()
      {:ok, eur1} = M.parse("EUR", version: @v1, registry: r)
      {:ok, amount} = M.from_minor_units(eur1, 100, registry: r)
      {:ok, bytes} = Codec.encode(amount, registry: r)
      unheld = [registry: r, version: "2030-01-01"]
      other = [registry: r, version: @v2]
      same = [registry: r, version: @v1]

      for opts <- [unheld, [registry: r, version: nil]] do
        expected = {:error, {:unknown_registry_version, Keyword.fetch!(opts, :version)}}
        assert M.from_minor_units(eur1, 100, opts) == expected
        assert M.from_decimal_string(eur1, "1.00", opts) == expected
        assert M.from_decimal(eur1, Decimal.new(1, 1, 0), :down, opts) == expected
        assert M.add(amount, amount, opts) == expected
        assert M.subtract(amount, amount, opts) == expected
        assert M.compare(amount, amount, opts) == expected
        assert M.negate(amount, opts) == expected
        assert M.allocate(amount, [1, 1], :first, opts) == expected
        assert M.round(amount, 0, :down, opts) == expected
        assert M.to_decimal(amount, opts) == expected
        assert M.to_decimal_string(amount, opts) == expected
        assert M.current_status(eur1, opts) == expected
        assert M.numeric_candidates("978", opts) == expected
        assert Codec.encode(amount, opts) == expected
        assert Codec.decode(bytes, opts) == expected
      end

      forged = {:error, {:forged_currency, eur1}}
      assert M.from_minor_units(eur1, 100, other) == forged
      assert M.add(amount, amount, other) == forged
      assert M.allocate(amount, [1, 1], :first, other) == forged
      assert M.round(amount, 0, :down, other) == forged
      assert M.to_decimal_string(amount, other) == forged
      assert M.current_status(eur1, other) == forged
      assert Codec.encode(amount, other) == forged
      assert {:error, {:forged_currency, %{version: @v1}}} = Codec.decode(bytes, other)

      assert {:ok, %Amount{minor_units: 200}} = M.add(amount, amount, same)
      assert Codec.decode(bytes, same) == {:ok, amount}
      assert {:ok, ^bytes} = Codec.encode(amount, same)

      assert M.numeric_candidates("191", registry: r, version: @v1) ==
               {:ok, [%{alpha: "HRD", versions: [@v1]}, %{alpha: "HRK", versions: [@v1]}]}
    end

    test "version-qualified active lookup distinguishes reused numeric codes" do
      r = folded()
      assert {:ok, %Currency{alpha: "XQQ"}} = M.parse_numeric("191", version: @v2, registry: r)

      assert M.parse_numeric("191", version: @v1, registry: r) ==
               {:error, {:unknown_currency, "191"}}

      assert M.numeric_candidates("191", registry: r) ==
               {:ok,
                [
                  %{alpha: "HRD", versions: [@v1, @v2]},
                  %{alpha: "HRK", versions: [@v1, @v2]},
                  %{alpha: "XQQ", versions: [@v2]}
                ]}
    end

    test "negative control: a fold that deletes is caught by the retention check" do
      retains? = fn r ->
        Map.keys(r.snapshots[@v1]) -- Map.keys(r.snapshots[List.last(r.versions)]) == []
      end

      deleting = Registry.build!([next_version()])

      deleting = %{
        deleting
        | snapshots: Map.put(deleting.snapshots, @v1, Registry.default().snapshots[@v1]),
          versions: [@v1, @v2]
      }

      assert retains?.(folded())
      refute retains?.(deleting)
    end

    test "build rejects duplicate versions, disagreeing rows and repeated active numerics" do
      assert_raise ArgumentError, ~r/duplicate extract version/, fn ->
        Registry.build!([@extract, @extract])
      end

      disagree =
        String.replace(
          @extract,
          "current\tEUR\t978\t2\t\tfalse\ncurrent\tALL",
          "current\tEUR\t978\t3\t\tfalse\ncurrent\tALL"
        )

      assert disagree != @extract
      assert_raise ArgumentError, ~r/rows of EUR disagree/, fn -> Registry.build!([disagree]) end

      repeat = @extract <> "current\tXQQ\t978\t2\t\tfalse\n"

      assert_raise ArgumentError, ~r/active numeric codes repeat/, fn ->
        Registry.build!([repeat])
      end

      assert_raise ArgumentError, ~r/lacks current_sha256/, fn ->
        @extract
        |> String.replace(~r/# current_sha256\t[0-9a-f]+\n/, "")
        |> then(&Registry.build!([&1]))
      end
    end
  end

  describe "version-specific membership and forgery" do
    test "values not in effect at their stated version are forged_currency" do
      r = folded()
      {:ok, xqq2} = M.parse("XQQ", registry: r)
      {:ok, isk1} = M.parse("ISK", version: @v1, registry: r)
      {:ok, isk2} = M.parse("ISK", version: @v2, registry: r)
      {:ok, eur1} = M.parse("EUR", version: @v1, registry: r)
      {:ok, eur2} = M.parse("EUR", version: @v2, registry: r)

      forged = [
        %{xqq2 | version: @v1},
        %{isk2 | version: @v1},
        %{isk1 | version: @v2},
        %{eur2 | status: :active},
        %{eur1 | status: {:retired, :not_recorded}},
        %{eur1 | numeric: 999},
        %{eur1 | minor_unit: 3},
        %{eur1 | alpha: "USD"}
      ]

      for c <- forged do
        assert M.from_minor_units(c, 1, registry: r) == {:error, {:forged_currency, c}}, inspect(c)
        assert M.current_status(c, registry: r) == {:error, {:forged_currency, c}}
      end

      assert M.from_minor_units(%{eur1 | version: "2030-01-01"}, 1, registry: r) ==
               {:error, {:unknown_registry_version, "2030-01-01"}}

      for other <- ["EUR", :EUR, {:MoneyCurrency, {:String, ~c"EUR"}, 978, 2}, %{alpha: "EUR"}],
          do: assert(M.from_minor_units(other, 1) == {:error, {:forged_currency, other}})

      {:ok, good} = M.from_minor_units(eur1, 1, registry: r)
      hand_built = %Amount{currency: %{eur1 | minor_unit: 0}, minor_units: 1}
      assert {:error, {:forged_currency, _}} = M.add(good, hand_built, registry: r)
      assert {:error, {:forged_currency, _}} = Codec.encode(hand_built, registry: r)
    end

    test "decode refuses identities from another version, unknown versions and non-canonical bytes" do
      r = folded()

      assert {:error, {:forged_currency, _}} =
               Codec.decode("elzoo-money/1 2026-09-17 XQQ 191 2 100", registry: r)

      assert {:error, {:forged_currency, _}} =
               Codec.decode("elzoo-money/1 2026-09-17 ISK 352 2 100", registry: r)

      assert {:error, {:forged_currency, _}} =
               Codec.decode("elzoo-money/1 2027-01-01 ISK 352 0 100", registry: r)

      assert {:error, {:forged_currency, _}} =
               Codec.decode("elzoo-money/1 2026-09-17 EUR 978 3 100")

      assert {:error, {:forged_currency, _}} =
               Codec.decode("elzoo-money/1 2026-09-17 HRK 191 2 100")

      assert Codec.decode("elzoo-money/1 2030-01-01 EUR 978 2 1") ==
               {:error, {:unknown_registry_version, "2030-01-01"}}

      assert Codec.decode("elzoo-money/1 2026-09-17 QQQ 001 2 1") ==
               {:error, {:unknown_currency, "QQQ"}}

      for bad <- [
            "elzoo-money/1 2026-09-17 EUR 978 2 -0",
            "elzoo-money/1 2026-09-17 EUR 978 2 007",
            "elzoo-money/1 2026-09-17 EUR 978 2 +7",
            "elzoo-money/1 2026-09-17 EUR 978 2 1.5",
            "elzoo-money/1 2026-09-17 eur 978 2 1",
            "elzoo-money/1 2026-09-17 EUR 978 02 1",
            "elzoo-money/1  2026-09-17 EUR 978 2 1",
            "elzoo-money/1 2026-09-17 EUR 978 2 1 ",
            "elzoo-money/2 2026-09-17 EUR 978 2 1",
            "elzoo-money/1 2026-09-17 EUR 978 2 " <> String.duplicate("9", 120),
            :bytes,
            nil
          ],
          do: assert(Codec.decode(bad) == {:error, {:malformed_amount, bad}}, inspect(bad))
    end

    test "codec round trip for JPY, BHD, EUR, CLF and negative amounts" do
      for {code, minor, text} <- [
            {"JPY", 1000, "1000"},
            {"BHD", 1234, "1.234"},
            {"EUR", -5, "-0.05"},
            {"CLF", 12345, "1.2345"}
          ] do
        {:ok, c} = M.parse(code)
        {:ok, a} = M.from_minor_units(c, minor)
        assert {:ok, bytes} = Codec.encode(a)

        assert bytes ==
                 "elzoo-money/1 #{@v1} #{code} #{String.pad_leading(Integer.to_string(c.numeric), 3, "0")} #{c.minor_unit} #{minor}"

        assert Codec.decode(bytes) == {:ok, a}
        assert M.to_decimal_string(a) == {:ok, text}
      end
    end
  end

  test "Source.latest_withdrawal keeps the verbatim text of the latest date" do
    rows =
      for w <- ["1989 to 1990", "1990-07 to 1990-09", "1989-1990", "1978 to 1981"],
          do: %{withdrawal: w}

    assert Source.latest_withdrawal(rows) == "1990-07 to 1990-09"
  end
end
