# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RetryTimeout do
  @moduledoc "Validated local retry policy. Idempotent redispatch is an unverified caller assertion."
  @cure :"Cure.Elzoo.RetryPolicy"
  @classes %{
    ClassCompleted: :completed,
    ClassPermanent: :permanent,
    ClassRetryable: :retryable,
    ClassDispatched: :dispatched
  }
  @decisions %{
    DecideSettle: :settle,
    DecideRetry: :retry,
    DecidePermanent: :permanent,
    DecideExhausted: :exhausted,
    DecideUnresolved: :unresolved
  }

  def policy(opts) do
    if proper_list?(opts) and Keyword.keyword?(opts) do
      max = Keyword.get(opts, :max_attempts, 3)
      base = Keyword.get(opts, :base_backoff_ms, 10)
      cap = Keyword.get(opts, :max_backoff_ms, 1000)
      mode = Keyword.get(opts, :mode, :redispatch_forbidden)

      cond do
        not (is_integer(max) and max >= 1) ->
          {:error, :invalid_max_attempts}

        not (is_integer(base) and is_integer(cap) and base >= 0 and cap >= base) ->
          {:error, :invalid_backoff}

        mode not in [:redispatch_forbidden, :redispatch_idempotent] ->
          {:error, :invalid_mode}

        true ->
          {:ok,
           {:RetryPolicy, max, base, cap,
            if(mode == :redispatch_forbidden, do: :RedispatchForbidden, else: :RedispatchIdempotent)}}
      end
    else
      {:error, :invalid_options}
    end
  end

  def valid_policy?({:RetryPolicy, max, base, cap, mode}),
    do:
      is_integer(max) and max >= 1 and is_integer(base) and base >= 0 and
        is_integer(cap) and cap >= base and mode in [:RedispatchForbidden, :RedispatchIdempotent]

  def valid_policy?(_), do: false

  def classify(result) do
    with {:ok, record} <- Elzoo.Envelope.decode_result(result),
         do: {:ok, Map.fetch!(@classes, apply(@cure, :classify, [record]))}
  end

  def decide(policy, attempt, class) do
    with :ok <- valid_call(policy, attempt),
         {tag, _} <- Enum.find(@classes, {nil, nil}, fn {_, value} -> value == class end),
         false <- is_nil(tag) do
      {:ok, Map.fetch!(@decisions, apply(@cure, :decide, [policy, attempt, tag]))}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_class}
    end
  end

  def backoff(policy, attempt) do
    with :ok <- valid_call(policy, attempt),
         do: {:ok, apply(@cure, :backoff, [policy, attempt])}
  end

  defp valid_call(policy, attempt) do
    cond do
      not valid_policy?(policy) -> {:error, :invalid_policy}
      not (is_integer(attempt) and attempt >= 1) -> {:error, :invalid_attempt}
      true -> :ok
    end
  end

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false
end
