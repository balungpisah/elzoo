# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.McpClient.Adapter do
  @moduledoc """
  The `delivery/effect-intent` Adapter for one MCP `tools/call`. The Adapter
  never retries; only the EffectIntent owner can permit a later send, on a
  recorded ground. The full classified outcome goes to the context's recipient
  Need by best-effort mailbox delivery; the owner keeps only a sealed digest.
  """
  alias Elzoo.McpClient.{Binding, Context, Ledger, Outcome, Redact, Session, Transport, Wire}

  @schema "elzoo/mcp-tool-call-v1"
  @value_schema "elzoo/mcp-tool-result"

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
    with %{context: %Context{session: %Session{config: c} = s} = ctx, key: key} <- req,
         %{attempt_id: attempt_id} <- req,
         {:ok, b, settings} <- Binding.load(c.binding),
         true <- b.digest == req.binding and settings == c.settings,
         true <- Wire.hex?(key) and is_binary(req.arguments) do
      # The credential as resolved before and after the call: a server that
      # echoes it never gets it into a delivered or digested result.
      secrets = Redact.secrets(c.credentials)

      {stage, reply, value} =
        case Wire.request(req.arguments, c.max_request_bytes) do
          {:ok, call} ->
            if is_pid(s.client) and Process.alive?(s.client),
              do: Transport.call(s.client, call.tool, call.arguments, c.call_timeout_ms),
              else: Transport.unsent_stage_for_pre(:not_connected)

          {:error, reason} ->
            Transport.unsent_stage_for_pre(reason)
        end

      # Redaction inside the session's ledger (it never returns tokens); if the
      # ledger is gone no unredacted content leaves: the outcome is unknown.
      {tag, value} =
        case {Outcome.classify(stage, reply), value} do
          {tag, nil} ->
            {tag, nil}

          {tag, v} ->
            case Ledger.redact(s.ledger, v, secrets ++ Redact.secrets(c.credentials)) do
              {:ok, redacted} -> {tag, redacted}
              :error -> {:adapter_error, nil}
            end
        end

      deliver(ctx, key, attempt_id, tag, value)
      envelope(tag, value, c, key, attempt_id)
    else
      _ -> failure(:adapter_error)
    end
  rescue
    _ -> failure(:adapter_error)
  catch
    _, _ -> failure(:adapter_error)
  end

  # Best-effort: a recipient that has exited loses the content; the settlement
  # recorded by the owner is unchanged. The message is sent before the owner
  # commits the settlement, so it is not a settlement: call_tool/3 returns a
  # completion only after the owner has confirmed it.
  defp deliver(%Context{recipient: pid}, key, attempt_id, tag, value) when is_pid(pid) do
    outcome =
      case tag do
        :completed -> {:completed, value}
        _ -> elem(Binding.outcome(tag), 1)
      end

    if Process.alive?(pid), do: send(pid, {:elzoo_mcp_result, key, attempt_id, outcome})
    :ok
  end

  defp deliver(_, _, _, _, _), do: :ok

  defp envelope(:completed, %{} = value, c, key, attempt_id) do
    digest = digest(value)

    %{
      "version" => 1,
      "message_id" => key,
      "correlation_id" => key,
      "attempt_id" => attempt_id,
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => %{
        "digest" => digest,
        "is_error" => value.is_error,
        "seal" => seal(c, key, attempt_id, digest, value.is_error)
      },
      "value_schema_id" => @value_schema,
      "value_schema_version" => 1
    }
  end

  defp envelope(:completed, _, _, _, _), do: failure(:malformed_response)
  defp envelope(tag, _, _, _, _), do: failure(tag)

  # Detail is a fixed atom: never server text, arguments or an exception.
  defp failure(tag), do: {:error, tag, :mcp}

  @doc "SHA-256 of the canonical JSON of a completed result (content, is_error, structured)."
  def digest(%{content: content, is_error: e, structured: s}) do
    bytes = Jason.encode!(%{"content" => content, "isError" => e, "structuredContent" => s})
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  @doc "MCP has no status query for a past tools/call: unknown stays unknown."
  def poll(_req), do: {:unavailable, :mcp_has_no_status}

  def validate_result(
        %{
          "outcome" => "completed",
          "value_schema_id" => @value_schema,
          "value_schema_version" => 1,
          "value" => %{"digest" => d, "is_error" => e, "seal" => s} = v
        },
        %{context: %Context{}}
      ) do
    if map_size(v) == 3 and Wire.hex?(d) and is_boolean(e) and Wire.hex?(s),
      do: :ok,
      else: :error
  rescue
    _ -> :error
  end

  def validate_result(_, _), do: :error

  def authenticate({:unavailable, :mcp_has_no_status}, _), do: :ok

  # Process-local integrity of our own transport's completion, not server
  # authentication. A forged or post-restart completion fails.
  def authenticate(
        %{"attempt_id" => attempt_id, "value" => %{"digest" => d, "is_error" => e, "seal" => s}},
        %{key: key, attempt_id: attempt_id, context: %Context{session: %Session{config: c}}}
      )
      when is_binary(s) do
    expected = seal(c, key, attempt_id, d, e)

    if byte_size(s) == byte_size(expected) and :crypto.hash_equals(s, expected),
      do: :ok,
      else: :error
  rescue
    _ -> :error
  end

  def authenticate(_, _), do: :error

  defp seal(c, key, attempt_id, digest, is_error) do
    data =
      Enum.map([key, attempt_id, digest, to_string(is_error)], &<<byte_size(&1)::32, &1::binary>>)

    :crypto.mac(:hmac, :sha256, c.seal_key, data) |> Base.encode16(case: :lower)
  end
end
