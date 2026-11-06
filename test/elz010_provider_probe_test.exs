# SPDX-License-Identifier: Apache-2.0
# ELZ-010 pre-implementation provider probes: exploration evidence recorded in
# docs/work/ELZ-010.md, re-run by mix check. Not acceptance evidence for a Piece.
Code.require_file("support/elz010_probe_test_helper.exs", __DIR__)

Code.require_file(
  "../pieces/integration/sql/test/support/durable_log_postgres_test_helper.exs",
  __DIR__
)

defmodule Elzoo.Elz010ProviderProbeTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Elzoo.Elz010Probe, as: P
  alias Elzoo.Elz010Probe.{Repo, Flaky, Blocking, Unique, SnoozeOnce}
  alias Elzoo.Elz010Probe.Record, as: RecordJob
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Postgres, Record, TestMigration}
  alias Elzoo.Outbox

  @store_prefix "elz010_store"
  @limits %{max_record_bytes: 256, max_batch_size: 8, max_checkpoint_bytes: 100_000}

  def reduce(acc, kind, _version, payload), do: [{kind, payload} | acc]

  defp fold,
    do: %{
      initial: [],
      kinds: %{
        "requested" => :state_bearing,
        "accepted" => :state_bearing,
        "attempt_started" => :state_bearing,
        "succeeded" => :state_bearing
      },
      versions: [1],
      destinations: ["jobs"],
      reduce: &__MODULE__.reduce/4
    }

  setup_all do
    {:ok, repo} = Repo.start_link(url: P.url!(), pool_size: 20, log: false)
    Process.unlink(repo)
    Repo.query!("select 1", [], log: false)

    for schema <- [P.prefix(), @store_prefix] do
      Repo.query!("drop schema if exists #{schema} cascade", [], log: false)
      Repo.query!("create schema #{schema}", [], log: false)
    end

    :ok = Ecto.Migrator.up(Repo, 1, Elzoo.Elz010Probe.Migration, prefix: P.prefix(), log: false)
    :ok = Ecto.Migrator.up(Repo, 1, TestMigration, prefix: @store_prefix, log: false)

    on_exit(fn ->
      {:ok, cleanup} = Repo.start_link(url: P.url!(), pool_size: 1, log: false, name: nil)
      Repo.put_dynamic_repo(cleanup)

      for schema <- [P.prefix(), @store_prefix],
          do: Repo.query!("drop schema if exists #{schema} cascade", [], log: false)

      Supervisor.stop(cleanup)
    end)

    :ok
  end

  setup do
    Repo.query!(
      "truncate #{P.prefix()}.oban_jobs, #{P.prefix()}.probe_effects, #{P.prefix()}.probe_domain restart identity",
      [],
      log: false
    )

    for t <- ~w(elzoo_outbox elzoo_checkpoints elzoo_log_records elzoo_log_heads),
        do: Repo.query!("truncate #{@store_prefix}.#{t} cascade", [], log: false)

    {:ok, store: Postgres.store(Repo, prefix: @store_prefix, fold: fold(), limits: @limits)}
  end

  defp oban(name, opts \\ []) do
    base = [
      name: name,
      repo: Repo,
      prefix: P.prefix(),
      queues: [probe: 10],
      stager: [interval: 50],
      notifier: Oban.Notifiers.PG,
      log: false
    ]

    start_supervised!({Oban, Keyword.merge(base, opts)}, id: name)
    name
  end

  defp settled(id, states), do: P.poll(fn -> P.job(id).state in states end) && P.job(id)

  defp batch(stream, expected, records, items) do
    nonce = :crypto.strong_rand_bytes(16)

    rows =
      records
      |> Enum.with_index(expected + 1)
      |> Enum.map(fn {{kind, payload}, sequence} ->
        row = %Record{
          stream: stream,
          sequence: sequence,
          kind: kind,
          schema_version: 1,
          payload: payload,
          nonce: nonce
        }

        %{row | digest: Log.digest(row)}
      end)

    target = expected + length(rows)

    outbox =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {{destination, payload}, position} ->
        item = %{
          stream: stream,
          sequence: target,
          position: position,
          destination: destination,
          payload: payload,
          nonce: nonce,
          state: :pending,
          ack_nonce: nil,
          ack_digest: nil,
          idempotency_key: Codec.item_key(stream, target, position)
        }

        Map.put(item, :digest, Codec.hash(Codec.item_bytes(item)))
      end)

    {rows, outbox}
  end

  defp append(store, stream, expected, records, items \\ []) do
    {rows, outbox} = batch(stream, expected, records, items)
    Postgres.append(store, stream, expected, rows, outbox)
  end

  test "O1 attempt count and terminal state persist across Oban instance restarts" do
    oban(O1a, queues: [])
    {:ok, job} = Oban.insert(O1a, Flaky.new(%{"fail_until" => 3}))
    stop_supervised!(O1a)
    oban(O1b)
    P.poll(fn -> P.job(job.id).state == "retryable" end)
    stop_supervised!(O1b)
    first = P.job(job.id)
    oban(O1c)
    final = settled(job.id, ["discarded", "completed"])
    attempts = Enum.map(P.effects(job.id), &elem(&1, 0))

    IO.puts(
      "ELZ-010 O1: #{inspect({first.state, first.attempt, final.state, final.attempt, attempts})}"
    )

    assert {first.state, first.attempt, final.state, final.attempt, attempts} ==
             {"retryable", 1, "discarded", 3, [1, 2, 3]}
  end

  test "O2 unique insert: sequential duplicate and 16 concurrent duplicates" do
    oban(O2, queues: [])
    {:ok, a} = Oban.insert(O2, Unique.new(%{"job_key" => "k1", "n" => 1}))
    {:ok, b} = Oban.insert(O2, Unique.new(%{"job_key" => "k1", "n" => 2}))

    results =
      1..16
      |> Task.async_stream(fn i -> Oban.insert(O2, Unique.new(%{"job_key" => "k2", "n" => i})) end,
        max_concurrency: 16
      )
      |> Enum.map(fn {:ok, {:ok, j}} -> {j.id, j.conflict?} end)

    rows = P.count("oban_jobs", "args->>'job_key' = 'k2'")
    inserted = Enum.count(results, fn {_, c} -> not c end)

    IO.puts(
      "ELZ-010 O2: sequential #{inspect({a.id, a.conflict?, b.id, b.conflict?})} concurrent rows=#{rows} inserted=#{inserted}"
    )

    assert b.conflict? and b.id == a.id
    assert rows == 1 and inserted == 1
  end

  test "O3 unique insert while the lock holder later rolls back: duplicate told conflict, nothing persists" do
    oban(O3, queues: [])
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          {:ok, j} = Oban.insert(O3, Unique.new(%{"job_key" => "k3"}))
          send(parent, {:held, j.id})

          receive do
            :rollback -> Repo.rollback(:probe)
          end
        end)
      end)

    assert_receive {:held, _}, 5_000
    {:ok, dup} = Oban.insert(O3, Unique.new(%{"job_key" => "k3"}))
    send(holder.pid, :rollback)
    Task.await(holder)
    rows = P.count("oban_jobs", "args->>'job_key' = 'k3'")

    IO.puts(
      "ELZ-010 O3: dup_id=#{inspect(dup.id)} conflict?=#{dup.conflict?} rows_after_rollback=#{rows}"
    )

    assert dup.conflict? and is_nil(dup.id) and rows == 0
  end

  test "O4 Oban.insert joins a caller Repo.transaction with a plain domain row" do
    oban(O4, queues: [])

    {:error, :abort} =
      Repo.transaction(fn ->
        Repo.query!("insert into #{P.prefix()}.probe_domain values ('d1')", [], log: false)
        {:ok, _} = Oban.insert(O4, RecordJob.new(%{"tag" => "t1"}))
        Repo.rollback(:abort)
      end)

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!("insert into #{P.prefix()}.probe_domain values ('d2')", [], log: false)
        {:ok, _} = Oban.insert(O4, RecordJob.new(%{"tag" => "t2"}))
      end)

    jobs =
      Repo.all(from(j in "oban_jobs", prefix: ^P.prefix(), select: fragment("?->>'tag'", j.args)))

    IO.puts("ELZ-010 O4: jobs=#{inspect(jobs)} domain_rows=#{P.count("probe_domain")}")
    assert jobs == ["t2"] and P.count("probe_domain") == 1
  end

  test "O5 rescued live job: stale attempt runs concurrently; its ack is fenced by attempted_at" do
    conf = Oban.config(oban(O5))
    {:ok, job} = Oban.insert(O5, Blocking.new(%{}))
    P.poll(fn -> P.effects(job.id) != [] end)
    {:ok, rescued} = Oban.Engine.rescue_jobs(conf, Oban.Job, rescue_after: 0)
    P.poll(fn -> {2, "attempt-2", "start"} in P.effects(job.id) end)
    P.release({job.id, 1}, :ok)
    P.poll(fn -> {1, "attempt-1", "finish"} in P.effects(job.id) end)
    Process.sleep(300)
    after_stale = P.job(job.id)
    P.release({job.id, 2}, :ok)
    final = settled(job.id, ["completed"])

    IO.puts(
      "ELZ-010 O5: rescued=#{length(rescued)} after_stale_ack=#{inspect({after_stale.state, after_stale.attempt})} final=#{inspect({final.state, final.attempt})} effects=#{inspect(P.effects(job.id))}"
    )

    assert {after_stale.state, after_stale.attempt} == {"executing", 2}
    assert {1, "attempt-1", "finish"} in P.effects(job.id)
    assert {final.state, final.attempt} == {"completed", 2}
  end

  test "O6 two Oban instances on one queue claim 300 jobs disjointly (no rescue)" do
    oban(O6a)
    oban(O6b)
    Oban.insert_all(O6a, for(i <- 1..300, do: RecordJob.new(%{"i" => i})))
    P.poll(fn -> P.count("oban_jobs", "state = 'completed'") == 300 end, 1_200)

    per_job =
      Repo.all(
        from(e in "probe_effects",
          prefix: ^P.prefix(),
          group_by: e.job_id,
          select: {e.job_id, count(), max(e.attempt)}
        )
      )

    %{rows: [[producers]]} =
      Repo.query!(
        "select count(distinct attempted_by[2]) from #{P.prefix()}.oban_jobs",
        [],
        log: false
      )

    IO.puts(
      "ELZ-010 O6: executed_jobs=#{length(per_job)} max_exec=#{per_job |> Enum.map(&elem(&1, 1)) |> Enum.max()} producers=#{producers}"
    )

    assert length(per_job) == 300 and Enum.all?(per_job, fn {_, c, a} -> c == 1 and a == 1 end)
  end

  test "O7 cancellation: scheduled job never runs; executing job is killed after its effect" do
    oban(O7)
    {:ok, scheduled} = Oban.insert(O7, RecordJob.new(%{"tag" => "s"}, schedule_in: 3600))
    :ok = Oban.cancel_job(O7, scheduled.id)
    {:ok, running} = Oban.insert(O7, Blocking.new(%{}))
    P.poll(fn -> P.effects(running.id) != [] end)
    :ok = Oban.cancel_job(O7, running.id)
    settled(running.id, ["cancelled"])
    Process.sleep(200)

    IO.puts(
      "ELZ-010 O7: scheduled=#{inspect({P.job(scheduled.id).state, P.effects(scheduled.id)})} executing=#{inspect({P.job(running.id).state, P.effects(running.id)})}"
    )

    assert P.job(scheduled.id).state == "cancelled" and P.effects(scheduled.id) == []
    assert P.effects(running.id) == [{1, "attempt-1", "start"}]
  end

  test "O8 snooze does not consume an Oban attempt (Oban 2.24.2 snooze_job inc attempt -1)" do
    oban(O8)
    {:ok, job} = Oban.insert(O8, SnoozeOnce.new(%{}))
    P.poll(fn -> P.job(job.id).state == "scheduled" end)
    snoozed = P.job(job.id)
    final = settled(job.id, ["completed", "discarded"])

    IO.puts(
      "ELZ-010 O8: snoozed_attempt=#{snoozed.attempt} final=#{inspect({final.state, final.attempt})} runs=#{length(P.effects(job.id))}"
    )

    assert snoozed.attempt == 0 and {final.state, final.attempt} == {"completed", 1}
    assert length(P.effects(job.id)) == 2
  end

  test "O10 SIGKILL of the executing OS process; Lifeline in a new instance rescues at attempt 2" do
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
    victim = Path.expand("support/elz010_oban_victim_test_helper.exs", __DIR__)
    args = Enum.flat_map(paths, &["-pa", &1]) ++ [victim]

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        args: args
      ])

    [_, id, os_pid] = Regex.run(~r/VICTIM_JOB=(\d+) OS_PID=(\d+)/, read_port(port, ""))
    id = String.to_integer(id)
    P.poll(fn -> P.effects(id) != [] end)
    {_, 0} = System.cmd("kill", ["-9", os_pid])
    assert_receive {^port, {:exit_status, 137}}, 10_000
    after_kill = P.job(id)
    oban(O10, lifeline: [interval: 200, rescue_after: 500])
    final = settled(id, ["completed"])

    IO.puts(
      "ELZ-010 O10: after_kill=#{inspect({after_kill.state, after_kill.attempt})} final=#{inspect({final.state, final.attempt})} effects=#{inspect(P.effects(id))}"
    )

    assert {after_kill.state, after_kill.attempt} == {"executing", 1}
    assert final.attempt == 2
    assert [{1, "os-pid-" <> ^os_pid, "start"}, {2, "os-pid-" <> other, "start"}] = P.effects(id)
    assert other != os_pid
  end

  defp read_port(port, acc) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data
        if acc =~ ~r/VICTIM_JOB=\d+ OS_PID=\d+/, do: acc, else: read_port(port, acc)
    after
      60_000 -> raise "victim did not start: #{acc}"
    end
  end

  test "G1 in_transaction? is per process: the caller sees true, an owned process does not join" do
    parent = self()

    {:error, :abort} =
      Repo.transaction(fn ->
        inside = Repo.in_transaction?()

        other =
          Task.async(fn ->
            {Repo.in_transaction?(),
             Repo.query!("insert into #{P.prefix()}.probe_domain values ('owned')", [], log: false)}
          end)
          |> Task.await()
          |> elem(0)

        send(parent, {:seen, inside, other})
        Repo.rollback(:abort)
      end)

    assert_received {:seen, true, false}

    IO.puts(
      "ELZ-010 G1: caller in_transaction?=true owned_process=false owned_row_survives_caller_rollback=#{P.count("probe_domain", "k = 'owned'") == 1}"
    )

    assert P.count("probe_domain", "k = 'owned'") == 1
    refute Repo.in_transaction?()
  end

  test "S1 Store.append inside a caller transaction that rolls back leaves no head (inner reply recorded, see #52)",
       %{store: s} do
    oban(S1, queues: [])
    {rows, items} = batch("job/q/a", 0, [{"accepted", "a"}], [])

    outer =
      Repo.transaction(fn ->
        send(self(), {:inner, Postgres.append(s, "job/q/a", 0, rows, items)})
        {:ok, _} = Oban.insert(S1, RecordJob.new(%{"tag" => "a"}))
        Repo.rollback(:caller_abort)
      end)

    assert_received {:inner, inner}
    head = Postgres.head(s, "job/q/a")

    IO.puts(
      "ELZ-010 S1: inner=#{inspect(inner)} outer=#{inspect(outer)} head_after=#{inspect(head)} jobs=#{P.count("oban_jobs")}"
    )

    assert outer == {:error, :caller_abort}
    assert head == {:ok, %{revision: 0, low_water: 0}} and P.count("oban_jobs") == 0
  end

  # Before ELZ-032 (#52) merged, a stale append inside the caller transaction
  # aborted it ({:error, :rollback}, no job; recorded in docs/work/ELZ-010.md).
  # With ELZ-032 the Store refuses before any statement, so the caller's
  # transaction is left intact.
  test "S2 a Store call inside a caller transaction is refused and leaves it intact (ELZ-032)",
       %{store: s} do
    oban(S2, queues: [])
    {:committed, 1} = append(s, "job/q/b", 0, [{"accepted", "b"}])

    outer =
      Repo.transaction(fn ->
        inner = append(s, "job/q/b", 0, [{"accepted", "b2"}])
        {:ok, _} = Oban.insert(S2, RecordJob.new(%{"tag" => "b"}))
        inner
      end)

    IO.puts("ELZ-010 S2: outer=#{inspect(outer)} jobs=#{P.count("oban_jobs")}")
    assert outer == {:ok, {:rejected, :caller_transaction}} and P.count("oban_jobs") == 1
    assert Postgres.head(s, "job/q/b") == {:ok, %{revision: 1, low_water: 0}}
  end

  test "S3 submission stream relay: crash before relay, crash between insert and ack, re-offer dedups",
       %{store: s} do
    oban(S3, queues: [])
    submissions = "jobs/q"
    {:committed, 1} = append(s, submissions, 0, [{"requested", "c"}], [{"jobs", "c"}])
    {:committed, 2} = append(s, submissions, 1, [{"requested", "d"}], [{"jobs", "d"}])
    # crash after submit commit, before any relay ran: a fresh relay discovers both
    # items through the single-stream pending/3 API.
    {:ok, pending} = Outbox.pending(s, submissions, 10)

    relay = fn item, ack? ->
      run = "job/q/" <> item.payload
      run_result = append(s, run, 0, [{"accepted", item.payload}])
      {:ok, job} = Oban.insert(S3, Unique.new(%{"job_key" => run}))

      ack =
        if ack? and job.id,
          do: Outbox.ack(s, item.idempotency_key, :crypto.strong_rand_bytes(16)),
          else: :skipped

      {run_result, job.id, job.conflict?, ack}
    end

    first = Enum.map(pending, &relay.(&1, false))
    {:ok, again} = Outbox.pending(s, submissions, 10)
    second = Enum.map(again, &relay.(&1, true))

    IO.puts(
      "ELZ-010 S3: discovered=#{length(pending)} first=#{inspect(first)} second=#{inspect(second)} jobs=#{P.count("oban_jobs")} pending_after=#{inspect(Outbox.pending(s, submissions, 10))}"
    )

    assert length(pending) == 2 and P.count("oban_jobs") == 2

    assert Enum.all?(
             second,
             &match?({{:conflict, _}, id, true, {:committed, _}} when is_integer(id), &1)
           )

    assert Outbox.pending(s, submissions, 10) == {:ok, []}
  end

  test "S4 revision fencing: a stale attempt's completion at its observed revision conflicts", %{
    store: s
  } do
    run = "job/q/e"
    {:committed, 1} = append(s, run, 0, [{"accepted", "e"}])
    {:committed, 2} = append(s, run, 1, [{"attempt_started", "1"}])
    {:committed, 3} = append(s, run, 2, [{"attempt_started", "2"}])
    stale = append(s, run, 2, [{"succeeded", "by-1"}])
    fresh = append(s, run, 3, [{"succeeded", "by-2"}])
    IO.puts("ELZ-010 S4: stale=#{inspect(stale)} fresh=#{inspect(fresh)}")
    assert stale == {:conflict, %{expected: 2, observed: 3}}
    assert fresh == {:committed, 4}
  end
end
