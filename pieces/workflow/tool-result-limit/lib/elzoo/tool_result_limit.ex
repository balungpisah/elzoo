# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ToolResultLimit do
  @moduledoc """
  Pure cut decision for a tool result: whole under the declared bound, else a
  store action for the whole bytes and a bounded, still marked, preview.
  """
  alias Elzoo.UntrustedContent
  alias Elzoo.ToolResultLimit.Result

  @min_bound 1_024
  @max_bound 1_048_576
  @reserve 512
  @outcomes ~w(completed failed refused late unknown out_of_budget retries_exhausted expired resource_lost)
  @pending_keys ~w(content size_bytes sha256 media_type encoding)
  @receipt_keys ~w(artifact_id version sha256 size_bytes media_type)
  @segment ~r/\A[A-Za-z0-9_.-]{1,64}\z/
  @max_version 9_223_372_036_854_775_807

  @doc """
  `decide(result, %{max_bytes: n, artifact_max_bytes: m}, source_action_id)` gives
  `{:ok, bounded}`, `{:store, pending, payload}`, `{:error, :unmarked}` or
  `{:error, :invalid_input}`. `payload` belongs to one `tool_call` action under
  the schema key `elzoo.tool-result-limit.store` version 1.
  """
  def decide(result, limits, source_action_id) do
    with {:ok, marked, media, encoding, bytes} <- Result.result(result),
         {:ok, max, artifact_max} <- limits(limits),
         true <- text?(source_action_id) || {:error, :invalid_input} do
      size = byte_size(bytes)

      decision =
        apply(:"Cure.Elzoo.ToolResultLimit", :decide, [
          encoding == "utf8",
          size > max,
          size > artifact_max
        ])

      sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      preview = if encoding == "utf8", do: preview(bytes, max - @reserve), else: ""
      pending = fn -> pending(marked, max, preview, size, sha, media, encoding) end

      case decision do
        :Whole ->
          {:ok, %{"content" => result["content"], "cut" => nil}}

        :Store ->
          {:store, pending.(),
           %{
             "source_action_id" => source_action_id,
             "sha256" => sha,
             "size_bytes" => size,
             "media_type" => media,
             "encoding" => encoding
           }}

        :OverArtifactMax ->
          {:ok, bounded(pending.(), nil, "over_artifact_max")}
      end
    end
  end

  @doc """
  `settle(pending, outcome, receipt)` gives `{:ok, bounded}` from the outcome
  class of the store action, or `{:error, :invalid_input}` (a `late` outcome
  included).
  """
  def settle(pending, outcome, receipt) do
    cond do
      not pending?(pending) or outcome not in @outcomes or outcome == "late" ->
        {:error, :invalid_input}

      outcome == "completed" and receipt?(receipt, pending) ->
        artifact = %{"artifact_id" => receipt["artifact_id"], "version" => receipt["version"]}
        {:ok, bounded(pending, artifact, nil)}

      outcome in ["completed", "unknown"] ->
        {:ok, bounded(pending, nil, "store_unknown")}

      true ->
        {:ok, bounded(pending, nil, "store_refused")}
    end
  end

  defp limits(%{max_bytes: max, artifact_max_bytes: artifact_max} = limits)
       when map_size(limits) == 2 and is_integer(max) and max in @min_bound..@max_bound and
              is_integer(artifact_max) and artifact_max > 0,
       do: {:ok, max, artifact_max}

  defp limits(_), do: {:error, :invalid_input}

  # The longest prefix of at most `limit` bytes that ends at a code point boundary.
  defp preview(text, limit) when byte_size(text) <= limit, do: text
  defp preview(text, limit), do: binary_part(text, 0, boundary(text, limit))

  defp boundary(_text, 0), do: 0

  defp boundary(text, at) do
    case :binary.at(text, at) do
      byte when Bitwise.band(byte, 0xC0) == 0x80 -> boundary(text, at - 1)
      _ -> at
    end
  end

  # Holds the preview, the fields of the cut, the sources and trust of the mark
  # and the declared bound; never content beyond the preview.
  defp pending(marked, max, preview, size, sha, media, encoding) do
    map = %{UntrustedContent.encode(marked) | "content" => preview, "max_bytes" => max}
    {:ok, checked} = UntrustedContent.decode(map)

    %{
      "content" => UntrustedContent.encode(checked),
      "size_bytes" => size,
      "sha256" => sha,
      "media_type" => media,
      "encoding" => encoding
    }
  end

  defp pending?(%{"content" => content} = p) when map_size(p) == 5 do
    with true <- Enum.all?(@pending_keys, &Map.has_key?(p, &1)),
         {:ok, _} <- UntrustedContent.decode(content),
         preview = content["content"],
         true <- content["max_bytes"] in @min_bound..@max_bound,
         true <- byte_size(preview) <= content["max_bytes"] - @reserve,
         true <- is_integer(p["size_bytes"]) and p["size_bytes"] in byte_size(preview)..16_777_216,
         true <- hex?(p["sha256"]) and Result.media?(p["media_type"]),
         true <- p["encoding"] == "utf8" or (p["encoding"] == "base64" and preview == "") do
      true
    else
      _ -> false
    end
  end

  defp pending?(_), do: false

  defp receipt?(%{} = r, p) when map_size(r) == 5 do
    Enum.all?(@receipt_keys, &Map.has_key?(r, &1)) and is_binary(r["artifact_id"]) and
      Regex.match?(@segment, r["artifact_id"]) and r["artifact_id"] not in [".", ".."] and
      is_integer(r["version"]) and r["version"] in 1..@max_version and
      Result.media?(r["media_type"]) and
      r["sha256"] == p["sha256"] and r["size_bytes"] === p["size_bytes"]
  end

  defp receipt?(_, _), do: false

  defp bounded(p, artifact, note) do
    preview = p["content"]["content"]
    size = p["size_bytes"]

    text =
      case {p["encoding"], artifact} do
        {"utf8", %{"artifact_id" => id, "version" => v}} ->
          "[cut: first #{byte_size(preview)} of #{size} bytes shown; whole result: artifact #{id} version #{v}]\n" <>
            preview

        {"utf8", nil} ->
          "[cut: first #{byte_size(preview)} of #{size} bytes shown; whole result not stored: #{note}]\n" <>
            preview

        {"base64", %{"artifact_id" => id, "version" => v}} ->
          "[binary result: #{size} bytes, #{p["media_type"]}; artifact #{id} version #{v}]"

        {"base64", nil} ->
          "[binary result: #{size} bytes, #{p["media_type"]}; not stored: #{note}]"
      end

    {:ok, checked} = UntrustedContent.decode(%{p["content"] | "content" => text})

    %{
      "content" => UntrustedContent.encode(checked),
      "cut" => %{
        "size_bytes" => size,
        "sha256" => p["sha256"],
        "media_type" => p["media_type"],
        "preview_bytes" => byte_size(preview),
        "artifact" => artifact,
        "note" => note
      }
    }
  end

  defp text?(t), do: is_binary(t) and t != "" and String.valid?(t)
  defp hex?(h), do: is_binary(h) and Regex.match?(~r/\A[0-9a-f]{64}\z/, h)
end
