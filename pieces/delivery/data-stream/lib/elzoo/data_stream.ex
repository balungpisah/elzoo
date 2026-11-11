# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DataStream do
  @moduledoc """
  One caller-scoped Anthropic text stream per locally retained admission.
  Construction is fixed; provide an actual EffectIntent Store/activation host.
  Read the adjacent README for authority, clock, cleanup and accounting limits.
  """
  use GenServer
  alias Elzoo.DataStream.{Config, Handle, Request, Session, Terminal}

  defstruct [
    :config,
    :generation,
    :capacity,
    allow_volatile: false,
    seam: :production,
    entries: %{}
  ]

  @wait 1_000
  def start_link(settings), do: construct(settings, :production)
  @doc false
  def __start_loopback__(settings, origin, ca \\ nil),
    do: construct(settings, {:loopback, origin, ca})

  defp construct(settings, seam) do
    caller = self()

    with {:ok, c, volatile} <- Config.load(settings, caller) do
      Elzoo.DataStream.Transport.endpoint(seam)

      case GenServer.start_link(__MODULE__, {c, volatile, seam}) do
        {:ok, _} = ok -> ok
        _ -> {:error, :unavailable}
      end
    end
  rescue
    _ -> {:error, :configuration}
  catch
    _, _ -> {:error, :unavailable}
  end

  def start(owner, effect, sink) do
    wall = System.system_time(:millisecond)
    mono = System.monotonic_time(:millisecond)
    call(owner, {:start, effect, sink, wall, mono}, :start)
  end

  def lookup(owner, id), do: call(owner, {:lookup, id}, :read)
  def status(owner, handle), do: call(owner, {:status, handle}, :read)
  def result(owner, handle), do: call(owner, {:result, handle}, :read)
  def cancel(owner, handle), do: call(owner, {:cancel, handle}, :control)
  def close(owner, handle), do: call(owner, {:close, handle}, :control)

  defp call(owner, msg, kind) when is_pid(owner) and node(owner) == node() do
    GenServer.call(owner, msg, @wait)
  catch
    :exit, {:timeout, _} ->
      case kind do
        :start -> {:unknown, :admission}
        :control -> {:unknown, :control}
        :read -> {:error, :timeout}
      end

    :exit, _ ->
      {:error, :unavailable}
  end

  defp call(_, _, _), do: {:error, :invalid_argument}
  @impl true
  def init({c, volatile, seam}) do
    Process.flag(:trap_exit, true)
    {:ok, capacity} = Elzoo.Backpressure.new(c.capacity)

    {:ok,
     %__MODULE__{
       config: c,
       allow_volatile: volatile,
       seam: seam,
       generation: make_ref(),
       capacity: capacity
     }}
  end

  @impl true
  def handle_call({:start, effect, sink, wall, mono}, {caller, _}, s) do
    s = expire(s)

    cond do
      caller not in s.config.authorized_callers ->
        {:reply, {:error, :unauthorized}, s}

      not is_function(sink, 1) ->
        {:reply, {:error, :invalid_argument}, s}

      true ->
        case known_entry(s, effect) do
          nil ->
            case Request.prepare(effect, s.config.models, wall, mono, s.config.total_timeout_ms) do
              {:ok, p} -> admit(s, caller, effect, sink, p)
              {:error, r} -> {:reply, {:refused, r}, s}
            end

          _ ->
            # Reinspection of an exact retained declaration remains possible
            # after its original deadline; this never authorizes new dispatch.
            admit(s, caller, effect, sink, %{command: effect["command"]})
        end
    end
  end

  def handle_call({:lookup, id}, {caller, _}, s) do
    s = expire(s)

    reply =
      if Request.id?(id) do
        case Enum.find_value(s.entries, fn {_, e} ->
               if e.caller == caller and e.message_id == id, do: e.handle
             end) do
          nil -> {:error, :not_found}
          h -> {:ok, h}
        end
      else
        {:error, :invalid_argument}
      end

    {:reply, reply, s}
  end

  def handle_call({op, h}, {caller, _}, s) when op in [:status, :result, :cancel, :close] do
    s = expire(s)

    case entry(s, h, caller) do
      {:error, r} ->
        {:reply, {:error, r}, s}

      {:ok, e} ->
        case op do
          :status ->
            {:reply, {:ok, Terminal.snapshot(e.terminal, e.phase)}, s}

          :result ->
            {:reply, if(e.phase == :retained, do: {:ok, e.terminal}, else: {:pending, e.phase}), s}

          :cancel ->
            if e.phase == :retained or e.terminal.delivery_complete do
              {:reply, {:ok, :already_terminal}, s}
            else
              GenServer.cast(e.session, :cancel)
              {:reply, {:ok, :pending}, s}
            end

          :close ->
            if e.phase == :retained do
              {:reply, {:ok, :closed}, remove(s, h.ref)}
            else
              GenServer.cast(e.session, :cancel)
              {:reply, {:ok, :pending}, s}
            end
        end
    end
  end

  def handle_call(_, _, s), do: {:reply, {:error, :invalid_argument}, s}

  defp known_entry(s, %{"command" => %{"message_id" => id, "idempotency_key" => logical}}) do
    if Request.id?(id) and Request.id?(logical) do
      Enum.find_value(s.entries, fn {_, e} ->
        if e.message_id == id or e.logical_ref == logical, do: e
      end)
    end
  end

  defp known_entry(_, _), do: nil

  defp admit(s, caller, effect, sink, p) do
    c = p.command

    existing = known_entry(s, effect)

    cond do
      existing && existing.caller != caller ->
        {:reply, {:error, :unauthorized}, s}

      existing &&
          (existing.effect !=
             :crypto.hash(:sha256, :erlang.term_to_binary(effect, [:deterministic])) or
             existing.sink != sink) ->
        {:reply, {:refused, :identity_conflict}, s}

      existing ->
        {:reply, {:ok, existing.handle}, s}

      true ->
        case Elzoo.Backpressure.admit(s.capacity) do
          {:ok, _, :saturated} ->
            {:reply, {:refused, :saturated}, s}

          {:ok, capacity, :admitted} ->
            h = %Handle{owner: self(), generation: s.generation, ref: make_ref()}

            opts = [
              owner: self(),
              caller: caller,
              handle: h,
              config: s.config,
              prepared: Map.put(p, :sink, sink),
              allow_volatile: s.allow_volatile,
              seam: s.seam
            ]

            case Session.start_link(opts) do
              {:ok, pid} ->
                sup = Session.custody(pid)

                e = %{
                  caller: caller,
                  handle: h,
                  session: pid,
                  session_ref: Process.monitor(pid),
                  sup: sup,
                  sup_ref: Process.monitor(sup),
                  caller_ref: Process.monitor(caller),
                  session_down: false,
                  sup_down: false,
                  settled: false,
                  dead_caller: false,
                  phase: :preparing,
                  terminal: %Terminal{},
                  effect: :crypto.hash(:sha256, :erlang.term_to_binary(effect, [:deterministic])),
                  sink: sink,
                  message_id: c["message_id"],
                  logical_ref: c["idempotency_key"],
                  expires: nil
                }

                s = %{s | capacity: capacity, entries: Map.put(s.entries, h.ref, e)}
                GenServer.cast(pid, :go)
                {:reply, {:ok, h}, s}

              _ ->
                {:reply, {:refused, :unavailable}, s}
            end
        end
    end
  end

  defp entry(s, %Handle{owner: owner, generation: gen, ref: ref}, caller)
       when is_pid(owner) and is_reference(gen) and is_reference(ref) do
    case Map.get(s.entries, ref) do
      nil -> {:error, :not_found}
      _e when owner != self() or gen != s.generation -> {:error, :not_found}
      e when e.caller != caller -> {:error, :unauthorized}
      e -> {:ok, e}
    end
  end

  defp entry(_, _, _), do: {:error, :invalid_argument}
  @impl true
  def handle_info({:summary, ref, phase, t}, s) do
    {:noreply,
     update(s, ref, fn e ->
       if e.phase == :retained, do: e, else: %{e | phase: phase, terminal: t}
     end)}
  end

  def handle_info({:settled, ref, t}, s) do
    {:noreply, s |> update(ref, &%{&1 | settled: true, terminal: t}) |> retain(ref)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, s) do
    case Enum.find(s.entries, fn {_, e} -> ref in [e.session_ref, e.sup_ref, e.caller_ref] end) do
      nil ->
        {:noreply, s}

      {key, e} ->
        cond do
          ref == e.caller_ref ->
            if e.phase == :retained do
              {:noreply, remove(s, key)}
            else
              GenServer.cast(e.session, :cancel)
              {:noreply, update(s, key, &%{&1 | dead_caller: true})}
            end

          ref == e.sup_ref ->
            {:noreply, s |> update(key, &%{&1 | sup_down: true}) |> retain(key)}

          true ->
            e = %{e | session_down: true}

            e =
              if e.settled,
                do: e,
                else: %{
                  e
                  | phase: :stopping,
                    terminal: %{
                      e.terminal
                      | status: :partial,
                        reason: :session_lost,
                        delivery_complete: false,
                        intent_confirmation:
                          if(e.terminal.intent_confirmation == :no_attempt,
                            do: :no_attempt,
                            else: :unconfirmed
                          )
                    }
                }

            if not e.sup_down, do: Process.send_after(self(), {:reap, key, e.sup}, 1_000)
            {:noreply, %{s | entries: Map.put(s.entries, key, e)} |> retain(key)}
        end
    end
  end

  def handle_info({:reap, ref, pid}, s) do
    if match?(%{phase: :stopping, sup: ^pid}, s.entries[ref]) and Process.alive?(pid),
      do: Process.exit(pid, :kill)

    {:noreply, s}
  end

  def handle_info(:expire, s), do: {:noreply, expire(s)}
  def handle_info(_, s), do: {:noreply, s}

  defp retain(s, ref) do
    case s.entries[ref] do
      %{session_down: true, sup_down: true, phase: p} = e when p != :retained ->
        if e.dead_caller do
          remove(s, ref)
        else
          t = e.terminal
          true = Terminal.size(t) <= 4096
          send(e.caller, {:data_stream_terminal, ref, t})
          Process.send_after(self(), :expire, 5_000)

          update(
            s,
            ref,
            &%{
              &1
              | phase: :retained,
                expires: System.monotonic_time(:millisecond) + 5_000
            }
          )
        end

      _ ->
        s
    end
  end

  defp update(s, ref, fun),
    do:
      if(Map.has_key?(s.entries, ref),
        do: %{s | entries: Map.update!(s.entries, ref, fun)},
        else: s
      )

  defp expire(s) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(s.entries, s, fn {ref, e}, acc ->
      if e.phase == :retained and e.expires <= now, do: remove(acc, ref), else: acc
    end)
  end

  defp remove(s, ref) do
    case Map.pop(s.entries, ref) do
      {nil, _} ->
        s

      {e, entries} ->
        Enum.each([e.session_ref, e.sup_ref, e.caller_ref], &Process.demonitor(&1, [:flush]))
        {:ok, capacity} = Elzoo.Backpressure.release(s.capacity)
        %{s | entries: entries, capacity: capacity}
    end
  end

  @impl true
  def format_status(status),
    do: Map.new(status, fn {k, _} -> {k, if(k == :log, do: [], else: :redacted)} end)
end

defimpl Inspect, for: Elzoo.DataStream do
  def inspect(_, _), do: "#DataStream.Owner<redacted>"
end
