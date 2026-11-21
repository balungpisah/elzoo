# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Pricing do
  @moduledoc """
  Exact charges from the usage totals of one tenant and period under one
  immutable rate-card version (ELZ-304).

  `price/3` builds each card line's exact value `quantity × rate ÷ per` in
  integer arithmetic and rounds it once through `Elzoo.Money.from_decimal/4`
  with the card's rounding mode; the Cure module `Cure.Elzoo.Pricing` decides
  the minimum and completeness. `difference/3` compares two charges of one card
  version. `content_hash/1` is the SHA-256 of the README's canonical card
  encoding. No I/O, clock, storage, journal post, exchange rate or Float.

  Errors are `{:error, reason}` with a fixed atom that never echoes an ID or
  amount. See the bundle README.
  """

  alias Elzoo.AiModel.Usage
  alias Elzoo.Money
  alias Elzoo.Money.{Amount, Currency, Registry}

  @cure :"Cure.Elzoo.Pricing"
  @card_keys [:card_id, :content_hash, :currency, :kind, :lines, :rounding, :version]
  @line_keys [:minimum, :model_id, :per, :provider_id, :rate, :unit]
  @usage_keys [:period, :rows, :tenant]
  @row_keys [:count, :known, :model_id, :provider_id, :source, :unit, :unknown_count]
  @charge_keys [:card, :incomplete, :lines, :period, :tenant, :total, :unknown_count]
  @identity_keys [:card_id, :content_hash, :kind, :version]
  @charged_keys [
    :charge,
    :count,
    :model_id,
    :provider_id,
    :quantity,
    :sources,
    :unit,
    :unknown_count
  ]
  @kinds [:cost, :price]
  @sources [:estimated, :provider_reported, :unknown]
  @pers for e <- 0..9, do: Integer.pow(10, e)
  @max_lines 1024
  @max_rows 4096
  @max_version 2_147_483_647
  @bound Integer.pow(10, 38)

  @doc """
  `{:ok, hash}`, the 32-byte SHA-256 of the canonical encoding of the card (a
  `content_hash` key is ignored), or `{:error, :card}`.
  """
  def content_hash(card) when is_map(card) and not is_struct(card) do
    body = Map.delete(card, :content_hash)
    if body?(body), do: {:ok, hash(body)}, else: {:error, :card}
  end

  def content_hash(_card), do: {:error, :card}

  @doc "Prices `usage` under `card`: `{:ok, charge}` or `{:error, reason}`."
  def price(card, usage, opts \\ []) do
    with {:ok, registry} <- registry(opts),
         {:ok, minimums} <- card(card, registry),
         true <-
           card.content_hash == hash(Map.delete(card, :content_hash)) || {:error, :content_hash},
         true <- usage?(usage) || {:error, :usage},
         index = Map.new(card.lines, &{key(&1), &1}),
         true <- Enum.all?(usage.rows, &Map.has_key?(index, key(&1))) || {:error, :unpriced_unit},
         {:ok, lines} <- lines(card, minimums, Enum.group_by(usage.rows, &key/1), registry),
         {:ok, total} <- total(card.currency, lines, registry) do
      unknown = Enum.map(lines, & &1.unknown_count)

      {:ok,
       %{
         tenant: usage.tenant,
         period: usage.period,
         card: Map.take(card, @identity_keys),
         lines: lines,
         total: total,
         incomplete: not apply(@cure, :complete, [unknown]),
         unknown_count: Enum.sum(unknown)
       }}
    end
  end

  @doc """
  `{:ok, later.total − earlier.total}` for two charges of the same tenant,
  period and card version, else `{:error, :card_mismatch}`; a malformed charge
  is `{:error, :charge}`.
  """
  def difference(earlier, later, opts \\ []) do
    with {:ok, registry} <- registry(opts),
         true <- (charge?(earlier, registry) and charge?(later, registry)) || {:error, :charge},
         true <-
           (earlier.tenant == later.tenant and earlier.period == later.period and
              earlier.card == later.card and identity(earlier) == identity(later)) ||
             {:error, :card_mismatch} do
      Money.subtract(later.total, %{earlier.total | currency: later.total.currency},
        registry: registry
      )
    end
  end

  # The currency identity that the content hash encodes; registry version and
  # status may differ between two charges of one card.
  defp identity(charge), do: Map.take(charge.total.currency, [:alpha, :numeric, :minor_unit])

  # ---------------------------------------------------------------- charges

  # Card lines in their order; a line with no row is absent (Cure decides).
  defp lines(card, minimums, rows_by_key, registry) do
    Enum.reduce_while(card.lines, {:ok, []}, fn line, {:ok, acc} ->
      rows = Map.get(rows_by_key, key(line), [])
      quantity = Enum.sum(Enum.map(rows, & &1.known))
      minimum = Map.fetch!(minimums, key(line))

      with {:ok, rounded} <- rounded(card, line, quantity, registry) do
        case apply(@cure, :line, [rows != [], minimum != nil, rounded, minimum || 0]) do
          :LineAbsent ->
            {:cont, {:ok, acc}}

          {:LineCharged, units} ->
            {:cont,
             {:ok,
              [
                %{
                  provider_id: line.provider_id,
                  model_id: line.model_id,
                  unit: line.unit,
                  quantity: quantity,
                  unknown_count: Enum.sum(Enum.map(rows, & &1.unknown_count)),
                  count: Enum.sum(Enum.map(rows, & &1.count)),
                  sources: Enum.sort(Enum.map(rows, & &1.source)),
                  charge: %Amount{currency: card.currency, minor_units: units}
                }
                | acc
              ]}}
        end
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # The exact value quantity × rate ÷ per, rounded once to minor units by
  # domain/money: the minor units, or :amount_range.
  defp rounded(card, line, quantity, registry) do
    {coefficient, exponent} = exact(quantity, line.rate, line.per)

    if length(Integer.digits(coefficient)) > 38 or exponent > 38 do
      {:error, :amount_range}
    else
      case Money.from_decimal(
             card.currency,
             Decimal.new(1, coefficient, exponent),
             card.rounding,
             registry: registry
           ) do
        {:ok, amount} -> {:ok, amount.minor_units}
        {:error, {:scale_overflow, _}} -> {:error, :amount_range}
      end
    end
  end

  # rate "I.F" is integer(I <> F) × 10^-|F|; per is 10^k. Trailing zeros of the
  # coefficient move into the exponent; zero is coefficient 0, exponent 0.
  defp exact(quantity, rate, per) do
    {digits, fraction} =
      case String.split(rate, ".") do
        [int] -> {int, ""}
        [int, fraction] -> {int <> fraction, fraction}
      end

    k = length(Integer.digits(per)) - 1
    trim(quantity * String.to_integer(digits), -byte_size(fraction) - k)
  end

  defp trim(0, _exponent), do: {0, 0}
  defp trim(c, exponent) when rem(c, 10) == 0, do: trim(div(c, 10), exponent + 1)
  defp trim(c, exponent), do: {c, exponent}

  defp total(currency, lines, registry) do
    {:ok, zero} = Money.from_minor_units(currency, 0, registry: registry)

    Enum.reduce_while(lines, {:ok, zero}, fn line, {:ok, sum} ->
      case Money.add(sum, line.charge, registry: registry) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, {:scale_overflow, _}} -> {:halt, {:error, :amount_range}}
      end
    end)
  end

  defp key(entry), do: {entry.provider_id, entry.model_id, entry.unit}

  # ---------------------------------------------------------------- canonical encoding

  # README "Content hash": every value is length-prefixed; optional fields are
  # appended only when present.
  defp hash(card), do: :crypto.hash(:sha256, encode(card))

  defp encode(card) do
    c = card.currency

    [
      text("elzoo/pricing/card"),
      field("card_id", text(card.card_id)),
      field("version", int(card.version)),
      field("kind", text(Atom.to_string(card.kind))),
      field(
        "currency",
        text([
          field("alpha", text(c.alpha)),
          field("numeric", int(c.numeric)),
          field("minor_unit", int(c.minor_unit))
        ])
      ),
      field("rounding", text(Atom.to_string(card.rounding))),
      field("lines", list(Enum.map(card.lines, &line/1)))
    ]
  end

  defp line(l) do
    text([
      field("provider_id", text(l.provider_id)),
      field("model_id", text(l.model_id)),
      field("unit", unit(l.unit)),
      field("rate", text(l.rate)),
      field("per", int(l.per)),
      if(l.minimum, do: field("minimum", text(l.minimum)), else: [])
    ])
  end

  defp unit({kind, ttl}), do: list([text(Atom.to_string(kind)), text(ttl)])
  defp unit(kind), do: list([text(Atom.to_string(kind))])

  defp field(key, value), do: [text(key), value]
  defp int(n), do: <<n::64>>
  defp list(items), do: [<<length(items)::32>> | items]

  defp text(iodata) do
    bytes = IO.iodata_to_binary(iodata)
    <<byte_size(bytes)::32, bytes::binary>>
  end

  # ---------------------------------------------------------------- validation

  # One check per call: every money call of the call gets the checked value, so
  # a raw registry is walked once, not once per line.
  defp registry([]), do: {:ok, Registry.default()}

  defp registry(registry: r) do
    case Registry.check(r) do
      {:ok, checked} -> {:ok, checked}
      {:error, _} -> {:error, :invalid}
    end
  end

  defp registry(_opts), do: {:error, :invalid}

  # Shape and bounds, then membership of the currency and each minimum as a
  # domain/money amount: the minimums by line key, or :card.
  defp card(card, registry) do
    with true <- shape?(card, @card_keys),
         true <- is_binary(card.content_hash) and byte_size(card.content_hash) == 32,
         true <- body?(Map.delete(card, :content_hash)),
         :ok <- Money.member(registry, card.currency),
         {:ok, minimums} <- minimums(card, registry) do
      {:ok, minimums}
    else
      _ -> {:error, :card}
    end
  end

  defp minimums(card, registry) do
    Enum.reduce_while(card.lines, {:ok, %{}}, fn
      %{minimum: nil} = line, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, key(line), nil)}}

      line, {:ok, acc} ->
        case Money.from_decimal_string(card.currency, line.minimum, registry: registry) do
          {:ok, amount} -> {:cont, {:ok, Map.put(acc, key(line), amount.minor_units)}}
          {:error, _} -> {:halt, :error}
        end
    end)
  end

  # The card body without registry data: content_hash/1 checks only this.
  defp body?(b) do
    shape?(b, @card_keys -- [:content_hash]) and text?(b.card_id) and version?(b.version) and
      b.kind in @kinds and currency?(b.currency) and b.rounding in Money.rounding_modes() and
      within?(b.lines, @max_lines) and b.lines != [] and
      Enum.all?(b.lines, &line?(&1, b.currency.minor_unit)) and
      ascending?(Enum.map(b.lines, &key/1))
  end

  defp currency?(%Currency{alpha: alpha, numeric: numeric, minor_unit: minor}),
    do:
      is_binary(alpha) and is_integer(numeric) and numeric >= 0 and is_integer(minor) and minor >= 0

  defp currency?(_), do: false

  defp line?(l, minor_unit) do
    shape?(l, @line_keys) and text?(l.provider_id) and text?(l.model_id) and unit?(l.unit) and
      rate?(l.rate) and l.per in @pers and (l.minimum == nil or minimum?(l.minimum, minor_unit))
  end

  # (0|[1-9][0-9]*)(\.[0-9]+)? with at most 18 significant and 18 fractional digits.
  defp rate?(rate) when is_binary(rate) and byte_size(rate) <= 40 do
    case Regex.run(~r/\A(0|[1-9][0-9]*)(?:\.([0-9]+))?\z/, rate) do
      [_, int] -> significant(int) <= 18
      [_, int, fraction] -> byte_size(fraction) <= 18 and significant(int <> fraction) <= 18
      nil -> false
    end
  end

  defp rate?(_), do: false

  # The domain/money decimal-string rule without a sign, and no fraction finer
  # than the minor unit; price/3 then constructs it through domain/money.
  defp minimum?(m, minor_unit) when is_binary(m) and byte_size(m) <= 40 do
    case Regex.run(~r/\A(0|[1-9][0-9]*)(?:\.([0-9]+))?\z/, m) do
      [_, int] -> significant(int) <= 38
      [_, int, fraction] -> byte_size(fraction) <= minor_unit and significant(int <> fraction) <= 38
      nil -> false
    end
  end

  defp minimum?(_, _), do: false

  defp significant(digits), do: byte_size(String.trim_leading(digits, "0"))

  defp usage?(u) do
    shape?(u, @usage_keys) and text?(u.tenant) and text?(u.period) and
      within?(u.rows, @max_rows) and Enum.all?(u.rows, &row?/1) and
      length(Enum.uniq_by(u.rows, &{key(&1), &1.source})) == length(u.rows)
  end

  defp row?(r) do
    shape?(r, @row_keys) and text?(r.provider_id) and text?(r.model_id) and unit?(r.unit) and
      r.source in @sources and is_integer(r.count) and r.count >= 1 and
      is_integer(r.unknown_count) and r.unknown_count in 0..r.count and is_integer(r.known) and
      r.known in 0..(@bound - 1) and (r.unknown_count < r.count or r.known == 0)
  end

  defp charge?(c, registry) do
    shape?(c, @charge_keys) and text?(c.tenant) and text?(c.period) and identity?(c.card) and
      amount?(c.total, registry) and is_boolean(c.incomplete) and is_integer(c.unknown_count) and
      c.unknown_count >= 0 and c.incomplete == c.unknown_count > 0 and
      within?(c.lines, @max_lines) and Enum.all?(c.lines, &charged?(&1, c.total.currency, registry))
  end

  defp identity?(i) do
    shape?(i, @identity_keys) and text?(i.card_id) and version?(i.version) and i.kind in @kinds and
      is_binary(i.content_hash) and byte_size(i.content_hash) == 32
  end

  defp charged?(l, currency, registry) do
    shape?(l, @charged_keys) and text?(l.provider_id) and text?(l.model_id) and unit?(l.unit) and
      is_integer(l.quantity) and l.quantity >= 0 and is_integer(l.unknown_count) and
      l.unknown_count >= 0 and is_integer(l.count) and l.count >= 1 and
      within?(l.sources, length(@sources)) and Enum.all?(l.sources, &(&1 in @sources)) and
      amount?(l.charge, registry) and l.charge.currency == currency
  end

  # A non-negative domain/money amount of a registry member with a minor unit.
  defp amount?(%Amount{currency: currency, minor_units: units}, registry),
    do:
      currency?(currency) and Money.member(registry, currency) == :ok and is_integer(units) and
        units in 0..(@bound - 1)

  defp amount?(_, _), do: false

  defp unit?({:cache_write_tokens, ttl}), do: ttl in Usage.ttls()
  defp unit?(unit), do: unit in Usage.units()

  # A plain atom-keyed map with exactly these keys; a struct is refused.
  defp shape?(map, keys) when is_map(map) and not is_struct(map),
    do: Enum.sort(Map.keys(map)) == keys

  defp shape?(_, _), do: false

  # A proper list of at most n entries.
  defp within?([], _), do: true
  defp within?([_ | rest], n) when n > 0, do: within?(rest, n - 1)
  defp within?(_, _), do: false

  # Strictly increasing in Erlang term order: sorted and unique.
  defp ascending?([a, b | rest]), do: a < b and ascending?([b | rest])
  defp ascending?(_), do: true

  defp version?(n), do: is_integer(n) and n in 1..@max_version

  # The domain/metering text rule: 1..128 bytes of valid UTF-8 without C0 or C1 controls.
  defp text?(t),
    do: is_binary(t) and byte_size(t) in 1..128 and String.valid?(t) and printable?(t)

  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false
end
