# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiEmbedding.OpenAI.Usage do
  @moduledoc """
  OpenAI embeddings usage (`CreateEmbeddingResponse.usage`: `prompt_tokens`,
  `total_tokens`) to the family core's usage value.

  `prompt_tokens` is the input counter, `input_uncached_tokens`, under the
  convention `input_includes_cached: false` (no prompt cache is documented for
  embeddings). `total_tokens`, when present, must equal `prompt_tokens`;
  otherwise, or when `prompt_tokens` is absent or not a non-negative integer, the
  input counter is `:unknown`. Cache reads, cache writes and output are not
  reported: `cache_read_tokens` and `output_tokens` are `:unknown` and the writes
  are one `provider_default` record of `:unknown` (never an empty list, which
  would mean a reported zero), so `prompt_input_tokens/1` is `:unknown`. No usage
  object at all gives `Usage.unknown/1` (source `:unknown`).
  """
  alias Elzoo.AiModel.Usage

  @convention %{input_includes_cached: false}

  def convention, do: @convention

  def from_raw(%{} = u) do
    prompt = u["prompt_tokens"]

    input =
      cond do
        not (is_integer(prompt) and prompt >= 0) -> :unknown
        Map.has_key?(u, "total_tokens") and u["total_tokens"] != prompt -> :unknown
        true -> prompt
      end

    raw = %{
      input: input,
      cache_read: :unknown,
      cache_writes: [%{ttl: "provider_default", amount: :unknown}],
      output: :unknown
    }

    case Usage.from_provider(raw, @convention, :provider_reported) do
      {:ok, usage} -> usage
      _ -> Usage.unknown(@convention)
    end
  end

  def from_raw(_), do: Usage.unknown(@convention)
end
