# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Elz099FuseProviderTest do
  use ExUnit.Case, async: true

  test "F1 runtime fuse 2.5.0 trips, resets without a recovery probe, and removes a unique name" do
    assert Application.spec(:fuse, :vsn) == ~c"2.5.0"
    assert List.keymember?(Application.started_applications(), :fuse, 0)

    # A reference makes the name unique without creating unbounded atoms.
    name = {__MODULE__, make_ref()}
    on_exit(fn -> :fuse.remove(name) end)

    assert :fuse.install(name, {{:standard, 0, 1_000}, {:reset, 1_000}}) == :ok
    assert :fuse.ask(name, :sync) == :ok
    assert :fuse.melt(name) == :ok
    assert :fuse.ask(name, :sync) == :blown

    deadline = System.monotonic_time(:millisecond) + 5_000
    await_reset(name, deadline)

    # All 32 callers are ready before release. No protected operation, health
    # result, or melt occurs: cooldown alone admits every ask in this sample.
    parent = self()

    callers =
      for _ <- 1..32 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :ask -> :fuse.ask(name, :sync)
          after
            5_000 -> flunk("concurrent ask was not released")
          end
        end)
      end

    for %{pid: pid} <- callers, do: assert_receive({:ready, ^pid}, 5_000)
    for %{pid: pid} <- callers, do: send(pid, :ask)
    answers = Enum.map(callers, &Task.await(&1, 5_000))
    assert Enum.frequencies(answers) == %{ok: 32}

    assert :fuse.remove(name) == :ok
    assert :fuse.ask(name, :sync) == {:error, :not_found}
    IO.puts("ELZ-099 F1: fuse=2.5.0 fresh=ok melt=blown cooldown_asks=32/32 removed=not_found")
  end

  test "F2 missing melt and volatile provider restart are checked in a separate BEAM" do
    server = Process.whereis(:fuse_server)
    assert is_pid(server)

    # Only the built provider's ebin is injected; no source compilation or root
    # application startup occurs in the destructive probe.
    script = Path.expand("support/elz099_fuse_restart_test_helper.exs", __DIR__)
    ebin = Application.app_dir(:fuse, "ebin")

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-pa", ebin, script]
      ])

    try do
      {output, status} = read_probe(port, "", System.monotonic_time(:millisecond) + 20_000)
      assert status == 0, output
      assert output =~ "ELZ-099 F2: missing_melt=ok missing_ask=not_found"
      assert output =~ "ELZ-099 F2: provider_restarted=true installed_name_after_restart=not_found"
      assert output =~ "ELZ-099 ISOLATED FUSE PROBE PASSED"
      assert Process.whereis(:fuse_server) == server
      IO.write(output)
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp await_reset(name, deadline) do
    case :fuse.ask(name, :sync) do
      :ok ->
        :ok

      :blown ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("fuse did not reset before the 5-second deadline")

        Process.sleep(10)
        await_reset(name, deadline)

      other ->
        flunk("unexpected ask during reset: #{inspect(other)}")
    end
  end

  defp read_probe(port, output, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, bytes}} -> read_probe(port, output <> bytes, deadline)
      {^port, {:exit_status, status}} -> {output, status}
    after
      remaining -> flunk("isolated fuse probe exceeded 20 seconds: #{output}")
    end
  end
end
