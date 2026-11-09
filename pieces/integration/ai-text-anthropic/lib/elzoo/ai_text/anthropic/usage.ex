# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiText.Anthropic.Usage do
  @moduledoc """
  Anthropic usage (documented in "Prompt caching", "Tracking cache performance"
  and "1-hour cache duration") to the family core's usage value.

  `input_tokens` excludes cache reads and writes (`input_includes_cached:
  false`). `cache_read_input_tokens` is the cache read; the writes are
  `cache_creation.ephemeral_5m_input_tokens` and
  `cache_creation.ephemeral_1h_input_tokens` as `5m` and `1h` records, or one
  `provider_default` record of `cache_creation_input_tokens` when only the total
  is present. When the total and the breakdown are both present they must agree
  (the page states the total equals the sum); otherwise the writes are one
  `provider_default` record of `:unknown`; they are never counted twice.
  `output_tokens_details.thinking_tokens` is `reasoning_tokens` when present.
  An absent field is `:unknown`, never zero; no usage object at all gives
  source `:unknown`.
  """
  alias Elzoo.AiModel.Usage

  @convention %{input_includes_cached: false}

  def convention, do: @convention

  def from_raw(%{} = u) when map_size(u) > 0 do
    raw =
      %{
        input: amount(u["input_tokens"]),
        cache_read: amount(u["cache_read_input_tokens"]),
        cache_writes: writes(u),
        output: amount(u["output_tokens"])
      }
      |> then(fn r ->
        case get_in(u, ["output_tokens_details", "thinking_tokens"]) do
          nil -> r
          n -> Map.put(r, :reasoning, amount(n))
        end
      end)

    case Usage.from_provider(raw, @convention, :provider_reported) do
      {:ok, usage} -> usage
      _ -> Usage.unknown(@convention)
    end
  end

  def from_raw(_), do: Usage.unknown(@convention)

  defp amount(n) when is_integer(n) and n >= 0, do: n
  defp amount(_), do: :unknown

  defp writes(u) do
    total = u["cache_creation_input_tokens"]
    detail = u["cache_creation"]

    breakdown =
      case detail do
        %{} = d ->
          for {ttl, key} <- [
                {"5m", "ephemeral_5m_input_tokens"},
                {"1h", "ephemeral_1h_input_tokens"}
              ],
              Map.has_key?(d, key),
              do: %{ttl: ttl, amount: amount(d[key])}

        _ ->
          nil
      end

    cond do
      is_list(breakdown) and breakdown != [] ->
        sum = Usage.sum(breakdown)

        cond do
          total == nil -> breakdown
          is_integer(total) and sum == total -> breakdown
          true -> [%{ttl: "provider_default", amount: :unknown}]
        end

      Map.has_key?(u, "cache_creation_input_tokens") ->
        [%{ttl: "provider_default", amount: amount(total)}]

      true ->
        [%{ttl: "provider_default", amount: :unknown}]
    end
  end
end
