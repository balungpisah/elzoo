# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiBatch.Completion do
  @moduledoc """
  The completion checks of a batch item: the same checks the synchronous text
  Adapter applies to a provider's decoded message, owned here so the ready text
  interface is unchanged. Written against the public text and family-core
  functions (`Elzoo.AiText.Schema`, `Elzoo.AiModel.Usage`,
  `Elzoo.AiModel.Provenance`); the interface's tests compare its outcomes with the
  synchronous path over a named corpus (equality is claimed for that corpus only).

  `complete(caps, request, raw)` takes `caps` (`%{provider, wire_surface,
  piece}`), the item's decoded text request and the item provider's decoded map,
  and returns `{:completed, %{content, tool_proposals, structured, finish, usage,
  provenance}}` or `{:failure, :malformed_response}`.

  - A missing or invalid response id, an unrecognized finish, an invalid usage
    value, non-text content or an invalid provenance is `malformed_response`.
  - A tool proposal is data: invalid JSON, a non-object, an undeclared tool or a
    schema mismatch is returned marked `malformed` with `arguments: nil` and the
    raw text kept, never dropped or repaired.
  - Structured output is `{:valid, value}` only after validation against the
    requested schema, otherwise `{:invalid, :missing | :invalid_json |
    :schema_mismatch}`.
  """
  alias Elzoo.AiModel.{Provenance, Usage}
  alias Elzoo.AiText.Schema

  @finishes [:stop, :length, :tool_calls, :content_filter, :refusal]

  def complete(caps, request, raw) do
    with %{} <- raw,
         true <- Elzoo.AiModel.text?(raw[:response_id], 256),
         true <- valid_finish?(raw[:finish]),
         {:ok, usage} <- Usage.validate(raw[:usage]),
         content when is_binary(content) <- raw[:content],
         true <- String.valid?(content),
         calls when is_list(calls) <- raw[:tool_calls],
         {:ok, provenance} <-
           Provenance.validate(%{
             model_ref: %{
               provider: caps.provider,
               model_id: request.model,
               wire_surface: caps.wire_surface
             },
             provider_model: raw[:provider_model],
             response_id: raw.response_id,
             request_id: Map.get(raw, :request_id, :absent),
             provider_piece: caps.piece
           }) do
      {:completed,
       %{
         content: content,
         tool_proposals: Enum.map(calls, &proposal(&1, request)),
         structured: structured(request, raw[:structured_json]),
         finish: raw.finish,
         usage: usage,
         provenance: provenance
       }}
    else
      _ -> {:failure, :malformed_response}
    end
  rescue
    _ -> {:failure, :malformed_response}
  end

  defp valid_finish?(f) when f in @finishes, do: true
  defp valid_finish?({:other, raw}), do: Elzoo.AiModel.text?(raw, 64)
  defp valid_finish?(_), do: false

  defp proposal(call, request) do
    base = %{
      id: text_or_nil(call[:id]),
      name: text_or_nil(call[:name]),
      raw_arguments: call[:arguments_json],
      arguments: nil,
      malformed: nil
    }

    tool = Enum.find(request.tools, &(&1.name == call[:name]))

    with json when is_binary(json) <- call[:arguments_json],
         {:ok, args} when is_map(args) <- decode_json(json),
         {:declared, %{input_schema: s}} <- {:declared, tool},
         {:ok, root} <- Schema.build(s),
         :ok <- Schema.validate(args, root) do
      %{base | arguments: args}
    else
      {:declared, nil} -> %{base | malformed: :undeclared_tool}
      {:error, :schema_mismatch} -> %{base | malformed: :schema_mismatch}
      {:ok, _not_object} -> %{base | malformed: :not_an_object}
      _ -> %{base | malformed: :invalid_json}
    end
  end

  defp text_or_nil(v), do: if(Elzoo.AiModel.text?(v, 256), do: v, else: nil)

  defp structured(%{output_schema: nil}, _), do: nil

  defp structured(%{output_schema: schema}, json) do
    with true <- is_binary(json) || {:error, :missing},
         {:ok, value} <- decode_json(json),
         {:ok, root} <- Schema.build(schema),
         :ok <- Schema.validate(value, root) do
      {:valid, value}
    else
      {:error, :missing} -> {:invalid, :missing}
      {:error, :schema_mismatch} -> {:invalid, :schema_mismatch}
      _ -> {:invalid, :invalid_json}
    end
  end

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, v} -> {:ok, v}
      _ -> {:error, :invalid_json}
    end
  end
end
