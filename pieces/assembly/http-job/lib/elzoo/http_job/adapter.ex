# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.HttpJob.Adapter do
  @moduledoc "One fixed-origin HTTP publication Adapter; every timer expiry has unknown dispatch."
  alias Elzoo.HttpJob.{Binding, Call, Wire}
  def failure_tags, do: Map.keys(Binding.failures())
  def schema, do: "elzoo/publication-v1"
  def validate(bytes, "elzoo/publication-v1"), do: Wire.publication(bytes)
  def validate(_, _), do: {:error, :schema}

  def send_effect(req), do: request(req, :put)

  def poll(req) do
    case request(req, :get) do
      result when is_map(result) -> result
      {:error, :not_acknowledged, _} -> {:pending, :http_pending}
      _ -> {:unavailable, :http_unavailable}
    end
  end

  defp request(req, method) do
    # These checks occur before starting any transport and must also run after recovery.
    with %{context: %Elzoo.HttpJob.Config{} = c} <- req,
         {:ok, b} <- Elzoo.EffectIntent.Binding.load(c.binding),
         true <- b.adapter == __MODULE__ and b.replay == :none and b.digest == req.binding,
         true <- c.origin == b.provider_account and Binding.origin?(c.origin),
         true <- Wire.hex?(req.key),
         :ok <- Wire.publication(req.arguments) do
      case Call.run(c.transport_supervisor, c.total_ms, fn -> transport(req, c, method) end) do
        {:ok, result} -> result
        {:error, :call_timeout} -> {:error, :transport_timeout, :unknown}
        _ -> {:error, :transport_error, :unknown}
      end
    else
      _ -> {:error, :request_rejected, :preflight}
    end
  rescue
    _ -> {:error, :transport_error, :unknown}
  end

  defp transport(req, c, method) do
    # Only explicit trusted credential returns before Req entry attest no send.
    # Raising, hanging, task-start failure or dying cannot establish that fact.
    case c.credentials.() do
      {:error, tag} when tag in [:preflight_unavailable, :request_rejected] ->
        {:error, tag, :preflight}

      {:ok, token} when is_binary(token) ->
        if byte_size(token) <= 4096 and not String.contains?(token, ["\r", "\n", <<0>>]) do
          headers = [{"content-type", "application/json"}, {"authorization", token}]

          response =
            Req.request(
              url: c.origin <> "/publications/" <> req.key,
              method: method,
              body: if(method == :put, do: req.arguments, else: nil),
              headers: headers,
              retry: false,
              redirect: false,
              decode_body: false,
              compressed: false,
              raw: true,
              receive_timeout: c.receive_ms,
              connect_options: [timeout: c.connect_ms],
              into: fn {:data, chunk}, {request, response} ->
                if byte_size(response.body) + byte_size(chunk) <= Wire.limit(),
                  do: {:cont, {request, %{response | body: response.body <> chunk}}},
                  else: {:halt, {request, %{response | body: :over_limit}}}
              end
            )

          translate(response, req, c)
        else
          {:error, :request_rejected, :preflight}
        end

      _ ->
        {:error, :request_rejected, :preflight}
    end
  end

  defp translate({:ok, %{status: status} = response}, req, c) when status in 200..299 do
    with encoding when encoding in [[], ["identity"]] <-
           Req.Response.get_header(response, "content-encoding"),
         {:ok, receipt} <- Wire.receipt(response.body),
         signature when is_binary(signature) <- signature(response) do
      value = Map.merge(receipt, %{"status" => status, "signature" => signature})
      # Authenticate inside the total request budget as well. Do not drop a
      # bad signature/key/digest completed receipt: the owner retains refusal.
      case {receipt["ack"], c.authenticate.(value, req)} do
        {true, _} -> completion(value, req)
        {false, :ok} -> {:error, :not_acknowledged, :pending}
        _ -> {:error, :receipt_invalid, :unauthenticated}
      end
    else
      _ -> {:error, :receipt_invalid, :schema}
    end
  end

  defp translate({:ok, %{status: s}}, _, _) when s in 300..399,
    do: {:error, :http_redirect, :status}

  defp translate({:ok, %{status: s}}, _, _) when s in 400..499, do: {:error, :http_4xx, :status}
  defp translate({:ok, %{status: s}}, _, _) when s in 500..599, do: {:error, :http_5xx, :status}

  defp translate({:error, %Req.TransportError{reason: :timeout}}, _, _),
    do: {:error, :transport_timeout, :unknown}

  defp translate(_, _, _), do: {:error, :transport_error, :unknown}

  defp signature(response) do
    case Req.Response.get_header(response, "x-elzoo-signature") do
      [s] -> if Wire.text?(s, 256), do: s, else: nil
      _ -> nil
    end
  end

  defp completion(value, req),
    do: %{
      "version" => 1,
      "message_id" => req.key,
      "correlation_id" => req.key,
      "attempt_id" => req.attempt_id,
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => value,
      "value_schema_id" => "elzoo/publication-receipt",
      "value_schema_version" => 1
    }

  def validate_result(
        %{
          "outcome" => "completed",
          "value_schema_id" => "elzoo/publication-receipt",
          "value_schema_version" => 1,
          "value" => v
        },
        req
      ) do
    with true <- is_map(v),
         {:ok, normalized} <- Wire.normalize(v),
         true <- normalized["ack"] and v["trust"] == "untrusted",
         true <-
           v["key"] == req.key and v["digest"] == Base.encode16(req.arguments_digest, case: :lower),
         true <- is_integer(v["status"]) and v["status"] in 200..299,
         true <- Wire.text?(v["signature"], 256) do
      :ok
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def validate_result(_, _), do: :error

  def authenticate({tag, value}, _)
      when {tag, value} in [pending: :http_pending, unavailable: :http_unavailable], do: :ok

  def authenticate(%{"value" => value}, %{context: %Elzoo.HttpJob.Config{} = c} = req) do
    case Call.run(c.transport_supervisor, c.total_ms, fn -> c.authenticate.(value, req) end) do
      {:ok, :ok} -> :ok
      _ -> :error
    end
  end

  def authenticate(_, _), do: :error
end
