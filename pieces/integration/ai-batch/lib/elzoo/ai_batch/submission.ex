# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiBatch.Submission do
  @moduledoc """
  The submission carried as the submit command payload (schema
  `elzoo/ai-batch-submission` version 1): a JSON object with exactly
  `"version": 1`, `"model"`, `"items"` (1..N `{"item_id", "request"}`) and an
  optional `"provider_options"` object (at most 32 members).

  - `item_id`: `^[A-Za-z0-9_-]{1,64}$`, unique in the submission.
  - `request`: an `integration/ai-text` request object, decoded by
    `Elzoo.AiText.Request.decode/2` from its canonical bytes, bounded by the item
    byte bound. Its `model` must equal the submission's (one model per
    submission).

  `decode/2` refuses duplicate keys at any depth, unknown members and invalid
  UTF-8, and returns the normalized submission and the canonical encoding
  (sorted keys, no whitespace), from which the caller builds its result join.
  `manifest/4` is the canonical intent argument naming the **exact provider
  create body** prepared once at admission and staged by the host:
  `{"version": 1, "model", "item_count", "wire_bytes", "wire_sha256",
  "provider_meta"}`, where `provider_meta` is the provider's non-secret request
  metadata (at most 8 text members, for example a beta header value). Errors
  are fixed atoms; nothing is echoed.
  """
  alias Elzoo.AiText.Request

  @id ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @manifest_keys ~w(item_count model provider_meta version wire_bytes wire_sha256)

  @doc """
  Decodes payload bytes under `bounds` (`max_submission_bytes`, `max_item_bytes`,
  `max_items`). Returns `{:ok, %{model, items: [%{item_id, request}],
  provider_options}, canonical}` or `{:error, :invalid_request | :too_large |
  :unsupported_feature}`.
  """
  def decode(bytes, bounds) when is_binary(bytes) do
    cond do
      byte_size(bytes) > bounds.max_submission_bytes ->
        {:error, :too_large}

      not String.valid?(bytes) ->
        {:error, :invalid_request}

      true ->
        with {:ok, ordered} <- json(bytes),
             {:ok, value} <- plain(ordered),
             {:ok, submission} <- normalize(value, bounds) do
          canonical = Request.canonical(value)

          if byte_size(canonical) > bounds.max_submission_bytes,
            do: {:error, :too_large},
            else: {:ok, submission, canonical}
        end
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  def decode(_, _), do: {:error, :invalid_request}

  defp normalize(%{"version" => 1, "model" => model, "items" => items} = v, bounds)
       when is_list(items) do
    cond do
      not Enum.all?(Map.keys(v), &(&1 in ~w(version model items provider_options))) ->
        {:error, :invalid_request}

      not Elzoo.AiModel.text?(model, 256) ->
        {:error, :invalid_request}

      items == [] ->
        {:error, :invalid_request}

      length(items) > bounds.max_items ->
        {:error, :too_large}

      true ->
        with {:ok, options} <- options(Map.get(v, "provider_options")),
             {:ok, decoded} <- collect(items, &item(&1, model, bounds)),
             ids = Enum.map(decoded, & &1.item_id),
             true <- length(Enum.uniq(ids)) == length(ids) || {:error, :invalid_request} do
          {:ok, %{model: model, items: decoded, provider_options: options}}
        end
    end
  end

  defp normalize(_, _), do: {:error, :invalid_request}

  defp options(nil), do: {:ok, %{}}
  defp options(%{} = o) when map_size(o) <= 32, do: {:ok, o}
  defp options(_), do: {:error, :invalid_request}

  defp item(%{"item_id" => id, "request" => %{} = request} = i, model, bounds)
       when map_size(i) == 2 do
    with true <- (is_binary(id) and Regex.match?(@id, id)) || {:error, :invalid_request},
         true <- request["model"] == model || {:error, :invalid_request},
         {:ok, decoded, _} <- Request.decode(Request.canonical(request), bounds.max_item_bytes) do
      {:ok, %{item_id: id, request: decoded}}
    end
  end

  defp item(_, _, _), do: {:error, :invalid_request}

  defp collect(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn x, {:ok, acc} ->
      case fun.(x) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        {:error, r} -> {:halt, {:error, r}}
      end
    end)
    |> case do
      {:ok, l} -> {:ok, Enum.reverse(l)}
      e -> e
    end
  end

  defp json(bytes) do
    case Jason.decode(bytes, objects: :ordered_objects) do
      {:ok, v} -> {:ok, v}
      _ -> {:error, :invalid_request}
    end
  end

  # Ordered objects to maps, refusing duplicate keys at any depth.
  defp plain(%Jason.OrderedObject{values: kvs}) do
    keys = Enum.map(kvs, &elem(&1, 0))

    if length(Enum.uniq(keys)) == length(keys) do
      Enum.reduce_while(kvs, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
        case plain(v) do
          {:ok, pv} -> {:cont, {:ok, Map.put(acc, k, pv)}}
          e -> {:halt, e}
        end
      end)
    else
      {:error, :invalid_request}
    end
  end

  defp plain(list) when is_list(list) do
    collect(list, &plain/1)
  end

  defp plain(v), do: {:ok, v}

  @doc "The canonical manifest bytes naming the exact create body `wire_body` and its `meta`."
  def manifest(model, item_count, wire_body, meta) do
    Request.canonical(%{
      "version" => 1,
      "model" => model,
      "item_count" => item_count,
      "wire_bytes" => byte_size(wire_body),
      "wire_sha256" => sha256(wire_body),
      "provider_meta" => meta
    })
  end

  @doc "True for provider metadata: a map of at most 8 text keys to text values (each 1..1024 bytes)."
  def meta?(meta) do
    is_map(meta) and not is_struct(meta) and map_size(meta) <= 8 and
      Enum.all?(meta, fn {k, v} -> Elzoo.AiModel.text?(k, 64) and Elzoo.AiModel.text?(v, 1024) end)
  end

  @doc "Decodes manifest bytes: `{:ok, %{model, item_count, wire_bytes, wire_sha256, provider_meta}}`."
  def decode_manifest(bytes) when is_binary(bytes) and byte_size(bytes) <= 16_384 do
    with {:ok, %{} = m} <- Jason.decode(bytes),
         true <- Enum.sort(Map.keys(m)) == @manifest_keys,
         1 <- m["version"],
         true <- Elzoo.AiModel.text?(m["model"], 256),
         n when is_integer(n) and n > 0 <- m["item_count"],
         b when is_integer(b) and b > 0 <- m["wire_bytes"],
         h when is_binary(h) <- m["wire_sha256"],
         true <- h =~ ~r/\A[0-9a-f]{64}\z/,
         true <- meta?(m["provider_meta"]),
         true <- Request.canonical(m) == bytes do
      {:ok,
       %{
         model: m["model"],
         item_count: n,
         wire_bytes: b,
         wire_sha256: h,
         provider_meta: m["provider_meta"]
       }}
    else
      _ -> {:error, :manifest}
    end
  rescue
    _ -> {:error, :manifest}
  end

  def decode_manifest(_), do: {:error, :manifest}

  @doc "True when `bytes` are exactly the create body the manifest names."
  def matches?(manifest, bytes) when is_binary(bytes) do
    byte_size(bytes) == manifest.wire_bytes and
      :crypto.hash_equals(sha256(bytes), manifest.wire_sha256)
  end

  def matches?(_, _), do: false

  @doc "Lowercase hex SHA-256."
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
