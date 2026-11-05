# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Envelope do
  @moduledoc "Versioned neutral message/result translation; payloads remain opaque."
  @message_required ~w(version message_id schema_id schema_version kind producer payload)
  @text_metadata ~w(correlation_id causation_id idempotency_key trace_id attempt_id)
  @number_metadata ~w(sequence deadline_unix_ms)
  @result_required ~w(version message_id correlation_id outcome dispatch)

  def decode(message) when is_map(message) do
    with true <-
           shape?(message, @message_required, @text_metadata ++ @number_metadata ++ ["reply_to"]),
         %{"unit_id" => unit, "port_id" => port} = producer when map_size(producer) == 2 <-
           message["producer"],
         true <- texts?([message["message_id"], message["schema_id"], message["kind"], unit, port]),
         true <- is_integer(message["version"]) and is_integer(message["schema_version"]),
         true <- optional_types?(message, @text_metadata, &text?/1),
         true <- optional_types?(message, @number_metadata, &is_integer/1),
         {:ok, reply_to} <- reply_to(message) do
      apply(:"Cure.Elzoo.Envelope", :validate, [
        {:EnvelopeMessage, message["version"], text(message["message_id"]),
         text(message["schema_id"]), message["schema_version"], text(message["kind"]), text(unit),
         text(port), message["payload"], reply_to, text_option(message, "attempt_id"),
         text_option(message, "correlation_id"), text_option(message, "causation_id"),
         text_option(message, "idempotency_key"), text_option(message, "trace_id"),
         option(message, "sequence"), option(message, "deadline_unix_ms")}
      ])
    else
      _ -> {:error, :invalid_shape}
    end
  end

  def decode(_), do: {:error, :invalid_shape}

  def encode(
        {:EnvelopeMessage, version, id, schema, schema_version, kind, unit, port, payload, reply_to,
         attempt, correlation, causation, idempotency, trace, sequence, deadline}
      ) do
    %{
      "version" => version,
      "message_id" => untext(id),
      "schema_id" => untext(schema),
      "schema_version" => schema_version,
      "kind" => untext(kind),
      "producer" => %{"unit_id" => untext(unit), "port_id" => untext(port)},
      "payload" => payload
    }
    |> put_reply_to(reply_to)
    |> put_text("attempt_id", attempt)
    |> put_text("correlation_id", correlation)
    |> put_text("causation_id", causation)
    |> put_text("idempotency_key", idempotency)
    |> put_text("trace_id", trace)
    |> put_option("sequence", sequence)
    |> put_option("deadline_unix_ms", deadline)
  end

  def validate(message) do
    with {:ok, _} <- decode(message), do: {:ok, message}
  end

  def decode_result(result) when is_map(result) do
    with true <-
           shape?(
             result,
             @result_required,
             ~w(value value_schema_id value_schema_version error_class attempt_id deadline_unix_ms)
           ),
         true <- is_integer(result["version"]),
         true <- texts?(Enum.map(~w(message_id correlation_id outcome dispatch), &result[&1])),
         true <- optional_types?(result, ~w(error_class attempt_id value_schema_id), &text?/1),
         true <- optional_types?(result, ~w(deadline_unix_ms value_schema_version), &is_integer/1) do
      apply(:"Cure.Elzoo.Envelope", :validate_result, [
        {:DeliveryResult, result["version"], text(result["message_id"]),
         text(result["correlation_id"]), text(result["outcome"]), text(result["dispatch"]),
         option(result, "value"), text_option(result, "value_schema_id"),
         option(result, "value_schema_version"), text_option(result, "error_class"),
         text_option(result, "attempt_id"), option(result, "deadline_unix_ms")}
      ])
    else
      _ -> {:error, :invalid_shape}
    end
  end

  def decode_result(_), do: {:error, :invalid_shape}

  def encode_result(
        {:DeliveryResult, version, id, correlation, outcome, dispatch, value, schema,
         schema_version, error, attempt, deadline}
      ) do
    %{
      "version" => version,
      "message_id" => untext(id),
      "correlation_id" => untext(correlation),
      "outcome" => untext(outcome),
      "dispatch" => untext(dispatch)
    }
    |> put_option("value", value)
    |> put_text("value_schema_id", schema)
    |> put_option("value_schema_version", schema_version)
    |> put_text("error_class", error)
    |> put_text("attempt_id", attempt)
    |> put_option("deadline_unix_ms", deadline)
  end

  def validate_result(result) do
    with {:ok, _} <- decode_result(result), do: {:ok, result}
  end

  defp shape?(map, required, optional) do
    Enum.all?(required, &Map.has_key?(map, &1)) and
      Enum.all?(Map.keys(map), &(&1 in required or &1 in optional))
  end

  defp text?(value), do: is_binary(value) and String.valid?(value)
  defp texts?(values), do: Enum.all?(values, &text?/1)
  defp text(value), do: {:String, String.to_charlist(value)}
  defp untext({:String, value}), do: List.to_string(value)

  defp optional_types?(map, keys, valid?) do
    Enum.all?(keys, fn key -> not Map.has_key?(map, key) or valid?.(map[key]) end)
  end

  defp option(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:some, value}
      :error -> :none
    end
  end

  defp text_option(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:some, text(value)}
      :error -> :none
    end
  end

  defp put_text(map, key, {:some, value}), do: Map.put(map, key, untext(value))
  defp put_text(map, _key, :none), do: map
  defp put_option(map, key, {:some, value}), do: Map.put(map, key, value)
  defp put_option(map, _key, :none), do: map

  defp reply_to(message) do
    case Map.fetch(message, "reply_to") do
      :error ->
        {:ok, :none}

      {:ok, %{"unit_id" => unit, "port_id" => port} = endpoint} when map_size(endpoint) == 2 ->
        if text?(unit) and text?(port) do
          {:ok, {:some, {:ReplyEndpoint, text(unit), text(port)}}}
        else
          {:error, :invalid_shape}
        end

      _ ->
        {:error, :invalid_shape}
    end
  end

  defp put_reply_to(map, :none), do: map

  defp put_reply_to(map, {:some, {:ReplyEndpoint, unit, port}}) do
    Map.put(map, "reply_to", %{"unit_id" => untext(unit), "port_id" => untext(port)})
  end
end
