# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DataStream.CopyTest do
  use ExUnit.Case, async: false
  @tag timeout: 180_000
  test "selected source closure compiles and repeats actual callback, custody, SQL and TLS tests in a separate Mix consumer" do
    destination =
      Path.join(
        System.tmp_dir!(),
        "elz101-copy-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    File.mkdir_p!(destination)
    on_exit(fn -> File.rm_rf!(destination) end)
    File.write!(Path.join(destination, "mix.exs"), project())

    plan =
      if Code.ensure_loaded?(Elzoo.Registry) do
        registry = Elzoo.Registry.load!()
        # In-memory registration permits evidence before serialized shared edits.
        piece =
          Path.expand("../../piece.json", __DIR__)
          |> File.read!()
          |> Jason.decode!()
          |> Map.put("directory", "pieces/delivery/data-stream")

        registry = %{registry | entries: Map.put(registry.entries, "delivery/data-stream", piece)}
        plan = Elzoo.Export.plan!(registry, ["delivery/data-stream"], destination)
        Elzoo.Export.write!(plan)
        plan
      else
        copied_selection(destination)
      end

    for {path, bytes} <- plan.files, do: assert(File.read!(Path.join(destination, path)) == bytes)
    ids = Enum.map(plan.pieces, & &1["id"])
    assert "integration/sql" in ids and "delivery/effect-intent" in ids
    refute Enum.any?(ids, &String.starts_with?(&1, "integration/ai-text"))
    refute Map.has_key?(plan.providers, "req_llm")
    refute Map.has_key?(plan.providers, "fuse")

    apps =
      closure(
        [:req, :jason, :server_sent_events, :ecto_sql, :postgrex, :cure, :crypto],
        MapSet.new()
      )

    refute :elzoo in apps or :req_llm in apps or :fuse in apps
    paths = for app <- apps, do: Application.app_dir(app, "ebin")
    args = Enum.flat_map(paths, &["-pa", &1]) ++ ["examples/copied_consumer.exs"]

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
      {output, exit} = collect(port, "", System.monotonic_time(:millisecond) + 150_000)
      assert exit == 0, output
      assert output =~ "DATA_STREAM_COPIED_CONSUMER_PASSED"
      IO.write(output)
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  # In an aggregate export, manifests and source are already flattened by
  # the actual exporter. Select this dependency closure from those manifests,
  # never from all files or loadable root modules in the aggregate.
  defp copied_selection(destination) do
    pieces = select(["delivery/data-stream"], %{}) |> Map.values()
    sources = Enum.flat_map(pieces, & &1["files"]) |> Enum.uniq()
    compiler = "lib/mix/tasks/compile_cure.ex"
    sources = Enum.uniq([compiler | sources])
    files = Map.new(sources, fn path -> {path, File.read!(path)} end)

    for {path, bytes} <- files do
      target = Path.join(destination, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, bytes)
    end

    providers = pieces |> Enum.flat_map(& &1["providers"]) |> Map.new(&{&1, %{}})
    %{files: files, pieces: pieces, providers: providers}
  end

  defp select([], seen), do: seen

  defp select([id | rest], seen) do
    if Map.has_key?(seen, id) do
      select(rest, seen)
    else
      m = Path.join([".elzoo", "pieces", id, "piece.json"]) |> File.read!() |> Jason.decode!()
      select(rest ++ m["dependencies"], Map.put(seen, id, m))
    end
  end

  defp project do
    """
    defmodule DataStreamConsumer.MixProject do
      use Mix.Project
      def project, do: [app: :data_stream_consumer,version: "0.1.0",prune_code_paths: false,compilers: (Mix.compilers() -- [:app]) ++ [:cure,:app],cure_paths: ["cure"],deps: [],test_ignore_filters: [~r/test_helper.exs$/],elixirc_options: [warnings_as_errors: true]]
      def application, do: [extra_applications: [:logger,:crypto,:req,:jason,:server_sent_events,:cure,:ecto_sql,:postgrex]]
    end
    """
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
      {^port, {:data, bytes}} -> collect(port, output <> bytes, deadline)
      {^port, {:exit_status, status}} -> {output, status}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        flunk("isolated consumer exceeded its finite deadline")
    end
  end
end
