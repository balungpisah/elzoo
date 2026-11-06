# SPDX-License-Identifier: Apache-2.0
Code.require_file(Path.expand("../../../../../test/support/durable_log_postgres.exs", __DIR__))

defmodule Elzoo.DurableLog.PostgresTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL
  alias Elzoo.{Checkpoint, Outbox}
  alias Elzoo.DurableLog, as: Log

  alias Elzoo.DurableLog.{
    Codec,
    Conformance,
    Postgres,
    PostgresHarness,
    Record,
    TestMigration,
    TestRepo,
    UnreachableRepo,
    Writer
  }

  @url PostgresHarness.database_url!()
  @limits %{max_record_bytes: 64, max_batch_size: 8, max_checkpoint_bytes: 10_000}
  defp fold,
    do: %{
      initial: 0,
      kinds: %{"added" => :state_bearing},
      versions: [1],
      destinations: ["sink"],
      reduce: fn n, _, _, _ -> n + 1 end
    }

  defp row(seq, nonce \\ <<1::128>>, stream \\ "pg") do
    r = %Record{
      stream: stream,
      sequence: seq,
      kind: "added",
      schema_version: 1,
      payload: "event",
      nonce: nonce
    }

    %{r | digest: Log.digest(r)}
  end

  defp checkpoint(rows) do
    replay = Log.replay(rows, List.last(rows).sequence, fold())

    c = %{
      stream: hd(rows).stream,
      sequence: elem(replay.cursor, 0),
      fold_version: 1,
      model: Integer.to_string(replay.model),
      cursor: replay.cursor,
      seen: replay.seen,
      nonce: :crypto.strong_rand_bytes(16)
    }

    Map.put(c, :digest, Codec.hash(Codec.checkpoint_bytes(c)))
  end

  defp start_writer(store) do
    result = Writer.start_link(store: store, stream: "pg", fold: fold(), limits: @limits)

    if match?({:ok, _}, result) do
      {:ok, writer} = result
      Process.unlink(writer)
      on_exit(fn -> if Process.alive?(writer), do: GenServer.stop(writer) end)
    end

    result
  end

  setup_all do
    {:ok, repo} = TestRepo.start_link(url: @url, pool_size: 2, log: false)

    try do
      PostgresHarness.reachable!(TestRepo)

      observations =
        for name <- ["server_version", "fsync", "synchronous_commit"] do
          [[value]] = SQL.query!(TestRepo, "SHOW #{name}", [], log: false).rows
          "#{name}=#{value}"
        end

      IO.puts("PostgreSQL monitored: " <> Enum.join(observations, " "))
    after
      Supervisor.stop(repo)
    end

    :ok
  end

  setup do
    Process.flag(:trap_exit, true)
    {:ok, repo} = TestRepo.start_link(url: @url, pool_size: 20, log: false)
    Process.unlink(repo)
    {:ok, controller} = PostgresHarness.start_link([])
    Process.unlink(controller)
    prefix = "elzoo_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    SQL.query!(TestRepo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [], log: false)
    :ok = Ecto.Migrator.up(TestRepo, 1, TestMigration, prefix: prefix, log: false)
    store = PostgresHarness.attach(TestRepo, prefix, fold(), @limits, controller)

    on_exit(fn ->
      try do
        PostgresHarness.cleanup(controller)
        SQL.query!(TestRepo, "DROP SCHEMA #{Postgres.identifier(prefix)} CASCADE", [], log: false)
      after
        Agent.stop(controller)
        if repo = Process.whereis(TestRepo), do: Supervisor.stop(repo)
      end
    end)

    %{store: store, prefix: Postgres.identifier(prefix), controller: controller}
  end

  for {{name, _}, index} <- Enum.with_index(Conformance.checks(), 1) do
    test "K#{index} #{name} against PostgreSQL", %{store: store} do
      opts = %{
        fold: fold(),
        limits: @limits,
        record: {"added", 1, "event"},
        destination: "sink",
        encode: &Integer.to_string/1,
        hook: &PostgresHarness.hook/3
      }

      assert :ok == Keyword.fetch!(Conformance.checks(), unquote(name)).(fn -> {store, opts} end)
    end
  end

  test "D11 Repo/pool restart preserves checkpoint fold and pending identities", %{store: s} do
    rows = [row(1), row(2)]
    items = Enum.map(rows, &Outbox.new("pg", &1.sequence, 1, "sink", "effect", &1.nonce))
    assert {:committed, 2} = Postgres.append(s, "pg", 0, rows, items)
    assert {:committed, 1} = Outbox.ack(s, hd(items).idempotency_key, <<2::128>>)
    assert {:committed, 2} = Postgres.put_checkpoint(s, checkpoint(rows))
    {:ok, pending} = Outbox.pending(s, "pg", 10)
    before = Checkpoint.recover(s, "pg", fold(), 1, fn bytes -> {:ok, String.to_integer(bytes)} end)
    assert :ok = Supervisor.stop(Process.whereis(TestRepo))
    {:ok, repo} = TestRepo.start_link(url: @url, pool_size: 20, log: false)
    Process.unlink(repo)

    assert Checkpoint.recover(s, "pg", fold(), 1, fn bytes -> {:ok, String.to_integer(bytes)} end) ==
             before

    assert Outbox.pending(s, "pg", 10) == {:ok, pending}
    {:ok, writer} = start_writer(s)
    assert Writer.snapshot(writer) == before
  end

  test "K6/D15 real first head INSERT and existing-head CAS stay unknown before late COMMIT", %{
    store: s,
    prefix: prefix,
    controller: controller
  } do
    for expected <- [0, 1] do
      r = row(expected + 1, :crypto.strong_rand_bytes(16))
      token = make_ref()
      PostgresHarness.hook(s, :inject, [:append, {:pause, token, :after_head_cas}])
      assert {:indeterminate, _} = Postgres.append(s, "pg", expected, [r], [])
      %{backend: backend} = PostgresHarness.paused(controller, token)

      assert [["idle in transaction"]] =
               SQL.query!(TestRepo, "SELECT state FROM pg_stat_activity WHERE pid=$1", [backend],
                 log: false
               ).rows

      visible =
        SQL.query!(TestRepo, "SELECT revision FROM #{prefix}.elzoo_log_heads WHERE stream='pg'", [],
          log: false
        ).rows

      assert visible == if(expected == 0, do: [], else: [[1]])
      assert {:unknown, :unfenced} = Log.confirm(s, "pg", expected, r.nonce, [r])
      assert {:committed, revision} = PostgresHarness.hook(s, :release, [token])
      assert revision == expected + 1
      assert {:committed, ^revision} = Log.confirm(s, "pg", expected, r.nonce, [r])
    end

    r = row(3, :crypto.strong_rand_bytes(16))
    PostgresHarness.hook(s, :inject, [:append, {:pause, :inserted, :before_commit}])
    assert {:indeterminate, _} = Postgres.append(s, "pg", 2, [r], [])
    assert {:unknown, :unfenced} = Log.confirm(s, "pg", 2, r.nonce, [r])
    assert {:committed, 3} = PostgresHarness.hook(s, :release, [:inserted])
    assert {:committed, 3} = Log.confirm(s, "pg", 2, r.nonce, [r])
  end

  test "D15 real checkpoint and retention barriers require exact receipts after COMMIT", %{store: s} do
    r = row(1)
    assert {:committed, 1} = Postgres.append(s, "pg", 0, [r], [])
    c = checkpoint([r])
    PostgresHarness.hook(s, :inject, [:put_checkpoint, {:pause, :checkpoint}])
    assert {:indeterminate, _} = Postgres.put_checkpoint(s, c)
    assert {:unknown, :unfenced} = Log.confirm_checkpoint(s, c)
    assert {:committed, 1} = PostgresHarness.hook(s, :release, [:checkpoint])
    assert {:committed, 1} = Log.confirm_checkpoint(s, c)
    receipt = Codec.receipt(:retain, "pg", 0, 1, <<3::128>>)
    PostgresHarness.hook(s, :inject, [:retain, {:pause, :retention}])
    assert {:indeterminate, _} = Postgres.retain(s, "pg", 0, 1, receipt.nonce)
    assert {:unknown, :unfenced} = Log.confirm_retention(s, receipt)
    assert {:committed, 1} = PostgresHarness.hook(s, :release, [:retention])
    assert {:committed, 1} = Log.confirm_retention(s, receipt)
  end

  test "D17 interior AND last committed UPDATE corruption yields damaged prefix without application writes",
       %{store: s, prefix: prefix} do
    for target <- [2, 3] do
      stream = "corrupt-#{target}"
      rows = Enum.map(1..3, &row(&1, <<1::128>>, stream))

      items =
        Enum.map(
          Enum.drop(rows, 1),
          &Outbox.new(stream, &1.sequence, 1, "sink", "effect", &1.nonce)
        )

      assert {:committed, 3} = Postgres.append(s, stream, 0, rows, items)
      assert {:committed, 3} = Outbox.ack(s, List.last(items).idempotency_key, <<2::128>>)

      SQL.query!(
        TestRepo,
        "UPDATE #{prefix}.elzoo_log_records SET digest=$3 WHERE stream=$1 AND sequence=$2",
        [stream, target, <<0::256>>],
        log: false
      )

      before = PostgresHarness.hook(s, :snapshot, [])
      assert {:ok, read, head} = Log.read(s, stream, 1, 10)
      replay = Log.replay(read, head, fold())
      assert replay.model == target - 1
      assert replay.cursor == {target - 1, true, [{:corrupt, target, :digest_mismatch}]}
      assert Checkpoint.recover(s, stream, fold(), 1, fn b -> {:ok, b} end) == replay

      assert {:error, {:replay_damaged, _}} =
               Writer.start_link(store: s, stream: stream, fold: fold(), limits: @limits)

      assert {:rejected, :torn_repair_unsupported} =
               Postgres.repair_torn_tail(s, stream, 3, <<1::128>>, <<2::128>>)

      assert {:ok, [_]} = Outbox.pending(s, stream, 10)
      assert PostgresHarness.hook(s, :snapshot, []) == before
    end
  end

  test "head-first ack locking, immutable FK and after-commit reply loss", %{
    store: s,
    prefix: prefix
  } do
    r = row(1)
    item = Outbox.new("pg", 1, 1, "sink", "effect", r.nonce)
    PostgresHarness.hook(s, :inject, [:append, {:pause, :committed, :after_commit_reply}])
    assert {:indeterminate, _} = Postgres.append(s, "pg", 0, [r], [item])
    assert {:committed, 1} = Log.confirm(s, "pg", 0, r.nonce, [r])
    assert {:committed, 1} = PostgresHarness.hook(s, :release, [:committed])
    before = PostgresHarness.hook(s, :snapshot, [])

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             SQL.query(TestRepo, "DELETE FROM #{prefix}.elzoo_log_records WHERE stream='pg'", [],
               log: false
             )

    assert PostgresHarness.hook(s, :snapshot, []) == before
    receipt = Codec.ack_receipt(item.idempotency_key, <<2::128>>)
    PostgresHarness.hook(s, :inject, [:ack, {:pause, :head_locked, :after_head_lock}])
    assert {:indeterminate, _} = Postgres.ack(s, item.idempotency_key, receipt.nonce)
    assert {:unknown, :unfenced} = Log.confirm_ack(s, receipt)

    assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
             SQL.query(
               TestRepo,
               "SELECT revision FROM #{prefix}.elzoo_log_heads WHERE stream='pg' FOR UPDATE NOWAIT",
               [],
               log: false
             )

    assert [[1]] =
             SQL.query!(
               TestRepo,
               "SELECT sequence FROM #{prefix}.elzoo_outbox WHERE stream='pg' FOR UPDATE NOWAIT",
               [],
               log: false
             ).rows

    assert {:committed, 1} = PostgresHarness.hook(s, :release, [:head_locked])
    assert {:committed, 1} = Log.confirm_ack(s, receipt)
    assert {:ok, []} = Outbox.pending(s, "pg", 10)
  end

  test "returned checkpoint wire/digest and outbox rows are revalidated without reader writes", %{
    store: s,
    prefix: prefix
  } do
    r = row(1)
    item = Outbox.new("pg", 1, 1, "sink", "effect", r.nonce)
    assert {:committed, 1} = Postgres.append(s, "pg", 0, [r], [item])
    c = checkpoint([r])
    assert {:committed, 1} = Postgres.put_checkpoint(s, c)

    for {cursor, seen, digest} <- [
          {<<255>>, Codec.seen_bytes(c.seen), c.digest},
          {Codec.cursor_bytes(c.cursor), <<1, 1::32>>, c.digest},
          {Codec.cursor_bytes(c.cursor), Codec.seen_bytes(c.seen), <<0::256>>}
        ] do
      SQL.query!(
        TestRepo,
        "UPDATE #{prefix}.elzoo_checkpoints SET cursor=$1,seen=$2,digest=$3",
        [cursor, seen, digest],
        log: false
      )

      before = PostgresHarness.hook(s, :snapshot, [])
      assert {:ok, invalid} = Postgres.latest_checkpoint(s, "pg", 1)
      refute Codec.checkpoint_valid?(invalid)

      assert %{model: 1, cursor: {1, false, []}} =
               Checkpoint.recover(s, "pg", fold(), 1, fn b -> {:ok, String.to_integer(b)} end)

      assert PostgresHarness.hook(s, :snapshot, []) == before
    end

    SQL.query!(TestRepo, "UPDATE #{prefix}.elzoo_outbox SET destination='undeclared'", [],
      log: false
    )

    before = PostgresHarness.hook(s, :snapshot, [])
    assert {:error, :malformed} = Outbox.pending(s, "pg", 10)
    assert PostgresHarness.hook(s, :snapshot, []) == before
  end

  test "declared empty kinds round trip through the portable text domain", %{
    prefix: prefix
  } do
    empty = %{fold() | kinds: %{"" => :state_bearing}}
    s = Postgres.store(TestRepo, prefix: String.trim(prefix, "\""), fold: empty, limits: @limits)
    r = %{row(1) | kind: ""}
    r = %{r | digest: Log.digest(r)}
    item = Outbox.new("pg", 1, 1, "sink", "effect", r.nonce)
    assert {:committed, 1} = Postgres.append(s, "pg", 0, [r], [item])
    assert {:ok, [read], _} = Postgres.read(s, "pg", 1, 10)
    assert read == r
    assert {:ok, [pending]} = Outbox.pending(s, "pg", 10)
    assert pending.destination == "sink"
  end

  @tag capture_log: true
  test "D19 pg_terminate_backend during Writer transaction is indeterminate and stops Writer", %{
    store: s
  } do
    {:ok, writer} = start_writer(s)
    monitor = Process.monitor(writer)
    PostgresHarness.hook(s, :inject, [:append, {:terminate, self()}])
    caller = Task.async(fn -> Writer.append(writer, [{"added", 1, "event"}]) end)
    assert_receive {:postgres_backend, ^writer, backend}, 5_000

    assert [[true]] =
             SQL.query!(TestRepo, "SELECT pg_terminate_backend($1)", [backend], log: false).rows

    send(writer, :continue)
    assert {:indeterminate, info} = Task.await(caller, 5_000)
    assert_receive {:DOWN, ^monitor, :process, ^writer, {:shutdown, {:indeterminate_write, ^info}}}
    assert {:unknown, :unfenced} = Log.confirm(s, "pg", 0, info.nonce, [row(1, info.nonce)])
  end

  @tag capture_log: true
  test "D19 unreachable server yields indeterminate/unavailable and Writer init refuses service", %{
    store: s
  } do
    url = @url |> URI.parse() |> Map.put(:port, 1) |> URI.to_string()

    start_supervised!(
      {UnreachableRepo,
       url: url,
       pool_size: 1,
       connect_timeout: 100,
       timeout: 150,
       queue_target: 10,
       queue_interval: 50,
       backoff_min: 100,
       backoff_max: 100,
       log: false}
    )

    bad = Postgres.store(UnreachableRepo, fold: fold(), limits: @limits, timeout: 150)
    before = PostgresHarness.hook(s, :snapshot, [])
    assert {:indeterminate, _} = Postgres.append(bad, "pg", 0, [row(1)], [])
    assert {:error, :unavailable} = Postgres.head(bad, "pg")
    assert {:error, {:storage, :unavailable}} = start_writer(bad)
    assert PostgresHarness.hook(s, :snapshot, []) == before
  end
end
