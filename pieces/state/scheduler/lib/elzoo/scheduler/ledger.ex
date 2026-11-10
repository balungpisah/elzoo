# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Scheduler.Ledger do
  @moduledoc """
  Durable projection of one scheduler stream (or the index stream) through the
  ready Store. Reads are paginated over the stream's records above the low
  water; any record that fails validation or decode makes the projection
  `:unreadable` (fail closed — the scheduler never guesses durable state).
  """
  alias Elzoo.DurableLog.Store
  alias Elzoo.Scheduler.Record

  @page 500

  @doc """
  `{:ok, head, projection}` where `projection` holds `definition`,
  `control` (`:active | :paused | :deleted`), `last_recorded`,
  `last_tick_ok_at`, `last_boundary` (the persisted availability boundary of
  the latest tick) and `occurrences` (`encoded_id => %{status, job_id,
  admitted_at}`). `{:error, :not_found | :unreadable | :unavailable}`.
  """
  def load(store, stream, fold, limits) do
    with {:ok, head} <- Store.read(store, :head, [stream]),
         {:ok, rows} <- read_all(store, stream, head) do
      project(head, rows, fold, limits)
    else
      {:error, :malformed} -> {:error, :unreadable}
      {:error, _} = error -> error
    end
  end

  @doc "Project the index stream into `{registered_ids, head}`."
  def load_index(store, stream, fold, limits) do
    with {:ok, head} <- Store.read(store, :head, [stream]),
         {:ok, rows} <- read_all(store, stream, head) do
      reduce_index(head, rows, fold, limits)
    else
      {:error, :malformed} -> {:error, :unreadable}
      {:error, _} = error -> error
    end
  end

  defp read_all(store, stream, head), do: read_all(store, stream, head.low_water + 1, head, [])

  defp read_all(_store, _stream, from, %{revision: revision}, acc) when from > revision,
    do: {:ok, Enum.reverse(acc)}

  defp read_all(store, stream, from, head, acc) do
    case Store.read(store, :read, [stream, from, @page]) do
      {:ok, rows, head2} ->
        case rows do
          [] ->
            read_all(store, stream, head2.revision + 1, head2, acc)

          _ ->
            read_all(store, stream, List.last(rows).sequence + 1, head2, Enum.reverse(rows) ++ acc)
        end

      {:error, {:pruned, low}} ->
        read_all(store, stream, low + 1, head, acc)

      {:error, _} = error ->
        error
    end
  end

  defp project(head, rows, fold, limits) do
    initial = %{
      definition: nil,
      control: :active,
      last_recorded: nil,
      last_tick_ok_at: nil,
      last_boundary: nil,
      occurrences: %{}
    }

    case fold_rows(rows, fold, limits, initial, &project_row/2) do
      {:ok, projection} -> {:ok, head, projection}
      :error -> {:error, :unreadable}
    end
  end

  defp reduce_index(head, rows, fold, limits) do
    case fold_rows(rows, fold, limits, %{}, &index_row/2) do
      {:ok, ids} -> {:ok, head, Enum.sort(Map.keys(ids))}
      :error -> {:error, :unreadable}
    end
  end

  defp fold_rows(rows, fold, limits, initial, fun) do
    Enum.reduce_while(rows, {:ok, initial}, fn row, {:ok, acc} ->
      case Record.decode(row, fold, limits) do
        {:ok, event} ->
          case fun.(event, acc) do
            {:ok, acc2} -> {:cont, {:ok, acc2}}
            :error -> {:halt, :error}
          end

        :unreadable ->
          {:halt, :error}
      end
    end)
  end

  defp index_row({:registered, sid, _at}, ids), do: {:ok, Map.put(ids, sid, true)}
  defp index_row({:retired, sid, _at}, ids), do: {:ok, Map.delete(ids, sid)}
  defp index_row(_, _ids), do: :error

  defp project_row({:defined, defn}, acc), do: {:ok, %{acc | definition: defn}}

  defp project_row({:control, tag, _at}, acc) do
    control = %{paused: :paused, resumed: :active, deleted: :deleted} |> Map.fetch!(tag)
    {:ok, %{acc | control: control}}
  end

  defp project_row({:tick, at, last, boundary, _backlog, _unsettled}, acc),
    do: {:ok, %{acc | last_recorded: last, last_tick_ok_at: at, last_boundary: boundary}}

  defp project_row({:slot, slot, decision, extra}, acc) do
    case decision do
      :admitted ->
        if terminal?(acc, extra.id) do
          {:ok, acc}
        else
          {:ok,
           put_occurrence(acc, extra.id, %{
             status: :admitted,
             origin: extra.origin,
             admitted_at: extra.at || slot,
             dispatch: acc.definition.dispatch
           })}
        end

      :replaced ->
        acc =
          if terminal?(acc, extra.old) do
            acc
          else
            put_occurrence(acc, extra.old, %{status: :replaced, by: extra.new})
          end

        if terminal?(acc, extra.new) do
          {:ok, acc}
        else
          {:ok,
           put_occurrence(acc, extra.new, %{
             status: :admitted,
             origin: extra.origin,
             admitted_at: extra.at || slot,
             dispatch: acc.definition.dispatch
           })}
        end

      _ ->
        {:ok, acc}
    end
  end

  defp project_row({:dispatch, id, phase, job_id}, acc) do
    if terminal?(acc, id) do
      {:ok, acc}
    else
      # `pending`/`error` records carry no job id: never let them erase a
      # job id an earlier `dispatched` record committed.
      fields =
        if is_integer(job_id),
          do: %{status: phase_status(phase), job_id: job_id},
          else: %{status: phase_status(phase)}

      {:ok, put_occurrence(acc, id, fields)}
    end
  end

  defp project_row({:settled, id, kind, via, at}, acc) do
    if terminal?(acc, id) do
      {:ok, acc}
    else
      {:ok, put_occurrence(acc, id, %{status: :settled, kind: kind, via: via, at: at})}
    end
  end

  defp project_row({:expired, id, at}, acc) do
    if terminal?(acc, id) do
      {:ok, acc}
    else
      {:ok, put_occurrence(acc, id, %{status: :expired, at: at})}
    end
  end

  defp project_row({:redefined, id, gen}, acc) do
    if terminal?(acc, id) do
      {:ok, acc}
    else
      {:ok, put_occurrence(acc, id, %{status: :redefined, to_generation: gen})}
    end
  end

  defp project_row(_, _acc), do: :error

  # Terminal occurrence statuses are sticky: the first committed terminal
  # record (`settled`, `expired`, `replaced`, `redefined`) stands, so a stale
  # dispatch, settlement or slot record written after it can never resurrect
  # the occurrence into the unsettled set.
  @terminal_statuses [:settled, :expired, :replaced, :redefined]

  defp terminal?(acc, id) do
    case Map.get(acc.occurrences, id) do
      %{status: status} -> status in @terminal_statuses
      _ -> false
    end
  end

  defp phase_status(:dispatched), do: :dispatched
  defp phase_status(:pending), do: :dispatch_pending
  defp phase_status(:error), do: :dispatch_error

  defp put_occurrence(acc, id, fields) do
    existing = Map.get(acc.occurrences, id, %{})
    admitted_at = Map.get(fields, :admitted_at) || Map.get(existing, :admitted_at)

    %{
      acc
      | occurrences:
          Map.put(
            acc.occurrences,
            id,
            Map.merge(existing, fields) |> Map.put(:admitted_at, admitted_at)
          )
    }
  end
end
