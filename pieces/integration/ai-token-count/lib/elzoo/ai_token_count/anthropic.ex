# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiTokenCount.Anthropic do
  @moduledoc """
  An upper bound for the input tokens of one `integration/ai-text` request to
  Anthropic, before the call. Estimator `elzoo/ai-token-count/anthropic-bytes`,
  version 1: three times the bytes of the canonical request, plus 1,024 when the
  request has at least one tool.

  The value is not a token count and not a usage fact: the usage that the
  provider reports stays the only usage fact. The factor rests on recorded
  observations of one model (see the README), not on a published tokenizer.

  Pure: no Effect, credential, network, clock, process or storage write. The
  one read outside the argument is the model catalogue of `llm_db`.
  """
  alias Elzoo.AiText.Request

  @factor 3
  @tool_prompt 1_024

  @doc """
  `{:ok, estimate}` with exactly the keys `size`, `unit`, `direction`,
  `provider_id`, `model_id`, `estimator_id` and `estimator_version`, or
  `{:refused, reason}` with `reason` one of `:invalid_request`, `:too_large`,
  `:unsupported_feature` and `:unknown_model`.
  """
  def estimate(payload) do
    case Request.decode(payload) do
      {:ok, %{output_schema: schema}, _canonical} when schema != nil ->
        # Anthropic adds a system prompt of no documented size for structured output.
        {:refused, :unsupported_feature}

      {:ok, request, canonical} ->
        case LLMDB.model(:anthropic, request.model) do
          {:ok, _} ->
            {:ok,
             %{
               size: @factor * byte_size(canonical) + tool_prompt(request.tools),
               unit: :tokens,
               direction: :upper_bound,
               provider_id: "anthropic",
               model_id: request.model,
               estimator_id: "elzoo/ai-token-count/anthropic-bytes",
               estimator_version: 1
             }}

          _ ->
            {:refused, :unknown_model}
        end

      {:error, reason} ->
        {:refused, reason}
    end
  end

  defp tool_prompt([]), do: 0
  defp tool_prompt([_ | _]), do: @tool_prompt
end
