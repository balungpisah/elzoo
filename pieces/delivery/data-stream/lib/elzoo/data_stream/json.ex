# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DataStream.JSON do
  @moduledoc false
  # Lex before decoding: strings/escapes are opaque and number lexemes are
  # bounded. An integer has at most 19 digits. decode/1 reads a request and
  # refuses a fraction or an exponent. decode_event/1 reads a stream event and
  # accepts one in a number of at most 64 bytes (ELZ-155). Jason retains objects
  # as ordered pairs until every decoded key at every depth has been checked
  # for duplication.
  @fraction 64
  def decode(bytes), do: decode(bytes, 0)
  def decode_event(bytes), do: decode(bytes, @fraction)

  defp decode(bytes, f) when is_binary(bytes) do
    with true <- String.valid?(bytes),
         :ok <- lex(bytes, 0, false, false, f),
         {:ok, ordered} <- Jason.decode(bytes, objects: :ordered_objects, strings: :copy),
         :ok <- unique(ordered) do
      {:ok, project(ordered)}
    else
      _ -> {:error, :invalid_json}
    end
  rescue
    _ -> {:error, :invalid_json}
  catch
    _, _ -> {:error, :invalid_json}
  end

  defp decode(_, _), do: {:error, :invalid_json}

  def encode(value), do: value |> ordered() |> Jason.encode!()

  defp ordered(m) when is_map(m),
    do: Jason.OrderedObject.new(m |> Enum.sort() |> Enum.map(fn {k, v} -> {k, ordered(v)} end))

  defp ordered(l) when is_list(l), do: Enum.map(l, &ordered/1)
  defp ordered(v), do: v

  defp unique(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(keys) == length(Enum.uniq(keys)),
      do: each(Enum.map(pairs, &elem(&1, 1))),
      else: :error
  end

  defp unique(l) when is_list(l), do: each(l)
  defp unique(_), do: :ok
  defp each(l), do: if(Enum.all?(l, &(unique(&1) == :ok)), do: :ok, else: :error)

  defp project(%Jason.OrderedObject{values: pairs}),
    do: Map.new(pairs, fn {k, v} -> {k, project(v)} end)

  defp project(l) when is_list(l), do: Enum.map(l, &project/1)
  defp project(v), do: v
  defp lex(<<>>, 0, false, false, _), do: :ok
  defp lex(<<>>, _, _, _, _), do: :error
  defp lex(<<_, rest::binary>>, d, true, true, f), do: lex(rest, d, true, false, f)
  defp lex(<<?\\, rest::binary>>, d, true, false, f), do: lex(rest, d, true, true, f)
  defp lex(<<?", rest::binary>>, d, true, false, f), do: lex(rest, d, false, false, f)
  defp lex(<<_, rest::binary>>, d, true, false, f), do: lex(rest, d, true, false, f)
  defp lex(<<?", rest::binary>>, d, false, false, f), do: lex(rest, d, true, false, f)

  defp lex(<<c, rest::binary>>, d, false, false, f) when c in [?{, ?[] and d < 16,
    do: lex(rest, d + 1, false, false, f)

  defp lex(<<c, rest::binary>>, d, false, false, f) when c in [?}, ?]] and d > 0,
    do: lex(rest, d - 1, false, false, f)

  defp lex(<<c, rest::binary>>, d, false, false, f) when c in ?0..?9 or c == ?-,
    do: number(rest, d, if(c == ?-, do: 0, else: 1), 1, false, f)

  defp lex(<<c, rest::binary>>, d, false, false, f) when c in ~c" \t\r\n,:truefalsn",
    do: lex(rest, d, false, false, f)

  defp lex(_, _, _, _, _), do: :error

  # One number: `n` digits in `b` bytes; `x` is set by a fraction or an exponent.
  # Without `x` at most 19 digits; with `x` at most `f` bytes. Jason checks the grammar.
  defp number(<<c, rest::binary>>, d, n, b, x, f) when c in ?0..?9,
    do: number(rest, d, n + 1, b + 1, x, f)

  defp number(<<c, rest::binary>>, d, n, b, _, f) when c in ~c".eE+-",
    do: number(rest, d, n, b + 1, true, f)

  defp number(rest, d, n, b, x, f) when (x and b <= f) or (not x and n in 1..19),
    do: lex(rest, d, false, false, f)

  defp number(_, _, _, _, _, _), do: :error
end
