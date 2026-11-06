# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/jobs_test_helper.exs", __DIR__)

defmodule Elzoo.JobsTest do
  use ExUnit.Case, async: false
  alias Elzoo.Jobs
  alias Elzoo.Jobs.{Relay, TestHelper, TestRepo, Worker}
  alias Elzoo.DurableLog.{Memory, Writer}

  @fold %{
    initial: 0,
    kinds: %{"event" => :state_bearing},
    versions: [1],
    destinations: ["jobs"],
    reduce: &__MODULE__.count/4
  }
  @limits %{max_record_bytes: 256, max_batch_size: 4, max_checkpoint_bytes: 10_000}
  def count(n, _, _, _), do: n + 1

  setup_all do
    prefix = TestHelper.setup_database!()
    on_exit(fn -> TestHelper.drop!(prefix) end)
    %{prefix: prefix}
  end

  setup %{prefix: prefix} do
    TestRepo.query!("truncate #{prefix}.oban_jobs restart identity", [], log: false)
    :ok
  end

  defp oban(ctx, name, queues \\ []),
    do: start_supervised!({Oban, TestHelper.oban_opts(name, ctx.prefix, queues)}, id: name) && name

  test "unique changeset per (queue, job_key); enqueue returns only persisted ids", ctx do
    o = oban(ctx, JobsUnique)
    {:ok, a} = Jobs.enqueue(o, Jobs.changeset("q", "k", 3))
    {:ok, b} = Jobs.enqueue(o, Jobs.changeset("q", "k", 3))
    {:ok, c} = Jobs.enqueue(o, Jobs.changeset("other", "k", 3))
    assert a == b and a != c
    assert {:ok, {^a, "available"}} = Jobs.state(o, "q", "k")
    assert {:ok, :absent} = Jobs.state(o, "q", "missing")
    assert {:ok, 1} = Jobs.cancel(o, "q", "k")
    assert {:ok, {^a, "cancelled"}} = Jobs.state(o, "q", "k")
  end

  test "a held unique lock yields {:retry, :unique_lock_held}, never a false enqueue (O3 rule)",
       ctx do
    o = oban(ctx, JobsLock)
    parent = self()

    holder =
      Task.async(fn ->
        TestRepo.transaction(fn ->
          {:ok, _} = Jobs.enqueue(o, Jobs.changeset("q", "held", 3))
          send(parent, :held)
          receive do: (:rollback -> TestRepo.rollback(:probe))
        end)
      end)

    assert_receive :held, 5_000
    assert Jobs.enqueue(o, Jobs.changeset("q", "held", 3)) == {:retry, :unique_lock_held}
    send(holder.pid, :rollback)
    Task.await(holder)
    assert {:ok, :absent} = Jobs.state(o, "q", "held")
    assert {:ok, id} = Jobs.enqueue(o, Jobs.changeset("q", "held", 3))
    assert is_integer(id)
  end

  test "worker dispatches by queue, traps linked exits, refuses unknown args versions" do
    job = fn args -> %Oban.Job{id: 1, attempt: 1, args: args} end

    assert Worker.perform(job.(%{"v" => 2, "queue" => "w", "job_key" => "k"})) ==
             {:cancel, :unsupported_version}

    assert Worker.perform(job.(%{"v" => 1, "queue" => "unregistered", "job_key" => "k"})) ==
             {:snooze, 5}

    :ok =
      Jobs.register("w", %{
        perform: fn _ ->
          pid = spawn_link(fn -> exit(:boom) end)
          ref = Process.monitor(pid)
          receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
          {:snooze, 2}
        end,
        backoff: fn _ -> 7 end
      })

    on_exit(fn -> Jobs.unregister("w") end)
    assert Worker.perform(job.(%{"v" => 1, "queue" => "w", "job_key" => "k"})) == {:snooze, 2}
    assert Process.flag(:trap_exit, false) == false
    assert Worker.backoff(job.(%{"v" => 1, "queue" => "w", "job_key" => "k"})) == 7
  end

  test "a real Oban execution reaches the registered runner", ctx do
    parent = self()

    :ok =
      Jobs.register("real", %{
        perform: fn %Oban.Job{args: args} ->
          send(parent, {:ran, args["job_key"]})
          :ok
        end,
        backoff: fn _ -> 1 end
      })

    on_exit(fn -> Jobs.unregister("real") end)
    o = oban(ctx, JobsReal, real: 2)
    {:ok, id} = Jobs.enqueue(o, Jobs.changeset("real", "x", 2))
    assert_receive {:ran, "x"}, 10_000
    TestHelper.poll(fn -> Jobs.state(o, "real", "x") == {:ok, {id, "completed"}} end)
  end

  defp memory_with_items(n) do
    {:ok, pid} = Memory.start_link(fold: @fold, limits: @limits)
    store = Memory.store(pid)
    {:ok, w} = Writer.start_link(store: store, stream: "jobs/r", fold: @fold, limits: @limits)

    for i <- 1..n,
        do: {:committed, ^i} = Writer.append(w, [{"event", 1, "e"}], [{"jobs", "item-#{i}"}])

    GenServer.stop(w)
    store
  end

  test "relay acks :done items, keeps skipped items pending and continues within the page" do
    store = memory_with_items(4)
    seen = :ets.new(:seen, [:public, :bag])

    handle = fn item ->
      :ets.insert(seen, {:offered, item.payload})

      case item.payload do
        "item-1" -> {:skip, :stuck}
        "item-2" -> raise "boom"
        _ -> :done
      end
    end

    {:ok, relay} =
      Relay.start_link(
        store: store,
        stream: "jobs/r",
        handle: handle,
        limit: 10,
        interval_ms: :manual
      )

    {:ok, pass} = Relay.run_once(relay)
    assert pass.acked == ["jobs/r/3/1", "jobs/r/4/1"]
    assert pass.skipped == [{"jobs/r/1/1", :stuck}, {"jobs/r/2/1", {:exception, RuntimeError}}]
    {:ok, pending} = Elzoo.Outbox.pending(store, "jobs/r", 10)
    assert Enum.map(pending, & &1.payload) == ["item-1", "item-2"]
    # at-least-once: the next pass offers the still-pending items again
    {:ok, again} = Relay.run_once(relay)
    assert again.acked == [] and length(again.skipped) == 2
  end

  test "stated limit: a full page of permanently skipped items blocks later items" do
    store = memory_with_items(3)

    handle = fn item ->
      if item.payload in ["item-1", "item-2"], do: {:skip, :stuck}, else: :done
    end

    {:ok, relay} =
      Relay.start_link(
        store: store,
        stream: "jobs/r",
        handle: handle,
        limit: 2,
        interval_ms: :manual
      )

    {:ok, pass} = Relay.run_once(relay)
    assert pass.acked == [] and length(pass.skipped) == 2
    {:ok, pending} = Elzoo.Outbox.pending(store, "jobs/r", 10)
    assert "item-3" in Enum.map(pending, & &1.payload)
  end

  test "relay start options are validated" do
    Process.flag(:trap_exit, true)

    assert {:error, :invalid_options} =
             Relay.start_link(store: nil, stream: "s", handle: :no, interval_ms: :manual)
  end
end
