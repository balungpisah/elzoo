defmodule Elzoo.JsonBoundary do
  @moduledoc """
  Validates input and translates exceptions around the trusted JSON adapter.

  Jason's implementation is upstream-owned. Cure's `@extern` declaration and
  this boundary make that assumption explicit; neither claims to prove Jason.
  """

  @adapter :"Cure.Elzoo.Adapter"

  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(value), do: encode(@adapter, value)

  @spec encode(module(), term()) :: {:ok, binary()} | {:error, term()}
  def encode(adapter, value) when is_binary(value) do
    if String.valid?(value) do
      try do
        {:ok, apply(adapter, :encode, [value])}
      rescue
        error -> {:error, {:library, error.__struct__}}
      end
    else
      {:error, :invalid_utf8}
    end
  end

  def encode(_adapter, _value), do: {:error, :invalid_type}
end
