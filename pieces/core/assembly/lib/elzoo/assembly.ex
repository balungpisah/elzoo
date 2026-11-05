# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Assembly do
  @moduledoc "Compose declared interfaces; execution still uses core/operator's compose."

  @doc "Validate a one-input/one-output interface and translate it to Cure."
  def decode(%{"input" => input, "output" => output} = face) when map_size(face) == 2 do
    with {:input, {:ok, input}} <- {:input, Elzoo.Port.decode(input)},
         {:output, {:ok, output}} <- {:output, Elzoo.Port.decode(output)} do
      apply(:"Cure.Elzoo.Assembly", :validate, [{:Interface, input, output}])
    else
      {side, {:error, reason}} -> {:error, {side, reason}}
    end
  end

  def decode(_), do: {:error, :invalid_shape}

  @doc "Return the outer interface if the adjacent declarations are compatible."
  def connect(first, second) do
    with {:first, {:ok, first}} <- {:first, decode(first)},
         {:second, {:ok, second}} <- {:second, decode(second)},
         {:ok, {:Interface, input, output}} <-
           apply(:"Cure.Elzoo.Assembly", :connect, [first, second]) do
      {:ok, %{"input" => Elzoo.Port.encode(input), "output" => Elzoo.Port.encode(output)}}
    else
      {side, {:error, reason}} -> {:error, {side, reason}}
      {:error, _} = error -> error
    end
  end
end
