# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Debounce do
  @moduledoc "Bounded validating boundary for a pure trailing-edge debounce policy."
  @operator :"Cure.Elzoo.Debounce"
  @max_integer 9_223_372_036_854_775_807
  @max_quiet_ms 86_400_000
  @max_epoch_bytes 160
  @max_value_bytes 65_536

  def new(epoch, quiet_ms) do
    cond do
      not valid_epoch?(epoch) -> {:error, :invalid_epoch}
      not valid_quiet_ms?(quiet_ms) -> {:error, :invalid_quiet_ms}
      true -> {:ok, apply(@operator, :initial, [:binary.bin_to_list(epoch), quiet_ms])}
    end
  end

  def transition(state, command) do
    if valid_state?(state) do
      case normalize_command(command) do
        {:ok, cure_command} ->
          {:Transition, next_state, outcome} = apply(@operator, :transition, [state, cure_command])
          result(state, next_state, outcome)

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, :invalid_state, state}
    end
  end

  defp normalize_command({:put, now, value}) do
    cond do
      not valid_now?(now) -> {:error, :invalid_now}
      not valid_value?(value) -> {:error, :invalid_value}
      true -> {:ok, {:DebouncePut, now, :binary.bin_to_list(value)}}
    end
  end

  defp normalize_command({:timeout, now, token}) do
    with :ok <- validate_now(now),
         {:ok, epoch, generation} <- validate_token(token) do
      {:ok, {:DebounceTimeout, now, :binary.bin_to_list(epoch), generation}}
    end
  end

  defp normalize_command(:clear), do: {:ok, :DebounceClear}
  defp normalize_command(_), do: {:error, :invalid_command}

  defp validate_now(now), do: if(valid_now?(now), do: :ok, else: {:error, :invalid_now})

  defp validate_token({epoch, generation}) do
    cond do
      not valid_epoch?(epoch) -> {:error, :invalid_token}
      not valid_generation?(generation) or generation == 0 -> {:error, :invalid_token}
      true -> {:ok, epoch, generation}
    end
  end

  defp validate_token(_), do: {:error, :invalid_token}

  defp result(_state, next_state, {:some, {:DebounceScheduled, generation, due_at}}) do
    {:ok, next_state, {:schedule, {state_epoch(next_state), generation}, due_at}}
  end

  defp result(_state, next_state, {:some, {:DebounceEmitted, value}}) do
    {:ok, next_state, {:emit, :erlang.list_to_binary(value)}}
  end

  defp result(_state, next_state, {:some, {:DebounceCancelled, generation}}) do
    {:ok, next_state, {:cancel, {state_epoch(next_state), generation}}}
  end

  defp result(_state, next_state, {:some, :DebounceIgnored}), do: {:ok, next_state, :ignored}
  defp result(_state, next_state, {:some, :DebounceUnchanged}), do: {:ok, next_state, :unchanged}

  defp result(state, _next_state, {:some, {:DebounceRejected, :DebounceTimeRegression}}),
    do: {:error, :time_regression, state}

  defp result(state, _next_state, {:some, {:DebounceRejected, :DebounceDeadlineOverflow}}),
    do: {:error, :deadline_overflow, state}

  defp result(state, _next_state, {:some, {:DebounceRejected, :DebounceGenerationExhausted}}),
    do: {:error, :generation_exhausted, state}

  defp result(state, _next_state, _unexpected), do: {:error, :invalid_result, state}

  defp state_epoch({:DebounceState, epoch, _quiet_ms, _generation, _pending, _last_observed_now}),
    do: :erlang.list_to_binary(epoch)

  defp valid_state?({:DebounceState, epoch, quiet_ms, generation, pending, last_observed_now}) do
    valid_byte_list?(epoch, @max_epoch_bytes, 1) and
      valid_epoch?(:erlang.list_to_binary(epoch)) and
      valid_quiet_ms?(quiet_ms) and valid_generation?(generation) and
      valid_last_observed_now?(last_observed_now) and
      valid_pending?(pending, generation, last_observed_now)
  end

  defp valid_state?(_), do: false

  defp valid_pending?(:none, _generation, _last_observed_now), do: true

  defp valid_pending?(
         {:some, {:DebouncePending, value, generation, due_at}},
         current_generation,
         last_observed_now
       ) do
    valid_byte_list?(value, @max_value_bytes, 0) and valid_generation?(generation) and
      generation > 0 and generation == current_generation and valid_now?(due_at) and
      match?({:some, _}, last_observed_now)
  end

  defp valid_pending?(_, _, _), do: false

  defp valid_last_observed_now?(:none), do: true
  defp valid_last_observed_now?({:some, now}), do: valid_now?(now)
  defp valid_last_observed_now?(_), do: false

  defp valid_epoch?(epoch) when is_binary(epoch) and byte_size(epoch) in 1..@max_epoch_bytes do
    String.valid?(epoch) and :binary.match(epoch, <<0>>) == :nomatch
  end

  defp valid_epoch?(_), do: false

  defp valid_quiet_ms?(quiet_ms),
    do: is_integer(quiet_ms) and quiet_ms >= 1 and quiet_ms <= @max_quiet_ms

  defp valid_now?(now), do: is_integer(now) and now >= 0 and now <= @max_integer

  defp valid_generation?(generation),
    do: is_integer(generation) and generation >= 0 and generation <= @max_integer

  defp valid_value?(value) when is_binary(value), do: byte_size(value) <= @max_value_bytes
  defp valid_value?(_), do: false

  defp valid_byte_list?(bytes, max_bytes, min_bytes),
    do: scan_byte_list(bytes, max_bytes, min_bytes, 0)

  defp scan_byte_list([], _max_bytes, min_bytes, length), do: length >= min_bytes

  defp scan_byte_list([byte | tail], max_bytes, min_bytes, length)
       when length < max_bytes and is_integer(byte) and byte >= 0 and byte <= 255 do
    scan_byte_list(tail, max_bytes, min_bytes, length + 1)
  end

  defp scan_byte_list(_, _max_bytes, _min_bytes, _length), do: false
end
