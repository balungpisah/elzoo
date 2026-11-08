# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Lease.Memory do
  @moduledoc """
  Memory Adapter of `state/lease` over the volatile `Elzoo.DurableLog.Memory`
  double: one **owner** process per Memory Store performs every Store call on
  leased streams as one serialized section (lease steps, the holder's
  terminal write, retention through `retain/5`), sampling the manual clock
  inside the section. Atomicity on the double is process serialization, the
  Memory Store's own atomicity model.

  Reviewed boundary: a second owner for the same Memory Store is rejected
  (`{:error, {:invalid, :duplicate_owner}}`, OTP `:global` registration); a
  Store call on a leased stream that bypasses the owner is outside the
  supported Contract (the double is a test instrument). The Memory Store has
  no multi-key transaction: a sweep is one section whose per-key appends
  commit individually, so a later failure cannot roll back earlier claims
  (`{:partial, …}`), a finite approximation of the provider's one-transaction
  law. `retention_observed: true` on a result is after-the-fact detection of
  a `low_water` move across the step, not prevention.
  """
  use GenServer
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Memory, Store}
  alias Elzoo.Lease.{Clock, Record}

  defstruct [:owner, :timeout]

  @page 1_000

  def new({Memory, opts} = store, clock, lease_opts) when is_pid(clock) do
    timeout = Keyword.get(lease_opts, :timeout_ms, 30_000)

    state = %{
      store: store,
      memory: Map.fetch!(Map.new(opts), :pid),
      clock: clock,
      hook: Keyword.get(lease_opts, :test_hook),
      timeout: timeout
    }

    case GenServer.start_link(__MODULE__, state) do
      {:ok, pid} -> {:ok, %__MODULE__{owner: pid, timeout: timeout}}
      {:error, :duplicate_owner} -> {:error, {:invalid, :duplicate_owner}}
      {:error, reason} -> {:error, {:invalid, {:owner, reason}}}
    end
  end

  def owner(%__MODULE__{owner: pid}), do: pid

  def single(backend, key, fun), do: call(backend, {:single, key, fun})
  def sweep(backend, keys, limit, fun, free_fun), do: call(backend, {:sweep, keys, limit, fun, free_fun})
  def read(backend, key), do: call(backend, {:read, key})

  @doc "Retention on a leased stream, serialized through the owner (the ready Store's `retain/5`)."
  def retain(backend, stream, expected, through, nonce),
    do: call(backend, {:retain, stream, expected, through, nonce})

  defp call(backend, message) do
    GenServer.call(backend.owner, message, backend.timeout + 5_000)
  catch
    :exit, {:timeout, _} -> {:error, :contended}
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(state) do
    case :global.register_name({__MODULE__, state.memory}, self()) do
      :yes -> {:ok, state}
      :no -> {:stop, :duplicate_owner}
    end
  end

  @impl true
  def handle_call({:single, key, fun}, _from, state) do
    reply =
      guarded(fn ->
        hook(state, :before_lock, key)

        with {:ok, head} <- head(state, key),
             {:ok, now} <- Clock.sample(state.clock) do
          hook(state, :after_clock, key)
          ctx = %{key: key, revision: head.revision, low_water: head.low_water, latest: latest(state, key, head), now: now}

          case fun.(ctx) do
            {:refuse, result} -> result
            {:write, rows, request, result} -> append(state, key, head, rows, request, result)
          end
        end
      end)

    {:reply, reply, state}
  end

  def handle_call({:sweep, keys, limit, fun, free_fun}, _from, state) do
    acc0 = %{held: [], refused: %{}, skipped_locked: [], skipped: []}

    reply =
      guarded(fn ->
        Enum.reduce_while(Enum.sort(keys), {:claimed, acc0}, fn key, {:claimed, acc} ->
          cond do
            length(acc.held) >= limit ->
              {:cont, {:claimed, %{acc | skipped: acc.skipped ++ [key]}}}

            true ->
              case head(state, key) do
                {:ok, %{revision: 0}} ->
                  {:cont, {:claimed, %{acc | refused: Map.put(acc.refused, key, free_fun.(key))}}}

                {:ok, head} ->
                  case Clock.sample(state.clock) do
                    {:ok, now} ->
                      hook(state, :after_clock, key)
                      ctx = %{key: key, revision: head.revision, low_water: head.low_water, latest: latest(state, key, head), now: now}

                      case fun.(ctx) do
                        {:refuse, refusal} ->
                          {:cont, {:claimed, %{acc | refused: Map.put(acc.refused, key, refusal)}}}

                        {:write, rows, request, held} ->
                          case append(state, key, head, rows, request, held) do
                            {:held, h} ->
                              {:cont, {:claimed, %{acc | held: acc.held ++ [h]}}}

                            failure ->
                              rest = Enum.drop_while(Enum.sort(keys), &(&1 != key)) |> tl()
                              {:halt, {:partial, %{committed: acc.held, refused: acc.refused, failed: {key, failure}, not_evaluated: rest}}}
                          end
                      end

                    {:error, reason} ->
                      rest = Enum.drop_while(Enum.sort(keys), &(&1 != key))
                      {:halt, {:partial, %{committed: acc.held, refused: acc.refused, failed: {key, {:error, reason}}, not_evaluated: rest}}}
                  end

                {:error, reason} ->
                  rest = Enum.drop_while(Enum.sort(keys), &(&1 != key))
                  {:halt, {:partial, %{committed: acc.held, refused: acc.refused, failed: {key, {:error, reason}}, not_evaluated: rest}}}
              end
          end
        end)
      end)

    {:reply, reply, state}
  end

  def handle_call({:read, key}, _from, state) do
    reply =
      guarded(fn ->
        with {:ok, head} <- head(state, key), {:ok, now} <- Clock.sample(state.clock) do
          {:ok, %{key: key, revision: head.revision, low_water: head.low_water, latest: latest(state, key, head), now: now}}
        end
      end)

    {:reply, reply, state}
  end

  def handle_call({:retain, stream, expected, through, nonce}, _from, state) do
    {:reply, guarded(fn -> Memory.retain(state.store, stream, expected, through, nonce) end), state}
  end

  # ── section internals ────────────────────────────────────────────────

  defp append(state, key, head, rows, request, result) do
    hook(state, :before_write, key)

    case Store.write(state.store, :append, [key, head.revision, rows, []], request) do
      {:committed, _} ->
        observed =
          case head(state, key) do
            {:ok, %{low_water: low}} -> low != head.low_water
            _ -> true
          end

        flag(result, observed)

      {:conflict, %{observed: observed}} ->
        {:lease_refused, %{reason: :lost_race, holder: nil, status: nil, revision: observed}}

      {:rejected, reason} ->
        {:error, {:rejected, reason}}

      {:indeterminate, info} ->
        {:indeterminate, Map.put(info, :records, rows)}
    end
  end

  defp flag({tag, map}, true) when is_map(map), do: {tag, Map.put(map, :retention_observed, true)}
  defp flag(other, _), do: other

  defp head(state, key) do
    case Store.read(state.store, :head, [key]) do
      {:ok, head} -> {:ok, head}
      {:error, reason} -> {:error, if(reason == :malformed, do: :malformed, else: :unavailable)}
    end
  end

  defp latest(state, key, head), do: latest(state, key, head, head.low_water + 1, nil)

  defp latest(state, key, head, from, best) do
    case Log.read(state.store, key, from, @page) do
      {:ok, rows, _} ->
        candidate =
          rows
          |> Enum.filter(fn row ->
            is_map(row) and is_integer(Map.get(row, :sequence)) and row.sequence <= head.revision and
              Record.lease_kind?(Map.get(row, :kind))
          end)
          |> Enum.max_by(& &1.sequence, fn -> nil end)

        best = if candidate && (best == nil or candidate.sequence > best.sequence), do: candidate, else: best
        last = Enum.reduce(rows, from - 1, fn r, acc -> if is_map(r) and is_integer(Map.get(r, :sequence)), do: max(acc, r.sequence), else: acc end)

        if length(rows) == @page and last >= from and last < head.revision,
          do: latest(state, key, head, last + 1, best),
          else: best

      _ ->
        throw(:unavailable)
    end
  end

  defp guarded(fun) do
    fun.()
  rescue
    _ -> {:error, :unavailable}
  catch
    :throw, :unavailable -> {:error, :unavailable}
    :throw, :malformed -> {:error, :malformed}
    _, _ -> {:error, :unavailable}
  end

  defp hook(%{hook: nil}, _, _), do: :ok
  defp hook(state, phase, key), do: state.hook.(phase, %{key: key, owner: self()})
end
