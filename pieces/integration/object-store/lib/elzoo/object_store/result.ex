# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ObjectStore.Result do
  @moduledoc """
  The finite outcome table of `integration/object-store` and its ELZ-011 delivery-result
  mapping. Every result is a map with `status`, `operation`, `store`, `bucket` and `key`
  (key-addressed operations) or `prefix` (`list`).

  | status | fields |
  | --- | --- |
  | `:committed` | `etag`, `bytes`, `sha256` (put: hex SHA-256 the provider echoed; delete: nil) |
  | `:found` | `metadata` (`etag`, `size`, `content_type`, `last_modified`, `sha256`), `body` (get only) |
  | `:absent` | — |
  | `:listed` | `keys`, `truncated`, `continuation` |
  | `:refused` | `reason`, `origin`: `:local` (decided before any connection), `:provider` (the provider's response) or `:adapter` (a get body over the bound, decided after dispatch) |
  | `:unknown` | `reason` |

  Refusal reasons: `denied`, `no_such_bucket`, `precondition_failed`, `too_large`,
  `invalid_key`, `checksum_mismatch`, `invalid_request`, `credentials_unavailable`.
  Unknown reasons: `deadline`, `transport`, `server_error`, `unverified`, `unexpected`,
  `integrity`, `adapter_error`.
  """

  @refusals ~w(denied no_such_bucket precondition_failed too_large invalid_key checksum_mismatch invalid_request credentials_unavailable)a
  @unknowns ~w(deadline transport server_error unverified unexpected integrity adapter_error)a
  @local_only ~w(invalid_request credentials_unavailable)a

  def refusal_reasons, do: @refusals
  def unknown_reasons, do: @unknowns

  @doc false
  def base(config, operation, target) do
    Map.merge(%{operation: operation, store: config.store_id, bucket: config.bucket}, target)
  end

  @doc false
  def refused(base, reason, origin)
      when reason in @refusals and origin in [:local, :provider, :adapter] and
             not (reason in @local_only and origin != :local),
      do: Map.merge(base, %{status: :refused, reason: reason, origin: origin})

  @doc false
  def unknown(base, reason) when reason in @unknowns,
    do: Map.merge(base, %{status: :unknown, reason: reason})

  @doc """
  Classify a provider error response (status and S3 error code) into the table. `code` is
  nil when the response carried none. `absent` is produced only for `NoSuchKey` on a read.
  """
  def classify_error(base, status, code, operation) do
    cond do
      status == 403 ->
        refused(base, :denied, :provider)

      status == 404 and code == "NoSuchBucket" ->
        refused(base, :no_such_bucket, :provider)

      status == 404 and code == "NoSuchKey" and operation in [:get, :head] ->
        Map.put(base, :status, :absent)

      status == 412 ->
        refused(base, :precondition_failed, :provider)

      status == 400 and code in ["XAmzContentChecksumMismatch", "BadDigest"] ->
        refused(base, :checksum_mismatch, :provider)

      status == 413 or (status == 400 and code == "EntityTooLarge") ->
        refused(base, :too_large, :provider)

      status == 400 and
          code in ["XMinioInvalidResourceName", "KeyTooLongError", "InvalidObjectName"] ->
        refused(base, :invalid_key, :provider)

      is_integer(status) and status >= 500 ->
        unknown(base, :server_error)

      true ->
        unknown(base, :unexpected)
    end
  end

  # ---- delivery mapping (ELZ-011)

  @doc """
  `{:ok, delivery_result_map, result}` or `{:error, reason}`. `request` is a string-keyed map
  with `message_id` and optional `correlation_id`, `attempt_id`, `deadline_unix_ms`. The map is
  checked by `Elzoo.Envelope.validate_result/1`. The value never carries a body or a URL.
  """
  def to_delivery_result(%{status: status} = result, request) when is_map(request) do
    with {:ok, base} <- envelope_base(request) do
      map =
        case status do
          s when s in [:committed, :found, :absent, :listed] ->
            Map.merge(base, %{
              "outcome" => "completed",
              "dispatch" => "dispatched",
              "value" => value(result),
              "value_schema_id" => "elzoo/object-store-#{status}",
              "value_schema_version" => 1
            })

          :refused ->
            {outcome, dispatch, class} = failure(result)
            fail(base, outcome, dispatch, class)

          :unknown ->
            {outcome, dispatch, class} = failure(result)
            fail(base, outcome, dispatch, class)
        end

      case Elzoo.Envelope.validate_result(map) do
        {:ok, checked} -> {:ok, checked, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "The `{outcome, dispatch, error_class}` triple of a refused or unknown result."
  def failure(%{status: :refused, reason: :credentials_unavailable}),
    do: {"rejected", "not_dispatched", "unavailable"}

  def failure(%{status: :refused, origin: :local}), do: {"rejected", "not_dispatched", "permanent"}

  def failure(%{status: :refused, origin: o}) when o in [:provider, :adapter],
    do: {"failed", "dispatched", "permanent"}

  def failure(%{status: :unknown, reason: :deadline}), do: {"timed_out", "unknown", "unclassified"}

  def failure(%{status: :unknown, reason: r}) when r in [:transport, :adapter_error],
    do: {"unknown", "unknown", "unclassified"}

  def failure(%{status: :unknown}), do: {"unknown", "dispatched", "unclassified"}

  defp value(%{status: :committed} = r),
    do: %{"key" => r.key, "etag" => r.etag, "bytes" => r.bytes, "sha256" => r.sha256}

  defp value(%{status: :found, metadata: m} = r),
    do: %{
      "key" => r.key,
      "etag" => m.etag,
      "size" => m.size,
      "content_type" => m.content_type,
      "sha256" => m.sha256
    }

  defp value(%{status: :absent} = r), do: %{"key" => r.key}

  defp value(%{status: :listed} = r),
    do: %{
      "prefix" => r.prefix,
      "keys" => r.keys,
      "truncated" => r.truncated,
      "continuation" => r.continuation
    }

  defp envelope_base(request) do
    case request["message_id"] do
      id when is_binary(id) and id != "" ->
        base = %{
          "version" => 1,
          "message_id" => id,
          "correlation_id" => request["correlation_id"] || id
        }

        {:ok,
         Enum.reduce(~w(attempt_id deadline_unix_ms), base, fn key, acc ->
           case request[key] do
             nil -> acc
             v -> Map.put(acc, key, v)
           end
         end)}

      _ ->
        {:error, :missing_message_id}
    end
  end

  defp fail(base, outcome, dispatch, class),
    do: Map.merge(base, %{"outcome" => outcome, "dispatch" => dispatch, "error_class" => class})
end
