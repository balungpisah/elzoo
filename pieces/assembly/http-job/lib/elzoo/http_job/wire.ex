# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.HttpJob.Wire do
  @moduledoc false
  @limit 16_384
  def limit, do: @limit

  def json(bytes) when is_binary(bytes) and byte_size(bytes) <= @limit do
    with {:ok, term} <- Jason.decode(bytes, keys: :strings, objects: :ordered_objects) do
      try do
        {map, _} = walk(term, 0, 128)
        if is_map(map), do: {:ok, map}, else: {:error, :schema}
      catch
        :invalid -> {:error, :schema}
      end
    else
      _ -> {:error, :schema}
    end
  rescue
    _ -> {:error, :schema}
  end

  def json(_), do: {:error, :schema}

  def publication(bytes) do
    with {:ok, map} <- json(bytes),
         true <- Enum.sort(Map.keys(map)) == ~w(kind text version),
         1 <- map["version"],
         "publication" <- map["kind"],
         text when is_binary(text) <- map["text"],
         true <- byte_size(text) <= 8192 and String.valid?(text) do
      :ok
    else
      _ -> {:error, :schema}
    end
  end

  def receipt(bytes) do
    with {:ok, map} <- json(bytes), do: normalize(map)
  end

  def normalize(map) when is_map(map) do
    with 1 <- map["version"],
         true <- hex?(map["key"]) and hex?(map["digest"]),
         true <- text?(map["kind"], 64),
         ack when is_boolean(ack) <- map["ack"] do
      {:ok,
       %{
         "version" => 1,
         "key" => map["key"],
         "digest" => map["digest"],
         "kind" => map["kind"],
         "ack" => ack,
         "trust" => "untrusted"
       }}
    else
      _ -> {:error, :schema}
    end
  end

  def normalize(_), do: {:error, :schema}
  def hex?(v), do: is_binary(v) and byte_size(v) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, v)

  def text?(v, max),
    do:
      is_binary(v) and byte_size(v) in 1..max and String.valid?(v) and
        not Regex.match?(~r/\p{Cc}/u, v)

  defp walk(_, d, n) when d > 8 or n < 1, do: throw(:invalid)

  defp walk(%Jason.OrderedObject{values: pairs}, d, n) do
    keys = Enum.map(pairs, &elem(&1, 0))
    if length(keys) > 32 or length(keys) != length(Enum.uniq(keys)), do: throw(:invalid)

    {rev, left} =
      Enum.reduce(pairs, {[], n - 1}, fn {key, value}, {acc, budget} ->
        if not is_binary(key) or byte_size(key) > 128, do: throw(:invalid)
        {child, rest} = walk(value, d + 1, budget)
        {[{key, child} | acc], rest}
      end)

    {Map.new(rev), left}
  end

  defp walk(list, d, n) when is_list(list), do: Enum.map_reduce(list, n - 1, &walk(&1, d + 1, &2))
  defp walk(value, _, n), do: {value, n - 1}
end
