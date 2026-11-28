# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)

defmodule Elzoo.RunEngineColdRecoveryTest do
  use ExUnit.Case, async: false
  import Elzoo.RunEngine.TestHelper
  alias Elzoo.{DurableLog, DynamicUnits, RunEngine}
  alias Elzoo.RunEngine.TestPattern

  setup_all do
    repo = database()
    start_supervised!({Registry, keys: :unique, name: Elzoo.RunEngine.TestRegistry}, id: :engine)
    start_supervised!({Registry, keys: :unique, name: Elzoo.RunEngine.UnitRegistry}, id: :unit)
    on_exit(fn -> Supervisor.stop(repo) end)
    :ok
  end

  test "completed default v1 retains its work result on a fresh VM" do
    requests = [
      request([action("work")]),
      request([finish_action("finish", %{"action_id" => "work"})])
    ]

    {c, engine} = writer(requests, [])
    assert {:ok, :applied} = send_input(engine)
    wait_for(engine, &(&1.outcome == :completed))
    # Captured again at ELZ-430: the recorded state with the completion pending carries
    # its mark (the control key stop_attempt, {Attempt, stop}); with that key removed the
    # rows give the capture before it.
    recover(c, engine, "3173e9095523c8a01eb8f577cb22a96670fb9c407afabe519c5973542d552e53")
  end

  test "paused explicit v1 retains an owner expiry on a fresh VM" do
    {c, engine} =
      writer([request([action("ask", "ask_person")])], protocol_version: 1, expiry_reports: :owner)

    assert {:ok, :applied} = send_input(engine)
    Agent.update(c.clock, fn _ -> 40_000 end)
    assert {:ok, _} = RunEngine.input(engine, "expiry", wake(), verified())
    assert view(engine).slots[{1, 0}].outcome == "expired"

    assert {:ok, :applied} =
             RunEngine.control(engine, "pause", %{kind: :pause, pause_deadline: 50_000}, verified())

    assert view(engine).phase == :paused
    recover(c, engine, "7dfe5dbd87effd6db0fb1c8705e3420c69fac50af2a232e1727254b17bab05c9")
  end

  test "open v2 with an active-wait message advances on a fresh VM" do
    requests = [
      request_v2([action("wait", "wait_event")]),
      request_v2([action("ask", "ask_person")])
    ]

    {c, engine} = writer(requests, protocol_version: 2, messages: :while_active)
    assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())
    message = %{start_input_v2() | "kind" => "message", "payload" => %{"text" => "hello"}}
    assert {:ok, :applied} = RunEngine.input(engine, "message", message, verified())
    assert view(engine).request_count == 2
    recover(c, engine, "1d3715bc33fe086e0b4583c9f7e06687d5e21c5656cfc31f03b09fe54b1cc555")
  end

  defp writer(requests, options) do
    c =
      fixture(
        [identity: "frozen-run-engine", pattern: {TestPattern, :step, %{requests: requests}}] ++
          options
      )

    {c, start(c, result_reader: %{evidence_store: c.evidence_store, retention_count: 1_024})}
  end

  defp recover(c, engine, frozen_hash) do
    scope = %{run_id: "run", tenant: "tenant", principal: "principal"}
    limits = %{max_records: 65_536, max_bytes: 536_870_912}
    assert {:ok, _} = status = RunEngine.status(engine)
    assert {:ok, _} = transcript = RunEngine.transcript(engine, scope, limits)
    result = RunEngine.result(engine, scope, limits)

    if c.opts[:protocol_version] == nil do
      assert {:ok, %{payload: %{"value" => 7}}} = result
    else
      assert {:pending, :not_completed} = result
    end

    # From the three frozen captures, before the extra input. The log Writer
    # independently chooses a random nonce on every append; its digest covers it.
    records =
      Enum.flat_map([{c.store, c.opts[:identity]}, {c.evidence_store, "evidence"}], fn {store,
                                                                                        stream} ->
        assert {:ok, rows, %{revision: n}} = DurableLog.read(store, stream, 1, 1_000)
        assert length(rows) == n
        for r <- rows, do: {r.stream, r.sequence, r.kind, r.schema_version, r.payload}
      end)

    assert Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(records, [:deterministic])),
             case: :lower
           ) == frozen_hash

    GenServer.stop(engine)
    assert :ok = DynamicUnits.stop(c.directory, c.opts[:identity])
    GenServer.stop(c.run)
    GenServer.stop(c.evidence)

    options =
      Keyword.take(c.opts, [:identity, :pattern, :protocol_version, :messages, :expiry_reports])

    encode = fn term -> Base.encode64(:erlang.term_to_binary(term)) end
    script = Path.expand("../support/run_engine_cold_reader_test_helper.exs", __DIR__)

    # The copied consumer gets its dependency paths from its launcher, not Mix.
    # Each -pa prepends, so pass them last-to-first to keep the writer's lookup order.
    paths = Enum.flat_map(Enum.reverse(:code.get_path()), &["-pa", List.to_string(&1)])

    args =
      paths ++ [script, c.prefix, encode.(options), encode.({status, transcript, result})]

    {output, exit_code} =
      System.cmd(System.find_executable("elixir"), args,
        stderr_to_stdout: true,
        env: [{"ERL_FLAGS", "+S 2:2"}]
      )

    assert exit_code == 0, output
  end
end
