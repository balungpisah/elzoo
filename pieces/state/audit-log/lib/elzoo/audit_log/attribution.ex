# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AuditLog.Attribution do
  @moduledoc """
  Shape validation of the caller-supplied session attribution (a declared Need).

  `actor` is an opaque reference and `action` the session's initiating business action:
  each 1..256 bytes of UTF-8 without control characters. `reason` is 0..1024 bytes of the
  same shape. Nothing is authenticated here; the host's identity layer supplies a truthful
  actor until `domain/principal` exists.
  """

  @max_ref 256
  @max_reason 1024

  @spec validate(term()) ::
          {:ok, %{actor: binary(), action: binary(), reason: binary()}}
          | {:error, {:attribution, atom()}}
  def validate(%{} = attribution) when map_size(attribution) == 3 do
    with {:ok, actor} <- field(attribution, :actor, 1, @max_ref),
         {:ok, action} <- field(attribution, :action, 1, @max_ref),
         {:ok, reason} <- field(attribution, :reason, 0, @max_reason) do
      {:ok, %{actor: actor, action: action, reason: reason}}
    end
  end

  def validate(_), do: {:error, {:attribution, :shape}}

  defp field(map, key, min, max) do
    value = Map.get(map, key)

    if is_binary(value) and byte_size(value) in min..max and String.valid?(value) and
         not control?(value),
       do: {:ok, value},
       else: {:error, {:attribution, key}}
  end

  defp control?(value),
    do: Enum.any?(String.to_charlist(value), &(&1 < 0x20 or &1 in 0x7F..0x9F))
end
