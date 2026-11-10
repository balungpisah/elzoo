# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiEmbedding.Provider do
  @moduledoc """
  The behaviour an embedding provider Piece implements.

  - `capabilities/0` returns `%{piece: catalogue_id, provider: text, wire_surface:
    text, models: %{model_id => %{native: n, min: n, max: n}}, input_types:
    [input_type], max_inputs: n, convention: %{input_includes_cached: boolean},
    options: %{key => validator}}`. `models` declares each model the provider
    serves with its native vector dimension and the inclusive range a request's
    `dimensions` may take (`min == max == native` for a model without reduction).
    `input_types` is drawn from `:unspecified`, `:query`, `:document` and always
    holds `:unspecified`; a request for an undeclared one is refused
    `:unsupported_feature`. `options` declares the provider-options keys (strings)
    with a 1-arity validator returning `:ok`; any other key, or a failing value,
    is refused `:invalid_request` (never ignored).
  - `translate(request, provider_config)` is pure: the neutral request to the
    provider's wire request, or `{:refused, :invalid_request |
    :unsupported_feature | :too_large}`. It never reads a credential.
  - `call(wire, call_opts)` performs **exactly one** HTTP exchange with the
    injected credential `call_opts.credential` and returns `{:ok, exchange}` or
    `{:transport, :timeout | :closed | :other}`. No retry, no redirect.
  - `decode(exchange, request)` turns a successful exchange into
    `{:ok, %{items: [%{index: term, vector: term}], provider_model: term, usage:
    usage, request_id: text | :absent}}` with the items exactly as the provider
    listed them (the interface validates count, indices, lengths and values), or
    `{:failure, tag}` / `{:failure, tag, %{retry_after: seconds}}`.
  - `classify_failure(exchange_or_transport)` returns one of
    `Elzoo.AiEmbedding.Outcome.provider_tags/0`.
  """
  @callback capabilities() :: map()
  @callback translate(request :: map(), provider_config :: term()) ::
              {:ok, term()} | {:refused, atom()}
  @callback call(wire :: term(), call_opts :: map()) :: {:ok, term()} | {:transport, atom()}
  @callback decode(exchange :: term(), request :: map()) :: {:ok, map()} | {:failure, atom()}
  @callback classify_failure(term()) :: atom()

  @input_types [:unspecified, :query, :document]
  def input_types, do: @input_types

  @doc false
  def valid_capabilities?(%{} = c) do
    is_binary(c[:piece]) and is_binary(c[:provider]) and is_binary(c[:wire_surface]) and
      models?(c[:models]) and is_list(c[:input_types]) and :unspecified in c.input_types and
      Enum.all?(c.input_types, &(&1 in @input_types)) and is_integer(c[:max_inputs]) and
      c.max_inputs >= 1 and
      match?(%{input_includes_cached: b} when is_boolean(b), c[:convention]) and
      is_map(c[:options]) and
      Enum.all?(c.options, fn {k, v} -> is_binary(k) and is_function(v, 1) end)
  end

  def valid_capabilities?(_), do: false

  defp models?(%{} = models) when map_size(models) > 0 do
    Enum.all?(models, fn
      {id, %{native: n, min: lo, max: hi}} ->
        Elzoo.AiModel.text?(id, 256) and Enum.all?([n, lo, hi], &is_integer/1) and lo >= 1 and
          lo <= n and n <= hi

      _ ->
        false
    end)
  end

  defp models?(_), do: false
end
