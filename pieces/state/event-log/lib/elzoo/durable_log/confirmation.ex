# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableLog.Confirmation do
  @moduledoc false
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Store}

  def confirm(store, stream, expected, nonce, records) do
    if records == [] do
      {:unknown, :malformed}
    else
      replies = Enum.map(1..length(records), &Store.read(store, :read_at, [stream, expected + &1]))
      fold = record_fold(store, records)

      rows =
        Enum.map(replies, fn
          {:ok, :absent, _} ->
            :absent

          {:ok, row, head} ->
            if is_integer(Map.get(row, :sequence)) and row.sequence <= head.revision and
                 row.sequence > head.low_water, do: row, else: :invalid

          _ ->
            :invalid
        end)

      cond do
        Enum.any?(replies, &match?({:error, :caller_transaction}, &1)) ->
          {:unknown, :caller_transaction}

        Enum.any?(replies, &match?({:error, :unavailable}, &1)) ->
          {:unknown, :unavailable}

        Enum.any?(rows, &(&1 == :absent)) ->
          {:unknown, :unfenced}

        not Enum.all?(Enum.with_index(rows, expected + 1), fn {r, seq} ->
          is_map(r) and Map.get(r, :stream) == stream and Map.get(r, :sequence) == seq and
              Log.validate_row(r, fold) == :ok
        end) ->
          {:unknown, :malformed}

        Enum.zip(rows, records)
        |> Enum.all?(fn {actual, wanted} ->
          actual.nonce == nonce and Log.validate_row(wanted, fold) == :ok and
            actual.digest == wanted.digest and
              Log.canonical_bytes(actual) == Log.canonical_bytes(wanted)
        end) ->
          {:committed, expected + length(records)}

        hd(rows).nonce != nonce and Enum.all?(rows, &(&1.nonce == hd(rows).nonce)) ->
          :superseded

        true ->
          {:unknown, :mismatch}
      end
    end
  end

  def confirm_checkpoint(store, request) do
    case Store.read(store, :read_checkpoint, [
           request.stream,
           request.sequence,
           request.fold_version
         ]) do
      {:ok, :absent} ->
        {:unknown, :unfenced}

      {:ok, row} ->
        cond do
          not Codec.checkpoint_valid?(row) or row.stream != request.stream or
            row.sequence != request.sequence or row.fold_version != request.fold_version ->
            {:unknown, :malformed}

          row.nonce != request.nonce ->
            :superseded

          Codec.checkpoint_valid?(request) and
              Codec.checkpoint_bytes(row) == Codec.checkpoint_bytes(request) ->
            {:committed, request.sequence}

          true ->
            {:unknown, :mismatch}
        end

      {:error, reason} ->
        {:unknown, reason}
    end
  end

  def confirm_retention(store, request) do
    with {:ok, receipt} <- Store.read(store, :read_maintenance, [request.stream, :retain]),
         {:ok, head} <- Store.read(store, :head, [request.stream]) do
      if Codec.receipt_valid?(receipt) and receipt == request and head.low_water == request.target,
        do: {:committed, request.target},
        else: {:unknown, :unfenced}
    else
      {:error, reason} -> {:unknown, reason}
    end
  end

  def confirm_repair(store, request) do
    case Store.read(store, :read_maintenance, [request.stream, :repair_torn_tail]) do
      {:ok, receipt} ->
        if Codec.receipt_valid?(receipt) and receipt == request,
          do: {:committed, request.target},
          else: {:unknown, :unfenced}

      {:error, reason} ->
        {:unknown, reason}
    end
  end

  def confirm_ack(store, request) do
    case Store.read(store, :read_ack, [request.extra]) do
      {:ok, :absent} ->
        {:unknown, :unfenced}

      {:ok, row} ->
        cond do
          not Codec.item_valid?(row) or row.idempotency_key != request.extra ->
            {:unknown, :malformed}

          row.state == :pending ->
            {:unknown, :unfenced}

          row.ack_nonce != request.nonce ->
            :superseded

          Codec.receipt_valid?(request) and row.ack_digest == request.digest ->
            {:committed, row.sequence}

          true ->
            {:unknown, :mismatch}
        end

      {:error, reason} ->
        {:unknown, reason}
    end
  end

  defp record_fold({_, opts}, records) do
    fallback = %{
      kinds: Map.new(records, &{&1.kind, :state_bearing}),
      versions: Enum.map(records, & &1.schema_version)
    }

    if is_map(opts), do: Map.get(opts, :fold, fallback), else: fallback
  end
end
