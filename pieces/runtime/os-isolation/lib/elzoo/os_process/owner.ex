# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.OsProcess.Owner do
  @moduledoc """
  One owner process per run. It asks erlexec to spawn the command as a linked,
  group-leading child, accumulates bounded output, decodes the provider's exit report,
  observes the group with `pgrep` after the exit notification and replies to the submitter.
  It never sends a signal; cancellation asks the provider to stop the group.

  Provider protocol (erlexec 2.6.0): `exec:run/2` with `link` links the proxy process to this
  owner and produces no synthetic `'DOWN'`; the proxy forwards `{stdout | stderr, OsPid, Data}`
  and then exits with `normal`, `{exit_status, Status}` or `port_closed`. This owner traps exits,
  monitors the proxy and treats the first of `{:EXIT, proxy, reason}` / `{:DOWN, _, _, proxy, reason}`
  as the terminal event; a `:noproc` monitor result defers to the linked `:EXIT` message.
  """
  use GenServer, restart: :temporary
  alias Elzoo.OsProcess.Result

  @poll_ms 50

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def cancel(owner) do
    GenServer.call(owner, :cancel, 5_000)
  catch
    :exit, _ -> {:error, :unknown_run}
  end

  def caller_down(owner), do: GenServer.cast(owner, :caller_down)

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)
    :ets.insert(args.tid, {args.ref, self(), args.submitter, nil, :spawning})
    Process.monitor(args.submitter)

    state = %{
      tid: args.tid,
      ref: args.ref,
      submitter: args.submitter,
      request: args.request,
      remaining_ms: args.remaining_ms,
      config: args.config,
      proxy: nil,
      mref: nil,
      os_pid: nil,
      output: [],
      bytes: 0,
      truncated: false,
      terminal: nil,
      cancel: nil,
      dropped: false,
      dispatched_at: nil,
      timeout_ms: nil,
      safety: nil,
      observe_until: nil,
      observe_failures: 0,
      saw_members: false
    }

    {:ok, state, {:continue, :spawn}}
  end

  @impl true
  def handle_continue(:spawn, state) do
    request = state.request

    with :ok <- validate_files(request),
         {:ok, timeout} <- effective_timeout(state) do
      env = env_list(request.env)
      argv = Enum.map([request.executable | request.args], &String.to_charlist/1)

      opts =
        [
          {:group, 0},
          :kill_group,
          :link,
          :stdout,
          :stderr,
          {:timeout, timeout},
          {:kill_timeout, state.config.grace_s},
          {:env, env}
        ] ++ if(request.cwd, do: [{:cd, String.to_charlist(request.cwd)}], else: [])

      # Measured before exec:run: the provider's watchdog starts after this instant, so a signal
      # it sends can only be reported at or after started_at + timeout.
      started_at = System.monotonic_time(:millisecond)

      case :exec.run(argv, opts) do
        {:ok, proxy, os_pid} ->
          mref = Process.monitor(proxy)
          run_hook(state, :before_register)
          :ets.insert(state.tid, {state.ref, self(), state.submitter, os_pid, :running})
          run_hook(state, :after_run)
          bound = timeout + state.config.grace_s * 1000 + state.config.observe_timeout_ms
          safety = Process.send_after(self(), :safety, min(bound, 4_294_967_295))

          {:noreply,
           %{
             state
             | proxy: proxy,
               mref: mref,
               os_pid: os_pid,
               dispatched_at: started_at,
               timeout_ms: timeout,
               safety: safety
           }}

        {:error, _reason} ->
          finish(state, Result.rejected(:spawn_failed))
      end
    else
      {:error, :spawn_failed} -> finish(state, Result.rejected(:spawn_failed))
      {:error, :expired} -> finish(state, Result.expired(request))
    end
  end

  @impl true
  def handle_call(:cancel, _from, %{terminal: nil} = state) do
    case state.cancel do
      nil ->
        request_stop(state.os_pid)
        {:reply, {:ok, :requested}, %{state | cancel: :cancel}}

      _ ->
        {:reply, {:ok, :already_requested}, state}
    end
  end

  def handle_call(:cancel, _from, state), do: {:reply, {:error, :unknown_run}, state}

  @impl true
  def handle_cast(:caller_down, state), do: {:noreply, caller_down_state(state)}

  @impl true
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = state),
    do: {:noreply, append(state, data)}

  def handle_info({:stderr, os_pid, data}, %{os_pid: os_pid} = state),
    do: {:noreply, append(state, data)}

  def handle_info({:DOWN, mref, :process, proxy, reason}, %{mref: mref, proxy: proxy} = state) do
    # :noproc means the proxy exited before the monitor existed; the linked :EXIT carries the reason.
    if reason == :noproc, do: {:noreply, state}, else: terminal(state, reason)
  end

  def handle_info({:EXIT, proxy, reason}, %{proxy: proxy} = state), do: terminal(state, reason)

  def handle_info({:DOWN, _mon, :process, submitter, _reason}, %{submitter: submitter} = state),
    do: {:noreply, caller_down_state(state)}

  def handle_info(:safety, %{terminal: nil} = state) do
    request_stop(state.os_pid)
    terminal(state, :no_exit_notification)
  end

  def handle_info(:safety, state), do: {:noreply, state}

  def handle_info(:observe, %{terminal: nil} = state), do: {:noreply, state}

  def handle_info(:observe, state) do
    case members(state.config.pgrep_path, state.os_pid) do
      {:ok, []} ->
        finish(state, build_result(state, {:empty, []}))

      {:ok, pids} ->
        state = %{state | saw_members: true}

        if System.monotonic_time(:millisecond) >= state.observe_until,
          do: finish(state, build_result(state, {:alive, pids})),
          else: schedule_observe(state)

      :failed ->
        if state.observe_failures >= 1,
          do: finish(state, build_result(state, :failed)),
          else: schedule_observe(%{state | observe_failures: state.observe_failures + 1}, 100)
    end
  end

  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # ---- terminal event and observation

  defp terminal(%{terminal: nil} = state, reason) do
    if state.safety, do: Process.cancel_timer(state.safety)
    if state.mref, do: Process.demonitor(state.mref, [:flush])

    state = %{
      state
      | terminal: reason,
        observe_until: System.monotonic_time(:millisecond) + state.config.observe_timeout_ms
    }

    send(self(), :observe)
    {:noreply, state}
  end

  defp terminal(state, _reason), do: {:noreply, state}

  defp schedule_observe(state, delay \\ @poll_ms) do
    Process.send_after(self(), :observe, delay)
    {:noreply, state}
  end

  defp build_result(state, observation) do
    output = IO.iodata_to_binary(Enum.reverse(state.output))
    common = %{output: output, truncated: state.truncated, os_pid: state.os_pid}

    members =
      case observation do
        {:alive, pids} -> pids
        _ -> []
      end

    case {decode(state), observation} do
      {_, :failed} ->
        Result.unknown(
          :observation_failed,
          Map.merge(common, %{cause: state.cancel, exit_code: exit_code(state)})
        )

      {{:unknown, reason}, _} ->
        Result.unknown(
          reason,
          Map.merge(common, %{cause: state.cancel, members: members, exit_code: exit_code(state)})
        )

      {_, {:alive, pids}} ->
        Result.unknown(
          :group_alive,
          Map.merge(common, %{cause: state.cancel, members: pids, exit_code: exit_code(state)})
        )

      {{:completed, code}, {:empty, _}} ->
        leftovers = if state.saw_members, do: :reaped, else: :none
        Result.completed(code, output, state.truncated, leftovers, state.os_pid)

      {{:terminated, stage, signal}, {:empty, _}} ->
        Result.terminated(stage, signal, output, state.truncated, state.os_pid)
    end
  end

  # The provider's exit report decides the outcome; a request issued by this owner never does.
  defp decode(%{terminal: :no_exit_notification}), do: {:unknown, :no_exit_notification}
  defp decode(%{terminal: :port_closed}), do: {:unknown, :port_closed}

  defp decode(%{terminal: :normal, cancel: nil}), do: {:completed, 0}
  defp decode(%{terminal: :normal}), do: {:unknown, :provider_masked_stop}

  defp decode(%{terminal: {:exit_status, status}} = state) do
    case Result.decode_wait_status(status) do
      {:exit, code} ->
        {:completed, code}

      {:signal, sig} when sig in [15, 9] ->
        if deadline_due?(state),
          do:
            {:terminated, if(sig == 15, do: :term, else: :kill),
             if(sig == 15, do: :sigterm, else: :sigkill)},
          else: {:completed, 128 + sig}

      {:signal, sig} ->
        {:completed, 128 + sig}
    end
  end

  defp decode(_state), do: {:unknown, :provider_exit_unknown}

  defp exit_code(%{terminal: {:exit_status, status}}) do
    case Result.decode_wait_status(status) do
      {:exit, code} -> code
      {:signal, sig} -> 128 + sig
    end
  end

  defp exit_code(%{terminal: :normal}), do: 0
  defp exit_code(_), do: nil

  # The provider's watchdog fires at or after started_at + timeout (started_at is taken before
  # exec:run). A SIGTERM or SIGKILL status reported before that instant is not the provider's; one
  # reported at or after it is attributed to the provider, indistinguishable from a self- or
  # externally signalled command ending after that instant (declared residual).
  defp deadline_due?(state),
    do: System.monotonic_time(:millisecond) >= state.dispatched_at + state.timeout_ms

  defp finish(state, result) do
    unless state.dropped, do: send(state.submitter, {Elzoo.OsProcess, state.ref, result})
    :ets.insert(state.tid, {state.ref, self(), state.submitter, state.os_pid, :finished})
    {:stop, :normal, state}
  end

  defp caller_down_state(%{terminal: nil, cancel: nil} = state) do
    if state.os_pid, do: request_stop(state.os_pid)
    %{state | cancel: :caller_down, dropped: true}
  end

  defp caller_down_state(state), do: %{state | dropped: true}

  # exec:stop/1 is a 30 s call into the provider; a stuck provider must not block this owner.
  # The request is acceptance only; its effect is observed through the exit report and pgrep.
  defp request_stop(os_pid) do
    spawn(fn ->
      try do
        :exec.stop(os_pid)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  defp append(state, data) do
    size = byte_size(data)
    room = state.config.max_output_bytes - state.bytes

    cond do
      room <= 0 ->
        %{state | truncated: true}

      size <= room ->
        %{state | output: [data | state.output], bytes: state.bytes + size}

      true ->
        %{
          state
          | output: [binary_part(data, 0, room) | state.output],
            bytes: state.bytes + room,
            truncated: true
        }
    end
  end

  # ---- dispatch-time checks

  defp validate_files(request) do
    exe_ok =
      case File.stat(request.executable) do
        {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
        _ -> false
      end

    cwd_ok = request.cwd == nil or File.dir?(request.cwd)
    if exe_ok and cwd_ok, do: :ok, else: {:error, :spawn_failed}
  end

  defp effective_timeout(state) do
    candidates = Enum.reject([state.remaining_ms, state.request.max_run_ms], &is_nil/1)
    timeout = Enum.min(candidates)
    if timeout <= 0, do: {:error, :expired}, else: {:ok, timeout}
  end

  defp env_list(%{inherit: inherit, set: set}) do
    inherited =
      Enum.flat_map(inherit, fn name ->
        case System.get_env(name) do
          nil -> []
          value -> [{String.to_charlist(name), String.to_charlist(value)}]
        end
      end)

    [
      :clear
      | inherited ++ Enum.map(set, fn {n, v} -> {String.to_charlist(n), String.to_charlist(v)} end)
    ]
  end

  defp run_hook(state, name) do
    case Map.get(state.config.test_hooks, name) do
      nil -> :ok
      fun -> fun.()
    end
  end

  # ---- group observation (pgrep is observation only; it never causes a signal)

  @doc false
  def members(pgrep_path, os_pid) do
    case System.cmd(pgrep_path, ["-g", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out |> String.split("\n", trim: true) |> Enum.flat_map(&parse_pid/1)}
      {_, 1} -> {:ok, []}
      {_, _} -> :failed
    end
  rescue
    _ -> :failed
  end

  defp parse_pid(line) do
    case Integer.parse(String.trim(line)) do
      {pid, ""} -> [pid]
      _ -> []
    end
  end

  @doc false
  def observe_until_empty(pgrep_path, os_pid, bound_ms) do
    deadline = System.monotonic_time(:millisecond) + bound_ms
    do_observe(pgrep_path, os_pid, deadline, 0)
  end

  defp do_observe(pgrep_path, os_pid, deadline, failures) do
    case members(pgrep_path, os_pid) do
      {:ok, []} ->
        []

      {:ok, pids} ->
        if System.monotonic_time(:millisecond) >= deadline do
          pids
        else
          Process.sleep(@poll_ms)
          do_observe(pgrep_path, os_pid, deadline, failures)
        end

      :failed when failures >= 1 ->
        :observation_failed

      :failed ->
        Process.sleep(100)
        do_observe(pgrep_path, os_pid, deadline, failures + 1)
    end
  end
end
