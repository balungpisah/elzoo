# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RetryTimeout.Runner do
  @moduledoc """
  Volatile, single-node in-flight runner; no queue or shedding.
  Monitor the runner: DOWN before settlement means unknown, not failure/no Effect.
  A blocking dead-letter sink blocks this runner, including admission. Timeout and
  expiry kill the attempt task with an untrappable :kill exit without waiting. A caller's
  GenServer.call timeout is unknown admission, and may be followed by settlement.
  snapshot/1 is inspection, not telemetry or durable accounting.
  """
  use GenServer
  alias Elzoo.{Backpressure, DeadLetter, Envelope, RequestReply, RetryTimeout}
  @max_timer 4_294_967_295

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def submit(runner, envelope), do: GenServer.call(runner, {:submit, envelope})
  def snapshot(runner), do: GenServer.call(runner, :snapshot)

  @impl true
  def init(opts) do
    with true <- proper_list?(opts) and Keyword.keyword?(opts),
         {:ok, capacity} <- Backpressure.new(Keyword.get(opts, :capacity)),
         true <- RetryTimeout.valid_policy?(Keyword.get(opts, :policy)),
         timeout when is_integer(timeout) and timeout > 0 <- Keyword.get(opts, :attempt_timeout_ms),
         attempt when is_function(attempt, 1) <- Keyword.get(opts, :attempt),
         sink when is_function(sink, 1) <- Keyword.get(opts, :dead_letter),
         now when is_function(now, 0) <-
           Keyword.get(opts, :now_ms, fn -> System.os_time(:millisecond) end),
         supervisor when not is_nil(supervisor) <- Keyword.get(opts, :task_supervisor) do
      {:ok,
       %{
         capacity: capacity,
         policy: opts[:policy],
         timeout: timeout,
         attempt: attempt,
         sink: sink,
         now: now,
         supervisor: supervisor,
         ops: %{},
         tasks: %{},
         settled: 0,
         dead_lettered: 0,
         late_or_mismatched: 0
       }}
    else
      _ -> {:stop, :invalid_options}
    end
  end

  @impl true
  def handle_call(:snapshot, _, state) do
    {:CapacityState, capacity, in_flight} = state.capacity

    {:reply,
     Map.take(state, [:settled, :dead_lettered, :late_or_mismatched])
     |> Map.merge(%{capacity: capacity, in_flight: in_flight, open: map_size(state.ops)}), state}
  end

  def handle_call({:submit, request}, {caller, _}, state) do
    case admission(state, request) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, capacity, remaining} ->
        ref = make_ref()

        op = %{
          request: request,
          caller: caller,
          identity: identity(request),
          n: 0,
          current: nil,
          last: nil,
          task: nil,
          timers: %{}
        }

        op = if is_nil(remaining), do: op, else: arm(op, ref, :deadline, remaining)
        state = %{state | capacity: capacity, ops: Map.put(state.ops, ref, op)}
        {:reply, {:ok, ref}, launch(state, ref)}
    end
  end

  defp admission(state, request) do
    with {:ok, _} <- phase(Envelope.decode(request)),
         false <- Map.has_key?(request, "attempt_id"),
         false <- Enum.any?(state.ops, fn {_, op} -> op.identity == identity(request) end) do
      remaining =
        if Map.has_key?(request, "deadline_unix_ms"),
          do: request["deadline_unix_ms"] - state.now.(),
          else: nil

      cond do
        not is_nil(remaining) and remaining <= 0 ->
          {:error, {:expired, result(request, "timed_out", "not_dispatched", "permanent")}}

        true ->
          case Backpressure.admit(state.capacity) do
            {:ok, _, :saturated} ->
              {:error, {:saturated, result(request, "rejected", "not_dispatched", "unavailable")}}

            {:ok, capacity, :admitted} ->
              {:ok, capacity, remaining}
          end
      end
    else
      {:error, _} = error ->
        error

      true ->
        {:error,
         if(Map.has_key?(request, "attempt_id"),
           do: :attempt_id_present,
           else: :operation_in_flight
         )}
    end
  end

  @impl true
  def handle_info({task_ref, response}, state) when is_reference(task_ref) do
    case Map.fetch(state.tasks, task_ref) do
      :error ->
        {:noreply, late(state)}

      {:ok, ref} ->
        Process.demonitor(task_ref, [:flush])
        op = Map.fetch!(state.ops, ref)

        if deadline_due?(op) do
          {:noreply, expire(state, ref)}
        else
          state = clear_task(state, ref, false)

          case RequestReply.correlate(op.current, response) do
            {:ok, valid} ->
              {:noreply, observed(state, ref, valid)}

            _ ->
              {:noreply,
               observed(late(state), ref, result(op.current, "unknown", "unknown", "unclassified"))}
          end
        end
    end
  end

  def handle_info({:DOWN, task_ref, :process, _, _}, state) do
    case Map.fetch(state.tasks, task_ref) do
      :error ->
        {:noreply, state}

      {:ok, ref} ->
        op = state.ops[ref]

        if deadline_due?(op) do
          {:noreply, expire(state, ref)}
        else
          state = clear_task(state, ref, false)
          {:noreply, observed(state, ref, result(op.current, "unknown", "unknown", "unclassified"))}
        end
    end
  end

  def handle_info({:retry_timer, ref, kind, token}, state) do
    with {:ok, op} <- Map.fetch(state.ops, ref),
         {_, ^token, target} <- Map.get(op.timers, kind) do
      remaining = target - monotonic()

      cond do
        remaining > 0 ->
          timer =
            Process.send_after(self(), {:retry_timer, ref, kind, token}, min(remaining, @max_timer))

          op = put_in(op.timers[kind], {timer, token, target})
          {:noreply, put_op(state, ref, op)}

        kind == :deadline or deadline_due?(op) ->
          {:noreply, expire(state, ref)}

        kind == :retry ->
          op = %{op | timers: Map.delete(op.timers, :retry)}
          {:noreply, launch(put_op(state, ref, op), ref)}

        kind == :attempt ->
          state = clear_task(state, ref, true)

          {:noreply,
           observed(state, ref, result(op.current, "timed_out", "unknown", "unclassified"))}
      end
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp launch(state, ref) do
    op = state.ops[ref]

    if deadline_due?(op) do
      expire(state, ref)
    else
      n = op.n + 1

      current =
        Map.put(
          op.request,
          "attempt_id",
          op.request["message_id"] <> "/attempt/" <> Integer.to_string(n)
        )

      op = %{op | n: n, current: current}
      state = put_op(state, ref, op)

      case start_task(state.supervisor, state.attempt, current) do
        {:ok, task} ->
          op = %{op | task: task} |> arm(ref, :attempt, state.timeout)
          %{put_op(state, ref, op) | tasks: Map.put(state.tasks, task.ref, ref)}

        :error ->
          observed(state, ref, result(current, "unknown", "unknown", "unclassified"))
      end
    end
  end

  defp start_task(supervisor, attempt, request) do
    try do
      {:ok, Task.Supervisor.async_nolink(supervisor, fn -> attempt.(request) end)}
    catch
      _, _ -> :error
    end
  end

  defp observed(state, ref, response) do
    op = %{state.ops[ref] | last: response}
    state = put_op(state, ref, op)
    {:ok, class} = RetryTimeout.classify(response)
    {:ok, decision} = RetryTimeout.decide(state.policy, op.n, class)

    case decision do
      :settle ->
        finish(state, ref, {:completed, response})

      :retry ->
        {:ok, delay} = RetryTimeout.backoff(state.policy, op.n)
        put_op(state, ref, arm(op, ref, :retry, delay))

      :permanent ->
        dead_letter(state, ref, "permanent")

      :exhausted ->
        dead_letter(state, ref, "retries_exhausted")

      :unresolved ->
        dead_letter(state, ref, "dispatched_unresolved")
    end
  end

  defp expire(state, ref) do
    op = state.ops[ref]

    response =
      if op.task != nil or op.last == nil,
        do: result(op.current || op.request, "timed_out", "unknown", "unclassified"),
        else: op.last

    state = clear_task(state, ref, true)
    dead_letter(put_op(state, ref, %{state.ops[ref] | last: response}), ref, "deadline_expired")
  end

  defp dead_letter(state, ref, reason) do
    op = state.ops[ref]
    {:ok, record} = DeadLetter.from_result(op.request, op.last, op.n, reason)

    status =
      try do
        if state.sink.(record) == :ok, do: :dead_lettered, else: :unsettled
      catch
        _, _ -> :unsettled
      end

    finish(state, ref, {status, record})
  end

  defp finish(state, ref, {status, _} = settlement) do
    op = state.ops[ref]
    Enum.each(op.timers, fn {_, {timer, _, _}} -> Process.cancel_timer(timer) end)
    state = clear_task(state, ref, true)
    {:ok, capacity} = Backpressure.release(state.capacity)
    send(op.caller, {RetryTimeout, ref, settlement})

    %{
      state
      | ops: Map.delete(state.ops, ref),
        capacity: capacity,
        settled: state.settled + 1,
        dead_lettered: state.dead_lettered + if(status == :dead_lettered, do: 1, else: 0)
    }
  end

  defp clear_task(state, ref, terminate?) do
    op = state.ops[ref]
    {timer, timers} = Map.pop(op.timers, :attempt)
    if timer, do: Process.cancel_timer(elem(timer, 0))

    tasks =
      if op.task do
        Process.demonitor(op.task.ref, [:flush])

        if terminate?, do: Process.exit(op.task.pid, :kill)

        Map.delete(state.tasks, op.task.ref)
      else
        state.tasks
      end

    %{put_op(state, ref, %{op | task: nil, timers: timers}) | tasks: tasks}
  end

  defp arm(op, ref, kind, delay) do
    token = make_ref()
    target = monotonic() + delay
    timer = Process.send_after(self(), {:retry_timer, ref, kind, token}, min(delay, @max_timer))
    put_in(op.timers[kind], {timer, token, target})
  end

  defp deadline_due?(op) do
    case Map.get(op.timers, :deadline) do
      nil -> false
      {_, _, target} -> monotonic() >= target
    end
  end

  defp monotonic, do: System.monotonic_time(:millisecond)
  defp put_op(state, ref, op), do: %{state | ops: Map.put(state.ops, ref, op)}
  defp late(state), do: %{state | late_or_mismatched: state.late_or_mismatched + 1}
  defp identity(request), do: Map.get(request, "correlation_id", request["message_id"])
  defp phase({:ok, _} = ok), do: ok
  defp phase({:error, e}), do: {:error, {:envelope, e}}

  defp result(request, outcome, dispatch, error) do
    %{
      "version" => 1,
      "message_id" => request["message_id"],
      "correlation_id" => identity(request),
      "outcome" => outcome,
      "dispatch" => dispatch,
      "error_class" => error
    }
    |> Map.merge(Map.take(request, ~w(attempt_id deadline_unix_ms)))
  end

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false
end
