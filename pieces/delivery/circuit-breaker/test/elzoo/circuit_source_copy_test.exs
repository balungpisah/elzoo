# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CircuitSourceCopyTest do
  use ExUnit.Case, async: true
  @piece Path.expand("../..", __DIR__)

  @tag timeout: 120_000
  test "C20 independent original and renamed circuit sources run every circuit scenario without Elzoo.Application" do
    destination =
      Path.join(System.tmp_dir!(), "elz100-copy-" <> Base.encode16(:crypto.strong_rand_bytes(12)))

    File.mkdir!(destination)
    on_exit(fn -> File.rm_rf!(destination) end)
    paths = provider_paths()
    own = ~w(cure/elzoo/circuit_policy.cure lib/elzoo/circuit_breaker.ex
      test/elzoo/circuit_policy_test.exs test/elzoo/circuit_breaker_test.exs
      test/elzoo/circuit_lifecycle_test.exs test/elzoo/circuit_provider_test.exs
      test/support/circuit_provider_test_helper.exs)
    capacity = ~w(cure/elzoo/backpressure.cure lib/elzoo/backpressure.ex)

    for variant <- [:original, :renamed] do
      dir = Path.join(destination, Atom.to_string(variant))
      File.mkdir!(dir)

      for relative <- own ++ capacity do
        source = Path.join(@piece, relative)

        source =
          if File.regular?(source),
            do: source,
            else: Path.expand("../backpressure/#{relative}", @piece)

        original = File.read!(source)

        bytes =
          if variant == :renamed do
            original
            |> String.replace("Elzoo.", "Consumer.")
            |> String.replace("CapacityState", "ConsumerCapacityState")
          else
            original
          end

        target = Path.join(dir, relative)
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, bytes)
        assert File.read!(target) == bytes
      end

      File.write!(Path.join(dir, "run.exs"), runner())

      {output, status} =
        System.cmd(System.find_executable("elixir"), paths ++ ["run.exs"],
          cd: dir,
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "ELZ-100 SOURCE CONSUMER PASSED"
      assert output =~ "Result: 21 passed"

      # A fresh VM loads the compiled consumer plus runtime providers only.
      # Cure's compiler and the catalogue application are absent at runtime.
      runtime_paths =
        ["-pa", Path.join(dir, "ebin")] ++
          Enum.flat_map([:fuse, :telemetry], &["-pa", Application.app_dir(&1, "ebin")])

      prefix = if variant == :renamed, do: "Consumer", else: "Elzoo"

      runtime = """
      import ExUnit.Assertions
      assert :code.which(Cure.Compiler) == :non_existing
      assert :code.which(Elzoo.Application) == :non_existing
      {:ok, _} = Application.ensure_all_started(:fuse)
      {:ok, _} = Application.ensure_all_started(:telemetry)
      {:ok, clock} = Agent.start_link(fn -> -1000 end)
      {:ok, supervisor} = Supervisor.start_link([{#{prefix}.CircuitBreaker, name: :circuit_copied_runtime,
        clock: fn -> Agent.get(clock, & &1) end}], strategy: :one_for_one)
      [{{#{prefix}.CircuitBreaker, :circuit_copied_runtime}, owner, _, _}] = Supervisor.which_children(supervisor)
      {:ok, p} = #{prefix}.CircuitBreaker.admit(owner)
      {:ok, :applied} = #{prefix}.CircuitBreaker.finish(owner, p, :healthy)
      {:ok, %{mode: :closed}} = #{prefix}.CircuitBreaker.status(owner)
      Supervisor.stop(supervisor)
      IO.puts("ELZ-100 COMPILER-FREE RUNTIME PASSED")
      """

      {output, status} =
        System.cmd(System.find_executable("elixir"), runtime_paths ++ ["-e", runtime],
          cd: dir,
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "ELZ-100 COMPILER-FREE RUNTIME PASSED"
    end
  end

  defp provider_paths do
    closure = fn recurse, app, seen ->
      if MapSet.member?(seen, app) do
        seen
      else
        _ = Application.load(app)

        Enum.reduce(
          (Application.spec(app, :applications) || []) --
            (Application.spec(app, :optional_applications) || []),
          MapSet.put(seen, app),
          fn dep, acc -> recurse.(recurse, dep, acc) end
        )
      end
    end

    apps = Enum.reduce([:cure, :fuse, :telemetry], MapSet.new(), &closure.(closure, &1, &2))
    refute MapSet.member?(apps, :elzoo)
    assert Application.spec(:fuse, :vsn) == ~c"2.5.0"
    assert Application.spec(:telemetry, :vsn) == ~c"1.4.2"
    Enum.flat_map(apps, &["-pa", Application.app_dir(&1, "ebin")])
  end

  defp runner do
    ~S"""
    import ExUnit.Assertions
    assert :code.which(Elzoo.Application) == :non_existing
    assert :code.which(Elzoo.ObjectStore) == :non_existing
    assert :code.which(Elzoo.Notification) == :non_existing
    {:ok, _} = Application.ensure_all_started(:cure)
    {:ok, _} = Application.ensure_all_started(:fuse)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    File.mkdir!("ebin")
    :code.add_patha(~c"ebin")
    for file <- ["cure/elzoo/backpressure.cure", "cure/elzoo/circuit_policy.cure"] do
      assert {:ok, _, _} = Cure.Compiler.compile_file(file, output_dir: "ebin")
    end
    assert {:ok, _, %{compile_warnings: [], runtime_warnings: []}} = Kernel.ParallelCompiler.compile_to_path(
      ["lib/elzoo/backpressure.ex", "lib/elzoo/circuit_breaker.ex"], "ebin", return_diagnostics: true)
    ExUnit.start(autorun: false, seed: 0, timeout: 60_000)
    for file <- ["test/elzoo/circuit_policy_test.exs", "test/elzoo/circuit_breaker_test.exs",
      "test/elzoo/circuit_lifecycle_test.exs", "test/elzoo/circuit_provider_test.exs"], do: Code.require_file(file)
    result = ExUnit.run()
    assert result.total > 0 and result.failures == 0
    assert :code.which(Elzoo.Application) == :non_existing
    assert not Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :elzoo end)
    IO.puts("ELZ-100 SOURCE CONSUMER PASSED")
    """
  end
end
