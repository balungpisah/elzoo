defmodule Elzoo.CheckSelectionTest do
  use ExUnit.Case, async: true
  alias Elzoo.CheckSelection, as: Selection

  setup do
    entries =
      Map.new(Selection.consumer_ids() ++ ["runtime/unit", "workflow/approval"], fn id ->
        {id, %{"id" => id, "status" => "ready", "dependencies" => []}}
      end)
      |> put_in(["runtime/host", "dependencies"], ["runtime/unit"])
      |> put_in(["assembly/ingest-json-unit", "dependencies"], ["runtime/host"])

    %{registry: %{entries: entries}}
  end

  test "a Piece change selects its existing independent consumer", %{registry: registry} do
    selection = select(registry, ["pieces/delivery/transformation/lib/transform.ex"])
    assert selection.selected == ["delivery/transformation"]
    assert selection.affected == ["delivery/transformation"]
    assert length(selection.skipped) == 25
    refute selection.aggregate
    assert selection.uncovered == []
    assert_partition(selection)
  end

  test "dependency changes select transitive dependants through IDs without a consumer", ctx do
    selection = select(ctx.registry, ["pieces/runtime/unit/lib/unit.ex"])
    assert selection.selected == ["assembly/ingest-json-unit", "runtime/host"]
    assert selection.affected == ["assembly/ingest-json-unit", "runtime/host", "runtime/unit"]
    assert "runtime/unit" in selection.without_consumer
    refute selection.aggregate
    assert selection.uncovered == []
    assert_partition(selection)
  end

  test "manifest, README, new and deleted paths inside a known Piece select its dependants", ctx do
    for relative <- ["piece.json", "README.md", "test/new_test.exs", "lib/deleted.ex"] do
      selection = select(ctx.registry, ["pieces/runtime/host/" <> relative])
      assert selection.selected == ["assembly/ingest-json-unit", "runtime/host"]
    end
  end

  test "an affected Piece without consumer closure coverage retains the aggregate", ctx do
    selection = select(ctx.registry, ["pieces/workflow/approval/lib/approval.ex"])
    assert selection.selected == []
    assert selection.affected == ["workflow/approval"]
    assert "workflow/approval" in selection.without_consumer
    assert selection.aggregate
    assert selection.uncovered == ["workflow/approval"]
    assert selection.aggregate_reason =~ "lack copying coverage"
    assert Selection.report(selection) =~ "Aggregate consumer: selected (all ready IDs)"
    assert Selection.report(selection) =~ "OTP-only consumer and all root tests: selected"
    assert Selection.report(selection) =~ "unselected consumer checks are not validated"

    assert :ok ==
             ExUnit.Filters.eval([], exclusion_filters(selection), %{aggregate_consumer: true}, [])

    assert_partition(selection)
  end

  test "an uncovered transitive dependant also requires the aggregate", ctx do
    registry = put_in(ctx.registry, [:entries, "workflow/approval", "dependencies"], ["core/port"])
    selection = select(registry, ["pieces/core/port/README.md"])
    assert selection.selected == ["core/port"]
    assert selection.affected == ["core/port", "workflow/approval"]
    assert selection.uncovered == ["workflow/approval"]
    assert selection.aggregate
  end

  test "shared fallback keeps the aggregate even when all ready IDs have fixed consumers", ctx do
    registry = %{entries: Map.take(ctx.registry.entries, Selection.consumer_ids())}
    registry = put_in(registry.entries["runtime/host"]["dependencies"], [])
    selection = select(registry, ["test/export_test.exs"])
    assert selection.uncovered == []
    assert selection.aggregate
    assert selection.aggregate_reason =~ "full fallback"
    assert Selection.test_args(selection) == ["--warnings-as-errors"]
  end

  test "shared harness, toolchain, registry, workflow and unknown paths select all", ctx do
    for path <- [
          "lib/elzoo/export.ex",
          "lib/elzoo/check_selection.ex",
          "lib/mix/tasks/check.ex",
          "test/export_test.exs",
          "test/test_helper.exs",
          "config/test.exs",
          "mix.exs",
          "mix.lock",
          ".tool-versions",
          ".github/workflows/symbolic-check.yml",
          "scripts/run-ci-check.sh",
          "registry/catalogue.json",
          "registry/providers.json",
          "spikes/ash_foundation/mix.lock",
          "pieces/unknown/piece/lib/new.ex",
          "pieces/runtime/unit-other/lib/new.ex",
          "docs/unknown.md"
        ] do
      selection = select(ctx.registry, ["pieces/runtime/host/README.md", path])
      assert_all(selection)
      assert selection.aggregate
      assert selection.aggregate_reason =~ "full fallback"
      assert selection.reason =~ inspect(path)
    end
  end

  test "unsafe, malformed, missing and empty inputs never select an empty subset", ctx do
    for paths <- [
          [],
          ["../pieces/runtime/host/README.md"],
          ["/pieces/runtime/host/README.md"],
          ["pieces/runtime/host/../../mix.exs"],
          ["pieces/runtime/host//README.md"],
          ["pieces/runtime/host/"],
          ["pieces\\runtime\\host\\README.md"],
          ["pieces/runtime/host/evil\nname"],
          [<<255>>],
          [nil]
        ] do
      assert_all(select(ctx.registry, paths))
    end

    assert_all(Selection.for_changes(ctx.registry, {:ok, "not a path list"}))
    assert_all(Selection.for_changes(ctx.registry, {:error, "comparison unavailable"}))
  end

  test "selection is deterministic with duplicates and unions", ctx do
    paths = ["pieces/runtime/host/README.md", "pieces/core/port/README.md"]
    left = select(ctx.registry, paths)
    assert left == select(ctx.registry, Enum.reverse(paths ++ paths))
    assert left.selected == ["assembly/ingest-json-unit", "core/port", "runtime/host"]
    assert_partition(left)
  end

  test "default full mode excludes nothing and retains its acceptance marker", ctx do
    selection = Selection.full(ctx.registry)
    assert_all(selection)
    assert Selection.test_args(selection) == ["--warnings-as-errors"]
    assert Selection.report(selection) =~ "Aggregate consumer: selected (all ready IDs)"
    assert Selection.success_marker(selection) == "ELZOO CHECK PASSED"
  end

  test "affected filters exclude only aggregate and skipped per-ID consumers", ctx do
    selection = select(ctx.registry, ["pieces/core/port/README.md"])
    filters = exclusion_filters(selection)
    assert :ok == ExUnit.Filters.eval([], filters, %{}, [])
    assert :ok == ExUnit.Filters.eval([], filters, %{consumer_id: "core/port"}, [])

    for id <- selection.skipped do
      assert {:excluded, _} = ExUnit.Filters.eval([], filters, %{consumer_id: id}, [])
    end

    assert {:excluded, _} = ExUnit.Filters.eval([], filters, %{aggregate_consumer: true}, [])
    refute Selection.success_marker(selection) =~ "ELZOO CHECK PASSED"
  end

  test "Git changes include commits, staged/unstaged edits, renames, deletions and untracked files",
       ctx do
    root = git_fixture()
    base = git!(root, ["rev-parse", "HEAD"]) |> String.trim()
    File.rename!(Path.join(root, "pieces/core/port/a.ex"), Path.join(root, "renamed.ex"))
    git!(root, ["add", "-A"])
    git!(root, ["-c", "commit.gpgsign=false", "commit", "-qm", "rename"])
    File.write!(Path.join(root, "pieces/runtime/unit/u.ex"), "staged")
    git!(root, ["add", "."])
    File.write!(Path.join(root, "pieces/runtime/unit/u.ex"), "unstaged")
    File.rm!(Path.join(root, "pieces/runtime/host/h.ex"))
    File.write!(Path.join(root, "new unknown file.ex"), "new")

    assert {:ok, diff} = Selection.changed_paths(root, base)

    assert diff.paths == [
             "new unknown file.ex",
             "pieces/core/port/a.ex",
             "pieces/runtime/host/h.ex",
             "pieces/runtime/unit/u.ex",
             "renamed.ex"
           ]

    assert diff.base == base
    assert diff.head != base
    assert_all(Selection.from_git(ctx.registry, base, root))
  end

  test "real Git diff can narrow a known Piece; missing base and empty diff select all", ctx do
    root = git_fixture()
    base = git!(root, ["rev-parse", "HEAD"]) |> String.trim()
    assert_all(Selection.from_git(ctx.registry, base, root))
    File.write!(Path.join(root, "pieces/runtime/unit/u.ex"), "changed")
    selection = Selection.from_git(ctx.registry, base, root)
    assert selection.selected == ["assembly/ingest-json-unit", "runtime/host"]
    assert selection.comparison =~ base

    for ref <- ["", "missing-ref", "--help"] do
      assert_all(Selection.from_git(ctx.registry, ref, root))
    end

    assert_all(Selection.from_git(ctx.registry, base, Path.join(root, "missing-directory")))
  end

  test "CI runs the full check for every event; the workflow never invokes affected mode" do
    workflow = File.read!(".github/workflows/symbolic-check.yml")
    assert workflow =~ "fetch-depth: 0"
    refute workflow =~ "ELZOO_CHECK_EVENT"
    refute workflow =~ "ELZOO_CHECK_BASE"
    refute workflow =~ "--affected"

    # ELZ-073: three work jobs run the three parts of the full check; together they are the full check.
    # Execute the actual run blocks using a harmless stand-in for the check wrapper.
    scripts =
      for [_, step] <-
            Regex.scan(~r/      - name: Run mix check\n(.*?)      - name:/s, workflow) do
        [_, script] = Regex.run(~r/^        run: (.+)\n/m, step)
        script
      end

    assert scripts ==
             for(part <- Selection.parts(), do: "sh scripts/run-ci-check.sh --part #{part}")

    root = git_fixture()
    stub = Path.join(root, "sh")
    File.write!(stub, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
    File.chmod!(stub, 0o755)
    base = "base with spaces; not shell code"

    # A leftover event or base variable must not select affected mode.
    for {script, part} <- Enum.zip(scripts, Selection.parts()),
        event <- ["pull_request", "push", "workflow_dispatch", "unknown", ""] do
      {output, 0} =
        System.cmd("/bin/sh", ["-eu", "-c", script],
          env: [
            {"PATH", root <> ":" <> System.fetch_env!("PATH")},
            {"ELZOO_CHECK_EVENT", event},
            {"ELZOO_CHECK_BASE", base}
          ]
        )

      assert output == "scripts/run-ci-check.sh\n--part\n#{part}\n"
    end
  end

  test "resource sampler wrapper forwards arguments and command failure" do
    root = git_fixture()
    File.write!(Path.join(root, "python3"), "#!/bin/sh\nexit 0\n")
    File.write!(Path.join(root, "mix"), "#!/bin/sh\nprintf '%s\\n' \"$@\"\nexit 7\n")
    File.chmod!(Path.join(root, "python3"), 0o755)
    File.chmod!(Path.join(root, "mix"), 0o755)

    for args <- [[], ["--affected", "base with spaces"]] do
      {output, status} =
        System.cmd("/bin/sh", ["scripts/run-ci-check.sh" | args],
          env: [{"PATH", root <> ":" <> System.fetch_env!("PATH")}, {"RUNNER_TEMP", root}]
        )

      assert status == 7
      assert output == Enum.join(["check" | args], "\n") <> "\n"
    end
  end

  defp select(registry, paths), do: Selection.for_changes(registry, {:ok, paths})

  defp assert_all(selection) do
    assert selection.selected == Enum.sort(Selection.consumer_ids())
    assert selection.skipped == []
    assert selection.aggregate
  end

  defp assert_partition(selection) do
    assert Enum.sort(selection.selected ++ selection.skipped) == Enum.sort(Selection.consumer_ids())
    assert MapSet.disjoint?(MapSet.new(selection.selected), MapSet.new(selection.skipped))
  end

  defp exclusion_filters(selection) do
    {opts, [], []} =
      OptionParser.parse(Selection.test_args(selection),
        strict: [exclude: :keep, warnings_as_errors: :boolean]
      )

    opts |> Keyword.get_values(:exclude) |> ExUnit.Filters.parse()
  end

  defp git_fixture do
    root =
      Path.join(
        System.tmp_dir!(),
        "elzoo-selection-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(root, ["init", "-q"])
    git!(root, ["config", "user.email", "selector-test@example.invalid"])
    git!(root, ["config", "user.name", "Selector test"])

    for path <- ["pieces/core/port/a.ex", "pieces/runtime/unit/u.ex", "pieces/runtime/host/h.ex"] do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), "original")
    end

    git!(root, ["add", "."])
    git!(root, ["-c", "commit.gpgsign=false", "commit", "-qm", "base"])
    root
  end

  # ELZ-073: `mix check --part ...` runs one of three disjoint parts of the full check.
  test "a part names its markers, filters and report" do
    assert Selection.parts() == ["root", "consumers-db", "consumers"]

    assert Enum.map(Selection.parts(), &Selection.success_marker(Selection.part(&1))) ==
             ["ELZOO ROOT SUITE PASSED", "ELZOO CONSUMERS DB PASSED", "ELZOO CONSUMERS PASSED"]

    # No part prints the marker of the full check, which only the aggregating job prints.
    refute "ELZOO CHECK PASSED" in Enum.map(
             Selection.parts(),
             &Selection.success_marker(Selection.part(&1))
           )

    for part <- Selection.parts() do
      assert Selection.report(Selection.part(part)) =~ "part #{part}"
      args = Selection.test_args(Selection.part(part))
      assert hd(args) == "--warnings-as-errors"
      %{include: include, exclude: exclude} = Selection.part_filters(part)

      assert Enum.drop(args, 1) ==
               Enum.flat_map(include, &["--only", &1]) ++ Enum.flat_map(exclude, &["--exclude", &1])
    end

    assert_raise FunctionClauseError, fn -> Selection.part("everything") end
  end

  test "the PostgreSQL consumers belong to the consumers-db part and nowhere else" do
    db = Selection.part_filters("consumers-db").include
    rest = Selection.part_filters("consumers").include

    for id <- Selection.postgres_consumer_ids() do
      assert "consumer_id:#{id}" in db
      refute "consumer_id:#{id}" in rest
    end

    assert length(rest) ==
             length(Selection.consumer_ids()) - length(Selection.postgres_consumer_ids())

    assert Enum.all?(
             rest,
             &(&1 in Enum.map(Selection.consumer_ids(), fn id -> "consumer_id:#{id}" end))
           )

    assert "aggregate_consumer" in db
    assert Selection.part_filters("root").exclude == ["consumer_id", "aggregate_consumer"]
  end

  test "mix check refuses an unknown part and other arguments before it runs any stage" do
    assert_raise Mix.Error, ~r/unknown part "everything"/, fn ->
      Mix.Tasks.Check.run(["--part", "everything"])
    end

    assert_raise Mix.Error, ~r/usage: mix check/, fn -> Mix.Tasks.Check.run(["--part"]) end

    assert_raise Mix.Error, ~r/usage: mix check/, fn ->
      Mix.Tasks.Check.run(["--part", "root", "--affected", "x"])
    end

    assert_raise Mix.Error, ~r/usage: mix check/, fn -> Mix.Tasks.Check.run(["--bogus"]) end
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
