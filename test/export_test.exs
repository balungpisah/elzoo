defmodule Elzoo.ExportTest do
  use ExUnit.Case, async: false
  @root File.cwd!()

  setup do
    destination =
      Path.join(System.tmp_dir!(), "elzoo-consumer-#{System.unique_integer([:positive])}")

    File.mkdir_p!(destination)
    File.write!(Path.join(destination, "mix.exs"), project([], false))
    on_exit(fn -> File.rm_rf!(destination) end)
    {:ok, destination: destination, registry: Elzoo.Registry.load!(@root)}
  end

  test "planning is read-only; copies are idempotent and carry exact hashes", ctx do
    plan = Elzoo.Export.plan!(ctx.registry, ["integration/json"], ctx.destination)
    assert File.ls!(ctx.destination) == ["mix.exs"]
    refute Map.has_key?(plan.providers, "cure")
    refute Map.has_key?(plan.files, "lib/mix/tasks/compile_cure.ex")
    :ok = Elzoo.Export.write!(plan)
    :ok = Elzoo.Export.write!(plan)
    receipt = Path.join(ctx.destination, plan.receipt) |> File.read!() |> Jason.decode!()
    assert receipt["providers"]["jason"]["version"] == "1.4.5"

    for {relative, expected} <- receipt["sha256"] do
      actual =
        Path.join(ctx.destination, relative)
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert actual == expected
    end

    assert File.read!(Path.join(ctx.destination, "mix.exs")) == project([], false)
  end

  test "a conflict found late in the selection writes nothing", ctx do
    file = Path.join(ctx.destination, "test/elzoo/json_recipe_test.exs")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "application-owned changes")

    assert_raise ArgumentError, ~r/refusing to overwrite/, fn ->
      Elzoo.Export.plan!(ctx.registry, ["integration/json"], ctx.destination)
    end

    refute File.exists?(Path.join(ctx.destination, ".elzoo"))
    refute File.exists?(Path.join(ctx.destination, "licenses"))
    assert File.read!(file) == "application-owned changes"
  end

  test "destination symlinks and changes after planning are refused", ctx do
    outside = Path.join(ctx.destination, "outside")
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(ctx.destination, "lib"))

    assert_raise ArgumentError, ~r/destination symlink/, fn ->
      Elzoo.Export.plan!(ctx.registry, ["runtime/unit"], ctx.destination)
    end

    File.rm!(Path.join(ctx.destination, "lib"))
    plan = Elzoo.Export.plan!(ctx.registry, ["runtime/unit"], ctx.destination)
    source = Path.join(ctx.destination, "lib/elzoo/unit.ex")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "new application changes")
    assert_raise ArgumentError, ~r/refusing to overwrite/, fn -> Elzoo.Export.write!(plan) end
    refute File.exists?(Path.join(ctx.destination, ".elzoo"))
  end

  test "replacing the destination root with a symlink invalidates a plan", ctx do
    plan = Elzoo.Export.plan!(ctx.registry, ["runtime/unit"], ctx.destination)
    moved = ctx.destination <> "-moved"
    File.rename!(ctx.destination, moved)
    on_exit(fn -> File.rm_rf!(moved) end)
    File.ln_s!(moved, ctx.destination)
    assert_raise ArgumentError, ~r/destination must remain/, fn -> Elzoo.Export.write!(plan) end
    refute File.exists?(Path.join(moved, ".elzoo"))
  end

  @tag timeout: 120_000
  test "an OTP-only piece runs in a normal independent Mix project", ctx do
    plan = Elzoo.Export.plan!(ctx.registry, ["runtime/unit"], ctx.destination)
    Elzoo.Export.write!(plan)
    File.write!(Path.join(ctx.destination, "test/test_helper.exs"), "ExUnit.start()\n")

    {output, status} =
      System.cmd("mix", ["test"],
        cd: ctx.destination,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}]
      )

    assert status == 0, output
    assert output =~ "1 passed"
  end

  @tag timeout: 120_000
  test "all selected sources compile and run outside Elzoo with only upstream code paths", ctx do
    ids =
      ctx.registry.entries
      |> Map.values()
      |> Enum.filter(&(&1["status"] == "ready"))
      |> Enum.map(& &1["id"])

    plan = Elzoo.Export.plan!(ctx.registry, ids, ctx.destination)
    Elzoo.Export.write!(plan)

    File.write!(
      Path.join(ctx.destination, "mix.exs"),
      project([:logger, :cure, :jason, :req, :crypto], true)
    )

    File.write!(Path.join(ctx.destination, "test/test_helper.exs"), "ExUnit.start(seed: 0)\n")

    # Reuse only compiled upstream dependency artifacts. A fresh VM gets no
    # elzoo ebin, project sources, or runtime application. A separate cold
    # acceptance probe also exercises ordinary dependency fetching/building.
    paths =
      Path.wildcard(Path.join([@root, "_build", "test", "lib", "*", "ebin"]))
      |> Enum.reject(&(Path.basename(Path.dirname(&1)) == "elzoo"))

    bootstrap = Path.join(ctx.destination, "isolated.exs")

    File.write!(bootstrap, """
    unless :code.which(Elzoo.Registry) == :non_existing and :code.which(:"Cure.Elzoo.Core") == :non_existing,
      do: raise("Elzoo leaked into the consumer code path")
    Mix.CLI.main(["test", "--no-deps-check"])
    """)

    args = Enum.flat_map(paths, &["-pa", &1]) ++ [bootstrap]

    {output, status} =
      System.cmd("elixir", args,
        cd: ctx.destination,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}]
      )

    assert status == 0, output
    assert output =~ "passed"
    refute output =~ "0 tests"
    refute File.exists?(Path.join(ctx.destination, "lib/elzoo/application.ex"))
  end

  defp project(applications, cure?) do
    compilers = if cure?, do: "compilers: (Mix.compilers() -- [:app]) ++ [:cure, :app],", else: ""

    """
    defmodule Consumer.MixProject do
      use Mix.Project
      def project, do: [app: :consumer, version: "0.1.0", #{compilers} deps: []]
      def application, do: [extra_applications: #{inspect(applications)}]
    end
    """
  end
end
