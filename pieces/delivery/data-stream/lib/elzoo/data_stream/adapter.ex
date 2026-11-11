# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DataStream.Adapter do
  @moduledoc false
  alias Elzoo.DataStream.{JSON, Protocol, Request}
  def failure_tags, do: Map.keys(Elzoo.DataStream.Binding.failures())
  def schema, do: "elzoo/anthropic-text-stream-request/1"

  def validate(args, schema) do
    if schema == schema(), do: Request.provider_body?(args), else: {:error, :schema}
  end

  def send_effect(req) do
    c = req.context
    ref = Process.monitor(c.session)

    case GenServer.call(c.session, {:adapter, c.generation, self(), req}, :infinity) do
      {:ok, token} ->
        receive do
          {:data_stream_adapter, ^token, result} ->
            Process.demonitor(ref, [:flush])
            result

          {:DOWN, ^ref, :process, _, _} ->
            {:error, :session_lost, :redacted}
        end

      _ ->
        {:error, :adapter_error, :redacted}
    end
  rescue
    _ -> {:error, :adapter_error, :redacted}
  catch
    _, _ -> {:error, :adapter_error, :redacted}
  end

  def poll(_), do: {:unavailable, :no_status_query}
  def authenticate({:unavailable, :no_status_query}, _), do: :ok
  def authenticate(result, req), do: validate_result(result, req)

  def validate_result(r, req) do
    with true <-
           is_map(r) and
             Enum.sort(Map.keys(r)) ==
               Enum.sort(
                 ~w(version message_id correlation_id attempt_id outcome dispatch value value_schema_id value_schema_version)
               ),
         true <- r["version"] == 1 and r["outcome"] == "completed" and r["dispatch"] == "dispatched",
         true <-
           r["message_id"] == req.key and r["correlation_id"] == req.key and
             r["attempt_id"] == req.attempt_id,
         true <-
           r["value_schema_id"] == "elzoo/anthropic-text-stream-delivery" and
             r["value_schema_version"] == 1,
         v when is_map(v) <- r["value"],
         true <- Enum.sort(Map.keys(v)) == ~w(outcome_digest response_id seal),
         true <- Protocol.id?(v["response_id"]) and hex?(v["outcome_digest"]) and hex?(v["seal"]),
         true <- v["seal"] == seal(req, v["response_id"], v["outcome_digest"]) do
      :ok
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def completed(req, response_id, digest) do
    %{
      "version" => 1,
      "message_id" => req.key,
      "correlation_id" => req.key,
      "attempt_id" => req.attempt_id,
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value_schema_id" => "elzoo/anthropic-text-stream-delivery",
      "value_schema_version" => 1,
      "value" => %{
        "response_id" => response_id,
        "outcome_digest" => digest,
        "seal" => seal(req, response_id, digest)
      }
    }
  end

  defp seal(req, id, digest) do
    c = req.context

    bytes =
      JSON.encode(%{
        "key" => req.key,
        "attempt" => req.attempt_id,
        "generation" => c.seal_generation,
        "response_id" => id,
        "outcome_digest" => digest
      })

    :crypto.mac(:hmac, :sha256, c.seal_key, bytes) |> Base.encode16(case: :lower)
  end

  defp hex?(b), do: is_binary(b) and Regex.match?(~r/\A[0-9a-f]{64}\z/, b)
end
