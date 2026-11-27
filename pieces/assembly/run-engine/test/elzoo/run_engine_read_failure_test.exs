# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)

defmodule Elzoo.RunEngineReadFailureTest.ReadFaultStore do
  # The engine's own Store over the Unit's Store: every call is forwarded, and on request
  # the reply of one journal scan read (`read/4` of 1,000 records from sequence 1) is
  # replaced, after `skip` such reads that are forwarded unchanged. The Unit keeps the
  # plain Store, so only the engine's journal lookups meet the fault.
  @behaviour Elzoo.DurableLog.Store

  def new(store) do
    control = ExUnit.Callbacks.start_supervised!({Agent, fn -> nil end}, id: make_ref())
    {__MODULE__, %{store: store, control: control}}
  end

  def fail_next_scan({__MODULE__, %{control: control}}, fault, skip \\ 0),
    do: Agent.update(control, fn _ -> %{fault: fault, skip: skip} end)

  def armed?({__MODULE__, %{control: control}}), do: Agent.get(control, & &1) != nil

  def read({__MODULE__, %{control: control}} = adapter, stream, from, limit) do
    fault =
      if from == 1 and limit == 1_000 do
        Agent.get_and_update(control, fn
          %{skip: 0, fault: fault} -> {fault, nil}
          %{skip: skip} = armed -> {nil, %{armed | skip: skip - 1}}
          nil -> {nil, nil}
        end)
      end

    reply(fault, delegate(adapter, :read, [stream, from, limit]))
  end

  defp reply(nil, reply), do: reply
  defp reply(:unavailable, _), do: {:error, :unavailable}
  # A reply that the Store layer does not accept: DurableLog.read/4 gives {:error, :malformed}.
  defp reply(:malformed, _), do: {:error, :gap}
  defp reply(:pruned, _), do: {:error, {:pruned, 1}}
  defp reply(:low_water, {:ok, rows, head}), do: {:ok, rows, %{head | low_water: 1}}

  defp reply({:without, id}, {:ok, rows, head}),
    do: {:ok, Enum.reject(rows, &(&1.kind == "input" and input_id(&1) == id)), head}

  defp input_id(row) do
    {1, {id, _}} = :erlang.binary_to_term(row.payload, [:safe])
    id
  end

  def capabilities(adapter), do: delegate(adapter, :capabilities, [])
  def head(adapter, stream), do: delegate(adapter, :head, [stream])
  def read_at(adapter, stream, sequence), do: delegate(adapter, :read_at, [stream, sequence])
  def pending(adapter, stream, limit), do: delegate(adapter, :pending, [stream, limit])
  def read_ack(adapter, id), do: delegate(adapter, :read_ack, [id])

  def latest_checkpoint(adapter, stream, version),
    do: delegate(adapter, :latest_checkpoint, [stream, version])

  def read_checkpoint(adapter, stream, sequence, version),
    do: delegate(adapter, :read_checkpoint, [stream, sequence, version])

  def read_maintenance(adapter, stream, operation),
    do: delegate(adapter, :read_maintenance, [stream, operation])

  def append(adapter, stream, expected, records, items),
    do: delegate(adapter, :append, [stream, expected, records, items])

  def put_checkpoint(adapter, checkpoint), do: delegate(adapter, :put_checkpoint, [checkpoint])

  def retain(adapter, stream, expected, through, nonce),
    do: delegate(adapter, :retain, [stream, expected, through, nonce])

  def ack(adapter, id, nonce), do: delegate(adapter, :ack, [id, nonce])

  def repair_torn_tail(adapter, stream, expected, staged, nonce),
    do: delegate(adapter, :repair_torn_tail, [stream, expected, staged, nonce])

  defp delegate({__MODULE__, %{store: {module, _} = store}}, operation, args),
    do: apply(module, operation, [store | args])
end

