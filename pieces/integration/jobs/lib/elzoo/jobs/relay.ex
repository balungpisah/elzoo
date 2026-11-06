# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Jobs.Relay do
  @moduledoc """
  Polls one ELZ-009 outbox stream with the unchanged single-stream
  `Elzoo.Outbox.pending/3` and hands each pending item to `handle`.
  `handle` returns `:done` (the item is acked) or `{:skip, reason}` (left
  pending). A skipped item does not stop the pass: later items of the same page
  are still handled. Because `pending/3` returns the oldest `limit` items and
  has no offset, a full page of permanently skipped items blocks later items
  (stated limit). Delivery to `handle` is at-least-once.

  Config (construction time, fixed): `store`, `stream`, `handle`, `limit`,
  `interval_ms` (`:manual` disables the timer). Control: OTP start/stop only.
  """
  use GenServer
  alias Elzoo.Outbox

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Run one pass now; returns `{:ok, %{acked: keys, skipped: [{key, reason}]}}` or `{:error, reason}`."
  def run_once(relay, timeout \\ 15_000), do: GenServer.call(relay, :run_once, timeout)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      store: Keyword.fetch!(opts, :store),
      stream: Keyword.fetch!(opts, :stream),
      handle: Keyword.fetch!(opts, :handle),
      limit: Keyword.get(opts, :limit, 100),
      interval: Keyword.get(opts, :interval_ms, 1_000)
    }

    if is_function(state.handle, 1) and is_integer(state.limit) and state.limit > 0 and
         (state.interval == :manual or (is_integer(state.interval) and state.interval > 0)) do
      {:ok, schedule(state)}
    else
      {:stop, :invalid_options}
    end
  end

  @impl true
  def handle_call(:run_once, _, state), do: {:reply, pass(state), state}

  @impl true
  def handle_info(:tick, state) do
    _ = pass(state)
    {:noreply, schedule(state)}
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  defp schedule(%{interval: :manual} = state), do: state

  defp schedule(state) do
    Process.send_after(self(), :tick, state.interval)
    state
  end

  defp pass(state) do
    case Outbox.pending(state.store, state.stream, state.limit) do
      {:ok, items} ->
        {:ok,
         Enum.reduce(items, %{acked: [], skipped: []}, fn item, acc ->
           case safe(state.handle, item) do
             :done -> ack(state, item, acc)
             {:skip, reason} -> %{acc | skipped: acc.skipped ++ [{item.idempotency_key, reason}]}
           end
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ack(state, item, acc) do
    case Outbox.ack(state.store, item.idempotency_key, :crypto.strong_rand_bytes(16)) do
      {:committed, _} -> %{acc | acked: acc.acked ++ [item.idempotency_key]}
      other -> %{acc | skipped: acc.skipped ++ [{item.idempotency_key, {:ack, other}}]}
    end
  end

  defp safe(handle, item) do
    case handle.(item) do
      :done -> :done
      {:skip, reason} -> {:skip, reason}
      other -> {:skip, {:invalid_handle_result, other}}
    end
  rescue
    exception -> {:skip, {:exception, exception.__struct__}}
  catch
    kind, _ -> {:skip, {:caught, kind}}
  end
end
