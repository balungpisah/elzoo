# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableLog do
  @moduledoc "Canonical records and a read-only deterministic replay boundary."
  @replay :"Cure.Elzoo.Replay"
  @max_sequence 9_223_372_036_854_775_807
  @max_version 2_147_483_647
  alias Elzoo.DurableLog.Codec

  defdelegate confirm(store, stream, expected, nonce, records), to: Elzoo.DurableLog.Confirmation
  defdelegate confirm_checkpoint(store, request), to: Elzoo.DurableLog.Confirmation
  defdelegate confirm_retention(store, request), to: Elzoo.DurableLog.Confirmation
  defdelegate confirm_ack(store, request), to: Elzoo.DurableLog.Confirmation
  defdelegate confirm_repair(store, request), to: Elzoo.DurableLog.Confirmation

  def read(store, stream, from, limit) do
    alias Elzoo.DurableLog.Store

    with %{append_visibility: capability} <- Store.read(store, :capabilities, []),
         {:ok, rows, head} <- Store.read(store, :read, [stream, from, limit]) do
      {:ok, rows, Map.put(head, :capabilities, %{append_visibility: capability})}
    end
  end

  defmodule Record do
    @moduledoc "An immutable record with a format-version-1 SHA-256 digest."
    defstruct [:stream, :sequence, :kind, :schema_version, :payload, :nonce, :digest]
  end

  def canonical_bytes(row) do
    <<1::8, byte_size(row.stream)::32, row.stream::binary, row.sequence::64,
      byte_size(row.kind)::32, row.kind::binary, row.schema_version::32, byte_size(row.nonce)::32,
      row.nonce::binary, byte_size(row.payload)::32, row.payload::binary>>
  end

  def digest(row), do: :crypto.hash(:sha256, canonical_bytes(row))

  def validate_row(row, fold, limits \\ %{}) do
    with :ok <- validate_fields(row, fold, limits) do
      if is_binary(Map.get(row, :digest)) and byte_size(row.digest) == 32 and
           row.digest == digest(row),
         do: :ok,
         else: {:error, :digest_mismatch}
    end
  end

  defp validate_fields(row, fold, limits) when is_map(row) do
    cond do
      not valid_stream?(Map.get(row, :stream)) ->
        {:error, :invalid_stream}

      not uint?(Map.get(row, :sequence), 1, @max_sequence) ->
        {:error, :invalid_revision}

      not Codec.text?(Map.get(row, :kind)) ->
        {:error, :unknown_kind}

      Map.get(fold.kinds, row.kind) not in [:state_bearing, :non_state_bearing] ->
        {:error, :unknown_kind}

      not uint?(Map.get(row, :schema_version), 1, @max_version) or
          row.schema_version not in fold.versions ->
        {:error, :unsupported_version}

      not is_binary(Map.get(row, :payload)) ->
        {:error, :malformed_row}

      byte_size(row.payload) > Map.get(limits, :max_record_bytes, 4_294_967_295) ->
        {:error, :record_too_large}

      not is_binary(Map.get(row, :nonce)) or byte_size(row.nonce) != 16 ->
        {:error, :malformed_row}

      true ->
        :ok
    end
  end

  defp validate_fields(_, _, _), do: {:error, :malformed_row}

  @doc "Static append validation; request has stream, expected, records and outbox fields."
  def preflight(request, fold, limits) when is_map(request) do
    cond do
      not valid_stream?(Map.get(request, :stream)) ->
        {:rejected, :invalid_stream}

      not uint?(Map.get(request, :expected), 0, @max_sequence) ->
        {:rejected, :invalid_revision}

      not proper_list?(Map.get(request, :records)) ->
        {:rejected, :empty_batch}

      request.records == [] ->
        {:rejected, :empty_batch}

      length(request.records) > limits.max_batch_size ->
        {:rejected, :batch_too_large}

      request.expected + length(request.records) > @max_sequence ->
        {:rejected, :invalid_revision}

      true ->
        preflight_records(request, fold, limits)
    end
  end

  def preflight(_, _, _), do: {:rejected, :invalid_stream}

  defp preflight_records(request, fold, limits) do
    error =
      request.records
      |> Enum.with_index(1)
      |> Enum.find_value(fn
        {{kind, version, payload}, offset} ->
          row = %Record{
            stream: request.stream,
            sequence: request.expected + offset,
            kind: kind,
            schema_version: version,
            payload: payload,
            nonce: <<0::128>>
          }

          case validate_fields(row, fold, limits) do
            :ok -> nil
            {:error, :malformed_row} -> :record_too_large
            {:error, reason} -> reason
          end

        _ ->
          :unknown_kind
      end)

    cond do
      error != nil ->
        {:rejected, error}

      not proper_list?(Map.get(request, :outbox)) or
          not Enum.all?(request.outbox, fn
            {destination, payload} ->
              Codec.destination?(destination) and destination in Map.get(fold, :destinations, []) and
                is_binary(payload) and byte_size(payload) <= limits.max_record_bytes

            _ ->
              false
          end) ->
        {:rejected, :invalid_outbox_item}

      true ->
        :ok
    end
  end

  @doc "Replay rows against a head revision (or a head map), optionally from fold.resume."
  def replay(rows, head, fold) do
    state = Map.get(fold, :resume, %{model: fold.initial, cursor: {0, false, []}, seen: %{}})
    state = Map.put(state, :tail, :intact)
    revision = if is_map(head), do: head.revision, else: head

    terminal =
      Enum.any?(elem(state.cursor, 2), fn
        {:corrupt, _, _} -> true
        {:truncated, _, _} -> true
        _ -> false
      end)

    {result, stopped} =
      if(terminal, do: [], else: rows)
      |> Enum.with_index()
      |> Enum.sort_by(fn {row, index} -> {sequence(row), index} end)
      |> Enum.with_index()
      |> Enum.reduce_while({state, terminal}, fn {{row, _}, index}, {state, _} ->
        cond do
          torn?(row, head, index == length(rows) - 1) ->
            {:halt, {%{state | tail: :torn}, false}}

          true ->
            case replay_row(row, state, fold) do
              {:ok, next} -> {:cont, {next, false}}
              {:error, next} -> {:halt, {next, true}}
            end
        end
      end)

    {applied, _, _} = result.cursor

    if not stopped and revision > applied do
      damage(result, {:truncated, revision, applied})
    else
      result
    end
  end

  defp replay_row(row, state, fold) do
    seq = sequence(row)

    with :ok <- validate_row(row, fold, Map.get(fold, :limits, %{})),
         :ok <- identity(state, seq, row.digest) do
      role = Map.fetch!(fold.kinds, row.kind)
      {cursor, admitted} = project(state.cursor, seq, role)

      try do
        model =
          if admitted,
            do: fold.reduce.(state.model, row.kind, row.schema_version, row.payload),
            else: state.model

        {applied, _, _} = state.cursor
        seen = if seq > applied, do: Map.put(state.seen, seq, row.digest), else: state.seen
        {:ok, %{state | model: model, cursor: cursor, seen: seen}}
      catch
        _, _ -> {:error, damage(state, {:corrupt, seq, :reducer_failure})}
      end
    else
      {:error, reason} -> {:error, damage(state, {:corrupt, seq, reason})}
    end
  end

  defp identity(state, seq, digest) do
    case Map.fetch(state.seen, seq) do
      {:ok, other} when other != digest -> {:error, :sequence_identity_mismatch}
      :error when seq == elem(state.cursor, 0) -> {:error, :sequence_identity_mismatch}
      _ -> :ok
    end
  end

  defp project({applied, damaged, diagnostics}, sequence, role) do
    cursor = {:ReplayCursor, applied, damaged, []}

    order =
      if sequence < applied,
        do: :ReplayOutOfOrder,
        else: apply(@replay, :classify, [cursor, sequence])

    {:ReplayCursor, next, damaged, added} = apply(@replay, :track, [cursor, sequence, order])

    added =
      Enum.map(added, fn {:ReplayDiagnostic, seq, tag} ->
        {seq, Map.fetch!(%{ReplayGap: :gap, ReplayOutOfOrder: :out_of_order}, tag)}
      end)

    role = Map.fetch!(%{state_bearing: :StateBearing, non_state_bearing: :NonStateBearing}, role)
    {{next, damaged, added ++ diagnostics}, apply(@replay, :admits, [order, role])}
  end

  defp torn?(
         row,
         %{
           revision: revision,
           capabilities: %{append_visibility: :staged_uncommitted_tail},
           staged_tail: %{sequence: seq, nonce: nonce, uncommitted: true}
         },
         true
       ) do
    is_map(row) and seq == revision + 1 and sequence(row) == seq and
      is_binary(nonce) and byte_size(nonce) == 16 and Map.get(row, :nonce) == nonce
  end

  defp torn?(_, _, _), do: false

  defp damage(state, diagnostic) do
    {applied, _, diagnostics} = state.cursor
    %{state | cursor: {applied, true, [diagnostic | diagnostics]}}
  end

  defp sequence(row) when is_map(row) do
    case Map.get(row, :sequence) do
      seq when is_integer(seq) and seq >= 1 -> seq
      _ -> 0
    end
  end

  defp sequence(_), do: 0
  defp uint?(n, low, high), do: is_integer(n) and n >= low and n <= high
  defp valid_stream?(s), do: Codec.stream?(s)
  defp proper_list?([]), do: true
  defp proper_list?([_ | rest]), do: proper_list?(rest)
  defp proper_list?(_), do: false
end
