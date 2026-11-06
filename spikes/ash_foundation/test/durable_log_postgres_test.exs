# SPDX-License-Identifier: Apache-2.0
Code.require_file("support/durable_log_comparison.exs", __DIR__)

defmodule ElzooAshSpike.DurableLogPostgresTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL
  alias Elzoo.DurableLog.{Conformance, Postgres, PostgresHarness, TestMigration}
  alias ElzooAshSpike.{LogRepo, LogStore}
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

  setup do
    {:ok, repo} = LogRepo.start_link(url: @url, pool_size: 20, log: false)
    Process.unlink(repo)
    {:ok, controller} = PostgresHarness.start_link([])
    Process.unlink(controller)
    prefix = "elzoo_ash_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    on_exit(fn ->
      try do
        PostgresHarness.cleanup(controller)

        SQL.query!(LogRepo, "DROP SCHEMA IF EXISTS #{Postgres.identifier(prefix)} CASCADE", [],
          log: false
        )
      after
        Agent.stop(controller)
        Supervisor.stop(repo)
      end
    end)

    PostgresHarness.reachable!(LogRepo)
    SQL.query!(LogRepo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [], log: false)
    :ok = Ecto.Migrator.up(LogRepo, 1, TestMigration, prefix: prefix, log: false)
    {Postgres, opts} = PostgresHarness.attach(LogRepo, prefix, fold(), @limits, controller)
    %{store: {LogStore, opts}}
  end

  for {id, name} <- [
        {1, :append_readback},
        {2, :cas_exclusivity},
        {3, :stale_conflict_replaces_nothing},
        {4, :duplicate_insert_refused},
        {5, :atomic_head_record_outbox},
        {8, :ack_cas}
      ] do
    test "AshPostgres K#{id} #{name}", %{store: store} do
      opts = %{
        fold: fold(),
        limits: @limits,
        record: {"added", 1, "event"},
        destination: "sink",
        encode: &Integer.to_string/1,
        hook: &LogStore.hook/3
      }

      result = Keyword.fetch!(Conformance.checks(), unquote(name)).(fn -> {store, opts} end)
      IO.puts("AshPostgres K#{unquote(id)} #{unquote(name)}: #{inspect(result)}")
      assert result == :ok
    end
  end

  test "revision CAS refuses a stale Ash resource even without a record insert", %{
    store: {LogStore, opts}
  } do
    alias ElzooAshSpike.LogHead

    head =
      LogHead
      |> Ash.Changeset.for_create(:create, %{stream: "cas-only", revision: 0},
        tenant: opts.prefix
      )
      |> Ash.create!()

    advance = fn target ->
      head
      |> Ash.Changeset.for_update(:advance, %{target: target}, tenant: opts.prefix)
      |> Ash.update()
    end

    assert {:ok, %{revision: 2}} = advance.(2)
    assert {:error, _} = advance.(3)
    assert %{revision: 2} = Ash.get!(LogHead, "cas-only", tenant: opts.prefix)
  end
end
