# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CircuitBreaker do
  @moduledoc "Volatile first-failure circuit admission over fuse 2.5.0; one fenced recovery probe."
  use GenServer

  alias Elzoo.Backpressure
  @policy :"Cure.Elzoo.CircuitPolicy"
  @event [:elzoo, :circuit_breaker, :transition]
  @defaults [role: :other, cooldown_ms: 1_000, observation_timeout_ms: 5_000, max_tracked: 128]
  @modes %{closed: :Closed, open: :Open, half_open: :HalfOpen, unavailable: :Unavailable}
  @observations %{healthy: :Healthy, unhealthy: :Unhealthy, neutral: :Neutral, unknown: :Unknown}

  def start_link(opts) do
    with {:ok, config} <- options(opts) do
      # OTP registers this name before init: a losing start cannot touch fuse.
      GenServer.start_link(__MODULE__, config, name: config.name)
    end
  end

  def child_spec(opts),
    do: %{
      id: {__MODULE__, Keyword.get(opts, :name)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }

  def admit(owner), do: call(owner, :admit)

  def finish(owner, permit, observation) do
    cond do
      not Map.has_key?(@observations, observation) -> {:error, :invalid_observation}
      not permit_shape?(permit) -> {:error, :invalid_permit}
      true -> call(owner, {:finish, permit, observation})
    end
  end

  def abandon(owner, permit), do: finish(owner, permit, :unknown)

  defp permit_shape?({__MODULE__, incarnation, epoch, ref}),
    do: is_reference(incarnation) and is_integer(epoch) and is_reference(ref)

  defp permit_shape?(_), do: false
  def status(owner), do: call(owner, :status)

  defp call(owner, request) when is_pid(owner) do
    GenServer.call(owner, request)
  catch
    :exit, {:timeout, _} -> {:unknown, :owner_call_timeout}
    :exit, _ -> {:error, :owner_unavailable}
  end

  defp call(_, _), do: {:error, :owner_unavailable}

  defp options(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:name, :clock | Keyword.keys(@defaults)])) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      config =
        Map.new(Keyword.merge(@defaults, opts))
        |> Map.put_new(:clock, fn -> System.monotonic_time(:millisecond) end)

      if is_atom(config[:name]) and config[:name] not in [nil, false, true] and
           config.role in [:object_store, :notification, :model, :other] and
           bounded?(config.cooldown_ms, 60_000) and bounded?(config.observation_timeout_ms, 60_000) and
           bounded?(config.max_tracked, 4096) and is_function(config.clock, 0),
         do: {:ok, config},
         else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp bounded?(n, max), do: is_integer(n) and n >= 1 and n <= max

  @impl true
  def init(config) do
    provider = Process.whereis(:fuse_server)
    {:ok, capacity} = Backpressure.new(config.max_tracked)

    state = %{
      config: config,
      fuse: {:elzoo_circuit_breaker, config.name},
      provider: provider,
      provider_monitor: if(is_pid(provider), do: Process.monitor(provider)),
      incarnation: make_ref(),
      mode: :half_open,
      epoch: 0,
      permits: %{},
      probe: nil,
      capacity: capacity,
      last_now: nil,
      open_until: nil
    }

    # Never attach to a replacement incarnation, even during initialization.
    with true <- Application.spec(:fuse, :vsn) == ~c"2.5.0",
         true <- Application.get_env(:fuse, :stats_plugin, :fuse_stats_ets) == :fuse_stats_ets,
         {:ok, :ok} <-
           invoke(state, fn ->
             :fuse.install(state.fuse, {{:standard, 0, 1_000}, {:reset, config.cooldown_ms}})
           end),
         {:ok, :ok} <- invoke(state, fn -> :fuse.ask(state.fuse, :sync) end) do
      state =
        case sample(state) do
          {:ok, next, _} -> next
          {:error, next} -> next
        end

      emit(state, :half_open, :startup)
      if provider_identity?(state), do: {:ok, state}, else: {:stop, :provider_unavailable}
    else
      _ -> {:stop, :provider_unavailable}
    end
  end

  @impl true
  def handle_call(:admit, {holder, _}, state) do
    case advance(state) do
      {:error, reason, next} ->
        {:reply, {:refused, reason}, next}

      {:ok, next, now} ->
        case admission(next, now) do
          decision when decision in [:Normal, :Probe, :CheckReset] ->
            admit_checked(next, holder, decision)

          decision ->
            {:reply, refusal(decision), next}
        end
    end
  end

  def handle_call({:finish, permit, observation}, {holder, _}, state) do
    # Invalid reports change nothing, including expiry and cooldown bookkeeping.
    with true <- Map.has_key?(@observations, observation),
         {:ok, ref, _} <- authenticate(state, permit, holder) do
      finish_checked(state, ref, observation)
    else
      false -> {:reply, {:error, :invalid_observation}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _, state) do
    case advance(state) do
      {:ok, next, now} ->
        {:reply, {:ok, snapshot(next, now)}, next}

      {:error, :provider_unavailable, next} ->
        # Unavailability is an inspectable, permanently latched mode.
        {:reply, {:ok, snapshot(next, next.last_now)}, next}

      {:error, reason, next} ->
        {:reply, {:error, reason}, next}
    end
  end

  def handle_call(_, _, state), do: {:reply, {:error, :invalid_permit}, state}

  defp authenticate(state, {__MODULE__, incarnation, epoch, ref}, holder)
       when is_reference(incarnation) and is_integer(epoch) and is_reference(ref) do
    cond do
      incarnation != state.incarnation -> {:error, :invalid_permit}
      not Map.has_key?(state.permits, ref) -> {:error, :stale_permit}
      state.permits[ref].holder != holder -> {:error, :wrong_holder}
      state.permits[ref].epoch != epoch -> {:error, :invalid_permit}
      true -> {:ok, ref, state.permits[ref]}
    end
  end

  defp authenticate(_, _, _), do: {:error, :invalid_permit}

  defp finish_checked(state, ref, observation) do
    entry = Map.fetch!(state.permits, ref)

    if entry.epoch != state.epoch do
      # Authentication has already succeeded. An invalidated retained probe
      # has no current health to observe: retire it without clock/provider
      # evaluation, preserving health and the exact existing cooldown target.
      {:Keep, _} =
        apply(@policy, :observe, [
          @modes[state.mode],
          false,
          entry.probe,
          @observations[observation]
        ])

      {:reply, {:ok, :applied}, retire(state, ref)}
    else
      finish_current(state, ref, observation)
    end
  end

  defp finish_current(state, ref, observation) do
    case advance(state) do
      {:error, reason, next} ->
        {:reply, {:error, reason}, next}

      {:ok, next, _} ->
        case Map.fetch(next.permits, ref) do
          :error ->
            {:reply, {:error, :stale_permit}, next}

          {:ok, entry} ->
            decision =
              apply(@policy, :observe, [
                @modes[next.mode],
                entry.epoch == next.epoch,
                entry.probe,
                @observations[observation]
              ])

            next = retire(next, ref)

            case decision do
              {:Keep, _} ->
                {:reply, {:ok, :applied}, next}

              :Close ->
                {:reply, {:ok, :applied},
                 transition(%{next | open_until: nil}, :closed, :probe_healthy)}

              :Trip ->
                {next, error} = trip(next, observation)
                {:reply, if(error, do: {:error, error}, else: {:ok, :applied}), next}
            end
        end
    end
  end

  defp admit_checked(state, holder, initial) do
    case invoke(state, fn -> :fuse.ask(state.fuse, :sync) end) do
      {:ok, result} when result in [:ok, :blown] ->
        # Calls and observers can be slow. Re-evaluate freshness after them.
        case advance(state) do
          {:error, reason, next} ->
            {:reply, {:refused, reason}, next}

          {:ok, next, now} ->
            next =
              cond do
                result == :blown and next.mode in [:closed, :half_open] ->
                  next
                  |> invalidate()
                  |> Map.put(:open_until, now + next.config.cooldown_ms)
                  |> transition(:open, :unhealthy)

                result == :ok and initial == :CheckReset and admission(next, now) == :CheckReset ->
                  transition(next, :half_open, :cooldown_ready)

                true ->
                  next
              end

            grant(next, holder, result)
        end

      _ ->
        {:reply, {:refused, :provider_unavailable}, unavailable(state)}
    end
  end

  defp grant(state, holder, provider_result) do
    # In particular, a replacement between reset observation and probe grant
    # must not be mistaken for the bound provider. No atomic crash guarantee.
    case advance(state) do
      {:error, reason, next} ->
        {:reply, {:refused, reason}, next}

      {:ok, next, now} ->
        decision = admission(next, now)

        if provider_result == :ok and decision in [:Normal, :Probe] do
          case Backpressure.admit(next.capacity) do
            {:ok, _, :saturated} ->
              {:reply, {:refused, :tracking_saturated}, next}

            {:ok, capacity, :admitted} ->
              if provider_identity?(next) do
                ref = make_ref()
                probe = decision == :Probe

                entry = %{
                  holder: holder,
                  monitor: Process.monitor(holder),
                  epoch: next.epoch,
                  probe: probe,
                  down: false,
                  expires: now + next.config.observation_timeout_ms,
                  timer:
                    Process.send_after(
                      self(),
                      {:circuit_expiry, next.incarnation, ref},
                      next.config.observation_timeout_ms
                    )
                }

                permit = {__MODULE__, next.incarnation, next.epoch, ref}

                next = %{
                  next
                  | capacity: capacity,
                    permits: Map.put(next.permits, ref, entry),
                    probe: if(probe, do: ref, else: next.probe)
                }

                {:reply, {:ok, permit}, next}
              else
                {:reply, {:refused, :provider_unavailable}, unavailable(next)}
              end
          end
        else
          {:reply, if(provider_result == :blown, do: {:refused, :open}, else: refusal(decision)),
           next}
        end
    end
  end

  defp admission(state, now),
    do:
      apply(@policy, :admission, [
        @modes[state.mode],
        state.probe != nil,
        now,
        state.open_until || now + 1
      ])

  defp refusal(:RefuseBusy), do: {:refused, :probe_busy}
  defp refusal(:RefuseUnavailable), do: {:refused, :provider_unavailable}
  defp refusal(_), do: {:refused, :open}

  # Sampled time is local monotonic data; negative samples are valid.
  defp sample(state) do
    now = state.config.clock.()

    if is_integer(now) and (state.last_now == nil or now >= state.last_now) do
      next = %{state | last_now: now}
      # A clock failure after a melt cannot invent a target. On recovery,
      # conservatively start the whole local delay from this valid sample.
      next =
        if next.mode == :open and next.open_until == nil,
          do: %{next | open_until: now + next.config.cooldown_ms},
          else: next

      {:ok, next, now}
    else
      {:error, state}
    end
  rescue
    _ -> {:error, state}
  catch
    _, _ -> {:error, state}
  end

  defp advance(state) do
    cond do
      state.mode == :unavailable ->
        {:error, :provider_unavailable, state}

      not provider_identity?(state) ->
        {:error, :provider_unavailable, unavailable(state)}

      true ->
        case sample(state) do
          {:error, next} ->
            {:error, :clock_unavailable, next}

          {:ok, next, now} ->
            advance_sampled(next, now)
        end
    end
  end

  defp advance_sampled(next, now) do
    if not provider_identity?(next) do
      {:error, :provider_unavailable, unavailable(next)}
    else
      expired =
        Enum.find(next.permits, fn {_, e} ->
          e.epoch == next.epoch and (e.down or now >= e.expires)
        end)

      case expired do
        nil ->
          {:ok, next, now}

        {_, entry} ->
          {next, error} =
            trip(next, if(entry.down, do: :holder_down, else: :observation_expired))

          if error, do: {:error, error, next}, else: {:ok, next, next.last_now}
      end
    end
  end

  defp trip(state, cause) do
    from = state.mode
    state = invalidate(state)
    # melt alone returns ok even for an absent name. Confirm existence with
    # sync ask, including ok after a very short upstream reset.
    result =
      with {:ok, :ok} <- invoke(state, fn -> :fuse.melt(state.fuse) end),
           {:ok, answer} when answer in [:ok, :blown] <-
             invoke(state, fn -> :fuse.ask(state.fuse, :sync) end),
           do: :ok

    case result do
      :ok ->
        state = %{state | mode: :open, open_until: nil}

        case sample(state) do
          {:ok, next, _} ->
            emit(next, :open, cause, from)
            {next, nil}

          {:error, next} ->
            {next, :clock_unavailable}
        end

      _ ->
        {unavailable(state), :provider_unavailable}
    end
  end

  # Invalidation retires ordinary permits immediately; unfinished probes keep
  # their monitor and capacity until authenticated retirement or matching DOWN.
  defp invalidate(state) do
    next =
      Enum.reduce(state.permits, state, fn {ref, entry}, acc ->
        if entry.probe do
          cancel(entry.timer)
          put_in(acc.permits[ref].timer, nil)
        else
          retire(acc, ref)
        end
      end)

    %{next | epoch: next.epoch + 1}
  end

  defp retire(state, ref) do
    case Map.pop(state.permits, ref) do
      {nil, _} ->
        state

      {entry, permits} ->
        cancel(entry.timer)
        Process.demonitor(entry.monitor, [:flush])
        {:ok, capacity} = Backpressure.release(state.capacity)

        %{
          state
          | permits: permits,
            capacity: capacity,
            probe: if(state.probe == ref, do: nil, else: state.probe)
        }
    end
  end

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)

  defp provider_identity?(state),
    do: is_pid(state.provider) and Process.whereis(:fuse_server) == state.provider

  defp invoke(state, fun) do
    if provider_identity?(state) do
      result = fun.()
      if provider_identity?(state), do: {:ok, result}, else: :error
    else
      :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp unavailable(%{mode: :unavailable} = state), do: state

  defp unavailable(state) do
    next = Enum.reduce(Map.keys(state.permits), state, &retire(&2, &1))
    transition(next, :unavailable, :provider_unavailable)
  end

  defp transition(state, mode, cause) do
    from = state.mode
    next = %{state | mode: mode}
    emit(next, mode, cause, from)
    next
  end

  defp emit(state, to, cause, from \\ :half_open) do
    :telemetry.execute(
      @event,
      %{
        tracked: map_size(state.permits),
        epoch: state.epoch,
        cooldown_remaining_ms: remaining(state, state.last_now)
      },
      %{role: state.config.role, from: from, to: to, cause: cause}
    )
  end

  defp remaining(state, now) do
    if is_integer(now) and is_integer(state.open_until), do: max(0, state.open_until - now), else: 0
  end

  defp snapshot(state, now),
    do: %{
      mode: state.mode,
      epoch: state.epoch,
      tracked: map_size(state.permits),
      recovery_probe_held: state.probe != nil,
      cooldown_remaining_ms: remaining(state, now),
      settings:
        Map.take(state.config, Keyword.keys(@defaults))
        |> Map.merge(%{failure_threshold: 1, recovery_probes: 1, history_ms: 1_000})
    }

  @impl true
  def handle_info({:circuit_expiry, incarnation, ref}, state) do
    if incarnation == state.incarnation and Map.has_key?(state.permits, ref) and
         state.permits[ref].epoch == state.epoch do
      next =
        case advance(state) do
          {:ok, next, _} -> next
          {:error, _, next} -> next
        end

      next =
        case Map.fetch(next.permits, ref) do
          {:ok, entry} when entry.epoch == next.epoch ->
            cancel(entry.timer)
            delay = if next.last_now, do: max(1, entry.expires - next.last_now), else: 10

            put_in(
              next.permits[ref].timer,
              Process.send_after(
                self(),
                {:circuit_expiry, incarnation, ref},
                min(delay, next.config.observation_timeout_ms)
              )
            )

          _ ->
            next
        end

      {:noreply, next}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, _discarded_reason}, state) do
    cond do
      monitor == state.provider_monitor and pid == state.provider ->
        {:noreply, unavailable(state)}

      true ->
        case Enum.find(state.permits, fn {_, e} -> e.monitor == monitor and e.holder == pid end) do
          nil ->
            {:noreply, state}

          {ref, entry} ->
            next =
              if entry.epoch != state.epoch do
                retire(state, ref)
              else
                next = put_in(state.permits[ref].down, true)

                case advance(next) do
                  {:ok, next, _} -> retire(next, ref)
                  {:error, _, next} -> next
                end
              end

            {:noreply, next}
        end
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    Enum.each(state.permits, fn {_, e} ->
      cancel(e.timer)
      Process.demonitor(e.monitor, [:flush])
    end)

    if provider_identity?(state), do: invoke(state, fn -> :fuse.remove(state.fuse) end)
    :ok
  end
end
