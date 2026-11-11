# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DataStream.JSON do
  @moduledoc false
  # Lex before decoding: strings/escapes are opaque; numbers have only integer
  # grammar and bounded lexemes. Jason retains objects as ordered pairs until
  # every decoded key at every depth has been checked for duplication.
  def decode(bytes) when is_binary(bytes) do
    with true <- String.valid?(bytes),
         :ok <- lex(bytes, 0, false, false),
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

  def decode(_), do: {:error, :invalid_json}

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
  defp lex(<<>>, 0, false, false), do: :ok
  defp lex(<<>>, _, _, _), do: :error
  defp lex(<<_, rest::binary>>, d, true, true), do: lex(rest, d, true, false)
  defp lex(<<?\\, rest::binary>>, d, true, false), do: lex(rest, d, true, true)
  defp lex(<<?", rest::binary>>, d, true, false), do: lex(rest, d, false, false)
  defp lex(<<_, rest::binary>>, d, true, false), do: lex(rest, d, true, false)
  defp lex(<<?", rest::binary>>, d, false, false), do: lex(rest, d, true, false)

  defp lex(<<c, rest::binary>>, d, false, false) when c in [?{, ?[] and d < 16,
    do: lex(rest, d + 1, false, false)

  defp lex(<<c, rest::binary>>, d, false, false) when c in [?}, ?]] and d > 0,
    do: lex(rest, d - 1, false, false)

  defp lex(<<c, rest::binary>>, d, false, false) when c in ?0..?9 or c == ?-,
    do: number(rest, d, if(c == ?-, do: 0, else: 1))

  defp lex(<<c, rest::binary>>, d, false, false) when c in ~c" \t\r\n,:truefalsn",
    do: lex(rest, d, false, false)

  defp lex(_, _, _, _), do: :error
  defp number(<<c, rest::binary>>, d, n) when c in ?0..?9 and n < 19, do: number(rest, d, n + 1)
  defp number(<<c, _::binary>>, _, _) when c in ?0..?9 or c in ~c".eE+", do: :error
  defp number(rest, d, n) when n > 0, do: lex(rest, d, false, false)
  defp number(_, _, _), do: :error
end
