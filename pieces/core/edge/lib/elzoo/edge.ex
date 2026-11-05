# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Edge do
  @moduledoc "Translate named endpoint declarations and check fused/volatile placement in Cure."

  def decode_binding(
        %{"unit_id" => unit, "port" => port, "delivery" => delivery, "required_route" => required} =
          binding
      )
      when map_size(binding) == 4 and is_boolean(required) do
    with true <- text?(unit) and text?(delivery),
         {:ok, port} <- Elzoo.Port.decode(port) do
      apply(:"Cure.Elzoo.Edge", :validate_binding, [
        {:PortBinding, text(unit), port, text(delivery), required}
      ])
    else
      false -> {:error, :invalid_shape}
      {:error, _} = error -> error
    end
  end

  def decode_binding(_), do: {:error, :invalid_shape}

  def decode_port(
        unit,
        %{"port" => port, "delivery" => delivery, "required_route" => required} = declaration
      )
      when map_size(declaration) == 3 do
    decode_binding(%{
      "unit_id" => unit,
      "port" => port,
      "delivery" => delivery,
      "required_route" => required
    })
  end

  def decode_port(_, _), do: {:error, :invalid_shape}

  def decode(%{"id" => id, "placement" => placement, "source" => source, "target" => target} = edge)
      when map_size(edge) == 4 do
    with true <- text?(id) and text?(placement),
         {:ok, source} <- decode_reference(source),
         {:ok, target} <- decode_reference(target) do
      apply(:"Cure.Elzoo.Edge", :validate, [
        {:EdgeDeclaration, text(id), text(placement), source, target}
      ])
    else
      false -> {:error, :invalid_shape}
      {:error, _} = error -> error
    end
  end

  def decode(_), do: {:error, :invalid_shape}

  def connect(edge, source, target) do
    with {:edge, {:ok, edge}} <- {:edge, decode(edge)},
         {:source, {:ok, source}} <- {:source, decode_binding(source)},
         {:target, {:ok, target}} <- {:target, decode_binding(target)} do
      apply(:"Cure.Elzoo.Edge", :connect, [edge, source, target])
    else
      {side, {:error, reason}} -> {:error, {side, reason}}
    end
  end

  defp decode_reference(%{"unit_id" => unit, "port_id" => port} = reference)
       when map_size(reference) == 2 do
    if text?(unit) and text?(port) do
      apply(:"Cure.Elzoo.Edge", :validate_reference, [{:RouteReference, text(unit), text(port)}])
    else
      {:error, :invalid_shape}
    end
  end

  defp decode_reference(_), do: {:error, :invalid_shape}
  defp text?(value), do: is_binary(value) and String.valid?(value)
  defp text(value), do: {:String, String.to_charlist(value)}
end
