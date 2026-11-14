# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)
Code.require_file("../../examples/document_publication.exs", __DIR__)

defmodule Elzoo.RunEngineTest.Work do
  # Work of a schema-map binding: it reports which binding's work ran, with the
  # payload of the action, and completes with that payload.
  def run(parent, tag, payload) do
    send(parent, {:work_ran, tag, payload})
    payload
  end
end

defmodule Elzoo.RunEngineTest do
  use ExUnit.Case, async: false
  import Elzoo.RunEngine.TestHelper
  alias Elzoo.{DurableUnit, DynamicUnits, PayloadSchema, RunEngine}
  alias Elzoo.EffectIntent.Binding
  alias Elzoo.RunEngine.{ChangedAccountBinding, TestBinding, TestPattern}
  alias Elzoo.RunEngineTest.Work
  alias Elzoo.RunEngine.DocumentPublication
  alias Elzoo.RunApprovalRelease, as: Run
  alias Elzoo.DurableLog.PostgresHarness

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

  describe "Recorded cycle and non-agent flow" do
    test "document publication uses typed nested validation, person, genuine consent and actual completion map" do
      document = %{"target" => "public", "title" => "Checked document"}
      c = fixture(pattern: {DocumentPublication, :step, %{stage: :validate, document: document}})
      require_approval(c)

      bindings =
        Map.update!(c.opts[:bindings], "nested_callable", fn binding ->
          binding =
            Map.put(binding, :facts, fn action -> Map.put(binding.facts.(action), :estimate, 2) end)

          Map.put(binding, :nested, fn action ->
            %{
              budget_id: "validation",
              incarnation: "sealed",
              mfa: {DocumentPublication, :validation},
              initial_state: :start,
              schema_id: "message",
              schema_version: 1,
              payload: action["payload"]
            }
          end)
        end)

      engine =
        start(c,
          bindings: bindings,
          gate: %{id: "publication", version: 1, call: &DocumentPublication.gate/2}
        )

      assert {:ok, :applied} = send_input(engine)

      waiting =
        wait_for(engine, fn v ->
          Enum.any?(v.slots, fn {_, s} -> s.action_id == "material" and s.phase == :waiting end)
        end)

      {person_key, _} = Enum.find(waiting.slots, fn {_, s} -> s.action_id == "material" end)

      answer =
        result("material", %{"citation" => "reviewed"})
        |> Map.delete("outcome")
        |> Map.merge(%{"kind" => "person_answer", "person_id" => "person"})

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "material",
                 answer,
                 verified(%{occurrence: person_key, verified_person: "person"})
               )

      {:ok, run} = Run.status(c.run, "run")
      [%{request_key: key}] = run.approvals
      refute_receive {:effect_started, _, _}

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "approve",
                 %{kind: :approval_evidence, request_key: key, evidence: consent(key)},
                 verified()
               )

      assert_receive {:effect_started, provider, req}

      assert Jason.decode!(req.arguments) ==
               Map.put(document, "material", %{"citation" => "reviewed"})

      {publication_key, _} =
        Enum.find(view(engine).slots, fn {_, s} -> s.action_id == "publication" end)

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "publication-result",
                 result("publication", %{"published" => true}),
                 verified(%{occurrence: publication_key, actual: 1, dispatch: "dispatched"})
               )

      # The host acknowledges only after this applied result.
      send(provider, {:result, %{"published" => true}})
      assert view(engine).outcome == :completed
      {:ok, evidence, _} = Elzoo.DurableLog.read(c.store, "evidence", 1, 10)
      [row] = evidence

      assert %{
               run_id: "run",
               operation_id: "operation",
               attempt_id: "attempt",
               action_id: "publication"
             } =
               :erlang.binary_to_term(row.payload, [:safe])

      assert {:ok, audit} = DocumentPublication.audit(c.store, c.prefix)
      assert map_size(audit.settlements) == 6
      assert map_size(audit.charges) == 6

      assert DocumentPublication.gate(
               {:PatternStep,
                %{"actions" => [action("restricted", "tool_call", %{"target" => "restricted"})]}},
               %{}
             ) == {:deny, "restricted_target"}
    end

    test "input precedes evaluation, zero output and stable retry preserve recorded time" do
      c = fixture()
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      Agent.update(c.clock, fn _ -> 3_001 end)
      assert {:ok, :duplicate} = send_input(engine)
      assert view(engine).request_count == 0
      assert length(rows(c)) == 4

      assert {:error, :input_id_conflict} =
               RunEngine.input(
                 engine,
                 "start",
                 put_in(start_input()["payload"], %{"different" => true}),
                 verified()
               )
    end

    test "missing cap refuses and invalid output charges without an action" do
      c = fixture()

      assert {:error, :invalid_options_or_recovery} =
               RunEngine.start_link(Keyword.delete(c.opts, :request_cap))

      engine = start(c, pattern: {TestPattern, :step, %{requests: [:invalid]}})
      assert {:ok, :applied} = send_input(engine)
      assert %{request_count: 1, slots: %{}, classification: :invalid_request} = view(engine)
    end
  end

  describe "Gate order and denial" do
    test "all schema-rejected occurrences consume identities but never call gate or reserve" do
      bad = Map.put(action("a"), "schema_id", "unknown")

      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([bad]), request([action("a")])]}}
        )

      engine =
        start(c,
          gate: %{
            id: "gate",
            version: 1,
            call: fn _, _ -> flunk("schema/identity rejection reached gate") end
          }
        )

      assert {:ok, :applied} = send_input(engine)
      v = view(engine)
      assert v.request_count == 2
      assert v.slots[{1, 0}].outcome == "refused"
      assert v.slots[{2, 0}].outcome == "refused"
      assert Enum.all?(v.joins, fn {_, join} -> join.closed and join.outcome == :failed end)
      assert {:ok, audit} = DocumentPublication.audit(c.store, c.prefix)
      assert audit.verdicts == %{}
      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)

      assert Enum.all?(DurableUnit.snapshot(unit).slots, fn {_, slot} ->
               not Map.has_key?(slot, :reservation)
             end)
    end

    test "denied sibling commits one refusal without reservation while allowed local completes" do
      c =
        fixture(
          pattern:
            {TestPattern, :step, %{requests: [request([action("denied"), action("allowed")])]}}
        )

      parent = self()

      gate = %{
        id: "gate",
        version: 1,
        call: fn {:PatternStep, map}, context ->
          [a] = map["actions"]
          send(parent, {:gate, a["id"], context})
          if a["id"] == "denied", do: {:deny, "restricted"}, else: :allow
        end
      }

      bindings =
        Map.update!(c.opts[:bindings], "local_work", fn binding ->
          Map.put(binding, :work, fn a ->
            {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
            state = DurableUnit.snapshot(unit)
            assert %{verdict: %{verdict: :allow}, phase: :ready} = state.slots[{1, 1}]
            {TestPattern, :work, [a["payload"]]}
          end)
        end)

      engine = start(c, gate: gate, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      view = wait_for(engine, fn v -> Enum.all?(v.slots, fn {_, s} -> s.phase == :settled end) end)
      assert view.slots[{1, 0}].outcome == "refused"
      assert view.slots[{1, 1}].outcome == "completed"
      assert view.joins[1] == %{closed: true, outcome: :partial}

      assert_receive {:gate, "denied",
                      %{tenant: "tenant", proposer: "principal", effect_class: "compute"}}

      assert_receive {:gate, "allowed", _}
      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
      state = DurableUnit.snapshot(unit)
      refute Map.has_key?(state.slots[{1, 0}], :reservation)

      assert {:Transition, _, {:some, {:status, %{committed: 1, reserved: 0}}}} =
               Elzoo.Budget.step(state.control.budgets["root"].state, {3_000, :status})
    end

    test "raise throw exit malformed and invalid reason fail closed" do
      for call <- [
            fn _, _ -> raise "private" end,
            fn _, _ -> throw(:private) end,
            fn _, _ -> exit(:private) end,
            fn _, _ -> :bad end,
            fn _, _ -> {:deny, "BAD"} end
          ] do
        c = fixture(pattern: {TestPattern, :step, %{requests: [request([action("a")])]}})
        engine = start(c, gate: %{id: "gate", version: 1, call: call})
        assert {:ok, :applied} = send_input(engine)
        assert view(engine).slots[{1, 0}].verdict.reason == "gate_failure"
        assert view(engine).joins[1].outcome == :failed
      end
    end
  end

  describe "Durable budget and nested share" do
    test "monetary exhaustion stops below the request cap without discarding the accepted result" do
      for rule <- [:pause, :finish] do
        c =
          fixture(
            pattern: {TestPattern, :step, %{requests: [request([action("cost", "tool_call")])]}},
            budget: %{cap: 1, unit: "credits", id: "budget", incarnation: "sealed"},
            budget_rule: rule
          )

        engine = start(c)
        assert {:ok, :applied} = send_input(engine)
        assert_receive {:effect_started, provider, _}

        assert {:ok, :applied} =
                 RunEngine.input(
                   engine,
                   "actual",
                   result("cost"),
                   verified(%{occurrence: {1, 0}, actual: 3, dispatch: "dispatched"})
                 )

        assert view(engine).slots[{1, 0}].outcome == "completed"
        assert view(engine).joins[1].closed
        assert view(engine).request_count == 1

        if rule == :finish do
          assert view(engine).outcome == :out_of_budget
        else
          assert view(engine).phase == :paused

          assert {:ok, :applied} =
                   RunEngine.control(
                     engine,
                     "continue-money",
                     %{kind: :continue, person_id: "person", run_deadline: 60_000},
                     verified(%{verified_person: "person"})
                   )

          assert view(engine).phase == :paused
        end

        send(provider, {:result, %{}})
      end
    end

    test "child finish does not release its parent share before outstanding actual cost" do
      c =
        fixture(
          pattern:
            {TestPattern, :step, %{requests: [request([action("nested", "nested_callable")])]}},
          budget: %{cap: 5, unit: "credits", id: "budget", incarnation: "sealed"}
        )

      base = c.opts[:bindings]["nested_callable"]

      nested = %{
        base
        | facts: fn a -> %{base.facts.(a) | estimate: 5} end,
          nested: fn a ->
            %{
              base.nested.(a)
              | initial_state: %{
                  requests: [
                    request([action("slow", "tool_call"), finish_action("finish-child")])
                  ]
                }
            }
          end
      }

      engine = start(c, bindings: Map.put(c.opts[:bindings], "nested_callable", nested))
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, provider, _}
      assert view(engine).slots[{1, 0}].phase == :running
      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
      budget = DurableUnit.snapshot(unit).control.budgets["root"].state

      assert {:Transition, _, {:some, {:status, %{committed: 0, reserved: 5}}}} =
               Elzoo.Budget.step(budget, {2_000, :status})

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "child-actual",
                 result("slow"),
                 verified(%{occurrence: {2, 0}, actual: 7, dispatch: "dispatched"})
               )

      assert view(engine).slots[{1, 0}].outcome == "completed"
      budget = DurableUnit.snapshot(unit).control.budgets["root"].state

      assert {:Transition, _, {:some, {:status, %{committed: 7, reserved: 0}}}} =
               Elzoo.Budget.step(budget, {2_000, :status})

      send(provider, {:result, %{}})
    end

    test "charge-stopped child propagates later actual without changing its settled parent outcome" do
      c =
        fixture(
          pattern:
            {TestPattern, :step, %{requests: [request([action("nested", "nested_callable")])]}},
          request_cap: 2,
          budget: %{cap: 5, unit: "credits", id: "budget", incarnation: "sealed"}
        )

      base = c.opts[:bindings]["nested_callable"]

      nested = %{
        base
        | facts: fn a -> %{base.facts.(a) | estimate: 5} end,
          nested: fn a ->
            %{
              base.nested.(a)
              | initial_state: %{
                  requests: [
                    request([action("slow", "tool_call"), action("person", "ask_person")]),
                    request([action("excess")])
                  ]
                }
            }
          end
      }

      engine = start(c, bindings: Map.put(c.opts[:bindings], "nested_callable", nested))
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, provider, _}

      answer = %{
        "type" => "input",
        "version" => 1,
        "kind" => "person_answer",
        "action_id" => "person",
        "person_id" => "person",
        "schema_id" => "message",
        "schema_version" => 1,
        "payload" => %{}
      }

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "person-answer",
                 answer,
                 verified(%{occurrence: {2, 1}, verified_person: "person", actual: 0})
               )

      assert view(engine).slots[{1, 0}].outcome == "out_of_budget"
      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
      budget = DurableUnit.snapshot(unit).control.budgets["root"].state

      assert {:Transition, _, {:some, {:status, %{committed: 0, reserved: 5}}}} =
               Elzoo.Budget.step(budget, {2_000, :status})

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "child-actual",
                 result("slow"),
                 verified(%{occurrence: {2, 0}, actual: 7, dispatch: "dispatched"})
               )

      assert view(engine).slots[{1, 0}].outcome == "out_of_budget"
      assert view(engine).request_count == 3
      budget = DurableUnit.snapshot(unit).control.budgets["root"].state

      assert {:Transition, _, {:some, {:status, %{committed: 7, reserved: 0}}}} =
               Elzoo.Budget.step(budget, {2_000, :status})

      send(provider, {:result, %{}})
    end

    test "sibling reservations cannot overspend; overage persists and unknown is never released as zero" do
      for {outcome, actual, committed, reserved} <- [
            {"completed", 3, 3, 0},
            {"unknown", nil, 0, 1},
            {"refused", 0, 0, 0}
          ] do
        c =
          fixture(
            pattern:
              {TestPattern, :step,
               %{
                 requests: [
                   request([
                     action("first", "tool_call"),
                     action("sibling", "tool_call")
                   ])
                 ]
               }},
            budget: %{cap: 1, unit: "credits", id: "budget", incarnation: "sealed"}
          )

        engine = start(c)
        assert {:ok, :applied} = send_input(engine)
        assert_receive {:effect_started, provider, _}
        assert view(engine).slots[{1, 1}].outcome == "out_of_budget"
        refute_receive {:effect_started, _, _}

        assert {:ok, :applied} =
                 RunEngine.input(
                   engine,
                   "settle",
                   Map.put(result("first"), "outcome", outcome),
                   verified(%{occurrence: {1, 0}, actual: actual, dispatch: "dispatched"})
                 )

        {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
        budget = DurableUnit.snapshot(unit).control.budgets["root"]

        assert {:Transition, _, {:some, {:status, %{committed: ^committed, reserved: ^reserved}}}} =
                 Elzoo.Budget.step(budget.state, {2_001, :status})

        GenServer.stop(engine)
        engine = start(c)
        assert view(engine).joins[1].closed
        assert DurableUnit.snapshot(unit).control.budgets["root"] == budget
        send(provider, {:result, %{}})
        refute_receive {:effect_started, _, _}
      end
    end

    test "room period needs a distinct explicit Run after settlement and retains lifetime capacity" do
      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("one")]), :invalid]}},
          request_cap: 1
        )

      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert wait_for(engine, &(&1.outcome == :out_of_budget)).request_count == 2
      GenServer.stop(engine)
      {:ok, old} = Run.status(c.run, "run")

      assert {:ok, revision, _} =
               Run.command(c.run, %{
                 kind: :create,
                 run_id: "period-two",
                 operation_id: "operation-two",
                 provider_refs: %{},
                 expected_revision: old.revision
               })

      assert {:ok, _, _} =
               Run.command(c.run, %{
                 kind: :begin_attempt,
                 run_id: "period-two",
                 attempt_id: "second",
                 expected_revision: revision
               })

      engine = start(c, run_id: "period-two")
      assert view(engine).request_count == 0
      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
      assert DurableUnit.snapshot(unit).control.lifetime == 1
      context = verified(%{run_id: "period-two", attempt_id: "second"})
      assert {:error, :input_id_conflict} = RunEngine.input(engine, "start", start_input(), context)
      assert {:ok, :applied} = RunEngine.input(engine, "period-two-input", start_input(), context)
      assert wait_for(engine, &(&1.outcome == :out_of_budget)).request_count == 2
      assert DurableUnit.snapshot(unit).control.lifetime == 2
    end

    test "sealed request charge and Budget generation survive Attempt changes and restart" do
      c = fixture(pattern: {TestPattern, :step, %{requests: [:invalid]}}, request_cap: 3)

      assert {:error, :invalid_options_or_recovery} =
               RunEngine.start_link(Keyword.delete(c.opts, :budget))

      engine = start(c)
      assert {:ok, :applied} = send_input(engine)

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "attempt-change",
                 %{kind: :begin_attempt, attempt_id: "second"},
                 verified()
               )

      assert view(engine).request_count == 1
      assert view(engine).attempt_id == "second"
      GenServer.stop(engine)
      engine = start(c)
      assert view(engine).request_count == 1

      assert {:error, :incompatible_recovery} =
               RunEngine.start_link(c.opts |> Keyword.delete(:name) |> Keyword.put(:request_cap, 4))

      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
      state = DurableUnit.snapshot(unit)

      assert {:Transition, _, {:some, {:status, %{generation: {"sealed", 1}, committed: 0}}}} =
               Elzoo.Budget.step(state.control.budgets["root"].state, {2_000, :status})
    end

    test "nested denial chain uses shared charge and settles its previously admitted parent" do
      root = request([action("nested", "nested_callable")])
      c = fixture(pattern: {TestPattern, :step, %{requests: [root]}}, request_cap: 3)
      base = c.opts[:bindings]["nested_callable"]

      bindings =
        Map.put(c.opts[:bindings], "nested_callable", %{
          base
          | nested: fn a ->
              %{base.nested.(a) | mfa: {TestPattern, :chain}, initial_state: 0}
            end
        })

      engine =
        start(c,
          bindings: bindings,
          gate: %{
            id: "gate",
            version: 1,
            call: fn {:PatternStep, m}, _ ->
              if hd(m["actions"])["kind"] == "nested_callable",
                do: :allow,
                else: {:deny, "restricted"}
            end
          }
        )

      assert {:ok, :applied} = send_input(engine)
      result = view(engine)
      assert result.request_count == 4
      assert result.outcome == :out_of_budget
      assert result.slots[{1, 0}].outcome == "out_of_budget"
      assert map_size(result.slots) == 5
      refute Map.has_key?(result.joins, 4)
    end

    test "deny-all chain charges every output then stops without excess actions" do
      c = fixture(pattern: {TestPattern, :chain, 0}, request_cap: 3)
      parent = self()

      engine =
        start(c,
          gate: %{
            id: "gate",
            version: 1,
            call: fn _, _ ->
              send(parent, :gate_sample)
              {:deny, "restricted"}
            end
          }
        )

      assert {:ok, :applied} = send_input(engine)
      view = view(engine)
      assert view.request_count == 4
      assert view.generation_closed
      assert view.outcome == :out_of_budget
      assert map_size(view.slots) == 6
      refute Map.has_key?(view.joins, 4)
      for _ <- 1..6, do: assert_receive(:gate_sample)
      refute_receive :gate_sample
      assert Enum.all?(view.slots, fn {_, s} -> s.phase == :settled end)
    end
  end

  describe "Person, pause, wake and termination" do
    test "a result accepted while paused reaches the pattern once after continue, including restart" do
      c =
        fixture(
          pattern:
            {TestPattern, :step,
             %{
               requests: [
                 request([action("answer", "ask_person")]),
                 request([action("after", "ask_person")])
               ]
             }}
        )

      engine = start(c)
      assert {:ok, :applied} = send_input(engine)

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "pause",
                 %{kind: :pause, pause_deadline: 50_000},
                 verified()
               )

      answer =
        result("answer")
        |> Map.put("kind", "person_answer")
        |> Map.put("person_id", "person")
        |> Map.delete("outcome")

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "answer",
                 answer,
                 verified(%{occurrence: {1, 0}, verified_person: "person", actual: 0})
               )

      assert view(engine).joins[1].closed
      assert view(engine).request_count == 1
      GenServer.stop(engine)
      engine = start(c)
      assert view(engine).phase == :paused

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "resume",
                 %{kind: :continue, person_id: "person", run_deadline: 60_000},
                 verified(%{verified_person: "person"})
               )

      assert view(engine).request_count == 2
      assert view(engine).slots[{2, 0}].phase == :waiting

      assert {:ok, :duplicate} =
               RunEngine.input(
                 engine,
                 "answer",
                 answer,
                 verified(%{occurrence: {1, 0}, verified_person: "person", actual: 0})
               )

      assert view(engine).request_count == 2
    end

    test "local action expiry is distinct from global deadline, and pause/continue retains pending local veto" do
      for action <- [:expired, :pause] do
        c = fixture(pattern: {TestPattern, :step, %{requests: [request([action("slow")])]}})
        parent = self()

        bindings =
          Map.update!(
            c.opts[:bindings],
            "local_work",
            &Map.put(&1, :work, fn a -> {TestPattern, :blocked, [parent, a["payload"]]} end)
          )

        engine = start(c, bindings: bindings)
        assert {:ok, :applied} = send_input(engine)
        assert_receive {:local_started, task}

        if action == :expired do
          Agent.update(c.clock, fn _ -> 40_000 end)
          assert {:ok, :applied} = RunEngine.input(engine, "deadline", wake(), verified())
          assert view(engine).slots[{1, 0}].outcome == "expired"
          assert view(engine).outcome == nil
          send(task, :finish)

          assert {:ok, :applied} =
                   RunEngine.input(
                     engine,
                     "late-result",
                     result("slow"),
                     verified(%{occurrence: {1, 0}})
                   )

          assert view(engine).slots[{1, 0}].outcome == "expired"
        else
          assert {:ok, :applied} =
                   RunEngine.control(
                     engine,
                     "pause",
                     %{kind: :pause, pause_deadline: 50_000},
                     verified()
                   )

          assert view(engine).phase == :paused

          assert {:error, :invalid_control} =
                   RunEngine.control(
                     engine,
                     "unverified",
                     %{kind: :continue, person_id: "person", run_deadline: 60_000},
                     verified()
                   )

          assert {:ok, :applied} =
                   RunEngine.control(
                     engine,
                     "continue",
                     %{kind: :continue, person_id: "person", run_deadline: 60_000},
                     verified(%{verified_person: "person"})
                   )

          assert view(engine).phase == :waiting
          assert view(engine).request_count == 1
          send(task, :finish)
          assert wait_for(engine, & &1.joins[1].closed).slots[{1, 0}].outcome == "completed"
        end
      end
    end

    test "verified person and deadline equality precede a later answer; generic completion is incompatible" do
      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("ask", "ask_person")])]}}
        )

      engine = start(c)
      assert {:ok, :applied} = send_input(engine)

      assert {:ok, :applied} =
               RunEngine.input(engine, "not-person", result("ask"), verified(%{occurrence: {1, 0}}))

      assert view(engine).slots[{1, 0}].phase == :waiting

      answer =
        result("ask")
        |> Map.delete("outcome")
        |> Map.put("kind", "person_answer")
        |> Map.put("person_id", "person")

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "wrong-person",
                 answer,
                 verified(%{occurrence: {1, 0}, verified_person: "other"})
               )

      assert view(engine).slots[{1, 0}].phase == :waiting
      Agent.update(c.clock, fn _ -> 40_000 end)

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "equal-deadline",
                 answer,
                 verified(%{occurrence: {1, 0}, verified_person: "person"})
               )

      assert view(engine).slots[{1, 0}].outcome == "expired"
      assert view(engine).joins[1].closed
    end

    test "both charge-stop rules retain slow within-cap completion and denial obligations" do
      for rule <- [:pause, :finish] do
        first = request([action("slow"), action("deny")])

        c =
          fixture(
            pattern: {TestPattern, :step, %{requests: [first, :invalid]}},
            request_cap: 1,
            budget_rule: rule
          )

        parent = self()

        bindings =
          Map.update!(
            c.opts[:bindings],
            "local_work",
            &Map.put(&1, :work, fn a -> {TestPattern, :blocked, [parent, a["payload"]]} end)
          )

        gate = %{
          id: "gate",
          version: 1,
          call: fn {:PatternStep, m}, _ ->
            if hd(m["actions"])["id"] == "deny", do: {:deny, "restricted"}, else: :allow
          end
        }

        engine = start(c, bindings: bindings, gate: gate)
        assert {:ok, :applied} = send_input(engine)
        assert_receive {:local_started, task}
        before = view(engine)
        assert before.request_count == 2
        assert before.generation_closed
        assert before.slots[{1, 1}].outcome == "refused"
        assert before.phase == if(rule == :pause, do: :paused, else: :terminal)
        assert before.outcome == if(rule == :finish, do: :out_of_budget, else: nil)
        send(task, :finish)
        after_result = wait_for(engine, &(&1.slots[{1, 0}].phase == :settled))
        assert after_result.slots[{1, 0}].outcome == "completed"
        assert after_result.joins[1] == %{closed: true, outcome: :partial}
        assert after_result.request_count == 2
        assert after_result.phase == before.phase
        assert after_result.outcome == before.outcome
      end
    end

    test "exact cap waits for explicit wake; stale Attempt cannot tick deadlines" do
      c = fixture(pattern: {TestPattern, :step, %{requests: [:invalid]}}, request_cap: 1)
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      refute view(engine).generation_closed
      Agent.update(c.clock, fn _ -> 60_000 end)

      assert {:ok, :applied} =
               RunEngine.input(engine, "stale", wake(), verified(%{attempt_id: "old"}))

      refute view(engine).generation_closed
      assert view(engine).outcome == nil
      assert {:ok, :applied} = RunEngine.input(engine, "wake", wake(), verified())
      assert view(engine).outcome == :out_of_time
      assert view(engine).request_count == 1
    end
  end

  describe "Three reused identities and log reader" do
    test "two reused refusals settle only their occurrences, original result remains original" do
      req = request([action("same")])
      first = request([action("same"), action("trigger")])
      c = fixture(pattern: {TestPattern, :step, %{requests: [first, req, req]}})
      parent = self()

      bindings =
        Map.update!(
          c.opts[:bindings],
          "local_work",
          &Map.put(&1, :work, fn a ->
            if a["id"] == "same",
              do: {TestPattern, :blocked, [parent, a["payload"]]},
              else: {TestPattern, :work, [a["payload"]]}
          end)
        )

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:local_started, task}
      pending = wait_for(engine, &(&1.request_count == 3))
      assert pending.slots[{1, 0}].phase == :running
      assert pending.slots[{2, 0}].outcome == "refused"
      assert pending.slots[{3, 0}].outcome == "refused"
      refute pending.joins[1].closed
      send(task, :finish)
      result = wait_for(engine, & &1.joins[1].closed)
      assert Enum.map(1..3, &result.slots[{&1, 0}].outcome) == ["completed", "refused", "refused"]
      assert Enum.all?(result.joins, fn {_, j} -> j.closed end)
      refute_receive {:local_started, _}
      assert {:ok, audit} = DocumentPublication.audit(c.store, c.prefix)
      assert map_size(audit.verdicts) == 2
      assert map_size(audit.settlements) == 4
      assert map_size(audit.charges) == 3

      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
      assert {:committed, checkpoint} = DurableUnit.checkpoint(unit)
      GenServer.stop(engine)
      assert :ok = DynamicUnits.stop(c.directory, c.prefix)

      writer =
        start_supervised!(%{
          id: make_ref(),
          start:
            {Elzoo.DurableLog.Writer, :start_link,
             [
               [
                 store: c.store,
                 stream: c.prefix,
                 fold: DurableUnit.fold(c.unit_opts),
                 limits: DurableUnit.limits(c.unit_opts)
               ]
             ]}
        })

      record = %{
        version: 1,
        kind: :protocol,
        id: "unresolved",
        run_id: "run",
        attempt_id: "attempt",
        input: Map.put(wake(), "at_ms", 2_000),
        correlation: %{},
        context: %{}
      }

      assert {:committed, _} =
               Elzoo.DurableLog.Writer.append(
                 writer,
                 [
                   {"input", 1,
                    :erlang.term_to_binary({1, {"unresolved", record}}, [
                      :deterministic,
                      {:minor_version, 2}
                    ])}
                 ]
               )

      assert {:ok, ^audit} = DocumentPublication.audit(c.store, c.prefix)

      memory_pid =
        start_supervised!(%{
          id: make_ref(),
          start:
            {Elzoo.DurableLog.Memory, :start_link,
             [
               [
                 fold: DurableUnit.fold(c.unit_opts),
                 limits: DurableUnit.limits(c.unit_opts)
               ]
             ]}
        })

      memory = Elzoo.DurableLog.Memory.store(memory_pid)

      for row <- rows(c) do
        assert {:committed, _} =
                 Elzoo.DurableLog.Memory.append(memory, c.prefix, row.sequence - 1, [row], [])
      end

      last = List.last(rows(c))

      staged = %{
        last
        | sequence: last.sequence + 1,
          payload: "uncommitted-not-an-engine-record",
          nonce: :crypto.strong_rand_bytes(16)
      }

      staged = %{staged | digest: Elzoo.DurableLog.digest(staged)}
      :ok = Elzoo.DurableLog.Memory.fault(memory, :append, :stage)

      assert {:indeterminate, _} =
               Elzoo.DurableLog.Memory.append(memory, c.prefix, last.sequence, [staged], [])

      assert {:ok, ^audit} = DocumentPublication.audit(memory, c.prefix)

      assert {:committed, _} =
               Elzoo.DurableLog.Postgres.retain(
                 c.store,
                 c.prefix,
                 0,
                 checkpoint,
                 :crypto.strong_rand_bytes(16)
               )

      assert {:error, :unavailable_or_pruned_history} = DocumentPublication.audit(c.store, c.prefix)
    end
  end

  describe "First committed verdict and restart" do
    test "answer death resamples; gate and refusal input/result reply-loss boundaries drain without new business input" do
      parent = self()

      c =
        fixture(pattern: {TestPattern, :step, %{requests: [request([action("a", "ask_person")])]}})

      engine =
        start(c,
          gate: %{
            id: "gate",
            version: 1,
            call: fn _, _ ->
              send(parent, :sampled_without_commit)
              receive do: (:continue -> :allow)
            end
          }
        )

      caller = Task.async(fn -> catch_exit(send_input(engine)) end)
      assert_receive :sampled_without_commit
      Process.exit(engine, :kill)
      Task.await(caller)
      engine = start(c, gate: %{id: "gate", version: 1, call: fn _, _ -> {:deny, "resampled"} end})
      assert view(engine).slots[{1, 0}].outcome == "refused"
      assert view(engine).slots[{1, 0}].verdict.reason == "resampled"

      # SQL's existing dispatch seam loses the committed reply at the four
      # exact append boundaries (configure=1/2, protocol=3/4, gate=5/6,
      # refusal=7/8). No alternate engine or fault framework is involved.
      for target <- 5..8 do
        c =
          fixture(
            pattern: {TestPattern, :step, %{requests: [request([action("a", "ask_person")])]}}
          )

        {module, config} = c.store

        store =
          {module,
           %{
             config
             | test_dispatch: fn op, request, run ->
                 if op == :append and request.stream == c.prefix and request.target == target,
                   do: PostgresHarness.hook(c.store, :inject, [:append, :reply_loss])

                 config.test_dispatch.(op, request, run)
               end
           }}

        unit_opts = Keyword.put(c.unit_opts, :store, store)

        directory =
          start_supervised!(%{
            id: make_ref(),
            restart: :temporary,
            start:
              {DynamicUnits, :start_link,
               [
                 [
                   registry: Elzoo.RunEngine.UnitRegistry,
                   supervisor: c.supervisor,
                   idle_ms: 60_000,
                   unit_options: fn _ -> unit_opts end
                 ]
               ]}
          })

        gate = %{
          id: "gate",
          version: 1,
          call: fn _, _ ->
            send(parent, {:sample, target})
            {:deny, "restricted"}
          end
        }

        engine = start(c, store: store, directory: directory, gate: gate)
        assert {:error, :storage_unknown} = send_input(engine)
        assert_receive {:sample, ^target}
        GenServer.stop(engine)
        assert :ok = DynamicUnits.stop(directory, c.prefix)

        engine =
          start(c,
            store: store,
            directory: directory,
            gate: %{gate | call: fn _, _ -> flunk("committed verdict recalled") end}
          )

        assert view(engine).slots[{1, 0}].outcome == "refused"
        assert view(engine).joins[1].closed
        assert view(engine).request_count == 1
        refute_receive {:sample, ^target}
      end
    end

    test "restart never recalls a committed verdict; later opposite batch cannot replace it" do
      c =
        fixture(pattern: {TestPattern, :step, %{requests: [request([action("a", "ask_person")])]}})

      parent = self()

      engine =
        start(c,
          gate: %{
            id: "gate",
            version: 1,
            call: fn _, _ ->
              send(parent, :sample)
              :allow
            end
          }
        )

      assert {:ok, :applied} = send_input(engine)
      assert_receive :sample
      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)

      assert {:ok, :applied} =
               DurableUnit.step(unit, "opposite-batch", %{
                 version: 1,
                 kind: :gate,
                 request: 1,
                 at_ms: 2_001,
                 entries: [
                   %{index: 0, verdict: :deny, reason: "changed", gate_id: "gate", gate_version: 1}
                 ]
               })

      GenServer.stop(engine)

      engine =
        start(c,
          gate: %{id: "gate", version: 1, call: fn _, _ -> flunk("committed gate recalled") end}
        )

      assert view(engine).slots[{1, 0}].verdict.verdict == :allow
      assert view(engine).slots[{1, 0}].phase == :waiting
      refute_receive :sample
    end
  end

  describe "Append rejection/uncertainty" do
    @tag timeout: 120_000
    test "live caller timeout reuses committed bytes, and eviction never repeats a logical invocation" do
      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("ask", "ask_person")])]}}
        )

      parent = self()

      engine =
        start(c,
          gate: %{
            id: "gate",
            version: 1,
            call: fn _, _ ->
              send(parent, {:gate_barrier, self()})
              receive do: (:release_gate -> :allow)
            end
          }
        )

      caller = Task.async(fn -> send_input(engine) end)
      assert_receive {:gate_barrier, ^engine}
      assert Task.yield(caller, 1_000) == nil
      assert Task.shutdown(caller, :brutal_kill) == nil
      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
      assert Process.alive?(unit)
      assert DurableUnit.snapshot(unit).control.count == 1
      send(engine, :release_gate)
      assert view(engine).slots[{1, 0}].phase == :waiting
      Agent.update(c.clock, fn _ -> 2_001 end)
      assert {:ok, :duplicate} = send_input(engine)

      for n <- 1..1_025 do
        assert {:ok, :applied} = RunEngine.input(engine, "evict-#{n}", wake(), verified())
      end

      # This ID is now outside DU's 1024-entry FIFO. The engine uses the
      # original recorded bytes/time and persistent invocation identity.
      assert {:ok, :applied} = send_input(engine)
      assert view(engine).request_count == 1
      assert view(engine).slots[{1, 0}].phase == :waiting
      refute_receive {:gate_barrier, _}
    end

    test "CAS loser stops and installs neither its pattern output nor outbox" do
      c = fixture(pattern: {TestPattern, :step, %{requests: [request([action("never")])]}})
      engine = start(c)
      {:ok, loser} = DynamicUnits.find(c.directory, c.prefix)
      {:ok, winner} = DurableUnit.start_link(Keyword.put(c.unit_opts, :stream, c.prefix))
      Process.unlink(winner)
      on_exit(fn -> if Process.alive?(winner), do: GenServer.stop(winner) end)

      record = %{
        version: 1,
        kind: :protocol,
        id: "winner",
        run_id: "run",
        attempt_id: "old",
        input: Map.put(wake(), "at_ms", 2_000),
        correlation: %{},
        context: %{}
      }

      assert {:ok, :applied} = DurableUnit.step(winner, "winner", record)
      monitor = Process.monitor(loser)
      assert {:error, :durable_unit_conflict} = send_input(engine)
      assert_receive {:DOWN, ^monitor, :process, ^loser, {:shutdown, :durable_unit_conflict}}
      assert view(engine).reconciliation == :durable_unit_conflict
      assert {:ok, []} = Elzoo.Outbox.pending(c.store, c.prefix, 64)

      refute Enum.any?(rows(c), fn row ->
               match?({1, {"start", _}}, :erlang.binary_to_term(row.payload))
             end)
    end

    test "definitive pre-input and result size rejection sleep, never hot reopen, and corrected explicit startup drains" do
      for stage <- [:input, :result] do
        c =
          fixture(
            pattern:
              if(stage == :result,
                do: {TestPattern, :sized, {:text, 1_500}},
                else: {TestPattern, :step, %{requests: []}}
              )
          )

        {module, config} = c.store
        limited = {module, put_in(config.limits.max_record_bytes, 4_096)}
        unit_opts = Keyword.put(c.unit_opts, :store, limited)

        directory =
          start_supervised!(%{
            id: make_ref(),
            restart: :temporary,
            start:
              {DynamicUnits, :start_link,
               [
                 [
                   registry: Elzoo.RunEngine.UnitRegistry,
                   supervisor: c.supervisor,
                   idle_ms: 60_000,
                   unit_options: fn _ -> unit_opts end
                 ]
               ]}
          })

        engine = start(c, directory: directory, store: limited)

        input =
          if stage == :input,
            do: put_in(start_input()["payload"], %{"text" => String.duplicate("x", 5_000)}),
            else: start_input()

        assert {:error, :storage_rejected} = RunEngine.input(engine, "start", input, verified())
        assert :not_found = DynamicUnits.find(directory, c.prefix)
        assert DynamicSupervisor.which_children(c.supervisor) == []
        count = length(rows(c))
        assert {:error, :storage_rejected} = RunEngine.input(engine, "wake", wake(), verified())
        send(engine, {:durable_unit_input, "queued", %{version: 1, kind: :protocol}})
        assert {:error, :storage_rejected} = send_input(engine)
        assert length(rows(c)) == count
        GenServer.stop(engine)
        GenServer.stop(directory)
        # Confirmed stop/spec removal permits host replacement with corrected
        # Store limits. This is infrastructure startup, not an engine retry API.
        corrected =
          start_supervised!(%{
            id: make_ref(),
            restart: :temporary,
            start:
              {DynamicUnits, :start_link,
               [
                 [
                   registry: Elzoo.RunEngine.UnitRegistry,
                   supervisor: c.supervisor,
                   idle_ms: 60_000,
                   unit_options: fn _ -> c.unit_opts end
                 ]
               ]}
          })

        engine = start(c, directory: corrected)

        if stage == :result do
          assert wait_for(engine, &(&1.slots[{1, 0}].phase == :settled)).slots[{1, 0}].outcome ==
                   "completed"

          assert view(engine).request_count == 1
        else
          assert {:ok, :applied} = RunEngine.input(engine, "start", input, verified())
        end
      end
    end

    test "unknown pre-input append suppresses intake until explicit fenced reopen" do
      for mode <- [:reply_loss, :rollback] do
        c = fixture()
        engine = start(c)
        :ok = PostgresHarness.hook(c.store, :inject, [:append, mode])
        assert {:error, :storage_unknown} = send_input(engine)
        assert {:error, :storage_unknown} = send_input(engine, "no-hot-retry")
        count = length(rows(c))
        Process.sleep(10)
        assert length(rows(c)) == count
        GenServer.stop(engine)
        # These deterministic facilities have completed/rolled back the write.
        # Host fencing and explicit startup, never an incoming result, reopen it.
        assert :ok = DynamicUnits.stop(c.directory, c.prefix)
        engine = start(c)
        assert {:ok, disposition} = send_input(engine)
        assert disposition in [:applied, :duplicate]
        assert view(engine).request_count == 0
      end
    end
  end

  describe "Intent recovery windows" do
    test "descriptor and raw-outcome input/result reply-loss windows recover without a second send or gate call" do
      for target <- 11..14 do
        c =
          fixture(
            pattern: {TestPattern, :step, %{requests: [request([action("publish", "tool_call")])]}}
          )

        {module, config} = c.store

        store =
          {module,
           %{
             config
             | test_dispatch: fn op, request, run ->
                 if op == :append and request.stream == c.prefix and request.target == target,
                   do: PostgresHarness.hook(c.store, :inject, [:append, :reply_loss])

                 config.test_dispatch.(op, request, run)
               end
           }}

        unit_opts = Keyword.put(c.unit_opts, :store, store)

        directory =
          start_supervised!(%{
            id: make_ref(),
            restart: :temporary,
            start:
              {DynamicUnits, :start_link,
               [
                 [
                   registry: Elzoo.RunEngine.UnitRegistry,
                   supervisor: c.supervisor,
                   idle_ms: 60_000,
                   unit_options: fn _ -> unit_opts end
                 ]
               ]}
          })

        engine = start(c, store: store, directory: directory)

        if target <= 12 do
          assert {:error, :storage_unknown} = send_input(engine)
          refute_receive {:effect_started, _, _}
        else
          assert {:ok, :applied} = send_input(engine)
          assert_receive {:effect_started, provider, _}

          assert {:error, :storage_unknown} =
                   RunEngine.input(
                     engine,
                     "sink-result",
                     result("publish"),
                     verified(%{occurrence: {1, 0}, actual: 1, dispatch: "dispatched"})
                   )

          send(provider, {:result, %{}})
        end

        GenServer.stop(engine)
        assert :ok = DynamicUnits.stop(directory, c.prefix)
        Agent.update(c.host_mode, fn _ -> :recover end)

        engine =
          start(c,
            store: store,
            directory: directory,
            gate: %{id: "gate", version: 1, call: fn _, _ -> flunk("committed gate recalled") end}
          )

        if target <= 12 do
          assert_receive {:effect_started, provider, _}
          assert view(engine).slots[{1, 0}].phase == :running
          send(provider, {:result, %{}})
        else
          assert view(engine).slots[{1, 0}].outcome == "completed"
          assert view(engine).joins[1].closed
        end

        assert view(engine).request_count == 1
        refute_receive {:effect_started, _, _}
      end
    end

    test "changed provider binding refuses recovery without replacing recorded arguments or identity" do
      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("publish", "tool_call")])]}}
        )

      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, provider, original}
      GenServer.stop(engine)

      changed =
        Map.update!(
          c.opts[:effect_intent],
          "effect",
          &Keyword.put(&1, :binding, Elzoo.RunEngine.ChangedAccountBinding)
        )

      assert {:error, :changed_binding} =
               RunEngine.start_link(Keyword.put(c.opts, :effect_intent, changed))

      refute_receive {:effect_started, _, _}
      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
      descriptor = DurableUnit.snapshot(unit).slots[{1, 0}].intent
      assert descriptor.identity == ["tenant", "account", "effect", "publish", "publish"]
      assert descriptor.arguments == original.arguments
      send(provider, {:result, %{}})
    end

    test "read-only admission reports reconciliation and never sends or silently activates" do
      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("publish", "tool_call")])]}}
        )

      Agent.update(c.host_mode, fn _ -> :read_only end)
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert %{phase: :reconcile, reconciliation: :read_only} = view(engine).slots[{1, 0}]
      refute_receive {:effect_started, _, _}
      Agent.update(c.host_mode, fn _ -> :fresh end)
      assert {:ok, :applied} = RunEngine.input(engine, "wake", wake(), verified())
      assert view(engine).slots[{1, 0}].phase == :reconcile
      refute_receive {:effect_started, _, _}

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "pause-reconciliation",
                 %{kind: :pause, pause_deadline: 50_000},
                 verified()
               )

      GenServer.stop(engine)
      engine = start(c)
      assert view(engine).phase == :paused
      assert view(engine).slots[{1, 0}].phase == :ready
      refute_receive {:effect_started, _, _}

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "continue-reconciliation",
                 %{kind: :continue, person_id: "person", run_deadline: 60_000},
                 verified(%{verified_person: "person"})
               )

      assert_receive {:effect_started, provider, _}
      assert view(engine).slots[{1, 0}].phase == :running
      GenServer.stop(engine)
      Agent.update(c.host_mode, fn _ -> :recover end)
      engine = start(c)
      refute_receive {:effect_started, _, _}
      assert view(engine).slots[{1, 0}].outcome == "unknown"
      send(provider, {:result, %{}})
    end

    test "ALLOW dispatches once and a reserved recovery never sends again" do
      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("publish", "tool_call")])]}}
        )

      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, task, req}
      assert req.arguments == Jason.encode!(%{"value" => 7})
      GenServer.stop(engine)
      Agent.update(c.host_mode, fn _ -> :recover end)
      engine = start(c)
      assert view(engine).slots[{1, 0}].outcome == "unknown"
      assert view(engine).joins[1].outcome == :failed
      refute_receive {:effect_started, _, _}
      send(task, {:result, %{"accepted" => true}})

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "late-provider",
                 result("publish"),
                 verified(%{occurrence: {1, 0}, actual: 1, dispatch: "dispatched"})
               )

      assert view(engine).slots[{1, 0}].outcome == "unknown"
    end
  end

  describe "Concurrent request and Attempt routing" do
    test "fanout settles out of order and duplicate or stale results do not settle twice" do
      c = fixture(pattern: {TestPattern, :step, %{requests: [request([action("a"), action("b")])]}})
      parent = self()

      bindings =
        Map.update!(
          c.opts[:bindings],
          "local_work",
          &Map.put(&1, :work, fn a -> {TestPattern, :blocked, [parent, a["payload"]]} end)
        )

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:local_started, first}
      assert_receive {:local_started, second}

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "old",
                 result("a"),
                 verified(%{attempt_id: "old", occurrence: {1, 0}, actual: 99})
               )

      assert view(engine).slots[{1, 0}].phase == :running
      send(second, :finish)
      partial = wait_for(engine, &(&1.slots[{1, 1}].phase == :settled))
      refute partial.joins[1].closed
      send(first, :finish)
      completed = wait_for(engine, & &1.joins[1].closed)
      assert completed.joins[1].outcome == :all

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "duplicate-different-id",
                 Map.put(result("a"), "outcome", "failed"),
                 verified(%{occurrence: {1, 0}, actual: 99})
               )

      assert view(engine).slots == completed.slots
    end
  end

  describe "Local work recovery/cancel" do
    test "actual killed/timed-out tasks retain their loss kind and capacity refusal starts no fifth task" do
      for loss <- [:killed, :timed_out, :unavailable, :capacity] do
        actions = for n <- 0..if(loss == :capacity, do: 4, else: 0), do: action("work-#{n}")
        c = fixture(pattern: {TestPattern, :step, %{requests: [request(actions)]}})
        parent = self()

        bindings =
          Map.update!(c.opts[:bindings], "local_work", fn binding ->
            binding =
              Map.put(binding, :work, fn a -> {TestPattern, :blocked, [parent, a["payload"]]} end)

            if loss == :timed_out,
              do: Map.put(binding, :facts, fn a -> %{binding.facts.(a) | deadline_ms: 2_100} end),
              else: binding
          end)

        engine = start(c, bindings: bindings)
        assert {:ok, :applied} = send_input(engine)
        assert_receive {:local_started, task}

        case loss do
          :capacity ->
            for _ <- 1..3, do: assert_receive({:local_started, _})
            refute_receive {:local_started, _}
            assert view(engine).slots[{1, 4}].outcome == "failed"

          :killed ->
            Process.exit(task, :kill)

          :unavailable ->
            Process.exit(task, :ordinary_failure)

          :timed_out ->
            :ok
        end

        key = if loss == :capacity, do: {1, 4}, else: {1, 0}
        assert wait_for(engine, &(&1.slots[key].phase == :settled)).slots[key].outcome == "failed"
        {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
        join = DurableUnit.snapshot(unit).control.trackers[1].join |> Map.put(:now, fn -> 2_000 end)
        assert {:ok, branches} = Elzoo.Aggregation.status(join)
        expected = if loss == :capacity, do: :unavailable, else: loss
        assert branches["work-#{elem(key, 1)}"].loss == expected
      end
    end

    test "targeted cancel closes before controller cancellation; Unit replacement records loss before queued result" do
      for operation <- [:cancel, :replace] do
        c = fixture(pattern: {TestPattern, :step, %{requests: [request([action("slow")])]}})
        parent = self()

        bindings =
          Map.update!(
            c.opts[:bindings],
            "local_work",
            &Map.put(&1, :work, fn a -> {TestPattern, :blocked, [parent, a["payload"]]} end)
          )

        engine = start(c, bindings: bindings)
        assert {:ok, :applied} = send_input(engine)
        assert_receive {:local_started, task}

        case operation do
          :cancel ->
            assert {:ok, :applied} =
                     RunEngine.control(
                       engine,
                       "cancel",
                       %{kind: :cancel, attempt_id: "attempt"},
                       verified()
                     )

          :replace ->
            assert :ok = DynamicUnits.stop(c.directory, c.prefix)
            assert {:ok, :applied} = RunEngine.input(engine, "wake", wake(), verified())
        end

        assert view(engine).slots[{1, 0}].outcome == "failed"
        send(task, :finish)

        assert {:ok, :applied} =
                 RunEngine.input(engine, "late", result("slow"), verified(%{occurrence: {1, 0}}))

        assert view(engine).slots[{1, 0}].outcome == "failed"
        assert view(engine).joins[1].closed
      end
    end

    test "receiver replacement commits local restart loss before surviving completion" do
      c = fixture(pattern: {TestPattern, :step, %{requests: [request([action("a")])]}})
      parent = self()

      bindings =
        Map.update!(
          c.opts[:bindings],
          "local_work",
          &Map.put(&1, :work, fn a -> {TestPattern, :blocked, [parent, a["payload"]]} end)
        )

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:local_started, task}
      GenServer.stop(engine)
      engine = start(c, bindings: bindings)
      assert view(engine).slots[{1, 0}].outcome == "failed"
      assert view(engine).joins[1].closed
      send(task, :finish)
      # A public status barrier observes the same committed first settlement.
      assert view(engine).slots[{1, 0}].outcome == "failed"

      assert Enum.all?(rows(c), fn row ->
               term = :erlang.binary_to_term(row.payload, [:safe])
               not String.contains?(inspect(term), "#Reference")
             end)
    end
  end

  describe "ASK and release-only resource composition" do
    test "ASK non-Effects release approval without inventing an intent" do
      for kind <- ["local_work", "ask_person", "nested_callable", "finish"] do
        c =
          fixture(pattern: {TestPattern, :step, %{requests: [request([action("approved", kind)])]}})

        require_approval(c)
        bindings = Map.update!(c.opts[:bindings], kind, &%{&1 | effect_class: "publish"})
        engine = start(c, bindings: bindings)
        assert {:ok, :applied} = send_input(engine)
        {:ok, run} = Run.status(c.run, "run")
        [%{request_key: key}] = run.approvals

        assert {:ok, :applied} =
                 RunEngine.control(
                   engine,
                   "consent",
                   %{kind: :approval_evidence, request_key: key, evidence: consent(key)},
                   verified()
                 )

        assert view(engine).slots[{1, 0}].phase != :approval
        {:ok, run} = Run.status(c.run, "run")
        assert run.effects == %{}
        assert [%{status: :released}] = Enum.map(run.approvals, &Map.take(&1, [:status]))
        refute_receive {:effect_started, _, _}
      end
    end

    test "ASK non-Effect ready recovery revalidates release after death before dispatch" do
      for authority <- [:unchanged, :changed] do
        c = fixture(pattern: {TestPattern, :step, %{requests: [request([action("approved")])]}})
        require_approval(c)
        armed = start_supervised!({Agent, fn -> true end}, id: make_ref())
        parent = self()
        base = c.opts[:bindings]["local_work"]

        binding = %{
          base
          | effect_class: "publish",
            work: fn action ->
              if Agent.get_and_update(armed, &{&1, false}) do
                send(parent, :died_after_ready)
                Process.exit(self(), :kill)
              end

              send(parent, :work_dispatched)
              base.work.(action)
            end
        }

        bindings = Map.put(c.opts[:bindings], "local_work", binding)
        engine = start(c, bindings: bindings)
        assert {:ok, :applied} = send_input(engine)
        {:ok, run} = Run.status(c.run, "run")
        [%{request_key: key}] = run.approvals
        monitor = Process.monitor(engine)

        assert catch_exit(
                 RunEngine.control(
                   engine,
                   "consent",
                   %{kind: :approval_evidence, request_key: key, evidence: consent(key)},
                   verified()
                 )
               )

        assert_receive :died_after_ready
        assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}
        {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
        assert DurableUnit.snapshot(unit).slots[{1, 0}].phase == :ready
        {:ok, run} = Run.status(c.run, "run")
        assert [%{status: :released}] = Enum.map(run.approvals, &Map.take(&1, [:status]))
        assert run.effects == %{}
        refute_receive :work_dispatched

        if authority == :changed, do: Agent.update(c.context, &%{&1 | authority: []})
        engine = start(c, bindings: bindings)
        state = wait_for(engine, &(&1.slots[{1, 0}].phase == :settled))

        if authority == :unchanged do
          assert state.slots[{1, 0}].outcome == "completed"
          assert_receive :work_dispatched
        else
          assert state.slots[{1, 0}].outcome == "refused"
        end

        refute_receive :work_dispatched
        refute_receive {:effect_started, _, _}
      end
    end

    test "ASK descriptor recovery checks engine startup binding before first Run binding" do
      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("publish", "tool_call")])]}}
        )

      require_approval(c)
      {module, config} = c.store

      store =
        {module,
         %{
           config
           | test_dispatch: fn op, request, run ->
               if op == :append and request.stream == c.prefix and request.target == 12,
                 do: PostgresHarness.hook(c.store, :inject, [:append, :reply_loss])

               config.test_dispatch.(op, request, run)
             end
         }}

      directory =
        start_supervised!(%{
          id: make_ref(),
          restart: :temporary,
          start:
            {DynamicUnits, :start_link,
             [
               [
                 registry: Elzoo.RunEngine.UnitRegistry,
                 supervisor: c.supervisor,
                 idle_ms: 60_000,
                 unit_options: fn _ -> Keyword.put(c.unit_opts, :store, store) end
               ]
             ]}
        })

      engine = start(c, store: store, directory: directory)
      assert {:error, :storage_unknown} = send_input(engine)
      {:ok, run} = Run.status(c.run, "run")
      assert run.effects == %{}
      GenServer.stop(engine)
      assert :ok = DynamicUnits.stop(directory, c.prefix)

      changed =
        Map.update!(
          c.opts[:effect_intent],
          "effect",
          &Keyword.put(&1, :binding, Elzoo.RunEngine.ChangedRevisionBinding)
        )

      assert {:error, :changed_binding} =
               RunEngine.start_link(
                 Keyword.merge(c.opts, effect_intent: changed, store: store, directory: directory)
               )

      {:ok, run} = Run.status(c.run, "run")
      assert run.effects == %{}
      refute_receive {:effect_started, _, _}
      engine = start(c, store: store, directory: directory)
      {:ok, run} = Run.status(c.run, "run")
      [%{request_key: key}] = run.approvals

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "consent",
                 %{kind: :approval_evidence, request_key: key, evidence: consent(key)},
                 verified()
               )

      assert_receive {:effect_started, provider, _}
      refute_receive {:effect_started, _, _}
      send(provider, {:result, %{}})
    end

    test "retained consent is revalidated against changed authority and revocation before any send" do
      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("publish", "tool_call")])]}}
        )

      require_approval(c)
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      {:ok, run} = Run.status(c.run, "run")
      [%{request_key: key}] = run.approvals
      authority = Agent.get(c.context, & &1.authority)
      Agent.update(c.context, &%{&1 | authority: []})

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "blocked-consent",
                 %{kind: :approval_evidence, request_key: key, evidence: consent(key)},
                 verified()
               )

      refute_receive {:effect_started, _, _}
      assert view(engine).slots[{1, 0}].phase == :approval

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "revoke",
                 %{
                   kind: :approval_evidence,
                   request_key: key,
                   revoked_evidence_key: {"verifier", "consent"}
                 },
                 verified()
               )

      Agent.update(c.context, &%{&1 | authority: authority})
      GenServer.stop(engine)
      engine = start(c)
      assert view(engine).slots[{1, 0}].phase == :approval
      {:ok, run} = Run.status(c.run, "run")
      assert %{classification: :waiting_approval} = run.effects["publish"]
      refute_receive {:effect_started, _, _}
    end

    test "reserved ordinary ASK on receiver restart becomes lost outcome, without another send" do
      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("publish", "tool_call")])]}}
        )

      require_approval(c)
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      {:ok, run} = Run.status(c.run, "run")
      [%{request_key: key}] = run.approvals

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "consent",
                 %{kind: :approval_evidence, request_key: key, evidence: consent(key)},
                 verified()
               )

      assert_receive {:effect_started, task, _}
      GenServer.stop(engine)
      engine = start(c)
      assert view(engine).slots[{1, 0}].outcome == "unknown"
      assert view(engine).joins[1].closed
      refute_receive {:effect_started, _, _}
      send(task, {:result, %{}})
    end

    test "ordinary ASK waits durably, then genuine consent dispatches once" do
      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("publish", "tool_call")])]}}
        )

      require_approval(c)
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert view(engine).slots[{1, 0}].phase == :approval
      refute_receive {:effect_started, _, _}
      GenServer.stop(engine)
      engine = start(c)
      assert view(engine).slots[{1, 0}].phase == :approval
      {:ok, run} = Run.status(c.run, "run")
      [%{request_key: key}] = run.approvals

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "consent",
                 %{
                   kind: :approval_evidence,
                   request_key: key,
                   evidence: consent(key)
                 },
                 verified()
               )

      assert_receive {:effect_started, task, _}
      assert view(engine).slots[{1, 0}].phase == :running
      send(task, {:result, %{"published" => true}})

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "sink",
                 result("publish", %{"published" => true}),
                 verified(%{occurrence: {1, 0}, actual: 1, dispatch: "dispatched"})
               )

      assert view(engine).joins[1].outcome == :all
      refute_receive {:effect_started, _, _}
    end

    test "ASK resource release precedes Resource's barrier and never Run Effect dispatch" do
      a =
        action("open", "resource_open", %{
          "run_id" => "run",
          "resource_name" => "document",
          "data" => %{}
        })

      c = fixture(pattern: {TestPattern, :step, %{requests: [request([a])]}})
      require_approval(c)
      {owner, bindings} = resource(c)
      engine = start(c, resources: %{"document" => owner}, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      refute_receive {:effect_started, _, _}
      {:ok, run} = Run.status(c.run, "run")
      [%{request_key: key}] = run.approvals

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "consent",
                 %{
                   kind: :approval_evidence,
                   request_key: key,
                   evidence: consent(key)
                 },
                 verified()
               )

      assert_receive {:effect_started, task, _}
      {:ok, run} = Run.status(c.run, "run")
      assert run.effects == %{}
      assert [%{status: :released}] = Enum.map(run.approvals, &Map.take(&1, [:status]))
      assert {:ok, %{state: %{phase: :opening}}} = Elzoo.RunResource.read(owner, 0)
      send(task, {:result, %{}})
    end
  end

  describe "Resource lifetime and consumption" do
    test "nested Resource lifetime settles its owning child Budget and cursor only once" do
      open =
        action("open", "resource_open", %{
          "run_id" => "run",
          "resource_name" => "document",
          "data" => %{}
        })

      c =
        fixture(
          pattern:
            {TestPattern, :step, %{requests: [request([action("nested", "nested_callable")])]}}
        )

      {owner, bindings} =
        resource(c, :stay, %{
          budget_id: "nested-nested",
          unit: "credits",
          cost_ref: "2:0",
          generation: {"sealed", 1}
        })

      base = bindings["nested_callable"]

      bindings =
        Map.put(bindings, "nested_callable", %{
          base
          | facts: fn a -> %{base.facts.(a) | estimate: 5} end,
            nested: fn a -> %{base.nested.(a) | initial_state: %{requests: [request([open])]}} end
        })

      engine = start(c, resources: %{"document" => owner}, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, opening, _}

      assert {:ok, _} =
               Elzoo.RunResource.command(owner, %{
                 id: "opened",
                 at_ms: 2_000,
                 body:
                   {:observed, ["tenant", "account", "effect", "publish", "open"],
                    {:completed, %{opened_at_ms: 2_000}}}
               })

      assert {:ok, :applied} = RunEngine.input(engine, "consume-open", wake(), verified())
      assert {:ok, _} = Elzoo.RunResource.command(owner, %{id: "close", at_ms: 3_000, body: :pause})
      Agent.update(c.clock, fn _ -> 40_000 end)

      assert {:ok, _} =
               Elzoo.RunResource.command(owner, %{id: "expiry", at_ms: 40_000, body: :tick})

      assert {:ok, :applied} = RunEngine.input(engine, "consume-close", wake(), verified())
      assert_receive {:effect_started, closing, _}

      assert {:ok, _} =
               Elzoo.RunResource.command(owner, %{
                 id: "closed",
                 at_ms: 40_000,
                 body:
                   {:observed, ["tenant", "account", "effect", "publish", "cleanup"],
                    {:completed, %{opened_at_ms: 2_000, closed_at_ms: 40_000}}}
               })

      assert {:ok, :applied} = RunEngine.input(engine, "consume-actual", wake(), verified())
      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
      budgets = DurableUnit.snapshot(unit).control.budgets

      assert {:Transition, _, {:some, {:status, %{committed: 1, reserved: 0}}}} =
               Elzoo.Budget.step(budgets["1:0"].state, {40_000, :status})

      assert {:Transition, _, {:some, {:status, %{committed: 0, reserved: 5}}}} =
               Elzoo.Budget.step(budgets["root"].state, {39_999, :status})

      GenServer.stop(engine)
      engine = start(c, resources: %{"document" => owner}, bindings: bindings)
      assert DurableUnit.snapshot(unit).control.budgets == budgets
      assert view(engine).reconciliation == nil
      send(opening, {:result, %{}})
      send(closing, {:result, %{}})
    end

    test "refused queued Resource intent remains ordinary after death before cursor commit" do
      payload = %{"run_id" => "run", "resource_name" => "document", "data" => %{}}

      c =
        fixture(
          pattern:
            {TestPattern, :step,
             %{
               requests: [
                 request([action("open", "resource_open", payload)]),
                 request([
                   action("using", "resource_use", payload),
                   action("queued", "resource_use", payload)
                 ])
               ]
             }}
        )

      {owner, bindings} = resource(c)
      armed = start_supervised!({Agent, fn -> false end}, id: make_ref())
      parent = self()
      {module, config} = c.store

      store =
        {module,
         %{
           config
           | test_dispatch: fn op, req, run ->
               if op == :append and req.stream == c.prefix and Agent.get(armed, & &1) and
                    req.expected > 0 do
                 {:ok, rows, _} = Elzoo.DurableLog.read(c.store, c.prefix, req.expected, 1)

                 case rows do
                   [%{kind: "result", payload: bytes}] ->
                     {1, {_, state}} = :erlang.binary_to_term(bytes, [:safe])

                     if match?(%{phase: :settled}, state.slots[{2, 1}]) do
                       Agent.update(armed, fn _ -> false end)
                       send(parent, :died_before_cursor)
                       exit(:kill)
                     end

                   _ ->
                     :ok
                 end
               end

               config.test_dispatch.(op, req, run)
             end
         }}

      directory =
        start_supervised!(%{
          id: make_ref(),
          restart: :temporary,
          start:
            {DynamicUnits, :start_link,
             [
               [
                 registry: Elzoo.RunEngine.UnitRegistry,
                 supervisor: c.supervisor,
                 idle_ms: 60_000,
                 unit_options: fn _ -> Keyword.put(c.unit_opts, :store, store) end
               ]
             ]}
        })

      engine =
        start(c,
          resources: %{"document" => owner},
          bindings: bindings,
          store: store,
          directory: directory
        )

      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, opening, _}

      assert {:ok, _} =
               Elzoo.RunResource.command(owner, %{
                 id: "opened",
                 at_ms: 2_000,
                 body:
                   {:observed, ["tenant", "account", "effect", "publish", "open"],
                    {:completed, %{opened_at_ms: 2_000}}}
               })

      assert {:ok, :applied} = RunEngine.input(engine, "opened", wake(), verified())
      assert_receive {:effect_started, using, _}
      refute_receive {:effect_started, _, _}
      Agent.update(c.context, &%{&1 | authority: []})

      assert {:ok, _} =
               Elzoo.RunResource.command(owner, %{
                 id: "used",
                 at_ms: 2_001,
                 body:
                   {:observed, ["tenant", "account", "effect", "publish", "using"],
                    {:completed, %{}}}
               })

      Agent.update(armed, fn _ -> true end)
      assert {:error, _} = RunEngine.input(engine, "consume-use", wake(), verified())
      assert_receive :died_before_cursor
      GenServer.stop(engine)
      assert :ok = DynamicUnits.stop(directory, c.prefix)
      Agent.update(c.host_mode, fn _ -> :recover end)

      engine =
        start(c,
          resources: %{"document" => owner},
          bindings: bindings,
          store: store,
          directory: directory
        )

      assert view(engine).slots[{2, 1}].outcome == "refused"
      refute_receive {:effect_started, _, _}
      send(opening, {:result, %{}})
      send(using, {:result, %{}})
    end

    test "stay/close pause and deadline retain Resource's barrier; read-only cleanup remains visible" do
      for {policy, mode} <- [{:stay, :fresh}, {:close, :fresh}, {:close, :read_only}] do
        a =
          action("open", "resource_open", %{
            "run_id" => "run",
            "resource_name" => "document",
            "data" => %{}
          })

        c = fixture(pattern: {TestPattern, :step, %{requests: [request([a])]}})
        {owner, bindings} = resource(c, policy)
        engine = start(c, resources: %{"document" => owner}, bindings: bindings)
        assert {:ok, :applied} = send_input(engine)
        assert_receive {:effect_started, opening, _}

        assert {:ok, _} =
                 Elzoo.RunResource.command(owner, %{
                   id: "opened",
                   at_ms: 2_000,
                   body:
                     {:observed, ["tenant", "account", "effect", "publish", "open"],
                      {:completed, %{opened_at_ms: 2_000}}}
                 })

        send(opening, {:result, %{}})
        assert {:ok, :applied} = RunEngine.input(engine, "consume-open", wake(), verified())
        Agent.update(c.host_mode, fn _ -> mode end)

        reply =
          RunEngine.control(engine, "pause", %{kind: :pause, pause_deadline: 50_000}, verified())

        if policy == :stay do
          assert reply == {:ok, :applied}
          assert {:ok, %{state: %{phase: :open}}} = Elzoo.RunResource.read(owner, 0)
          Agent.update(c.clock, &(&1 + 1))

          assert {:ok, :applied} =
                   RunEngine.control(
                     engine,
                     "pause",
                     %{kind: :pause, pause_deadline: 50_000},
                     verified()
                   )

          assert {:error, :input_id_conflict} =
                   RunEngine.control(
                     engine,
                     "pause",
                     %{kind: :continue, person_id: "person", run_deadline: 60_000},
                     verified(%{verified_person: "person"})
                   )

          assert view(engine).phase == :paused
          assert {:ok, %{state: %{paused: true}}} = Elzoo.RunResource.read(owner, 0)
          refute_receive {:effect_started, _, _}
          Agent.update(c.clock, fn _ -> 40_000 end)

          assert {:ok, _} =
                   Elzoo.RunResource.command(owner, %{id: "deadline", at_ms: 40_000, body: :tick})

          assert {:ok, :applied} = RunEngine.input(engine, "consume-deadline", wake(), verified())
        else
          assert {:ok, %{state: %{phase: :closing}}} = Elzoo.RunResource.read(owner, 0)
        end

        if mode == :read_only do
          assert reply == {:error, :cleanup_pending}
          assert view(engine).reconciliation == :cleanup_pending

          assert {:error, :cleanup_pending} =
                   RunEngine.input(engine, "no-retry", wake(), verified())

          refute_receive {:effect_started, _, _}
        else
          assert_receive {:effect_started, closing, request}
          assert Jason.decode!(request.arguments)["operation"] == "resource_close"

          assert {:ok, _} =
                   Elzoo.RunResource.command(owner, %{
                     id: "unknown-close",
                     at_ms: c.opts[:clock].(),
                     body:
                       {:observed, ["tenant", "account", "effect", "publish", "cleanup"],
                        {:unknown, %{}}}
                   })

          send(closing, :unknown)
          assert {:ok, %{state: %{phase: :closing}}} = Elzoo.RunResource.read(owner, 0)
          refute_receive {:effect_started, _, _}
        end
      end
    end

    test "all five Run endings drive original cleanup once, including restart and cursor replay" do
      for ending <- [:completed, :failed, :cancelled, :out_of_time, :out_of_budget] do
        a =
          action("open", "resource_open", %{
            "run_id" => "run",
            "resource_name" => "document",
            "data" => %{}
          })

        c = fixture(pattern: {TestPattern, :resource_step, {:open, request([a])}})
        {owner, bindings} = resource(c)
        engine = start(c, resources: %{"document" => owner}, bindings: bindings)
        assert {:ok, :applied} = send_input(engine)
        assert_receive {:effect_started, opening, req}
        identity = ["tenant", "account", "effect", "publish", "open"]

        assert {:ok, _} =
                 Elzoo.RunResource.command(owner, %{
                   id: "open-evidence",
                   at_ms: 2_000,
                   body: {:observed, identity, {:completed, %{opened_at_ms: 2_000}}}
                 })

        send(opening, {:result, %{}})
        assert req.arguments != ""
        assert {:ok, :applied} = RunEngine.input(engine, "consume", wake(), verified())
        assert view(engine).slots[{1, 0}].outcome == "completed"
        assert view(engine).request_count == 1

        assert {:ok, _} =
                 Elzoo.RunResource.command(owner, %{
                   id: "resource-event",
                   at_ms: 2_500,
                   body: {:event, "change", %{"revision" => 2}}
                 })

        Agent.update(c.clock, fn _ -> 2_600 end)
        assert {:ok, :applied} = RunEngine.input(engine, "consume-event", wake(), verified())
        assert view(engine).request_count == 2
        assert {:ok, :applied} = RunEngine.input(engine, "repeat-event", wake(), verified())
        assert view(engine).request_count == 2

        assert [2_500] ==
                 for(
                   row <- rows(c),
                   row.kind == "input",
                   {1, {_, %{kind: :protocol, input: %{"kind" => "resource_event"} = input}}} <-
                     [:erlang.binary_to_term(row.payload)],
                   do: input["at_ms"]
                 )

        Agent.update(c.clock, fn _ -> 3_000 end)

        event = %{
          run_id: "run",
          attempt_id: "attempt",
          operation_id: "operation",
          action_id: "open"
        }

        {:committed, sequence} =
          Elzoo.DurableLog.Writer.append(c.evidence, [
            {"completion", 1, :erlang.term_to_binary(event, [:deterministic, {:minor_version, 2}])}
          ])

        {:ok, run} = Run.status(c.run, "run")

        assert {:ok, _, _} =
                 Run.command(c.run, %{
                   kind: :complete,
                   run_id: "run",
                   attempt_id: "attempt",
                   expected_revision: run.revision,
                   outcome: ending,
                   reason: "named_ending",
                   evidence_ref:
                     if(ending == :completed, do: %{stream: "evidence", sequence: sequence})
                 })

        assert {:ok, :applied} =
                 RunEngine.input(engine, "observe-ending", wake(), verified())

        assert_receive {:effect_started, closing, close_req}
        assert Jason.decode!(close_req.arguments)["operation"] == "resource_close"

        assert {:ok, _} =
                 Elzoo.RunResource.command(owner, %{
                   id: "close-evidence",
                   at_ms: 3_000,
                   body:
                     {:observed, ["tenant", "account", "effect", "publish", "cleanup"],
                      {:completed, %{opened_at_ms: 2_000, closed_at_ms: 3_000}}}
                 })

        send(closing, {:result, %{}})
        assert {:ok, :applied} = RunEngine.input(engine, "consume-close", wake(), verified())

        assert {:ok, %{state: %{phase: :closed, final_actual: 1}}} =
                 Elzoo.RunResource.read(owner, 0)

        assert view(engine).outcome == ending
        {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
        before = DurableUnit.snapshot(unit).control
        GenServer.stop(engine)
        Agent.update(c.clock, fn _ -> 3_001 end)
        engine = start(c, resources: %{"document" => owner}, bindings: bindings)
        assert {:ok, :applied} = RunEngine.input(engine, "repeat-close", wake(), verified())
        after_restart = DurableUnit.snapshot(unit).control
        assert after_restart.budgets == before.budgets
        assert after_restart.cursors == before.cursors
        refute_receive {:effect_started, _, _}
      end
    end
  end

  describe "Sizing and sanitized evidence" do
    test "malformed outcomes cannot replace wrong action or unverified person correlation" do
      for kind <- ["tool_call", "ask_person"],
          bad <- [:action, :unverified, :person],
          oversized <- [false, true] do
        c =
          fixture(pattern: {TestPattern, :step, %{requests: [request([action("pending", kind)])]}})

        engine = start(c)
        assert {:ok, :applied} = send_input(engine)

        input =
          result(
            if(bad == :action, do: "other", else: "pending"),
            if(oversized, do: %{"data" => String.duplicate("s", 65_537)}, else: %{})
          )
          |> Map.put("schema_id", "wrong")

        input =
          if kind == "ask_person",
            do:
              input
              |> Map.put("kind", "person_answer")
              |> Map.put("person_id", if(bad == :person, do: "other", else: "person"))
              |> Map.delete("outcome"),
            else: input

        context =
          verified(%{
            occurrence: {1, 0},
            verified_person: if(bad == :unverified, do: nil, else: "person")
          })

        reply = RunEngine.input(engine, "wrong", input, context)
        assert match?({:ok, :applied}, reply) or match?({:error, _}, reply)

        if kind == "ask_person" or bad == :action do
          assert view(engine).slots[{1, 0}].phase in [:running, :waiting]
          refute view(engine).joins[1].closed
        end

        if kind == "tool_call" do
          assert_receive {:effect_started, provider, _}
          send(provider, {:result, %{}})
        end
      end
    end

    test "oversized request identities become charged bounded invalid output before join creation" do
      c =
        fixture(pattern: {TestPattern, :oversized_id, 300_000})

      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert view(engine).request_count == 1
      assert view(engine).joins == %{}
      assert view(engine).slots == %{}
      assert view(engine).classification == :invalid_request
      assert {:ok, :applied} = RunEngine.input(engine, "next", wake(), verified())
    end

    test "oversized or wrong-schema outcomes become bounded local loss or external unknown, never truncated completion" do
      for kind <- ["local_work", "tool_call"], failure <- [:size, :schema] do
        c =
          fixture(pattern: {TestPattern, :step, %{requests: [request([action("pending", kind)])]}})

        parent = self()

        bindings =
          Map.update!(
            c.opts[:bindings],
            "local_work",
            &Map.put(&1, :work, fn a -> {TestPattern, :blocked, [parent, a["payload"]]} end)
          )

        engine = start(c, bindings: bindings)
        assert {:ok, :applied} = send_input(engine)

        provider =
          if kind == "local_work" do
            assert_receive {:local_started, task}
            task
          else
            assert_receive {:effect_started, task, _}
            task
          end

        input =
          if failure == :size,
            do: result("pending", %{"data" => String.duplicate("s", 65_537)}),
            else: Map.put(result("pending"), "schema_id", "different")

        assert {:ok, :applied} =
                 RunEngine.input(
                   engine,
                   "bad-result",
                   input,
                   verified(%{occurrence: {1, 0}, dispatch: "dispatched"})
                 )

        assert view(engine).slots[{1, 0}].outcome ==
                 if(kind == "local_work", do: "failed", else: "unknown")

        assert view(engine).joins[1].outcome == :failed
        refute Enum.any?(rows(c), &String.contains?(&1.payload, String.duplicate("s", 1_000)))
        if kind == "local_work", do: send(provider, :finish), else: send(provider, {:result, %{}})
      end
    end

    test "64 active occurrences admit fully, while the next whole request cannot borrow settlement capacity" do
      first = request(for n <- 0..63, do: action("person-#{n}", "ask_person"))
      next = request([action("extra-one", "ask_person"), action("extra-two", "ask_person")])
      c = fixture(pattern: {TestPattern, :step, %{requests: [first, next]}})
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert map_size(view(engine).slots) == 64
      assert Enum.all?(view(engine).slots, fn {_, s} -> s.phase == :waiting end)

      answer =
        result("person-0")
        |> Map.delete("outcome")
        |> Map.merge(%{"kind" => "person_answer", "person_id" => "person"})

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "answer",
                 answer,
                 verified(%{occurrence: {1, 0}, verified_person: "person", actual: 0})
               )

      assert view(engine).request_count == 2
      assert map_size(view(engine).slots) == 64
      assert view(engine).slots[{1, 0}].outcome == "completed"
      refute Map.has_key?(view(engine).joins, 2)
      assert {:ok, audit} = DocumentPublication.audit(c.store, c.prefix)
      assert audit.charges[{"run", 2}] == :within_cap_invalid
    end

    test "aggregate request-map overflow is bounded and a refused checkpoint leaves full-log recovery" do
      c = fixture(pattern: {TestPattern, :sized, {:request, 70_000}})
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert view(engine).request_count == 1
      assert view(engine).slots == %{}
      assert view(engine).classification == :invalid_request
      GenServer.stop(engine)
      assert :ok = DynamicUnits.stop(c.directory, c.prefix)
      # A smaller host checkpoint allowance exercises canonical whole-snapshot
      # refusal without manufacturing a huge journal or changing the engine cap.
      unit_opts = Keyword.put(c.unit_opts, :max_checkpoint_bytes, 512)

      directory =
        start_supervised!(%{
          id: make_ref(),
          restart: :temporary,
          start:
            {DynamicUnits, :start_link,
             [
               [
                 registry: Elzoo.RunEngine.UnitRegistry,
                 supervisor: c.supervisor,
                 idle_ms: 60_000,
                 unit_options: fn _ -> unit_opts end
               ]
             ]}
        })

      engine = start(c, directory: directory)
      {:ok, unit} = DynamicUnits.find(directory, c.prefix)
      assert {:rejected, :checkpoint_too_large} = DurableUnit.checkpoint(unit)
      assert view(engine).request_count == 1
      GenServer.stop(engine)
      assert :ok = DynamicUnits.stop(directory, c.prefix)
      engine = start(c, directory: directory)
      assert view(engine).request_count == 1

      assert {:rejected, :checkpoint_too_large} =
               DurableUnit.checkpoint(elem(DynamicUnits.find(directory, c.prefix), 1))
    end

    test "64-entry gate batches and 256 lifetime actions leave refusal capacity, then refuse the next request" do
      c = fixture(pattern: {TestPattern, :batches, {0, 0}}, request_cap: 6)

      gate = %{
        id: String.duplicate("g", 128),
        version: 2_147_483_647,
        call: fn _, _ -> {:deny, String.duplicate("d", 64)} end
      }

      engine = start(c, gate: gate)
      assert {:ok, :applied} = send_input(engine)
      result = view(engine)
      assert result.request_count == 5
      assert map_size(result.slots) == 256

      assert Enum.all?(result.slots, fn {_, s} -> s.phase == :settled and s.outcome == "refused" end)

      assert map_size(result.joins) == 4
      assert Enum.all?(rows(c), &(byte_size(&1.payload) <= 16_777_216))

      batches =
        for r <- rows(c),
            r.kind == "input",
            {1, {_, %{kind: :gate} = record}} <- [:erlang.binary_to_term(r.payload)],
            do: record

      assert length(batches) == 4
      assert Enum.all?(batches, &(length(&1.entries) == 64))
      assert Enum.all?(batches, &(byte_size(:erlang.term_to_binary(&1)) < 262_144))

      for {name, id, values} <- [
            {"gate-verdict", "elzoo.run-engine.gate-verdict", batches},
            {"refusal", "elzoo.run-engine.refusal",
             for(
               row <- rows(c),
               row.kind == "input",
               {1, {_, %{kind: :protocol, input: %{"outcome" => "refused", "payload" => payload}}}} <-
                 [:erlang.binary_to_term(row.payload)],
               do: payload
             )}
          ] do
        schema =
          File.read!(Path.expand("../../examples/schemas/#{name}-v1.json", __DIR__))
          |> Jason.decode!()

        port = %{"id" => name, "direction" => "input", "schema_id" => id, "schema_version" => 1}
        assert {:ok, compiled} = Elzoo.PayloadSchema.build(port, schema)

        for value <- values do
          json = value |> Jason.encode!() |> Jason.decode!()
          assert :ok = Elzoo.PayloadSchema.check(compiled, port, json)
          refute :ok == Elzoo.PayloadSchema.check(compiled, port, Map.put(json, "extra", true))
          if name == "refusal", do: assert(byte_size(:erlang.term_to_binary(value)) <= 1_024)
        end
      end
    end

    test "compact JSON boundary and combined float-array slot overflow refuse before work" do
      for {kind, size, allowed} <- [
            {:text, 65_527, true},
            {:text, 65_528, true},
            {:text, 65_529, false},
            {:depth, 31, true},
            {:depth, 32, false},
            {:floats, 16_000, false}
          ] do
        c = fixture(pattern: {TestPattern, :sized, {kind, size}})
        engine = start(c)
        assert {:ok, :applied} = send_input(engine)
        result = wait_for(engine, &(&1.slots[{1, 0}].phase == :settled))
        assert result.slots[{1, 0}].outcome == "completed" == allowed
        assert result.request_count == 1
        assert Enum.all?(rows(c), &(byte_size(&1.payload) <= 16_777_216))
        refute inspect(view(engine)) =~ "xxxx"
      end
    end
  end

  defp flush_observer do
    receive do
      {:pattern_input, _, _} -> flush_observer()
    after
      0 -> :ok
    end
  end

  defp outcome_records(c, action_id) do
    for row <- rows(c),
        row.kind == "input",
        {1, {_id, %{kind: :protocol, input: %{"action_id" => ^action_id} = input}}} <-
          [:erlang.binary_to_term(row.payload, [:safe])],
        do: input
  end

  describe "nested_result_reaches_parent" do
    test "the parent gets the finish of its child with the declared schema, exact payload and child actual" do
      payload = %{"choice" => "approve", "score" => 3, "nested" => %{"list" => [1, 2.5, nil]}}

      {c, bindings} =
        nested_setup(%{
          "nested" => [request([action("slow", "tool_call"), finish_action("done", payload)])]
        })

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, provider, _}
      refute_receive {:pattern_input, "root", %{"action_id" => "nested"}}, 50

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "child-actual",
                 result("slow"),
                 verified(%{occurrence: {2, 0}, actual: 7, dispatch: "dispatched"})
               )

      assert_receive {:pattern_input, "root", %{"action_id" => "nested"} = input}

      assert %{
               "kind" => "action_outcome",
               "outcome" => "completed",
               "schema_id" => "result",
               "schema_version" => 1,
               "payload" => ^payload
             } = input

      refute_receive {:pattern_input, "root", %{"action_id" => "nested"}}, 50
      assert view(engine).slots[{1, 0}].outcome == "completed"
      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
      control = DurableUnit.snapshot(unit).control

      assert {:Transition, _, {:some, {:status, %{committed: 7, reserved: 0}}}} =
               Elzoo.Budget.step(control.budgets["1:0"].state, {2_000, :status})

      assert DurableUnit.snapshot(unit).slots[{1, 0}].actual == 7
      send(provider, {:result, %{}})
    end
  end

  describe "nested_result_wrong_schema" do
    test "another schema ID or another version fails the parent action without the child payload" do
      for {schema_id, version} <- [{"message", 1}, {"result", 2}] do
        {c, bindings} =
          nested_setup(%{
            "nested" => [
              request([finish_action("done", %{"secret" => "child-body"}, schema_id, version)])
            ]
          })

        schemas = Map.put(c.opts[:schemas], {"result", 2}, c.opts[:schemas][{"result", 1}])
        engine = start(c, bindings: bindings, schemas: schemas)
        assert {:ok, :applied} = send_input(engine)
        assert_receive {:pattern_input, "root", %{"action_id" => "nested"} = input}
        assert input["outcome"] == "failed"
        assert input["schema_id"] == "elzoo.run-engine.refusal"
        assert input["payload"]["reason"] == "nested_result_invalid"
        refute inspect(input) =~ "child-body"
        refute_receive {:pattern_input, "root", %{"action_id" => "nested"}}, 50
        assert view(engine).slots[{1, 0}].outcome == "failed"
        GenServer.stop(engine)
        Process.unregister(:run_engine_observer)
      end
    end
  end

  describe "nested_without_finish" do
    test "a child whose actions settle without a finish keeps the nested_completed outcome" do
      # A child without a finish ends only when generation closes: the cap is
      # exactly used (root request, child request) and a wake closes it.
      {c, bindings} =
        nested_setup(%{"nested" => [request([action("work", "local_work")])]}, request_cap: 2)

      gate = fn {:PatternStep, m}, _ ->
        if hd(m["actions"])["kind"] == "nested_callable", do: :allow, else: {:deny, "restricted"}
      end

      engine = start(c, bindings: bindings, gate: %{id: "gate", version: 1, call: gate})
      assert {:ok, :applied} = send_input(engine)
      assert view(engine).slots[{2, 0}].outcome == "refused"
      refute_receive {:pattern_input, "root", %{"action_id" => "nested"}}, 50
      assert {:ok, :applied} = RunEngine.input(engine, "wake", wake(), verified())
      assert view(engine).slots[{1, 0}].outcome == "completed"

      # Generation is closed, so no pattern input follows: the committed outcome
      # record of the parent action is the observation.
      assert [input] = outcome_records(c, "nested")
      assert input["outcome"] == "completed"
      assert input["schema_id"] == "elzoo.run-engine.refusal"
      assert input["payload"]["reason"] == "nested_completed"
    end
  end

  describe "nested_result_bounds" do
    test "a payload at the bound reaches the parent whole; one byte more is refused to the child" do
      filler = fn size -> %{"x" => String.duplicate("x", size)} end
      at_bound = filler.(65_528)
      assert byte_size(Jason.encode!(at_bound)) == 65_536
      over = filler.(65_529)
      assert byte_size(Jason.encode!(over)) == 65_537

      {c, bindings} =
        nested_setup(%{"nested" => [{:finish_sized, "done", 65_528}]})

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:pattern_input, "root", %{"action_id" => "nested"} = input}
      assert input["outcome"] == "completed"
      assert input["payload"] == at_bound
      GenServer.stop(engine)
      Process.unregister(:run_engine_observer)

      {c, bindings} =
        nested_setup(%{"nested" => [{:finish_sized, "done", 65_529}]})

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:pattern_input, "nested", %{"action_id" => "done"} = refused}
      assert refused["outcome"] == "refused"
      assert refused["payload"]["reason"] == "payload_schema"
      refute_receive {:pattern_input, "root", %{"action_id" => "nested"}}, 100
      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
      assert DurableUnit.snapshot(unit).control.callables["1:0"].closed == false
      assert view(engine).slots[{1, 0}].phase == :running
    end
  end

  describe "nested_result_survives_restart" do
    test "the kept finish is rebuilt after a restart; the parent gets one outcome and no action runs twice" do
      payload = %{"choice" => "kept", "n" => [1, 2]}

      # Sequence of the committed log (input/result pairs): 19/20 the continuation
      # that closes the child and keeps its finish, 21/22 the outcome of the finish
      # action, 23/24 the outcome of the parent action. The SQL dispatch seam loses
      # the reply of the append at the target, after it is committed: 22 is after
      # the child's finish and before the parent's outcome, 23 and 24 are inside
      # and after the parent's outcome.
      for target <- [22, 23, 24] do
        {c, bindings} = nested_setup(%{"nested" => [request([finish_action("done", payload)])]})
        {module, config} = c.store

        store =
          {module,
           %{
             config
             | test_dispatch: fn op, request, run ->
                 if op == :append and request.stream == c.prefix and request.target == target,
                   do: PostgresHarness.hook(c.store, :inject, [:append, :reply_loss])

                 config.test_dispatch.(op, request, run)
               end
           }}

        unit_opts = Keyword.put(c.unit_opts, :store, store)

        directory =
          start_supervised!(%{
            id: make_ref(),
            restart: :temporary,
            start:
              {DynamicUnits, :start_link,
               [
                 [
                   registry: Elzoo.RunEngine.UnitRegistry,
                   supervisor: c.supervisor,
                   idle_ms: 60_000,
                   unit_options: fn _ -> unit_opts end
                 ]
               ]}
          })

        engine = start(c, store: store, directory: directory, bindings: bindings)
        assert {:error, :storage_unknown} = send_input(engine)
        GenServer.stop(engine)
        assert :ok = DynamicUnits.stop(directory, c.prefix)

        engine = start(c, store: store, directory: directory, bindings: bindings)
        assert view(engine).slots[{1, 0}].outcome == "completed"
        assert view(engine).joins[1].closed

        assert [%{"outcome" => "completed", "schema_id" => "result", "payload" => ^payload}] =
                 outcome_records(c, "nested")

        # One outcome for the finish action and one for the parent action.
        assert [_] = outcome_records(c, "done")
        assert view(engine).request_count == 2
        {:ok, unit} = DynamicUnits.find(directory, c.prefix)
        assert DurableUnit.snapshot(unit).control.callables["1:0"].closed

        # The counting pattern: the child saw only its start, the root saw its
        # start and exactly one outcome for the parent action, across both engines.
        assert_receive {:pattern_input, "nested", %{"kind" => "start"}}
        refute_receive {:pattern_input, "nested", _}, 100
        assert_receive {:pattern_input, "root", %{"kind" => "start"}}
        assert_receive {:pattern_input, "root", %{"action_id" => "nested", "payload" => ^payload}}
        refute_receive {:pattern_input, "root", _}, 100

        Process.unregister(:run_engine_observer)
        flush_observer()
      end
    end
  end

  describe "first_finish_only" do
    test "a second finish of the same child does not replace the first payload" do
      {c, bindings} =
        nested_setup(%{
          "nested" => [
            request([
              finish_action("first", %{"choice" => "first"}),
              finish_action("second", %{"choice" => "second"})
            ])
          ]
        })

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:pattern_input, "root", %{"action_id" => "nested"} = input}
      assert input["outcome"] == "completed"
      assert input["payload"] == %{"choice" => "first"}
      refute_receive {:pattern_input, "root", %{"action_id" => "nested"}}, 100
      assert [%{"payload" => %{"choice" => "first"}}] = outcome_records(c, "nested")
      assert view(engine).slots[{2, 1}].phase == :settled
    end
  end

  describe "two_levels" do
    test "a child of a child reaches its parent, which finishes with it for the root; charge and shares unchanged" do
      payload = %{"choice" => "inner"}

      {c, bindings} =
        nested_setup(%{
          "nested" => [request([action("inner", "nested_callable")]), {:finish_with_seen, "mid"}],
          "inner" => [request([finish_action("inner-done", payload)])]
        })

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)

      # The middle callable received the inner payload and used it in its finish.
      assert_receive {:pattern_input, "nested", %{"action_id" => "inner"} = middle}
      assert middle["outcome"] == "completed"
      assert middle["schema_id"] == "result"
      assert middle["payload"] == payload

      # The root received what the middle callable finished with.
      assert_receive {:pattern_input, "root", %{"action_id" => "nested"} = root}
      assert root["outcome"] == "completed"
      assert root["schema_id"] == "result"
      assert root["payload"] == %{"seen" => payload}
      refute_receive {:pattern_input, "root", %{"action_id" => "nested"}}, 100

      # Shared charge count: root request, inner request, inner finish, middle finish.
      view = wait_for(engine, &(&1.slots[{1, 0}].phase == :settled))
      assert view.request_count == 4
      assert view.generation_closed == false

      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
      budgets = DurableUnit.snapshot(unit).control.budgets
      assert Enum.sort(Map.keys(budgets)) == ["1:0", "2:0", "root"]
      assert {budgets["1:0"].cap, budgets["2:0"].cap} == {10, 10}

      for {id, committed, reserved} <- [{"root", 0, 0}, {"1:0", 0, 0}, {"2:0", 0, 0}] do
        assert {:Transition, _, {:some, {:status, %{committed: ^committed, reserved: ^reserved}}}} =
                 Elzoo.Budget.step(budgets[id].state, {2_000, :status})
      end
    end
  end

  describe "payload_not_exposed" do
    @tag :capture_log
    test "a sentinel in a child's finish payload reaches the parent only, not status, logs or telemetry" do
      sentinel = "SENTINEL-6b1f0d52-child-finish-text"

      {c, bindings} =
        nested_setup(%{"nested" => [request([finish_action("done", %{"note" => sentinel})])]})

      parent = self()
      handler = "payload-not-exposed-#{System.unique_integer([:positive])}"

      events =
        for family <- [:job, :effect],
            kind <- [:start, :stop, :exception],
            do: [:elzoo, family, kind]

      :telemetry.attach_many(
        handler,
        events,
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          engine = start(c, bindings: bindings)
          assert {:ok, :applied} = send_input(engine)

          assert_receive {:pattern_input, "root", %{"action_id" => "nested"} = input}
          assert input["payload"] == %{"note" => sentinel}

          refute inspect(view(engine)) =~ sentinel
          refute inspect(:sys.get_status(engine)) =~ sentinel
          refute inspect(RunEngine.status(engine)) =~ sentinel
          GenServer.stop(engine)
        end)

      refute log =~ sentinel
      refute_received {:telemetry, _, _, _}
    end
  end

  # Helpers of the schema-map groups. The helper has no schema-entry builder, no
  # counting gate, no reporting work, no schema-map nested setup and no view of
  # state.requests, so they live here.

  defp schema_entry(id, schema) do
    port = %{"id" => id, "direction" => "input", "schema_id" => id, "schema_version" => 1}
    {:ok, compiled} = PayloadSchema.build(port, schema)

    {{id, 1},
     %{port: port, compiled: compiled, digest: :crypto.hash(:sha256, Jason.encode!(schema))}}
  end

  # The fixture's schemas plus the given action schemas (objects) and result schemas.
  defp add_schemas(c, actions, results) do
    entries =
      Enum.map(actions, &schema_entry(&1, %{"type" => "object"})) ++
        Enum.map(results, &schema_entry(&1, %{}))

    Map.merge(c.opts[:schemas], Map.new(entries))
  end

  defp act(id, kind, schema_id, payload \\ %{"value" => 7}),
    do: %{action(id, kind, payload) | "schema_id" => schema_id}

  # The binding of the fixture for `kind`, with changes.
  defp variant(c, kind, changes), do: Map.merge(c.opts[:bindings][kind], Map.new(changes))

  defp scripted_root(actions),
    do: {TestPattern, :scripted, %{name: "root", script: [request(actions)]}}

  defp reporting(parent, tag),
    do: fn a -> {Work, :run, [parent, tag, a["payload"]]} end

  # A gate that reports each call with its context and allows.
  defp counting_gate(parent) do
    %{
      id: "gate",
      version: 1,
      call: fn {:PatternStep, map}, context ->
        [a] = map["actions"]
        send(parent, {:gate, a["id"], context})
        :allow
      end
    }
  end

  defp gated(acc \\ []) do
    receive do
      {:gate, id, _} -> gated([id | acc])
    after
      100 -> Enum.sort(acc)
    end
  end

  defp snap(c) do
    {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
    DurableUnit.snapshot(unit)
  end

  defp requests(c), do: snap(c).requests

  # The committed admission facts of each occurrence.
  defp admissions(c) do
    for row <- rows(c),
        row.kind == "input",
        {1, {_id, %{kind: :admission} = record}} <- [:erlang.binary_to_term(row.payload, [:safe])],
        into: %{},
        do: {record.occurrence, record.facts}
  end

  defp outcome_for(id) do
    assert_receive {:pattern_input, "root", %{"action_id" => ^id} = input}
    input
  end

  defp provider_input(id, schema_id),
    do: Map.put(result(id), "schema_id", schema_id)

  defp forwarder do
    parent = self()

    start_supervised!(%{
      id: make_ref(),
      restart: :temporary,
      start: {Task, :start_link, [fn -> forward(parent) end]}
    })
  end

  defp forward(parent) do
    receive do
      message ->
        send(parent, {:forwarded, message})
        forward(parent)
    end
  end

  # The tool_call binding with an intent for the "other" startup entry.
  defp other_bindings(c) do
    {:ok, loaded} = Binding.load(ChangedAccountBinding)

    Map.update!(c.opts[:bindings], "tool_call", fn base ->
      Map.put(base, :facts, fn action ->
        Map.update!(base.facts.(action), :intent, fn intent ->
          %{
            intent
            | identity: ["tenant", "changed-account", "effect", "publish", action["id"]],
              binding: "other",
              binding_digest: loaded.digest
          }
        end)
      end)
    end)
  end

  describe "binding_by_schema" do
    test "each action of one request runs the work and gets the result of the binding of its own schema" do
      Process.register(self(), :run_engine_observer)
      parent = self()

      c =
        fixture(
          pattern:
            scripted_root([
              act("a1", "local_work", "a.work", %{"v" => 1}),
              act("b1", "local_work", "b.work", %{"v" => 2})
            ])
        )

      a =
        variant(c, "local_work",
          id: "bind-a",
          version: 3,
          result: {"a.result", 1},
          work: reporting(parent, "A")
        )

      b =
        variant(c, "local_work",
          id: "bind-b",
          version: 5,
          result: {"b.result", 1},
          work: reporting(parent, "B")
        )

      bindings = Map.put(c.opts[:bindings], "local_work", %{"a.work" => a, "b.work" => b})
      schemas = add_schemas(c, ["a.work", "b.work"], ["a.result", "b.result"])
      engine = start(c, bindings: bindings, schemas: schemas)
      assert {:ok, :applied} = send_input(engine)

      # The work of A ran once for the A action only, that of B once for the B action only.
      assert_receive {:work_ran, "A", %{"v" => 1}}
      assert_receive {:work_ran, "B", %{"v" => 2}}
      refute_receive {:work_ran, _, _}, 100

      assert %{"outcome" => "completed", "schema_id" => "a.result", "schema_version" => 1} =
               outcome_for("a1")

      assert %{"outcome" => "completed", "schema_id" => "b.result", "schema_version" => 1} =
               outcome_for("b1")

      refute_receive {:pattern_input, "root", %{"action_id" => _}}, 50

      admitted = admissions(c)
      assert %{binding_id: "bind-a", binding_version: 3} = admitted[{1, 0}]
      assert %{binding_id: "bind-b", binding_version: 5} = admitted[{1, 1}]
    end
  end

  describe "outcome_schema_by_binding" do
    test "an outcome is checked against the result of the binding of its own occurrence" do
      Process.register(self(), :run_engine_observer)

      c =
        fixture(
          pattern:
            scripted_root([
              act("a1", "tool_call", "a.call"),
              act("b1", "tool_call", "b.call"),
              act("b2", "tool_call", "b.call")
            ])
        )

      a = variant(c, "tool_call", id: "bind-a", version: 3)
      b = variant(c, "tool_call", id: "bind-b", version: 5, result: {"b.result", 1})
      bindings = Map.put(c.opts[:bindings], "tool_call", %{"a.call" => a, "b.call" => b})
      schemas = add_schemas(c, ["a.call", "b.call"], ["b.result"])
      engine = start(c, bindings: bindings, schemas: schemas)
      assert {:ok, :applied} = send_input(engine)

      providers =
        for _ <- 1..3,
            do:
              (
                assert_receive {:effect_started, p, _}
                p
              )

      give = fn id, key, schema_id ->
        assert {:ok, :applied} =
                 RunEngine.input(
                   engine,
                   "outcome-#{id}-#{schema_id}",
                   provider_input(id, schema_id),
                   verified(%{occurrence: key, actual: 1, dispatch: "dispatched"})
                 )
      end

      # The B occurrence expects b.result: the schema of A is invalid for it.
      give.("b1", {1, 1}, "result")

      assert %{
               "outcome" => "unknown",
               "schema_id" => "elzoo.run-engine.refusal",
               "payload" => %{"reason" => "invalid_outcome"}
             } = outcome_for("b1")

      give.("b2", {1, 2}, "b.result")
      assert %{"outcome" => "completed", "schema_id" => "b.result"} = outcome_for("b2")
      give.("a1", {1, 0}, "result")
      assert %{"outcome" => "completed", "schema_id" => "result"} = outcome_for("a1")

      slots = view(engine).slots
      assert slots[{1, 0}].outcome == "completed"
      assert slots[{1, 1}].outcome == "unknown"
      assert slots[{1, 2}].outcome == "completed"
      for provider <- providers, do: send(provider, {:result, %{}})
    end
  end

  describe "unbound_schema_refused" do
    test "a schema or kind with no binding is refused before the gate and any reservation" do
      Process.register(self(), :run_engine_observer)
      parent = self()

      c =
        fixture(
          pattern:
            scripted_root([
              act("u1", "tool_call", "u.call"),
              act("n1", "model_call", "action"),
              act("p1", "tool_call", "nowhere"),
              act("s1", "tool_call", "a.call")
            ])
        )

      tool = variant(c, "tool_call", id: "bind-a", version: 3)

      bindings =
        c.opts[:bindings]
        |> Map.put("tool_call", %{"a.call" => tool})
        |> Map.delete("model_call")

      schemas = add_schemas(c, ["a.call", "u.call"], [])
      engine = start(c, bindings: bindings, schemas: schemas, gate: counting_gate(parent))
      assert {:ok, :applied} = send_input(engine)

      # The sibling of a mapped schema is gated and runs; nothing else is.
      assert_receive {:effect_started, provider, _}
      assert gated() == ["s1"]

      for {id, reason} <- [
            {"u1", "missing_binding"},
            {"n1", "missing_binding"},
            {"p1", "payload_schema"}
          ] do
        assert %{
                 "outcome" => "refused",
                 "schema_id" => "elzoo.run-engine.refusal",
                 "payload" => %{"reason" => ^reason}
               } = outcome_for(id)
      end

      state = snap(c)

      for key <- [{1, 0}, {1, 1}, {1, 2}] do
        refute Map.has_key?(state.slots[key], :reservation)
        refute Map.has_key?(state.slots[key], :action)
      end

      assert Map.has_key?(state.slots[{1, 3}], :reservation)

      # Only the sibling holds its estimate.
      assert {:Transition, _, {:some, {:status, %{committed: 0, reserved: 1}}}} =
               Elzoo.Budget.step(state.control.budgets["root"].state, {2_000, :status})

      # The request has left state.requests; a late outcome changes nothing.
      assert requests(c) == %{}
      before = view(engine).slots

      for {id, key} <- [{"u1", {1, 0}}, {"n1", {1, 1}}, {"p1", {1, 2}}] do
        reply =
          RunEngine.input(
            engine,
            "late-#{id}",
            result(id),
            verified(%{occurrence: key, actual: 0, dispatch: "dispatched"})
          )

        assert match?({:ok, _}, reply)
        assert Process.alive?(engine)
        assert view(engine).slots == before
      end

      send(provider, {:result, %{}})
    end
  end

  describe "nested_binding_by_schema" do
    test "each nested action starts the child of its own binding and meets the result of its own binding" do
      Process.register(self(), :run_engine_observer)

      c =
        fixture(
          pattern:
            scripted_root([
              act("na", "nested_callable", "a.call", %{"child" => "a"}),
              act("nb", "nested_callable", "b.call", %{"child" => "b"})
            ])
        )

      base = c.opts[:bindings]["nested_callable"]

      nested = fn id, version, result, name ->
        %{
          base
          | id: id,
            version: version,
            result: {result, 1},
            facts: fn a -> %{base.facts.(a) | estimate: 10} end,
            nested: fn a ->
              %{
                base.nested.(a)
                | mfa: {TestPattern, :scripted},
                  initial_state: %{
                    name: name,
                    script: [
                      request([finish_action("fin-" <> name, %{"from" => name}, "a.result")])
                    ]
                  }
              }
            end
        }
      end

      bindings =
        Map.put(c.opts[:bindings], "nested_callable", %{
          "a.call" => nested.("bind-na", 3, "a.result", "child-a"),
          "b.call" => nested.("bind-nb", 5, "b.result", "child-b")
        })

      schemas = add_schemas(c, ["a.call", "b.call"], ["a.result", "b.result"])
      engine = start(c, bindings: bindings, schemas: schemas)
      assert {:ok, :applied} = send_input(engine)

      # The counting pattern: each child got the start input of its own action.
      assert_receive {:pattern_input, "child-a",
                      %{"kind" => "start", "payload" => %{"child" => "a"}}}

      assert_receive {:pattern_input, "child-b",
                      %{"kind" => "start", "payload" => %{"child" => "b"}}}

      refute_receive {:pattern_input, "child-a", %{"kind" => "start"}}, 100
      refute_receive {:pattern_input, "child-b", %{"kind" => "start"}}, 100

      # NA: the child finishes with a.result, the result of its parent's binding.
      assert %{
               "outcome" => "completed",
               "schema_id" => "a.result",
               "payload" => %{"from" => "child-a"}
             } = outcome_for("na")

      # NB: the child finishes with a.result, not b.result.
      assert %{
               "outcome" => "failed",
               "schema_id" => "elzoo.run-engine.refusal",
               "payload" => %{"reason" => "nested_result_invalid"}
             } = outcome_for("nb")

      slots = view(engine).slots
      assert slots[{1, 0}].outcome == "completed"
      assert slots[{1, 1}].outcome == "failed"
    end
  end

  describe "person_and_authority_by_schema" do
    test "each ask settles only on the verified answer of the person of its own binding" do
      Process.register(self(), :run_engine_observer)

      c =
        fixture(
          pattern:
            scripted_root([act("pa", "ask_person", "p.ask"), act("pb", "ask_person", "q.ask")])
        )

      alice = variant(c, "ask_person", id: "bind-a", version: 3, person: fn _ -> "alice" end)
      bob = variant(c, "ask_person", id: "bind-b", version: 5, person: fn _ -> "bob" end)
      bindings = Map.put(c.opts[:bindings], "ask_person", %{"p.ask" => alice, "q.ask" => bob})
      engine = start(c, bindings: bindings, schemas: add_schemas(c, ["p.ask", "q.ask"], []))
      assert {:ok, :applied} = send_input(engine)

      wait_for(engine, fn v ->
        map_size(v.slots) == 2 and Enum.all?(v.slots, fn {_, s} -> s.phase == :waiting end)
      end)

      answer = fn id, key, person ->
        input =
          result(id)
          |> Map.delete("outcome")
          |> Map.merge(%{"kind" => "person_answer", "person_id" => person})

        RunEngine.input(
          engine,
          "answer-#{id}-#{person}",
          input,
          verified(%{occurrence: key, verified_person: person})
        )
      end

      # The person of the other binding cannot settle either action.
      answer.("pa", {1, 0}, "bob")
      answer.("pb", {1, 1}, "alice")
      assert view(engine).slots[{1, 0}].phase == :waiting
      assert view(engine).slots[{1, 1}].phase == :waiting
      refute_receive {:pattern_input, "root", %{"action_id" => _}}, 50

      assert {:ok, :applied} = answer.("pa", {1, 0}, "alice")
      assert %{"kind" => "person_answer", "person_id" => "alice"} = outcome_for("pa")
      assert view(engine).slots[{1, 0}].outcome == "completed"
      assert view(engine).slots[{1, 1}].phase == :waiting
      assert {:ok, :applied} = answer.("pb", {1, 1}, "bob")
      assert %{"kind" => "person_answer", "person_id" => "bob"} = outcome_for("pb")
      assert view(engine).slots[{1, 1}].outcome == "completed"
    end

    test "the gate and the authority see the effect class of the binding of each action" do
      Process.register(self(), :run_engine_observer)
      parent = self()

      c =
        fixture(
          pattern:
            scripted_root([
              act("c1", "tool_call", "c.call"),
              act("p1", "tool_call", "p.call")
            ])
        )

      # The context policy has a rule for compute only.
      Agent.update(c.context, fn ctx ->
        %{ctx | policy: %{ctx.policy | rules: [hd(ctx.policy.rules)]}}
      end)

      compute = variant(c, "tool_call", id: "bind-c", version: 3, effect_class: "compute")
      publish = variant(c, "tool_call", id: "bind-p", version: 5)

      bindings =
        Map.put(c.opts[:bindings], "tool_call", %{"c.call" => compute, "p.call" => publish})

      engine =
        start(c,
          bindings: bindings,
          schemas: add_schemas(c, ["c.call", "p.call"], []),
          gate: counting_gate(parent)
        )

      assert {:ok, :applied} = send_input(engine)
      assert_receive {:gate, "c1", %{effect_class: "compute"}}
      assert_receive {:gate, "p1", %{effect_class: "publish"}}

      assert %{
               "outcome" => "refused",
               "schema_id" => "elzoo.run-engine.refusal",
               "payload" => %{"reason" => "authority"}
             } = outcome_for("p1")

      # The compute action is allowed and runs; the publish action never reaches the Adapter.
      assert_receive {:effect_started, provider, _}
      refute_receive {:effect_started, _, _}, 100
      assert view(engine).slots[{1, 0}].phase == :running
      assert view(engine).slots[{1, 1}].outcome == "refused"
      send(provider, {:result, %{}})
    end
  end

  describe "restart_keeps_choice" do
    test "a restart with the same schema maps keeps each action on its own binding and starts no work twice" do
      Process.register(self(), :run_engine_observer)
      parent = self()

      c =
        fixture(
          pattern:
            scripted_root([
              act("a1", "local_work", "a.work", %{"v" => 1}),
              act("b1", "local_work", "b.work", %{"v" => 2})
            ])
        )

      require_approval(c)

      a =
        variant(c, "local_work",
          id: "bind-a",
          version: 3,
          effect_class: "publish",
          result: {"a.result", 1},
          work: reporting(parent, "A")
        )

      b =
        variant(c, "local_work",
          id: "bind-b",
          version: 5,
          effect_class: "publish",
          result: {"b.result", 1},
          work: reporting(parent, "B")
        )

      map = %{"a.work" => a, "b.work" => b}
      bindings = Map.put(c.opts[:bindings], "local_work", map)
      schemas = add_schemas(c, ["a.work", "b.work"], ["a.result", "b.result"])
      engine = start(c, bindings: bindings, schemas: schemas)
      assert {:ok, :applied} = send_input(engine)

      # Both actions are admitted and wait for consent: no work yet.
      wait_for(engine, fn v ->
        map_size(v.slots) == 2 and Enum.all?(v.slots, fn {_, s} -> s.phase == :approval end)
      end)

      refute_receive {:work_ran, _, _}, 50
      GenServer.stop(engine)

      # A changed schema map is an incompatible restart, whatever the change.
      changed = [
        Map.put(map, "c.work", a),
        %{map | "b.work" => %{b | version: 6}},
        %{map | "b.work" => %{b | id: "bind-c"}},
        Map.delete(map, "b.work"),
        a
      ]

      for entry <- changed do
        opts =
          Keyword.merge(c.opts,
            bindings: Map.put(c.opts[:bindings], "local_work", entry),
            schemas: schemas
          )

        assert {:error, :incompatible_recovery} = RunEngine.start_link(opts)
      end

      # A binding replaced by a schema map holding that binding is incompatible too.
      nested = c.opts[:bindings]["nested_callable"]

      opts =
        Keyword.merge(c.opts,
          bindings: Map.put(bindings, "nested_callable", %{"message" => nested}),
          schemas: schemas
        )

      assert {:error, :incompatible_recovery} = RunEngine.start_link(opts)

      engine = start(c, bindings: bindings, schemas: schemas)

      assert Enum.all?(view(engine).slots, fn {_, slot} -> slot.phase == :approval end)
      {:ok, run} = Run.status(c.run, "run")
      assert [_, _] = run.approvals

      for %{request_key: key} <- run.approvals do
        assert {:ok, :applied} =
                 RunEngine.control(
                   engine,
                   "consent-#{inspect(key)}",
                   %{
                     kind: :approval_evidence,
                     request_key: key,
                     evidence: Map.put(consent(key), :evidence_id, "consent-" <> elem(key, 1))
                   },
                   verified()
                 )
      end

      assert_receive {:work_ran, "A", %{"v" => 1}}
      assert_receive {:work_ran, "B", %{"v" => 2}}
      refute_receive {:work_ran, _, _}, 100
      assert %{"outcome" => "completed", "schema_id" => "a.result"} = outcome_for("a1")
      assert %{"outcome" => "completed", "schema_id" => "b.result"} = outcome_for("b1")
      refute_receive {:pattern_input, "root", %{"action_id" => _}}, 50
      assert view(engine).joins[1].outcome == :all
    end

    test "a value of neither form is refused at start and starts no Unit" do
      c = fixture()
      binding = c.opts[:bindings]["local_work"]

      for entry <- [
            %{},
            %{"" => binding},
            %{String.duplicate("k", 201) => binding},
            %{1 => binding},
            %{"a\0b" => binding},
            %{"a.work" => %{version: 1}},
            %{version: 1},
            Map.put(binding, "a.work", binding)
          ] do
        opts = Keyword.put(c.opts, :bindings, Map.put(c.opts[:bindings], "local_work", entry))
        assert {:error, :invalid_options_or_recovery} = RunEngine.start_link(opts)
      end

      assert DynamicUnits.find(c.directory, c.prefix) == :not_found

      # The bound itself is valid: a key of 200 bytes starts the engine.
      bindings = Map.put(c.opts[:bindings], "local_work", %{String.duplicate("k", 200) => binding})
      assert is_pid(start(c, bindings: bindings))
    end
  end

  describe "effect_bindings_override" do
    test "no override gives the one effect entry; a given map adds its entries and is no engine option" do
      c = fixture()
      assert Map.keys(c.opts[:effect_intent]) == ["effect"]
      assert c.opts[:effect_intent]["effect"][:binding] == TestBinding
      assert c.opts[:effect_intent]["effect"][:adapter_context] == self()
      refute Keyword.has_key?(c.opts, :effect_bindings)

      forwarder = forwarder()
      c = fixture(effect_bindings: %{"other" => {ChangedAccountBinding, forwarder}})
      assert Enum.sort(Map.keys(c.opts[:effect_intent])) == ["effect", "other"]
      assert c.opts[:effect_intent]["effect"][:binding] == TestBinding
      assert c.opts[:effect_intent]["effect"][:adapter_context] == self()
      assert c.opts[:effect_intent]["other"][:binding] == ChangedAccountBinding
      assert c.opts[:effect_intent]["other"][:adapter_context] == forwarder
      refute Keyword.has_key?(c.opts, :effect_bindings)
    end

    test "a tool_call with an intent for the other entry is dispatched through that entry" do
      forwarder = forwarder()

      c =
        fixture(
          effect_bindings: %{"other" => {ChangedAccountBinding, forwarder}},
          pattern: {TestPattern, :step, %{requests: [request([action("publish", "tool_call")])]}}
        )

      engine = start(c, bindings: other_bindings(c))
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:forwarded, {:effect_started, provider, _}}
      refute_received {:effect_started, _, _}
      send(provider, {:result, %{}})
    end

    test "after consent the Run owner dispatches through the other entry, with no refused intent binding" do
      forwarder = forwarder()

      c =
        fixture(
          effect_bindings: %{"other" => {ChangedAccountBinding, forwarder}},
          pattern: {TestPattern, :step, %{requests: [request([action("publish", "tool_call")])]}}
        )

      require_approval(c)
      engine = start(c, bindings: other_bindings(c))
      assert {:ok, :applied} = send_input(engine)
      assert view(engine).slots[{1, 0}].phase == :approval
      refute_receive {:forwarded, _}, 50
      {:ok, run} = Run.status(c.run, "run")
      [%{request_key: key}] = run.approvals

      assert {:ok, :applied} =
               RunEngine.control(
                 engine,
                 "consent",
                 %{kind: :approval_evidence, request_key: key, evidence: consent(key)},
                 verified()
               )

      assert_receive {:forwarded, {:effect_started, provider, _}}
      refute_received {:effect_started, _, _}
      assert view(engine).slots[{1, 0}].phase == :running
      {:ok, run} = Run.status(c.run, "run")
      assert %{"publish" => _} = run.effects
      refute inspect(run) =~ "intent_binding"
      send(provider, {:result, %{}})
    end
  end

  describe "call_waits_past_the_default" do
    @tag timeout: 30_000
    test "every_call_waits: an input slower than 5 s returns applied; control/4 and status/1 sent during it reply after it" do
      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("ask", "ask_person")])]}}
        )

      parent = self()
      first_call = :atomics.new(1, [])

      engine =
        start(c,
          gate: %{
            id: "gate",
            version: 1,
            call: fn _, _ ->
              if :atomics.add_get(first_call, 1, 1) == 1 do
                send(parent, {:gate_barrier, self()})
                Process.sleep(5_500)
              end

              :allow
            end
          }
        )

      timed = fn call ->
        Task.async(fn ->
          sent = System.monotonic_time(:millisecond)
          reply = call.()
          {reply, System.monotonic_time(:millisecond) - sent}
        end)
      end

      input = timed.(fn -> send_input(engine) end)
      assert_receive {:gate_barrier, ^engine}
      status = timed.(fn -> RunEngine.status(engine) end)

      control =
        timed.(fn ->
          RunEngine.control(engine, "pause", %{kind: :pause, pause_deadline: 50_000}, verified())
        end)

      assert {{:ok, :applied}, input_ms} = Task.await(input, 20_000)
      assert input_ms > 5_000
      assert {{:ok, view}, status_ms} = Task.await(status, 20_000)
      assert status_ms > 5_000
      assert view.request_count == 1
      assert view.slots[{1, 0}].phase == :waiting
      assert {{:ok, :applied}, control_ms} = Task.await(control, 20_000)
      assert control_ms > 5_000
    end
  end

  defp journal(c) do
    for row <- rows(c), row.kind == "input" do
      {1, {_id, rec}} = :erlang.binary_to_term(row.payload, [:safe])

      case rec do
        %{kind: :protocol, input: input, correlation: correlation} ->
          reason = if is_map(input["payload"]), do: input["payload"]["reason"]

          {:protocol, input["kind"], input["action_id"], input["outcome"], input["at_ms"],
           correlation[:actual], correlation[:occurrence], reason}

        %{kind: kind} ->
          {kind, rec[:occurrence], rec[:actual], rec[:at_ms], rec[:phase]}
      end
    end
  end

  describe "known_costs_are_exact" do
    # The expectations below are literal rows read from the journal of the engine
    # before ELZ-190 (the clock is fixed); the repair must leave them as they were.
    test "a child with no loss gives its parent the committed amount, with the rows of main" do
      {c, bindings} =
        nested_setup(%{
          "nested" => [request([action("slow", "tool_call"), finish_action("done")])]
        })

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, provider, _}

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "child-actual",
                 result("slow"),
                 verified(%{occurrence: {2, 0}, actual: 7, dispatch: "dispatched"})
               )

      assert journal(c) == [
               {:configure, nil, nil, nil, nil},
               {:protocol, "start", nil, nil, 2000, nil, nil, nil},
               {:gate, nil, nil, 2000, nil},
               {:admission, {1, 0}, nil, 2000, nil},
               {:authorization, {1, 0}, nil, 2000, nil},
               {:nested, {1, 0}, nil, 2000, nil},
               {:gate, nil, nil, 2000, nil},
               {:admission, {2, 0}, nil, 2000, nil},
               {:authorization, {2, 0}, nil, 2000, nil},
               {:continuation, {2, 0}, nil, nil, :running},
               {:admission, {2, 1}, nil, 2000, nil},
               {:authorization, {2, 1}, nil, 2000, nil},
               {:continuation, {2, 1}, nil, nil, :running},
               {:protocol, "action_outcome", "done", "completed", 2000, 0, {2, 1}, "finished"},
               {:protocol, "action_outcome", "slow", "completed", 2000, 7, {2, 0}, nil},
               {:protocol, "action_outcome", "nested", "completed", 2000, 7, {1, 0}, nil}
             ]

      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
      assert DurableUnit.snapshot(unit).slots[{1, 0}].actual == 7
      send(provider, {:result, %{}})
    end

    test "a refused parent slot still gets its later actual, with the rows of main" do
      c =
        fixture(
          pattern:
            {TestPattern, :step, %{requests: [request([action("nested", "nested_callable")])]}},
          request_cap: 2,
          budget: %{cap: 5, unit: "credits", id: "budget", incarnation: "sealed"}
        )

      base = c.opts[:bindings]["nested_callable"]

      nested = %{
        base
        | facts: fn a -> %{base.facts.(a) | estimate: 5} end,
          nested: fn a ->
            %{
              base.nested.(a)
              | initial_state: %{
                  requests: [
                    request([action("slow", "tool_call"), action("person", "ask_person")]),
                    request([action("excess")])
                  ]
                }
            }
          end
      }

      engine = start(c, bindings: Map.put(c.opts[:bindings], "nested_callable", nested))
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, provider, _}

      answer = %{
        "type" => "input",
        "version" => 1,
        "kind" => "person_answer",
        "action_id" => "person",
        "person_id" => "person",
        "schema_id" => "message",
        "schema_version" => 1,
        "payload" => %{}
      }

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "person-answer",
                 answer,
                 verified(%{occurrence: {2, 1}, verified_person: "person", actual: 0})
               )

      assert view(engine).slots[{1, 0}].outcome == "out_of_budget"

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "child-actual",
                 result("slow"),
                 verified(%{occurrence: {2, 0}, actual: 7, dispatch: "dispatched"})
               )

      assert journal(c) == [
               {:configure, nil, nil, nil, nil},
               {:protocol, "start", nil, nil, 2000, nil, nil, nil},
               {:gate, nil, nil, 2000, nil},
               {:admission, {1, 0}, nil, 2000, nil},
               {:authorization, {1, 0}, nil, 2000, nil},
               {:nested, {1, 0}, nil, 2000, nil},
               {:gate, nil, nil, 2000, nil},
               {:admission, {2, 0}, nil, 2000, nil},
               {:authorization, {2, 0}, nil, 2000, nil},
               {:continuation, {2, 0}, nil, nil, :running},
               {:admission, {2, 1}, nil, 2000, nil},
               {:authorization, {2, 1}, nil, 2000, nil},
               {:continuation, {2, 1}, nil, nil, :waiting},
               {:protocol, "action_outcome", "person", "unknown", 2000, 0, {2, 1},
                "invalid_outcome"},
               {:run_view, nil, nil, nil, nil},
               {:protocol, "action_outcome", "nested", "out_of_budget", 2000, nil, {1, 0},
                "out_of_budget"},
               {:protocol, "action_outcome", "slow", "completed", 2000, 7, {2, 0}, nil},
               {:nested_actual, {1, 0}, 7, 2000, nil}
             ]

      {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
      assert DurableUnit.snapshot(unit).slots[{1, 0}].actual == 7
      send(provider, {:result, %{}})
    end
  end

  # ELZ-190 helpers.
  defp restart(c, engine, overrides) do
    GenServer.stop(engine)
    assert :ok = DynamicUnits.stop(c.directory, c.prefix)
    Agent.update(c.host_mode, fn _ -> :recover end)
    start(c, overrides)
  end

  defp unit_state(c) do
    {:ok, unit} = DynamicUnits.find(c.directory, c.prefix)
    DurableUnit.snapshot(unit)
  end

  defp budget_status(c, id, at \\ 2_000) do
    {:Transition, _, {:some, {:status, status}}} =
      Elzoo.Budget.step(unit_state(c).control.budgets[id].state, {at, :status})

    Map.take(status, [:committed, :reserved])
  end

  # The root asks one nested callable and then runs `after_nested`; the child runs `script`.
  defp lost_setup(
         script,
         after_nested \\ [request([finish_action("root-done", %{"action_id" => "nested"})])],
         overrides \\ []
       ) do
    root = [request([action("nested", "nested_callable")]) | after_nested]

    nested_setup(
      %{"nested" => script},
      Keyword.merge([pattern: {TestPattern, :scripted, %{name: "root", script: root}}], overrides)
    )
  end

  defp lost_child(payload),
    do: [request([action("lost", "tool_call"), finish_action("done", payload)])]

  describe "nested_lost_effect_reaches_parent" do
    test "a child with a lost Effect finishes; the parent gets the finish with no actual and the Run finishes" do
      payload = %{"choice" => "kept"}
      {c, bindings} = lost_setup(lost_child(payload))
      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, _lost, _}
      assert view(engine).slots[{1, 0}].phase == :running
      refute_receive {:pattern_input, "root", %{"action_id" => "nested"}}, 50

      engine = restart(c, engine, bindings: bindings)
      assert view(engine).slots[{2, 0}].outcome == "unknown"
      # A bounded wait: the parent must settle, it must not stay running.
      wait_for(engine, &(&1.slots[{1, 0}].phase == :settled))
      assert_receive {:pattern_input, "root", %{"action_id" => "nested"} = input}
      assert %{"outcome" => "completed", "schema_id" => "result", "payload" => ^payload} = input
      assert view(engine).slots[{1, 0}].outcome == "completed"
      assert unit_state(c).slots[{1, 0}][:actual] == nil
      assert unit_state(c).slots[{2, 0}][:actual] == nil
      assert wait_for(engine, &(&1.outcome == :completed)).outcome == :completed
      assert [_] = outcome_records(c, "nested")
      refute Enum.any?(journal(c), &match?({:nested_actual, _, _, _, _}, &1))
    end
  end

  describe "unknown_is_not_zero" do
    test "the lost reservation and the parent share stay held, nothing is committed, and the next action is out of budget" do
      payload = %{"choice" => "kept"}

      {c, bindings} =
        lost_setup(lost_child(payload), [request([action("next", "local_work")])],
          budget: %{cap: 10, unit: "credits", id: "budget", incarnation: "sealed"}
        )

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, _lost, _}
      assert budget_status(c, "root") == %{committed: 0, reserved: 10}
      assert budget_status(c, "1:0") == %{committed: 0, reserved: 1}

      engine = restart(c, engine, bindings: bindings)
      wait_for(engine, &(&1.slots[{1, 0}].phase == :settled))
      # The child Budget still holds the lost action, the parent Budget the share.
      assert budget_status(c, "1:0") == %{committed: 0, reserved: 1}
      assert budget_status(c, "root") == %{committed: 0, reserved: 10}
      assert unit_state(c).slots[{1, 0}][:actual] == nil
      # No room beside the share: the next action is refused as with a known cost of that size.
      assert wait_for(engine, &(&1.slots[{3, 0}] != nil)).slots[{3, 0}].outcome == "out_of_budget"
    end
  end

  defp bounded(fun, ms \\ 3_000) do
    task = Task.async(fun)

    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, reply} -> reply
      _ -> flunk("the call did not return in #{ms} ms")
    end
  end

  defp settled?(view, action_id),
    do: Enum.any?(view.slots, fn {_, s} -> s.action_id == action_id and s.phase == :settled end)

  defp slot_by(view, action_id),
    do: Enum.find_value(view.slots, fn {_, s} -> if s.action_id == action_id, do: s end)

  describe "no_second_outcome" do
    test "inputs and a second restart write no further outcome or actual for the parent" do
      payload = %{"choice" => "kept"}
      chain = for n <- 1..4, do: request([action("a#{n}", "local_work")])
      {c, bindings} = lost_setup(lost_child(payload), chain)
      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, _lost, _}
      engine = restart(c, engine, bindings: bindings)
      wait_for(engine, &(&1.slots[{1, 0}].phase == :settled))
      # Open slots of the Run make progress in the drain that settled the parent.
      wait_for(engine, &settled?(&1, "a4"))
      assert [_] = outcome_records(c, "nested")

      for n <- 1..3,
          do: assert({:ok, :applied} = RunEngine.input(engine, "wake-#{n}", wake(), verified()))

      assert [_] = outcome_records(c, "nested")
      refute Enum.any?(journal(c), &match?({:nested_actual, _, _, _, _}, &1))

      before = %{
        view: view(engine),
        root: budget_status(c, "root"),
        child: budget_status(c, "1:0"),
        records: length(rows(c)),
        slot: unit_state(c).slots[{1, 0}]
      }

      engine = restart(c, engine, bindings: bindings)

      assert %{
               view: view(engine),
               root: budget_status(c, "root"),
               child: budget_status(c, "1:0"),
               records: length(rows(c)),
               slot: unit_state(c).slots[{1, 0}]
             } == before

      assert [_] = outcome_records(c, "nested")
      refute Enum.any?(journal(c), &match?({:nested_actual, _, _, _, _}, &1))
    end
  end

  describe "loss_two_levels_down" do
    test "a lost Effect in a grandchild gives an unknown actual at each level, and each level keeps its reservation" do
      payload = %{"choice" => "inner"}

      {c, bindings} =
        nested_setup(
          %{
            "nested" => [
              request([action("inner", "nested_callable")]),
              {:finish_with_seen, "mid"}
            ],
            "inner" => lost_child(payload)
          },
          pattern:
            {TestPattern, :scripted,
             %{
               name: "root",
               script: [
                 request([action("nested", "nested_callable")]),
                 request([finish_action("root-done", %{"action_id" => "nested"})])
               ]
             }}
        )

      bindings =
        Map.update!(bindings, "nested_callable", fn binding ->
          %{
            binding
            | facts: fn a ->
                facts = binding.facts.(a)
                if a["id"] == "inner", do: %{facts | estimate: 5}, else: facts
              end
          }
        end)

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, _lost, _}
      engine = restart(c, engine, bindings: bindings)
      wait_for(engine, &(&1.slots[{1, 0}].phase == :settled))
      view = wait_for(engine, &(&1.outcome == :completed))

      # The slot of the grandchild's parent, inside the child, and the slot of the child, in the root.
      assert view.slots[{2, 0}].outcome == "completed"
      assert view.slots[{1, 0}].outcome == "completed"
      state = unit_state(c)
      assert state.slots[{2, 0}][:actual] == nil
      assert state.slots[{1, 0}][:actual] == nil
      assert budget_status(c, "2:0") == %{committed: 0, reserved: 1}
      assert budget_status(c, "1:0") == %{committed: 0, reserved: 5}
      assert budget_status(c, "root") == %{committed: 0, reserved: 10}
      refute Enum.any?(journal(c), &match?({:nested_actual, _, _, _, _}, &1))
    end
  end

  describe "still_waits_for_a_cost_that_can_come" do
    test "a child with a slot still open does not settle its parent; the result then gives the exact amount" do
      {c, bindings} =
        lost_setup([request([action("slow", "tool_call"), finish_action("done")])], [])

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, provider, _}
      assert unit_state(c).control.callables["1:0"].closed
      refute_receive {:pattern_input, "root", %{"action_id" => "nested"}}, 100
      assert view(engine).slots[{1, 0}].phase == :running

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "child-actual",
                 result("slow"),
                 verified(%{occurrence: {2, 0}, actual: 5, dispatch: "dispatched"})
               )

      assert_receive {:pattern_input, "root", %{"action_id" => "nested", "outcome" => "completed"}}
      assert unit_state(c).slots[{1, 0}].actual == 5
      assert budget_status(c, "root") == %{committed: 5, reserved: 0}
      send(provider, {:result, %{}})
    end

    test "a settled Resource action whose cost the cursor has not settled keeps the parent waiting" do
      open =
        action("open", "resource_open", %{
          "run_id" => "run",
          "resource_name" => "document",
          "data" => %{}
        })

      c =
        fixture(
          pattern:
            {TestPattern, :step, %{requests: [request([action("nested", "nested_callable")])]}}
        )

      {owner, bindings} =
        resource(c, :stay, %{
          budget_id: "nested-nested",
          unit: "credits",
          cost_ref: "2:0",
          generation: {"sealed", 1}
        })

      base = bindings["nested_callable"]

      bindings =
        Map.put(bindings, "nested_callable", %{
          base
          | facts: fn a -> %{base.facts.(a) | estimate: 5, deadline_ms: 55_000} end,
            nested: fn a ->
              %{
                base.nested.(a)
                | initial_state: %{requests: [request([open, finish_action("done")])]}
              }
            end
        })

      engine = start(c, resources: %{"document" => owner}, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, opening, _}

      assert {:ok, _} =
               Elzoo.RunResource.command(owner, %{
                 id: "opened",
                 at_ms: 2_000,
                 body:
                   {:observed, ["tenant", "account", "effect", "publish", "open"],
                    {:completed, %{opened_at_ms: 2_000}}}
               })

      assert {:ok, :applied} = RunEngine.input(engine, "consume-open", wake(), verified())
      # The child is closed and its Resource action settled; the cost is not settled yet.
      assert unit_state(c).control.callables["1:0"].closed
      assert slot_by(view(engine), "open").phase == :settled
      assert unit_state(c).slots[{2, 0}][:actual] == nil
      assert view(engine).slots[{1, 0}].phase == :running
      assert {:ok, _} = Elzoo.RunResource.command(owner, %{id: "close", at_ms: 3_000, body: :pause})
      Agent.update(c.clock, fn _ -> 40_000 end)

      assert {:ok, _} =
               Elzoo.RunResource.command(owner, %{id: "expiry", at_ms: 40_000, body: :tick})

      assert {:ok, :applied} = RunEngine.input(engine, "consume-close", wake(), verified())
      assert_receive {:effect_started, closing, _}
      assert view(engine).slots[{1, 0}].phase == :running

      assert {:ok, _} =
               Elzoo.RunResource.command(owner, %{
                 id: "closed",
                 at_ms: 40_000,
                 body:
                   {:observed, ["tenant", "account", "effect", "publish", "cleanup"],
                    {:completed, %{opened_at_ms: 2_000, closed_at_ms: 40_000}}}
               })

      assert {:ok, :applied} = RunEngine.input(engine, "consume-actual", wake(), verified())
      assert budget_status(c, "1:0", 40_000) == %{committed: 1, reserved: 0}
      assert view(engine).slots[{1, 0}].phase == :settled
      assert unit_state(c).slots[{1, 0}].actual == 1
      send(opening, {:result, %{}})
      send(closing, {:result, %{}})
    end
  end

  describe "finish_rules_hold" do
    test "a finish in another schema gives nested_result_invalid with an unknown actual" do
      {c, bindings} =
        lost_setup(
          [
            request([
              action("lost", "tool_call"),
              finish_action("done", %{"secret" => "child-body"}, "message", 1)
            ])
          ],
          []
        )

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, _lost, _}
      engine = restart(c, engine, bindings: bindings)
      wait_for(engine, &(&1.slots[{1, 0}].phase == :settled))
      assert_receive {:pattern_input, "root", %{"action_id" => "nested"} = input}
      assert input["outcome"] == "failed"
      assert input["payload"]["reason"] == "nested_result_invalid"
      refute inspect(input) =~ "child-body"
      assert view(engine).slots[{1, 0}].outcome == "failed"
      assert unit_state(c).slots[{1, 0}][:actual] == nil
      assert budget_status(c, "root") == %{committed: 0, reserved: 10}
    end

    test "a child that settles with no admitted finish gives nested_completed with an unknown actual" do
      {c, bindings} =
        lost_setup([request([action("lost", "tool_call")])], [], request_cap: 2)

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, _lost, _}
      engine = restart(c, engine, bindings: bindings)
      assert {:ok, :applied} = RunEngine.input(engine, "wake", wake(), verified())
      wait_for(engine, &(&1.slots[{1, 0}].phase == :settled))
      assert view(engine).slots[{1, 0}].outcome == "completed"
      assert [input] = outcome_records(c, "nested")
      assert input["payload"]["reason"] == "nested_completed"
      assert unit_state(c).slots[{1, 0}][:actual] == nil
      assert budget_status(c, "root") == %{committed: 0, reserved: 10}
    end
  end

  describe "local_work_closed_without_a_budget_step" do
    test "a child whose local work is closed at an Attempt change settles its parent as unknown, with no actual and no outcome record" do
      parent = self()
      script = [request([action("work", "local_work"), finish_action("done")])]
      {c, bindings} = lost_setup(script, [])

      bindings =
        Map.update!(
          bindings,
          "local_work",
          &Map.put(&1, :work, fn a -> {TestPattern, :blocked, [parent, a["payload"]]} end)
        )

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:local_started, task}
      assert unit_state(c).control.callables["1:0"].closed

      assert {:ok, :applied} =
               bounded(fn ->
                 RunEngine.control(
                   engine,
                   "attempt-change",
                   %{kind: :begin_attempt, attempt_id: "second"},
                   verified()
                 )
               end)

      view = view(engine)
      assert view.attempt_id == "second"
      assert view.slots[{2, 0}].outcome == "failed"
      # close_local settled the slot with no Budget step: no reservation field, no actual,
      # and the Budget of the child still holds the entry.
      state = unit_state(c)
      refute Map.has_key?(state.slots[{2, 0}], :reservation)
      refute Map.has_key?(state.slots[{2, 0}], :actual)
      assert budget_status(c, "1:0") == %{committed: 0, reserved: 1}
      # The parent of the old Attempt is settled by the change itself, in the run_view fold
      # step: the child cost is final unknown, so no actual and the root Budget keeps the share.
      assert view.slots[{1, 0}].phase == :settled
      assert view.slots[{1, 0}].outcome == "unknown"
      assert state.slots[{1, 0}][:actual] == nil
      assert budget_status(c, "root") == %{committed: 0, reserved: 10}
      # No protocol record is written for the parent.
      assert outcome_records(c, "nested") == []
      count = length(rows(c))

      engine = restart(c, engine, bindings: bindings)
      assert view(engine).slots[{1, 0}].phase == :settled
      assert view(engine).slots[{1, 0}].outcome == "unknown"
      assert budget_status(c, "root") == %{committed: 0, reserved: 10}
      assert outcome_records(c, "nested") == []
      assert length(rows(c)) == count
      send(task, :finish)
    end

    test "an expired parent whose child later closes with a lost cost stays as settled and the Run goes on" do
      payload = %{"choice" => "late"}

      script = [request([action("lost", "tool_call")]), request([finish_action("done", payload)])]

      {c, bindings} = lost_setup(script, [request([action("after", "local_work")])])

      bindings =
        Map.update!(bindings, "nested_callable", fn binding ->
          %{binding | facts: fn a -> %{binding.facts.(a) | deadline_ms: 10_000} end}
        end)

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, _lost, _}
      Agent.update(c.clock, fn _ -> 10_000 end)
      assert {:ok, :applied} = RunEngine.input(engine, "expire", wake(), verified())
      assert view(engine).slots[{1, 0}].outcome == "expired"
      expired = unit_state(c).slots[{1, 0}]
      assert expired[:actual] == nil

      engine = restart(c, engine, bindings: bindings)
      wait_for(engine, &(&1.slots[{2, 0}].phase == :settled))
      wait_for(engine, &settled?(&1, "done"))
      assert unit_state(c).control.callables["1:0"].closed
      assert view(engine).slots[{1, 0}].outcome == "expired"
      assert unit_state(c).slots[{1, 0}] == expired
      assert outcome_records(c, "nested") == []
      refute Enum.any?(journal(c), &match?({:nested_actual, _, _, _, _}, &1))
      # The next work of the Run goes on: the root asks for it and it settles.
      assert {:ok, :applied} = RunEngine.input(engine, "wake-after", wake(), verified())
      wait_for(engine, &settled?(&1, "after"))
      assert unit_state(c).slots[{1, 0}] == expired
      assert outcome_records(c, "nested") == []
    end
  end

  describe "expired_reservation_is_still_unknown" do
    test "a lost Effect whose deadline passed before the child finished gives the parent no actual, at any clock" do
      payload = %{"choice" => "kept"}

      # The child waits for a person after the loss and finishes after the deadline of the
      # lost Effect: the finish asks the Budget of the child at that later clock, which
      # sweeps the lost entry to Expired in the durable state.
      script = [
        request([action("lost", "tool_call")]),
        request([action("hold", "ask_person")]),
        request([finish_action("done", payload)])
      ]

      {c, bindings} = lost_setup(script, [])

      bindings =
        bindings
        |> Map.update!("nested_callable", fn binding ->
          %{binding | facts: fn a -> %{binding.facts.(a) | deadline_ms: 55_000} end}
        end)
        |> Map.update!("tool_call", fn binding ->
          %{
            binding
            | facts: fn a ->
                facts = binding.facts.(a)
                %{facts | deadline_ms: 20_000, intent: %{facts.intent | deadline_ms: 20_000}}
              end
          }
        end)

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, _lost, _}
      engine = restart(c, engine, bindings: bindings)
      wait_for(engine, &(&1.slots[{3, 0}] != nil))
      assert view(engine).slots[{2, 0}].outcome == "unknown"
      assert view(engine).slots[{1, 0}].phase == :running
      Agent.update(c.clock, fn _ -> 25_000 end)

      answer = %{
        "type" => "input",
        "version" => 1,
        "kind" => "person_answer",
        "action_id" => "hold",
        "person_id" => "person",
        "schema_id" => "message",
        "schema_version" => 1,
        "payload" => %{}
      }

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "person-answer",
                 answer,
                 verified(%{occurrence: {3, 0}, verified_person: "person", actual: 0})
               )

      wait_for(engine, &(&1.slots[{1, 0}].phase == :settled))
      assert view(engine).slots[{1, 0}].outcome == "completed"
      assert unit_state(c).slots[{1, 0}][:actual] == nil
      # The lost entry is Expired: it left `reserved` and nothing was committed for it.
      assert budget_status(c, "1:0", 25_000) == %{committed: 0, reserved: 0}
      assert budget_status(c, "root", 25_000) == %{committed: 0, reserved: 10}

      record = fn engine ->
        %{
          view: view(engine),
          slot: unit_state(c).slots[{1, 0}],
          records: length(rows(c)),
          budgets: for(id <- ["root", "1:0"], into: %{}, do: {id, budget_status(c, id)})
        }
      end

      first = record.(engine)
      engine = restart(c, engine, bindings: bindings)
      assert record.(engine) == first
      Agent.update(c.clock, fn _ -> 58_000 end)
      engine = restart(c, engine, bindings: bindings)
      assert record.(engine) == first
      assert [_] = outcome_records(c, "nested")
      refute Enum.any?(journal(c), &match?({:nested_actual, _, _, _, _}, &1))
    end
  end

  describe "no_loop_for_a_parent_that_cannot_settle" do
    # The root finishes in the same request that starts the child: the Run is terminal
    # and the parent slot, still running, can no longer take an outcome.
    defp finishing_root(child_script) do
      root = [
        request([action("src", "local_work")]),
        request([
          action("nested", "nested_callable"),
          finish_action("root-done", %{"action_id" => "src"})
        ])
      ]

      nested_setup(%{"nested" => child_script},
        pattern: {TestPattern, :scripted, %{name: "root", script: root}}
      )
    end

    test "a child with a known cost: the call returns and no record is written for the parent" do
      {c, bindings} = finishing_root([])
      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = bounded(fn -> send_input(engine) end)
      view = bounded(fn -> wait_for(engine, &(&1.outcome == :completed)) end, 5_000)
      assert slot_by(view, "nested").phase == :running
      assert outcome_records(c, "nested") == []

      assert {:ok, :applied} =
               bounded(fn -> RunEngine.input(engine, "wake", wake(), verified()) end)

      assert outcome_records(c, "nested") == []
    end

    test "a child with an unknown cost: the call returns and no record is written for the parent" do
      parent = self()
      script = [request([action("work", "local_work"), finish_action("done")])]
      {c, bindings} = lost_setup(script, [])

      bindings =
        Map.update!(
          bindings,
          "local_work",
          &Map.put(&1, :work, fn a -> {TestPattern, :blocked, [parent, a["payload"]]} end)
        )

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = bounded(fn -> send_input(engine) end)
      assert_receive {:local_started, task}

      assert {:ok, :applied} =
               bounded(fn ->
                 RunEngine.control(
                   engine,
                   "attempt-change",
                   %{kind: :begin_attempt, attempt_id: "second"},
                   verified()
                 )
               end)

      assert slot_by(view(engine), "work").outcome == "failed"
      assert slot_by(view(engine), "nested").phase == :settled
      assert slot_by(view(engine), "nested").outcome == "unknown"

      assert {:ok, :applied} =
               bounded(fn ->
                 RunEngine.input(engine, "wake", wake(), verified(%{attempt_id: "second"}))
               end)

      assert outcome_records(c, "nested") == []
      send(task, :finish)
    end
  end

  # ELZ-191 helpers.
  defp change_attempt(engine, attempt \\ "second") do
    assert {:ok, :applied} =
             bounded(fn ->
               RunEngine.control(
                 engine,
                 "attempt-" <> attempt,
                 %{kind: :begin_attempt, attempt_id: attempt},
                 verified()
               )
             end)
  end

  defp tool_run(overrides \\ []) do
    fixture(
      Keyword.merge(
        [pattern: {TestPattern, :step, %{requests: [request([action("publish", "tool_call")])]}}],
        overrides
      )
    )
  end

  defp wait_unit(c, predicate, left \\ 400)

  defp wait_unit(c, _, 0),
    do: flunk("the durable state did not reach the expected phase: #{inspect(unit_state(c).slots)}")

  defp wait_unit(c, predicate, left) do
    if predicate.(unit_state(c)),
      do: :ok,
      else:
        (
          Process.sleep(5)
          wait_unit(c, predicate, left - 1)
        )
  end

  # A context function that stops the engine at its n-th call: it blocks (:block) or
  # suspends the Run owner and goes on (:suspend_run). The durable state is what the
  # engine had committed before.
  defp trap_context(c, at_call, mode) do
    parent = self()
    calls = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    fn ->
      if Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) == at_call do
        case mode do
          :block ->
            send(parent, {:trapped, self()})

            receive do
              :release -> :ok
            after
              30_000 -> :ok
            end

          :suspend_run ->
            :sys.suspend(c.run)
            send(parent, {:trapped, self()})
        end
      end

      Agent.get(c.context, & &1)
    end
  end

  # The engine process dies where it stands; the unit restarts as after a crash.
  defp halt_engine(c, engine) do
    ref = Process.monitor(engine)
    Process.exit(engine, :kill)
    assert_receive {:DOWN, ^ref, :process, ^engine, _}, 5_000
    assert :ok = DynamicUnits.stop(c.directory, c.prefix)
    Agent.update(c.host_mode, fn _ -> :recover end)
  end

  defp change_attempt_down(c, attempt \\ "second") do
    {:ok, run} = Run.status(c.run, "run")

    assert {:ok, _, _} =
             Run.command(c.run, %{
               kind: :begin_attempt,
               run_id: "run",
               attempt_id: attempt,
               expected_revision: run.revision
             })
  end

  defp send_async(engine, id \\ "start") do
    spawn(fn ->
      try do
        RunEngine.input(engine, id, start_input(), verified())
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp budgets(c),
    do: for({id, _} <- unit_state(c).control.budgets, into: %{}, do: {id, budget_status(c, id)})

  defp footprint(c, engine),
    do: %{
      view: view(engine),
      slots: unit_state(c).slots,
      budgets: budgets(c),
      records: length(rows(c))
    }

  # A late result for the slot, with the Attempt of the slot and with the new one.
  defp late_results(engine, key, id) do
    for {attempt, tag} <- [{"attempt", "old"}, {"second", "new"}] do
      assert {:ok, _} =
               RunEngine.input(
                 engine,
                 "late-#{tag}-#{id}",
                 result(id),
                 verified(%{
                   attempt_id: attempt,
                   occurrence: key,
                   actual: 1,
                   dispatch: "dispatched"
                 })
               )
    end
  end

  describe "sent_slot_becomes_unknown" do
    test "a dispatched tool action becomes unknown, keeps its reservation and is never sent again" do
      c = tool_run()
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, task, _}, 5_000
      before = budget_status(c, "root")
      assert before == %{committed: 0, reserved: 1}
      reservation = unit_state(c).slots[{1, 0}].reservation

      change_attempt(engine)
      assert view(engine).slots[{1, 0}].phase == :settled
      assert view(engine).slots[{1, 0}].outcome == "unknown"
      slot = unit_state(c).slots[{1, 0}]
      assert slot[:actual] == nil
      assert slot.reservation == reservation
      assert budget_status(c, "root") == before
      assert view(engine).joins[1].closed

      engine = restart(c, engine, [])
      refute_receive {:effect_started, _, _}, 300
      assert unit_state(c).slots[{1, 0}] == slot
      assert budget_status(c, "root") == before

      late_results(engine, {1, 0}, "publish")
      assert unit_state(c).slots[{1, 0}] == slot
      assert budget_status(c, "root") == before
      refute_receive {:effect_started, _, _}, 300
      send(task, {:result, %{}})
    end

    test "a slot in reconcile becomes unknown with its reservation held" do
      c = tool_run()
      Agent.update(c.host_mode, fn _ -> :read_only end)
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert %{phase: :reconcile, reconciliation: :read_only} = view(engine).slots[{1, 0}]
      before = budget_status(c, "root")
      assert before == %{committed: 0, reserved: 1}

      change_attempt(engine)
      assert view(engine).slots[{1, 0}].phase == :settled
      assert view(engine).slots[{1, 0}].outcome == "unknown"
      slot = unit_state(c).slots[{1, 0}]
      assert slot[:actual] == nil
      assert budget_status(c, "root") == before

      Agent.update(c.host_mode, fn _ -> :fresh end)
      engine = restart(c, engine, [])
      refute_receive {:effect_started, _, _}, 300
      assert unit_state(c).slots[{1, 0}] == slot
      late_results(engine, {1, 0}, "publish")
      assert unit_state(c).slots[{1, 0}] == slot
      assert budget_status(c, "root") == before
      refute_receive {:effect_started, _, _}, 300
    end

    test "a waiting ask_person becomes unknown and a late answer changes nothing" do
      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("ask", "ask_person")])]}}
        )

      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert view(engine).slots[{1, 0}].phase == :waiting
      before = budget_status(c, "root")
      assert before == %{committed: 0, reserved: 1}

      change_attempt(engine)
      assert view(engine).slots[{1, 0}].phase == :settled
      assert view(engine).slots[{1, 0}].outcome == "unknown"
      slot = unit_state(c).slots[{1, 0}]
      assert slot[:actual] == nil
      assert budget_status(c, "root") == before

      engine = restart(c, engine, [])

      answer = %{
        "type" => "input",
        "version" => 1,
        "kind" => "person_answer",
        "action_id" => "ask",
        "person_id" => "person",
        "schema_id" => "message",
        "schema_version" => 1,
        "payload" => %{}
      }

      for {attempt, tag} <- [{"attempt", "old"}, {"second", "new"}] do
        assert {:ok, _} =
                 RunEngine.input(
                   engine,
                   "late-answer-#{tag}",
                   answer,
                   verified(%{
                     attempt_id: attempt,
                     occurrence: {1, 0},
                     verified_person: "person",
                     actual: 1
                   })
                 )
      end

      assert unit_state(c).slots[{1, 0}] == slot
      assert budget_status(c, "root") == before
    end

    test "a tool action that waits for approval with a request key may have been sent: unknown, held, never sent" do
      c = tool_run()
      require_approval(c)
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert view(engine).slots[{1, 0}].phase == :approval
      assert is_tuple(unit_state(c).slots[{1, 0}].request_key)
      {:ok, run} = Run.status(c.run, "run")
      [%{request_key: key}] = run.approvals
      before = budget_status(c, "root")
      assert before == %{committed: 0, reserved: 1}

      change_attempt(engine)
      assert view(engine).slots[{1, 0}].outcome == "unknown"
      slot = unit_state(c).slots[{1, 0}]
      assert slot[:actual] == nil
      assert budget_status(c, "root") == before

      # The Run no longer knows the approval request of the older Attempt.
      assert {:error, {:run_control, {:refused, :unknown_request}}} =
               RunEngine.control(
                 engine,
                 "consent",
                 %{kind: :approval_evidence, request_key: key, evidence: consent(key)},
                 verified()
               )

      refute_receive {:effect_started, _, _}, 300
      engine = restart(c, engine, [])
      refute_receive {:effect_started, _, _}, 300
      assert unit_state(c).slots[{1, 0}] == slot
      assert budget_status(c, "root") == before
      assert view(engine).slots[{1, 0}].outcome == "unknown"
    end
  end

  describe "unsent_slot_is_released" do
    # Held by stopping the engine process where it stands: the slot keeps the phase of its
    # last committed record; the Attempt changes while the engine is down; a new engine
    # folds the view record at its start.
    defp unsent_case(c, trap_opts, phase, reserved_before) do
      engine = start(c, trap_opts)
      send_async(engine)
      assert_receive {:trapped, _}, 5_000
      wait_unit(c, &(&1.slots[{1, 0}] != nil and &1.slots[{1, 0}].phase == phase))
      assert budget_status(c, "root") == %{committed: 0, reserved: reserved_before}
      halt_engine(c, engine)
      if trap_opts[:resume_run], do: :sys.resume(c.run)
      change_attempt_down(c)
      engine = start(c)
      assert view(engine).slots[{1, 0}].phase == :settled
      assert view(engine).slots[{1, 0}].outcome == "refused"
      slot = unit_state(c).slots[{1, 0}]
      assert slot.actual == 0
      assert budget_status(c, "root") == %{committed: 0, reserved: 0}
      refute_receive {:effect_started, _, _}, 300
      engine = restart(c, engine, [])
      refute_receive {:effect_started, _, _}, 300
      assert unit_state(c).slots[{1, 0}] == slot
      assert budget_status(c, "root") == %{committed: 0, reserved: 0}
      assert view(engine).slots[{1, 0}].outcome == "refused"
    end

    test "a slot in checking is refused with nothing held" do
      c = tool_run()
      parent = self()

      gate = %{
        id: "gate",
        version: 1,
        call: fn _, _ ->
          send(parent, {:trapped, self()})

          receive do
            :release -> :allow
          after
            30_000 -> :allow
          end
        end
      }

      unsent_case(c, [gate: gate], :checking, 0)
    end

    test "a slot in allowed is refused with nothing held" do
      c = tool_run()
      parent = self()
      armed = start_supervised!({Agent, fn -> true end}, id: make_ref())
      base = c.opts[:bindings]["tool_call"]

      bindings =
        Map.put(c.opts[:bindings], "tool_call", %{
          base
          | facts: fn a ->
              if Agent.get_and_update(armed, &{&1, false}) do
                send(parent, {:trapped, self()})

                receive do
                  :release -> :ok
                after
                  30_000 -> :ok
                end
              end

              base.facts.(a)
            end
        })

      unsent_case(c, [bindings: bindings], :allowed, 0)
    end

    test "a slot in authorizing is refused and its reservation is released" do
      c = tool_run()
      unsent_case(c, [context: trap_context(c, 1, :block)], :authorizing, 1)
    end

    test "a slot in refusing is refused" do
      c = tool_run()
      gate = %{id: "gate", version: 1, call: fn _, _ -> {:deny, "restricted"} end}
      unsent_case(c, [gate: gate, context: trap_context(c, 1, :block)], :refusing, 0)
    end

    test "a slot waiting for approval with no request key is refused and its reservation is released" do
      c = tool_run()
      require_approval(c)
      unsent_case(c, [context: trap_context(c, 1, :suspend_run), resume_run: true], :approval, 1)
    end

    test "a ready tool or model slot is refused, released, and never sent, also after a restart" do
      for kind <- ["tool_call", "model_call"] do
        c =
          fixture(pattern: {TestPattern, :step, %{requests: [request([action("publish", kind)])]}})

        unsent_case(c, [context: trap_context(c, 2, :block)], :ready, 1)
      end
    end

    test "a non-intent slot waiting for approval with a request key is refused and released" do
      c =
        fixture(
          pattern: {TestPattern, :step, %{requests: [request([action("work", "local_work")])]}}
        )

      require_approval(c)
      bindings = Map.update!(c.opts[:bindings], "local_work", &%{&1 | effect_class: "publish"})
      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert view(engine).slots[{1, 0}].phase == :approval
      assert is_tuple(unit_state(c).slots[{1, 0}].request_key)
      {:ok, run} = Run.status(c.run, "run")
      [%{request_key: key}] = run.approvals
      assert budget_status(c, "root") == %{committed: 0, reserved: 1}

      change_attempt(engine)
      assert view(engine).slots[{1, 0}].outcome == "refused"
      slot = unit_state(c).slots[{1, 0}]
      assert slot.actual == 0
      assert budget_status(c, "root") == %{committed: 0, reserved: 0}

      # The Run no longer knows the approval request of the older Attempt.
      assert {:error, {:run_control, {:refused, :unknown_request}}} =
               RunEngine.control(
                 engine,
                 "consent",
                 %{kind: :approval_evidence, request_key: key, evidence: consent(key)},
                 verified()
               )

      engine = restart(c, engine, bindings: bindings)
      assert unit_state(c).slots[{1, 0}] == slot
      assert view(engine).slots[{1, 0}].outcome == "refused"
      assert budget_status(c, "root") == %{committed: 0, reserved: 0}
    end
  end

  # A nested parent whose child asks `a` (a tool whose cost is known when it is settled) and
  # then `w`, an action that waits for approval: the child cannot finish before the change.
  defp known_cost_child do
    {c, bindings} =
      lost_setup(
        [
          request([action("a", "tool_call")]),
          request([action("w", "local_work"), finish_action("done")])
        ],
        []
      )

    require_approval(c)

    bindings =
      bindings
      |> Map.update!("local_work", &%{&1 | effect_class: "publish"})
      |> Map.update!("tool_call", &%{&1 | effect_class: "compute"})

    {c, bindings}
  end

  describe "nested_parent_and_child_close" do
    test "a child with a kept finish and only known costs: the parent gets the committed amount, the finish is dropped" do
      {c, bindings} = known_cost_child()
      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, task, _}, 5_000

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "a-result",
                 result("a"),
                 verified(%{occurrence: {2, 0}, actual: 5, dispatch: "dispatched"})
               )

      assert slot_by(view(engine), "w").phase == :approval
      assert slot_by(view(engine), "done").phase == :settled
      assert unit_state(c).control.callables["1:0"][:finish] != nil
      assert view(engine).slots[{1, 0}].phase == :running
      assert budget_status(c, "1:0") == %{committed: 5, reserved: 1}
      assert budget_status(c, "root") == %{committed: 0, reserved: 10}

      change_attempt(engine)
      view = view(engine)
      assert Enum.all?(view.slots, fn {_, s} -> s.phase == :settled end)
      assert slot_by(view, "w").outcome == "refused"
      assert view.slots[{1, 0}].outcome == "unknown"
      state = unit_state(c)
      assert state.slots[{1, 0}].actual === 5
      assert state.slots[{3, 0}].actual === 0
      assert state.control.callables["1:0"].closed
      refute Map.has_key?(state.control.callables["1:0"], :finish)
      assert budget_status(c, "1:0") == %{committed: 5, reserved: 0}
      assert budget_status(c, "root") == %{committed: 5, reserved: 0}
      refute_receive {:pattern_input, "root", %{"action_id" => "nested"}}, 300
      assert outcome_records(c, "nested") == []

      engine = restart(c, engine, bindings: bindings)
      assert unit_state(c).slots[{1, 0}] == state.slots[{1, 0}]
      refute_receive {:pattern_input, "root", %{"action_id" => "nested"}}, 300
      assert view(engine).slots[{1, 0}].outcome == "unknown"
      send(task, {:result, %{}})
    end

    test "a child with a sent action: the parent is settled with no actual, its share stays held, the finish is dropped" do
      {c, bindings} =
        lost_setup([request([action("slow", "tool_call"), finish_action("done")])], [])

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, provider, _}, 5_000
      assert unit_state(c).control.callables["1:0"][:finish] != nil
      assert view(engine).slots[{1, 0}].phase == :running

      change_attempt(engine)
      view = view(engine)
      assert Enum.all?(view.slots, fn {_, s} -> s.phase == :settled end)
      assert slot_by(view, "slow").outcome == "unknown"
      assert view.slots[{1, 0}].outcome == "unknown"
      state = unit_state(c)
      assert state.slots[{1, 0}][:actual] == nil
      assert state.control.callables["1:0"].closed
      refute Map.has_key?(state.control.callables["1:0"], :finish)
      assert budget_status(c, "1:0") == %{committed: 0, reserved: 1}
      assert budget_status(c, "root") == %{committed: 0, reserved: 10}
      refute_receive {:pattern_input, "root", %{"action_id" => "nested"}}, 300
      assert outcome_records(c, "nested") == []
      send(provider, {:result, %{}})
    end

    test "two levels close deepest first: every level reads its closed child" do
      {c, bindings} =
        nested_setup(
          %{
            "nested" => [request([action("inner", "nested_callable")])],
            "inner" => [
              request([action("a", "tool_call")]),
              request([action("w", "local_work")])
            ]
          },
          pattern:
            {TestPattern, :scripted,
             %{name: "root", script: [request([action("nested", "nested_callable")])]}}
        )

      require_approval(c)

      bindings =
        bindings
        |> Map.update!("local_work", &%{&1 | effect_class: "publish"})
        |> Map.update!("tool_call", &%{&1 | effect_class: "compute"})

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, task, _}, 5_000

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "a-result",
                 result("a"),
                 verified(%{occurrence: {3, 0}, actual: 4, dispatch: "dispatched"})
               )

      assert slot_by(view(engine), "w").phase == :approval
      change_attempt(engine)
      view = view(engine)
      assert Enum.all?(view.slots, fn {_, s} -> s.phase == :settled end)
      state = unit_state(c)
      # The grandchild settled first: its parent read a known cost, and so did the root slot.
      assert state.slots[{2, 0}].actual === 4
      assert state.slots[{1, 0}].actual === 4
      assert budget_status(c, "2:0") == %{committed: 4, reserved: 0}
      assert budget_status(c, "1:0") == %{committed: 4, reserved: 0}
      assert budget_status(c, "root") == %{committed: 4, reserved: 0}
      send(task, {:result, %{}})
    end

    test "two levels with a sent action: every level is unknown and keeps its reservation" do
      {c, bindings} =
        nested_setup(
          %{
            "nested" => [request([action("inner", "nested_callable")])],
            "inner" => [request([action("slow", "tool_call")])]
          },
          pattern:
            {TestPattern, :scripted,
             %{name: "root", script: [request([action("nested", "nested_callable")])]}}
        )

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, task, _}, 5_000
      change_attempt(engine)
      view = view(engine)
      assert Enum.all?(view.slots, fn {_, s} -> s.phase == :settled and s.outcome == "unknown" end)
      state = unit_state(c)
      assert Enum.all?(state.slots, fn {_, s} -> s[:actual] == nil end)
      assert budget_status(c, "2:0") == %{committed: 0, reserved: 1}
      assert budget_status(c, "1:0") == %{committed: 0, reserved: 10}
      assert budget_status(c, "root") == %{committed: 0, reserved: 10}
      send(task, {:result, %{}})
    end
  end

  describe "new_attempt_works" do
    test "a wake in the new Attempt asks a new request that runs to its outcome, with no open slot left" do
      c =
        tool_run(
          pattern:
            {TestPattern, :step,
             %{requests: [request([action("publish", "tool_call")]), request([action("next")])]}}
        )

      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, task, _}, 5_000
      change_attempt(engine)
      state = unit_state(c)

      assert Enum.all?(state.slots, fn {_, s} ->
               s.phase == :settled and not is_map_key(s, :pending_input)
             end)

      assert view(engine).phase == :active
      old = state.slots[{1, 0}]

      assert {:ok, :applied} =
               bounded(fn ->
                 RunEngine.input(engine, "wake-second", wake(), verified(%{attempt_id: "second"}))
               end)

      view = wait_for(engine, &settled?(&1, "next"), 1_000)
      assert slot_by(view, "next").outcome == "completed"
      assert slot_by(view, "next").phase == :settled
      assert unit_state(c).slots[{1, 0}] == old
      assert budget_status(c, "root") == %{committed: 1, reserved: 1}
      send(task, {:result, %{}})
    end

    test "a second change closes what the second Attempt opened and leaves the first settlements as they were" do
      c =
        tool_run(
          pattern:
            {TestPattern, :step,
             %{
               requests: [
                 request([action("publish", "tool_call")]),
                 request([action("again", "tool_call")])
               ]
             }}
        )

      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, first, _}, 5_000
      change_attempt(engine)
      closed = unit_state(c).slots[{1, 0}]

      assert {:ok, :applied} =
               bounded(fn ->
                 RunEngine.input(engine, "wake-second", wake(), verified(%{attempt_id: "second"}))
               end)

      assert_receive {:effect_started, second, _}, 5_000
      assert view(engine).slots[{2, 0}].phase == :running
      assert unit_state(c).slots[{2, 0}].attempt_id == "second"
      assert budget_status(c, "root") == %{committed: 0, reserved: 2}

      change_attempt(engine, "third")
      assert view(engine).slots[{2, 0}].phase == :settled
      assert view(engine).slots[{2, 0}].outcome == "unknown"
      assert unit_state(c).slots[{1, 0}] == closed
      assert budget_status(c, "root") == %{committed: 0, reserved: 2}
      engine = restart(c, engine, [])
      refute_receive {:effect_started, _, _}, 300
      assert unit_state(c).slots[{1, 0}] == closed
      assert view(engine).attempt_id == "third"
      send(first, {:result, %{}})
      send(second, {:result, %{}})
    end
  end

  describe "run_ends_and_unit_configures" do
    test "after the change the Run ends and a new Run with another id configures on the same unit" do
      c = tool_run()
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, task, _}, 5_000
      change_attempt(engine)
      {:ok, run} = Run.status(c.run, "run")

      assert {:ok, _, _} =
               Run.command(c.run, %{
                 kind: :complete,
                 run_id: "run",
                 attempt_id: "second",
                 outcome: :failed,
                 reason: "test",
                 evidence_ref: nil,
                 expected_revision: run.revision
               })

      engine = restart(c, engine, [])
      assert view(engine).phase == :terminal
      assert view(engine).outcome == :failed
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
      engine = start(c, run_id: "period-two", pattern: next)
      assert view(engine).run_id == "period-two"
      assert view(engine).slots == %{}
      context = verified(%{run_id: "period-two", attempt_id: "third"})
      assert {:ok, :applied} = RunEngine.input(engine, "period-two-input", start_input(), context)
      assert wait_for(engine, &settled?(&1, "again"), 1_000).phase == :active
      send(task, {:result, %{}})
    end
  end

  describe "resource_cost_still_arrives" do
    defp resource_open_action,
      do:
        action("open", "resource_open", %{
          "run_id" => "run",
          "resource_name" => "document",
          "data" => %{}
        })

    # The open action is sent, the Attempt changes, then the Resource observes the open,
    # the close and the final cost: the cursor settles the Budget of the action.
    defp resource_cursor(c, engine, owner) do
      second = verified(%{attempt_id: "second"})

      assert {:ok, _} =
               Elzoo.RunResource.command(owner, %{
                 id: "opened",
                 at_ms: 2_000,
                 body:
                   {:observed, ["tenant", "account", "effect", "publish", "open"],
                    {:completed, %{opened_at_ms: 2_000}}}
               })

      assert {:ok, :applied} = RunEngine.input(engine, "consume-open", wake(), second)
      assert {:ok, _} = Elzoo.RunResource.command(owner, %{id: "close", at_ms: 3_000, body: :pause})
      Agent.update(c.clock, fn _ -> 40_000 end)

      assert {:ok, _} =
               Elzoo.RunResource.command(owner, %{id: "expiry", at_ms: 40_000, body: :tick})

      assert {:ok, :applied} = RunEngine.input(engine, "consume-close", wake(), second)
      assert_receive {:effect_started, closing, _}, 5_000

      assert {:ok, _} =
               Elzoo.RunResource.command(owner, %{
                 id: "closed",
                 at_ms: 40_000,
                 body:
                   {:observed, ["tenant", "account", "effect", "publish", "cleanup"],
                    {:completed, %{opened_at_ms: 2_000, closed_at_ms: 40_000}}}
               })

      assert {:ok, :applied} = RunEngine.input(engine, "consume-actual", wake(), second)
      closing
    end

    test "a root Resource action open at the change: the cursor settles its Budget and nothing fails" do
      c = fixture(pattern: {TestPattern, :step, %{requests: [request([resource_open_action()])]}})
      {owner, bindings} = resource(c)
      engine = start(c, resources: %{"document" => owner}, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, opening, _}, 5_000

      change_attempt(engine)
      assert slot_by(view(engine), "open").phase == :settled
      assert slot_by(view(engine), "open").outcome == "unknown"
      assert unit_state(c).slots[{1, 0}][:actual] == nil
      assert budget_status(c, "root") == %{committed: 0, reserved: 1}

      closing = resource_cursor(c, engine, owner)
      assert budget_status(c, "root", 40_000) == %{committed: 1, reserved: 0}
      assert unit_state(c).slots[{1, 0}].actual == 1
      assert view(engine).reconciliation == nil
      assert {:ok, %{state: _}} = Elzoo.RunResource.read(owner, 0)

      engine = restart(c, engine, resources: %{"document" => owner}, bindings: bindings)
      assert view(engine).reconciliation == nil
      assert budget_status(c, "root", 40_000) == %{committed: 1, reserved: 0}
      send(opening, {:result, %{}})
      send(closing, {:result, %{}})
    end

    defp nested_resource_run do
      c =
        fixture(
          pattern:
            {TestPattern, :step, %{requests: [request([action("nested", "nested_callable")])]}}
        )

      {owner, bindings} =
        resource(c, :stay, %{
          budget_id: "nested-nested",
          unit: "credits",
          cost_ref: "2:0",
          generation: {"sealed", 1}
        })

      base = bindings["nested_callable"]

      bindings =
        Map.put(bindings, "nested_callable", %{
          base
          | facts: fn a -> %{base.facts.(a) | estimate: 5, deadline_ms: 55_000} end,
            nested: fn a ->
              %{
                base.nested.(a)
                | initial_state: %{
                    requests: [request([resource_open_action(), finish_action("done")])]
                  }
              }
            end
        })

      {c, owner, bindings}
    end

    test "a Resource action inside a child at the change: the cursor settles the child Budget and the parent gets its actual" do
      {c, owner, bindings} = nested_resource_run()
      engine = start(c, resources: %{"document" => owner}, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, opening, _}, 5_000
      assert unit_state(c).control.callables["1:0"][:finish] != nil

      change_attempt(engine)
      assert view(engine).slots[{1, 0}].phase == :settled
      assert view(engine).slots[{1, 0}].outcome == "unknown"
      assert slot_by(view(engine), "open").outcome == "unknown"
      assert unit_state(c).slots[{1, 0}][:actual] == nil
      refute Map.has_key?(unit_state(c).control.callables["1:0"], :finish)
      # The cost can still come: the child Budget and the share stay held.
      assert budget_status(c, "1:0") == %{committed: 0, reserved: 1}
      assert budget_status(c, "root") == %{committed: 0, reserved: 5}

      closing = resource_cursor(c, engine, owner)
      assert budget_status(c, "1:0", 40_000) == %{committed: 1, reserved: 0}
      assert unit_state(c).slots[{1, 0}].actual == 1
      assert budget_status(c, "root", 40_000) == %{committed: 1, reserved: 0}
      assert Enum.any?(journal(c), &match?({:nested_actual, {1, 0}, 1, _, _}, &1))
      assert outcome_records(c, "nested") == []
      assert view(engine).reconciliation == nil
      send(opening, {:result, %{}})
      send(closing, {:result, %{}})
    end
  end

  describe "replay_is_equal" do
    test "a sent tool action: a restart after the change gives the same view, Budgets and journal" do
      c = tool_run()
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, task, _}, 5_000
      change_attempt(engine)
      first = footprint(c, engine)
      assert first.budgets == %{"root" => %{committed: 0, reserved: 1}}
      engine = restart(c, engine, [])
      assert footprint(c, engine) == first
      refute_receive {:effect_started, _, _}, 300
      engine = restart(c, engine, [])
      assert footprint(c, engine) == first
      send(task, {:result, %{}})
    end

    test "a nested parent and its child: a restart after the change gives the same view, Budgets and journal" do
      {c, bindings} = known_cost_child()
      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, task, _}, 5_000

      assert {:ok, :applied} =
               RunEngine.input(
                 engine,
                 "a-result",
                 result("a"),
                 verified(%{occurrence: {2, 0}, actual: 5, dispatch: "dispatched"})
               )

      change_attempt(engine)
      first = footprint(c, engine)
      assert first.budgets["root"] == %{committed: 5, reserved: 0}
      assert first.budgets["1:0"] == %{committed: 5, reserved: 0}
      engine = restart(c, engine, bindings: bindings)
      assert footprint(c, engine) == first
      send(task, {:result, %{}})
    end

    test "a Resource action in a child: a restart after the change and after the cursor gives the same state" do
      {c, owner, bindings} = nested_resource_run()
      overrides = [resources: %{"document" => owner}, bindings: bindings]
      engine = start(c, overrides)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, opening, _}, 5_000
      change_attempt(engine)
      first = footprint(c, engine)
      engine = restart(c, engine, overrides)
      assert footprint(c, engine) == first

      closing = resource_cursor(c, engine, owner)
      settled = footprint(c, engine)
      assert settled.budgets["1:0"] == budget_status(c, "1:0", 2_000)
      engine = restart(c, engine, overrides)
      assert footprint(c, engine) == settled
      send(opening, {:result, %{}})
      send(closing, {:result, %{}})
    end
  end

  describe "first_settlement_wins" do
    test "an outcome of either Attempt and an expiry leave a closed tool slot as it was" do
      c = tool_run()
      engine = start(c)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, task, _}, 5_000
      change_attempt(engine)
      slot = unit_state(c).slots[{1, 0}]
      before = budgets(c)

      late_results(engine, {1, 0}, "publish")
      assert unit_state(c).slots[{1, 0}] == slot
      assert budgets(c) == before

      # The clock passes the deadline of the action; an input of the new Attempt arrives.
      Agent.update(c.clock, fn _ -> 41_000 end)

      assert {:ok, :applied} =
               RunEngine.input(engine, "expire", wake(), verified(%{attempt_id: "second"}))

      assert unit_state(c).slots[{1, 0}] == slot
      assert view(engine).slots[{1, 0}].outcome == "unknown"
      assert budgets(c) == before
      send(task, {:result, %{}})
    end

    test "an outcome of either Attempt and an expiry leave a closed nested parent as it was" do
      {c, bindings} =
        lost_setup([request([action("slow", "tool_call"), finish_action("done")])], [])

      engine = start(c, bindings: bindings)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, provider, _}, 5_000
      change_attempt(engine)
      slot = unit_state(c).slots[{1, 0}]
      child = unit_state(c).slots[{2, 0}]
      before = budgets(c)

      for {attempt, tag} <- [{"attempt", "old"}, {"second", "new"}] do
        assert {:ok, _} =
                 RunEngine.input(
                   engine,
                   "late-nested-#{tag}",
                   result("nested"),
                   verified(%{
                     attempt_id: attempt,
                     occurrence: {1, 0},
                     actual: 3,
                     dispatch: "dispatched"
                   })
                 )
      end

      late_results(engine, {2, 0}, "slow")
      Agent.update(c.clock, fn _ -> 41_000 end)

      assert {:ok, :applied} =
               RunEngine.input(engine, "expire", wake(), verified(%{attempt_id: "second"}))

      assert unit_state(c).slots[{1, 0}] == slot
      assert unit_state(c).slots[{2, 0}] == child
      assert budgets(c) == before
      send(provider, {:result, %{}})
    end

    test "a settled parent turned back to refusing by an over-cap child is settled again at the change, first outcome kept" do
      {c, bindings} =
        lost_setup(
          [request([action("slow", "tool_call")]), request([action("excess")])],
          [],
          request_cap: 2
        )

      bindings =
        Map.update!(bindings, "nested_callable", fn binding ->
          %{binding | facts: fn a -> %{binding.facts.(a) | deadline_ms: 10_000} end}
        end)

      # The engine stops where it stands after the over-cap record, before the Run ends:
      # the clock function suspends the Run owner once, when armed.
      armed = start_supervised!({Agent, fn -> false end}, id: make_ref())
      parent = self()

      clock = fn ->
        if Agent.get_and_update(armed, &{&1, false}) do
          :sys.suspend(c.run)
          send(parent, {:trapped, self()})
        end

        Agent.get(c.clock, & &1)
      end

      engine = start(c, bindings: bindings, clock: clock)
      assert {:ok, :applied} = send_input(engine)
      assert_receive {:effect_started, provider, _}, 5_000
      Agent.update(c.clock, fn _ -> 10_000 end)
      # Not a wake: a wake would close the generation at the cap.
      assert {:ok, :applied} = RunEngine.input(engine, "expire", start_input(), verified())
      assert view(engine).slots[{1, 0}].outcome == "expired"
      expired = unit_state(c).slots[{1, 0}]
      assert expired[:actual] == nil
      before = budgets(c)

      # The child goes on: its next request is over the shared cap and denies its parent.
      Agent.update(armed, fn _ -> true end)

      spawn(fn ->
        try do
          RunEngine.input(
            engine,
            "child-result",
            Map.put(result("slow"), "outcome", "unknown"),
            verified(%{occurrence: {2, 0}, dispatch: "dispatched"})
          )
        catch
          :exit, _ -> :ok
        end
      end)

      assert_receive {:trapped, _}, 5_000
      wait_unit(c, &(&1.slots[{1, 0}].phase == :refusing and &1.control.stop_pending != nil))
      assert unit_state(c).slots[{1, 0}].outcome == "expired"
      halt_engine(c, engine)
      :sys.resume(c.run)
      change_attempt_down(c)

      engine = start(c, bindings: bindings)
      assert view(engine).slots[{1, 0}].phase == :settled
      assert view(engine).slots[{1, 0}].outcome == "expired"
      assert unit_state(c).slots[{1, 0}][:actual] == nil

      assert Map.take(unit_state(c).slots[{1, 0}], [:outcome, :actual, :reservation]) ==
               Map.take(expired, [:outcome, :actual, :reservation])

      assert budgets(c) == before
      engine = restart(c, engine, bindings: bindings)
      assert view(engine).slots[{1, 0}].phase == :settled
      assert budgets(c) == before
      send(provider, {:result, %{}})
    end
  end
end
