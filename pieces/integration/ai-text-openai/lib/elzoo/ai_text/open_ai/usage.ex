# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiText.OpenAI.Usage do
  @moduledoc """
  OpenAI Responses usage (`ResponseUsage` of the pinned OpenAPI document) to the
  family core's usage value. Every counter is tied to a named schema field:

  - input (convention `input_includes_cached: true`): `usage.input_tokens`;
  - `cache_read_tokens`: `usage.input_tokens_details.cached_tokens`;
  - cache writes `30m` and `12h`:
    `usage.input_tokens_details.cache_write_tokens_details.ttl_30m_tokens` and
    `ttl_12h_tokens`; or one `provider_default` record of
    `usage.input_tokens_details.cache_write_tokens` when no breakdown is given;
  - `output_tokens`: `usage.output_tokens`;
  - `reasoning_tokens`: `usage.output_tokens_details.reasoning_tokens`.

  When the total and the breakdown are both present they must agree (sum equals
  total), otherwise the writes are one `provider_default` record of `:unknown`; a
  breakdown lacking one of its two TTL fields without a matching total is also
  `:unknown`. Writes are never counted twice and never a partial sum. An absent
  field is `:unknown`, never zero; no usage object gives source `:unknown`.
  `total_tokens` is not used.
  """
  alias Elzoo.AiModel.Usage

  @convention %{input_includes_cached: true}

  def convention, do: @convention

  def from_raw(%{} = u) when map_size(u) > 0 do
    details = if is_map(u["input_tokens_details"]), do: u["input_tokens_details"], else: %{}

    raw =
      %{
        input: amount(u["input_tokens"]),
        cache_read: amount(details["cached_tokens"]),
        cache_writes: writes(details),
        output: amount(u["output_tokens"])
      }
      |> then(fn r ->
        case u["output_tokens_details"] do
          %{"reasoning_tokens" => n} -> Map.put(r, :reasoning, amount(n))
          _ -> r
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

  defp writes(details) do
    total = details["cache_write_tokens"]

    breakdown =
      case details["cache_write_tokens_details"] do
        %{} = d ->
          for {ttl, key} <- [{"30m", "ttl_30m_tokens"}, {"12h", "ttl_12h_tokens"}],
              Map.has_key?(d, key),
              do: %{ttl: ttl, amount: amount(d[key])}

        _ ->
          nil
      end

    cond do
      is_list(breakdown) and breakdown != [] ->
        sum = Usage.sum(breakdown)

        cond do
          # Both TTL fields present and no total: the breakdown is complete.
          total == nil and length(breakdown) == 2 -> breakdown
          is_integer(total) and sum == total -> breakdown
          # A partial or disagreeing breakdown leaves writes unknown.
          true -> [%{ttl: "provider_default", amount: :unknown}]
        end

      Map.has_key?(details, "cache_write_tokens") ->
        [%{ttl: "provider_default", amount: amount(total)}]

      true ->
        [%{ttl: "provider_default", amount: :unknown}]
    end
  end
end
