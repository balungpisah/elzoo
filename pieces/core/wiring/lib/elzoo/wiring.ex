# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Wiring do
  @moduledoc "Local declaration checks, not a transport or full graph validator."

  def validate(wiring) do
    with {:ok, _bindings, _edges} <- inspect_wiring(wiring), do: {:ok, wiring}
  end

  def accept(wiring, edge_id, envelope) do
    with {:wiring, {:ok, bindings, edges}} <- {:wiring, inspect_wiring(wiring)},
         {:route, {:ok, edge}} <- {:route, fetch(edges, edge_id, :unknown_edge)},
         {:envelope, {:ok, message}} <- {:envelope, Elzoo.Envelope.decode(envelope)},
         {:wiring, {:ok, source}} <-
           {:wiring, Elzoo.Edge.decode_binding(Map.fetch!(bindings, reference(edge["source"])))},
         {:route, {:ok, true}} <-
           {:route, apply(:"Cure.Elzoo.Wiring", :accept, [message, source])} do
      {:ok, envelope}
    else
      {phase, {:error, reason}} -> {:error, {phase, reason}}
    end
  end

  defp inspect_wiring(%{"version" => 1, "units" => units, "edges" => edges} = wiring)
       when map_size(wiring) == 3 and is_list(units) and is_list(edges) do
    with {:ok, bindings} <- bindings(units),
         {:ok, edges, connected} <- edges(edges, bindings),
         :ok <- required_routes(bindings, connected) do
      {:ok, bindings, edges}
    end
  end

  defp inspect_wiring(_), do: {:error, :invalid_shape}

  defp bindings(units) do
    Enum.reduce_while(Enum.with_index(units), {:ok, %{}, MapSet.new()}, fn
      {%{"id" => id, "ports" => ports} = unit, index}, {:ok, bindings, ids}
      when map_size(unit) == 2 and is_binary(id) and is_list(ports) ->
        cond do
          not String.valid?(id) or id == "" ->
            {:halt, {:error, {:unit, index, :invalid_id}}}

          MapSet.member?(ids, id) ->
            {:halt, {:error, {:unit, index, :duplicate_id}}}

          true ->
            case unit_ports(id, ports, bindings) do
              {:ok, bindings} -> {:cont, {:ok, bindings, MapSet.put(ids, id)}}
              {:error, _} = error -> {:halt, error}
            end
        end

      {_, index}, _ ->
        {:halt, {:error, {:unit, index, :invalid_shape}}}
    end)
    |> case do
      {:ok, bindings, _} -> {:ok, bindings}
      {:error, _} = error -> error
    end
  end

  defp unit_ports(unit, ports, bindings) do
    Enum.reduce_while(Enum.with_index(ports), {:ok, bindings}, fn
      {%{"port" => port, "delivery" => delivery, "required_route" => required} = declaration, index},
      {:ok, bindings}
      when map_size(declaration) == 3 ->
        binding = %{
          "unit_id" => unit,
          "port" => port,
          "delivery" => delivery,
          "required_route" => required
        }

        case Elzoo.Edge.decode_port(unit, declaration) do
          {:ok, _} ->
            key = {unit, port["id"]}

            if Map.has_key?(bindings, key) do
              {:halt, {:error, {:port, unit, index, :duplicate_id}}}
            else
              {:cont, {:ok, Map.put(bindings, key, binding)}}
            end

          {:error, reason} ->
            {:halt, {:error, {:port, unit, index, reason}}}
        end

      {_, index}, _ ->
        {:halt, {:error, {:port, unit, index, :invalid_shape}}}
    end)
  end

  defp edges(edges, bindings) do
    Enum.reduce_while(Enum.with_index(edges), {:ok, %{}, MapSet.new(), MapSet.new()}, fn
      {edge, index}, {:ok, checked, routes, connected} ->
        with {:ok, _} <- Elzoo.Edge.decode(edge),
             false <- Map.has_key?(checked, edge["id"]),
             {:ok, source} <- fetch(bindings, reference(edge["source"]), :unknown_source),
             {:ok, target} <- fetch(bindings, reference(edge["target"]), :unknown_target),
             {:ok, true} <- Elzoo.Edge.connect(edge, source, target) do
          route = {reference(edge["source"]), reference(edge["target"])}

          if MapSet.member?(routes, route) do
            {:halt, {:error, {:edge, index, :duplicate_route}}}
          else
            connected = connected |> MapSet.put(elem(route, 0)) |> MapSet.put(elem(route, 1))
            {:cont, {:ok, Map.put(checked, edge["id"], edge), MapSet.put(routes, route), connected}}
          end
        else
          true -> {:halt, {:error, {:edge, index, :duplicate_id}}}
          {:error, reason} -> {:halt, {:error, {:edge, index, reason}}}
        end
    end)
    |> case do
      {:ok, checked, _, connected} -> {:ok, checked, connected}
      {:error, _} = error -> error
    end
  end

  defp required_routes(bindings, connected) do
    bindings
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn {key, binding}, :ok ->
      case apply(:"Cure.Elzoo.Wiring", :require_route, [
             binding["required_route"],
             MapSet.member?(connected, key)
           ]) do
        {:ok, true} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:route, key, reason}}}
      end
    end)
  end

  defp reference(reference), do: {reference["unit_id"], reference["port_id"]}

  defp fetch(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, reason}
    end
  end
end
