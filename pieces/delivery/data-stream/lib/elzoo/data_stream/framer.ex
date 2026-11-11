# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DataStream.Framer do
  @moduledoc false
  defstruct raw: <<>>,
            prefix: <<>>,
            beginning: true,
            line: false,
            cr: false,
            boundary: false,
            blocks: 0

  def new, do: %__MODULE__{}

  def feed(f, bytes, state, callback), do: scan(f, bytes, state, callback)

  def eof(%{beginning: true, prefix: p} = f, state, _cb) when p != <<>>,
    do: {:error, :malformed_response, f, state}

  def eof(%{cr: true} = f, state, cb) do
    if f.boundary,
      do: emit(%{f | cr: false}, <<>>, state, cb),
      else: {:error, :malformed_response, f, state}
  end

  def eof(%{raw: <<>>} = f, state, _cb), do: {:ok, f, state}
  def eof(f, state, _cb), do: {:error, :malformed_response, f, state}

  defp scan(f, <<>>, state, _cb), do: {:ok, f, state}

  defp scan(%{beginning: true} = f, <<c, rest::binary>>, state, cb) do
    p = f.prefix <> <<c>>

    cond do
      p == <<239, 187, 191>> -> scan(%{f | beginning: false, prefix: <<>>, raw: p}, rest, state, cb)
      p in [<<239>>, <<239, 187>>] -> scan(%{f | prefix: p}, rest, state, cb)
      true -> scan(%{f | beginning: false, prefix: <<>>}, p <> rest, state, cb)
    end
  end

  defp scan(%{cr: true} = f, bytes, state, cb) do
    {f, rest} =
      case bytes do
        <<?\n, rest::binary>> -> {%{f | raw: f.raw <> "\n", cr: false}, rest}
        _ -> {%{f | cr: false}, bytes}
      end

    cond do
      byte_size(f.raw) > 65_536 -> {:error, :block_limit, f, state}
      f.boundary -> emit(f, rest, state, cb)
      true -> scan(f, rest, state, cb)
    end
  end

  defp scan(f, <<c, rest::binary>>, state, cb) do
    f = %{f | raw: f.raw <> <<c>>}

    cond do
      byte_size(f.raw) > 65_536 -> {:error, :block_limit, f, state}
      c == ?\r -> scan(%{f | cr: true, boundary: not f.line, line: false}, rest, state, cb)
      c == ?\n and not f.line -> emit(f, rest, state, cb)
      c == ?\n -> scan(%{f | line: false}, rest, state, cb)
      true -> scan(%{f | line: true}, rest, state, cb)
    end
  end

  defp emit(%{blocks: n} = f, _rest, state, _cb) when n >= 65_536,
    do: {:error, :event_limit, f, state}

  defp emit(f, rest, state, cb) do
    block = f.raw
    f = %{f | raw: <<>>, boundary: false, line: false, blocks: f.blocks + 1}

    if String.valid?(block) do
      case cb.(block, state) do
        {:ok, next} -> scan(f, rest, next, cb)
        {:halt, next} -> {:halt, f, next}
        {:error, reason, next} -> {:error, reason, f, next}
      end
    else
      {:error, :malformed_response, f, state}
    end
  end
end
