# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiEmbedding.Request do
  @moduledoc """
  The embedding request carried as the Effect command payload (schema
  `elzoo/ai-embedding-request` version 1): a JSON object with exactly these
  members.

  - `"version"`: `1`.
  - `"model"`: model identifier, 1..256 bytes without control characters.
  - `"inputs"`: 1..2048 strings, each nonempty valid UTF-8 (newlines and tabs
    allowed). The Config narrows the count and the bytes per input.
  - `"dimensions"` (optional): a positive integer; the provider declares which
    values each model accepts.
  - `"input_type"` (optional): `"query" | "document" | "unspecified"` (default
    `"unspecified"`).
  - `"provider_options"` (optional): an object of at most 32 members, validated by
    the provider.

  `decode/2` refuses duplicate keys at any depth, unknown members and invalid
  UTF-8, and returns the normalized request (atom keys) with the canonical
  encoding (object keys sorted, no insignificant whitespace, Jason's string
  escaping). The canonical bytes are the EffectIntent argument bytes, so the
  request bound applies to them: more than `max` canonical bytes (at most
  65,536, the `delivery/effect-intent` argument bound) is `:too_large`. A raw
  payload over `parse_limit/0` bytes is refused `:too_large` without parsing.
  Errors are fixed atoms; nothing is echoed.
  """
  @max_bytes 65_536
  @parse_limit 1_048_576
  @max_inputs 2048
  @top ~w(version model inputs dimensions input_type provider_options)
  @required ~w(version model inputs)
  @input_types %{"unspecified" => :unspecified, "query" => :query, "document" => :document}

  def max_bytes, do: @max_bytes
  def parse_limit, do: @parse_limit
  def max_inputs, do: @max_inputs

  @doc "Decodes and normalizes payload bytes; `{:ok, request, canonical}` or `{:error, reason}`."
  def decode(bytes, max \\ @max_bytes)

  def decode(bytes, max) when is_binary(bytes) and is_integer(max) and max in 1..@max_bytes do
    cond do
      byte_size(bytes) > @parse_limit ->
        {:error, :too_large}

      not String.valid?(bytes) ->
        {:error, :invalid_request}

      true ->
        with {:ok, ordered} <- json(bytes),
             {:ok, value} <- plain(ordered),
             {:ok, request} <- normalize(value) do
          canonical = canonical(value)

          if byte_size(canonical) > max,
            do: {:error, :too_large},
            else: {:ok, request, canonical}
        end
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  def decode(_, _), do: {:error, :invalid_request}

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
    Enum.reduce_while(list, {:ok, []}, fn v, {:ok, acc} ->
      case plain(v) do
        {:ok, pv} -> {:cont, {:ok, [pv | acc]}}
        e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, l} -> {:ok, Enum.reverse(l)}
      e -> e
    end
  end

  defp plain(v), do: {:ok, v}

  @doc "Canonical JSON: object keys sorted, no insignificant whitespace."
  def canonical(map) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> canonical(v) end)

    "{" <> inner <> "}"
  end

  def canonical(list) when is_list(list), do: "[" <> Enum.map_join(list, ",", &canonical/1) <> "]"
  def canonical(v), do: Jason.encode!(v)

  defp normalize(%{} = v) do
    cond do
      not Enum.all?(Map.keys(v), &(&1 in @top)) -> {:error, :invalid_request}
      not Enum.all?(@required, &Map.has_key?(v, &1)) -> {:error, :invalid_request}
      v["version"] != 1 -> {:error, :invalid_request}
      not Elzoo.AiModel.text?(v["model"], 256) -> {:error, :invalid_request}
      true -> build(v)
    end
  end

  defp normalize(_), do: {:error, :invalid_request}

  defp build(v) do
    with {:ok, inputs} <- inputs(v["inputs"]),
         {:ok, dims} <- dimensions(Map.get(v, "dimensions")),
         {:ok, type} <- Map.fetch(@input_types, Map.get(v, "input_type", "unspecified")),
         {:ok, options} <- options(Map.get(v, "provider_options")) do
      {:ok,
       %{
         model: v["model"],
         inputs: inputs,
         dimensions: dims,
         input_type: type,
         provider_options: options
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_request}
    end
  end

  defp inputs(list) when is_list(list) and list != [] do
    cond do
      length(list) > @max_inputs -> {:error, :too_large}
      Enum.all?(list, &input?/1) -> {:ok, list}
      true -> {:error, :invalid_request}
    end
  end

  defp inputs(_), do: {:error, :invalid_request}

  defp input?(s), do: is_binary(s) and s != "" and String.valid?(s)

  defp dimensions(nil), do: {:ok, nil}
  defp dimensions(n) when is_integer(n) and n >= 1, do: {:ok, n}
  defp dimensions(_), do: {:error, :invalid_request}

  defp options(nil), do: {:ok, %{}}
  defp options(%{} = o) when map_size(o) <= 32, do: {:ok, o}
  defp options(_), do: {:error, :invalid_request}
end
