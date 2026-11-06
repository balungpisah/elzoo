# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/durable_job_test_helper.exs", __DIR__)

defmodule Elzoo.DurableJobTest do
  use ExUnit.Case, async: false
  import Elzoo.DurableJob.TestHelper
  alias Elzoo.DurableJob
  alias Elzoo.DurableJob.{Run, Submitter, TestRepo}
  alias Elzoo.DurableLog.{Memory, Writer}
  alias Elzoo.{Jobs, Outbox}

  setup_all do
    prefix = setup_database!()
    on_exit(fn -> drop!(prefix) end)
    %{prefix: prefix}
  end

  defp run_stream(f, key), do: Run.run_stream(f.queue, key)

  defp submit(f, key, input \\ [1, 2, 3], policy \\ fast(), deadline \\ far()),
    do: DurableJob.submit(f.queue, key, input, policy, deadline)

  defp counting_handler(fail_calls, failure) do
    counter = :counters.new(1, [])

    fn input ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) <= fail_calls,
        do: {:error, failure},
        else: {:ok, Enum.sum(input)}
    end
  end

  defp job_row(f, id) do
    %{rows: [[state, attempt]]} =
      TestRepo.query!("select state, attempt from #{f.prefix}.oban_jobs where id = $1", [id],
        log: false
      )

    {state, attempt}
  end

  defp job_id(f, key) do
    {:ok, {id, _}} = Jobs.state(f.oban, f.queue, key)
    id
  end

  defp raw_append(store, stream, records, versions \\ [1]) do
    fold = %{Run.store_fold() | initial: 0, versions: versions, reduce: fn n, _, _, _ -> n + 1 end}
    {:ok, w} = Writer.start_link(store: store, stream: stream, fold: fold, limits: Run.limits())
    result = Writer.append(w, records)
    GenServer.stop(w)
    result
  end

  for backend <- [:memory, :postgres] do
    @tag backend: backend
    test "DJ1 #{backend}: submit, relay, attempt 1 succeeds", %{prefix: prefix} do
      f = flow(prefix, unquote(backend))
      assert submit(f, "k1") == {:ok, %{phase: :submitted}}
      assert DurableJob.status(f.queue, "k1") |> elem(1) |> Map.get(:phase) == :submitted
      assert {:ok, %{acked: [_], skipped: []}} = relay!(f.queue)
      poll(fn -> phase(f, "k1") == :succeeded end)
      assert kinds(f.store, run_stream(f, "k1")) == ~w(accepted attempt_started succeeded)
      assert kinds(f.store, Run.submission_stream(f.queue)) == ~w(requested)
      assert {:ok, []} = Outbox.pending(f.store, Run.submission_stream(f.queue), 10)

      assert {:ok, %{result: 6, attempts_made: 1, stalled: false}} =
               DurableJob.status(f.queue, "k1")

      poll(fn -> oban_state(f, "k1") == "completed" end)
    end

    @tag backend: backend
    test "DJ4 #{backend}: transient failures until attempt 3, deterministic records", %{
      prefix: prefix
    } do
      f = flow(prefix, unquote(backend), handler: counting_handler(2, :transient))
      {:ok, _} = submit(f, "k4", [5])
      {:ok, _} = relay!(f.queue)
      poll(fn -> phase(f, "k4") == :succeeded end)

      assert kinds(f.store, run_stream(f, "k4")) ==
               ~w(accepted attempt_started attempt_failed attempt_started attempt_failed attempt_started succeeded)

      assert {:ok, %{result: 5, attempts_made: 3}} = DurableJob.status(f.queue, "k4")
    end

    @tag backend: backend
    test "DJ11 #{backend}: rescued-but-alive stale attempt is re-classified stale and snoozes (success)",
         %{prefix: prefix} do
      stale_attempt(prefix, unquote(backend), {:ok, 100})
    end
  end

  test "DJ11 postgres: stale attempt failing after the rescue cannot move the Run", %{
    prefix: prefix
  } do
    stale_attempt(prefix, :postgres, {:error, :transient})
  end

  defp stale_attempt(prefix, backend, stale_result) do
    f = flow(prefix, backend, handler: blocking_handler(self()))
    {:ok, _} = submit(f, "k11", [4, 5])
    {:ok, _} = relay!(f.queue)
    assert_receive {:entered, e1, _}, 10_000
    id = job_id(f, "k11")
    {:ok, [_]} = Oban.Engine.rescue_jobs(Oban.config(f.oban), Oban.Job, rescue_after: 0)
    assert_receive {:entered, e2, _}, 10_000
    assert job_row(f, id) == {"executing", 2}
    send(e1, {:release, stale_result})
    Process.sleep(300)
    assert phase(f, "k11") == :active
    assert job_row(f, id) == {"executing", 2}
    send(e2, {:release, {:ok, 9}})
    poll(fn -> phase(f, "k11") == :succeeded end)
    records = records(f.store, run_stream(f, "k11"))
    assert Enum.map(records, &elem(&1, 0)) == ~w(accepted attempt_started attempt_started succeeded)
    assert {"succeeded", %{"attempt" => 2, "result" => 9}} = List.last(records)
    poll(fn -> job_row(f, id) == {"completed", 2} end)
  end

  test "DJ2 duplicate submits; a competing Submitter is fenced by the stream CAS", %{prefix: prefix} do
    f = flow(prefix, :postgres)
    deadline = far()
    {:ok, _} = submit(f, "k2", [1, 2, 3], fast(), deadline)
    assert {:duplicate, {:ok, %{phase: :submitted}}} = submit(f, "k2", [1, 2, 3], fast(), deadline)
    assert submit(f, "k2", [9], fast(), deadline) == {:error, :job_key_conflict}
    assert submit(f, "k2", [1, 2, 3], fast(), deadline + 1) == {:error, :job_key_conflict}
    {:ok, other} = Submitter.start_link(name: :elzoo_dj2_other, store: f.store, queue: f.queue)
    {:ok, request} = Run.request("k2b", [7], fast(), deadline, System.os_time(:millisecond))
    assert {:ok, _} = Submitter.submit(other, request)
    assert {:duplicate, _} = submit(f, "k2b", [7], fast(), deadline)
    GenServer.stop(other)
    assert kinds(f.store, Run.submission_stream(f.queue)) == ~w(requested requested)
    {:ok, %{acked: acked}} = relay!(f.queue)
    assert length(acked) == 2
    poll(fn -> phase(f, "k2") == :succeeded and phase(f, "k2b") == :succeeded end)
    assert kinds(f.store, run_stream(f, "k2")) == ~w(accepted attempt_started succeeded)
  end

  test "DJ3 relay crash between insert and ack, held unique lock, foreign accepted", %{
    prefix: prefix
  } do
    f = flow(prefix, :postgres)
    cfg = :persistent_term.get({DurableJob, f.queue})
    {:ok, _} = submit(f, "k3a")
    {:ok, [item]} = Outbox.pending(f.store, Run.submission_stream(f.queue), 10)
    assert DurableJob.relay(cfg, item) == :done
    assert {:ok, %{acked: [_]}} = relay!(f.queue)
    poll(fn -> phase(f, "k3a") == :succeeded end)
    assert kinds(f.store, run_stream(f, "k3a")) == ~w(accepted attempt_started succeeded)

    parent = self()

    holder =
      Task.async(fn ->
        TestRepo.transaction(fn ->
          {:ok, _} = Jobs.enqueue(f.oban, Jobs.changeset(f.queue, "k3b", 5))
          send(parent, :held)
          receive do: (:rollback -> TestRepo.rollback(:test))
        end)
      end)

    assert_receive :held, 5_000
    {:ok, _} = submit(f, "k3b")
    assert {:ok, %{acked: [], skipped: [{_, :unique_lock_held}]}} = relay!(f.queue)
    send(holder.pid, :rollback)
    Task.await(holder)
    assert {:ok, %{acked: [_]}} = relay!(f.queue)
    poll(fn -> phase(f, "k3b") == :succeeded end)

    {:ok, request} = Run.request("k3c", [1], fast(), far(), System.os_time(:millisecond))

    {:committed, 1} =
      raw_append(f.store, run_stream(f, "k3c"), [
        {"accepted", 1, Run.encode(%{"request" => request, "submission" => "jobs/other/1/1"})}
      ])

    {:ok, _} = submit(f, "k3c", [1])
    assert {:ok, %{acked: [], skipped: [{_, :foreign_run}]}} = relay!(f.queue)
    assert {:ok, [_]} = Outbox.pending(f.store, Run.submission_stream(f.queue), 10)
  end

  test "DJ3a crash after submit commit, before the relay ever ran", %{prefix: prefix} do
    f = flow(prefix, :postgres)
    {:ok, _} = submit(f, "k3x")
    stop_supervised!({DurableJob, f.queue})
    start_job(f.queue, f.store, f.oban, [])
    assert {:ok, %{acked: [_]}} = relay!(f.queue)
    poll(fn -> phase(f, "k3x") == :succeeded end)
    assert kinds(f.store, run_stream(f, "k3x")) == ~w(accepted attempt_started succeeded)
  end

  test "DJ5 retry exhaustion records exhausted at the budget", %{prefix: prefix} do
    f = flow(prefix, :postgres, handler: fn _ -> {:error, :transient} end)
    {:ok, _} = submit(f, "k5", [1], max_attempts: 2, base_backoff_ms: 0, max_backoff_ms: 0)
    {:ok, _} = relay!(f.queue)
    poll(fn -> phase(f, "k5") == :exhausted end)

    assert kinds(f.store, run_stream(f, "k5")) ==
             ~w(accepted attempt_started attempt_failed attempt_started exhausted)

    poll(fn -> oban_state(f, "k5") == "cancelled" end)
    assert {:ok, %{attempts_made: 2}} = DurableJob.status(f.queue, "k5")
  end

  test "DJ6 permanent failure is not retried", %{prefix: prefix} do
    f = flow(prefix, :postgres, handler: fn _ -> {:error, :permanent} end)
    {:ok, _} = submit(f, "k6")
    {:ok, _} = relay!(f.queue)
    poll(fn -> phase(f, "k6") == :failed end)
    assert kinds(f.store, run_stream(f, "k6")) == ~w(accepted attempt_started failed)
    poll(fn -> oban_state(f, "k6") == "cancelled" end)
  end

  test "DJ7 deadline passes while waiting; a completion after the deadline expires", %{
    prefix: prefix
  } do
    {:ok, clock} = Agent.start_link(fn -> 1_000_000 end)
    now = fn -> Agent.get(clock, & &1) end
    f = flow(prefix, :postgres, now_ms: now, handler: fn _ -> {:error, :transient} end)
    policy = [max_attempts: 3, base_backoff_ms: 1_000, max_backoff_ms: 1_000]
    {:ok, _} = DurableJob.submit(f.queue, "k7a", [1], policy, 2_000_000)
    {:ok, _} = relay!(f.queue)
    poll(fn -> phase(f, "k7a") == :waiting end)
    Agent.update(clock, fn _ -> 2_000_001 end)
    poll(fn -> phase(f, "k7a") == :expired end)

    assert kinds(f.store, run_stream(f, "k7a")) ==
             ~w(accepted attempt_started attempt_failed expired)

    Agent.update(clock, fn _ -> 1_000_000 end)

    late = fn input ->
      Agent.update(clock, fn _ -> 2_000_001 end)
      {:ok, Enum.sum(input)}
    end

    g = flow(prefix, :postgres, now_ms: now, handler: late)
    {:ok, _} = DurableJob.submit(g.queue, "k7b", [1], fast(), 2_000_000)
    {:ok, _} = relay!(g.queue)
    poll(fn -> phase(g, "k7b") == :expired end)
    assert kinds(g.store, run_stream(g, "k7b")) == ~w(accepted attempt_started expired)
  end

  test "DJ8 cancel while waiting, while active, after success", %{prefix: prefix} do
    f = flow(prefix, :postgres, handler: fn _ -> {:error, :transient} end)

    {:ok, _} =
      submit(f, "k8a", [1], max_attempts: 3, base_backoff_ms: 60_000, max_backoff_ms: 60_000)

    {:ok, _} = relay!(f.queue)
    poll(fn -> phase(f, "k8a") == :waiting end)
    assert DurableJob.cancel(f.queue, "k8a", "operator") == {:ok, :cancelled}
    poll(fn -> oban_state(f, "k8a") == "cancelled" end)
    assert List.last(kinds(f.store, run_stream(f, "k8a"))) == "cancelled"

    g = flow(prefix, :postgres, handler: blocking_handler(self()))
    {:ok, _} = submit(g, "k8b")
    {:ok, _} = relay!(g.queue)
    assert_receive {:entered, pid, _}, 10_000
    assert DurableJob.cancel(g.queue, "k8b", "operator") == {:ok, :cancelled}
    send(pid, {:release, {:ok, 1}})
    poll(fn -> oban_state(g, "k8b") == "cancelled" end)
    Process.sleep(200)
    assert kinds(g.store, run_stream(g, "k8b")) == ~w(accepted attempt_started cancelled)

    h = flow(prefix, :postgres)
    {:ok, _} = submit(h, "k8c")
    {:ok, _} = relay!(h.queue)
    poll(fn -> phase(h, "k8c") == :succeeded end)
    assert DurableJob.cancel(h.queue, "k8c", "operator") == {:error, {:terminal, :succeeded}}
    assert DurableJob.cancel(h.queue, "missing", "operator") == {:error, :not_found}
  end

  test "DJ8 (d) cancel before relay, and after accepted while the insert is blocked", %{
    prefix: prefix
  } do
    f = flow(prefix, :postgres)
    {:ok, _} = submit(f, "k8d")
    assert DurableJob.cancel(f.queue, "k8d", "operator") == {:ok, :cancelled}
    assert kinds(f.store, run_stream(f, "k8d")) == ~w(cancelled)
    assert {:ok, %{acked: [_], skipped: []}} = relay!(f.queue)
    assert oban_state(f, "k8d") == :absent
    assert phase(f, "k8d") == :cancelled

    parent = self()

    holder =
      Task.async(fn ->
        TestRepo.transaction(fn ->
          {:ok, _} = Jobs.enqueue(f.oban, Jobs.changeset(f.queue, "k8e", 5))
          send(parent, :held)
          receive do: (:rollback -> TestRepo.rollback(:test))
        end)
      end)

    assert_receive :held, 5_000
    {:ok, _} = submit(f, "k8e")
    assert {:ok, %{skipped: [{_, :unique_lock_held}]}} = relay!(f.queue)
    assert DurableJob.cancel(f.queue, "k8e", "operator") == {:ok, :cancelled}
    send(holder.pid, :rollback)
    Task.await(holder)
    assert {:ok, %{acked: [_]}} = relay!(f.queue)
    assert oban_state(f, "k8e") == :absent
    assert kinds(f.store, run_stream(f, "k8e")) == ~w(accepted cancelled)
  end

  test "DJ10 Oban, Repo and Assembly restart while waiting does not reset the budget", %{
    prefix: prefix
  } do
    f = flow(prefix, :postgres, handler: fn _ -> {:error, :transient} end)
    {:ok, _} = submit(f, "k10", [1], max_attempts: 2, base_backoff_ms: 2_000, max_backoff_ms: 2_000)
    {:ok, _} = relay!(f.queue)
    poll(fn -> phase(f, "k10") == :waiting end)
    [{"accepted", %{"request" => before}} | _] = records(f.store, run_stream(f, "k10"))
    stop_supervised!({DurableJob, f.queue})
    stop_supervised!(f.oban)
    :ok = Supervisor.stop(TestRepo)
    {:ok, repo} = TestRepo.start_link(url: url!(), pool_size: 20, log: false)
    Process.unlink(repo)
    start_oban(f.oban, prefix, f.queue, [])
    start_job(f.queue, f.store, f.oban, handler: fn _ -> {:error, :transient} end)
    poll(fn -> phase(f, "k10") == :exhausted end)
    records = records(f.store, run_stream(f, "k10"))

    assert Enum.map(records, &elem(&1, 0)) ==
             ~w(accepted attempt_started attempt_failed attempt_started exhausted)

    assert [{"accepted", %{"request" => ^before}} | _] = records
    assert for({"attempt_started", %{"attempt" => n}} <- records, do: n) == [1, 2]
  end

  test "DJ12 a second Oban job for one Run yields; one attempt, one terminal record", %{
    prefix: prefix
  } do
    f = flow(prefix, :postgres, handler: blocking_handler(self()))
    {:ok, _} = submit(f, "k12")
    {:ok, _} = relay!(f.queue)
    assert_receive {:entered, pid, _}, 10_000

    {:ok, dup} =
      Oban.insert(
        f.oban,
        Elzoo.Jobs.Worker.new(%{"v" => 1, "queue" => f.queue, "job_key" => "k12"},
          queue: f.queue,
          max_attempts: 5
        )
      )

    poll(fn -> elem(job_row(f, dup.id), 0) == "cancelled" end)
    send(pid, {:release, {:ok, 3}})
    poll(fn -> phase(f, "k12") == :succeeded end)
    assert kinds(f.store, run_stream(f, "k12")) == ~w(accepted attempt_started succeeded)
  end

  test "DJ13 reply lost after the succeeded commit: worker survives, no second succeeded", %{
    prefix: prefix
  } do
    store = store(:memory, prefix)
    handler = fn input -> Memory.fault(store, :append, :reply_loss) && {:ok, Enum.sum(input)} end
    f = flow(prefix, :memory, store: store, handler: handler)
    {:ok, _} = submit(f, "k13")
    {:ok, _} = relay!(f.queue)
    poll(fn -> oban_state(f, "k13") == "cancelled" end)
    assert kinds(store, run_stream(f, "k13")) == ~w(accepted attempt_started succeeded)
    assert phase(f, "k13") == :succeeded
  end

  test "DJ14 damaged Run stream, record version 2 and args version 2 are refused", %{prefix: prefix} do
    f = flow(prefix, :postgres)

    {:committed, 1} =
      raw_append(f.store, run_stream(f, "k14"), [
        {"succeeded", 1, Run.encode(%{"attempt" => 9, "result" => 1})}
      ])

    {:ok, id} = Jobs.enqueue(f.oban, Jobs.changeset(f.queue, "k14", 3))
    poll(fn -> elem(job_row(f, id), 0) == "cancelled" end)
    assert DurableJob.status(f.queue, "k14") == {:error, :damaged}
    assert kinds(f.store, run_stream(f, "k14")) == ~w(succeeded)

    {:ok, pid} =
      Memory.start_link(fold: %{Run.store_fold() | versions: [1, 2]}, limits: Run.limits())

    v2 = Memory.store(pid)
    g = flow(prefix, :memory, store: v2)
    {:ok, request} = Run.request("k14b", [1], fast(), far(), System.os_time(:millisecond))

    {:committed, 1} =
      raw_append(
        v2,
        run_stream(g, "k14b"),
        [
          {"accepted", 2, Run.encode(%{"request" => request, "submission" => "x/1/1"})}
        ],
        [1, 2]
      )

    {:ok, id2} = Jobs.enqueue(g.oban, Jobs.changeset(g.queue, "k14b", 3))
    poll(fn -> elem(job_row(g, id2), 0) == "cancelled" end)
    assert DurableJob.status(g.queue, "k14b") == {:error, :damaged}

    {:ok, j} =
      Oban.insert(
        f.oban,
        Elzoo.Jobs.Worker.new(%{"v" => 2, "queue" => f.queue, "job_key" => "k14c"}, queue: f.queue)
      )

    poll(fn -> elem(job_row(f, j.id), 0) == "cancelled" end)
  end

  test "DJ15 unreachable PostgreSQL store: worker snoozes without consuming Oban or Run attempts",
       %{prefix: prefix} do
    {:ok, repo} =
      Elzoo.DurableJob.UnreachableRepo.start_link(
        url: "ecto://nobody:nobody@localhost:1/none",
        pool_size: 1,
        queue_target: 50,
        queue_interval: 100,
        backoff_type: :stop,
        log: false
      )

    Process.unlink(repo)

    store =
      Elzoo.DurableLog.Postgres.store(Elzoo.DurableJob.UnreachableRepo,
        fold: Run.store_fold(),
        limits: Run.limits()
      )

    f = flow(prefix, :postgres, store: store, snooze_s: 60)
    assert submit(f, "k15") == {:error, :unavailable}
    {:ok, id} = Jobs.enqueue(f.oban, Jobs.changeset(f.queue, "k15", 3))
    poll(fn -> job_row(f, id) == {"scheduled", 0} end)
    assert DurableJob.status(f.queue, "k15") == {:error, :unavailable}
  end

  test "DJ16 provider job cancelled outside the Assembly while waiting: stalled, no deadline record",
       %{prefix: prefix} do
    f = flow(prefix, :postgres, handler: fn _ -> {:error, :transient} end)

    {:ok, _} =
      submit(f, "k16", [1], max_attempts: 3, base_backoff_ms: 60_000, max_backoff_ms: 60_000)

    {:ok, _} = relay!(f.queue)
    poll(fn -> phase(f, "k16") == :waiting end)
    :ok = Oban.cancel_job(f.oban, job_id(f, "k16"))
    poll(fn -> oban_state(f, "k16") == "cancelled" end)
    assert {:ok, %{phase: :waiting, stalled: true}} = DurableJob.status(f.queue, "k16")
    assert kinds(f.store, run_stream(f, "k16")) == ~w(accepted attempt_started attempt_failed)
  end

  test "DJ17 entry points refuse inside a caller transaction on the configured Repo", %{
    prefix: prefix
  } do
    f = flow(prefix, :postgres)
    {:ok, _} = submit(f, "k17")

    assert {:ok, results} =
             TestRepo.transaction(fn ->
               {submit(f, "k17b"), DurableJob.cancel(f.queue, "k17", "op"),
                DurableJob.status(f.queue, "k17")}
             end)

    assert results ==
             {{:error, :caller_transaction}, {:error, :caller_transaction},
              {:error, :caller_transaction}}

    assert kinds(f.store, Run.submission_stream(f.queue)) == ~w(requested)
    assert kinds(f.store, run_stream(f, "k17")) == []
  end

  test "DJ19 a stale pre-start execution arriving after the current attempt_started snoozes", %{
    prefix: prefix
  } do
    parent = self()

    hook = fn :before_begin, job ->
      if job.attempt == 1 do
        send(parent, {:hook, self()})
        receive do: (:go -> :ok)
      end

      :ok
    end

    f = flow(prefix, :postgres, handler: blocking_handler(parent), test_hook: hook)
    :ok = Oban.pause_queue(f.oban, queue: f.queue)
    {:ok, _} = submit(f, "k19")
    {:ok, _} = relay!(f.queue)
    cfg = :persistent_term.get({DurableJob, f.queue})
    id = job_id(f, "k19")

    exec = fn attempt ->
      %Oban.Job{id: id, attempt: attempt, args: %{"v" => 1, "queue" => f.queue, "job_key" => "k19"}}
    end

    run = fn job ->
      Task.async(fn -> Elzoo.Jobs.Worker.trapping(fn -> DurableJob.perform(cfg, job) end) end)
    end

    # W2 conflict path: E1 (Oban attempt 1) has folded and waits before its append.
    e1 = run.(exec.(1))
    assert_receive {:hook, e1_pid}, 5_000
    e2 = run.(exec.(2))
    assert_receive {:entered, e2_handler, _}, 5_000
    send(e1_pid, :go)
    assert {:snooze, _} = Task.await(e1)

    # A later stale execution (Oban attempt 1) arriving after attempt_started{oban_attempt: 2}.
    # It folds the newer recorded oban_attempt and never reaches the begin hook.
    late = run.(exec.(1))
    assert {:snooze, _} = Task.await(late)
    refute_received {:hook, _}

    send(e2_handler, {:release, {:ok, 3}})
    assert Task.await(e2) == :ok
    records = records(f.store, run_stream(f, "k19"))
    assert Enum.map(records, &elem(&1, 0)) == ~w(accepted attempt_started succeeded)
    assert [_, {"attempt_started", %{"attempt" => 1, "oban_attempt" => 2}}, _] = records
  end

  test "DJ20 relay skips stuck items within a page; a full page of stuck items blocks later ones",
       %{prefix: prefix} do
    foreign = fn f, key ->
      {:ok, request} = Run.request(key, [1], fast(), far(), System.os_time(:millisecond))

      {:committed, 1} =
        raw_append(f.store, run_stream(f, key), [
          {"accepted", 1, Run.encode(%{"request" => request, "submission" => "jobs/other/1/1"})}
        ])
    end

    f = flow(prefix, :postgres)
    foreign.(f, "a")
    {:ok, _} = submit(f, "a", [1])
    {:ok, _} = submit(f, "c")
    assert {:ok, %{acked: [_], skipped: [{_, :foreign_run}]}} = relay!(f.queue)
    poll(fn -> phase(f, "c") == :succeeded end)

    g = flow(prefix, :postgres, relay_limit: 2)
    foreign.(g, "a")
    foreign.(g, "b")
    {:ok, _} = submit(g, "a", [1])
    {:ok, _} = submit(g, "b", [1])
    {:ok, _} = submit(g, "c")
    assert {:ok, %{acked: [], skipped: [_, _]}} = relay!(g.queue)
    assert phase(g, "c") == :submitted
    assert oban_state(g, "c") == :absent
  end
end
