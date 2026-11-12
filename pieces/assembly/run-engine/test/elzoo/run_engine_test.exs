# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/run_engine_test_helper.exs", __DIR__)
Code.require_file("../../examples/document_publication.exs", __DIR__)

defmodule Elzoo.RunEngineTest do
  use ExUnit.Case, async: false
  import Elzoo.RunEngine.TestHelper
  alias Elzoo.{DurableUnit, DynamicUnits, RunEngine}
  alias Elzoo.RunEngine.TestPattern
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

      caller = Task.async(fn -> catch_exit(send_input(engine)) end)
      assert_receive {:gate_barrier, ^engine}
      assert {:timeout, _} = Task.await(caller, 6_000)
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
end
