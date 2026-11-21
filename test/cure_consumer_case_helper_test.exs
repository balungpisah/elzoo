# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CureConsumerCaseHelperTest do
  @moduledoc """
  ELZ-289: the copied-consumer harness with controlled consumers (one small Mix project each, no Piece). A
  run that exits 0 without the end of its own suite is rejected, a completed run is accepted, and a consumer
  whose owning test ExUnit kills stops with its actual descendants. ELZ-291: also while a descendant forks.
  """
  use ExUnit.Case, async: true

  alias Elzoo.CureConsumerCase

  @helper Path.expand("support/cure_consumer_case_test_helper.exs", __DIR__)

  # ELZ-291: forks continuously. Each fork copies 60,000 mappings (of alternating protection, so they cannot
  # merge; below Linux's default limit of 65,530 per process) and takes tens of milliseconds, so a stop
  # signal often arrives while a fork is in flight. Each child appends its PID to the file named by argv[1],
  # then becomes `sleep 60`. Only the two newest children are kept, so the cleanup walk is short and often
  # ends before a fork in flight has returned.
  @forker ~S"""
  import mmap, os, shutil, signal, sys
  log = os.open(sys.argv[1], os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
  sleep = shutil.which("sleep")
  maps = [mmap.mmap(-1, 4096, prot=mmap.PROT_READ | (i % 2) * mmap.PROT_WRITE) for i in range(60000)]
  children = []
  while True:
      pid = os.fork()
      if pid == 0:
          os.write(log, b"%d\n" % os.getpid())
          os.execv(sleep, ["sleep", "60"])
      children.append(pid)
      if len(children) > 2:
          old = children.pop(0)
          os.kill(old, signal.SIGKILL)
          os.waitpid(old, 0)
  """

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
    dir = CureConsumerCase.create_destination!()
    on_exit(fn -> File.rm_rf!(dir) end)

    # A port child (OTP gives it a session of its own) with a background grandchild.
    rows =
      killed_owner!(
        dir,
        ~S|Task.start(fn -> System.cmd("sh", ["-c", "sleep 600 & sleep 600"]) end)|,
        ~S|Enum.count(rows, &(elem(&1, 2) == "sleep")) == 2|
      )

    left = kill_running(Enum.map(rows, &hd/1), 0)

    # The consumer VM, its port helper erl_child_setup, the port child sh and its two sleep children.
    assert Enum.map(rows, &List.last/1)
           |> Enum.frequencies()
           |> Map.take(~w(sh sleep erl_child_setup)) ==
             %{"sh" => 1, "sleep" => 2, "erl_child_setup" => 1}

    assert left == [], "still running after the owner was killed: #{inspect(left)}"
  end

  test "a consumer whose owning test is killed while a descendant forks stops with every child" do
    dir = CureConsumerCase.create_destination!()
    on_exit(fn -> File.rm_rf!(dir) end)
    forked = Path.join(dir, "forked")

    # A port child that forks continuously; the tree is recorded once two of its children run `sleep`.
    rows =
      killed_owner!(
        dir,
        "Task.start(fn -> System.cmd(\"python3\", #{inspect(["-I", "-c", @forker, forked])}) end)",
        ~S|Enum.count(rows, &(elem(&1, 2) == "sleep")) >= 2|
      )

    children = String.split(File.read!(forked))

    # A killed forker can take a moment to end (it unmaps 60,000 mappings); an escaped child is a `sleep 60`.
    left = kill_running(Enum.map(rows, &hd/1) ++ children, 40)
    # A forker that cleanup missed went on forking while kill_running waited.
    later = String.split(File.read!(forked)) -- children
    if later != [], do: kill_running(later, 0)

    assert length(children) >= 3

    assert left == [],
           "still running after the owner was killed: #{inspect(left)} of #{length(children)} forked"
  end

  # Runs a consumer whose test evaluates `start`, waits until `ready` holds for `rows`, its OS process tree
  # ({pid, ppid, comm} of its own OS PID and every descendant's, from `ps`), writes that tree to a record in
  # `dir` and keeps writing output (the end of its output pipe would end it before its children). Its owner
  # is an inner ExUnit test that ExUnit kills on its timeout. Returns the recorded rows as [pid, ppid, comm].
  defp killed_owner!(dir, start, ready) do
    record = Path.join(dir, "descendants")

    tree =
      String.replace(
        ~S"""
        root = System.pid()

        tree = fn ->
          {table, 0} = System.cmd("ps", ["-A", "-o", "pid=,ppid=,comm="])
          rows = for line <- String.split(table, "\n", trim: true),
                     [pid, ppid, comm | _] <- [String.split(line)], Path.basename(comm) != "ps",
                     do: {pid, ppid, Path.basename(comm)}
          seen = Enum.reduce(1..10, MapSet.new([root]), fn _, seen ->
            Enum.reduce(rows, seen, fn {pid, ppid, _}, seen ->
              if ppid in seen, do: MapSet.put(seen, pid), else: seen
            end)
          end)
          Enum.filter(rows, fn {pid, _, _} -> pid in seen end)
        end

        rows = Enum.find_value(1..200, fn _ ->
          rows = tree.()
          if READY, do: rows, else: Process.sleep(50) && nil
        end)

        File.write!(RECORD, Enum.map_join(rows, "\n", fn {pid, ppid, comm} -> "#{pid} #{ppid} #{comm}" end))
        Stream.repeatedly(fn -> IO.write("."); Process.sleep(2) end) |> Stream.run()
        """,
        ["READY", "RECORD"],
        fn
          "READY" -> ready
          "RECORD" -> inspect(record)
        end
      )

    destination = consumer!(start <> "\n" <> tree)
    owner = Path.join(dir, "owner.exs")

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
        cd: dir,
        stderr_to_stdout: true
      )

    assert output =~ "test timed out after 10000ms", output

    assert File.exists?(record),
           "the consumer recorded no descendants before its owner was killed\n" <> output

    for line <- File.read!(record) |> String.split("\n"), do: String.split(line)
  end

  # `ps` rows ("pid stat command") of the PIDs of `pids` that still run, killed so none outlives the case. A
  # zombie has ended and waits only to be reaped. With `tries`, a process gets up to `tries` × 50 ms to end.
  defp kill_running(pids, tries) do
    {table, _} = System.cmd("ps", ["-o", "pid=,stat=,comm=", "-p", Enum.join(pids, ",")])

    left =
      for line <- String.split(table, "\n", trim: true),
          [pid, stat | _] <- [String.split(line)],
          not String.starts_with?(stat, "Z"),
          do: {pid, String.trim(line)}

    left_pids = Enum.map(left, &elem(&1, 0))

    cond do
      left == [] ->
        []

      tries > 0 ->
        Process.sleep(50)
        kill_running(left_pids, tries - 1)

      true ->
        System.cmd("kill", ["-KILL" | left_pids], stderr_to_stdout: true)
        Enum.map(left, &elem(&1, 1))
    end
  end
end
