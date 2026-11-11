# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CircuitProviderTest do
  use ExUnit.Case, async: true

  @tag timeout: 60_000
  test "C12 actual provider restarts, startup/grant races, post-call clock and melt timeout in a private BEAM" do
    server = Process.whereis(:fuse_server)

    paths = [
      Application.app_dir(:fuse, "ebin"),
      Application.app_dir(:telemetry, "ebin"),
      Elzoo.CircuitBreaker |> :code.which() |> List.to_string() |> Path.dirname()
    ]

    args =
      Enum.flat_map(paths, &["-pa", &1]) ++
        [Path.expand("../support/circuit_provider_test_helper.exs", __DIR__)]

    port =
      Port.open(
        {:spawn_executable, System.find_executable("elixir")},
        [:binary, :exit_status, :stderr_to_stdout, args: args]
      )

    try do
      {output, exit} = collect(port, "", System.monotonic_time(:millisecond) + 45_000)
      assert exit == 0, output
      assert output =~ "ELZ-100 ISOLATED PROVIDER SCENARIOS PASSED"
      assert Process.whereis(:fuse_server) == server
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp collect(port, output, deadline) do
    receive do
      {^port, {:data, bytes}} -> collect(port, output <> bytes, deadline)
      {^port, {:exit_status, status}} -> {output, status}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        flunk("provider probe deadline: #{output}")
    end
  end
end
