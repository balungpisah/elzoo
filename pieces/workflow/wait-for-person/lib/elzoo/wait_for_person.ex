# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.WaitForPerson do
  @moduledoc "Pure policy: a Run asks a named person and continues with the answer or the time-out."
  alias Elzoo.PatternStep

  @doc "Decides one checked input against the open asks of one request. See the bundle README."
  def step(state, checked_input, verified_person) do
    with true <- state?(state) and (is_nil(verified_person) or text?(verified_person)),
         {:ok, input} <- input(checked_input) do
      kind =
        case input["kind"] do
          "action_outcome" -> :OutcomeInput
          "person_answer" -> :AnswerInput
          _ -> :OtherInput
        end

      id = input["action_id"]
      named = Map.get(state.asks, id)

      {settlement, tracker} =
        case PatternStep.accept(state.tracker, checked_input) do
          {:applied, tracker} -> {:SettleApplied, tracker}
          {:late, _} -> {:SettleLate, nil}
          {:refused, _, _} -> {:SettleRefused, nil}
        end

      same_person = named == input["person_id"] and named == verified_person

      decision =
        apply(:"Cure.Elzoo.WaitForPerson", :decide, [kind, named != nil, settlement, same_person])

      project(state, id, input, tracker, decision)
    else
      _ -> {:error, :invalid_shape}
    end
  rescue
    # Checked PatternStep operands are opaque; malformed or forged operands stay redacted.
    _ in [FunctionClauseError, KeyError, BadMapError, MatchError] -> {:error, :invalid_shape}
  end

  @doc "Chooses which input the host records for text from a verified person."
  def route(asks, verified_person) do
    if asks?(asks) and text?(verified_person) do
      case for({id, ^verified_person} <- asks, do: id) do
        [] -> :message
        [id] -> {:answer, id}
        _ -> {:refused, :ambiguous_ask}
      end
    else
      {:error, :invalid_shape}
    end
  end

  defp project(state, _, _, _, :AskPass), do: {:ok, state, :pass}
  defp project(state, _, _, _, :AskLate), do: {:ok, state, :late}

  defp project(state, _, _, _, :AskIncompatible),
    do: {:ok, state, {:refused, :incompatible_answer_kind}}

  defp project(state, _, _, _, :AskWrongPerson), do: {:ok, state, {:refused, :wrong_person}}

  defp project(state, id, input, tracker, :AskClosed),
    do: {:ok, close(state, id, tracker), {:closed, id, input["outcome"]}}

  defp project(state, id, _, tracker, :AskAnswer),
    do: {:ok, close(state, id, tracker), {:answer, id}}

  defp close(state, id, tracker), do: %{state | asks: Map.delete(state.asks, id), tracker: tracker}

  defp input({:PatternStep, %{"type" => "input"} = map}) do
    with {:ok, _} <- PatternStep.decode(map), do: {:ok, map}
  end

  defp input(_), do: {:error, :invalid_shape}

  defp state?(%{asks: asks, tracker: {:PatternStepTracker, actions}} = state)
       when map_size(state) == 2 and is_map(actions) and is_map(asks) and map_size(asks) <= 64,
       do: asks?(asks)

  defp state?(_), do: false

  defp asks?(asks) when is_map(asks),
    do: Enum.all?(asks, fn {id, person} -> text?(id) and text?(person) end)

  defp asks?(_), do: false

  defp text?(value), do: is_binary(value) and value != "" and String.valid?(value)
end
