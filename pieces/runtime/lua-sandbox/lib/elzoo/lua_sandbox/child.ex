# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandbox.Child do
  @moduledoc false
  # One short-lived Port owner per exchange. It is not linked to the caller, traps
  # exits and monitors the caller, so an exit of the Port (for example a write into a
  # closed child input) is a message to the owner and never a signal to the caller.
  # The caller holds the absolute deadline and waits for the end of the owner. The
  # child is killed by OS pid and reaped on every path, also when the caller dies.
  # No GenServer, no pool.

  alias Elzoo.LuaSandbox.Json

  @reap_ms 5_000

  @doc """
  Returns `{:frame, body}`, or `{:host_outcome, :wall_time | :process_exit | :protocol_error}`.
  """
  def exchange(executable, frame, deadline) do
    caller = self()
    ref = make_ref()

    case start_owner(fn -> own(caller, ref, executable, frame) end) do
      {:ok, owner, monitor} -> await_owner(owner, monitor, ref, deadline)
      :error -> {:host_outcome, :process_exit}
    end
  end

  # The start of the owner is the start of the child: its failure is a host outcome,
  # as a failed `Port.open` is.
  defp start_owner(fun) do
    {owner, monitor} = spawn_monitor(fun)
    {:ok, owner, monitor}
  rescue
    SystemLimitError -> :error
  end

  defp await_owner(owner, monitor, ref, deadline) do
    {outcome, down?} =
      receive do
        {^ref, result} -> {result, false}
        {:DOWN, ^monitor, :process, _, _} -> {{:host_outcome, :process_exit}, true}
      after
        max(0, deadline - System.monotonic_time(:millisecond)) ->
          send(owner, {ref, :stop})
          {{:host_outcome, :wall_time}, false}
      end

    # The owner reaps the child before it ends: no child and no process is left.
    unless down? do
      receive do
        {:DOWN, ^monitor, :process, _, _} -> :ok
      end
    end

    receive do
      {^ref, _} -> :ok
    after
      0 -> :ok
    end

    outcome
  end

  defp own(caller, ref, executable, frame) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)
    env = for {name, _} <- System.get_env(), do: {String.to_charlist(name), false}

    result =
      try do
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [],
            env: env
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        run(port, os_pid, {ref, caller_monitor}, frame)
      rescue
        _ in [ErlangError, ArgumentError] -> {:host_outcome, :process_exit}
      end

    if result, do: send(caller, {ref, result})
  end

  # nil: stopped by the caller, or the caller died; there is no result to send
  defp run(port, os_pid, stop, frame) do
    # `send` keeps a stalled child from suspending the owner: it still sees a stop.
    send(port, {self(), {:command, frame}})
    await(port, stop, <<>>, nil)
  after
    reap(port, os_pid)
  end

  # frame: nil while no complete frame was seen, else the body
  defp await(port, {ref, caller_monitor} = stop, acc, frame) do
    receive do
      {^port, {:data, data}} ->
        if frame != nil,
          do: {:host_outcome, :protocol_error},
          else: read_frame(port, stop, acc <> data)

      {^port, {:exit_status, status}} ->
        Process.put(:port_end, :reported)
        exited(status, acc, frame)

      # the Port ended with no exit report (a write into a closed child input)
      {:EXIT, ^port, _reason} ->
        Process.put(:port_end, :no_report)

        if frame == nil and acc != <<>>,
          do: {:host_outcome, :protocol_error},
          else: {:host_outcome, :process_exit}

      {^ref, :stop} ->
        nil

      {:DOWN, ^caller_monitor, :process, _, _} ->
        nil
    end
  end

  defp read_frame(port, stop, acc) when byte_size(acc) < 4, do: await(port, stop, acc, nil)

  defp read_frame(port, stop, <<length::unsigned-little-32, rest::binary>> = acc) do
    cond do
      length == 0 or length > Json.frame_max() -> {:host_outcome, :protocol_error}
      byte_size(rest) < length -> await(port, stop, acc, nil)
      byte_size(rest) > length -> {:host_outcome, :protocol_error}
      true -> await(port, stop, acc, rest)
    end
  end

  defp exited(0, _acc, frame) when is_binary(frame), do: {:frame, frame}
  defp exited(_status, _acc, frame) when is_binary(frame), do: {:host_outcome, :process_exit}
  defp exited(0, acc, nil) when byte_size(acc) > 0, do: {:host_outcome, :protocol_error}
  defp exited(_status, _acc, nil), do: {:host_outcome, :process_exit}

  # Kill by OS pid and wait until the child is gone. One absolute deadline bounds the
  # whole reap to `@reap_ms`.
  defp reap(port, os_pid) do
    until = System.monotonic_time(:millisecond) + @reap_ms

    case {Process.get(:port_end), Port.info(port)} do
      {:reported, _} ->
        :ok

      {_, nil} ->
        kill(os_pid)
        wait_gone(os_pid, until)

      {_, _} ->
        kill(os_pid)

        receive do
          {^port, {:exit_status, _}} -> :ok
          {:EXIT, ^port, _} -> wait_gone(os_pid, until)
        after
          max(0, until - System.monotonic_time(:millisecond)) ->
            if Port.info(port), do: Port.close(port)
        end
    end
  end

  defp kill(os_pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
  end

  # A Port that ended with no exit report cannot say when the child is reaped.
  defp wait_gone(os_pid, until), do: poll_gone(Integer.to_string(os_pid), until)

  defp poll_gone(os_pid, until) do
    case System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true) do
      {_, 0} ->
        if System.monotonic_time(:millisecond) < until do
          Process.sleep(5)
          poll_gone(os_pid, until)
        end

      _ ->
        :ok
    end
  end
end
