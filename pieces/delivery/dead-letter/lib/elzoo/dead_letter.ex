# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DeadLetter do
  @moduledoc "Redacted failure record, not storage. Caller may record deadline_before_dispatch after refused admission."
  @required ~w(version message_id correlation_id attempts reason)
  @triple ~w(last_outcome last_dispatch last_error_class)
  @optional @triple ++ ~w(last_attempt_id deadline_unix_ms)

  def from_result(request, result, attempts, reason) do
    with {:ok, _} <- phase(Elzoo.Envelope.decode(request), :envelope),
         :ok <- result_matches(request, result) do
      record = %{
        "version" => 1,
        "message_id" => request["message_id"],
        "correlation_id" => Map.get(request, "correlation_id", request["message_id"]),
        "attempts" => attempts,
        "reason" => reason
      }

      record = copy(record, request, ~w(deadline_unix_ms))

      record =
        if is_nil(result),
          do: record,
          else:
            record
            |> Map.merge(
              Map.new(@triple, fn key -> {key, result[String.replace_prefix(key, "last_", "")]} end)
            )
            |> copy(result, ~w(attempt_id), "last_")

      phase(validate(record), :dead_letter)
    end
  end

  def validate(map) do
    with {:ok, _} <- decode(map), do: {:ok, map}
  end

  def decode(map) when is_map(map) do
    with true <- Enum.all?(@required, &Map.has_key?(map, &1)),
         true <- Enum.all?(Map.keys(map), &(&1 in @required or &1 in @optional)),
         true <- is_integer(map["version"]) and is_integer(map["attempts"]),
         true <- Enum.all?(~w(message_id correlation_id reason), &text?(map[&1])),
         true <-
           Enum.all?(@triple ++ ["last_attempt_id"], &(not Map.has_key?(map, &1) or text?(map[&1]))),
         true <- not Map.has_key?(map, "deadline_unix_ms") or is_integer(map["deadline_unix_ms"]),
         :ok <- triple(map) do
      apply(:"Cure.Elzoo.DeadLetter", :validate, [
        {:DeadLetterRecord, map["version"], text(map["message_id"]), text(map["correlation_id"]),
         map["attempts"], text(map["reason"]), option(map, "last_outcome", &text/1),
         option(map, "last_dispatch", &text/1), option(map, "last_error_class", &text/1),
         option(map, "last_attempt_id", &text/1), option(map, "deadline_unix_ms", & &1)}
      ])
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_shape}
    end
  end

  def decode(_), do: {:error, :invalid_shape}

  def encode(
        {:DeadLetterRecord, version, id, correlation, attempts, reason, outcome, dispatch, error,
         attempt, deadline}
      ) do
    %{
      "version" => version,
      "message_id" => untext(id),
      "correlation_id" => untext(correlation),
      "attempts" => attempts,
      "reason" => untext(reason)
    }
    |> put("last_outcome", outcome, &untext/1)
    |> put("last_dispatch", dispatch, &untext/1)
    |> put("last_error_class", error, &untext/1)
    |> put("last_attempt_id", attempt, &untext/1)
    |> put("deadline_unix_ms", deadline, & &1)
  end

  defp result_matches(_, nil), do: :ok

  defp result_matches(request, result) do
    with {:ok, _} <- phase(Elzoo.Envelope.validate_result(result), :result),
         true <-
           result["message_id"] == request["message_id"] and
             result["correlation_id"] == Map.get(request, "correlation_id", request["message_id"]) and
             result["deadline_unix_ms"] == request["deadline_unix_ms"] do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, {:result, :identity_mismatch}}
    end
  end

  defp triple(map) do
    case Enum.count(@triple, &Map.has_key?(map, &1)) do
      0 ->
        :ok

      3 ->
        result = %{
          "version" => 1,
          "message_id" => map["message_id"],
          "correlation_id" => map["correlation_id"],
          "outcome" => map["last_outcome"],
          "dispatch" => map["last_dispatch"],
          "error_class" => map["last_error_class"]
        }

        case Elzoo.Envelope.validate_result(result) do
          {:ok, _} -> :ok
          _ -> {:error, :invalid_last_result}
        end

      _ ->
        {:error, :invalid_last_result}
    end
  end

  defp phase({:ok, v}, _), do: {:ok, v}
  defp phase({:error, e}, phase), do: {:error, {phase, e}}
  defp text?(v), do: is_binary(v) and String.valid?(v)
  defp text(v), do: {:String, String.to_charlist(v)}
  defp untext({:String, v}), do: List.to_string(v)
  defp option(map, key, f), do: if(Map.has_key?(map, key), do: {:some, f.(map[key])}, else: :none)
  defp put(map, _, :none, _), do: map
  defp put(map, key, {:some, v}, f), do: Map.put(map, key, f.(v))

  defp copy(target, source, keys, prefix \\ "") do
    Enum.reduce(keys, target, fn key, acc ->
      if Map.has_key?(source, key), do: Map.put(acc, prefix <> key, source[key]), else: acc
    end)
  end
end
