# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)

defmodule Elzoo.RunEngineMessagesTest do
  use ExUnit.Case, async: false
  import Elzoo.RunEngine.TestHelper
  alias Elzoo.{DurableUnit, DynamicUnits, RunEngine}
  alias Elzoo.RunEngine.TestPattern

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  setup_all do
    pid = database()
    {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.TestRegistry)
    {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.UnitRegistry)
    for p <- [registry, units], do: Process.unlink(p)
    on_exit(fn -> for p <- [registry, units, pid], Process.alive?(p), do: Supervisor.stop(p) end)
    :ok
  end

  describe "default_off_is_unchanged" do
    test "without the option a message while a tool slot runs is applied and not given" do
      %{c: c, engine: engine, provider: provider} = tool_running([])
      before = unit_state(c)
      assert {:ok, :applied} = RunEngine.input(engine, "m1", message(), verified())
      assert inputs_of(pattern_inputs(), "root") == []
      after_message = unit_state(c)
      refute Map.has_key?(after_message.control.invocations, "m1")
      assert after_message.slots == before.slots
      assert after_message.control.lifecycle == before.control.lifecycle

      {:ok, %{entries: entries}} = RunEngine.transcript(engine, scope(), limits())
      assert [%{kind: "message"}] = for(e <- entries, e.type == :input, e.input_id == "m1", do: e)

      tool_outcome(engine, provider)

      assert [%{"kind" => "action_outcome", "action_id" => "t"}] =
               inputs_of(pattern_inputs(), "root")
    end

    test "the configure record differs only by the option, and a changed option is no recovery" do
      {c0, bindings0} = messages_setup([:wait])
      engine0 = start(c0, bindings: bindings0)
      [{_, %{kind: :configure, control: without}} | _] = unit_inputs(c0)
      refute Map.has_key?(without, :messages)

      GenServer.stop(engine0)

      assert {:error, :incompatible_recovery} =
               start_link(c0, bindings: bindings0, messages: :while_active)

      assert :ok = DynamicUnits.stop(c0.directory, identity(c0))

      {c1, bindings1} = messages_setup([:wait])
      engine1 = start(c1, bindings: bindings1, messages: :while_active)
      [{_, %{kind: :configure, control: with_option}} | _] = unit_inputs(c1)
      assert with_option.messages == :while_active
      assert with_option.fingerprint == wrap(without.fingerprint)

      assert Map.drop(with_option, [:messages, :fingerprint]) ==
               Map.delete(without, :fingerprint)

      GenServer.stop(engine1)
      assert {:error, :incompatible_recovery} = start_link(c1, bindings: bindings1)
    end

    test "with expiry_reports the messages wrap is the outer one" do
      {c0, bindings0} = messages_setup([:wait])
      _ = start(c0, bindings: bindings0, expiry_reports: :owner)
      [{_, %{kind: :configure, control: reports_only}} | _] = unit_inputs(c0)

      {c1, bindings1} = messages_setup([:wait])
      _ = start(c1, bindings: bindings1, expiry_reports: :owner, messages: :while_active)
      [{_, %{kind: :configure, control: both}} | _] = unit_inputs(c1)
      assert both.fingerprint == wrap(reports_only.fingerprint)
      assert {both.expiry_reports, both.messages} == {:owner, :while_active}

      assert Map.delete(both, :messages) |> Map.delete(:fingerprint) ==
               Map.delete(reports_only, :fingerprint)
    end

    test "any other value or a second key is refused before a Unit starts" do
      {c, bindings} = messages_setup([:wait])

      for options <- [
            [messages: :idle],
            [messages: true],
            [messages: nil],
            [messages: :while_active, messages: :while_active]
          ] do
        assert {:error, :invalid_options_or_recovery} =
                 RunEngine.start_link(c.opts ++ [bindings: bindings] ++ options)

        assert DynamicUnits.find(c.directory, identity(c)) == :not_found
      end

      _engine = start(c, bindings: bindings, protocol_version: 1, messages: :while_active)
      assert unit_state(c).control.messages == :while_active

      {c2, bindings2} = messages_setup([:wait], %{}, protocol_version: 2)
      _engine = start(c2, bindings: bindings2, protocol_version: 2, messages: :while_active)
      assert unit_state(c2).control.messages == :while_active
      assert unit_state(c2).control.protocol_version == 2
    end

    test "a new Run configured on the Unit takes the option of its own start" do
      {c, bindings} = messages_setup([request([action("ask", "ask_person")]), :wait])
      engine = start(c, bindings: bindings, messages: :while_active)
      assert {:ok, :applied} = send_input(engine)
      cancel = %{"type" => "input", "version" => 1, "kind" => "cancel", "attempt_id" => "attempt"}
      assert {:ok, _} = RunEngine.input(engine, "end", cancel, verified())
      assert wait_for(engine, &(&1.phase == :terminal)).outcome == :cancelled
      GenServer.stop(engine)
      new_run(c)
      engine = start(c, bindings: bindings, run_id: "period-two", run_deadline: 120_000)
      assert view(engine).run_id == "period-two"
      refute Map.has_key?(unit_state(c).control, :messages)
    end
  end

  describe "message_reaches_root_while_active" do
    test "a message while a tool slot runs is given to the root and settles nothing" do
      %{c: c, engine: engine, provider: provider} = tool_running(messages: :while_active)
      before = unit_state(c)
      assert before.control.lifecycle.phase == :waiting
      assert {:ok, :applied} = RunEngine.input(engine, "m1", message(), verified())

      committed = committed_input(c, "m1")
      assert committed["kind"] == "message" and committed["at_ms"] == 2_000
      assert inputs_of(pattern_inputs(), "root") == [committed]

      state = unit_state(c)
      assert state.slots == before.slots
      assert state.control.count == before.control.count
      assert state.control.receipts == before.control.receipts
      assert state.control.budgets == before.control.budgets
      assert state.control.trackers == before.control.trackers
      assert state.control.lifecycle.waits == before.control.lifecycle.waits
      assert state.control.lifecycle.phase == :waiting
      assert state.control.classification == :remain_waiting
      assert Map.has_key?(state.control.invocations, "m1")

      tool_outcome(engine, provider)

      assert [%{"kind" => "action_outcome", "action_id" => "t", "outcome" => "completed"}] =
               inputs_of(pattern_inputs(), "root")

      {:ok, %{entries: entries}} = RunEngine.transcript(engine, scope(), limits())
      m1 = Enum.find(entries, &(&1.type == :input and &1.input_id == "m1"))
      assert m1.kind == "message"
      assert [%{type: :input}] = for(e <- entries, e.sequence == m1.sequence, do: e)

      [settlement] = for e <- entries, e.type == :settlement, e.occurrence == {1, 0}, do: e
      outcome = Enum.find(entries, &(&1.sequence == settlement.sequence and &1.type == :input))
      assert outcome.kind == "action_outcome" and settlement.sequence > m1.sequence
      assert settlement.outcome == "completed"
    end

    test "with only a running nested parent whose child opened nothing, the root is given it" do
      {c, bindings} =
        messages_setup(
          [request([action("nested", "nested_callable")]), :wait],
          %{"nested" => [:wait, :wait]}
        )

      engine = start(c, bindings: bindings, messages: :while_active)
      assert {:ok, :applied} = send_input(engine)
      wait_for(engine, &(&1.slots[{1, 0}][:phase] == :running))
      inputs = pattern_inputs()
      assert [%{"kind" => "start"}] = inputs_of(inputs, "root")
      assert [%{"kind" => "start"}] = inputs_of(inputs, "nested")
      assert view(engine).phase == :active
      assert map_size(unit_state(c).slots) == 1

      assert {:ok, :applied} = RunEngine.input(engine, "m1", message(), verified())
      inputs = pattern_inputs()
      assert inputs_of(inputs, "root") == [committed_input(c, "m1")]
      assert inputs_of(inputs, "nested") == []
      assert unit_state(c).control.classification == :permit_new_work
      assert unit_state(c).slots[{1, 0}].phase == :running
    end

    test "with only running local work, the root is given it" do
      {c, bindings} = messages_setup([request([action("lw", "local_work")]), :wait, :wait])
      engine = start(c, bindings: bindings, messages: :while_active)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:local_started, worker}, 5_000
      wait_for(engine, &(&1.slots[{1, 0}][:phase] == :running))
      assert [%{"kind" => "start"}] = inputs_of(pattern_inputs(), "root")
      assert view(engine).phase == :waiting

      assert {:ok, :applied} = RunEngine.input(engine, "m1", message(), verified())
      assert inputs_of(pattern_inputs(), "root") == [committed_input(c, "m1")]
      assert unit_state(c).control.classification == :remain_waiting
      assert unit_state(c).slots[{1, 0}].phase == :running

      send(worker, :finish)
      wait_for(engine, &(&1.slots[{1, 0}][:phase] == :settled))

      assert [%{"kind" => "action_outcome", "action_id" => "lw"}] =
               inputs_of(pattern_inputs(), "root")
    end

    test "the same ID with equal bytes is a duplicate and changed bytes are a conflict" do
      %{c: c, engine: engine} = tool_running(messages: :while_active)
      assert {:ok, :applied} = RunEngine.input(engine, "m1", message(), verified())
      assert [%{"kind" => "message"}] = inputs_of(pattern_inputs(), "root")
      records = length(unit_inputs(c))
      assert {:ok, :duplicate} = RunEngine.input(engine, "m1", message(), verified())

      assert {:error, :input_id_conflict} =
               RunEngine.input(engine, "m1", message(1, %{"text" => "other"}), verified())

      assert inputs_of(pattern_inputs(), "root") == []
      assert length(unit_inputs(c)) == records
    end

    test "under protocol v2 a message while a wait_event waits is given to the root" do
      %{c: c, engine: engine} = v2_waiting([:wait, :wait], [])
      assert {:ok, :applied} = RunEngine.input(engine, "m1", message(2), verified())
      assert inputs_of(pattern_inputs(), "root") == [committed_input(c, "m1")]
      assert committed_input(c, "m1")["version"] == 2
      [wait] = for {k, s} <- unit_state(c).slots, s.kind == "wait_event", do: k
      assert unit_state(c).slots[wait].phase != :settled

      assert {:ok, %{waits: [w]}} = RunEngine.event_waits(engine, scope(), limits())
      assert w.status != :settled
      assert {:ok, %{entries: entries}} = RunEngine.transcript(engine, scope(), limits())
      assert Enum.any?(entries, &(&1.type == :input and &1.input_id == "m1"))
    end

    test "under protocol v2 a message whose root request is the first excess leaves the readers working" do
      script = [request_v2([action("lw", "local_work")]), :wait]
      %{c: c, engine: engine} = v2_waiting(script, request_cap: 1)
      assert {:ok, _} = RunEngine.input(engine, "m1", message(2), verified())
      assert inputs_of(pattern_inputs(), "root") == [committed_input(c, "m1")]

      state = unit_state(c)
      assert state.control.receipts[2].disposition == :over_cap
      assert state.control.receipts[2].input_id == "m1"
      assert state.control.generation_closed

      assert {:ok, _} = RunEngine.event_waits(engine, scope(), limits())
      assert {:ok, %{entries: entries}} = RunEngine.transcript(engine, scope(), limits())
      assert Enum.any?(entries, &(&1.type == :input and &1.input_id == "m1"))
    end
  end

  describe "message_opens_work" do
    test "a request of the message is charged and admitted while the tool slot stays open" do
      script = [request([action("t", "tool_call")]), request([action("lw", "local_work")]), :wait]
      %{c: c, engine: engine} = tool_running([messages: :while_active], script)
      assert {:ok, :applied} = RunEngine.input(engine, "m1", message(), verified())
      assert inputs_of(pattern_inputs(), "root") == [committed_input(c, "m1")]
      assert_receive {:local_started, worker}, 5_000
      view = wait_for(engine, &(&1.slots[{2, 0}][:phase] == :running))
      assert view.slots[{1, 0}].phase == :running

      state = unit_state(c)
      assert state.control.count == 2
      assert state.control.receipts[2].input_id == "m1"
      assert state.slots[{2, 0}].action_id == "lw"
      send(worker, :finish)
    end

    test "at the cap the message's request is the first excess and the tool slot is retained" do
      script = [request([action("t", "tool_call")]), request([action("lw", "local_work")]), :wait]
      %{c: c, engine: engine} = tool_running([messages: :while_active, request_cap: 1], script)
      assert {:ok, _} = RunEngine.input(engine, "m1", message(), verified())
      assert inputs_of(pattern_inputs(), "root") == [committed_input(c, "m1")]

      state = unit_state(c)
      assert state.control.classification == :over_cap
      assert state.control.receipts[2].disposition == :over_cap
      assert state.control.receipts[2].input_id == "m1"
      assert state.control.generation_closed
      assert state.control.lifecycle.phase == :terminal
      assert state.control.lifecycle.outcome == :out_of_budget
      assert state.slots[{1, 0}].phase == :running
      refute Map.has_key?(state.slots, {2, 0})
      refute_receive {:local_started, _}, 200
    end
  end

  describe "root_only_message_only" do
    test "with a nested child's tool open, the message reaches the root only" do
      {c, bindings} =
        messages_setup(
          [request([action("C", "nested_callable")]), :wait],
          %{"C" => [request([action("t1", "tool_call")]), :wait]}
        )

      engine = start(c, bindings: bindings, messages: :while_active)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, _, _}, 5_000
      wait_for(engine, &(&1.slots[{2, 0}][:phase] == :running))
      inputs = pattern_inputs()
      assert [%{"kind" => "start"}] = inputs_of(inputs, "root")
      assert [%{"kind" => "start"}] = inputs_of(inputs, "C")
      assert unit_state(c).slots[{1, 0}].phase == :running

      assert {:ok, :applied} = RunEngine.input(engine, "m1", message(), verified())
      inputs = pattern_inputs()
      assert inputs_of(inputs, "root") == [committed_input(c, "m1")]
      assert inputs_of(inputs, "C") == []
    end

    test "a wake and a later start while a slot is active are not given and keep today's step" do
      %{c: c, engine: engine} = tool_running(messages: :while_active)
      state = unit_state(c)

      for {id, input, classification} <- [
            {"w1", wake(), :remain_waiting},
            {"s2", start_input(), :remain_waiting}
          ] do
        record = protocol_record(id, input)
        assert_same_step_without_option(state, record, classification)
      end

      assert {:ok, :applied} = RunEngine.input(engine, "w1", wake(), verified())
      assert {:ok, :applied} = RunEngine.input(engine, "s2", start_input(), verified())
      assert inputs_of(pattern_inputs(), "root") == []
      refute Map.has_key?(unit_state(c).control.invocations, "w1")
      refute Map.has_key?(unit_state(c).control.invocations, "s2")
    end

    test "a granted resource_event while a tool slot runs is not given and keeps today's step" do
      open_action =
        action("open", "resource_open", %{
          "run_id" => "run",
          "resource_name" => "document",
          "data" => %{}
        })

      script = [request([open_action]), request([action("t", "tool_call")]), :wait, :wait]
      {c, bindings} = messages_setup(script)
      {owner, bindings} = resource(%{c | opts: Keyword.put(c.opts, :bindings, bindings)})

      engine =
        start(c,
          resources: %{"document" => owner},
          bindings: bindings,
          messages: :while_active
        )

      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, opening, _}, 5_000
      identity = ["tenant", "account", "effect", "publish", "open"]

      assert {:ok, _} =
               Elzoo.RunResource.command(owner, %{
                 id: "open-evidence",
                 at_ms: 2_000,
                 body: {:observed, identity, {:completed, %{opened_at_ms: 2_000}}}
               })

      send(opening, {:result, %{}})
      assert {:ok, :applied} = RunEngine.input(engine, "consume", wake(), verified())
      assert_receive {:effect_started, _tool, _}, 5_000
      wait_for(engine, &(&1.slots[{2, 0}][:phase] == :running))
      assert view(engine).slots[{1, 0}].outcome == "completed"

      assert [%{"kind" => "start"}, %{"kind" => "action_outcome", "action_id" => "open"}] =
               inputs_of(pattern_inputs(), "root")

      state = unit_state(c)
      assert Map.has_key?(state.control.cursors, "document")

      res_input = %{
        "type" => "input",
        "version" => 1,
        "kind" => "resource_event",
        "schema_id" => "message",
        "schema_version" => 1,
        "payload" => %{"event" => "change"}
      }

      record = protocol_record("r1", res_input, correlation: %{resource: "document"})
      assert_same_step_without_option(state, record, :resource_event)
    end

    test "a message while paused is not given, not after continue either, and a new ID is" do
      %{c: c, engine: engine} = tool_running(messages: :while_active)
      assert {:ok, :applied} = pause(engine)
      assert {:ok, :applied} = RunEngine.input(engine, "m1", message(), verified())
      assert unit_state(c).control.classification == :remain_paused
      assert {:ok, :applied} = continue(engine)
      assert inputs_of(pattern_inputs(), "root") == []
      refute Map.has_key?(unit_state(c).control.invocations, "m1")

      records = length(unit_inputs(c))
      assert {:ok, :duplicate} = RunEngine.input(engine, "m1", message(), verified())
      assert inputs_of(pattern_inputs(), "root") == []
      assert length(unit_inputs(c)) == records

      assert {:ok, :applied} = RunEngine.input(engine, "m2", message(), verified())
      assert inputs_of(pattern_inputs(), "root") == [committed_input(c, "m2")]
    end
  end

  describe "root_only_message_only (refused cases)" do
    test "with the option each case that stays refused keeps today's step and gives nothing" do
      %{c: c} = ask_waiting(messages: :while_active)
      state = unit_state(c)
      assert state.control.messages == :while_active
      at = fn ms -> Map.put(message(), "at_ms", ms) end
      root = state.control.budgets["root"].state
      at_cap = put_elem(root, 5, elem(root, 2))

      paused =
        update_in(state.control.lifecycle, &%{&1 | phase: :paused, pause_deadline: 30_000})

      cases = [
        {"run deadline", state, protocol_record("m", at.(60_000)),
         {:request_outcome, :out_of_time}},
        {"pause deadline", paused, protocol_record("m", at.(30_000)),
         {:request_outcome, :out_of_time}},
        {"paused", paused, protocol_record("m", at.(20_000)), :remain_paused},
        {"terminal",
         update_in(state.control.lifecycle, &%{&1 | phase: :terminal, outcome: :cancelled}),
         protocol_record("m", at.(2_000)), :unchanged},
        {"budget at cap", put_in(state.control.budgets["root"].state, at_cap),
         protocol_record("m", at.(2_000)), {:request_outcome, :out_of_budget}},
        {"another Run", state, protocol_record("m", at.(2_000), run_id: "other"), :late},
        {"stale Attempt", state, protocol_record("m", at.(2_000), attempt_id: "older"), :late},
        {"generation closed", put_in(state.control.generation_closed, true),
         protocol_record("m", at.(2_000)), :remain_waiting},
        {"stop pending", put_in(state.control.stop_pending, :cancelled),
         protocol_record("m", at.(2_000)), :remain_waiting},
        {"root closed", put_in(state.control.callables["root"].closed, true),
         protocol_record("m", at.(2_000)), :remain_waiting}
      ]

      for {label, from, record, classification} <- cases do
        {:Transition, next, :none} = RunEngine.step(from, record)
        assert next.control.classification == classification, label
        assert_same_step_without_option(from, record, classification)
      end
    end
  end

  describe "ordering_with_reports" do
    test "a message at an ask's deadline is given before the ask's report" do
      %{c: c, engine: engine} = ask_waiting(expiry_reports: :owner, messages: :while_active)
      at(c, 40_000)
      assert {:ok, :applied} = RunEngine.input(engine, "m1", message(), verified())
      assert_received {:pattern_input, "root", first}
      assert_received {:pattern_input, "root", second}
      assert inputs_of(pattern_inputs(), "root") == []
      assert first == committed_input(c, "m1") and first["at_ms"] == 40_000
      assert second == expired("ask", {1, 0}, 40_000)
      assert resume_records(c) == [{resume_id({1, 0}), {1, 0}}]

      {:ok, %{entries: entries}} = RunEngine.transcript(engine, scope(), limits())
      m1 = Enum.find(entries, &(&1.type == :input and &1.input_id == "m1"))

      assert [%{type: :input}, %{type: :settlement} = settlement] =
               for(e <- entries, e.sequence == m1.sequence, do: e)

      assert {settlement.occurrence, settlement.by, settlement.reason, settlement.outcome} ==
               {{1, 0}, :protocol, nil, "expired"}
    end

    test "when the message's request is the first excess the held report is dropped" do
      script = [request([action("ask", "ask_person")]), request([action("lw", "local_work")])]

      %{c: c, engine: engine} =
        ask_waiting([expiry_reports: :owner, messages: :while_active, request_cap: 1], script)

      at(c, 40_000)
      assert {:ok, _} = RunEngine.input(engine, "m1", message(), verified())
      assert inputs_of(pattern_inputs(), "root") == [committed_input(c, "m1")]

      state = unit_state(c)
      assert state.control.classification == :over_cap
      assert state.control.generation_closed
      assert state.slots[{1, 0}][:pending_input] == nil
      assert resume_records(c) == []
      assert wait_for(engine, &(&1.phase == :terminal)).outcome == :out_of_budget

      {:ok, %{entries: entries}} = RunEngine.transcript(engine, scope(), limits())
      m1 = Enum.find(entries, &(&1.type == :input and &1.input_id == "m1"))
      in_m1 = for e <- entries, e.sequence == m1.sequence, do: e

      assert [%{occurrence: {1, 0}, by: :protocol, reason: nil}] =
               for(e <- in_m1, e.type == :settlement, do: e)
    end

    test "with expiry_reports alone the root is given only the report" do
      %{c: c, engine: engine} = ask_waiting(expiry_reports: :owner)
      at(c, 40_000)
      assert {:ok, _} = RunEngine.input(engine, "m1", message(), verified())
      assert inputs_of(pattern_inputs(), "root") == [expired("ask", {1, 0}, 40_000)]
      refute Map.has_key?(unit_state(c).control.invocations, "m1")
    end
  end

  describe "room_and_replay" do
    test "without room for its invocation entry the message is record_size; with room it is given" do
      %{c: c} = ask_waiting(messages: :while_active)
      state = unit_state(c)
      assert state.control.lifecycle.phase == :waiting
      record = protocol_record(String.duplicate("m", 160), message())

      padded = pad_invocations(state, 64)
      assert {:Transition, next, :none} = RunEngine.step(padded, record)
      assert_non_settling_refused(next, padded)

      {:Transition, given, :none} = RunEngine.step(state, record)
      assert Map.has_key?(given.control.invocations, record.id)
      assert given.control.callables["root"].state.script == [:wait]
      assert given.slots == state.slots

      {_switch, _ms} = non_settling_switch(state, record, [:wait], :remain_waiting)
    end

    test "two restarts after a message and an outcome give an equal state" do
      %{c: c, engine: engine, provider: provider} = tool_running(messages: :while_active)
      assert {:ok, :applied} = RunEngine.input(engine, "m1", message(), verified())
      tool_outcome(engine, provider)
      _ = pattern_inputs()
      replay_is_equal(c, engine, bindings: c.bindings, messages: :while_active)
    end

    test "two restarts after a message and its report give an equal state" do
      %{c: c, engine: engine} = ask_waiting(expiry_reports: :owner, messages: :while_active)
      at(c, 40_000)
      assert {:ok, :applied} = RunEngine.input(engine, "m1", message(), verified())
      _ = pattern_inputs()

      replay_is_equal(c, engine,
        bindings: c.bindings,
        expiry_reports: :owner,
        messages: :while_active
      )
    end
  end

  # The root runs `script` under TestPattern.waiting; the first request asks one tool
  # call "t". Returns once the tool slot runs and the root was given its start.
  defp tool_running(overrides, script \\ nil) do
    script = script || [request([action("t", "tool_call")]), :wait, :wait]
    {c, bindings} = messages_setup(script)
    engine = start(c, [bindings: bindings] ++ overrides)
    assert {:ok, :applied} = send_input(engine)
    assert_receive {:effect_started, provider, _}, 5_000
    wait_for(engine, &(&1.slots[{1, 0}][:phase] == :running))
    assert [%{"kind" => "start"}] = inputs_of(pattern_inputs(), "root")
    assert view(engine).phase == :waiting
    %{c: Map.put(c, :bindings, bindings), engine: engine, provider: provider}
  end

  # The host gives the tool slot {1, 0} its outcome (actual 1), then the provider replies.
  defp tool_outcome(engine, provider) do
    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "t-result",
               result("t"),
               verified(%{occurrence: {1, 0}, actual: 1, dispatch: "dispatched"})
             )

    send(provider, {:result, %{}})
    assert view(engine).slots[{1, 0}].phase == :settled
  end

  # The root's start asks one person "ask" (deadline 40,000).
  defp ask_waiting(overrides, script \\ nil) do
    script = script || [request([action("ask", "ask_person")]), :wait, :wait]
    {c, bindings} = messages_setup(script)
    engine = start(c, [bindings: bindings] ++ overrides)
    assert {:ok, :applied} = send_input(engine)
    wait_for(engine, &(&1.slots[{1, 0}][:phase] == :waiting))
    assert [%{"kind" => "start"}] = inputs_of(pattern_inputs(), "root")
    %{c: Map.put(c, :bindings, bindings), engine: engine}
  end

  # A native v2 root whose start asks one wait_event and then runs `rest`.
  defp v2_waiting(rest, overrides) do
    {c, bindings} =
      messages_setup([request_v2([action("wait", "wait_event")]) | rest], %{}, protocol_version: 2)

    engine =
      start(
        c,
        [bindings: bindings, protocol_version: 2, messages: :while_active] ++ overrides
      )

    assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())
    assert [%{"kind" => "start"}] = inputs_of(pattern_inputs(), "root")

    assert [_] =
             for({_, s} <- unit_state(c).slots, s.kind == "wait_event", s.phase != :settled, do: s)

    %{c: Map.put(c, :bindings, bindings), engine: engine}
  end

  # The same pure step with the option removed from control decides the same.
  defp assert_same_step_without_option(state, record, classification) do
    {:Transition, with_option, :none} = RunEngine.step(state, record)
    without = %{state | control: Map.delete(state.control, :messages)}
    {:Transition, without_option, :none} = RunEngine.step(without, record)
    assert with_option == put_in(without_option.control[:messages], :while_active)
    assert with_option.control.classification == classification
    refute Map.has_key?(with_option.control.invocations, record.id)
    assert with_option.control.callables == state.control.callables
  end

  defp new_run(c) do
    {:ok, ended} = Elzoo.RunApprovalRelease.status(c.run, "run")

    assert {:ok, revision, _} =
             Elzoo.RunApprovalRelease.command(c.run, %{
               kind: :create,
               run_id: "period-two",
               operation_id: "operation-two",
               provider_refs: %{},
               expected_revision: ended.revision
             })

    assert {:ok, _, _} =
             Elzoo.RunApprovalRelease.command(c.run, %{
               kind: :begin_attempt,
               run_id: "period-two",
               attempt_id: "third",
               expected_revision: revision
             })
  end

  defp message(version \\ 1, payload \\ %{"text" => "hello"}),
    do: %{
      "type" => "input",
      "version" => version,
      "kind" => "message",
      "schema_id" => "message",
      "schema_version" => 1,
      "payload" => payload
    }

  # The input of the committed protocol record with this ID.
  defp committed_input(c, id) do
    [input] = for {^id, %{kind: :protocol} = r} <- unit_inputs(c), do: r.input
    input
  end

  defp wrap(fingerprint),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({:messages, :while_active, fingerprint}, [
          :deterministic,
          {:minor_version, 2}
        ])
      )

  defp at(c, ms), do: Agent.update(c.clock, fn _ -> ms end)

  defp pause(engine, deadline \\ 50_000),
    do: RunEngine.control(engine, "pause", %{kind: :pause, pause_deadline: deadline}, verified())

  defp continue(engine, id \\ "continue"),
    do:
      RunEngine.control(
        engine,
        id,
        %{kind: :continue, person_id: "person", run_deadline: 60_000},
        verified(%{verified_person: "person"})
      )

  defp identity(c), do: Keyword.fetch!(c.opts, :identity)

  # Copied from run_engine_test.exs (ELZ-190 helpers).
  defp restart(c, engine, overrides) do
    GenServer.stop(engine)
    assert :ok = DynamicUnits.stop(c.directory, identity(c))
    Agent.update(c.host_mode, fn _ -> :recover end)
    start(c, overrides)
  end

  defp unit_state(c) do
    {:ok, unit} = DynamicUnits.find(c.directory, identity(c))
    DurableUnit.snapshot(unit)
  end

  # Copied from run_engine_test.exs (ELZ-234 helpers).
  defp assert_non_settling_refused(next, before) do
    assert next.control.classification == :record_size
    assert next.control.invocations == before.control.invocations
    assert next.control.callables == before.control.callables
    assert next.control.count == before.control.count
    assert next.control.receipts == before.control.receipts
    assert next.control.trackers == before.control.trackers
    assert next.slots == before.slots
    assert next.requests == before.requests
    assert control_headroom(next) >= 0
  end

  defp non_settling_switch(state, record, expected_script, expected_classification) do
    base = pad_invocations(state, 500)
    started = System.monotonic_time(:millisecond)

    results =
      for h <- 64..266 do
        padded = pad_invocations(base, h)
        {:Transition, next, :none} = RunEngine.step(padded, record)
        assert control_headroom(next) >= 0
        called? = Map.has_key?(next.control.invocations, record.id)

        if called? do
          assert next.control.callables["root"].state.script == expected_script
          assert next.control.classification == expected_classification
        else
          assert_non_settling_refused(next, padded)
        end

        {h, called?}
      end

    elapsed_ms = System.monotonic_time(:millisecond) - started
    {refused, accepted} = Enum.split_while(results, fn {_, called?} -> not called? end)
    assert refused != []
    assert accepted != []
    assert Enum.all?(accepted, fn {_, called?} -> called? end)
    [{switch_h, true} | _] = accepted
    {switch_h, elapsed_ms}
  end

  # The committed Unit inputs, in commit order: {input ID, record}.
  defp unit_inputs(c) do
    {:ok, rows, _} = Elzoo.DurableLog.read(c.store, identity(c), 1, 1_000)
    for %{kind: "input"} = row <- rows, do: elem(:erlang.binary_to_term(row.payload, [:safe]), 1)
  end

  # Every pattern input sent so far, in order: {callable name, input}.
  defp pattern_inputs(acc \\ []) do
    receive do
      {:pattern_input, name, input} -> pattern_inputs([{name, input} | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp inputs_of(inputs, name), do: for({^name, input} <- inputs, do: input)

  # The root and each child run TestPattern.waiting, which sends each input it is
  # given to the test process; `children` maps each nested action ID to its script.
  # Local work blocks until told.
  defp messages_setup(root, children \\ %{}, overrides \\ []) do
    if Process.whereis(:run_engine_observer) != self(),
      do: Process.register(self(), :run_engine_observer)

    c = fixture([pattern: {TestPattern, :waiting, %{name: "root", script: root}}] ++ overrides)
    reader = %{evidence_store: c.evidence_store, retention_count: 1_024}
    c = %{c | opts: Keyword.put(c.opts, :result_reader, reader)}
    base = c.opts[:bindings]["nested_callable"]
    parent = self()

    nested = %{
      base
      | facts: fn a -> %{base.facts.(a) | estimate: 10} end,
        nested: fn a ->
          %{
            base.nested.(a)
            | mfa: {TestPattern, :waiting},
              initial_state: %{name: a["id"], script: Map.fetch!(children, a["id"])}
          }
        end
    }

    bindings =
      c.opts[:bindings]
      |> Map.put("nested_callable", nested)
      |> Map.update!(
        "local_work",
        &Map.put(&1, :work, fn a -> {TestPattern, :blocked, [parent, a["payload"]]} end)
      )

    {c, bindings}
  end

  defp start_link(c, overrides), do: RunEngine.start_link(Keyword.merge(c.opts, overrides))

  defp replay_is_equal(c, engine, overrides) do
    before = %{view: Map.delete(view(engine), :classification), state: unit_state(c)}
    records = length(unit_inputs(c))
    transcript = RunEngine.transcript(engine, scope(), limits())
    assert {:ok, _} = transcript

    _ =
      Enum.reduce(1..2, engine, fn _, engine ->
        engine = restart(c, engine, overrides)
        state = unit_state(c)
        assert Map.delete(view(engine), :classification) == before.view
        assert state.slots == before.state.slots
        assert state.control.budgets == before.state.control.budgets
        assert state.control.callables == before.state.control.callables
        assert state.control.receipts == before.state.control.receipts
        assert state.control.count == before.state.control.count
        assert length(unit_inputs(c)) == records
        assert RunEngine.transcript(engine, scope(), limits()) == transcript
        assert RunEngine.transcript(engine, scope(), limits()) == transcript
        engine
      end)

    refute_receive {:pattern_input, _, _}, 300
    refute_receive {:effect_started, _, _}, 100
  end

  # The engine's expiry input for the action `id` of slot `{request, index}`.
  defp expired(id, {request, index}, at),
    do: %{
      "type" => "input",
      "version" => 1,
      "kind" => "action_outcome",
      "action_id" => id,
      "outcome" => "expired",
      "schema_id" => "elzoo.run-engine.refusal",
      "schema_version" => 1,
      "payload" => %{
        "reason" => "expired",
        "gate_id" => "gate",
        "gate_version" => 1,
        "request" => request,
        "index" => index
      },
      "at_ms" => at
    }

  defp resume_id(key, run_id \\ "run"),
    do:
      "resume:" <>
        Base.encode16(
          :crypto.hash(
            :sha256,
            :erlang.term_to_binary({run_id, key}, [:deterministic, {:minor_version, 2}])
          ),
          case: :lower
        )

  defp resume_records(c),
    do: for({id, %{kind: :resume_input} = r} <- unit_inputs(c), do: {id, r.occurrence})

  defp scope, do: %{tenant: "tenant", principal: "principal", run_id: "run"}
  defp limits, do: %{max_records: 65_536, max_bytes: 536_870_912}
end
