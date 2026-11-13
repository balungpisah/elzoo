# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.StallDetect do
  @moduledoc "Pure stall verdict over a bounded window of one Run's v1 pattern-step record."

  alias Elzoo.PatternStep

  @type verdict :: :not_stalled | {:stalled, :repeated_action | :no_input}

  @spec verdict(term(), term(), term(), term()) ::
          {:ok, verdict()} | {:error, :window_too_large | :invalid_shape}
  def verdict(window, _limits, _now_ms, _approval_waits)
      when is_list(window) and length(window) > 256,
      do: {:error, :window_too_large}

  def verdict(window, %{repeats: repeats, idle_ms: idle_ms} = limits, now_ms, approval_waits)
      when is_list(window) and length(window) in 1..256 and map_size(limits) == 2 and
             is_integer(repeats) and repeats in 2..256 and is_integer(idle_ms) and idle_ms > 0 and
             is_integer(now_ms) and now_ms >= 0 and is_list(approval_waits) and
             length(approval_waits) <= 64 do
    checked = Enum.map(window, &PatternStep.decode/1)

    inputs =
      for {{:ok, _}, %{"type" => "input", "kind" => kind} = map} <- Enum.zip(checked, window),
          kind != "wake",
          do: map["at_ms"]

    if Enum.all?(checked, &match?({:ok, _}, &1)) and inputs != [] and
         Enum.all?(approval_waits, &text?/1) do
      entries = Enum.zip(window, Enum.map(checked, &elem(&1, 1)))
      {:ok, decide(entries, repeats, now_ms - Enum.max(inputs) >= idle_ms, approval_waits)}
    else
      {:error, :invalid_shape}
    end
  end

  def verdict(_, _, _, _), do: {:error, :invalid_shape}

  defp decide(entries, repeats, idle?, approval_waits) do
    requests = for {%{"type" => "request"} = map, _} <- entries, do: map["actions"]
    all = for actions <- requests, action <- actions, do: identity(action)
    newest = List.last(requests, [])

    cond do
      Enum.any?(newest, fn action ->
        key = identity(action)
        Enum.count(all, &(&1 === key)) >= repeats
      end) ->
        {:stalled, :repeated_action}

      idle? and not healthy_wait?(entries, approval_waits) ->
        {:stalled, :no_input}

      true ->
        :not_stalled
    end
  end

  defp identity(action),
    do: {action["kind"], action["schema_id"], action["schema_version"], action["payload"]}

  defp healthy_wait?([], _approval_waits), do: false

  defp healthy_wait?([{%{"type" => "request", "actions" => actions}, checked} | later], waits) do
    open?(actions, checked, later, waits) or healthy_wait?(later, waits)
  end

  defp healthy_wait?([_input | later], waits), do: healthy_wait?(later, waits)

  defp open?(actions, checked, later, waits) do
    {_tracker, settled} =
      Enum.reduce(later, {PatternStep.open(checked), MapSet.new()}, fn {map, input}, acc ->
        settle(acc, map, input)
      end)

    Enum.any?(actions, fn %{"id" => id, "kind" => kind} ->
      not MapSet.member?(settled, id) and (kind == "ask_person" or id in waits)
    end)
  end

  defp settle({tracker, settled}, %{"type" => "input"} = map, input) do
    case PatternStep.accept(tracker, input) do
      {:applied, tracker} -> {tracker, MapSet.put(settled, map["action_id"])}
      {_, tracker} -> {tracker, settled}
      {_, _, tracker} -> {tracker, settled}
    end
  end

  defp settle(acc, _request, _checked), do: acc

  defp text?(value), do: is_binary(value) and value != "" and String.valid?(value)
end
