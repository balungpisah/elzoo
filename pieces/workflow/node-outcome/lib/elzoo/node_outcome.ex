# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.NodeOutcome do
  @moduledoc "Pure rule for what follows the settled outcome of one graph node."

  @classes ~w(completed failed refused late unknown out_of_budget retries_exhausted expired resource_lost)
  @max_links 10_000
  @max_routes 9

  @spec routes(term(), term()) :: {:ok, %{String.t() => String.t()}} | {:error, :invalid_input}
  def routes(links, node_id) do
    if text?(node_id), do: collect(links, node_id, %{}, 0), else: {:error, :invalid_input}
  end

  @spec decide(term(), term()) ::
          {:follow, String.t()}
          | :proceed
          | {:fail_run, :no_outcome_link}
          | {:error, :invalid_input}
  def decide(routes, outcome) when is_map(routes) and outcome in @classes do
    if map_size(routes) <= @max_routes and
         Enum.all?(routes, fn {class, target} -> class in @classes and text?(target) end) do
      target = Map.get(routes, outcome)

      case apply(:"Cure.Elzoo.NodeOutcome", :decide, [outcome == "completed", target != nil]) do
        :OutcomeFollow -> {:follow, target}
        :OutcomeProceed -> :proceed
        :OutcomeFail -> {:fail_run, :no_outcome_link}
      end
    else
      {:error, :invalid_input}
    end
  end

  def decide(_, _), do: {:error, :invalid_input}

  defp collect([], _node_id, routes, _count), do: {:ok, routes}

  defp collect([link | rest], node_id, routes, count) when count < @max_links and is_map(link) do
    case link do
      %{"kind" => "outcome", "from" => ^node_id} ->
        with {:ok, class, target} <- outcome_link(link),
             false <- Map.has_key?(routes, class) do
          collect(rest, node_id, Map.put(routes, class, target), count + 1)
        else
          _ -> {:error, :invalid_input}
        end

      _ ->
        collect(rest, node_id, routes, count + 1)
    end
  end

  defp collect(_, _, _, _), do: {:error, :invalid_input}

  defp outcome_link(%{"outcome" => class, "to" => target}) when class in @classes do
    if text?(target), do: {:ok, class, target}, else: :error
  end

  defp outcome_link(_), do: :error

  defp text?(value),
    do: is_binary(value) and byte_size(value) in 1..128 and String.valid?(value)
end
