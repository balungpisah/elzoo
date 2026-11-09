# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiModel.Usage do
  @moduledoc """
  Unit-tagged usage with the provider's input-token convention.

  A usage value is
  `%{counters: [%{unit: unit, amount: amount}], cache_writes: [%{ttl: ttl, amount: amount}],
  convention: %{input_includes_cached: boolean}, source: :provider_reported | :unknown}`
  where `amount` is a non-negative integer or `:unknown` (never a zero standing in
  for an absent value), at most one counter per unit and one cache-write record per
  TTL. An empty `cache_writes` list means the provider reported no cache write; a
  write total the provider did not report is a record with amount `:unknown`.

  The accounting identity (see `input_uncached/4` and `prompt_input_tokens/1`):
  with `input_includes_cached: false` (Anthropic) `input_uncached_tokens` is the
  provider's input counter; with `true` (OpenAI) it is
  `input - cache_read - sum(cache_writes)`. Where every component is known,
  `prompt_input_tokens = input_uncached_tokens + cache_read_tokens + sum(cache_writes)`;
  otherwise the derived value is `:unknown`. Prices and cost are not usage.
  """
  import Elzoo.AiModel, only: [amount?: 1, exact_keys?: 2]

  @units [
    :input_uncached_tokens,
    :cache_read_tokens,
    :output_tokens,
    :reasoning_tokens,
    :images,
    :audio_seconds,
    :characters,
    :search_units,
    :video_seconds
  ]
  @ttls ["5m", "1h", "30m", "12h", "24h", "provider_default"]
  @max_records 16

  def units, do: @units
  def ttls, do: @ttls

  @doc "Validates a usage value."
  def validate(usage) do
    cond do
      not exact_keys?(usage, [:counters, :cache_writes, :convention, :source]) ->
        {:error, :usage_shape}

      not records?(usage.counters, :unit, @units) ->
        {:error, :usage_counter}

      not records?(usage.cache_writes, :ttl, @ttls) ->
        {:error, :usage_cache_write}

      not (exact_keys?(usage.convention, [:input_includes_cached]) and
               is_boolean(usage.convention.input_includes_cached)) ->
        {:error, :usage_convention}

      usage.source not in [:provider_reported, :unknown] ->
        {:error, :usage_source}

      true ->
        {:ok, usage}
    end
  end

  defp records?(list, key, allowed) do
    is_list(list) and length(list) <= @max_records and
      Enum.all?(list, fn r ->
        exact_keys?(r, [key, :amount]) and r[key] in allowed and amount?(r.amount)
      end) and
      length(Enum.uniq_by(list, & &1[key])) == length(list)
  end

  @doc """
  The provider-independent uncached input: `input` under
  `input_includes_cached: false`; `input - cache_read - sum(writes)` under `true`.
  Any needed component `:unknown`, or a negative difference (an inconsistent
  provider report), gives `:unknown`, never a clamped zero.
  """
  def input_uncached(input, _cache_read, _writes, false), do: input

  def input_uncached(input, cache_read, writes, true) do
    with n when is_integer(n) <- input,
         r when is_integer(r) <- cache_read,
         w when is_integer(w) <- sum(writes),
         d when d >= 0 <- n - r - w do
      d
    else
      _ -> :unknown
    end
  end

  @doc "Sum of cache-write amounts; `:unknown` if any record is unknown."
  def sum(writes) do
    Enum.reduce(writes, 0, fn
      %{amount: n}, acc when is_integer(n) and is_integer(acc) -> acc + n
      _, _ -> :unknown
    end)
  end

  @doc "The amount of `unit` in `usage`; `:unknown` if the counter is absent."
  def amount(%{counters: counters}, unit) do
    case Enum.find(counters, &(&1.unit == unit)) do
      %{amount: a} -> a
      nil -> :unknown
    end
  end

  @doc """
  `input_uncached_tokens + cache_read_tokens + sum(cache_writes)` when every
  component is known, else `:unknown`.
  """
  def prompt_input_tokens(usage) do
    with u when is_integer(u) <- amount(usage, :input_uncached_tokens),
         r when is_integer(r) <- amount(usage, :cache_read_tokens),
         w when is_integer(w) <- sum(usage.cache_writes) do
      u + r + w
    else
      _ -> :unknown
    end
  end

  @doc """
  Builds a validated usage value from a provider's raw counters. `raw` holds
  `:input`, `:cache_read`, `:cache_writes`, `:output` and optionally
  `:reasoning` and further units, each an amount (`:unknown` when the provider
  did not report it). The convention decides `input_uncached_tokens`.
  """
  def from_provider(raw, %{input_includes_cached: includes} = convention, source)
      when is_map(raw) and is_boolean(includes) do
    writes = Map.get(raw, :cache_writes, [])
    input = Map.get(raw, :input, :unknown)
    read = Map.get(raw, :cache_read, :unknown)

    extra =
      raw
      |> Map.drop([:input, :cache_read, :cache_writes, :output, :reasoning])
      |> Enum.map(fn {unit, amount} -> %{unit: unit, amount: amount} end)

    counters =
      [
        %{unit: :input_uncached_tokens, amount: input_uncached(input, read, writes, includes)},
        %{unit: :cache_read_tokens, amount: read},
        %{unit: :output_tokens, amount: Map.get(raw, :output, :unknown)}
      ] ++
        if(Map.has_key?(raw, :reasoning),
          do: [%{unit: :reasoning_tokens, amount: raw.reasoning}],
          else: []
        ) ++ Enum.sort_by(extra, & &1.unit)

    with true <- amount?(input) and amount?(read) and is_list(writes) do
      validate(%{counters: counters, cache_writes: writes, convention: convention, source: source})
    else
      _ -> {:error, :usage_counter}
    end
  end

  def from_provider(_, _, _), do: {:error, :usage_shape}

  @doc "Usage when the provider reported none: every listed counter `:unknown`."
  def unknown(convention) do
    {:ok, usage} =
      validate(%{
        counters: Enum.map([:input_uncached_tokens, :cache_read_tokens, :output_tokens], &%{unit: &1, amount: :unknown}),
        cache_writes: [%{ttl: "provider_default", amount: :unknown}],
        convention: convention,
        source: :unknown
      })

    usage
  end
end
