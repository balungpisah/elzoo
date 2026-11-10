# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/lease_test_helper.exs", __DIR__)

# The ready integration/sql harness (hooks for the Store conformance checks K1–K11),
# located in the repository layout or in the copied consumer layout.
[
  Path.expand(
    "../../../../integration/sql/test/support/durable_log_postgres_test_helper.exs",
    __DIR__
  ),
  Path.expand("../support/durable_log_postgres_test_helper.exs", __DIR__)
]
|> Enum.find(&File.exists?/1)
|> case do
  nil -> raise "integration/sql test support not found: state/lease depends on integration/sql"
  path -> Code.require_file(path)
end

defmodule Elzoo.Lease.LS28Repo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.LeasePostgresTest do
  @moduledoc """
  `state/lease` on a disposable PostgreSQL database with the store clock sampled
  under the head row lock. Scenario IDs follow the ELZ-028 work record. The
  database is verified before any schema or data effect (R6). Finite scenarios
  on one local PostgreSQL; locking, clock and transaction semantics are upstream.
  """
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Conformance, Memory, Postgres, PostgresHarness}
  alias Elzoo.Lease
  alias Elzoo.Lease.{LS28Repo, Record, TestHelper, TestRepo}

  @minute 60_000
  @hour_us 3_600_000_000

  setup_all do
    {:ok, repo} = TestRepo.start_link(url: TestHelper.url!(), pool_size: 2, log: false)

    try do
      :ok = TestHelper.database_guard!(TestRepo)

      observations =
        for name <- ["server_version", "fsync", "synchronous_commit"] do
          [[value]] = SQL.query!(TestRepo, "SHOW #{name}", [], log: false).rows
          "#{name}=#{value}"
        end

      [[db]] = SQL.query!(TestRepo, "SELECT current_database()", [], log: false).rows
      offset = TestHelper.pg_now(TestRepo) - System.os_time(:microsecond)

      IO.puts(
        "PostgreSQL monitored (state/lease): #{Enum.join(observations, " ")} database=#{db} store_clock_minus_node_clock_us=#{offset}"
      )
    after
      Supervisor.stop(repo)
    end

    :ok
  end

  setup do
    Process.flag(:trap_exit, true)
    {:ok, repo} = TestRepo.start_link(url: TestHelper.url!(), pool_size: 20, log: false)
    Process.unlink(repo)
    :ok = TestHelper.database_guard!(TestRepo)
    prefix = TestHelper.schema!(TestRepo)
    store = TestHelper.pg_store(TestRepo, prefix)
    {:ok, lease} = TestHelper.pg_lease(store)

    on_exit(fn ->
      try do
        TestHelper.drop!(TestRepo, prefix)
      after
        if pid = Process.whereis(TestRepo), do: Supervisor.stop(pid)
      end
    end)

    %{store: store, lease: lease, prefix: prefix}
  end

  # A separate transaction that holds the head row lock of `key` until released.
  defp hold_lock(prefix, key, fun \\ fn -> :ok end) do
    test = self()

    task =
      Task.async(fn ->
        TestRepo.transaction(
          fn ->
            SQL.query!(
              TestRepo,
              "SELECT revision FROM #{Postgres.identifier(prefix)}.elzoo_log_heads WHERE stream = $1 FOR UPDATE",
              [key],
              log: false
            )

            send(test, {:locked, self()})

            receive do
              :release -> fun.()
            after
              20_000 -> :timeout
            end
          end,
          timeout: 30_000
        )
      end)

    receive do
      {:locked, pid} -> {task, pid}
    after
      5_000 -> raise "lock not acquired"
    end
  end

  defp release_lock({task, pid}) do
    send(pid, :release)
    Task.await(task, 30_000)
  end

  defp wait_until(fun, deadline_ms) do
    started = System.monotonic_time(:millisecond)

    Stream.repeatedly(fn -> fun.() end)
    |> Enum.find(fn ok -> ok or System.monotonic_time(:millisecond) - started > deadline_ms end)
    |> Kernel.||(raise("condition not reached within #{deadline_ms} ms"))
  end

  defp contender_waits_on_lock?(pid) do
    [[waiting]] =
      SQL.query!(
        TestRepo,
        "SELECT COALESCE(wait_event_type = 'Lock', FALSE) FROM pg_stat_activity WHERE pid = $1",
        [pid],
        log: false
      ).rows

    waiting
  end

  defp forge_rows(prefix, key, expected, specs) do
    {:ok, rows, request} =
      Record.records(
        key,
        expected,
        Enum.map(specs, fn {k, p} -> {k, 1, p} end),
        TestHelper.fold(),
        TestHelper.limits()
      )

    for r <- rows do
      SQL.query!(
        TestRepo,
        "INSERT INTO #{Postgres.identifier(prefix)}.elzoo_log_records (stream, sequence, kind, schema_version, payload, nonce, digest) VALUES ($1,$2,$3,$4,$5,$6,$7)",
        [r.stream, r.sequence, r.kind, r.schema_version, r.payload, r.nonce, r.digest],
        log: false
      )
    end

    SQL.query!(
      TestRepo,
      "INSERT INTO #{Postgres.identifier(prefix)}.elzoo_log_heads (stream, revision) VALUES ($1, $2) ON CONFLICT (stream) DO UPDATE SET revision = $2",
      [key, request.target],
      log: false
    )

    request
  end

  test "ELZ-095 active checked-out backend reports no lock wait as false" do
    TestRepo.checkout(fn ->
      [[pid]] = SQL.query!(TestRepo, "SELECT pg_backend_pid()", [], log: false).rows

      assert [[nil]] =
               SQL.query!(
                 TestRepo,
                 "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
                 [pid], log: false).rows

      assert contender_waits_on_lock?(pid) === false
    end)
  end

  test "LS1/LS5 claim, hold, status by the store clock; a lease stamped in the past is stale", %{
    lease: lease,
    store: store
  } do
    before = TestHelper.pg_now(TestRepo)
    assert {:held, held} = Lease.claim(lease, "k", "alice", @minute)
    assert held.live.at >= before and held.live.at <= TestHelper.pg_now(TestRepo)
    assert {:held, ^held} = Lease.hold(lease, "k", "alice")
    assert {:ok, %{status: :active, holder: %{owner: "alice"}, as_of: 1}} = Lease.status(lease, "k")

    # expiry is judged by the server clock: a forged lease stamped two hours ago with a one-minute ttl is stale
    TestHelper.forge!(store, "old", 0, [
      {"lease_claimed",
       TestHelper.holder_payload("bob", TestHelper.pg_now(TestRepo) - 2 * @hour_us, @minute)}
    ])

    assert {:ok, %{status: :stale, holder: %{owner: "bob"}}} = Lease.status(lease, "old")
    assert {:held, %{live: %{revision: 3}}} = Lease.claim(lease, "old", "carol", @minute)
    [_, released, _] = TestHelper.rows(store, "old")

    assert %{"owner" => "bob", "by" => "carol", "reason" => "stale"} =
             Jason.decode!(released.payload)
  end

  test "LS4 the expired holder's old fence is refused by revision after a replacement; control without takeover",
       %{lease: lease, store: store} do
    now = TestHelper.pg_now(TestRepo)

    {_, _} =
      TestHelper.forge!(store, "k", 0, [
        {"lease_claimed", TestHelper.holder_payload("alice", now - @hour_us, @minute)}
      ])

    a = %{
      owner: "alice",
      live: %{key: "k", revision: 1, at: now - @hour_us, until: now - @hour_us + @minute * 1000}
    }

    assert {:held, b} = Lease.claim(lease, "k", "bob", @minute)
    assert {:fenced, %{expected: 1, observed: 3}} = Lease.write(lease, a, [{"added", 1, "x"}])
    assert {:held, %{live: %{revision: 4}}} = Lease.write(lease, b, [{"added", 1, "x"}])

    TestHelper.forge!(store, "lonely", 0, [
      {"lease_claimed", TestHelper.holder_payload("carol", now - @hour_us, @minute)}
    ])

    c = %{owner: "carol", live: %{key: "lonely", revision: 1, at: now - @hour_us, until: 0}}
    assert {:ok, %{status: :stale}} = Lease.status(lease, "lonely")
    assert {:held, _} = Lease.write(lease, c, [{"added", 1, "late"}])
  end

  test "LS6 concurrent claims from separate connections: exactly one holder", %{lease: lease} do
    results =
      1..8
      |> Task.async_stream(fn i -> Lease.claim(lease, "k", "w#{i}", @minute) end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &match?({:held, _}, &1)) == 1
    assert Enum.count(results, &match?({:lease_refused, %{reason: :active}}, &1)) == 7
    assert {:ok, %{revision: 1}} = Lease.status(lease, "k")
  end

  test "LS7 claim_expired as one transaction: skipped_locked, free-running sweeps, limit, return barrier, no head insert",
       %{lease: lease, store: store, prefix: prefix} do
    past = TestHelper.pg_now(TestRepo) - @hour_us

    for k <- ~w(s1 s2 s3 s4),
        do:
          TestHelper.forge!(store, k, 0, [
            {"lease_claimed", TestHelper.holder_payload("old", past, @minute)}
          ])

    {:held, _} = Lease.claim(lease, "active", "old", @minute)
    # LS7a: a locked candidate is skipped, never waited for
    lock = hold_lock(prefix, "s1")
    assert {:claimed, r} = Lease.claim_expired(lease, "sweeper", @minute, 10, ~w(s1 s2 free active))
    release_lock(lock)
    assert r.skipped_locked == ["s1"] and Enum.map(r.held, & &1.live.key) == ["s2"]
    assert %{reason: :free} = r.refused["free"]
    assert %{reason: :active} = r.refused["active"]
    assert [] = TestHelper.rows(store, "free")
    # LS7b: four free-running sweeps over shared candidates: no key granted to two live owners
    results =
      1..4
      |> Task.async_stream(
        fn i -> Lease.claim_expired(lease, "sw#{i}", @minute, 10, ~w(s1 s3 s4 active)) end,
        max_concurrency: 4,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    held = results |> Enum.flat_map(fn {:claimed, r} -> r.held end) |> Enum.map(& &1.live.key)
    assert Enum.sort(held) == ~w(s1 s3 s4)

    for {:claimed, r} <- results,
        do: refute(Map.has_key?(r.held |> Map.new(&{&1.live.key, 1}), "active"))

    # LS7c: limit stops the sweep; the rest is reported skipped
    for k <- ~w(l1 l2 l3),
        do:
          TestHelper.forge!(store, k, 0, [
            {"lease_claimed", TestHelper.holder_payload("old", past, @minute)}
          ])

    assert {:claimed, %{held: [_], skipped: ~w(l2 l3)}} =
             Lease.claim_expired(lease, "sweeper", @minute, 1, ~w(l1 l2 l3))

    # LS7d: overlapping invocations with a return barrier: A pending at :before_return while B sweeps the expired key
    test = self()

    {:ok, lease_a} =
      TestHelper.pg_lease(store,
        hook: fn
          :before_return, _ ->
            send(test, :a_pending)
            receive do: (:go -> :ok)

          _, _ ->
            :ok
        end
      )

    TestHelper.forge!(store, "ov", 0, [
      {"lease_claimed", TestHelper.holder_payload("old", past, @minute)}
    ])

    a = Task.async(fn -> Lease.claim_expired(lease_a, "A", 1, 1, ~w(ov)) end)
    receive do: (:a_pending -> :ok)
    wait_until(fn -> match?({:ok, %{status: :stale}}, Lease.status(lease, "ov")) end, 5_000)
    assert {:claimed, %{held: [b]}} = Lease.claim_expired(lease, "B", @minute, 1, ~w(ov))
    send(a.pid, :go)
    assert {:claimed, %{held: [a_held]}} = Task.await(a, 10_000)
    assert a_held.live.key == "ov" and b.live.key == "ov" and a_held.live.revision < b.live.revision
  end

  test "LS8/LS8b/LS8c renewal across a handoff and across expiry, sampled under the lock", %{
    lease: lease,
    store: store,
    prefix: prefix
  } do
    # LS8: A's renewal waits on the lock while the lock holder records B's takeover of A's expired lease
    past = TestHelper.pg_now(TestRepo) - @hour_us

    TestHelper.forge!(store, "k", 0, [
      {"lease_claimed", TestHelper.holder_payload("alice", past, @minute)}
    ])

    now = TestHelper.pg_now(TestRepo)

    lock =
      hold_lock(prefix, "k", fn ->
        forge_rows(prefix, "k", 1, [
          {"lease_released", TestHelper.release_payload("alice", "bob", now, :stale)},
          {"lease_claimed", TestHelper.holder_payload("bob", now, @minute)}
        ])
      end)

    renew = Task.async(fn -> Lease.renew(lease, "alice", ["k"], @minute) end)
    Process.sleep(200)
    refute Task.yield(renew, 0)
    release_lock(lock)

    assert {:renewed, %{refused: %{"k" => %{reason: :not_holder, holder: "bob"}}}} =
             Task.await(renew, 10_000)

    assert length(TestHelper.rows(store, "k")) == 3

    # LS8b: the lease expires while the renewal waits on the lock; sampled after expiry -> refused, nothing written
    {:held, _} = Lease.claim(lease, "b", "alice", 300)
    lock = hold_lock(prefix, "b")
    renew_b = Task.async(fn -> Lease.renew(lease, "alice", ["b"], @minute) end)
    wait_until(fn -> match?({:ok, %{status: :stale}}, Lease.status(lease, "b")) end, 5_000)
    release_lock(lock)
    assert {:renewed, %{refused: %{"b" => %{reason: :stale}}}} = Task.await(renew_b, 10_000)
    assert length(TestHelper.rows(store, "b")) == 1

    # LS8c: sampled live, the store clock passes expiry after the sample, the commit is accepted with the earlier sample
    test = self()

    {:ok, lease_c} =
      TestHelper.pg_lease(store,
        hook: fn
          :after_clock, %{key: "c"} ->
            send(test, :sampled)
            receive do: (:go -> :ok)

          _, _ ->
            :ok
        end
      )

    {:held, c} = Lease.claim(lease, "c", "alice", 2_000)
    renew_c = Task.async(fn -> Lease.renew(lease_c, "alice", ["c"], 60 * @minute) end)
    receive do: (:sampled -> :ok)
    wait_until(fn -> TestHelper.pg_now(TestRepo) >= c.live.until end, 10_000)
    send(renew_c.pid, :go)

    assert {:renewed, %{held: %{"c" => %{live: %{at: at, until: until}}}}} =
             Task.await(renew_c, 15_000)

    assert at < c.live.until and until == at + 60 * @minute * 1000
    assert {:ok, %{status: :active}} = Lease.status(lease, "c")
  end

  test "LS9/LS10/LS18/LS25 future stamp, unreadable record, regression on a free key, the 100 -> 90 -> 95 terminal sequence",
       %{lease: lease, store: store, prefix: prefix} do
    future = TestHelper.pg_now(TestRepo) + @hour_us
    # LS9
    TestHelper.forge!(store, "f", 0, [
      {"lease_claimed", TestHelper.holder_payload("alice", future, @minute)}
    ])

    assert {:ok, %{status: :ambiguous, reason: :future_stamp, holder: %{owner: "alice"}}} =
             Lease.status(lease, "f")

    assert {:lease_refused, %{reason: :ambiguous}} = Lease.claim(lease, "f", "bob", @minute)
    assert {:lease_refused, %{reason: :ambiguous}} = Lease.release(lease, "f", "alice")
    assert {:held, _} = Lease.seize(lease, "f", "op", @minute, :clock_regression)
    assert {:ok, %{status: :active, holder: %{owner: "op"}}} = Lease.status(lease, "f")
    # LS10: garbage payload and a digest mismatch
    TestHelper.forge!(store, "u", 0, [{"lease_claimed", "{garbage"}])
    assert {:ok, %{status: :ambiguous, reason: :unreadable, holder: nil}} = Lease.status(lease, "u")
    {:held, _} = Lease.claim(lease, "d", "alice", @minute)

    SQL.query!(
      TestRepo,
      "UPDATE #{Postgres.identifier(prefix)}.elzoo_log_records SET payload = $2 WHERE stream = $1",
      ["d", TestHelper.holder_payload("mallory", 1, 1)],
      log: false
    )

    assert {:ok, %{status: :ambiguous, reason: :unreadable}} = Lease.status(lease, "d")
    assert {:lease_refused, %{reason: :unreadable}} = Lease.claim(lease, "d", "bob", @minute)
    assert {:held, _} = Lease.seize(lease, "d", "op", @minute, :corrupt_record)

    # LS18: a release stamped in the future makes the free key regressed for every ordinary operation
    TestHelper.forge!(store, "r", 0, [
      {"lease_released", TestHelper.release_payload("x", "x", future, :released)}
    ])

    assert {:ok, %{status: :free}} = Lease.status(lease, "r")
    assert {:lease_refused, %{reason: :regression}} = Lease.claim(lease, "r", "bob", @minute)

    assert {:claimed, %{refused: %{"r" => %{reason: :regression}}}} =
             Lease.claim_expired(lease, "bob", @minute, 1, ["r"])

    assert {:held, _} = Lease.seize(lease, "r", "op", @minute, :clock_regression)

    # LS25: latest holder stamp ahead of the clock (100); samples now (90) and later (95) stay earlier than it
    TestHelper.forge!(store, "t", 0, [
      {"lease_claimed", TestHelper.holder_payload("alice", future, @minute)}
    ])

    h = %{
      owner: "alice",
      live: %{key: "t", revision: 1, at: future, until: future + @minute * 1000}
    }

    assert {:lease_refused, %{reason: :regression}} = Lease.complete(lease, h, [{"done", 1, "r"}])
    assert length(TestHelper.rows(store, "t")) == 1

    assert {:ok, %{status: :ambiguous, reason: :future_stamp, holder: %{owner: "alice"}}} =
             Lease.status(lease, "t")

    assert {:lease_refused, %{reason: :regression}} = Lease.complete(lease, h, [{"done", 1, "r"}])

    assert {:renewed, %{refused: %{"t" => %{reason: :ambiguous}}}} =
             Lease.renew(lease, "alice", ["t"], @minute)

    assert {:held, s} = Lease.seize(lease, "t", "op", @minute, :clock_regression)

    assert %{"reason" => "clock_regression", "owner" => "alice", "by" => "op"} =
             Jason.decode!(Enum.at(TestHelper.rows(store, "t"), 1).payload)

    assert {:fenced, %{expected: 1, observed: 3}} = Lease.complete(lease, h, [{"done", 1, "r"}])
    assert {:completed, %{revision: 5}} = Lease.complete(lease, s, [{"done", 1, "r"}])
    assert {:ok, %{status: :free}} = Lease.status(lease, "t")
  end

  test "LS11 unknown outcomes: a committed write with a lost reply confirms; a failure before commit leaves nothing",
       %{store: store} do
    test = self()

    {:ok, lease} =
      TestHelper.pg_lease(store,
        hook: fn phase, %{key: key} ->
          case {phase, Process.get({:fail, key})} do
            {^phase, ^phase} ->
              Process.delete({:fail, key})
              send(test, {:failed, phase})
              raise DBConnection.ConnectionError, "injected failure"

            _ ->
              :ok
          end
        end
      )

    Process.put({:fail, "k"}, :after_commit)
    assert {:indeterminate, info} = Lease.claim(lease, "k", "alice", @minute)
    assert {:committed, 1} = Lease.confirm(lease, info)
    assert {:held, _} = Lease.hold(lease, "k", "alice")
    Process.put({:fail, "s"}, :after_write)
    assert {:indeterminate, info2} = Lease.claim(lease, "s", "alice", @minute)
    assert {:unknown, :unfenced} = Lease.confirm(lease, info2)
    assert [] = TestHelper.rows(store, "s")
    {:held, _} = Lease.claim(lease, "s", "bob", @minute)
    assert :superseded = Lease.confirm(lease, info2)

    # LS11c the terminal batch is atomic: a failure after the writes but before commit leaves neither record
    {:held, h} = Lease.claim(lease, "t", "alice", @minute)
    Process.put({:fail, "t"}, :after_write)
    assert {:indeterminate, _} = Lease.complete(lease, h, [{"done", 1, "r"}])
    assert length(TestHelper.rows(store, "t")) == 1
    assert {:completed, %{revision: 3}} = Lease.complete(lease, h, [{"done", 1, "r"}])
    assert [_, %{kind: "done"}, %{kind: "lease_released"}] = TestHelper.rows(store, "t")
  end

  test "LS12/LS13/LS14 caller transaction, unreachable repo stays unavailable, construction pairing",
       %{
         lease: lease,
         store: store
       } do
    {:held, h} = Lease.claim(lease, "k", "alice", @minute)

    TestRepo.transaction(fn ->
      assert {:error, :caller_transaction} = Lease.claim(lease, "k2", "alice", @minute)
      assert {:error, :caller_transaction} = Lease.status(lease, "k")

      assert {:error, :caller_transaction} =
               Lease.renew(lease, "alice", ["k"], @minute)
               |> elem(1)
               |> Map.fetch!(:errors)
               |> Map.fetch!("k")

      assert {:error, :caller_transaction} = Lease.claim_expired(lease, "alice", @minute, 1, ["k"])
      assert {:error, :caller_transaction} = Lease.complete(lease, h, [{"done", 1, "r"}])
      assert {:error, :caller_transaction} = Lease.write(lease, h, [{"added", 1, "x"}])

      assert {:error, :caller_transaction} =
               Lease.confirm(lease, %{stream: "k", expected: 0, nonce: <<0::128>>, records: []})

      assert {:error, :caller_transaction} = TestHelper.pg_lease(store)
    end)

    assert [] = TestHelper.rows(store, "k2")
    {:ok, manual} = Elzoo.Lease.Clock.manual(0)

    assert {:error, {:invalid, :clock}} =
             Lease.new(
               store: store,
               fold: TestHelper.fold(),
               limits: TestHelper.limits(),
               clock: {:manual, manual}
             )

    Supervisor.stop(Process.whereis(TestRepo))
    assert {:error, :unavailable} = Lease.claim(lease, "k3", "alice", @minute)
    assert {:error, :unavailable} = Lease.claim_expired(lease, "alice", @minute, 1, ["k3"])
    assert {:error, :unavailable} = Lease.status(lease, "k")
    assert {:error, :unavailable} = Lease.write(lease, h, [{"added", 1, "x"}])

    assert {:error, :unavailable} =
             Lease.confirm(lease, %{stream: "k", expected: 0, nonce: <<0::128>>, records: []})

    {:ok, repo} = TestRepo.start_link(url: TestHelper.url!(), pool_size: 20, log: false)
    Process.unlink(repo)
  end

  test "LS15/LS16/LS17 retention: pruned latest record fails closed, concurrent retention is serialized by the head lock",
       %{lease: lease, store: store, prefix: prefix} do
    {:held, h} = Lease.claim(lease, "k", "alice", @minute)
    {:held, _} = Lease.write(lease, h, [{"added", 1, "x"}])
    {:renewed, _} = Lease.renew(lease, "alice", ["k"], @minute)
    assert {:ok, %{through: 2}} = Lease.retention_bound(lease, "k")
    {_, _} = TestHelper.checkpoint(store, "k")
    :ok = TestHelper.retain!(store, "k", 2)
    assert {:ok, %{status: :active, low_water: 2}} = Lease.status(lease, "k")
    :ok = TestHelper.retain!(store, "k", 3)
    assert {:ok, %{status: :ambiguous, reason: :pruned_prefix}} = Lease.status(lease, "k")
    assert {:lease_refused, %{reason: :pruned_prefix}} = Lease.claim(lease, "k", "bob", @minute)
    assert {:held, _} = Lease.seize(lease, "k", "op", @minute, :pruned_prefix)

    # LS16: the Store's retain pauses after its head lock; the lease step waits for it and reads the post-retention state
    test = self()

    paused_store =
      TestHelper.pg_store(TestRepo, prefix,
        test_hook: fn
          :maintenance, :after_head_lock, _ ->
            send(test, :retain_locked)
            receive do: (:continue -> :ok)

          _, _, _ ->
            :ok
        end
      )

    {:held, h2} = Lease.claim(lease, "r", "alice", @minute)
    {:held, _} = Lease.write(lease, h2, [{"added", 1, "x"}])
    {_, _} = TestHelper.checkpoint(store, "r")

    retain =
      Task.async(fn -> Postgres.retain(paused_store, "r", 0, 1, :crypto.strong_rand_bytes(16)) end)

    receive do: (:retain_locked -> :ok)
    claim = Task.async(fn -> Lease.claim(lease, "r", "bob", @minute) end)
    Process.sleep(200)
    refute Task.yield(claim, 0)
    send(retain.pid, :continue)
    assert {:committed, 1} = Task.await(retain, 10_000)
    assert {:lease_refused, %{reason: :pruned_prefix}} = Task.await(claim, 10_000)

    assert {:ok, %{status: :ambiguous, reason: :pruned_prefix, low_water: 1}} =
             Lease.status(lease, "r")
  end

  test "LS20 completed receipt is not a lease; LS26 an unlocked reader sees stale before a sampled-live renewal commits and active after",
       %{lease: lease, store: store} do
    {:held, h} = Lease.claim(lease, "k", "alice", @minute)
    assert {:completed, receipt} = Lease.complete(lease, h, [{"done", 1, "r"}])
    refute Map.has_key?(receipt, :live)
    assert {:error, {:invalid, :held}} = Lease.write(lease, receipt, [{"added", 1, "x"}])
    assert {:fenced, _} = Lease.complete(lease, h, [{"done", 1, "x"}])
    # LS26
    test = self()

    {:ok, lease_r} =
      TestHelper.pg_lease(store,
        hook: fn
          :after_clock, %{key: "c"} ->
            send(test, :sampled)
            receive do: (:go -> :ok)

          _, _ ->
            :ok
        end
      )

    {:held, c} = Lease.claim(lease, "c", "alice", 1_500)
    renew = Task.async(fn -> Lease.renew(lease_r, "alice", ["c"], 60 * @minute) end)
    receive do: (:sampled -> :ok)
    wait_until(fn -> TestHelper.pg_now(TestRepo) >= c.live.until end, 10_000)
    assert {:ok, %{status: :stale, as_of: 1}} = Lease.status(lease, "c")
    send(renew.pid, :go)
    assert {:renewed, %{held: %{"c" => %{live: %{revision: 2}}}}} = Task.await(renew, 15_000)
    assert {:ok, %{status: :active, as_of: 2}} = Lease.status(lease, "c")
  end

  test "LS22 the helper guard fails closed on an expectation mismatch and a mismatched database name" do
    url = TestHelper.url!()

    try do
      System.put_env("ELZOO_TEST_DATABASE_EXPECT", "another_database")
      assert_raise RuntimeError, ~r/does not match/, fn -> TestHelper.database_guard!(TestRepo) end
      System.delete_env("ELZOO_TEST_DATABASE_EXPECT")

      System.put_env(
        "ELZOO_TEST_DATABASE_URL",
        String.replace(url, ~r{/[^/?]+(\?.*)?$}, "/some_other_name")
      )

      assert_raise RuntimeError, ~r/effective database differs/, fn ->
        TestHelper.database_guard!(TestRepo)
      end

      System.delete_env("ELZOO_TEST_DATABASE_URL")
      assert_raise RuntimeError, ~r/required/, fn -> TestHelper.database_guard!(TestRepo) end
    after
      System.put_env("ELZOO_TEST_DATABASE_URL", url)

      if expect = System.get_env("ELZOO_TEST_DATABASE_EXPECT_SAVED"),
        do: System.put_env("ELZOO_TEST_DATABASE_EXPECT", expect)
    end

    assert :ok = TestHelper.database_guard!(TestRepo)
  end

  test "LS23 OD-1a: the complete migration v1 shape is pinned; any other shape fails closed with no write, also after construction",
       %{store: store, prefix: prefix} do
    {:ok, lease} = TestHelper.pg_lease(store)
    {:held, h} = Lease.claim(lease, "k", "alice", @minute)
    heads = "#{Postgres.identifier(prefix)}.elzoo_log_heads"
    records = "#{Postgres.identifier(prefix)}.elzoo_log_records"
    # added column
    SQL.query!(TestRepo, "ALTER TABLE #{heads} ADD COLUMN extra integer", [], log: false)

    assert {:error,
            {:schema,
             %{version: 1, heads: %{columns: %{unexpected: [{"extra", "integer", "YES", nil}]}}}}} =
             TestHelper.pg_lease(store)

    assert {:error, {:schema, _}} = Lease.claim(lease, "k2", "alice", @minute)
    assert {:error, {:schema, _}} = Lease.claim_expired(lease, "alice", @minute, 1, ["k"])

    # compatible-looking mutation after construction: the holder's write/4, the reads,
    # confirmation and complete/4 are refused, nothing written
    assert {:error, {:schema, _}} = Lease.write(lease, h, [{"added", 1, "x"}])
    assert {:error, {:schema, _}} = Lease.status(lease, "k")
    # The malformed receipt would return {:unknown, :malformed} without the pre-read pin.
    assert {:error, {:schema, _}} =
             Lease.confirm(lease, %{stream: "k", expected: 0, nonce: <<0::128>>, records: []})

    assert {:error, {:schema, _}} = Lease.complete(lease, h, [{"done", 1, "r"}])
    assert [] = TestHelper.rows(store, "k2")
    assert length(TestHelper.rows(store, "k")) == 1
    SQL.query!(TestRepo, "ALTER TABLE #{heads} DROP COLUMN extra", [], log: false)
    assert {:ok, _} = TestHelper.pg_lease(store)
    assert {:held, h} = Lease.write(lease, h, [{"added", 1, "x"}])
    # retyped column
    SQL.query!(TestRepo, "ALTER TABLE #{records} ALTER COLUMN schema_version TYPE bigint", [],
      log: false
    )

    assert {:error,
            {:schema,
             %{
               records: %{
                 columns: %{
                   missing: [{"schema_version", "integer", "NO", nil}],
                   unexpected: [{"schema_version", "bigint", "NO", nil}]
                 }
               }
             }}} = TestHelper.pg_lease(store)

    SQL.query!(TestRepo, "ALTER TABLE #{records} ALTER COLUMN schema_version TYPE integer", [],
      log: false
    )

    # nullability change
    SQL.query!(TestRepo, "ALTER TABLE #{heads} ALTER COLUMN revision DROP NOT NULL", [], log: false)

    assert {:error,
            {:schema,
             %{
               heads: %{
                 columns: %{
                   missing: [{"revision", "bigint", "NO", nil}],
                   unexpected: [{"revision", "bigint", "YES", nil}]
                 }
               }
             }}} = TestHelper.pg_lease(store)

    SQL.query!(TestRepo, "ALTER TABLE #{heads} ALTER COLUMN revision SET NOT NULL", [], log: false)
    # dropped check constraint
    SQL.query!(TestRepo, "ALTER TABLE #{heads} DROP CONSTRAINT elzoo_head_bounds", [], log: false)

    assert {:error,
            {:schema,
             %{heads: %{constraints: %{missing: [{"elzoo_head_bounds", "c", _}], unexpected: []}}}}} =
             TestHelper.pg_lease(store)

    assert {:error, {:schema, _}} = Lease.write(lease, h, [{"added", 1, "y"}])

    SQL.query!(
      TestRepo,
      "ALTER TABLE #{heads} ADD CONSTRAINT elzoo_head_bounds CHECK (revision >= 0 AND low_water >= 0 AND low_water <= revision)",
      [],
      log: false
    )

    assert {:ok, _} = TestHelper.pg_lease(store)
    # primary key change (the heads key; the records key carries the outbox foreign key)
    SQL.query!(TestRepo, "ALTER TABLE #{heads} DROP CONSTRAINT elzoo_log_heads_pkey", [],
      log: false
    )

    assert {:error,
            {:schema,
             %{
               heads: %{
                 constraints: %{missing: [{"elzoo_log_heads_pkey", "p", "PRIMARY KEY (stream)"}]}
               }
             }}} =
             TestHelper.pg_lease(store)

    SQL.query!(TestRepo, "ALTER TABLE #{heads} ADD PRIMARY KEY (stream)", [], log: false)
    assert {:ok, _} = TestHelper.pg_lease(store)
    # dropped column
    SQL.query!(TestRepo, "ALTER TABLE #{heads} DROP COLUMN last_retention_through", [], log: false)

    assert {:error,
            {:schema,
             %{heads: %{columns: %{missing: [{"last_retention_through", "bigint", "YES", nil}]}}}}} =
             TestHelper.pg_lease(store)

    _ = h
  end

  test "LS24 OD-1b: lease rows are the ready Store's rows (conformance K1–K11 over lease records, replay, confirm, retain)",
       %{store: store, lease: lease, prefix: prefix} do
    lease_record = {"lease_claimed", 1, TestHelper.holder_payload("conformance-owner", 1, 1_000)}

    opts = %{
      fold: TestHelper.fold(),
      limits: TestHelper.limits(),
      record: lease_record,
      destination: "sink",
      encode: &Integer.to_string/1
    }

    # each check runs in a fresh, empty namespace (the checks' own precondition)
    pg_factory = fn ->
      fresh = TestHelper.schema!(TestRepo)
      {:ok, controller} = PostgresHarness.start_link([])

      harness_store =
        PostgresHarness.attach(TestRepo, fresh, TestHelper.fold(), TestHelper.limits(), controller)

      cleanup = fn ->
        PostgresHarness.cleanup(controller)
        TestHelper.drop!(TestRepo, fresh)
        Agent.stop(controller)
      end

      {harness_store, Map.merge(opts, %{hook: &PostgresHarness.hook/3, cleanup: cleanup})}
    end

    for {name, check} <- Conformance.checks() do
      result = check.(pg_factory)

      assert :ok == result,
             "PostgreSQL conformance #{name} over lease records: #{inspect(result, limit: 40)}"
    end

    memory_factory = fn ->
      {:ok, pid} = Memory.start_link(fold: TestHelper.fold(), limits: TestHelper.limits())

      {Memory.store(pid),
       Map.merge(opts, %{hook: &Memory.conformance_hook/3, cleanup: fn -> GenServer.stop(pid) end})}
    end

    for {name, check} <- Conformance.checks() do
      result = check.(memory_factory)

      assert :ok == result,
             "Memory conformance #{name} over lease records: #{inspect(result, limit: 40)}"
    end

    _ = prefix

    # OD-1b counterexamples are refused at construction: a Store whose fold lacks the lease kinds,
    # or caller-passed fold/limits that differ from the Store term's
    plain_store =
      Postgres.store(TestRepo,
        prefix: prefix,
        fold: %{TestHelper.fold() | kinds: %{"added" => :state_bearing}},
        limits: TestHelper.limits()
      )

    assert {:error, {:invalid, :fold}} = Lease.new(store: plain_store, clock: :store)

    assert {:error, {:invalid, :fold}} =
             Lease.new(store: store, fold: %{TestHelper.fold() | versions: [1, 2]}, clock: :store)

    assert {:error, {:invalid, :limits}} =
             Lease.new(
               store: store,
               limits: %{TestHelper.limits() | max_record_bytes: 4_096},
               clock: :store
             )

    assert {:ok, _} =
             Lease.new(
               store: store,
               fold: TestHelper.fold(),
               limits: TestHelper.limits(),
               clock: :store
             )

    # replay over an interleaved stream: the cursor advances over lease records, the reducer never sees them
    {:held, h} = Lease.claim(lease, "mix", "alice", @minute)
    {:held, h} = Lease.write(lease, h, [{"added", 1, "x"}])
    {:renewed, _} = Lease.renew(lease, "alice", ["mix"], @minute)

    {:completed, _} =
      Lease.complete(lease, %{h | live: %{h.live | revision: 3}}, [{"done", 1, "r"}])

    rows = TestHelper.rows(store, "mix")
    assert Enum.map(rows, & &1.kind) == ~w(lease_claimed added lease_renewed done lease_released)

    assert %{model: 2, cursor: {5, false, []}, tail: :intact} =
             Log.replay(rows, 5, TestHelper.fold())

    assert Enum.all?(rows, &(Log.validate_row(&1, TestHelper.fold(), TestHelper.limits()) == :ok))

    # the Store's own read returns every Adapter-written row as a valid record (an invalid row would be a plain map)
    assert Enum.all?(rows, &match?(%Log.Record{}, &1))
    assert {:ok, %Log.Record{kind: "lease_renewed"}, _} = Postgres.read_at(store, "mix", 3)
    # confirm by nonce through the ready Store
    renewed = Enum.at(rows, 2)
    assert {:committed, 3} = Log.confirm(store, "mix", 2, renewed.nonce, [renewed])
    # retain through a lease record; the lease reads pruned_prefix (fail closed)
    {_, _} = TestHelper.checkpoint(store, "mix")
    :ok = TestHelper.retain!(store, "mix", 5)

    assert {:ok, %{status: :ambiguous, reason: :pruned_prefix, low_water: 5}} =
             Lease.status(lease, "mix")
  end

  test "LS28 absent-head races: uncommitted first claim looks free, locked head is skipped, a commit between the two probes is evaluated, single-key claim serializes after the first commit",
       %{lease: lease, store: store, prefix: prefix} do
    heads = "#{Postgres.identifier(prefix)}.elzoo_log_heads"
    test = self()

    # Holder, first claimant and strict contender use three reserved connections of this
    # dedicated pool, never the shared suite pool or a short checkout timeout.
    {:ok, contention_repo} =
      LS28Repo.start_link(url: TestHelper.url!(), pool_size: 3, log: false)

    Process.unlink(contention_repo)

    on_exit(fn ->
      if pid = Process.whereis(LS28Repo), do: Supervisor.stop(pid)
    end)

    contention_store = TestHelper.pg_store(LS28Repo, prefix)

    # (a) a transaction holds an uncommitted head insert for "x": the sweep sees no committed head and reports free without blocking
    holder =
      Task.async(fn ->
        LS28Repo.transaction(fn ->
          SQL.query!(LS28Repo, "INSERT INTO #{heads} (stream, revision) VALUES ('x', 0)", [],
            log: false
          )

          send(test, :inserted)

          receive do
            :commit -> :ok
          after
            5_000 -> raise "uncommitted holder was not released"
          end
        end)
      end)

    receive do
      :inserted -> :ok
    after
      5_000 -> raise "uncommitted holder did not insert its head"
    end

    assert {:claimed, %{refused: %{"x" => %{reason: :free}}, skipped_locked: []}} =
             Lease.claim_expired(lease, "sweeper", @minute, 1, ["x"])

    # (d) the first claimant has checked out a reserved connection and entered
    # the Piece's transaction before the first insert commits. The test
    # observes its unique-index lock wait, then commits the holder. The first
    # claimant holds the now-present head lock while the strict second
    # claimant receives the database's lock-not-available result.
    {:ok, first_claimant} =
      TestHelper.pg_lease(contention_store,
        hook: fn
          :before_lock, %{key: "x", repo: repo} ->
            [[backend_pid]] = SQL.query!(repo, "SELECT pg_backend_pid()", [], log: false).rows
            send(test, {:first_claimant_ready, self(), backend_pid})

            receive do
              :continue_first_claimant -> :ok
            after
              5_000 -> raise "first claimant was not released"
            end

          :after_lock, %{key: "x"} ->
            send(test, {:first_claimant_holds_lock, self()})

            receive do
              :release_first_claimant -> :ok
            after
              5_000 -> raise "first claimant was not released after locking"
            end

          _, _ ->
            :ok
        end
      )

    first_claim = Task.async(fn -> Lease.claim(first_claimant, "x", "bob", @minute) end)

    {first_claimant_pid, backend_pid} =
      receive do
        {:first_claimant_ready, pid, backend_pid} -> {pid, backend_pid}
      after
        5_000 -> raise "first claimant did not enter its reserved connection"
      end

    send(first_claimant_pid, :continue_first_claimant)
    wait_until(fn -> contender_waits_on_lock?(backend_pid) end, 5_000)
    send(holder.pid, :commit)
    assert {:ok, _} = Task.await(holder, 10_000)

    first_lock_pid =
      receive do
        {:first_claimant_holds_lock, pid} -> pid
      after
        5_000 -> raise "first claimant did not lock the committed head"
      end

    {:ok, strict_contender} =
      TestHelper.pg_lease(contention_store,
        hook: fn
          :before_lock, %{key: "x", repo: repo} ->
            SQL.query!(repo, "SET LOCAL lock_timeout = '100ms'", [], log: false)

          _, _ ->
            :ok
        end
      )

    assert {:error, :contended} = Lease.claim(strict_contender, "x", "carol", @minute)

    {:ok, timed_contender} =
      TestHelper.pg_lease(contention_store,
        timeout_ms: 500,
        hook: fn
          :before_lock, %{key: "x", repo: repo} ->
            [[backend_pid]] = SQL.query!(repo, "SELECT pg_backend_pid()", [], log: false).rows
            [[lock_timeout]] = SQL.query!(repo, "SHOW lock_timeout", [], log: false).rows
            send(test, {:timed_contender_ready, backend_pid, lock_timeout})

          _, _ ->
            :ok
        end
      )

    timed_claim = Task.async(fn -> Lease.claim(timed_contender, "x", "dana", @minute) end)

    timed_backend_pid =
      receive do
        {:timed_contender_ready, backend_pid, "500ms"} -> backend_pid
      after
        5_000 -> raise "timed contender did not enter the configured lock-timeout connection"
      end

    wait_until(fn -> contender_waits_on_lock?(timed_backend_pid) end, 5_000)
    assert {:error, :contended} = Task.await(timed_claim, 5_000)

    send(first_lock_pid, :release_first_claimant)
    assert {:held, _} = Task.await(first_claim, 10_000)

    # A transport close at the exact pre-insert seam is not proof of lock
    # contention and must remain unavailable.
    {:ok, disconnected_contender} =
      TestHelper.pg_lease(contention_store,
        hook: fn
          :before_insert_head, %{key: "disconnect", repo: repo} ->
            [[backend_pid]] = SQL.query!(repo, "SELECT pg_backend_pid()", [], log: false).rows

            terminator =
              Task.async(fn ->
                SQL.query!(TestRepo, "SELECT pg_terminate_backend($1)", [backend_pid], log: false)
              end)

            assert [[true]] = Task.await(terminator, 5_000).rows

          _, _ ->
            :ok
        end
      )

    assert {:error, :unavailable} =
             Lease.claim(disconnected_contender, "disconnect", "erin", @minute)

    # (b) a committed head locked by another transaction is skipped_locked and the sweep's transaction still commits its other claims
    past = TestHelper.pg_now(TestRepo) - @hour_us

    TestHelper.forge!(store, "y", 0, [
      {"lease_claimed", TestHelper.holder_payload("old", past, @minute)}
    ])

    lock = hold_lock(prefix, "x")

    assert {:claimed, %{held: [%{live: %{key: "y"}}], skipped_locked: ["x"]}} =
             Lease.claim_expired(lease, "sweeper", @minute, 5, ~w(x y))

    release_lock(lock)

    # (c) a first claim committed between the two probes is evaluated (active -> refused), never reported skipped_locked or free
    {:ok, probing} =
      TestHelper.pg_lease(store,
        hook: fn
          :after_skip_locked, %{key: "z"} ->
            send(test, :probing)

            receive do
              :go -> :ok
            after
              5_000 -> raise "sweep was not released after its first probe"
            end

          _, _ ->
            :ok
        end
      )

    first =
      Task.async(fn ->
        TestRepo.transaction(fn ->
          forge_rows(prefix, "z", 0, [
            {"lease_claimed",
             TestHelper.holder_payload("first", TestHelper.pg_now(TestRepo), @minute)}
          ])

          send(test, :first_ready)

          receive do
            :commit -> :ok
          after
            5_000 -> raise "between-probes holder was not released"
          end
        end)
      end)

    receive do
      :first_ready -> :ok
    after
      5_000 -> raise "between-probes holder did not become ready"
    end

    sweep = Task.async(fn -> Lease.claim_expired(probing, "sweeper", @minute, 1, ["z"]) end)

    receive do
      :probing -> :ok
    after
      5_000 -> raise "sweep did not reach the second probe"
    end

    send(first.pid, :commit)
    assert {:ok, _} = Task.await(first, 10_000)
    send(sweep.pid, :go)

    assert {:claimed,
            %{refused: %{"z" => %{reason: :active, holder: "first"}}, skipped_locked: [], held: []}} =
             Task.await(sweep, 10_000)
  end
end
