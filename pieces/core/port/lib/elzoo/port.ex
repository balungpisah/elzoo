# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Port do
  @moduledoc "Translation of language-neutral Port descriptors to the pure Cure checker."

  @doc "Validate and translate an exact string-keyed descriptor; does not inspect payloads."
  def decode(
        %{
          "id" => id,
          "direction" => direction,
          "schema_id" => schema,
          "schema_version" => version
        } = descriptor
      )
      when map_size(descriptor) == 4 and is_binary(id) and is_binary(direction) and
             is_binary(schema) and is_integer(version) do
    if Enum.all?([id, direction, schema], &String.valid?/1) do
      apply(:"Cure.Elzoo.Port", :validate, [
        {:Descriptor, text(id), text(direction), text(schema), version}
      ])
    else
      {:error, :invalid_shape}
    end
  end

  def decode(_), do: {:error, :invalid_shape}

  @doc "Translate a validated Cure descriptor back to the neutral representation."
  def encode({:Descriptor, {:String, id}, {:String, direction}, {:String, schema}, version}) do
    %{
      "id" => List.to_string(id),
      "direction" => List.to_string(direction),
      "schema_id" => List.to_string(schema),
      "schema_version" => version
    }
  end

  defp text(value), do: {:String, String.to_charlist(value)}

  @doc "Check declarations before execution. Success is {:ok, true}, not a payload certificate."
  def compatible(source, target) do
    with {:source, {:ok, source}} <- {:source, decode(source)},
         {:target, {:ok, target}} <- {:target, decode(target)} do
      apply(:"Cure.Elzoo.Port", :compatible, [source, target])
    else
      {side, {:error, reason}} -> {:error, {side, reason}}
    end
  end
end
