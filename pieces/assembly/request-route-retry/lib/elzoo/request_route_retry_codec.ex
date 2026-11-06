# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RequestRouteRetry.Codec do
  @moduledoc false
  @labels %{
    WindowFresh: "fresh",
    WindowAdvance: "advance",
    WindowReorder: "reorder",
    WindowNewIncarnation: "new_incarnation",
    WindowDuplicate: "duplicate",
    WindowStale: "stale",
    WindowSuperseded: "superseded",
    WindowFull: "full"
  }
  @accepted ~w(fresh advance reorder new_incarnation)

  def message(%{"sender" => s, "incarnation" => i, "sequence" => q, "value" => v} = m)
      when map_size(m) == 4 and is_integer(s) and is_integer(i) and is_integer(q) and is_integer(v),
      do: {:ok, {:Message, s, i, q, v}}

  def message(_), do: {:error, :invalid_message}

  def encode_message({:Message, s, i, q, v})
      when is_integer(s) and is_integer(i) and is_integer(q) and is_integer(v),
      do: {:ok, %{"sender" => s, "incarnation" => i, "sequence" => q, "value" => v}}

  def encode_message(_), do: {:error, :invalid_message}

  def label(decision), do: Map.fetch(@labels, decision)
  def accepted?(label), do: label in @accepted
  def known?(label), do: label in Map.values(@labels)

  def valid_value?(%{"decision" => label, "total" => total} = value) when map_size(value) == 2,
    do: known?(label) and if(accepted?(label), do: is_integer(total), else: is_nil(total))

  def valid_value?(_), do: false
end

defmodule Elzoo.RequestRouteRetry.Codec.Worker do
  @behaviour Elzoo.UnitAdapter.Codec
  alias Elzoo.RequestRouteRetry.Codec
  def decode_payload("example/rr-work", 1, value), do: Codec.message(value)
  def decode_payload(_, _, _), do: {:error, :invalid_schema}

  def encode_output({:some, {:RouteRetryOutput, decision, option}}) do
    with {:ok, label} <- Codec.label(decision),
         {:ok, total} <- total(option),
         value = %{"decision" => label, "total" => total},
         true <- Codec.valid_value?(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_output}
    end
  end

  def encode_output(_), do: {:error, :invalid_output}
  defp total(:none), do: {:ok, nil}
  defp total({:some, n}) when is_integer(n), do: {:ok, n}
  defp total(_), do: {:error, :invalid_total}
  def value_schema, do: {"example/rr-result", 1}
end

defmodule Elzoo.RequestRouteRetry.Codec.Dedup do
  @behaviour Elzoo.UnitAdapter.Codec
  alias Elzoo.RequestRouteRetry.Codec
  def decode_payload("example/rr-work", 1, value), do: Codec.message(value)
  def decode_payload(_, _, _), do: {:error, :invalid_schema}

  def encode_output({:some, {:DedupOutcome, decision, option}}) do
    with {:ok, label} <- Codec.label(decision),
         {:ok, accepted} <- accepted(option),
         true <- Codec.accepted?(label) == (accepted != nil) do
      {:ok, %{"decision" => label, "accepted" => accepted}}
    else
      _ -> {:error, :invalid_output}
    end
  end

  def encode_output(_), do: {:error, :invalid_output}
  defp accepted(:none), do: {:ok, nil}
  defp accepted({:some, message}), do: Codec.encode_message(message)
  defp accepted(_), do: {:error, :invalid_message}
  def value_schema, do: {"example/rr-dedup-outcome", 1}
end

defmodule Elzoo.RequestRouteRetry.Codec.Accumulate do
  @behaviour Elzoo.UnitAdapter.Codec
  def decode_payload("example/rr-accepted", 1, value),
    do: Elzoo.RequestRouteRetry.Codec.message(value)

  def decode_payload(_, _, _), do: {:error, :invalid_schema}
  def encode_output({:some, n}) when is_integer(n), do: {:ok, n}
  def encode_output(_), do: {:error, :invalid_output}
  def value_schema, do: {"example/rr-total", 1}
end
