# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RequestReply do
  @moduledoc "Stateless request/result correlation and named reply-wrapper checks."

  def reply_endpoint(request) do
    with {:ok, record} <- phase(Elzoo.Envelope.decode(request), :request),
         {:ok, {:ReplyEndpoint, unit, port}} <-
           phase(decide(:reply_endpoint, [record]), :correlation) do
      {:ok, %{"unit_id" => untext(unit), "port_id" => untext(port)}}
    end
  end

  def expected_correlation(request) do
    with {:ok, record} <- phase(Elzoo.Envelope.decode(request), :request) do
      {:ok, untext(decide(:expected_correlation, [record]))}
    end
  end

  def correlate(request, result) do
    with {:ok, request_record} <- phase(Elzoo.Envelope.decode(request), :request),
         {:ok, result_record} <- phase(Elzoo.Envelope.decode_result(result), :result),
         {:ok, true} <- phase(decide(:correlate, [request_record, result_record]), :correlation) do
      {:ok, result}
    end
  end

  def accept_reply(request, reply, arrival_endpoint) do
    with {:ok, request_record} <- phase(Elzoo.Envelope.decode(request), :request),
         {:ok, endpoint} <- phase(decode_endpoint(arrival_endpoint), :arrival),
         {:ok, reply_record} <- phase(Elzoo.Envelope.decode(reply), :reply),
         {:ok, true} <-
           phase(decide(:accept_reply, [request_record, reply_record, endpoint]), :reply) do
      correlate(request, reply["payload"])
    end
  end

  defp decode_endpoint(%{"unit_id" => unit, "port_id" => port} = endpoint)
       when map_size(endpoint) == 2 and is_binary(unit) and is_binary(port) do
    if String.valid?(unit) and String.valid?(port) and unit != "" and port != "" do
      {:ok,
       {:ReplyEndpoint, {:String, String.to_charlist(unit)}, {:String, String.to_charlist(port)}}}
    else
      {:error, :invalid_shape}
    end
  end

  defp decode_endpoint(_), do: {:error, :invalid_shape}
  defp decide(function, arguments), do: apply(:"Cure.Elzoo.RequestReply", function, arguments)
  defp untext({:String, value}), do: List.to_string(value)
  defp phase({:error, reason}, phase), do: {:error, {phase, reason}}
  defp phase({:ok, value}, _phase), do: {:ok, value}
end
