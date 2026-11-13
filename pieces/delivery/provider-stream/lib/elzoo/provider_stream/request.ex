# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ProviderStream.Request do
  @moduledoc false
  # Refusal rules and the POST body. The payload is decoded only by
  # Elzoo.AiText.Request.decode/1; no second validator.

  def prepare(payload, models) do
    with {:ok, r, _canonical} <- Elzoo.AiText.Request.decode(payload),
         :ok <- supported(r),
         :ok <- if(r.model in models, do: :ok, else: {:error, :invalid_request}),
         :ok <- assistants(r.messages) do
      {:ok, Jason.encode!(body(r)), r.model}
    end
  end

  defp supported(r) do
    if r.output_schema == nil and r.sampling == nil and r.reasoning == :none and
         r.cache_hint == nil and r.stop_sequences == [] and r.provider_options == %{} and
         system_first?(r.messages),
       do: :ok,
       else: {:error, :unsupported_feature}
  end

  defp system_first?(messages) do
    messages |> Enum.drop_while(&(&1.role == :system)) |> Enum.all?(&(&1.role != :system))
  end

  defp assistants(messages) do
    if Enum.any?(messages, &(&1.role == :assistant and &1.text == "" and &1.tool_calls == [])),
      do: {:error, :invalid_request},
      else: :ok
  end

  defp body(r) do
    {system, rest} = Enum.split_with(r.messages, &(&1.role == :system))

    %{
      "model" => r.model,
      "max_tokens" => r.max_output_tokens,
      "stream" => true,
      "thinking" => %{"type" => "disabled"},
      "messages" =>
        rest
        |> Enum.chunk_by(&(&1.role == :tool_result))
        |> Enum.flat_map(&messages/1)
    }
    |> put_if(system != [], "system", Enum.map(system, &text_block(&1.text)))
    |> put_if(r.tools != [], "tools", Enum.map(r.tools, &tool/1))
    |> put_if(r.tools != [], "tool_choice", choice(r.tool_choice))
  end

  defp messages([%{role: :tool_result} | _] = results) do
    [%{"role" => "user", "content" => Enum.map(results, &result/1)}]
  end

  defp messages(list), do: Enum.map(list, &message/1)

  defp message(%{role: :user, text: t}), do: %{"role" => "user", "content" => [text_block(t)]}

  defp message(%{role: :assistant, text: t, tool_calls: calls}) do
    text = if t == "", do: [], else: [text_block(t)]

    uses =
      Enum.map(calls, fn c ->
        %{"type" => "tool_use", "id" => c.id, "name" => c.name, "input" => c.arguments}
      end)

    %{"role" => "assistant", "content" => text ++ uses}
  end

  defp result(m) do
    %{"type" => "tool_result", "tool_use_id" => m.tool_use_id, "content" => m.text}
    |> put_if(m.is_error, "is_error", true)
  end

  defp text_block(t), do: %{"type" => "text", "text" => t}

  defp tool(t),
    do: %{"name" => t.name, "description" => t.description, "input_schema" => t.input_schema}

  defp choice({:tool, name}), do: %{"type" => "tool", "name" => name}
  defp choice(type), do: %{"type" => Atom.to_string(type)}

  defp put_if(map, true, k, v), do: Map.put(map, k, v)
  defp put_if(map, false, _, _), do: map
end
