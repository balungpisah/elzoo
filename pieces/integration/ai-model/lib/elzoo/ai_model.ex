# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiModel do
  @moduledoc """
  Family core of the `integration/ai-model` Pieces: provider-neutral data and
  validators shared by every model-type interface (model reference, usage and
  its accounting identity, cache hint, provenance, failure classes, job
  reference and state, stream chunk). Pure: no I/O, no process, no
  configuration. Every validator returns `{:ok, value}` or `{:error, reason}`
  with a fixed reason atom; no input is echoed in an error.
  """

  @doc false
  # Nonempty valid UTF-8 of at most `max` bytes without control characters.
  def text?(value, max) do
    is_binary(value) and byte_size(value) in 1..max and String.valid?(value) and
      not String.match?(value, ~r/[\x00-\x1F\x7F]/u)
  end

  @doc false
  def amount?(:unknown), do: true
  def amount?(n), do: is_integer(n) and n >= 0

  @doc false
  def exact_keys?(map, keys) when is_map(map) and not is_struct(map),
    do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  def exact_keys?(_, _), do: false
end
