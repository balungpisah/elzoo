# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Notification.Adapter do
  @moduledoc """
  The `delivery/effect-intent` Adapter for one SMTP email. The Adapter never
  retries; only the EffectIntent owner can permit a later send, on a recorded
  ground. A `250` after `DATA` is acceptance, never delivery.
  """
  alias Elzoo.Notification.{Binding, Config, Outcome, Transport, Wire}

  @schema "elzoo/notification-email-v1"
  @value_schema "elzoo/notification-acceptance"

  def failure_tags, do: Map.keys(Binding.failures())
  def schema, do: @schema

  def validate(bytes, @schema) do
    case Wire.request(bytes, Wire.max()) do
      {:ok, _} -> :ok
      _ -> {:error, :schema}
    end
  end

  def validate(_, _), do: {:error, :schema}

  def send_effect(req) do
    with %{context: %Config{} = c, key: key, attempt_id: attempt_id} <- req,
         {:ok, b, settings} <- Binding.load(c.binding),
         true <- b.digest == req.binding and settings == c.settings,
         true <- Wire.hex?(key) and is_binary(req.arguments) do
      case Wire.request(req.arguments, c.max_request_bytes) do
        {:ok, message} ->
          {stage, reply, receipt} = Transport.run(c, settings, key, message)
          result(Outcome.classify(stage, reply), receipt, c, key, attempt_id, settings)

        {:error, :too_large} ->
          failure(Outcome.classify(:MailPre, :MailOversize))

        {:error, :invalid_address} ->
          failure(Outcome.classify(:MailPre, :MailBadAddress))

        _ ->
          failure(:adapter_error)
      end
    else
      _ -> failure(:adapter_error)
    end
  rescue
    _ -> failure(:adapter_error)
  catch
    _, _ -> failure(:adapter_error)
  end

  defp result(:accepted, receipt, c, key, attempt_id, settings) do
    with true <- is_binary(receipt),
         provider_id = String.trim_trailing(receipt, "\r\n"),
         true <- Wire.text?(provider_id, 256) do
      message_id = Transport.message_id(key, settings.sender)

      %{
        "version" => 1,
        "message_id" => key,
        "correlation_id" => key,
        "attempt_id" => attempt_id,
        "outcome" => "completed",
        "dispatch" => "dispatched",
        "value" => %{
          "provider_id" => provider_id,
          "message_id" => message_id,
          "seal" => seal(c, key, attempt_id, provider_id, message_id)
        },
        "value_schema_id" => @value_schema,
        "value_schema_version" => 1
      }
    else
      _ -> failure(:unclassified_reply)
    end
  end

  defp result(tag, _, _, _, _, _), do: failure(tag)

  # Detail is a fixed atom: never server text, an address or an exception.
  defp failure(tag), do: {:error, tag, :smtp}

  @doc "SMTP has no status query: an unknown outcome stays unknown until reconciliation."
  def poll(_req), do: {:unavailable, :smtp_has_no_status}

  def validate_result(
        %{
          "outcome" => "completed",
          "value_schema_id" => @value_schema,
          "value_schema_version" => 1,
          "value" => %{"provider_id" => p, "message_id" => m, "seal" => s} = v
        },
        %{key: key, context: %Config{settings: settings}}
      ) do
    if map_size(v) == 3 and Wire.text?(p, 256) and Wire.hex?(s) and
         m == Transport.message_id(key, settings.sender),
       do: :ok,
       else: :error
  rescue
    _ -> :error
  end

  def validate_result(_, _), do: :error

  def authenticate({:unavailable, :smtp_has_no_status}, _), do: :ok

  # Process-local integrity of our own transport's completion, not provider
  # authentication: SMTP offers none. A forged or post-restart completion fails.
  def authenticate(
        %{
          "attempt_id" => attempt_id,
          "value" => %{"provider_id" => p, "message_id" => m, "seal" => s}
        },
        %{key: key, attempt_id: attempt_id, context: %Config{} = c}
      )
      when is_binary(s) do
    expected = seal(c, key, attempt_id, p, m)

    if byte_size(s) == byte_size(expected) and :crypto.hash_equals(s, expected),
      do: :ok,
      else: :error
  rescue
    _ -> :error
  end

  def authenticate(_, _), do: :error

  defp seal(%Config{seal_key: k}, key, attempt_id, provider_id, message_id) do
    data = Enum.map([key, attempt_id, provider_id, message_id], &<<byte_size(&1)::32, &1::binary>>)
    :crypto.mac(:hmac, :sha256, k, data) |> Base.encode16(case: :lower)
  end
end
