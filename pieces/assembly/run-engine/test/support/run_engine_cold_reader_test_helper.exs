# SPDX-License-Identifier: Apache-2.0
# Launched as its own OS process, with no writer VM atom table or live owners.
Code.require_file("run_engine_test_helper.exs", __DIR__)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
ExUnit.start(autorun: false)

defmodule Elzoo.RunEngineColdReader do
  use ExUnit.Case
  import Elzoo.RunEngine.TestHelper
  alias Elzoo.{DurableLog, DynamicUnits, RunEngine}

  test "recover the writer's original PostgreSQL streams" do
    Process.flag(:trap_exit, true)
    repo = database()
    on_exit(fn -> Supervisor.stop(repo) end)
    start_supervised!({Registry, keys: :unique, name: Elzoo.RunEngine.TestRegistry}, id: :engine)
    start_supervised!({Registry, keys: :unique, name: Elzoo.RunEngine.UnitRegistry}, id: :unit)

    [prefix, encoded_options, expected] = System.argv()
    Code.ensure_loaded!(RunEngine)
    options = :erlang.binary_to_term(Base.decode64!(encoded_options), [:safe])
    parent = self()

    # Audit before the Unit replays anything. Record a bad payload but still let
    # the Unit return its own recovery error, independently of the audit.
    audit = fn store, identity ->
      {:ok, rows, %{revision: n}} = DurableLog.read(store, identity, 1, 1_000)

      decoded =
        Enum.count(rows, fn row ->
          try do
            :erlang.binary_to_term(row.payload, [:safe])
            true
          rescue
            ArgumentError -> false
          end
        end)

      send(parent, {:audit, rows, n, decoded})
    end

    c = fixture(options, prefix: prefix, audit: audit)
    if options[:expiry_reports], do: Agent.update(c.clock, fn _ -> 40_000 end)

    opts =
      Keyword.put(c.opts, :result_reader, %{
        evidence_store: c.evidence_store,
        retention_count: 1_024
      })

    assert_raise ArgumentError, fn -> String.to_existing_atom("decided_unix_ms") end
    assert {:ok, engine} = RunEngine.start_link(opts)
    assert_received {:audit, rows, n, decoded}
    assert n > 0 and length(rows) == n and decoded == n

    scope = %{run_id: "run", tenant: "tenant", principal: "principal"}
    limits = %{max_records: 65_536, max_bytes: 536_870_912}

    actual =
      {RunEngine.status(engine), RunEngine.transcript(engine, scope, limits),
       RunEngine.result(engine, scope, limits)}

    assert actual == :erlang.binary_to_term(Base.decode64!(expected), [:safe])

    changed =
      cond do
        opts[:messages] -> Keyword.delete(opts, :messages)
        opts[:expiry_reports] -> Keyword.delete(opts, :expiry_reports)
        true -> Keyword.put(opts, :expiry_reports, :owner)
      end

    GenServer.stop(engine)
    assert :ok = DynamicUnits.stop(c.directory, opts[:identity])
    assert {:ok, ^rows, _} = DurableLog.read(c.store, opts[:identity], 1, 1_000)
    assert {:error, :incompatible_recovery} = RunEngine.start_link(changed)

    if opts[:messages] do
      assert {:ok, engine} = RunEngine.start_link(opts)
      cancel = %{"type" => "input", "version" => 2, "kind" => "cancel", "attempt_id" => "attempt"}
      assert {:ok, _} = RunEngine.input(engine, "cancel-after-recovery", cancel, verified())
      assert {:ok, %{phase: :terminal, outcome: :cancelled}} = RunEngine.status(engine)
      GenServer.stop(engine)
    end
  end
end

%{total: 1, failures: 0} = ExUnit.run()
