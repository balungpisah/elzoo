# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DataStream.Request do
  @moduledoc false
  alias Elzoo.DataStream.JSON
  @max 9_223_372_036_854_775_807
  @command ~w(version message_id schema_id schema_version kind producer payload idempotency_key deadline_unix_ms)
  @excluded ~w(tools tool_choice thinking images documents output_config response_format cache_control stop_sequences temperature top_p top_k batch server_tools fallback metadata service_tier stream)
  def id?(b), do: is_binary(b) and Regex.match?(~r/\A[A-Za-z0-9._:-]{1,64}\z/, b)

  def prepare(effect, models, wall, mono, total) do
    with :ok <- exact(effect, ~w(capability_id operation classification command), []),
         true <-
           effect["classification"] == "untrusted" and
             effect["capability_id"] == "delivery/data-stream" and
             effect["operation"] == "generate_stream",
         c = effect["command"],
         :ok <- exact(c, @command, ["correlation_id"]),
         true <-
           c["version"] == 1 and c["schema_version"] == 1 and
             c["schema_id"] == "elzoo/anthropic-text-stream-request" and c["kind"] == "command",
         :ok <- exact(c["producer"], ~w(unit_id port_id), []),
         true <-
           Enum.all?(
             [
               c["message_id"],
               c["idempotency_key"],
               Map.get(c, "correlation_id", c["message_id"]),
               c["producer"]["unit_id"],
               c["producer"]["port_id"]
             ],
             &id?/1
           ),
         d = c["deadline_unix_ms"],
         true <- is_integer(d) and d in 0..@max,
         true <- is_binary(c["payload"]),
         :ok <- ceiling(byte_size(c["payload"]), 65_536),
         {:ok, payload} <- decode(c["payload"]),
         :ok <- payload(payload, models),
         body =
           JSON.encode(
             Map.merge(payload, %{"stream" => true, "thinking" => %{"type" => "disabled"}})
           ),
         :ok <- ceiling(byte_size(body), 65_536),
         {:ok, _} <- Elzoo.Effect.decode(effect),
         deadline = mono + min(total, d - wall),
         true <- d > wall and deadline > System.monotonic_time(:millisecond) do
      {:ok, %{body: body, model: payload["model"], command: c, deadline: deadline}}
    else
      {:error, r} when r in [:too_large, :unsupported_feature, :expired] -> {:error, r}
      false -> if(expired?(effect, wall), do: {:error, :expired}, else: {:error, :invalid_request})
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  def provider_body?(body) do
    with true <- is_binary(body) and byte_size(body) <= 65_536,
         {:ok, m} <- JSON.decode(body),
         true <- is_map(m) and m["stream"] == true and m["thinking"] == %{"type" => "disabled"},
         :ok <- payload(Map.drop(m, ~w(stream thinking)), [m["model"]]),
         true <- JSON.encode(m) == body do
      :ok
    else
      _ -> {:error, :schema}
    end
  end

  defp expired?(%{"command" => %{"deadline_unix_ms" => d}}, wall),
    do: is_integer(d) and d in 0..@max and d <= wall

  defp expired?(_, _), do: false

  defp decode(b) do
    case JSON.decode(b) do
      {:ok, m} -> {:ok, m}
      _ -> {:error, :invalid_request}
    end
  end

  defp payload(m, models) do
    with :ok <- exact(m, ~w(model messages max_tokens), ["system"]),
         true <- Elzoo.DataStream.Protocol.model?(m["model"]) and m["model"] in models,
         n = m["max_tokens"],
         true <- is_integer(n) and n > 0,
         :ok <- ceiling(n, 4096),
         l when is_list(l) and l != [] <- m["messages"],
         :ok <- ceiling(length(l), 32),
         :ok <- messages(l, "user"),
         true <- List.last(l)["role"] == "user",
         :ok <- optional_system(m) do
      :ok
    else
      {:error, _} = e -> e
      _ -> {:error, :invalid_request}
    end
  end

  defp messages([], _), do: :ok

  defp messages([m | rest], role) do
    with :ok <- exact(m, ~w(role content), []),
         true <- m["role"] == role,
         :ok <- content(m["content"]) do
      messages(rest, if(role == "user", do: "assistant", else: "user"))
    else
      {:error, _} = e -> e
      _ -> {:error, :invalid_request}
    end
  end

  defp content(l) when is_list(l), do: {:error, :unsupported_feature}

  defp content(b) when is_binary(b) and b != "" do
    if String.valid?(b), do: ceiling(byte_size(b), 16_384), else: {:error, :invalid_request}
  end

  defp content(_), do: {:error, :invalid_request}
  defp optional_system(m), do: if(Map.has_key?(m, "system"), do: content(m["system"]), else: :ok)
  defp ceiling(n, max), do: if(n <= max, do: :ok, else: {:error, :too_large})

  defp exact(m, req, opt) when is_map(m) do
    cond do
      Enum.any?(Map.keys(m), &(&1 in @excluded and &1 not in req and &1 not in opt)) ->
        {:error, :unsupported_feature}

      Enum.sort(Map.keys(m) -- opt) != Enum.sort(req) ->
        {:error, :invalid_request}

      true ->
        :ok
    end
  end

  defp exact(_, _, _), do: {:error, :invalid_request}
end
