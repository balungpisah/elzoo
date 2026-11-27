# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_host_test_helper.exs", __DIR__)

defmodule Elzoo.RunHostTimeTest do
  # Deadline wakes and lease renewal and expiry, on disposable PostgreSQL with the
  # trusted engine clock of the node (Unix milliseconds) and the store clock of the
  # lease, and on Memory with a manual lease clock moved independently.
  use ExUnit.Case, async: false
  import Elzoo.RunHost.TestHelper
  alias Elzoo.{Lease, RunHost}
  alias Elzoo.RunApprovalRelease, as: Owner

  setup_all do
    repo = database()
    on_exit(fn -> if Process.alive?(repo), do: Supervisor.stop(repo) end)
    load_model_catalog()
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "deadlines" do
    test "an idle Run past its deadline ends :out_of_time through the host's own wake" do
      env = postgres()
      {host, _} = host(env, notify())
      deadline = clock() + 400
      spec = spec("idle", stub([]), run_deadline: deadline)

      assert :ok = RunHost.start_run(host, :idle, spec)
      assert_receive {:terminal, :idle, :out_of_time}, 5_000
      assert [wake] = wakes(transcript(host, :idle, spec))
      assert wake.input_id == wake_id(spec, deadline)
      assert wake.at_ms >= deadline
    end

    test "paused with the Run deadline first: the Run ends at the Run deadline" do
      env = postgres()
      {host, _} = host(env, notify())
      run_deadline = clock() + 600
      spec = spec("run-first", stub([]), run_deadline: run_deadline)
      pause_deadline = clock() + 10_000

      assert :ok = RunHost.start_run(host, :run_first, spec)

      assert {:ok, :applied} =
               RunHost.control(
                 host,
                 :run_first,
                 "pause",
                 %{kind: :pause, pause_deadline: pause_deadline},
                 verified(spec)
               )

      assert {:ok, %{phase: :paused, run_deadline: ^run_deadline, pause_deadline: ^pause_deadline}} =
               RunHost.deadlines(host, :run_first)

      assert_receive {:terminal, :run_first, :out_of_time}, 5_000
      assert [wake] = wakes(transcript(host, :run_first, spec))
      assert wake.input_id == wake_id(spec, run_deadline)
      assert wake.at_ms >= run_deadline and wake.at_ms < pause_deadline
    end

    test "paused with the pause deadline first (a Budget exhaustion under :pause): the Run ends at the pause deadline" do
      env = postgres()
      {host, _} = host(env, notify())

      context = fn ->
        %{
          policy: policy(),
          authority: [%{target: "document", field: "published", value: true}],
          resource_names: ["document"],
          pause_deadline: clock() + 700
        }
      end

      run_deadline = clock() + 60_000

      spec =
        spec("pause-first", stub([answer("too dear")]),
          budget_rule: :pause,
          budget: %{cap: 100, unit: "tokens", id: "budget", incarnation: "sealed"},
          descriptor: [estimate: 10],
          context: context,
          run_deadline: run_deadline
        )

      assert :ok = RunHost.start_run(host, :pause_first, spec)

      assert {:ok, :applied} =
               RunHost.input(
                 host,
                 :pause_first,
                 "start",
                 start_input(),
                 verified(spec, %{pause_deadline: clock() + 700})
               )

      assert_receive {:terminal, :pause_first, :out_of_time}, 5_000
      assert [{_, outcome}] = ai_inputs(env, spec)
      assert outcome.correlation.actual == 2_598
      pause_deadline = outcome.context.pause_deadline
      assert [wake] = wakes(transcript(host, :pause_first, spec))
      assert wake.input_id == wake_id(spec, pause_deadline)
      assert wake.at_ms >= pause_deadline and wake.at_ms < run_deadline
    end

    test "a continue that replaces the Run deadline moves the timer; the replaced timer gives no input" do
      env = postgres()
      {host, _} = host(env, notify())
      first = clock() + 1_000
      spec = spec("moved", stub([]), run_deadline: first)

      assert :ok = RunHost.start_run(host, :moved, spec)

      assert {:ok, :applied} =
               RunHost.control(
                 host,
                 :moved,
                 "pause",
                 %{kind: :pause, pause_deadline: clock() + 20_000},
                 verified(spec)
               )

      second = clock() + 2_000

      assert {:ok, :applied} =
               RunHost.control(
                 host,
                 :moved,
                 "continue",
                 %{kind: :continue, person_id: "person", run_deadline: second},
                 verified(spec, %{verified_person: "person"})
               )

      assert {:ok, %{run_deadline: ^second, pause_deadline: nil}} = RunHost.deadlines(host, :moved)
      assert_receive {:terminal, :moved, :out_of_time}, 6_000
      assert [wake] = wakes(transcript(host, :moved, spec))
      assert wake.input_id == wake_id(spec, second)
      assert wake.at_ms >= second
    end

    test "a wake that the engine refuses for its passed pause operand is sent again with a fresh one" do
      env = postgres()
      {host, _} = host(env, notify())
      {:ok, mode} = Agent.start_link(fn -> :short end)

      context = fn ->
        margin = if Agent.get(mode, & &1) == :short, do: 100, else: 600_000

        %{
          policy: policy(),
          authority: [%{target: "document", field: "published", value: true}],
          resource_names: ["document"],
          pause_deadline: clock() + margin
        }
      end

      deadline = clock() + 600

      spec =
        spec("refused", stub([]), budget_rule: :pause, context: context, run_deadline: deadline)

      assert :ok = RunHost.start_run(host, :refused, spec)

      # The wake waits in the engine for the Run owner, past its pause operand.
      owner = run(host, :refused).pids.owner
      :sys.suspend(owner)
      Process.sleep(1_000)
      Agent.update(mode, fn _ -> :long end)
      :sys.resume(owner)
      assert_receive {:terminal, :refused, :out_of_time}, 5_000
      assert [wake] = wakes(transcript(host, :refused, spec))
      assert wake.input_id == wake_id(spec, deadline)
    end
  end

  describe "lease_clock" do
    test "a lease clock moved past the confirmed until stops admission before any node timer" do
      env = memory()
      {host, _} = host(env, notify())
      spec = spec("moved-clock", stub([]))
      assert :ok = RunHost.start_run(host, :moved_clock, spec)
      Lease.Clock.advance(env.clock, 61_000_000)

      assert {:error, :lease_lost} =
               RunHost.input(host, :moved_clock, "start", start_input(), verified(spec))

      assert_receive {:lost, :moved_clock, :expired}, 3_000
      eventually(fn -> run(host, :moved_clock) == nil end)
    end

    test "a claim that waits a whole TTL before the lease samples its clock keeps its lease" do
      {:ok, slow} = Agent.start_link(fn -> true end)

      hook = fn
        :before_lock, _ -> if Agent.get_and_update(slow, &{&1, false}), do: Process.sleep(2_500)
        _, _ -> :ok
      end

      env = postgres(lease: [test_hook: hook])
      stub = stub([answer("still held")])
      {host, _} = host(env, notify() ++ [lease_ttl_ms: 2_000])
      spec = spec("slow-claim", stub)

      assert :ok = RunHost.start_run(host, :slow_claim, spec)

      assert {:ok, :applied} =
               RunHost.input(host, :slow_claim, "start", start_input(), verified(spec))

      assert_receive {:terminal, :slow_claim, :completed}, 5_000
      refute_received {:lost, :slow_claim, _}
    end
  end

  describe "renewal" do
    test "a Run that lives through several TTLs keeps writing, renewed on the lease clock" do
      env = postgres()
      stub = stub([{:block, answer("after the renewals")}])
      {host, _} = host(env, notify() ++ [lease_ttl_ms: 1_000])
      spec = spec("renewed", stub)

      assert :ok = RunHost.start_run(host, :renewed, spec)
      assert {:ok, :applied} = RunHost.input(host, :renewed, "start", start_input(), verified(spec))
      assert_receive {:stub_entered, stub_task}, 5_000

      for n <- 1..6 do
        Process.sleep(500)

        assert {:ok, :applied} =
                 RunHost.input(host, :renewed, "message-#{n}", message("more #{n}"), verified(spec))
      end

      assert renewals(env, spec) >= 4
      send(stub_task, :release)
      assert_receive {:terminal, :renewed, :completed}, 5_000
      refute_received {:lost, :renewed, _}
    end

    test "a lost renewal stops admission for the Run and fences its processes" do
      env = postgres()
      {host, _} = host(env, notify() ++ [lease_ttl_ms: 1_000])
      spec = spec("seized", stub([]))
      before = Process.list()

      assert :ok = RunHost.start_run(host, :seized, spec)
      pids = new_processes(before)
      assert length(pids) >= 6

      {:held, _} =
        Lease.seize(env.lease, "run/" <> spec.unit, "operator", 60_000, :operator_takeover)

      assert_receive {:lost, :seized, reason}, 3_000
      assert elem(reason, 0) == :lease_lost

      assert {:error, :lease_lost} =
               RunHost.input(host, :seized, "late", start_input(), verified(spec))

      eventually(fn -> run(host, :seized) == nil end)
      assert alive_pids(pids) == []

      assert {:error, :lease_lost} =
               RunHost.input(host, :seized, "late", start_input(), verified(spec))

      assert {:error, :not_running} = RunHost.status(host, :seized)
    end

    @tag timeout: 60_000
    test "a renewal reply delayed past the caller timeout: admission stops, the owner is fenced before any replacement" do
      {:ok, delay} = Agent.start_link(fn -> false end)

      hook = fn
        :after_commit, %{key: "run/slow"} ->
          if Agent.get_and_update(delay, &{&1, false}), do: Process.sleep(6_000)

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {host, specs} = host(env, notify() ++ [lease_ttl_ms: 12_000])
      spec = spec("slow", stub([]))
      remember(specs, :slow, spec)

      assert :ok = RunHost.start_run(host, :slow, spec)
      owner = run(host, :slow).pids.owner
      Agent.update(delay, fn _ -> true end)

      # The renewal starts at half the TTL and its caller gives up after 5,000 ms,
      # before the expiry deadline: an unconfirmed renewal.
      assert_receive {:lost, :slow, {:unknown, :no_receipt}}, 12_000
      assert Process.alive?(host)

      assert {:error, :lease_lost} =
               RunHost.input(host, :slow, "late", start_input(), verified(spec))

      eventually(fn -> not Process.alive?(owner) end)
      assert [slow: :woken] = RunHost.wake(host, [:slow])
      assert run(host, :slow).pids.owner != owner

      # The renewal itself committed: a late success that reopened nothing and gave no
      # receipt for reconcile:.
      assert renewals(env, spec) >= 1
      assert state(host).receipts == %{}
      refute Agent.get(delay, & &1)
    end

    test "an indeterminate renewal: on_lost once, its receipt kept past the late result and reconciled at the next start" do
      test = self()
      {:ok, armed} = Agent.start_link(fn -> false end)

      # The renewal's transaction fails after its write: an unknown outcome.
      hook = fn
        :after_write, %{key: "run/indeterminate"} ->
          if Agent.get_and_update(armed, &{&1, false}) do
            send(test, {:renewal_written, self()})
            receive do: (:go -> raise "the connection ends after the write")
          end

        _, _ ->
          :ok
      end

      env = postgres(lease: [test_hook: hook])
      {host, specs} = host(env, notify() ++ [lease_ttl_ms: 4_000])
      spec = spec("indeterminate", stub([answer("after the reconcile")]))
      remember(specs, :indeterminate, spec)
      assert :ok = RunHost.start_run(host, :indeterminate, spec)
      Agent.update(armed, fn _ -> true end)

      # The renewal's task is held, so that its result reaches the host only after the
      # owner's exit, the worker's exit and the teardown.
      assert_receive {:renewal_written, owner}, 5_000
      [task] = Task.Supervisor.children(state(host).tasks)
      :erlang.suspend_process(task)
      send(owner, :go)

      assert_receive {:lost, :indeterminate, {:indeterminate, receipt}}, 5_000

      assert {:error, :lease_lost} =
               RunHost.input(host, :indeterminate, "start", start_input(), verified(spec))

      eventually(fn -> run(host, :indeterminate) == nil end)
      :erlang.resume_process(task)
      refute_receive {:lost, :indeterminate, _}, 500
      assert state(host).receipts == %{indeterminate: receipt}

      # The renewal never committed: the next start gives its receipt to the owner as
      # reconcile:, and the new claim supersedes it.
      trace([{Owner, :start_link, 1}])
      assert [indeterminate: :woken] = RunHost.wake(host, [:indeterminate])
      assert_receive {:trace, _, :call, {Owner, :start_link, [opts]}}, 1_000
      assert opts[:reconcile] == receipt
      assert state(host).receipts == %{}

      assert {:ok, :applied} =
               RunHost.input(host, :indeterminate, "start", start_input(), verified(spec))

      assert_receive {:terminal, :indeterminate, :completed}, 5_000
    end

    test "a worker's report of an indeterminate owner exit that comes first: on_lost once, the receipt kept" do
      env = postgres()
      {host, _} = host(env, notify())
      spec = spec("reported", stub([]))
      assert :ok = RunHost.start_run(host, :reported, spec)
      %{worker: worker, pids: %{owner: owner}} = run(host, :reported)
      receipt = %{stream: "run/reported", nonce: "forged"}

      # An exit of the owner forged to the worker: the worker's report reaches the host
      # first, and the owner then ends with the worker, with no loss of its own.
      send(worker, {:EXIT, owner, {:shutdown, {:indeterminate, receipt}}})
      assert_receive {:lost, :reported, {:indeterminate, ^receipt}}, 5_000

      assert {:error, :lease_lost} =
               RunHost.input(host, :reported, "start", start_input(), verified(spec))

      eventually(fn -> run(host, :reported) == nil end)
      refute Process.alive?(owner)
      refute_receive {:lost, :reported, _}, 300
      assert state(host).receipts == %{reported: receipt}
    end
  end

  defp wakes(entries), do: for(%{type: :input, kind: "wake"} = e <- entries, do: e)

  defp wake_id(spec, deadline) do
    "wake:" <>
      (:crypto.hash(
         :sha256,
         :erlang.term_to_binary({spec.run_id, spec.attempt_id, deadline}, [:deterministic])
       )
       |> Base.encode16(case: :lower))
  end

  defp message(text),
    do: %{
      "type" => "input",
      "version" => 1,
      "kind" => "message",
      "schema_id" => "elzoo.agent-loop.message",
      "schema_version" => 1,
      "payload" => %{"text" => text}
    }

  defp renewals(env, spec),
    do: length(for %{kind: "lease_renewed"} <- rows(env, "run/" <> spec.unit), do: 1)
end
