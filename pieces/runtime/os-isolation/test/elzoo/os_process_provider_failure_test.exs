# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.OsProcessProviderFailureTest do
  @moduledoc """
  Provider-level failures (rows T24 and T25): the erlexec application stopping, and its port
  program dying. Each test restores the provider application before it ends.
  """
  use ExUnit.Case, async: false
  alias Elzoo.OsProcess

  @sh "/bin/sh"
  @fixture Path.join(__DIR__, "os_process_fixture.sh")
  @pgrep System.find_executable("pgrep")
  @kill System.find_executable("kill")
  @moduletag timeout: 60_000
  @moduletag capture_log: true

  setup do
    :ok = Elzoo.OsProcess.Provider.ensure_started()
    on_exit(fn -> :ok = Elzoo.OsProcess.Provider.ensure_started() end)
    :ok
  end

  defp members(os_pid) do
    case System.cmd(@pgrep, ["-g", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&String.to_integer/1)
      {_, 1} -> []
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if fun.(),
        do: :ok,
        else:
          (
            Process.sleep(25)
            :wait
          )
    end)
    |> Enum.find(fn r -> r == :ok or System.monotonic_time(:millisecond) >= deadline end)
  end

  defp os_pid_of(sup, ref) do
    :ok =
      wait_until(fn -> match?(%{os_pid: p} when is_integer(p), OsProcess.info(sup, ref)) end, 5_000)

    OsProcess.info(sup, ref).os_pid
  end

  test "T24 stopping the provider application makes its port program stop every child (VM-exit analogue)" do
    sup =
      start_supervised!(
        {OsProcess, max_concurrent: 1, queue_limit: 0, queue_timeout_ms: 1_000, grace_s: 1}
      )

    {:ok, ref} =
      OsProcess.submit(sup, %{executable: @sh, args: [@fixture, "child", "30"]}, max_run_ms: 20_000)

    os_pid = os_pid_of(sup, ref)
    assert :ok = wait_until(fn -> length(members(os_pid)) >= 2 end, 2_000)
    :ok = Application.stop(:erlexec)

    # The provider's finalize stops the child; its proxy exits with port_closed, which the owner
    # reports after its own observation.
    assert_receive {OsProcess, ^ref, %{status: :unknown, reason: :port_closed, os_pid: ^os_pid}},
                   10_000

    assert :ok = wait_until(fn -> members(os_pid) == [] end, 5_000)
  end

  test "T25 the port program killed with SIGKILL orphans the child: unknown{port_closed} with the observed members" do
    sup =
      start_supervised!(
        {OsProcess,
         max_concurrent: 1,
         queue_limit: 0,
         queue_timeout_ms: 1_000,
         grace_s: 1,
         observe_timeout_ms: 500}
      )

    {:ok, ref} =
      OsProcess.submit(sup, %{executable: @sh, args: [@fixture, "sleep", "30"]}, max_run_ms: 20_000)

    os_pid = os_pid_of(sup, ref)
    # Only this VM's port program: its OS pid comes from the provider server's Port, never from a
    # name match, so no other VM on the host is touched.
    port = :sys.get_state(:exec) |> elem(1)
    {:os_pid, port_os_pid} = :erlang.port_info(port, :os_pid)
    on_exit(fn -> System.cmd(@kill, ["-s", "KILL", "--", "-#{os_pid}"], stderr_to_stdout: true) end)

    {_, 0} =
      System.cmd(@kill, ["-s", "KILL", Integer.to_string(port_os_pid)], stderr_to_stdout: true)

    assert_receive {OsProcess, ^ref,
                    %{status: :unknown, reason: :port_closed, members: members, os_pid: ^os_pid}},
                   10_000

    assert members != [], "the orphaned child is reported, not hidden"
    System.cmd(@kill, ["-s", "KILL", "--", "-#{os_pid}"], stderr_to_stdout: true)
    assert :ok = wait_until(fn -> members(os_pid) == [] end, 5_000)
  end
end
