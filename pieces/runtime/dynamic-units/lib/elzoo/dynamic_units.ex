# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DynamicUnits do
  @moduledoc "Bounded local identity and idle lifecycle over caller-owned OTP infrastructure."
  use GenServer
  alias Elzoo.DurableUnit

  def start_link(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(
           Keyword.keys(opts),
           &(&1 in [:registry, :supervisor, :unit_options, :idle_ms, :name])
         ) and
         is_atom(opts[:registry]) and not is_nil(opts[:registry]) and
         (is_pid(opts[:supervisor]) or
            (is_atom(opts[:supervisor]) and not is_nil(opts[:supervisor]))) and
         is_function(opts[:unit_options], 1) and is_integer(opts[:idle_ms]) and
         opts[:idle_ms] in 1..4_294_967_295 do
      GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
    else
      {:error, :invalid_options}
    end
  rescue
    ArgumentError -> {:error, :invalid_options}
  end

  def start(server, identity), do: GenServer.call(server, {:start, identity})
  def find(server, identity), do: GenServer.call(server, {:find, identity})
  def stop(server, identity), do: GenServer.call(server, {:stop, identity})
  def route(server, identity, message), do: GenServer.call(server, {:route, identity, message})

  @doc false
  # Only the start MFA changes; OTP retains DurableUnit's transient/shutdown policy.
  def start_unit(directory, identity, generation, opts) do
    with {:ok, pid} = result <- DurableUnit.start_link(opts) do
      send(directory, {:unit_started, identity, generation, pid})
      result
    end
  end

  @impl true
  def init(opts) do
    registry = opts[:registry]
    supervisor = GenServer.whereis(opts[:supervisor])
    registry_pid = Process.whereis(registry)
    # Ordinary via-name resolution also rejects a duplicate-key Registry.
    :undefined = Registry.whereis_name({registry, make_ref()})
    true = is_pid(supervisor) and is_pid(registry_pid)
    true = node(supervisor) == node()
    [] = DynamicSupervisor.which_children(supervisor)
    Enum.each([registry_pid, supervisor], &Process.monitor/1)

    {:ok,
     %{
       registry: registry,
       supervisor: supervisor,
       infrastructure: [registry_pid, supervisor],
       available: true,
       unit_options: opts[:unit_options],
       idle_ms: opts[:idle_ms],
       entries: %{}
     }}
  catch
    _, _ -> {:stop, :unavailable}
  end

  @impl true
  def handle_call(request, _, state) do
    identity = elem(request, 1)

    cond do
      not identity?(identity) ->
        {:reply, {:error, :invalid_identity}, state}

      match?({:route, _, _}, request) and not message?(elem(request, 2)) ->
        {:reply, {:error, :invalid_message}, state}

      not available?(state) ->
        {:reply, {:error, :unavailable}, %{state | available: false}}

      true ->
        try do
          {reply, state} = operate(request, state)
          {:reply, reply, state}
        rescue
          ArgumentError -> {:reply, {:error, :unavailable}, %{state | available: false}}
        catch
          :exit, _ -> {:reply, {:error, :unavailable}, %{state | available: false}}
        end
    end
  end

  @impl true
  def handle_info({:unit_started, identity, generation, pid}, state) do
    case state.entries[identity] do
      %{generation: ^generation, pid: previous} when previous != pid ->
        # A notification may outlive its PID. Its monitor still prompts
        # supervisor-confirmed removal after an unobserved terminal exit.
        if available?(state) and
             (not Process.alive?(pid) or
                (registered?(state, identity, pid) and owned?(state, pid))) do
          state = clear_incarnation(state, identity)
          {:noreply, install(state, identity, generation, pid)}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:idle, identity, generation, token}, state) do
    case state.entries[identity] do
      %{generation: ^generation, token: ^token} ->
        if available?(state) do
          try do
            {_, state} = sleep(state, identity)
            {:noreply, state}
          catch
            :exit, _ -> {:noreply, %{state | available: false}}
          end
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    if pid in state.infrastructure do
      # Infrastructure replacement requires a fresh subtree, never adoption.
      {:noreply, %{state | available: false}}
    else
      case Enum.find(state.entries, fn {_, entry} -> entry.ref == ref and entry.pid == pid end) do
        {identity, _} ->
          if available?(state) do
            try do
              terminal = reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)
              state = put_in(state.entries[identity].terminal, terminal)
              {_, state} = locate(state, identity)
              {:noreply, state}
            catch
              :exit, _ -> {:noreply, %{state | available: false}}
            end
          else
            {:noreply, state}
          end

        nil ->
          {:noreply, state}
      end
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp operate({:find, identity}, state) do
    case locate(state, identity) do
      {{:live, pid}, state} -> {{:ok, pid}, state}
      {:absent, state} -> {:not_found, state}
      {:busy, state} -> {{:error, :busy}, state}
    end
  end

  defp operate({:start, identity}, state), do: wake(state, identity)
  defp operate({:stop, identity}, state), do: sleep(state, identity)

  defp operate({:route, identity, message}, state) do
    case wake(state, identity, false) do
      {{:ok, pid}, state} ->
        send(pid, message)

        try do
          # Same-sender ordering, not application acceptance or durable delivery.
          DurableUnit.snapshot(pid)
          {{:ok, :routed}, refresh(state, identity)}
        catch
          :exit, _ -> {{:indeterminate, :delivery}, state}
        end

      refused ->
        refused
    end
  end

  defp wake(state, identity, touch \\ true) do
    case locate(state, identity) do
      {{:live, pid}, state} ->
        {{:ok, pid}, if(touch, do: refresh(state, identity), else: state)}

      {:busy, state} ->
        {{:error, :busy}, state}

      {:absent, state} ->
        # A failing callback is translated here, never logged or returned verbatim.
        result =
          try do
            opts = state.unit_options.(identity)

            true =
              Keyword.keyword?(opts) and not Keyword.has_key?(opts, :name) and
                not Keyword.has_key?(opts, :stream)

            opts = opts ++ [stream: identity, name: {:via, Registry, {state.registry, identity}}]
            generation = make_ref()

            spec = %{
              DurableUnit.child_spec(opts)
              | start: {__MODULE__, :start_unit, [self(), identity, generation, opts]}
            }

            {DynamicSupervisor.start_child(state.supervisor, spec), generation}
          catch
            _, _ -> {{:error, :start_failed}, nil}
          end

        case result do
          {{:ok, pid}, generation} ->
            {{:ok, pid}, install(state, identity, generation, pid)}

          {{:error, :max_children}, _} ->
            {{:error, :capacity}, state}

          _ ->
            reply = if available?(state), do: :start_failed, else: :unavailable
            {{:error, reply}, state}
        end
    end
  end

  defp sleep(state, identity) do
    case locate(state, identity) do
      {:absent, state} ->
        {:ok, state}

      {:busy, state} ->
        {{:error, :busy}, state}

      {{:live, pid}, state} ->
        case DynamicSupervisor.terminate_child(state.supervisor, pid) do
          :ok ->
            {:ok, drop(state, identity)}

          {:error, :not_found} ->
            # The supervisor may already have replaced this PID. Never claim
            # that its absence also stopped the replacement.
            case locate(state, identity) do
              {:absent, state} -> {:ok, state}
              {_, state} -> {{:error, :busy}, state}
            end
        end
    end
  end

  defp locate(state, identity) do
    case state.entries[identity] do
      nil ->
        if Registry.whereis_name({state.registry, identity}) == :undefined,
          do: {:absent, state},
          else: {:busy, state}

      entry ->
        children = DynamicSupervisor.which_children(state.supervisor)

        # The supervisor sends startup notifications before its snapshot reply.
        # Reconcile this admission before deciding that its spec disappeared.
        state =
          receive do
            {:unit_started, ^identity, generation, _} = notification
            when generation == entry.generation ->
              {:noreply, state} = handle_info(notification, state)
              state
          after
            0 -> state
          end

        entry = state.entries[identity]

        cond do
          Process.alive?(entry.pid) and registered?(state, identity, entry.pid) and
              Enum.any?(children, &(elem(&1, 1) == entry.pid)) ->
            {{:live, entry.pid}, state}

          Registry.whereis_name({state.registry, identity}) == :undefined and
              not Enum.any?(children, fn child ->
                pid = elem(child, 1)

                # Only a nonterminal admission can have an unlearned replacement.
                pid == entry.pid or (pid == :restarting and not entry.terminal) or
                    (not entry.terminal and is_pid(pid) and
                       not Enum.any?(state.entries, fn {_, e} -> e.pid == pid end))
              end) ->
            {:absent, drop(state, identity)}

          true ->
            {:busy, state}
        end
    end
  end

  defp install(state, identity, generation, pid) do
    entry = %{
      pid: pid,
      generation: generation,
      ref: Process.monitor(pid),
      timer: nil,
      token: nil,
      terminal: false
    }

    refresh(put_in(state.entries[identity], entry), identity)
  end

  defp refresh(state, identity) do
    entry = state.entries[identity]
    if entry.timer, do: Process.cancel_timer(entry.timer)
    token = make_ref()
    deadline = System.monotonic_time(:millisecond) + state.idle_ms

    timer =
      Process.send_after(self(), {:idle, identity, entry.generation, token}, deadline, abs: true)

    put_in(state.entries[identity], %{entry | timer: timer, token: token})
  end

  defp clear_incarnation(state, identity) do
    entry = state.entries[identity]
    Process.demonitor(entry.ref, [:flush])
    Process.cancel_timer(entry.timer)
    state
  end

  defp drop(state, identity) do
    state = clear_incarnation(state, identity)
    %{state | entries: Map.delete(state.entries, identity)}
  end

  defp owned?(state, pid),
    do: Enum.any?(DynamicSupervisor.which_children(state.supervisor), &(elem(&1, 1) == pid))

  defp registered?(state, identity, pid),
    do: Registry.lookup(state.registry, identity) == [{pid, nil}]

  defp available?(state), do: state.available and Enum.all?(state.infrastructure, &Process.alive?/1)

  defp identity?(id),
    do:
      is_binary(id) and byte_size(id) in 1..160 and String.valid?(id) and
        not String.contains?(id, <<0>>)

  defp message?({:durable_unit_input, id, _}), do: identity?(id)
  defp message?(_), do: false
end
