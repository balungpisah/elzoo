## SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)

defmodule Elzoo.RunEngineTranscriptTest do
  use ExUnit.Case, async: false
  import Elzoo.RunEngine.TestHelper
  alias Elzoo.{DurableLog, DurableUnit, DynamicUnits, RunEngine}
  alias Elzoo.RunApprovalRelease, as: Run
  alias Elzoo.RunEngine.TestPattern

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

  @policy %{id: "policy", version: 1, content_hash: <<0::256>>}

  describe "nested_tree" do
    test "a completed two-level nested Run gives each path, nested start and finish, settlement and the terminal outcome in commit order" do
      {c, engine, provider} = nested_run()
      send(provider, {:result, %{}})
      {:ok, transcript} = transcript(engine)
      assert transcript.run_id == "run"
      entries = transcript.entries

      assert Enum.map(entries, &brief/1) == [
               {:input, "start", 2_000},
               {:gate, {1, 0}, :allow, 2_000},
               {:action, {1, 0}, [], "nested_callable", "nested", 2_000},
               {:authorization, {1, 0}, :allow, 2_000},
               {:nested_start, {1, 0}, 2_000},
               {:gate, {2, 0}, :allow, 2_000},
               {:action, {2, 0}, [{1, 0}], "nested_callable", "inner", 2_000},
               {:authorization, {2, 0}, :allow, 2_000},
               {:nested_start, {2, 0}, 2_000},
               {:gate, {3, 0}, :allow, 2_000},
               {:action, {3, 0}, [{1, 0}, {2, 0}], "tool_call", "slow", 2_000},
               {:authorization, {3, 0}, :allow, 2_000},
               {:input, "action_outcome", 3_000},
               {:settlement, {3, 0}, [{1, 0}, {2, 0}], "completed", :protocol, nil, 7, 3_000},
               {:gate, {4, 0}, :allow, 3_000},
               {:action, {4, 0}, [{1, 0}, {2, 0}], "finish", "inner-done", 3_000},
               {:authorization, {4, 0}, :allow, 3_000},
               {:nested_finish, {2, 0}, nil},
               {:input, "action_outcome", 3_000},
               {:settlement, {4, 0}, [{1, 0}, {2, 0}], "completed", :protocol, "finished", 0,
                3_000},
               {:input, "action_outcome", 3_000},
               {:settlement, {2, 0}, [{1, 0}], "completed", :protocol, nil, 7, 3_000},
               {:gate, {5, 0}, :allow, 3_000},
               {:action, {5, 0}, [{1, 0}], "finish", "mid", 3_000},
               {:authorization, {5, 0}, :allow, 3_000},
               {:nested_finish, {1, 0}, nil},
               {:input, "action_outcome", 3_000},
               {:settlement, {5, 0}, [{1, 0}], "completed", :protocol, "finished", 0, 3_000},
               {:input, "action_outcome", 3_000},
               {:settlement, {1, 0}, [], "completed", :protocol, nil, 7, 3_000},
               {:gate, {6, 0}, :allow, 3_000},
               {:action, {6, 0}, [], "finish", "finish", 3_000},
               {:authorization, {6, 0}, :allow, 3_000},
               {:settlement, {6, 0}, [], "completed", :finish, nil, 0, 3_000},
               {:terminal, :completed, 3_000}
             ]

      seen = %{"accepted" => true}

      assert [
               %{schema_id: "message", schema_version: 1, payload: %{"value" => 7}},
               %{schema_id: "message", schema_version: 1, payload: %{"value" => 7}}
             ] = Enum.filter(entries, &(&1.type == :nested_start))

      assert [
               %{schema_id: "result", schema_version: 1, payload: %{"seen" => ^seen}},
               %{schema_id: "result", schema_version: 1, payload: %{"seen" => %{"seen" => ^seen}}}
             ] = Enum.filter(entries, &(&1.type == :nested_finish))

      assert %{
               attempt_id: "attempt",
               schema_id: "result",
               schema_version: 1,
               payload: %{"action_id" => "nested"}
             } = Enum.find(entries, &(&1.type == :action and &1.action_id == "finish"))

      for entry <- entries, entry.type == :authorization, do: assert(entry.policy == @policy)

      for entry <- entries, entry.type == :gate do
        assert {entry.reason, entry.gate_id, entry.gate_version} == {nil, "gate", 1}
      end

      # Commit order: each entry names the input row of its record; its result is next.
      sequences = Enum.map(entries, & &1.sequence)
      assert sequences == Enum.sort(sequences)
      by_sequence = Map.new(rows(c), &{&1.sequence, &1.kind})

      for sequence <- sequences,
          do: assert({by_sequence[sequence], by_sequence[sequence + 1]} == {"input", "result"})

      inputs = for entry <- entries, entry.type == :input, do: entry.input_id
      assert hd(inputs) == "start"
      assert inputs -- Enum.uniq(inputs) == []
    end
  end

  describe "ask_paused" do
    test "a Run paused at an ASK returns its entries so far: the ask verdict with its policy and no settlement" do
      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("publish", "tool_call")])]}}
        )

      require_approval(c)
      engine = start(c, result_reader: reader(c))
      assert {:ok, :applied} = send_input(engine)
      assert view(engine).slots[{1, 0}].phase == :approval
      {:ok, %{approvals: [_]}} = Run.status(c.run, "run")
      {:ok, %{entries: entries}} = transcript(engine)

      assert Enum.map(entries, &brief/1) == [
               {:input, "start", 2_000},
               {:gate, {1, 0}, :allow, 2_000},
               {:action, {1, 0}, [], "tool_call", "publish", 2_000},
               {:authorization, {1, 0}, :ask, 2_000}
             ]

      assert List.last(entries).policy == @policy
    end
  end

  describe "unknown_and_attempt_closed" do
    test "an Effect made unknown by a restart settles unknown with no actual" do
      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("publish", "tool_call")])]}}
        )

      engine = start(c, result_reader: reader(c))
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, task, _}
      GenServer.stop(engine)
      Agent.update(c.host_mode, fn _ -> :recover end)
      Agent.update(c.clock, fn _ -> 2_500 end)
      engine = start(c, result_reader: reader(c))
      assert view(engine).slots[{1, 0}].outcome == "unknown"
      send(task, {:result, %{}})
      {:ok, %{entries: entries}} = transcript(engine)

      assert [settlement] = Enum.filter(entries, &(&1.type == :settlement))

      assert %{
               occurrence: {1, 0},
               path: [],
               action_id: "publish",
               outcome: "unknown",
               actual: :unknown,
               at_ms: 2_500
             } = settlement

      refute Enum.any?(entries, &(&1.type == :actual))
    end

    test "a change of Attempt closes the open slots of the older Attempt in its run_view with no reason" do
      c =
        fixture(
          pattern:
            {TestPattern, :step,
             %{requests: [request([action("publish", "tool_call"), action("ask", "ask_person")])]}}
        )

      engine = start(c, result_reader: reader(c))
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, task, _}
      assert view(engine).slots[{1, 1}].phase == :waiting
      Agent.update(c.clock, fn _ -> 2_700 end)

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "attempt-second",
                 %{kind: :begin_attempt, attempt_id: "second"},
                 verified()
               )

      send(task, {:result, %{}})
      {:ok, %{entries: entries}} = transcript(engine)

      assert for(entry <- entries, entry.type == :settlement, do: brief(entry)) == [
               {:settlement, {1, 0}, [], "unknown", :run_view, nil, :unknown, 2_700},
               {:settlement, {1, 1}, [], "unknown", :run_view, nil, :unknown, 2_700}
             ]
    end
  end

  describe "later_actual" do
    test "a parent settled with no actual gets an actual entry when its child's cost arrives later" do
      {c, bindings} = nested_setup(%{"nested" => [request([action("slow", "tool_call")])]})
      nested = bindings["nested_callable"]

      bindings =
        Map.put(bindings, "nested_callable", %{
          nested
          | facts: fn a -> %{nested.facts.(a) | deadline_ms: 10_000} end
        })

      engine = start(c, bindings: bindings, result_reader: reader(c))
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, provider, _}
      Agent.update(c.clock, fn _ -> 15_000 end)
      assert {:ok, _} = RunEngine.input(engine, "wake", wake(), verified())
      assert view(engine).slots[{1, 0}].outcome == "expired"
      Agent.update(c.clock, fn _ -> 16_000 end)

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "slow-result",
                 result("slow"),
                 verified(%{occurrence: {2, 0}, actual: 5, dispatch: "dispatched"})
               )

      wait_for(engine, fn _ ->
        {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
        DurableUnit.snapshot(unit).slots[{1, 0}][:actual] == 5
      end)

      send(provider, {:result, %{}})
      {:ok, %{entries: entries}} = transcript(engine)
      from_wake = Enum.drop_while(entries, &(Map.get(&1, :input_id) != "wake"))

      assert Enum.map(from_wake, &brief/1) == [
               {:input, "wake", 15_000},
               {:settlement, {1, 0}, [], "expired", :protocol, nil, :unknown, 15_000},
               {:input, "action_outcome", 16_000},
               {:settlement, {2, 0}, [{1, 0}], "completed", :protocol, nil, 5, 16_000},
               {:actual, {1, 0}, 5, 16_000}
             ]

      [actual] = Enum.filter(entries, &(&1.type == :actual))
      assert {:ok, [input, _result], _} = DurableLog.read(c.store, c.prefix, actual.sequence, 2)
      assert {1, {_, %{kind: :nested_actual}}} = :erlang.binary_to_term(input.payload, [:safe])
    end
  end

  describe "outside_event_wait" do
    test "a native v2 outside-event wait shows its action, the outside-event input and its settlement" do
      ticket = start_supervised!({Agent, fn -> nil end}, id: make_ref())

      source = %{
        id: "events",
        version: 1,
        head: fn _ -> {:ok, %{revision: 0, low_water: 0}} end,
        read: fn _, event_id ->
          {:ok,
           %{
             head: %{revision: 1, low_water: 0},
             event: %{
               id: event_id,
               source_id: "events",
               correlation_id: Agent.get(ticket, & &1),
               sequence: 1,
               schema_id: "result",
               schema_version: 1,
               payload: %{"accepted" => true}
             }
           }}
        end
      }

      requests = [
        request_v2([action("wait", "wait_event")]),
        request_v2([finish_action("finish", %{"action_id" => "wait"})])
      ]

      c =
        fixture(
          protocol_version: 2,
          event_source: source,
          pattern: {TestPattern, :step, %{requests: requests}}
        )

      engine = start(c)
      assert {:ok, :applied} = RunEngine.input(engine, "start", start_input_v2(), verified())
      {:ok, %{waits: [wait]}} = RunEngine.event_waits(engine, scope(), limits())
      Agent.update(ticket, fn _ -> wait.correlation_id end)
      Agent.update(c.clock, fn _ -> 3_000 end)

      event = %{
        "type" => "input",
        "version" => 2,
        "kind" => "outside_event",
        "action_id" => "wait",
        "source_id" => "events",
        "correlation_id" => wait.correlation_id,
        "event_id" => "accepted-event",
        "schema_id" => "result",
        "schema_version" => 1,
        "payload" => %{"accepted" => true}
      }

      context = verified(%{occurrence: wait.occurrence, actual: 0, dispatch: "not_dispatched"})
      assert {:ok, :applied} = RunEngine.input(engine, "accepted-event", event, context)
      wait_for(engine, &(&1.outcome == :completed))
      {:ok, %{entries: entries}} = transcript(engine)

      assert Enum.map(entries, &brief/1) == [
               {:input, "start", 2_000},
               {:gate, {1, 0}, :allow, 2_000},
               {:action, {1, 0}, [], "wait_event", "wait", 2_000},
               {:authorization, {1, 0}, :allow, 2_000},
               {:input, "outside_event", 3_000},
               {:settlement, {1, 0}, [], "completed", :protocol, nil, 0, 3_000},
               {:gate, {2, 0}, :allow, 3_000},
               {:action, {2, 0}, [], "finish", "finish", 3_000},
               {:authorization, {2, 0}, :allow, 3_000},
               {:settlement, {2, 0}, [], "completed", :finish, nil, 0, 3_000},
               {:terminal, :completed, 3_000}
             ]

      assert Enum.find(entries, &(&1.type == :input and &1.kind == "outside_event")).input_id ==
               "accepted-event"
    end
  end

  describe "gate_denial" do
    test "a gate denial shows the deny verdict and the refusal reason with no action entry" do
      gate = %{
        id: "gate",
        version: 1,
        call: fn {:PatternStep, %{"actions" => [a]}}, _ ->
          if a["id"] == "denied", do: {:deny, "restricted"}, else: :allow
        end
      }

      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("ok"), action("denied")])]}}
        )

      engine = start(c, gate: gate, result_reader: reader(c))
      assert {:ok, :applied} = send_input(engine)
      wait_for(engine, &(&1.slots[{1, 1}].phase == :settled))
      {:ok, %{entries: entries}} = transcript(engine)
      denied = Enum.filter(entries, &(Map.get(&1, :occurrence) == {1, 1}))

      assert Enum.map(denied, &brief/1) == [
               {:gate, {1, 1}, :deny, 2_000},
               {:settlement, {1, 1}, [], "refused", :protocol, "restricted", 0, 2_000}
             ]

      assert hd(denied).reason == "restricted"
      assert Enum.any?(entries, &(&1.type == :action and &1.occurrence == {1, 0}))
    end

    test "an engine refusal committed after another slot's deadline settles both: only the refused slot has a reason" do
      # Y (ask_person, deadline 30,000) waits in the root. The nested child asks X; its
      # gate moves the clock past Y's deadline and denies X, so the engine's refusal
      # record of X is the first protocol record after that deadline.
      clock = start_supervised!({Agent, fn -> 2_000 end}, id: make_ref())

      gate = %{
        id: "gate",
        version: 1,
        call: fn {:PatternStep, %{"actions" => [a]}}, _ ->
          if a["id"] == "x" do
            Agent.update(clock, fn _ -> 35_000 end)
            {:deny, "restricted"}
          else
            :allow
          end
        end
      }

      {c, bindings} =
        nested_setup(
          %{"nested" => [request([action("x")])]},
          pattern:
            {TestPattern, :scripted,
             %{
               name: "root",
               script: [request([action("y", "ask_person"), action("nested", "nested_callable")])]
             }}
        )

      person = bindings["ask_person"]

      bindings =
        Map.put(bindings, "ask_person", %{
          person
          | facts: fn a -> %{person.facts.(a) | deadline_ms: 30_000} end
        })

      engine =
        start(c,
          bindings: bindings,
          gate: gate,
          clock: fn -> Agent.get(clock, & &1) end,
          result_reader: reader(c)
        )

      assert {:ok, :applied} = send_input(engine)
      wait_for(engine, &(&1.slots[{2, 0}][:phase] == :settled))
      {:ok, %{entries: entries}} = transcript(engine)

      x = Enum.find(entries, &(&1.type == :settlement and &1.action_id == "x"))
      y = Enum.find(entries, &(&1.type == :settlement and &1.action_id == "y"))
      assert x.sequence == y.sequence
      assert {x.outcome, x.reason, x.path, x.at_ms} == {"refused", "restricted", [{1, 1}], 35_000}
      assert {y.outcome, y.reason, y.path, y.at_ms} == {"expired", nil, [], 35_000}
      refute Enum.any?(entries, &(&1.type == :action and &1.action_id == "x"))
      refute Enum.any?(entries, &(&1.type == :settlement and &1.action_id == "nested"))
    end
  end

  describe "earlier_run" do
    test "a Unit holding an earlier Run returns only the scoped Run, also with a late input of the earlier Run" do
      c = fixture(pattern: {TestPattern, :step, %{requests: [request([action("first")])]}})
      engine = start(c, result_reader: reader(c))
      assert {:ok, :applied} = send_input(engine)
      wait_for(engine, &(&1.slots[{1, 0}].phase == :settled))
      {:ok, run} = Run.status(c.run, "run")

      assert {:ok, _, _} =
               Run.command(c.run, %{
                 kind: :complete,
                 run_id: "run",
                 attempt_id: "attempt",
                 outcome: :failed,
                 reason: "test",
                 evidence_ref: nil,
                 expected_revision: run.revision
               })

      GenServer.stop(engine)
      engine = start(c, result_reader: reader(c))
      assert view(engine).phase == :terminal
      GenServer.stop(engine)
      {:ok, ended} = Run.status(c.run, "run")

      assert {:ok, revision, _} =
               Run.command(c.run, %{
                 kind: :create,
                 run_id: "period-two",
                 operation_id: "operation-two",
                 provider_refs: %{},
                 expected_revision: ended.revision
               })

      assert {:ok, _, _} =
               Run.command(c.run, %{
                 kind: :begin_attempt,
                 run_id: "period-two",
                 attempt_id: "third",
                 expected_revision: revision
               })

      next = {TestPattern, :step, %{requests: [request([action("again")])]}}
      engine = start(c, run_id: "period-two", pattern: next, result_reader: reader(c))
      before_late = length(rows(c))

      assert {:ok, _} =
               RunEngine.input(
                 engine,
                 "late-first",
                 result("first"),
                 verified(%{occurrence: {1, 0}, actual: 0, dispatch: "dispatched"})
               )

      assert length(rows(c)) == before_late + 2
      late = Enum.find(rows(c), &(&1.sequence == before_late + 1))

      assert {1, {"late-first", %{kind: :protocol, run_id: "run"}}} =
               :erlang.binary_to_term(late.payload, [:safe])

      # The new Run is configured before the late input of the earlier Run.
      assert Enum.any?(rows(c), fn row ->
               row.sequence < late.sequence and row.kind == "input" and
                 match?(
                   {1, {_, %{kind: :configure, control: %{run_id: "period-two"}}}},
                   :erlang.binary_to_term(row.payload, [:safe])
                 )
             end)

      context = verified(%{run_id: "period-two", attempt_id: "third"})
      assert {:ok, :applied} = RunEngine.input(engine, "period-two-input", start_input(), context)
      wait_for(engine, &(&1.slots[{1, 0}].phase == :settled))
      period_two = %{tenant: "tenant", principal: "principal", run_id: "period-two"}
      assert {:ok, transcript} = RunEngine.transcript(engine, period_two, limits())
      assert transcript.run_id == "period-two"

      assert Enum.map(transcript.entries, &brief/1) == [
               {:input, "start", 2_000},
               {:gate, {1, 0}, :allow, 2_000},
               {:action, {1, 0}, [], "local_work", "again", 2_000},
               {:authorization, {1, 0}, :allow, 2_000},
               {:input, "action_outcome", 2_000},
               {:settlement, {1, 0}, [], "completed", :protocol, nil, 1, 2_000}
             ]

      assert hd(transcript.entries).input_id == "period-two-input"
      assert hd(transcript.entries).sequence > before_late + 2
      assert Enum.all?(transcript.entries, &(Map.get(&1, :attempt_id, "third") == "third"))
    end
  end

  describe "scope_limits_reader" do
    test "wrong scope, malformed limits and no reader fail before any Run-owner or Store read" do
      c = fixture(pattern: {TestPattern, :step, %{requests: [request([action("work")])]}})
      engine = start(c, result_reader: reader(c))
      assert {:ok, :applied} = send_input(engine)
      wait_for(engine, &(&1.slots[{1, 0}].phase == :settled))

      assert_no_owner_or_store_read(engine, fn ->
        for scope <- [
              %{scope() | tenant: "other"},
              %{scope() | principal: "other"},
              %{scope() | run_id: "other"},
              Map.put(scope(), :extra, true),
              Map.delete(scope(), :tenant),
              nil
            ] do
          assert {:error, :scope} = RunEngine.transcript(engine, scope, limits())
        end

        for invalid <- [
              nil,
              %{max_records: 1},
              %{max_bytes: 1},
              %{max_records: 1, max_bytes: 1, extra: true},
              %{max_records: 0, max_bytes: 1},
              %{max_records: 65_537, max_bytes: 1},
              %{max_records: 1.5, max_bytes: 1},
              %{max_records: 1, max_bytes: 0},
              %{max_records: 1, max_bytes: 536_870_913}
            ] do
          assert {:error, :invalid_limits} = RunEngine.transcript(engine, scope(), invalid)
        end
      end)

      unconfigured = fixture(pattern: {TestPattern, :step, %{requests: []}})
      bare = start(unconfigured)
      assert {:ok, :applied} = send_input(bare)

      assert_no_owner_or_store_read(bare, fn ->
        assert {:error, :reader_unconfigured} = RunEngine.transcript(bare, scope(), limits())
      end)
    end
  end

  describe "read_bounds" do
    test "exact limits succeed and one record or byte less is read_limit; pruned is history and unavailable is unavailable" do
      c =
        fixture(
          unit_store: memory_unit_store(),
          pattern: {TestPattern, :step, %{requests: [request([action("work")])]}}
        )

      engine = start(c, result_reader: reader(c))
      assert {:ok, :applied} = send_input(engine)
      wait_for(engine, &(&1.slots[{1, 0}].phase == :settled))
      retained = rows(c)
      bytes = Enum.sum(Enum.map(retained, &:erlang.iolist_size(DurableLog.canonical_bytes(&1))))
      exact = %{max_records: length(retained), max_bytes: bytes}

      assert {:ok, %{entries: entries}} = RunEngine.transcript(engine, scope(), exact)
      assert {:ok, %{entries: ^entries}} = transcript(engine)

      assert {:error, :read_limit} =
               RunEngine.transcript(engine, scope(), %{exact | max_records: length(retained) - 1})

      assert {:error, :read_limit} =
               RunEngine.transcript(engine, scope(), %{exact | max_bytes: bytes - 1})

      assert :ok = DurableLog.Memory.fault(c.store, :read, :unavailable)
      assert {:error, :unavailable} = transcript(engine)
      assert {:ok, %{entries: ^entries}} = transcript(engine)

      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
      assert {:committed, _} = DurableUnit.checkpoint(unit)
      through = length(retained)

      assert {:committed, ^through} =
               DurableLog.Memory.retain(
                 c.store,
                 c.prefix,
                 0,
                 through,
                 :crypto.strong_rand_bytes(16)
               )

      assert {:error, :history} = transcript(engine)
    end
  end

  describe "read_only" do
    test "reads change no stream head and call no callback, and two reads are equal" do
      calls = start_supervised!({Agent, fn -> %{} end}, id: make_ref())
      count = fn name -> Agent.update(calls, &Map.update(&1, name, 1, fn n -> n + 1 end)) end
      {c, engine, provider} = nested_run(calls: count)
      send(provider, {:result, %{}})
      flush_pattern_inputs()
      unit_before = DurableLog.read(c.store, c.prefix, 1, 1_000)
      evidence_before = DurableLog.read(c.evidence_store, "evidence", 1, 1_000)
      {:ok, owner_before} = Run.status(c.run, "run")
      calls_before = Agent.get(calls, & &1)
      assert map_size(calls_before) > 0

      {:ok, first} = transcript(engine)
      {:ok, second} = transcript(engine)
      assert first == second

      refute_receive {:pattern_input, _, _}, 100
      assert Agent.get(calls, & &1) == calls_before
      assert DurableLog.read(c.store, c.prefix, 1, 1_000) == unit_before
      assert DurableLog.read(c.evidence_store, "evidence", 1, 1_000) == evidence_before
      assert Run.status(c.run, "run") == {:ok, owner_before}
    end
  end

  # The root asks one nested_callable "nested", whose child asks "inner", whose child
  # asks the tool call "slow" and finishes with its result; "nested" finishes with what
  # it saw and the root finishes with "nested". The tool result arrives at 3,000.
  defp nested_run(opts \\ []) do
    count = Keyword.get(opts, :calls, fn _ -> :ok end)

    {c, bindings} =
      nested_setup(
        %{
          "nested" => [request([action("inner", "nested_callable")]), {:finish_with_seen, "mid"}],
          "inner" => [request([action("slow", "tool_call")]), {:finish_with_seen, "inner-done"}]
        },
        pattern:
          {TestPattern, :scripted,
           %{
             name: "root",
             script: [
               request([action("nested", "nested_callable")]),
               request([finish_action("finish", %{"action_id" => "nested"})])
             ]
           }}
      )

    gate = %{id: "gate", version: 1, call: fn _, _ -> count.(:gate) && :allow end}
    clock = fn -> count.(:clock) && Agent.get(c.clock, & &1) end

    engine =
      start(c,
        bindings: counted(bindings, count),
        gate: gate,
        clock: clock,
        result_reader: reader(c)
      )

    assert {:ok, :applied} = send_input(engine)
    assert_receive {:effect_started, provider, _}
    Agent.update(c.clock, fn _ -> 3_000 end)

    assert {:ok, :applied} =
             RunEngine.input(
               engine,
               "slow-result",
               result("slow"),
               verified(%{occurrence: {3, 0}, actual: 7, dispatch: "dispatched"})
             )

    wait_for(engine, &(&1.outcome == :completed))
    {c, engine, provider}
  end

  defp counted(bindings, count) do
    Map.new(bindings, fn {kind, binding} ->
      {kind,
       Enum.reduce([:facts, :proposal, :work, :person, :nested], binding, fn field, acc ->
         case Map.get(acc, field) do
           fun when is_function(fun, 1) ->
             Map.put(acc, field, fn argument -> count.({:binding, field}) && fun.(argument) end)

           _ ->
             acc
         end
       end)}
    end)
  end

  defp flush_pattern_inputs do
    receive do
      {:pattern_input, _, _} -> flush_pattern_inputs()
    after
      0 -> :ok
    end
  end

  defp brief(%{type: :input} = e), do: {:input, e.kind, e.at_ms}
  defp brief(%{type: :gate} = e), do: {:gate, e.occurrence, e.verdict, e.at_ms}

  defp brief(%{type: :action} = e),
    do: {:action, e.occurrence, e.path, e.kind, e.action_id, e.at_ms}

  defp brief(%{type: :authorization} = e), do: {:authorization, e.occurrence, e.verdict, e.at_ms}
  defp brief(%{type: :nested_start} = e), do: {:nested_start, e.occurrence, e.at_ms}
  defp brief(%{type: :nested_finish} = e), do: {:nested_finish, e.occurrence, e.at_ms}

  defp brief(%{type: :settlement} = e),
    do: {:settlement, e.occurrence, e.path, e.outcome, e.by, e.reason, e.actual, e.at_ms}

  defp brief(%{type: :actual} = e), do: {:actual, e.occurrence, e.actual, e.at_ms}
  defp brief(%{type: :terminal} = e), do: {:terminal, e.outcome, e.at_ms}

  defp assert_no_owner_or_store_read(engine, assertion) do
    patterns = [{Run, :status, 2}, {DurableLog, :read, 4}]
    for mfa <- patterns, do: :erlang.trace_pattern(mfa, true, [:global])
    :erlang.trace(engine, true, [:call])

    try do
      assertion.()
      delivered = :erlang.trace_delivered(engine)
      assert_receive {:trace_delivered, ^engine, ^delivered}, 5_000
      refute_received {:trace, ^engine, :call, _}
    after
      :erlang.trace(engine, false, [:call])
      for mfa <- patterns, do: :erlang.trace_pattern(mfa, false, [:global])
    end
  end

  defp memory_unit_store do
    options = [
      operator: {RunEngine, :step, %{version: 1, control: nil, slots: %{}, requests: %{}}},
      retention_count: 1_024,
      max_record_bytes: 16_777_216,
      max_checkpoint_bytes: 33_554_432
    ]

    pid =
      start_supervised!(%{
        id: make_ref(),
        start:
          {DurableLog.Memory, :start_link,
           [[fold: DurableUnit.fold(options), limits: DurableUnit.limits(options)]]}
      })

    DurableLog.Memory.store(pid)
  end

  defp transcript(engine), do: RunEngine.transcript(engine, scope(), limits())
  defp reader(c), do: %{evidence_store: c.evidence_store, retention_count: 1_024}
  defp scope, do: %{tenant: "tenant", principal: "principal", run_id: "run"}
  defp limits, do: %{max_records: 65_536, max_bytes: 536_870_912}
end
