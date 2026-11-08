# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.OsProcessTest do
  @moduledoc """
  Real-process scenarios for runtime/os-isolation through erlexec 2.6.0. Row IDs refer to the
  transition table in the Piece README. Group death is asserted by this test's own `pgrep -g`.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Elzoo.OsProcess

  @sh "/bin/sh"
  @fixture Path.join(__DIR__, "os_process_fixture.sh")
  @pgrep System.find_executable("pgrep")
  @kill System.find_executable("kill")
  @moduletag timeout: 60_000

  setup_all do
    :ok = Elzoo.OsProcess.Provider.ensure_started()
    :ok
  end

  defp start(opts \\ []) do
    defaults = [
      max_concurrent: 2,
      queue_limit: 2,
      queue_timeout_ms: 2_000,
      grace_s: 1,
      observe_timeout_ms: 2_000
    ]

    start_supervised!({OsProcess, Keyword.merge(defaults, opts)}, id: make_ref())
  end

  defp spec(mode, args \\ [], extra \\ %{}),
    do: Map.merge(%{executable: @sh, args: [@fixture, mode | Enum.map(args, &to_string/1)]}, extra)

  defp result(ref, timeout \\ 20_000) do
    receive do
      {OsProcess, ^ref, result} -> result
    after
      timeout -> flunk("no result for #{inspect(ref)} within #{timeout} ms")
    end
  end

  defp members(os_pid) do
    case System.cmd(@pgrep, ["-g", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&String.to_integer/1)
      {_, 1} -> []
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if fun.(),
        do: :ok,
        else:
          (
            Process.sleep(25)
            :wait
          )
    end)
    |> Enum.find(fn r -> r == :ok or System.monotonic_time(:millisecond) >= deadline end)
  end

  defp wait_empty(os_pid, timeout_ms \\ 4_000),
    do: wait_until(fn -> members(os_pid) == [] end, timeout_ms)

  defp kill_group(os_pid),
    do: System.cmd(@kill, ["-s", "KILL", "--", "-#{os_pid}"], stderr_to_stdout: true)

  defp kill_pid(pid), do: System.cmd(@kill, ["-s", "KILL", "#{pid}"], stderr_to_stdout: true)

  defp os_pid_of(sup, ref),
    do:
      wait_until(fn -> match?(%{os_pid: p} when is_integer(p), OsProcess.info(sup, ref)) end, 5_000) &&
        OsProcess.info(sup, ref).os_pid

  defp tmp_script(name, body) do
    path =
      Path.join(
        System.tmp_dir!(),
        "elzoo-os-process-#{name}-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # ---- T1 and Config

  test "T1 malformed spec and options are rejected synchronously" do
    sup = start()

    assert {:error, {:invalid_spec, :executable}} =
             OsProcess.submit(sup, %{executable: "sh"}, max_run_ms: 100)

    assert {:error, {:invalid_spec, :deadline}} = OsProcess.submit(sup, spec("exit", [0]), [])

    assert {:error, {:invalid_spec, :env}} =
             OsProcess.submit(sup, spec("exit", [0], %{env: %{other: 1}}), max_run_ms: 100)

    assert {:error, {:invalid_spec, :args}} =
             OsProcess.submit(sup, %{executable: @sh, args: [1]}, max_run_ms: 100)

    assert {:error, {:invalid_spec, :cwd}} =
             OsProcess.submit(sup, spec("exit", [0], %{cwd: "relative"}), max_run_ms: 100)

    assert {:error, {:invalid_spec, :max_run_ms}} =
             OsProcess.submit(sup, spec("exit", [0]), max_run_ms: 0)

    assert {:error, {:invalid_spec, :request}} =
             OsProcess.submit(sup, spec("exit", [0]), max_run_ms: 100, request: %{"x" => "y"})

    assert {:error, {:invalid_spec, :deadline_too_far}} =
             OsProcess.submit(sup, spec("exit", [0]),
               deadline_unix_ms: System.os_time(:millisecond) + 5_000_000_000
             )
  end

  test "Config: every setting is validated; hot update is not offered" do
    assert {:error, {:invalid_config, :max_concurrent}} =
             OsProcess.start_link(max_concurrent: 0, queue_limit: 0, queue_timeout_ms: 1)

    assert {:error, {:invalid_config, :queue_limit}} =
             OsProcess.start_link(max_concurrent: 1, queue_limit: -1, queue_timeout_ms: 1)

    assert {:error, {:invalid_config, :queue_timeout_ms}} =
             OsProcess.start_link(
               max_concurrent: 1,
               queue_limit: 0,
               queue_timeout_ms: 4_294_967_296
             )

    assert {:error, {:invalid_config, :grace_s}} =
             OsProcess.start_link(
               max_concurrent: 1,
               queue_limit: 0,
               queue_timeout_ms: 1,
               grace_s: 0
             )

    assert {:error, {:invalid_config, :observe_timeout_ms}} =
             OsProcess.start_link(
               max_concurrent: 1,
               queue_limit: 0,
               queue_timeout_ms: 1,
               observe_timeout_ms: 0
             )

    assert {:error, {:invalid_config, :max_output_bytes}} =
             OsProcess.start_link(
               max_concurrent: 1,
               queue_limit: 0,
               queue_timeout_ms: 1,
               max_output_bytes: 0
             )

    assert {:error, {:tool_unavailable, :pgrep}} =
             OsProcess.start_link(
               max_concurrent: 1,
               queue_limit: 0,
               queue_timeout_ms: 1,
               pgrep_path: "/nonexistent/pgrep"
             )

    assert {:error, {:invalid_config, :now_unix_ms}} =
             OsProcess.start_link(
               max_concurrent: 1,
               queue_limit: 0,
               queue_timeout_ms: 1,
               now_unix_ms: :no
             )

    assert {:error, {:invalid_config, :provider_user}} =
             OsProcess.start_link(
               max_concurrent: 1,
               queue_limit: 0,
               queue_timeout_ms: 1,
               provider_user: ""
             )

    assert {:error, {:invalid_config, :test_hooks}} =
             OsProcess.start_link(
               max_concurrent: 1,
               queue_limit: 0,
               queue_timeout_ms: 1,
               test_hooks: %{a: 1}
             )

    assert {:error, {:invalid_config, :options}} = OsProcess.start_link(%{})
    sup = start()
    assert %{in_flight: 0, queued: 0, capacity: 2} = OsProcess.snapshot(sup)
  end

  # ---- normal completion (T11)

  test "T11 normal exit: exit code 0, merged stdout and stderr, group empty, os_pid reported" do
    sup = start()
    {:ok, ref} = OsProcess.submit(sup, spec("stderr"), max_run_ms: 5_000)

    assert %{
             status: :completed,
             exit_code: 0,
             output: output,
             truncated: false,
             leftovers: :none,
             os_pid: os_pid
           } = result(ref)

    assert output =~ "out" and output =~ "err"
    assert members(os_pid) == []
  end

  test "T11 non-zero exit is completed, not an error" do
    sup = start()

    assert {:ok, %{status: :completed, exit_code: 7}} =
             OsProcess.run(sup, spec("exit", [7]), max_run_ms: 5_000)
  end

  test "T11 a command that ends itself with SIGTERM is completed with 143" do
    sup = start()

    assert {:ok, %{status: :completed, exit_code: 143}} =
             OsProcess.run(sup, spec("self-term"), max_run_ms: 5_000)
  end

  # ---- deadline (T14, T15, T16, C1, C3)

  test "T14 deadline, SIGTERM honoured: the provider's reported signal is an observation in unknown, never a stage; group empty" do
    sup = start()
    {:ok, ref} = OsProcess.submit(sup, spec("sleep", [30]), max_run_ms: 300)
    os_pid = os_pid_of(sup, ref)

    assert %{
             status: :unknown,
             reason: :signal_after_deadline,
             signal: :sigterm,
             exit_code: 143,
             members: [],
             os_pid: ^os_pid
           } = result = result(ref)

    refute Map.has_key?(result, :stage)
    assert members(os_pid) == []
  end

  test "T15/C1 deadline, SIGTERM ignored: the provider escalates to SIGKILL; the reported signal is sigkill, never sigterm" do
    sup = start(grace_s: 1)
    {:ok, ref} = OsProcess.submit(sup, spec("ignore-term", [30]), max_run_ms: 300)
    os_pid = os_pid_of(sup, ref)

    assert %{
             status: :unknown,
             reason: :signal_after_deadline,
             signal: :sigkill,
             exit_code: 137,
             output: "ignoring\n"
           } = result(ref)

    assert members(os_pid) == []
  end

  test "B1 a command that signals itself after the deadline is unknown, the same as the provider's signal" do
    sup = start(grace_s: 3)
    {:ok, ref} = OsProcess.submit(sup, spec("late-self-term", ["0.8"]), max_run_ms: 200)
    os_pid = os_pid_of(sup, ref)

    assert %{status: :unknown, reason: :signal_after_deadline, signal: :sigterm} = result(ref)
    assert members(os_pid) == []
  end

  test "T16 deadline with a background member in the group: the whole group is gone" do
    sup = start()
    {:ok, ref} = OsProcess.submit(sup, spec("child", [30]), max_run_ms: 400)
    os_pid = os_pid_of(sup, ref)
    assert :ok = wait_until(fn -> length(members(os_pid)) >= 2 end, 2_000)
    assert %{status: :unknown, reason: :signal_after_deadline} = result(ref)
    assert members(os_pid) == []
  end

  test "C3 natural exit during the provider's grace is completed, not terminated" do
    sup = start(grace_s: 3)
    {:ok, ref} = OsProcess.submit(sup, spec("natural-exit", ["0.5"]), max_run_ms: 150)
    assert %{status: :completed, exit_code: 0, output: "ignoring\n"} = result(ref)
  end

  test "T12 a member that closed stdout and lingers after the leader exit is reaped by the provider's at-exit TERM" do
    sup = start()
    {:ok, ref} = OsProcess.submit(sup, spec("linger", [30]), max_run_ms: 5_000)
    assert %{status: :completed, exit_code: 0, leftovers: leftovers, os_pid: os_pid} = result(ref)
    assert leftovers in [:none, :reaped]
    assert members(os_pid) == []
  end

  test "T13 a TERM-ignoring member after the leader exit is reported as unknown{group_alive} with members (D4)" do
    sup = start(observe_timeout_ms: 1_200)
    {:ok, ref} = OsProcess.submit(sup, spec("linger-ignore", [30]), max_run_ms: 5_000)

    assert %{
             status: :unknown,
             reason: :group_alive,
             members: [_ | _] = pids,
             os_pid: os_pid,
             exit_code: 0
           } = result(ref)

    on_exit(fn -> kill_group(os_pid) end)
    assert Enum.all?(pids, &is_integer/1)
    kill_group(os_pid)
    assert :ok = wait_empty(os_pid)
  end

  test "T15 a deadline command that ignores TERM and exits leaves the group empty before the result arrives" do
    sup = start()
    {:ok, ref} = OsProcess.submit(sup, spec("ignore-term", [30]), max_run_ms: 200)
    os_pid = os_pid_of(sup, ref)
    result = result(ref)
    assert %{status: :unknown, reason: :signal_after_deadline} = result
    assert members(os_pid) == []
  end

  # ---- queue and admission (T2–T8)

  test "T2/T8 a deadline already passed is expired, not dispatched" do
    sup = start()

    {:ok, ref} =
      OsProcess.submit(sup, spec("exit", [0]), deadline_unix_ms: System.os_time(:millisecond) - 1)

    assert %{status: :expired} = result(ref)
    assert OsProcess.info(sup, ref) == nil
  end

  test "T3/T4 queue_full and queue_timeout are distinct rejections" do
    sup = start(max_concurrent: 1, queue_limit: 1, queue_timeout_ms: 300)
    {:ok, running} = OsProcess.submit(sup, spec("sleep", [30]), max_run_ms: 10_000)
    os_pid = os_pid_of(sup, running)
    {:ok, queued} = OsProcess.submit(sup, spec("exit", [0]), max_run_ms: 1_000)
    {:ok, third} = OsProcess.submit(sup, spec("exit", [0]), max_run_ms: 1_000)
    assert %{status: :rejected, reason: :queue_full} = result(third)
    assert %{status: :rejected, reason: :queue_timeout} = result(queued)
    assert %{in_flight: 1, queued: 0} = OsProcess.snapshot(sup)
    assert {:ok, :requested} = OsProcess.cancel(sup, running)
    assert %{status: :unknown, reason: :provider_masked_stop, cause: :cancel} = result(running)
    assert members(os_pid) == []
  end

  test "T5 the deadline wins over the queue: a queued request expires, never completes" do
    sup = start(max_concurrent: 1, queue_limit: 1, queue_timeout_ms: 5_000)
    {:ok, running} = OsProcess.submit(sup, spec("sleep", [30]), max_run_ms: 10_000)
    _ = os_pid_of(sup, running)

    {:ok, queued} =
      OsProcess.submit(sup, spec("exit", [0]), deadline_unix_ms: System.os_time(:millisecond) + 300)

    assert %{status: :expired} = result(queued)
    assert {:ok, :requested} = OsProcess.cancel(sup, running)
    assert %{status: :unknown} = result(running)
  end

  test "T7 cancelling a queued request yields rejected{cancelled}; the slot flow continues" do
    sup = start(max_concurrent: 1, queue_limit: 2, queue_timeout_ms: 5_000)
    {:ok, running} = OsProcess.submit(sup, spec("sleep", [30]), max_run_ms: 10_000)
    _ = os_pid_of(sup, running)
    {:ok, queued} = OsProcess.submit(sup, spec("exit", [3]), max_run_ms: 5_000)
    {:ok, queued2} = OsProcess.submit(sup, spec("exit", [4]), max_run_ms: 5_000)
    assert {:ok, :requested} = OsProcess.cancel(sup, queued)
    assert %{status: :rejected, reason: :cancelled} = result(queued)
    assert {:ok, :requested} = OsProcess.cancel(sup, running)
    assert %{status: :unknown, cause: :cancel} = result(running)
    assert %{status: :completed, exit_code: 4} = result(queued2)
    assert {:error, :unknown_run} = OsProcess.cancel(sup, queued2)
  end

  test "T6 a submitter that dies while queued is dropped" do
    sup = start(max_concurrent: 1, queue_limit: 2, queue_timeout_ms: 5_000)
    {:ok, running} = OsProcess.submit(sup, spec("sleep", [30]), max_run_ms: 10_000)
    _ = os_pid_of(sup, running)
    parent = self()

    pid =
      spawn(fn ->
        {:ok, ref} = OsProcess.submit(sup, spec("exit", [0]), max_run_ms: 5_000)
        send(parent, {:queued, ref})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:queued, _}, 2_000
    assert %{queued: 1} = OsProcess.snapshot(sup)
    Process.exit(pid, :kill)
    assert :ok = wait_until(fn -> OsProcess.snapshot(sup).queued == 0 end, 2_000)
    assert {:ok, :requested} = OsProcess.cancel(sup, running)
    assert %{status: :unknown} = result(running)
  end

  test "capacity conservation: six submits on two slots never exceed two in flight and all settle" do
    sup = start(max_concurrent: 2, queue_limit: 4, queue_timeout_ms: 10_000)

    refs =
      for _ <- 1..6, do: elem(OsProcess.submit(sup, spec("sleep", ["0.2"]), max_run_ms: 5_000), 1)

    peaks =
      Stream.repeatedly(fn ->
        Process.sleep(20)
        OsProcess.snapshot(sup).in_flight
      end)
      |> Enum.take(20)

    assert Enum.max(peaks) <= 2
    for ref <- refs, do: assert(%{status: :completed, exit_code: 0} = result(ref))

    assert :ok =
             wait_until(
               fn -> OsProcess.snapshot(sup) == %{in_flight: 0, queued: 0, capacity: 2} end,
               2_000
             )
  end

  # ---- review findings on PR #120 (F1-F5)

  test "F1/F5 cancelling queued requests prunes the FIFO while a slot stays occupied; a repeated cancel is idempotent" do
    sup = start(max_concurrent: 1, queue_limit: 1, queue_timeout_ms: 30_000)
    {:ok, running} = OsProcess.submit(sup, spec("sleep", [30]), max_run_ms: 60_000)
    _ = os_pid_of(sup, running)

    refs =
      for _ <- 1..50 do
        {:ok, ref} = OsProcess.submit(sup, spec("exit", [0]), max_run_ms: 5_000)
        assert {:ok, :requested} = OsProcess.cancel(sup, ref)
        assert %{status: :rejected, reason: :cancelled} = result(ref)
        assert {:ok, :already_requested} = OsProcess.cancel(sup, ref)
        ref
      end

    state = :sys.get_state(OsProcess.adapter(sup))
    assert :queue.len(state.queue) == 0
    assert state.queued == %{}
    assert %{queued: 0, in_flight: 1} = OsProcess.snapshot(sup)
    assert {:ok, :already_requested} = OsProcess.cancel(sup, hd(refs))
    assert {:ok, :requested} = OsProcess.cancel(sup, running)
    assert %{status: :unknown} = result(running)
  end

  test "F2 an owner death keeps its slot until the group is observed empty; the queued command waits" do
    sup = start(max_concurrent: 1, queue_limit: 1, queue_timeout_ms: 30_000, grace_s: 1)
    {:ok, first} = OsProcess.submit(sup, spec("ignore-term", [30]), max_run_ms: 60_000)
    os_pid = os_pid_of(sup, first)
    %{owner: owner} = OsProcess.info(sup, first)
    {:ok, second} = OsProcess.submit(sup, spec("exit", [0]), max_run_ms: 5_000)
    assert %{in_flight: 1, queued: 1} = OsProcess.snapshot(sup)
    Process.exit(owner, :kill)
    Process.sleep(200)
    # the TERM-ignoring group is still alive during the provider's grace: the second must not start
    assert members(os_pid) != []
    assert %{in_flight: 1, queued: 1} = OsProcess.snapshot(sup)
    assert OsProcess.info(sup, second) == nil
    assert %{status: :unknown, reason: :owner_exit, members: []} = result(first)
    assert members(os_pid) == []
    assert %{status: :completed, exit_code: 0} = result(second)
  end

  test "F3 run/3 waits for the request's own bound; a shorter await_ms cancels and reports the ref" do
    sup = start(queue_timeout_ms: 1_000, grace_s: 1, observe_timeout_ms: 500)

    assert %{queue_timeout_ms: 1_000, grace_ms: 1_000, observe_timeout_ms: 500} =
             OsProcess.bounds(sup)

    assert {:ok, %{status: :completed, exit_code: 0}} =
             OsProcess.run(sup, spec("sleep", ["0.2"]), max_run_ms: 10_000)

    assert {:error, {:no_result, ref}} =
             OsProcess.run(sup, spec("sleep", [30]), max_run_ms: 60_000, await_ms: 300)

    assert %{status: :unknown, reason: :provider_masked_stop, cause: :cancel} = result(ref)
  end

  test "F4 a SIGTERM the command sends itself before the deadline instant is completed 143, not a timeout" do
    sup = start()

    assert {:ok, %{status: :completed, exit_code: 143}} =
             OsProcess.run(sup, spec("self-term"), max_run_ms: 1_500)
  end

  test "F6 an Adapter restart while an owner-death observation runs keeps that slot counted" do
    sup = start(max_concurrent: 1, queue_limit: 1, queue_timeout_ms: 30_000, grace_s: 2)
    {:ok, first} = OsProcess.submit(sup, spec("ignore-term", [30]), max_run_ms: 60_000)
    os_pid = os_pid_of(sup, first)
    %{owner: owner} = OsProcess.info(sup, first)
    adapter = OsProcess.adapter(sup)
    Process.exit(owner, :kill)
    assert :ok = wait_until(fn -> map_size(:sys.get_state(adapter).observing) == 1 end, 2_000)
    Process.exit(adapter, :kill)

    assert :ok =
             wait_until(
               fn -> is_pid(OsProcess.adapter(sup)) and OsProcess.adapter(sup) != adapter end,
               2_000
             )

    assert %{in_flight: 1} = OsProcess.snapshot(sup)
    {:ok, second} = OsProcess.submit(sup, spec("exit", [0]), max_run_ms: 5_000)
    assert %{in_flight: 1, queued: 1} = OsProcess.snapshot(sup)
    assert members(os_pid) != []
    assert %{status: :unknown, reason: :owner_exit, members: []} = result(first)
    refute_receive {OsProcess, ^first, _}, 300
    assert members(os_pid) == []
    assert %{status: :completed, exit_code: 0} = result(second)
    assert :ok = wait_until(fn -> OsProcess.snapshot(sup).in_flight == 0 end, 2_000)
  end

  test "F7 a slow step between exec:run and registration does not turn a provider timeout into completed" do
    sup = start(test_hooks: %{after_run: fn -> Process.sleep(250) end})
    {:ok, ref} = OsProcess.submit(sup, spec("sleep", [30]), max_run_ms: 300)
    assert %{status: :unknown, reason: :signal_after_deadline, signal: :sigterm} = result(ref)
  end

  test "R2 a cancel accepted while exec:run is still in progress stops the group once os_pid is known" do
    sup = start(test_hooks: %{before_run: fn -> Process.sleep(400) end})
    {:ok, ref} = OsProcess.submit(sup, spec("sleep", [30]), max_run_ms: 20_000)
    assert {:ok, :requested} = OsProcess.cancel(sup, ref)
    assert {:ok, :already_requested} = OsProcess.cancel(sup, ref)

    assert %{status: :unknown, reason: :provider_masked_stop, cause: :cancel, os_pid: os_pid} =
             result(ref)

    assert is_integer(os_pid)
    assert members(os_pid) == []
  end

  test "R2 a submitter that dies while exec:run is still in progress: the group is stopped" do
    sup = start(test_hooks: %{before_run: fn -> Process.sleep(400) end})
    before = :exec.which_children()
    parent = self()

    pid =
      spawn(fn ->
        {:ok, ref} = OsProcess.submit(sup, spec("sleep", [30]), max_run_ms: 20_000)
        send(parent, {:ref, ref})

        receive do
          :never -> :ok
        end
      end)

    ref =
      receive do
        {:ref, r} -> r
      after
        2_000 -> flunk("no ref")
      end

    Process.exit(pid, :kill)
    os_pid = os_pid_of(sup, ref)
    assert is_integer(os_pid)
    assert :ok = wait_empty(os_pid)
    assert :ok = wait_until(fn -> :exec.which_children() -- before == [] end, 5_000)
    assert :ok = wait_until(fn -> OsProcess.snapshot(sup).in_flight == 0 end, 5_000)
  end

  test "T10 the provider refuses the request before fork: rejected{spawn_failed}, no child exists" do
    sup = start()
    before = :exec.which_children()

    assert {:ok, %{status: :rejected, reason: :spawn_failed}} =
             OsProcess.run(sup, spec("exit", [0], %{env: %{inherit: [], set: [{"EMPTY", ""}]}}),
               max_run_ms: 2_000
             )

    assert :exec.which_children() -- before == []
  end

  test "T8/T30 the deadline passes while the slot frees: dispatch-time expiry, and the late queue timer is ignored" do
    sup = start(max_concurrent: 1, queue_limit: 1, queue_timeout_ms: 10_000)
    {:ok, running} = OsProcess.submit(sup, spec("exit", [0]), max_run_ms: 5_000)

    {:ok, queued} =
      OsProcess.submit(sup, spec("exit", [0]), deadline_unix_ms: System.os_time(:millisecond) + 400)

    adapter = OsProcess.adapter(sup)
    :ok = :sys.suspend(adapter)
    # the running command finishes (owner DOWN enters the mailbox) before the queued deadline;
    # the queue timer message for the deadline enters the mailbox after it
    assert %{status: :completed} = result(running)
    Process.sleep(700)
    :ok = :sys.resume(adapter)
    assert %{status: :expired} = result(queued)
    refute_receive {OsProcess, ^queued, _}, 500
    assert %{in_flight: 0, queued: 0} = OsProcess.snapshot(sup)
    assert OsProcess.info(sup, queued) == nil
  end

  # ---- spawn failure (T9) and exec failure after validation (B5)

  test "T9 pre-dispatch validation: missing file, no execute bit, missing cwd are rejected{spawn_failed}" do
    sup = start()

    assert {:ok, %{status: :rejected, reason: :spawn_failed}} =
             OsProcess.run(sup, %{executable: "/nonexistent/bin/x"}, max_run_ms: 1_000)

    noexec = tmp_script("noexec", "exit 0\n")
    File.chmod!(noexec, 0o644)

    assert {:ok, %{status: :rejected, reason: :spawn_failed}} =
             OsProcess.run(sup, %{executable: noexec}, max_run_ms: 1_000)

    assert {:ok, %{status: :rejected, reason: :spawn_failed}} =
             OsProcess.run(sup, spec("exit", [0], %{cwd: "/nonexistent/dir"}), max_run_ms: 1_000)
  end

  test "B5 an exec failure after validation is reported by the provider as exit 1 (declared residual)" do
    sup = start()
    bad = tmp_script("badinterp", "")
    File.write!(bad, "#!/nonexistent/interpreter\nexit 0\n")

    assert {:ok, %{status: :completed, exit_code: 1}} =
             OsProcess.run(sup, %{executable: bad}, max_run_ms: 2_000)
  end

  # ---- cancellation and caller death (T17, T18, T19)

  test "T17/T18 cancel stops the group through the provider; the result is unknown{provider_masked_stop}; duplicates are idempotent" do
    sup = start()
    {:ok, ref} = OsProcess.submit(sup, spec("child", [30]), max_run_ms: 20_000)
    os_pid = os_pid_of(sup, ref)
    assert :ok = wait_until(fn -> length(members(os_pid)) >= 2 end, 2_000)
    assert {:ok, :requested} = OsProcess.cancel(sup, ref)
    assert {:ok, :already_requested} = OsProcess.cancel(sup, ref)

    assert %{
             status: :unknown,
             reason: :provider_masked_stop,
             cause: :cancel,
             members: [],
             os_pid: ^os_pid
           } = result(ref)

    assert members(os_pid) == []
    assert {:error, :unknown_run} = OsProcess.cancel(sup, ref)
  end

  test "T19 a submitter that dies while running stops the group; no result is delivered" do
    sup = start()
    parent = self()

    pid =
      spawn(fn ->
        {:ok, ref} = OsProcess.submit(sup, spec("sleep", [30]), max_run_ms: 20_000)
        send(parent, {:ref, ref})

        receive do
          :never -> :ok
        end
      end)

    ref =
      receive do
        {:ref, r} -> r
      after
        2_000 -> flunk("no ref")
      end

    os_pid = os_pid_of(sup, ref)
    Process.exit(pid, :kill)
    assert :ok = wait_empty(os_pid)
    assert :ok = wait_until(fn -> OsProcess.info(sup, ref) == nil end, 5_000)
  end

  # ---- owner, Adapter and provider failures (T20–T25)

  test "T20 a provider that stops reporting yields unknown{no_exit_notification} at the safety bound" do
    sup = start(grace_s: 1, observe_timeout_ms: 500)
    {:ok, ref} = OsProcess.submit(sup, spec("sleep", ["0.3"]), max_run_ms: 300)
    os_pid = os_pid_of(sup, ref)
    :ok = :sys.suspend(:exec)
    on_exit(fn -> :sys.resume(:exec) end)
    assert %{status: :unknown, reason: :no_exit_notification, os_pid: ^os_pid} = result(ref, 10_000)
    :sys.resume(:exec)
    assert :ok = wait_empty(os_pid)
  end

  test "T21a an owner that dies before the os_pid is recorded yields unknown{owner_exit_before_registration}; the provider stops the child" do
    sup = start(test_hooks: %{before_register: fn -> Process.exit(self(), :kill) end})
    before = :exec.which_children()
    {:ok, ref} = OsProcess.submit(sup, spec("sleep", [30]), max_run_ms: 20_000)
    assert %{status: :unknown, reason: :owner_exit_before_registration} = result(ref)
    new = :exec.which_children() -- before
    assert :ok = wait_until(fn -> Enum.all?(new, &(members(&1) == [])) end, 5_000)
    assert %{in_flight: 0} = OsProcess.snapshot(sup)
  end

  test "T21b an owner killed after registration: the provider stops the group, the Adapter observes and reports unknown{owner_exit}" do
    sup = start()
    {:ok, ref} = OsProcess.submit(sup, spec("child", [30]), max_run_ms: 20_000)
    os_pid = os_pid_of(sup, ref)
    %{owner: owner} = OsProcess.info(sup, ref)
    assert :ok = wait_until(fn -> length(members(os_pid)) >= 2 end, 2_000)

    log =
      capture_log(fn ->
        Process.exit(owner, :kill)
        assert %{status: :unknown, reason: :owner_exit, members: [], os_pid: ^os_pid} = result(ref)
      end)

    assert members(os_pid) == []
    refute log =~ "os_process_fixture"
    assert %{in_flight: 0} = OsProcess.snapshot(sup)
  end

  test "T22 the Adapter dies and restarts: a running command still replies and the slot count is rebuilt" do
    sup = start()
    {:ok, ref} = OsProcess.submit(sup, spec("sleep", ["0.6"]), max_run_ms: 5_000)
    _ = os_pid_of(sup, ref)
    adapter = OsProcess.adapter(sup)
    Process.exit(adapter, :kill)

    assert :ok =
             wait_until(
               fn -> is_pid(OsProcess.adapter(sup)) and OsProcess.adapter(sup) != adapter end,
               2_000
             )

    assert %{in_flight: 1} = OsProcess.snapshot(sup)
    assert %{status: :completed, exit_code: 0} = result(ref)
    assert :ok = wait_until(fn -> OsProcess.snapshot(sup).in_flight == 0 end, 2_000)
  end

  test "T23 the Adapter and the owner die together: the provider stops the group" do
    sup = start()
    {:ok, ref} = OsProcess.submit(sup, spec("child", [30]), max_run_ms: 20_000)
    os_pid = os_pid_of(sup, ref)
    %{owner: owner} = OsProcess.info(sup, ref)
    Process.exit(OsProcess.adapter(sup), :kill)
    Process.exit(owner, :kill)
    assert :ok = wait_empty(os_pid)
  end

  test "T26 a failing observation tool yields unknown{observation_failed}; the provider's cleanup already ran" do
    failing = tmp_script("failpgrep", "exit 3\n")
    sup = start(pgrep_path: failing)
    {:ok, ref} = OsProcess.submit(sup, spec("exit", [0]), max_run_ms: 5_000)

    assert %{status: :unknown, reason: :observation_failed, exit_code: 0, os_pid: os_pid} =
             result(ref)

    assert members(os_pid) == []
  end

  test "C2 observation-channel control: a tool that always reports empty makes the Adapter report its observation, not the truth" do
    fake = tmp_script("fakepgrep", "exit 1\n")
    sup = start(pgrep_path: fake)
    {:ok, ref} = OsProcess.submit(sup, spec("linger-ignore", [30]), max_run_ms: 5_000)
    assert %{status: :completed, exit_code: 0, leftovers: :none, os_pid: os_pid} = result(ref)
    on_exit(fn -> kill_group(os_pid) end)
    assert members(os_pid) != []
    kill_group(os_pid)
    assert :ok = wait_empty(os_pid)
  end

  # ---- output, environment, cwd (T27, T28)

  test "T27 output beyond max_output_bytes is dropped and flagged" do
    sup = start(max_output_bytes: 10_000)

    assert {:ok, %{status: :completed, exit_code: 0, output: output, truncated: true}} =
             OsProcess.run(sup, spec("spew", [200_000]), max_run_ms: 10_000)

    assert byte_size(output) <= 10_000
  end

  test "T28 the child environment is the allowlist only; cwd is applied" do
    System.put_env("ELZOO_OS_PROCESS_SECRET", "s3cret-value")
    on_exit(fn -> System.delete_env("ELZOO_OS_PROCESS_SECRET") end)
    sup = start()
    env = %{inherit: ["HOME", "ABSENT_NAME"], set: [{"KEEP", "yes"}]}

    {:ok, %{status: :completed, output: output}} =
      OsProcess.run(
        sup,
        spec("env", ["HOME", "KEEP", "ELZOO_OS_PROCESS_SECRET", "PATH"], %{env: env}),
        max_run_ms: 5_000
      )

    assert output =~ "HOME=#{System.get_env("HOME")}"
    assert output =~ "KEEP=yes"
    assert output =~ "ELZOO_OS_PROCESS_SECRET=__unset__"
    # sh sets a default PATH when none is inherited: the VM's PATH must not be visible.
    refute output =~ "PATH=#{System.get_env("PATH")}\n"

    {:ok, %{status: :completed, output: cwd_out}} =
      OsProcess.run(sup, spec("cwd", [], %{cwd: System.tmp_dir!()}), max_run_ms: 5_000)

    assert String.trim(cwd_out) == Path.expand(System.tmp_dir!()) or
             String.trim(cwd_out) =~ String.trim_trailing(System.tmp_dir!(), "/")
  end

  test "no observation channel carries the command line, environment or output of a run" do
    System.put_env("ELZOO_OS_PROCESS_SECRET2", "very-secret-env")
    on_exit(fn -> System.delete_env("ELZOO_OS_PROCESS_SECRET2") end)
    sup = start()

    log =
      capture_log(fn ->
        {:ok, ref} =
          OsProcess.submit(
            sup,
            spec("echo", ["very-secret-arg"], %{
              env: %{inherit: ["ELZOO_OS_PROCESS_SECRET2"], set: []}
            }),
            max_run_ms: 5_000
          )

        assert %{status: :completed} = result(ref)
        {:ok, ref2} = OsProcess.submit(sup, spec("sleep", [30]), max_run_ms: 20_000)
        _ = os_pid_of(sup, ref2)
        %{owner: owner} = OsProcess.info(sup, ref2)
        Process.exit(owner, :kill)
        assert %{status: :unknown, reason: :owner_exit} = result(ref2)
      end)

    refute log =~ "very-secret"
    refute log =~ "os_process_fixture"
  end

  # ---- escaped daemon (T29, D5)

  test "T29 a descendant that leaves the group is a residual: it outlives the result and is not a member" do
    elixir = System.find_executable("elixir")
    assert is_binary(elixir), "elixir executable required for the escape fixture"
    sup = start(max_output_bytes: 65_536)

    script =
      ~s|p = Port.open({:spawn_executable, "/bin/sleep"}, [args: ["30"]]); {:os_pid, os} = :erlang.port_info(p, :os_pid); IO.puts(os)|

    env = %{inherit: ["HOME", "PATH", "LANG", "LC_ALL"], set: []}

    {:ok, %{status: :completed, exit_code: 0, output: output, os_pid: os_pid}} =
      OsProcess.run(sup, %{executable: elixir, args: ["-e", script], env: env},
        max_run_ms: 30_000,
        await_ms: 40_000
      )

    escaped = output |> String.trim() |> String.split("\n") |> List.last() |> String.to_integer()
    on_exit(fn -> kill_pid(escaped) end)

    assert match?({_, 0}, System.cmd("ps", ["-p", Integer.to_string(escaped)])),
           "escaped process should be alive"

    refute escaped in members(os_pid)
    assert members(os_pid) == []
    kill_pid(escaped)
  end

  # ---- provider protocol (P1) and consumer priv dir (GD1-consumer)

  test "P1 with link, erlexec produces no synthetic DOWN; the linked EXIT carries the decoded status" do
    Process.flag(:trap_exit, true)

    {:ok, proxy, os_pid} =
      :exec.run([~c"/bin/sh", ~c"-c", ~c"exit 5"], [{:group, 0}, :kill_group, :link, :monitor])

    assert_receive {:EXIT, ^proxy, {:exit_status, status}}, 5_000
    assert {:exit, 5} = Elzoo.OsProcess.Result.decode_wait_status(status)
    refute_receive {:DOWN, ^os_pid, :process, _, _}, 200
  end

  test "GD1-consumer: the provider's port program is found from the provider priv dir on the code path" do
    priv = :code.priv_dir(:erlexec)
    assert is_list(priv)
    assert File.dir?(priv)
    [exe] = Path.wildcard(Path.join([to_string(priv), "*", "exec-port"]))
    assert File.regular?(exe)
    assert is_pid(Process.whereis(:exec))
  end
end
