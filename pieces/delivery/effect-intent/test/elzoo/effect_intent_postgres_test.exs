# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/effect_intent_test_helper.exs", __DIR__)

sql_helper = Path.expand("../support/durable_log_postgres_test_helper.exs", __DIR__)

sql_helper =
  if File.regular?(sql_helper),
    do: sql_helper,
    else:
      Path.expand(
        "../../../../integration/sql/test/support/durable_log_postgres_test_helper.exs",
        __DIR__
      )

Code.require_file(sql_helper)

defmodule Elzoo.EffectIntent.SqlTestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.EffectIntent.PostgresTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.{Binding, Model, StoreHost, TestBinding, SqlTestRepo}
  alias Elzoo.DurableLog.{Postgres, PostgresHarness, TestMigration, Store}

  setup do
    url = PostgresHarness.database_url!()
    {:ok, repo} = SqlTestRepo.start_link(url: url, pool_size: 10, log: false)
    Process.unlink(repo)
    PostgresHarness.reachable!(SqlTestRepo)
    prefix = "intent_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    SQL.query!(SqlTestRepo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [], log: false)
    :ok = Ecto.Migrator.up(SqlTestRepo, 1, TestMigration, prefix: prefix, log: false)
    {:ok, controller} = PostgresHarness.start_link([])
    Process.unlink(controller)
    {:ok, b} = Binding.load(TestBinding)
    store = PostgresHarness.attach(SqlTestRepo, prefix, Model.fold(b), Model.limits(), controller)

    host_store =
      Postgres.store(SqlTestRepo,
        prefix: prefix,
        fold: StoreHost.fold(),
        limits: StoreHost.limits()
      )

    authority = start_supervised!({Agent, fn -> :fresh end})
    supervisor = start_supervised!({Task.Supervisor, []})

    host = %{
      store: host_store,
      authorize: fn _, generation ->
        case Agent.get(authority, & &1) do
          :fresh -> :fresh
          :recover -> {:recovered, generation}
        end
      end
    }

    context = %{
      parent: self(),
      send: fn _ -> {:error, :timeout, "timeout"} end,
      poll: fn _ -> {:unknown_to_provider, "trusted"} end
    }

    opts = [
      binding: TestBinding,
      identity: ["tenant", "account", "test", "refund", "sql-request"],
      arguments: "args",
      deadline: 5000,
      clock: fn -> 100 end,
      store: store,
      host: {StoreHost, host},
      adapter_context: context,
      task_supervisor: supervisor
    ]

    on_exit(fn ->
      try do
        PostgresHarness.cleanup(controller)

        SQL.query!(SqlTestRepo, "DROP SCHEMA #{Postgres.identifier(prefix)} CASCADE", [],
          log: false
        )
      after
        if Process.alive?(controller), do: Agent.stop(controller)
        if Process.alive?(repo), do: Supervisor.stop(repo)
      end
    end)

    %{store: store, host: host, authority: authority, opts: opts, context: context}
  end

  defp owner(opts), do: start_supervised!(Supervisor.child_spec({Intent, opts}, id: make_ref()))
  defp eventually(fun, n \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (receive do
         after
           10 -> eventually(fun, n - 1)
         end)
  end

  test "real SQL append/checkpoint/recovery and explicit replay-safe rearm", c do
    pid = owner(c.opts)
    assert Intent.status(pid).active
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, req}
    eventually(fn -> Intent.status(pid).revision == 3 end)
    key = req.key
    assert {:ok, %{sequence: 2}} = Store.read(c.store, :latest_checkpoint, [Model.stream(key), 1])
    GenServer.stop(pid)
    recovered = owner(c.opts)
    refute Intent.status(recovered).active
    GenServer.stop(recovered)
    Agent.update(c.authority, fn _ -> :recover end)
    activated = owner(c.opts)
    assert {:ok, :polling} = Intent.advance(activated, :poll)
    assert_receive {:physical_poll, _, _}
    eventually(fn -> Intent.status(activated).phase == {:Definite, :ProviderReplaySafe, 1} end)
    assert {:ok, :Stop} = Intent.advance(activated, :rearm)
    assert {:ok, :dispatched} = Intent.advance(activated, :dispatch)
    assert_receive {:physical_send, _, req2}
    assert req2.key == req.key
    refute req2.attempt_id == req.attempt_id
    assert Intent.status(activated).flags.replay_dependent
  end

  test "real SQL indeterminate checkpoint commit never authorizes a local send", c do
    pid = owner(c.opts)
    :ok = PostgresHarness.hook(c.store, :inject, [:put_checkpoint, {:pause, :checkpoint}])
    assert {:error, {:checkpoint, {:indeterminate, _}}} = Intent.advance(pid, :dispatch)
    refute_receive {:physical_send, _, _}, 20
    refute Intent.status(pid).active
    assert {:committed, 2} = PostgresHarness.hook(c.store, :release, [:checkpoint])
    assert {:error, :read_only} = Intent.advance(pid, :dispatch)
    GenServer.stop(pid)
    recovered = owner(c.opts)
    assert Intent.status(recovered).phase == {:Dispatched, :Fresh, 1}
    refute Intent.status(recovered).active
  end

  test "real SQL uncertain contradictory completion halts and survives late commit/restart", c do
    context = %{c.context | send: fn _ -> {:error, :no_send, "no bytes"} end}
    opts = Keyword.put(c.opts, :adapter_context, context)
    pid = owner(opts)
    assert {:ok, :dispatched} = Intent.advance(pid, :dispatch)
    assert_receive {:physical_send, _, req}
    eventually(fn -> Intent.status(pid).phase == {:Definite, :AdapterNoSend, 1} end)
    :ok = PostgresHarness.hook(c.store, :inject, [:append, {:pause, :contradiction}])

    completion = %{
      "version" => 1,
      "message_id" => req.key,
      "correlation_id" => req.key,
      "attempt_id" => req.attempt_id,
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => %{"digest" => req.arguments_digest},
      "value_schema_id" => "completion",
      "value_schema_version" => 1
    }

    assert {:not_retained, {:write, {:indeterminate, _}}} = Intent.observe(pid, completion)
    refute Intent.status(pid).active
    assert {:committed, 4} = PostgresHarness.hook(c.store, :release, [:contradiction])
    GenServer.stop(pid)
    Agent.update(c.authority, fn _ -> :recover end)
    recovered = owner(opts)
    assert Intent.status(recovered).flags.quarantined
    assert {:error, :not_rearmable} = Intent.advance(recovered, :rearm)
    refute_receive {:physical_send, _, _}, 20
  end

  test "real SQL host CAS admits only one competing fresh activation", c do
    key = Model.key(c.opts[:identity])
    base = %{key: key, revision: 0, digest: Model.hash(Model.binary({:empty_intent, 1, key}))}

    results =
      1..2
      |> Task.async_stream(
        fn _ ->
          StoreHost.activate(c.host, Map.put(base, :nonce, :crypto.strong_rand_bytes(16)))
        end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &match?({:active, 1, _}, &1)) == 1
    assert Enum.count(results, &match?({:read_only, _}, &1)) == 1
    assert {:ok, %{revision: 1}} = Store.read(c.host.store, :head, [StoreHost.stream(key)])
  end
end
