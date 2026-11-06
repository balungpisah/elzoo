# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableLog.Store do
  @moduledoc "Provider callbacks and the exception-safe dispatch boundary."
  alias Elzoo.DurableLog.Codec
  @type store :: {module(), term()}
  @type write_result ::
          {:committed, non_neg_integer()}
          | {:conflict, map()}
          | {:rejected, atom()}
          | {:indeterminate, map()}
  @callback capabilities(store()) :: %{append_visibility: :atomic | :staged_uncommitted_tail}
  @callback head(store(), binary()) :: {:ok, map()} | {:error, :unavailable | :malformed}
  @callback append(store(), binary(), non_neg_integer(), [map()], [map()]) :: write_result()
  @callback read(store(), binary(), pos_integer(), pos_integer()) ::
              {:ok, [map()], map()} | {:error, term()}
  @callback read_at(store(), binary(), pos_integer()) ::
              {:ok, map() | :absent, map()} | {:error, term()}
  @callback put_checkpoint(store(), map()) :: write_result()
  @callback latest_checkpoint(store(), binary(), pos_integer()) ::
              {:ok, map() | :none} | {:error, term()}
  @callback retain(store(), binary(), non_neg_integer(), non_neg_integer(), binary()) ::
              write_result()
  @callback pending(store(), binary(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  @callback ack(store(), binary(), binary()) :: write_result()
  @callback read_ack(store(), binary()) :: {:ok, map() | :absent} | {:error, term()}
  @callback read_checkpoint(store(), binary(), non_neg_integer(), pos_integer()) ::
              {:ok, map() | :absent} | {:error, term()}
  @callback read_maintenance(store(), binary(), atom()) :: {:ok, map() | :absent} | {:error, term()}
  @callback repair_torn_tail(store(), binary(), non_neg_integer(), binary(), binary()) ::
              write_result()
  @rejections ~w(empty_batch batch_too_large record_too_large invalid_stream invalid_revision unknown_kind unsupported_version invalid_outbox_item checkpoint_too_large checkpoint_beyond_tail invalid_retention_range retention_beyond_checkpoint retention_beyond_pending_outbox torn_repair_unsupported unfenced_tail)a

  def read(store, operation, args) do
    case invoke(store, operation, args) do
      {:reply, reply} -> if read_reply?(operation, reply), do: reply, else: {:error, :malformed}
      {:failure, _} -> {:error, :unavailable}
    end
  end

  def write(store, operation, args, request) do
    classify_write(invoke(store, operation, args), request)
  end

  def classify_write(result, request) do
    case result do
      {:reply, {:committed, revision}} when is_integer(revision) and revision >= 0 ->
        if revision == request.target,
          do: {:committed, revision},
          else: unknown(request, :malformed_reply)

      {:reply, {:conflict, %{expected: expected, observed: observed} = conflict}} ->
        if expected == request.expected and (observed == :unknown or Codec.uint?(observed)),
          do: {:conflict, conflict},
          else: unknown(request, :malformed_reply)

      {:reply, {:rejected, reason}} when reason in @rejections ->
        {:rejected, reason}

      {:reply, {:indeterminate, %{cause: cause}}}
      when cause in [:exception, :exit, :timeout, :malformed_reply, :unavailable] ->
        unknown(request, cause)

      {:reply, {:error, :unavailable}} ->
        unknown(request, :unavailable)

      {:reply, _} ->
        unknown(request, :malformed_reply)

      {:failure, cause} ->
        unknown(request, cause)
    end
  end

  def unknown(request, cause),
    do:
      {:indeterminate,
       Map.put(
         Map.take(
           request,
           [:operation, :stream, :expected, :target, :nonce, :digest]
         ),
         :cause,
         cause
       )}

  defp invoke({module, _} = store, operation, args) do
    try do
      {:reply, apply(module, operation, [store | args])}
    rescue
      _ -> {:failure, :exception}
    catch
      :exit, {:timeout, _} -> {:failure, :timeout}
      :exit, _ -> {:failure, :exit}
      _, _ -> {:failure, :exception}
    end
  end

  defp read_reply?(:capabilities, %{append_visibility: v}),
    do: v in [:atomic, :staged_uncommitted_tail]

  defp read_reply?(:head, {:ok, h}), do: head?(h)
  defp read_reply?(:read, {:ok, rows, h}), do: proper_list?(rows) and head?(h)
  defp read_reply?(:read_at, {:ok, row, h}), do: (row == :absent or is_map(row)) and head?(h)
  defp read_reply?(:pending, {:ok, rows}), do: proper_list?(rows)

  defp read_reply?(op, {:ok, row})
       when op in [:read_ack, :read_checkpoint, :read_maintenance, :latest_checkpoint],
       do: is_map(row) or row in [:none, :absent]

  defp read_reply?(_, {:error, {:pruned, low}}), do: Codec.uint?(low)
  defp read_reply?(_, {:error, reason}), do: reason in [:unavailable, :malformed]
  defp read_reply?(_, _), do: false
  defp head?(%{revision: r, low_water: l}), do: Codec.uint?(r) and Codec.uint?(l) and l <= r
  defp head?(_), do: false
  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false
end
