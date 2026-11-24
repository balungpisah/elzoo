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
  @max_u32 4_294_967_295
  @jitters %{none: :JitterNone, full: :JitterFull}
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
      jitter = Keyword.get(opts, :jitter, :none)
      mfd = Keyword.get(opts, :max_failure_delay_ms, 3_600_000)

      cond do
        not (is_integer(max) and max >= 1) ->
          {:error, :invalid_max_attempts}

        not (is_integer(base) and is_integer(cap) and base >= 0 and cap >= base) ->
          {:error, :invalid_backoff}

        mode not in [:redispatch_forbidden, :redispatch_idempotent] ->
          {:error, :invalid_mode}

        not is_map_key(@jitters, jitter) ->
          {:error, :invalid_jitter}

        not (is_integer(mfd) and mfd in 0..@max_u32) ->
          {:error, :invalid_max_failure_delay}

        true ->
          mode =
            if mode == :redispatch_forbidden, do: :RedispatchForbidden, else: :RedispatchIdempotent

          {:ok, {:RetryPolicy, max, base, cap, mode, @jitters[jitter], mfd}}
      end
    else
      {:error, :invalid_options}
    end
  end

  def valid_policy?({:RetryPolicy, max, base, cap, mode, jitter, mfd}),
    do:
      is_integer(max) and max >= 1 and is_integer(base) and base >= 0 and
        is_integer(cap) and cap >= base and mode in [:RedispatchForbidden, :RedispatchIdempotent] and
        jitter in [:JitterNone, :JitterFull] and is_integer(mfd) and mfd in 0..@max_u32

  def valid_policy?(_), do: false

  def classify(result) do
    with {:ok, record} <- Elzoo.Envelope.decode_result(result),
         do: {:ok, Map.fetch!(@classes, apply(@cure, :classify, [record]))}
  end

  def decide(policy, attempt, class) do
    with :ok <- valid_call(policy, attempt),
         {:ok, tag} <- class_tag(class) do
      {:ok, Map.fetch!(@decisions, apply(@cure, :decide, [policy, attempt, tag]))}
    end
  end

  def backoff(policy, attempt) do
    with :ok <- valid_call(policy, attempt),
         do: {:ok, apply(@cure, :backoff, [policy, attempt])}
  end

  def delay(policy, attempt, class, input) do
    with :ok <- valid_call(policy, attempt),
         {:ok, tag} <- class_tag(class),
         {:ok, failure, random} <- delay_input(input) do
      {:ok, apply(@cure, :delay, [policy, attempt, tag, failure, random])}
    end
  end

  defp delay_input(%{failure_delay_ms: fd, random: r} = input)
       when map_size(input) == 2 and (is_nil(fd) or (is_integer(fd) and fd >= 0)) and
              is_integer(r) and r >= 0 and r <= @max_u32,
       do: {:ok, if(is_nil(fd), do: :none, else: {:some, fd}), r}

  defp delay_input(_), do: {:error, :invalid_delay_input}

  defp class_tag(class) do
    case Enum.find(@classes, fn {_, value} -> value == class end) do
      {tag, _} -> {:ok, tag}
      nil -> {:error, :invalid_class}
    end
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
