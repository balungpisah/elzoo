# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.IngestCodec.Count do
  @behaviour Elzoo.UnitAdapter.Codec
  def decode_payload("example/ingest-message", 1, payload) do
    case payload do
      %{"sender" => s, "incarnation" => i, "sequence" => q, "value" => v}
      when map_size(payload) == 4 and is_integer(s) and is_integer(i) and is_integer(q) and
             is_integer(v) ->
        {:ok, apply(:"Cure.Elzoo.Idempotency", :message, [s, i, q, v])}

      _ ->
        {:error, :invalid_payload}
    end
  end

  def decode_payload(_, _, _), do: {:error, :unsupported_schema}
  def encode_output(:none), do: {:ok, nil}
  def encode_output({:some, value}) when is_integer(value), do: {:ok, value}
  def encode_output(_), do: {:error, :invalid_output}
  def value_schema, do: {"example/optional-count", 1}
end

defmodule Elzoo.IngestCodec.Accepted do
  @behaviour Elzoo.UnitAdapter.Codec
  defdelegate decode_payload(schema, version, payload), to: Elzoo.IngestCodec.Count
  def encode_output(:none), do: {:ok, nil}

  def encode_output({:some, {:Message, s, i, q, v} = message})
      when is_integer(s) and is_integer(i) and is_integer(q) and is_integer(v), do: {:ok, message}

  def encode_output(_), do: {:error, :invalid_output}
  def value_schema, do: {"example/accepted-message", 1}
end

defmodule Elzoo.IngestCodec.Total do
  @behaviour Elzoo.UnitAdapter.Codec
  def decode_payload("example/accepted-message", 1, {:Message, s, i, q, v} = message)
      when is_integer(s) and is_integer(i) and is_integer(q) and is_integer(v), do: {:ok, message}

  def decode_payload("example/accepted-message", 1, _), do: {:error, :invalid_payload}
  def decode_payload(_, _, _), do: {:error, :unsupported_schema}
  defdelegate encode_output(output), to: Elzoo.IngestCodec.Count
  defdelegate value_schema(), to: Elzoo.IngestCodec.Count
end
