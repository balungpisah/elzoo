# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Routing do
  @moduledoc "Pure metadata selection among declared Wiring edges; no delivery or expiry."

  def validate(wiring, table) do
    with {:ok, _source} <- inspect_table(wiring, table), do: {:ok, table}
  end

  def route(wiring, table, envelope) do
    with {:ok, source} <- inspect_table(wiring, table),
         {:ok, message} <- phase(Elzoo.Envelope.decode(envelope), :envelope),
         {:ok, true} <- phase(apply(:"Cure.Elzoo.Wiring", :accept, [message, source]), :source) do
      table["routes"]
      |> Enum.filter(fn route ->
        apply(:"Cure.Elzoo.Routing", :matches, [message, decode_match(route["match"])])
      end)
      |> Enum.map(& &1["edge_id"])
      |> Enum.sort()
      |> accept_edges(wiring, envelope)
    end
  end

  def route_one(wiring, table, envelope) do
    case route(wiring, table, envelope) do
      {:ok, []} -> {:error, {:route, :no_route}}
      {:ok, [id]} -> {:ok, id}
      {:ok, [_ | _]} -> {:error, {:route, :ambiguous_route}}
      {:error, _} = error -> error
    end
  end

  defp inspect_table(wiring, table) do
    with {:ok, _} <- phase(Elzoo.Wiring.validate(wiring), :wiring),
         :ok <- table_shape(table),
         {:ok, source} <- source_binding(wiring, table["source"]),
         :ok <- routes(wiring["edges"], table) do
      {:ok, source}
    end
  end

  defp table_shape(%{"version" => 1, "source" => source, "routes" => routes} = table)
       when map_size(table) == 3 and is_list(routes) and length(routes) >= 0 do
    if endpoint?(source) and Enum.all?(routes, &route_shape?/1),
      do: :ok,
      else: {:error, {:table, :invalid_shape}}
  end

  defp table_shape(_), do: {:error, {:table, :invalid_shape}}

  defp endpoint?(%{"unit_id" => unit, "port_id" => port} = source),
    do: map_size(source) == 2 and text?(unit) and text?(port)

  defp endpoint?(_), do: false

  defp route_shape?(%{"edge_id" => id, "match" => match} = route),
    do: map_size(route) == 2 and text?(id) and match_shape?(match)

  defp route_shape?(_), do: false

  defp match_shape?(match) when is_map(match) do
    Enum.all?(match, fn
      {"kind", value} -> text?(value)
      {"schema_id", value} -> text?(value)
      {"schema_version", value} -> is_integer(value) and value > 0
      _ -> false
    end)
  end

  defp match_shape?(_), do: false

  defp source_binding(wiring, reference) do
    binding =
      for unit <- wiring["units"],
          unit["id"] == reference["unit_id"],
          declaration <- unit["ports"],
          declaration["port"]["id"] == reference["port_id"],
          do: Map.put(declaration, "unit_id", unit["id"])

    case binding do
      [binding] ->
        if binding["port"]["direction"] == "output",
          do: phase(Elzoo.Edge.decode_binding(binding), :source),
          else: {:error, {:table, :invalid_source}}

      [] ->
        {:error, {:table, :unknown_source}}
    end
  end

  defp routes(edges, table) do
    edges = Map.new(edges, &{&1["id"], &1})

    Enum.reduce_while(table["routes"], {:ok, MapSet.new()}, fn route, {:ok, seen} ->
      id = route["edge_id"]

      case Map.fetch(edges, id) do
        :error ->
          {:halt, {:error, {:route, id, :unknown_edge}}}

        {:ok, edge} ->
          cond do
            edge["source"] != table["source"] ->
              {:halt, {:error, {:route, id, :source_mismatch}}}

            MapSet.member?(seen, id) ->
              {:halt, {:error, {:route, id, :duplicate_route}}}

            true ->
              {:cont, {:ok, MapSet.put(seen, id)}}
          end
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp accept_edges(ids, wiring, envelope) do
    Enum.reduce_while(ids, {:ok, ids}, fn id, result ->
      case Elzoo.Wiring.accept(wiring, id, envelope) do
        {:ok, _} -> {:cont, result}
        {:error, reason} -> {:halt, {:error, {:edge, id, reason}}}
      end
    end)
  end

  defp decode_match(match) do
    {:RoutingMatch, text_option(match, "kind"), text_option(match, "schema_id"),
     option(match, "schema_version")}
  end

  defp text_option(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:some, {:String, String.to_charlist(value)}}
      :error -> :none
    end
  end

  defp option(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:some, value}
      :error -> :none
    end
  end

  defp text?(value), do: is_binary(value) and String.valid?(value) and value != ""
  defp phase({:ok, value}, _), do: {:ok, value}
  defp phase({:error, reason}, phase), do: {:error, {phase, reason}}
end
