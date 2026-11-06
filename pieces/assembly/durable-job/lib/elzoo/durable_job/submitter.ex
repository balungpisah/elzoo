# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableJob.Submitter do
  @moduledoc """
  ELZ-010-owned process serializing submits for one queue onto the submission
  stream `jobs/<queue>`. Its ELZ-009 Writer fold holds every submitted job_key
  and request digest (memory grows with distinct keys; stated limit), so
  duplicate and conflicting submits are answered before appending. A second
  Submitter for the same queue is fenced by the stream CAS. Traps exits so a
  Writer that stops on an indeterminate write is replaced lazily.
  """
  use GenServer
  alias Elzoo.DurableJob.Run
  alias Elzoo.DurableLog.Writer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  def submit(server, request), do: GenServer.call(server, {:submit, request}, 15_000)
  def known?(server, job_key), do: GenServer.call(server, {:known, job_key}, 15_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       store: Keyword.fetch!(opts, :store),
       stream: Run.submission_stream(Keyword.fetch!(opts, :queue)),
       writer: nil
     }}
  end

  @impl true
  def handle_call({:known, key}, _, state) do
    case ensure(state) do
      {:ok, state} -> {:reply, {:ok, Map.has_key?(model(state), key)}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:submit, request}, _, state) do
    {reply, state} = submit_loop(state, request, 3)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, _}, %{writer: pid} = state), do: {:noreply, %{state | writer: nil}}
  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  defp submit_loop(state, _request, 0), do: {{:error, :contended}, state}

  defp submit_loop(state, request, rounds) do
    with {:ok, state} <- ensure(state) do
      key = request["job_key"]

      case Map.fetch(model(state), key) do
        {:ok, digest} ->
          if digest == Run.digest(request),
            do: {{:duplicate, key}, state},
            else: {{:error, :job_key_conflict}, state}

        :error ->
          payload = Run.encode(request)

          case Writer.append(state.writer, [{"requested", Run.version(), payload}], [
                 {"jobs", payload}
               ]) do
            {:committed, _} -> {{:ok, %{phase: :submitted}}, state}
            {:conflict, _} -> submit_loop(state, request, rounds - 1)
            {:indeterminate, info} -> {{:indeterminate, info}, %{state | writer: nil}}
            {:rejected, reason} -> {{:error, {:rejected, reason}}, state}
          end
      end
    else
      {:error, reason, state} -> {{:error, reason}, state}
    end
  end

  defp model(state), do: Writer.snapshot(state.writer).model

  defp ensure(%{writer: pid} = state) when is_pid(pid), do: {:ok, state}

  defp ensure(state) do
    case Writer.start_link(
           store: state.store,
           stream: state.stream,
           fold: Run.submission_fold(),
           limits: Run.limits()
         ) do
      {:ok, pid} ->
        {:ok, %{state | writer: pid}}

      {:error, reason} ->
        receive do
          {:EXIT, _, _} -> :ok
        after
          0 -> :ok
        end

        {:error, init_error(reason), state}
    end
  end

  defp init_error({:replay_damaged, _}), do: :damaged
  defp init_error(_), do: :unavailable
end
