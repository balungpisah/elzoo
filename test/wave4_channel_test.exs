Code.require_file("support/wave4_channel_helper.exs", __DIR__)

defmodule Elzoo.Wave4ChannelTest do
  use ExUnit.Case, async: false

  alias Elzoo.{
    CheckedCommand,
    Conversation,
    DurableUnit,
    DynamicUnits,
    Outbox,
    RunApprovalRelease,
    RunEngine,
    Wave4ChannelExample
  }

  setup_all do
    repo = Elzoo.Wave4ChannelTestHelper.start_database!()
    on_exit(fn -> if Process.alive?(repo), do: GenServer.stop(repo) end)
    :ok
  end

  setup do
    {:ok, fixture: Elzoo.Wave4ChannelTestHelper.fixture()}
  end

  test "signed loopback processes two distinct inputs and replays the first", %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    first = Elzoo.Wave4ChannelTestHelper.event()

    assert {:ok, {{_, 202, _}, _headers, _body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, first)

    first_outbox = assert_input_outbox(fixture, first, 1)

    second =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "event-2",
        "input_id" => "input-2",
        "expected_revision" => 3,
        "text" => "second native input"
      })

    assert {:ok, {{_, 503, _}, _headers, _body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, second)

    assert ^first_outbox = assert_input_outbox(fixture, first, 1)

    assert {:ok, %{run_id: first_run, unit_id: first_unit, status: first_status}} =
             process_event(fixture, listener, first, 3, 1, 4)

    assert {:ok, %{run_id: second_run, unit_id: second_unit, status: second_status}} =
             process_event(fixture, listener, second, 6, 4, 7)

    assert first_run != second_run
    assert first_unit != second_unit
    assert first_status.current_attempt != second_status.current_attempt
    assert first_status.attempts == [first_status.current_attempt]
    assert second_status.attempts == [second_status.current_attempt]
    assert {:ok, current_first_status} = RunApprovalRelease.status(fixture.owner, first_run)
    assert {:ok, current_second_status} = RunApprovalRelease.status(fixture.owner, second_run)
    assert stable_run_status(current_first_status) == stable_run_status(first_status)
    assert stable_run_status(current_second_status) == stable_run_status(second_status)

    assert {:ok, replay} = Elzoo.Wave4ChannelTestHelper.post(listener, first)
    assert {{_, 202, _}, _headers, body} = replay
    assert %{"status" => "committed", "revision" => 1} = Jason.decode!(body)

    assert {:ok, []} =
             Outbox.pending(fixture.command_store, checked_stream(fixture.profile.tenant), 64)

    assert {:ok, {{_, 200, _}, _headers, before_view}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert {:ok, {{_, 200, _}, _headers, after_view}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert before_view == after_view

    assert %{
             "status" => "ok",
             "view" => %{
               "revision" => 6,
               "messages" => messages,
               "associations" => associations,
               "runs" => runs
             }
           } =
             Jason.decode!(after_view)

    assert messages == [
             %{
               "actor" => fixture.profile.actor,
               "message_id" => first["input_id"],
               "role" => "source",
               "text" => first["text"]
             },
             %{
               "actor" => fixture.profile.actor,
               "input_message_id" => first["input_id"],
               "message_id" => Elzoo.Wave4ChannelTestHelper.answer_id(first["input_id"]),
               "role" => "assistant",
               "run_id" => first_run,
               "text" => expected_answer(first)
             },
             %{
               "actor" => fixture.profile.actor,
               "message_id" => second["input_id"],
               "role" => "source",
               "text" => second["text"]
             },
             %{
               "actor" => fixture.profile.actor,
               "input_message_id" => second["input_id"],
               "message_id" => Elzoo.Wave4ChannelTestHelper.answer_id(second["input_id"]),
               "role" => "assistant",
               "run_id" => second_run,
               "text" => expected_answer(second)
             }
           ]

    assert associations == [
             %{"input_message_id" => first["input_id"], "run_id" => first_run},
             %{"input_message_id" => second["input_id"], "run_id" => second_run}
           ]

    assert runs == [
             %{
               "run_id" => first_run,
               "operation_id" =>
                 Elzoo.Wave4ChannelTestHelper.native_operation(fixture.profile, first_run),
               "outcome" => "completed",
               "revision" => 7
             },
             %{
               "run_id" => second_run,
               "operation_id" =>
                 Elzoo.Wave4ChannelTestHelper.native_operation(fixture.profile, second_run),
               "outcome" => "completed",
               "revision" => 7
             }
           ]

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, resource} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    assert resource.revision == 6
    assert Map.keys(resource.fields) == ["conversation"]
    assert {:ok, projection} = Conversation.view(resource, scope)
    assert projection.revision == 6
    assert length(projection.messages) == 4
    assert length(projection.associations) == 2

    assert {:ok, []} =
             Outbox.pending(fixture.command_store, checked_stream(fixture.profile.tenant), 64)

    assert :not_found = DynamicUnits.find(fixture.directory, first_unit)
    assert :not_found = DynamicUnits.find(fixture.directory, second_unit)
    assert Registry.lookup(fixture.native.registry, first_unit) == []
    assert Registry.lookup(fixture.native.registry, second_unit) == []
  end

  defp process_event(
         fixture,
         listener,
         event,
         answer_revision,
         outbox_sequence,
         completion_revision
       ) do
    expected_input_revision = event["expected_revision"] + 1

    with {:ok, {{_, 202, _}, _headers, response}} <-
           Elzoo.Wave4ChannelTestHelper.post(listener, event),
         %{"status" => "committed", "revision" => ^expected_input_revision} <-
           Jason.decode!(response) do
      run_id =
        Elzoo.Wave4ChannelTestHelper.run_id(
          fixture.profile,
          event["event_id"],
          event["input_id"]
        )

      unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
      input_id = event["input_id"]
      stream = checked_stream(fixture.profile.tenant)

      assert_input_outbox(fixture, event, outbox_sequence)

      assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
      assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
      assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
      assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
      assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
      assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
      assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
      assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
      assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
      assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
      assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
      assert {:ok, unit} = DynamicUnits.find(fixture.directory, unit_id)
      assert Map.keys(DurableUnit.snapshot(unit).control.budgets) == ["root"]
      assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

      assert {:result, :completed} =
               wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

      assert {:answered, ^answer_revision} = Wave4ChannelExample.advance(fixture.host)

      assert [{engine, _}] = Registry.lookup(fixture.native.registry, unit_id)

      assert {:ok,
              %{
                run_id: ^run_id,
                attempt_id: attempt_id,
                outcome: :completed,
                request_count: 2,
                slots: slots
              } = engine_status} = RunEngine.status(engine)

      assert attempt_id == Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)
      assert map_size(slots) == 2

      work_count =
        Enum.count(slots, fn {_key, slot} ->
          slot.kind == "local_work" and slot.phase == :settled and slot.outcome == "completed"
        end)

      assert work_count == 1

      budget_count = map_size(DurableUnit.snapshot(unit).control.budgets)
      assert budget_count == 1
      budget = DurableUnit.snapshot(unit).control.budgets["root"].state

      assert {:Transition, _, {:some, {:status, %{committed: 1, reserved: 0}}}} =
               Elzoo.Budget.step(budget, {fixture.clock.(), :status})

      assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
      assert {:ok, []} = Outbox.pending(fixture.command_store, stream, 64)

      expected_answer =
        "answer:" <> Base.encode16(:crypto.hash(:sha256, event["text"]), case: :lower)

      assert {:ok, {{_, 200, _}, _headers, view}} =
               Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

      assert %{"status" => "ok", "view" => %{"messages" => messages}} = Jason.decode!(view)
      assert Enum.any?(messages, &(&1["text"] == expected_answer))
      assert {:ok, status} = RunApprovalRelease.status(fixture.owner, run_id)
      assert status.current_attempt == attempt_id
      assert status.attempts == [attempt_id]

      assert status.operation_id ==
               Elzoo.Wave4ChannelTestHelper.native_operation(fixture.profile, run_id)

      assert status.outcome == :completed
      assert status.completion_revision == completion_revision
      assert_command_receipts(fixture, event, run_id, answer_revision)

      {:ok,
       %{
         run_id: run_id,
         unit_id: unit_id,
         status: status,
         engine_status: engine_status,
         work_count: work_count,
         budget_count: budget_count
       }}
    end
  end

  defp wait_for_result(host, deadline) do
    case Wave4ChannelExample.advance(host) do
      {:result, :completed} = result ->
        result

      {:pending, reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk(
            "native result did not become observable before the deadline: " <>
              "reason=#{inspect(reason)}"
          )
        else
          Process.sleep(1)
          wait_for_result(host, deadline)
        end

      other ->
        flunk("unexpected native completion state: #{inspect(other)}")
    end
  end

  defp assert_input_outbox(fixture, event, sequence) do
    profile = fixture.profile
    stream = checked_stream(profile.tenant)
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(profile, event["event_id"])
    idempotency_key = "#{stream}/#{sequence}/1"

    assert {:ok, [item]} = Outbox.pending(fixture.command_store, stream, 64)

    assert %{
             stream: ^stream,
             sequence: ^sequence,
             position: 1,
             destination: "wave4-channel-input",
             state: :pending,
             idempotency_key: ^idempotency_key,
             ack_nonce: nil,
             ack_digest: nil
           } = item

    assert is_binary(item.nonce) and byte_size(item.nonce) == 16
    assert is_binary(item.digest) and byte_size(item.digest) == 32

    assert Jason.decode!(item.payload) == %{
             "actor" => profile.actor,
             "operation_id" => operation,
             "resource" => profile.conversation_id,
             "revision" => event["expected_revision"] + 1,
             "tenant" => profile.tenant,
             "type" => "checked_command",
             "version" => 1
           }

    item
  end

  defp assert_command_receipts(fixture, event, run_id, answer_revision) do
    profile = fixture.profile
    scope = %{tenant: profile.tenant, actor: profile.actor}
    input_id = event["input_id"]
    input_revision = event["expected_revision"] + 1
    input_operation = Elzoo.Wave4ChannelTestHelper.input_operation(profile, event["event_id"])

    association_operation =
      Elzoo.Wave4ChannelTestHelper.association_operation(profile, event["event_id"], input_id)

    answer_operation =
      Elzoo.Wave4ChannelTestHelper.answer_operation(profile, event["event_id"], input_id)

    answer_id = Elzoo.Wave4ChannelTestHelper.answer_id(input_id)

    assert {:completed, %{revision: ^input_revision, response: {:record, input_fields}}} =
             CheckedCommand.result(
               fixture.handles.input,
               scope,
               {profile.tenant, profile.actor, input_operation}
             )

    assert Map.new(input_fields) == %{
             "message_id" => {:text, input_id},
             "revision" => input_revision
           }

    assert {:completed, %{revision: association_revision, response: {:record, association_fields}}} =
             CheckedCommand.result(
               fixture.handles.association,
               scope,
               {profile.tenant, profile.actor, association_operation}
             )

    assert association_revision == input_revision + 1

    assert Map.new(association_fields) == %{
             "message_id" => {:text, input_id},
             "revision" => association_revision,
             "run_id" => {:text, run_id}
           }

    assert {:completed, %{revision: ^answer_revision, response: {:record, answer_fields}}} =
             CheckedCommand.result(
               fixture.handles.answer,
               scope,
               {profile.tenant, profile.actor, answer_operation}
             )

    assert Map.new(answer_fields) == %{
             "input_message_id" => {:text, input_id},
             "message_id" => {:text, answer_id},
             "revision" => answer_revision,
             "run_id" => {:text, run_id}
           }
  end

  defp expected_answer(event),
    do: "answer:" <> Base.encode16(:crypto.hash(:sha256, event["text"]), case: :lower)

  defp stable_run_status(status),
    do:
      Map.take(status, [
        :id,
        :operation_id,
        :current_attempt,
        :attempts,
        :outcome,
        :completion_revision,
        :evidence_ref
      ])

  defp checked_stream(tenant) do
    "cc1:" <>
      Base.url_encode64(:erlang.term_to_binary({:cc, 1, tenant}, [:deterministic]), padding: false)
  end
end