defmodule Elzoo.RunEngineReadFailureTest do
  # ELZ-433: a journal lookup of the engine that cannot read the whole history (an
  # unavailable or malformed read, a pruned history, a page whose head has low-water above
  # zero) ends in a defined result, never a match error that stops the engine process.
  use ExUnit.Case, async: false
  import Elzoo.RunEngine.TestHelper
  alias Elzoo.{DurableLog, DurableUnit, DynamicUnits, PayloadSchema, RunEngine}
  alias Elzoo.RunApprovalRelease, as: Run
  alias Elzoo.RunEngine.TestPattern
  alias Elzoo.RunEngineReadFailureTest.ReadFaultStore

  @faults [:unavailable, :malformed, :pruned, :low_water]

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  setup_all do
    pid = database()
    {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.TestRegistry)
    {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.UnitRegistry)
    for process <- [registry, units], do: Process.unlink(process)

    on_exit(fn ->
      for process <- [registry, units, pid], Process.alive?(process), do: Supervisor.stop(process)
    end)

    :ok
  end

  describe "read_fault_store" do
    test "each fault replaces one scan read with its listed read result" do
      c = fixture()
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      store = ReadFaultStore.new(c.store)
      {:ok, page, %{low_water: 0}} = DurableLog.read(c.store, c.prefix, 1, 1_000)

      for {fault, expected} <- [
            unavailable: {:error, :unavailable},
            malformed: {:error, :malformed},
            pruned: {:error, {:pruned, 1}}
          ] do
        ReadFaultStore.fail_next_scan(store, fault)
        assert DurableLog.read(store, c.prefix, 1, 1_000) == expected
        assert {:ok, ^page, %{low_water: 0}} = DurableLog.read(store, c.prefix, 1, 1_000)
      end

      ReadFaultStore.fail_next_scan(store, :low_water)
      assert {:ok, ^page, %{low_water: 1}} = DurableLog.read(store, c.prefix, 1, 1_000)
      assert {:ok, ^page, %{low_water: 0}} = DurableLog.read(store, c.prefix, 1, 1_000)
    end
  end

  describe "input_lookup_fails" do
    test "input/4 gives unavailable and commits nothing for its ID; the same input applies after the fault" do
      c = fixture()
      {engine, store} = start_faulty(c)
      assert {:ok, :applied} = send_input(engine)

      for fault <- @faults do
        id = "wake-#{fault}"
        # A command for another Run moves the owner revision: the call first commits
        # the Run view "run:<revision>" in current/1, before the lookup of its ID.
        revision = move_owner_revision(c, "other-#{fault}")
        before = input_ids(c)
        ReadFaultStore.fail_next_scan(store, fault)

        assert {:error, :unavailable} = RunEngine.input(engine, id, wake(), verified())
        refute ReadFaultStore.armed?(store)
        assert input_ids(c) == before ++ ["run:#{revision}"]
        assert Process.alive?(engine)
        assert view(engine).reconciliation == nil

        assert {:ok, :applied} = RunEngine.input(engine, id, wake(), verified())
        assert input_ids(c) == before ++ ["run:#{revision}", id]
      end
    end
  end

  describe "control_lookup_fails" do
    test "pause, continue and cancel give unavailable, commit nothing and apply after the fault" do
      # Each control, its context and what its view shows once it applies.
      controls = [
        {"pause", %{kind: :pause, pause_deadline: 50_000}, verified(), &(&1.phase == :paused)},
        {"continue", %{kind: :continue, person_id: "person", run_deadline: 60_000},
         verified(%{verified_person: "person"}), &(&1.phase == :waiting)},
        {"cancel", %{kind: :cancel, attempt_id: "attempt"}, verified(),
         &(&1.slots[{1, 0}].phase == :settled)}
      ]

      for fault <- @faults do
        c =
          fixture(
            pattern: {TestPattern, :step, %{requests: [request([action("ask", "ask_person")])]}}
          )

        {engine, store} = start_faulty(c)
        assert {:ok, :applied} = send_input(engine)

        for {id, command, context, applied?} <- controls do
          before = rows(c)
          ReadFaultStore.fail_next_scan(store, fault)

          assert {:error, :unavailable} = RunEngine.control(engine, id, command, context)
          refute ReadFaultStore.armed?(store)
          assert rows(c) == before
          assert Process.alive?(engine)
          assert view(engine).reconciliation == nil

          assert {:ok, :applied} = RunEngine.control(engine, id, command, context)
          assert id in input_ids(c)
          assert applied?.(view(engine))
        end
      end
    end
  end

  describe "settled_retry_lookup_fails" do
    test "a failed admission lookup of a settled retry gives unavailable and commits nothing; cleared, it is a duplicate" do
      Process.register(self(), :run_engine_observer)
      b1 = %{action("b1", "tool_call") | "schema_id" => "b.call"}
      c = fixture(pattern: {TestPattern, :scripted, %{name: "root", script: [request([b1])]}})

      # A schema map: the expected result of the action is read from its admission once
      # its slot settled and its request left the state.
      changes = %{id: "bind-b", version: 5, result: {"b.result", 1}}
      binding = Map.merge(c.opts[:bindings]["tool_call"], changes)

      bindings = Map.put(c.opts[:bindings], "tool_call", %{"b.call" => binding})

      schemas =
        Map.merge(
          c.opts[:schemas],
          Map.new([schema_entry("b.call", %{"type" => "object"}), schema_entry("b.result", %{})])
        )

      {engine, store} = start_faulty(c, bindings: bindings, schemas: schemas)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, provider, _}, 5_000

      # An outcome with another schema than the binding's result is recorded as a refusal.
      outcome = result("b1")
      context = verified(%{occurrence: {1, 0}, actual: 1, dispatch: "dispatched"})
      assert {:ok, :applied} = RunEngine.input(engine, "outcome-b1", outcome, context)

      assert_receive {:pattern_input, "root",
                      %{"action_id" => "b1", "payload" => %{"reason" => "invalid_outcome"}}}

      assert view(engine).slots[{1, 0}].phase == :settled
      assert snapshot(c).requests == %{}
      before = rows(c)

      for fault <- @faults do
        # The lookup of the input ID reads; the second lookup, of the admission, fails.
        ReadFaultStore.fail_next_scan(store, fault, 1)
        assert {:error, :unavailable} = RunEngine.input(engine, "outcome-b1", outcome, context)
        refute ReadFaultStore.armed?(store)
        assert rows(c) == before
        assert view(engine).reconciliation == nil
      end

      assert {:ok, :duplicate} = RunEngine.input(engine, "outcome-b1", outcome, context)
      assert rows(c) == before
      send(provider, {:result, %{}})
    end
  end

  describe "winner_read_fails" do
    test "after input_id_conflict a failed read of the winner halts unavailable; a winner read equal is taken" do
      for fault <- @faults do
        {c, engine, store} = conflict(&run_view/2, fault)
        before = rows(c)

        assert {:error, :unavailable} = RunEngine.input(engine, "after", wake(), verified())
        refute ReadFaultStore.armed?(store)
        assert view(engine).reconciliation == :unavailable
        assert Process.alive?(engine)
        assert rows(c) == before
        # The storage halt answers every later call until a host restart.
        assert {:error, :unavailable} = RunEngine.input(engine, "after", wake(), verified())
      end

      # The same conflict with the winner read: a Run view, equal on kind, request and
      # occurrence, is taken.
      {c, engine, _} = conflict(&run_view/2)
      assert {:ok, :applied} = RunEngine.input(engine, "after", wake(), verified())
      assert view(engine).reconciliation == nil
      assert "after" in input_ids(c)
    end
  end

  describe "winner_contradicts" do
    test "a complete scan with no winner halts integrity_failure" do
      {c, engine, store} = conflict(&run_view/2, :without_winner)
      before = rows(c)

      assert {:error, :integrity_failure} = RunEngine.input(engine, "after", wake(), verified())
      refute ReadFaultStore.armed?(store)
      assert view(engine).reconciliation == :integrity_failure
      assert rows(c) == before
    end

    test "a winner of another kind, request or occurrence halts integrity_failure" do
      # Kind: a protocol input under the ID of the engine's Run view.
      {_, engine, _} = conflict(fn id, _ -> protocol_record(id, wake()) end)
      assert {:error, :integrity_failure} = RunEngine.input(engine, "after", wake(), verified())
      assert view(engine).reconciliation == :integrity_failure

      # Request: the gate record of request 2 names request 1. Occurrence: the admission
      # of occurrence {2, 0} names {1, 0}. Both change nothing in the state they meet.
      gate = %{
        version: 1,
        kind: :gate,
        schema_id: "elzoo.run-engine.gate-verdict",
        schema_version: 1,
        request: 1,
        entries: [],
        at_ms: 2_000
      }

      admission = %{version: 1, kind: :admission, occurrence: {1, 0}, facts: %{}, at_ms: 2_000}

      for {id, winner} <- [
            {fn prefix -> stable_id("gate:", {1, {prefix, "run"}, 2}) end, gate},
            {fn _ -> stable_id("admit:", {"run", {2, 0}}) end, admission}
          ] do
        c =
          fixture(
            pattern:
              {TestPattern, :step,
               %{
                 requests: [
                   request([action("first", "ask_person")]),
                   request([action("second", "ask_person")])
                 ]
               }}
          )

        engine = start(c)
        assert {:ok, :applied} = send_input(engine)
        assert view(engine).slots[{1, 0}].phase == :waiting
        {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
        assert {:ok, :applied} = DurableUnit.step(unit, id.(c.prefix), winner)

        answer =
          result("first")
          |> Map.put("kind", "person_answer")
          |> Map.put("person_id", "person")
          |> Map.delete("outcome")

        # The answer applies; request 2 follows, and its record meets the winner.
        assert {:error, :integrity_failure} =
                 RunEngine.input(
                   engine,
                   "answer",
                   answer,
                   verified(%{occurrence: {1, 0}, verified_person: "person", actual: 0})
                 )

        assert view(engine).reconciliation == :integrity_failure
      end
    end
  end

  # The engine reads its journal through the fault Store; the Unit writes through the
  # plain one.
  defp start_faulty(c, overrides \\ []) do
    store = ReadFaultStore.new(c.store)
    {start(c, Keyword.put(overrides, :store, store)), store}
  end

  # The engine has a Run view to commit under "run:<revision>" at its next call, and
  # `winner.(id, earlier_revision)` is already committed under that ID, so
  # DurableUnit.step/3 answers :input_id_conflict and the engine reads the winner (after
  # `fault`, if any). The winner leaves the Run revision of the state below the owner's,
  # so the engine commits its Run view whatever state it holds.
  defp conflict(winner, fault \\ nil) do
    c = fixture()
    {engine, store} = start_faulty(c)
    assert {:ok, :applied} = send_input(engine)
    {:ok, owner} = Run.status(c.run, "run")
    id = "run:#{move_owner_revision(c, "other")}"
    {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
    assert {:ok, :applied} = DurableUnit.step(unit, id, winner.(id, owner.revision))

    case fault do
      nil -> :ok
      :without_winner -> ReadFaultStore.fail_next_scan(store, {:without, id})
      fault -> ReadFaultStore.fail_next_scan(store, fault)
    end

    {c, engine, store}
  end

  # A Run view record of `revision` (under any ID), as the engine writes it.
  defp run_view(_id, revision) do
    %{
      version: 1,
      kind: :run_view,
      view: %{
        id: "run",
        operation_id: "operation",
        current_attempt: "attempt",
        revision: revision,
        outcome: nil,
        at_ms: 2_000
      }
    }
  end

  # A command for another Run on the shared owner moves the owner revision.
  defp move_owner_revision(c, other) do
    {:ok, owner} = Run.status(c.run, "run")

    {:ok, revision, _} =
      Run.command(c.run, %{
        kind: :create,
        run_id: other,
        operation_id: "operation-" <> other,
        provider_refs: %{},
        expected_revision: owner.revision
      })

    revision
  end

  # The IDs of the journal's input records, in commit order.
  defp input_ids(c) do
    for row <- rows(c), row.kind == "input" do
      {1, {id, _}} = :erlang.binary_to_term(row.payload, [:safe])
      id
    end
  end

  defp snapshot(c) do
    {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
    DurableUnit.snapshot(unit)
  end

  defp schema_entry(id, schema) do
    port = %{"id" => id, "direction" => "input", "schema_id" => id, "schema_version" => 1}
    {:ok, compiled} = PayloadSchema.build(port, schema)

    {{id, 1},
     %{port: port, compiled: compiled, digest: :crypto.hash(:sha256, Jason.encode!(schema))}}
  end

  # The engine's internal record IDs (its stable_id/2).
  defp stable_id(prefix, value) do
    bytes = :erlang.term_to_binary(value, [:deterministic, {:minor_version, 2}])
    prefix <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end
end
