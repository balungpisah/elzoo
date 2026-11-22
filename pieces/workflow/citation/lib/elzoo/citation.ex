# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Citation do
  @moduledoc """
  Pure check of a model's cited answer against the exact items it was given.

  `schema/0` gives the cited-answer schema version 1; `check/3` accepts a
  citation only when its item ID is a given item's by exact bytes and its quote
  occurs in that item's content as exact bytes, and resolves each quote by its
  first occurrence to the item's source, version and byte range. Errors are
  fixed atoms that echo nothing. No I/O, clock, process or normalization.
  """

  @max_items 256
  @max_id 1024
  @max_version 2_147_483_647
  @max_content 1_048_576
  @max_total_content 8_388_608
  @max_offset 9_007_199_254_740_991
  @max_text 65_536
  @max_quote 1024
  @max_citations 32

  @schema %{
    "type" => "object",
    "properties" => %{
      "text" => %{"type" => "string", "maxLength" => @max_text},
      "citations" => %{
        "type" => "array",
        "maxItems" => @max_citations,
        "items" => %{
          "type" => "object",
          "properties" => %{
            "item_id" => %{"type" => "string", "minLength" => 1, "maxLength" => @max_id},
            "quote" => %{"type" => "string", "minLength" => 1, "maxLength" => @max_quote}
          },
          "required" => ["item_id", "quote"],
          "additionalProperties" => false
        }
      }
    },
    "required" => ["text", "citations"],
    "additionalProperties" => false
  }

  @doc "The decoded JSON Schema object of a cited answer, version 1."
  def schema, do: @schema

  @doc """
  Check one decoded answer against the given items under the policy.

  Returns `{:ok, %{citations: resolved}}` or `{:error, reason}`, reason one of
  `:invalid`, `:malformed`, `:too_many`, `:duplicate`, `:unknown_item`,
  `:quote_not_found` and `:uncited`, the first failing rule in that order.
  """
  def check(answer, items, policy) do
    with {:ok, index} <- host(items, policy),
         {:ok, citations, count} <- answer(answer),
         :ok <- if(count > @max_citations, do: {:error, :too_many}, else: :ok),
         :ok <- unique(citations, MapSet.new()),
         :ok <- known(citations, index),
         {:ok, resolved} <- resolve(citations, index, []) do
      if count < policy.min_citations,
        do: {:error, :uncited},
        else: {:ok, %{citations: resolved}}
    end
  end

  # Rule 1: host input, checked before the model's answer.
  defp host(items, %{min_citations: min} = policy)
       when map_size(policy) == 1 and is_integer(min) and min >= 0 and min <= @max_citations,
       do: items(items, %{}, 0, 0)

  defp host(_items, _policy), do: {:error, :invalid}

  defp items([], index, _count, _total), do: {:ok, index}

  defp items([item | rest], index, count, total) when count < @max_items do
    with {:ok, id, content} <- item(item),
         false <- Map.has_key?(index, id),
         sum when sum <= @max_total_content <- total + byte_size(content) do
      items(rest, Map.put(index, id, item), count + 1, sum)
    else
      _ -> {:error, :invalid}
    end
  end

  defp items(_items, _index, _count, _total), do: {:error, :invalid}

  defp item(%{item_id: id, source: source, version: version, content: content} = item)
       when map_size(item) == 4,
       do: fields(id, source, version, content, 0)

  defp item(
         %{item_id: id, source: source, version: version, content: content, start_byte: start} =
           item
       )
       when map_size(item) == 5 and is_integer(start) and start >= 0,
       do: fields(id, source, version, content, start)

  defp item(_item), do: :error

  defp fields(id, source, version, content, start) do
    if text?(id, 1, @max_id) and text?(source, 1, @max_id) and is_integer(version) and
         version >= 1 and version <= @max_version and is_binary(content) and
         byte_size(content) <= @max_content and start + byte_size(content) <= @max_offset,
       do: {:ok, id, content},
       else: :error
  end

  # Rule 2: the answer's shape and bounds, over the whole answer.
  defp answer(%{"text" => text, "citations" => citations} = answer)
       when map_size(answer) == 2 do
    if text?(text, 0, @max_text), do: citations(citations, [], 0), else: {:error, :malformed}
  end

  defp answer(_answer), do: {:error, :malformed}

  defp citations([], acc, count), do: {:ok, Enum.reverse(acc), count}

  defp citations([%{"item_id" => id, "quote" => quote} = citation | rest], acc, count)
       when map_size(citation) == 2 do
    if text?(id, 1, @max_id) and text?(quote, 1, @max_quote),
      do: citations(rest, [{id, quote} | acc], count + 1),
      else: {:error, :malformed}
  end

  defp citations(_citations, _acc, _count), do: {:error, :malformed}

  # Rule 4: a repeated {item_id, quote} pair.
  defp unique([], _seen), do: :ok

  defp unique([pair | rest], seen) do
    if MapSet.member?(seen, pair),
      do: {:error, :duplicate},
      else: unique(rest, MapSet.put(seen, pair))
  end

  # Rule 5: every cited item ID is a given item's by exact bytes.
  defp known(citations, index) do
    if Enum.all?(citations, fn {id, _quote} -> Map.has_key?(index, id) end),
      do: :ok,
      else: {:error, :unknown_item}
  end

  # Rule 6: the quote's bytes occur in the cited item's content; the first
  # occurrence gives the offsets.
  defp resolve([], _index, acc), do: {:ok, Enum.reverse(acc)}

  defp resolve([{id, quote} | rest], index, acc) do
    item = Map.fetch!(index, id)

    case :binary.match(item.content, quote) do
      {position, length} ->
        start = Map.get(item, :start_byte, 0) + position

        entry = %{
          item_id: item.item_id,
          source: item.source,
          version: item.version,
          start_byte: start,
          end_byte: start + length
        }

        resolve(rest, index, [entry | acc])

      :nomatch ->
        {:error, :quote_not_found}
    end
  end

  defp text?(value, min, max),
    do:
      is_binary(value) and byte_size(value) >= min and byte_size(value) <= max and
        String.valid?(value)
end
