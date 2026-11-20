# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CureConsumerCaseHelperTest do
  @moduledoc """
  ELZ-289: the copied-consumer harness with controlled consumers (one small Mix project each, no Piece). A
  run that exits 0 without the end of its own suite is rejected, a completed run is accepted, and a consumer
  whose owning test ExUnit kills stops with its actual descendants.
  """
  use ExUnit.Case, async: true

  alias Elzoo.CureConsumerCase

  @helper Path.expand("support/cure_consumer_case_test_helper.exs", __DIR__)

  # A consumer project whose one test prints a nested suite's summary line, then runs `body`.
  defp consumer!(body) do
    destination = CureConsumerCase.create_destination!()
    on_exit(fn -> File.rm_rf!(destination) end)
    File.write!(Path.join(destination, "mix.exs"), CureConsumerCase.project([], false))
    File.mkdir!(Path.join(destination, "test"))

    File.write!(
      Path.join(destination, "test/test_helper.exs"),
      CureConsumerCase.consumer_test_helper(:error)
    )

    File.write!(Path.join(destination, "test/controlled_test.exs"), """
    defmodule ControlledTest do
      use ExUnit.Case

      test "controlled" do
        IO.puts("Result: 63 passed")
        #{body}
      end
    end
    """)

    destination
  end

  test "a consumer that exits 0 after a nested Result line, before its own summary, is rejected" do
    # The VM handles SIGTERM with init:stop/0 and exits 0 in the middle of the test.
    destination =
      consumer!(~S"""
      System.cmd("kill", ["-TERM", System.pid()])
      Process.sleep(:infinity)
      """)

    error =
      assert_raise ExUnit.AssertionError, fn ->
        CureConsumerCase.run_consumer_suite!(destination, [], [], "", "consumer=interrupted")
      end

    assert error.message =~ "the consumer VM exited 0, but its own mix test did not finish"
    assert error.message =~ "Result: 63 passed"
    refute error.message =~ "Result: 1 passed"
  end

  test "a normally completed consumer is accepted" do
    output = CureConsumerCase.run_consumer_suite!(consumer!(""), [], [], "", "consumer=completed")
    assert output =~ "Result: 63 passed"
    assert output =~ "Result: 1 passed"
  end

  test "a consumer whose owning test is killed on its timeout stops with its descendants" do
    record = Path.join(CureConsumerCase.create_destination!(), "descendants")
    on_exit(fn -> File.rm_rf!(Path.dirname(record)) end)

    # The consumer starts a port child (OTP gives it a session of its own) with a background grandchild,
    # writes its own OS PID and every descendant's (PID, parent, command), then blocks.
    destination =
      consumer!(
        String.replace(
          ~S"""
          Task.start(fn -> System.cmd("sh", ["-c", "sleep 600 & sleep 600"]) end)
          root = System.pid()

          tree = fn ->
            {table, 0} = System.cmd("ps", ["-A", "-o", "pid=,ppid=,comm="])
            rows = for line <- String.split(table, "\n", trim: true),
                       [pid, ppid, comm | _] <- [String.split(line)], comm != "ps", do: {pid, ppid, comm}
            seen = Enum.reduce(1..10, MapSet.new([root]), fn _, seen ->
              Enum.reduce(rows, seen, fn {pid, ppid, _}, seen ->
                if ppid in seen, do: MapSet.put(seen, pid), else: seen
              end)
            end)
            Enum.filter(rows, fn {pid, _, _} -> pid in seen end)
          end

          rows = Enum.find_value(1..200, fn _ ->
            rows = tree.()
            if Enum.count(rows, &(elem(&1, 2) == "sleep")) == 2, do: rows, else: Process.sleep(50) && nil
          end)

          File.write!(RECORD, Enum.map_join(rows, "\n", fn {pid, ppid, comm} -> "#{pid} #{ppid} #{comm}" end))
          Process.sleep(:infinity)
          """,
          "RECORD",
          inspect(record)
        )
      )

    owner = Path.join(Path.dirname(record), "owner.exs")

    File.write!(owner, """
    Code.require_file(#{inspect(@helper)})
    ExUnit.start(autorun: false, seed: 0)

    defmodule OwnerTimeoutTest do
      use ExUnit.Case

      # The only short limit: this controlled owner is meant to be killed on it.
      @tag timeout: 10_000
      test "owner" do
        Elzoo.CureConsumerCase.run_consumer_suite!(#{inspect(destination)}, [], [], "", "consumer=owner")
      end
    end

    ExUnit.run()
    """)

    {output, _} =
      System.cmd("elixir", ["-pa", Mix.Project.compile_path(), owner],
        cd: Path.dirname(record),
        stderr_to_stdout: true
      )

    assert output =~ "test timed out after 10000ms", output

    assert File.exists?(record),
           "the consumer recorded no descendants before its owner was killed\n" <> output

    rows = for line <- File.read!(record) |> String.split("\n"), do: String.split(line)
    left = running(Enum.map(rows, &hd/1))
    if left != [], do: System.cmd("kill", ["-KILL" | left], stderr_to_stdout: true)

    # The consumer VM, its port helper erl_child_setup, the port child sh and its two sleep children.
    assert Enum.map(rows, &List.last/1)
           |> Enum.frequencies()
           |> Map.take(~w(sh sleep erl_child_setup)) ==
             %{"sh" => 1, "sleep" => 2, "erl_child_setup" => 1}

    assert left == [], "still running after the owner was killed: #{inspect(left)}"
  end

  # PIDs of `pids` that run (a zombie has ended and waits only to be reaped).
  defp running(pids) do
    {table, _} = System.cmd("ps", ["-o", "pid=,stat=", "-p", Enum.join(pids, ",")])

    for line <- String.split(table, "\n", trim: true),
        [pid, stat] <- [String.split(line)],
        not String.starts_with?(stat, "Z"),
        do: pid
  end
end
