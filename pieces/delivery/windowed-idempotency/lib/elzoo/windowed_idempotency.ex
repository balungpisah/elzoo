# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.WindowedIdempotency do
  @moduledoc "Validating boundary for volatile sequence-window duplicate and stale suppression."
  @receiver :"Cure.Elzoo.WindowedIdempotency"
  @decisions %{
    WindowFresh: :fresh,
    WindowAdvance: :advance,
    WindowReorder: :reorder,
    WindowDuplicate: :duplicate,
    WindowStale: :stale,
    WindowSuperseded: :superseded,
    WindowNewIncarnation: :new_incarnation,
    WindowFull: :full
  }

  def new(window, max_senders) do
    cond do
      not (is_integer(window) and window >= 1) -> {:error, :invalid_window}
      not (is_integer(max_senders) and max_senders >= 1) -> {:error, :invalid_max_senders}
      true -> {:ok, apply(@receiver, :initial, [window, max_senders])}
    end
  end

  def unquote(:receive)(state, message) do
    with :ok <- validate(state, message) do
      {:Transition, next, output} = apply(@receiver, :receiver, [state, message])
      {:ok, {next, output}, decision(state, message)}
    end
  end

  def classify(state, message) do
    with :ok <- validate(state, message), do: {:ok, decision(state, message)}
  end

  defp decision(state, message),
    do: Map.fetch!(@decisions, apply(@receiver, :classify, [state, message]))

  defp validate(state, message) do
    cond do
      not valid_state?(state) -> {:error, :invalid_state}
      not valid_message?(message) -> {:error, :invalid_message}
      true -> :ok
    end
  end

  defp valid_message?({:Message, s, i, q, v}),
    do: is_integer(s) and is_integer(i) and is_integer(q) and is_integer(v)

  defp valid_message?(_), do: false

  defp valid_state?({:WindowedState, window, max_senders, senders})
       when is_integer(window) and window >= 1 and is_integer(max_senders) and max_senders >= 1 do
    proper_list?(senders) and length(senders) <= max_senders and
      Enum.all?(senders, &valid_entry?(&1, window)) and
      length(Enum.uniq_by(senders, &elem(&1, 1))) == length(senders)
  end

  defp valid_state?(_), do: false

  defp valid_entry?({:SenderWindow, sender, incarnation, high, accepted}, window)
       when is_integer(sender) and is_integer(incarnation) and is_integer(high) do
    proper_list?(accepted) and accepted != [] and
      Enum.all?(accepted, &(is_integer(&1) and &1 > high - window and &1 <= high)) and
      high in accepted and length(Enum.uniq(accepted)) == length(accepted)
  end

  defp valid_entry?(_, _), do: false
  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false
end
