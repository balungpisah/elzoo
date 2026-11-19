Code.require_file("support/wave4_channel_helper.exs", __DIR__)

defmodule Elzoo.Wave4ChannelTest.ReadProbe do
  alias Elzoo.{DurableLog.Store, Outbox}

  def attach(store) do
    {:ok, observer} = Agent.start_link(fn -> %{calls: [], counts: %{}, transforms: %{}} end)
    {{__MODULE__, %{store: store, observer: observer}}, observer}
  end

  def calls(observer), do: Agent.get(observer, &Enum.reverse(&1.calls))

  def reset(observer),
    do: Agent.update(observer, &%{&1 | calls: [], counts: %{}, transforms: %{}})

  def transform(observer, operation, fun),
    do: Agent.update(observer, &put_in(&1.transforms[operation], fun))

  def rewrite_item(item, payload) do
    rebuilt =
      Outbox.new(item.stream, item.sequence, item.position, item.destination, payload, item.nonce)

    Map.merge(item, Map.from_struct(rebuilt))
  end

  def capabilities({__MODULE__, state}) do
    record(state.observer, :capabilities)
    Store.read(state.store, :capabilities, [])
  end

  def head({__MODULE__, state}, stream) do
    count = record(state.observer, :head)
    result = Store.read(state.store, :head, [stream])
    apply_transform(state.observer, :head, count, result)
  end

  def read({__MODULE__, state}, stream, from, limit) do
    count = record(state.observer, :read)
    result = Store.read(state.store, :read, [stream, from, limit])
    apply_transform(state.observer, :read, count, result)
  end

  def read_ack({__MODULE__, state}, key) do
    count = record(state.observer, :read_ack)
    result = Store.read(state.store, :read_ack, [key])
    apply_transform(state.observer, :read_ack, count, result)
  end

  defp record(observer, operation) do
    Agent.get_and_update(observer, fn state ->
      count = Map.get(state.counts, operation, 0) + 1

      {count,
       %{
         state
         | calls: [operation | state.calls],
           counts: Map.put(state.counts, operation, count)
       }}
    end)
  end

  defp apply_transform(observer, operation, count, result) do
    case Agent.get(observer, &Map.get(&1.transforms, operation)) do
      fun when is_function(fun, 2) -> fun.(result, count)
      _ -> result
    end
  end
