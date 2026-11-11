# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/data_stream_test_helper.exs", __DIR__)

defmodule Elzoo.DataStream.SqlRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.DataStream.SqlMigration do
  use Ecto.Migration
  def up, do: Elzoo.DurableLog.Postgres.Migration.up()
end

defmodule Elzoo.DataStream.PostgresTest do
  use ExUnit.Case, async: false
  alias Elzoo.DataStream, as: Stream
  alias Elzoo.DataStream.{Fixture, Peer, SqlRepo, SqlMigration, TestBinding}
  alias Elzoo.DurableLog.{Postgres, Store}
  alias Ecto.Adapters.SQL

  setup do
    for app <- [:req, :ecto_sql, :postgrex], do: {:ok, _} = Application.ensure_all_started(app)

    url =
      System.get_env("ELZOO_TEST_DATABASE_URL") ||
        raise "disposable ELZOO_TEST_DATABASE_URL required (never skipped)"

    expected = URI.parse(url)
    {:ok, repo} = SqlRepo.start_link(url: url, pool_size: 6, log: false)
    Process.unlink(repo)
    on_exit(fn -> if Process.alive?(repo), do: Supervisor.stop(repo) end)
    # Read-only identification first, then fail closed before schema effects.
    identity =
      SQL.query!(
        SqlRepo,
        "SELECT current_database(),current_user,inet_server_port(),current_setting('fsync'),current_setting('synchronous_commit')",
        [],
        log: false
      ).rows

    user = expected.userinfo |> String.split(":", parts: 2) |> hd()

    assert [[database, ^user, port, "on", "on"]] = identity
    assert database == String.trim_leading(expected.path, "/")
    assert port in 1..65_535

    prefix = "stream_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    SQL.query!(SqlRepo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [], log: false)
    :ok = Ecto.Migrator.up(SqlRepo, 1, SqlMigration, prefix: prefix, log: false)
    {:ok, mode} = Agent.start_link(fn -> :normal end)
    parent = self()

    dispatch = fn op, req, run ->
      m = Agent.get(mode, & &1)
      result = run.()

      cond do
        m == :lost_dispatch_checkpoint and op == :put_checkpoint and req.target == 2 ->
          {:error, :lost_reply}

        m == :lost_settlement and op == :append and req.target == 3 ->
          {:error, :lost_reply}

        m == :block_dispatch_checkpoint and op == :put_checkpoint and req.target == 2 ->
          send(parent, {:blocked_sql, self()})

          receive do
            :release -> result
          end

        true ->
          result
      end
    end

    store =
      Postgres.store(SqlRepo,
        prefix: prefix,
        fold: Elzoo.EffectIntent.fold(TestBinding),
        limits: Elzoo.EffectIntent.limits(),
        test_dispatch: dispatch
      )

    host_store =
      Postgres.store(SqlRepo,
        prefix: prefix,
        fold: Elzoo.EffectIntent.StoreHost.fold(),
        limits: Elzoo.EffectIntent.StoreHost.limits()
      )

    host =
      {Elzoo.EffectIntent.StoreHost,
       %{store: host_store, authorize: fn _, g -> if g == 0, do: :fresh, else: {:recovered, g} end}}

    settings = [
      tenant: "tenant-test",
      binding: TestBinding,
      store: store,
      host: host,
      credentials: fn -> {:ok, "test-key"} end,
      models: ["claude-sonnet-5"],
      total_timeout_ms: 3_000,
      receive_timeout_ms: 1_000,
      ack_timeout_ms: 500
    ]

    on_exit(fn ->
      SQL.query!(SqlRepo, "DROP SCHEMA #{Postgres.identifier(prefix)} CASCADE", [], log: false)
    end)

    %{settings: settings, mode: mode, store: store}
  end

  test "durable completed stream is fenced after local forgetting and recovered activation", c do
    peer = Peer.start(self(), fn mod, s -> Peer.response(mod, s, Fixture.complete()) end)
    {:ok, owner} = Stream.__start_loopback__(c.settings, peer.origin)
    effect = Fixture.effect()
    sink = &Fixture.ack/1
    {:ok, h} = Stream.start(owner, effect, sink)
    t = Fixture.terminal(h)
    assert t.delivery_complete and t.intent_confirmation == :confirmed
    assert_receive {:stream_request, _, _, _, _}, 2_000
    stream = Elzoo.EffectIntent.Model.stream(t.correlation.intent_key)
    assert {:ok, %{revision: 3}} = Store.read(c.store, :head, [stream])
    assert {:ok, :closed} = Stream.close(owner, h)
    {:ok, h2} = Stream.start(owner, effect, sink)
    t2 = Fixture.terminal(h2)
    assert t2.reason == :intent_unavailable and t2.intent_confirmation == :unconfirmed
    assert t2.correlation.attempt_id == t.correlation.attempt_id
    refute_receive {:stream_request, _, _, _, _}, 20
    GenServer.stop(owner)
  end

  test "lost dispatched checkpoint acknowledgement never launches HTTP; recovery cannot resend",
       c do
    Agent.update(c.mode, fn _ -> :lost_dispatch_checkpoint end)
    peer = Peer.start(self(), fn mod, s -> Peer.response(mod, s, Fixture.complete()) end)
    {:ok, owner} = Stream.__start_loopback__(c.settings, peer.origin)
    effect = Fixture.effect()
    sink = &Fixture.ack/1
    {:ok, h} = Stream.start(owner, effect, sink)
    t = Fixture.terminal(h)
    assert t.reason == :intent_unavailable
    assert t.intent_confirmation == :unconfirmed
    stream = Elzoo.EffectIntent.Model.stream(t.correlation.intent_key)
    assert {:ok, %{sequence: 2}} = Store.read(c.store, :latest_checkpoint, [stream, 1])
    assert {:ok, :closed} = Stream.close(owner, h)
    Agent.update(c.mode, fn _ -> :normal end)
    {:ok, h2} = Stream.start(owner, effect, sink)
    assert Fixture.terminal(h2).reason == :intent_unavailable
    refute_receive {:stream_request, _, _, _, _}, 20
    GenServer.stop(owner)
  end

  test "local complete survives indeterminate settlement with provider usage unaltered", c do
    Agent.update(c.mode, fn _ -> :lost_settlement end)
    peer = Peer.start(self(), fn mod, s -> Peer.response(mod, s, Fixture.complete()) end)
    {:ok, owner} = Stream.__start_loopback__(c.settings, peer.origin)
    {:ok, h} = Stream.start(owner, Fixture.effect(), &Fixture.ack/1)
    t = Fixture.terminal(h)
    assert t.delivery_complete and t.source_complete and t.intent_confirmation == :unconfirmed
    assert {:provider_reported, u} = t.incurred_usage
    assert Elzoo.AiModel.Usage.amount(u, :output_tokens) == 5
    GenServer.stop(owner)
  end

  test "blocked acknowledged-write path spends D, cleanup keeps accepted SQL writes unknown", c do
    Agent.update(c.mode, fn _ -> :block_dispatch_checkpoint end)
    peer = Peer.start(self(), fn mod, s -> Peer.response(mod, s, Fixture.complete()) end)

    settings =
      Keyword.merge(c.settings, total_timeout_ms: 150, receive_timeout_ms: 100, ack_timeout_ms: 100)

    {:ok, owner} = Stream.__start_loopback__(settings, peer.origin)
    {:ok, h} = Stream.start(owner, Fixture.effect(), &Fixture.ack/1)
    assert_receive {:blocked_sql, worker}, 1_000
    t = Fixture.terminal(h)
    assert t.reason == :timeout
    refute Process.alive?(worker)
    refute_receive {:stream_request, _, _, _, _}, 0
    GenServer.stop(owner)
  end
end
