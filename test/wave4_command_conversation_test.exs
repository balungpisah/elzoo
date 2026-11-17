Code.require_file("support/wave4_command_conversation_helper.exs", __DIR__)

defmodule Elzoo.Wave4.CommandConversationTest do
  use ExUnit.Case, async: false

  alias Elzoo.{CheckedCommand, Conversation, RunEngine}
  alias Elzoo.DurableLog.PostgresHarness
  alias Elzoo.RunEngine.TestHelper
  alias Elzoo.Wave4.CommandConversationHelper, as: Fixture

  setup_all do
    repo = Fixture.start_repo!()
    engine_repo = TestHelper.database()
    {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.TestRegistry)
    Process.unlink(registry)
    {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.UnitRegistry)
    Process.unlink(units)

    on_exit(fn ->
      if Process.alive?(registry), do: Supervisor.stop(registry)
      if Process.alive?(units), do: Supervisor.stop(units)
      if Process.alive?(engine_repo), do: Supervisor.stop(engine_repo)
      if Process.alive?(repo), do: Supervisor.stop(repo)
    end)

    :ok
  end

  setup do
    pg = Fixture.pg_fixture()
    on_exit(fn -> Fixture.cleanup_pg!(pg) end)
    %{pg: pg}
  end

  test "Conversation commits input, association, completed answer, reconstruction and later runs",
       %{pg: pg} do
    memory = Fixture.memory_fixture()
    on_exit(fn -> Fixture.stop_memory(memory) end)

    for {kind, store} <- [{:memory, memory.store}, {:postgres, pg.store}] do
      handle = Fixture.handle(store)
      initial = Fixture.read(handle)
      assert {:ok, []} = Fixture.pending_outbox(store)
      assert {:ok, empty} = Conversation.view(initial, scope())

      assert empty == %{
               tenant: Fixture.tenant(),
               resource: Fixture.resource(),
               revision: 0,
               messages: [],
               associations: []
             }

      input_facts = Fixture.facts("append_input", %{"input_role" => {:text, "user"}})
      input_request = Fixture.request("input-one", 0, "message-one", "hello")

      {:ok, writes, _response} =
        Conversation.prepare(initial, input_request, %{
          tenant: Fixture.tenant(),
          actor: Fixture.actor(),
          data: input_facts
        })

      assert [%{target: target, field: "conversation"}] = writes
      assert target == Fixture.resource()
      assert Fixture.read(handle) == initial
      assert {:ok, []} = Fixture.pending_outbox(store)

      assert {:unknown, :not_observed} =
               CheckedCommand.result(
                 handle,
                 %{tenant: Fixture.tenant(), actor: Fixture.actor()},
                 {Fixture.tenant(), Fixture.actor(), "input-one"}
               )

      if kind == :postgres, do: assert(Fixture.counts(pg) == %{records: 0, outbox: 0})

      {input, _, _} = Fixture.append_input(handle, 0, "input-one", "message-one", "hello")
      assert {:completed, %{revision: 1}} = input

      {association, _, _} =
        Fixture.associate(handle, 1, "associate-one", "message-one", "run-one")

      assert {:completed, %{revision: 2}} = association

      {answer, _, _} =
        Fixture.answer(handle, 2, "answer-one", "answer-one", "message-one", "run-one", "world")

      assert {:completed, %{revision: 3}} = answer

      handle = Fixture.handle(store)

      {second_input, _, _} =
        Fixture.append_input(handle, 3, "input-two", "message-two", "second")

      assert {:completed, %{revision: 4}} = second_input

      {same_run, _, _} =
        Fixture.associate(handle, 4, "associate-two", "message-two", "run-one")

      assert {:completed, %{revision: 5}} = same_run

      {third_input, _, _} =
        Fixture.append_input(handle, 5, "input-three", "message-three", "third")

      assert {:completed, %{revision: 6}} = third_input

      {another_run, _, _} =
        Fixture.associate(handle, 6, "associate-three", "message-three", "run-two")

      assert {:completed, %{revision: 7}} = another_run

      {third_answer, _, _} =
        Fixture.answer(
          handle,
          7,
          "answer-three",
          "answer-three",
          "message-three",
          "run-two",
          "done"
        )

      assert {:completed, %{revision: 8}} = third_answer

      handle = Fixture.handle(store)
      view = Fixture.view(handle)
      assert view.revision == 8

      assert view.messages == [
               %{actor: Fixture.actor(), message_id: "message-one", role: "user", text: "hello"},
               %{
                 actor: Fixture.actor(),
                 input_message_id: "message-one",
                 message_id: "answer-one",
                 role: "assistant",
                 run_id: "run-one",
                 text: "world"
               },
               %{actor: Fixture.actor(), message_id: "message-two", role: "user", text: "second"},
               %{actor: Fixture.actor(), message_id: "message-three", role: "user", text: "third"},
               %{
                 actor: Fixture.actor(),
                 input_message_id: "message-three",
                 message_id: "answer-three",
                 role: "assistant",
                 run_id: "run-two",
                 text: "done"
               }
             ]

      assert Enum.map(view.associations, &{&1.input_message_id, &1.run_id}) == [
               {"message-one", "run-one"},
               {"message-two", "run-one"},
               {"message-three", "run-two"}
             ]

      assert view == %{
               tenant: Fixture.tenant(),
               resource: Fixture.resource(),
               revision: 8,
               messages: view.messages,
               associations: [
                 %{input_message_id: "message-one", run_id: "run-one"},
                 %{input_message_id: "message-two", run_id: "run-one"},
                 %{input_message_id: "message-three", run_id: "run-two"}
               ]
             }

      assert {:ok, outbox} = Fixture.pending_outbox(store)
      assert length(outbox) == 8
      assert Enum.all?(outbox, &(&1.destination == "conversation-notify"))

      assert {:completed, %{revision: 1}} =
               CheckedCommand.result(
                 handle,
                 %{tenant: Fixture.tenant(), actor: Fixture.actor()},
                 {Fixture.tenant(), Fixture.actor(), "input-one"}
               )

      for {operation, result} <- [
            {"input-one", input},
            {"associate-one", association},
            {"answer-one", answer},
            {"input-two", second_input},
            {"associate-two", same_run},
            {"input-three", third_input},
            {"associate-three", another_run},
            {"answer-three", third_answer}
          ] do
        assert CheckedCommand.result(
                 handle,
                 %{tenant: Fixture.tenant(), actor: Fixture.actor()},
                 {Fixture.tenant(), Fixture.actor(), operation}
               ) == result
      end

      if kind == :postgres do
        assert Fixture.counts(pg) == %{records: 8, outbox: 8}
      end
    end
  end

  test "retained denials, replay, conflicts and scoped reads preserve the resource", %{pg: pg} do
    memory = Fixture.memory_fixture()
    on_exit(fn -> Fixture.stop_memory(memory) end)

    for {kind, store} <- [{:memory, memory.store}, {:postgres, pg.store}] do
      handle = Fixture.handle(store)
      before = Fixture.view(handle)
      {:ok, outbox_before} = Fixture.pending_outbox(store)
      request = Fixture.request("denied-policy", 0, "denied-message", "no")
      facts = Fixture.facts("append_input", %{"input_role" => {:text, "user"}})

      denied =
        CheckedCommand.execute(
          handle,
          Fixture.context(request, facts, Fixture.read(handle), verdict: :deny),
          request
        )

      assert {:denied, {:authorization, _}} = denied
      assert Fixture.view(handle) == before
      assert Fixture.pending_outbox(store) == {:ok, outbox_before}
      if kind == :postgres, do: assert(Fixture.counts(pg) == %{records: 1, outbox: 0})
      if kind == :postgres, do: assert(Fixture.counts(pg) == %{records: 1, outbox: 0})

      assert CheckedCommand.result(
               handle,
               %{tenant: Fixture.tenant(), actor: Fixture.actor()},
               {Fixture.tenant(), Fixture.actor(), "denied-policy"}
             ) == denied

      changed = Fixture.handle(store, gate: fn _, _ -> :allow end)

      assert CheckedCommand.execute(
               changed,
               Fixture.context(request, facts, Fixture.read(changed)),
               request
             ) == denied

      assert Fixture.view(changed) == before
      assert Fixture.pending_outbox(store) == {:ok, outbox_before}

      assert CheckedCommand.result(
               changed,
               %{tenant: Fixture.tenant(), actor: Fixture.actor()},
               {Fixture.tenant(), Fixture.actor(), "denied-policy"}
             ) == denied

      gate_denied_request = Fixture.request("denied-gate", 0, "gate-message", "gate")
      gate_denied_handle = Fixture.handle(store, gate: fn _, _ -> {:deny, "maintenance"} end)

      gate_denied =
        CheckedCommand.execute(
          gate_denied_handle,
          Fixture.context(gate_denied_request, facts, Fixture.read(gate_denied_handle)),
          gate_denied_request
        )

      assert {:denied, {:gate, "maintenance"}} = gate_denied
      gate_denied_view = Fixture.view(gate_denied_handle)
      {:ok, gate_denied_outbox} = Fixture.pending_outbox(store)
      assert gate_denied_view == before
      if kind == :postgres, do: assert(Fixture.counts(pg) == %{records: 2, outbox: 0})

      gate_replay_handle = Fixture.handle(store, gate: fn _, _ -> :allow end)

      assert CheckedCommand.execute(
               gate_replay_handle,
               Fixture.context(gate_denied_request, facts, Fixture.read(handle)),
               gate_denied_request
             ) == gate_denied

      assert Fixture.view(gate_replay_handle) == gate_denied_view
      assert Fixture.pending_outbox(store) == {:ok, gate_denied_outbox}
      if kind == :postgres, do: assert(Fixture.counts(pg) == %{records: 2, outbox: 0})

      assert CheckedCommand.result(
               gate_replay_handle,
               %{tenant: Fixture.tenant(), actor: Fixture.actor()},
               {Fixture.tenant(), Fixture.actor(), "denied-gate"}
             ) == gate_denied

      {completed, completed_request, completed_facts} =
        Fixture.append_input(changed, 0, "accepted", "same-id", "same text")

      assert {:completed, %{revision: 1}} = completed
      counts = if kind == :postgres, do: Fixture.counts(pg)
      completed_view = Fixture.view(changed)
      {:ok, completed_outbox} = Fixture.pending_outbox(store)

      assert CheckedCommand.execute(
               Fixture.handle(store, gate: fn _, _ -> {:deny, "changed-gate"} end),
               Fixture.context(completed_request, completed_facts, Fixture.read(changed),
                 verdict: :deny
               ),
               completed_request
             ) == completed

      assert Fixture.view(changed) == completed_view
      assert Fixture.pending_outbox(store) == {:ok, completed_outbox}

      assert CheckedCommand.result(
               changed,
               %{tenant: Fixture.tenant(), actor: Fixture.actor()},
               {Fixture.tenant(), Fixture.actor(), "accepted"}
             ) == completed

      if kind == :postgres, do: assert(Fixture.counts(pg) == counts)

      duplicate = Fixture.request("duplicate-id", 1, "same-id", "same text")

      assert {:refused, "duplicate_message_id"} =
               Conversation.prepare(Fixture.read(changed), duplicate, %{
                 tenant: Fixture.tenant(),
                 actor: Fixture.actor(),
                 data: completed_facts
               })

      duplicate_result =
        CheckedCommand.execute(
          changed,
          Fixture.context(duplicate, completed_facts, Fixture.read(changed)),
          duplicate
        )

      assert duplicate_result == {:conflict, {:domain, "duplicate_message_id"}}
      assert Fixture.view(changed) == completed_view
      assert Fixture.pending_outbox(store) == {:ok, completed_outbox}

      assert CheckedCommand.result(
               changed,
               %{tenant: Fixture.tenant(), actor: Fixture.actor()},
               {Fixture.tenant(), Fixture.actor(), "duplicate-id"}
             ) == duplicate_result

      if kind == :postgres, do: assert(Fixture.counts(pg) == %{records: 4, outbox: 1})

      {association, _, _} = Fixture.associate(changed, 1, "associate", "same-id", "run-one")
      assert {:completed, %{revision: 2}} = association
      associated_view = Fixture.view(changed)
      {:ok, associated_outbox} = Fixture.pending_outbox(store)
      if kind == :postgres, do: assert(Fixture.counts(pg) == %{records: 5, outbox: 2})

      {incomplete, incomplete_request, incomplete_facts} =
        Fixture.answer(changed, 2, "incomplete", "answer-bad", "same-id", "run-one", "bad", false)

      assert {:refused, "run_not_completed"} =
               Conversation.prepare(Fixture.read(changed), incomplete_request, %{
                 tenant: Fixture.tenant(),
                 actor: Fixture.actor(),
                 data: incomplete_facts
               })

      assert incomplete == {:conflict, {:domain, "run_not_completed"}}
      assert Fixture.view(changed) == associated_view
      assert Fixture.pending_outbox(store) == {:ok, associated_outbox}

      assert CheckedCommand.result(
               changed,
               %{tenant: Fixture.tenant(), actor: Fixture.actor()},
               {Fixture.tenant(), Fixture.actor(), "incomplete"}
             ) == incomplete

      if kind == :postgres, do: assert(Fixture.counts(pg) == %{records: 6, outbox: 2})

      mismatch_request = Fixture.request("mismatch", 2, "answer-bad-two", "bad")

      mismatch_facts =
        Fixture.facts("append_answer", %{
          "run_id" => {:text, "run-two"},
          "input_message_id" => {:text, "same-id"},
          "completed" => true
        })

      mismatch_snapshot = Fixture.read(changed)
      host_facts = %{tenant: Fixture.tenant(), actor: Fixture.actor(), data: mismatch_facts}
      pure_preparation = Conversation.prepare(mismatch_snapshot, mismatch_request, host_facts)
      assert {:refused, "association_mismatch"} = pure_preparation

      assert Fixture.descriptor().prepare.(mismatch_snapshot, mismatch_request, host_facts) ==
               pure_preparation

      mismatch_context = Fixture.context(mismatch_request, mismatch_facts, mismatch_snapshot)
      mismatch = CheckedCommand.execute(changed, mismatch_context, mismatch_request)

      assert mismatch == {:conflict, {:domain, "association_mismatch"}}
      assert Fixture.view(changed) == associated_view
      assert Fixture.pending_outbox(store) == {:ok, associated_outbox}

      assert CheckedCommand.result(
               changed,
               %{tenant: Fixture.tenant(), actor: Fixture.actor()},
               {Fixture.tenant(), Fixture.actor(), "mismatch"}
             ) == mismatch

      if kind == :postgres, do: assert(Fixture.counts(pg) == %{records: 7, outbox: 2})
      after_association = associated_view
      after_association_outbox = associated_outbox
      reassociation_request = Fixture.request("reassociate", 2, "same-id")
      reassociation_facts = Fixture.facts("associate_run", %{"run_id" => {:text, "run-two"}})

      assert {:refused, "already_associated"} =
               Conversation.prepare(Fixture.read(changed), reassociation_request, %{
                 tenant: Fixture.tenant(),
                 actor: Fixture.actor(),
                 data: reassociation_facts
               })

      reassociation =
        CheckedCommand.execute(
          changed,
          Fixture.context(reassociation_request, reassociation_facts, Fixture.read(changed)),
          reassociation_request
        )

      assert reassociation == {:conflict, {:domain, "already_associated"}}
      assert Fixture.view(changed) == after_association
      assert Fixture.pending_outbox(store) == {:ok, after_association_outbox}

      assert CheckedCommand.result(
               changed,
               %{tenant: Fixture.tenant(), actor: Fixture.actor()},
               {Fixture.tenant(), Fixture.actor(), "reassociate"}
             ) == reassociation

      if kind == :postgres, do: assert(Fixture.counts(pg) == %{records: 8, outbox: 2})

      identity = {Fixture.tenant(), Fixture.actor(), "accepted"}
      wrong_resource = %{completed_request | resource: "other-resource"}

      assert {:conflict, :identity} =
               CheckedCommand.execute(
                 changed,
                 Fixture.context(completed_request, completed_facts, Fixture.read(changed)),
                 wrong_resource
               )

      assert :not_found =
               CheckedCommand.result(
                 changed,
                 %{tenant: "other-tenant", actor: Fixture.actor()},
                 identity
               )

      assert :not_found =
               CheckedCommand.result(
                 changed,
                 %{tenant: Fixture.tenant(), actor: "other-actor"},
                 identity
               )

      assert :not_found =
               CheckedCommand.resource(
                 changed,
                 %{tenant: Fixture.tenant(), actor: Fixture.actor(), resources: []},
                 Fixture.resource()
               )

      assert Fixture.view(changed) == after_association
      assert Fixture.pending_outbox(store) == {:ok, after_association_outbox}
      if kind == :postgres, do: assert(Fixture.counts(pg) == %{records: 8, outbox: 2})
    end
  end

  test "PostgreSQL preparation barrier retains one CAS winner and one stale identity", %{pg: pg} do
    parent = self()

    prepare = fn snapshot, request, facts ->
      result = Conversation.prepare(snapshot, request, facts)

      send(
        parent,
        {:prepared, self(), {facts.tenant, facts.actor, request.operation_id},
         request.expected_revision}
      )

      receive do
        :release_prepare -> result
      after
        5_000 -> flunk("preparer barrier timed out")
      end
    end

    handle = Fixture.handle(pg.store, descriptor: %{prepare: prepare})
    facts = Fixture.facts("append_input", %{"input_role" => {:text, "user"}})
    initial = Fixture.read(handle)
    assert initial.revision == 0

    calls =
      for {operation, message} <- [{"race-a", "message-a"}, {"race-b", "message-b"}] do
        request = Fixture.request(operation, 0, message, operation)
        context = Fixture.context(request, facts, initial)
        Task.async(fn -> {request, CheckedCommand.execute(handle, context, request)} end)
      end

    assert_receive {:prepared, first_pid, first_identity, first_revision}
    assert_receive {:prepared, second_pid, second_identity, second_revision}
    assert first_pid != second_pid

    assert MapSet.new([{first_identity, first_revision}, {second_identity, second_revision}]) ==
             MapSet.new([
               {{Fixture.tenant(), Fixture.actor(), "race-a"}, 0},
               {{Fixture.tenant(), Fixture.actor(), "race-b"}, 0}
             ])

    send(first_pid, :release_prepare)
    send(second_pid, :release_prepare)
    results = Enum.map(calls, &Task.await(&1, 15_000))

    [{winner_request, winner_result}] =
      Enum.filter(results, fn {_, result} -> match?({:completed, %{revision: 1}}, result) end)

    [{loser_request, loser_result}] =
      Enum.filter(results, fn {_, result} -> result == {:conflict, :stale_revision} end)

    winner_message = %{
      actor: Fixture.actor(),
      message_id: winner_request.payload["message_id"],
      role: "user",
      text: winner_request.payload["text"]
    }

    assert Fixture.view(Fixture.handle(pg.store)) == %{
             tenant: Fixture.tenant(),
             resource: Fixture.resource(),
             revision: 1,
             messages: [winner_message],
             associations: []
           }

    assert CheckedCommand.result(
             handle,
             %{tenant: Fixture.tenant(), actor: Fixture.actor()},
             {Fixture.tenant(), Fixture.actor(), winner_request.operation_id}
           ) == winner_result

    assert CheckedCommand.result(
             handle,
             %{tenant: Fixture.tenant(), actor: Fixture.actor()},
             {Fixture.tenant(), Fixture.actor(), loser_request.operation_id}
           ) == loser_result

    assert Fixture.counts(pg) == %{records: 2, outbox: 1}
    {:ok, winner_outbox} = Fixture.pending_outbox(pg.store)
    assert length(winner_outbox) == 1
    assert Enum.all?(winner_outbox, &(&1.destination == "conversation-notify"))

    current = Fixture.handle(pg.store)

    retry = %{
      loser_request
      | operation_id: "#{loser_request.operation_id}-retry",
        expected_revision: 1
    }

    retry_ctx = Fixture.context(retry, facts, Fixture.read(current))
    retry_result = CheckedCommand.execute(current, retry_ctx, retry)
    assert {:completed, %{revision: 2}} = retry_result

    assert {:conflict, :identity} =
             CheckedCommand.execute(current, retry_ctx, %{
               retry
               | operation_id: loser_request.operation_id
             })

    retry_message = %{
      actor: Fixture.actor(),
      message_id: loser_request.payload["message_id"],
      role: "user",
      text: loser_request.payload["text"]
    }

    assert Fixture.view(current) == %{
             tenant: Fixture.tenant(),
             resource: Fixture.resource(),
             revision: 2,
             messages: [winner_message, retry_message],
             associations: []
           }

    assert CheckedCommand.result(
             current,
             %{tenant: Fixture.tenant(), actor: Fixture.actor()},
             {Fixture.tenant(), Fixture.actor(), retry.operation_id}
           ) == retry_result

    assert CheckedCommand.result(
             current,
             %{tenant: Fixture.tenant(), actor: Fixture.actor()},
             {Fixture.tenant(), Fixture.actor(), loser_request.operation_id}
           ) == loser_result

    assert Fixture.counts(pg) == %{records: 3, outbox: 2}
    assert {:ok, retry_outbox} = Fixture.pending_outbox(pg.store)
    assert length(retry_outbox) == 2
    assert Enum.all?(retry_outbox, &(&1.destination == "conversation-notify"))
  end

  test "PostgreSQL lost response, readback outage, reopen and rollback are distinct", %{pg: pg} do
    parent = self()

    prepare = fn snapshot, request, facts ->
      result = Conversation.prepare(snapshot, request, facts)
      PostgresHarness.hook(pg.store, :inject, [:read_at, :unavailable])
      send(parent, {:prepared_after_read, request.operation_id})
      result
    end

    handle = Fixture.handle(pg.store, descriptor: %{prepare: prepare})
    request = Fixture.request("reply-loss", 0, "message-loss", "committed")
    facts = Fixture.facts("append_input", %{"input_role" => {:text, "user"}})
    context = Fixture.context(request, facts, Fixture.read(handle))
    PostgresHarness.hook(pg.store, :inject, [:append, :reply_loss])
    assert {:unknown, :unresolved} = CheckedCommand.execute(handle, context, request)
    assert_receive {:prepared_after_read, "reply-loss"}
    PostgresHarness.hook(pg.store, :inject, [:read, :unavailable])

    assert {:unknown, :unresolved} =
             CheckedCommand.result(
               handle,
               %{tenant: Fixture.tenant(), actor: Fixture.actor()},
               {Fixture.tenant(), Fixture.actor(), "reply-loss"}
             )

    store = PostgresHarness.hook(pg.store, :reopen, [])
    reopened = Fixture.handle(store)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.result(
               reopened,
               %{tenant: Fixture.tenant(), actor: Fixture.actor()},
               {Fixture.tenant(), Fixture.actor(), "reply-loss"}
             )

    assert Fixture.counts(pg) == %{records: 1, outbox: 1}
    assert Fixture.view(reopened).messages |> Enum.map(& &1.message_id) == ["message-loss"]

    other = Fixture.pg_fixture()
    on_exit(fn -> Fixture.cleanup_pg!(other) end)
    rollback_handle = Fixture.handle(other.store)
    rollback_request = Fixture.request("rollback", 0, "message-rollback", "not committed")
    rollback_facts = Fixture.facts("append_input", %{"input_role" => {:text, "user"}})

    rollback_context =
      Fixture.context(rollback_request, rollback_facts, Fixture.read(rollback_handle))

    PostgresHarness.hook(other.store, :inject, [:append, :rollback])
    result = CheckedCommand.execute(rollback_handle, rollback_context, rollback_request)
    refute match?({:completed, _}, result)
    assert Fixture.counts(other) == %{records: 0, outbox: 0}

    assert {:unknown, :not_observed} =
             CheckedCommand.result(
               rollback_handle,
               %{tenant: Fixture.tenant(), actor: Fixture.actor()},
               {Fixture.tenant(), Fixture.actor(), "rollback"}
             )
  end

  test "ASK release binds current authority, purpose, identity and evidence once", %{pg: pg} do
    handle = Fixture.handle(pg.store)
    run_id = "conversation-run"
    {input, _, _} = Fixture.append_input(handle, 0, "approval-input", "approval-input", "question")
    assert {:completed, %{revision: 1}} = input

    {association, _, _} =
      Fixture.associate(handle, 1, "approval-association", "approval-input", run_id)

    assert {:completed, %{revision: 2}} = association

    {pending, request, facts} =
      Fixture.answer(
        handle,
        2,
        "approval-answer",
        "approval-answer",
        "approval-input",
        run_id,
        "answer",
        true,
        verdict: :ask
      )

    assert {:approval_pending, %{key: key}} = pending
    before = Fixture.view(handle)
    assert before.revision == 2
    assert Fixture.counts(pg) == %{records: 3, outbox: 2}

    evidence = %{
      verifier: "command-reviewer",
      evidence_id: "conversation-approval",
      reviewer: "human-reviewer",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: 100,
      expiry: 200
    }

    envelope = %{purpose: :command, tenant: Fixture.tenant(), evidence: evidence}
    identity = {Fixture.tenant(), Fixture.actor(), "approval-answer"}
    command_owner = elem(key, 0)
    action_id = elem(key, 1)
    assert action_id == elem(identity, 2)
    release_base = Fixture.context(request, facts, Fixture.read(handle), verdict: :ask)

    release_context =
      Map.merge(release_base, %{
        approver: %{identity: "human-reviewer", authority: release_base.own},
        now: 150,
        revoked: []
      })

    wrong_purpose_evidence = %{
      evidence
      | request: {command_owner, action_id, elem(key, 2), elem(key, 3), elem(key, 4)}
    }

    wrong_purpose_envelope = %{envelope | purpose: :run, evidence: wrong_purpose_evidence}
    assert elem(wrong_purpose_evidence.request, 0) == command_owner
    assert elem(wrong_purpose_evidence.request, 1) == action_id

    changed_prepare = fn snapshot, pending_request, host_facts ->
      case Conversation.prepare(snapshot, pending_request, host_facts) do
        {:ok, [%{value: {:record, state_fields}} = write], response} ->
          {"messages", {:list, messages}} = List.keyfind(state_fields, "messages", 0)
          {:record, answer_fields} = List.last(messages)

          changed_answer_fields =
            Enum.map(answer_fields, fn
              {"text", {:text, _}} -> {"text", {:text, "changed answer"}}
              field -> field
            end)

          changed_messages =
            List.replace_at(messages, -1, {:record, changed_answer_fields})

          changed_fields =
            Enum.map(state_fields, fn
              {"messages", _} -> {"messages", {:list, changed_messages}}
              field -> field
            end)

          {:ok, [%{write | value: {:record, changed_fields}}], response}

        other ->
          other
      end
    end

    {:ok, changed_writes, _} =
      changed_prepare.(Fixture.read(handle), request, %{
        tenant: Fixture.tenant(),
        actor: Fixture.actor(),
        data: facts
      })

    assert changed_writes != release_base.own

    changed_handle = Fixture.handle(pg.store, descriptor: %{prepare: changed_prepare})

    changed_context = %{
      release_context
      | own: changed_writes,
        approver: %{identity: "human-reviewer", authority: changed_writes}
    }

    refusal_contexts = [
      {:wrong_purpose_equal_run_owner, handle, release_context, wrong_purpose_envelope,
       :wrong_purpose},
      {:wrong_run_fact, handle,
       %{
         release_context
         | facts:
             Fixture.facts("append_answer", %{
               "run_id" => {:text, "other-run"},
               "input_message_id" => {:text, "approval-input"},
               "completed" => true
             })
       }, envelope, :refused},
      {:wrong_input_fact, handle,
       %{
         release_context
         | facts:
             Fixture.facts("append_answer", %{
               "run_id" => {:text, run_id},
               "input_message_id" => {:text, "other-input"},
               "completed" => true
             })
       }, envelope, :refused},
      {:changed_writes, changed_handle, changed_context, envelope, :binding_mismatch},
      {:revoked, handle,
       %{release_context | revoked: [{"command-reviewer", "conversation-approval"}]}, envelope,
       :refused},
      {:missing_authority, handle,
       %{release_context | approver: %{identity: "human-reviewer", authority: []}}, envelope,
       :refused}
    ]

    snapshot = PostgresHarness.hook(pg.store, :snapshot, [])

    refusal_state =
      {Fixture.view(handle), snapshot.elzoo_log_records, snapshot.elzoo_outbox,
       CheckedCommand.result(handle, %{tenant: Fixture.tenant(), actor: Fixture.actor()}, identity)}

    Enum.each(refusal_contexts, fn {_name, refusal_handle, context, candidate, expected} ->
      result = CheckedCommand.release(refusal_handle, context, identity, candidate)

      case expected do
        :binding_mismatch -> assert result == {:release_refused, :binding_mismatch}
        :wrong_purpose -> assert result == {:release_refused, :invalid_request}
        :refused -> assert match?({:release_refused, _}, result)
      end

      snapshot = PostgresHarness.hook(pg.store, :snapshot, [])

      assert {Fixture.view(handle), snapshot.elzoo_log_records, snapshot.elzoo_outbox,
              CheckedCommand.result(
                handle,
                %{tenant: Fixture.tenant(), actor: Fixture.actor()},
                identity
              )} == refusal_state
    end)

    reopened = Fixture.handle(PostgresHarness.hook(pg.store, :reopen, []))

    assert {:completed, %{revision: 3}} =
             CheckedCommand.release(reopened, release_context, identity, envelope)

    assert {:completed, %{revision: 3}} =
             CheckedCommand.release(reopened, release_context, identity, envelope)

    assert Fixture.view(reopened).revision == 3
    assert Fixture.counts(pg) == %{records: 4, outbox: 3}
  end

  @tag :postgres
  test "stale answer release is a separate terminal conflict", %{pg: pg} do
    handle = Fixture.handle(pg.store)
    {input, _, _} = Fixture.append_input(handle, 0, "stale-input", "stale-input", "question")
    assert {:completed, %{revision: 1}} = input

    {association, _, _} =
      Fixture.associate(handle, 1, "stale-association", "stale-input", "stale-run")

    assert {:completed, %{revision: 2}} = association

    {pending, request, facts} =
      Fixture.answer(
        handle,
        2,
        "stale-answer",
        "stale-answer",
        "stale-input",
        "stale-run",
        "answer",
        true,
        verdict: :ask
      )

    assert {:approval_pending, %{key: key}} = pending
    release_base = Fixture.context(request, facts, Fixture.read(handle), verdict: :ask)

    release_context =
      Map.merge(release_base, %{
        approver: %{identity: "human-reviewer", authority: release_base.own},
        now: 150,
        revoked: []
      })

    evidence = %{
      verifier: "command-reviewer",
      evidence_id: "stale-approval",
      reviewer: "human-reviewer",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: 100,
      expiry: 200
    }

    envelope = %{purpose: :command, tenant: Fixture.tenant(), evidence: evidence}
    identity = {Fixture.tenant(), Fixture.actor(), "stale-answer"}

    {intervening, _, _} =
      Fixture.append_input(handle, 2, "intervening-input", "later-input", "later")

    assert {:completed, %{revision: 3}} = intervening

    assert {:conflict, :stale_revision} =
             CheckedCommand.release(handle, release_context, identity, envelope)

    assert {:conflict, :stale_revision} =
             CheckedCommand.release(handle, release_context, identity, envelope)

    assert {:conflict, :stale_revision} =
             CheckedCommand.result(
               handle,
               %{tenant: Fixture.tenant(), actor: Fixture.actor()},
               identity
             )

    assert Enum.map(Fixture.view(handle).messages, & &1.message_id) == [
             "stale-input",
             "later-input"
           ]

    assert Fixture.counts(pg) == %{records: 5, outbox: 3}
  end

  test "RunEngine and CheckedCommand send the same PatternStep frame to their real gates", %{
    pg: _pg
  } do
    parent = self()

    gate = fn frame, context ->
      send(parent, {:command_gate, frame, context})
      :allow
    end

    store = Fixture.memory_fixture()
    on_exit(fn -> Fixture.stop_memory(store) end)
    command = Fixture.handle(store.store, gate: gate)
    request = Fixture.request("native-parity", 0, "parity-input", "payload")
    facts = Fixture.facts("append_input", %{"input_role" => {:text, "user"}})
    command_context = Fixture.context(request, facts, Fixture.read(command))
    assert command_context.parent == :none
    c = TestHelper.fixture()

    run_store =
      Elzoo.DurableLog.Postgres.store(Elzoo.RunEngine.TestRepo,
        prefix: c.prefix,
        fold: Elzoo.RunApprovalRelease.fold(),
        limits: Elzoo.RunApprovalRelease.limits()
      )

    {:ok, run_records_before, run_head_before} = Elzoo.DurableLog.read(run_store, "runs", 1, 1000)
    engine_registry_before = Registry.lookup(Elzoo.RunEngine.TestRegistry, c.prefix)
    assert engine_registry_before == []
    unit_rows_before = TestHelper.rows(c)
    assert unit_rows_before == []
    {:ok, run_before} = Elzoo.RunApprovalRelease.status(c.opts[:run_owner], "run")
    assert Map.get(run_before, :parent) == nil
    command_result = CheckedCommand.execute(command, command_context, request)
    assert {:completed, %{revision: 1}} = command_result
    assert {:ok, ^run_before} = Elzoo.RunApprovalRelease.status(c.opts[:run_owner], "run")
    assert TestHelper.rows(c) == unit_rows_before
    assert Registry.lookup(Elzoo.RunEngine.TestRegistry, c.prefix) == engine_registry_before

    assert {:ok, ^run_records_before, ^run_head_before} =
             Elzoo.DurableLog.read(run_store, "runs", 1, 1000)

    assert [%{field: "conversation", value: authorized_value}] = command_context.own
    assert Fixture.read(command).fields["conversation"] == authorized_value

    assert Fixture.view(command) == %{
             tenant: Fixture.tenant(),
             resource: Fixture.resource(),
             revision: 1,
             messages: [
               %{
                 actor: Fixture.actor(),
                 message_id: "parity-input",
                 role: "user",
                 text: "payload"
               }
             ],
             associations: []
           }

    assert_receive {:command_gate, {:PatternStep, command_frame}, command_gate_context}

    action =
      TestHelper.action("native-parity", "local_work", request.payload)
      |> Map.put("schema_id", Fixture.port()["schema_id"])

    {:ok, schema} =
      Elzoo.PayloadSchema.build(Fixture.port(), %{
        "type" => "object",
        "properties" => %{"message_id" => %{"type" => "string"}, "text" => %{"type" => "string"}},
        "required" => ["message_id"],
        "additionalProperties" => false
      })

    context = command_context
    own = context.own
    base = c.opts[:bindings]["local_work"]

    binding = %{
      base
      | effect_class: "conversation.write",
        proposal: fn action ->
          proposal = %{
            tenant: Fixture.tenant(),
            resource: Fixture.resource(),
            action_id: action["id"],
            payload: portable_payload(action["payload"]),
            writes: own
          }

          {policy, authority} = Agent.get(c.context, &{&1.policy, &1.authority})
          send(parent, {:engine_authorization_inputs, action["id"], proposal, policy, authority})
          proposal
        end,
        work: fn action ->
          {Elzoo.Wave4.CommandConversationHelper, :observe_work, [parent, action["payload"]]}
        end
    }

    Agent.update(c.context, fn ctx ->
      %{ctx | policy: Fixture.policy(), authority: own, resource_names: [Fixture.resource()]}
    end)

    engine_gate = fn frame, gate_context ->
      send(parent, {:engine_gate, frame, gate_context})
      :allow
    end

    schemas =
      Map.put(c.opts[:schemas], {Fixture.port()["schema_id"], 1}, %{
        port: Fixture.port(),
        compiled: schema,
        digest: :crypto.hash(:sha256, "conversation-schema")
      })

    pattern = {Elzoo.RunEngine.TestPattern, :step, %{requests: [TestHelper.request([action])]}}
    bindings = Map.put(c.opts[:bindings], "local_work", binding)

    {:ok, engine} =
      RunEngine.start_link(
        Keyword.merge(c.opts,
          pattern: pattern,
          schemas: schemas,
          bindings: bindings,
          tenant: Fixture.tenant(),
          principal: Fixture.actor(),
          gate: %{id: "gate", version: 1, call: engine_gate}
        )
      )

    Process.unlink(engine)
    on_exit(fn -> if Process.alive?(engine), do: GenServer.stop(engine) end)

    assert {:ok, :applied} =
             RunEngine.input(engine, "start", TestHelper.start_input(), TestHelper.verified())

    assert_receive {:engine_gate, {:PatternStep, engine_frame}, engine_gate_context}, 5_000

    assert_receive {:engine_authorization_inputs, "native-parity", engine_proposal, engine_policy,
                    engine_authority},
                   5_000

    assert engine_proposal == %{
             tenant: Fixture.tenant(),
             resource: Fixture.resource(),
             action_id: "native-parity",
             payload: portable_payload(request.payload),
             writes: own
           }

    assert engine_policy == command_context.policy
    assert engine_authority == own

    assert_receive {:engine_authorization_inputs, "native-parity", ^engine_proposal, ^engine_policy,
                    ^engine_authority},
                   5_000

    assert {:ok, status} = RunEngine.status(engine)
    assert %{phase: :running} = status.slots[{1, 0}]

    assert %{verdict: :allow, gate_id: "gate", gate_version: 1} =
             status.slots[{1, 0}].verdict

    assert_receive {:local_work, worker, payload}, 5_000
    assert payload == request.payload

    assert {:ok, :applied} =
             RunEngine.control(
               engine,
               "pause",
               %{kind: :pause, pause_deadline: 50_000},
               TestHelper.verified()
             )

    send(worker, :finish_work)
    completed = TestHelper.wait_for(engine, &(&1.slots[{1, 0}].phase == :settled))
    assert completed.slots[{1, 0}].outcome == "completed"

    authorization_events =
      TestHelper.rows(c)
      |> Enum.map(fn row ->
        {1, {_id, event}} = :erlang.binary_to_term(row.payload, [:safe])
        event
      end)
      |> Enum.filter(&(Map.get(&1, :kind) == :authorization))

    assert [%{decision: %{verdict: :allow, permitted: ^own}}] = authorization_events
    GenServer.stop(engine)
    assert engine_frame == command_frame
    assert engine_gate_context == command_gate_context
  end

  test "DENY, ASK and gate failures retain their decisions without local dispatch" do
    cases = [
      {"native-denied", :deny, :allow},
      {"native-ask", :ask, :allow},
      {"native-gate-denied", :allow, :deny},
      {"native-gate-invalid", :allow, :invalid},
      {"native-gate-raising", :allow, :raise}
    ]

    Enum.each(cases, fn {operation, policy_verdict, gate_result} ->
      parent = self()
      memory = Fixture.memory_fixture()
      on_exit(fn -> Fixture.stop_memory(memory) end)
      request = Fixture.request(operation, 0, operation <> "-message", "payload")
      facts = Fixture.facts("append_input", %{"input_role" => {:text, "user"}})

      command_context =
        Fixture.context(request, facts, Fixture.read(Fixture.handle(memory.store)),
          verdict: policy_verdict,
          parent: :none
        )

      assert command_context.parent == :none

      command =
        Fixture.handle(memory.store,
          gate: observed_gate(parent, :command_gate, gate_result)
        )

      command_result = CheckedCommand.execute(command, command_context, request)

      case {policy_verdict, gate_result} do
        {:deny, :allow} ->
          assert match?({:denied, {:authorization, _}}, command_result)

        {:ask, :allow} ->
          assert match?({:approval_pending, _}, command_result)

        {:allow, :deny} ->
          assert command_result == {:denied, {:gate, "policy_denied"}}

        {:allow, gate} when gate in [:invalid, :raise] ->
          assert command_result == {:denied, {:gate, "gate_failure"}}
      end

      assert CheckedCommand.result(
               command,
               %{tenant: Fixture.tenant(), actor: Fixture.actor()},
               {Fixture.tenant(), Fixture.actor(), operation}
             ) == command_result

      assert Fixture.view(command) == %{
               tenant: Fixture.tenant(),
               resource: Fixture.resource(),
               revision: 0,
               messages: [],
               associations: []
             }

      assert Fixture.pending_outbox(memory.store) == {:ok, []}
      assert_receive {:command_gate, {:PatternStep, command_frame}, command_gate_context}

      c = TestHelper.fixture()

      {engine, _action} =
        start_native_engine(
          c,
          parent,
          request,
          command_context.own,
          Fixture.policy(policy_verdict),
          gate_result
        )

      assert {:ok, :applied} =
               RunEngine.input(engine, "start", TestHelper.start_input(), TestHelper.verified())

      assert_receive {:engine_gate, {:PatternStep, engine_frame}, engine_gate_context}, 5_000
      assert engine_frame == command_frame
      assert engine_gate_context == command_gate_context

      assert {:ok, status} = RunEngine.status(engine)
      slot = status.slots[{1, 0}]

      expected_gate_reason =
        case gate_result do
          :deny -> "policy_denied"
          gate when gate in [:invalid, :raise] -> "gate_failure"
          :allow -> nil
        end

      assert slot.verdict == %{
               verdict: if(gate_result == :allow, do: :allow, else: :deny),
               reason: expected_gate_reason,
               gate_id: "gate",
               gate_version: 1
             }

      if policy_verdict == :ask do
        assert slot.phase == :approval
        {:approval_pending, %{key: command_key}} = command_result
        command_identity = {Fixture.tenant(), Fixture.actor(), operation}
        command_view_before = Fixture.view(command)
        {:ok, command_outbox_before} = Fixture.pending_outbox(memory.store)
        {:ok, run_before} = Elzoo.RunApprovalRelease.status(c.opts[:run_owner], "run")
        [%{request_key: key}] = run_before.approvals
        engine_evidence = TestHelper.consent(key)

        command_refusal_context =
          Map.merge(command_context, %{
            own: [],
            approver: %{identity: "reviewer", authority: []},
            now: c.opts[:clock].(),
            revoked: []
          })

        command_evidence = %{
          engine_evidence
          | verifier: "command-reviewer",
            evidence_id: operation <> "-command-evidence",
            request: command_key
        }

        command_envelope = %{
          purpose: :command,
          tenant: Fixture.tenant(),
          evidence: command_evidence
        }

        assert {:release_refused, _} =
                 CheckedCommand.release(
                   command,
                   command_refusal_context,
                   command_identity,
                   command_envelope
                 )

        assert_receive {:command_gate, {:PatternStep, release_frame}, release_gate_context}
        assert release_frame == command_frame
        assert release_gate_context == command_gate_context

        assert CheckedCommand.result(
                 command,
                 %{tenant: Fixture.tenant(), actor: Fixture.actor()},
                 command_identity
               ) == command_result

        assert Fixture.view(command) == command_view_before
        assert Fixture.pending_outbox(memory.store) == {:ok, command_outbox_before}

        assert command_evidence.issued_at == engine_evidence.issued_at
        assert command_evidence.expiry == engine_evidence.expiry

        Agent.update(c.context, fn context ->
          %{context | authority: [], approver: %{identity: "reviewer", authority: []}}
        end)

        assert {:ok, :applied} =
                 RunEngine.control(
                   engine,
                   "refused-consent",
                   %{
                     kind: :approval_evidence,
                     request_key: key,
                     evidence: engine_evidence
                   },
                   TestHelper.verified()
                 )

        assert {:ok, status} = RunEngine.status(engine)
        assert status.slots[{1, 0}].phase == :approval
        {:ok, run_after} = Elzoo.RunApprovalRelease.status(c.opts[:run_owner], "run")
        assert [%{request_key: ^key}] = run_after.approvals
        assert run_after.approvals == run_before.approvals
        assert run_after.effects == run_before.effects
      else
        assert slot.phase == :settled
        assert slot.outcome == "refused"
      end

      refute_receive {:local_work, _, _}
    end)
  end

  defp scope do
    %{tenant: Fixture.tenant(), actor: Fixture.actor(), resources: [Fixture.resource()]}
  end

  defp start_native_engine(c, parent, request, own, policy, gate_result) do
    Agent.update(c.context, fn context ->
      Map.merge(context, %{
        policy: policy,
        authority: own,
        resource_names: [Fixture.resource()],
        max_age: 10_000,
        verifiers: ["verifier"],
        run: %{id: "run", root: "run", ancestry: []},
        approver: %{identity: "reviewer", authority: own}
      })
    end)

    schema = Fixture.schema()
    base = c.opts[:bindings]["local_work"]

    binding = %{
      base
      | effect_class: "conversation.write",
        proposal: fn action ->
          proposal = %{
            tenant: Fixture.tenant(),
            resource: Fixture.resource(),
            action_id: action["id"],
            payload: portable_payload(action["payload"]),
            writes: own
          }

          {observed_policy, observed_authority} =
            Agent.get(c.context, &{&1.policy, &1.authority})

          send(
            parent,
            {:engine_authorization_inputs, action["id"], proposal, observed_policy,
             observed_authority}
          )

          proposal
        end,
        work: fn action ->
          {Elzoo.Wave4.CommandConversationHelper, :observe_work, [parent, action["payload"]]}
        end
    }

    action =
      TestHelper.action(request.operation_id, "local_work", request.payload)
      |> Map.put("schema_id", Fixture.port()["schema_id"])

    schemas =
      Map.put(c.opts[:schemas], {Fixture.port()["schema_id"], 1}, %{
        port: Fixture.port(),
        compiled: schema,
        digest: :crypto.hash(:sha256, "conversation-schema")
      })

    pattern = {Elzoo.RunEngine.TestPattern, :step, %{requests: [TestHelper.request([action])]}}
    bindings = Map.put(c.opts[:bindings], "local_work", binding)

    {:ok, engine} =
      RunEngine.start_link(
        Keyword.merge(c.opts,
          pattern: pattern,
          schemas: schemas,
          bindings: bindings,
          tenant: Fixture.tenant(),
          principal: Fixture.actor(),
          gate: %{id: "gate", version: 1, call: observed_gate(parent, :engine_gate, gate_result)}
        )
      )

    Process.unlink(engine)
    on_exit(fn -> if Process.alive?(engine), do: GenServer.stop(engine) end)
    {engine, action}
  end

  defp observed_gate(parent, label, gate_result) do
    fn frame, context ->
      send(parent, {label, frame, context})

      case gate_result do
        :allow -> :allow
        :deny -> {:deny, "policy_denied"}
        :invalid -> :unexpected
        :raise -> raise "synthetic gate failure"
      end
    end
  end

  defp portable_payload(payload),
    do:
      {:record,
       Enum.sort_by(
         Enum.map(payload, fn {key, value} ->
           {key, {:text, value}}
         end),
         &elem(&1, 0)
       )}
end
