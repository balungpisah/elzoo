# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ProviderStream.Chunk do
  @moduledoc """
  The chunk shapes of this Piece. `:tool_start`, payload
  `%{index, id, name}`, is owned here: `index` is the provider's content block
  index (0 to 63), `id` is 1 to 128 bytes of `[A-Za-z0-9_-]` and `name` is 1 to
  64 bytes of `[a-zA-Z0-9_-]`. Each other kind is passed unchanged to
  `Elzoo.AiModel.StreamChunk.validate/1`, which does not accept `:tool_start`.
  """
  import Elzoo.AiModel, only: [exact_keys?: 2]

  def validate(%{kind: :tool_start} = chunk) do
    with true <- exact_keys?(chunk, [:seq, :kind, :payload]),
         true <- is_integer(chunk.seq) and chunk.seq >= 0,
         p = chunk.payload,
         true <- exact_keys?(p, [:index, :id, :name]),
         true <- is_integer(p.index) and p.index in 0..63,
         true <- tool_id?(p.id) and tool_name?(p.name) do
      {:ok, chunk}
    else
      _ -> {:error, :stream_chunk}
    end
  end

  def validate(chunk), do: Elzoo.AiModel.StreamChunk.validate(chunk)

  @doc false
  def tool_id?(id), do: is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, id)

  @doc false
  def tool_name?(name), do: is_binary(name) and Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, name)
end
