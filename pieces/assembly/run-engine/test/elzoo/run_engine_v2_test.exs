# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)

defmodule Elzoo.RunEngineV2Test do
  use ExUnit.Case, async: false
  import Elzoo.RunEngine.TestHelper
  alias Elzoo.{DurableUnit, DynamicUnits, RunEngine}
  alias Elzoo.RunEngine.TestPattern
  alias Elzoo.RunApprovalRelease, as: Run

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

  test "v2 activation and event settlement are durable, paired, and replayed without source reads" do
    calls = ExUnit.Callbacks.start_supervised!({Agent, fn -> %{head: 0, read: 0, ticket: nil} end})
    event_id = String.duplicate("e", 201)
    payload = %{"accepted" => true}

    source = %{
      id: "events",
      version: 1,
      head: fn _ ->
        Agent.update(calls, &Map.update!(&1, :head, fn n -> n + 1 end))
        {:ok, %{revision: 0, low_water: 0}}
      end,
      read: fn _, requested_id ->
        Agent.update(calls, &Map.update!(&1, :read, fn n -> n + 1 end))
        ticket = Agent.get(calls, & &1.ticket)

        {:ok,
         %{
           head: %{revision: 1, low_water: 0},
           event: %{
             id: requested_id,
             source_id: "events",
             correlation_id: ticket,
             sequence: 1,
             schema_id: "result",
             schema_version: 1,
             payload: payload
           }
         }}
      end
    }

    scripted_request = request_v2([action("wait", "wait_event")])

    c =
      fixture(
        protocol_version: 2,
        event_source: source,
        pattern:
          {TestPattern, :step,
           %{
             requests: [
               scripted_request,
               request_v2([finish_action("finish", %{"action_id" => "wait"})])
             ]
           }}
      )

    {:ok, fresh_unit} = DynamicUnits.start(c.directory, c.opts[:identity])

    assert DurableUnit.snapshot(fresh_unit) == %{
             version: 2,
             control: nil,
             slots: %{},
             requests: %{}
           }

    engine = start(c)
    {:ok, unit} = DynamicUnits.find(c.directory, c.opts[:identity])
    assert unit == fresh_unit
    initial = DurableUnit.snapshot(unit)
    assert initial.version == 2
    assert map_size(initial) == 4
    assert initial.control.protocol_version == 2
    assert Agent.get(calls, & &1.head) == 0
    assert Agent.get(calls, & &1.read) == 0

    start_record = %{
      version: 2,
      kind: :protocol,
      id: "start",
      input: Map.put(start_input_v2(), "at_ms", 2_000),
      run_id: "run",
      attempt_id: "attempt",
      correlation: %{},
      context: %{pause_deadline: 50_000}
    }

    assert {:Transition, %{version: 2}, _} = RunEngine.step(initial, start_record)

    assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())

    wait =
      wait_for(engine, fn view ->
        Enum.any?(view.slots, fn {_, slot} ->
          slot.kind == "wait_event" and slot.phase == :waiting
        end)
      end)

    key = Enum.find_value(wait.slots, fn {key, slot} -> if slot.kind == "wait_event", do: key end)
    native_wait = DurableUnit.snapshot(unit).slots[key]
    assert native_wait.phase == :waiting
    refute Map.has_key?(native_wait, :outcome)

    scope = %{tenant: "tenant", principal: "principal", run_id: "run"}
    limits = %{max_records: 65_536, max_bytes: 536_870_912}

    assert {:ok, %{run_id: "run", attempt_id: "attempt", waits: [waiting]}} =
             RunEngine.event_waits(engine, scope, limits)

    assert Map.keys(waiting) |> Enum.sort() ==
             Enum.sort([
               :occurrence,
               :action_id,
               :source_id,
               :correlation_id,
               :cursor,
               :deadline_ms,
               :status,
               :outcome,
               :accepted_event
             ])

    assert waiting.occurrence == key
    assert waiting.status == :waiting
    assert is_binary(waiting.correlation_id)
    assert byte_size(waiting.correlation_id) in 1..128
    assert Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, waiting.correlation_id)
    assert is_nil(waiting.accepted_event)
    assert {:error, :scope} = RunEngine.event_waits(engine, %{scope | tenant: "other"}, limits)

    assert {:error, :invalid_limits} =
             RunEngine.event_waits(engine, scope, %{max_records: 0, max_bytes: 1})

    assert Agent.get(calls, & &1.read) == 0

    Agent.update(calls, &Map.put(&1, :ticket, waiting.correlation_id))

    input = %{
      "type" => "input",
      "version" => 2,
      "kind" => "outside_event",
      "action_id" => waiting.action_id,
      "source_id" => waiting.source_id,
      "correlation_id" => waiting.correlation_id,
      "event_id" => event_id,
      "schema_id" => "result",
      "schema_version" => 1,
      "payload" => payload
    }

    context = verified(%{occurrence: key, actual: 0, dispatch: "not_dispatched"})

    assert {:error, :invalid_correlation} =
             RunEngine.input(engine, "spoofed-event", input, Map.put(context, :verified_event, %{}))

    assert {:error, :invalid_correlation} =
             RunEngine.input(engine, "claimed-cost", input, Map.put(context, :actual, 1))

    assert {:error, :invalid_correlation} =
             RunEngine.input(
               engine,
               "claimed-dispatch",
               input,
               Map.put(context, :dispatch, "dispatched")
             )

    assert Agent.get(calls, & &1.read) == 0
    event_input_id = "outside-event-input"
    assert {:ok, :applied} = RunEngine.input(engine, event_input_id, input, context)
    assert Agent.get(calls, & &1.read) == 1

    assert {:ok, :unchanged} = RunEngine.input(engine, event_input_id, input, context)
    assert Agent.get(calls, & &1.read) == 1

    assert {:ok, %{waits: [settled]}} = RunEngine.event_waits(engine, scope, limits)
    assert settled.status == :settled
    assert settled.outcome == "completed"
    assert settled.accepted_event == %{event_id: event_id, input_id: event_input_id, sequence: 1}
    assert wait_for(engine, &(&1.outcome == :completed)).outcome == :completed

    assert {:ok, %{action_id: "wait", payload: ^payload}} =
             RunEngine.result(engine, scope, limits)
  end

  test "a failed outside-event source read appends no original input" do
    calls = ExUnit.Callbacks.start_supervised!({Agent, fn -> 0 end})

    source = %{
      id: "events",
      version: 1,
      head: fn _ -> {:ok, %{revision: 0, low_water: 0}} end,
      read: fn _, _ ->
        Agent.update(calls, &(&1 + 1))
        {:error, :unavailable}
      end
    }

    c =
      fixture(
        protocol_version: 2,
        event_source: source,
        pattern: {TestPattern, :step, %{requests: [request_v2([action("wait", "wait_event")])]}}
      )

    engine = start(c)
    assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())

    {:ok, %{waits: [waiting]}} =
      RunEngine.event_waits(engine, %{tenant: "tenant", principal: "principal", run_id: "run"}, %{
        max_records: 100,
        max_bytes: 100_000
      })

    input = %{
      "type" => "input",
      "version" => 2,
      "kind" => "outside_event",
      "action_id" => waiting.action_id,
      "source_id" => waiting.source_id,
      "correlation_id" => waiting.correlation_id,
      "event_id" => "event-failure",
      "schema_id" => "result",
      "schema_version" => 1,
      "payload" => %{"accepted" => true}
    }

    context = verified(%{occurrence: waiting.occurrence, actual: 0, dispatch: "not_dispatched"})
    assert {:error, _} = RunEngine.input(engine, "source-failure", input, context)
    assert Agent.get(calls, & &1) == 1

    refute Enum.any?(rows(c), fn row ->
             row.kind == "input" and
               match?({1, {"source-failure", _}}, :erlang.binary_to_term(row.payload, [:safe]))
           end)
  end

  test "local work after an outside event can be the completed result" do
    calls = ExUnit.Callbacks.start_supervised!({Agent, fn -> %{ticket: nil, read: 0} end})
    event_payload = %{"accepted" => true}

    source = %{
      id: "events",
      version: 1,
      head: fn _ -> {:ok, %{revision: 0, low_water: 0}} end,
      read: fn _, event_id ->
        Agent.update(calls, &Map.update!(&1, :read, fn n -> n + 1 end))
        ticket = Agent.get(calls, & &1.ticket)

        {:ok,
         %{
           head: %{revision: 1, low_water: 0},
           event: %{
             id: event_id,
             source_id: "events",
             correlation_id: ticket,
             sequence: 1,
             schema_id: "result",
             schema_version: 1,
             payload: event_payload
           }
         }}
      end
    }

    c =
      fixture(
        protocol_version: 2,
        event_source: source,
        pattern:
          {TestPattern, :step,
           %{
             requests: [
               request_v2([action("wait", "wait_event")]),
               request_v2([action("local", "local_work")]),
               request_v2([finish_action("finish", %{"action_id" => "local"})])
             ]
           }}
      )

    parent = self()
    wait_estimate = 0
    local_estimate = 7

    bindings =
      c.opts[:bindings]
      |> Map.update!("wait_event", fn binding ->
        Map.put(binding, :facts, fn action ->
          Map.put(binding.facts.(action), :estimate, wait_estimate)
        end)
      end)
      |> Map.update!("local_work", fn binding ->
        binding
        |> Map.put(:facts, fn action ->
          Map.put(binding.facts.(action), :estimate, local_estimate)
        end)
        |> Map.put(:work, fn action ->
          {TestPattern, :blocked, [parent, action["payload"]]}
        end)
      end)

    engine = start(c, bindings: bindings)
    assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())

    scope = %{tenant: "tenant", principal: "principal", run_id: "run"}
    limits = %{max_records: 65_536, max_bytes: 536_870_912}
    assert {:ok, %{waits: [waiting]}} = RunEngine.event_waits(engine, scope, limits)
    {:ok, unit} = DynamicUnits.find(c.directory, c.opts[:identity])
    waiting_state = DurableUnit.snapshot(unit)
    waiting_slot = waiting_state.slots[waiting.occurrence]

    {:Transition, _, {:some, {:status, waiting_budget}}} =
      Elzoo.Budget.step(waiting_state.control.budgets["root"].state, {2_000, :status})

    assert waiting_slot.estimate == wait_estimate
    assert waiting_slot.reservation == nil
    assert waiting_budget.reserved == 0
    assert waiting_budget.open == 0
    assert waiting_budget.committed == 0

    Agent.update(calls, &Map.put(&1, :ticket, waiting.correlation_id))

    input = %{
      "type" => "input",
      "version" => 2,
      "kind" => "outside_event",
      "action_id" => waiting.action_id,
      "source_id" => waiting.source_id,
      "correlation_id" => waiting.correlation_id,
      "event_id" => "event-before-local-work",
      "schema_id" => "result",
      "schema_version" => 1,
      "payload" => event_payload
    }

    context = verified(%{occurrence: waiting.occurrence, actual: 0, dispatch: "not_dispatched"})
    assert {:ok, :applied} = RunEngine.input(engine, "event-before-local-work", input, context)
    assert_receive {:local_started, task}, 5_000

    running = DurableUnit.snapshot(unit)
    wait_slot = running.slots[waiting.occurrence]

    {local_key, local_slot} =
      Enum.find(running.slots, fn {_, slot} -> slot.action_id == "local" end)

    {:Transition, _, {:some, {:status, running_budget}}} =
      Elzoo.Budget.step(running.control.budgets["root"].state, {2_000, :status})

    assert wait_slot.actual == 0
    assert wait_slot.reservation == nil
    assert local_slot.phase == :running
    assert local_slot.reservation.estimate == local_estimate
    assert running_budget.reserved == local_estimate
    assert running_budget.committed == 0

    send(task, :finish)
    assert wait_for(engine, &(&1.outcome == :completed)).outcome == :completed
    assert Agent.get(calls, & &1.read) == 1

    completed = DurableUnit.snapshot(unit)
    completed_wait = completed.slots[waiting.occurrence]
    completed_local = completed.slots[local_key]

    {:Transition, _, {:some, {:status, completed_budget}}} =
      Elzoo.Budget.step(completed.control.budgets["root"].state, {2_000, :status})

    assert completed_wait.actual == 0
    assert completed_wait.reservation == nil
    assert completed_local.actual == local_estimate
    assert completed_local.reservation.estimate == local_estimate
    assert completed_budget.reserved == 0
    assert completed_budget.committed == local_estimate

    assert {:ok, %{action_id: "local", payload: %{"value" => 7}}} =
             RunEngine.result(engine, scope, limits)
  end

  test "zero-estimate wait is admitted when a live sibling reservation fills the budget" do
    parent = self()

    source = %{
      id: "events",
      version: 1,
      head: fn _ -> {:ok, %{revision: 0, low_water: 0}} end,
      read: fn _, _ -> {:error, :not_found} end
    }

    local_estimate = 7

    c =
      fixture(
        protocol_version: 2,
        event_source: source,
        budget: %{cap: local_estimate, unit: "credits", id: "budget", incarnation: "sealed"},
        pattern:
          {TestPattern, :step,
           %{
             requests: [
               request_v2([action("local", "local_work"), action("wait", "wait_event")])
             ]
           }}
      )

    bindings =
      c.opts[:bindings]
      |> Map.update!("local_work", fn binding ->
        binding
        |> Map.put(:facts, fn action ->
          Map.put(binding.facts.(action), :estimate, local_estimate)
        end)
        |> Map.put(:work, fn action ->
          {TestPattern, :blocked, [parent, action["payload"]]}
        end)
      end)
      |> Map.update!("wait_event", fn binding ->
        Map.put(binding, :facts, fn action -> Map.put(binding.facts.(action), :estimate, 0) end)
      end)

    engine = start(c, bindings: bindings)

    assert {:ok, :applied} =
             RunEngine.input(engine, "start-capacity-boundary", start_input_v2(), verified())

    assert_receive {:local_started, task}, 5_000

    try do
      scope = %{tenant: "tenant", principal: "principal", run_id: "run"}
      limits = %{max_records: 65_536, max_bytes: 536_870_912}
      assert {:ok, %{waits: [wait]}} = RunEngine.event_waits(engine, scope, limits)

      {:ok, unit} = DynamicUnits.find(c.directory, c.opts[:identity])
      state = DurableUnit.snapshot(unit)
      wait_slot = state.slots[wait.occurrence]

      {local_key, local_slot} =
        Enum.find(state.slots, fn {_, slot} -> slot.action_id == "local" end)

      {:Transition, _, {:some, {:status, budget}}} =
        Elzoo.Budget.step(state.control.budgets["root"].state, {2_000, :status})

      assert wait_slot.phase == :waiting
      assert wait_slot.estimate == 0
      assert wait_slot.reservation == nil
      assert local_slot.phase == :running
      assert local_slot.reservation.estimate == local_estimate
      assert budget.reserved == local_estimate
      assert budget.remaining == 0
      assert budget.open == 1
      assert budget.committed == 0
      assert state.slots[local_key].reservation.estimate == local_estimate
    after
      send(task, :finish)
    end
  end

  test "zero-estimate local work remains refused in v1 and v2" do
    parent = self()

    for version <- [1, 2] do
      action = action("zero-local", "local_work")
      request = if version == 1, do: request([action]), else: request_v2([action])

      c =
        fixture(
          protocol_version: version,
          pattern: {TestPattern, :step, %{requests: [request]}}
        )

      bindings =
        Map.update!(c.opts[:bindings], "local_work", fn binding ->
          binding
          |> Map.put(:facts, fn action -> Map.put(binding.facts.(action), :estimate, 0) end)
          |> Map.put(:work, fn action ->
            send(parent, {:zero_local_work_started, version})
            {TestPattern, :work, [action["payload"]]}
          end)
        end)

      engine = start(c, bindings: bindings)
      input = if version == 1, do: start_input(), else: start_input_v2()
      assert {:ok, :applied} = RunEngine.input(engine, "zero-local-start", input, verified())

      view =
        wait_for(engine, fn view ->
          Enum.any?(view.slots, fn {_, slot} ->
            slot.action_id == "zero-local" and slot.phase == :settled
          end)
        end)

      slot =
        Enum.find_value(view.slots, fn {_, slot} -> if slot.action_id == "zero-local", do: slot end)

      assert slot.outcome == "out_of_budget"
      assert is_nil(slot[:reservation])
      refute_receive {:zero_local_work_started, ^version}, 0

      {:ok, unit} = DynamicUnits.find(c.directory, c.opts[:identity])
      state = DurableUnit.snapshot(unit)

      {:Transition, _, {:some, {:status, budget}}} =
        Elzoo.Budget.step(state.control.budgets["root"].state, {2_000, :status})

      assert budget.reserved == 0
      assert budget.open == 0
      assert budget.committed == 0
    end
  end

  test "non-integer zero and negative wait estimates still refuse" do
    for estimate <- [0.0, -1] do
      c =
        fixture(
          protocol_version: 2,
          pattern:
            {TestPattern, :step, %{requests: [request_v2([action("invalid-wait", "wait_event")])]}}
        )

      bindings =
        Map.update!(c.opts[:bindings], "wait_event", fn binding ->
          Map.put(binding, :facts, fn action ->
            Map.put(binding.facts.(action), :estimate, estimate)
          end)
        end)

      engine = start(c, bindings: bindings)

      assert {:ok, :applied} =
               RunEngine.input(engine, "invalid-wait-start", start_input_v2(), verified())

      view =
        wait_for(engine, fn view ->
          Enum.any?(view.slots, fn {_, slot} ->
            slot.action_id == "invalid-wait" and slot.phase == :settled
          end)
        end)

      slot =
        Enum.find_value(view.slots, fn {_, slot} ->
          if slot.action_id == "invalid-wait", do: slot
        end)

      assert slot.kind == "wait_event"
      assert slot.outcome == "out_of_budget"
      assert is_nil(slot[:reservation])

      assert {:ok, %{waits: []}} =
               RunEngine.event_waits(
                 engine,
                 %{
                   tenant: "tenant",
                   principal: "principal",
                   run_id: "run"
                 },
                 %{max_records: 65_536, max_bytes: 536_870_912}
               )

      {:ok, unit} = DynamicUnits.find(c.directory, c.opts[:identity])
      state = DurableUnit.snapshot(unit)

      {:Transition, _, {:some, {:status, budget}}} =
        Elzoo.Budget.step(state.control.budgets["root"].state, {2_000, :status})

      assert budget.reserved == 0
      assert budget.open == 0
      assert budget.committed == 0
    end
  end

  test "v2 rejects v1 inputs and PatternStep requests without upgrading their tags" do
    c =
      fixture(
        protocol_version: 2,
        pattern: {TestPattern, :step, %{requests: [request([action("legacy")])]}}
      )

    engine = start(c)
    before = rows(c)

    assert match?({:error, _}, RunEngine.input(engine, "legacy-start", start_input(), verified()))
    assert rows(c) == before
    assert {:ok, :applied} = RunEngine.input(engine, "start-v2", start_input_v2(), verified())
    assert wait_for(engine, &(&1.classification == :invalid_request)).request_count == 1
    assert view(engine).slots == %{}
    assert Enum.all?(protocol_records(c), &(&1.version == 2 and &1.input["version"] == 2))
  end

  test "a v2 Unit is fresh and is reused for a second v2 Run" do
    c =
      fixture(
        protocol_version: 2,
        pattern:
          {TestPattern, :step,
           %{
             requests: [
               request_v2([action("local", "local_work")]),
               request_v2([finish_action("done", %{"action_id" => "local"})])
             ]
           }}
      )

    {:ok, unit} = DynamicUnits.start(c.directory, c.opts[:identity])
    assert DurableUnit.snapshot(unit) == %{version: 2, control: nil, slots: %{}, requests: %{}}
    engine = start(c)
    assert {:ok, :applied} = RunEngine.input(engine, "start-first", start_input_v2(), verified())
    assert wait_for(engine, &(&1.outcome == :completed)).outcome == :completed
    first = DurableUnit.snapshot(unit)
    assert first.version == 2
    assert first.control.run_id == "run"
    GenServer.stop(engine)

    {:ok, old_run} = Run.status(c.run, "run")

    assert {:ok, revision, _} =
             Run.command(c.run, %{
               kind: :create,
               run_id: "run-two",
               operation_id: "operation-two",
               provider_refs: %{},
               expected_revision: old_run.revision
             })

    assert {:ok, _, _} =
             Run.command(c.run, %{
               kind: :begin_attempt,
               run_id: "run-two",
               attempt_id: "attempt-two",
               expected_revision: revision
             })

    engine = start(c, run_id: "run-two")
    assert {:ok, ^unit} = DynamicUnits.find(c.directory, c.opts[:identity])
    second = DurableUnit.snapshot(unit)
    assert second.version == 2
    assert second.control.run_id == "run-two"
    assert second.control.attempt_id == "attempt-two"

    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "start-second",
               start_input_v2(),
               verified(%{run_id: "run-two", attempt_id: "attempt-two"})
             )

    assert wait_for(engine, &(&1.outcome == :completed)).outcome == :completed
    assert DurableUnit.snapshot(unit).control.run_id == "run-two"
  end

  test "v2 person answers and lifecycle controls retain native v2 records" do
    c =
      fixture(
        protocol_version: 2,
        pattern:
          {TestPattern, :step,
           %{
             requests: [
               request_v2([action("answer", "ask_person")]),
               request_v2([finish_action("done", %{"action_id" => "answer"})])
             ]
           }}
      )

    engine = start(c)
    assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())
    wait_for(engine, &(&1.slots[{1, 0}][:phase] == :waiting))

    assert {:ok, :applied} =
             RunEngine.control(
               engine,
               "pause-v2",
               %{kind: :pause, pause_deadline: 50_000},
               verified()
             )

    answer = person_answer_v2("answer", "person", %{"value" => 7})

    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "person-answer-v2",
               answer,
               verified(%{occurrence: {1, 0}, verified_person: "person"})
             )

    assert view(engine).phase == :paused

    assert {:ok, :applied} =
             RunEngine.control(
               engine,
               "continue-v2",
               %{kind: :continue, person_id: "person", run_deadline: 60_000},
               verified(%{verified_person: "person"})
             )

    assert wait_for(engine, &(&1.outcome == :completed)).outcome == :completed

    assert Enum.any?(
             protocol_records(c),
             &(&1.input["kind"] == "person_answer" and &1.input["version"] == 2)
           )
  end

  # ELZ-359 (#843): the readers project a resumed v2 input with the fold's phase switch.
  test "native_v2_resumed_input: after continue a resumed answer leaves the Run active, the readers agree, and the next wake reaches the root" do
    Process.register(self(), :run_engine_observer)

    c =
      fixture(
        protocol_version: 2,
        pattern:
          {TestPattern, :waiting,
           %{name: "root", script: [request_v2([action("answer", "ask_person")]), :wait, :wait]}}
      )

    c = %{
      c
      | opts:
          Keyword.put(c.opts, :result_reader, %{
            evidence_store: c.evidence_store,
            retention_count: 1_024
          })
    }

    engine = start(c)
    assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())
    assert_receive {:pattern_input, "root", %{"kind" => "start"}}
    wait_for(engine, &(&1.slots[{1, 0}][:phase] == :waiting))

    assert {:ok, :applied} =
             RunEngine.control(
               engine,
               "pause-v2",
               %{kind: :pause, pause_deadline: 50_000},
               verified()
             )

    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "person-answer-v2",
               person_answer_v2("answer", "person", %{"value" => 7}),
               verified(%{occurrence: {1, 0}, verified_person: "person"})
             )

    assert {:ok, :applied} =
             RunEngine.control(
               engine,
               "continue-v2",
               %{kind: :continue, person_id: "person", run_deadline: 60_000},
               verified(%{verified_person: "person"})
             )

    assert_receive {:pattern_input, "root", %{"kind" => "person_answer", "version" => 2}}
    assert view(engine).phase == :active

    scope = %{tenant: "tenant", principal: "principal", run_id: "run"}
    limits = %{max_records: 65_536, max_bytes: 536_870_912}
    assert {:ok, %{run_id: "run", waits: []}} = RunEngine.event_waits(engine, scope, limits)
    assert {:ok, %{run_id: "run"}} = RunEngine.transcript(engine, scope, limits)

    assert {:ok, _} = RunEngine.input(engine, "wake-v2", wake_v2(), verified())
    assert_receive {:pattern_input, "root", %{"kind" => "wake", "version" => 2}}
    refute_receive {:pattern_input, _, _}, 200
    Process.unregister(:run_engine_observer)
  end

  test "v2 tool and model actions use effect completion without changing protocol tags" do
    c =
      fixture(
        protocol_version: 2,
        pattern:
          {TestPattern, :step,
           %{
             requests: [
               request_v2([action("tool", "tool_call")]),
               request_v2([action("model", "model_call")]),
               request_v2([finish_action("finish", %{"action_id" => "model"})])
             ]
           }}
      )

    engine = start(c)
    assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())
    assert_receive {:effect_started, tool_provider, _}, 5_000

    tool_key =
      Enum.find_value(view(engine).slots, fn {key, slot} -> if slot.action_id == "tool", do: key end)

    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "tool-result-v2",
               action_outcome_v2("tool", %{"value" => 7}),
               verified(%{occurrence: tool_key, actual: 1, dispatch: "dispatched"})
             )

    send(tool_provider, {:result, %{"value" => 7}})
    assert_receive {:effect_started, model_provider, _}, 5_000

    model_key =
      Enum.find_value(view(engine).slots, fn {key, slot} ->
        if slot.action_id == "model", do: key
      end)

    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "model-result-v2",
               action_outcome_v2("model", %{"value" => 7}),
               verified(%{occurrence: model_key, actual: 1, dispatch: "dispatched"})
             )

    send(model_provider, {:result, %{"value" => 7}})
    assert wait_for(engine, &(&1.outcome == :completed)).outcome == :completed
    assert Enum.all?(protocol_records(c), &(&1.version == 2 and &1.input["version"] == 2))
  end

  test "v2 nested callable accepts a v2 child request and settles its parent" do
    c =
      fixture(
        protocol_version: 2,
        pattern:
          {TestPattern, :step, %{requests: [request_v2([action("nested", "nested_callable")])]}}
      )

    base = c.opts[:bindings]["nested_callable"]

    nested =
      Map.put(base, :nested, fn action ->
        Map.put(base.nested.(action), :initial_state, %{
          requests: [request_v2([finish_action("child-finish")])]
        })
      end)

    engine = start(c, bindings: Map.put(c.opts[:bindings], "nested_callable", nested))
    assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())

    assert wait_for(engine, &(&1.slots[{1, 0}][:outcome] == "completed")).slots[{1, 0}].outcome ==
             "completed"

    assert Enum.all?(protocol_records(c), &(&1.version == 2))
  end

  test "v2 schema-map binding selects its result schema and rejects a mismatched result" do
    parent = self()
    mapped = action("mapped", "local_work")

    c =
      fixture(
        protocol_version: 2,
        pattern: {TestPattern, :step, %{requests: [request_v2([mapped])]}}
      )

    binding =
      c.opts[:bindings]["local_work"]
      |> Map.put(:id, "schema-local")
      |> Map.put(:version, 2)
      |> Map.put(:result, {"result", 1})
      |> Map.put(:work, fn action ->
        send(parent, {:custom_binding, action["id"]})
        {TestPattern, :work, [action["payload"]]}
      end)

    engine = start(c, bindings: Map.put(c.opts[:bindings], "local_work", %{"action" => binding}))

    assert {:ok, :applied} = RunEngine.input(engine, "mapped-start", start_input_v2(), verified())
    assert_receive {:custom_binding, "mapped"}

    assert wait_for(engine, &(&1.slots[{1, 0}][:outcome] == "completed")).slots[{1, 0}].outcome ==
             "completed"

    mapped_record = Enum.find(protocol_records(c), &(&1.input["action_id"] == "mapped"))
    assert mapped_record.version == 2
    assert mapped_record.input["schema_id"] == "result"

    parent = self()

    blocked =
      Map.put(binding, :work, fn action -> {TestPattern, :blocked, [parent, action["payload"]]} end)

    bad_action = action("mapped", "local_work")

    bad =
      fixture(
        protocol_version: 2,
        pattern: {TestPattern, :step, %{requests: [request_v2([bad_action])]}}
      )

    bad_engine =
      start(bad, bindings: Map.put(bad.opts[:bindings], "local_work", %{"action" => blocked}))

    assert {:ok, :applied} = RunEngine.input(bad_engine, "bad-start", start_input_v2(), verified())
    assert_receive {:local_started, task}, 5_000

    assert {:ok, :applied} =
             RunEngine.input(
               bad_engine,
               "wrong-result-schema",
               action_outcome_v2("mapped", %{"value" => 7}, "action"),
               verified(%{occurrence: {1, 0}, actual: 1, dispatch: "dispatched"})
             )

    assert wait_for(bad_engine, &(&1.slots[{1, 0}][:outcome] == "failed")).slots[{1, 0}].outcome ==
             "failed"

    {_, bad_record} = Enum.find(durable_records(bad), fn {id, _} -> id == "wrong-result-schema" end)
    assert bad_record.version == 2
    assert bad_record.input["version"] == 2
    assert bad_record.input["schema_id"] == "elzoo.run-engine.refusal"
    send(task, :finish)
  end

  test "v2 resource consumption validates the stored v1 map before recording a v2 envelope" do
    open =
      action("open", "resource_open", %{
        "run_id" => "run",
        "resource_name" => "document",
        "data" => %{}
      })

    c =
      fixture(
        protocol_version: 2,
        pattern:
          {TestPattern, :step,
           %{requests: [request_v2([open]), request_v2([action("after", "local_work")])]}}
      )

    {owner, bindings} = resource(c)
    engine = start(c, resources: %{"document" => owner}, bindings: bindings)
    assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())
    assert_receive {:effect_started, opening, _}, 5_000

    assert {:ok, _} =
             Elzoo.RunResource.command(owner, %{
               id: "open-evidence",
               at_ms: 2_000,
               body:
                 {:observed, ["tenant", "account", "effect", "publish", "open"],
                  {:completed, %{opened_at_ms: 2_000}}}
             })

    send(opening, {:result, %{}})
    assert {:ok, :applied} = RunEngine.input(engine, "consume-open", wake_v2(), verified())
    assert view(engine).slots[{1, 0}].outcome == "completed"

    assert {:ok, _} =
             Elzoo.RunResource.command(owner, %{
               id: "resource-event",
               at_ms: 2_500,
               body: {:event, "change", %{"revision" => 2}}
             })

    Agent.update(c.clock, fn _ -> 2_600 end)
    assert {:ok, :applied} = RunEngine.input(engine, "consume-event", wake_v2(), verified())

    {:ok, resource_history} = Elzoo.RunResource.read(owner, 0)

    resource_event =
      Enum.find_value(resource_history.entries, fn entry ->
        Enum.find(entry.inputs, &(&1["kind"] == "resource_event"))
      end)

    assert resource_event["version"] == 1

    assert Enum.sort(Map.keys(resource_event)) ==
             Enum.sort([
               "type",
               "version",
               "kind",
               "at_ms",
               "schema_id",
               "schema_version",
               "payload"
             ])

    {_, event_record} =
      Enum.find(protocol_records_with_ids(c), fn {_, record} ->
        record.input["kind"] == "resource_event"
      end)

    assert event_record.version == 2
    assert event_record.input == Map.put(resource_event, "version", 2)
  end

  test "v2 source descriptors validate shape and arity without a 32-bit version cap" do
    calls = ExUnit.Callbacks.start_supervised!({Agent, fn -> %{head: 0, read: 0} end})

    source = %{
      id: "events",
      version: 2_147_483_648,
      head: fn _ -> Agent.update(calls, &Map.update!(&1, :head, fn n -> n + 1 end)) end,
      read: fn _, _ -> Agent.update(calls, &Map.update!(&1, :read, fn n -> n + 1 end)) end
    }

    c = fixture(protocol_version: 2, event_source: source)

    for version <- [0, -1, 3, 1.0] do
      assert {:error, :invalid_options_or_recovery} =
               RunEngine.start_link(Keyword.put(c.opts, :protocol_version, version))
    end

    invalid_sources = [
      Map.delete(source, :head),
      Map.put(source, :extra, true),
      Map.put(source, :version, 0),
      Map.put(source, :version, -1),
      Map.put(source, :head, fn -> :ok end),
      Map.put(source, :read, fn _ -> :ok end),
      Map.put(source, :id, String.duplicate("s", 201))
    ]

    for event_source <- invalid_sources do
      assert {:error, :invalid_options_or_recovery} =
               RunEngine.start_link(Keyword.put(c.opts, :event_source, event_source))
    end

    assert {:error, :invalid_options_or_recovery} =
             RunEngine.start_link(Keyword.put(c.opts, :event_source, nil))

    assert {:error, :invalid_options_or_recovery} =
             RunEngine.start_link(Keyword.put(c.opts, :protocol_version, 1))

    assert {:error, :invalid_options_or_recovery} =
             RunEngine.start_link(c.opts ++ [protocol_version: 2])

    assert {:error, :invalid_options_or_recovery} =
             RunEngine.start_link(c.opts ++ [event_source: source])

    engine = start(c)
    {:ok, unit} = DynamicUnits.find(c.directory, c.opts[:identity])

    assert DurableUnit.snapshot(unit).control.event_source == %{
             id: "events",
             version: 2_147_483_648
           }

    assert Agent.get(calls, & &1) == %{head: 0, read: 0}
    assert is_pid(engine)
  end

  test "omitted and explicit v1 preserve native configuration and recorded bytes" do
    pattern = {TestPattern, :step, %{requests: [request([action("local")])]}}
    omitted = fixture(pattern: pattern)
    explicit = fixture(protocol_version: 1, pattern: pattern)
    omitted_engine = start(omitted)
    explicit_engine = start(explicit)
    {:ok, omitted_unit} = DynamicUnits.find(omitted.directory, omitted.opts[:identity])
    {:ok, explicit_unit} = DynamicUnits.find(explicit.directory, explicit.opts[:identity])

    omitted_initial = DurableUnit.snapshot(omitted_unit)
    explicit_initial = DurableUnit.snapshot(explicit_unit)
    assert omitted_initial.version == 1
    assert omitted_initial == explicit_initial
    assert omitted_initial.control.fingerprint == explicit_initial.control.fingerprint
    assert Run.status(omitted.run, "run") |> elem(0) == :ok
    assert Run.status(explicit.run, "run") |> elem(0) == :ok
    assert is_pid(omitted_engine)
    assert is_pid(explicit_engine)

    assert {:ok, :applied} =
             RunEngine.input(omitted_engine, "same-start", start_input(), verified())

    assert {:ok, :applied} =
             RunEngine.input(explicit_engine, "same-start", start_input(), verified())

    # The local work completes by a later engine input, after `input/4` returns.
    for engine <- [omitted_engine, explicit_engine] do
      settled = wait_for(engine, &(&1.slots[{1, 0}][:phase] == :settled))
      assert settled.slots[{1, 0}].outcome == "completed"
    end

    assert Enum.map(protocol_records(omitted), & &1.input) ==
             Enum.map(protocol_records(explicit), & &1.input)

    assert Enum.all?(protocol_records(omitted), &(&1.version == 1 and &1.input["version"] == 1))
    assert Enum.all?(protocol_records(explicit), &(&1.version == 1 and &1.input["version"] == 1))

    omitted_state = DurableUnit.snapshot(omitted_unit)
    explicit_state = DurableUnit.snapshot(explicit_unit)
    omitted_slot = omitted_state.slots[{1, 0}]
    explicit_slot = explicit_state.slots[{1, 0}]

    assert omitted_slot.kind == "local_work"
    assert omitted_slot.phase == :settled
    assert omitted_slot.outcome == "completed"
    refute Map.has_key?(omitted_slot, :event_receipt)
    assert omitted_slot == explicit_slot

    assert :erlang.term_to_binary(omitted_state, [:deterministic, {:minor_version, 2}]) ==
             :erlang.term_to_binary(explicit_state, [:deterministic, {:minor_version, 2}])
  end

  # ELZ-360 (#854): through the v2 path a local-work outcome is committed with the pause
  # deadline that the host's context callback gives when its delivery is handled. The
  # work is dispatched while the callback gives 30,000; its outcome comes at 35,000.
  test "native_v2_local_outcome_pause_deadline" do
    {c, engine, task} = v2_local_outcome_setup()

    Agent.update(c.context, &Map.put(&1, :pause_deadline, 50_000))
    Agent.update(c.clock, fn _ -> 35_000 end)
    send(task, :finish)

    contexts = await_v2_local_outcome_contexts(c)
    assert_v2_paused_and_read(c, engine)
    assert contexts == [%{pause_deadline: 50_000}]
  end

  test "outcome_waiting_in_the_mailbox_takes_the_later_deadline (v2)" do
    {c, engine, task} = v2_local_outcome_setup()

    # The outcome waits in the suspended engine's mailbox while the callback still
    # gives 30,000; it is handled after the callback gives 50,000.
    :ok = :sys.suspend(engine)
    Agent.update(c.clock, fn _ -> 35_000 end)
    send(task, :finish)
    await_v2_mailbox(engine)
    Agent.update(c.context, &Map.put(&1, :pause_deadline, 50_000))
    :ok = :sys.resume(engine)

    contexts = await_v2_local_outcome_contexts(c)
    assert_v2_paused_and_read(c, engine)
    assert contexts == [%{pause_deadline: 50_000}]
  end

  # A v2 :pause Run with request cap 1 whose root asks local work "slow" (blocked until
  # told) and, on its outcome, a second request: the first excess.
  defp v2_local_outcome_setup do
    Process.register(self(), :run_engine_observer)
    parent = self()

    c =
      fixture(
        protocol_version: 2,
        request_cap: 1,
        budget_rule: :pause,
        pattern:
          {TestPattern, :waiting,
           %{
             name: "root",
             script: [
               request_v2([action("slow")]),
               request_v2([action("x", "ask_person")]),
               :wait
             ]
           }}
      )

    bindings =
      Map.update!(c.opts[:bindings], "local_work", fn binding ->
        Map.put(binding, :work, fn a -> {TestPattern, :blocked, [parent, a["payload"]]} end)
      end)

    Agent.update(c.context, &Map.put(&1, :pause_deadline, 30_000))
    engine = start(c, bindings: bindings)
    assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())
    assert_receive {:pattern_input, "root", %{"kind" => "start"}}
    assert_receive {:local_started, task}, 5_000
    {c, engine, task}
  end

  defp assert_v2_paused_and_read(c, engine) do
    assert_receive {:pattern_input, "root", %{"kind" => "action_outcome", "action_id" => "slow"}}
    assert {:ok, :applied} = RunEngine.input(engine, "wake-v2", wake_v2(), verified())
    {:ok, unit} = DynamicUnits.find(c.directory, c.opts[:identity])
    lifecycle = DurableUnit.snapshot(unit).control.lifecycle

    assert {view(engine).phase, lifecycle.phase, lifecycle.pause_deadline} ==
             {:paused, :paused, 50_000}

    scope = %{tenant: "tenant", principal: "principal", run_id: "run"}
    limits = %{max_records: 65_536, max_bytes: 536_870_912}
    assert {:ok, %{run_id: "run"}} = RunEngine.event_waits(engine, scope, limits)
    assert {:ok, %{run_id: "run"}} = RunEngine.transcript(engine, scope, limits)
    Process.unregister(:run_engine_observer)
  end

  defp await_v2_local_outcome_contexts(c, left \\ 400) do
    contexts =
      for {"local:" <> _, record} <- protocol_records_with_ids(c), do: record.context

    cond do
      contexts != [] -> contexts
      left == 0 -> flunk("no local-work outcome was committed")
      true -> Process.sleep(5) && await_v2_local_outcome_contexts(c, left - 1)
    end
  end

  defp await_v2_mailbox(pid, left \\ 400) do
    cond do
      Process.info(pid, :message_queue_len) != {:message_queue_len, 0} -> :ok
      left == 0 -> flunk("no message reached the suspended engine")
      true -> Process.sleep(5) && await_v2_mailbox(pid, left - 1)
    end
  end

  defp action_outcome_v2(action_id, payload, schema_id \\ "result") do
    %{
      "type" => "input",
      "version" => 2,
      "kind" => "action_outcome",
      "action_id" => action_id,
      "outcome" => "completed",
      "schema_id" => schema_id,
      "schema_version" => 1,
      "payload" => payload
    }
  end

  defp person_answer_v2(action_id, person_id, payload) do
    %{
      "type" => "input",
      "version" => 2,
      "kind" => "person_answer",
      "action_id" => action_id,
      "person_id" => person_id,
      "schema_id" => "result",
      "schema_version" => 1,
      "payload" => payload
    }
  end

  defp wake_v2, do: %{"type" => "input", "version" => 2, "kind" => "wake"}

  defp protocol_records(c), do: Enum.map(protocol_records_with_ids(c), &elem(&1, 1))

  defp protocol_records_with_ids(c) do
    Enum.filter(durable_records(c), fn {_, record} -> Map.get(record, :kind) == :protocol end)
  end

  defp durable_records(c) do
    Enum.flat_map(rows(c), fn row ->
      case :erlang.binary_to_term(row.payload, [:safe]) do
        {1, {id, record}} when is_map(record) -> [{id, record}]
        _ -> []
      end
    end)
  end
end
