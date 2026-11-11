# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Observability.CopyTest do
  use ExUnit.Case, async: false

  @tag timeout: 180_000
  test "actual source-copy closure runs in a clean consumer without root Application" do
    if Code.ensure_loaded?(Elzoo.Registry) do
      destination =
        Path.join(System.tmp_dir!(), "elz106-copy-#{System.unique_integer([:positive])}")

      File.mkdir_p!(destination)
      on_exit(fn -> File.rm_rf!(destination) end)

      File.write!(Path.join(destination, "mix.exs"), """
      defmodule ObservabilityConsumer.MixProject do
        use Mix.Project
        def project, do: [app: :observability_consumer, version: "0.1.0", deps: [], prune_code_paths: false, test_ignore_filters: [~r/test_helper.exs$/], elixirc_options: [warnings_as_errors: true]]
        def application, do: [extra_applications: [:logger, :crypto, :prometheus, :telemetry]]
      end
      """)

      File.mkdir_p!(Path.join(destination, "test"))
      File.write!(Path.join(destination, "test/test_helper.exs"), "ExUnit.start(seed: 0)\n")

      registry = Elzoo.Registry.load!()
      piece = Path.expand("../../piece.json", __DIR__) |> File.read!() |> Jason.decode!()
      piece = Map.put(piece, "directory", "pieces/integration/observability")

      registry = %{
        registry
        | entries: Map.put(registry.entries, "integration/observability", piece)
      }

      plan = Elzoo.Export.plan!(registry, ["integration/observability"], destination)
      Elzoo.Export.write!(plan)

      assert Enum.sort(Enum.map(plan.pieces, & &1["id"])) == [
               "integration/observability",
               "runtime/telemetry"
             ]

      assert Enum.sort(Map.keys(plan.providers)) == ~w(ddskerl elixir otp prometheus telemetry)
      for {path, bytes} <- plan.files, do: assert(File.read!(Path.join(destination, path)) == bytes)

      # Only declared applications and their required upstream closure, not
      # root's code paths or Application, are available to the independent VM.
      apps = closure([:logger, :crypto, :prometheus, :telemetry], MapSet.new())
      refute :elzoo in apps
      paths = Enum.map(apps, &Application.app_dir(&1, "ebin"))
      args = Enum.flat_map(paths, &["-pa", &1]) ++ ["examples/observability_copied_consumer.exs"]

      port =
        Port.open({:spawn_executable, System.find_executable("elixir")}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          cd: destination,
          args: args,
          env: [
            {~c"MIX_ENV", ~c"test"},
            {~c"MIX_BUILD_PATH", false},
            {~c"MIX_DEPS_PATH", false},
            {~c"ERL_LIBS", false},
            {~c"ERL_FLAGS", ~c"+S 4:4 +SDcpu 1 +SDio 1"}
          ]
        ])

      try do
        {output, status} = collect(port, "", System.monotonic_time(:millisecond) + 150_000)
        assert status == 0, output
        assert output =~ "OBSERVABILITY_COPIED_CONSUMER_PASSED"
        IO.write(output)
      after
        if Port.info(port), do: Port.close(port)
      end
    else
      refute Code.ensure_loaded?(Elzoo.Application)
      refute Application.spec(:elzoo)
    end
  end

  defp closure([], seen), do: seen

  defp closure([app | rest], seen) do
    if app in seen do
      closure(rest, seen)
    else
      Application.load(app)

      needed =
        (Application.spec(app, :applications) || []) --
          (Application.spec(app, :optional_applications) || [])

      closure(rest ++ needed, MapSet.put(seen, app))
    end
  end

  defp collect(port, output, deadline) do
    receive do
      {^port, {:data, data}} -> collect(port, output <> data, deadline)
      {^port, {:exit_status, status}} -> {output, status}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        flunk("copied consumer exceeded finite deadline")
    end
  end
end
