# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CheckedCommandCopySupportTest do
  use ExUnit.Case, async: false

  @root File.cwd!()
  @piece_id "assembly/checked-command"
  @checked_test "test/elzoo/checked_command_test.exs"
  @sql_helper "test/support/durable_log_postgres_test_helper.exs"
  @source_sql_helper "pieces/integration/sql/test/support/durable_log_postgres_test_helper.exs"
  @probe_sentinel "sql-test-support-sentinel"

  test "the exported CheckedCommand test keeps real SQL support in either load order" do
    destination = consumer_destination!()
    on_exit(fn -> File.rm_rf!(destination) end)

    plan =
      @root
      |> Elzoo.Registry.load!()
      |> Elzoo.Export.plan!([@piece_id], destination)

    assert Enum.any?(plan.pieces, &(&1["id"] == "integration/sql"))
    assert Map.has_key?(plan.files, @sql_helper)
    assert Map.has_key?(plan.files, @checked_test)
    assert :ok = Elzoo.Export.write!(plan)

    sql_helper = Path.join(destination, @sql_helper)
    checked_test = Path.join(destination, @checked_test)

    assert File.regular?(sql_helper)
    assert File.regular?(checked_test)

    assert Path.expand(
             "../support/durable_log_postgres_test_helper.exs",
             Path.dirname(checked_test)
           ) == sql_helper

    for order <- [:support_first, :checked_test_first] do
      output =
        run_child!(
          destination,
          support_order_script(order, checked_test, sql_helper)
        )

      assert output =~ "REAL_SHARED_HELPER=true"
      assert output =~ "POSTGRES_CASES=17 ENABLED=true"
    end
  end

  test "missing copied SQL support fails closed without replacing loaded support" do
    destination = consumer_destination!()
    on_exit(fn -> File.rm_rf!(destination) end)
    checked_test = Path.join(destination, @checked_test)
    File.mkdir_p!(Path.dirname(checked_test))
    File.cp!(Path.join(@root, "pieces/assembly/checked-command/" <> @checked_test), checked_test)

    output =
      run_child!(
        destination,
        missing_support_script(checked_test, Path.join(@root, @source_sql_helper))
      )

    assert output =~ "MISSING_SUPPORT_FAILS_CLOSED=true"
    assert output =~ "REAL_SHARED_HELPER_PRESERVED=true"
  end

  defp consumer_destination! do
    destination = Elzoo.CureConsumerCase.create_destination!()
    File.write!(Path.join(destination, "mix.exs"), Elzoo.CureConsumerCase.project([], false))
    destination
  end

  defp run_child!(destination, script) do
    compiled_libs = Path.join([@root, "_build", "test", "lib"])

    paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.map(&Path.expand(&1, @root))
      |> Enum.filter(fn path ->
        Path.basename(path) == "ebin" and Path.dirname(Path.dirname(path)) == compiled_libs
      end)
      |> Enum.sort()

    args = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", script]

    {output, status} =
      System.cmd("elixir", args,
        cd: destination,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}]
      )

    assert status == 0, output
    output
  end

  defp support_order_script(order, checked_test, sql_helper) do
    loads =
      case order do
        :support_first ->
          "Code.require_file(#{inspect(sql_helper)})\nCode.require_file(#{inspect(checked_test)})"

        :checked_test_first ->
          "Code.require_file(#{inspect(checked_test)})\nCode.require_file(#{inspect(sql_helper)})"
      end

    """
    System.put_env("ELZOO_TEST_DATABASE_URL", #{@probe_sentinel |> inspect()})
    ExUnit.start(autorun: false, seed: 0)
    #{loads}

    tests = Elzoo.CheckedCommandTest.__ex_unit__().tests
    postgres_tests = Enum.filter(tests, &Map.get(&1.tags, :postgres, false))
    enabled = postgres_tests != [] and Enum.all?(postgres_tests, &(not Map.get(&1.tags, :skip, false)))

    unless Elzoo.DurableLog.PostgresHarness.database_url!() == System.get_env("ELZOO_TEST_DATABASE_URL") and
             Elzoo.DurableLog.TestRepo.__adapter__() == Ecto.Adapters.Postgres and
             length(postgres_tests) == 17 and enabled do
      raise "copied SQL support was replaced or PostgreSQL cases were disabled"
    end

    IO.puts("REAL_SHARED_HELPER=true")
    IO.puts("POSTGRES_CASES=\#{length(postgres_tests)} ENABLED=\#{enabled}")
    """
  end

  defp missing_support_script(checked_test, source_sql_helper) do
    """
    System.put_env("ELZOO_TEST_DATABASE_URL", #{@probe_sentinel |> inspect()})
    ExUnit.start(autorun: false, seed: 0)
    Code.require_file(#{inspect(source_sql_helper)})

    try do
      Code.require_file(#{inspect(checked_test)})
      raise "missing SQL support did not fail closed"
    rescue
      error in RuntimeError ->
        unless String.contains?(error.message, "CheckedCommand PostgreSQL test support is unavailable"),
          do: reraise(error, __STACKTRACE__)
    end

    unless Elzoo.DurableLog.PostgresHarness.database_url!() == System.get_env("ELZOO_TEST_DATABASE_URL") and
             Elzoo.DurableLog.TestRepo.__adapter__() == Ecto.Adapters.Postgres do
      raise "missing support replaced the shared SQL helper"
    end

    IO.puts("MISSING_SUPPORT_FAILS_CLOSED=true")
    IO.puts("REAL_SHARED_HELPER_PRESERVED=true")
    """
  end
end
