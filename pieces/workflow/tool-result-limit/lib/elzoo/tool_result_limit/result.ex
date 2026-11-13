# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ToolResultLimit.Result do
  @moduledoc false
  # Internal to workflow/tool-result-limit and not part of its Contract: the
  # check of a result and of a media type, shared by the decision and the Adapter.
  alias Elzoo.UntrustedContent

  @encodings ~w(utf8 base64)

  # The bytes of a result: `{:ok, marked, media_type, encoding, bytes}`.
  def result(%{"content" => content, "media_type" => media, "encoding" => encoding} = result)
      when map_size(result) == 3 do
    case UntrustedContent.decode(content) do
      {:ok, marked} ->
        with true <- media?(media) and encoding in @encodings,
             {:ok, bytes} <- bytes(content["content"], encoding) do
          {:ok, marked, media, encoding, bytes}
        else
          _ -> {:error, :invalid_input}
        end

      _ ->
        {:error, :unmarked}
    end
  end

  def result(_), do: {:error, :invalid_input}

  def media?(media),
    do:
      is_binary(media) and media != "" and String.valid?(media) and byte_size(media) <= 256 and
        not String.contains?(media, <<0>>)

  defp bytes(text, "utf8"), do: {:ok, text}
  defp bytes(text, "base64"), do: Base.decode64(text)
end
