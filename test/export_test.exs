defmodule Elzoo.ExportTest do
  use Elzoo.CureConsumerCase, async: false

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

  test "install guidance separates compiler lifecycle from tested library versions", ctx do
    plan = Elzoo.Export.plan!(ctx.registry, ["integration/cure-json"], ctx.destination)
    instructions = plan.files[plan.instructions]
    assert instructions =~ "runtime: false"
    assert instructions =~ "208248063d64e621782cd26dd30698ee42850a89"
    assert instructions =~ ~s({:jason, "~> 1.4.5"})
    assert instructions =~ "not evidence for untested releases"
    receipt = Jason.decode!(plan.files[plan.receipt])
    assert receipt["providers"]["jason"]["version"] == "1.4.5"
  end

  test "install guidance emits provider runtime policy while retaining the default", ctx do
    erlexec = Elzoo.Export.plan!(ctx.registry, ["runtime/os-isolation"], ctx.destination)
    erlexec_instructions = erlexec.files[erlexec.instructions]

    assert erlexec_instructions =~ ~s({:erlexec, "~> 2.6.0", runtime: false})

    jason = Elzoo.Export.plan!(ctx.registry, ["integration/json"], ctx.destination)
    jason_instructions = jason.files[jason.instructions]

    assert jason_instructions =~ ~s({:jason, "~> 1.4.5"})
    refute jason_instructions =~ ~s({:jason, "~> 1.4.5", runtime: false})
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
      timed("consumer=runtime/unit consumer_mix_test", fn ->
        System.cmd("mix", ["test"],
          cd: ctx.destination,
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}]
        )
      end)

    assert status == 0, output
    assert output =~ "1 passed"
  end

  # The aggregate consumer runs every ready bundle's own tests plus copy/compile.
  # It grows with each ready Piece: 125.2 s locally on 2026-11-06; 493.6 s locally
  # on 2026-11-07 (PR #59 head 4fdc8ad), where 360 s timed out twice on symbolic CI.
  # ~2.4x local margin (ELZ-036). A split is a possible later task.
  @tag timeout: 1_200_000
  @tag :aggregate_consumer
  test "all selected sources compile and run outside Elzoo with only upstream code paths", ctx do
    ids =
      ctx.registry.entries
      |> Map.values()
      |> Enum.filter(&(&1["status"] == "ready"))
      |> Enum.map(& &1["id"])

    # Inner tests share one consumer with every ready Piece, so Cure reads every
    # copied source root: one inner test hit the default 60 s on symbolic CI
    # (PR #59 run 42327909118). 5x default for this consumer only (ELZ-037).
    assert_cure_consumer(ctx, ids, inner_timeout: 300_000)
  end

  # PostgreSQL consumers share one disposable CI database: in sequence, here. The
  # database-free consumers run from test/consumer_group_{a,b,c}_test.exs (ELZ-049).
  Elzoo.CureConsumerCase.consumer_tests(Elzoo.CureConsumerCase.postgres_consumer_ids())

  test "affected selection only filters the existing consumer tests", ctx do
    selection =
      Elzoo.CheckSelection.for_changes(
        ctx.registry,
        {:ok, ["pieces/delivery/transformation/README.md"]}
      )

    assert selection.selected == ["assembly/request-route-retry", "delivery/transformation"]
    refute selection.aggregate
    assert selection.uncovered == []

    uncovered =
      Elzoo.CheckSelection.for_changes(
        ctx.registry,
        {:ok, ["pieces/workflow/approval/README.md"]}
      )

    assert uncovered.selected == []
    assert uncovered.aggregate
    assert uncovered.uncovered == ["workflow/approval"]
    # Per-ID consumers live in four modules since ELZ-049. Count them together; the inventory is
    # unchanged. A targeted run of this file alone cannot see the other modules.
    for module <- Elzoo.CureConsumerCase.consumer_test_modules() do
      assert Code.ensure_loaded?(module),
             "#{inspect(module)} is not loaded; run the whole suite or include its file"
    end

    tests =
      Enum.flat_map(Elzoo.CureConsumerCase.consumer_test_modules(), & &1.__ex_unit__().tests)

    per_id = Enum.filter(tests, &Map.has_key?(&1.tags, :consumer_id))
    aggregate = Enum.filter(tests, &Map.has_key?(&1.tags, :aggregate_consumer))
    assert length(per_id) == 26
    assert length(aggregate) == 1

    # The per-test limits are part of the measured layout: 240 s for the concurrent groups,
    # 120 s for the sequential PostgreSQL consumers.
    for test <- per_id do
      expected =
        if test.module == __MODULE__,
          do: 120_000,
          else: Elzoo.CureConsumerCase.concurrent_timeout()

      assert test.tags.timeout == expected, "#{test.tags.consumer_id} in #{inspect(test.module)}"
    end

    groups = Elzoo.CureConsumerCase.database_free_groups()
    database_free = Enum.flat_map([:a, :b, :c], &Map.fetch!(groups, &1))

    assert Enum.sort(database_free ++ Elzoo.CureConsumerCase.postgres_consumer_ids()) ==
             Enum.sort(Elzoo.CheckSelection.consumer_ids())

    for id <- database_free,
        entry <- Elzoo.Registry.select!(ctx.registry, [id]),
        provider <- Map.get(entry, "providers", []) do
      refute provider in Elzoo.CureConsumerCase.postgres_providers(),
             "#{id} copies #{entry["id"]}, which needs #{provider}; it cannot run concurrently"
    end

    assert Enum.sort(Enum.map(per_id, & &1.tags.consumer_id)) ==
             Enum.sort(Elzoo.CheckSelection.consumer_ids())

    for test <- per_id do
      assert test.name ==
               String.to_atom(
                 "test #{test.tags.consumer_id} carries its own checks into an independent consumer"
               )
    end

    {opts, [], []} =
      OptionParser.parse(Elzoo.CheckSelection.test_args(selection),
        strict: [exclude: :keep, warnings_as_errors: :boolean]
      )

    filters = opts |> Keyword.get_values(:exclude) |> ExUnit.Filters.parse()
    remaining = Enum.filter(tests, &(ExUnit.Filters.eval([], filters, &1.tags, tests) == :ok))
    assert length(remaining) == length(tests) - 25

    assert Enum.any?(remaining, fn test ->
             test.name == :"test an OTP-only piece runs in a normal independent Mix project"
           end)

    for test <- tests -- (per_id ++ aggregate) do
      assert test in remaining
    end
  end
end
