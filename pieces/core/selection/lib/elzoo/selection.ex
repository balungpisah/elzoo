# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Selection do
  @moduledoc "Pure compatible-interface selection by explicit rank; no placement or lookup."

  def select(requirement, candidates) do
    with {:ok, checked} <- inspect_candidates(requirement, candidates) do
      case groups(checked) do
        [] when checked == [] ->
          {:error, {:selection, :missing}}

        [] ->
          failures = Enum.map(checked, fn {id, _rank, {:error, reason}} -> {id, reason} end)
          {:error, {:selection, {:incompatible, failures}}}

        [{_rank, [id]} | _] ->
          {:ok, id}

        [{_rank, ids} | _] ->
          {:error, {:selection, {:ambiguous, ids}}}
      end
    end
  end

  def rank(requirement, candidates) do
    with {:ok, checked} <- inspect_candidates(requirement, candidates), do: {:ok, groups(checked)}
  end

  defp inspect_candidates(requirement, candidates) do
    with {:ok, requirement} <- decode_requirement(requirement),
         {:ok, candidates} <- decode_candidates(candidates),
         :ok <- unique_ids(candidates) do
      checked =
        candidates
        |> Enum.sort_by(fn {id, _} -> id end)
        |> Enum.map(fn {id, candidate} ->
          result = apply(:"Cure.Elzoo.Selection", :compatible, [requirement, candidate])
          {id, elem(candidate, 4), compatibility(result)}
        end)

      {:ok, checked}
    end
  end

  defp decode_requirement(
         %{"upstream" => upstream, "downstream" => downstream, "delivery" => delivery} = requirement
       )
       when map_size(requirement) == 3 do
    with {:ok, upstream_record} <- requirement_port(upstream, "output", :invalid_upstream),
         {:ok, downstream_record} <- requirement_port(downstream, "input", :invalid_downstream),
         {:ok, _} <- phase(delivery_binding("requirement", downstream, delivery), :requirement) do
      {:ok, {:SelectionRequirement, upstream_record, downstream_record, text(delivery)}}
    end
  end

  defp decode_requirement(_), do: {:error, {:requirement, :invalid_shape}}

  defp requirement_port(port, direction, reason) do
    case Elzoo.Port.decode(port) do
      {:ok, record} ->
        if port["direction"] == direction,
          do: {:ok, record},
          else: {:error, {:requirement, reason}}

      {:error, _} ->
        {:error, {:requirement, reason}}
    end
  end

  defp decode_candidates(candidates) when is_list(candidates) do
    Enum.reduce_while(Enum.with_index(candidates), {:ok, []}, fn {candidate, index},
                                                                 {:ok, checked} ->
      case decode_candidate(candidate) do
        {:ok, record} -> {:cont, {:ok, [{candidate["piece_id"], record} | checked]}}
        {:error, reason} -> {:halt, {:error, {:candidate, index, reason}}}
      end
    end)
    |> case do
      {:ok, checked} -> {:ok, Enum.reverse(checked)}
      {:error, _} = error -> error
    end
  end

  defp decode_candidates(_), do: {:error, {:candidate, :invalid_shape}}

  defp decode_candidate(
         %{"piece_id" => id, "interface" => face, "delivery" => delivery, "rank" => rank} =
           candidate
       )
       when map_size(candidate) == 4 do
    with true <- text?(id),
         true <- is_integer(rank) and rank >= 0,
         {:ok, interface} <- Elzoo.Assembly.decode(face),
         {:ok, _} <- delivery_binding(id, face["input"], delivery) do
      {:ok, {:SelectionCandidate, text(id), interface, text(delivery), rank}}
    else
      false -> {:error, :invalid_shape}
      {:error, _} = error -> error
    end
  end

  defp decode_candidate(_), do: {:error, :invalid_shape}

  defp delivery_binding(unit, port, delivery) do
    Elzoo.Edge.decode_binding(%{
      "unit_id" => unit,
      "port" => port,
      "delivery" => delivery,
      "required_route" => false
    })
  end

  defp unique_ids(candidates) do
    duplicate =
      candidates
      |> Enum.frequencies_by(fn {id, _} -> id end)
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
      |> List.first()

    if duplicate, do: {:error, {:candidate, :duplicate_id, duplicate}}, else: :ok
  end

  defp groups(checked) do
    checked
    |> Enum.flat_map(fn
      {id, rank, {:ok, true}} -> [{rank, id}]
      {_, _, {:error, _}} -> []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {rank, ids} -> {rank, Enum.sort(ids)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp compatibility({:error, {:delivery, :delivery_mismatch}}), do: {:error, :delivery_mismatch}
  defp compatibility(result), do: result
  defp text?(value), do: is_binary(value) and String.valid?(value) and value != ""
  defp text(value), do: {:String, String.to_charlist(value)}
  defp phase({:ok, value}, _), do: {:ok, value}
  defp phase({:error, reason}, phase), do: {:error, {phase, reason}}
end
