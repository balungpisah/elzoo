# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.SourceOnlyProviderTest do
  use Elzoo.CureConsumerCase, async: false

  @root File.cwd!()
  @id "fixture/source-only-provider"
  @native "lib/elzoo/source_only_probe/native/host.c"
  @test "test/elz165_source_only_probe_test.exs"
  @fixtures Path.join(@root, "test/fixtures/elz165_source_only_provider")

  setup ctx do
    root = Path.join(ctx.destination, "source")
    File.mkdir!(root)

    for file <- ~w(mix.lock .tool-versions LICENSE NOTICE registry/providers.json) do
      target = Path.join(root, file)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(@root, file), target)
    end

    guide = Path.join(root, "docs/consuming.md")
    File.mkdir_p!(Path.dirname(guide))
    File.write!(guide, "# Synthetic consumer guide\n")

    template = ctx.registry.entries["integration/json"]

    piece =
      template
      |> Map.drop(~w(directory summary disposition phase manifest))
      |> Map.merge(%{
        "id" => @id,
        "providers" => ["lua_source"],
        "files" => [@native, @test],
        "contract" => "Synthetic source-only consumer build probe.",
        "grounding" => [
          %{"kind" => "test", "file" => @test, "claim" => "Finite native execution probe."}
        ]
      })

    directory = "pieces/" <> @id

    for {source, target} <- [{"host.c", @native}, {"native_case.exs.fixture", @test}] do
      path = Path.join([root, directory, target])
      File.mkdir_p!(Path.dirname(path))
      File.cp!(Path.join(@fixtures, source), path)
    end

    File.write!(
      Path.join([root, directory, "README.md"]),
      "# Synthetic source-only consumer fixture\n"
    )

    File.write!(Path.join([root, directory, "piece.json"]), Jason.encode!(piece))
    entry = %{"id" => @id, "status" => "ready", "manifest" => directory <> "/piece.json"}

    File.write!(
      Path.join(root, "registry/catalogue.json"),
      Jason.encode!(%{"schema_version" => 1, "entries" => [entry]})
    )

    %{registry: Elzoo.Registry.load!(root)}
  end

  test "native planning is read-only and copies exact owned bytes", ctx do
    plan = Elzoo.Export.plan!(ctx.registry, [@id], ctx.destination)
    assert File.ls!(ctx.destination) |> Enum.sort() == ["mix.exs", "source"]
    assert plan.files[@native] == File.read!(Path.join(@fixtures, "host.c"))
    receipt = Jason.decode!(plan.files[plan.receipt])

    assert receipt["sha256"][@native] ==
             Base.encode16(:crypto.hash(:sha256, plan.files[@native]), case: :lower)

    refute Enum.any?(Map.keys(plan.files), &String.starts_with?(&1, "deps/"))
    assert Elzoo.CureConsumerCase.source_dependencies!(%{providers: %{}}, %{}) == []

    for provider <- [
          %{"source" => "git", "package" => "lua_source"},
          %{"source" => "git", "package" => "lua_source", "compile" => false}
        ] do
      assert Elzoo.CureConsumerCase.source_dependencies!(
               %{providers: %{"lua_source" => provider}},
               %{}
             ) == []
    end
  end

  test "selected source-only checkouts are required and get only path compile/app options", ctx do
    plan = Elzoo.Export.plan!(ctx.registry, [@id], ctx.destination)
    source = Mix.Project.deps_paths()[:lua_source]

    assert Elzoo.CureConsumerCase.source_dependencies!(plan, Mix.Project.deps_paths()) ==
             [{:lua_source, [path: source, compile: false, app: false]}]

    for paths <- [%{}, %{lua_source: nil}, %{lua_source: Path.join(ctx.destination, "missing")}] do
      assert_raise ArgumentError, ~r/source-only provider checkout unavailable: lua_source/, fn ->
        Elzoo.CureConsumerCase.source_dependencies!(plan, paths)
      end
    end
  end

  @tag timeout: 150_000
  test "root native copied consumer uses the selected source checkout", ctx do
    source = Mix.Project.deps_paths()[:lua_source]

    {before, 0} =
      System.cmd("git", ["-C", source, "status", "--porcelain", "--untracked-files=all"])

    assert_cure_consumer(ctx, [@id], inner_timeout: 125_000)

    {after_build, 0} =
      System.cmd("git", ["-C", source, "status", "--porcelain", "--untracked-files=all"])

    assert before == after_build

    refute File.read!(Path.join(ctx.destination, "mix.exs")) =~
             "extra_applications: [:logger, :lua_source]"
  end

  @tag timeout: 150_000
  test "new-Piece own-test mode builds native sources but does not load dependency tests", ctx do
    registry = ctx.registry
    dependency = "fixture/source-only-dependency"
    directory = "pieces/" <> dependency
    file = "test/elz165_excluded_dependency_test.exs"
    path = Path.join([registry.root, directory, file])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "raise \"dependency test must not be loaded\"\n")
    File.write!(Path.join([registry.root, directory, "README.md"]), "# Dependency fixture\n")

    piece =
      registry.entries[@id]
      |> Map.merge(%{
        "id" => dependency,
        "directory" => directory,
        "dependencies" => [],
        "providers" => [],
        "files" => [file],
        "grounding" => [%{"kind" => "test", "file" => file, "claim" => "Selection sentinel."}]
      })

    File.write!(Path.join([registry.root, directory, "piece.json"]), Jason.encode!(piece))

    registry =
      registry
      |> put_in([:entries, dependency], piece)
      |> put_in([:entries, @id, "dependencies"], [dependency])

    assert_cure_consumer(%{ctx | registry: registry}, [@id],
      only_tests_of: @id,
      inner_timeout: 125_000
    )

    assert File.regular?(Path.join(ctx.destination, file))
  end
end
