# SPDX-License-Identifier: Apache-2.0
# Destructive probe: invoked only by elz099_fuse_provider_test.exs in its own VM.
defmodule Elzoo.Elz099FuseRestartProbe do
  import ExUnit.Assertions

  def run do
    {:ok, _} = Application.ensure_all_started(:fuse)
    assert Application.spec(:fuse, :vsn) == ~c"2.5.0"
    name = {__MODULE__, make_ref()}

    try do
      assert :fuse.ask(name, :sync) == {:error, :not_found}
      assert :fuse.melt(name) == :ok
      assert :fuse.ask(name, :sync) == {:error, :not_found}
      IO.puts("ELZ-099 F2: missing_melt=ok missing_ask=not_found")

      assert :fuse.install(name, {{:standard, 0, 1_000}, {:reset, 60_000}}) == :ok
      assert :fuse.ask(name, :sync) == :ok
      assert :fuse.melt(name) == :ok
      assert :fuse.ask(name, :sync) == :blown

      server = Process.whereis(:fuse_server)
      assert is_pid(server)
      monitor = Process.monitor(server)
      Process.exit(server, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^server, :killed}, 5_000
      await_replacement(server, System.monotonic_time(:millisecond) + 5_000)
      assert :fuse.ask(name, :sync) == {:error, :not_found}
      IO.puts("ELZ-099 F2: provider_restarted=true installed_name_after_restart=not_found")
      IO.puts("ELZ-099 ISOLATED FUSE PROBE PASSED")
    after
      :fuse.remove(name)
      Application.stop(:fuse)
    end
  end

  defp await_replacement(old, deadline) do
    case Process.whereis(:fuse_server) do
      pid when is_pid(pid) and pid != old ->
        # A call also waits for the registered replacement to finish init.
        assert :fuse.ask({__MODULE__, :absent}, :sync) == {:error, :not_found}

      _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("fuse server did not restart before the 5-second deadline")

        Process.sleep(10)
        await_replacement(old, deadline)
    end
  end
end

Elzoo.Elz099FuseRestartProbe.run()
