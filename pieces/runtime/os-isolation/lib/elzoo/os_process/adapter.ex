# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.OsProcess.Adapter do
  @moduledoc """
  Admission, bounded FIFO queue and dispatch. Slots are counted by `Elzoo.Backpressure`;
  the queue and its timers are Adapter-owned policy. Each dispatched run gets its own
  `Elzoo.OsProcess.Owner`, which replies to the submitter itself; the Adapter only learns
  completion from the owner's exit. Runs are recorded in the supervisor-owned ETS table
  so an Adapter restart recovers live owners and reports dead ones.
  """
  use GenServer
  alias Elzoo.Backpressure
  alias Elzoo.OsProcess.{Config, Owner, Result}

  def start_link(%Config{} = config), do: GenServer.start_link(__MODULE__, config)

  @impl true
  def init(%Config{} = config) do
    {:ok, capacity} = Backpressure.new(config.max_concurrent)

    state = %{
      config: config,
      tid: config.tid,
      dsup: nil,
      capacity: capacity,
      queue: :queue.new(),
      queued: %{},
      running: %{},
      observing: %{},
      cancelled: {:queue.new(), MapSet.new()},
      generation: 0
    }

    {:ok, recover(state)}
  end

  @impl true
  def handle_call(:tid, _from, state), do: {:reply, state.tid, state}

  def handle_call(:snapshot, _from, state) do
    {:CapacityState, capacity, in_flight} = state.capacity
    {:reply, %{in_flight: in_flight, queued: map_size(state.queued), capacity: capacity}, state}
  end

  def handle_call(:bounds, _from, state) do
    config = state.config

    {:reply,
     %{
       queue_timeout_ms: config.queue_timeout_ms,
       grace_ms: config.grace_s * 1000,
       observe_timeout_ms: config.observe_timeout_ms
     }, state}
  end

  def handle_call({:submit, spec, opts, submitter}, _from, state) do
    case Result.validate_request(spec, opts) do
      {:error, _} = error ->
        {:reply, error, state}

      {:ok, request} ->
        ref = make_ref()
        now_unix = state.config.now_unix_ms.()
        mono = System.monotonic_time(:millisecond)

        target =
          case request.deadline_unix_ms do
            nil -> nil
            deadline -> mono + (deadline - now_unix)
          end

        cond do
          target != nil and target <= mono ->
            notify(submitter, ref, Result.expired(request))
            {:reply, {:ok, ref}, state}

          target != nil and target - mono > Config.max_timer() ->
            {:reply, {:error, {:invalid_spec, :deadline_too_far}}, state}

          true ->
            entry = %{ref: ref, submitter: submitter, request: request, target: target}
            {:reply, {:ok, ref}, admit(state, entry)}
        end
    end
  end

  def handle_call({:cancel, ref}, _from, state) do
    cond do
      Map.has_key?(state.queued, ref) ->
        entry = state.queued[ref]
        state = drop_queued(state, ref)
        notify(entry.submitter, ref, Result.rejected(:cancelled))
        {:reply, {:ok, :requested}, remember_cancelled(state, ref)}

      Map.has_key?(state.running, ref) ->
        # Asynchronous: the owner may be inside exec:run; the Adapter never blocks on it.
        case {state.running[ref], :ets.lookup(state.tid, ref)} do
          {%{cancel_requested: true}, _} ->
            {:reply, {:ok, :already_requested}, state}

          {_, [{^ref, _owner, _submitter, _os_pid, status}]} when status in [:exited, :finished] ->
            # The leader has exited; the provider cannot stop the group any more. The run's
            # result reports what remains (completed or unknown{group_alive}).
            {:reply, {:error, :already_exited}, state}

          {entry, _} ->
            Owner.cancel(entry.owner)
            running = Map.put(state.running, ref, Map.put(entry, :cancel_requested, true))
            {:reply, {:ok, :requested}, %{state | running: running}}
        end

      MapSet.member?(elem(state.cancelled, 1), ref) ->
        {:reply, {:ok, :already_requested}, state}

      true ->
        {:reply, {:error, :unknown_run}, state}
    end
  end

  @impl true
  def handle_info({:queue_timer, ref, generation}, state) do
    case state.queued[ref] do
      %{generation: ^generation} = entry ->
        state = drop_queued(state, ref)
        mono = System.monotonic_time(:millisecond)

        result =
          if entry.target != nil and mono >= entry.target,
            do: Result.expired(entry.request),
            else: Result.rejected(:queue_timeout)

        notify(entry.submitter, ref, result)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _mon, :process, pid, reason}, state) do
    cond do
      ref = find_running(state, pid) ->
        {:noreply, owner_down(state, ref, reason)}

      ref = find_queued_submitter(state, pid) ->
        {:noreply, drop_queued(state, ref)}

      Map.has_key?(state.observing, pid) ->
        :ets.delete(state.tid, state.observing[pid])
        {:noreply, release(%{state | observing: Map.delete(state.observing, pid)})}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Admission: a free slot dispatches now; otherwise the bounded queue or queue_full.
  defp admit(state, entry) do
    case Backpressure.admit(state.capacity) do
      {:ok, capacity, :admitted} ->
        dispatch(%{state | capacity: capacity}, entry)

      {:ok, _capacity, :saturated} ->
        if map_size(state.queued) < state.config.queue_limit do
          mono = System.monotonic_time(:millisecond)
          wait = state.config.queue_timeout_ms
          wait = if entry.target, do: min(wait, max(entry.target - mono, 0)), else: wait
          generation = state.generation + 1
          timer = Process.send_after(self(), {:queue_timer, entry.ref, generation}, wait)
          mon = Process.monitor(entry.submitter)
          entry = Map.merge(entry, %{generation: generation, timer: timer, mon: mon})

          %{
            state
            | queue: :queue.in(entry.ref, state.queue),
              queued: Map.put(state.queued, entry.ref, entry),
              generation: generation
          }
        else
          notify(entry.submitter, entry.ref, Result.rejected(:queue_full))
          state
        end
    end
  end

  defp dispatch(state, entry) do
    mono = System.monotonic_time(:millisecond)

    if entry.target != nil and mono >= entry.target do
      notify(entry.submitter, entry.ref, Result.expired(entry.request))
      release(state)
    else
      remaining = if entry.target, do: entry.target - mono, else: nil
      state = ensure_dsup(state)

      args = %{
        tid: state.tid,
        ref: entry.ref,
        submitter: entry.submitter,
        request: entry.request,
        remaining_ms: remaining,
        config: state.config
      }

      case DynamicSupervisor.start_child(state.dsup, {Owner, args}) do
        {:ok, owner} ->
          mon = Process.monitor(owner)

          %{
            state
            | running:
                Map.put(state.running, entry.ref, %{owner: owner, mon: mon, cancel_requested: false})
          }

        {:error, _} ->
          notify(entry.submitter, entry.ref, Result.unknown(:owner_start_failed, %{}))
          release(state)
      end
    end
  end

  defp owner_down(state, ref, _reason) do
    %{owner: owner} = state.running[ref]
    state = %{state | running: Map.delete(state.running, ref)}

    case :ets.lookup(state.tid, ref) do
      [{^ref, ^owner, _submitter, _os_pid, :finished}] ->
        :ets.delete(state.tid, ref)

      [{^ref, ^owner, submitter, nil, _status}] ->
        :ets.delete(state.tid, ref)
        notify(submitter, ref, Result.unknown(:owner_exit_before_registration, %{}))

      [{^ref, ^owner, submitter, os_pid, _status}] ->
        # The slot stands for a running OS command: it is released only when the group has been
        # observed empty or the observation bound passed, by the observer's exit (handle_info DOWN).
        # The registry row stays, marked {:observing, observer}, so a restarted Adapter counts it.
        {:observing, state_with_observer(state, ref, owner, submitter, os_pid)}

      _ ->
        :ok
    end
    |> case do
      {:observing, observing_state} -> observing_state
      _ -> release(state)
    end
  end

  # The observer is not linked to the Adapter: it survives an Adapter restart, notifies the
  # submitter exactly once, and deletes its own registry row afterwards. It starts work only after
  # its row is written, so the row can never outlive a finished observer.
  defp state_with_observer(state, ref, owner, submitter, os_pid) do
    config = state.config
    tid = state.tid
    bound = config.grace_s * 1000 + config.observe_timeout_ms

    {pid, _mon} =
      spawn_monitor(fn ->
        receive do
          :go -> :ok
        end

        members = Owner.observe_until_empty(config.pgrep_path, os_pid, bound)
        notify(submitter, ref, Result.unknown(:owner_exit, %{os_pid: os_pid, members: members}))

        # The instance (and its table) may have stopped while this observer ran.
        try do
          :ets.delete(tid, ref)
        rescue
          ArgumentError -> :ok
        end
      end)

    :ets.insert(tid, {ref, owner, submitter, os_pid, {:observing, pid}})
    send(pid, :go)
    %{state | observing: Map.put(state.observing, pid, ref)}
  end

  defp adopt_observer(state, ref, pid) do
    Process.monitor(pid)

    capacity =
      case Backpressure.admit(state.capacity) do
        {:ok, c, _} -> c
      end

    %{state | observing: Map.put(state.observing, pid, ref), capacity: capacity}
  end

  # Bounded memory of queued requests settled by cancel, so a repeated cancel stays idempotent.
  @cancelled_limit 1024
  defp remember_cancelled(state, ref) do
    {q, set} = state.cancelled
    {q, set} = {:queue.in(ref, q), MapSet.put(set, ref)}

    {q, set} =
      if :queue.len(q) > @cancelled_limit do
        {{:value, old}, q} = :queue.out(q)
        {q, MapSet.delete(set, old)}
      else
        {q, set}
      end

    %{state | cancelled: {q, set}}
  end

  defp release(state) do
    state =
      case Backpressure.release(state.capacity) do
        {:ok, capacity} -> %{state | capacity: capacity}
        {:error, :release_underflow} -> state
      end

    case :queue.out(state.queue) do
      {{:value, ref}, rest} ->
        state = %{state | queue: rest}

        case state.queued[ref] do
          nil ->
            release_next(state)

          entry ->
            Process.cancel_timer(entry.timer)
            Process.demonitor(entry.mon, [:flush])
            state = %{state | queued: Map.delete(state.queued, ref)}

            case Backpressure.admit(state.capacity) do
              {:ok, capacity, :admitted} -> dispatch(%{state | capacity: capacity}, entry)
              {:ok, _, :saturated} -> state
            end
        end

      {:empty, _} ->
        state
    end
  end

  # A queued ref already removed (cancel/caller death) leaves a stale queue token.
  defp release_next(state) do
    case :queue.out(state.queue) do
      {{:value, ref}, rest} ->
        state = %{state | queue: rest}

        case state.queued[ref] do
          nil ->
            release_next(state)

          entry ->
            Process.cancel_timer(entry.timer)
            Process.demonitor(entry.mon, [:flush])
            state = %{state | queued: Map.delete(state.queued, ref)}

            case Backpressure.admit(state.capacity) do
              {:ok, capacity, :admitted} -> dispatch(%{state | capacity: capacity}, entry)
              {:ok, _, :saturated} -> state
            end
        end

      {:empty, _} ->
        state
    end
  end

  defp drop_queued(state, ref) do
    case state.queued[ref] do
      nil ->
        state

      entry ->
        Process.cancel_timer(entry.timer)
        Process.demonitor(entry.mon, [:flush])

        %{
          state
          | queued: Map.delete(state.queued, ref),
            queue: :queue.filter(&(&1 != ref), state.queue)
        }
    end
  end

  defp find_running(state, pid),
    do: Enum.find_value(state.running, fn {ref, %{owner: owner}} -> if owner == pid, do: ref end)

  defp find_queued_submitter(state, pid),
    do: Enum.find_value(state.queued, fn {ref, entry} -> if entry.submitter == pid, do: ref end)

  defp ensure_dsup(%{dsup: pid} = state) when is_pid(pid), do: state

  defp ensure_dsup(state) do
    dsup =
      state.config.supervisor
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {DynamicSupervisor, pid, _, _} when is_pid(pid) -> pid
        _ -> nil
      end)

    %{state | dsup: dsup}
  end

  # Adapter restart: live owners are re-monitored and counted; dead owners are reported.
  defp recover(state) do
    :ets.tab2list(state.tid)
    |> Enum.reduce(state, fn {ref, owner, submitter, os_pid, status}, acc ->
      cond do
        status == :finished ->
          :ets.delete(acc.tid, ref)
          acc

        match?({:observing, _}, status) ->
          {:observing, observer} = status

          if Process.alive?(observer) do
            adopt_observer(acc, ref, observer)
          else
            # The observer ended between notifying and deleting its row, or was killed: it owned
            # the only notification, so nothing is sent again (at most once).
            :ets.delete(acc.tid, ref)
            acc
          end

        is_pid(owner) and Process.alive?(owner) ->
          mon = Process.monitor(owner)

          capacity =
            case Backpressure.admit(acc.capacity) do
              {:ok, c, _} -> c
            end

          %{
            acc
            | running:
                Map.put(acc.running, ref, %{owner: owner, mon: mon, cancel_requested: false}),
              capacity: capacity
          }

        true ->
          if os_pid == nil do
            :ets.delete(acc.tid, ref)
            notify(submitter, ref, Result.unknown(:owner_exit_before_registration, %{}))
            acc
          else
            capacity =
              case Backpressure.admit(acc.capacity) do
                {:ok, c, _} -> c
              end

            state_with_observer(%{acc | capacity: capacity}, ref, owner, submitter, os_pid)
          end
      end
    end)
  end

  defp notify(submitter, ref, result), do: send(submitter, {Elzoo.OsProcess, ref, result})
end
