# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiModel.Provenance do
  @moduledoc """
  Where a result came from:
  `%{model_ref: model_ref, provider_model: text, response_id: text | :absent,
  request_id: text | :absent, provider_piece: text}`. `provider_model` is the
  model the provider says served the call; `response_id` the provider's message
  or response id; `request_id` the provider's HTTP request id; `provider_piece`
  the catalogue ID of the provider Piece.
  """
  import Elzoo.AiModel, only: [text?: 2, exact_keys?: 2]

  def validate(p) do
    with true <- exact_keys?(p, [:model_ref, :provider_model, :response_id, :request_id, :provider_piece]),
         {:ok, _} <- Elzoo.AiModel.ModelRef.validate(p.model_ref),
         true <- text?(p.provider_model, 256) and text?(p.provider_piece, 128),
         true <- id?(p.response_id) and id?(p.request_id) do
      {:ok, p}
    else
      _ -> {:error, :provenance}
    end
  end

  defp id?(:absent), do: true
  defp id?(id), do: text?(id, 256)
end
