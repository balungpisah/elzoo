# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AsyncWork do
  @moduledoc """
  Bounded volatile local computation with cancellation, monotonic deadlines
  and plain-info delivery through an owner's Registry name. See the bundle
  README for supervision, trust and delivery limits.
  """
  use GenServer

  @killed [:kill, :killed, :shutdown]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Admit local work; a call timeout after dispatch has an uncertain outcome."
  def start(server, fun, timeout_ms, wrap),
    do: GenServer.call(server, {:start, fun, timeout_ms, wrap})

  @doc "Kill active work; cancellation cannot recall an already sent offer."
  def cancel(server, work_ref), do: GenServer.call(server, {:cancel, work_ref})

  @impl true
  def init(opts) do
    with {:via, Registry, {registry, _key}} = owner <- Keyword.get(opts, :owner),
         true <- is_atom(registry),
         supervisor when not is_nil(supervisor) <- Keyword.get(opts, :task_supervisor),
         max when is_integer(max) and max > 0 <- Keyword.get(opts, :max_concurrency) do
      Process.flag(:trap_exit, true)
      {:ok, %{owner: owner, supervisor: supervisor, max: max, work: %{}}}
    else
      _ -> {:stop, :invalid_options}
    end
  end

  @impl true
  def handle_call({:start, fun, timeout, wrap}, _from, state) do
    cond do
      not (is_function(fun, 0) and is_function(wrap, 2) and is_integer(timeout) and
               timeout in 1..4_294_967_295) ->
        {:reply, {:error, :invalid_work}, state}

      map_size(state.work) >= state.max ->
        {:reply, {:error, :capacity}, state}

      true ->
        deadline = System.monotonic_time(:millisecond) + timeout

        case dispatch(state.supervisor, fun) do
          {:ok, task} ->
            timer = Process.send_after(self(), {:deadline, task.ref}, deadline, abs: true)
            work = %{task: task, timer: timer, deadline: deadline, wrap: wrap}
            {:reply, {:ok, task.ref}, put_in(state.work[task.ref], work)}

          :error ->
            {:reply, {:error, :unavailable}, state}
        end
    end
  end

  def handle_call({:cancel, ref}, _from, state) do
    if Map.has_key?(state.work, ref) do
      {:reply, :ok, settle(state, ref, {:lost, :killed})}
    else
      {:reply, {:error, :late}, state}
    end
  end

  @impl true
  def handle_info({ref, outcome}, state) when is_reference(ref) do
    case Map.fetch(state.work, ref) do
      {:ok, work} ->
        outcome =
          if match?({:completed, _}, outcome) and
               System.monotonic_time(:millisecond) >= work.deadline,
             do: {:lost, :timed_out},
             else: outcome

        {:noreply, settle(state, ref, outcome)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    loss = if reason in @killed, do: :killed, else: :unavailable
    {:noreply, settle(state, ref, {:lost, loss})}
  end

  def handle_info({:deadline, ref}, state),
    do: {:noreply, settle(state, ref, {:lost, :timed_out})}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.work, fn {_ref, work} ->
      Process.cancel_timer(work.timer)
      Task.shutdown(work.task, :brutal_kill)
    end)
  end

  defp dispatch(supervisor, fun) do
    {:ok, Task.Supervisor.async_nolink(supervisor, fn -> invoke(fun) end, shutdown: :brutal_kill)}
  catch
    _, _ -> :error
  end

  # Catch inside the task, before OTP can log exception values or stacktraces.
  defp invoke(fun) do
    {:completed, fun.()}
  catch
    :exit, reason when reason in @killed -> {:lost, :killed}
    _, _ -> {:lost, :unavailable}
  end

  defp settle(state, ref, outcome) do
    case Map.pop(state.work, ref) do
      {nil, _} ->
        state

      {work, remaining} ->
        Process.cancel_timer(work.timer)
        # shutdown waits for actual termination, including tasks trapping exits.
        Task.shutdown(work.task, :brutal_kill)
        offer(state.owner, work.wrap, ref, outcome)
        %{state | work: remaining}
    end
  end

  defp offer(owner, wrap, ref, outcome) do
    message = wrap.(ref, outcome)
    GenServer.whereis(owner) |> send(message)
  catch
    _, _ -> :ok
  end
end
