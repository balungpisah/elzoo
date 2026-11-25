# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)

defmodule Elzoo.RunEngineFrozenRowsTest do
  use ExUnit.Case, async: false
  import Elzoo.RunEngine.TestHelper
  alias Elzoo.{RunApprovalRelease, RunEngine}
  alias Elzoo.DurableLog.Postgres
  alias Elzoo.RunEngine.TestPattern

  @scope %{run_id: "run", tenant: "tenant", principal: "principal"}
  @limits %{max_records: 65_536, max_bytes: 536_870_912}

  setup_all do
    repo = database()
    start_supervised!({Registry, keys: :unique, name: Elzoo.RunEngine.TestRegistry}, id: :engine)
    start_supervised!({Registry, keys: :unique, name: Elzoo.RunEngine.UnitRegistry}, id: :unit)
    on_exit(fn -> Supervisor.stop(repo) end)
    :ok
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "completed default v1 retains the first local-work result" do
    data =
      frozen("completed-v1", "8a12f02649305017c444e47e9d21a83051d41f249b95141f9e4cf47683820466")

    requests = [
      request([action("work")]),
      request([finish_action("finish", %{"action_id" => "work"})])
    ]

    opts = preload(data, requests, [])
    assert {:error, :incompatible_recovery} = RunEngine.start_link(opts ++ [expiry_reports: :owner])
    assert {:ok, %{payload: %{"value" => 7}}} = data.result
    recover(opts, data)
  end

  test "paused v1 retains the owner expiry" do
    data =
      frozen("paused-v1-owner", "210297b4cf59da6800bfce880b4d6b300c11ae7d3c578d1c1c672ca4a5f79f54")

    opts =
      preload(data, [request([action("ask", "ask_person")])],
        protocol_version: 1,
        expiry_reports: :owner
      )

    assert {:error, :incompatible_recovery} =
             RunEngine.start_link(Keyword.delete(opts, :expiry_reports))

    assert {:ok, %{phase: :paused, slots: %{{1, 0} => %{outcome: "expired"}}}} = data.status
    assert {:pending, :not_completed} = data.result
    recover(opts, data)
  end

  test "open v2 retains the active message and event wait, then accepts cancellation" do
    data =
      frozen("open-v2-messages", "8d81ee743827de107b2dccffb3dcf38779af317240ecd7a0deeaee5b497a1c21")

    requests = [
      request_v2([action("wait", "wait_event")]),
      request_v2([action("ask", "ask_person")])
    ]

    opts = preload(data, requests, protocol_version: 2, messages: :while_active)
    assert {:error, :incompatible_recovery} = RunEngine.start_link(Keyword.delete(opts, :messages))
    assert {:ok, %{request_count: 2, slots: %{{1, 0} => %{kind: "wait_event"}}}} = data.status
    assert {:pending, :not_completed} = data.result
    engine = recover(opts, data)
    cancel = %{"type" => "input", "version" => 2, "kind" => "cancel", "attempt_id" => "attempt"}
    assert {:ok, _} = RunEngine.input(engine, "cancel-after-recovery", cancel, verified())
    assert {:ok, %{phase: :terminal, outcome: :cancelled}} = RunEngine.status(engine)
  end

  # Captured from the frozen engine on PostgreSQL. Add new captures; do not regenerate these.
  defp frozen(name, sha256) do
    bytes = File.read!(Path.join(__DIR__, "../fixtures/run-engine/#{name}.etf"))
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == sha256
    :erlang.binary_to_term(bytes)
  end

  defp preload(data, requests, options) do
    c =
      fixture(
        [identity: "frozen-run-engine", pattern: {TestPattern, :step, %{requests: requests}}] ++
          options
      )

    for {store, rows} <- [{c.store, data.rows}, {c.evidence_store, data.evidence}], row <- rows do
      seq = row.sequence
      assert {:committed, ^seq} = Postgres.append(store, row.stream, seq - 1, [row], [])
    end

    # fixture/1 created the Run and began its Attempt. Only the completed cut needs another owner command.
    if data.evidence != [] do
      {:ok, %{evidence_ref: ref}} = data.result
      {:ok, owner} = RunApprovalRelease.status(c.run, "run")

      assert {:ok, _, _} =
               RunApprovalRelease.command(c.run, %{
                 kind: :complete,
                 run_id: "run",
                 attempt_id: "attempt",
                 outcome: :completed,
                 reason: "engine",
                 evidence_ref: ref,
                 expected_revision: owner.revision
               })
    end

    opts = Keyword.put(c.opts, :result_reader, %{evidence_store: c.evidence_store, retention_count: 1_024})
    {:ok, from_store, _} = Elzoo.DurableLog.read(c.store, opts[:identity], 1, 1_000)
    assert from_store == data.rows
    assert {:ok, owner} = RunApprovalRelease.status(c.run, "run")
    IO.inspect(Map.take(owner, [:revision, :operation_id, :current_attempt, :outcome, :evidence_ref]), label: "owner")
    assert {:ok, engine} = RunEngine.start_link(opts)
    GenServer.stop(engine)
    opts
  end

  defp recover(opts, data) do
    engine =
      start_supervised!(%{
        id: RunEngine,
        start: {RunEngine, :start_link, [opts]},
        restart: :temporary
      })

    assert RunEngine.status(engine) == data.status
    assert {:ok, _} = transcript = RunEngine.transcript(engine, @scope, @limits)
    assert transcript == data.transcript
    assert RunEngine.result(engine, @scope, @limits) == data.result
    engine
  end
end
