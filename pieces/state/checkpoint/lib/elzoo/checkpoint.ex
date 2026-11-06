# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Checkpoint do
  @moduledoc "Immutable, bounded snapshots of a complete replay prefix."
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Store}
  defstruct [:stream, :sequence, :fold_version, :model, :cursor, :seen, :nonce, :digest]

  def take(writer, stream, version, encode) when is_pid(writer),
    do: GenServer.call(writer, {:checkpoint, stream, version, encode})

  def take({store, state, limits}, stream, version, encode) do
    try do
      checkpoint = %__MODULE__{
        stream: stream,
        sequence: elem(state.cursor, 0),
        fold_version: version,
        model: encode.(state.model),
        cursor: state.cursor,
        seen: state.seen,
        nonce: :crypto.strong_rand_bytes(16)
      }

      checkpoint = %{checkpoint | digest: Codec.hash(Codec.checkpoint_bytes(checkpoint))}

      cond do
        not Codec.checkpoint_valid?(checkpoint) ->
          {:error, :malformed}

        byte_size(Codec.checkpoint_bytes(checkpoint)) + 32 > limits.max_checkpoint_bytes ->
          {:rejected, :checkpoint_too_large}

        true ->
          request = %{
            operation: :put_checkpoint,
            stream: stream,
            expected: checkpoint.sequence,
            target: checkpoint.sequence,
            nonce: checkpoint.nonce,
            digest: checkpoint.digest
          }

          Store.write(store, :put_checkpoint, [checkpoint], request)
      end
    catch
      _, _ -> {:error, :encode_failure}
    end
  end

  def canonical_bytes(c), do: Codec.checkpoint_bytes(c)
  def valid?(c), do: Codec.checkpoint_valid?(c)

  def recover(store, stream, fold, version, decode) do
    with {:ok, head} <- Store.read(store, :head, [stream]),
         {:ok, latest} <- Store.read(store, :latest_checkpoint, [stream, version]),
         latest = bounded_latest(latest, head),
         {:ok, seed} <- select_checkpoint(store, stream, version, latest, decode) do
      spec = if(seed == nil, do: Map.delete(fold, :resume), else: Map.put(fold, :resume, seed))
      from = if(seed == nil, do: 1, else: elem(seed.cursor, 0) + 1)

      terminal =
        seed != nil and
          Enum.any?(elem(seed.cursor, 2), fn
            {:corrupt, _, _} -> true
            {:truncated, _, _} -> true
            _ -> false
          end)

      if terminal do
        Map.put(seed, :tail, :intact)
      else
        with {:ok, rows, head} <- read_tail(store, stream, from, []) do
          Log.replay(rows, head, spec)
        end
      end
    end
  end

  defp bounded_latest(latest, head) when is_map(latest) do
    if Codec.uint?(Map.get(latest, :sequence)) and latest.sequence > head.revision,
      do: :none,
      else: latest
  end

  defp bounded_latest(latest, _), do: latest

  defp select_checkpoint(_, _, _, :none, _), do: {:ok, nil}
  defp select_checkpoint(_, _, _, :absent, _), do: {:ok, nil}

  defp select_checkpoint(store, stream, version, c, decode) do
    seed = decode_checkpoint(c, stream, version, decode)

    cond do
      seed != nil -> {:ok, seed}
      not is_map(c) or not Codec.uint?(Map.get(c, :sequence)) -> {:ok, nil}
      c.sequence == 0 -> {:ok, nil}
      true -> find_earlier(store, stream, version, c.sequence - 1, decode)
    end
  end

  defp find_earlier(store, stream, version, sequence, decode) do
    case Store.read(store, :read_checkpoint, [stream, sequence, version]) do
      {:ok, c} ->
        case decode_checkpoint(c, stream, version, decode) do
          nil ->
            if sequence == 0,
              do: {:ok, nil},
              else: find_earlier(store, stream, version, sequence - 1, decode)

          seed ->
            {:ok, seed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_checkpoint(c, stream, version, decode) do
    try do
      if Codec.checkpoint_valid?(c) and c.stream == stream and c.fold_version == version do
        case decode.(c.model) do
          {:ok, model} -> %{model: model, cursor: c.cursor, seen: c.seen}
          _ -> nil
        end
      end
    catch
      _, _ -> nil
    end
  end

  defp read_tail(store, stream, from, acc) do
    case Log.read(store, stream, from, 1_000) do
      {:ok, rows, head} ->
        last =
          Enum.reduce(rows, from - 1, fn row, n ->
            if is_map(row) and is_integer(Map.get(row, :sequence)),
              do: max(n, row.sequence),
              else: n
          end)

        if length(rows) == 1_000 and last >= from and last < head.revision,
          do: read_tail(store, stream, last + 1, acc ++ rows),
          else: {:ok, acc ++ rows, head}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
