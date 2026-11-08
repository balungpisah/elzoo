# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.EffectIntent.Policy do
  @moduledoc false
  alias Elzoo.EffectIntent.Binding
  @core :"Cure.Elzoo.EffectIntentPolicy"
  @events [
    :Admit,
    :Arm,
    :NoSend,
    :PermanentNoSend,
    :Lost,
    :TimedOut,
    :Failed,
    :Pending,
    :NoEffect,
    :ProviderUnknown,
    :Completed,
    :Resume,
    :Rearm,
    :Expired,
    :SchemaInvalid,
    :CapacityRefused,
    :Uncertain,
    :Recover,
    :Revise,
    :Contradiction,
    :Refused
  ]
  @grounds [:AdapterNoSend, :ProviderNoEffect, :ProviderReplaySafe]
  @outcomes [:Awaiting, :SentNoBytes, :FinalNoEffect, :ReplayCovered, :EffectCompleted]
  def initial, do: apply(@core, :initial, [])
  def count({:State, p, _, _, _, _, _, _}), do: phase_count(p)
  def revisions({:State, _, _, _, _, _, r, _}), do: r
  def phase({:State, p, _, _, _, _, _, _}), do: p

  def flags({:State, _, d, q, dep, ever, _, _}),
    do: %{disarmed: d, quarantined: q, replay_dependent: dep, ever_possibly_sent: ever}

  def history({:State, _, _, _, _, _, _, h}), do: h
  def event?(e), do: e in @events
  def classify(state, event, attempt), do: apply(@core, :classify_event, [state, event, attempt])

  def decide(state, event, attempt, config),
    do: apply(@core, :decide, [state, event, attempt, config])

  def permitted?(state, :Arm, config), do: apply(@core, :can_arm, [state, config])
  def permitted?(state, :Rearm, config), do: apply(@core, :can_rearm, [state, config])
  def permitted?(state, :Revise, config), do: apply(@core, :can_revise, [state, config])

  def config(binding, deadline, anchor, now) do
    with true <- Binding.uint?(now),
         true <- anchor == nil or Binding.uint?(anchor),
         {:ok, recovery} <- Binding.recovery_deadline(deadline, binding.recovery_grace_ms) do
      base = anchor || now

      {cap, horizon, flight, allowance} =
        case binding.replay do
          :none ->
            {:NoReplay, base, 0, 0}

          %{window_ms: w, max_flight_ms: f, clock_allowance_ms: a} ->
            if Binding.uint?(base + w),
              do: {:ReplaySafe, base + w, f, a},
              else: {:NoReplay, base, 0, 0}
        end

      {:ok,
       {:Config, now, deadline, base, horizon, flight, allowance, cap, recovery,
        binding.revision == :same_key_changed_arguments}}
    else
      _ -> {:error, :clock_or_deadline}
    end
  end

  def valid_config?(
        {:Config, now, deadline, anchor, horizon, flight, allowance, cap, recovery, rev}
      ) do
    Enum.all?([now, deadline, anchor, horizon, flight, allowance], &Binding.uint?/1) and
      cap in [:NoReplay, :ReplaySafe] and is_boolean(rev) and
      (recovery == :NoRecovery or
         match?(
           {:RecoveryAt, n} when is_integer(n) and n >= 0 and n <= 9_223_372_036_854_775_807,
           recovery
         ))
  end

  def valid_config?(_), do: false

  def valid?({:State, phase, d, q, dep, ever, r, h}) do
    is_boolean(d) and is_boolean(q) and is_boolean(dep) and is_boolean(ever) and
      is_integer(r) and r in 0..256 and is_list(h) and length(h) <= 256 and
      Enum.all?(h, &(&1 in @outcomes)) and valid_phase?(phase) and
      length(h) == phase_count(phase) and phase_count(phase) + r <= 256 and
      (h == [] or ever) and (not dep or ever) and history_valid?(phase, h, dep)
  rescue
    _ -> false
  end

  def valid?(_), do: false
  defp history_valid?(:Empty, [], false), do: true
  defp history_valid?({:Intended, :Fresh, 0}, [], false), do: true

  defp history_valid?(phase, [head | tail], dependent) do
    tail_ok = Enum.all?(tail, &(&1 in [:SentNoBytes, :FinalNoEffect, :ReplayCovered]))

    requires_replay =
      :ReplayCovered in tail or match?({:Intended, {:After, :ProviderReplaySafe}, _}, phase)

    consistent =
      case phase do
        {:Intended, {:After, g}, _} -> head == outcome(g)
        {:Dispatched, :Fresh, 1} -> head == :Awaiting and tail == []
        {:Dispatched, {:After, g}, _} -> head == :Awaiting and tail != [] and hd(tail) == outcome(g)
        {:Definite, g, _} -> head == outcome(g)
        {tag, n} when tag in [:Confirmed, :Stranded] -> n > 0
        _ -> false
      end

    tail_ok and consistent and (not requires_replay or dependent)
  end

  defp history_valid?(_, _, _), do: false
  defp outcome(:AdapterNoSend), do: :SentNoBytes
  defp outcome(:ProviderNoEffect), do: :FinalNoEffect
  defp outcome(:ProviderReplaySafe), do: :ReplayCovered

  defp valid_phase?(:Empty), do: true
  defp valid_phase?({tag, n}) when tag in [:Confirmed, :Stranded], do: is_integer(n) and n in 0..256
  defp valid_phase?({:Definite, g, n}), do: g in @grounds and is_integer(n) and n in 1..256

  defp valid_phase?({tag, origin, n}) when tag in [:Intended, :Dispatched],
    do: valid_origin?(origin) and is_integer(n) and n in 0..256

  defp valid_phase?(_), do: false
  defp valid_origin?(:Fresh), do: true
  defp valid_origin?({:After, g}), do: g in @grounds
  defp valid_origin?(_), do: false
  defp phase_count(:Empty), do: 0
  defp phase_count({tag, n}) when tag in [:Confirmed, :Stranded], do: n
  defp phase_count({_, _, n}), do: n
end
