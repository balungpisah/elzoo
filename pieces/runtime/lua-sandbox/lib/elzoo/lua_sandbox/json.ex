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
  or `:size` (a string or the canonical encoding is over `value_bytes`).
  """
  def check(term, value_bytes) do
    case walk(term, value_bytes, 0, false) do
      :invalid -> :invalid
      {:ok, true} -> :size
      {:ok, false} -> if byte_size(encode(term)) > value_bytes, do: :size, else: :ok
    end
  end

  # Returns :invalid or {:ok, oversize_string_seen?}
  defp walk(nil, _, _, big), do: {:ok, big}
  defp walk(bool, _, _, big) when is_boolean(bool), do: {:ok, big}

  defp walk(int, _, _, big) when is_integer(int) and int >= @int_min and int <= @int_max,
    do: {:ok, big}

  defp walk(float, _, _, big) when is_float(float), do: {:ok, big}

  defp walk(text, limit, _, big) when is_binary(text) do
    if String.valid?(text), do: {:ok, big or byte_size(text) > limit}, else: :invalid
  end

  defp walk(list, limit, depth, big) when is_list(list) and depth < @max_containers do
    walk_all(list, limit, depth + 1, big)
  end

  defp walk(map, limit, depth, big)
       when is_map(map) and not is_struct(map) and depth < @max_containers do
    Enum.reduce_while(map, {:ok, big}, fn {key, value}, {:ok, acc} ->
      with true <- is_binary(key),
           {:ok, acc} <- walk(key, limit, depth + 1, acc),
           {:ok, acc} <- walk(value, limit, depth + 1, acc) do
        {:cont, {:ok, acc}}
      else
        _ -> {:halt, :invalid}
      end
    end)
  end

  defp walk(_, _, _, _), do: :invalid

  defp walk_all(list, limit, depth, big) do
    if proper?(list) do
      Enum.reduce_while(list, {:ok, big}, fn item, {:ok, acc} ->
        case walk(item, limit, depth, acc) do
          :invalid -> {:halt, :invalid}
          ok -> {:cont, ok}
        end
      end)
    else
      :invalid
    end
  end

  defp proper?([]), do: true
  defp proper?([_ | tail]), do: proper?(tail)
  defp proper?(_), do: false

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
