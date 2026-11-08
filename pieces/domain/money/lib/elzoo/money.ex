# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Money do
  @moduledoc """
  Exact currency amounts over the closed, versioned ISO 4217 registry (ELZ-031).

  A currency is an `Elzoo.Money.Currency` from the registry, never a bare
  string; an amount is an integer count of minor units scaled by that
  currency's exponent. Arithmetic decisions are the Cure module
  `Cure.Elzoo.Money`; this module checks registry membership, validates input
  types and translates results. No Float is accepted or produced anywhere.

  Every rejection is `{:error, {reason, detail}}` with `reason` one of
  `:currency_mismatch`, `:unknown_currency`, `:malformed_code`,
  `:retired_currency`, `:scale_overflow`, `:malformed_amount`,
  `:invalid_ratios`, `:unknown_rounding_mode`, `:unknown_placement`,
  `:no_minor_unit`, `:forged_currency` and `:unknown_registry_version`.

  Options (per call; no default changes at runtime): `registry:` a registry
  value (default `Elzoo.Money.Registry.default/0`); `version:` a held registry
  version id (default the newest held version).
  """
  alias Elzoo.Money.Registry

  @cure :"Cure.Elzoo.Money"
  @rounding_modes [:down, :half_up, :half_even, :ceiling, :floor, :half_down, :up]
  @placements %{first: :MoneyFirst, last: :MoneyLast, spread: :MoneySpread}
  @max_ratios 1000
  @max_digits 38
  @bound Integer.pow(10, 38)
  @min_scale -18

  defmodule Currency do
    @moduledoc "A registry member: identity, status and the version it was resolved under."
    @enforce_keys [:alpha, :numeric, :minor_unit, :status, :version]
    defstruct @enforce_keys
  end

  defmodule Amount do
    @moduledoc "An integer count of minor units of a registry currency."
    @enforce_keys [:currency, :minor_units]
    defstruct @enforce_keys
  end

  @doc "The supported rounding modes (Decimal's mode names)."
  def rounding_modes, do: @rounding_modes

  # ── registry lookup ─────────────────────────────────────────────────────

  @doc """
  Parse an untrusted alpha code. Exactly three ASCII letters (no trimming),
  else `malformed_code`; an unknown code is `unknown_currency`; retired codes
  parse with their `{:retired, withdrawal}` status.
  """
  def parse(text, opts \\ []) do
    with {:ok, registry, version} <- context(opts) do
      cond do
        not (is_binary(text) and Regex.match?(~r/\A[A-Za-z]{3}\z/, text)) ->
          {:error, {:malformed_code, text}}

        entry = Registry.entry(registry, version, String.upcase(text)) ->
          {:ok, currency(entry, version)}

        true ->
          {:error, {:unknown_currency, String.upcase(text)}}
      end
    end
  end

  @doc """
  Parse an untrusted three-digit numeric code among the currencies active in
  the stated version (numeric codes are unique there).
  """
  def parse_numeric(text, opts \\ []) do
    with {:ok, registry, version} <- context(opts) do
      cond do
        not (is_binary(text) and Regex.match?(~r/\A[0-9]{3}\z/, text)) ->
          {:error, {:malformed_code, text}}

        alpha = registry.active_numeric[version][String.to_integer(text)] ->
          {:ok, currency(Registry.entry(registry, version, alpha), version)}

        true ->
          {:error, {:unknown_currency, text}}
      end
    end
  end

  @doc """
  An enumeration, not a parse: every alpha code that any held version links to
  the numeric code (as its identity or in a source row), with those versions,
  in alpha order. It never chooses among reused codes.
  """
  def numeric_candidates(text, opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry.default())

    if is_binary(text) and Regex.match?(~r/\A[0-9]{3}\z/, text) do
      n = String.to_integer(text)

      links =
        for version <- registry.versions,
            {alpha, entry} <- registry.snapshots[version],
            entry.numeric == n or Enum.any?(entry.rows, &(&1.numeric == n)),
            do: {alpha, version}

      {:ok,
       links
       |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
       |> Enum.sort()
       |> Enum.map(fn {alpha, versions} -> %{alpha: alpha, versions: versions} end)}
    else
      {:error, {:malformed_code, text}}
    end
  end

  @doc "The status of the currency's code in the newest held version."
  def current_status(currency, opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry.default())

    with :ok <- member(registry, currency) do
      {:ok, Registry.entry(registry, Registry.latest(registry), currency.alpha).status}
    end
  end

  # ── construction ────────────────────────────────────────────────────────

  @doc "An amount of `minor_units` (an integer) in a registry currency."
  def from_minor_units(currency, minor_units, opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry.default())

    with :ok <- member(registry, currency),
         :ok <- scalable(currency) do
      if is_integer(minor_units),
        do: {:ok, %Amount{currency: currency, minor_units: minor_units}},
        else: {:error, {:malformed_amount, minor_units}}
    end
  end

  @doc """
  An amount from an untrusted decimal string, exactly: at most 40 bytes of
  `-?(0|[1-9][0-9]*)(.[0-9]+)?` with at most 38 significant digits; a fraction
  finer than the exponent is `scale_overflow`. No Decimal context is used.
  """
  def from_decimal_string(currency, text, opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry.default())

    with :ok <- member(registry, currency),
         :ok <- scalable(currency),
         {:ok, sign, digits, fraction} <- decimal_text(text) do
      exponent = currency.minor_unit

      if byte_size(fraction) > exponent do
        {:error,
         {:scale_overflow,
          %{alpha: currency.alpha, exponent: exponent, scale: byte_size(fraction)}}}
      else
        bounded(
          currency,
          sign * String.to_integer(digits <> String.pad_trailing(fraction, exponent, "0")),
          text
        )
      end
    end
  end

  defp decimal_text(text) when is_binary(text) and byte_size(text) <= 40 do
    case Regex.run(~r/\A(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?\z/, text) do
      [_, minus, int] -> digits(minus, int, "", text)
      [_, minus, int, fraction] -> digits(minus, int, fraction, text)
      nil -> {:error, {:malformed_amount, text}}
    end
  end

  defp decimal_text(text), do: {:error, {:malformed_amount, text}}

  defp digits(minus, int, fraction, text) do
    if byte_size(String.trim_leading(int <> fraction, "0")) <= @max_digits,
      do: {:ok, if(minus == "-", do: -1, else: 1), int, fraction},
      else: {:error, {:malformed_amount, text}}
  end

  @doc """
  An amount from a finite `%Decimal{}` rounded to minor units with a declared
  rounding mode. The struct is read field by field (coefficient at most 38
  digits, exponent -38..38); rounding is integer arithmetic, so the process
  Decimal context never applies.
  """
  def from_decimal(currency, decimal, mode, opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry.default())

    with :ok <- member(registry, currency),
         :ok <- scalable(currency),
         :ok <- mode(mode),
         {:ok, sign, coefficient, exp} <- decimal_fields(decimal) do
      shift = exp + currency.minor_unit

      minor =
        if shift >= 0,
          do: sign * coefficient * Integer.pow(10, shift),
          else: divide(sign * coefficient, Integer.pow(10, -shift), mode)

      bounded(currency, minor, decimal)
    end
  end

  defp decimal_fields(%{__struct__: Decimal, sign: sign, coef: coef, exp: exp})
       when sign in [1, -1] and is_integer(coef) and coef >= 0 and is_integer(exp) and
              exp in -38..38 do
    if length(Integer.digits(coef)) <= @max_digits,
      do: {:ok, sign, coef, exp},
      else: {:error, {:malformed_amount, :coefficient_digits}}
  end

  defp decimal_fields(other), do: {:error, {:malformed_amount, other}}

  defp bounded(currency, minor, input) do
    if abs(minor) < @bound,
      do: {:ok, %Amount{currency: currency, minor_units: minor}},
      else: {:error, {:malformed_amount, %{magnitude: input}}}
  end

  # ── arithmetic (Cure) ───────────────────────────────────────────────────

  @doc "Same-currency sum; different currencies are `currency_mismatch`."
  def add(left, right, opts \\ []), do: binary(:add, left, right, opts)

  @doc "Same-currency difference; different currencies are `currency_mismatch`."
  def subtract(left, right, opts \\ []), do: binary(:subtract, left, right, opts)

  @doc "`:lt`, `:eq` or `:gt` for same-currency amounts."
  def compare(left, right, opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry.default())

    with :ok <- amount(registry, left),
         :ok <- amount(registry, right) do
      case apply(@cure, :compare, [cure(left), cure(right)]) do
        {:MoneyCompared, :MoneyLess} -> {:ok, :lt}
        {:MoneyCompared, :MoneyEqual} -> {:ok, :eq}
        {:MoneyCompared, :MoneyGreater} -> {:ok, :gt}
        {:MoneyCompareRejected, {:MoneyCurrencyMismatch, _, _}} -> mismatch(left, right)
      end
    end
  end

  @doc "The amount with the opposite sign."
  def negate(value, opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry.default())

    with :ok <- amount(registry, value) do
      {:MoneyAmount, _, minor} = apply(@cure, :negate, [cure(value)])
      {:ok, %Amount{value | minor_units: minor}}
    end
  end

  defp binary(operation, left, right, opts) do
    registry = Keyword.get(opts, :registry, Registry.default())

    with :ok <- amount(registry, left),
         :ok <- amount(registry, right) do
      case apply(@cure, operation, [cure(left), cure(right)]) do
        {:MoneyOk, {:MoneyAmount, _, minor}} -> {:ok, %Amount{left | minor_units: minor}}
        {:MoneyRejected, {:MoneyCurrencyMismatch, _, _}} -> mismatch(left, right)
      end
    end
  end

  defp mismatch(left, right),
    do: {:error, {:currency_mismatch, %{left: left.currency.alpha, right: right.currency.alpha}}}

  @doc """
  Allocate by 1 to 1000 non-negative integer ratios with a positive sum. Each
  share is `trunc(total * ratio / sum)`; the residual (total minus the shares,
  zero or with the total's sign) goes to the first positive-ratio part
  (`:first`), the last (`:last`), or one minor unit each in order (`:spread`).
  Returns `%{parts: [Amount], residual_placed: integer}`; the residual is
  already inside the parts.
  """
  def allocate(total, ratios, placement, opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry.default())

    with :ok <- amount(registry, total),
         :ok <- ratios(ratios),
         {:ok, cure_placement} <- placement(placement) do
      case apply(@cure, :allocate, [cure(total), ratios, cure_placement]) do
        {:MoneyAllocated, {:MoneyAllocation, parts, residual}} ->
          {:ok,
           %{
             parts:
               Enum.map(parts, fn {:MoneyAmount, _, minor} ->
                 %Amount{total | minor_units: minor}
               end),
             residual_placed: residual
           }}

        {:MoneyAllocationRejected, :MoneyInvalidRatios} ->
          {:error, {:invalid_ratios, ratios}}
      end
    end
  end

  defp ratios(ratios) do
    if proper_integers?(ratios, 0),
      do: :ok,
      else: {:error, {:invalid_ratios, ratios}}
  end

  # A proper list of 1 to 1000 integers (improper lists and other terms fail).
  defp proper_integers?([], count), do: count in 1..@max_ratios
  defp proper_integers?([r | rest], count) when is_integer(r) and count < @max_ratios,
    do: proper_integers?(rest, count + 1)

  defp proper_integers?(_, _), do: false

  defp placement(placement) when is_atom(placement) and is_map_key(@placements, placement),
    do: {:ok, Map.fetch!(@placements, placement)}

  defp placement(other), do: {:error, {:unknown_placement, other}}

  # ── rounding and decimal output ─────────────────────────────────────────

  @doc """
  Round to `scale` fractional digits (an integer in -18..exponent) with a
  declared mode; the result stays in minor units of the same currency.
  """
  def round(value, scale, mode, opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry.default())

    with :ok <- amount(registry, value),
         :ok <- mode(mode),
         :ok <- scale(value.currency, scale) do
      factor = Integer.pow(10, value.currency.minor_unit - scale)
      {:ok, %Amount{value | minor_units: divide(value.minor_units, factor, mode) * factor}}
    end
  end

  defp scale(_currency, scale) when not is_integer(scale), do: {:error, {:malformed_amount, scale}}

  defp scale(currency, scale) do
    if scale in @min_scale..currency.minor_unit//1,
      do: :ok,
      else:
        {:error,
         {:scale_overflow, %{alpha: currency.alpha, exponent: currency.minor_unit, scale: scale}}}
  end

  @doc "The exact `%Decimal{}` value (`Decimal.new/3`; no context applies)."
  def to_decimal(value, opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry.default())

    with :ok <- amount(registry, value) do
      sign = if value.minor_units < 0, do: -1, else: 1
      {:ok, Decimal.new(sign, abs(value.minor_units), -value.currency.minor_unit)}
    end
  end

  @doc ~S|The decimal string: `JPY 1000` is "1000", `BHD 1234` is "1.234".|
  def to_decimal_string(value, opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry.default())

    with :ok <- amount(registry, value) do
      exponent = value.currency.minor_unit
      digits = value.minor_units |> abs() |> Integer.to_string()
      sign = if value.minor_units < 0, do: "-", else: ""

      if exponent == 0 do
        {:ok, sign <> digits}
      else
        padded = String.pad_leading(digits, exponent + 1, "0")
        {int, fraction} = String.split_at(padded, byte_size(padded) - exponent)
        {:ok, sign <> int <> "." <> fraction}
      end
    end
  end

  # Integer division of n by a positive power of ten d with a rounding mode.
  defp divide(n, d, mode) do
    sign = if n < 0, do: -1, else: 1
    q = div(abs(n), d)
    r = rem(abs(n), d)
    twice = 2 * r

    up =
      case mode do
        :down -> false
        :up -> r > 0
        :half_up -> twice >= d
        :half_down -> twice > d
        :half_even -> twice > d or (twice == d and rem(q, 2) == 1)
        :ceiling -> r > 0 and sign > 0
        :floor -> r > 0 and sign < 0
      end

    sign * if(up, do: q + 1, else: q)
  end

  defp mode(mode) when mode in @rounding_modes, do: :ok
  defp mode(mode), do: {:error, {:unknown_rounding_mode, mode}}

  # ── membership and translation ──────────────────────────────────────────

  defp context(opts) do
    registry = Keyword.get(opts, :registry, Registry.default())
    version = Keyword.get(opts, :version, Registry.latest(registry))

    if is_binary(version) and Registry.held?(registry, version),
      do: {:ok, registry, version},
      else: {:error, {:unknown_registry_version, version}}
  end

  @doc false
  def currency(entry, version),
    do: %Currency{
      alpha: entry.alpha,
      numeric: entry.numeric,
      minor_unit: entry.minor_unit,
      status: entry.status,
      version: version
    }

  @doc """
  `:ok` when the value is the registry member in effect at its own version:
  equal identity and equal status. Otherwise `forged_currency`, or
  `unknown_registry_version` for a version this registry does not hold.
  """
  def member(registry, %Currency{version: version, alpha: alpha} = c) when is_binary(version) do
    cond do
      not Registry.held?(registry, version) ->
        {:error, {:unknown_registry_version, version}}

      (entry = Registry.entry(registry, version, alpha)) && currency(entry, version) == c ->
        :ok

      true ->
        {:error, {:forged_currency, c}}
    end
  end

  def member(_registry, other), do: {:error, {:forged_currency, other}}

  defp scalable(%Currency{minor_unit: minor, numeric: numeric})
       when is_integer(minor) and is_integer(numeric),
       do: :ok

  defp scalable(%Currency{minor_unit: :not_applicable, alpha: alpha}),
    do: {:error, {:no_minor_unit, alpha}}

  defp scalable(%Currency{alpha: alpha}), do: {:error, {:retired_currency, alpha}}

  defp amount(registry, %Amount{currency: currency, minor_units: minor}) when is_integer(minor) do
    with :ok <- member(registry, currency), do: scalable(currency)
  end

  defp amount(_registry, other), do: {:error, {:malformed_amount, other}}

  defp cure(%Amount{currency: c, minor_units: minor}),
    do:
      {:MoneyAmount, {:MoneyCurrency, {:String, String.to_charlist(c.alpha)}, c.numeric, c.minor_unit},
       minor}
end
