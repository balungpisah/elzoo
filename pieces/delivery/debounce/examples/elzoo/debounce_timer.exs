# SPDX-License-Identifier: Apache-2.0
# The host owns monotonic time and its origin, serialization, timer scheduling/cancellation, and epoch changes.
defmodule Elzoo.DebounceTimerExample do
  alias Elzoo.Debounce

  def run(value) when is_binary(value) do
    origin = System.monotonic_time(:millisecond)
    {:ok, state} = Debounce.new("example-epoch", 250)
    now = elapsed_ms(origin)
    {:ok, pending, {:schedule, token, due_at}} = Debounce.transition(state, {:put, now, value})

    await_timeout(pending, token, due_at, origin)
  end

  defp await_timeout(state, token, due_at, origin) do
    now = elapsed_ms(origin)
    Process.send_after(self(), {:debounce_timeout, token}, max(due_at - now, 0))

    receive do
      {:debounce_timeout, ^token} ->
        now = elapsed_ms(origin)

        case Debounce.transition(state, {:timeout, now, token}) do
          {:ok, _state, {:emit, value}} ->
            {:ok, value}

          {:ok, next_state, {:schedule, ^token, next_due_at}} ->
            await_timeout(next_state, token, next_due_at, origin)

          {:ok, next_state, :ignored} ->
            {:ignored, next_state}

          {:error, reason, ^state} ->
            {:error, reason}
        end
    after
      30_000 -> {:error, :timer_not_delivered}
    end
  end

  defp elapsed_ms(origin), do: System.monotonic_time(:millisecond) - origin
end
