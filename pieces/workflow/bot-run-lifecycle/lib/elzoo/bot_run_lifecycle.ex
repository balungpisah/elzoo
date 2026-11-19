# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.BotRunLifecycle do
  @moduledoc "Pure lifecycle over caller-owned waits and ready Run/PatternStep facts."
  alias Elzoo.{PatternStep, Run}

  @phases %{active: :Active, waiting: :Waiting, paused: :Paused, terminal: :Terminal}
  @waits [:model, :tool, :approval, :person, :child_run, :outside_event, :resource_event]

  @doc "See the bundle README for exact state, checked protocol and host Control operands."
  def step(state, input, context), do: step_version(state, input, context, 1)
  def step(state, input, context, 2), do: step_version(state, input, context, 2)
  def step(_, _, _, _), do: {:error, :invalid_shape}

  defp step_version(state, input, context, version) do
    with true <- state?(state, version) and context?(context),
         {:ok, event} <- input(input, version),
         true <- operands?(state, event, context, version) do
      {classification, candidate, wait_id} = classify(state, event, context, version)

      decision =
        apply(:"Cure.Elzoo.BotRunLifecycle", :decide, [
          Map.fetch!(@phases, state.phase),
          classification,
          context.budget_exhausted,
          context.budget_rule == :pause
        ])

      project(state, candidate, event, context, wait_id, decision)
    else
      _ -> {:error, :invalid_shape}
    end
  rescue
    # Checked PatternStep operands are opaque; malformed/forged operands stay redacted.
    _ in [FunctionClauseError, KeyError, BadMapError, MatchError] -> {:error, :invalid_shape}
  end

  defp input({:PatternStep, %{"type" => "input"} = map}, 1) do
    with {:ok, _} <- PatternStep.decode(map), do: {:ok, map}
  end

  defp input({:PatternStepV2, %{"type" => "input"} = map}, 2) do
    with {:ok, _} <- PatternStep.decode(map, 2), do: {:ok, map}
  end

  defp input(%{control: :pause, at_ms: at, attempt_id: id, pause_deadline: deadline} = map, version)
       when version in [1, 2] and map_size(map) == 4 do
    if time?(at) and text?(id) and time?(deadline) and deadline > at,
      do: {:ok, map},
      else: {:error, :invalid_shape}
  end

  defp input(
         %{control: :continue, at_ms: at, attempt_id: id, person_id: person, run_deadline: deadline} =
           map,
         version
       )
       when version in [1, 2] and map_size(map) == 5 do
    if time?(at) and text?(id) and text?(person) and time?(deadline) and deadline > at,
      do: {:ok, map},
      else: {:error, :invalid_shape}
  end

  defp input(_, _), do: {:error, :invalid_shape}

  defp state?(state, 1), do: state?(state, :PatternStepTracker)
  defp state?(state, 2), do: state?(state, :PatternStepTrackerV2)

  defp state?(
         %{
           phase: phase,
           waits: waits,
           tracker: {tag, actions},
           outcome: outcome,
           run_deadline: deadline,
           pause_deadline: pause
         } = state,
         expected_tag
       )
       when map_size(state) == 6 and is_map(waits) and is_map(actions) and tag == expected_tag do
    Map.has_key?(@phases, phase) and time?(deadline) and
      (is_nil(pause) or time?(pause)) and (phase != :paused or time?(pause)) and
      if(phase == :terminal, do: Run.outcome?(outcome), else: is_nil(outcome)) and
      Enum.all?(waits, fn
        {id, %{kind: kind, attempt_id: attempt, one_shot: once} = wait} ->
          wait_shape?(wait, kind, expected_tag) and text?(id) and text?(attempt) and kind in @waits and
            is_boolean(once) and (kind == :resource_event or once)

        _ ->
          false
      end)
  end

  defp state?(_, _), do: false

  defp wait_shape?(wait, :outside_event, :PatternStepTrackerV2) do
    map_size(wait) == 5 and text?(wait[:source_id]) and text?(wait[:correlation_id])
  end

  defp wait_shape?(wait, _, _), do: map_size(wait) == 3

  defp context?(%{
         current_attempt: current,
         originating_attempt: origin,
         budget_exhausted: empty,
         budget_rule: rule
       }) do
    text?(current) and (is_nil(origin) or text?(origin)) and is_boolean(empty) and
      rule in [:pause, :finish]
  end

  defp context?(_), do: false

  defp operands?(_state, event, context, version) do
    if version == 2 and event["kind"] == "outside_event" do
      verified_event?(context[:verified_event], event)
    else
      cond do
        event["kind"] == "run_ended" ->
          match?(%{outcome: _}, event["payload"]) and Run.outcome?(event["payload"].outcome)

        event[:control] == :continue ->
          text?(context[:verified_person]) and context.verified_person == event.person_id

        event["kind"] == "person_answer" ->
          text?(context[:verified_person]) and context.verified_person == event["person_id"]

        true ->
          true
      end
    end
  end

  defp verified_event?(
         %{source_id: source, correlation_id: correlation, event_id: id} = facts,
         event
       )
       when map_size(facts) == 3 do
    text?(source) and text?(correlation) and text?(id) and
      source == event["source_id"] and correlation == event["correlation_id"] and
      id == event["event_id"]
  end

  defp verified_event?(_, _), do: false

  defp classify(state, event, context, version) do
    origin = event[:attempt_id] || event["attempt_id"] || context.originating_attempt

    cond do
      state.phase == :terminal ->
        {:Work, state, nil}

      event["kind"] == "run_ended" ->
        {:Ended, state, nil}

      event["kind"] != "wake" and Run.classify_attempt(context.current_attempt, origin) == :stale ->
        {:OldAttempt, state, nil}

      at(event) >= state.run_deadline or
          (state.phase == :paused and at(event) >= state.pause_deadline) ->
        {:Expired, state, nil}

      event["kind"] == "cancel" ->
        {:Cancel, state, nil}

      event[:control] == :pause ->
        {:Pause, state, nil}

      event[:control] == :continue ->
        {:Continue, state, nil}

      event["kind"] in ["action_outcome", "person_answer", "resource_event"] ->
        correlate(state, event, context, version)

      event["kind"] == "outside_event" ->
        correlate(state, event, context, version)

      true ->
        {:Work, state, nil}
    end
  end

  defp correlate(state, event, context, version) do
    id = event["action_id"] || context[:wait_id]

    case Map.get(state.waits, id) do
      %{attempt_id: attempt} = wait ->
        cond do
          Run.classify_attempt(context.current_attempt, attempt) == :stale ->
            {:ClosedWait, state, id}

          event["kind"] == "resource_event" ->
            if wait.kind == :resource_event,
              do: {:Accepted, settle(state, id, wait.one_shot), id},
              else: {:ClosedWait, state, id}

          event["kind"] == "outside_event" ->
            if version == 2 and wait.kind == :outside_event and
                 wait.source_id == event["source_id"] and
                 wait.correlation_id == event["correlation_id"] do
              accept(state, event, id, version)
            else
              {:ClosedWait, state, id}
            end

          wait.kind not in [:model, :tool, :person] and
              not (version == 2 and event["kind"] == "action_outcome" and
                       wait.kind == :outside_event) ->
            {:Incompatible, state, id}

          true ->
            accept(state, event, id, version)
        end

      nil ->
        {:ClosedWait, state, id}
    end
  end

  defp accept(state, event, id, version) do
    case decode_event(event, version) do
      {:ok, checked} ->
        case PatternStep.accept(state.tracker, checked) do
          {:applied, tracker} ->
            {:Accepted, %{settle(state, id, true) | tracker: tracker}, id}

          {:late, _} ->
            {:ClosedWait, state, id}

          {:refused, _, _} ->
            {:Incompatible, state, id}
        end

      _ ->
        {:Incompatible, state, id}
    end
  end

  defp decode_event(event, 1), do: PatternStep.decode(event)
  defp decode_event(event, 2), do: PatternStep.decode(event, 2)

  defp settle(state, id, true), do: %{state | waits: Map.delete(state.waits, id)}
  defp settle(state, _, false), do: state

  defp project(state, _, _, _, _, :Unchanged), do: {:ok, state, :unchanged}
  defp project(state, _, _, _, _, :Late), do: {:ok, state, :late}

  defp project(state, _, event, _, _, :InstallOutcome),
    do: {:ok, %{state | phase: :terminal, outcome: event["payload"].outcome}, :unchanged}

  defp project(state, _, _, _, _, :RequestTime), do: {:ok, state, {:request_outcome, :out_of_time}}
  defp project(state, _, _, _, _, :RequestCancel), do: {:ok, state, {:request_outcome, :cancelled}}

  defp project(_, candidate, _, _, _, :RequestBudget),
    do: {:ok, candidate, {:request_outcome, :out_of_budget}}

  defp project(state, candidate, event, context, _, :EnterPause) do
    deadline =
      if state.phase == :paused,
        do: state.pause_deadline,
        else: event[:pause_deadline] || context[:pause_deadline]

    if time?(deadline) and deadline > at(event),
      do: {:ok, %{candidate | phase: :paused, pause_deadline: deadline}, :remain_paused},
      else: {:error, :invalid_shape}
  end

  defp project(_, candidate, event, _, _, :Resume) do
    phase = if map_size(candidate.waits) == 0, do: :active, else: :waiting
    decision = if phase == :active, do: :permit_new_work, else: :remain_waiting

    {:ok, %{candidate | phase: phase, pause_deadline: nil, run_deadline: event.run_deadline},
     decision}
  end

  defp project(_, candidate, _, _, id, :AcceptWait) do
    phase =
      cond do
        candidate.phase == :paused -> :paused
        map_size(candidate.waits) == 0 -> :active
        true -> candidate.phase
      end

    {:ok, %{candidate | phase: phase}, {:accept_wait, id}}
  end

  defp project(state, _, _, _, _, :RemainPaused), do: {:ok, state, :remain_paused}
  defp project(state, _, _, _, _, :RemainWaiting), do: {:ok, state, :remain_waiting}
  defp project(state, _, _, _, _, :PermitWork), do: {:ok, state, :permit_new_work}

  defp at(event), do: event[:at_ms] || event["at_ms"]
  defp time?(value), do: is_integer(value) and value >= 0
  defp text?(value), do: is_binary(value) and value != "" and String.valid?(value)
end
