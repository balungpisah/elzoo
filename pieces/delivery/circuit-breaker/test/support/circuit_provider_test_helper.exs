# SPDX-License-Identifier: Apache-2.0
# Destructive scenarios run in a separate BEAM; never restart the parent's fuse.
defmodule Elzoo.CircuitProviderProbe do
  import ExUnit.Assertions
  alias Elzoo.CircuitBreaker, as: C
  @name :circuit_isolated_probe
  @fuse {:elzoo_circuit_breaker, @name}

  def run do
    {:ok, _} = Application.ensure_all_started(:fuse)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    missing_name()
    restart()
    initialization_race()
    grant_race()
    delayed_clock()
    melt_timeout()
    IO.puts("ELZ-100 ISOLATED PROVIDER SCENARIOS PASSED")
  end

  defp owner(opts \\ []) do
    {:ok, pid} =
      C.start_link(
        Keyword.merge([name: @name, cooldown_ms: 1, observation_timeout_ms: 30_000], opts)
      )

    pid
  end

  defp status(pid) do
    {:ok, s} = C.status(pid)
    s
  end

  defp closed(opts \\ []) do
    pid = owner(opts)
    {:ok, p} = C.admit(pid)
    assert C.finish(pid, p, :healthy) == {:ok, :applied}
    pid
  end

  defp wait(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    unless fun.() do
      assert System.monotonic_time(:millisecond) < deadline, "provider probe deadline"
      Process.sleep(5)
      wait(fun, deadline)
    end
  end

  defp restarted(server) do
    Process.exit(server, :kill)

    wait(fn ->
      is_pid(Process.whereis(:fuse_server)) and Process.whereis(:fuse_server) != server
    end)

    assert :fuse.ask(:uninstalled_isolated_probe, :sync) == {:error, :not_found}
  end

  defp waiting(server, tag) do
    wait(fn ->
      {:messages, messages} = Process.info(server, :messages)

      Enum.any?(messages, &match?({:"$gen_call", _, {^tag, _}}, &1)) or
        Enum.any?(messages, &match?({:"$gen_call", _, {^tag, _, _}}, &1))
    end)
  end

  defp missing_name do
    pid = closed()
    {:ok, p} = C.admit(pid)
    assert :fuse.remove(@fuse) == :ok
    # Upstream missing-name melt returns ok; the required ask detects absence.
    assert C.finish(pid, p, :unhealthy) == {:error, :provider_unavailable}
    assert status(pid).mode == :unavailable
    assert C.admit(pid) == {:refused, :provider_unavailable}
    assert :fuse.ask(@fuse, :sync) == {:error, :not_found}
    GenServer.stop(pid)
  end

  defp restart do
    pid = owner()
    {:ok, p} = C.admit(pid)
    restarted(Process.whereis(:fuse_server))
    assert C.admit(pid) == {:refused, :provider_unavailable}
    assert C.finish(pid, p, :healthy) in [{:error, :stale_permit}, {:error, :provider_unavailable}]
    assert status(pid).mode == :unavailable
    GenServer.stop(pid)
    fresh = owner()
    assert status(fresh).mode == :half_open
    assert C.finish(fresh, p, :healthy) == {:error, :invalid_permit}
    {:ok, probe} = C.admit(fresh)
    assert C.finish(fresh, probe, :healthy) == {:ok, :applied}
    GenServer.stop(fresh)
  end

  defp initialization_race do
    server = Process.whereis(:fuse_server)
    :ok = :sys.suspend(server)

    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)
        C.start_link(name: @name)
      end)

    # Registration is visible while init waits for install. A second start
    # must lose without sending an install/reset of its own.
    wait(fn -> is_pid(Process.whereis(@name)) end)
    waiting(server, :install)
    registered = Process.whereis(@name)
    assert C.start_link(name: @name) == {:error, {:already_started, registered}}
    restarted(server)
    assert Task.await(task) == {:error, :provider_unavailable}
    assert :fuse.ask(@fuse, :sync) == {:error, :not_found}
  end

  defp grant_race do
    pid = owner()
    server = Process.whereis(:fuse_server)
    :ok = :sys.suspend(server)
    task = Task.async(fn -> C.admit(pid) end)
    waiting(server, :ask)
    restarted(server)
    assert Task.await(task) == {:refused, :provider_unavailable}
    assert status(pid).mode == :unavailable
    GenServer.stop(pid)
  end

  defp delayed_clock do
    {:ok, clock} = Agent.start_link(fn -> -100 end)

    pid =
      owner(clock: fn -> Agent.get(clock, & &1) end, cooldown_ms: 30, observation_timeout_ms: 10)

    {:ok, p} = C.admit(pid)
    assert C.finish(pid, p, :unknown) == {:ok, :applied}
    Agent.update(clock, fn _ -> -70 end)
    # A real timer, not fake-clock progress, resets upstream.
    wait(fn -> :fuse.ask(@fuse, :sync) == :ok end)
    server = Process.whereis(:fuse_server)
    :ok = :sys.suspend(server)
    parent = self()

    holder =
      spawn_link(fn ->
        answer = C.admit(pid)
        send(parent, {:delayed_answer, answer})

        receive do
          :finish -> send(parent, {:delayed_finish, C.finish(pid, elem(answer, 1), :healthy)})
        end
      end)

    waiting(server, :ask)
    Agent.update(clock, fn _ -> 1_000 end)
    :ok = :sys.resume(server)
    assert_receive {:delayed_answer, {:ok, _}}, 2_000
    # A permit deadline starts from the post-provider sample, not the old -70.
    assert status(pid).mode == :half_open
    send(holder, :finish)
    assert_receive {:delayed_finish, {:ok, :applied}}, 2_000
    assert status(pid).mode == :closed
    {:ok, p} = C.admit(pid)
    server = Process.whereis(:fuse_server)
    :ok = :sys.suspend(server)
    # Holder identity must remain the original caller, so coordinate a resume
    # from a separate process while this process blocks in finish.
    spawn_link(fn ->
      waiting(server, :melt)
      Agent.update(clock, fn _ -> 2_000 end)
      :ok = :sys.resume(server)
    end)

    assert C.finish(pid, p, :unhealthy) == {:ok, :applied}
    assert status(pid).cooldown_remaining_ms == 30
    Agent.update(clock, fn _ -> 2_029 end)
    assert C.admit(pid) == {:refused, :open}
    GenServer.stop(pid)
    Agent.stop(clock)
  end

  defp melt_timeout do
    pid = closed()
    {:ok, p} = C.admit(pid)
    server = Process.whereis(:fuse_server)
    :ok = :sys.suspend(server)

    spawn_link(fn ->
      waiting(server, :melt)
      Process.sleep(5_100)
      :ok = :sys.resume(server)
    end)

    # Both public and upstream calls use 5000 ms. Either timeout may win;
    # neither answer attests no-send, nor may a later reply restore health.
    assert C.finish(pid, p, :unhealthy) in [
             {:unknown, :owner_call_timeout},
             {:error, :provider_unavailable}
           ]

    wait(fn -> status(pid).mode == :unavailable end)
    assert C.admit(pid) == {:refused, :provider_unavailable}
    GenServer.stop(pid)
  end
end

Elzoo.CircuitProviderProbe.run()
