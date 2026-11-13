# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.MidRunInput do
  @moduledoc "Pure policy: a new message during a Run follows the one rule that the Run declares."
  alias Elzoo.PatternStep

  @rules %{
    queue: :QueueRule,
    reject: :RejectRule,
    interrupt: :InterruptRule,
    steer: :SteerRule,
    side_run: :SideRunRule
  }
  @phases %{active: :RunActive, waiting: :RunWaiting, paused: :RunPaused, terminal: :RunTerminal}
  @bound 16

  @doc "Decides one checked input under the rule of the state. See the bundle README."
  def step(state, checked_input, run) do
    with true <- state?(state) and run?(run),
         {:ok, input} <- input(checked_input) do
      fill =
        case length(state.queue) do
          0 -> :QueueEmpty
          @bound -> :QueueFull
          _ -> :QueueHolding
        end

      decision =
        apply(:"Cure.Elzoo.MidRunInput", :decide, [
          Map.fetch!(@rules, state.rule),
          Map.fetch!(@phases, run.phase),
          input["kind"] == "message",
          fill
        ])

      project(state, input, run, decision)
    else
      _ -> {:error, :invalid_shape}
    end
  rescue
    # Checked PatternStep operands are opaque; malformed or forged operands stay redacted.
    _ in [FunctionClauseError, KeyError, BadMapError, MatchError] -> {:error, :invalid_shape}
  end

  @doc "Removes the oldest queued message, when the caller may start new work."
  def next(state) do
    case state?(state) && state.queue do
      false -> {:error, :invalid_shape}
      [] -> {:ok, state, :empty}
      [message | rest] -> {:ok, %{state | queue: rest}, {:deliver, message}}
    end
  end

  defp project(state, _, _, :MidPass), do: {:ok, state, :pass}
  defp project(state, message, _, :MidDeliver), do: {:ok, state, {:deliver, message}}

  defp project(state, message, _, :MidQueued),
    do: {:ok, %{state | queue: state.queue ++ [message]}, :queued}

  defp project(state, _, _, :MidQueueFull), do: {:ok, state, {:refused, :queue_full}}
  defp project(state, _, _, :MidRunBusy), do: {:ok, state, {:refused, :run_busy}}
  defp project(state, _, _, :MidRunEnded), do: {:ok, state, {:refused, :run_ended}}

  defp project(state, message, run, :MidInterrupt),
    do: {:ok, state, {:interrupt, message, report(run)}}

  defp project(state, message, run, :MidSideRun),
    do: {:ok, state, {:side_run, message, report(run)}}

  defp report(run), do: %{delivered: run.delivered, open: run.open}

  defp input({:PatternStep, %{"type" => "input"} = map}) do
    with {:ok, _} <- PatternStep.decode(map), do: {:ok, PatternStep.encode({:PatternStep, map})}
  end

  defp input(_), do: {:error, :invalid_shape}

  defp state?(%{rule: rule, queue: queue} = state)
       when map_size(state) == 2 and is_list(queue) and length(queue) <= @bound do
    Map.has_key?(@rules, rule) and
      Enum.all?(
        queue,
        &match?({:ok, {:PatternStep, %{"kind" => "message"}}}, PatternStep.decode(&1))
      )
  end

  defp state?(_), do: false

  defp run?(%{phase: phase, delivered: delivered, open: open} = run) when map_size(run) == 3 do
    Map.has_key?(@phases, phase) and ids?(delivered) and ids?(open) and
      MapSet.disjoint?(MapSet.new(delivered), MapSet.new(open))
  end

  defp run?(_), do: false

  defp ids?(ids), do: is_list(ids) and Enum.all?(ids, &text?/1)
  defp text?(value), do: is_binary(value) and value != "" and String.valid?(value)
end
