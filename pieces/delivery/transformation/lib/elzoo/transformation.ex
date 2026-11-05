# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Transformation do
  @moduledoc "Re-wrap an opaque payload transformation for an explicit output Port."

  def translate(envelope, target, fun) do
    with {:ok, _} <- phase(Elzoo.Envelope.decode(envelope), :envelope),
         {:ok, port} <- decode_target(target) do
      translated =
        envelope
        |> Map.delete("sequence")
        |> Map.put("message_id", target["message_id"])
        |> Map.put("producer", %{"unit_id" => target["unit_id"], "port_id" => port["id"]})
        |> Map.put("schema_id", port["schema_id"])
        |> Map.put("schema_version", port["schema_version"])
        |> Map.put("causation_id", envelope["message_id"])
        |> Map.put("correlation_id", Map.get(envelope, "correlation_id", envelope["message_id"]))
        |> Map.put("payload", fun.(envelope["payload"]))

      phase(Elzoo.Envelope.validate(translated), :envelope)
    end
  end

  defp decode_target(%{"unit_id" => unit, "port" => port, "message_id" => id} = target)
       when map_size(target) == 3 do
    with true <- text?(unit) and text?(id),
         {:ok, _} <- phase(Elzoo.Port.decode(port), :target) do
      if port["direction"] == "output",
        do: {:ok, port},
        else: {:error, {:target, :invalid_direction}}
    else
      false -> {:error, {:target, :invalid_shape}}
      {:error, _} = error -> error
    end
  end

  defp decode_target(_), do: {:error, {:target, :invalid_shape}}
  defp text?(value), do: is_binary(value) and String.valid?(value) and value != ""
  defp phase({:ok, value}, _), do: {:ok, value}
  defp phase({:error, reason}, phase), do: {:error, {phase, reason}}
end
