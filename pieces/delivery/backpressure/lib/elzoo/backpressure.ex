# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Backpressure do
  @moduledoc "Pure in-flight capacity, with zero waiting queue and no shedding."
  @cure :"Cure.Elzoo.Backpressure"

  def new(capacity) when is_integer(capacity) and capacity > 0,
    do: {:ok, apply(@cure, :initial, [capacity])}

  def new(_), do: {:error, :invalid_capacity}

  def admit(state) do
    if valid?(state) do
      decision = apply(@cure, :classify_admit, [state])
      next = apply(@cure, :admit_step, [state, decision])
      {:ok, next, if(decision == :Admitted, do: :admitted, else: :saturated)}
    else
      {:error, :invalid_state}
    end
  end

  def release(state) do
    if valid?(state) do
      case apply(@cure, :classify_release, [state]) do
        :Released -> {:ok, apply(@cure, :release_step, [state, :Released])}
        :ReleaseUnderflow -> {:error, :release_underflow}
      end
    else
      {:error, :invalid_state}
    end
  end

  defp valid?({:CapacityState, c, n}),
    do: is_integer(c) and c > 0 and is_integer(n) and n >= 0 and n <= c

  defp valid?(_), do: false
end
