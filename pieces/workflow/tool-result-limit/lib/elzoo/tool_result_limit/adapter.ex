# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ToolResultLimit.Adapter do
  @moduledoc """
  `delivery/effect-intent` Adapter for the one outside write of
  `workflow/tool-result-limit`: the `Elzoo.Artifact.put/4` of a recorded tool result.

  The host binds it:

      use Elzoo.EffectIntent.Binding,
        adapter: Elzoo.ToolResultLimit.Adapter,
        failures: Elzoo.ToolResultLimit.Adapter.failures(),
        no_send_attestations: Elzoo.ToolResultLimit.Adapter.no_send(),
        id: ..., provider_account: ..., operation: ..., clock: ...

  The Adapter context is `%{log, extract, artifact, caller, access,
  access_expires_at_unix_ms, retain_until_unix_ms, sink, seal_key}`, fixed by
  the host when it starts the intent owner.
  """
  alias Elzoo.ToolResultLimit.Result

  @schema "elzoo.tool-result-limit.put"
  @value_schema "elzoo.tool-result-limit.receipt"
  @keys ~w(encoding media_type sequence sha256 size_bytes stream version)
  @failures %{
    invalid_arguments: {"rejected", "not_dispatched", "permanent"},
    record_unavailable: {"timed_out", "not_dispatched", "unavailable"},
    digest_mismatch: {"rejected", "not_dispatched", "permanent"},
    store_refused: {"failed", "dispatched", "permanent"},
    store_unknown: {"unknown", "dispatched", "unclassified"}
  }

  @doc "The fixed failure table: tag => {outcome, dispatch, error_class}."
  def failures, do: @failures

  @doc "The tags that attest that `put` was not called."
  def no_send, do: [:invalid_arguments, :record_unavailable, :digest_mismatch]

  def failure_tags, do: @failures |> Map.keys() |> Enum.sort()
  def schema, do: @schema

  @doc """
  The canonical argument bytes of an intent from a store payload and the log
  record (`stream`, `sequence`) that holds the outcome; `{:error, :invalid_input}`
  for a malformed operand.
  """
  def arguments(payload, stream, sequence) when is_map(payload) do
    fields = %{
      "version" => 1,
      "stream" => stream,
      "sequence" => sequence,
      "sha256" => payload["sha256"],
      "size_bytes" => payload["size_bytes"],
      "media_type" => payload["media_type"],
      "encoding" => payload["encoding"]
    }

    if fields?(fields), do: canonical(fields), else: {:error, :invalid_input}
  end

  def arguments(_, _, _), do: {:error, :invalid_input}

  def validate(bytes, @schema), do: if(match?({:ok, _}, decode(bytes)), do: :ok, else: :error)
  def validate(_, _), do: :error

  def send_effect(%{context: ctx, key: key, attempt_id: attempt_id} = req) do
    with {:ok, a} <- tagged(decode(req.arguments), :invalid_arguments),
         {:ok, row} <- tagged(record(ctx.log, a), :record_unavailable),
         {:ok, result} <- tagged(extract(ctx.extract, row.payload), :record_unavailable),
         {:ok, bytes} <- tagged(matching(result, a), :digest_mismatch) do
      put(ctx, key, attempt_id, a, bytes, req)
    end
  end

  # Never a second put: an unknown put stays unknown.
  def poll(_req), do: {:unavailable, :no_status}

  def authenticate(%{"outcome" => "completed", "value" => value}, req) do
    with %{"receipt_sha256" => digest, "seal" => seal} when map_size(value) == 2 <- value,
         true <- is_binary(digest) and is_binary(seal),
         expected = seal(req.context.seal_key, req.key, req.attempt_id, digest),
         true <- byte_size(seal) == byte_size(expected) and :crypto.hash_equals(seal, expected) do
      :ok
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def authenticate(_, _), do: :error

  def validate_result(
        %{
          "outcome" => "completed",
          "message_id" => key,
          "correlation_id" => key,
          "attempt_id" => attempt_id,
          "value_schema_id" => @value_schema,
          "value_schema_version" => 1,
          "value" => %{"receipt_sha256" => digest, "seal" => seal} = value
        },
        %{key: key, attempt_id: attempt_id}
      )
      when map_size(value) == 2 and is_binary(seal) do
    if hex?(digest), do: :ok, else: :error
  end

  def validate_result(_, _), do: :error

  defp put(ctx, key, attempt_id, a, bytes, req) do
    input = %{
      bytes: bytes,
      media_type: a["media_type"],
      access: ctx.access,
      access_expires_at_unix_ms: ctx.access_expires_at_unix_ms,
      retain_until_unix_ms: ctx.retain_until_unix_ms
    }

    case call_put(ctx, key, input) do
      {:ok, record} ->
        receipt = %{
          "artifact_id" => record.artifact_id,
          "version" => record.version,
          "sha256" => a["sha256"],
          "size_bytes" => record.size_bytes,
          "media_type" => record.media_type
        }

        {:ok, encoded} = canonical(receipt)
        digest = sha256(encoded)
        notify(ctx.sink, key, {:receipt, attempt_id, receipt})
        completed(req, digest)

      {:error, reason}
      when reason in [:too_large, :invalid, :access_denied, :expired, :deleted] ->
        {:error, :store_refused, nil}

      {:error, {tag, _}} when tag in [:invalid, :object_store_refused] ->
        {:error, :store_refused, nil}

      _ ->
        {:error, :store_unknown, nil}
    end
  end

  defp call_put(ctx, key, input) do
    Elzoo.Artifact.put(ctx.artifact, ctx.caller, key, input)
  catch
    _, _ -> :raised
  end

  # A failure of the sink does not change the result.
  defp notify(sink, key, message) do
    sink.(key, message)
  catch
    _, _ -> :ok
  end

  defp completed(req, digest) do
    %{
      "version" => 1,
      "message_id" => req.key,
      "correlation_id" => req.key,
      "attempt_id" => req.attempt_id,
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => %{
        "receipt_sha256" => digest,
        "seal" => seal(req.context.seal_key, req.key, req.attempt_id, digest)
      },
      "value_schema_id" => @value_schema,
      "value_schema_version" => 1
    }
  end

  defp seal(seal_key, key, attempt_id, digest) do
    framed =
      for part <- [key, attempt_id, digest], into: "", do: <<byte_size(part)::32, part::binary>>

    :crypto.mac(:hmac, :sha256, seal_key, framed) |> Base.encode16(case: :lower)
  end

  # Step 1: a committed record at exactly this sequence; a staged tail is not a record.
  defp record(log, %{"stream" => stream, "sequence" => sequence}) do
    case Elzoo.DurableLog.read(log, stream, sequence, 1) do
      {:ok, [%{sequence: ^sequence} = row], %{revision: revision}} when sequence <= revision ->
        {:ok, row}

      _ ->
        :error
    end
  catch
    _, _ -> :error
  end

  defp extract(extract, payload) do
    case extract.(payload) do
      {:ok, result} -> {:ok, result}
      _ -> :error
    end
  catch
    _, _ -> :error
  end

  # Step 2: the recorded result has the media type, encoding, size and hash of the arguments.
  defp matching(result, a) do
    with {:ok, _marked, media, encoding, bytes} <- Result.result(result),
         true <- media == a["media_type"] and encoding == a["encoding"],
         true <- byte_size(bytes) == a["size_bytes"] and sha256(bytes) == a["sha256"] do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp tagged({:ok, value}, _tag), do: {:ok, value}
  defp tagged(_, tag), do: {:error, tag, nil}

  defp decode(bytes) when is_binary(bytes) do
    with {:ok, %{} = fields} <- Jason.decode(bytes),
         true <- map_size(fields) == 7 and Enum.sort(Map.keys(fields)) == @keys,
         true <- fields?(fields),
         {:ok, ^bytes} <- canonical(fields) do
      {:ok, fields}
    else
      _ -> :error
    end
  end

  defp decode(_), do: :error

  defp fields?(f) do
    f["version"] === 1 and is_binary(f["stream"]) and f["stream"] != "" and
      String.valid?(f["stream"]) and is_integer(f["sequence"]) and f["sequence"] > 0 and
      hex?(f["sha256"]) and is_integer(f["size_bytes"]) and f["size_bytes"] >= 0 and
      Result.media?(f["media_type"]) and f["encoding"] in ["utf8", "base64"]
  end

  defp canonical(map),
    do: {:ok, map |> Enum.sort() |> Jason.OrderedObject.new() |> Jason.encode!()}

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp hex?(h), do: is_binary(h) and Regex.match?(~r/\A[0-9a-f]{64}\z/, h)
end
