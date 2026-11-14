# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandbox.Json do
  @moduledoc false
  # Canonical UTF-8 JSON shared by the descriptor identity, the request frame and
  # the size rule: no whitespace, object keys sorted bytewise, strings escaped
  # only for `"`, `\`, and control characters, integers in decimal, floats as the
  # shortest round-trip digits in a fixed layout. The C host implements the same
  # rules; the plain-data bounds are measured on this encoding.

  import Bitwise

  @int_min -9_223_372_036_854_775_808
  @int_max 9_223_372_036_854_775_807
  @max_containers 32

  def int_min, do: @int_min
  def int_max, do: @int_max
  def max_containers, do: @max_containers

  @doc "Canonical encoding of a plain term (maps need binary keys)."
  def encode(term), do: IO.iodata_to_binary(enc(term))

  defp enc(nil), do: "null"
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(int) when is_integer(int), do: Integer.to_string(int)
  defp enc(float) when is_float(float), do: float_text(float)
  defp enc(text) when is_binary(text), do: [?", escape(text), ?"]

  defp enc(list) when is_list(list),
    do: ["[", list |> Enum.map(&enc/1) |> Enum.intersperse(","), "]"]

  defp enc(map) when is_map(map) do
    members =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [enc(key), ":", enc(value)] end)
      |> Enum.intersperse(",")

    ["{", members, "}"]
  end

  defp escape(text), do: for(<<byte <- text>>, into: "", do: esc(byte))

  defp esc(?"), do: "\\\""
  defp esc(?\\), do: "\\\\"
  defp esc(?\b), do: "\\b"
  defp esc(?\f), do: "\\f"
  defp esc(?\n), do: "\\n"
  defp esc(?\r), do: "\\r"
  defp esc(?\t), do: "\\t"

  defp esc(byte) when byte < 0x20 do
    "\\u" <> String.pad_leading(String.downcase(Integer.to_string(byte, 16)), 4, "0")
  end

  defp esc(byte), do: <<byte>>

  @doc "Shortest round-trip digits in a fixed layout; always contains `.`."
  def float_text(float) do
    <<sign::1, _::63>> = <<float::float>>
    {digits, exponent} = shortest(abs(float))
    if(sign == 1, do: "-", else: "") <> layout(digits, exponent)
  end

  defp shortest(value) do
    Enum.find_value(0..16, fn precision ->
      text = :erlang.float_to_binary(value, [{:scientific, precision}])
      [mantissa, exponent] = String.split(text, "e")

      # an overflowing candidate (for example 2e+308) does not parse: it is not a match
      case Float.parse(mantissa <> "e" <> exponent) do
        {^value, ""} -> {String.replace(mantissa, ".", ""), String.to_integer(exponent)}
        _ -> nil
      end
    end)
  end

  defp layout(digits, exponent) when exponent >= -5 and exponent < 16 do
    count = byte_size(digits)

    cond do
      exponent < 0 ->
        "0." <> String.duplicate("0", -exponent - 1) <> digits

      count <= exponent + 1 ->
        digits <> String.duplicate("0", exponent + 1 - count) <> ".0"

      true ->
        binary_part(digits, 0, exponent + 1) <>
          "." <> binary_part(digits, exponent + 1, count - exponent - 1)
    end
  end

  defp layout(digits, exponent) do
    count = byte_size(digits)
    rest = if count == 1, do: "0", else: binary_part(digits, 1, count - 1)
    binary_part(digits, 0, 1) <> "." <> rest <> "e" <> Integer.to_string(exponent)
  end

  @doc """
  Check a term as plain data within `value_bytes`.

  Returns `:ok`, `:invalid` (not plain data, or more than 32 nested containers)
  or `:size` (the canonical encoding is over `value_bytes`).

  The walk carries a budget of `value_bytes`. Each node takes at most its size in
  the canonical encoding (a string its bytes and two quotes, a number or a literal
  one byte, a container two bytes), so the walk stops with `:size` as soon as the
  budget is used up and its work is bounded by `value_bytes`, not by the count of
  references to shared subterms. Where a term is both over the size and not plain
  data, the answer is the one that the walk meets first. `encode/1` runs only on a
  term that the walk passed, and its size is compared exactly.
  """
  def check(term, value_bytes) do
    case walk(term, value_bytes, 0) do
      :invalid -> :invalid
      :size -> :size
      {:ok, _left} -> if byte_size(encode(term)) > value_bytes, do: :size, else: :ok
    end
  end

  # Returns :invalid, :size or {:ok, budget left}.
  defp walk(nil, left, _), do: take(left, 1)
  defp walk(bool, left, _) when is_boolean(bool), do: take(left, 1)

  defp walk(int, left, _) when is_integer(int) and int >= @int_min and int <= @int_max,
    do: take(left, 1)

  defp walk(float, left, _) when is_float(float), do: take(left, 1)

  defp walk(text, left, _) when is_binary(text) do
    case take(left, byte_size(text) + 2) do
      {:ok, _} = ok -> if String.valid?(text), do: ok, else: :invalid
      :size -> :size
    end
  end

  defp walk(list, left, depth) when is_list(list) and depth < @max_containers do
    with {:ok, left} <- take(left, 2), do: walk_all(list, left, depth + 1)
  end

  defp walk(map, left, depth)
       when is_map(map) and not is_struct(map) and depth < @max_containers do
    with {:ok, left} <- take(left, 2) do
      Enum.reduce_while(map, {:ok, left}, fn {key, value}, {:ok, acc} ->
        with true <- is_binary(key),
             {:ok, acc} <- walk(key, acc, depth + 1),
             {:ok, acc} <- walk(value, acc, depth + 1) do
          {:cont, {:ok, acc}}
        else
          :size -> {:halt, :size}
          _ -> {:halt, :invalid}
        end
      end)
    end
  end

  defp walk(_, _, _), do: :invalid

  defp walk_all([], left, _depth), do: {:ok, left}

  defp walk_all([item | tail], left, depth) do
    case walk(item, left, depth) do
      {:ok, left} -> walk_all(tail, left, depth)
      other -> other
    end
  end

  defp walk_all(_improper, _left, _depth), do: :invalid

  defp take(left, cost) when cost <= left, do: {:ok, left - cost}
  defp take(_left, _cost), do: :size

  @doc """
  Strict decode: valid JSON, no duplicate object keys, no trailing bytes.
  Returns `{:ok, term}` or `:error`.
  """
  def decode(bytes) when is_binary(bytes) do
    case Jason.decode(bytes, objects: :ordered_objects) do
      {:ok, term} -> plain(term)
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp plain(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))

    if length(Enum.uniq(keys)) == length(keys) do
      Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case plain(value) do
          {:ok, converted} -> {:cont, {:ok, Map.put(acc, key, converted)}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp plain(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case plain(item) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp plain(other), do: {:ok, other}

  @doc "Little-endian 32-bit frame header plus the body."
  def frame(body), do: <<byte_size(body)::unsigned-little-32>> <> body

  def frame_max, do: 1 <<< 20
end
