# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ScheduleOccurrence do
  @moduledoc """
  Validating boundary for the pure schedule-occurrence policy
  (delivery/trigger, schedule slice). Due slots, the current instant and the
  availability boundary are UTC Unix milliseconds supplied by the caller; this
  module performs no I/O and reads no clock. Transitions must be applied by one
  serialized owner per schedule (a process or a compare-and-set store).
  """
  @cure :"Cure.Elzoo.ScheduleOccurrence"
  @idempotency :"Cure.Elzoo.Idempotency"
  @max_queue_bound 1024

  @typedoc "skip | replace | {:queue, n} with 1 <= n <= 1024"
  @type policy :: :skip | :replace | {:queue, pos_integer()}
  @type schedule :: %{
          schedule_id: String.t(),
          generation: non_neg_integer(),
          policy: policy(),
          payload: String.t()
        }
  @type arrival :: %{now_unix_ms: integer(), available_since_unix_ms: integer()}
  @type id :: {:OccurrenceId, String.t(), non_neg_integer(), integer()}

  # ------------------------------------------------------------ construction

  @doc "State with no unsettled occurrence; the caller chooses and records the initial watermark."
  def new(schedule, last_recorded_unix_ms) do
    with {:ok, record} <- schedule_record(schedule),
         :ok <- instant(last_recorded_unix_ms) do
      {:ok, apply(@cure, :initial, [record, last_recorded_unix_ms])}
    end
  end

  @doc """
  Rebuild a retained state after a restart from the schedule, the watermark and
  the unsettled occurrence ids (all of the current generation, at or below the
  watermark, within the policy bound). The caller owns storage.
  """
  def restore(schedule, last_recorded_unix_ms, unsettled_ids) do
    with {:ok, record} <- schedule_record(schedule),
         :ok <- instant(last_recorded_unix_ms),
         true <- proper_list?(unsettled_ids) || {:error, :invalid_unsettled} do
      payload = elem(record, 4)

      state =
        apply(@cure, :restored, [
          record,
          last_recorded_unix_ms,
          Enum.map(unsettled_ids, &{:Occurrence, &1, payload})
        ])

      if valid_state?(state), do: {:ok, state}, else: {:error, :invalid_unsettled}
    end
  end

  @doc "Occurrence identity: schedule id, generation and scheduled instant only."
  def identify(schedule_id, generation, scheduled_unix_ms)
      when is_binary(schedule_id) and schedule_id != "" and is_integer(generation) and
             generation >= 0 and is_integer(scheduled_unix_ms),
      do: apply(@cure, :identify, [schedule_id, generation, scheduled_unix_ms])

  def identify(_, _, _), do: {:error, :invalid_id}

  @doc "Derived text key `generation:instant:schedule_id`; numbers first so the id needs no escaping."
  def encode_id({:OccurrenceId, schedule_id, generation, scheduled_unix_ms} = id) do
    if valid_id?(id),
      do: {:ok, "#{generation}:#{scheduled_unix_ms}:#{schedule_id}"},
      else: {:error, :invalid_id}
  end

  def encode_id(_), do: {:error, :invalid_id}

  @doc "Inverse of encode_id/1."
  def decode_id(text) when is_binary(text) do
    with [generation, instant, schedule_id] <- String.split(text, ":", parts: 3),
         {generation, ""} <- Integer.parse(generation),
         {instant, ""} <- Integer.parse(instant),
         id = {:OccurrenceId, schedule_id, generation, instant},
         true <- valid_id?(id) do
      {:ok, id}
    else
      _ -> {:error, :invalid_encoded_id}
    end
  end

  def decode_id(_), do: {:error, :invalid_encoded_id}

  @doc "Schedule, watermark and unsettled ids of a valid state."
  def inspect_state({:ScheduleState, record, last, unsettled} = state) do
    if valid_state?(state) do
      {:ok,
       %{
         schedule: schedule_map(record),
         last_recorded_unix_ms: last,
         unsettled: Enum.map(unsettled, &elem(&1, 1))
       }}
    else
      {:error, :invalid_state}
    end
  end

  def inspect_state(_), do: {:error, :invalid_state}

  # ------------------------------------------------------------ admission

  @doc """
  Admit due slots computed upstream, in non-decreasing order, with the arrival
  `%{now_unix_ms, available_since_unix_ms}`. The caller establishes that the
  scheduler was continuously available from the boundary through now and that
  every unrecorded slot before the boundary passed while offline; this module
  validates the numbers only. The whole call is refused, without any
  transition, when a slot is after now, the boundary is after now, the batch
  is unsorted or a term is malformed. Returns the next state and one recorded
  decision per slot:
  `{:occurrence, id, :live | :offline_catch_up}`, `{:already_recorded, slot}`,
  `{:skipped, slot, :offline_catch_up | :overlap | :queue_full}`,
  `{:replaced, old_id, new_id}`.
  """
  def admit_slots(state, slots, arrival) do
    with true <- valid_state?(state) || {:error, :invalid_state},
         {:ok, {now, boundary}} <- arrival_record(arrival),
         true <-
           (proper_list?(slots) and Enum.all?(slots, &is_integer/1)) || {:error, :invalid_slots},
         true <- slots == Enum.sort(slots) || {:error, :unsorted_slots},
         nil <- Enum.find(slots, &(&1 > now)) |> late(now) do
      cure_arrival = {:Arrival, now, boundary}

      {next, decisions} =
        Enum.reduce(slots, {state, []}, fn slot, {acc, out} ->
          {:SlotResult, next, decision} = apply(@cure, :admit_slot, [acc, slot, cure_arrival])
          {next, [slot_decision(decision, slot) | out]}
        end)

      {:ok, next, Enum.reverse(decisions)}
    end
  end

  def admit_slot(state, slot, arrival) when is_integer(slot) do
    with {:ok, next, [decision]} <- admit_slots(state, [slot], arrival), do: {:ok, next, decision}
  end

  def admit_slot(_, _, _), do: {:error, :invalid_slots}

  defp late(nil, _), do: nil
  defp late(slot, _now), do: {:error, {:not_due, slot}}

  defp slot_decision({:Admitted, id, origin}, _), do: {:occurrence, id, origin(origin)}
  defp slot_decision({:AlreadyRecorded, slot}, _), do: {:already_recorded, slot}
  defp slot_decision(:SkippedOffline, slot), do: {:skipped, slot, :offline_catch_up}
  defp slot_decision(:SkippedOverlap, slot), do: {:skipped, slot, :overlap}
  defp slot_decision({:SkippedQueueFull, _origin}, slot), do: {:skipped, slot, :queue_full}
  defp slot_decision({:Replaced, old, new}, _), do: {:replaced, old, new}

  defp origin(:Live), do: :live
  defp origin(:CatchUp), do: :offline_catch_up

  # ------------------------------------------------------------ settlement

  @doc "Settle an unsettled occurrence as acknowledged or released; both are terminal."
  def settle(state, {kind, {:OccurrenceId, _, _, _} = id})
      when kind in [:acknowledged, :released] do
    with true <- valid_state?(state) || {:error, :invalid_state},
         true <- valid_id?(id) || {:error, :invalid_id} do
      cure_kind = if kind == :acknowledged, do: :Acknowledged, else: :Released
      {:SettlementResult, next, decision} = apply(@cure, :settle, [state, id, cure_kind])

      result =
        case decision do
          {:Settled, _} -> {:settled, kind, id}
          {:RejectedSettlement, :StaleGeneration} -> {:rejected, :stale_generation}
          {:RejectedSettlement, :UnknownOccurrence} -> {:rejected, :unknown_occurrence}
        end

      {:ok, next, result}
    end
  end

  def settle(_, _), do: {:error, :invalid_settlement}

  @doc """
  Translate a validated core/envelope DeliveryResult into a settlement for the
  occurrence named by its `correlation_id` (an encoded id): `completed`
  acknowledges, `rejected` and `failed` release, `timed_out` and `unknown`
  settle nothing (unknown external outcome is never treated as no effect).
  """
  def settlement_from_result(result) do
    with {:ok, result} <- Elzoo.Envelope.validate_result(result),
         {:ok, id} <- decode_id(result["correlation_id"]) do
      case result["outcome"] do
        "completed" -> {:ok, {:acknowledged, id}}
        "rejected" -> {:ok, {:released, id}}
        "failed" -> {:ok, {:released, id}}
        other when other in ["timed_out", "unknown"] -> {:ok, :no_settlement}
        _ -> {:error, :unknown_outcome}
      end
    else
      {:error, :invalid_encoded_id} -> {:error, :invalid_correlation_id}
      other -> other
    end
  end

  # ------------------------------------------------------------ delivery admission (query)

  @doc "Admit a presented delivery when its id is unsettled and its payload matches; the state never changes."
  def admit_delivery(state, {:OccurrenceId, _, _, _} = id, payload) when is_binary(payload) do
    with true <- valid_state?(state) || {:error, :invalid_state},
         true <- valid_id?(id) || {:error, :invalid_id} do
      case apply(@cure, :admit_delivery, [state, id, payload]) do
        :AdmittedDelivery -> {:ok, :admitted}
        {:RejectedDelivery, :DeliveryStaleGeneration} -> {:ok, {:rejected, :stale_generation}}
        {:RejectedDelivery, :DeliveryUnknownOccurrence} -> {:ok, {:rejected, :unknown_occurrence}}
        {:RejectedDelivery, :PayloadMismatch} -> {:ok, {:rejected, :payload_mismatch}}
      end
    end
  end

  def admit_delivery(_, _, _), do: {:error, :invalid_delivery}

  @doc """
  Consumer-side duplicate suppression with the real delivery/idempotency
  receiver, one history per schedule id. `histories` is a map held by the
  consumer owner (start with `%{}`). Inside a history the message key is
  sender 0, incarnation = generation, sequence = scheduled instant, so two
  schedules never share a key. Returns `{:ok, histories, :emit | :suppress}`.
  History retention is the idempotency Piece's own: unbounded, volatile.
  """
  def consumer_dedup(histories, {:OccurrenceId, schedule_id, generation, instant} = id, value)
      when is_map(histories) and is_integer(value) do
    if valid_id?(id) do
      history = Map.get(histories, schedule_id, [])
      message = apply(@idempotency, :message, [0, generation, instant, value])

      {:Transition, next, output} = apply(@idempotency, :receiver, [history, message])
      {:ok, Map.put(histories, schedule_id, next), if(output == :none, do: :suppress, else: :emit)}
    else
      {:error, :invalid_id}
    end
  end

  def consumer_dedup(_, _, _), do: {:error, :invalid_delivery}

  @doc "Retire a schedule's idempotency history; later presentations emit again."
  def forget_schedule(histories, schedule_id) when is_map(histories) and is_binary(schedule_id),
    do: {:ok, Map.delete(histories, schedule_id)}

  def forget_schedule(_, _), do: {:error, :invalid_schedule_id}

  # ------------------------------------------------------------ redefinition

  @doc "Replace the definition with the same id and a strictly greater generation; unsettled occurrences are superseded."
  def redefine(state, schedule) do
    with true <- valid_state?(state) || {:error, :invalid_state},
         {:ok, record} <- schedule_record(schedule) do
      {:ScheduleState, {:Schedule, _, old_generation, _, _}, _, _} = state
      {:RedefinitionResult, next, decision} = apply(@cure, :redefine, [state, record])

      result =
        case decision do
          {:Redefined, superseded} -> {:redefined, old_generation, superseded}
          {:RejectedRedefinition, :RedefinitionStaleGeneration} -> {:rejected, :stale_generation}
          {:RejectedRedefinition, :ScheduleMismatch} -> {:rejected, :schedule_mismatch}
          {:RejectedRedefinition, :RedefinitionInvalid} -> {:rejected, :invalid_schedule}
        end

      {:ok, next, result}
    end
  end

  # ------------------------------------------------------------ validation

  defp schedule_record(%{schedule_id: sid, generation: gen, policy: policy, payload: payload}) do
    cond do
      not (is_binary(sid) and sid != "") ->
        {:error, :invalid_schedule_id}

      not (is_integer(gen) and gen >= 0) ->
        {:error, :invalid_generation}

      not is_binary(payload) ->
        {:error, :invalid_payload}

      true ->
        case policy do
          :skip ->
            {:ok, {:Schedule, sid, gen, :Skip, payload}}

          :replace ->
            {:ok, {:Schedule, sid, gen, :Replace, payload}}

          {:queue, n} when is_integer(n) and n >= 1 and n <= @max_queue_bound ->
            {:ok, {:Schedule, sid, gen, {:Queue, peano(n)}, payload}}

          _ ->
            {:error, :invalid_policy}
        end
    end
  end

  defp schedule_record(_), do: {:error, :invalid_schedule}

  defp arrival_record(%{now_unix_ms: now, available_since_unix_ms: boundary})
       when is_integer(now) and is_integer(boundary) do
    if boundary <= now, do: {:ok, {now, boundary}}, else: {:error, :boundary_after_now}
  end

  defp arrival_record(%{now_unix_ms: now} = arrival) when is_integer(now) do
    if Map.has_key?(arrival, :available_since_unix_ms),
      do: {:error, :invalid_arrival},
      else: {:error, :missing_availability_boundary}
  end

  defp arrival_record(_), do: {:error, :invalid_arrival}

  defp instant(value) when is_integer(value), do: :ok
  defp instant(_), do: {:error, :invalid_instant}

  defp peano(0), do: :Z
  defp peano(n), do: {:S, peano(n - 1)}

  defp unpeano(:Z), do: 0
  defp unpeano({:S, n}), do: 1 + unpeano(n)

  defp schedule_map({:Schedule, sid, gen, policy, payload}),
    do: %{schedule_id: sid, generation: gen, policy: policy_map(policy), payload: payload}

  defp policy_map(:Skip), do: :skip
  defp policy_map(:Replace), do: :replace
  defp policy_map({:Queue, n}), do: {:queue, unpeano(n)}

  defp valid_state?(
         {:ScheduleState, {:Schedule, sid, gen, policy, payload} = record, last, unsettled}
       )
       when is_integer(last) do
    with true <- valid_policy_term?(policy),
         {:ok, ^record} <- schedule_record(schedule_map(record)) do
      proper_list?(unsettled) and
        Enum.all?(unsettled, &valid_occurrence?(&1, sid, gen, payload, last)) and
        length(Enum.uniq_by(unsettled, &elem(&1, 1))) == length(unsettled) and
        length(unsettled) <= bound(policy)
    else
      _ -> false
    end
  end

  defp valid_state?(_), do: false

  defp valid_policy_term?(:Skip), do: true
  defp valid_policy_term?(:Replace), do: true
  defp valid_policy_term?({:Queue, n}), do: valid_peano?(n, @max_queue_bound)
  defp valid_policy_term?(_), do: false

  defp valid_peano?(:Z, _), do: true
  defp valid_peano?({:S, n}, budget) when budget > 0, do: valid_peano?(n, budget - 1)
  defp valid_peano?(_, _), do: false

  defp bound(:Skip), do: 1
  defp bound(:Replace), do: 1
  defp bound({:Queue, n}), do: unpeano(n)

  defp valid_occurrence?(
         {:Occurrence, {:OccurrenceId, sid, gen, slot}, payload},
         sid,
         gen,
         payload,
         last
       ),
       do: is_integer(slot) and slot <= last

  defp valid_occurrence?(_, _, _, _, _), do: false

  defp valid_id?({:OccurrenceId, sid, gen, slot}),
    do: is_binary(sid) and sid != "" and is_integer(gen) and gen >= 0 and is_integer(slot)

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false
end
