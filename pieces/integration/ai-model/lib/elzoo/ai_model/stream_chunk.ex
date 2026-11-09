# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiModel.StreamChunk do
  @moduledoc """
  The streaming chunk shape: `%{seq: n, kind: kind, payload: payload}` with `seq`
  a non-negative integer and `kind` one of:

  - `:text_delta`: payload is a UTF-8 binary (may be empty);
  - `:tool_delta`: payload `%{index: n, delta: binary}` (partial tool arguments,
    data only, never executed);
  - `:usage`: payload is a valid `Elzoo.AiModel.Usage` value;
  - `:finish`: payload `%{reason: atom}` or `%{reason: {:other, text}}`.

  The shape is fixed here; the streaming mode itself is a later slice.
  """
  import Elzoo.AiModel, only: [text?: 2, exact_keys?: 2]

  def kinds, do: [:text_delta, :tool_delta, :usage, :finish]

  def validate(chunk) do
    with true <- exact_keys?(chunk, [:seq, :kind, :payload]),
         true <- is_integer(chunk.seq) and chunk.seq >= 0,
         true <- payload?(chunk.kind, chunk.payload) do
      {:ok, chunk}
    else
      _ -> {:error, :stream_chunk}
    end
  end

  defp payload?(:text_delta, p), do: is_binary(p) and String.valid?(p)

  defp payload?(:tool_delta, p),
    do:
      exact_keys?(p, [:index, :delta]) and is_integer(p.index) and p.index >= 0 and
        is_binary(p.delta) and String.valid?(p.delta)

  defp payload?(:usage, p), do: match?({:ok, _}, Elzoo.AiModel.Usage.validate(p))
  defp payload?(:finish, %{reason: {:other, raw}} = p), do: map_size(p) == 1 and text?(raw, 64)
  defp payload?(:finish, %{reason: r} = p), do: map_size(p) == 1 and is_atom(r) and r not in [nil, true, false]
  defp payload?(_, _), do: false
end
