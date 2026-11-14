# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaSandbox.Child do
  @moduledoc false
  # The caller-held Port owner: spawn one child, write one frame, read exactly
  # one reply frame under an absolute monotonic deadline, and reap the child on
  # every return path. No GenServer, no pool.

  alias Elzoo.LuaSandbox.Json

  @reap_ms 5_000

  @doc """
  Returns `{:frame, body}`, or `{:host_outcome, :wall_time | :process_exit | :protocol_error}`.
  """
  def exchange(executable, frame, deadline) do
    env = for {name, _} <- System.get_env(), do: {String.to_charlist(name), false}

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [],
        env: env
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    try do
      # `send` keeps a stalled child from suspending the caller past the deadline.
      send(port, {self(), {:command, frame}})
      await(port, deadline, <<>>, nil)
    after
      reap(port, os_pid)
    end
  rescue
    _ in [ErlangError, ArgumentError] -> {:host_outcome, :process_exit}
  end

  # frame: nil while no complete frame was seen, else the body
  defp await(port, deadline, acc, frame) do
    wait = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, data}} ->
        if frame != nil,
          do: {:host_outcome, :protocol_error},
          else: read_frame(port, deadline, acc <> data)

      {^port, {:exit_status, status}} ->
        exited(status, acc, frame)
    after
      wait -> {:host_outcome, :wall_time}
    end
  end

  defp read_frame(port, deadline, acc) when byte_size(acc) < 4, do: await(port, deadline, acc, nil)

  defp read_frame(port, deadline, <<length::unsigned-little-32, rest::binary>> = acc) do
    cond do
      length == 0 or length > Json.frame_max() -> {:host_outcome, :protocol_error}
      byte_size(rest) < length -> await(port, deadline, acc, nil)
      byte_size(rest) > length -> {:host_outcome, :protocol_error}
      true -> await(port, deadline, acc, rest)
    end
  end

  defp exited(0, _acc, frame) when is_binary(frame), do: {:frame, frame}
  defp exited(_status, _acc, frame) when is_binary(frame), do: {:host_outcome, :process_exit}
  defp exited(0, acc, nil) when byte_size(acc) > 0, do: {:host_outcome, :protocol_error}
  defp exited(_status, _acc, nil), do: {:host_outcome, :process_exit}

  # Kill by OS pid and wait for the exit report: the child is gone afterwards.
  defp reap(port, os_pid) do
    if Port.info(port) do
      System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        @reap_ms -> if Port.info(port), do: Port.close(port)
      end
    end

    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end
end
