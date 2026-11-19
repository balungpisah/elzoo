# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PatternStep do
  @moduledoc "Exact v1/v2 pattern-step maps and pure, caller-owned request settlement."

  @actions ~w(model_call tool_call local_work ask_person nested_callable resource_open resource_use resource_close finish)
  @actions_v2 @actions ++ ["wait_event"]
  @outcomes ~w(completed failed refused late unknown out_of_budget retries_exhausted expired resource_lost)

  @opaque checked :: {:PatternStep, map()}
  @opaque tracker :: {:PatternStepTracker, %{String.t() => {String.t(), boolean()}}}
  @opaque checked_v2 :: {:PatternStepV2, map()}
  @opaque tracker_v2 :: {:PatternStepTrackerV2, %{String.t() => {String.t(), boolean()}}}

  @spec decode(term()) :: {:ok, checked()} | {:error, :invalid_shape}
  def decode(%{"type" => "request", "version" => 1, "actions" => actions} = map)
      when map_size(map) == 3 and is_list(actions) and length(actions) in 1..64 do
    valid =
      Enum.all?(actions, &action?/1) and
        MapSet.size(MapSet.new(actions, & &1["id"])) == length(actions)

    checked(map, valid)
  end

  def decode(%{"type" => "input", "version" => 1, "kind" => _, "at_ms" => at} = map)
      when is_integer(at) and at >= 0 do
    checked(map, input?(map))
  end

  def decode(_), do: {:error, :invalid_shape}

  @spec decode(term(), term()) :: {:ok, checked() | checked_v2()} | {:error, :invalid_shape}
  def decode(map, 1), do: decode(map)

  def decode(%{"type" => "request", "version" => 2, "actions" => actions} = map, 2)
      when map_size(map) == 3 and is_list(actions) and length(actions) in 1..64 do
    valid =
      Enum.all?(actions, &action_v2?/1) and
        MapSet.size(MapSet.new(actions, & &1["id"])) == length(actions)

    checked_v2(map, valid)
  end

  def decode(%{"type" => "input", "version" => 2, "kind" => _, "at_ms" => at} = map, 2)
      when is_integer(at) and at >= 0 do
    checked_v2(map, input_v2?(map))
  end

  def decode(_, 2), do: {:error, :invalid_shape}
  def decode(_, _), do: {:error, :invalid_shape}

  @spec encode(checked() | checked_v2()) :: map()
  def encode({:PatternStep, map}), do: map
  def encode({:PatternStepV2, map}), do: map

  @spec open(checked() | checked_v2()) :: tracker() | tracker_v2()
  def open({:PatternStep, %{"type" => "request", "actions" => actions}}) do
    {:PatternStepTracker, Map.new(actions, &{&1["id"], {&1["kind"], false}})}
  end

  def open({:PatternStepV2, %{"type" => "request", "actions" => actions}}) do
    {:PatternStepTrackerV2, Map.new(actions, &{&1["id"], {&1["kind"], false}})}
  end

  @spec accept(tracker() | tracker_v2(), checked() | checked_v2()) ::
          {:applied | :late, tracker() | tracker_v2()}
          | {:refused, atom(), tracker() | tracker_v2()}
  def accept({:PatternStepTracker, _} = tracker, {:PatternStepV2, %{"type" => "input"}}),
    do: {:refused, :incompatible_version, tracker}

  def accept({:PatternStepTrackerV2, _} = tracker, {:PatternStep, %{"type" => "input"}}),
    do: {:refused, :incompatible_version, tracker}

  def accept({:PatternStepTracker, actions} = tracker, {:PatternStep, %{"type" => "input"} = input}) do
    if input["kind"] in ["action_outcome", "person_answer"] do
      id = input["action_id"]
      {kind, settled} = Map.get(actions, id, {nil, false})

      compatible =
        if input["kind"] == "person_answer",
          do: kind == "ask_person",
          else: kind != "ask_person" or input["outcome"] != "completed"

      case apply(:"Cure.Elzoo.PatternStep", :decide, [
             kind != nil,
             settled,
             input["outcome"] == "late",
             compatible
           ]) do
        :PatternApplied -> {:applied, {:PatternStepTracker, Map.put(actions, id, {kind, true})}}
        :PatternLate -> {:late, tracker}
        :PatternRefused -> {:refused, :incompatible_answer_kind, tracker}
      end
    else
      {:refused, :not_an_outcome, tracker}
    end
  end

  def accept(
        {:PatternStepTrackerV2, actions} = tracker,
        {:PatternStepV2, %{"type" => "input"} = input}
      ) do
    if input["kind"] in ["action_outcome", "person_answer", "outside_event"] do
      id = input["action_id"]
      {kind, settled} = Map.get(actions, id, {nil, false})

      compatible =
        case input["kind"] do
          "person_answer" ->
            kind == "ask_person"

          "outside_event" ->
            kind == "wait_event"

          "action_outcome" ->
            (kind != "ask_person" or input["outcome"] != "completed") and
              (kind != "wait_event" or input["outcome"] != "completed")
        end

      reported_late = input["kind"] == "action_outcome" and input["outcome"] == "late"

      case apply(:"Cure.Elzoo.PatternStep", :decide, [
             kind != nil,
             settled,
             reported_late,
             compatible
           ]) do
        :PatternApplied -> {:applied, {:PatternStepTrackerV2, Map.put(actions, id, {kind, true})}}
        :PatternLate -> {:late, tracker}
        :PatternRefused -> {:refused, :incompatible_answer_kind, tracker}
      end
    else
      {:refused, :not_an_outcome, tracker}
    end
  end

  defp checked(map, true), do: {:ok, {:PatternStep, map}}
  defp checked(_, false), do: {:error, :invalid_shape}
  defp checked_v2(map, true), do: {:ok, {:PatternStepV2, map}}
  defp checked_v2(_, false), do: {:error, :invalid_shape}

  defp action?(%{"id" => id, "kind" => kind} = action) when map_size(action) == 5 do
    text?(id) and kind in @actions and typed?(action)
  end

  defp action?(_), do: false

  defp action_v2?(%{"id" => id, "kind" => kind} = action) when map_size(action) == 5 do
    text?(id) and kind in @actions_v2 and typed?(action)
  end

  defp action_v2?(_), do: false

  defp input?(%{"kind" => kind} = input) do
    case kind do
      kind when kind in ~w(start message resource_event run_ended) ->
        map_size(input) == 7 and typed?(input)

      "action_outcome" ->
        map_size(input) == 9 and text?(input["action_id"]) and
          input["outcome"] in @outcomes and typed?(input)

      "person_answer" ->
        map_size(input) == 9 and text?(input["action_id"]) and
          text?(input["person_id"]) and typed?(input)

      "cancel" ->
        map_size(input) == 5 and text?(input["attempt_id"])

      "wake" ->
        map_size(input) == 4

      _ ->
        false
    end
  end

  defp input_v2?(%{"kind" => "outside_event"} = input) do
    map_size(input) == 11 and
      Enum.all?(
        [input["action_id"], input["source_id"], input["correlation_id"], input["event_id"]],
        &text?/1
      ) and
      typed?(input)
  end

  defp input_v2?(input), do: input?(input)

  defp typed?(%{"schema_id" => id, "schema_version" => version, "payload" => _}) do
    match?(
      {:ok, _},
      Elzoo.Port.decode(%{
        "id" => id,
        "direction" => "input",
        "schema_id" => id,
        "schema_version" => version
      })
    )
  end

  defp typed?(_), do: false
  defp text?(value), do: is_binary(value) and value != "" and String.valid?(value)
end