end

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

  setup context do
    fixture =
      if context[:reply_source],
        do: Elzoo.Wave4ChannelTestHelper.reply_fixture(),
        else: Elzoo.Wave4ChannelTestHelper.fixture()

    {:ok, fixture: fixture}
  end

  @tag :reply_source
  test "fixed reply source reads checked primary and reply evidence from PostgreSQL", %{
    fixture: fixture
  } do
    profile =
      fixture.profile
      |> Map.merge(%{
        tenant: String.duplicate("t", 128),
        actor: String.duplicate("a", 128),
        conversation_id: String.duplicate("c", 128),
        source_id: String.duplicate("s", 128),
        reply_source_id: String.duplicate("r", 128),
        native_target: Wave4ChannelExample.NativeBindings.reply_target()
      })

    gates = %{input: fixture.gates.input, reply: fixture.gates.input}

    assert {:ok, handles} =
             Wave4ChannelExample.CommandBindings.build_reply(fixture.command_store, gates)

    denied_gates = %{input: fn _, _ -> :deny end, reply: fixture.gates.input}

    assert {:ok, denied_handles} =
             Wave4ChannelExample.CommandBindings.build_reply(fixture.command_store, denied_gates)

    event_id = "primary-webhook"
    input_id = "primary-message"
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(profile, event_id, input_id)
    primary_operation = Elzoo.Wave4ChannelTestHelper.input_operation(profile, event_id)

    primary_facts =
      {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}

    denied_operation = Elzoo.Wave4ChannelTestHelper.input_operation(profile, "denied-before-reply")

    denied_request = %{
      operation_id: denied_operation,
      resource: profile.conversation_id,
      expected_revision: 0,
      payload: %{"message_id" => "denied-message", "text" => "denied"}
    }

    assert {:denied, {:gate, _}} =
             execute_reply_command(
               denied_handles.input,
               profile,
               denied_request,
               primary_facts,
               &Wave4ChannelExample.CommandBindings.prepare_reply_input/3
             )

    assert {:ok, %{revision: 0}} =
             CheckedCommand.resource(
               denied_handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(profile),
               profile.conversation_id
             )

    assert {:denied, {:gate, _}} =
             CheckedCommand.result(
               handles.input,
               %{tenant: profile.tenant, actor: profile.actor},
               {profile.tenant, profile.actor, denied_operation}
             )

    assert {:ok, []} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(%{fixture | profile: profile})

    primary_request = %{
      operation_id: primary_operation,
      resource: profile.conversation_id,
      expected_revision: 0,
      payload: %{"message_id" => input_id, "text" => "question"}
    }

    assert {:completed, %{revision: 1}} =
             execute_reply_command(
               handles.input,
               profile,
               primary_request,
               primary_facts,
               &Wave4ChannelExample.CommandBindings.prepare_reply_input/3
             )

    assert {:ok, [primary_item]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(%{fixture | profile: profile})

    assert byte_size(primary_item.idempotency_key) > 128

    primary_association_facts =
      {:record,
       [
         {"mode", {:text, "associate_run"}},
         {"primary_key", {:text, primary_item.idempotency_key}},
         {"run_id", {:text, run_id}}
       ]}

    primary_association = %{
      operation_id:
        Elzoo.Wave4ChannelTestHelper.association_operation_for(profile, primary_operation, input_id),
      resource: profile.conversation_id,
      expected_revision: 1,
      payload: %{"message_id" => input_id}
    }

    assert {:completed, %{revision: 2}} =
             execute_reply_command(
               handles.association,
               profile,
               primary_association,
               primary_association_facts,
               &Wave4ChannelExample.CommandBindings.prepare_reply_association/3
             )

    reply_event_id = "reply-webhook"
    reply_operation = Elzoo.Wave4ChannelTestHelper.reply_operation(profile, reply_event_id)
    ticket = "native-ticket-1"
    reply_facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}

    reply_request = %{
      operation_id: reply_operation,
      resource: profile.conversation_id,
      expected_revision: 2,
      payload: %{"message_id" => ticket, "text" => "exact retained reply"}
    }

    assert {:completed, %{revision: 3}} =
             execute_reply_command(
               handles.reply_input,
               profile,
               reply_request,
               reply_facts,
               &Wave4ChannelExample.CommandBindings.prepare_reply_input/3
             )

    assert {:ok, [primary_item, reply_item]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(%{fixture | profile: profile})

    assert byte_size(reply_item.idempotency_key) > 128

    reply_association_facts =
      {:record,
       [
         {"mode", {:text, "associate_run"}},
         {"primary_key", {:text, primary_item.idempotency_key}},
         {"reply_key", {:text, reply_item.idempotency_key}},
         {"run_id", {:text, run_id}}
       ]}

    reply_association = %{
      operation_id:
        Elzoo.Wave4ChannelTestHelper.association_operation_for(profile, reply_operation, ticket),
      resource: profile.conversation_id,
      expected_revision: 3,
      payload: %{"message_id" => ticket}
    }

    assert {:completed, %{revision: 4}} =
             execute_reply_command(
               handles.reply_association,
               profile,
               reply_association,
               reply_association_facts,
               &Wave4ChannelExample.CommandBindings.prepare_reply_association/3
             )

    assert {:completed, %{revision: 1, response: {:record, _}}} =
             CheckedCommand.result(
               handles.input,
               %{tenant: profile.tenant, actor: profile.actor},
               {profile.tenant, profile.actor, primary_operation}
             )

    assert {:completed, %{revision: 3, response: {:record, _}}} =
             CheckedCommand.result(
               handles.reply_input,
               %{tenant: profile.tenant, actor: profile.actor},
               {profile.tenant, profile.actor, reply_operation}
             )

    assert {:completed, %{revision: 2, response: {:record, _}}} =
             CheckedCommand.result(
               handles.association,
               %{tenant: profile.tenant, actor: profile.actor},
               {profile.tenant, profile.actor,
                Elzoo.Wave4ChannelTestHelper.association_operation_for(
                  profile,
                  primary_operation,
                  input_id
                )}
             )

    assert {:completed, %{revision: 4, response: {:record, _}}} =
             CheckedCommand.result(
               handles.reply_association,
               %{tenant: profile.tenant, actor: profile.actor},
               {profile.tenant, profile.actor,
                Elzoo.Wave4ChannelTestHelper.association_operation_for(
                  profile,
                  reply_operation,
                  ticket
                )}
             )

    scope = %{tenant: profile.tenant, principal: profile.actor, run_id: run_id}

    assert {:ok, %{revision: 5, low_water: 0}} =
             Elzoo.DurableLog.Store.read(
               fixture.command_store,
               :head,
               [Elzoo.Wave4ChannelTestHelper.command_stream(profile.tenant)]
             )

    assert {:ok, rows, _} =
             Elzoo.DurableLog.read(
               fixture.command_store,
               Elzoo.Wave4ChannelTestHelper.command_stream(profile.tenant),
               1,
               5
             )

    assert Enum.map(rows, & &1.sequence) == [1, 2, 3, 4, 5]

    assert {:ok, snapshot} =
             CheckedCommand.resource(
               handles.input,
               %{
                 tenant: profile.tenant,
                 actor: profile.actor,
                 resources: [profile.conversation_id]
               },
               profile.conversation_id
             )

    assert {:ok, clean_snapshot} =
             Wave4ChannelExample.CommandBindings.conversation_snapshot(snapshot, profile.tenant)

    assert {:ok, view} =
             Conversation.view(
               clean_snapshot,
               %{tenant: profile.tenant, actor: profile.actor, resources: [profile.conversation_id]}
             )

    assert Enum.any?(
             view.messages,
             &(&1.message_id == ticket and &1.text == "exact retained reply")
           )

    oversized_metadata =
      {:record,
       [
         {"primary_key", {:text, primary_item.idempotency_key}},
         {"reply_key", {:text, reply_item.idempotency_key}},
         {"run_id", {:text, String.duplicate("r", 129)}},
         {"version", {:text, "1"}}
       ]}

    assert {:error, :metadata} =
             Wave4ChannelExample.CommandBindings.conversation_snapshot(
               %{snapshot | fields: Map.put(snapshot.fields, "wave4_reply", oversized_metadata)},
               profile.tenant
             )

    primary = %{
      key: primary_item.idempotency_key,
      operation_id: primary_operation,
      input_id: input_id,
      run_id: run_id
    }

    {probe_store, read_probe} =
      Elzoo.Wave4ChannelTest.ReadProbe.attach(fixture.command_store)

    on_exit(fn -> if Process.alive?(read_probe), do: Agent.stop(read_probe) end)

    assert {:ok, %{head: head, event: event}} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               reply_item.idempotency_key,
               profile,
               run_id,
               probe_store,
               handles,
               primary
             )

    assert head.revision == 5
    assert reply_item.sequence == 4

    assert Elzoo.Wave4ChannelTest.ReadProbe.calls(read_probe) ==
             [:head, :capabilities, :read, :read_ack, :head]

    assert event == %{
             id: reply_item.idempotency_key,
             source_id: profile.reply_source_id,
             correlation_id: ticket,
             sequence: reply_item.sequence,
             schema_id: "message/v1",
             schema_version: 1,
             payload: %{"text" => "exact retained reply"}
           }

    stream = Elzoo.Wave4ChannelTestHelper.command_stream(profile.tenant)

    assert {:rejected, :invalid_retention_range} =
             Elzoo.DurableLog.Postgres.retain(fixture.command_store, stream, 0, 0, <<11::128>>)

    retention_receipt = Elzoo.DurableLog.Codec.receipt(:retain, stream, 0, 0, <<12::128>>)
    Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)

    Elzoo.Wave4ChannelTest.ReadProbe.transform(read_probe, :head, fn
      {:ok, native_head}, _count ->
        {:ok, Map.put(native_head, :last_retention, retention_receipt)}

      result, _count ->
        result
    end)

    Elzoo.Wave4ChannelTest.ReadProbe.transform(read_probe, :read, fn
      {:ok, records, native_head}, _count ->
        {:ok, records, Map.put(native_head, :last_retention, retention_receipt)}

      result, _count ->
        result
    end)

    assert {:ok, normalized_head} =
             Elzoo.Wave4ChannelExample.ReplySource.head(scope, profile, run_id, probe_store)

    assert normalized_head == %{revision: 5, low_water: 0}
    assert Elzoo.Wave4ChannelTest.ReadProbe.calls(read_probe) == [:head]

    assert {:ok, %{head: retained_head, event: ^event}} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               reply_item.idempotency_key,
               profile,
               run_id,
               probe_store,
               handles,
               primary
             )

    assert retained_head == %{revision: 5, low_water: 0}

    assert Elzoo.Wave4ChannelTest.ReadProbe.calls(read_probe) ==
             [:head, :head, :capabilities, :read, :read_ack, :head]

    Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)

    assert %{facts: facts} =
             Wave4ChannelExample.NativeBindings.build(profile).bindings["wait_event"]

    assert facts.(%{}).estimate == 0

    assert Wave4ChannelExample.NativeBindings.build(profile).bindings["local_work"].facts.(%{}).estimate ==
             1

    future =
      Outbox.new(
        Elzoo.Wave4ChannelTestHelper.command_stream(profile.tenant),
        6,
        1,
        "wave4-channel-reply",
        "{}",
        <<0::128>>
      )

    assert {:error, :not_found} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               future.idempotency_key,
               profile,
               run_id,
               probe_store,
               handles,
               primary
             )

    non_event =
      Outbox.new(
        Elzoo.Wave4ChannelTestHelper.command_stream(profile.tenant),
        3,
        1,
        "wave4-channel-reply",
        "{}",
        <<1::128>>
      )

    assert {:error, :not_found} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               non_event.idempotency_key,
               profile,
               run_id,
               probe_store,
               handles,
               primary
             )

    assert {:error, :unavailable} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               reply_item.idempotency_key,
               profile,
               run_id,
               probe_store,
               handles,
               %{primary | operation_id: "wrong-operation"}
             )

    for invalid_scope <- [Map.put(scope, :extra, true), %{scope | principal: "wrong-principal"}] do
      Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)
      Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [:head, :unavailable])

      assert {:error, :unavailable} =
               Elzoo.Wave4ChannelExample.ReplySource.read(
                 invalid_scope,
                 reply_item.idempotency_key,
                 profile,
                 run_id,
                 probe_store,
                 handles,
                 primary
               )

      assert Elzoo.Wave4ChannelTest.ReadProbe.calls(read_probe) == []

      assert {:error, :unavailable} =
               Elzoo.Wave4ChannelExample.ReplySource.head(
                 scope,
                 profile,
                 run_id,
                 probe_store
               )

      assert Elzoo.Wave4ChannelTest.ReadProbe.calls(read_probe) == [:head]
    end

    Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)
    Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [:head, :unavailable])

    assert {:error, :unavailable} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               reply_item.idempotency_key,
               profile,
               run_id,
               probe_store,
               handles,
               primary
             )

    assert Elzoo.Wave4ChannelTest.ReadProbe.calls(read_probe) == [:head]

    Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)

    Elzoo.Wave4ChannelTest.ReadProbe.transform(read_probe, :head, fn
      {:ok, head}, 2 -> {:ok, %{head | revision: head.revision + 1}}
      result, _count -> result
    end)

    assert {:error, :unavailable} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               reply_item.idempotency_key,
               profile,
               run_id,
               probe_store,
               handles,
               primary
             )

    assert Elzoo.Wave4ChannelTest.ReadProbe.calls(read_probe) ==
             [:head, :capabilities, :read, :read_ack, :head]

    for {name, mutate} <- [
          {"item key", &Map.put(&1, :idempotency_key, "not-canonical")},
          {"item nonce", &Map.put(&1, :nonce, <<0::128>>)},
          {"item digest", &Map.put(&1, :digest, <<0::256>>)},
          {"item destination", &Map.put(&1, :destination, "wrong-destination")}
        ] do
      Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)
      transform_reply_item(read_probe, reply_item.idempotency_key, mutate)

      assert {:error, :unavailable} =
               Elzoo.Wave4ChannelExample.ReplySource.read(
                 scope,
                 reply_item.idempotency_key,
                 profile,
                 run_id,
                 probe_store,
                 handles,
                 primary
               ),
             name
    end

    for {name, mutate} <- [
          {"extra notice field", &Map.put(&1, "extra", true)},
          {"wrong notice resource", &Map.put(&1, "resource", "other-resource")},
          {"wrong notice actor", &Map.put(&1, "actor", "other-actor")},
          {"wrong notice tenant", &Map.put(&1, "tenant", "other-tenant")},
          {"wrong notice operation", &Map.put(&1, "operation_id", "other-operation")}
        ] do
      Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)

      transform_reply_item(read_probe, reply_item.idempotency_key, fn item ->
        rewrite_notice(item, mutate)
      end)

      assert {:error, :unavailable} =
               Elzoo.Wave4ChannelExample.ReplySource.read(
                 scope,
                 reply_item.idempotency_key,
                 profile,
                 run_id,
                 probe_store,
                 handles,
                 primary
               ),
             name
    end

    Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)

    transform_reply_item(read_probe, reply_item.idempotency_key, fn item ->
      Elzoo.Wave4ChannelTest.ReadProbe.rewrite_item(item, "not-json")
    end)

    assert {:error, :unavailable} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               reply_item.idempotency_key,
               profile,
               run_id,
               probe_store,
               handles,
               primary
             )

    Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)

    assert {:ok, %{head: valid_head, event: valid_event}} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               reply_item.idempotency_key,
               profile,
               run_id,
               probe_store,
               handles,
               primary
             )

    assert valid_head == %{revision: 5, low_water: 0}
    assert valid_event == event

    Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)
    secondary_fixture = Elzoo.Wave4ChannelTestHelper.fixture()

    assert {:ok, secondary_handles} =
             Wave4ChannelExample.CommandBindings.build_reply(
               secondary_fixture.command_store,
               gates
             )

    mismatched_handles = %{handles | reply_association: secondary_handles.reply_association}

    assert {:error, :unavailable} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               reply_item.idempotency_key,
               profile,
               run_id,
               probe_store,
               mismatched_handles,
               primary
             )

    stream = Elzoo.Wave4ChannelTestHelper.command_stream(profile.tenant)
    {:ok, gap_rows, gap_head} = Elzoo.DurableLog.read(fixture.command_store, stream, 1, 5)

    fold = %{
      initial: %{},
      kinds: %{"checked_command" => :state_bearing},
      versions: [1],
      reduce: fn model, _, _, _ -> model end
    }

    replay = Elzoo.DurableLog.replay(gap_rows, gap_head, fold)

    assert {:committed, 5} =
             Elzoo.Checkpoint.take(
               {fixture.command_store, replay, %{max_checkpoint_bytes: 1_048_576}},
               stream,
               1,
               &:erlang.term_to_binary/1
             )

    assert {:committed, 1} =
             Elzoo.DurableLog.Postgres.retain(fixture.command_store, stream, 0, 1, <<10::128>>)

    assert {:error, :gap} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               reply_item.idempotency_key,
               profile,
               run_id,
               fixture.command_store,
               handles,
               primary
             )
  end

  defp transform_reply_item(observer, key, transform) do
    Elzoo.Wave4ChannelTest.ReadProbe.transform(observer, :read_ack, fn
      {:ok, item}, _count when item.idempotency_key == key -> {:ok, transform.(item)}
      result, _count -> result
    end)
  end

  defp rewrite_notice(item, transform) do
    payload = item.payload |> Jason.decode!() |> transform.() |> Jason.encode!()
    Elzoo.Wave4ChannelTest.ReadProbe.rewrite_item(item, payload)
  end

  defp execute_reply_command(handle, profile, request, data, prepare) do
    scope = Elzoo.Wave4ChannelTestHelper.scope(profile)
    assert {:ok, snapshot} = CheckedCommand.resource(handle, scope, profile.conversation_id)
    facts = %{tenant: profile.tenant, actor: profile.actor, data: data}
    assert {:ok, writes, _} = prepare.(snapshot, request, facts)

    context = %{
      tenant: profile.tenant,
      actor: profile.actor,
      policy: Elzoo.Wave4ChannelTestHelper.policy(),
      own: writes,
      parent: :none,
      facts: data
    }

    CheckedCommand.execute(handle, context, request)
  end

  test "startup requires a unique compatible binding and the fixed ASCII profile", %{
    fixture: fixture
  } do
    Process.flag(:trap_exit, true)
    options = fixture.host_options
    [binding] = options[:bindings]

    assert {:error, :invalid_options} =
             Wave4ChannelExample.start_link(Keyword.put(options, :bindings, []))

    ambiguous = Map.put(binding, "id", "second-channel-binding")

    assert {:error, :invalid_options} =
             Wave4ChannelExample.start_link(Keyword.put(options, :bindings, [binding, ambiguous]))

    wrong_target = put_in(binding["target"]["callable"], "other")

    assert {:error, :invalid_options} =
             Wave4ChannelExample.start_link(Keyword.put(options, :bindings, [wrong_target]))

    arbitrary =
      Map.put(
        options[:profile],
        :native_target,
        Map.put(options[:profile].native_target, "callable", "other")
      )

    arbitrary_binding = put_in(binding["target"]["callable"], "other")

    assert {:error, :invalid_options} =
             Wave4ChannelExample.start_link(
               options
               |> Keyword.put(:profile, arbitrary)
               |> Keyword.put(:bindings, [arbitrary_binding])
             )

    non_ascii = Map.put(options[:profile], :conversation_id, "channel-café")

    assert {:error, :invalid_options} =
             Wave4ChannelExample.start_link(Keyword.put(options, :profile, non_ascii))

    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, "no-run-created")

    assert %{state: :redacted, message: :redacted, reason: :redacted, log: :redacted} =
             Wave4ChannelExample.format_status(%{
               state: "sensitive-event",
               message: "sensitive-credential",
               reason: "sensitive-reason",
               log: "sensitive-log"
             })

    refute inspect(:sys.get_status(fixture.host)) =~ fixture.profile.source_id
  end

  test "ASK survives reopen and releases only once with fresh command evidence", %{
    fixture: fixture
  } do
    gate_control =
      start_supervised!({Agent, fn -> %{fault: nil, store: nil} end}, id: make_ref())

    policy_control = start_supervised!({Agent, fn -> :ask end}, id: make_ref())
    authority_control = start_supervised!({Agent, fn -> %{} end}, id: make_ref())

    gates = %{
      input: controlled_gate(gate_control),
      association: fn _, _ -> :allow end,
      answer: fn _, _ -> :allow end
    }

    policy = fn _mode, _event, _now ->
      Elzoo.Wave4ChannelTestHelper.policy(Agent.get(policy_control, & &1))
    end

    authority = fn mode, _event, _request, _facts ->
      if mode == :release, do: Agent.get(authority_control, & &1), else: %{}
    end

    fixture = host_with_gates(fixture, gates, policy: policy, authority: authority)
    set_gate_fault(gate_control, fixture.command_store, nil)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)

    event = Elzoo.Wave4ChannelTestHelper.event()
    event_id = event["event_id"]

    normalized = %{
      version: event["version"],
      event_id: event["event_id"],
      conversation_id: event["conversation_id"],
      input_id: event["input_id"],
      expected_revision: event["expected_revision"],
      text: event["text"]
    }

    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])
    identity = {fixture.profile.tenant, fixture.profile.actor, operation}
    scope = %{tenant: fixture.profile.tenant, actor: fixture.profile.actor}

    assert {:ok, {{_, 202, _}, _, body}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert %{"event_id" => ^event_id, "status" => "pending_approval"} = Jason.decode!(body)

    assert {:approval_pending, %{key: key, requirement: requirement}} =
             CheckedCommand.result(fixture.handles.input, scope, identity)

    assert {:ok, %{revision: 0}} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               fixture.profile.conversation_id
             )

    assert {:ok, %{revision: 1}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        event["event_id"],
        event["input_id"]
      )

    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)

    assert :not_found =
             DynamicUnits.find(fixture.directory, Elzoo.Wave4ChannelTestHelper.unit_id(run_id))

    assert take_hash_calls() == []

    before_replay = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])
    Elzoo.Wave4ChannelTestHelper.stop_listener!(listener)
    GenServer.stop(fixture.host, :normal)
    reopened_store = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :reopen, [])
    {:ok, reopened_handles} = Elzoo.Wave4ChannelExample.CommandBindings.build(reopened_store, gates)

    host_options =
      fixture.host_options
      |> Keyword.put(:command_store, reopened_store)
      |> Keyword.put(:handles, reopened_handles)

    fixture = %{
      fixture
      | command_store: reopened_store,
        handles: reopened_handles,
        host_options: host_options
    }

    host = Elzoo.Wave4ChannelTestHelper.start_host!(fixture)
    fixture = %{fixture | host: host}
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)

    assert {:approval_pending, %{key: ^key, requirement: ^requirement}} =
             CheckedCommand.result(fixture.handles.input, scope, identity)

    assert {:ok, {{_, 202, _}, _, replay_body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert %{"event_id" => ^event_id, "status" => "pending_approval"} =
             Jason.decode!(replay_body)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             before_replay

    before_refusals = before_replay

    assert {:rejected, :conflict} =
             Wave4ChannelExample.release(
               fixture.host,
               %{normalized | text: "changed original event"},
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               %{purpose: :command, tenant: fixture.profile.tenant, evidence: %{}}
             )

    now = System.system_time(:millisecond)

    evidence = %{
      verifier: "wave4-command-approver",
      evidence_id: "release-valid",
      reviewer: "human-reviewer",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: now - 1_000,
      expiry: now + 60_000
    }

    envelope = %{purpose: :command, tenant: fixture.profile.tenant, evidence: evidence}

    request = %{
      operation_id: operation,
      resource: normalized.conversation_id,
      expected_revision: normalized.expected_revision,
      payload: %{"message_id" => normalized.input_id, "text" => normalized.text}
    }

    facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
    prepared_facts = %{tenant: fixture.profile.tenant, actor: fixture.profile.actor, data: facts}

    assert {:ok, snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               normalized.conversation_id
             )

    assert {:ok, writes, _response} = Conversation.prepare(snapshot, request, prepared_facts)

    release_authority = %{
      approver: %{identity: "human-reviewer", authority: writes},
      now: now,
      revoked: []
    }

    Agent.update(authority_control, fn _ -> release_authority end)

    assert {:rejected, :invalid} =
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               %{envelope | purpose: :run}
             )

    wrong_request = %{
      evidence
      | evidence_id: "release-wrong-request",
        request: put_elem(key, 1, "other")
    }

    assert match?(
             {:rejected, _},
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               %{envelope | evidence: wrong_request}
             )
           )

    Agent.update(policy_control, fn _ -> :deny end)

    assert match?(
             {:rejected, _},
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               %{envelope | evidence: %{evidence | evidence_id: "release-changed-policy"}}
             )
           )

    Agent.update(policy_control, fn _ -> :ask end)

    revoked = %{
      release_authority
      | revoked: [{evidence.verifier, "release-revoked"}]
    }

    Agent.update(authority_control, fn _ -> revoked end)

    assert match?(
             {:rejected, _},
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               %{envelope | evidence: %{evidence | evidence_id: "release-revoked"}}
             )
           )

    self_approval = %{
      release_authority
      | approver: %{identity: fixture.profile.actor, authority: writes}
    }

    Agent.update(authority_control, fn _ -> self_approval end)

    assert match?(
             {:rejected, _},
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               %{envelope | evidence: %{evidence | evidence_id: "release-self"}}
             )
           )

    Agent.update(authority_control, fn _ -> release_authority end)

    assert match?(
             {:rejected, _},
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               %{
                 envelope
                 | evidence: %{
                     evidence
                     | evidence_id: "release-stale",
                       issued_at: now - 60_001,
                       expiry: now + 60_000
                   }
               }
             )
           )

    assert match?(
             {:rejected, _},
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               %{
                 envelope
                 | evidence: %{
                     evidence
                     | evidence_id: "release-expired",
                       issued_at: now - 1_000,
                       expiry: now - 1
                   }
               }
             )
           )

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             before_refusals

    assert {:approval_pending, %{key: ^key, requirement: ^requirement}} =
             CheckedCommand.result(fixture.handles.input, scope, identity)

    set_gate_fault(gate_control, fixture.command_store, :reply_loss)

    assert {:unknown, :unavailable} =
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               envelope
             )

    Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [:read, :unavailable])
    assert {:unknown, :release} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, {{_, 200, _}, _, view_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 1}} = Jason.decode!(view_body)

    assert {:error, :unavailable} =
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               envelope
             )

    assert {:reconciled, :release} = Wave4ChannelExample.advance(fixture.host)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.result(fixture.handles.input, scope, identity)

    released_item = assert_input_outbox(fixture, event, 2)

    assert {:ok, {{_, 202, _}, _, committed_body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert %{"event_id" => ^event_id, "revision" => 1, "status" => "committed"} =
             Jason.decode!(committed_body)

    assert ^released_item = assert_input_outbox(fixture, event, 2)

    Agent.update(policy_control, fn _ -> :allow end)
    assert {:ok, %{run_id: first_run}} = process_event(fixture, listener, event, 3, 2, 4)

    second =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "ask-followup",
        "input_id" => "ask-followup-input",
        "expected_revision" => 3,
        "text" => "continued after release"
      })

    assert {:ok, %{run_id: second_run}} = process_event(fixture, listener, second, 6, 5, 7)
    assert first_run != second_run
    assert {:ok, %{revision: 7}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert take_hash_calls() == []
  end

  test "initial ASK reply loss recovers the same pending requirement after a read outage", %{
    fixture: fixture
  } do
    gate_control = start_supervised!({Agent, fn -> %{fault: nil, store: nil} end}, id: make_ref())
    policy_control = start_supervised!({Agent, fn -> :ask end}, id: make_ref())
    authority_control = start_supervised!({Agent, fn -> %{} end}, id: make_ref())

    gates = %{
      input: controlled_gate(gate_control),
      association: fn _, _ -> :allow end,
      answer: fn _, _ -> :allow end
    }

    policy = fn _mode, _event, _now ->
      Elzoo.Wave4ChannelTestHelper.policy(Agent.get(policy_control, & &1))
    end

    authority = fn mode, _event, _request, _facts ->
      if mode == :release, do: Agent.get(authority_control, & &1), else: %{}
    end

    fixture = host_with_gates(fixture, gates, policy: policy, authority: authority)
    set_gate_fault(gate_control, fixture.command_store, :reply_loss)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    event_id = event["event_id"]
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event_id)
    identity = {fixture.profile.tenant, fixture.profile.actor, operation}
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event_id, event["input_id"])
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    unit_after_ask = Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :append) == nil
    assert {:ok, %{revision: 1}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, %{revision: 0}} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               fixture.profile.conversation_id
             )

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, []) ==
             unit_after_ask

    pending_state = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])
    Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [:read, :unavailable])
    assert {:unknown, :input} = Wave4ChannelExample.advance(fixture.host)
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :read) == nil

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             pending_state

    assert {:reconciled, :approval_pending} = Wave4ChannelExample.advance(fixture.host)

    assert {:approval_pending, %{key: key, requirement: requirement}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    assert %{key: ^key, requirement: ^requirement} = :sys.get_state(fixture.host).approval

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             pending_state

    assert {:ok, {{_, 202, _}, _, pending_body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert %{"event_id" => ^event_id, "status" => "pending_approval"} = Jason.decode!(pending_body)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             pending_state

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert take_hash_calls() == []

    now = System.system_time(:millisecond)

    evidence = %{
      verifier: "wave4-command-approver",
      evidence_id: "initial-ask-release",
      reviewer: "human-reviewer",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: now - 1_000,
      expiry: now + 60_000
    }

    envelope = %{purpose: :command, tenant: fixture.profile.tenant, evidence: evidence}

    normalized = %{
      version: event["version"],
      event_id: event_id,
      conversation_id: event["conversation_id"],
      input_id: event["input_id"],
      expected_revision: event["expected_revision"],
      text: event["text"]
    }

    request = %{
      operation_id: operation,
      resource: normalized.conversation_id,
      expected_revision: normalized.expected_revision,
      payload: %{"message_id" => normalized.input_id, "text" => normalized.text}
    }

    facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
    prepared_facts = %{tenant: fixture.profile.tenant, actor: fixture.profile.actor, data: facts}

    assert {:ok, snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               normalized.conversation_id
             )

    assert {:ok, writes, _response} = Conversation.prepare(snapshot, request, prepared_facts)

    Agent.update(authority_control, fn _ ->
      %{approver: %{identity: "human-reviewer", authority: writes}, now: now, revoked: []}
    end)

    assert {:committed, 1} =
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               envelope
             )

    assert {:completed, %{revision: 1}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    released_item = assert_input_outbox(fixture, event, 2)
    released_state = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])

    assert {:ok, {{_, 202, _}, _, committed_body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert %{"event_id" => ^event_id, "revision" => 1, "status" => "committed"} =
             Jason.decode!(committed_body)

    assert ^released_item = assert_input_outbox(fixture, event, 2)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             released_state

    assert {:ok, %{revision: 2}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert take_hash_calls() == []
  end

  test "a paused release writer cannot reconcile from the earlier ASK receipt", %{fixture: fixture} do
    gate_control = start_supervised!({Agent, fn -> %{fault: nil, store: nil} end}, id: make_ref())
    policy_control = start_supervised!({Agent, fn -> :ask end}, id: make_ref())
    authority_control = start_supervised!({Agent, fn -> %{} end}, id: make_ref())

    clock_control =
      start_supervised!({Agent, fn -> fixture.profile.deadline_ms - 1_000 end}, id: make_ref())

    clock = fn -> Agent.get(clock_control, & &1) end

    gates = %{
      input: controlled_gate(gate_control),
      association: fn _, _ -> :allow end,
      answer: fn _, _ -> :allow end
    }

    policy = fn _mode, _event, _now ->
      Elzoo.Wave4ChannelTestHelper.policy(Agent.get(policy_control, & &1))
    end

    authority = fn mode, _event, _request, _facts ->
      if mode == :release, do: Agent.get(authority_control, & &1), else: %{}
    end

    fixture =
      host_with_gates(fixture, gates,
        policy: policy,
        authority: authority,
        clock: clock
      )

    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    event_id = event["event_id"]
    input_id = event["input_id"]
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event_id)
    identity = {fixture.profile.tenant, fixture.profile.actor, operation}
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event_id, input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    normalized = %{
      version: event["version"],
      event_id: event_id,
      conversation_id: event["conversation_id"],
      input_id: input_id,
      expected_revision: event["expected_revision"],
      text: event["text"]
    }

    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert {:approval_pending, %{key: key, requirement: requirement}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    now = clock.()
    assert now < fixture.profile.deadline_ms

    evidence = %{
      verifier: "wave4-command-approver",
      evidence_id: "paused-release",
      reviewer: "human-reviewer",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: now - 1_000,
      expiry: now + 60_000
    }

    envelope = %{purpose: :command, tenant: fixture.profile.tenant, evidence: evidence}

    request = %{
      operation_id: operation,
      resource: normalized.conversation_id,
      expected_revision: normalized.expected_revision,
      payload: %{"message_id" => normalized.input_id, "text" => normalized.text}
    }

    facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
    prepared_facts = %{tenant: fixture.profile.tenant, actor: fixture.profile.actor, data: facts}

    assert {:ok, snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               normalized.conversation_id
             )

    assert {:ok, writes, _response} = Conversation.prepare(snapshot, request, prepared_facts)

    Agent.update(authority_control, fn _ ->
      %{approver: %{identity: "human-reviewer", authority: writes}, now: now, revoked: []}
    end)

    before_release = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])
    token = :wave4_release_writer
    set_gate_fault(gate_control, fixture.command_store, {:pause, token})

    caller =
      Task.async(fn ->
        Wave4ChannelExample.release(
          fixture.host,
          normalized,
          Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
          envelope
        )
      end)

    writer = wait_for_paused(fixture.controller, token, System.monotonic_time(:millisecond) + 5_000)
    assert writer.operation == :append
    assert is_integer(writer.backend)
    assert Process.alive?(writer.pid)
    assert {:unknown, :unavailable} = Task.await(caller, 10_000)
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :append) == nil

    assert {:approval_pending, %{key: ^key, requirement: ^requirement}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    assert {:unknown, :release} = Wave4ChannelExample.advance(fixture.host)
    assert Process.alive?(writer.pid)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             before_release

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert take_hash_calls() == []

    blocked_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "blocked-by-release-unknown",
        "input_id" => "blocked-release-input",
        "expected_revision" => 0
      })

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, blocked_event)

    assert {:error, :unavailable} =
             Wave4ChannelExample.release(
               fixture.host,
               normalized,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               envelope
             )

    assert {:approval_pending, %{key: ^key, requirement: ^requirement}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             before_release

    Agent.update(clock_control, fn _ -> fixture.profile.deadline_ms + 1 end)
    assert clock.() > fixture.profile.deadline_ms

    writer_ref = Process.monitor(writer.pid)

    assert {:committed, _revision} =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :release, [token])

    assert_receive {:DOWN, ^writer_ref, :process, writer_pid, _reason}, 5_000
    assert writer_pid == writer.pid
    assert Agent.get(fixture.controller, &Map.get(&1.paused, token)) == nil

    refute Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             before_release

    assert {:reconciled, :release} = Wave4ChannelExample.advance(fixture.host)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    released_item = assert_input_outbox(fixture, event, 2)
    released_state = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])
    assert {:ok, {{_, 202, _}, _, replay_body}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert %{"event_id" => ^event_id, "revision" => 1, "status" => "committed"} =
             Jason.decode!(replay_body)

    assert ^released_item = assert_input_outbox(fixture, event, 2)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             released_state

    assert {:ok, %{revision: 2}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert take_hash_calls() == []
  end

  test "committed input reply loss stays fenced through read outage until identity confirmation", %{
    fixture: fixture
  } do
    gate_control = start_supervised!({Agent, fn -> %{fault: nil, store: nil} end}, id: make_ref())

    gates = %{
      input: controlled_gate(gate_control),
      association: fn _, _ -> :allow end,
      answer: fn _, _ -> :allow end
    }

    fixture = host_with_gates(fixture, gates)
    set_gate_fault(gate_control, fixture.command_store, :reply_loss)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    event = Elzoo.Wave4ChannelTestHelper.event()
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])
    identity = {fixture.profile.tenant, fixture.profile.actor, operation}

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:ok, %{revision: 1}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert_input_outbox(fixture, event, 1)

    committed_state =
      Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])

    Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [:read, :unavailable])
    assert {:unknown, :input} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, {{_, 200, _}, _, view_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 1}} = Jason.decode!(view_body)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(
               listener,
               Elzoo.Wave4ChannelTestHelper.event(%{
                 "event_id" => "blocked-during-input-unknown",
                 "input_id" => "blocked-input",
                 "expected_revision" => 1
               })
             )

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             committed_state

    assert {:reconciled, :input} = Wave4ChannelExample.advance(fixture.host)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    assert {:ok, {{_, 202, _}, _, replay_body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert %{"revision" => 1, "status" => "committed"} = Jason.decode!(replay_body)

    assert ^committed_state =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])

    assert {:ok, %{run_id: _run_id}} = process_event(fixture, listener, event, 3, 1, 4)

    next =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "after-input-confirmation",
        "input_id" => "after-confirmation-input",
        "expected_revision" => 3,
        "text" => "approval state was cleared"
      })

    assert {:ok, {{_, 202, _}, _, next_body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, next)

    assert %{"revision" => 4, "status" => "committed"} = Jason.decode!(next_body)
    assert {:ok, %{revision: 4}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert take_hash_calls() == []
  end

  test "retained input denial reconciles after reply loss without admitting through read outage", %{
    fixture: fixture
  } do
    gate_control = start_supervised!({Agent, fn -> :deny end}, id: make_ref())

    input_gate = fn _frame, _context ->
      verdict =
        Agent.get_and_update(gate_control, fn
          :deny -> {:deny, :allow}
          :allow -> {:allow, :allow}
        end)

      case verdict do
        :deny ->
          Elzoo.DurableLog.PostgresHarness.hook(
            fixture.command_store,
            :inject,
            [:read_at, :unavailable]
          )

          Elzoo.DurableLog.PostgresHarness.hook(
            fixture.command_store,
            :inject,
            [:append, :reply_loss]
          )

          :deny

        :allow ->
          :allow
      end
    end

    gates = %{
      input: input_gate,
      association: fn _, _ -> :allow end,
      answer: fn _, _ -> :allow end
    }

    fixture = host_with_gates(fixture, gates)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "reply-lost-denial"})
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])
    identity = {fixture.profile.tenant, fixture.profile.actor, operation}

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert {:denied, {:gate, _}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [:read, :unavailable])
    assert {:unknown, :input} = Wave4ChannelExample.advance(fixture.host)

    blocked = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "denial-still-fenced"})
    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, blocked)

    assert {:denied, {:gate, _}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    assert {:reconciled, :input_terminal} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, %{revision: 1}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, %{revision: 0}} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               fixture.profile.conversation_id
             )

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:unknown, :not_observed} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor,
                Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, blocked["event_id"])}
             )

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        event["event_id"],
        event["input_id"]
      )

    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)

    assert :not_found =
             DynamicUnits.find(fixture.directory, Elzoo.Wave4ChannelTestHelper.unit_id(run_id))

    assert take_hash_calls() == []
    drain_read_at_fault!(fixture, fixture.profile)

    next =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "after-denial-reconciliation",
        "input_id" => "after-denial-input",
        "expected_revision" => 0
      })

    next_operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, next["event_id"])

    assert {:ok, {{_, 202, _}, _, next_body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, next)

    assert %{"revision" => 1, "status" => "committed"} = Jason.decode!(next_body)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, next_operation}
             )

    assert_input_outbox(fixture, next, 2)

    assert {:ok, %{revision: 1}} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               fixture.profile.conversation_id
             )

    assert take_hash_calls() == []
  end

  test "retained stale release conflict reconciles after read outage", %{fixture: fixture} do
    trace_native_hash(fixture.native.task_supervisor)
    race = stale_release_race!(fixture, :reply_loss)
    fixture = race.fixture
    listener = race.listener
    profile = fixture.profile

    assert race.release_result == {:unknown, :unavailable}
    assert race.retained_result == {:conflict, :stale_revision}

    Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [:read, :unavailable])
    assert {:unknown, :release} = Wave4ChannelExample.advance(fixture.host)

    blocked =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "stale-release-still-fenced",
        "input_id" => "stale-release-blocked-input",
        "expected_revision" => 1
      })

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, blocked)

    assert {:unknown, :not_observed} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: profile.tenant, actor: profile.actor},
               {profile.tenant, profile.actor,
                Elzoo.Wave4ChannelTestHelper.input_operation(profile, blocked["event_id"])}
             )

    assert {:conflict, :stale_revision} =
             CheckedCommand.result(fixture.handles.input, race.scope, race.identity)

    assert {:reconciled, :release_conflict} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, %{revision: 1}} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(profile),
               profile.conversation_id
             )

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        profile,
        race.event["event_id"],
        race.event["input_id"]
      )

    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)

    assert :not_found =
             DynamicUnits.find(fixture.directory, Elzoo.Wave4ChannelTestHelper.unit_id(run_id))

    drain_read_at_fault!(fixture, profile)

    next =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "after-release-conflict-reconciliation",
        "input_id" => "after-release-conflict-input",
        "expected_revision" => 1
      })

    next_operation = Elzoo.Wave4ChannelTestHelper.input_operation(profile, next["event_id"])

    assert {:ok, {{_, 202, _}, _, next_body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, next)

    assert %{"revision" => 2, "status" => "committed"} = Jason.decode!(next_body)

    assert {:completed, %{revision: 2}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: profile.tenant, actor: profile.actor},
               {profile.tenant, profile.actor, next_operation}
             )

    assert_input_outbox(fixture, next, 4)
    assert take_hash_calls() == []
  end

  test "direct stale release conflict does not poison future admission", %{fixture: fixture} do
    trace_native_hash(fixture.native.task_supervisor)
    race = stale_release_race!(fixture, :direct)
    fixture = race.fixture
    profile = fixture.profile

    assert race.release_result == {:rejected, :conflict}
    assert race.retained_result == {:conflict, :stale_revision}
    assert {:idle, :no_input} = Wave4ChannelExample.advance(fixture.host)

    next =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "after-direct-release-conflict",
        "input_id" => "after-direct-release-input",
        "expected_revision" => 1
      })

    next_operation = Elzoo.Wave4ChannelTestHelper.input_operation(profile, next["event_id"])

    assert {:ok, {{_, 202, _}, _, next_body}} =
             Elzoo.Wave4ChannelTestHelper.post(race.listener, next)

    assert %{"revision" => 2, "status" => "committed"} = Jason.decode!(next_body)

    assert {:completed, %{revision: 2}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: profile.tenant, actor: profile.actor},
               {profile.tenant, profile.actor, next_operation}
             )

    assert_input_outbox(fixture, next, 4)
    assert take_hash_calls() == []
  end

  test "paused input writer is not treated as non-commit and stays fenced until it exits", %{
    fixture: fixture
  } do
    gate_control = start_supervised!({Agent, fn -> %{fault: nil, store: nil} end}, id: make_ref())

    gates = %{
      input: controlled_gate(gate_control),
      association: fn _, _ -> :allow end,
      answer: fn _, _ -> :allow end
    }

    fixture = host_with_gates(fixture, gates)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    token = :wave4_input_writer
    set_gate_fault(gate_control, fixture.command_store, {:pause, token})

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    paused = Elzoo.DurableLog.PostgresHarness.paused(fixture.controller, token)
    assert Process.alive?(paused.pid)

    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])

    assert {:unknown, :not_observed} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, operation}
             )

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(
               listener,
               Elzoo.Wave4ChannelTestHelper.event(%{
                 "event_id" => "blocked-live-writer",
                 "input_id" => "blocked-live-input"
               })
             )

    _ = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :release, [token])

    assert {:ok, {{_, 200, _}, _, view_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 1}} = Jason.decode!(view_body)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(
               listener,
               Elzoo.Wave4ChannelTestHelper.event(%{
                 "event_id" => "blocked-after-writer-exit",
                 "input_id" => "blocked-after-exit-input",
                 "expected_revision" => 1
               })
             )

    assert {:reconciled, :input} = Wave4ChannelExample.advance(fixture.host)
    item = assert_input_outbox(fixture, event, 1)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, operation}
             )

    assert item.idempotency_key == "#{checked_stream(fixture.profile.tenant)}/1/1"
  end

  test "association reply loss stays fenced with zero native allocation until confirmation", %{
    fixture: fixture
  } do
    gate_control = start_supervised!({Agent, fn -> %{fault: nil, store: nil} end}, id: make_ref())

    gates = %{
      input: fn _, _ -> :allow end,
      association: controlled_gate(gate_control),
      answer: fn _, _ -> :allow end
    }

    fixture = host_with_gates(fixture, gates)
    set_gate_fault(gate_control, fixture.command_store, nil)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    event = Elzoo.Wave4ChannelTestHelper.event()

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    item = assert_input_outbox(fixture, event, 1)
    input_id = event["input_id"]
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        event["event_id"],
        event["input_id"]
      )

    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    set_gate_fault(gate_control, fixture.command_store, :reply_loss)

    assert {:unknown, :association} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, %{revision: 2}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert take_hash_calls() == []

    Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [:read, :unavailable])
    assert {:unknown, :association} = Wave4ChannelExample.advance(fixture.host)

    before_reads = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])

    assert {:ok, {{_, 503, _}, _, unavailable_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert Jason.decode!(unavailable_body) == %{"status" => "unavailable"}

    blocked =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "blocked-after-association-loss",
        "input_id" => "blocked-association-input",
        "expected_revision" => 2
      })

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, blocked)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             before_reads

    assert item == assert_input_outbox(fixture, event, 1)
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert take_hash_calls() == []

    assert {:reconciled, :association} = Wave4ChannelExample.advance(fixture.host)

    assert {:completed, %{revision: 2}} =
             CheckedCommand.result(
               fixture.handles.association,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor,
                Elzoo.Wave4ChannelTestHelper.association_operation(
                  fixture.profile,
                  event["event_id"],
                  event["input_id"]
                )}
             )

    assert {:run_created, _owner_revision} = Wave4ChannelExample.advance(fixture.host)
    assert item == assert_input_outbox(fixture, event, 1)
    assert {:attempt_started, _attempt_id} = Wave4ChannelExample.advance(fixture.host)
    assert take_hash_calls() == []
  end

  test "committed answer reply loss reconciles without rerunning native work or replacing the answer",
       %{
         fixture: fixture
       } do
    gate_control = start_supervised!({Agent, fn -> %{fault: nil, store: nil} end}, id: make_ref())

    gates = %{
      input: fn _, _ -> :allow end,
      association: fn _, _ -> :allow end,
      answer: controlled_gate(gate_control)
    }

    fixture = host_with_gates(fixture, gates)
    set_gate_fault(gate_control, fixture.command_store, nil)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    event = Elzoo.Wave4ChannelTestHelper.event()

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    item = assert_input_outbox(fixture, event, 1)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        event["event_id"],
        event["input_id"]
      )

    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    input_id = event["input_id"]
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _owner_revision} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _attempt_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == [event["text"]]
    assert {:ok, %{revision: 2}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    set_gate_fault(gate_control, fixture.command_store, :reply_loss)
    assert {:unknown, :answer} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, %{revision: 3}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, resource} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               fixture.profile.conversation_id
             )

    assert resource.revision == 3
    assert item == assert_input_outbox(fixture, event, 1)
    committed_state = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])

    Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [:read, :unavailable])
    assert {:unknown, :answer} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, {{_, 200, _}, _, view_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 3}} = Jason.decode!(view_body)

    blocked =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "blocked-after-answer-loss",
        "input_id" => "blocked-answer-input",
        "expected_revision" => 3
      })

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, blocked)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             committed_state

    assert item == assert_input_outbox(fixture, event, 1)
    assert take_hash_calls() == []

    assert {:reconciled, :answer} = Wave4ChannelExample.advance(fixture.host)

    answer_operation =
      Elzoo.Wave4ChannelTestHelper.answer_operation(
        fixture.profile,
        event["event_id"],
        event["input_id"]
      )

    assert {:completed, %{revision: 3}} =
             CheckedCommand.result(
               fixture.handles.answer,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, answer_operation}
             )

    assert {:ok, %{revision: 3}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             committed_state

    assert item == assert_input_outbox(fixture, event, 1)
    assert take_hash_calls() == []

    assert {:acknowledged, input_id} = Wave4ChannelExample.advance(fixture.host)
    assert input_id == event["input_id"]
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, %{state: :acked, ack_nonce: nonce}} =
             Elzoo.DurableLog.Store.read(
               fixture.command_store,
               :read_ack,
               [item.idempotency_key]
             )

    assert nonce == item.nonce
    assert take_hash_calls() == []
  end

  test "dead registry registrations do not block a committed answer acknowledgement", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == [event["text"]]
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [{engine_pid, _}] = Registry.lookup(fixture.native.registry, unit_id)
    [{unit_pid, nil}] = Registry.lookup(Elzoo.RunEngine.UnitRegistry, unit_id)
    assert Process.alive?(engine_pid)
    assert Process.alive?(unit_pid)

    partitions =
      registry_partition_pids!(fixture.native.registry) ++
        registry_partition_pids!(Elzoo.RunEngine.UnitRegistry)

    ack_result =
      with_suspended_registry_partitions(partitions, fn ->
        result = Wave4ChannelExample.advance(fixture.host)
        refute Process.alive?(engine_pid)
        refute Process.alive?(unit_pid)
        assert [{^engine_pid, _}] = Registry.lookup(fixture.native.registry, unit_id)
        assert [{^unit_pid, nil}] = Registry.lookup(Elzoo.RunEngine.UnitRegistry, unit_id)

        assert {:ok, ack} =
                 Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
                   item.idempotency_key
                 ])

        assert ack.state == :acked
        assert ack.idempotency_key == item.idempotency_key
        assert ack.ack_nonce == item.nonce

        assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
        result
      end)

    assert {:acknowledged, ^input_id} = ack_result
    assert take_hash_calls() == []

    deadline = System.monotonic_time(:millisecond) + 5_000
    wait_for_registry_cleanup!(fixture.native.registry, unit_id, deadline)
    wait_for_registry_cleanup!(Elzoo.RunEngine.UnitRegistry, unit_id, deadline)
  end

  test "fenced reopen recovers association, native result, and answer without replacement work", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()

    stale =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "before-recovery",
        "expected_revision" => 1
      })

    assert {:ok, {{_, 409, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, stale)
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    item = assert_input_outbox(fixture, event, 2)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    input_id = event["input_id"]

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, attempt_id} = Wave4ChannelExample.advance(fixture.host)
    assert attempt_id == Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)

    assert {:ok, %{current_attempt: ^attempt_id, outcome: nil}} =
             RunApprovalRelease.status(fixture.owner, run_id)

    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == [event["text"]]

    assert {:ok, run_status_before} = RunApprovalRelease.status(fixture.owner, run_id)
    assert {:ok, unit_before} = DynamicUnits.find(fixture.directory, unit_id)
    [{engine_before, _}] = Registry.lookup(fixture.native.registry, unit_id)
    unit_status_before = RunEngine.status(engine_before)
    budget_before = DurableUnit.snapshot(unit_before).control.budgets["root"].state

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :duplicate} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == []
    assert {:ok, run_status_after} = RunApprovalRelease.status(fixture.owner, run_id)
    assert stable_run_status(run_status_after) == stable_run_status(run_status_before)
    assert {:ok, unit_after} = DynamicUnits.find(fixture.directory, unit_id)
    [{engine_after, _}] = Registry.lookup(fixture.native.registry, unit_id)
    assert {:ok, engine_status_after} = RunEngine.status(engine_after)
    assert {:ok, engine_status_before} = unit_status_before
    assert engine_status_after.request_count == engine_status_before.request_count
    assert DurableUnit.snapshot(unit_after).control.budgets["root"].state == budget_before

    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)

    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert take_hash_calls() == []
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:ok, %{revision: 4}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, %{state: :acked, sequence: 2, ack_nonce: nonce, idempotency_key: key}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [item.idempotency_key])

    assert key == item.idempotency_key
    assert nonce == item.nonce

    assert {:ok, {{_, 200, _}, _, view}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 3, "messages" => messages}} =
             Jason.decode!(view)

    assert Enum.count(messages, &(&1["role"] == "assistant")) == 1
  end

  test "ack reply loss is positively confirmed by the original canonical key and nonce", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)

    stale =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "ack-prerequisite",
        "expected_revision" => 1
      })

    event = Elzoo.Wave4ChannelTestHelper.event()

    assert {:ok, {{_, 409, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, stale)
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    item = assert_input_outbox(fixture, event, 2)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    input_id = event["input_id"]
    trace_native_hash(fixture.native.task_supervisor)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:ack, :reply_loss]
             )

    ack_result = Wave4ChannelExample.advance(fixture.host)
    faults = Agent.get(fixture.controller, & &1.faults)
    assert Map.get(faults, :ack) == nil
    assert {:acknowledged, ^input_id} = ack_result

    assert {:ok, {{_, 200, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 3}} = Jason.decode!(body)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert take_hash_calls() == [event["text"]]

    assert {:idle, :no_input} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, %{state: :acked, sequence: 2, ack_nonce: nonce, idempotency_key: key}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [item.idempotency_key])

    assert key == item.idempotency_key
    assert nonce == item.nonce
    assert {:ok, %{revision: 4}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
  end

  test "ack rollback remains fenced and reopens directly from the retained answer", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == [event["text"]]
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    ack_key = item.idempotency_key
    ack_nonce = item.nonce

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:ack, :rollback]
             )

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:read_ack, :unavailable]
             )

    assert Map.take(Agent.get(fixture.native_controller, & &1.faults), [:ack, :read_ack]) == %{}
    assert {:unknown, :ack} = Wave4ChannelExample.advance(fixture.host)
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :read_ack) == nil
    assert Map.take(Agent.get(fixture.native_controller, & &1.faults), [:ack, :read_ack]) == %{}
    assert {:ack, ^ack_key, ^ack_nonce, _receipt} = :sys.get_state(fixture.host).poison

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:read_ack, :malformed]
             )

    assert {:unknown, :ack} = Wave4ChannelExample.advance(fixture.host)
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :read_ack) == nil
    assert {:unknown, :ack} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, [^item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 200, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 3, "messages" => messages}} =
             Jason.decode!(body)

    assert Enum.count(messages, &(&1["role"] == "assistant")) == 1

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert take_hash_calls() == []
    assert {:ok, %{revision: 3}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, %{state: :acked, ack_nonce: nonce, idempotency_key: key, sequence: 1}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [item.idempotency_key])

    assert key == item.idempotency_key
    assert nonce == item.nonce
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 200, _}, _, view_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 3, "messages" => recovered_messages}} =
             Jason.decode!(view_body)

    assert Enum.count(recovered_messages, &(&1["role"] == "assistant")) == 1
  end

  test "a different nonce winning the original ack key reports conflict and retains host poison", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    original_key = item.idempotency_key
    original_nonce = item.nonce
    other_nonce = :crypto.strong_rand_bytes(16)
    refute other_nonce == original_nonce

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:ack, :rollback]
             )

    assert {:unknown, :ack} = Wave4ChannelExample.advance(fixture.host)
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :ack) == nil

    assert {:committed, _sequence} =
             Elzoo.Outbox.ack(fixture.command_store, original_key, other_nonce)

    assert {:ok, head_before_conflict} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:blocked, :ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert {:ack, ^original_key, ^original_nonce, _receipt} = :sys.get_state(fixture.host).poison

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, %{state: :acked, idempotency_key: ^original_key, ack_nonce: ^other_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [original_key])

    assert :superseded =
             Elzoo.DurableLog.confirm_ack(
               fixture.command_store,
               Elzoo.DurableLog.Codec.ack_receipt(original_key, original_nonce)
             )

    assert {:ok, {{_, 200, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 3, "messages" => messages} = view} =
             Jason.decode!(body)

    assert Enum.count(messages, &(&1["role"] == "assistant")) == 1

    poison = :sys.get_state(fixture.host).poison
    assert {:ack, ^original_key, ^original_nonce, _receipt} = poison
    assert {:blocked, :ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert {:ack, ^original_key, ^original_nonce, _receipt} = :sys.get_state(fixture.host).poison
    assert {:ok, ^head_before_conflict} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, {{_, 200, _}, _, body_after}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => ^view} = Jason.decode!(body_after)
    assert take_hash_calls() == [event["text"]]
  end

  test "native input append remains live and unresolved until its PostgreSQL writer is released", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    token = :wave4_native_input_writer

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, _} = Wave4ChannelExample.advance(fixture.host)
    trace_native_hash(fixture.native.task_supervisor)

    before_native_write =
      Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])

    Elzoo.DurableLog.PostgresHarness.hook(
      fixture.native.unit_store,
      :inject,
      [:append, {:pause, token}]
    )

    caller = Task.async(fn -> Wave4ChannelExample.advance(fixture.host) end)

    writer =
      wait_for_paused(fixture.native_controller, token, System.monotonic_time(:millisecond) + 5_000)

    assert writer.operation == :append
    assert is_integer(writer.backend)
    assert Process.alive?(writer.pid)
    assert {:unknown, :native_input} = Task.await(caller, 10_000)
    assert {:blocked, :native_input} = Wave4ChannelExample.advance(fixture.host)
    assert Process.alive?(writer.pid)

    assert before_native_write ==
             Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])

    assert take_hash_calls() == []

    writer_ref = Process.monitor(writer.pid)

    assert {:committed, _revision} =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :release, [token])

    assert_receive {:DOWN, ^writer_ref, :process, _, _}, 5_000
    assert Agent.get(fixture.native_controller, &Map.get(&1.paused, token)) == nil

    refute before_native_write ==
             Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :duplicate} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == [event["text"]]
  end

  test "volatile local work is recorded as terminal loss after fenced reopen", %{fixture: fixture} do
    token = make_ref()
    deadline = fixture.profile.deadline_ms
    fixture = host_with_native_hash_barrier(fixture, self(), token)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)
    assert_receive {:wave4_native_hash_blocked, task_pid, ^token, _actual_result}, 5_000
    assert Process.alive?(task_pid)
    assert task_pid in Task.Supervisor.children(fixture.native.task_supervisor)
    [{engine, _}] = Registry.lookup(fixture.native.registry, unit_id)

    assert {:pending, _} =
             RunEngine.result(
               engine,
               %{tenant: fixture.profile.tenant, principal: fixture.profile.actor, run_id: run_id},
               %{max_records: 2_048, max_bytes: 16_777_216}
             )

    assert take_hash_calls() == [event["text"]]
    assert {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    fixture = without_native_hash_barrier(fixture)
    {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    refute Process.alive?(task_pid)
    assert fixture.profile.deadline_ms == deadline
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :duplicate} = Wave4ChannelExample.advance(fixture.host)
    [{recovered_engine, _}] = Registry.lookup(fixture.native.registry, unit_id)
    assert {:ok, native_status} = RunEngine.status(recovered_engine)

    assert native_status.run_id == run_id
    assert native_status.attempt_id == Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)
    assert is_nil(native_status.outcome)

    assert Enum.any?(Map.values(native_status.slots), fn slot ->
             slot.kind == "local_work" and slot.outcome == "failed"
           end)

    assert {:ok, run} = RunApprovalRelease.status(fixture.owner, run_id)
    assert is_nil(run.outcome)

    assert {:ok, _revision, _} =
             RunApprovalRelease.command(fixture.owner, %{
               kind: :complete,
               run_id: run_id,
               attempt_id: run.current_attempt,
               outcome: :failed,
               reason: "local_restart",
               evidence_ref: nil,
               expected_revision: run.revision
             })

    assert {:terminal, :failed} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, run} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run.outcome == :failed
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert take_hash_calls() == []
    assert {:ok, %{revision: 2}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 200, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 2, "messages" => messages}} =
             Jason.decode!(body)

    refute Enum.any?(messages, &(&1["role"] == "assistant"))

    assert {:ok, %{state: :acked, ack_nonce: nonce, idempotency_key: key}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [item.idempotency_key])

    assert key == item.idempotency_key
    assert nonce == item.nonce
  end

  test "cancelled real native work produces no answer and is fenced before ack", %{fixture: fixture} do
    assert_terminal_work_outcome(fixture, :cancelled)
  end

  test "out-of-budget real native work produces no answer and is fenced before ack", %{
    fixture: fixture
  } do
    assert_terminal_work_outcome(fixture, :out_of_budget)
  end

  test "out-of-time real native work produces no answer and is fenced before ack", %{
    fixture: fixture
  } do
    assert_terminal_work_outcome(fixture, :out_of_time)
  end

  test "uncertain native input stays fenced until safe reopen and original-ID confirmation", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, attempt_id} = Wave4ChannelExample.advance(fixture.host)
    assert attempt_id == Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)
    assert {:engine_started, unit_id} = Wave4ChannelExample.advance(fixture.host)

    trace_native_hash(fixture.native.task_supervisor)
    trace_engine_input(fixture.host)

    before_native_input =
      Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])

    Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :inject, [:append, :reply_loss])

    assert {:unknown, :native_input} = Wave4ChannelExample.advance(fixture.host)
    assert Agent.get(fixture.native_controller, &Map.get(&1.faults, :append)) == nil

    after_native_input =
      Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])

    refute before_native_input == after_native_input
    assert {:blocked, :native_input} = Wave4ChannelExample.advance(fixture.host)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert :not_found = Elzoo.DynamicUnits.find(fixture.directory, unit_id)
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []

    assert {:ok, {{_, 200, _}, _, view_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 2, "messages" => messages}} =
             Jason.decode!(view_body)

    refute Enum.any?(messages, &(&1["role"] == "assistant"))
    assert {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert item.sequence == 1
    assert take_engine_input_ids() == [Elzoo.Wave4ChannelTestHelper.native_input_id(run_id)]
    assert take_hash_calls() == []
    assert {:ok, run_before} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_before.current_attempt == attempt_id
    assert is_nil(run_before.outcome)

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    trace_engine_input(fixture.host)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    [{recovered_engine, _}] = Registry.lookup(fixture.native.registry, unit_id)

    assert {:ok, _native_result} =
             wait_public_result(
               recovered_engine,
               %{tenant: fixture.profile.tenant, principal: fixture.profile.actor, run_id: run_id},
               System.monotonic_time(:millisecond) + 10_000
             )

    assert take_hash_calls() == [event["text"]]

    Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :inject, [:read, :unavailable])
    assert {:unknown, :native_input} = Wave4ChannelExample.advance(fixture.host)
    assert Agent.get(fixture.native_controller, &Map.get(&1.faults, :read)) == nil
    assert {:blocked, :native_input} = Wave4ChannelExample.advance(fixture.host)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert :not_found = Elzoo.DynamicUnits.find(fixture.directory, unit_id)
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []

    assert {:ok, {{_, 200, _}, _, view_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 2, "messages" => messages}} =
             Jason.decode!(view_body)

    refute Enum.any?(messages, &(&1["role"] == "assistant"))
    assert take_engine_input_ids() == [Elzoo.Wave4ChannelTestHelper.native_input_id(run_id)]
    assert take_hash_calls() == []

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    trace_native_hash(fixture.native.task_supervisor)
    trace_engine_input(fixture.host)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :duplicate} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_engine_input_ids() == [Elzoo.Wave4ChannelTestHelper.native_input_id(run_id)]
    assert take_hash_calls() == []
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, run_after} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_after.id == run_before.id
    assert run_after.operation_id == run_before.operation_id
    assert run_after.attempts == run_before.attempts
    assert run_after.current_attempt == attempt_id
    assert run_after.outcome == :completed
    assert is_integer(run_after.completion_revision)
    assert is_map(run_after.evidence_ref)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
  end

  test "unavailable authoritative result reader cannot append an answer or acknowledge", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    [{engine, _}] =
      Registry.lookup(fixture.native.registry, Elzoo.Wave4ChannelTestHelper.unit_id(run_id))

    result_scope = %{
      tenant: fixture.profile.tenant,
      principal: fixture.profile.actor,
      run_id: run_id
    }

    assert {:ok, _result} =
             wait_public_result(engine, result_scope, System.monotonic_time(:millisecond) + 10_000)

    resource_scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    Elzoo.DurableLog.PostgresHarness.hook(fixture.native.evidence_store, :inject, [
      :read,
      :unavailable
    ])

    assert {:pending, _reason} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, ^snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    assert {:ok, [^item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 200, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 2, "messages" => messages}} =
             Jason.decode!(body)

    refute Enum.any?(messages, &(&1["role"] == "assistant"))

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == [event["text"]]
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
  end

  test "Run creation and Attempt reply loss retain identities without early native allocation", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    attempt_id = Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    {:ok, [input_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    Elzoo.DurableLog.PostgresHarness.hook(fixture.run_store, :inject, [:append, :reply_loss])
    assert {:unknown, :run_create} = Wave4ChannelExample.advance(fixture.host)
    assert {:unknown, :run_create} = Wave4ChannelExample.advance(fixture.host)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert [] = Task.Supervisor.children(fixture.native.task_supervisor)
    assert take_hash_calls() == []
    assert {:ok, [^input_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []

    Elzoo.DurableLog.PostgresHarness.hook(fixture.run_store, :inject, [:append, :reply_loss])
    assert {:unknown, :attempt} = Wave4ChannelExample.advance(fixture.host)
    assert {:unknown, :attempt} = Wave4ChannelExample.advance(fixture.host)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert [] = Task.Supervisor.children(fixture.native.task_supervisor)
    assert take_hash_calls() == []

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == [event["text"]]
    assert {:ok, run} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run.current_attempt == attempt_id
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:ok, %{revision: 3}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
  end

  test "partial Engine startup is fenced and cleaned before reopening the same Attempt", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    attempt_id = Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, ^attempt_id} = Wave4ChannelExample.advance(fixture.host)
    {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :inject, [:read, :unavailable])

    assert {:unknown, :engine_start} = Wave4ChannelExample.advance(fixture.host)
    assert Agent.get(fixture.native_controller, &Map.get(&1.faults, :read)) == nil
    assert {:blocked, :engine_start} = Wave4ChannelExample.advance(fixture.host)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert [] = Task.Supervisor.children(fixture.native.task_supervisor)
    assert take_hash_calls() == []
    assert {:ok, run_before} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_before.current_attempt == attempt_id
    assert {:ok, [^item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == [event["text"]]
    assert {:ok, run_after} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_after.id == run_before.id
    assert run_after.attempts == run_before.attempts
    assert run_after.current_attempt == attempt_id
    assert run_after.operation_id == run_before.operation_id
    assert run_after.outcome == :completed
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
  end

  test "Engine Registry outage retains acquired children and recovers the same Attempt", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    attempt_id = Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, ^attempt_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, run_before} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_before.current_attempt == attempt_id
    assert run_before.attempts == [attempt_id]
    registry = fixture.native.registry
    registry_pid = Process.whereis(registry)
    assert is_pid(registry_pid)
    assert :ok = ExUnit.Callbacks.stop_supervised!(registry)
    assert is_nil(Process.whereis(registry))

    trace_native_start_returns(fixture.host)

    try do
      assert {:unknown, :engine_start} = Wave4ChannelExample.advance(fixture.host)
      returns = collect_native_start_returns(fixture.host, %{})
      writer = Map.fetch!(returns, {Elzoo.DurableLog.Writer, :start_link})
      async = Map.fetch!(returns, {Elzoo.AsyncWork, :start_link})
      Process.put(:wave4_native_start_pids, native_start_pids(returns))
      assert {:ok, writer_pid} = writer
      assert {:ok, async_pid} = async

      state_after = :sys.get_state(fixture.host)
      assert state_after.writer == writer_pid
      assert state_after.async_work == async_pid
      assert is_nil(state_after.engine)
      refute Process.alive?(writer_pid)
      refute Process.alive?(async_pid)
      assert {:blocked, _} = Wave4ChannelExample.advance(fixture.host)
      assert is_nil(Process.whereis(registry))
      assert Task.Supervisor.children(fixture.native.task_supervisor) == []
      assert take_hash_calls() == []

      assert {:ok, run_after_failure} = RunApprovalRelease.status(fixture.owner, run_id)
      assert run_after_failure.id == run_before.id
      assert run_after_failure.operation_id == run_before.operation_id
      assert run_after_failure.current_attempt == attempt_id
      assert run_after_failure.attempts == [attempt_id]

      ExUnit.Callbacks.start_supervised!({Registry, keys: :unique, name: registry}, id: registry)
      assert Registry.lookup(registry, unit_id) == []
      assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    after
      stop_native_start_returns(fixture.host)

      if is_nil(Process.whereis(registry)) do
        ExUnit.Callbacks.start_supervised!({Registry, keys: :unique, name: registry}, id: registry)
      end
    end

    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_recovered, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, run_recovered} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_recovered.id == run_before.id
    assert run_recovered.operation_id == run_before.operation_id
    assert run_recovered.current_attempt == attempt_id
    assert run_recovered.attempts == [attempt_id]
    assert run_recovered.revision == run_before.revision

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert take_hash_calls() == [event["text"]]
    assert {:ok, run_after} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_after.id == run_before.id
    assert run_after.operation_id == run_before.operation_id
    assert run_after.current_attempt == attempt_id
    assert run_after.attempts == [attempt_id]
    assert run_after.outcome == :completed
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
  end

  test "accepted-but-misconfigured nil task supervisor cleans the acquired evidence Writer", %{
    fixture: fixture
  } do
    native = Map.put(fixture.native, :task_supervisor, nil)
    host = Elzoo.Wave4ChannelTestHelper.start_host!(fixture, native: native)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture, host: host)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    attempt_id = Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(host)
    assert {:run_created, _} = Wave4ChannelExample.advance(host)
    assert {:attempt_started, ^attempt_id} = Wave4ChannelExample.advance(host)
    assert {:ok, run_before} = RunApprovalRelease.status(fixture.owner, run_id)

    trace_native_start_returns(host)

    try do
      assert {:unknown, :engine_start} = Wave4ChannelExample.advance(host)
      returns = collect_native_start_returns(host, %{})
      writer = Map.fetch!(returns, {Elzoo.DurableLog.Writer, :start_link})
      assert {:ok, writer_pid} = writer
      assert Map.fetch!(returns, {Elzoo.AsyncWork, :start_link}) == {:error, :invalid_options}
      Process.put(:wave4_native_start_pids, [writer_pid])
      refute Process.alive?(writer_pid)

      state_after = :sys.get_state(host)
      assert is_nil(state_after.writer)
      assert is_nil(state_after.async_work)
      assert is_nil(state_after.engine)
      assert Registry.lookup(fixture.native.registry, unit_id) == []
      assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
      assert Task.Supervisor.children(fixture.native.task_supervisor) == []
      assert take_hash_calls() == []

      assert {:ok, run_after} = RunApprovalRelease.status(fixture.owner, run_id)
      assert run_after.id == run_before.id
      assert run_after.current_attempt == attempt_id
      assert run_after.attempts == [attempt_id]
    after
      stop_native_start_returns(host)
    end
  end

  test "HTTP and read guards return fixed statuses without mutation", %{fixture: fixture} do
    event = Elzoo.Wave4ChannelTestHelper.event()
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)

    bad_mac = "v1=" <> String.duplicate("0", 64)

    assert {:ok, {{_, 401, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, event, signature: bad_mac)

    assert {:ok, {{_, 400, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, event,
               headers: [{"x-elzoo-signature", "bad"}]
             )

    assert {:ok, {{_, 405, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.request(listener, :get, "/elzoo/v1/messages")

    assert {:ok, {{_, 405, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.request(
               listener,
               :post,
               "/elzoo/v1/conversations/channel-conversation"
             )

    assert {:ok, {{_, 404, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.request(listener, :get, "/not-a-route")

    assert {:ok, {{_, 404, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id,
               query: "x=1"
             )

    unauthorized = fn _ ->
      {:ok,
       %{
         tenant: "other",
         actor: fixture.profile.actor,
         resources: [fixture.profile.conversation_id]
       }}
    end

    unauthorized_listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture, principal: unauthorized)
    trace_read_apis(fixture.host)

    assert {:ok, {{_, 403, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(
               unauthorized_listener,
               fixture.profile.conversation_id
             )

    await_trace_delivery(fixture.host)
    refute_receive {:trace, _, :call, {CheckedCommand, :resource, _}}, 100
    refute_receive {:trace, _, :call, {RunApprovalRelease, :status, _}}, 100

    principals = [
      {fn _ ->
         {:ok,
          %{
            tenant: "other",
            actor: fixture.profile.actor,
            resources: [fixture.profile.conversation_id]
          }}
       end, 403},
      {fn _ ->
         {:ok,
          %{tenant: fixture.profile.tenant, actor: fixture.profile.actor, resources: :malformed}}
       end, 503},
      {fn _ -> raise "sensitive principal failure" end, 503},
      {fn _ -> exit({:sensitive, :principal}) end, 503}
    ]

    for {principal, expected} <- principals do
      authorized = Elzoo.Wave4ChannelTestHelper.listener!(fixture, principal: principal)
      response = Elzoo.Wave4ChannelTestHelper.get(authorized, fixture.profile.conversation_id)
      assert {:ok, {{_, status, _}, _, body}} = response
      assert status == expected
      assert Jason.decode!(body) in [%{"status" => "forbidden"}, %{"status" => "unavailable"}]
    end

    repeated = fn _ ->
      {:ok,
       %{
         tenant: fixture.profile.tenant,
         actor: fixture.profile.actor,
         resources: [fixture.profile.conversation_id, fixture.profile.conversation_id]
       }}
    end

    repeated_listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture, principal: repeated)

    assert {:ok, {{_, 200, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(repeated_listener, fixture.profile.conversation_id)

    unavailable_host_listener =
      Elzoo.Wave4ChannelTestHelper.listener!(fixture, host: :wave4_channel_missing_host)

    assert {:ok, {{_, 503, _}, _, unavailable_body}} =
             Elzoo.Wave4ChannelTestHelper.get(
               unavailable_host_listener,
               fixture.profile.conversation_id
             )

    assert Jason.decode!(unavailable_body) == %{"status" => "unavailable"}

    assert {:ok, %{revision: 0}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
  end

  test "retained identities reach CheckedCommand conflicts while deadline survives reopen", %{
    fixture: fixture
  } do
    event = Elzoo.Wave4ChannelTestHelper.event()
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, %{run_id: run_id}} = process_event(fixture, listener, event, 3, 1, 4)
    assert take_hash_calls() == []

    duplicate =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "domain-invalid",
        "input_id" => event["input_id"],
        "expected_revision" => 3
      })

    assert {:ok, {{_, 400, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, duplicate)

    duplicate_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, duplicate["event_id"])

    assert {:conflict, {:domain, _}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, duplicate_operation}
             )

    before = public_state(fixture, [event], [run_id])
    changed_bytes = Map.put(event, "text", event["text"] <> " changed")
    changed_revision = Map.put(event, "expected_revision", 1)

    grants = fn _ ->
      {:ok,
       %{
         tenant: fixture.profile.tenant,
         actor: fixture.profile.actor,
         resources: [fixture.profile.conversation_id, "other-conversation"]
       }}
    end

    wide_listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture, webhook_principal: grants)
    changed_resource = Map.put(event, "conversation_id", "other-conversation")
    changed_events = [changed_bytes, changed_revision, changed_resource]
    trace_checked_execute(fixture.host)

    for changed <- changed_events do
      assert {:ok, {{_, 409, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(wide_listener, changed)
    end

    executed_requests = take_checked_execute_requests()
    :erlang.trace(fixture.host, false, [:call])
    :erlang.trace_pattern({CheckedCommand, :execute, 3}, false, [:local])

    assert Enum.map(executed_requests, &{&1.resource, &1.expected_revision, &1.payload}) ==
             Enum.map(changed_events, fn changed ->
               {
                 changed["conversation_id"],
                 changed["expected_revision"],
                 %{"message_id" => changed["input_id"], "text" => changed["text"]}
               }
             end)

    assert public_state(fixture, [event], [run_id]) == before

    Elzoo.Wave4ChannelTestHelper.stop_listener!(listener)
    Elzoo.Wave4ChannelTestHelper.stop_listener!(wide_listener)
    GenServer.stop(fixture.host, :normal)
    expired_clock = fn -> fixture.profile.deadline_ms + 1 end
    host = Elzoo.Wave4ChannelTestHelper.start_host!(fixture, clock: expired_clock)
    reopened = %{fixture | host: host}
    reopened_listener = Elzoo.Wave4ChannelTestHelper.listener!(reopened)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(reopened_listener, event)

    new_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "after-deadline",
        "input_id" => "after-deadline-input",
        "expected_revision" => 3
      })

    assert {:ok, {{_, 409, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reopened_listener, new_event)

    assert {:ok, %{revision: 4}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    after_deadline_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, new_event["event_id"])

    assert {:unknown, :not_observed} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, after_deadline_operation}
             )

    assert take_hash_calls() == []
  end

  test "admission callback exceptions and exits return fixed errors without writes", %{
    fixture: fixture
  } do
    for {event_id, failure} <- [{"policy-raised", :raise}, {"policy-exited", :exit}] do
      parent = self()

      policy = fn _mode, event, _now ->
        send(parent, {:policy_callback, event.event_id})

        case failure do
          :raise -> raise "sensitive policy failure for #{event.event_id}"
          :exit -> exit({:sensitive, event.event_id})
        end
      end

      host = Elzoo.Wave4ChannelTestHelper.start_host!(fixture, policy: policy)
      scoped_fixture = %{fixture | host: host}
      listener = Elzoo.Wave4ChannelTestHelper.listener!(scoped_fixture)

      event =
        Elzoo.Wave4ChannelTestHelper.event(%{
          "event_id" => event_id,
          "input_id" => "#{event_id}-input"
        })

      assert {:ok, head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

      assert {:ok, resource_before} =
               CheckedCommand.resource(
                 fixture.handles.input,
                 Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
                 fixture.profile.conversation_id
               )

      assert {:ok, {{_, 503, _}, _, body}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
      assert Jason.decode!(body) == %{"event_id" => event_id, "status" => "unavailable"}
      refute body =~ "sensitive"
      assert_receive {:policy_callback, ^event_id}
      assert Process.alive?(host)
      assert {:idle, :no_input} = Wave4ChannelExample.advance(host)
      assert {:ok, ^head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
      assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

      assert {:ok, ^resource_before} =
               CheckedCommand.resource(
                 fixture.handles.input,
                 Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
                 fixture.profile.conversation_id
               )
    end
  end

  test "input gate and policy denials retain refusal without resource, outbox, or native work", %{
    fixture: fixture
  } do
    denied_gate = %{
      input: fn _frame, _context -> :deny end,
      association: fn _frame, _context -> :allow end,
      answer: fn _frame, _context -> :allow end
    }

    {:ok, handles} =
      Elzoo.Wave4ChannelExample.CommandBindings.build(fixture.command_store, denied_gate)

    gate_host = Elzoo.Wave4ChannelTestHelper.start_host!(fixture, handles: handles)
    gate_listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture, host: gate_host)
    gate_event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "gate-denied"})

    assert {:ok, {{_, 403, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(gate_listener, gate_event)

    gate_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, gate_event["event_id"])

    assert {:denied, _} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, gate_operation}
             )

    artifact = Elzoo.Wave4ChannelTestHelper.policy()
    denied_rule = %{hd(artifact.rules) | verdict: :deny}
    unsigned = %{artifact | rules: [denied_rule]}

    denied_policy =
      Map.put(
        unsigned,
        :content_hash,
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary(Map.delete(unsigned, :content_hash), [:deterministic])
        )
      )

    policy = fn _mode, _event, _now -> denied_policy end
    policy_host = Elzoo.Wave4ChannelTestHelper.start_host!(fixture, policy: policy)
    policy_listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture, host: policy_host)
    policy_event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "policy-denied"})

    assert {:ok, {{_, 403, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(policy_listener, policy_event)

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, resource} =
             CheckedCommand.resource(
               fixture.handles.input,
               %{
                 tenant: fixture.profile.tenant,
                 actor: fixture.profile.actor,
                 resources: [fixture.profile.conversation_id]
               },
               fixture.profile.conversation_id
             )

    assert resource.revision == 0

    assert :not_found =
             DynamicUnits.find(
               fixture.directory,
               Elzoo.Wave4ChannelTestHelper.unit_id("never-created")
             )
  end

  test "GET fails closed when the already-open run owner is unavailable", %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, _} = Wave4ChannelExample.advance(fixture.host)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    before_head = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    before_outbox = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    Process.exit(fixture.owner, :kill)

    assert {:ok, {{_, 503, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert Jason.decode!(body) == %{"status" => "unavailable"}

    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == before_head
    assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == before_outbox

    assert :not_found =
             DynamicUnits.find(fixture.directory, Elzoo.Wave4ChannelTestHelper.unit_id(run_id))

    assert Registry.lookup(fixture.native.registry, Elzoo.Wave4ChannelTestHelper.unit_id(run_id)) ==
             []
  end

  test "GET reports not_recorded only for the known pre-creation phase", %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, _} = Wave4ChannelExample.advance(fixture.host)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)

    assert {:ok, resource_before} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               fixture.profile.conversation_id
             )

    assert {:ok, head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, outbox_before} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 200, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{
             "status" => "ok",
             "view" => %{"runs" => [%{"outcome" => "not_recorded", "run_id" => ^run_id}]}
           } = Jason.decode!(body)

    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)

    assert {:ok, ^resource_before} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               fixture.profile.conversation_id
             )

    assert {:ok, ^head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, ^outbox_before} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert :not_found =
             DynamicUnits.find(fixture.directory, Elzoo.Wave4ChannelTestHelper.unit_id(run_id))

    assert Registry.lookup(fixture.native.registry, Elzoo.Wave4ChannelTestHelper.unit_id(run_id)) ==
             []
  end

  test "GET fails closed when a retained run has a mismatched native operation", %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, _} = Wave4ChannelExample.advance(fixture.host)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, _, _} =
             RunApprovalRelease.command(fixture.owner, %{
               kind: :create,
               run_id: run_id,
               operation_id: "wrong-native-operation",
               provider_refs: %{},
               expected_revision: fixture.held.live.revision
             })

    before_head = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    before_outbox = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 503, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert Jason.decode!(body) == %{"status" => "unavailable"}
    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == before_head
    assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == before_outbox
  end

  test "future capacity accounts for the association and answer before input admission", %{
    fixture: fixture
  } do
    for index <- 1..15 do
      assert {:completed, %{revision: ^index}} =
               seed_message!(fixture, index, String.duplicate("x", 4_096))
    end

    resource_scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    candidate =
      Enum.find_value(4_096..1//-16, fn size ->
        event =
          Elzoo.Wave4ChannelTestHelper.event(%{
            "event_id" => "capacity-event",
            "input_id" => "capacity-input",
            "expected_revision" => snapshot.revision,
            "text" => String.duplicate("y", size)
          })

        case hypothetical_capacity(snapshot, fixture.profile, event) do
          {:future_refusal, stage} -> {event, stage}
          _ -> nil
        end
      end)

    assert {event, stage} = candidate
    assert stage in [:association, :answer]
    assert {:ok, head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert {:ok, ^snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    assert {:ok, ^head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])

    assert {:unknown, :not_observed} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, operation}
             )

    assert {:error, :not_found} =
             RunApprovalRelease.status(
               fixture.owner,
               Elzoo.Wave4ChannelTestHelper.run_id(
                 fixture.profile,
                 event["event_id"],
                 event["input_id"]
               )
             )
  end

  test "full CheckedCommand resource snapshots reserve capacity before input admission", %{
    fixture: fixture
  } do
    for index <- 1..15 do
      assert {:completed, %{revision: ^index}} =
               seed_message!(fixture, index, String.duplicate("x", 4_096))
    end

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               scope,
               fixture.profile.conversation_id
             )

    {event, [input_size, association_size, answer_size]} =
      Enum.find_value(4_096..1//-1, fn size ->
        event =
          Elzoo.Wave4ChannelTestHelper.event(%{
            "event_id" => "capacity-wrapper-event",
            "input_id" => "capacity-wrapper-input",
            "expected_revision" => snapshot.revision,
            "text" => String.duplicate("y", size)
          })

        with :fits <- hypothetical_capacity(snapshot, fixture.profile, event),
             {:ok, [input_size, association_size, answer_size]} <-
               hypothetical_checked_resource_sizes(snapshot, fixture.profile, event),
             true <- input_size <= 65_536,
             true <- association_size <= 65_536,
             true <- answer_size > 65_536 do
          {event, [input_size, association_size, answer_size]}
        else
          _ -> nil
        end
      end)

    assert input_size <= 65_536
    assert association_size <= 65_536
    assert answer_size > 65_536

    assert {:ok, head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    assert {:ok, ^snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               scope,
               fixture.profile.conversation_id
             )

    assert {:ok, ^head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:unknown, :not_observed} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor,
                Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])}
             )

    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert take_hash_calls() == []
  end

  test "signed loopback processes two distinct inputs and replays the first", %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    first = Elzoo.Wave4ChannelTestHelper.event()

    stale =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "stale-event",
        "input_id" => "stale-input",
        "expected_revision" => 1
      })

    assert {:ok, {{_, 409, _}, _headers, _body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, stale)

    stale_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, stale["event_id"])

    assert {:conflict, :stale_revision} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, stale_operation}
             )

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:ok, %{revision: 1}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, {{_, 202, _}, _headers, _body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, first)

    first_outbox = assert_input_outbox(fixture, first, 2)

    second =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "event-2",
        "input_id" => "input-2",
        "expected_revision" => 3,
        "text" => "second native input"
      })

    assert {:ok, {{_, 503, _}, _headers, _body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, second)

    assert ^first_outbox = assert_input_outbox(fixture, first, 2)

    Elzoo.Wave4ChannelTestHelper.stop_listener!(listener)
    GenServer.stop(fixture.host, :normal)
    reopened = Elzoo.Wave4ChannelTestHelper.start_host!(fixture)
    fixture = %{fixture | host: reopened}
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)

    assert {:ok, {{_, 503, _}, _headers, _body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, second)

    assert {:ok, {{_, 202, _}, _headers, body}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, first)

    assert %{"status" => "committed", "revision" => 1} = Jason.decode!(body)
    assert ^first_outbox = assert_input_outbox(fixture, first, 2)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, %{run_id: first_run, unit_id: first_unit, status: first_status}} =
             process_event(fixture, listener, first, 3, 2, 4)

    assert {:ok, %{run_id: second_run, unit_id: second_unit, status: second_status}} =
             process_event(fixture, listener, second, 6, 5, 7)

    assert {:ok, %{revision: 7}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert first_run != second_run
    assert first_unit != second_unit
    assert first_status.current_attempt != second_status.current_attempt
    assert first_status.attempts == [first_status.current_attempt]
    assert second_status.attempts == [second_status.current_attempt]
    assert {:ok, current_first_status} = RunApprovalRelease.status(fixture.owner, first_run)
    assert {:ok, current_second_status} = RunApprovalRelease.status(fixture.owner, second_run)
    assert stable_run_status(current_first_status) == stable_run_status(first_status)
    assert stable_run_status(current_second_status) == stable_run_status(second_status)
    before_reads = public_state(fixture, [first, second], [first_run, second_run])

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
    assert public_state(fixture, [first, second], [first_run, second_run]) == before_reads
    assert take_hash_calls() == []

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

  test "release refuses an ASK at and after the immutable deadline", %{fixture: fixture} do
    deadline = fixture.profile.deadline_ms

    clock_control =
      start_supervised!({Agent, fn -> deadline - 1_000 end}, id: make_ref())

    authority_control = start_supervised!({Agent, fn -> %{} end}, id: make_ref())
    clock = fn -> Agent.get(clock_control, & &1) end
    policy = fn _mode, _event, _now -> Elzoo.Wave4ChannelTestHelper.policy(:ask) end

    authority = fn mode, _event, _request, _facts ->
      if mode == :release do
        Agent.get(authority_control, fn authority ->
          Map.merge(authority, %{now: clock.(), revoked: []})
        end)
      else
        %{}
      end
    end

    fixture =
      host_with_gates(fixture, fixture.gates,
        clock: clock,
        policy: policy,
        authority: authority
      )

    assert clock.() < deadline

    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    normalized = normalized_event(event)
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])
    identity = {fixture.profile.tenant, fixture.profile.actor, operation}
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, body}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert %{"status" => "pending_approval"} = Jason.decode!(body)

    assert {:approval_pending, %{key: key, requirement: requirement}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    request = %{
      operation_id: operation,
      resource: normalized.conversation_id,
      expected_revision: normalized.expected_revision,
      payload: %{"message_id" => normalized.input_id, "text" => normalized.text}
    }

    facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
    prepared_facts = %{tenant: fixture.profile.tenant, actor: fixture.profile.actor, data: facts}

    assert {:ok, snapshot} =
             CheckedCommand.resource(fixture.handles.input, scope, normalized.conversation_id)

    assert {:ok, writes, _response} = Conversation.prepare(snapshot, request, prepared_facts)

    Agent.update(authority_control, fn _ ->
      %{approver: %{identity: "human-reviewer", authority: writes}}
    end)

    evidence = %{
      verifier: "wave4-command-approver",
      evidence_id: "deadline-release",
      reviewer: "human-reviewer",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: deadline - 100,
      expiry: deadline + 60_000
    }

    envelope = %{purpose: :command, tenant: fixture.profile.tenant, evidence: evidence}
    before_command = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])
    before_unit = Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])

    assert {:ok, before_resource} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    assert before_resource.revision == 0

    assert {:ok, before_head} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    for current_time <- [deadline, deadline + 1] do
      Agent.update(clock_control, fn _ -> current_time end)

      assert {:rejected, :conflict} =
               Wave4ChannelExample.release(fixture.host, normalized, scope, envelope)

      assert {:approval_pending, %{key: ^key, requirement: ^requirement}} =
               CheckedCommand.result(
                 fixture.handles.input,
                 %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
                 identity
               )

      assert %{key: ^key, requirement: ^requirement} = :sys.get_state(fixture.host).approval

      assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
               before_command

      assert Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, []) ==
               before_unit

      assert {:ok, ^before_resource} =
               CheckedCommand.resource(
                 fixture.handles.input,
                 scope,
                 fixture.profile.conversation_id
               )

      assert {:ok, ^before_head} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
      assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
      assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
      assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
      assert Registry.lookup(fixture.native.registry, unit_id) == []
      assert Task.Supervisor.children(fixture.native.task_supervisor) == []
      assert take_hash_calls() == []
    end
  end

  test "foreign completed input notification is rejected before checked-command reads", %{
    fixture: fixture
  } do
    event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "foreign-completed",
        "input_id" => "foreign-completed-input",
        "conversation_id" => "other-conversation"
      })

    assert {{:completed, %{revision: 1}}, _writes} = seed_input_command!(fixture, event, :allow)
    {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert Jason.decode!(item.payload)["resource"] == event["conversation_id"]
    profile_scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    broad_scope =
      Map.put(profile_scope, :resources, [fixture.profile.conversation_id, event["conversation_id"]])

    assert {:ok, profile_before} =
             CheckedCommand.resource(
               fixture.handles.input,
               broad_scope,
               fixture.profile.conversation_id
             )

    assert {:ok, foreign_before} =
             CheckedCommand.resource(fixture.handles.input, broad_scope, event["conversation_id"])

    assert {:ok, before_head} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    before_command = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])
    before_unit = Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    trace_native_hash(fixture.native.task_supervisor)
    trace_checked_reads(fixture.host)

    assert {:unknown, :input_observation} = Wave4ChannelExample.advance(fixture.host)
    assert take_checked_read_calls() == []

    assert {:ok, ^profile_before} =
             CheckedCommand.resource(
               fixture.handles.input,
               broad_scope,
               fixture.profile.conversation_id
             )

    assert {:ok, ^foreign_before} =
             CheckedCommand.resource(fixture.handles.input, broad_scope, event["conversation_id"])

    assert {:ok, ^before_head} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             before_command

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, []) ==
             before_unit

    assert {:ok, [^item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert %{poison: {:input_observation, :unknown}} = :sys.get_state(fixture.host)
    assert take_hash_calls() == []
  end

  test "a retained foreign ASK cannot be released through a broad scope", %{fixture: fixture} do
    event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "foreign-ask",
        "input_id" => "foreign-ask-input",
        "conversation_id" => "other-conversation"
      })

    assert {{:approval_pending, %{key: key, requirement: requirement}}, writes} =
             seed_input_command!(fixture, event, :ask)

    broad_scope =
      Map.put(Elzoo.Wave4ChannelTestHelper.scope(fixture.profile), :resources, [
        fixture.profile.conversation_id,
        event["conversation_id"]
      ])

    assert {:ok, foreign_before} =
             CheckedCommand.resource(fixture.handles.input, broad_scope, event["conversation_id"])

    assert {:ok, profile_before} =
             CheckedCommand.resource(
               fixture.handles.input,
               broad_scope,
               fixture.profile.conversation_id
             )

    assert {:ok, before_head} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    before_command = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, [])
    parent = self()

    policy = fn _mode, _event, _now -> Elzoo.Wave4ChannelTestHelper.policy(:ask) end

    authority = fn mode, _event, _request, _facts ->
      if mode == :release do
        send(parent, :foreign_release_authority_called)

        %{
          approver: %{identity: "human-reviewer", authority: writes},
          now: fixture.clock.(),
          revoked: []
        }
      else
        %{}
      end
    end

    fixture = host_with_gates(fixture, fixture.gates, policy: policy, authority: authority)
    normalized = normalized_event(event)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:pending, :approval} = Wave4ChannelExample.admit(fixture.host, normalized, broad_scope)

    assert %{event: ^normalized, key: ^key, requirement: ^requirement} =
             :sys.get_state(fixture.host).approval

    assert {:ok, ^before_head} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             before_command

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    now = fixture.clock.()

    evidence = %{
      verifier: "wave4-command-approver",
      evidence_id: "foreign-ask-release",
      reviewer: "human-reviewer",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: now - 1_000,
      expiry: now + 60_000
    }

    envelope = %{purpose: :command, tenant: fixture.profile.tenant, evidence: evidence}

    assert {:rejected, :forbidden} =
             Wave4ChannelExample.release(fixture.host, normalized, broad_scope, envelope)

    refute_receive :foreign_release_authority_called

    assert {:approval_pending, %{key: ^key, requirement: ^requirement}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor,
                Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])}
             )

    assert {:ok, ^foreign_before} =
             CheckedCommand.resource(fixture.handles.input, broad_scope, event["conversation_id"])

    assert {:ok, ^profile_before} =
             CheckedCommand.resource(
               fixture.handles.input,
               broad_scope,
               fixture.profile.conversation_id
             )

    assert {:ok, ^before_head} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :snapshot, []) ==
             before_command

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert take_hash_calls() == []
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

      native_calls = take_hash_calls()
      assert native_calls == [event["text"]]

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
      assert take_hash_calls() == []

      {:ok,
       %{
         run_id: run_id,
         unit_id: unit_id,
         status: status,
         engine_status: engine_status,
         work_count: work_count,
         native_calls: native_calls,
         budget_count: budget_count
       }}
    end
  end

  defp normalized_event(event) do
    %{
      version: event["version"],
      event_id: event["event_id"],
      conversation_id: event["conversation_id"],
      input_id: event["input_id"],
      expected_revision: event["expected_revision"],
      text: event["text"]
    }
  end

  defp drain_read_at_fault!(fixture, profile) do
    case Elzoo.DurableLog.Store.read(
           fixture.command_store,
           :read_at,
           [checked_stream(profile.tenant), 1]
         ) do
      {:error, :unavailable} -> :ok
      {:ok, _row, _head} -> :ok
      other -> flunk("unexpected read_at result: #{inspect(other)}")
    end
  end

  defp stale_release_race!(fixture, mode) when mode in [:reply_loss, :direct] do
    gate_control = start_supervised!({Agent, fn -> %{fault: nil, store: nil} end}, id: make_ref())
    policy_control = start_supervised!({Agent, fn -> :ask end}, id: make_ref())
    authority_control = start_supervised!({Agent, fn -> %{} end}, id: make_ref())
    authority_calls = start_supervised!({Agent, fn -> 0 end}, id: make_ref())
    parent = self()
    barrier = make_ref()
    suffix = Atom.to_string(mode)

    gates = %{
      input: controlled_gate(gate_control),
      association: fn _, _ -> :allow end,
      answer: fn _, _ -> :allow end
    }

    policy = fn _mode, _event, _now ->
      Elzoo.Wave4ChannelTestHelper.policy(Agent.get(policy_control, & &1))
    end

    authority = fn mode, _event, _request, _facts ->
      if mode == :release do
        call = Agent.get_and_update(authority_calls, fn count -> {count + 1, count + 1} end)

        if call == 2 do
          send(parent, {:release_authority_barrier, self(), barrier})

          receive do
            {:continue_release_authority, ^barrier} -> :ok
          after
            10_000 -> exit(:authority_barrier_timeout)
          end
        end

        Agent.get(authority_control, & &1)
      else
        %{}
      end
    end

    fixture = host_with_gates(fixture, gates, policy: policy, authority: authority)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)

    event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "stale-release-#{suffix}",
        "input_id" => "stale-release-input-#{suffix}"
      })

    normalized = normalized_event(event)
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])
    identity = {fixture.profile.tenant, fixture.profile.actor, operation}
    scope = %{tenant: fixture.profile.tenant, actor: fixture.profile.actor}

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert {:approval_pending, %{key: key}} =
             CheckedCommand.result(fixture.handles.input, scope, identity)

    now = System.system_time(:millisecond)

    evidence = %{
      verifier: "wave4-command-approver",
      evidence_id: "stale-release-#{suffix}",
      reviewer: "human-reviewer",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: now - 1_000,
      expiry: now + 60_000
    }

    envelope = %{purpose: :command, tenant: fixture.profile.tenant, evidence: evidence}

    request = %{
      operation_id: operation,
      resource: normalized.conversation_id,
      expected_revision: normalized.expected_revision,
      payload: %{"message_id" => normalized.input_id, "text" => normalized.text}
    }

    facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
    prepared_facts = %{tenant: fixture.profile.tenant, actor: fixture.profile.actor, data: facts}

    assert {:ok, snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               normalized.conversation_id
             )

    assert {:ok, writes, _} = Conversation.prepare(snapshot, request, prepared_facts)

    Agent.update(authority_control, fn _ ->
      %{approver: %{identity: "human-reviewer", authority: writes}, now: now, revoked: []}
    end)

    Agent.update(policy_control, fn _ -> :allow end)

    caller =
      Task.async(fn ->
        Wave4ChannelExample.release(
          fixture.host,
          normalized,
          Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
          envelope
        )
      end)

    assert_receive {:release_authority_barrier, release_host, ^barrier}, 5_000
    assert {:completed, %{revision: 1}} = seed_message!(fixture, 1, "intervening public write")

    if mode == :reply_loss do
      set_gate_fault(gate_control, fixture.command_store, :reply_loss)
    end

    send(release_host, {:continue_release_authority, barrier})
    release_result = Task.await(caller, 10_000)

    if mode == :reply_loss do
      assert Map.get(Agent.get(fixture.controller, & &1.faults), :append) == nil
    end

    retained_result = CheckedCommand.result(fixture.handles.input, scope, identity)
    assert {:conflict, :stale_revision} = retained_result

    %{
      fixture: fixture,
      listener: listener,
      event: event,
      identity: identity,
      scope: scope,
      release_result: release_result,
      retained_result: retained_result
    }
  end

  defp seed_input_command!(fixture, event, verdict) do
    profile = fixture.profile
    resource = event["conversation_id"]

    scope =
      Map.put(
        Elzoo.Wave4ChannelTestHelper.scope(profile),
        :resources,
        [
          profile.conversation_id,
          resource
        ]
        |> Enum.uniq()
      )

    assert {:ok, snapshot} = CheckedCommand.resource(fixture.handles.input, scope, resource)

    request = %{
      operation_id: Elzoo.Wave4ChannelTestHelper.input_operation(profile, event["event_id"]),
      resource: resource,
      expected_revision: event["expected_revision"],
      payload: %{"message_id" => event["input_id"], "text" => event["text"]}
    }

    facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
    prepared_facts = %{tenant: profile.tenant, actor: profile.actor, data: facts}
    assert {:ok, writes, _response} = Conversation.prepare(snapshot, request, prepared_facts)

    context = %{
      tenant: profile.tenant,
      actor: profile.actor,
      policy: Elzoo.Wave4ChannelTestHelper.policy(verdict),
      own: writes,
      parent: :none,
      facts: facts
    }

    {CheckedCommand.execute(fixture.handles.input, context, request), writes}
  end

  defp seed_message!(fixture, index, text) do
    profile = fixture.profile
    scope = Elzoo.Wave4ChannelTestHelper.scope(profile)

    assert {:ok, snapshot} =
             CheckedCommand.resource(fixture.handles.input, scope, profile.conversation_id)

    event_id = "seed-event-#{index}"
    message_id = "seed-message-#{index}"

    request = %{
      operation_id: Elzoo.Wave4ChannelTestHelper.input_operation(profile, event_id),
      resource: profile.conversation_id,
      expected_revision: snapshot.revision,
      payload: %{"message_id" => message_id, "text" => text}
    }

    facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
    prepared_facts = %{tenant: profile.tenant, actor: profile.actor, data: facts}
    assert {:ok, writes, _} = Conversation.prepare(snapshot, request, prepared_facts)

    context = %{
      tenant: profile.tenant,
      actor: profile.actor,
      policy: Elzoo.Wave4ChannelTestHelper.policy(),
      own: writes,
      parent: :none,
      facts: facts
    }

    result = CheckedCommand.execute(fixture.handles.input, context, request)
    assert {:completed, _} = result
    assert {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:committed, _} =
             Outbox.ack(fixture.command_store, item.idempotency_key, item.nonce)

    result
  end

  defp hypothetical_capacity(snapshot, profile, event) do
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(profile, event["event_id"])
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(profile, event["event_id"], event["input_id"])
    base = %{tenant: profile.tenant, actor: profile.actor}

    input_request = %{
      operation_id: operation,
      resource: event["conversation_id"],
      expected_revision: snapshot.revision,
      payload: %{"message_id" => event["input_id"], "text" => event["text"]}
    }

    input_facts =
      Map.put(
        base,
        :data,
        {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
      )

    with {:ok, input_writes, _} <- Conversation.prepare(snapshot, input_request, input_facts),
         input_snapshot <- apply_test_writes(snapshot, input_writes),
         association_request <- %{
           operation_id:
             Elzoo.Wave4ChannelTestHelper.association_operation(
               profile,
               event["event_id"],
               event["input_id"]
             ),
           resource: event["conversation_id"],
           expected_revision: snapshot.revision + 1,
           payload: %{"message_id" => event["input_id"]}
         },
         association_facts <-
           Map.put(
             base,
             :data,
             {:record, [{"mode", {:text, "associate_run"}}, {"run_id", {:text, run_id}}]}
           ) do
      case Conversation.prepare(input_snapshot, association_request, association_facts) do
        {:refused, _} ->
          {:future_refusal, :association}

        {:ok, association_writes, _} ->
          associated_snapshot = apply_test_writes(input_snapshot, association_writes)

          answer_request = %{
            operation_id:
              Elzoo.Wave4ChannelTestHelper.answer_operation(
                profile,
                event["event_id"],
                event["input_id"]
              ),
            resource: event["conversation_id"],
            expected_revision: snapshot.revision + 2,
            payload: %{
              "message_id" => Elzoo.Wave4ChannelTestHelper.answer_id(event["input_id"]),
              "text" => String.duplicate("x", 71)
            }
          }

          answer_facts =
            Map.put(
              base,
              :data,
              {:record,
               [
                 {"completed", true},
                 {"input_message_id", {:text, event["input_id"]}},
                 {"mode", {:text, "append_answer"}},
                 {"run_id", {:text, run_id}}
               ]}
            )

          case Conversation.prepare(associated_snapshot, answer_request, answer_facts) do
            {:refused, _} -> {:future_refusal, :answer}
            {:ok, _, _} -> :fits
          end
      end
    else
      _ -> :input_does_not_fit
    end
  end

  defp hypothetical_checked_resource_sizes(snapshot, profile, event) do
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(profile, event["event_id"])
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(profile, event["event_id"], event["input_id"])
    base = %{tenant: profile.tenant, actor: profile.actor}

    input_request = %{
      operation_id: operation,
      resource: event["conversation_id"],
      expected_revision: snapshot.revision,
      payload: %{"message_id" => event["input_id"], "text" => event["text"]}
    }

    input_facts =
      Map.put(
        base,
        :data,
        {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
      )

    with {:ok, input_writes, _} <-
           Conversation.prepare(snapshot, input_request, input_facts),
         input_snapshot <- apply_test_writes(snapshot, input_writes),
         association_request <- %{
           operation_id:
             Elzoo.Wave4ChannelTestHelper.association_operation(
               profile,
               event["event_id"],
               event["input_id"]
             ),
           resource: event["conversation_id"],
           expected_revision: input_snapshot.revision,
           payload: %{"message_id" => event["input_id"]}
         },
         association_facts <-
           Map.put(
             base,
             :data,
             {:record, [{"mode", {:text, "associate_run"}}, {"run_id", {:text, run_id}}]}
           ),
         {:ok, association_writes, _} <-
           Conversation.prepare(input_snapshot, association_request, association_facts),
         association_snapshot <- apply_test_writes(input_snapshot, association_writes),
         answer_request <- %{
           operation_id:
             Elzoo.Wave4ChannelTestHelper.answer_operation(
               profile,
               event["event_id"],
               event["input_id"]
             ),
           resource: event["conversation_id"],
           expected_revision: association_snapshot.revision,
           payload: %{
             "message_id" => Elzoo.Wave4ChannelTestHelper.answer_id(event["input_id"]),
             "text" => String.duplicate("x", 71)
           }
         },
         answer_facts <-
           Map.put(
             base,
             :data,
             {:record,
              [
                {"completed", true},
                {"input_message_id", {:text, event["input_id"]}},
                {"mode", {:text, "append_answer"}},
                {"run_id", {:text, run_id}}
              ]}
           ),
         {:ok, answer_writes, _} <-
           Conversation.prepare(association_snapshot, answer_request, answer_facts),
         answer_snapshot <- apply_test_writes(association_snapshot, answer_writes) do
      {:ok,
       Enum.map([input_snapshot, association_snapshot, answer_snapshot], fn projected ->
         byte_size(
           :erlang.term_to_binary(
             %{revision: projected.revision, fields: projected.fields},
             [:deterministic]
           )
         )
       end)}
    else
      _ -> :refused
    end
  end

  defp apply_test_writes(snapshot, writes) do
    fields = Enum.reduce(writes, snapshot.fields, &Map.put(&2, &1.field, &1.value))
    %{snapshot | revision: snapshot.revision + 1, fields: fields}
  end

  defp trace_native_hash(task_supervisor) do
    module = Elzoo.Wave4ChannelExample.NativeWork
    Process.put(:wave4_channel_hash_trace_target, task_supervisor)
    :erlang.trace_pattern({module, :hash, 1}, true, [:local])
    :erlang.trace(task_supervisor, true, [:call, :set_on_spawn])

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(task_supervisor), do: :erlang.trace(task_supervisor, false, [:all])
      :erlang.trace_pattern({module, :hash, 1}, false, [:local])
      take_hash_calls()
    end)
  end

  defp trace_engine_input(host) do
    Process.put(:wave4_channel_engine_input_trace_target, host)
    :erlang.trace_pattern({RunEngine, :input, 4}, true, [:local])
    :erlang.trace(host, true, [:call])

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(host), do: :erlang.trace(host, false, [:all])
      :erlang.trace_pattern({RunEngine, :input, 4}, false, [:local])
      take_engine_input_ids()
    end)
  end

  defp take_engine_input_ids(acc \\ []) do
    await_trace_delivery(Process.get(:wave4_channel_engine_input_trace_target))

    receive do
      {:trace, _pid, :call, {RunEngine, :input, [_engine, input_id, _input, _context]}} ->
        take_engine_input_ids([input_id | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp trace_read_apis(host) do
    Process.put(:wave4_channel_read_trace_target, host)
    :erlang.trace_pattern({CheckedCommand, :resource, 3}, true, [:local])
    :erlang.trace_pattern({RunApprovalRelease, :status, 2}, true, [:local])
    :erlang.trace(host, true, [:call])

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(host), do: :erlang.trace(host, false, [:all])
      :erlang.trace_pattern({CheckedCommand, :resource, 3}, false, [:local])
      :erlang.trace_pattern({RunApprovalRelease, :status, 2}, false, [:local])
      flush_trace_calls()
    end)
  end

  defp trace_checked_reads(host) do
    Process.put(:wave4_channel_read_trace_target, host)
    :erlang.trace_pattern({CheckedCommand, :result, 3}, true, [:local])
    :erlang.trace_pattern({CheckedCommand, :resource, 3}, true, [:local])
    :erlang.trace(host, true, [:call])

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(host), do: :erlang.trace(host, false, [:call])
      :erlang.trace_pattern({CheckedCommand, :result, 3}, false, [:local])
      :erlang.trace_pattern({CheckedCommand, :resource, 3}, false, [:local])
      flush_trace_calls()
    end)
  end

  defp take_checked_read_calls(acc \\ []) do
    await_trace_delivery(Process.get(:wave4_channel_read_trace_target))

    receive do
      {:trace, _pid, :call, {CheckedCommand, function, _args}}
      when function in [:result, :resource] ->
        take_checked_read_calls([function | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp trace_checked_execute(host) do
    Process.put(:wave4_channel_execute_trace_target, host)
    :erlang.trace_pattern({CheckedCommand, :execute, 3}, true, [:local])
    :erlang.trace(host, true, [:call])

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(host), do: :erlang.trace(host, false, [:call])
      :erlang.trace_pattern({CheckedCommand, :execute, 3}, false, [:local])
      take_checked_execute_requests()
    end)
  end

  defp take_checked_execute_requests(acc \\ []) do
    await_trace_delivery(Process.get(:wave4_channel_execute_trace_target))

    receive do
      {:trace, _pid, :call, {CheckedCommand, :execute, [_handle, _context, request]}} ->
        take_checked_execute_requests([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp flush_trace_calls do
    await_trace_delivery(Process.get(:wave4_channel_read_trace_target))

    receive do
      {:trace, _pid, :call, _} -> flush_trace_calls()
    after
      0 -> :ok
    end
  end

  defp take_hash_calls do
    await_trace_delivery(Process.get(:wave4_channel_hash_trace_target))
    take_hash_calls([])
  end

  defp take_hash_calls(acc) do
    receive do
      {:trace, _pid, :call, {Elzoo.Wave4ChannelExample.NativeWork, :hash, [text]}} ->
        take_hash_calls([text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp await_trace_delivery(target) when is_pid(target) do
    if Process.alive?(target) do
      delivered = :erlang.trace_delivered(target)
      assert_receive {:trace_delivered, ^target, ^delivered}, 5_000
    end
  end

  defp await_trace_delivery(_), do: :ok

  defp public_state(fixture, events, run_ids) do
    profile = fixture.profile
    scope = %{tenant: profile.tenant, actor: profile.actor}
    resource_scope = Map.put(scope, :resources, [profile.conversation_id])

    {:ok, resource} =
      CheckedCommand.resource(fixture.handles.input, resource_scope, profile.conversation_id)

    {:ok, head} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    {:ok, outbox} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    receipts =
      Enum.map(events, fn event ->
        input_id = event["input_id"]
        input_op = Elzoo.Wave4ChannelTestHelper.input_operation(profile, event["event_id"])

        association_op =
          Elzoo.Wave4ChannelTestHelper.association_operation(profile, event["event_id"], input_id)

        answer_op =
          Elzoo.Wave4ChannelTestHelper.answer_operation(profile, event["event_id"], input_id)

        {
          CheckedCommand.result(
            fixture.handles.input,
            scope,
            {profile.tenant, profile.actor, input_op}
          ),
          CheckedCommand.result(
            fixture.handles.association,
            scope,
            {profile.tenant, profile.actor, association_op}
          ),
          CheckedCommand.result(
            fixture.handles.answer,
            scope,
            {profile.tenant, profile.actor, answer_op}
          )
        }
      end)

    units =
      Enum.map(
        run_ids,
        &DynamicUnits.find(fixture.directory, Elzoo.Wave4ChannelTestHelper.unit_id(&1))
      )

    unit_states =
      Enum.map(units, fn
        {:ok, unit} -> DurableUnit.snapshot(unit)
        other -> other
      end)

    engines =
      Enum.map(
        run_ids,
        &Registry.lookup(fixture.native.registry, Elzoo.Wave4ChannelTestHelper.unit_id(&1))
      )

    engine_states =
      Enum.map(engines, fn
        [{engine, _}] -> RunEngine.status(engine)
        other -> other
      end)

    runs = Enum.map(run_ids, &RunApprovalRelease.status(fixture.owner, &1))

    %{
      resource: resource,
      head: head,
      outbox: outbox,
      receipts: receipts,
      runs: runs,
      units: units,
      unit_states: unit_states,
      engines: engines,
      engine_states: engine_states
    }
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

  defp wait_public_result(engine, scope, deadline) do
    case RunEngine.result(engine, scope, %{max_records: 2_048, max_bytes: 16_777_216}) do
      {:ok, _} = result ->
        result

      {:pending, _} ->
        retry_public_result(engine, scope, deadline)

      {:error, :unavailable} ->
        retry_public_result(engine, scope, deadline)

      other ->
        other
    end
  end

  defp retry_public_result(engine, scope, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(1)
      wait_public_result(engine, scope, deadline)
    else
      {:error, :timeout}
    end
  end

  defp wait_for_paused(controller, token, deadline) do
    case Agent.get(controller, &Map.get(&1.paused, token)) do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1)
          wait_for_paused(controller, token, deadline)
        else
          flunk("Postgres writer did not reach the pause barrier")
        end

      paused ->
        paused
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

  defp controlled_gate(control) do
    fn _frame, _context ->
      {fault, store} =
        Agent.get_and_update(control, fn state ->
          {{state.fault, state.store}, %{state | fault: nil}}
        end)

      case fault do
        :reply_loss ->
          Elzoo.DurableLog.PostgresHarness.hook(store, :inject, [:read_at, :unavailable])
          Elzoo.DurableLog.PostgresHarness.hook(store, :inject, [:append, :reply_loss])

        {:pause, token} ->
          Elzoo.DurableLog.PostgresHarness.hook(store, :inject, [:append, {:pause, token}])

        nil ->
          :ok
      end

      :allow
    end
  end

  defp host_with_gates(fixture, gates, overrides \\ []) do
    {:ok, handles} = Wave4ChannelExample.CommandBindings.build(fixture.command_store, gates)
    if Process.alive?(fixture.host), do: GenServer.stop(fixture.host, :normal)
    host_options = Keyword.merge(fixture.host_options, Keyword.merge([handles: handles], overrides))

    host =
      Elzoo.Wave4ChannelTestHelper.start_host!(
        fixture,
        Keyword.merge([handles: handles], overrides)
      )

    %{fixture | host: host, handles: handles, host_options: host_options}
  end

  defp host_with_native_hash_barrier(fixture, parent, token) do
    if Process.alive?(fixture.host), do: GenServer.stop(fixture.host, :normal, 5_000)

    engine = fixture.native.engine
    work = engine.bindings["local_work"]

    instrumented_work =
      Map.put(work, :work, fn action ->
        {__MODULE__, :blocked_native_hash, [action["payload"]["text"], parent, token]}
      end)

    native_engine = %{engine | bindings: Map.put(engine.bindings, "local_work", instrumented_work)}
    native = %{fixture.native | engine: native_engine}
    host_options = Keyword.put(fixture.host_options, :native, native)
    fixture = %{fixture | native: native, host_options: host_options}
    host = Elzoo.Wave4ChannelTestHelper.start_host!(fixture)
    %{fixture | host: host}
  end

  defp without_native_hash_barrier(fixture) do
    native = %{
      fixture.native
      | engine: Elzoo.Wave4ChannelExample.NativeBindings.build(fixture.profile)
    }

    %{fixture | native: native, host_options: Keyword.put(fixture.host_options, :native, native)}
  end

  def blocked_native_hash(text, parent, token) do
    result = Elzoo.Wave4ChannelExample.NativeWork.hash(text)
    send(parent, {:wave4_native_hash_blocked, self(), token, result})

    receive do
      {:release_wave4_native_hash, ^token} -> result
    end
  end

  defp assert_terminal_work_outcome(fixture, outcome) do
    token = make_ref()
    fixture = host_with_native_hash_barrier(fixture, self(), token)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    attempt_id = Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    item = assert_input_outbox(fixture, event, 1)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, ^attempt_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)
    assert_receive {:wave4_native_hash_blocked, task_pid, ^token, _actual_result}, 5_000
    assert Process.alive?(task_pid)
    assert task_pid in Task.Supervisor.children(fixture.native.task_supervisor)
    host_state = :sys.get_state(fixture.host)
    assert host_state.phase == :result
    engine_pid = host_state.engine
    async_pid = host_state.async_work
    writer_pid = host_state.writer
    [{unit_pid, nil}] = Registry.lookup(Elzoo.RunEngine.UnitRegistry, unit_id)
    assert is_pid(engine_pid) and Process.alive?(engine_pid)
    assert is_pid(async_pid) and Process.alive?(async_pid)
    assert Process.alive?(unit_pid)
    assert take_hash_calls() == [event["text"]]

    assert {:ok, run_before} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_before.current_attempt == attempt_id
    assert run_before.attempts == [attempt_id]
    assert is_nil(run_before.outcome)

    case outcome do
      :cancelled ->
        assert {:ok, _, :cancelled} =
                 RunApprovalRelease.command(fixture.owner, %{
                   kind: :cancel,
                   run_id: run_id,
                   attempt_id: attempt_id,
                   expected_revision: run_before.revision
                 })

      outcome when outcome in [:out_of_budget, :out_of_time] ->
        assert {:ok, _, ^outcome} =
                 RunApprovalRelease.command(fixture.owner, %{
                   kind: :complete,
                   run_id: run_id,
                   attempt_id: attempt_id,
                   outcome: outcome,
                   reason: nil,
                   evidence_ref: nil,
                   expected_revision: run_before.revision
                 })
    end

    assert {:terminal, ^outcome} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, run_terminal} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_terminal.id == run_before.id
    assert run_terminal.operation_id == run_before.operation_id
    assert run_terminal.current_attempt == attempt_id
    assert run_terminal.attempts == [attempt_id]
    assert run_terminal.revision == run_before.revision + 1
    assert run_terminal.outcome == outcome
    assert {:ok, [^item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    refute Process.alive?(task_pid)
    refute Process.alive?(engine_pid)
    refute Process.alive?(async_pid)
    refute Process.alive?(unit_pid)
    if is_pid(writer_pid), do: refute(Process.alive?(writer_pid))
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []

    cleanup_deadline = System.monotonic_time(:millisecond) + 5_000
    wait_for_registry_cleanup!(fixture.native.registry, unit_id, cleanup_deadline)
    wait_for_registry_cleanup!(Elzoo.RunEngine.UnitRegistry, unit_id, cleanup_deadline)
    wait_for_directory_cleanup!(fixture.directory, unit_id, cleanup_deadline)
    wait_for_unit_supervisor_cleanup!(fixture.unit_supervisor, cleanup_deadline)

    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert DynamicSupervisor.which_children(fixture.unit_supervisor) == []

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:ok, %{revision: 2}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, %{state: :acked, sequence: 1, ack_nonce: nonce, idempotency_key: key}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [item.idempotency_key])

    assert key == item.idempotency_key
    assert nonce == item.nonce

    assert {:ok, {{_, 200, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert %{"status" => "ok", "view" => %{"revision" => 2, "messages" => messages}} =
             Jason.decode!(body)

    assert Enum.count(messages, &(&1["role"] == "source")) == 1
    refute Enum.any?(messages, &(&1["role"] == "assistant"))
    assert take_hash_calls() == []
  end

  defp set_gate_fault(control, store, fault) do
    Agent.update(control, fn state -> %{state | store: store, fault: fault} end)
  end

  defp trace_native_start_returns(host) do
    Code.ensure_loaded!(Elzoo.DurableLog.Writer)
    Code.ensure_loaded!(Elzoo.AsyncWork)

    :erlang.trace_pattern(
      {Elzoo.DurableLog.Writer, :start_link, 1},
      [{:_, [], [{:return_trace}]}],
      [:global]
    )

    :erlang.trace_pattern(
      {Elzoo.AsyncWork, :start_link, 1},
      [{:_, [], [{:return_trace}]}],
      [:global]
    )

    :erlang.trace(host, true, [:call])
  end

  defp stop_native_start_returns(host) do
    :erlang.trace(host, false, [:call])
    :erlang.trace_pattern({Elzoo.DurableLog.Writer, :start_link, 1}, false, [:global])
    :erlang.trace_pattern({Elzoo.AsyncWork, :start_link, 1}, false, [:global])

    for pid <- Process.get(:wave4_native_start_pids, []) do
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 5_000)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end
    end

    Process.delete(:wave4_native_start_pids)
  end

  defp native_start_pids(returns) do
    [
      Map.get(returns, {Elzoo.DurableLog.Writer, :start_link}),
      Map.get(returns, {Elzoo.AsyncWork, :start_link})
    ]
    |> Enum.flat_map(fn
      {:ok, pid} when is_pid(pid) -> [pid]
      _ -> []
    end)
  end

  defp collect_native_start_returns(host, found) do
    reference = :erlang.trace_delivered(host)

    receive do
      {:trace_delivered, ^host, ^reference} -> collect_native_start_returns_received(host, found)
    after
      5_000 -> flunk("native start trace delivery timed out")
    end
  end

  defp collect_native_start_returns_received(host, found) do
    receive do
      {:trace, ^host, :return_from, {module, :start_link, 1}, result}
      when module in [Elzoo.DurableLog.Writer, Elzoo.AsyncWork] ->
        collect_native_start_returns_received(host, Map.put(found, {module, :start_link}, result))

      {:trace, ^host, :call, _} ->
        collect_native_start_returns_received(host, found)

      {:trace, ^host, _event, _} ->
        collect_native_start_returns_received(host, found)

      {:trace, ^host, _event, _, _} ->
        collect_native_start_returns_received(host, found)
    after
      0 -> found
    end
  end

  defp registry_partition_pids!(registry) do
    supervisor = Process.whereis(registry)
    assert is_pid(supervisor)

    partitions =
      supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&is_pid/1)

    assert partitions != []
    partitions
  end

  defp with_suspended_registry_partitions([], fun), do: fun.()

  defp with_suspended_registry_partitions([pid | rest], fun) do
    assert :ok = :sys.suspend(pid)

    try do
      with_suspended_registry_partitions(rest, fun)
    after
      assert :ok = :sys.resume(pid)
    end
  end

  defp wait_for_registry_cleanup!(registry, id, deadline) do
    registrations = Registry.lookup(registry, id)

    cond do
      registrations == [] ->
        :ok

      Enum.any?(registrations, fn {pid, _value} -> Process.alive?(pid) end) ->
        flunk("Registry retained a live native process")

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("Registry retained a stopped native process")

      true ->
        Process.sleep(1)
        wait_for_registry_cleanup!(registry, id, deadline)
    end
  end

  defp wait_for_directory_cleanup!(directory, id, deadline) do
    case DynamicUnits.find(directory, id) do
      :not_found ->
        :ok

      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          flunk("DynamicUnits retained a live native process")
        else
          if System.monotonic_time(:millisecond) >= deadline do
            flunk("DynamicUnits retained a stopped native process")
          else
            Process.sleep(1)
            wait_for_directory_cleanup!(directory, id, deadline)
          end
        end

      {:error, :unavailable} ->
        flunk("DynamicUnits became unavailable during native cleanup")
    end
  end

  defp wait_for_unit_supervisor_cleanup!(supervisor, deadline) do
    children = DynamicSupervisor.which_children(supervisor)

    cond do
      Enum.any?(children, fn {_id, pid, _type, _modules} ->
        is_pid(pid) and Process.alive?(pid)
      end) ->
        flunk("unit supervisor retained a live native child")

      children == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("unit supervisor retained a stopped native child")

      true ->
        Process.sleep(1)
        wait_for_unit_supervisor_cleanup!(supervisor, deadline)
    end
  end

  test "reply profile activates a primary wait and keeps GET and reply intake read-only" do
    {:ok, callbacks} = Agent.start_link(fn -> %{clock: 0, policy: 0, authority: 0} end)
    on_exit(fn -> if Process.alive?(callbacks), do: Agent.stop(callbacks) end)

    clock = fn ->
      Agent.update(callbacks, &Map.update!(&1, :clock, fn count -> count + 1 end))
      System.system_time(:millisecond)
    end

    policy = fn _mode, _event, _now ->
      Agent.update(callbacks, &Map.update!(&1, :policy, fn count -> count + 1 end))
      Elzoo.Wave4ChannelTestHelper.policy()
    end

    authority = fn _mode, _event, _request, _facts ->
      Agent.update(callbacks, &Map.update!(&1, :authority, fn count -> count + 1 end))
      %{}
    end

    fixture =
      Elzoo.Wave4ChannelTestHelper.reply_fixture(
        clock: clock,
        policy: policy,
        authority: authority
      )

    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    refute primary_listener.port == reply_listener.port
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "reply-profile-primary"})

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)

    assert {:observed, observed_input} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert observed_input == event["input_id"]
    {source_store, source_probe} = Elzoo.Wave4ChannelTest.ReadProbe.attach(fixture.command_store)
    :sys.replace_state(fixture.host, &%{&1 | command_store: source_store})

    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    primary_run =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        event["event_id"],
        event["input_id"]
      )

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    assert {:ok, view} = Elzoo.Wave4ChannelExample.view(fixture.host, scope)
    assert %{waits: [wait]} = view.event_waits
    assert wait.status == :waiting
    assert wait.source_id == fixture.profile.reply_source_id
    assert byte_size(wait.correlation_id) in 1..128
    assert Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, wait.correlation_id)
    assert is_list(wait.occurrence)
    assert length(wait.occurrence) == 2

    assert Enum.any?(view.associations, fn association ->
             association.input_message_id == event["input_id"] and association.run_id == primary_run
           end)

    stream = checked_stream(fixture.profile.tenant)
    {:ok, head_before} = Elzoo.DurableLog.Store.read(fixture.command_store, :head, [stream])

    assert {:ok, [primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert primary_item.destination == "wave4-channel-input"
    assert primary_item.sequence == 1
    assert {:ok, {^stream, 1, 1}} = Elzoo.Outbox.parse_id(primary_item.idempotency_key)

    assert wait.cursor == head_before.revision

    host_state = :sys.get_state(fixture.host)
    assert {:ok, native_status} = Elzoo.RunEngine.status(host_state.engine)
    assert [%{kind: "wait_event", phase: :waiting}] = Map.values(native_status.slots)
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []

    native_engine_state = :sys.get_state(host_state.engine)
    assert [native_wait_slot] = Map.values(native_engine_state.state.slots)
    assert native_wait_slot.kind == "wait_event"
    assert native_wait_slot.phase == :waiting
    assert native_wait_slot.reservation == nil
    assert native_wait_slot.actual == 0

    budget = native_engine_state.state.control.budgets["root"]

    {:Transition, _, {:some, {:status, budget_status}}} =
      Elzoo.Budget.step(budget.state, {System.system_time(:millisecond), :status})

    assert budget_status.committed == 0
    assert budget_status.reserved == 0

    assert %{facts: wait_facts} =
             Elzoo.Wave4ChannelExample.NativeBindings.build(fixture.profile).bindings["wait_event"]

    assert wait_facts.(%{}).estimate == 0

    {:ok, resource_before} =
      Elzoo.CheckedCommand.resource(
        fixture.handles.input,
        %{
          tenant: fixture.profile.tenant,
          actor: fixture.profile.actor,
          resources: [fixture.profile.conversation_id]
        },
        fixture.profile.conversation_id
      )

    callbacks_before_get = Agent.get(callbacks, & &1)
    Elzoo.Wave4ChannelTest.ReadProbe.reset(source_probe)
    trace_native_hash(fixture.native.task_supervisor)
    trace_engine_input(fixture.host)
    host_engine_before_get = host_state.engine
    native_tasks_before_get = Task.Supervisor.children(fixture.native.task_supervisor)

    assert {:ok, {{_, 200, _}, _, first_body}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert {:ok, {{_, 200, _}, _, second_body}} =
             Elzoo.Wave4ChannelTestHelper.get(reply_listener, fixture.profile.conversation_id)

    assert Jason.decode!(first_body) == Jason.decode!(second_body)

    assert wait.occurrence ==
             Jason.decode!(first_body)["view"]["event_waits"]["waits"]
             |> hd()
             |> Map.fetch!("occurrence")

    assert Agent.get(callbacks, & &1) == callbacks_before_get
    assert Elzoo.Wave4ChannelTest.ReadProbe.calls(source_probe) == []
    assert take_hash_calls() == []
    assert take_engine_input_ids() == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == native_tasks_before_get
    assert :sys.get_state(fixture.host).engine == host_engine_before_get

    assert {:ok, ^head_before} = Elzoo.DurableLog.Store.read(fixture.command_store, :head, [stream])

    assert {:ok, ^resource_before} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               %{
                 tenant: fixture.profile.tenant,
                 actor: fixture.profile.actor,
                 resources: [fixture.profile.conversation_id]
               },
               fixture.profile.conversation_id
             )

    reply_event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "reply-profile-refused-reply"})

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert {:ok, ^head_before} = Elzoo.DurableLog.Store.read(fixture.command_store, :head, [stream])

    assert {:ok, ^resource_before} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               %{
                 tenant: fixture.profile.tenant,
                 actor: fixture.profile.actor,
                 resources: [fixture.profile.conversation_id]
               },
               fixture.profile.conversation_id
             )

    mismatched_profile =
      Map.put(fixture.profile, :native_target, Elzoo.Wave4ChannelExample.NativeBindings.target())

    assert {:stop, :invalid_options} =
             Task.async(fn ->
               Elzoo.Wave4ChannelExample.init(
                 Keyword.put(fixture.host_options, :profile, mismatched_profile)
               )
             end)
             |> Task.await()
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
