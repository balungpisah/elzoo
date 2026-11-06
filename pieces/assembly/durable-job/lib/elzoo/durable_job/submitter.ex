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

  @doc "Default call timeouts derive from `Elzoo.DurableJob.writer_timeout_ms/0`."
  def submit(server, request, timeout \\ 3 * Elzoo.DurableJob.writer_timeout_ms() + 5_000),
    do: GenServer.call(server, {:submit, request}, timeout)

  def known?(server, job_key, timeout \\ Elzoo.DurableJob.writer_timeout_ms() + 5_000),
    do: GenServer.call(server, {:known, job_key}, timeout)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       store: Keyword.fetch!(opts, :store),
       queue: Keyword.fetch!(opts, :queue),
       stream: Run.submission_stream(Keyword.fetch!(opts, :queue)),
       writer_timeout: Keyword.get(opts, :writer_timeout_ms, Elzoo.DurableJob.writer_timeout_ms()),
       writer: nil
     }}
  end

  @impl true
  def handle_call({:known, key}, _, state) do
    case ensure(state) do
      {:ok, state} ->
        case model(state) do
          {:ok, model} -> {:reply, {:ok, Map.has_key?(model, key)}, state}
          :exit -> {:reply, {:error, :unavailable}, drop(state)}
        end

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
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

      case model(state) do
        :exit -> {{:error, :unavailable}, drop(state)}
        {:ok, model} -> submit_new(state, request, rounds, key, Map.fetch(model, key))
      end
    else
      {:error, reason, state} -> {{:error, reason}, state}
    end
  end

  defp submit_new(state, request, rounds, key, found) do
    case found do
      {:ok, digest} ->
        if digest == Run.digest(request),
          do: {{:duplicate, key}, state},
          else: {{:error, :job_key_conflict}, state}

      :error ->
        payload = Run.encode(request)

        case append(state, payload) do
          {:committed, _} -> {{:ok, %{phase: :submitted}}, state}
          {:conflict, _} -> submit_loop(state, request, rounds - 1)
          {:indeterminate, info} -> {{:indeterminate, info}, %{state | writer: nil}}
          {:rejected, reason} -> {{:error, {:rejected, reason}}, state}
          {:exit, cause} -> {{:indeterminate, unknown(state, key, cause)}, drop(state)}
        end
    end
  end

  # The append was sent: an exit (timeout) leaves its commit unknown. The
  # Writer is killed so a late reply cannot reach a replaced Writer.
  defp append(state, payload) do
    Writer.append(
      state.writer,
      [{"requested", Run.version(), payload}],
      [{"jobs", payload}],
      state.writer_timeout
    )
  catch
    :exit, {:timeout, _} -> {:exit, :timeout}
    :exit, _ -> {:exit, :exit}
  end

  defp unknown(state, key, cause),
    do: %{operation: :submit, queue: state.queue, job_key: key, cause: cause}

  defp drop(%{writer: pid} = state) when is_pid(pid) do
    Process.exit(pid, :kill)
    %{state | writer: nil}
  end

  defp drop(state), do: state

  defp model(state) do
    {:ok, Writer.snapshot(state.writer).model}
  catch
    :exit, _ -> :exit
  end

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
