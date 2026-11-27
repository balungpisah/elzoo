Code.require_file("support/wave4_channel_helper.exs", __DIR__)

defmodule Elzoo.Wave4ChannelTest.ReadProbe do
  alias Elzoo.{DurableLog.Codec, DurableLog.Store, Outbox}

  def attach({_module, inner} = store) do
    {:ok, observer} =
      Agent.start_link(fn ->
        %{calls: [], counts: %{}, transforms: %{}, faults: %{}, rollbacks: [], acks: []}
      end)

    # A transparent wrapper presents the wrapped store's declared fold and
    # limits: the durable log validates outbox items and confirmations
    # against them through the store it is given.
    declared = if is_map(inner), do: Map.take(inner, [:fold, :limits]), else: %{}
    {{__MODULE__, Map.merge(declared, %{store: store, observer: observer})}, observer}
  end

  def calls(observer), do: Agent.get(observer, &Enum.reverse(&1.calls))

  def reset(observer),
    do:
      Agent.update(
        observer,
        &%{&1 | calls: [], counts: %{}, transforms: %{}, faults: %{}, rollbacks: [], acks: []}
      )

  def transform(observer, operation, fun),
    do: Agent.update(observer, &put_in(&1.transforms[operation], fun))

  # Faults targeted at one outbox key, consumed one per matching call in the
  # given order: `:pass` lets one call through, `:ack` takes `:rollback`
  # (the PostgreSQL rollback hook is armed for exactly this write, which is
  # forwarded, reaches `:before_commit` and rolls back; see `rollbacks/1`),
  # `{:pause, token}` (the write is forwarded and pauses before its commit
  # with its writer alive) or `:reply_loss` (the write commits, its reply is
  # lost), and `:read_ack` takes `:unavailable` or `:malformed`. Other keys and operations are never
  # touched, unlike the PostgreSQL harness's next-call faults.
  def fault(observer, operation, key, modes) when is_list(modes),
    do: Agent.update(observer, &put_in(&1.faults[{operation, key}], modes))

  def fault(observer, operation, key, mode), do: fault(observer, operation, key, [mode])

  def faults(observer), do: Agent.get(observer, & &1.faults)

  # `{key, barrier_phases}` of each forwarded `:rollback` ack, oldest first:
  # the PostgreSQL barriers the write passed on its way to the rollback.
  def rollbacks(observer), do: Agent.get(observer, &Enum.reverse(&1.rollbacks))

  # The keys of every acknowledgement write dispatched through the probe.
  def acks(observer), do: Agent.get(observer, &Enum.reverse(&1.acks))

  def rewrite_item(item, payload) do
    rebuilt =
      Outbox.new(item.stream, item.sequence, item.position, item.destination, payload, item.nonce)

    Map.merge(item, Map.from_struct(rebuilt))
  end

  def capabilities({__MODULE__, state}) do
    count = record(state.observer, :capabilities)
    result = Store.read(state.store, :capabilities, [])
    apply_transform(state.observer, :capabilities, count, result)
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

    case take_fault(state.observer, :read_ack, key) do
      :unavailable ->
        {:error, :unavailable}

      :malformed ->
        {:error, :malformed}

      _pass ->
        result = Store.read(state.store, :read_ack, [key])
        apply_transform(state.observer, :read_ack, count, result)
    end
  end

  def read_at({__MODULE__, state}, stream, sequence) do
    count = record(state.observer, :read_at)
    result = Store.read(state.store, :read_at, [stream, sequence])
    apply_transform(state.observer, :read_at, count, result)
  end

  # v2 reads and writes flow through the probed store as well: outbox
  # windows, acknowledgements and checkpoints must pass through unchanged or
  # the host poisons on an artificial unavailability.
  def pending({__MODULE__, state}, stream, limit) do
    count = record(state.observer, :pending)
    result = Store.read(state.store, :pending, [stream, limit])
    apply_transform(state.observer, :pending, count, result)
  end

  def read_checkpoint({__MODULE__, state}, stream, kind, sequence) do
    Store.read(state.store, :read_checkpoint, [stream, kind, sequence])
  end

  def read_maintenance({__MODULE__, state}, stream, kind) do
    Store.read(state.store, :read_maintenance, [stream, kind])
  end

  def latest_checkpoint({__MODULE__, state}, stream, position) do
    Store.read(state.store, :latest_checkpoint, [stream, position])
  end

  def append({__MODULE__, state}, stream, revision, records, checkpoints) do
    record(state.observer, :append)
    store_write(state.store, :append, [stream, revision, records, checkpoints])
  end

  def ack({__MODULE__, state}, id, nonce) do
    record(state.observer, :ack)
    Agent.update(state.observer, &%{&1 | acks: [id | &1.acks]})

    case take_fault(state.observer, :ack, id) do
      {:pause, _token} = pause ->
        :ok = Elzoo.DurableLog.PostgresHarness.hook(state.store, :inject, [:ack, pause])
        store_write(state.store, :ack, [id, nonce])

      :rollback ->
        {_postgres, inner} = state.store
        seen = length(Elzoo.DurableLog.PostgresHarness.history(inner.controller))
        :ok = Elzoo.DurableLog.PostgresHarness.hook(state.store, :inject, [:ack, :rollback])
        result = store_write(state.store, :ack, [id, nonce])

        phases =
          inner.controller
          |> Elzoo.DurableLog.PostgresHarness.history()
          |> Enum.drop(seen)

        Agent.update(state.observer, &%{&1 | rollbacks: [{id, phases} | &1.rollbacks]})
        result

      :reply_loss ->
        _committed = store_write(state.store, :ack, [id, nonce])
        Store.unknown(Codec.ack_receipt(id, nonce), :unavailable)

      _pass ->
        store_write(state.store, :ack, [id, nonce])
    end
  end

  def retain({__MODULE__, state}, stream, kind, sequence, digest) do
    store_write(state.store, :retain, [stream, kind, sequence, digest])
  end

  def put_checkpoint({__MODULE__, state}, checkpoint) do
    store_write(state.store, :put_checkpoint, [checkpoint])
  end

  def repair_torn_tail({__MODULE__, state}, stream, sequence, digest, nonce) do
    store_write(state.store, :repair_torn_tail, [stream, sequence, digest, nonce])
  end

  defp store_write(store, operation, args) do
    apply(elem(store, 0), operation, [store | args])
  end

  defp take_fault(observer, operation, key) do
    Agent.get_and_update(observer, fn state ->
      case Map.get(state.faults, {operation, key}) do
        [mode] -> {mode, %{state | faults: Map.delete(state.faults, {operation, key})}}
        [mode | rest] -> {mode, %{state | faults: Map.put(state.faults, {operation, key}, rest)}}
        _ -> {nil, state}
      end
    end)
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
    # The v2 conversation piece caps stream segments at 64 bytes; the profile
    # uses the maximum length so the custody binding proofs still exercise
    # the longest legal identifiers. The actor is not a stream segment and
    # keeps the original 128-byte worst case.
    profile =
      fixture.profile
      |> Map.merge(%{
        tenant: String.duplicate("t", 64),
        actor: String.duplicate("a", 128),
        conversation_id: String.duplicate("c", 64),
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
               &Wave4ChannelExample.Intents.prepare/3
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
               &Wave4ChannelExample.Intents.prepare/3
             )

    assert {:ok, primary_window} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(%{fixture | profile: profile})

    [primary_item] = Enum.filter(primary_window, &(&1.destination == "wave4-channel-input"))

    command_stream = Elzoo.Wave4ChannelTestHelper.command_stream(profile.tenant)
    assert {:ok, {^command_stream, 2, 1}} = Outbox.parse_id(primary_item.idempotency_key)

    primary_association_facts =
      {:record,
       [
         {"mode", {:text, "associate_run"}},
         {"primary_key", {:text, primary_item.idempotency_key}},
         {"primary_nonce", {:bytes, primary_item.nonce}},
         {"primary_sequence", 1},
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
               &Wave4ChannelExample.Intents.prepare/3
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
               &Wave4ChannelExample.Intents.prepare/3
             )

    assert {:ok, reply_window} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(%{fixture | profile: profile})

    assert Enum.filter(reply_window, &(&1.destination == "wave4-channel-input")) == [primary_item]
    [reply_item] = Enum.filter(reply_window, &(&1.destination == "wave4-channel-reply"))

    assert {:ok, {^command_stream, 4, 1}} = Outbox.parse_id(reply_item.idempotency_key)

    reply_association_facts =
      {:record,
       [
         {"mode", {:text, "associate_run"}},
         {"primary_key", {:text, primary_item.idempotency_key}},
         {"reply_key", {:text, reply_item.idempotency_key}},
         {"reply_nonce", {:bytes, reply_item.nonce}},
         {"reply_sequence", 3},
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
               &Wave4ChannelExample.Intents.prepare/3
             )

    # The commands are committed; deliver their intents into the conversation
    # stream in command order through an owner, exactly as the host's delivery
    # pass would.
    assert {:ok, conversation_owner} =
             Conversation.start_link(
               store: fixture.conversation_store,
               target_tenant: profile.tenant,
               conversation_id: profile.conversation_id
             )

    on_exit(fn ->
      if Process.alive?(conversation_owner),
        do: GenServer.stop(conversation_owner, :normal, 5_000)
    end)

    assert {:completed, %{revision: 1, response: primary_response}} =
             CheckedCommand.result(
               handles.input,
               %{tenant: profile.tenant, actor: profile.actor},
               {profile.tenant, profile.actor, primary_operation}
             )

    assert {:ok, :input, input_dto} = Wave4ChannelExample.Intents.delivery(primary_response)

    assert {:ok, %{sequence: 1}} = Conversation.append_input(conversation_owner, input_dto)

    assert {:completed, %{revision: 2, response: primary_assoc_response}} =
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

    assert {:ok, :association, primary_assoc_dto} =
             Wave4ChannelExample.Intents.delivery(primary_assoc_response)

    assert {:ok, %{sequence: 2}} =
             Conversation.associate_run(conversation_owner, primary_assoc_dto)

    assert {:completed, %{revision: 3, response: reply_response}} =
             CheckedCommand.result(
               handles.reply_input,
               %{tenant: profile.tenant, actor: profile.actor},
               {profile.tenant, profile.actor, reply_operation}
             )

    assert {:ok, :input, reply_dto} = Wave4ChannelExample.Intents.delivery(reply_response)

    assert {:ok, %{sequence: 3}} = Conversation.append_input(conversation_owner, reply_dto)

    assert {:completed, %{revision: 4, response: reply_assoc_response}} =
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

    assert {:ok, :association, reply_assoc_dto} =
             Wave4ChannelExample.Intents.delivery(reply_assoc_response)

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

    read_scope = %{
      tenant: profile.tenant,
      actor: profile.actor,
      resources: [profile.conversation_id]
    }

    reference = %{
      target_tenant: profile.tenant,
      conversation_id: profile.conversation_id
    }

    assert {:ok, %{entries: conversation_entries}} =
             Conversation.page(fixture.conversation_store, read_scope, reference, 1, 100)

    assert Enum.any?(
             conversation_entries,
             &(&1.kind == :input and &1.message_id == ticket and &1.text == "exact retained reply")
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
             Wave4ChannelExample.Intents.metadata(
               Map.put(snapshot.fields, "wave4_reply", oversized_metadata),
               profile.tenant
             )

    primary = %{
      key: primary_item.idempotency_key,
      operation_id: primary_operation,
      input_id: input_id,
      run_id: run_id
    }

    # Both associations are committed, and only the primary one is delivered.
    # Committed receipts are not visibility: the reply is not an event before
    # both input-to-Run associations are in the conversation.
    assert {:error, :unavailable} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               reply_item.idempotency_key,
               profile,
               run_id,
               fixture.command_store,
               fixture.conversation_store,
               handles,
               primary
             )

    assert {:ok, %{sequence: 4}} =
             Conversation.associate_run(conversation_owner, reply_assoc_dto)

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
               fixture.conversation_store,
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
               fixture.conversation_store,
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
               fixture.conversation_store,
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

    # The key points inside the committed range at another command's row: the
    # canonical item binding does not verify, so the read fails closed rather
    # than fabricating or misreading an event.
    assert {:error, :unavailable} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               non_event.idempotency_key,
               profile,
               run_id,
               probe_store,
               fixture.conversation_store,
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
               fixture.conversation_store,
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
                 fixture.conversation_store,
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
               fixture.conversation_store,
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
               fixture.conversation_store,
               handles,
               primary
             )

    assert Elzoo.Wave4ChannelTest.ReadProbe.calls(read_probe) ==
             [:head, :capabilities, :read, :read_ack, :head]

    for {name, mutate} <- [
          {"item key", &Map.put(&1, :idempotency_key, "not-canonical")},
          {"item nonce", &Map.put(&1, :nonce, <<0::128>>)},
          {"item digest", &Map.put(&1, :digest, <<0::256>>)},
          {"reply source destination", &Map.put(&1, :destination, "wrong-destination")},
          {"canonical stream", &Map.put(&1, :stream, "wrong-stream")},
          {"canonical position", &Map.put(&1, :position, 2)},
          {"canonical sequence", fn item -> Map.put(item, :sequence, item.sequence + 1) end}
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
                 fixture.conversation_store,
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
          {"wrong notice operation", &Map.put(&1, "operation_id", "other-operation")},
          {"wrong notice receipt revision",
           &Map.update!(&1, "revision", fn revision -> revision + 1 end)},
          {"missing exact-schema revision", &Map.delete(&1, "revision")},
          {"unexpected source field", &Map.put(&1, "source_id", profile.reply_source_id)},
          {"float notice version", &Map.put(&1, "version", 1.0)}
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
                 fixture.conversation_store,
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
               fixture.conversation_store,
               handles,
               primary
             )

    Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)

    assert {:error, :unavailable} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               reply_item.idempotency_key,
               profile,
               run_id,
               probe_store,
               fixture.conversation_store,
               handles,
               %{primary | input_id: "wrong-reply-ticket"}
             ),
           "wrong reply ticket"

    {:ok, probe_handles} =
      Elzoo.Wave4ChannelExample.CommandBindings.build_reply(probe_store, fixture.gates)

    reply_command_operation = Jason.decode!(reply_item.payload)["operation_id"]

    reply_command_identity = {profile.tenant, profile.actor, reply_command_operation}
    result_scope = %{tenant: profile.tenant, actor: profile.actor}

    assert {:completed, %{revision: 3}} =
             CheckedCommand.result(handles.reply_input, result_scope, reply_command_identity)

    Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)

    Elzoo.Wave4ChannelTest.ReadProbe.transform(read_probe, :read, fn _result, _count ->
      {:error, :unavailable}
    end)

    assert {:unknown, :unresolved} =
             CheckedCommand.result(probe_handles.reply_input, result_scope, reply_command_identity)

    assert :read in Elzoo.Wave4ChannelTest.ReadProbe.calls(read_probe)

    Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)

    Elzoo.Wave4ChannelTest.ReadProbe.transform(read_probe, :read, fn _result, _count ->
      {:error, :unavailable}
    end)

    assert {:error, :unavailable} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               reply_item.idempotency_key,
               profile,
               run_id,
               probe_store,
               fixture.conversation_store,
               probe_handles,
               primary
             ),
           "unavailable public read is not a positive-low-water gap"

    assert :read in Elzoo.Wave4ChannelTest.ReadProbe.calls(read_probe)

    range_faults = [
      {"empty source range", fn {:ok, _records, head}, _count -> {:ok, [], head} end},
      {"missing source row",
       fn {:ok, records, head}, _count ->
         {:ok, Enum.reject(records, &(&1.sequence == reply_item.sequence)), head}
       end},
      {"noncontiguous source sequence",
       fn {:ok, records, head}, _count ->
         {:ok,
          Enum.map(records, fn item ->
            if item.sequence == 2, do: Map.put(item, :sequence, 3), else: item
          end), head}
       end},
      {"unavailable source range", fn _result, _count -> {:error, :unavailable} end}
    ]

    for {name, transform} <- range_faults do
      Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)
      Elzoo.Wave4ChannelTest.ReadProbe.transform(read_probe, :read, transform)

      assert {:error, :unavailable} =
               Elzoo.Wave4ChannelExample.ReplySource.read(
                 scope,
                 reply_item.idempotency_key,
                 profile,
                 run_id,
                 probe_store,
                 fixture.conversation_store,
                 handles,
                 primary
               ),
             name

      assert {:ok, %{revision: 5, low_water: 0}} =
               Elzoo.Wave4ChannelExample.ReplySource.head(scope, profile, run_id, probe_store)
    end

    Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)

    Elzoo.Wave4ChannelTest.ReadProbe.transform(read_probe, :head, fn
      {:ok, head}, _count -> {:ok, %{head | low_water: 1}}
      result, _count -> result
    end)

    assert {:error, :gap} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               reply_item.idempotency_key,
               profile,
               run_id,
               probe_store,
               fixture.conversation_store,
               handles,
               primary
             )

    Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)

    Elzoo.Wave4ChannelTest.ReadProbe.transform(read_probe, :head, fn
      {:ok, head}, _count -> {:ok, %{head | revision: 4_097}}
      result, _count -> result
    end)

    assert {:error, :unavailable} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               reply_item.idempotency_key,
               profile,
               run_id,
               probe_store,
               fixture.conversation_store,
               handles,
               primary
             )

    assert Elzoo.Wave4ChannelTest.ReadProbe.calls(read_probe) == [:head]

    Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)

    Elzoo.Wave4ChannelTest.ReadProbe.transform(read_probe, :read, fn
      {:ok, records, head}, _count ->
        {:ok,
         Enum.map(records, fn item ->
           if item.sequence == reply_item.sequence,
             do: Map.put(item, :payload, String.duplicate("x", 1_048_577)),
             else: item
         end), head}

      result, _count ->
        result
    end)

    assert {:error, :unavailable} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               reply_item.idempotency_key,
               profile,
               run_id,
               probe_store,
               fixture.conversation_store,
               handles,
               primary
             )

    assert Elzoo.Wave4ChannelTest.ReadProbe.calls(read_probe) ==
             [:head, :capabilities, :read, :head]

    Elzoo.Wave4ChannelTest.ReadProbe.reset(read_probe)

    assert {:ok, %{head: valid_head, event: valid_event}} =
             Elzoo.Wave4ChannelExample.ReplySource.read(
               scope,
               reply_item.idempotency_key,
               profile,
               run_id,
               probe_store,
               fixture.conversation_store,
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
               fixture.conversation_store,
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
               fixture.conversation_store,
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

    assert options[:profile].native_target == Wave4ChannelExample.NativeBindings.target()
    refute Map.has_key?(options[:profile], :reply_source_id)

    copied_primary_target =
      Map.new(options[:profile].native_target, fn {key, value} -> {key, :binary.copy(value)} end)

    copied_primary_profile = Map.put(options[:profile], :native_target, copied_primary_target)

    copied_primary_options =
      options
      |> Keyword.put(:profile, copied_primary_profile)
      |> Keyword.put(
        :native,
        Map.put(
          options[:native],
          :engine,
          Wave4ChannelExample.NativeBindings.build(copied_primary_profile)
        )
      )

    assert {:ok, %{profile: %{native_target: ^copied_primary_target}}} =
             Task.async(fn -> Wave4ChannelExample.init(copied_primary_options) end)
             |> Task.await()

    reply_fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    reply_options = reply_fixture.host_options
    declared_reply_target = Wave4ChannelExample.NativeBindings.reply_target()
    assert reply_options[:profile].native_target == declared_reply_target

    copied_reply_target =
      Map.new(declared_reply_target, fn {key, value} -> {key, :binary.copy(value)} end)

    copied_reply_profile = Map.put(reply_options[:profile], :native_target, copied_reply_target)
    [reply_binding] = reply_options[:bindings]

    copied_reply_options =
      reply_options
      |> Keyword.put(:profile, copied_reply_profile)
      |> Keyword.put(:bindings, [Map.put(reply_binding, "target", copied_reply_target)])
      |> Keyword.put(
        :native,
        Map.put(
          reply_options[:native],
          :engine,
          Wave4ChannelExample.NativeBindings.build(copied_reply_profile)
        )
      )

    assert {:ok, %{profile: %{native_target: ^copied_reply_target}}} =
             Task.async(fn -> Wave4ChannelExample.init(copied_reply_options) end)
             |> Task.await()

    arbitrary_reply_target = Map.put(declared_reply_target, "callable", "unregistered")

    arbitrary_reply_profile =
      Map.put(reply_options[:profile], :native_target, arbitrary_reply_target)

    arbitrary_reply_binding = Map.put(reply_binding, "target", arbitrary_reply_target)

    assert {:ok, %{target: ^arbitrary_reply_target}} =
             Elzoo.TriggerBinding.select(
               [arbitrary_reply_binding],
               %{tenant: arbitrary_reply_profile.tenant, source: arbitrary_reply_profile.source_id},
               %{"schema_id" => "elzoo.message/v1", "schema_version" => 1}
             )

    arbitrary_reply_options =
      reply_options
      |> Keyword.put(:profile, arbitrary_reply_profile)
      |> Keyword.put(:bindings, [arbitrary_reply_binding])

    assert {:stop, :invalid_options} =
             Task.async(fn -> Wave4ChannelExample.init(arbitrary_reply_options) end)
             |> Task.await()

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

    assert {:ok, writes, _response} =
             Wave4ChannelExample.Intents.prepare(snapshot, request, prepared_facts)

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

    assert {:ok, writes, _response} =
             Wave4ChannelExample.Intents.prepare(snapshot, request, prepared_facts)

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

    assert {:ok, writes, _response} =
             Wave4ChannelExample.Intents.prepare(snapshot, request, prepared_facts)

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

    # v2 fencing is absence-based: an association whose delivery is unproven
    # never appears in the view, so GET answers truthfully from the delivered
    # log. The input message is visible; the association and any run are not.
    assert {:ok, {{_, 200, _}, _, view_body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    view = Jason.decode!(view_body)["view"]
    assert view["associations"] == []
    assert view["runs"] == []
    assert Enum.any?(view["messages"], &(&1["message_id"] == input_id))

    blocked =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "blocked-after-association-loss",
        "input_id" => "blocked-association-input",
        "expected_revision" => 2
      })

    assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, blocked)

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

    # The reconciled association's delivery receipt is carried to the custody
    # gate: the round runs to its answer and acknowledges its primary item.
    assert %{current: %{deliveries: %{association: {_key, _nonce}}}} =
             :sys.get_state(fixture.host)

    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
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
    {:ok, pending_items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(pending_items, &(&1.destination == "wave4-channel-input"))
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
    {:ok, pending_items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(pending_items, &(&1.destination == "wave4-channel-input"))
    ack_key = item.idempotency_key
    ack_nonce = item.nonce

    # The answer's delivery item is acknowledged in the same advance, before
    # the primary item, so the faults target the primary item's key: the
    # harness's next-call faults would land on the delivery acknowledgement.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :ack, ack_key, :rollback)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :read_ack, ack_key, :unavailable)

    assert Map.take(Agent.get(fixture.native_controller, & &1.faults), [:ack, :read_ack]) == %{}
    assert {:unknown, :ack} = Wave4ChannelExample.advance(fixture.host)
    assert Elzoo.Wave4ChannelTest.ReadProbe.faults(probe) == %{}

    # A SQL rollback: the forwarded acknowledgement reached its commit barrier,
    # rolled back there, and left the item pending.
    assert [{^ack_key, phases}] = Elzoo.Wave4ChannelTest.ReadProbe.rollbacks(probe)
    assert {:ack, :before_commit} in phases
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :ack) == nil

    assert {:ok, %{state: :pending, nonce: ^ack_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [ack_key])

    assert Map.take(Agent.get(fixture.native_controller, & &1.faults), [:ack, :read_ack]) == %{}
    assert {:ack, ^ack_key, ^ack_nonce, _receipt} = :sys.get_state(fixture.host).poison

    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :read_ack, ack_key, :malformed)

    assert {:unknown, :ack} = Wave4ChannelExample.advance(fixture.host)
    assert Elzoo.Wave4ChannelTest.ReadProbe.faults(probe) == %{}
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
    {:ok, pending_items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(pending_items, &(&1.destination == "wave4-channel-input"))
    original_key = item.idempotency_key
    original_nonce = item.nonce
    other_nonce = :crypto.strong_rand_bytes(16)
    refute other_nonce == original_nonce

    # Targeted at the primary item's key: the answer's delivery item is
    # acknowledged first in the same advance.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :ack, original_key, :rollback)

    assert {:unknown, :ack} = Wave4ChannelExample.advance(fixture.host)
    assert Elzoo.Wave4ChannelTest.ReadProbe.faults(probe) == %{}

    # A SQL rollback: the forwarded acknowledgement reached its commit barrier,
    # rolled back there, and left the item pending.
    assert [{^original_key, phases}] = Elzoo.Wave4ChannelTest.ReadProbe.rollbacks(probe)
    assert {:ack, :before_commit} in phases
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :ack) == nil

    assert {:ok, %{state: :pending, nonce: ^original_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [original_key])

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
    {:ok, pending_items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(pending_items, &(&1.destination == "wave4-channel-input"))
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
    {:ok, pending_items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(pending_items, &(&1.destination == "wave4-channel-input"))
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

    {:ok, pending_items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(pending_items, &(&1.destination == "wave4-channel-input"))

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
    {:ok, window_items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [input_item] = Enum.filter(window_items, &(&1.destination == "wave4-channel-input"))

    Elzoo.DurableLog.PostgresHarness.hook(fixture.run_store, :inject, [:append, :reply_loss])
    assert {:unknown, :run_create} = Wave4ChannelExample.advance(fixture.host)
    assert {:unknown, :run_create} = Wave4ChannelExample.advance(fixture.host)
    assert :not_found = DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert [] = Task.Supervisor.children(fixture.native.task_supervisor)
    assert take_hash_calls() == []
    {:ok, window_after} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert Enum.filter(window_after, &(&1.destination == "wave4-channel-input")) == [input_item]

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
    {:ok, pending_items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(pending_items, &(&1.destination == "wave4-channel-input"))

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

    assert {:ok, {{_, 409, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, duplicate)

    duplicate_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, duplicate["event_id"])

    assert {:unknown, :not_observed} =
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

    # v2: the re-posted duplicate is an idempotent re-execution of a retained
    # terminal row — it commits nothing, so the head stays at revision 3.
    assert {:ok, %{revision: 3}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
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
    # The association becomes visible when the next advance delivers it; the
    # run is created in the same step, so the GET consults the run owner.
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
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

    # In v2 the delivering advance atomically continues into run creation, so
    # the pre-creation phase is observable only across a restart: the fresh
    # host delivers the association and stops at the known :create_run phase.
    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [listener])
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    assert {:observed, _} = Wave4ChannelExample.advance(fixture.host)

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

    # In v2 the association is visible only once delivered, and the delivering
    # advance would run host recovery against the mismatched run first. Append
    # the association entry directly, exactly as the delivery pass would.
    conversation_owner = Elzoo.Wave4ChannelTestHelper.conversation_owner(fixture)

    scope = %{tenant: fixture.profile.tenant, actor: fixture.profile.actor}
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])

    association_operation =
      Elzoo.Wave4ChannelTestHelper.association_operation_for(
        fixture.profile,
        operation,
        event["input_id"]
      )

    assert {:completed, %{response: response}} =
             CheckedCommand.result(
               fixture.handles.association,
               scope,
               {fixture.profile.tenant, fixture.profile.actor, association_operation}
             )

    assert {:ok, :association, association_dto} =
             Elzoo.Wave4ChannelExample.Intents.delivery(response)

    assert {:ok, %{sequence: _}} =
             Elzoo.Conversation.associate_run(conversation_owner, association_dto)

    before_head = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    before_outbox = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 503, _}, _, body}} =
             Elzoo.Wave4ChannelTestHelper.get(listener, fixture.profile.conversation_id)

    assert Jason.decode!(body) == %{"status" => "unavailable"}
    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == before_head
    assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == before_outbox
  end

  @tag timeout: 300_000
  test "admission reserves no conversation space for the future association and answer", %{
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

    event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "unreserved-capacity-event",
        "input_id" => "unreserved-capacity-input",
        "expected_revision" => snapshot.revision,
        "text" => String.duplicate("y", 4_096)
      })

    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert_round_completes!(fixture, event, snapshot.revision + 3)

    assert {:ok, view} = Wave4ChannelExample.view(fixture.host, scope)

    assert Enum.any?(
             view.messages,
             &(&1.message_id == "unreserved-capacity-input" and &1.role == "source")
           )

    assert Enum.any?(view.messages, &(&1.role == "assistant"))

    assert view.associations == [
             %{input_message_id: "unreserved-capacity-input", run_id: run_id_of(fixture, event)}
           ]

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
  end

  @tag timeout: 300_000
  test "the channel resource stays bounded while the conversation exceeds 65,536 bytes", %{
    fixture: fixture
  } do
    for index <- 1..17 do
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

    assert Map.keys(snapshot.fields) == ["wave4_intent"]
    assert_conversation_exceeds!(fixture, 65_536)

    event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "bounded-resource-event",
        "input_id" => "bounded-resource-input",
        "expected_revision" => snapshot.revision,
        "text" => String.duplicate("y", 4_096)
      })

    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert_round_completes!(fixture, event, snapshot.revision + 3)

    assert {:ok, final_resource} =
             CheckedCommand.resource(
               fixture.handles.input,
               scope,
               fixture.profile.conversation_id
             )

    assert Map.keys(final_resource.fields) == ["wave4_intent"]

    assert {:bytes, digest} = final_resource.fields["wave4_intent"]
    assert byte_size(digest) == 32
    assert final_resource.revision == snapshot.revision + 3

    assert {:ok, view} = Wave4ChannelExample.view(fixture.host, scope)
    assert byte_size(Jason.encode!(view)) <= 1_048_576
  end

  @tag timeout: 300_000
  test "v2 primary admission over a conversation above 65,536 bytes binds only the intent digest" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()

    for index <- 1..17 do
      assert {:completed, %{revision: ^index}} =
               seed_message!(fixture, index, String.duplicate("x", 4_096))
    end

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, snapshot} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    assert_conversation_exceeds!(fixture, 65_536)

    event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "v2-digest-binding-event",
        "input_id" => "v2-digest-binding-input",
        "expected_revision" => snapshot.revision,
        "text" => String.duplicate("y", 4_096)
      })

    {primary_listener, _reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)

    input_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])

    assert {:completed, %{revision: input_revision, response: {:record, fields}}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, input_operation}
             )

    assert input_revision == snapshot.revision + 1

    assert {:ok, :input, dto} =
             Wave4ChannelExample.Intents.delivery({:record, fields})

    assert dto.message_id == event["input_id"]
    assert dto.text == event["text"]
    assert dto.role == "source"

    assert {:ok, resource} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    assert Map.keys(resource.fields) |> Enum.sort() == ["wave4_intent"]

    assert {:bytes, digest} = resource.fields["wave4_intent"]
    assert byte_size(digest) == 32
    assert resource.revision == input_revision
  end

  @tag timeout: 300_000
  test "v2 completes a signed reply round beyond 64 messages" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()

    for index <- 1..62 do
      assert {:completed, %{revision: ^index}} = seed_message!(fixture, index, "x")
    end

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, snapshot} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "v2-beyond-slots",
        "input_id" => "v2-beyond-primary",
        "expected_revision" => snapshot.revision,
        "text" => "primary"
      })

    assert_reply_round_completes!(fixture, event)
    assert_message_count_at_least!(fixture, 64)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
  end

  @tag timeout: 300_000
  test "signed v2 primary beyond 64 messages reaches native work", %{fixture: fixture} do
    for index <- 1..62 do
      assert {:completed, %{revision: ^index}} = seed_message!(fixture, index, "x")
    end

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, snapshot} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "v2-beyond-one",
        "input_id" => "v2-beyond-one-input",
        "expected_revision" => snapshot.revision,
        "text" => "primary"
      })

    trace_native_hash(fixture.native.task_supervisor)
    trace_engine_input(fixture.host)

    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)

    input_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])

    assert {:completed, %{revision: input_revision}} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, input_operation}
             )

    assert input_revision == snapshot.revision + 1

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    assert {:observed, _input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, _run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)
    assert take_engine_input_ids() != []

    assert {:ok, _native_result} =
             wait_public_result(
               :sys.get_state(fixture.host).engine,
               %{tenant: fixture.profile.tenant, principal: fixture.profile.actor, run_id: run_id},
               System.monotonic_time(:millisecond) + 10_000
             )

    assert take_hash_calls() != []
  end

  @tag timeout: 300_000
  test "a committed message and association are visible only after delivery", %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    # The conversation append is unavailable: the input commits at admission
    # but its delivery can never be proven while the fault holds.
    Elzoo.DurableLog.PostgresHarness.hook(fixture.conversation_store, :inject, [
      :append,
      :unavailable
    ])

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)

    input_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])

    assert {:completed, _} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, input_operation}
             )

    # Committed but undelivered: the message stays invisible.
    assert {:ok, view_before} = Wave4ChannelExample.view(fixture.host, scope)
    refute Enum.any?(view_before.messages, &(&1.message_id == input_id))
    refute Enum.any?(view_before.associations, &(&1.input_message_id == input_id))

    # Recovering redelivers the identical intent; the pipeline completes and
    # both the message and its association become visible.
    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [listener])

    assert_round_completes!(fixture, event, 3)

    assert {:ok, view_after} = Wave4ChannelExample.view(fixture.host, scope)

    assert Enum.any?(
             view_after.messages,
             &(&1.message_id == input_id and &1.role == "source")
           )

    assert Enum.any?(
             view_after.associations,
             &(&1.input_message_id == input_id and &1.run_id == run_id)
           )
  end

  @tag timeout: 300_000
  test "a signed input reusing a pending message ID is refused before commit", %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, snapshot} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    duplicate =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "duplicate-pending-input",
        "input_id" => input_id,
        "expected_revision" => snapshot.revision,
        "text" => "different text"
      })

    assert {:ok, {{_, 409, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, duplicate)

    input_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, duplicate["event_id"])

    assert {:unknown, :not_observed} =
             CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, input_operation}
             )

    assert {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert length(items) == 1

    assert_round_completes!(fixture, event, 3)

    later =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "duplicate-delivered-input",
        "input_id" => input_id,
        "expected_revision" => 3,
        "text" => "later text"
      })

    assert {:ok, {{_, 409, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, later)
  end

  @tag timeout: 300_000
  test "a fresh operation whose retained-result read fails is refused, not exempted from admission",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    profile = fixture.profile

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert_round_completes!(fixture, event, 3)

    # A new operation reusing the completed round's message ID.
    reused =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "reuse-after-round",
        "input_id" => input_id,
        "expected_revision" => 3,
        "text" => "a different text"
      })

    identity =
      {profile.tenant, profile.actor,
       Elzoo.Wave4ChannelTestHelper.input_operation(profile, reused["event_id"])}

    result_scope = %{tenant: profile.tenant, actor: profile.actor}

    {probe_store, probe} = Elzoo.Wave4ChannelTest.ReadProbe.attach(fixture.command_store)
    on_exit(fn -> if Process.alive?(probe), do: Agent.stop(probe) end)

    :sys.replace_state(fixture.host, fn state ->
      input = %{state.handles.input | store: probe_store}
      %{state | handles: %{state.handles | input: input}}
    end)

    head_before = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    outbox_before = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    # Admission reads the identity's retained result twice: to classify the
    # request, then for its freshness. Each read starts with the Store's
    # capabilities and head; the first read pages the history, which checks
    # the capabilities once more. So the freshness read is the third
    # capabilities and the third head call. It fails, once as an unreadable
    # history head and once as a history whose Store is not atomic. Neither is
    # a retained outcome, so neither exempts the operation from admission.
    faults = [
      {:head, fn result, count -> if count == 3, do: {:error, :unavailable}, else: result end},
      {:capabilities,
       fn result, count ->
         if count == 3, do: %{append_visibility: :staged_uncommitted_tail}, else: result
       end}
    ]

    for {operation, fault} <- faults do
      Elzoo.Wave4ChannelTest.ReadProbe.reset(probe)
      Elzoo.Wave4ChannelTest.ReadProbe.transform(probe, operation, fault)

      assert {:ok, {{_, 503, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, reused)

      assert [:capabilities, :head, :capabilities, :read, :head, :capabilities | _] =
               Elzoo.Wave4ChannelTest.ReadProbe.calls(probe)

      assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == head_before
      assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == outbox_before

      assert {:unknown, :not_observed} =
               CheckedCommand.result(fixture.handles.input, result_scope, identity)
    end

    # With the reads intact, admission decides it: the message ID belongs to
    # the completed round, so the new operation is a conflict.
    Elzoo.Wave4ChannelTest.ReadProbe.reset(probe)
    assert {:ok, {{_, 409, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, reused)
    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == head_before

    assert {:unknown, :not_observed} =
             CheckedCommand.result(fixture.handles.input, result_scope, identity)
  end

  @tag timeout: 300_000
  test "a fresh reply naming another granted conversation is refused before it executes" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    profile = fixture.profile
    other = "other-conversation"

    wide = %{
      tenant: profile.tenant,
      actor: profile.actor,
      resources: [profile.conversation_id, other]
    }

    result_scope = %{tenant: profile.tenant, actor: profile.actor}

    {primary_listener, reply_listener} =
      Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture,
        webhook_principal: fn _conn -> {:ok, wide} end
      )

    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "fixed-target-primary"})
    input_id = event["input_id"]

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Wave4ChannelExample.advance(fixture.host) end)

    scope = Elzoo.Wave4ChannelTestHelper.scope(profile)
    assert {:ok, %{event_waits: %{waits: [wait]}}} = Wave4ChannelExample.view(fixture.host, scope)

    assert {:ok, %{revision: revision}} =
             CheckedCommand.resource(fixture.handles.input, scope, profile.conversation_id)

    # The other granted conversation reaches the same revision, so a reply
    # executed against it would find its expected revision there.
    for n <- 1..revision do
      seed =
        Elzoo.Wave4ChannelTestHelper.event(%{
          "event_id" => "other-#{n}",
          "input_id" => "other-input-#{n}",
          "conversation_id" => other,
          "expected_revision" => n - 1
        })

      assert {{:completed, %{revision: ^n}}, _writes} = seed_input_command!(fixture, seed, :allow)
    end

    assert {:ok, %{revision: ^revision}} =
             CheckedCommand.resource(fixture.handles.input, wide, other)

    head_before = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "fixed-target-reply",
        "conversation_id" => other,
        "input_id" => wait.correlation_id,
        "expected_revision" => revision,
        "text" => "aimed at the other conversation"
      })

    # Directly at the host boundary, with a trusted scope that grants both
    # conversations, and through the signed listener.
    assert {:rejected, :forbidden} =
             Wave4ChannelExample.admit_reply(fixture.host, normalized_event(reply_event), wide)

    assert {:ok, {{_, 403, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == head_before

    assert {:ok, %{revision: ^revision}} =
             CheckedCommand.resource(fixture.handles.input, wide, other)

    reply_identity =
      {profile.tenant, profile.actor,
       Elzoo.Wave4ChannelTestHelper.reply_operation(profile, reply_event["event_id"])}

    assert {:unknown, :not_observed} =
             CheckedCommand.result(fixture.handles.reply_input, result_scope, reply_identity)

    assert :sys.get_state(fixture.host).reply == nil
  end

  @tag timeout: 300_000
  test "a reply-profile host reopened between primary delivery and association completes the round" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    profile = fixture.profile
    scope = Elzoo.Wave4ChannelTestHelper.scope(profile)
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "reopen-before-association"})
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)

    # The primary is delivered at sequence 1; its association is not committed.
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, 1} = conversation_head(fixture)

    association =
      {profile.tenant, profile.actor,
       Elzoo.Wave4ChannelTestHelper.association_operation(profile, event["event_id"], input_id)}

    assert {:unknown, :not_observed} =
             CheckedCommand.result(
               fixture.handles.association,
               %{tenant: profile.tenant, actor: profile.actor},
               association
             )

    # The reopened host remembers no delivered sequence: the primary
    # association's custody facts take it from the conversation.
    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    {_primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, snapshot} =
             CheckedCommand.resource(fixture.handles.input, scope, profile.conversation_id)

    assert {:ok, %{run_id: ^run_id, primary_sequence: 1, reply_key: nil}} =
             Wave4ChannelExample.Intents.metadata(snapshot.fields, profile.tenant)

    Enum.each(1..10, fn _ -> Wave4ChannelExample.advance(fixture.host) end)

    assert {:ok, %{event_waits: %{waits: [wait]}}} = Wave4ChannelExample.view(fixture.host, scope)

    assert {:ok, before_reply} =
             CheckedCommand.resource(fixture.handles.input, scope, profile.conversation_id)

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "reopen-before-association-reply",
        "input_id" => wait.correlation_id,
        "expected_revision" => before_reply.revision,
        "text" => "reply after reopen"
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    reply_key = Enum.find(pending, &(&1.destination == "wave4-channel-reply")).idempotency_key

    assert {:reply_observed, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_reply, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, _native_result} =
             wait_public_result(
               :sys.get_state(fixture.host).engine,
               %{tenant: profile.tenant, principal: profile.actor, run_id: run_id},
               System.monotonic_time(:millisecond) + 10_000
             )

    assert {:result, :completed} = Wave4ChannelExample.advance(fixture.host)
    assert {:answered, _revision} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_acknowledged, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
  end

  @tag timeout: 300_000
  test "a cut between the conversation append and its acknowledgement redelivers without a new row",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    reference = Elzoo.Wave4ChannelTestHelper.conversation_reference(fixture.profile)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(pending, &(&1.destination == "wave4-channel-delivery"))
    key = item.idempotency_key
    nonce = item.nonce

    # The cut: the association's delivery append commits, then its
    # acknowledgement rolls back before it commits (the first acknowledgement
    # of this advance; the input item is acknowledged only at the round's end).
    Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [:ack, :rollback])

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :ack) == nil
    assert {:delivery_ack, ^key, ^nonce, _reason} = :sys.get_state(fixture.host).poison

    # At the cut the conversation row exists and the item is still pending.
    assert {:ok, %{entries: entries}} =
             Conversation.page(fixture.conversation_store, scope, reference, 1, 100)

    assert Enum.count(
             entries,
             &(&1.kind == :association and &1.input_message_id == input_id and
                 &1.run_id == run_id)
           ) == 1

    assert {:ok, %{state: :pending, nonce: ^nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [key])

    assert {:ok, head_at_cut} = conversation_head(fixture)
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)

    # The crash: fence the host and reopen. Redelivery of the identical intent
    # is already present, so the Conversation head does not move, and the
    # item is acknowledged with its original key and nonce.
    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [listener])
    assert {:ok, ^head_at_cut} = conversation_head(fixture)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, ^head_at_cut} = conversation_head(fixture)

    assert {:ok, %{state: :acked, nonce: ^nonce, ack_nonce: ^nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [key])

    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, ^head_at_cut} = conversation_head(fixture)

    assert {:ok, %{entries: entries_after}} =
             Conversation.page(fixture.conversation_store, scope, reference, 1, 100)

    assert entries_after == entries
  end

  @tag timeout: 300_000
  test "an unknown delivery is retried with the identical intent before later intents", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    reference = Elzoo.Wave4ChannelTestHelper.conversation_reference(fixture.profile)

    first =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "ordering-first",
        "input_id" => "ordering-first-input"
      })

    second =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "ordering-second",
        "input_id" => "ordering-second-input",
        "expected_revision" => 1,
        "text" => "the later intent"
      })

    # Two committed, undelivered intents of this conversation, in command
    # sequence order: the signed input, then a second input committed behind it.
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, first)
    assert {{:completed, %{revision: 2}}, _writes} = seed_input_command!(fixture, second, :allow)

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert [first_item, second_item] =
             Enum.filter(pending, &(&1.destination == "wave4-channel-input"))

    assert first_item.sequence < second_item.sequence
    assert {:ok, 0} = conversation_head(fixture)

    # The first intent's append is unknown: the delivery pass stops there.
    Elzoo.DurableLog.PostgresHarness.hook(fixture.conversation_store, :inject, [
      :append,
      :unavailable
    ])

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery, first_key, _reason} = :sys.get_state(fixture.host).poison
    assert first_key == first_item.idempotency_key

    # While it is unknown, the later intent does not pass it.
    assert {:ok, 0} = conversation_head(fixture)

    # The retry appends the identical first intent, then the later one.
    assert {:observed, "ordering-first-input"} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, %{entries: entries}} =
             Conversation.page(fixture.conversation_store, scope, reference, 1, 100)

    assert Enum.map(entries, &{&1.kind, &1.message_id, &1.sequence}) == [
             {:input, "ordering-first-input", 1},
             {:input, "ordering-second-input", 2}
           ]
  end

  @tag timeout: 300_000
  test "a window read failure while an unknown delivery is retried keeps that retry first", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    Elzoo.DurableLog.PostgresHarness.hook(fixture.conversation_store, :inject, [
      :append,
      :unavailable
    ])

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery, key, _reason} = retry = :sys.get_state(fixture.host).poison
    assert {:ok, head_before} = conversation_head(fixture)

    # The retry cannot read the outbox window: nothing is delivered and the
    # unknown delivery stays the retry state; no later work runs.
    Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [:pending, :unavailable])

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :pending) == nil
    assert :sys.get_state(fixture.host).poison == retry
    assert {:ok, ^head_before} = conversation_head(fixture)
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)

    # Discovery is retried: the identical intent is delivered first.
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, head_after} = conversation_head(fixture)
    assert head_after == head_before + 1

    assert {:ok, %{state: :acked}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [key])
  end

  @tag timeout: 300_000
  test "the host restarts its conversation owner from the validated stream when it exits", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    reference = Elzoo.Wave4ChannelTestHelper.conversation_reference(fixture.profile)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    owner = Elzoo.Wave4ChannelTestHelper.conversation_owner(fixture)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    wait_until!(
      fn ->
        restarted = Elzoo.Wave4ChannelTestHelper.conversation_owner(fixture)
        is_pid(restarted) and restarted != owner and Process.alive?(restarted)
      end,
      System.monotonic_time(:millisecond) + 5_000
    )

    assert Process.alive?(fixture.host)

    # The restarted owner read the delivered input; the round continues and
    # the association is delivered through it.
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, %{entries: entries}} =
             Conversation.page(fixture.conversation_store, scope, reference, 1, 100)

    assert Enum.map(entries, &{&1.kind, &1.sequence}) == [{:input, 1}, {:association, 2}]
  end

  @tag timeout: 300_000
  test "a definite delivery refusal is reported and blocks later deliveries", %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    reference = Elzoo.Wave4ChannelTestHelper.conversation_reference(fixture.profile)

    # Admission succeeds while no conflicting row is visible.
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)

    # A conflicting input with the same message ID lands in the conversation
    # after admission: the committed input's delivery is then a definite
    # refusal — never a silent retry — and the host reports it and blocks.
    assert {:ok, owner} =
             Conversation.start_link(
               store: fixture.conversation_store,
               target_tenant: fixture.profile.tenant,
               conversation_id: fixture.profile.conversation_id
             )

    assert {:ok, %{sequence: _}} =
             Conversation.append_input(owner, %{
               message_id: input_id,
               actor: fixture.profile.actor,
               text: "preexisting",
               role: "source"
             })

    GenServer.stop(owner, :normal, 5_000)

    assert {:blocked, {:delivery_refused, code}} = Wave4ChannelExample.advance(fixture.host)
    assert is_binary(code)
    assert match?({:blocked, _}, Wave4ChannelExample.advance(fixture.host))

    # Nothing was appended by the channel's deliveries: the conflicting row is
    # the only input with this message ID and no association ever lands.
    assert {:ok, %{entries: entries}} =
             Conversation.page(fixture.conversation_store, scope, reference, 1, 100)

    assert Enum.count(entries, &(&1.kind == :input and &1.message_id == input_id)) == 1
    refute Enum.any?(entries, &(&1.kind == :association))
  end

  @tag timeout: 300_000
  test "a committed acknowledgement with a lost reply is confirmed by its original key and nonce",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))
    key = item.idempotency_key
    nonce = item.nonce

    # The association item's acknowledgement commits but its reply is lost,
    # and the same-pass confirmation cannot read the item either: the host
    # keeps the original key and nonce and advances nothing.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :ack, key, :reply_loss)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :read_ack, key, [:pass, :unavailable])

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert Elzoo.Wave4ChannelTest.ReadProbe.faults(probe) == %{}
    assert {:delivery_ack, ^key, ^nonce, _reason} = :sys.get_state(fixture.host).poison

    assert {:ok, %{state: :acked, ack_nonce: ^nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [key])

    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
    assert {:ok, head_before} = conversation_head(fixture)

    # The next advance confirms that acknowledgement by its key and nonce
    # before anything else, then the round continues; nothing is redelivered.
    Elzoo.Wave4ChannelTest.ReadProbe.reset(probe)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert :read_ack in Elzoo.Wave4ChannelTest.ReadProbe.calls(probe)
    assert :sys.get_state(fixture.host).poison == nil
    assert {:ok, ^head_before} = conversation_head(fixture)
  end

  @tag timeout: 300_000
  test "a delivery acknowledgement that another nonce won stays fenced", %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))
    key = item.idempotency_key
    nonce = item.nonce
    other_nonce = :crypto.strong_rand_bytes(16)
    refute other_nonce == nonce

    # The association is delivered, its acknowledgement rolls back (unknown),
    # and then another nonce wins the item's key.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :ack, key, :rollback)

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, _reason} = :sys.get_state(fixture.host).poison

    # A SQL rollback: the forwarded acknowledgement reached its commit barrier,
    # rolled back there, and left the item pending.
    assert [{^key, phases}] = Elzoo.Wave4ChannelTest.ReadProbe.rollbacks(probe)
    assert {:ack, :before_commit} in phases
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :ack) == nil

    assert {:ok, %{state: :pending, nonce: ^nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [key])

    assert {:committed, _} = Elzoo.Outbox.ack(fixture.command_store, key, other_nonce)
    assert {:ok, head_before} = conversation_head(fixture)

    # The item is no longer pending, but the original nonce did not win: the
    # host stays fenced and nothing later runs.
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, _reason} = :sys.get_state(fixture.host).poison
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
    assert {:ok, ^head_before} = conversation_head(fixture)

    assert {:ok, %{state: :acked, nonce: ^nonce, ack_nonce: ^other_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [key])

    # Across a fenced reopen the original key and nonce are no longer in host
    # memory: recovery rebuilds them from the durable outbox item of the
    # completed association command, finds another nonce's acknowledgement,
    # and stays fenced instead of moving on to Run creation.
    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [listener])
    assert :sys.get_state(fixture.host).poison == nil

    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, :superseded} = :sys.get_state(fixture.host).poison
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert :sys.get_state(fixture.host).phase == :idle
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
    assert {:ok, ^head_before} = conversation_head(fixture)
  end

  @tag timeout: 300_000
  test "a delivery acknowledgement paused before its commit is confirmed, never written twice", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))
    key = item.idempotency_key
    nonce = item.nonce

    # The association's delivery acknowledgement pauses before its commit: its
    # writer is alive and the item still reads pending everywhere else.
    probe = probe_host_command_store!(fixture)
    token = :wave4_delivery_ack_writer

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [
               :ack,
               {:pause, token}
             ])

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, _reason} = :sys.get_state(fixture.host).poison
    writer = Elzoo.DurableLog.PostgresHarness.paused(fixture.controller, token)
    assert writer.operation == :ack
    assert Process.alive?(writer.pid)

    assert {:ok, %{state: :pending}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [key])

    # Confirmation by the original receipt is read-only: no second
    # acknowledgement starts while the first one's writer is alive.
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert Enum.count(Elzoo.Wave4ChannelTest.ReadProbe.calls(probe), &(&1 == :ack)) == 1
    assert Process.alive?(writer.pid)
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)

    # The original acknowledgement commits; its receipt (key, nonce and
    # digest) is confirmed and the round continues without another write.
    assert {:committed, _} =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :release, [token])

    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert Enum.count(Elzoo.Wave4ChannelTest.ReadProbe.calls(probe), &(&1 == :ack)) == 1

    assert {:ok, %{state: :acked, ack_nonce: ^nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [key])
  end

  @tag timeout: 300_000
  test "a delivery acknowledgement never sent because its item read failed is sent on the retry",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))
    key = item.idempotency_key
    nonce = item.nonce

    # The association is delivered, then the read before its first
    # acknowledgement fails: no acknowledgement was sent, so the host keeps a
    # retryable state instead of waiting for a write that never happened.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :read_ack, key, :unavailable)

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack_unsent, ^key, ^nonce, :unavailable} = :sys.get_state(fixture.host).poison
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == []

    assert {:ok, %{state: :pending, nonce: ^nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [key])

    assert {:ok, head_after_delivery} = conversation_head(fixture)

    # The retry reads the item again and sends the first acknowledgement once;
    # the identical redelivery appends nothing.
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == [key]

    assert {:ok, %{state: :acked, ack_nonce: ^nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [key])

    assert {:ok, ^head_after_delivery} = conversation_head(fixture)
  end

  @tag timeout: 300_000
  test "an unsent delivery acknowledgement whose key another nonce won before the retry stays fenced",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))
    key = item.idempotency_key
    nonce = item.nonce
    other_nonce = :crypto.strong_rand_bytes(16)
    refute other_nonce == nonce

    # The association is delivered and the read before its first
    # acknowledgement fails: nothing was sent, and the host keeps the item's
    # original key and nonce.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :read_ack, key, :unavailable)

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack_unsent, ^key, ^nonce, :unavailable} = :sys.get_state(fixture.host).poison
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == []

    # Before the retry another nonce acknowledges that key: the item is no
    # longer pending, so a rescan of the pending window would not see it.
    assert {:committed, _} = Elzoo.Outbox.ack(fixture.command_store, key, other_nonce)

    # The retry reads that exact item by its original key and nonce, finds
    # the other nonce's acknowledgement and stays fenced: no acknowledgement
    # is sent and nothing later runs.
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, :superseded} = :sys.get_state(fixture.host).poison
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == []
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)

    assert {:ok, %{state: :acked, nonce: ^nonce, ack_nonce: ^other_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [key])
  end

  @tag timeout: 300_000
  test "an unreadable acknowledgement proof on reopen is observed again on the next advance", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))
    key = item.idempotency_key
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, %{state: :acked}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [key])

    # After a reopen, the proof that the association's delivery item was
    # acknowledged with its original nonce cannot be read once: recovery keeps
    # a retryable, read-only state and observes again on the next advance.
    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [listener])
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :read_ack, key, :unavailable)

    assert {:unknown, :recovery} = Wave4ChannelExample.advance(fixture.host)
    assert {:v2_recovery, :delivery_ack} = :sys.get_state(fixture.host).poison
    assert Elzoo.Wave4ChannelTest.ReadProbe.faults(probe) == %{}

    # Two consecutive retries cannot read the pending window: nothing is
    # observed and the recovery stays retryable, never a terminal failure.
    for _ <- 1..2 do
      assert :ok =
               Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [
                 :pending,
                 :unavailable
               ])

      assert {:unknown, :recovery} = Wave4ChannelExample.advance(fixture.host)
      assert Map.get(Agent.get(fixture.controller, & &1.faults), :pending) == nil
      assert {:v2_recovery, :delivery_ack} = :sys.get_state(fixture.host).poison
    end

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert %{poison: nil, phase: :create_run} = :sys.get_state(fixture.host)
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == []
  end

  @tag timeout: 300_000
  test "a superseded answer delivery acknowledgement stays fenced across a fenced reopen", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)

    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))
    [primary_item] = Enum.filter(items, &(&1.destination == "wave4-channel-input"))
    key = item.idempotency_key
    nonce = item.nonce
    other_nonce = :crypto.strong_rand_bytes(16)
    refute other_nonce == nonce

    # The answer is delivered, its acknowledgement rolls back, and another
    # nonce wins the answer item's key.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :ack, key, :rollback)
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, _reason} = :sys.get_state(fixture.host).poison
    assert {:committed, _} = Elzoo.Outbox.ack(fixture.command_store, key, other_nonce)
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)

    # Across a fenced reopen, recovery verifies the answer's delivery
    # acknowledgement by its rebuilt original key and nonce before it would
    # advance to the primary acknowledgement.
    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [listener])
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, :superseded} = :sys.get_state(fixture.host).poison
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert :sys.get_state(fixture.host).current == nil

    primary_nonce = primary_item.nonce

    assert {:ok, %{state: :pending, nonce: ^primary_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
               primary_item.idempotency_key
             ])
  end

  @tag timeout: 300_000
  test "a superseded answer delivery acknowledgement in a two-source round stays fenced across a fenced reopen" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    profile = fixture.profile
    scope = Elzoo.Wave4ChannelTestHelper.scope(profile)
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "two-source-answer-superseded"})
    primary_id = event["input_id"]
    run_id = run_id_of(fixture, event)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)
    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Wave4ChannelExample.advance(fixture.host) end)
    assert {:ok, %{event_waits: %{waits: [wait]}}} = Wave4ChannelExample.view(fixture.host, scope)

    assert {:ok, before_reply} =
             CheckedCommand.resource(fixture.handles.input, scope, profile.conversation_id)

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "two-source-answer-superseded-reply",
        "input_id" => wait.correlation_id,
        "expected_revision" => before_reply.revision,
        "text" => "reply"
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    reply_item = Enum.find(pending, &(&1.destination == "wave4-channel-reply"))
    primary_item = Enum.find(pending, &(&1.destination == "wave4-channel-input"))
    reply_key = reply_item.idempotency_key
    reply_nonce = reply_item.nonce
    primary_key = primary_item.idempotency_key
    primary_nonce = primary_item.nonce

    assert {:reply_observed, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_reply, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, _native_result} =
             wait_public_result(
               :sys.get_state(fixture.host).engine,
               %{tenant: profile.tenant, principal: profile.actor, run_id: run_id},
               System.monotonic_time(:millisecond) + 10_000
             )

    assert {:result, :completed} = Wave4ChannelExample.advance(fixture.host)
    assert {:answered, _revision} = Wave4ChannelExample.advance(fixture.host)

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [answer_item] = Enum.filter(pending, &(&1.destination == "wave4-channel-delivery"))
    key = answer_item.idempotency_key
    nonce = answer_item.nonce
    other_nonce = :crypto.strong_rand_bytes(16)
    refute other_nonce == nonce

    # The answer is delivered, its acknowledgement rolls back in SQL, and
    # another nonce acknowledges the answer item's key.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :ack, key, :rollback)

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, _reason} = :sys.get_state(fixture.host).poison
    assert [{^key, phases}] = Elzoo.Wave4ChannelTest.ReadProbe.rollbacks(probe)
    assert {:ack, :before_commit} in phases
    assert {:committed, _} = Elzoo.Outbox.ack(fixture.command_store, key, other_nonce)
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)

    # After a fenced reopen the round replays its native work up to the
    # retained answer. Before the answer could move the round on to its
    # native acknowledgements, the answer's delivery acknowledgement is
    # verified by its original key and nonce, and the host stays fenced.
    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    probe = probe_host_command_store!(fixture)

    steps =
      Enum.reduce_while(1..14, [], fn _, steps ->
        step = Wave4ChannelExample.advance(fixture.host)
        steps = [step | steps]

        if match?({:blocked, _}, step),
          do: {:halt, Enum.reverse(steps)},
          else: {:cont, steps}
      end)

    assert List.last(steps) == {:blocked, :delivery_ack_superseded}
    refute Enum.any?(steps, &match?({:answered, _}, &1))
    assert {:delivery_ack, ^key, ^nonce, :superseded} = :sys.get_state(fixture.host).poison
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == []

    # Both native keys stay pending with their original nonces.
    assert {:ok, %{state: :pending, nonce: ^reply_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [reply_key])

    assert {:ok, %{state: :pending, nonce: ^primary_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [primary_key])
  end

  @tag timeout: 300_000
  test "a superseded reply-association delivery acknowledgement stays fenced across a fenced reopen" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    profile = fixture.profile
    scope = Elzoo.Wave4ChannelTestHelper.scope(profile)
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "reply-association-superseded"})
    primary_id = event["input_id"]

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)
    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Wave4ChannelExample.advance(fixture.host) end)
    assert {:ok, %{event_waits: %{waits: [wait]}}} = Wave4ChannelExample.view(fixture.host, scope)

    assert {:ok, before_reply} =
             CheckedCommand.resource(fixture.handles.input, scope, profile.conversation_id)

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "reply-association-superseded-reply",
        "input_id" => wait.correlation_id,
        "expected_revision" => before_reply.revision,
        "text" => "reply whose association acknowledgement is superseded"
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    reply_key = Enum.find(pending, &(&1.destination == "wave4-channel-reply")).idempotency_key
    assert {:reply_observed, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, _} = Wave4ChannelExample.advance(fixture.host)

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(pending, &(&1.destination == "wave4-channel-delivery"))
    key = item.idempotency_key
    nonce = item.nonce
    other_nonce = :crypto.strong_rand_bytes(16)
    refute other_nonce == nonce

    # The reply association is delivered, its acknowledgement rolls back, and
    # another nonce wins its key before any native reply input.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :ack, key, :rollback)
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, _reason} = :sys.get_state(fixture.host).poison
    assert {:committed, _} = Elzoo.Outbox.ack(fixture.command_store, key, other_nonce)
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)

    # Across a fenced reopen, recovery verifies the reply association's
    # delivery acknowledgement before the native reply input.
    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    trace_engine_input(fixture.host)
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, :superseded} = :sys.get_state(fixture.host).poison
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert %{current: nil, engine: nil} = :sys.get_state(fixture.host)
    assert take_engine_input_ids() == []
  end

  @tag timeout: 300_000
  test "an answer whose delivery key another nonce acknowledges before the next advance stays fenced",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    complete_native_v1!(fixture, listener, event)
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)

    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [answer_item] = Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))
    [primary_item] = Enum.filter(items, &(&1.destination == "wave4-channel-input"))
    key = answer_item.idempotency_key
    nonce = answer_item.nonce

    # The fresh answer's item is still pending: the host carries its original
    # key and nonce to the primary acknowledgement.
    assert %{phase: :ack, current: %{deliveries: %{answer: {^key, ^nonce}}}} =
             :sys.get_state(fixture.host)

    assert_superseded_answer_fenced!(fixture, key, nonce, [primary_item])
  end

  @tag timeout: 300_000
  test "a reconciled answer whose delivery key another nonce acknowledges before the next advance stays fenced",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    complete_native_v1!(fixture, listener, event)

    # The answer commits and its reply is lost: the next advance reconciles it
    # read-only, before any delivery pass, while its item is still pending.
    lose_next_command_reply!(fixture)
    assert {:unknown, :answer} = Wave4ChannelExample.advance(fixture.host)
    assert {:reconciled, :answer} = Wave4ChannelExample.advance(fixture.host)

    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [answer_item] = Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))
    [primary_item] = Enum.filter(items, &(&1.destination == "wave4-channel-input"))
    key = answer_item.idempotency_key
    nonce = answer_item.nonce

    assert %{phase: :ack, current: %{deliveries: %{answer: {^key, ^nonce}}}} =
             :sys.get_state(fixture.host)

    assert_superseded_answer_fenced!(fixture, key, nonce, [primary_item])
  end

  @tag timeout: 300_000
  test "a reconciled two-source answer whose delivery key another nonce acknowledges before the next advance stays fenced" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    {_event, wait} = await_reply_wait!(fixture, primary_listener, "reconciled-answer-superseded")
    post_reply!(fixture, reply_listener, wait, "reconciled-answer-superseded-reply")

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    native_items =
      Enum.filter(pending, &(&1.destination in ["wave4-channel-input", "wave4-channel-reply"]))

    assert length(native_items) == 2
    advance_to_answer(fixture.host, System.monotonic_time(:millisecond) + 30_000, [])

    # The answer commits and its reply is lost: the next advance reconciles it
    # read-only, before any delivery pass, while its item is still pending.
    lose_next_command_reply!(fixture)
    assert {:unknown, :answer} = Wave4ChannelExample.advance(fixture.host)
    assert {:reconciled, :answer} = Wave4ChannelExample.advance(fixture.host)

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [answer_item] = Enum.filter(pending, &(&1.destination == "wave4-channel-delivery"))
    key = answer_item.idempotency_key
    nonce = answer_item.nonce

    assert %{phase: :reply_ack, current: %{deliveries: %{answer: {^key, ^nonce}}}} =
             :sys.get_state(fixture.host)

    assert_superseded_answer_fenced!(fixture, key, nonce, native_items)
  end

  @tag timeout: 300_000
  test "a recovered answer whose pending delivery key another nonce acknowledges stays fenced",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    complete_native_v1!(fixture, listener, event)
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)

    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [answer_item] = Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))
    [primary_item] = Enum.filter(items, &(&1.destination == "wave4-channel-input"))
    key = answer_item.idempotency_key
    nonce = answer_item.nonce
    other_nonce = :crypto.strong_rand_bytes(16)
    refute other_nonce == nonce

    # The answer is delivered and its acknowledgement rolls back in SQL: the
    # item stays pending.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :ack, key, :rollback)
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, _reason} = :sys.get_state(fixture.host).poison
    {:ok, entries} = Elzoo.Wave4ChannelTestHelper.conversation_entries(fixture)
    assert Enum.count(entries, &(&1.kind == :answer)) == 1

    # After a fenced reopen the first delivery pass does not reach the item,
    # so recovery finds the answer delivered with its item still pending and
    # carries the item's original key and nonce.
    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [listener])
    probe = probe_host_command_store!(fixture)
    hide_from_window!(probe, key)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)

    assert %{phase: :ack, current: %{deliveries: %{answer: {^key, ^nonce}}}} =
             :sys.get_state(fixture.host)

    # Another nonce then acknowledges that key: the primary acknowledgement
    # waits for the original receipt, so the host stays fenced.
    Elzoo.Wave4ChannelTest.ReadProbe.reset(probe)
    assert {:committed, _} = Outbox.ack(fixture.command_store, key, other_nonce)
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, :superseded} = :sys.get_state(fixture.host).poison
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == []
    assert_native_items_pending!(fixture, [primary_item])
  end

  @tag timeout: 300_000
  test "a recovered association whose pending delivery key another nonce acknowledges stays fenced before the primary acknowledgement",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))
    [primary_item] = Enum.filter(items, &(&1.destination == "wave4-channel-input"))
    key = item.idempotency_key
    nonce = item.nonce
    other_nonce = :crypto.strong_rand_bytes(16)
    refute other_nonce == nonce

    # The association is delivered and its acknowledgement rolls back in SQL.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :ack, key, :rollback)
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, _reason} = :sys.get_state(fixture.host).poison

    # Recovery finds the association delivered with its item still pending
    # (the reopen's first delivery pass does not reach it) and carries the
    # item's original key and nonce through the round.
    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [listener])
    probe = probe_host_command_store!(fixture)
    hide_from_window!(probe, key)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)

    assert %{phase: :create_run, current: %{deliveries: %{association: {^key, ^nonce}}}} =
             :sys.get_state(fixture.host)

    # Another nonce acknowledges that key. The round runs its native work
    # and answers; before the primary acknowledgement the association's
    # original receipt is required, so the host stays fenced.
    Elzoo.Wave4ChannelTest.ReadProbe.reset(probe)
    assert {:committed, _} = Outbox.ack(fixture.command_store, key, other_nonce)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, :superseded} = :sys.get_state(fixture.host).poison
    assert_native_items_pending!(fixture, [primary_item])
  end

  @tag timeout: 300_000
  test "a recovered reply association whose pending delivery key another nonce acknowledges stays fenced before the reply acknowledgement" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    profile = fixture.profile
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    {event, wait} = await_reply_wait!(fixture, primary_listener, "recovered-reply-association")
    primary_id = event["input_id"]
    post_reply!(fixture, reply_listener, wait, "recovered-reply-association-reply")

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    native_items =
      Enum.filter(pending, &(&1.destination in ["wave4-channel-input", "wave4-channel-reply"]))

    reply_key = Enum.find(native_items, &(&1.destination == "wave4-channel-reply")).idempotency_key
    assert {:reply_observed, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, _} = Wave4ChannelExample.advance(fixture.host)

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(pending, &(&1.destination == "wave4-channel-delivery"))
    key = item.idempotency_key
    nonce = item.nonce
    other_nonce = :crypto.strong_rand_bytes(16)
    refute other_nonce == nonce

    # The primary association's item, second in the stream, was acknowledged
    # with its original nonce.
    association_key =
      Elzoo.DurableLog.Codec.item_key(
        Elzoo.Wave4ChannelTestHelper.command_stream(profile.tenant),
        2,
        1
      )

    assert {:ok,
            %{
              state: :acked,
              destination: "wave4-channel-delivery",
              nonce: association_nonce,
              ack_nonce: association_nonce,
              payload: association_payload
            }} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [association_key])

    assert Jason.decode!(association_payload)["operation_id"] ==
             Elzoo.Wave4ChannelTestHelper.association_operation(
               profile,
               event["event_id"],
               primary_id
             )

    # The reply association is delivered and its acknowledgement rolls back.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :ack, key, :rollback)
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, _reason} = :sys.get_state(fixture.host).poison

    # After a fenced reopen the first delivery pass does not reach the reply
    # association's item: recovery carries both associations' receipts, the
    # primary one acknowledged and the reply one still pending.
    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    probe = probe_host_command_store!(fixture)
    hide_from_window!(probe, key)
    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
    assert %{current: %{deliveries: deliveries}} = :sys.get_state(fixture.host)

    assert deliveries == %{
             association: {association_key, association_nonce},
             reply_association: {key, nonce}
           }

    # Another nonce acknowledges the reply association's key. The round
    # replays to its answer; before the reply acknowledgement the original
    # receipt is required, so the host stays fenced.
    Elzoo.Wave4ChannelTest.ReadProbe.reset(probe)
    assert {:committed, _} = Outbox.ack(fixture.command_store, key, other_nonce)
    advance_to_answer(fixture.host, System.monotonic_time(:millisecond) + 30_000, [])
    assert {:answered, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, :superseded} = :sys.get_state(fixture.host).poison
    assert_native_items_pending!(fixture, native_items)
  end

  @tag timeout: 300_000
  test "recovery scans past another profile's acknowledged reply row to the association's delivery item",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))
    key = item.idempotency_key
    nonce = item.nonce

    # A reply-profile writer of this tenant's stream commits a reply input for
    # another conversation above the association's item and acknowledges it:
    # the row is invisible to the pending window, and this immediate profile's
    # PostgreSQL Store, whose destinations exclude replies, reads it as
    # malformed.
    {foreign_key, reply_store} = commit_foreign_reply_row!(fixture)

    assert {:ok, %{state: :acked}} =
             Elzoo.DurableLog.Store.read(reply_store, :read_ack, [foreign_key])

    assert {:error, :malformed} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [foreign_key])

    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, %{state: :acked, ack_nonce: ^nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [key])

    # Across a fenced reopen recovery rebuilds the association's delivery
    # identity from the stream head down. While the association's own slot
    # cannot be read as this profile's either, no exact match exists and the
    # host stays fenced; then the scan passes the foreign row and finds it.
    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [listener])
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :read_ack, key, :malformed)
    assert {:unknown, :recovery} = Wave4ChannelExample.advance(fixture.host)
    assert {:v2_recovery, :delivery_ack} = :sys.get_state(fixture.host).poison
    assert Elzoo.Wave4ChannelTest.ReadProbe.faults(probe) == %{}
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)

    assert %{poison: nil, phase: :create_run, current: %{deliveries: deliveries}} =
             :sys.get_state(fixture.host)

    assert deliveries == %{association: {key, nonce}}
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == []
  end

  @tag timeout: 300_000
  test "a reply observation fences on another conversation's pending reply item as on main, and recovery adopts the reply once it drains" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    {event, wait} = await_reply_wait!(fixture, primary_listener, "foreign-reply-observation")
    primary_id = event["input_id"]
    post_reply!(fixture, reply_listener, wait, "foreign-reply-observation-reply")

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [reply_item] = Enum.filter(pending, &(&1.destination == "wave4-channel-reply"))
    reply_key = reply_item.idempotency_key

    # After this reply's admission another conversation of the tenant commits
    # a reply input: two reply items share the outbox window, and by main's
    # rule the round cannot prove which one is its own.
    seed_foreign_reply_notifications!(fixture, 1, "observation-foreign")
    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert [^reply_item, foreign] = Enum.filter(pending, &(&1.destination == "wave4-channel-reply"))

    # As on main the observation fences, and the fence holds: no item is
    # adopted and the reply is not associated.
    assert {:blocked, :reply_observation} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_observation, :unproven} = :sys.get_state(fixture.host).poison
    assert {:blocked, :reply_observation} = Wave4ChannelExample.advance(fixture.host)
    assert %{reply: %{item: nil}} = :sys.get_state(fixture.host)

    # After a fenced reopen recovery retries, read-only, while the other
    # conversation's reply item is pending; once it drains, recovery adopts
    # this round's reply item and the round completes.
    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    assert {:unknown, :recovery} = Wave4ChannelExample.advance(fixture.host)
    assert {:v2_recovery, :metadata} = :sys.get_state(fixture.host).poison

    assert {:committed, _} =
             Outbox.ack(fixture.command_store, foreign.idempotency_key, foreign.nonce)

    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
    assert %{reply: %{item: %{idempotency_key: ^reply_key}}} = :sys.get_state(fixture.host)
    advance_to_answer(fixture.host, System.monotonic_time(:millisecond) + 30_000, [])
    assert {:answered, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_acknowledged, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
  end

  @tag timeout: 300_000
  test "v2 recovery waits on another conversation's pending reply item, and the restored Run's expiry ends in main's reply ambiguity fence" do
    {:ok, clock_state} = Agent.start_link(fn -> System.system_time(:millisecond) end)
    on_exit(fn -> if Process.alive?(clock_state), do: Agent.stop(clock_state) end)
    clock = fn -> Agent.get(clock_state, & &1) end
    deadline = clock.() + 120_000
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture(clock: clock, deadline_ms: deadline)
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    {event, _wait} = await_reply_wait!(fixture, primary_listener, "foreign-reply-recovery")
    primary_id = event["input_id"]
    wait = :sys.get_state(fixture.host).native_wait

    # Another conversation of the tenant commits a reply input after this
    # round's wait: its reply item shares the window, and its sequence lies
    # between the wait's cursor and the tenant head.
    seed_foreign_reply_notifications!(fixture, 1, "recovery-foreign")
    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert [foreign] = Enum.filter(pending, &(&1.destination == "wave4-channel-reply"))
    assert {:ok, %{revision: head}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert head == wait.cursor + 1

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    # As on main, recovery adopts no reply item it has not proven its own: it
    # retries, read-only, while the other conversation's reply item is pending.
    assert {:unknown, :recovery} = Wave4ChannelExample.advance(fixture.host)
    assert {:v2_recovery, :metadata} = :sys.get_state(fixture.host).poison
    assert {:unknown, :recovery} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, %{state: :pending}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
               foreign.idempotency_key
             ])

    # Once it drains, the round is restored without a reply and waits again.
    # The foreign sequence past the saved cursor leaves the reply cursor
    # ambiguous, as on main.
    assert {:committed, _} =
             Outbox.ack(fixture.command_store, foreign.idempotency_key, foreign.nonce)

    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
    assert %{reply: nil} = :sys.get_state(fixture.host)
    Enum.each(1..10, fn _ -> Wave4ChannelExample.advance(fixture.host) end)
    restored = :sys.get_state(fixture.host)
    assert restored.native_wait.status == :waiting
    assert restored.native_wait.cursor == wait.cursor
    assert restored.ambiguous_reply == true

    # The restored Run's expiry keeps main's fence: recovery restored no reply
    # of this round and the head moved past the saved cursor, so no expiry
    # wake is sent and the fence holds. This fence is the defined behaviour
    # until the reply cursor rule changes.
    Agent.update(clock_state, fn _ -> deadline + 1 end)
    assert {:blocked, :reply_ambiguous} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_ambiguity, :expiry} = :sys.get_state(fixture.host).poison
    assert {:blocked, :reply_ambiguity} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_ambiguity, :expiry} = :sys.get_state(fixture.host).poison
  end

  @tag timeout: 300_000
  test "an association whose delivery key another nonce acknowledges before delivery keeps a cancelled round fenced",
       %{fixture: fixture} do
    token = make_ref()
    fixture = host_with_native_hash_barrier(fixture, self(), token)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    attempt_id = Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))
    [primary_item] = Enum.filter(items, &(&1.destination == "wave4-channel-input"))
    key = item.idempotency_key
    nonce = item.nonce
    other_nonce = :crypto.strong_rand_bytes(16)
    refute other_nonce == nonce

    # The fresh association's delivery receipt is carried in the round's
    # custody.
    assert %{current: %{deliveries: %{association: {^key, ^nonce}}}} =
             :sys.get_state(fixture.host)

    # Another nonce acknowledges the association's key before any delivery
    # pass: no pass sees the item again, and no association row is appended.
    assert {:committed, _} = Outbox.ack(fixture.command_store, key, other_nonce)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, ^attempt_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)
    assert_receive {:wave4_native_hash_blocked, task_pid, ^token, _result}, 5_000

    # The immediate round is cancelled: it has no answer, so its association
    # is the only delivery-only item that its primary acknowledgement relies
    # on, and the host stays fenced before that acknowledgement.
    assert {:ok, run} = RunApprovalRelease.status(fixture.owner, run_id)

    assert {:ok, _, :cancelled} =
             RunApprovalRelease.command(fixture.owner, %{
               kind: :cancel,
               run_id: run_id,
               attempt_id: attempt_id,
               expected_revision: run.revision
             })

    assert {:terminal, :cancelled} = Wave4ChannelExample.advance(fixture.host)
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, :superseded} = :sys.get_state(fixture.host).poison
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert_native_items_pending!(fixture, [primary_item])
    {:ok, entries} = Elzoo.Wave4ChannelTestHelper.conversation_entries(fixture)
    refute Enum.any?(entries, &(&1.kind == :association))
    send(task_pid, {:release_wave4_native_hash, token})
  end

  @tag timeout: 300_000
  test "an answer acknowledged by a competing caller with its original nonce before any assistant row releases no native custody until a fenced reopen appends it once" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    {event, wait} = await_reply_wait!(fixture, primary_listener, "competing-answer-ack")
    primary_id = event["input_id"]
    post_reply!(fixture, reply_listener, wait, "competing-answer-ack-reply")

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    native_items =
      Enum.filter(pending, &(&1.destination in ["wave4-channel-input", "wave4-channel-reply"]))

    assert length(native_items) == 2
    advance_to_answer(fixture.host, System.monotonic_time(:millisecond) + 30_000, [])
    assert {:answered, _} = Wave4ChannelExample.advance(fixture.host)

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [answer_item] = Enum.filter(pending, &(&1.destination == "wave4-channel-delivery"))
    key = answer_item.idempotency_key
    nonce = answer_item.nonce

    assert %{phase: :reply_ack, current: %{deliveries: %{answer: {^key, ^nonce}}}} =
             :sys.get_state(fixture.host)

    # A competing caller reads the answer item and acknowledges it with its
    # original nonce before any assistant row exists: the acknowledgement
    # matches the item's original receipt, yet nothing was appended.
    {:ok, entries_before} = Elzoo.Wave4ChannelTestHelper.conversation_entries(fixture)
    refute Enum.any?(entries_before, &(&1.kind == :answer))
    assert {:committed, _} = Outbox.ack(fixture.command_store, key, nonce)
    probe = probe_host_command_store!(fixture)

    # The live host never reads the missing row as final: this lifetime's
    # own append, or the acknowledging caller's, may still commit. Each
    # advance rereads the original receipt and the row and writes nothing,
    # and neither native item is acknowledged.
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :delivery_record} = :sys.get_state(fixture.host).poison
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :delivery_record} = :sys.get_state(fixture.host).poison
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == []
    assert {:ok, ^entries_before} = Elzoo.Wave4ChannelTestHelper.conversation_entries(fixture)
    assert_native_items_pending!(fixture, native_items)

    # A fenced reopen ends every earlier writer, so the row's absence is
    # definite: the restored round appends the retained intent once, before
    # its first native acknowledgement, and completes.
    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
    advance_to_answer(fixture.host, System.monotonic_time(:millisecond) + 30_000, [])
    assert {:answered, _} = Wave4ChannelExample.advance(fixture.host)
    [reply_item] = Enum.filter(native_items, &(&1.destination == "wave4-channel-reply"))
    reply_key = reply_item.idempotency_key
    assert {:reply_acknowledged, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
    answer_message_id = Elzoo.Wave4ChannelTestHelper.answer_id(primary_id)
    {:ok, entries} = Elzoo.Wave4ChannelTestHelper.conversation_entries(fixture)

    assert [%{message_id: ^answer_message_id, input_message_id: ^primary_id}] =
             Enum.filter(entries, &(&1.kind == :answer))
  end

  @tag timeout: 300_000
  test "an answer acknowledged by a competing caller whose Conversation row names another actor keeps native custody, live and after a fenced reopen",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)
    complete_native_v1!(fixture, listener, event)
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [answer_item] = Enum.filter(pending, &(&1.destination == "wave4-channel-delivery"))
    [primary_item] = Enum.filter(pending, &(&1.destination == "wave4-channel-input"))
    key = answer_item.idempotency_key
    text = :sys.get_state(fixture.host).current.answer

    # A competing caller appends an answer with this answer's ID, text, Run
    # and input under another actor, then acknowledges the answer item with
    # its original nonce.
    assert {:ok, _} =
             Elzoo.Conversation.append_answer(
               Elzoo.Wave4ChannelTestHelper.conversation_owner(fixture),
               %{
                 message_id: Elzoo.Wave4ChannelTestHelper.answer_id(input_id),
                 actor: "competing-actor",
                 text: text,
                 run_id: run_id,
                 input_message_id: input_id,
                 completed: true
               }
             )

    assert {:committed, _} = Outbox.ack(fixture.command_store, key, answer_item.nonce)
    probe = probe_host_command_store!(fixture)

    # The row is compared with the intent the answer command retained: the
    # other actor is the Conversation's own refusal, a defined fence, and no
    # native item is acknowledged.
    assert {:blocked, {:delivery_refused, "duplicate_message_id"}} =
             Wave4ChannelExample.advance(fixture.host)

    assert {:delivery_refused, ^key, "duplicate_message_id"} =
             :sys.get_state(fixture.host).poison

    assert {:blocked, {:delivery_refused, "duplicate_message_id"}} =
             Wave4ChannelExample.advance(fixture.host)

    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == []
    assert_native_items_pending!(fixture, [primary_item])

    # After a fenced reopen the restored round takes its answer from the same
    # retained intent, never from that row, and stays fenced.
    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert %{current: %{answer: ^text}} = :sys.get_state(fixture.host)

    assert {:blocked, {:delivery_refused, "duplicate_message_id"}} =
             Wave4ChannelExample.advance(fixture.host)

    assert {:delivery_refused, ^key, "duplicate_message_id"} =
             :sys.get_state(fixture.host).poison

    assert_native_items_pending!(fixture, [primary_item])
    {:ok, entries} = Elzoo.Wave4ChannelTestHelper.conversation_entries(fixture)
    assert [%{actor: "competing-actor"}] = Enum.filter(entries, &(&1.kind == :answer))
  end

  @tag timeout: 300_000
  test "a live host rereads a delayed answer append that commits after a competing acknowledgement and proceeds without a second write",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    complete_native_v1!(fixture, listener, event)
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [answer_item] = Enum.filter(pending, &(&1.destination == "wave4-channel-delivery"))
    [primary_item] = Enum.filter(pending, &(&1.destination == "wave4-channel-input"))
    key = answer_item.idempotency_key

    # This lifetime's delivery pass appends the answer, and the append pauses
    # after its head compare-and-set: its outcome is unknown.
    token = make_ref()

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.conversation_store, :inject, [
               :append,
               {:pause, token}
             ])

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery, ^key, :unresolved} = :sys.get_state(fixture.host).poison
    {:ok, head_before} = Elzoo.Wave4ChannelTestHelper.conversation_head(fixture)

    # A competing caller acknowledges the answer item with its original
    # nonce while that append is in flight: no delivery pass sees it again.
    assert {:committed, _} = Outbox.ack(fixture.command_store, key, answer_item.nonce)

    # The live host never reads the missing row as final: each advance
    # rereads the original receipt and the row, and writes nothing.
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :delivery_record} = :sys.get_state(fixture.host).poison
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :delivery_record} = :sys.get_state(fixture.host).poison
    assert {:ok, ^head_before} = Elzoo.Wave4ChannelTestHelper.conversation_head(fixture)
    assert_native_items_pending!(fixture, [primary_item])

    # The delayed append commits: the next advance proves that row and
    # completes the round, which holds exactly one answer.
    refute Elzoo.DurableLog.PostgresHarness.hook(fixture.conversation_store, :release, [token]) ==
             {:error, :absent}

    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    {:ok, entries} = Elzoo.Wave4ChannelTestHelper.conversation_entries(fixture)
    assert [%{input_message_id: ^input_id}] = Enum.filter(entries, &(&1.kind == :answer))
  end

  @tag timeout: 300_000
  test "after a fenced reopen a restored round never resends an answer its own delivery pass dispatched",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    complete_native_v1!(fixture, listener, event)
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [answer_item] = Enum.filter(pending, &(&1.destination == "wave4-channel-delivery"))
    [primary_item] = Enum.filter(pending, &(&1.destination == "wave4-channel-input"))
    key = answer_item.idempotency_key
    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)

    # The reopened host's delivery pass appends the still pending answer, and
    # the append pauses: this lifetime's own outcome is unknown.
    token = make_ref()

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.conversation_store, :inject, [
               :append,
               {:pause, token}
             ])

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery, ^key, :unresolved} = :sys.get_state(fixture.host).poison
    {:ok, head_before} = Elzoo.Wave4ChannelTestHelper.conversation_head(fixture)
    assert {:committed, _} = Outbox.ack(fixture.command_store, key, answer_item.nonce)

    # The round is restored, yet its answer's absence is not definite: this
    # lifetime dispatched that append, so each advance only rereads.
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :delivery_record} = :sys.get_state(fixture.host).poison
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :delivery_record} = :sys.get_state(fixture.host).poison
    assert {:ok, ^head_before} = Elzoo.Wave4ChannelTestHelper.conversation_head(fixture)
    assert_native_items_pending!(fixture, [primary_item])

    refute Elzoo.DurableLog.PostgresHarness.hook(fixture.conversation_store, :release, [token]) ==
             {:error, :absent}

    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    {:ok, entries} = Elzoo.Wave4ChannelTestHelper.conversation_entries(fixture)
    assert [%{input_message_id: ^input_id}] = Enum.filter(entries, &(&1.kind == :answer))
  end

  @tag timeout: 300_000
  test "a v1 answer acknowledged by a competing caller before any row is reread live, then appended once after a fenced reopen",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)
    complete_native_v1!(fixture, listener, event)
    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    text = :sys.get_state(fixture.host).current.answer

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [answer_item] = Enum.filter(pending, &(&1.destination == "wave4-channel-delivery"))
    [primary_item] = Enum.filter(pending, &(&1.destination == "wave4-channel-input"))
    key = answer_item.idempotency_key
    {:ok, entries_before} = Elzoo.Wave4ChannelTestHelper.conversation_entries(fixture)
    assert {:committed, _} = Outbox.ack(fixture.command_store, key, answer_item.nonce)

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :delivery_record} = :sys.get_state(fixture.host).poison
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, ^entries_before} = Elzoo.Wave4ChannelTestHelper.conversation_entries(fixture)
    assert_native_items_pending!(fixture, [primary_item])

    # After a fenced reopen the restored round rebuilds its answer from the
    # retained intent, not from the missing row, and appends that intent once
    # before its native acknowledgement.
    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    {:ok, entries} = Elzoo.Wave4ChannelTestHelper.conversation_entries(fixture)

    assert [%{text: ^text, run_id: ^run_id, input_message_id: ^input_id}] =
             Enum.filter(entries, &(&1.kind == :answer))
  end

  @tag timeout: 300_000
  test "an association acknowledged by a competing caller whose row names another Run keeps a cancelled round fenced",
       %{fixture: fixture} do
    token = make_ref()
    fixture = host_with_native_hash_barrier(fixture, self(), token)
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)
    attempt_id = Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))
    [primary_item] = Enum.filter(items, &(&1.destination == "wave4-channel-input"))
    key = item.idempotency_key

    # A competing caller associates the input with another Run, then
    # acknowledges the association item with its original nonce before any
    # delivery pass sees it.
    assert {:ok, _} =
             Elzoo.Conversation.associate_run(
               Elzoo.Wave4ChannelTestHelper.conversation_owner(fixture),
               %{input_message_id: input_id, run_id: "competing-run"}
             )

    assert {:committed, _} = Outbox.ack(fixture.command_store, key, item.nonce)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, ^attempt_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)
    assert_receive {:wave4_native_hash_blocked, task_pid, ^token, _result}, 5_000
    assert {:ok, run} = RunApprovalRelease.status(fixture.owner, run_id)

    assert {:ok, _, :cancelled} =
             RunApprovalRelease.command(fixture.owner, %{
               kind: :cancel,
               run_id: run_id,
               attempt_id: attempt_id,
               expected_revision: run.revision
             })

    # The row is compared with the association's retained intent: another
    # Run is the Conversation's own refusal, a defined fence before the
    # primary acknowledgement.
    assert {:terminal, :cancelled} = Wave4ChannelExample.advance(fixture.host)

    assert {:blocked, {:delivery_refused, "already_associated"}} =
             Wave4ChannelExample.advance(fixture.host)

    assert {:delivery_refused, ^key, "already_associated"} = :sys.get_state(fixture.host).poison

    assert {:blocked, {:delivery_refused, "already_associated"}} =
             Wave4ChannelExample.advance(fixture.host)

    assert_native_items_pending!(fixture, [primary_item])
    send(task_pid, {:release_wave4_native_hash, token})
  end

  @tag timeout: 300_000
  test "after the backlog drains one unavailable resource read keeps the recovery retry state, and recovery completes" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    {event, wait} = await_reply_wait!(fixture, primary_listener, "resource-read-retry")
    primary_id = event["input_id"]
    foreign = seed_foreign_inputs!(fixture, 63, "resource-read-foreign")
    commit_reply_input!(fixture, wait, "resource-read-reply-input")

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    assert {:unknown, :recovery} = Wave4ChannelExample.advance(fixture.host)
    assert {:v2_recovery, :metadata} = :sys.get_state(fixture.host).poison

    Enum.each(foreign, fn item ->
      assert {:committed, _} = Outbox.ack(fixture.command_store, item.idempotency_key, item.nonce)
    end)

    # The drained window shows the reply input: recovery delivers it, and
    # the observation's own window read fails, so the retry state stays.
    probe = probe_host_command_store!(fixture)

    Elzoo.Wave4ChannelTest.ReadProbe.transform(probe, :pending, fn
      _result, 2 -> {:error, :unavailable}
      result, _count -> result
    end)

    assert {:unknown, :recovery} = Wave4ChannelExample.advance(fixture.host)
    assert {:v2_recovery, :metadata} = :sys.get_state(fixture.host).poison
    {:ok, entries} = Elzoo.Wave4ChannelTestHelper.conversation_entries(fixture)
    assert Enum.any?(entries, &(&1.kind == :input and &1.message_id == wait.correlation_id))

    # With the reply visible and delivered, one unavailable resource read
    # keeps the recovery retry state, and the next advance recovers.
    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [
               :read,
               :unavailable
             ])

    assert {:unknown, :recovery} = Wave4ChannelExample.advance(fixture.host)
    assert {:v2_recovery, :metadata} = :sys.get_state(fixture.host).poison
    refute Map.has_key?(Agent.get(fixture.controller, & &1.faults), :read)
    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)

    assert %{reply: %{ticket: ticket, item: %{idempotency_key: reply_key}}} =
             :sys.get_state(fixture.host)

    assert ticket == wait.correlation_id
    advance_to_answer(fixture.host, System.monotonic_time(:millisecond) + 30_000, [])
    assert {:answered, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_acknowledged, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
  end

  @tag timeout: 300_000
  test "a reconciled association whose delivery receipt cannot be read retries that read alone",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)

    # The association commits and its reply is lost.
    lose_next_command_reply!(fixture)
    assert {:unknown, :association} = Wave4ChannelExample.advance(fixture.host)

    association_key =
      Elzoo.DurableLog.Codec.item_key(
        Elzoo.Wave4ChannelTestHelper.command_stream(fixture.profile.tenant),
        2,
        1
      )

    # Reconciliation confirms the committed association, and the lookup of
    # its delivery receipt cannot be read: only that lookup is retried, with
    # no reread of command history or of the Conversation.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :read_ack, association_key, :unavailable)
    assert {:unknown, :association_delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:association_delivery_receipt, :association, 2} = :sys.get_state(fixture.host).poison
    trace_checked_reads(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert take_checked_read_calls() == []

    assert %{current: %{deliveries: %{association: {^association_key, _nonce}}}} =
             :sys.get_state(fixture.host)

    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
  end

  @tag timeout: 300_000
  test "a reply association whose delivery receipt cannot be read retries that read alone" do
    {fixture, primary_id, reply_key, revision, association_key} =
      observed_reply_round!("reply-receipt-retry")

    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :read_ack, association_key, :unavailable)
    assert {:unknown, :association_delivery} = Wave4ChannelExample.advance(fixture.host)

    assert {:association_delivery_receipt, :reply_association, ^revision} =
             :sys.get_state(fixture.host).poison

    trace_checked_reads(fixture.host)
    assert {:reply_associated, ^revision} = Wave4ChannelExample.advance(fixture.host)
    assert take_checked_read_calls() == []
    complete_reply_round!(fixture, primary_id, reply_key)
  end

  @tag timeout: 300_000
  test "a reconciled reply association whose delivery receipt cannot be read retries that read alone" do
    {fixture, primary_id, reply_key, revision, association_key} =
      observed_reply_round!("reply-receipt-reconcile")

    lose_next_command_reply!(fixture)
    assert {:unknown, :reply_association} = Wave4ChannelExample.advance(fixture.host)
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :read_ack, association_key, :unavailable)
    assert {:unknown, :association_delivery} = Wave4ChannelExample.advance(fixture.host)

    assert {:association_delivery_receipt, :reply_association, ^revision} =
             :sys.get_state(fixture.host).poison

    trace_checked_reads(fixture.host)
    assert {:reply_associated, ^revision} = Wave4ChannelExample.advance(fixture.host)
    assert take_checked_read_calls() == []
    complete_reply_round!(fixture, primary_id, reply_key)
  end

  @tag timeout: 300_000
  test "a full v1 outbox window hiding this conversation's input keeps discovery retryable until the backlog drains",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    {:ok, [input_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    foreign = seed_foreign_inputs!(fixture, 64, "v1-window-foreign")

    # The window holds 64 delivery items of another conversation and hides
    # this conversation's input: discovery is retried, never fenced.
    probe = probe_host_command_store!(fixture)
    serve_window!(fixture, probe, [input_item.idempotency_key], &as_delivery_item/1)
    assert {:unknown, :input_observation} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :window} = :sys.get_state(fixture.host).poison
    assert {:unknown, :input_observation} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :window} = :sys.get_state(fixture.host).poison

    Elzoo.Wave4ChannelTest.ReadProbe.reset(probe)
    drain!(fixture, foreign)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
  end

  @tag timeout: 300_000
  test "a full v2 outbox window keeps discovery retryable, before the first round and after a completed pair" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "v2-window-primary"})
    primary_id = event["input_id"]

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)

    {:ok, [primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    foreign = seed_foreign_inputs!(fixture, 64, "v2-window-foreign")

    # Before any round the window holds 64 delivery items of another
    # conversation and hides the primary input: discovery is retried.
    probe = probe_host_command_store!(fixture)
    serve_window!(fixture, probe, [primary_item.idempotency_key], &as_delivery_item/1)
    assert {:unknown, :input_observation} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :window} = :sys.get_state(fixture.host).poison
    assert {:unknown, :input_observation} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :window} = :sys.get_state(fixture.host).poison

    Elzoo.Wave4ChannelTest.ReadProbe.reset(probe)
    drain!(fixture, foreign)
    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Wave4ChannelExample.advance(fixture.host) end)
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, %{event_waits: %{waits: [wait]}}} =
             Wave4ChannelExample.view(fixture.host, scope)

    post_reply!(fixture, reply_listener, wait, "v2-window-reply")
    assert {:reply_observed, reply_key} = Wave4ChannelExample.advance(fixture.host)
    complete_reply_round!(fixture, primary_id, reply_key)

    # After the completed pair the same window is retried too, and discovery
    # idles once it drains.
    more_foreign = seed_foreign_inputs!(fixture, 64, "v2-window-later")
    serve_window!(fixture, probe, [], &as_delivery_item/1)
    assert {:unknown, :input_observation} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :window} = :sys.get_state(fixture.host).poison
    Elzoo.Wave4ChannelTest.ReadProbe.reset(probe)
    drain!(fixture, more_foreign)
    assert {:idle, :no_input} = Wave4ChannelExample.advance(fixture.host)
  end

  @tag timeout: 300_000
  test "a full outbox window that shows no reply item keeps the reply observation retryable" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    {event, wait} = await_reply_wait!(fixture, primary_listener, "reply-window")
    primary_id = event["input_id"]
    post_reply!(fixture, reply_listener, wait, "reply-window-reply")
    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [reply_item] = Enum.filter(pending, &(&1.destination == "wave4-channel-reply"))
    reply_key = reply_item.idempotency_key
    foreign = seed_foreign_inputs!(fixture, 63, "reply-window-foreign")

    # The window shows the primary item and 63 inputs of another
    # conversation, and hides the reply item behind them: no proof of the
    # reply is not a fence while the window is full.
    probe = probe_host_command_store!(fixture)
    serve_window!(fixture, probe, [reply_key], & &1)
    assert {:blocked, :reply_observation} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_observation, :unavailable} = :sys.get_state(fixture.host).poison
    assert {:blocked, :reply_observation} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_observation, :unavailable} = :sys.get_state(fixture.host).poison

    Elzoo.Wave4ChannelTest.ReadProbe.reset(probe)
    drain!(fixture, foreign)
    assert {:reply_observed, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    complete_reply_round!(fixture, primary_id, reply_key)
  end

  @tag timeout: 300_000
  test "unavailable reads while a v1 round is observed are retried, live and after a fenced reopen",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)

    # The delivery pass appends the input; the observation's own window read
    # fails.
    probe = probe_host_command_store!(fixture)

    Elzoo.Wave4ChannelTest.ReadProbe.transform(probe, :pending, fn
      _result, 2 -> {:error, :unavailable}
      result, _count -> result
    end)

    assert {:unknown, :input_observation} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :read} = :sys.get_state(fixture.host).poison

    # The input command's retained result cannot be read.
    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [
               :read,
               :unavailable
             ])

    assert {:unknown, :input_observation} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :recovery} = :sys.get_state(fixture.host).poison

    # The input's Conversation row cannot be read.
    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.conversation_store, :inject, [
               :read,
               :unavailable
             ])

    assert {:unknown, :input_observation} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :recovery} = :sys.get_state(fixture.host).poison
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    # After a fenced reopen the restored round's association row cannot be
    # read: the observation is retried, never fenced.
    assert {:ok, fixture} = Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, listener)
    conversation_probe = probe_host_conversation_store!(fixture)

    Elzoo.Wave4ChannelTest.ReadProbe.transform(conversation_probe, :read, fn
      _result, 2 -> {:error, :unavailable}
      result, _count -> result
    end)

    assert {:unknown, :input_observation} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :recovery} = :sys.get_state(fixture.host).poison
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
  end

  @tag timeout: 300_000
  test "an unreadable reply association row keeps v2 recovery retrying instead of adopting an unassociated reply" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    {event, wait} = await_reply_wait!(fixture, primary_listener, "reply-row-read")
    primary_id = event["input_id"]
    post_reply!(fixture, reply_listener, wait, "reply-row-read-reply")
    assert {:reply_observed, reply_key} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    # Recovery reads the reply ticket's association row to prove the reply
    # is not associated yet; that read fails, so recovery retries.
    probe = probe_host_conversation_store!(fixture)

    Elzoo.Wave4ChannelTest.ReadProbe.transform(probe, :read, fn
      _result, 5 -> {:error, :unavailable}
      result, _count -> result
    end)

    assert {:unknown, :recovery} = Wave4ChannelExample.advance(fixture.host)
    assert {:v2_recovery, :metadata} = :sys.get_state(fixture.host).poison
    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)

    assert %{reply: %{association_revision: nil, item: %{idempotency_key: ^reply_key}}} =
             :sys.get_state(fixture.host)

    advance_to_answer(fixture.host, System.monotonic_time(:millisecond) + 30_000, [])
    assert {:answered, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_acknowledged, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
  end

  @tag timeout: 300_000
  test "an exception before the reply association's outcome is known reconciles read-only" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    {event, wait} = await_reply_wait!(fixture, primary_listener, "reply-association-exception")
    primary_id = event["input_id"]
    post_reply!(fixture, reply_listener, wait, "reply-association-exception-reply")
    assert {:reply_observed, reply_key} = Wave4ChannelExample.advance(fixture.host)

    %{reply: %{event: reply_event, association_operation: operation}} =
      :sys.get_state(fixture.host)

    :sys.replace_state(
      fixture.host,
      &put_in(&1, [:reply, :event], Map.delete(reply_event, :conversation_id))
    )

    assert {:unknown, :reply_association} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_association, ^operation, :exception} = :sys.get_state(fixture.host).poison
    :sys.replace_state(fixture.host, &put_in(&1, [:reply, :event], reply_event))
    assert {:reconciled, :not_observed} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, _} = Wave4ChannelExample.advance(fixture.host)
    complete_reply_round!(fixture, primary_id, reply_key)
  end

  @tag timeout: 300_000
  test "an unavailable native ownership check before the engine starts is retried" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "native-check-retry"})
    primary_id = event["input_id"]
    run_id = run_id_of(fixture, event)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)

    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)

    # The unit directory cannot answer: nothing starts, and the step is
    # retried.
    directory = :sys.get_state(fixture.host).native.directory
    {dead, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _}
    :sys.replace_state(fixture.host, &put_in(&1, [:native, :directory], dead))
    assert {:error, :unavailable} = Wave4ChannelExample.advance(fixture.host)
    assert :sys.get_state(fixture.host).poison == nil
    :sys.replace_state(fixture.host, &put_in(&1, [:native, :directory], directory))
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..7, fn _ -> Wave4ChannelExample.advance(fixture.host) end)
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, %{event_waits: %{waits: [wait]}}} =
             Wave4ChannelExample.view(fixture.host, scope)

    post_reply!(fixture, reply_listener, wait, "native-check-retry-reply")
    assert {:reply_observed, reply_key} = Wave4ChannelExample.advance(fixture.host)
    complete_reply_round!(fixture, primary_id, reply_key)
  end

  @tag timeout: 300_000
  test "an unavailable event-wait read after the native result completes is retried" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    {event, wait} = await_reply_wait!(fixture, primary_listener, "event-wait-retry")
    primary_id = event["input_id"]
    post_reply!(fixture, reply_listener, wait, "event-wait-retry-reply")
    assert {:reply_observed, reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_reply, :applied} = Wave4ChannelExample.advance(fixture.host)

    # The engine's event waits cannot be read once its result completes:
    # the result stays pending and nothing is fenced.
    engine = :sys.get_state(fixture.host).engine
    proxy = event_waits_unavailable_engine(engine)
    :sys.replace_state(fixture.host, &%{&1 | engine: proxy})
    await_result_unavailable!(fixture.host, System.monotonic_time(:millisecond) + 10_000)
    assert :sys.get_state(fixture.host).poison == nil
    :sys.replace_state(fixture.host, &%{&1 | engine: engine})
    assert {:result, :completed} = Wave4ChannelExample.advance(fixture.host)
    assert {:answered, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_acknowledged, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
  end

  @tag timeout: 300_000
  test "a reply association append still in flight after a competing acknowledgement keeps the answer preflight retryable" do
    {fixture, primary_id, reply_key, revision, association_key} =
      observed_reply_round!("preflight-in-flight")

    assert {:reply_associated, ^revision} = Wave4ChannelExample.advance(fixture.host)

    # The delivery pass appends the reply association, and the append pauses
    # after its head compare-and-set; a competing caller then acknowledges the
    # item with its original nonce.
    token = make_ref()

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.conversation_store, :inject, [
               :append,
               {:pause, token}
             ])

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery, ^association_key, :unresolved} = :sys.get_state(fixture.host).poison

    assert {:ok, %{nonce: nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [association_key])

    assert {:committed, _} = Outbox.ack(fixture.command_store, association_key, nonce)

    # The association row is absent while that append is in flight: the
    # preflight retries and nothing reaches native work.
    assert {:error, :unavailable} = Wave4ChannelExample.advance(fixture.host)
    assert :sys.get_state(fixture.host).poison == nil
    assert {:error, :unavailable} = Wave4ChannelExample.advance(fixture.host)

    refute Elzoo.DurableLog.PostgresHarness.hook(fixture.conversation_store, :release, [token]) ==
             {:error, :absent}

    assert {:native_reply, :applied} = Wave4ChannelExample.advance(fixture.host)
    complete_reply_round!(fixture, primary_id, reply_key)
  end

  @tag timeout: 300_000
  test "a full outbox window never reads as no reply, and recovery adopts its own reply once the backlog drains" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    {event, wait} = await_reply_wait!(fixture, primary_listener, "full-window-reply")
    primary_id = event["input_id"]

    # Another conversation of the tenant commits 63 inputs: with this round's
    # primary item they fill the 64-item outbox window.
    foreign = seed_foreign_inputs!(fixture, 63, "full-window-foreign")
    assert length(foreign) == 63
    {:ok, window} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert length(window) == 64

    # This round's reply input commits behind them as item 65, as one
    # admitted by an earlier lifetime would: the full window does not show it.
    commit_reply_input!(fixture, wait, "full-window-reply-input")
    {:ok, window} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    refute Enum.any?(window, &(&1.destination == "wave4-channel-reply"))

    # After a fenced reopen recovery never reads the full window as "no
    # reply": discovery stays retryable while the window shows no proof.
    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    assert {:unknown, :recovery} = Wave4ChannelExample.advance(fixture.host)
    assert {:v2_recovery, :metadata} = :sys.get_state(fixture.host).poison
    assert {:unknown, :recovery} = Wave4ChannelExample.advance(fixture.host)
    assert %{current: nil, reply: nil} = :sys.get_state(fixture.host)

    # The other conversation's backlog drains: the next discovery delivers
    # this round's reply input, adopts its own reply item, and the round
    # completes.
    Enum.each(foreign, fn item ->
      assert {:committed, _} = Outbox.ack(fixture.command_store, item.idempotency_key, item.nonce)
    end)

    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)

    assert %{reply: %{ticket: ticket, item: %{idempotency_key: reply_key}}} =
             :sys.get_state(fixture.host)

    assert ticket == wait.correlation_id
    advance_to_answer(fixture.host, System.monotonic_time(:millisecond) + 30_000, [])
    assert {:answered, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_acknowledged, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
  end

  @tag timeout: 300_000
  test "a digest-valid notice whose identity is malformed is never classified as foreign",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    # Another conversation of the tenant commits an input behind this round's
    # association, and its notice is served with `actor: null` under a digest
    # recomputed over it.
    [foreign] = seed_foreign_inputs!(fixture, 1, "malformed-identity")
    foreign_key = foreign.idempotency_key
    probe = probe_host_command_store!(fixture)

    Elzoo.Wave4ChannelTest.ReadProbe.transform(probe, :pending, fn
      {:ok, items}, _count ->
        {:ok,
         Enum.map(items, fn item ->
           if item.idempotency_key == foreign_key do
             notice = item.payload |> Jason.decode!() |> Map.put("actor", nil)
             Elzoo.Wave4ChannelTest.ReadProbe.rewrite_item(item, Jason.encode!(notice))
           else
             item
           end
         end)}

      other, _count ->
        other
    end)

    # The delivery pass cannot classify the item, so it stops there and stays
    # fenced: nothing later runs.
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery, ^foreign_key, :notice} = :sys.get_state(fixture.host).poison
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery, ^foreign_key, :notice} = :sys.get_state(fixture.host).poison
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
  end

  @tag timeout: 300_000
  test "an unreadable association delivery receipt after the association commits retries that read alone",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)

    association_key =
      Elzoo.DurableLog.Codec.item_key(
        Elzoo.Wave4ChannelTestHelper.command_stream(fixture.profile.tenant),
        2,
        1
      )

    # The association commits; the lookup of its delivery item's original
    # key and nonce cannot be read.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :read_ack, association_key, :unavailable)
    assert {:unknown, :association_delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:association_delivery_receipt, :association, 2} = :sys.get_state(fixture.host).poison
    assert {:ok, %{revision: 2}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    # Write-time policy and authority become unavailable: the retry reads the
    # receipt alone and never executes the committed association again.
    parent = self()
    original = Map.take(:sys.get_state(fixture.host), [:policy, :authority])

    :sys.replace_state(fixture.host, fn state ->
      %{
        state
        | policy: fn _mode, _event, _now ->
            send(parent, :policy_called)
            raise "policy unavailable"
          end,
          authority: fn _a, _b, _c, _d ->
            send(parent, :authority_called)
            raise "authority unavailable"
          end
      }
    end)

    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    refute_received :policy_called
    refute_received :authority_called
    assert {:ok, %{revision: 2}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert %{current: %{deliveries: %{association: {^association_key, _nonce}}}} =
             :sys.get_state(fixture.host)

    # The round completes once write-time policy and authority return.
    :sys.replace_state(fixture.host, &Map.merge(&1, original))
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)

    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
  end

  @tag timeout: 300_000
  test "a window read failure after an unsent delivery acknowledgement is sent repeats discovery without a second acknowledgement",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))
    key = item.idempotency_key
    nonce = item.nonce

    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :read_ack, key, :unavailable)
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack_unsent, ^key, ^nonce, :unavailable} = :sys.get_state(fixture.host).poison
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == []

    # The retry sends the first acknowledgement; the window read after it
    # fails once. The host keeps a read-only resume state.
    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [
               :pending,
               :unavailable
             ])

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :pending) == nil
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == [key]

    assert {:ok, %{state: :acked, ack_nonce: ^nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [key])

    assert {:rediscover, :read} = :sys.get_state(fixture.host).poison
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)

    # Storage recovers: the next advance repeats discovery and the round goes
    # on; the acknowledgement is never sent again.
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == [key]
  end

  @tag timeout: 300_000
  test "a window read failure after a delivery acknowledgement is confirmed repeats discovery without another acknowledgement",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)

    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))
    key = item.idempotency_key
    nonce = item.nonce

    # The association item's acknowledgement commits with its reply lost, and
    # the same-pass readback fails: only read-only confirmation may follow.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :ack, key, :reply_loss)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :read_ack, key, [:pass, :unavailable])
    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, _reason} = :sys.get_state(fixture.host).poison
    Elzoo.Wave4ChannelTest.ReadProbe.reset(probe)

    # The next advance confirms it by its original receipt; the window read
    # that follows fails once, and the host keeps a read-only resume state.
    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [
               :pending,
               :unavailable
             ])

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :read} = :sys.get_state(fixture.host).poison
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)

    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == []

    assert {:ok, %{state: :acked, ack_nonce: ^nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [key])
  end

  @tag timeout: 300_000
  test "an unreadable outbox window at observation is observed again on the next advance",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)

    # The delivery pass reads the window; the observation's own read fails.
    probe = probe_host_command_store!(fixture)

    Elzoo.Wave4ChannelTest.ReadProbe.transform(probe, :pending, fn result, count ->
      if count == 2, do: {:error, :unavailable}, else: result
    end)

    assert {:unknown, :input_observation} = Wave4ChannelExample.advance(fixture.host)
    assert {:rediscover, :read} = :sys.get_state(fixture.host).poison
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert %{poison: nil, phase: :association} = :sys.get_state(fixture.host)
  end

  @tag timeout: 300_000
  test "a reply observation whose window read fails is repeated on the next advance" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    {_event, wait} = await_reply_wait!(fixture, primary_listener, "reply-observation-read")
    post_reply!(fixture, reply_listener, wait, "reply-observation-read-reply")

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [reply_item] = Enum.filter(pending, &(&1.destination == "wave4-channel-reply"))
    reply_key = reply_item.idempotency_key

    # After the reply input's committed write the observation's own window
    # read fails once: the round keeps its resume point and observes again.
    probe = probe_host_command_store!(fixture)

    Elzoo.Wave4ChannelTest.ReadProbe.transform(probe, :pending, fn result, count ->
      if count == 2, do: {:error, :unavailable}, else: result
    end)

    assert {:blocked, :reply_observation} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_observation, :unavailable} = :sys.get_state(fixture.host).poison
    assert {:reply_observed, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == []
  end

  @tag timeout: 300_000
  test "an unreadable answer delivery receipt after the answer commits retries that read alone",
       %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]
    complete_native_v1!(fixture, listener, event)

    answer_key =
      Elzoo.DurableLog.Codec.item_key(
        Elzoo.Wave4ChannelTestHelper.command_stream(fixture.profile.tenant),
        3,
        1
      )

    # The answer commits; the lookup of its delivery item's original key and
    # nonce cannot be read.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :read_ack, answer_key, :unavailable)
    assert {:unknown, :answer_delivery} = Wave4ChannelExample.advance(fixture.host)
    assert {:answer_delivery_receipt, 3} = :sys.get_state(fixture.host).poison
    assert {:ok, %{revision: 3}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    # Write-time policy and authority become unavailable: the retry reads the
    # receipt alone and never executes the committed answer again.
    parent = self()

    :sys.replace_state(fixture.host, fn state ->
      %{
        state
        | policy: fn _mode, _event, _now ->
            send(parent, :policy_called)
            raise "policy unavailable"
          end,
          authority: fn _a, _b, _c, _d ->
            send(parent, :authority_called)
            raise "authority unavailable"
          end
      }
    end)

    assert {:answered, 3} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, %{revision: 3}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    {:ok, items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert [%{idempotency_key: ^answer_key}] =
             Enum.filter(items, &(&1.destination == "wave4-channel-delivery"))

    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    refute_received :policy_called
    refute_received :authority_called
  end

  @tag timeout: 300_000
  test "native acknowledgements paused before their commit are confirmed, never written twice" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    profile = fixture.profile
    scope = Elzoo.Wave4ChannelTestHelper.scope(profile)
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "paused-native-acks"})
    primary_id = event["input_id"]
    run_id = run_id_of(fixture, event)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)
    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Wave4ChannelExample.advance(fixture.host) end)
    assert {:ok, %{event_waits: %{waits: [wait]}}} = Wave4ChannelExample.view(fixture.host, scope)

    assert {:ok, before_reply} =
             CheckedCommand.resource(fixture.handles.input, scope, profile.conversation_id)

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "paused-native-acks-reply",
        "input_id" => wait.correlation_id,
        "expected_revision" => before_reply.revision,
        "text" => "reply"
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    reply_item = Enum.find(pending, &(&1.destination == "wave4-channel-reply"))
    primary_item = Enum.find(pending, &(&1.destination == "wave4-channel-input"))
    reply_key = reply_item.idempotency_key
    reply_nonce = reply_item.nonce
    primary_key = primary_item.idempotency_key
    primary_nonce = primary_item.nonce

    assert {:reply_observed, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_reply, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, _native_result} =
             wait_public_result(
               :sys.get_state(fixture.host).engine,
               %{tenant: profile.tenant, principal: profile.actor, run_id: run_id},
               System.monotonic_time(:millisecond) + 10_000
             )

    assert {:result, :completed} = Wave4ChannelExample.advance(fixture.host)
    assert {:answered, _revision} = Wave4ChannelExample.advance(fixture.host)

    # The reply acknowledgement pauses before its commit with its writer
    # alive: confirmation by the original receipt is read-only, so no second
    # acknowledgement is written while that writer lives.
    probe = probe_host_command_store!(fixture)
    reply_token = :wave4_reply_ack_writer
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :ack, reply_key, {:pause, reply_token})

    assert {:unknown, :reply_ack} = Wave4ChannelExample.advance(fixture.host)
    reply_writer = Elzoo.DurableLog.PostgresHarness.paused(fixture.controller, reply_token)
    assert Process.alive?(reply_writer.pid)
    assert {:reply_ack, ^reply_key, ^reply_nonce, _reason} = :sys.get_state(fixture.host).poison

    assert {:ok, %{state: :pending}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [reply_key])

    assert {:unknown, :reply_ack} = Wave4ChannelExample.advance(fixture.host)
    assert {:unknown, :reply_ack} = Wave4ChannelExample.advance(fixture.host)
    assert Enum.count(Elzoo.Wave4ChannelTest.ReadProbe.acks(probe), &(&1 == reply_key)) == 1
    assert Process.alive?(reply_writer.pid)

    assert {:committed, _} =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :release, [reply_token])

    assert {:reconciled, :reply_ack} = Wave4ChannelExample.advance(fixture.host)
    assert Enum.count(Elzoo.Wave4ChannelTest.ReadProbe.acks(probe), &(&1 == reply_key)) == 1

    # The same for the primary acknowledgement.
    primary_token = :wave4_primary_ack_writer
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :ack, primary_key, {:pause, primary_token})

    assert {:unknown, :ack} = Wave4ChannelExample.advance(fixture.host)
    primary_writer = Elzoo.DurableLog.PostgresHarness.paused(fixture.controller, primary_token)
    assert Process.alive?(primary_writer.pid)
    assert {:ack, ^primary_key, ^primary_nonce, _reason} = :sys.get_state(fixture.host).poison

    assert {:unknown, :ack} = Wave4ChannelExample.advance(fixture.host)
    assert {:unknown, :ack} = Wave4ChannelExample.advance(fixture.host)
    assert Enum.count(Elzoo.Wave4ChannelTest.ReadProbe.acks(probe), &(&1 == primary_key)) == 1
    assert Process.alive?(primary_writer.pid)

    assert {:committed, _} =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :release, [primary_token])

    assert {:acknowledged, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
    assert Enum.count(Elzoo.Wave4ChannelTest.ReadProbe.acks(probe), &(&1 == primary_key)) == 1

    assert {:ok, %{state: :acked, ack_nonce: ^reply_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [reply_key])

    assert {:ok, %{state: :acked, ack_nonce: ^primary_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [primary_key])
  end

  @tag timeout: 300_000
  test "a faulted append is redelivered before its acknowledgement so nothing is lost", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, _} = Wave4ChannelExample.advance(fixture.host)

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    reference = Elzoo.Wave4ChannelTestHelper.conversation_reference(fixture.profile)

    # Exactly one append of the association delivery fails. Because the
    # acknowledgement only ever follows a proven append, the item stays
    # pending and the redelivery appends the association exactly once.
    Elzoo.DurableLog.PostgresHarness.hook(fixture.conversation_store, :inject, [
      :append,
      :unavailable
    ])

    assert {:unknown, :delivery} = Wave4ChannelExample.advance(fixture.host)

    # Recover through the poisoned delivery: the single-shot fault is spent.
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, %{entries: entries}} =
             Conversation.page(fixture.conversation_store, scope, reference, 1, 100)

    assert Enum.count(entries, &(&1.kind == :association and &1.input_message_id == input_id)) == 1,
           "the faulted delivery must be redelivered exactly once, never lost or duplicated"

    assert Enum.count(entries, &(&1.kind == :input and &1.message_id == input_id)) == 1
  end

  @tag timeout: 300_000
  test "a host-generated answer conflicting with the conversation is refused before commit", %{
    fixture: fixture
  } do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event()
    input_id = event["input_id"]

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, _} = Wave4ChannelExample.advance(fixture.host)

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    reference = Elzoo.Wave4ChannelTestHelper.conversation_reference(fixture.profile)

    # A foreign answer for this input lands in the conversation after the
    # association committed but before the host generates its own answer.
    answer_id = Elzoo.Wave4ChannelTestHelper.answer_id(input_id)

    assert {:ok, owner} =
             Conversation.start_link(
               store: fixture.conversation_store,
               target_tenant: fixture.profile.tenant,
               conversation_id: fixture.profile.conversation_id
             )

    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)

    assert {:ok, %{sequence: _}} =
             Conversation.associate_run(owner, %{input_message_id: input_id, run_id: run_id})

    assert {:ok, %{sequence: _}} =
             Conversation.append_answer(owner, %{
               message_id: answer_id,
               actor: fixture.profile.actor,
               text: "answer:foreign",
               run_id: run_id,
               input_message_id: input_id,
               completed: true
             })

    GenServer.stop(owner, :normal, 5_000)

    # The pipeline runs until it would generate the answer: admission of that
    # host-generated command must refuse it before commit — no answer row is
    # ever written for it and the pipeline cannot silently pass.
    answer_operation =
      Elzoo.Wave4ChannelTestHelper.answer_operation(fixture.profile, event["event_id"], input_id)

    result_scope = %{tenant: fixture.profile.tenant, actor: fixture.profile.actor}

    steps =
      Enum.map(1..8, fn _ -> Wave4ChannelExample.advance(fixture.host) end)

    refute Enum.any?(steps, &match?({:answered, _}, &1)),
           "the conflicting answer must never commit"

    assert {:unknown, :not_observed} =
             CheckedCommand.result(
               fixture.handles.answer,
               result_scope,
               {fixture.profile.tenant, fixture.profile.actor, answer_operation}
             )

    assert {:ok, %{entries: entries}} =
             Conversation.page(fixture.conversation_store, scope, reference, 1, 100)

    answers = Enum.filter(entries, &(&1.kind == :answer and &1.message_id == answer_id))
    assert length(answers) == 1
    assert hd(answers).text == "answer:foreign"
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
    assert Map.keys(resource.fields) == ["wave4_intent"]
    assert {:ok, projection_entries, projection_messages} = read_conversation(fixture, scope)
    assert length(projection_entries) == 6

    projection_associations = Enum.filter(projection_entries, &(&1.kind == :association))
    assert length(projection_messages) == 4
    assert length(projection_associations) == 2

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

    assert {:ok, writes, _response} =
             Wave4ChannelExample.Intents.prepare(snapshot, request, prepared_facts)

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

  defp run_id_of(fixture, event) do
    Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])
  end

  defp assert_round_completes!(fixture, event, answer_revision) do
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, _native_result} =
             wait_public_result(
               :sys.get_state(fixture.host).engine,
               %{tenant: fixture.profile.tenant, principal: fixture.profile.actor, run_id: run_id},
               System.monotonic_time(:millisecond) + 10_000
             )

    assert {:result, :completed} = Wave4ChannelExample.advance(fixture.host)
    assert {:answered, ^answer_revision} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:idle, :no_input} = Wave4ChannelExample.advance(fixture.host)
  end

  defp assert_reply_round_completes!(fixture, event) do
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    primary_id = event["input_id"]
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)

    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Wave4ChannelExample.advance(fixture.host) end)

    assert {:ok, %{event_waits: %{waits: [wait]}}} =
             Wave4ChannelExample.view(fixture.host, scope)

    assert {:ok, before_reply} =
             CheckedCommand.resource(
               fixture.handles.input,
               scope,
               fixture.profile.conversation_id
             )

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => event["event_id"] <> "-reply",
        "input_id" => wait.correlation_id,
        "expected_revision" => before_reply.revision,
        "text" => "reply"
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert {:ok, pending} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert reply_item = Enum.find(pending, &(&1.destination == "wave4-channel-reply"))
    reply_key = reply_item.idempotency_key

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], primary_id)

    assert {:reply_observed, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_reply, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, _native_result} =
             wait_public_result(
               :sys.get_state(fixture.host).engine,
               %{tenant: fixture.profile.tenant, principal: fixture.profile.actor, run_id: run_id},
               System.monotonic_time(:millisecond) + 10_000
             )

    assert {:result, :completed} = Wave4ChannelExample.advance(fixture.host)
    assert {:answered, _revision} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_acknowledged, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
  end

  defp assert_message_count_at_least!(fixture, count) do
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    reference = Elzoo.Wave4ChannelTestHelper.conversation_reference(fixture.profile)

    assert {:ok, %{entries: entries}} =
             Conversation.page(fixture.conversation_store, scope, reference, 1, 1_000)

    messages = Enum.count(entries, &(&1.kind in [:input, :answer]))
    assert messages > count, "expected more than #{count} visible messages, got #{messages}"
  end

  defp assert_conversation_exceeds!(fixture, bytes) do
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    reference = Elzoo.Wave4ChannelTestHelper.conversation_reference(fixture.profile)

    assert {:ok, %{entries: entries}} =
             Conversation.page(fixture.conversation_store, scope, reference, 1, 1_000)

    total =
      entries
      |> Enum.filter(&(&1.kind in [:input, :answer]))
      |> Enum.reduce(0, fn entry, acc -> acc + byte_size(entry.text || "") end)

    assert total > bytes, "expected conversation text above #{bytes} bytes, got #{total}"
  end

  defp read_conversation(fixture, scope) do
    reference = Elzoo.Wave4ChannelTestHelper.conversation_reference(fixture.profile)

    case Conversation.page(fixture.conversation_store, scope, reference, 1, 1_000) do
      {:ok, %{entries: entries}} ->
        messages = Enum.filter(entries, &(&1.kind in [:input, :answer]))
        {:ok, entries, messages}

      error ->
        error
    end
  end

  defp conversation_head(fixture) do
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    reference = Elzoo.Wave4ChannelTestHelper.conversation_reference(fixture.profile)

    case Conversation.page(fixture.conversation_store, scope, reference, 1, 1_000) do
      {:ok, %{entries: []}} -> {:ok, 0}
      {:ok, %{entries: entries}} -> {:ok, entries |> Enum.map(& &1.sequence) |> Enum.max()}
      error -> error
    end
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

    assert {:ok, writes, _} = Wave4ChannelExample.Intents.prepare(snapshot, request, prepared_facts)

    Agent.update(authority_control, fn _ ->
      %{approver: %{identity: "human-reviewer", authority: writes}, now: now, revoked: []}
    end)

    Agent.update(policy_control, fn _ -> :allow end)

    # Capture the conversation owner before the host parks inside the release
    # authority callback; seed_message! cannot reach :sys.get_state then.
    conversation_owner = Elzoo.Wave4ChannelTestHelper.conversation_owner(fixture)

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

    assert {:completed, %{revision: 1}} =
             seed_message!(fixture, 1, "intervening public write", conversation_owner)

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

  defp capacity_reply_fixture(ask_modes) do
    now = System.system_time(:millisecond)

    policy = fn mode, _event, _now ->
      Elzoo.Wave4ChannelTestHelper.policy(if(mode in ask_modes, do: :ask, else: :allow))
    end

    Elzoo.Wave4ChannelTestHelper.reply_fixture(
      clock: fn -> now end,
      deadline_ms: now + 600_000,
      policy: policy
    )
  end

  defp capacity_wait_fixture(ask_modes, event_id) do
    fixture = capacity_reply_fixture(ask_modes)
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    primary_event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => event_id})
    primary_input_id = primary_event["input_id"]

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    assert {:observed, ^primary_input_id} =
             Elzoo.Wave4ChannelExample.advance(fixture.host)

    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    assert {:ok, %{event_waits: %{waits: [wait]}}} =
             Elzoo.Wave4ChannelExample.view(
               fixture.host,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
             )

    assert wait.status == :waiting
    {fixture, primary_listener, reply_listener, primary_event, wait}
  end

  defp reply_event_for_capacity(_fixture, wait, event_id) do
    Elzoo.Wave4ChannelTestHelper.event(%{
      "event_id" => event_id,
      "input_id" => wait.correlation_id,
      "expected_revision" => 2,
      "text" => "capacity reply"
    })
  end

  defp checked_resource!(fixture) do
    CheckedCommand.resource(
      fixture.handles.input,
      Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
      fixture.profile.conversation_id
    )
  end

  defp checked_result(fixture, source, event) do
    {handle, operation} =
      case source do
        :primary ->
          {fixture.handles.input,
           Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])}

        :reply ->
          {fixture.handles.reply_input,
           Elzoo.Wave4ChannelTestHelper.reply_operation(fixture.profile, event["event_id"])}
      end

    CheckedCommand.result(
      handle,
      %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
      {fixture.profile.tenant, fixture.profile.actor, operation}
    )
  end

  defp seed_refusals_to_head!(fixture, target, prefix) do
    profile = fixture.profile
    handle = fixture.handles.input
    scope = Elzoo.Wave4ChannelTestHelper.scope(profile)
    result_scope = %{tenant: profile.tenant, actor: profile.actor}

    assert {:ok, %{revision: starting_head, low_water: 0}} =
             Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert starting_head <= target

    assert {:ok, snapshot} = CheckedCommand.resource(handle, scope, profile.conversation_id)
    assert {:ok, pending_before} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
    indices = if starting_head == target, do: [], else: Enum.to_list((starting_head + 1)..target)

    {first, last} =
      Enum.reduce(indices, {nil, nil}, fn index, {first, _last} ->
        event_id = "headroom-#{prefix}-#{index}"

        request = %{
          operation_id: Elzoo.Wave4ChannelTestHelper.input_operation(profile, event_id),
          resource: profile.conversation_id,
          expected_revision: snapshot.revision,
          payload: %{"message_id" => "message-#{event_id}", "text" => "retained refusal"}
        }

        assert {:ok, writes, _} =
                 Wave4ChannelExample.Intents.prepare(
                   snapshot,
                   request,
                   %{
                     tenant: profile.tenant,
                     actor: profile.actor,
                     data: facts
                   }
                 )

        context = %{
          tenant: profile.tenant,
          actor: profile.actor,
          policy: Elzoo.Wave4ChannelTestHelper.policy(:deny),
          own: writes,
          parent: :none,
          facts: facts
        }

        outcome = CheckedCommand.execute(handle, context, request)
        assert {:denied, _} = outcome
        retained = {request.operation_id, outcome}
        {first || retained, retained}
      end)

    assert {:ok, %{revision: ^target, low_water: 0}} =
             Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, ^snapshot} = CheckedCommand.resource(handle, scope, profile.conversation_id)
    assert {:ok, ^pending_before} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    for {operation_id, outcome} <-
          Enum.uniq_by([first, last] |> Enum.reject(&is_nil/1), &elem(&1, 0)) do
      assert CheckedCommand.result(
               handle,
               result_scope,
               {profile.tenant, profile.actor, operation_id}
             ) == outcome
    end

    :ok
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

    assert {:ok, writes, _response} =
             Wave4ChannelExample.Intents.prepare(snapshot, request, prepared_facts)

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

  defp seed_message!(fixture, index, text, conversation_owner \\ nil) do
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
    assert {:ok, writes, _} = Wave4ChannelExample.Intents.prepare(snapshot, request, prepared_facts)

    context = %{
      tenant: profile.tenant,
      actor: profile.actor,
      policy: Elzoo.Wave4ChannelTestHelper.policy(),
      own: writes,
      parent: :none,
      facts: facts
    }

    result = CheckedCommand.execute(fixture.handles.input, context, request)
    assert {:completed, completed} = result

    assert {:ok, :input, dto} = Wave4ChannelExample.Intents.delivery(completed.response)

    # The owner may be captured beforehand when the host is deliberately
    # parked inside a release call; :sys.get_state would deadlock then.
    owner = conversation_owner || Elzoo.Wave4ChannelTestHelper.conversation_owner(fixture)

    assert {:ok, %{sequence: ^index}} =
             Conversation.append_input(
               owner,
               dto
             )

    assert {:ok, [item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:committed, _} =
             Outbox.ack(fixture.command_store, item.idempotency_key, item.nonce)

    result
  end

  defp trace_native_hash(task_supervisor) do
    module = Elzoo.Wave4ChannelExample.NativeWork
    Code.ensure_loaded!(module)
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
    Code.ensure_loaded!(RunEngine)
    Process.put(:wave4_channel_engine_input_trace_target, host)
    :erlang.trace_pattern({RunEngine, :input, 4}, true, [:global])
    :erlang.trace(host, true, [:call])

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(host), do: :erlang.trace(host, false, [:all])
      :erlang.trace_pattern({RunEngine, :input, 4}, false, [:global])
      assert {:match_spec, false} = :erlang.trace_info({RunEngine, :input, 4}, :match_spec)
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

    assert {:ok, items} = Outbox.pending(fixture.command_store, stream, 64)

    assert [item] = Enum.filter(items, &(&1.idempotency_key == idempotency_key))

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

    assert Map.new(input_fields)["message_id"] == {:text, input_id}
    assert Map.new(input_fields)["revision"] == input_revision

    assert {:ok, :input, input_dto} =
             Wave4ChannelExample.Intents.delivery({:record, input_fields})

    assert input_dto == %{
             message_id: input_id,
             role: "source",
             actor: profile.actor,
             text: event["text"]
           }

    assert {:completed, %{revision: association_revision, response: {:record, association_fields}}} =
             CheckedCommand.result(
               fixture.handles.association,
               scope,
               {profile.tenant, profile.actor, association_operation}
             )

    assert association_revision == input_revision + 1

    assert Map.new(association_fields)["message_id"] == {:text, input_id}
    assert Map.new(association_fields)["revision"] == association_revision
    assert Map.new(association_fields)["run_id"] == {:text, run_id}

    assert {:ok, :association, association_dto} =
             Wave4ChannelExample.Intents.delivery({:record, association_fields})

    assert association_dto == %{input_message_id: input_id, run_id: run_id}

    assert {:completed, %{revision: ^answer_revision, response: {:record, answer_fields}}} =
             CheckedCommand.result(
               fixture.handles.answer,
               scope,
               {profile.tenant, profile.actor, answer_operation}
             )

    assert Map.new(answer_fields)["input_message_id"] == {:text, input_id}
    assert Map.new(answer_fields)["message_id"] == {:text, answer_id}
    assert Map.new(answer_fields)["revision"] == answer_revision
    assert Map.new(answer_fields)["run_id"] == {:text, run_id}

    assert {:ok, :answer, answer_dto} =
             Wave4ChannelExample.Intents.delivery({:record, answer_fields})

    assert answer_dto == %{
             message_id: answer_id,
             actor: profile.actor,
             text: "answer:#{digest_text(event["text"])}",
             run_id: run_id,
             input_message_id: input_id,
             completed: true
           }
  end

  defp digest_text(text) do
    Base.encode16(:crypto.hash(:sha256, text), case: :lower)
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

    callbacks_before_pre_native_get = Agent.get(callbacks, & &1)

    assert {:ok, {{_, 200, _}, _, pre_native_body}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert Jason.decode!(pre_native_body)["view"]["event_waits"] == nil
    assert Agent.get(callbacks, & &1) == callbacks_before_pre_native_get

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

    assert {:ok, {{_, 409, _}, _, refusal_body}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert Jason.decode!(refusal_body)["status"] == "conflict"

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

  @tag :view_encoding_limit
  test "GET encodes exactly one MiB and refuses one byte over from a controlled event-wait reader" do
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

    {primary_listener, _reply_listener} =
      Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "view-limit-primary"})
    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)
    assert {:observed, input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert input_id == event["input_id"]
    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    original_state = :sys.get_state(fixture.host)
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)

    native_scope = %{
      tenant: fixture.profile.tenant,
      principal: fixture.profile.actor,
      run_id: run_id
    }

    assert {:ok, %{waits: [wait]} = event_waits} =
             RunEngine.event_waits(original_state.engine, native_scope, %{
               max_records: 2_048,
               max_bytes: 16_777_216
             })

    assert wait.status == :waiting
    assert wait.action_id == "reply"
    assert wait.source_id == fixture.profile.reply_source_id
    assert is_binary(wait.correlation_id) and wait.correlation_id != ""
    assert is_tuple(wait.occurrence)

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, resource_before} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    assert {:ok, head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    {probe_store, source_probe} =
      Elzoo.Wave4ChannelTest.ReadProbe.attach(fixture.command_store)

    initial_fake_result = Map.put(event_waits, :test_padding, "")
    {:ok, reader} = Elzoo.Wave4ChannelTest.EventWaitReader.start_link(initial_fake_result, 3)
    Process.unlink(reader)

    :sys.replace_state(fixture.host, fn state ->
      %{state | command_store: probe_store, engine: reader}
    end)

    host_before_get = :sys.get_state(fixture.host)
    callbacks_before_get = Agent.get(callbacks, & &1)
    trace_engine_input(fixture.host)
    trace_native_hash(fixture.native.task_supervisor)

    try do
      assert {:ok, {{_, 200, _}, _, probe_body}} =
               Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

      padding_size = 1_048_576 - byte_size(probe_body)
      assert padding_size > 0

      padded_result = Map.put(event_waits, :test_padding, String.duplicate("x", padding_size))
      :ok = Elzoo.Wave4ChannelTest.EventWaitReader.put_result(reader, padded_result)

      assert {:ok, {{_, 200, _}, _, exact_body}} =
               Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

      assert byte_size(exact_body) == 1_048_576

      assert Jason.decode!(exact_body)["view"]["event_waits"]["test_padding"] |> byte_size() ==
               padding_size

      assert :sys.get_state(fixture.host) == host_before_get

      assert {:ok, ^head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

      assert {:ok, ^resource_before} =
               CheckedCommand.resource(
                 fixture.handles.input,
                 scope,
                 fixture.profile.conversation_id
               )

      assert Agent.get(callbacks, & &1) == callbacks_before_get
      assert Elzoo.Wave4ChannelTest.ReadProbe.calls(source_probe) == []
      assert take_engine_input_ids() == []
      assert take_hash_calls() == []

      over_result = Map.put(event_waits, :test_padding, String.duplicate("x", padding_size + 1))
      :ok = Elzoo.Wave4ChannelTest.EventWaitReader.put_result(reader, over_result)

      assert {:ok, {{_, 503, _}, _, unavailable_body}} =
               Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

      assert Jason.decode!(unavailable_body) == %{"status" => "unavailable"}
      assert byte_size(exact_body) + 1 == 1_048_577
      assert Elzoo.Wave4ChannelTest.EventWaitReader.calls(reader) == 3
      assert :sys.get_state(fixture.host) == host_before_get

      assert {:ok, ^head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

      assert {:ok, ^resource_before} =
               CheckedCommand.resource(
                 fixture.handles.input,
                 scope,
                 fixture.profile.conversation_id
               )

      assert Agent.get(callbacks, & &1) == callbacks_before_get
      assert Elzoo.Wave4ChannelTest.ReadProbe.calls(source_probe) == []
      assert take_engine_input_ids() == []
      assert take_hash_calls() == []

      :sys.replace_state(fixture.host, fn state -> %{state | engine: original_state.engine} end)

      assert {:ok, {{_, 200, _}, _, honest_body}} =
               Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

      refute Map.has_key?(Jason.decode!(honest_body)["view"]["event_waits"], "test_padding")
      assert :sys.get_state(fixture.host).engine == original_state.engine
      assert {:ok, ^head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

      assert {:ok, ^resource_before} =
               CheckedCommand.resource(
                 fixture.handles.input,
                 scope,
                 fixture.profile.conversation_id
               )

      assert Agent.get(callbacks, & &1) == callbacks_before_get
      assert Elzoo.Wave4ChannelTest.ReadProbe.calls(source_probe) == []
      assert take_engine_input_ids() == []
      assert take_hash_calls() == []
    after
      :sys.replace_state(fixture.host, fn state ->
        %{state | command_store: original_state.command_store, engine: original_state.engine}
      end)

      if Process.alive?(reader), do: GenServer.stop(reader, :normal, 5_000)
      if Process.alive?(source_probe), do: Agent.stop(source_probe)
    end
  end

  @tag :reply_round
  test "one signed reply wakes the primary, hashes retained text, acknowledges in order, and leaves a read-only final GET" do
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

    # The v2 conversation piece caps stream segments at 64 bytes; tenant and
    # conversation_id use the maximum legal length, the rest stay worst-case.
    max_identity = %{
      tenant: String.duplicate("t", 64),
      actor: String.duplicate("a", 128),
      conversation_id: String.duplicate("c", 64),
      source_id: String.duplicate("s", 128),
      reply_source_id: String.duplicate("r", 128)
    }

    fixture =
      Elzoo.Wave4ChannelTestHelper.reply_fixture(
        clock: clock,
        policy: policy,
        authority: authority,
        profile_overrides: max_identity
      )

    assert byte_size(fixture.profile.tenant) == 64
    assert byte_size(fixture.profile.conversation_id) == 64

    assert Enum.all?(
             [
               fixture.profile.actor,
               fixture.profile.source_id,
               fixture.profile.reply_source_id
             ],
             &(byte_size(&1) == 128)
           )

    profile_event = fn overrides ->
      Elzoo.Wave4ChannelTestHelper.event(
        Map.put_new(overrides, "conversation_id", fixture.profile.conversation_id)
      )
    end

    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    refute primary_listener.port == reply_listener.port

    denied_gates = %{input: fn _, _ -> :deny end, reply: fixture.gates.reply}

    assert {:ok, denied_handles} =
             Elzoo.Wave4ChannelExample.CommandBindings.build_reply(
               fixture.command_store,
               denied_gates
             )

    denied_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, "denied-before-round")

    denied_request = %{
      operation_id: denied_operation,
      resource: fixture.profile.conversation_id,
      expected_revision: 0,
      payload: %{"message_id" => "denied-message", "text" => "denied"}
    }

    assert {:denied, {:gate, _}} =
             execute_reply_command(
               denied_handles.input,
               fixture.profile,
               denied_request,
               {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]},
               &Elzoo.Wave4ChannelExample.Intents.prepare/3
             )

    trace_native_hash(fixture.native.task_supervisor)
    primary_event = profile_event.(%{"event_id" => "reply-round-primary"})
    primary_input_id = primary_event["input_id"]

    primary_run =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        primary_event["event_id"],
        primary_event["input_id"]
      )

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    assert {:observed, observed_input} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert observed_input == primary_event["input_id"]

    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    assert {:ok, waiting_view} = Elzoo.Wave4ChannelExample.view(fixture.host, scope)
    assert %{waits: [waiting]} = waiting_view.event_waits
    assert waiting.status == :waiting
    assert waiting.source_id == fixture.profile.reply_source_id
    assert is_list(waiting.occurrence) and length(waiting.occurrence) == 2
    assert waiting.accepted_event == nil
    cached_wait = :sys.get_state(fixture.host).native_wait
    assert cached_wait.correlation_id == waiting.correlation_id
    refute cached_wait.correlation_id == primary_input_id
    assert Enum.any?(waiting_view.associations, &(&1.input_message_id == primary_event["input_id"]))
    assert {:ok, [primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert primary_item.destination == "wave4-channel-input"
    assert primary_item.sequence == 2
    # v2 cannot produce a >128-byte key: tenants cap at 64 bytes. The canonical
    # key structure carries the full identity, which is what the size
    # assertion proxied.
    assert {:ok, {_stream, _sequence, 1}} = Elzoo.Outbox.parse_id(primary_item.idempotency_key)
    assert byte_size(primary_item.idempotency_key) > 64

    assert {:ok, {stream, primary_sequence, primary_position}} =
             Outbox.parse_id(primary_item.idempotency_key)

    assert stream == checked_stream(fixture.profile.tenant)
    assert primary_sequence == primary_item.sequence
    assert primary_position == primary_item.position

    assert Outbox.new(
             stream,
             primary_sequence,
             primary_position,
             primary_item.destination,
             primary_item.payload,
             primary_item.nonce
           ).idempotency_key == primary_item.idempotency_key

    assert take_hash_calls() == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []

    resource_scope = %{
      tenant: fixture.profile.tenant,
      actor: fixture.profile.actor,
      resources: [fixture.profile.conversation_id]
    }

    assert {:ok, before_reply} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    assert before_reply.revision == 2
    stream = checked_stream(fixture.profile.tenant)

    assert {:ok, head_before_reply} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :head, [stream])

    valid_reply_event =
      profile_event.(%{
        "event_id" => "reply-round-invalid-signature",
        "input_id" => waiting.correlation_id,
        "expected_revision" => before_reply.revision
      })

    wrong_resource_event =
      profile_event.(%{
        "event_id" => "reply-round-wrong-resource",
        "input_id" => waiting.correlation_id,
        "conversation_id" => "other-conversation",
        "expected_revision" => before_reply.revision
      })

    schema_event = Map.put(valid_reply_event, "extra", true)
    trace_engine_input(fixture.host)
    unchanged_host = :sys.get_state(fixture.host)
    {:ok, unchanged_outbox} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    invalid_reply_cases = [
      {"bad HMAC", reply_listener, valid_reply_event,
       [signature: "v1=" <> String.duplicate("0", 64)], 401},
      {"cross-key signature", %{reply_listener | signing_key: primary_listener.signing_key},
       valid_reply_event, [], 401},
      {"cross-source signature", %{reply_listener | source_id: fixture.profile.source_id},
       valid_reply_event, [], 401},
      {"wrong resource", reply_listener, wrong_resource_event, [], 403},
      {"non-exact schema", reply_listener, schema_event, [], 400}
    ]

    for {name, listener, event, options, status} <- invalid_reply_cases do
      assert {:ok, {{_, ^status, _}, _, _}} =
               Elzoo.Wave4ChannelTestHelper.post(listener, event, options),
             name

      assert {:ok, ^head_before_reply} =
               Elzoo.DurableLog.Store.read(fixture.command_store, :head, [stream])

      assert {:ok, ^before_reply} =
               Elzoo.CheckedCommand.resource(
                 fixture.handles.input,
                 resource_scope,
                 fixture.profile.conversation_id
               )

      assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == {:ok, unchanged_outbox}
      assert :sys.get_state(fixture.host) == unchanged_host
      assert Task.Supervisor.children(fixture.native.task_supervisor) == []
      assert take_engine_input_ids() == []
      assert take_hash_calls() == []
    end

    foreign =
      profile_event.(%{
        "event_id" => "reply-round-foreign-ticket",
        "input_id" => "foreign-ticket",
        "expected_revision" => before_reply.revision
      })

    assert {:ok, {{_, 409, _}, _, foreign_body}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, foreign),
           "wrong reply ticket"

    assert Jason.decode!(foreign_body)["status"] == "conflict"

    assert {:ok, ^head_before_reply} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :head, [stream])

    assert {:ok, ^before_reply} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == {:ok, unchanged_outbox}
    assert :sys.get_state(fixture.host) == unchanged_host
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert take_engine_input_ids() == []
    assert take_hash_calls() == []

    stale =
      profile_event.(%{
        "event_id" => "reply-round-stale-revision",
        "input_id" => waiting.correlation_id,
        "expected_revision" => before_reply.revision - 1
      })

    assert {:ok, {{_, 409, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, stale),
           "stale reply event"

    assert {:ok, ^head_before_reply} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :head, [stream])

    assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == {:ok, unchanged_outbox}
    assert :sys.get_state(fixture.host) == unchanged_host
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert take_engine_input_ids() == []
    assert take_hash_calls() == []

    reply_text = "The retained reply, not the primary question."

    reply_event =
      profile_event.(%{
        "event_id" => "reply-round-event",
        "input_id" => waiting.correlation_id,
        "expected_revision" => before_reply.revision,
        "text" => reply_text
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert take_hash_calls() == []
    assert {:ok, [^primary_item, reply_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert reply_item.destination == "wave4-channel-reply"
    reply_key = reply_item.idempotency_key
    assert {:ok, admitted_view} = Elzoo.Wave4ChannelExample.view(fixture.host, scope)
    assert %{waits: [%{status: :waiting, accepted_event: nil}]} = admitted_view.event_waits
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []

    assert {:completed, %{revision: 3}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.reply_input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor,
                Elzoo.Wave4ChannelTestHelper.reply_operation(
                  fixture.profile,
                  reply_event["event_id"]
                )}
             )

    assert reply_item.sequence == 4
    refute reply_item.sequence == 3
    assert {:ok, {_stream, _sequence, 1}} = Elzoo.Outbox.parse_id(reply_key)
    assert byte_size(reply_key) > 64

    assert {:ok, {reply_stream, reply_sequence, reply_position}} = Outbox.parse_id(reply_key)

    assert reply_stream == checked_stream(fixture.profile.tenant)
    assert reply_sequence == reply_item.sequence
    assert reply_position == reply_item.position

    assert Outbox.new(
             reply_stream,
             reply_sequence,
             reply_position,
             reply_item.destination,
             reply_item.payload,
             reply_item.nonce
           ).idempotency_key == reply_key

    assert {:ok, after_reply} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    assert after_reply.revision == 3

    changed = Map.put(reply_event, "text", "changed bytes")

    assert {:ok, {{_, 409, _}, _, changed_body}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, changed)

    assert Jason.decode!(changed_body)["status"] == "conflict"

    assert {:ok, after_changed_replay} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    assert after_changed_replay.revision == after_reply.revision
    assert take_hash_calls() == []

    assert {:reply_observed, ^reply_key} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, 4} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:native_reply, :applied} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    native_reply_input_id = :sys.get_state(fixture.host).reply.native_input_id
    reply_occurrence = :sys.get_state(fixture.host).reply.wait.occurrence
    assert is_binary(native_reply_input_id)
    assert byte_size(native_reply_input_id) in 1..160
    assert is_tuple(reply_occurrence)

    native_reply_id_digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(
          {:wave4_channel, 1, "reply-native-input", [primary_run, reply_key, reply_occurrence]},
          [:deterministic]
        )
      )

    assert native_reply_input_id ==
             "reply-native-input:" <> Base.url_encode64(native_reply_id_digest, padding: false)

    refute native_reply_input_id == reply_event["event_id"]

    assert {:ok, [^primary_item, ^reply_item | _]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    native_engine = :sys.get_state(fixture.host).engine

    native_scope = %{
      tenant: fixture.profile.tenant,
      principal: fixture.profile.actor,
      run_id: primary_run
    }

    assert {:ok, _native_result} =
             wait_public_result(
               native_engine,
               native_scope,
               System.monotonic_time(:millisecond) + 10_000
             )

    callbacks_before_wake_get = Agent.get(callbacks, & &1)
    tasks_before_wake_get = Task.Supervisor.children(fixture.native.task_supervisor)
    host_state_before_wake_get = :sys.get_state(fixture.host)
    assert {:ok, native_status_before_wake_get} = Elzoo.RunEngine.status(native_engine)

    assert {:ok, head_before_wake_get} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :head, [stream])

    assert {:ok, resource_before_wake_get} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    assert {:ok, {{_, 200, _}, _, wake_body}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert [%{"accepted_event" => wake_event, "status" => wake_status}] =
             get_in(Jason.decode!(wake_body), ["view", "event_waits", "waits"])

    assert wake_status in ["settled", "closed"]
    assert wake_event["event_id"] == reply_key
    refute wake_event["event_id"] == reply_event["event_id"]
    assert wake_event["input_id"] == native_reply_input_id
    assert wake_event["sequence"] == reply_item.sequence
    assert Agent.get(callbacks, & &1) == callbacks_before_wake_get
    assert Task.Supervisor.children(fixture.native.task_supervisor) == tasks_before_wake_get
    assert :sys.get_state(fixture.host) == host_state_before_wake_get
    assert {:ok, native_status_after_wake_get} = Elzoo.RunEngine.status(native_engine)
    assert native_status_after_wake_get == native_status_before_wake_get

    assert Elzoo.DurableLog.Store.read(fixture.command_store, :head, [stream]) ==
             {:ok, head_before_wake_get}

    assert Elzoo.CheckedCommand.resource(
             fixture.handles.input,
             resource_scope,
             fixture.profile.conversation_id
           ) == {:ok, resource_before_wake_get}

    assert {:ok, [^primary_item, ^reply_item | _]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:result, :completed} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert take_hash_calls() == [reply_text]

    assert {:ok, [^primary_item, ^reply_item | _]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:answered, 5} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    assert {:ok, [^primary_item, ^reply_item | _]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:reply_acknowledged, ^reply_key} =
             Elzoo.Wave4ChannelExample.advance(fixture.host)

    assert {:ok, [^primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, %{state: :acked}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
               reply_item.idempotency_key
             ])

    assert {:acknowledged, ^primary_input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, %{state: :acked}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
               primary_item.idempotency_key
             ])

    exact_replay_head = Elzoo.DurableLog.Store.read(fixture.command_store, :head, [stream])

    exact_replay_resource =
      Elzoo.CheckedCommand.resource(
        fixture.handles.input,
        resource_scope,
        fixture.profile.conversation_id
      )

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == {:ok, []}
    assert Elzoo.DurableLog.Store.read(fixture.command_store, :head, [stream]) == exact_replay_head

    assert Elzoo.CheckedCommand.resource(
             fixture.handles.input,
             resource_scope,
             fixture.profile.conversation_id
           ) ==
             exact_replay_resource

    assert take_hash_calls() == []

    assert {:ok, final_resource} = exact_replay_resource
    assert final_resource.revision == 5
    head_before_get = exact_replay_head
    callbacks_before_get = Agent.get(callbacks, & &1)
    native_tasks_before_get = Task.Supervisor.children(fixture.native.task_supervisor)
    engine_before_get = :sys.get_state(fixture.host).engine
    phase_before_get = :sys.get_state(fixture.host).phase
    assert {:ok, native_status_before_get} = Elzoo.RunEngine.status(engine_before_get)

    assert {:ok, {{_, 200, _}, _, first_body}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert {:ok, {{_, 200, _}, _, second_body}} =
             Elzoo.Wave4ChannelTestHelper.get(reply_listener, fixture.profile.conversation_id)

    assert Jason.decode!(first_body) == Jason.decode!(second_body)
    assert {:ok, final_view} = Elzoo.Wave4ChannelExample.view(fixture.host, scope)
    assert length(final_view.runs) == 1

    assert Enum.any?(final_view.associations, fn association ->
             association.input_message_id == primary_event["input_id"] and
               association.run_id == primary_run
           end)

    assert Enum.any?(final_view.associations, fn association ->
             association.input_message_id == waiting.correlation_id and
               association.run_id == primary_run
           end)

    assert %{waits: [final_wait]} = final_view.event_waits
    assert final_wait.status in [:settled, :closed]
    assert final_wait.accepted_event.event_id == reply_item.idempotency_key
    refute final_wait.accepted_event.event_id == reply_event["event_id"]
    assert final_wait.accepted_event.input_id == native_reply_input_id
    assert final_wait.accepted_event.sequence == reply_item.sequence

    assert Enum.any?(final_view.messages, fn message ->
             message.message_id == Elzoo.Wave4ChannelTestHelper.answer_id(primary_event["input_id"]) and
               message.text == expected_answer(reply_event)
           end)

    assert Agent.get(callbacks, & &1) == callbacks_before_get
    assert take_hash_calls() == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == native_tasks_before_get
    assert :sys.get_state(fixture.host).engine == engine_before_get
    assert :sys.get_state(fixture.host).phase == phase_before_get
    assert {:ok, native_status_after_get} = Elzoo.RunEngine.status(engine_before_get)
    assert native_status_after_get == native_status_before_get
    assert Elzoo.DurableLog.Store.read(fixture.command_store, :head, [stream]) == head_before_get

    assert Elzoo.CheckedCommand.resource(
             fixture.handles.input,
             resource_scope,
             fixture.profile.conversation_id
           ) ==
             exact_replay_resource

    assert {:ok, first_run_status} =
             Elzoo.RunApprovalRelease.status(fixture.native.run_owner, primary_run)

    first_attempt = first_run_status.current_attempt
    assert is_binary(first_attempt)
    first_engine = engine_before_get
    first_unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(primary_run)

    second_primary_event =
      profile_event.(%{
        "event_id" => "reply-round-primary-two",
        "input_id" => "primary-message-two",
        "expected_revision" => final_resource.revision,
        "text" => "The second primary request."
      })

    second_primary_id = second_primary_event["input_id"]

    second_run =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        second_primary_event["event_id"],
        second_primary_id
      )

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, second_primary_event)

    assert {:observed, ^second_primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    retired_state = :sys.get_state(fixture.host)
    assert retired_state.current.run_id == second_run
    assert retired_state.phase == :association
    assert is_nil(retired_state.engine)
    assert is_nil(retired_state.latest_native)
    assert is_nil(retired_state.native_wait)
    assert is_nil(retired_state.reply)
    assert retired_state.completed_pair.run_id == primary_run
    refute Process.alive?(first_engine)
    assert :not_found = DynamicUnits.find(fixture.directory, first_unit_id)
    assert Registry.lookup(fixture.native.registry, first_unit_id) == []

    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    assert {:ok, second_wait_view} = Elzoo.Wave4ChannelExample.view(fixture.host, scope)
    assert %{waits: [second_wait]} = second_wait_view.event_waits
    assert second_wait.status == :waiting
    assert second_wait.correlation_id != second_primary_id

    second_wait_state = :sys.get_state(fixture.host)
    assert second_wait_state.current.run_id == second_run
    assert second_wait_state.native_wait.correlation_id == second_wait.correlation_id
    assert second_wait_state.native_wait.correlation_id != second_primary_id
    assert second_wait_state.latest_native == nil

    assert {:ok, second_run_status} =
             Elzoo.RunApprovalRelease.status(fixture.native.run_owner, second_run)

    second_attempt = second_run_status.current_attempt
    assert is_binary(second_attempt)
    refute second_run == primary_run
    refute second_attempt == first_attempt
    assert length(second_wait_view.runs) == 2

    assert {:ok, [second_primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    second_wait_head = Elzoo.DurableLog.Store.read(fixture.command_store, :head, [stream])

    second_wait_resource =
      Elzoo.CheckedCommand.resource(
        fixture.handles.input,
        resource_scope,
        fixture.profile.conversation_id
      )

    second_wait_children = Task.Supervisor.children(fixture.native.task_supervisor)
    second_wait_host_state = :sys.get_state(fixture.host)
    second_wait_run_status = stable_run_status(second_run_status)
    first_wait_run_status = stable_run_status(first_run_status)

    assert {:ok, first_primary_ack} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
               primary_item.idempotency_key
             ])

    assert {:ok, first_reply_ack} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
               reply_item.idempotency_key
             ])

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert :sys.get_state(fixture.host) == second_wait_host_state
    assert Elzoo.DurableLog.Store.read(fixture.command_store, :head, [stream]) == second_wait_head

    assert Elzoo.CheckedCommand.resource(
             fixture.handles.input,
             resource_scope,
             fixture.profile.conversation_id
           ) ==
             second_wait_resource

    assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == {:ok, [second_primary_item]}
    assert Task.Supervisor.children(fixture.native.task_supervisor) == second_wait_children
    assert take_hash_calls() == []

    assert {:ok, unchanged_second_run} =
             Elzoo.RunApprovalRelease.status(fixture.native.run_owner, second_run)

    assert stable_run_status(unchanged_second_run) == second_wait_run_status

    assert {:ok, unchanged_first_run} =
             Elzoo.RunApprovalRelease.status(fixture.native.run_owner, primary_run)

    assert stable_run_status(unchanged_first_run) == first_wait_run_status

    assert Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
             primary_item.idempotency_key
           ]) ==
             {:ok, first_primary_ack}

    assert Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
             reply_item.idempotency_key
           ]) ==
             {:ok, first_reply_ack}

    assert {:ok, unchanged_wait_view} = Elzoo.Wave4ChannelExample.view(fixture.host, scope)
    assert unchanged_wait_view.event_waits == second_wait_view.event_waits
    assert {:ok, [unchanged_wait]} = Map.fetch(unchanged_wait_view.event_waits, :waits)
    assert unchanged_wait.correlation_id == second_wait.correlation_id
    assert unchanged_wait.occurrence == second_wait.occurrence
    assert unchanged_wait.status == :waiting
    assert unchanged_wait.accepted_event == nil

    assert {:ok, resource_before_second_reply} = second_wait_resource

    second_reply_text = "The retained second reply, not the second primary."

    second_reply_event =
      profile_event.(%{
        "event_id" => "reply-round-event-two",
        "input_id" => second_wait.correlation_id,
        "expected_revision" => resource_before_second_reply.revision,
        "text" => second_reply_text
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, second_reply_event)

    assert take_hash_calls() == []

    assert {:ok, [^second_primary_item, second_reply_item]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    second_reply_key = second_reply_item.idempotency_key
    refute second_reply_key == reply_key
    assert {:reply_observed, ^second_reply_key} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, 9} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:native_reply, :applied} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    second_native_state = :sys.get_state(fixture.host)
    second_native_input_id = second_native_state.reply.native_input_id
    second_engine = second_native_state.engine
    assert second_native_state.current.run_id == second_run
    assert byte_size(second_native_input_id) in 1..160

    assert {:ok, second_result} =
             wait_public_result(
               second_engine,
               %{
                 tenant: fixture.profile.tenant,
                 principal: fixture.profile.actor,
                 run_id: second_run
               },
               System.monotonic_time(:millisecond) + 10_000
             )

    assert second_result.payload["answer"] == expected_answer(second_reply_event)
    assert {:result, :completed} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert take_hash_calls() == [second_reply_text]
    assert {:answered, 10} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    assert {:reply_acknowledged, ^second_reply_key} =
             Elzoo.Wave4ChannelExample.advance(fixture.host)

    assert {:ok, [^second_primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:acknowledged, ^second_primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, %{state: :acked}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [second_reply_key])

    assert {:ok, %{state: :acked}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
               second_primary_item.idempotency_key
             ])

    final_second_state = :sys.get_state(fixture.host)
    assert is_nil(final_second_state.current)
    assert final_second_state.latest_native.run_id == second_run
    assert final_second_state.completed_pair.run_id == second_run
    final_second_head = Elzoo.DurableLog.Store.read(fixture.command_store, :head, [stream])

    final_second_resource =
      Elzoo.CheckedCommand.resource(
        fixture.handles.input,
        resource_scope,
        fixture.profile.conversation_id
      )

    final_callbacks = Agent.get(callbacks, & &1)
    final_tasks = Task.Supervisor.children(fixture.native.task_supervisor)
    assert {:ok, final_second_native_status} = Elzoo.RunEngine.status(second_engine)

    assert {:ok, {{_, 200, _}, _, second_get_body}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert {:ok, {{_, 200, _}, _, second_get_body_again}} =
             Elzoo.Wave4ChannelTestHelper.get(reply_listener, fixture.profile.conversation_id)

    assert Jason.decode!(second_get_body) == Jason.decode!(second_get_body_again)
    assert {:ok, second_final_view} = Elzoo.Wave4ChannelExample.view(fixture.host, scope)
    assert length(second_final_view.runs) == 2

    assert Enum.any?(second_final_view.messages, fn message ->
             message.message_id == Elzoo.Wave4ChannelTestHelper.answer_id(primary_event["input_id"]) and
               message.text == expected_answer(reply_event)
           end)

    assert Enum.any?(second_final_view.messages, fn message ->
             message.message_id == Elzoo.Wave4ChannelTestHelper.answer_id(second_primary_id) and
               message.text == expected_answer(second_reply_event)
           end)

    assert Agent.get(callbacks, & &1) == final_callbacks
    assert Task.Supervisor.children(fixture.native.task_supervisor) == final_tasks
    assert :sys.get_state(fixture.host) == final_second_state
    assert Elzoo.DurableLog.Store.read(fixture.command_store, :head, [stream]) == final_second_head

    assert Elzoo.CheckedCommand.resource(
             fixture.handles.input,
             resource_scope,
             fixture.profile.conversation_id
           ) ==
             final_second_resource

    assert {:ok, final_second_native_status_after_get} = Elzoo.RunEngine.status(second_engine)
    assert final_second_native_status_after_get == final_second_native_status
  end

  @tag :reply_recovery
  test "fenced v2 recovery restores original wait, reply, ordered acknowledgements, and latest reader" do
    {:ok, calls} = Agent.start_link(fn -> %{clock: 0, policy: 0, authority: 0} end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    clock = fn ->
      Agent.update(calls, &Map.update!(&1, :clock, fn count -> count + 1 end))
      System.system_time(:millisecond)
    end

    policy = fn _mode, _event, _now ->
      Agent.update(calls, &Map.update!(&1, :policy, fn count -> count + 1 end))
      Elzoo.Wave4ChannelTestHelper.policy()
    end

    authority = fn _mode, _event, _request, _facts ->
      Agent.update(calls, &Map.update!(&1, :authority, fn count -> count + 1 end))
      %{}
    end

    fixture =
      Elzoo.Wave4ChannelTestHelper.reply_fixture(
        clock: clock,
        policy: policy,
        authority: authority
      )

    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    primary_event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "recover-primary"})
    primary_id = primary_event["input_id"]

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        primary_event["event_id"],
        primary_id
      )

    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    assert {:observed, ^primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, %{event_waits: %{waits: [original_wait]}}} =
             Elzoo.Wave4ChannelExample.view(fixture.host, scope)

    assert original_wait.status == :waiting
    original_ticket = original_wait.correlation_id
    original_occurrence = original_wait.occurrence
    assert {:ok, [primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:ok, original_run_status} = RunApprovalRelease.status(fixture.owner, run_id)
    assert take_hash_calls() == []

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    assert :not_found = Elzoo.DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert {:ok, old_head} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    resource_scope = %{
      tenant: fixture.profile.tenant,
      actor: fixture.profile.actor,
      resources: [fixture.profile.conversation_id]
    }

    assert {:ok, old_resource} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    calls_before_get = Agent.get(calls, & &1)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert Agent.get(calls, & &1) == calls_before_get
    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == {:ok, old_head}

    assert Elzoo.CheckedCommand.resource(
             fixture.handles.input,
             resource_scope,
             fixture.profile.conversation_id
           ) == {:ok, old_resource}

    assert :not_found = Elzoo.DynamicUnits.find(fixture.directory, unit_id)

    trace_native_hash(fixture.native.task_supervisor)
    Enum.each(1..6, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)
    assert take_hash_calls() == []

    assert {:ok, %{event_waits: %{waits: [restored_wait]}}} =
             Elzoo.Wave4ChannelExample.view(fixture.host, scope)

    assert restored_wait.status == :waiting
    assert restored_wait.correlation_id == original_ticket
    assert restored_wait.occurrence == original_occurrence
    assert {:ok, restored_run_status} = RunApprovalRelease.status(fixture.owner, run_id)
    assert restored_run_status.id == original_run_status.id
    assert restored_run_status.attempts == original_run_status.attempts
    assert restored_run_status.current_attempt == original_run_status.current_attempt

    reply_text = "Durably retained reply during host replacement."

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "recover-reply",
        "input_id" => original_ticket,
        "expected_revision" => old_resource.revision,
        "text" => reply_text
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert is_nil(:sys.get_state(fixture.host).reply.association_revision)

    assert {:ok, [^primary_item, reply_item]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    reply_key = reply_item.idempotency_key
    reply_nonce = reply_item.nonce
    retained_reply = :sys.get_state(fixture.host).reply

    trace_engine_input(fixture.host)
    assert {:reply_observed, ^reply_key} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:read_at, :unavailable]
             )

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:append, :reply_loss]
             )

    assert {:unknown, :reply_association} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert is_nil(:sys.get_state(fixture.host).reply.association_revision)
    assert take_engine_input_ids() == []
    assert take_hash_calls() == []

    assert {:completed, %{revision: 4}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.reply_association,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, retained_reply.association_operation}
             )

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    recovered_reply_steps =
      Enum.map(1..4, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    assert :sys.get_state(fixture.host).reply.association_revision == 4
    assert {:pending, :event_waiting} in recovered_reply_steps
    assert :sys.get_state(fixture.host).phase == :reply_input
    assert :sys.get_state(fixture.host).reply.ticket == original_ticket

    trace_engine_input(fixture.host)

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.native.unit_store,
               :inject,
               [:append, :reply_loss]
             )

    assert {:unknown, :native_reply} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    [native_reply_input_id] = take_engine_input_ids()

    assert {:blocked, :provider_owner_replacement} =
             Elzoo.Wave4ChannelExample.advance(fixture.host)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(reply_listener, fixture.profile.conversation_id)

    hashes_before_native_reopen = take_hash_calls()
    assert hashes_before_native_reopen in [[], [reply_text]]

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    trace_engine_input(fixture.host)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert {:observed, ^primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    reply_recovery_steps =
      Enum.reduce_while(1..10, [], fn _, steps ->
        step = Elzoo.Wave4ChannelExample.advance(fixture.host)
        state = :sys.get_state(fixture.host)
        steps = [step | steps]

        if is_map(state.reply) and state.reply.native_input_id == native_reply_input_id,
          do: {:halt, Enum.reverse(steps)},
          else: {:cont, steps}
      end)

    assert reply_recovery_steps != []

    recovered_reply = :sys.get_state(fixture.host).reply
    assert :sys.get_state(fixture.host).current.run_id == run_id
    assert recovered_reply.item.idempotency_key == reply_key
    assert recovered_reply.native_input_id == native_reply_input_id

    assert {:ok, %{event_waits: %{waits: [accepted_wait]}}} =
             Elzoo.Wave4ChannelExample.view(
               fixture.host,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
             )

    assert accepted_wait.accepted_event.event_id == reply_key
    assert accepted_wait.accepted_event.input_id == native_reply_input_id
    refute native_reply_input_id in take_engine_input_ids()

    native_engine = :sys.get_state(fixture.host).engine

    native_scope = %{
      tenant: fixture.profile.tenant,
      principal: fixture.profile.actor,
      run_id: run_id
    }

    assert {:ok, native_result} =
             wait_public_result(
               native_engine,
               native_scope,
               System.monotonic_time(:millisecond) + 10_000
             )

    assert native_result.run_id == run_id
    assert native_result.attempt_id == original_run_status.current_attempt
    assert native_result.action_id == "hash"
    assert native_result.schema_id == "answer/v1"
    assert native_result.payload["answer"] == expected_answer(reply_event)
    assert hashes_before_native_reopen ++ take_hash_calls() == [reply_text]

    assert {:ok, {{_, 200, _}, _, wake_body}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    [accepted_wait] =
      Jason.decode!(wake_body)["view"]["event_waits"]["waits"]

    assert accepted_wait["accepted_event"]["event_id"] == reply_key
    assert accepted_wait["occurrence"] == Enum.map(original_occurrence, & &1)

    answer_operation =
      Elzoo.Wave4ChannelTestHelper.answer_operation(
        fixture.profile,
        primary_event["event_id"],
        primary_id
      )

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:read_at, :unavailable]
             )

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:append, :reply_loss]
             )

    assert {:unknown, :answer} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    assert {:ok, %{state: :pending, nonce: observed_primary_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
               primary_item.idempotency_key
             ])

    assert observed_primary_nonce == primary_item.nonce

    answer_head_before_reconciliation =
      Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:reconciled, :answer} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert :sys.get_state(fixture.host).phase == :reply_ack
    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == answer_head_before_reconciliation

    assert {:completed, %{revision: 5}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.answer,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, answer_operation}
             )

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    recovered_result_steps =
      Enum.reduce_while(1..8, [], fn _, steps ->
        step = Elzoo.Wave4ChannelExample.advance(fixture.host)
        steps = [step | steps]

        if match?({:answered, _}, step),
          do: {:halt, Enum.reverse(steps)},
          else: {:cont, steps}
      end)

    assert {:answered, 5} in recovered_result_steps
    assert :sys.get_state(fixture.host).phase == :reply_ack

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:ack, :rollback]
             )

    assert {:unknown, :reply_ack} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert :sys.get_state(fixture.host).phase == :reply_ack

    assert {:ok, %{state: :pending, nonce: ^reply_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [reply_key])

    # The rolled-back acknowledgement's outcome is unknown to the host: it is
    # confirmed read-only and never written again in this host lifetime. The
    # retry follows the fenced reopen below, which acknowledges it once.
    assert {:unknown, :reply_ack} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert take_hash_calls() == []

    assert {:ok, %{state: :pending, nonce: ^reply_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [reply_key])

    assert {:ok, %{state: :pending, nonce: primary_nonce}} =
             Elzoo.DurableLog.Store.read(
               fixture.command_store,
               :read_ack,
               [primary_item.idempotency_key]
             )

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    trace_native_hash(fixture.native.task_supervisor)

    # The first reopened host acknowledges the reply item once, by the first
    # acknowledgement of its lifetime, and is stopped right after it: the
    # primary item is still pending then.
    probe = probe_host_command_store!(fixture)
    primary_key = primary_item.idempotency_key

    assert {:observed, ^primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    reply_ack_steps =
      Enum.reduce_while(1..10, [], fn _, steps ->
        step = Elzoo.Wave4ChannelExample.advance(fixture.host)
        steps = [step | steps]

        if step == {:reply_acknowledged, reply_key},
          do: {:halt, Enum.reverse(steps)},
          else: {:cont, steps}
      end)

    assert List.last(reply_ack_steps) == {:reply_acknowledged, reply_key}
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == [reply_key]

    assert {:ok, %{state: :acked, nonce: ^reply_nonce, ack_nonce: ^reply_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [reply_key])

    assert {:ok, %{state: :pending, nonce: ^primary_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [primary_key])

    assert take_hash_calls() == []

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    trace_native_hash(fixture.native.task_supervisor)

    # The next host sends only the primary acknowledgement; its reply is lost
    # and confirmed by the original receipt.
    probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :ack, primary_key, :reply_loss)

    assert {:observed, ^primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    primary_ack_steps =
      Enum.map(1..8, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    assert Enum.any?(primary_ack_steps, &(&1 == {:acknowledged, primary_id}))
    assert Elzoo.Wave4ChannelTest.ReadProbe.faults(probe) == %{}
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == [primary_key]
    assert :sys.get_state(fixture.host).current == nil
    assert :sys.get_state(fixture.host).latest_native.run_id == run_id
    assert take_hash_calls() == []

    assert {:ok, %{state: :acked, nonce: ^primary_nonce}} =
             Elzoo.DurableLog.Store.read(
               fixture.command_store,
               :read_ack,
               [primary_item.idempotency_key]
             )

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    {primary_listener, _reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    trace_native_hash(fixture.native.task_supervisor)
    Enum.each(1..9, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)
    assert take_hash_calls() == []

    recovered_state = :sys.get_state(fixture.host)
    assert recovered_state.current == nil
    assert recovered_state.latest_native.run_id == run_id
    assert recovered_state.completed_pair.run_id == run_id
    assert {:ok, restored_unit} = Elzoo.DynamicUnits.find(fixture.directory, unit_id)
    assert Process.alive?(restored_unit)

    final_callbacks_before_get = Agent.get(calls, & &1)
    final_state_before_get = :sys.get_state(fixture.host)
    final_head_before_get = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    final_resource_before_get =
      Elzoo.CheckedCommand.resource(
        fixture.handles.input,
        resource_scope,
        fixture.profile.conversation_id
      )

    final_run_before_get = RunApprovalRelease.status(fixture.owner, run_id)
    final_tasks_before_get = Task.Supervisor.children(fixture.native.task_supervisor)

    assert {:ok, {{_, 200, _}, _, final_body}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert {:ok, {{_, 200, _}, _, final_body_again}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert Agent.get(calls, & &1) == final_callbacks_before_get
    assert :sys.get_state(fixture.host) == final_state_before_get
    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == final_head_before_get

    assert Elzoo.CheckedCommand.resource(
             fixture.handles.input,
             resource_scope,
             fixture.profile.conversation_id
           ) == final_resource_before_get

    assert RunApprovalRelease.status(fixture.owner, run_id) == final_run_before_get
    assert Task.Supervisor.children(fixture.native.task_supervisor) == final_tasks_before_get

    assert Jason.decode!(final_body) == Jason.decode!(final_body_again)
    assert {:ok, final_view} = Elzoo.Wave4ChannelExample.view(fixture.host, scope)
    assert final_view.event_waits.waits |> hd() |> Map.get(:correlation_id) == original_ticket
    assert final_view.event_waits.waits |> hd() |> Map.get(:occurrence) == original_occurrence
    assert length(Enum.filter(final_view.messages, &(&1.role == "assistant"))) == 1

    assert Enum.any?(
             final_view.messages,
             &(&1.message_id == Elzoo.Wave4ChannelTestHelper.answer_id(primary_id) and
                 &1.text == expected_answer(reply_event))
           )

    assert {:ok, %{revision: 5}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, %{revision: 5}} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
  end

  @tag :reply_source
  @tag :reply_round
  test "post-association answer preflight retries an unavailable read before native delivery", %{
    fixture: fixture
  } do
    trace_native_hash(fixture.native.task_supervisor)

    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    primary_event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "preflight-primary"})

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    assert {:observed, _} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, %{event_waits: %{waits: [wait]}}} =
             Elzoo.Wave4ChannelExample.view(fixture.host, scope)

    assert wait.status == :waiting

    resource_scope = %{
      tenant: fixture.profile.tenant,
      actor: fixture.profile.actor,
      resources: [fixture.profile.conversation_id]
    }

    assert {:ok, primary_resource} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    assert {:ok, [primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "preflight-reply",
        "input_id" => wait.correlation_id,
        "expected_revision" => primary_resource.revision,
        "text" => "Retained before preflight refusal."
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert {:ok, [^primary_item, reply_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:reply_observed, _} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, 4} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    state = :sys.get_state(fixture.host)
    engine = state.engine
    assert state.phase == :reply_input

    assert {:ok, before_head} =
             Elzoo.DurableLog.Store.read(
               fixture.command_store,
               :head,
               [Elzoo.Wave4ChannelTestHelper.command_stream(fixture.profile.tenant)]
             )

    assert {:ok, before_resource} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    assert before_resource.revision == state.reply.association_revision
    assert {:ok, before_native_status} = Elzoo.RunEngine.status(engine)
    children_before = Task.Supervisor.children(fixture.native.task_supervisor)
    assert children_before == []
    assert take_hash_calls() == []

    # v2 delivers the association and runs the preflight in one advance; a
    # command-head fault never survives the delivery pass. The preflight's
    # conversation scan is the evidence read it performs and delivery does
    # not. A read that failed decides nothing: the step is retried, and
    # nothing is written.
    Elzoo.DurableLog.PostgresHarness.hook(fixture.conversation_store, :inject, [:read, :unavailable])

    assert {:error, :unavailable} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert :sys.get_state(fixture.host).poison == nil
    assert take_hash_calls() == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == children_before

    assert Elzoo.DurableLog.Store.read(
             fixture.command_store,
             :head,
             [Elzoo.Wave4ChannelTestHelper.command_stream(fixture.profile.tenant)]
           ) == {:ok, before_head}

    assert Elzoo.CheckedCommand.resource(
             fixture.handles.input,
             resource_scope,
             fixture.profile.conversation_id
           ) == {:ok, before_resource}

    assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == {:ok, [primary_item, reply_item]}

    assert {:ok, %{waits: [pending_wait]}} =
             Elzoo.RunEngine.event_waits(
               engine,
               %{
                 tenant: fixture.profile.tenant,
                 principal: fixture.profile.actor,
                 run_id: state.current.run_id
               },
               %{max_records: 2_048, max_bytes: 16_777_216}
             )

    assert pending_wait.status == :waiting
    assert pending_wait.accepted_event == nil
    assert {:ok, after_native_status} = Elzoo.RunEngine.status(engine)
    assert after_native_status == before_native_status

    assert {:ok, %{state: :pending}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
               primary_item.idempotency_key
             ])

    assert {:ok, %{state: :pending}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
               reply_item.idempotency_key
             ])

    # The retried preflight reads, and the round completes.
    assert {:native_reply, :applied} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    advance_to_answer(fixture.host, System.monotonic_time(:millisecond) + 30_000, [])
    assert {:answered, _} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    reply_key = reply_item.idempotency_key
    assert {:reply_acknowledged, ^reply_key} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, _} = Elzoo.Wave4ChannelExample.advance(fixture.host)
  end

  @tag :reply_recovery
  test "completed v2 native result recovers after the profile deadline" do
    {:ok, clock_state} = Agent.start_link(fn -> System.system_time(:millisecond) end)
    on_exit(fn -> if Process.alive?(clock_state), do: Agent.stop(clock_state) end)
    clock = fn -> Agent.get(clock_state, & &1) end
    deadline = clock.() + 120_000

    fixture =
      Elzoo.Wave4ChannelTestHelper.reply_fixture(
        clock: clock,
        deadline_ms: deadline
      )

    {primary_listener, reply_listener} =
      Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    trace_native_hash(fixture.native.task_supervisor)

    primary_event =
      Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "recovery-after-deadline-primary"})

    primary_id = primary_event["input_id"]

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        primary_event["event_id"],
        primary_id
      )

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    assert {:observed, ^primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, %{event_waits: %{waits: [wait]}}} =
             Elzoo.Wave4ChannelExample.view(fixture.host, scope)

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "recovery-after-deadline-reply",
        "input_id" => wait.correlation_id,
        "expected_revision" => 2,
        "text" => "Recover the completed native result after deadline."
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert {:reply_observed, _} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, 4} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:native_reply, :applied} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    assert {:ok, [primary_item, reply_item]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    reply_key = reply_item.idempotency_key

    native_scope = %{
      tenant: fixture.profile.tenant,
      principal: fixture.profile.actor,
      run_id: run_id
    }

    assert {:ok, native_result} =
             wait_public_result(
               :sys.get_state(fixture.host).engine,
               native_scope,
               System.monotonic_time(:millisecond) + 10_000
             )

    assert native_result.run_id == run_id
    assert native_result.action_id == "hash"
    assert native_result.payload["answer"] == expected_answer(reply_event)
    assert {:result, :completed} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert take_hash_calls() == [reply_event["text"]]

    Agent.update(clock_state, fn _ -> deadline + 1 end)

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    {primary_listener, _reply_listener} =
      Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    recovered_steps =
      Enum.map(1..10, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    assert {:answered, 5} in recovered_steps
    assert Enum.any?(recovered_steps, &(&1 == {:reply_acknowledged, reply_key}))
    assert Enum.any?(recovered_steps, &(&1 == {:acknowledged, primary_id}))
    assert :sys.get_state(fixture.host).current == nil
    assert :sys.get_state(fixture.host).latest_native.run_id == run_id
    assert take_hash_calls() == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []

    answer_operation =
      Elzoo.Wave4ChannelTestHelper.answer_operation(
        fixture.profile,
        primary_event["event_id"],
        primary_id
      )

    assert {:completed, %{revision: 5}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.answer,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, answer_operation}
             )

    assert {:ok, %{state: :acked}} =
             Elzoo.DurableLog.Store.read(
               fixture.command_store,
               :read_ack,
               [primary_item.idempotency_key]
             )

    assert {:ok, %{state: :acked}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [reply_key])
  end

  @tag :native_expiry
  test "active v2 wait expires through one stable wake and retains its terminal reader" do
    {:ok, clock_state} = Agent.start_link(fn -> System.system_time(:millisecond) end)
    on_exit(fn -> if Process.alive?(clock_state), do: Agent.stop(clock_state) end)
    clock = fn -> Agent.get(clock_state, & &1) end
    deadline = clock.() + 120_000

    fixture =
      Elzoo.Wave4ChannelTestHelper.reply_fixture(
        clock: clock,
        deadline_ms: deadline
      )

    {primary_listener, reply_listener} =
      Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    trace_engine_input(fixture.host)
    trace_native_hash(fixture.native.task_supervisor)
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "active-wait-expiry"})
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)
    assert {:observed, ^input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)
    [activation_input_id] = take_engine_input_ids()
    refute activation_input_id == input_id
    wait = :sys.get_state(fixture.host).native_wait
    assert wait.status == :waiting
    assert take_hash_calls() == []

    original_run_status = RunApprovalRelease.status(fixture.owner, run_id)

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    trace_engine_input(fixture.host)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..10, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    recovery_input_ids = take_engine_input_ids()
    assert Enum.all?(recovery_input_ids, &(&1 == activation_input_id))

    recovered_state = :sys.get_state(fixture.host)
    assert recovered_state.current.run_id == run_id
    assert recovered_state.native_wait.status == :waiting
    assert recovered_state.native_wait.correlation_id == wait.correlation_id
    assert recovered_state.native_wait.occurrence == wait.occurrence
    assert recovered_state.native_wait.cursor == wait.cursor
    assert RunApprovalRelease.status(fixture.owner, run_id) == original_run_status
    assert take_hash_calls() == []

    Agent.update(clock_state, fn _ -> deadline + 1 end)
    assert {:native_expiry_wake, :applied} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    [expiry_id] = take_engine_input_ids()
    refute expiry_id == input_id

    scope = %{
      tenant: fixture.profile.tenant,
      principal: fixture.profile.actor,
      run_id: run_id
    }

    engine = :sys.get_state(fixture.host).engine

    assert {:terminal, outcome} =
             wait_public_result(engine, scope, System.monotonic_time(:millisecond) + 10_000)

    assert outcome in [:failed, :cancelled, :out_of_budget, :out_of_time]
    assert {:terminal, ^outcome} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert take_engine_input_ids() == []

    state = :sys.get_state(fixture.host)
    assert state.current == nil
    assert state.latest_native.run_id == run_id
    assert state.latest_native.engine == engine

    assert {:terminal, ^outcome} =
             RunEngine.result(engine, scope, %{max_records: 2_048, max_bytes: 16_777_216})

    assert take_hash_calls() == []

    head_before_get = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    resource_scope = %{
      tenant: fixture.profile.tenant,
      actor: fixture.profile.actor,
      resources: [fixture.profile.conversation_id]
    }

    resource_before_get =
      Elzoo.CheckedCommand.resource(
        fixture.handles.input,
        resource_scope,
        fixture.profile.conversation_id
      )

    assert {:ok, {{_, 200, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert {:ok, {{_, 200, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(reply_listener, fixture.profile.conversation_id)

    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == head_before_get

    assert Elzoo.CheckedCommand.resource(
             fixture.handles.input,
             resource_scope,
             fixture.profile.conversation_id
           ) == resource_before_get
  end

  @tag :native_expiry
  test "active v2 wait reopened after deadline reuses its original expiry wake" do
    {:ok, clock_state} = Agent.start_link(fn -> System.system_time(:millisecond) end)
    on_exit(fn -> if Process.alive?(clock_state), do: Agent.stop(clock_state) end)
    clock = fn -> Agent.get(clock_state, & &1) end
    deadline = clock.() + 120_000

    fixture =
      Elzoo.Wave4ChannelTestHelper.reply_fixture(
        clock: clock,
        deadline_ms: deadline
      )

    {primary_listener, reply_listener} =
      Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    trace_engine_input(fixture.host)
    trace_native_hash(fixture.native.task_supervisor)
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "expired-wait-reopen"})
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)

    assert {:observed, ^input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    [activation_input_id] = take_engine_input_ids()
    refute activation_input_id == input_id
    original_wait = :sys.get_state(fixture.host).native_wait
    assert original_wait.status == :waiting
    assert {:ok, original_run} = RunApprovalRelease.status(fixture.owner, run_id)
    original_attempt = original_run.current_attempt
    assert take_hash_calls() == []

    Agent.update(clock_state, fn _ -> deadline + 1 end)

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    {_primary_listener, _reply_listener} =
      Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    trace_engine_input(fixture.host)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    recovery_steps =
      Enum.reduce_while(1..12, [], fn _, steps ->
        result = Elzoo.Wave4ChannelExample.advance(fixture.host)
        next = [result | steps]

        if result == {:native_expiry_wake, :applied},
          do: {:halt, Enum.reverse(next)},
          else: {:cont, next}
      end)

    assert Enum.count(recovery_steps, &(&1 == {:native_expiry_wake, :applied})) == 1

    recovered_ids = take_engine_input_ids()
    expiry_ids = Enum.reject(recovered_ids, &(&1 == activation_input_id))
    assert [expiry_id] = Enum.uniq(expiry_ids)
    refute expiry_id == input_id
    assert take_hash_calls() == []

    recovered = :sys.get_state(fixture.host)
    assert recovered.current.run_id == run_id
    assert recovered.native_wait.correlation_id == original_wait.correlation_id
    assert recovered.native_wait.occurrence == original_wait.occurrence
    assert recovered.native_wait.cursor == original_wait.cursor

    assert {:ok, recovered_run} = RunApprovalRelease.status(fixture.owner, run_id)
    assert recovered_run.current_attempt == original_attempt
    assert recovered_run.attempts == original_run.attempts

    scope = %{tenant: fixture.profile.tenant, principal: fixture.profile.actor, run_id: run_id}
    engine = recovered.engine

    assert {:terminal, outcome} =
             wait_public_result(engine, scope, System.monotonic_time(:millisecond) + 10_000)

    assert {:terminal, ^outcome} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert take_engine_input_ids() == []
    assert take_hash_calls() == []

    assert {:terminal, ^outcome} =
             RunEngine.result(engine, scope, %{max_records: 2_048, max_bytes: 16_777_216})
  end

  @tag :native_expiry
  test "active v2 wait expiry excludes a pending reply ASK from acknowledgements" do
    {:ok, clock_state} = Agent.start_link(fn -> System.system_time(:millisecond) end)
    on_exit(fn -> if Process.alive?(clock_state), do: Agent.stop(clock_state) end)
    clock = fn -> Agent.get(clock_state, & &1) end
    deadline = clock.() + 120_000

    policy = fn mode, _event, _now ->
      Elzoo.Wave4ChannelTestHelper.policy(if(mode == :reply_input, do: :ask, else: :allow))
    end

    fixture =
      Elzoo.Wave4ChannelTestHelper.reply_fixture(
        clock: clock,
        deadline_ms: deadline,
        policy: policy
      )

    {primary_listener, reply_listener} =
      Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    trace_native_hash(fixture.native.task_supervisor)
    primary = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "expiry-pending-ask"})
    primary_id = primary["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, primary["event_id"], primary_id)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary)
    assert {:observed, ^primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)
    wait = :sys.get_state(fixture.host).native_wait
    assert wait.status == :waiting

    assert {:ok, [primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert primary_item.destination == "wave4-channel-input"
    primary_key = primary_item.idempotency_key
    primary_nonce = primary_item.nonce

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "expiry-pending-reply-ask",
        "input_id" => wait.correlation_id,
        "expected_revision" => 2,
        "text" => "An ASK is not a committed reply."
      })

    reply_operation =
      Elzoo.Wave4ChannelTestHelper.reply_operation(fixture.profile, reply_event["event_id"])

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert {:approval_pending, %{key: ask_key}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.reply_input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, reply_operation}
             )

    assert Map.get(:sys.get_state(fixture.host).reply, :item) == nil

    Enum.each(1..3, fn _ ->
      assert {:pending, :event_waiting} = Elzoo.Wave4ChannelExample.advance(fixture.host)
      assert :sys.get_state(fixture.host).phase == :result
      assert Map.get(:sys.get_state(fixture.host).reply, :item) == nil
    end)

    Agent.update(clock_state, fn _ -> deadline + 1 end)
    assert {:native_expiry_wake, :applied} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    scope = %{
      tenant: fixture.profile.tenant,
      principal: fixture.profile.actor,
      run_id: run_id
    }

    engine = :sys.get_state(fixture.host).engine

    assert {:terminal, outcome} =
             wait_public_result(engine, scope, System.monotonic_time(:millisecond) + 10_000)

    assert outcome in [:failed, :cancelled, :out_of_budget, :out_of_time]
    assert {:terminal, ^outcome} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    state = :sys.get_state(fixture.host)
    assert state.current == nil
    assert state.reply.release_state == :pending
    assert state.reply.key == ask_key
    assert state.latest_native.run_id == run_id

    assert {:approval_pending, %{key: ^ask_key}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.reply_input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, reply_operation}
             )

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, %{state: :acked, nonce: ^primary_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
               primary_key
             ])

    assert take_hash_calls() == []
  end

  @tag :native_recovery
  test "v2 GET stays read-only and unavailable until a fenced owner replacement" do
    {:ok, calls} =
      Agent.start_link(fn ->
        %{now: System.system_time(:millisecond), clock: 0, policy: 0, authority: 0}
      end)

    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    clock = fn ->
      Agent.get_and_update(calls, fn state ->
        {state.now, %{state | clock: state.clock + 1}}
      end)
    end

    policy = fn _mode, _event, _now ->
      Agent.update(calls, &%{&1 | policy: &1.policy + 1})
      Elzoo.Wave4ChannelTestHelper.policy()
    end

    authority = fn _mode, _event, _request, _facts ->
      Agent.update(calls, &%{&1 | authority: &1.authority + 1})
      %{}
    end

    fixture =
      Elzoo.Wave4ChannelTestHelper.reply_fixture(
        clock: clock,
        policy: policy,
        authority: authority
      )

    {primary_listener, reply_listener} =
      Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    trace_native_hash(fixture.native.task_supervisor)
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "owner-unavailable-primary"})
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)
    assert {:observed, ^input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    assert {:ok, %{event_waits: %{waits: [original_wait]}}} =
             Elzoo.Wave4ChannelExample.view(
               fixture.host,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
             )

    assert original_wait.status == :waiting
    assert {:ok, original_run} = RunApprovalRelease.status(fixture.owner, run_id)
    assert {:ok, original_head} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    resource_scope = %{
      tenant: fixture.profile.tenant,
      actor: fixture.profile.actor,
      resources: [fixture.profile.conversation_id]
    }

    original_resource =
      Elzoo.CheckedCommand.resource(
        fixture.handles.input,
        resource_scope,
        fixture.profile.conversation_id
      )

    old_engine = :sys.get_state(fixture.host).engine
    Process.exit(fixture.owner, :kill)
    refute Process.alive?(fixture.owner)

    calls_before_get = Agent.get(calls, & &1)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(reply_listener, fixture.profile.conversation_id)

    assert Agent.get(calls, & &1) == calls_before_get
    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == {:ok, original_head}

    assert Elzoo.CheckedCommand.resource(
             fixture.handles.input,
             resource_scope,
             fixture.profile.conversation_id
           ) == original_resource

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(
               fixture,
               [primary_listener, reply_listener]
             )

    assert not Process.alive?(old_engine)
    assert :not_found = Elzoo.DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    calls_before_recovery_get = Agent.get(calls, & &1)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(reply_listener, fixture.profile.conversation_id)

    assert Agent.get(calls, & &1) == calls_before_recovery_get
    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == {:ok, original_head}

    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..8, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    recovered_state = :sys.get_state(fixture.host)
    assert recovered_state.current.run_id == run_id
    assert recovered_state.native_wait.correlation_id == original_wait.correlation_id
    assert recovered_state.native_wait.cursor == original_wait.cursor
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert take_hash_calls() == []

    assert {:ok, recovered_run} = RunApprovalRelease.status(fixture.owner, run_id)
    assert recovered_run.id == original_run.id
    assert recovered_run.current_attempt == original_run.current_attempt
    assert recovered_run.attempts == original_run.attempts
  end

  @tag :reply_recovery
  test "recovery fences unknown reply IDs but restores the exact pending ASK" do
    policy = fn mode, _event, _now ->
      Elzoo.Wave4ChannelTestHelper.policy(
        if(mode in [:reply_input, :reply_release], do: :ask, else: :allow)
      )
    end

    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture(policy: policy)
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    trace_native_hash(fixture.native.task_supervisor)

    primary_event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "ambiguous-ask-primary"})
    primary_id = primary_event["input_id"]

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        primary_event["event_id"],
        primary_id
      )

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    assert {:observed, ^primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, %{event_waits: %{waits: [activation_wait]}}} =
             Elzoo.Wave4ChannelExample.view(fixture.host, scope)

    assert activation_wait.status == :waiting
    assert {:ok, [primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "ambiguous-ask-reply",
        "input_id" => activation_wait.correlation_id,
        "expected_revision" => 2,
        "text" => "Recover this exact pending ASK."
      })

    reply = normalized_event(reply_event)

    reply_operation =
      Elzoo.Wave4ChannelTestHelper.reply_operation(fixture.profile, reply_event["event_id"])

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert {:approval_pending, %{key: pending_key}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.reply_input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, reply_operation}
             )

    assert {:ok, [^primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:ok, ask_head} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert ask_head.revision > activation_wait.cursor
    assert take_hash_calls() == []

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert {:observed, ^primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..8, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    recovered = :sys.get_state(fixture.host)
    assert recovered.current.run_id == run_id
    assert recovered.phase == :result
    assert recovered.reply == nil
    assert recovered.ambiguous_reply

    assert {:ok, %{event_waits: %{waits: [restored_wait]}}} =
             Elzoo.Wave4ChannelExample.view(fixture.host, scope)

    assert restored_wait.status == :waiting
    assert restored_wait.cursor == activation_wait.cursor
    assert restored_wait.correlation_id == activation_wait.correlation_id

    trace_native_hash(fixture.native.task_supervisor)
    head_before_refusal = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    resource_scope = %{
      tenant: fixture.profile.tenant,
      actor: fixture.profile.actor,
      resources: [fixture.profile.conversation_id]
    }

    assert {:ok, resource_before_refusal} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    units_before_refusal =
      Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])

    fresh_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "ambiguous-ask-other-id",
        "input_id" => restored_wait.correlation_id,
        "expected_revision" => resource_before_refusal.revision,
        "text" => "Must remain fenced."
      })

    fresh_operation =
      Elzoo.Wave4ChannelTestHelper.reply_operation(fixture.profile, fresh_event["event_id"])

    assert {:ok, {{_, 409, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, fresh_event)

    assert {:unknown, :not_observed} =
             Elzoo.CheckedCommand.result(
               fixture.handles.reply_input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, fresh_operation}
             )

    assert :sys.get_state(fixture.host).ambiguous_reply
    assert :sys.get_state(fixture.host).reply == nil
    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == head_before_refusal

    assert Elzoo.CheckedCommand.resource(
             fixture.handles.input,
             resource_scope,
             fixture.profile.conversation_id
           ) == {:ok, resource_before_refusal}

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, []) ==
             units_before_refusal

    assert {:ok, [^primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert take_hash_calls() == []

    changed_event = Map.put(reply_event, "text", "changed request bytes")

    assert {:ok, {{_, 409, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, changed_event)

    assert :sys.get_state(fixture.host).ambiguous_reply
    assert :sys.get_state(fixture.host).reply == nil
    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == head_before_refusal

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    restored_ask = :sys.get_state(fixture.host)
    assert restored_ask.ambiguous_reply == false
    assert restored_ask.reply.event == reply

    assert restored_ask.reply.request == %{
             operation_id: reply_operation,
             resource: fixture.profile.conversation_id,
             expected_revision: reply.expected_revision,
             payload: %{"message_id" => reply.input_id, "text" => reply.text}
           }

    assert restored_ask.reply.wait.correlation_id == activation_wait.correlation_id

    assert {:approval_pending, %{key: ^pending_key}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.reply_input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, reply_operation}
             )

    evidence =
      release_envelope(
        fixture.profile,
        pending_key,
        System.system_time(:millisecond),
        "ambiguous-ask-release"
      )

    assert {:committed, 3} =
             Elzoo.Wave4ChannelExample.release_reply(fixture.host, reply, scope, evidence)

    assert {:ok, [^primary_item, reply_item]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    reply_key = reply_item.idempotency_key
    assert {:reply_observed, ^reply_key} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, 4} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:native_reply, :applied} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    native_scope = %{
      tenant: fixture.profile.tenant,
      principal: fixture.profile.actor,
      run_id: run_id
    }

    assert {:ok, _} =
             wait_public_result(
               :sys.get_state(fixture.host).engine,
               native_scope,
               System.monotonic_time(:millisecond) + 10_000
             )

    assert {:result, :completed} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert take_hash_calls() == [reply.text]
    assert {:answered, 5} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:reply_acknowledged, ^reply_key} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, final_view} = Elzoo.Wave4ChannelExample.view(fixture.host, scope)
    assert length(Enum.filter(final_view.messages, &(&1.role == "assistant"))) == 1

    assert Enum.any?(final_view.messages, fn message ->
             message.message_id ==
               Elzoo.Wave4ChannelTestHelper.answer_id(primary_id) and
               message.text == expected_answer(reply_event)
           end)
  end

  @tag :reply_recovery
  test "fenced v2 reply input cut preserves the original run without retrying uncertain work" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    token = make_ref()
    fixture = host_with_native_hash_barrier(fixture, self(), token)
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    trace_native_hash(fixture.native.task_supervisor)

    primary_event =
      Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "uncertain-reply-input-primary"})

    primary_id = primary_event["input_id"]

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        primary_event["event_id"],
        primary_id
      )

    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)
    attempt_id = Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    assert {:observed, ^primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, %{event_waits: %{waits: [wait]}}} =
             Elzoo.Wave4ChannelExample.view(fixture.host, scope)

    assert wait.status == :waiting
    reply_text = "preserve the original accepted event across a lost hash result"

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "uncertain-reply-input-reply",
        "input_id" => wait.correlation_id,
        "expected_revision" => 2,
        "text" => reply_text
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert {:reply_observed, _} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, 4} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    state_before_input = :sys.get_state(fixture.host)
    assert state_before_input.current.run_id == run_id
    assert state_before_input.phase == :reply_input

    assert {:native_reply, :applied} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    native_input_id = :sys.get_state(fixture.host).reply.native_input_id
    assert_receive {:wave4_native_hash_blocked, task_pid, ^token, expected}, 5_000
    assert expected == %{"answer" => expected_answer(reply_event)}
    assert Process.alive?(task_pid)
    assert task_pid in Task.Supervisor.children(fixture.native.task_supervisor)
    assert take_hash_calls() == [reply_text]

    native_scope = %{
      tenant: fixture.profile.tenant,
      principal: fixture.profile.actor,
      run_id: run_id
    }

    assert {:pending, _reason} =
             Elzoo.RunEngine.result(
               :sys.get_state(fixture.host).engine,
               native_scope,
               %{max_records: 2_048, max_bytes: 16_777_216}
             )

    assert {:ok, run_before_fence} =
             Elzoo.RunApprovalRelease.status(fixture.native.run_owner, run_id)

    assert run_before_fence.current_attempt == attempt_id
    assert run_before_fence.attempts == [attempt_id]

    assert {:ok, [primary_item, reply_item]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    {primary_listener, _reply_listener} =
      Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    assert :not_found = Elzoo.DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..8, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    recovered = :sys.get_state(fixture.host)
    assert recovered.current.run_id == run_id
    assert recovered.reply.native_input_id == native_input_id
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert take_hash_calls() == []

    assert {:ok, run_after_recovery} =
             Elzoo.RunApprovalRelease.status(fixture.native.run_owner, run_id)

    assert run_after_recovery.current_attempt == run_before_fence.current_attempt
    assert run_after_recovery.attempts == run_before_fence.attempts

    assert {:ok, [^primary_item, ^reply_item | _]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, %{state: :pending, nonce: primary_nonce}} =
             Elzoo.DurableLog.Store.read(
               fixture.command_store,
               :read_ack,
               [primary_item.idempotency_key]
             )

    assert {:ok, %{state: :pending, nonce: reply_nonce}} =
             Elzoo.DurableLog.Store.read(
               fixture.command_store,
               :read_ack,
               [reply_item.idempotency_key]
             )

    assert is_binary(primary_nonce)
    assert is_binary(reply_nonce)
  end

  @tag :reply_recovery
  test "v2 activation reply loss recovers the original wake only after full owner replacement" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "activation-reply-loss"})
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)

    trace_engine_input(fixture.host)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)

    assert {:observed, ^input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, attempt_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, _unit_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:ok, run_before} = RunApprovalRelease.status(fixture.owner, run_id)

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.native.unit_store,
               :inject,
               [:append, :reply_loss]
             )

    assert {:unknown, :native_input} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    [activation_id] = take_engine_input_ids()
    assert activation_id != input_id

    assert {:blocked, :provider_owner_replacement} =
             Elzoo.Wave4ChannelExample.advance(fixture.host)

    assert take_hash_calls() == []

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(reply_listener, fixture.profile.conversation_id)

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    trace_engine_input(fixture.host)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    recovery_steps = Enum.map(1..10, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)
    assert Enum.member?(recovery_steps, {:run_recovered, run_id})

    recovered = :sys.get_state(fixture.host)
    assert recovered.current.run_id == run_id
    assert recovered.native_wait.status == :waiting
    assert Enum.all?(take_engine_input_ids(), &(&1 == activation_id))
    assert take_hash_calls() == []

    assert {:ok, run_after} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_after.id == run_before.id
    assert run_after.operation_id == run_before.operation_id
    assert run_after.attempts == run_before.attempts
    assert run_after.current_attempt == attempt_id
  end

  @tag :reply_recovery
  test "v2 paused activation provider writer prevents same-host engine replacement" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "activation-paused-writer"})
    input_id = event["input_id"]
    run_id = Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], input_id)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)

    assert {:observed, ^input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, attempt_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, _} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    engine = :sys.get_state(fixture.host).engine
    trace_engine_input(fixture.host)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:ok, _unit} = Elzoo.DynamicUnits.find(fixture.directory, unit_id)
    before = native_store_snapshot(fixture.native.unit_store)
    token = :wave4_v2_activation_writer

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.native.unit_store,
               :inject,
               [:append, {:pause, token}]
             )

    caller = Task.async(fn -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    writer =
      wait_for_paused(fixture.native_controller, token, System.monotonic_time(:millisecond) + 5_000)

    assert writer.operation == :append
    assert is_integer(writer.backend)
    assert Process.alive?(writer.pid)
    assert {:unknown, :native_input} = Task.await(caller, 10_000)
    assert take_engine_input_ids() == [Elzoo.Wave4ChannelTestHelper.native_input_id(run_id)]
    native_state_after_timeout = :sys.get_state(fixture.host)
    registered_after_timeout = Registry.lookup(fixture.native.registry, unit_id)
    unit_after_timeout = Elzoo.DynamicUnits.find(fixture.directory, unit_id)
    tasks_while_paused = Task.Supervisor.children(fixture.native.task_supervisor)

    assert {:blocked, :provider_owner_replacement} =
             Elzoo.Wave4ChannelExample.advance(fixture.host)

    assert Process.alive?(writer.pid)
    assert :sys.get_state(fixture.host).engine == native_state_after_timeout.engine
    assert Registry.lookup(fixture.native.registry, unit_id) == registered_after_timeout
    assert Elzoo.DynamicUnits.find(fixture.directory, unit_id) == unit_after_timeout
    assert Task.Supervisor.children(fixture.native.task_supervisor) == tasks_while_paused
    assert take_engine_input_ids() == []

    assert native_store_snapshot(fixture.native.unit_store) == before

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(reply_listener, fixture.profile.conversation_id)

    assert take_hash_calls() == []
    writer_ref = Process.monitor(writer.pid)

    assert {:committed, _revision} =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :release, [token])

    assert_receive {:DOWN, ^writer_ref, :process, _, _}, 5_000

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    refute Process.alive?(engine)
    assert :not_found = Elzoo.DynamicUnits.find(fixture.directory, unit_id)
    assert Registry.lookup(fixture.native.registry, unit_id) == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []

    trace_engine_input(fixture.host)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..10, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)
    recovered = :sys.get_state(fixture.host)
    assert recovered.current.run_id == run_id
    assert recovered.native_wait.status == :waiting
    assert {:ok, recovered_run} = RunApprovalRelease.status(fixture.owner, run_id)
    assert recovered_run.current_attempt == attempt_id

    assert Enum.all?(
             take_engine_input_ids(),
             &(&1 == Elzoo.Wave4ChannelTestHelper.native_input_id(run_id))
           )

    assert take_hash_calls() == []

    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    native_scope = %{
      tenant: fixture.profile.tenant,
      principal: fixture.profile.actor,
      run_id: run_id
    }

    view_scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, %{event_waits: %{waits: [wait]}}} =
             Elzoo.Wave4ChannelExample.view(fixture.host, view_scope)

    resource_scope = %{
      tenant: fixture.profile.tenant,
      actor: fixture.profile.actor,
      resources: [fixture.profile.conversation_id]
    }

    assert {:ok, resource} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    reply_text = "Paused provider reply remains on its original event."

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "reply-paused-writer",
        "input_id" => wait.correlation_id,
        "expected_revision" => resource.revision,
        "text" => reply_text
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert {:reply_observed, reply_key} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, _revision} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:ok, _unit} = Elzoo.DynamicUnits.find(fixture.directory, unit_id)
    before_reply = native_store_snapshot(fixture.native.unit_store)
    reply_token = :wave4_v2_reply_writer

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.native.unit_store,
               :inject,
               [:append, {:pause, reply_token}]
             )

    reply_caller = Task.async(fn -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    reply_writer =
      wait_for_paused(
        fixture.native_controller,
        reply_token,
        System.monotonic_time(:millisecond) + 5_000
      )

    assert reply_writer.operation == :append
    assert is_integer(reply_writer.backend)
    assert Process.alive?(reply_writer.pid)
    assert {:unknown, :native_reply} = Task.await(reply_caller, 10_000)
    reply_state_after_timeout = :sys.get_state(fixture.host)
    reply_registry_after_timeout = Registry.lookup(fixture.native.registry, unit_id)
    reply_unit_after_timeout = Elzoo.DynamicUnits.find(fixture.directory, unit_id)
    reply_tasks_after_timeout = Task.Supervisor.children(fixture.native.task_supervisor)
    [native_reply_input_id] = take_engine_input_ids()

    assert {:blocked, :provider_owner_replacement} =
             Elzoo.Wave4ChannelExample.advance(fixture.host)

    assert Process.alive?(reply_writer.pid)
    assert :sys.get_state(fixture.host).engine == reply_state_after_timeout.engine
    assert Registry.lookup(fixture.native.registry, unit_id) == reply_registry_after_timeout
    assert Elzoo.DynamicUnits.find(fixture.directory, unit_id) == reply_unit_after_timeout
    assert Task.Supervisor.children(fixture.native.task_supervisor) == reply_tasks_after_timeout
    assert take_engine_input_ids() == []

    assert native_store_snapshot(fixture.native.unit_store) ==
             before_reply

    assert take_hash_calls() == []

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(reply_listener, fixture.profile.conversation_id)

    reply_writer_ref = Process.monitor(reply_writer.pid)

    assert {:committed, _revision} =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.native.unit_store,
               :release,
               [reply_token]
             )

    assert_receive {:DOWN, ^reply_writer_ref, :process, _, _}, 5_000
    hashes_before_reply_reopen = take_hash_calls()
    assert hashes_before_reply_reopen in [[], [reply_text]]

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    trace_engine_input(fixture.host)
    trace_native_hash(fixture.native.task_supervisor)
    assert {:observed, ^input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    recovered_steps =
      Enum.reduce_while(1..10, [], fn _, steps ->
        step = Elzoo.Wave4ChannelExample.advance(fixture.host)
        state = :sys.get_state(fixture.host)
        steps = [step | steps]

        if is_map(state.reply) and state.reply.native_input_id == native_reply_input_id,
          do: {:halt, Enum.reverse(steps)},
          else: {:cont, steps}
      end)

    assert recovered_steps != []
    recovered = :sys.get_state(fixture.host)
    assert recovered.current.run_id == run_id
    assert recovered.reply.item.idempotency_key == reply_key
    assert recovered.reply.native_input_id == native_reply_input_id

    recovered_engine = recovered.engine

    assert {:ok, _native_result} =
             wait_public_result(
               recovered_engine,
               native_scope,
               System.monotonic_time(:millisecond) + 10_000
             )

    assert hashes_before_reply_reopen ++ take_hash_calls() == [reply_text]

    assert {:ok, %{event_waits: %{waits: [accepted_wait]}}} =
             Elzoo.Wave4ChannelExample.view(fixture.host, view_scope)

    assert accepted_wait.accepted_event.event_id == reply_key
    assert accepted_wait.accepted_event.input_id == native_reply_input_id
  end

  @tag :reply_recovery
  test "v2 superseded reply acknowledgement stays fenced before primary acknowledgement" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    primary_event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "reply-ack-superseded"})
    primary_id = primary_event["input_id"]

    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    assert {:observed, ^primary_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, %{event_waits: %{waits: [wait]}}} =
             Elzoo.Wave4ChannelExample.view(fixture.host, scope)

    resource_scope = %{
      tenant: fixture.profile.tenant,
      actor: fixture.profile.actor,
      resources: [fixture.profile.conversation_id]
    }

    assert {:ok, resource} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               resource_scope,
               fixture.profile.conversation_id
             )

    reply_text = "Superseded ACK must not advance to the primary."

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "reply-ack-superseded-reply",
        "input_id" => wait.correlation_id,
        "expected_revision" => resource.revision,
        "text" => reply_text
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert {:reply_observed, _reply_key} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    steps =
      Enum.reduce_while(1..16, [], fn _, steps ->
        step = Elzoo.Wave4ChannelExample.advance(fixture.host)
        state = :sys.get_state(fixture.host)
        steps = [step | steps]

        if state.phase == :reply_ack,
          do: {:halt, Enum.reverse(steps)},
          else: {:cont, steps}
      end)

    assert Enum.any?(steps, &match?({:answered, _}, &1))
    assert :sys.get_state(fixture.host).phase == :reply_ack

    # The answer's delivery item is still pending at the halt, ahead of the
    # primary and reply items; the rollback targets the reply item's key so
    # that it lands on the reply acknowledgement, as on the harness before.
    assert {:ok, [primary_item, reply_item | _]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert take_hash_calls() == [reply_text]

    other_nonce = :crypto.strong_rand_bytes(16)
    primary_nonce = primary_item.nonce
    reply_nonce = reply_item.nonce
    refute other_nonce == reply_item.nonce

    probe = probe_host_command_store!(fixture)
    reply_key = reply_item.idempotency_key
    Elzoo.Wave4ChannelTest.ReadProbe.fault(probe, :ack, reply_key, :rollback)

    assert {:unknown, :reply_ack} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert Elzoo.Wave4ChannelTest.ReadProbe.faults(probe) == %{}

    # A SQL rollback: the forwarded acknowledgement reached its commit barrier,
    # rolled back there, and left the item pending.
    assert [{^reply_key, phases}] = Elzoo.Wave4ChannelTest.ReadProbe.rollbacks(probe)
    assert {:ack, :before_commit} in phases
    assert Map.get(Agent.get(fixture.controller, & &1.faults), :ack) == nil

    assert {:ok, %{state: :pending, nonce: ^reply_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [reply_key])

    assert {:committed, _} =
             Elzoo.Outbox.ack(fixture.command_store, reply_item.idempotency_key, other_nonce)

    assert {:unknown, :reply_ack} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert :sys.get_state(fixture.host).poison != nil

    assert {:ok, %{state: :acked, nonce: ^reply_nonce, ack_nonce: ^other_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
               reply_item.idempotency_key
             ])

    assert {:ok, %{state: :pending, nonce: ^primary_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
               primary_item.idempotency_key
             ])

    assert {:ok, [^primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert take_hash_calls() == []
  end

  @tag :reply_release
  @tag :capacity_headroom
  test "v2 primary and reply ASK release the saved identities through ordered acknowledgements" do
    {:ok, control} =
      Agent.start_link(fn ->
        %{now: System.system_time(:millisecond), clock: 0, policy: 0, authority: 0}
      end)

    on_exit(fn -> if Process.alive?(control), do: Agent.stop(control) end)

    clock = fn ->
      Agent.get_and_update(control, fn state ->
        {state.now, %{state | clock: state.clock + 1}}
      end)
    end

    policy = fn mode, _event, _now ->
      Agent.update(control, &%{&1 | policy: &1.policy + 1})
      verdict = if mode in [:input, :reply_input, :release, :reply_release], do: :ask, else: :allow
      Elzoo.Wave4ChannelTestHelper.policy(verdict)
    end

    initial_now = Agent.get(control, & &1.now)
    deadline = initial_now + 120_000

    fixture =
      Elzoo.Wave4ChannelTestHelper.reply_fixture(
        clock: clock,
        deadline_ms: deadline,
        policy: policy
      )

    seed_refusals_to_head!(fixture, 1017, "exact-primary")

    base_authority = Keyword.fetch!(fixture.host_options, :authority)

    authority = fn mode, event, request, facts ->
      Agent.update(control, &%{&1 | authority: &1.authority + 1})
      base_authority.(mode, event, request, facts)
    end

    :sys.replace_state(fixture.host, &%{&1 | authority: authority})
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    refute primary_listener.port == reply_listener.port
    trace_native_hash(fixture.native.task_supervisor)

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    primary_event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "ask-release-primary"})
    primary = normalized_event(primary_event)

    primary_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, primary_event["event_id"])

    primary_identity = {fixture.profile.tenant, fixture.profile.actor, primary_operation}

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    assert {:approval_pending, %{key: primary_key, requirement: primary_requirement}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               primary_identity
             )

    primary_evidence = release_envelope(fixture.profile, primary_key, initial_now, "primary-ask")
    primary_head = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert primary_head == {:ok, %{revision: 1018, low_water: 0}}

    assert {:rejected, :invalid} =
             Elzoo.Wave4ChannelExample.release(
               fixture.host,
               primary,
               scope,
               %{primary_evidence | purpose: :read}
             )

    assert {:rejected, :conflict} =
             Elzoo.Wave4ChannelExample.release(
               fixture.host,
               %{primary | text: "changed primary bytes"},
               scope,
               primary_evidence
             )

    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == primary_head

    assert {:approval_pending, %{key: ^primary_key, requirement: ^primary_requirement}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               primary_identity
             )

    assert {:committed, 1} =
             Elzoo.Wave4ChannelExample.release(fixture.host, primary, scope, primary_evidence)

    assert take_hash_calls() == []
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert {:observed, primary_input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert primary_input_id == primary.input_id
    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    assert %{waits: [wait]} =
             Elzoo.Wave4ChannelExample.view(fixture.host, scope) |> elem(1) |> Map.get(:event_waits)

    assert wait.status == :waiting
    assert {:ok, [primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    seed_refusals_to_head!(fixture, 1020, "exact-reply")

    assert {:ok, %{revision: 1020, low_water: 0}} =
             Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    reply_text = String.duplicate("r", 4096)
    assert byte_size(reply_text) == 4096

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "ask-release-reply",
        "input_id" => wait.correlation_id,
        "expected_revision" => 2,
        "text" => reply_text
      })

    reply = normalized_event(reply_event)

    reply_operation =
      Elzoo.Wave4ChannelTestHelper.reply_operation(fixture.profile, reply_event["event_id"])

    reply_identity = {fixture.profile.tenant, fixture.profile.actor, reply_operation}

    assert {:ok, {{_, 202, _}, _, reply_receipt}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert %{"status" => "pending_approval"} = Jason.decode!(reply_receipt)

    assert {:approval_pending, %{key: reply_key, requirement: reply_requirement}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.reply_input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               reply_identity
             )

    reply_evidence = release_envelope(fixture.profile, reply_key, initial_now, "reply-ask")
    reply_head = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert reply_head == {:ok, %{revision: 1021, low_water: 0}}

    assert {:ok, reply_resource_before_advance} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               %{
                 tenant: fixture.profile.tenant,
                 actor: fixture.profile.actor,
                 resources: [fixture.profile.conversation_id]
               },
               fixture.profile.conversation_id
             )

    native_units_before_second_reply =
      Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])

    tasks_before_second_reply = Task.Supervisor.children(fixture.native.task_supervisor)

    Enum.each(1..3, fn _ ->
      assert {:pending, :event_waiting} = Elzoo.Wave4ChannelExample.advance(fixture.host)

      pending_state = :sys.get_state(fixture.host)
      assert pending_state.phase == :result
      assert is_nil(Map.get(pending_state.reply, :item))
      assert is_nil(Map.get(pending_state.reply, :association_revision))

      assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == reply_head
      assert {:ok, [^primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

      assert {:ok, ^reply_resource_before_advance} =
               Elzoo.CheckedCommand.resource(
                 fixture.handles.input,
                 %{
                   tenant: fixture.profile.tenant,
                   actor: fixture.profile.actor,
                   resources: [fixture.profile.conversation_id]
                 },
                 fixture.profile.conversation_id
               )

      assert Elzoo.DurableLog.PostgresHarness.hook(
               fixture.native.unit_store,
               :snapshot,
               []
             ) == native_units_before_second_reply

      assert Task.Supervisor.children(fixture.native.task_supervisor) == tasks_before_second_reply
    end)

    second_reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "ask-release-reply-second",
        "input_id" => wait.correlation_id,
        "expected_revision" => 2,
        "text" => "A second reply must not be admitted while the first is waiting for release."
      })

    second_reply_operation =
      Elzoo.Wave4ChannelTestHelper.reply_operation(
        fixture.profile,
        second_reply_event["event_id"]
      )

    assert {:ok, {{_, 409, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, second_reply_event)

    assert {:unknown, :not_observed} =
             Elzoo.CheckedCommand.result(
               fixture.handles.reply_input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, second_reply_operation}
             )

    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == reply_head
    assert {:ok, [^primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, []) ==
             native_units_before_second_reply

    assert Task.Supervisor.children(fixture.native.task_supervisor) == tasks_before_second_reply
    assert take_hash_calls() == []

    assert {:ok, %{event_waits: %{waits: [unchanged_wait]}}} =
             Elzoo.Wave4ChannelExample.view(fixture.host, scope)

    assert unchanged_wait.status == :waiting
    assert unchanged_wait.correlation_id == wait.correlation_id

    changed_reply = %{reply | text: "changed reply bytes"}

    assert {:rejected, :invalid} =
             Elzoo.Wave4ChannelExample.release_reply(
               fixture.host,
               reply,
               scope,
               %{reply_evidence | purpose: :read}
             )

    assert {:rejected, :conflict} =
             Elzoo.Wave4ChannelExample.release_reply(
               fixture.host,
               changed_reply,
               scope,
               reply_evidence
             )

    stale_evidence =
      put_in(reply_evidence.evidence.request, put_elem(reply_key, 4, elem(reply_key, 4) + 1))

    assert match?(
             {:rejected, _},
             Elzoo.Wave4ChannelExample.release_reply(
               fixture.host,
               reply,
               scope,
               stale_evidence
             )
           )

    stale_time_evidence = %{
      reply_evidence
      | evidence: %{
          reply_evidence.evidence
          | issued_at: initial_now - 60_001,
            expiry: initial_now + 60_000
        }
    }

    assert {:rejected, :forbidden} =
             Elzoo.Wave4ChannelExample.release_reply(
               fixture.host,
               reply,
               scope,
               stale_time_evidence
             )

    {:ok, revoked} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(revoked), do: Agent.stop(revoked) end)

    revoked_authority = fn mode, event, request, facts ->
      context = base_authority.(mode, event, request, facts)

      if mode in [:release, :reply_release],
        do: Map.put(context, :revoked, Agent.get(revoked, & &1)),
        else: context
    end

    :sys.replace_state(fixture.host, &%{&1 | authority: revoked_authority})

    Agent.update(revoked, fn _ ->
      [{reply_evidence.evidence.verifier, reply_evidence.evidence.evidence_id}]
    end)

    assert {:rejected, :forbidden} =
             Elzoo.Wave4ChannelExample.release_reply(fixture.host, reply, scope, reply_evidence)

    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == reply_head

    assert {:approval_pending, %{key: ^reply_key, requirement: ^reply_requirement}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.reply_input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               reply_identity
             )

    assert {:ok, ^reply_resource_before_advance} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               %{
                 tenant: fixture.profile.tenant,
                 actor: fixture.profile.actor,
                 resources: [fixture.profile.conversation_id]
               },
               fixture.profile.conversation_id
             )

    assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == {:ok, [primary_item]}
    assert Task.Supervisor.children(fixture.native.task_supervisor) == tasks_before_second_reply
    assert take_hash_calls() == []

    Agent.update(revoked, fn _ -> [] end)
    Agent.update(control, &%{&1 | now: deadline + 1})

    assert {:rejected, :conflict} =
             Elzoo.Wave4ChannelExample.release_reply(fixture.host, reply, scope, reply_evidence)

    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == reply_head

    assert {:approval_pending, %{key: ^reply_key, requirement: ^reply_requirement}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.reply_input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               reply_identity
             )

    assert {:ok, ^reply_resource_before_advance} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               %{
                 tenant: fixture.profile.tenant,
                 actor: fixture.profile.actor,
                 resources: [fixture.profile.conversation_id]
               },
               fixture.profile.conversation_id
             )

    assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == {:ok, [primary_item]}
    assert Task.Supervisor.children(fixture.native.task_supervisor) == tasks_before_second_reply
    assert take_hash_calls() == []

    Agent.update(control, &%{&1 | now: initial_now})

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:append, :rollback]
             )

    assert {:unknown, :unavailable} =
             Elzoo.Wave4ChannelExample.release_reply(fixture.host, reply, scope, reply_evidence)

    assert {:approval_pending, %{key: ^reply_key, requirement: ^reply_requirement}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.reply_input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               reply_identity
             )

    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == reply_head
    assert {:reconciled, :approval_pending} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert :sys.get_state(fixture.host).reply.release_state == :pending

    Enum.each(1..2, fn _ ->
      assert {:pending, :event_waiting} = Elzoo.Wave4ChannelExample.advance(fixture.host)
      assert :sys.get_state(fixture.host).phase == :result
    end)

    assert Task.Supervisor.children(fixture.native.task_supervisor) == tasks_before_second_reply
    assert take_hash_calls() == []

    assert {:committed, reply_revision} =
             Elzoo.Wave4ChannelExample.release_reply(fixture.host, reply, scope, reply_evidence)

    assert reply_revision == 3

    assert {:completed, %{revision: ^reply_revision}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.reply_input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               reply_identity
             )

    assert {:ok, {{_, 202, _}, _, reply_committed_receipt}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert %{"status" => "committed", "revision" => ^reply_revision} =
             Jason.decode!(reply_committed_receipt)

    assert {:ok, [^primary_item, reply_item]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    reply_key = reply_item.idempotency_key

    assert {:reply_observed, ^reply_key} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, 4} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:native_reply, :applied} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    native_engine = :sys.get_state(fixture.host).engine

    native_scope = %{
      tenant: fixture.profile.tenant,
      principal: fixture.profile.actor,
      run_id: :sys.get_state(fixture.host).current.run_id
    }

    assert {:ok, _} =
             wait_public_result(
               native_engine,
               native_scope,
               System.monotonic_time(:millisecond) + 10_000
             )

    assert {:result, :completed} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert take_hash_calls() == [reply_text]
    assert {:answered, 5} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:reply_acknowledged, ^reply_key} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:ok, [^primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:acknowledged, ^primary_input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert take_hash_calls() == []

    assert {:ok, %{state: :acked}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
               reply_item.idempotency_key
             ])

    assert {:ok, %{state: :acked}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
               primary_item.idempotency_key
             ])

    assert {:ok, %{revision: 1024, low_water: 0}} =
             Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, resource_at_capacity} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               fixture.profile.conversation_id
             )

    assert {:ok, {{_, status, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    assert status in 200..299

    assert {:completed, %{revision: ^reply_revision}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.reply_input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               reply_identity
             )

    tasks_before_reply_replay = Task.Supervisor.children(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, reply_replay_receipt}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert reply_replay_receipt == reply_committed_receipt

    assert %{"status" => "committed", "revision" => ^reply_revision} =
             Jason.decode!(reply_replay_receipt)

    assert {:ok, %{revision: 1024, low_water: 0}} =
             Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, ^resource_at_capacity} =
             Elzoo.CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               fixture.profile.conversation_id
             )

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert Task.Supervisor.children(fixture.native.task_supervisor) == tasks_before_reply_replay
    assert take_hash_calls() == []

    state_before_get = :sys.get_state(fixture.host)
    head_before_get = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    callbacks_before_get = Agent.get(control, & &1)

    assert {:ok, {{_, 200, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(primary_listener, fixture.profile.conversation_id)

    assert {:ok, {{_, 200, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.get(reply_listener, fixture.profile.conversation_id)

    assert :sys.get_state(fixture.host) == state_before_get
    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == head_before_get
    assert Agent.get(control, & &1) == callbacks_before_get
  end

  @tag :capacity_headroom
  test "v2 one-over headroom refuses fresh primary admission" do
    fixture = capacity_reply_fixture([])
    {primary_listener, _reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    seed_refusals_to_head!(fixture, 1018, "primary-fresh-over")
    primary_event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "primary-fresh-over"})
    {:ok, before_resource} = checked_resource!(fixture)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    assert {:ok, %{revision: 1018, low_water: 0}} =
             Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, ^before_resource} = checked_resource!(fixture)
    assert {:unknown, :not_observed} = checked_result(fixture, :primary, primary_event)

    assert {:error, :not_found} =
             RunApprovalRelease.status(
               fixture.owner,
               Elzoo.Wave4ChannelTestHelper.run_id(
                 fixture.profile,
                 primary_event["event_id"],
                 primary_event["input_id"]
               )
             )

    assert take_hash_calls() == []
  end

  @tag :capacity_headroom
  test "v2 one-over headroom refuses pending primary ASK release" do
    fixture = capacity_reply_fixture([:input, :release])
    {primary_listener, _reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    trace_native_hash(fixture.native.task_supervisor)
    seed_refusals_to_head!(fixture, 1017, "primary-release-over")
    primary_event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "primary-release-over"})
    primary = normalized_event(primary_event)

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    {:approval_pending, %{key: primary_key}} = checked_result(fixture, :primary, primary_event)

    assert {:ok, %{revision: 1018, low_water: 0}} =
             Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    seed_refusals_to_head!(fixture, 1019, "primary-release-over-extra")
    {:ok, before_resource} = checked_resource!(fixture)

    evidence =
      release_envelope(
        fixture.profile,
        primary_key,
        fixture.profile.deadline_ms - 600_000,
        "primary-release-over"
      )

    assert {:rejected, :conflict} =
             Elzoo.Wave4ChannelExample.release(
               fixture.host,
               primary,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               evidence
             )

    assert {:ok, %{revision: 1019, low_water: 0}} =
             Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, ^before_resource} = checked_resource!(fixture)

    assert {:approval_pending, %{key: ^primary_key}} =
             checked_result(fixture, :primary, primary_event)

    assert take_hash_calls() == []
  end

  @tag :capacity_headroom
  @tag timeout: 300_000
  test "v2 reply one-over headroom refuses fresh reply and ASK release" do
    {fixture, _primary_listener, reply_listener, _primary_event, wait} =
      capacity_wait_fixture([:reply_input, :reply_release], "reply-fresh-over")

    seed_refusals_to_head!(fixture, 1021, "reply-fresh-over")
    reply_event = reply_event_for_capacity(fixture, wait, "reply-fresh-over")
    {:ok, before_resource} = checked_resource!(fixture)

    assert {:ok, {{_, 409, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert {:ok, %{revision: 1021, low_water: 0}} =
             Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, ^before_resource} = checked_resource!(fixture)
    assert {:unknown, :not_observed} = checked_result(fixture, :reply, reply_event)
    assert {:ok, [_primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert take_hash_calls() == []

    {fixture, _primary_listener, reply_listener, _primary_event, wait} =
      capacity_wait_fixture([:reply_input, :reply_release], "reply-release-over")

    seed_refusals_to_head!(fixture, 1020, "reply-release-over")
    reply_event = reply_event_for_capacity(fixture, wait, "reply-release-over")
    reply = normalized_event(reply_event)

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    {:approval_pending, %{key: reply_key}} = checked_result(fixture, :reply, reply_event)

    assert {:ok, %{revision: 1021, low_water: 0}} =
             Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    seed_refusals_to_head!(fixture, 1022, "reply-release-over-extra")
    {:ok, before_resource} = checked_resource!(fixture)

    evidence =
      release_envelope(
        fixture.profile,
        reply_key,
        fixture.profile.deadline_ms - 600_000,
        "reply-release-over"
      )

    assert {:rejected, :conflict} =
             Elzoo.Wave4ChannelExample.release_reply(
               fixture.host,
               reply,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               evidence
             )

    assert {:ok, %{revision: 1022, low_water: 0}} =
             Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, ^before_resource} = checked_resource!(fixture)
    assert {:approval_pending, %{key: ^reply_key}} = checked_result(fixture, :reply, reply_event)
    assert {:ok, [_primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert take_hash_calls() == []
  end

  @tag :reply_size_boundary
  test "signed reply text over 4,096 bytes is refused before command admission" do
    {fixture, _primary_listener, reply_listener, _primary_event, wait} =
      capacity_wait_fixture([], "reply-text-over-limit")

    reply_event =
      reply_event_for_capacity(fixture, wait, "reply-text-over-limit")
      |> Map.put("text", String.duplicate("r", 4_097))

    {:ok, head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    {:ok, resource_before} = checked_resource!(fixture)
    {:ok, outbox_before} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 400, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert {:ok, ^head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, ^resource_before} = checked_resource!(fixture)
    assert {:ok, ^outbox_before} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:unknown, :not_observed} = checked_result(fixture, :reply, reply_event)
    assert take_hash_calls() == []
  end

  @tag :resource_capacity
  test "post-association resource CAS drift blocks native event delivery" do
    {fixture, _primary_listener, reply_listener, primary_event, wait} =
      capacity_wait_fixture([], "post-association-resource-cas-drift")

    reply_event = reply_event_for_capacity(fixture, wait, "post-association-resource-cas-drift")

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert {:reply_observed, _} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:reply_associated, _} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        primary_event["event_id"],
        primary_event["input_id"]
      )

    assert {:ok, run_before} = RunApprovalRelease.status(fixture.owner, run_id)
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, resource_before} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    unrelated_event_id = "unrelated-resource-cas-change"
    unrelated_message_id = "unrelated-resource-cas-message"

    unrelated_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, unrelated_event_id)

    request = %{
      operation_id: unrelated_operation,
      resource: fixture.profile.conversation_id,
      expected_revision: resource_before.revision,
      payload: %{"message_id" => unrelated_message_id, "text" => "unrelated"}
    }

    facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}

    prepared_facts = %{
      tenant: fixture.profile.tenant,
      actor: fixture.profile.actor,
      data: facts
    }

    assert {:ok, writes, _} =
             Wave4ChannelExample.Intents.prepare(
               resource_before,
               request,
               prepared_facts
             )

    context = %{
      tenant: fixture.profile.tenant,
      actor: fixture.profile.actor,
      policy: Elzoo.Wave4ChannelTestHelper.policy(),
      own: writes,
      parent: :none,
      facts: facts
    }

    assert {:completed, _} = CheckedCommand.execute(fixture.handles.input, context, request)

    assert {:ok, resource_after} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    assert resource_after.revision == resource_before.revision + 1

    trace_engine_input(fixture.host)
    assert {:blocked, _reason} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert take_engine_input_ids() == []
    assert take_hash_calls() == []

    assert {:ok, run_after} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_after.current_attempt == run_before.current_attempt
    assert run_after.attempts == run_before.attempts
  end

  @tag :raw_body_boundary
  test "signed raw body accepts 65,536 bytes and rejects 65,537 bytes", %{fixture: fixture} do
    listener = Elzoo.Wave4ChannelTestHelper.listener!(fixture)
    first_event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "raw-body-at-limit"})
    assert map_size(first_event) == 6
    first_json = Jason.encode!(first_event)
    first_body = first_json <> String.duplicate(" ", 65_536 - byte_size(first_json))
    assert byte_size(first_body) == 65_536

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, first_event, body: first_body)

    second_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "raw-body-over-limit",
        "expected_revision" => 2
      })

    assert map_size(second_event) == 6
    second_json = Jason.encode!(second_event)
    second_body = second_json <> String.duplicate(" ", 65_537 - byte_size(second_json))
    assert byte_size(second_body) == 65_537

    {:ok, head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    {:ok, resource_before} = checked_resource!(fixture)
    {:ok, outbox_before} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, {{_, 413, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, second_event, body: second_body)

    assert {:ok, ^head_before} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, ^resource_before} = checked_resource!(fixture)
    assert {:ok, ^outbox_before} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:unknown, :not_observed} = checked_result(fixture, :primary, second_event)
  end

  @tag :reply_release
  test "unknown v2 release before commit reconciles to the original ASK identity" do
    {:ok, control} = Agent.start_link(fn -> %{now: System.system_time(:millisecond)} end)
    on_exit(fn -> if Process.alive?(control), do: Agent.stop(control) end)
    clock = fn -> Agent.get(control, & &1.now) end
    initial_now = clock.()
    deadline = initial_now + 120_000

    policy = fn mode, _event, _now ->
      Elzoo.Wave4ChannelTestHelper.policy(if(mode in [:input, :release], do: :ask, else: :allow))
    end

    {:ok, release_fault} = Agent.start_link(fn -> %{enabled: false, store: nil} end)
    on_exit(fn -> if Process.alive?(release_fault), do: Agent.stop(release_fault) end)

    input_gate = fn _frame, _context ->
      case Agent.get(release_fault, & &1) do
        %{enabled: true, store: store} ->
          :ok =
            Elzoo.DurableLog.PostgresHarness.hook(store, :inject, [
              :append,
              :rollback
            ])

          Agent.update(release_fault, &%{&1 | enabled: false})

        _ ->
          :ok
      end

      :allow
    end

    gates = %{
      input: input_gate,
      reply: fn _frame, _context -> :allow end,
      association: fn _frame, _context -> :allow end,
      answer: fn _frame, _context -> :allow end
    }

    fixture =
      Elzoo.Wave4ChannelTestHelper.reply_fixture(
        clock: clock,
        deadline_ms: deadline,
        policy: policy,
        gates: gates
      )

    Agent.update(release_fault, &%{&1 | store: fixture.command_store})
    listener = elem(Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture), 0)
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "release-before-commit"})
    normalized = normalized_event(event)
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])
    identity = {fixture.profile.tenant, fixture.profile.actor, operation}
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert {:approval_pending, %{key: key} = pending} =
             Elzoo.CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    evidence = release_envelope(fixture.profile, key, initial_now, "release-before-commit")
    head_before_release = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    units_before_release =
      Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, [])

    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    Agent.update(release_fault, &%{&1 | enabled: true})

    assert {:unknown, :unavailable} =
             Elzoo.Wave4ChannelExample.release(fixture.host, normalized, scope, evidence)

    fenced_state = :sys.get_state(fixture.host)

    assert {:v2_release, :primary, ^operation, facts, request, nil, _reason} =
             fenced_state.poison

    assert fenced_state.approval.event == normalized
    assert fenced_state.approval.operation_id == operation
    assert fenced_state.approval.facts == facts
    assert fenced_state.approval.request == request
    assert fenced_state.approval.request.operation_id == operation
    assert fenced_state.poison != nil

    assert {:approval_pending, ^pending} =
             Elzoo.CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == head_before_release
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:reconciled, :approval_pending} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    reconciled_state = :sys.get_state(fixture.host)
    assert is_nil(reconciled_state.poison)
    assert reconciled_state.approval.event == normalized
    assert reconciled_state.approval.operation_id == operation
    assert reconciled_state.approval.release_state == :pending
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert take_hash_calls() == []

    assert Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :snapshot, []) ==
             units_before_release

    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == head_before_release
  end

  @tag :reply_release
  test "committed v2 release reconciles after expiry without starting native work" do
    {:ok, control} = Agent.start_link(fn -> %{now: System.system_time(:millisecond)} end)
    on_exit(fn -> if Process.alive?(control), do: Agent.stop(control) end)
    clock = fn -> Agent.get(control, & &1.now) end
    initial_now = clock.()
    deadline = initial_now + 120_000

    policy = fn mode, _event, _now ->
      Elzoo.Wave4ChannelTestHelper.policy(if(mode in [:input, :release], do: :ask, else: :allow))
    end

    {:ok, release_fault} = Agent.start_link(fn -> %{enabled: false, store: nil} end)
    on_exit(fn -> if Process.alive?(release_fault), do: Agent.stop(release_fault) end)

    input_gate = fn _frame, _context ->
      case Agent.get(release_fault, & &1) do
        %{enabled: true, store: store} ->
          Elzoo.DurableLog.PostgresHarness.hook(store, :inject, [:read_at, :unavailable])
          Elzoo.DurableLog.PostgresHarness.hook(store, :inject, [:append, :reply_loss])
          Agent.update(release_fault, &%{&1 | enabled: false})

        _ ->
          :ok
      end

      :allow
    end

    gates = %{
      input: input_gate,
      reply: fn _frame, _context -> :allow end,
      association: fn _frame, _context -> :allow end,
      answer: fn _frame, _context -> :allow end
    }

    fixture =
      Elzoo.Wave4ChannelTestHelper.reply_fixture(
        clock: clock,
        deadline_ms: deadline,
        policy: policy,
        gates: gates
      )

    Agent.update(release_fault, &%{&1 | store: fixture.command_store})

    listener = elem(Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture), 0)
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "expired-release-primary"})
    normalized = normalized_event(event)
    operation = Elzoo.Wave4ChannelTestHelper.input_operation(fixture.profile, event["event_id"])

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], normalized.input_id)

    identity = {fixture.profile.tenant, fixture.profile.actor, operation}
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)

    assert {:approval_pending, %{key: key}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    evidence = release_envelope(fixture.profile, key, initial_now, "lost-release-reply")

    Agent.update(release_fault, &%{&1 | enabled: true})

    assert {:unknown, :unavailable} =
             Elzoo.Wave4ChannelExample.release(fixture.host, normalized, scope, evidence)

    assert {:completed, %{revision: 1}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               identity
             )

    assert {:ok, before_reconcile_head} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    Agent.update(control, &%{&1 | now: deadline + 1})
    assert {:reconciled, :release} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:pending, :expired} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert :sys.get_state(fixture.host).current == nil
    assert :sys.get_state(fixture.host).approval.release_state == :committed_expired
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)

    assert :not_found =
             DynamicUnits.find(fixture.directory, Elzoo.Wave4ChannelTestHelper.unit_id(run_id))

    assert take_hash_calls() == []
    assert {:ok, after_reconcile_head} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert after_reconcile_head == before_reconcile_head
    {:ok, pending_items} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    [item] = Enum.filter(pending_items, &(&1.destination == "wave4-channel-input"))
    assert item.destination == "wave4-channel-input"
  end

  @tag :reply_release
  test "committed v2 reply release reconciles after expiry without native work" do
    {:ok, control} = Agent.start_link(fn -> %{now: System.system_time(:millisecond)} end)
    on_exit(fn -> if Process.alive?(control), do: Agent.stop(control) end)
    clock = fn -> Agent.get(control, & &1.now) end
    initial_now = clock.()
    deadline = initial_now + 120_000

    {:ok, release_fault} = Agent.start_link(fn -> %{enabled: false, store: nil} end)
    on_exit(fn -> if Process.alive?(release_fault), do: Agent.stop(release_fault) end)

    reply_gate = fn _frame, _context ->
      case Agent.get(release_fault, & &1) do
        %{enabled: true, store: store} ->
          :ok =
            Elzoo.DurableLog.PostgresHarness.hook(store, :inject, [
              :read_at,
              :unavailable
            ])

          :ok =
            Elzoo.DurableLog.PostgresHarness.hook(store, :inject, [
              :append,
              :reply_loss
            ])

          Agent.update(release_fault, &%{&1 | enabled: false})

        _ ->
          :ok
      end

      :allow
    end

    gates = %{
      input: fn _frame, _context -> :allow end,
      reply: reply_gate,
      association: fn _frame, _context -> :allow end,
      answer: fn _frame, _context -> :allow end
    }

    policy = fn mode, _event, _now ->
      Elzoo.Wave4ChannelTestHelper.policy(
        if(mode in [:reply_input, :reply_release], do: :ask, else: :allow)
      )
    end

    fixture =
      Elzoo.Wave4ChannelTestHelper.reply_fixture(
        clock: clock,
        deadline_ms: deadline,
        policy: policy,
        gates: gates
      )

    Agent.update(release_fault, &%{&1 | store: fixture.command_store})

    {primary_listener, reply_listener} =
      Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    trace_native_hash(fixture.native.task_supervisor)

    primary_event =
      Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "expired-reply-release-primary"})

    primary_operation =
      Elzoo.Wave4ChannelTestHelper.input_operation(
        fixture.profile,
        primary_event["event_id"]
      )

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    assert {:completed, %{revision: 1}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, primary_operation}
             )

    primary = normalized_event(primary_event)
    assert {:observed, primary_input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert primary_input_id == primary.input_id
    Enum.each(1..11, fn _ -> Elzoo.Wave4ChannelExample.advance(fixture.host) end)

    assert {:ok, %{event_waits: %{waits: [wait]}}} =
             Elzoo.Wave4ChannelExample.view(fixture.host, scope)

    assert wait.status == :waiting
    assert {:ok, [primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    primary_run_id = :sys.get_state(fixture.host).current.run_id

    assert {:ok, before_run_status} =
             Elzoo.RunApprovalRelease.status(fixture.native.run_owner, primary_run_id)

    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(primary_run_id)
    assert {:ok, unit_before_release} = DynamicUnits.find(fixture.directory, unit_id)
    unit_state_before_release = DurableUnit.snapshot(unit_before_release)

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "expired-reply-release-reply",
        "input_id" => wait.correlation_id,
        "expected_revision" => 2,
        "text" => "retained reply text must not be delivered after expiry"
      })

    reply = normalized_event(reply_event)

    reply_operation =
      Elzoo.Wave4ChannelTestHelper.reply_operation(
        fixture.profile,
        reply_event["event_id"]
      )

    reply_identity = {fixture.profile.tenant, fixture.profile.actor, reply_operation}

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert {:approval_pending, %{key: reply_key}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.reply_input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               reply_identity
             )

    evidence = release_envelope(fixture.profile, reply_key, initial_now, "lost-reply-release")
    assert {:ok, head_before_release} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    Agent.update(release_fault, &%{&1 | enabled: true})

    assert {:unknown, :unavailable} =
             Elzoo.Wave4ChannelExample.release_reply(fixture.host, reply, scope, evidence)

    assert {:completed, %{revision: 3}} =
             Elzoo.CheckedCommand.result(
               fixture.handles.reply_input,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               reply_identity
             )

    assert {:ok, [^primary_item, reply_item]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    reply_ack_key = reply_item.idempotency_key

    Agent.update(control, &%{&1 | now: deadline + 1})
    assert {:reconciled, :release} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:ok, unit_after_release_reconciliation} = DynamicUnits.find(fixture.directory, unit_id)

    assert DurableUnit.snapshot(unit_after_release_reconciliation) == unit_state_before_release

    assert {:native_expiry_wake, :applied} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    # One unavailable read of the reply item at the terminal step decides
    # nothing: the step is retried, and nothing is written.
    reply_probe = probe_host_command_store!(fixture)
    Elzoo.Wave4ChannelTest.ReadProbe.fault(reply_probe, :read_ack, reply_ack_key, :unavailable)
    assert {:error, :unavailable} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert :sys.get_state(fixture.host).poison == nil

    assert {:terminal, outcome} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert outcome in [:failed, :cancelled, :out_of_budget, :out_of_time]
    # The terminal reply has no reply association: its custody facts are
    # persisted before the acknowledgement.
    assert {:reply_custody, custody_revision} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    assert {:ok, %{state: :pending}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [reply_ack_key])

    assert {:reply_acknowledged, ^reply_ack_key} = Elzoo.Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^primary_input_id} = Elzoo.Wave4ChannelExample.advance(fixture.host)

    recovered = :sys.get_state(fixture.host)
    assert recovered.current == nil
    assert recovered.latest_native.run_id == primary_run_id
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert take_hash_calls() == []

    assert {:ok, after_run_status} =
             Elzoo.RunApprovalRelease.status(fixture.native.run_owner, primary_run_id)

    assert after_run_status.current_attempt == before_run_status.current_attempt
    assert after_run_status.attempts == before_run_status.attempts
    assert after_run_status.outcome == outcome
    assert {:ok, _unit_after_terminal} = DynamicUnits.find(fixture.directory, unit_id)

    assert {:ok, %{revision: revision}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert revision == head_before_release.revision + 2

    assert {:ok, custody_snapshot} =
             CheckedCommand.resource(
               fixture.handles.input,
               Elzoo.Wave4ChannelTestHelper.scope(fixture.profile),
               fixture.profile.conversation_id
             )

    reply_item_nonce = reply_item.nonce

    assert custody_snapshot.revision == custody_revision

    assert {:ok, %{reply_key: ^reply_ack_key, reply_nonce: ^reply_item_nonce}} =
             Wave4ChannelExample.Intents.metadata(custody_snapshot.fields, fixture.profile.tenant)

    primary_nonce = primary_item.nonce

    assert {:ok, %{state: :acked, nonce: ^primary_nonce}} =
             Elzoo.DurableLog.Store.read(
               fixture.command_store,
               :read_ack,
               [primary_item.idempotency_key]
             )

    reply_nonce = reply_item.nonce

    assert {:ok, %{state: :acked, nonce: ^reply_nonce}} =
             Elzoo.DurableLog.Store.read(
               fixture.command_store,
               :read_ack,
               [reply_item.idempotency_key]
             )
  end

  @tag timeout: 300_000
  test "same-host answer reconciliation retains revision through both ACKs and next primary" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()

    {primary_listener, reply_listener} =
      Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    trace_native_hash(fixture.native.task_supervisor)

    primary_event =
      Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "same-host-reconcile-primary"})

    primary_id = primary_event["input_id"]

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Wave4ChannelExample.advance(fixture.host) end)

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, %{event_waits: %{waits: [wait]}}} =
             Wave4ChannelExample.view(fixture.host, scope)

    assert wait.status == :waiting
    assert {:ok, [primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, resource} =
             CheckedCommand.resource(
               fixture.handles.input,
               scope,
               fixture.profile.conversation_id
             )

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "same-host-reconcile-reply",
        "input_id" => wait.correlation_id,
        "expected_revision" => resource.revision,
        "text" => "same-host retained reply"
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert {:ok, [^primary_item, reply_item]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    advance_to_answer(fixture.host, System.monotonic_time(:millisecond) + 30_000, [])

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:read_at, :unavailable]
             )

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:append, :reply_loss]
             )

    assert {:unknown, :answer} = Wave4ChannelExample.advance(fixture.host)
    assert {:reconciled, :answer} = Wave4ChannelExample.advance(fixture.host)

    answer_operation =
      Elzoo.Wave4ChannelTestHelper.answer_operation(
        fixture.profile,
        primary_event["event_id"],
        primary_id
      )

    result_scope = %{tenant: fixture.profile.tenant, actor: fixture.profile.actor}

    assert {:completed, %{revision: answer_revision}} =
             CheckedCommand.result(
               fixture.handles.answer,
               result_scope,
               {fixture.profile.tenant, fixture.profile.actor, answer_operation}
             )

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        primary_event["event_id"],
        primary_id
      )

    attempt_id = Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)
    assert {:ok, run_before_ack} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_before_ack.current_attempt == attempt_id

    assert {:reply_acknowledged, reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert reply_key == reply_item.idempotency_key

    assert {:ok, %{state: :acked, idempotency_key: ^reply_key, ack_nonce: reply_nonce}} =
             Elzoo.DurableLog.Store.read(
               fixture.command_store,
               :read_ack,
               [reply_key]
             )

    assert reply_nonce == reply_item.nonce
    assert {:acknowledged, ^primary_id} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, %{state: :acked, idempotency_key: primary_key, ack_nonce: primary_nonce}} =
             Elzoo.DurableLog.Store.read(
               fixture.command_store,
               :read_ack,
               [primary_item.idempotency_key]
             )

    assert primary_key == primary_item.idempotency_key
    assert primary_nonce == primary_item.nonce
    assert {:ok, run_after_ack} = RunApprovalRelease.status(fixture.owner, run_id)
    assert stable_run_status(run_after_ack) == stable_run_status(run_before_ack)

    assert {:ok, completed_resource} =
             CheckedCommand.resource(
               fixture.handles.input,
               scope,
               fixture.profile.conversation_id
             )

    assert {:ok, _entries, conversation_messages} = read_conversation(fixture, scope)
    conversation = %{messages: conversation_messages}
    answer_id = Elzoo.Wave4ChannelTestHelper.answer_id(primary_id)
    assert Enum.count(conversation.messages, &(&1.message_id == answer_id)) == 1
    assert ["same-host retained reply"] = take_hash_calls()

    next_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "same-host-reconcile-next",
        "input_id" => "same-host-next-input",
        "expected_revision" => completed_resource.revision,
        "text" => "next primary"
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, next_event)

    assert {:observed, next_input_id} = Wave4ChannelExample.advance(fixture.host)
    assert next_input_id == next_event["input_id"]

    next_run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        next_event["event_id"],
        next_input_id
      )

    next_attempt_id = Elzoo.Wave4ChannelTestHelper.attempt_id(next_run_id)

    Enum.each(1..11, fn _ -> Wave4ChannelExample.advance(fixture.host) end)

    assert {:ok, next_run} = RunApprovalRelease.status(fixture.owner, next_run_id)
    assert next_run.current_attempt == next_attempt_id

    assert {:ok, next_view} = Wave4ChannelExample.view(fixture.host, scope)
    assert %{waits: [next_wait]} = next_view.event_waits
    assert next_wait.status == :waiting
    assert next_wait.source_id == fixture.profile.reply_source_id

    assert Enum.any?(next_view.associations, fn association ->
             association.input_message_id == next_input_id and association.run_id == next_run_id
           end)

    assert take_hash_calls() == []

    assert {:completed, %{revision: ^answer_revision}} =
             CheckedCommand.result(
               fixture.handles.answer,
               result_scope,
               {fixture.profile.tenant, fixture.profile.actor, answer_operation}
             )
  end

  @tag timeout: 300_000
  test "full pending window refuses fresh primary admission before and after reopen" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()

    {primary_listener, reply_listener} =
      Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    seed_foreign_reply_notifications!(fixture, 64, "full-window-refusal")
    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, %{revision: 64}} =
             Elzoo.Wave4ChannelTestHelper.command_head(fixture)

    assert {:ok, outbox_before} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert length(outbox_before) == 64
    assert Enum.all?(outbox_before, &(&1.destination == "wave4-channel-reply"))

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, resource_before} =
             CheckedCommand.resource(
               fixture.handles.input,
               scope,
               fixture.profile.conversation_id
             )

    head_before = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "full-window-new-primary"})

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)

    assert {:unknown, :reply_observation} = Wave4ChannelExample.advance(fixture.host)

    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == head_before
    assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == {:ok, outbox_before}

    assert CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id) ==
             {:ok, resource_before}

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(fixture.profile, event["event_id"], event["input_id"])

    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert take_hash_calls() == []

    assert {:ok, fixture} =
             Elzoo.Wave4ChannelTestHelper.fence_and_reopen!(fixture, [
               primary_listener,
               reply_listener
             ])

    {primary_listener, _reply_listener} =
      Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    trace_native_hash(fixture.native.task_supervisor)

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)

    assert {:unknown, :reply_observation} = Wave4ChannelExample.advance(fixture.host)

    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == head_before
    assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == {:ok, outbox_before}

    assert CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id) ==
             {:ok, resource_before}

    assert {:error, :not_found} = RunApprovalRelease.status(fixture.owner, run_id)
    assert Task.Supervisor.children(fixture.native.task_supervisor) == []
    assert take_hash_calls() == []
  end

  @tag timeout: 300_000
  test "complete short windows admit visible primaries and retain replay under a full window" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()

    {primary_listener, _reply_listener} =
      Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)

    seed_foreign_reply_notifications!(fixture, 63, "short-window-positive")
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "short-window-primary"})
    input_id = event["input_id"]

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)

    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:ok, items_at_limit} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert length(items_at_limit) == 64
    assert Enum.any?(items_at_limit, &(&1.destination == "wave4-channel-input"))

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)
    head_before_replay = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    outbox_before_replay = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    resource_before_replay =
      CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    result_before_replay = checked_result(fixture, :primary, event)
    assert {:completed, %{revision: 1}} = result_before_replay

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)

    assert Elzoo.Wave4ChannelTestHelper.command_head(fixture) == head_before_replay
    assert Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture) == outbox_before_replay

    assert CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id) ==
             resource_before_replay

    assert checked_result(fixture, :primary, event) == result_before_replay
  end

  defp seed_foreign_reply_notifications!(fixture, count, prefix) do
    profile = fixture.profile
    facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
    resource = "foreign-#{prefix}"
    scope = %{tenant: profile.tenant, actor: profile.actor, resources: [resource]}

    Enum.each(1..count, fn index ->
      event_id = "#{prefix}-#{index}"

      assert {:ok, snapshot} =
               CheckedCommand.resource(fixture.handles.reply_input, scope, resource)

      assert snapshot.revision == index - 1

      request = %{
        operation_id: Elzoo.Wave4ChannelTestHelper.reply_operation(profile, event_id),
        resource: resource,
        expected_revision: snapshot.revision,
        payload: %{"message_id" => "reply-#{event_id}", "text" => "foreign notice"}
      }

      prepared_facts = %{tenant: profile.tenant, actor: profile.actor, data: facts}

      assert {:ok, writes, _response} =
               Wave4ChannelExample.Intents.prepare(
                 snapshot,
                 request,
                 prepared_facts
               )

      context = %{
        tenant: profile.tenant,
        actor: profile.actor,
        policy: Elzoo.Wave4ChannelTestHelper.policy(),
        own: writes,
        parent: :none,
        facts: facts
      }

      assert {:completed, %{revision: ^index}} =
               CheckedCommand.execute(fixture.handles.reply_input, context, request)
    end)
  end

  @tag timeout: 300_000
  test "same-host reply association recovery stays fenced through post-commit read failures" do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    trace_native_hash(fixture.native.task_supervisor)

    primary_event =
      Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "reply-association-read-failure-primary"})

    primary_id = primary_event["input_id"]

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Wave4ChannelExample.advance(fixture.host) end)

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, %{event_waits: %{waits: [wait]}}} = Wave4ChannelExample.view(fixture.host, scope)
    assert wait.status == :waiting
    assert {:ok, [primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:ok, before_reply} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    reply_text = "post-commit association recovery"

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "reply-association-read-failure-reply",
        "input_id" => wait.correlation_id,
        "expected_revision" => before_reply.revision,
        "text" => reply_text
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    assert {:ok, [^primary_item, reply_item]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:reply_observed, reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert reply_key == reply_item.idempotency_key

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        primary_event["event_id"],
        primary_id
      )

    attempt_id = Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)
    assert {:ok, run_before} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_before.current_attempt == attempt_id

    before_association = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, %{revision: head_before}} = before_association

    # v2 post-commit confirmation reads the conversation log, not a checked
    # command handle: the reply-association path never reads handles.input.
    # Fault the conversation scan — the command commits, the read fails
    # afterwards, exactly the v1 post-commit shape.
    Elzoo.DurableLog.PostgresHarness.hook(fixture.conversation_store, :inject, [:read, :unavailable])

    assert {:unknown, :reply_association} = Wave4ChannelExample.advance(fixture.host)

    reply_operation =
      Elzoo.Wave4ChannelTestHelper.reply_operation(fixture.profile, reply_event["event_id"])

    association_operation =
      Elzoo.Wave4ChannelTestHelper.association_operation_for(
        fixture.profile,
        reply_operation,
        wait.correlation_id
      )

    assert {:completed, %{revision: association_revision}} =
             CheckedCommand.result(
               fixture.handles.reply_association,
               %{tenant: fixture.profile.tenant, actor: fixture.profile.actor},
               {fixture.profile.tenant, fixture.profile.actor, association_operation}
             )

    assert {:ok, committed_resource} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    assert committed_resource.revision == association_revision

    assert {:ok, committed_entries, _committed_conversation_messages} =
             read_conversation(fixture, scope)

    # The reply association command is committed but undelivered while the
    # host is fenced: no association entry exists in the conversation yet.
    refute Enum.any?(committed_entries, fn entry ->
             Map.get(entry, :kind) == :association and
               Map.get(entry, :input_message_id) == reply_event["input_id"]
           end)

    head_after_association = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    assert {:ok, %{revision: head_after}} = head_after_association
    assert head_after == head_before + 1

    assert {:ok, [^primary_item, ^reply_item | _]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert take_hash_calls() == []

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(
               fixture.command_store,
               :inject,
               [:read, :unavailable]
             )

    assert {:unknown, :reply_association} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, [^primary_item, ^reply_item | _]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert take_hash_calls() == []

    assert {:reconciled, :reply_association} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_reply, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, _native_result} =
             wait_public_result(
               :sys.get_state(fixture.host).engine,
               %{tenant: fixture.profile.tenant, principal: fixture.profile.actor, run_id: run_id},
               System.monotonic_time(:millisecond) + 10_000
             )

    assert {:result, :completed} = Wave4ChannelExample.advance(fixture.host)
    assert {:answered, answer_revision} = Wave4ChannelExample.advance(fixture.host)

    result_scope = %{tenant: fixture.profile.tenant, actor: fixture.profile.actor}

    answer_operation =
      Elzoo.Wave4ChannelTestHelper.answer_operation(
        fixture.profile,
        primary_event["event_id"],
        primary_id
      )

    answer_identity = {fixture.profile.tenant, fixture.profile.actor, answer_operation}

    assert {:completed, %{revision: ^answer_revision}} =
             CheckedCommand.result(fixture.handles.answer, result_scope, answer_identity)

    assert {:ok, run_before_ack} = RunApprovalRelease.status(fixture.owner, run_id)
    assert run_before_ack.current_attempt == attempt_id
    assert {:reply_acknowledged, ^reply_key} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, %{state: :acked, idempotency_key: ^reply_key, ack_nonce: reply_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [reply_key])

    assert reply_nonce == reply_item.nonce
    assert {:acknowledged, ^primary_id} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, %{state: :acked, idempotency_key: primary_key, ack_nonce: primary_nonce}} =
             Elzoo.DurableLog.Store.read(
               fixture.command_store,
               :read_ack,
               [primary_item.idempotency_key]
             )

    assert primary_key == primary_item.idempotency_key
    assert primary_nonce == primary_item.nonce
    assert {:ok, run_after_ack} = RunApprovalRelease.status(fixture.owner, run_id)
    assert stable_run_status(run_after_ack) == stable_run_status(run_before_ack)

    assert {:ok, completed_resource} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    assert completed_resource.revision == answer_revision

    assert {:ok, _entries, completed_conversation_messages} = read_conversation(fixture, scope)
    completed_conversation = %{messages: completed_conversation_messages}
    answer_id = Elzoo.Wave4ChannelTestHelper.answer_id(primary_id)
    assert Enum.count(completed_conversation.messages, &(&1.message_id == answer_id)) == 1
    assert [^reply_text] = take_hash_calls()
  end

  @tag timeout: 300_000
  test "committed reply-input loss reconciles after native expiry and preserves canonical ACKs" do
    {:ok, clock_state} = Agent.start_link(fn -> System.system_time(:millisecond) end)
    on_exit(fn -> if Process.alive?(clock_state), do: Agent.stop(clock_state) end)
    clock = fn -> Agent.get(clock_state, & &1) end
    deadline = clock.() + 120_000

    gate_control = start_supervised!({Agent, fn -> %{fault: nil, store: nil} end}, id: make_ref())

    gates = %{
      input: fn _frame, _context -> :allow end,
      reply: controlled_gate(gate_control),
      association: fn _frame, _context -> :allow end,
      answer: fn _frame, _context -> :allow end
    }

    fixture =
      Elzoo.Wave4ChannelTestHelper.reply_fixture(
        clock: clock,
        deadline_ms: deadline,
        gates: gates
      )

    set_gate_fault(gate_control, fixture.command_store, :reply_loss)
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    trace_native_hash(fixture.native.task_supervisor)

    primary_event =
      Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => "expired-committed-reply-primary"})

    primary_id = primary_event["input_id"]

    run_id =
      Elzoo.Wave4ChannelTestHelper.run_id(
        fixture.profile,
        primary_event["event_id"],
        primary_id
      )

    attempt_id = Elzoo.Wave4ChannelTestHelper.attempt_id(run_id)

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, primary_event)

    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Wave4ChannelExample.advance(fixture.host) end)

    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, %{event_waits: %{waits: [wait]}}} = Wave4ChannelExample.view(fixture.host, scope)
    assert wait.status == :waiting
    assert clock.() < deadline

    assert {:ok, [primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert primary_item.destination == "wave4-channel-input"

    result_scope = %{tenant: fixture.profile.tenant, actor: fixture.profile.actor}

    assert {:ok, before_reply} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => "expired-committed-reply-input",
        "input_id" => wait.correlation_id,
        "expected_revision" => before_reply.revision,
        "text" => "committed before expiry, never delivered"
      })

    reply_operation =
      Elzoo.Wave4ChannelTestHelper.reply_operation(fixture.profile, reply_event["event_id"])

    assert {:ok, {{_, 503, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    reply_identity = {fixture.profile.tenant, fixture.profile.actor, reply_operation}

    assert {:completed, %{revision: reply_revision}} =
             CheckedCommand.result(fixture.handles.reply_input, result_scope, reply_identity)

    assert reply_revision == before_reply.revision + 1

    assert {:ok, [^primary_item, reply_item]} =
             Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    reply_key = reply_item.idempotency_key
    assert reply_item.destination == "wave4-channel-reply"
    assert {:ok, {stream, sequence, 1}} = Outbox.parse_id(reply_key)
    assert stream == checked_stream(fixture.profile.tenant)
    assert sequence > 0

    assert {:ok, before_run_expiry} = RunApprovalRelease.status(fixture.owner, run_id)
    assert before_run_expiry.current_attempt == attempt_id

    Agent.update(clock_state, fn _ -> deadline + 1 end)
    assert {:reconciled, :reply_input_expired} = Wave4ChannelExample.advance(fixture.host)

    expired_state = :sys.get_state(fixture.host)
    assert expired_state.reply.input_state == :committed_expired
    assert expired_state.reply.release_state == :input_committed
    assert expired_state.reply.item == nil
    assert Map.get(expired_state.reply, :native_input_id) == nil

    assert {:native_expiry_wake, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:terminal, :out_of_time} =
             wait_public_result(
               expired_state.engine,
               %{tenant: fixture.profile.tenant, principal: fixture.profile.actor, run_id: run_id},
               System.monotonic_time(:millisecond) + 10_000
             )

    assert {:terminal, :out_of_time} = Wave4ChannelExample.advance(fixture.host)

    terminal_state = :sys.get_state(fixture.host)
    assert terminal_state.reply.item.idempotency_key == reply_key
    assert terminal_state.reply.item.nonce == reply_item.nonce
    assert Map.get(terminal_state.reply, :native_input_id) == nil
    assert Map.get(terminal_state.reply.wait, :accepted_event) == nil

    # The terminal reply has no reply association, so its custody facts (the
    # reply item's original key and nonce and the reply input's conversation
    # sequence) are persisted first; the item is still pending then. The
    # custody command's append pauses after its head compare-and-set: its
    # writer lives and the command reads as not observed, so reconciliation
    # stays read-only and submits nothing again.
    custody_token = :wave4_reply_custody_writer

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [
               :append,
               {:pause, custody_token}
             ])

    assert {:unknown, :reply_custody} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_custody, custody_operation} = poison = :sys.get_state(fixture.host).poison
    custody_writer = Elzoo.DurableLog.PostgresHarness.paused(fixture.controller, custody_token)
    assert custody_writer.operation == :append
    assert Process.alive?(custody_writer.pid)
    custody_identity = {fixture.profile.tenant, fixture.profile.actor, custody_operation}

    assert {:unknown, :not_observed} =
             CheckedCommand.result(fixture.handles.reply_custody, result_scope, custody_identity)

    assert {:unknown, :reply_custody} = Wave4ChannelExample.advance(fixture.host)
    assert {:unknown, :reply_custody} = Wave4ChannelExample.advance(fixture.host)
    assert :sys.get_state(fixture.host).poison == poison
    assert Process.alive?(custody_writer.pid)

    # The original command commits; reconciliation confirms it.
    assert {:committed, _} =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :release, [custody_token])

    assert {:reply_custody, custody_revision} = Wave4ChannelExample.advance(fixture.host)
    assert custody_revision == reply_revision + 1
    assert :sys.get_state(fixture.host).poison == nil

    assert {:ok, custody_snapshot} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    assert custody_snapshot.revision == custody_revision
    assert {:ok, custody_entries, _messages} = read_conversation(fixture, scope)

    [reply_entry] =
      Enum.filter(
        custody_entries,
        &(&1[:kind] == :input and &1[:message_id] == wait.correlation_id)
      )

    reply_item_nonce = reply_item.nonce
    reply_sequence = reply_entry.sequence

    assert {:ok,
            %{
              run_id: ^run_id,
              primary_key: primary_custody_key,
              reply_key: ^reply_key,
              reply_nonce: ^reply_item_nonce,
              reply_sequence: ^reply_sequence
            }} =
             Wave4ChannelExample.Intents.metadata(custody_snapshot.fields, fixture.profile.tenant)

    assert primary_custody_key == primary_item.idempotency_key

    assert {:ok, %{state: :pending, nonce: ^reply_item_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [reply_key])

    assert {:reply_acknowledged, ^reply_key} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, %{state: :acked, idempotency_key: ^reply_key, ack_nonce: reply_nonce}} =
             Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [reply_key])

    assert reply_nonce == reply_item.nonce
    assert {:ok, [^primary_item]} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)
    assert {:acknowledged, ^primary_id} = Wave4ChannelExample.advance(fixture.host)

    assert {:ok, %{state: :acked, idempotency_key: primary_key, ack_nonce: primary_nonce}} =
             Elzoo.DurableLog.Store.read(
               fixture.command_store,
               :read_ack,
               [primary_item.idempotency_key]
             )

    assert primary_key == primary_item.idempotency_key
    assert primary_nonce == primary_item.nonce
    assert {:ok, []} = Elzoo.Wave4ChannelTestHelper.pending_outbox(fixture)

    assert {:completed, %{revision: ^reply_revision}} =
             CheckedCommand.result(fixture.handles.reply_input, result_scope, reply_identity)

    answer_operation =
      Elzoo.Wave4ChannelTestHelper.answer_operation(
        fixture.profile,
        primary_event["event_id"],
        primary_id
      )

    assert {:unknown, :not_observed} =
             CheckedCommand.result(
               fixture.handles.answer,
               result_scope,
               {fixture.profile.tenant, fixture.profile.actor, answer_operation}
             )

    assert {:ok, final_resource} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    assert final_resource.revision == custody_revision

    assert {:ok, final_entries, _final_conversation_messages} =
             read_conversation(fixture, scope)

    final_inputs = Enum.filter(final_entries, &(&1[:kind] == :input))
    final_answers = Enum.filter(final_entries, &(&1[:kind] == :answer))
    final_associations = Enum.filter(final_entries, &(&1[:kind] == :association))
    assert Enum.count(final_inputs, &(&1[:role] == "source")) == 2
    assert final_answers == []
    assert Enum.count(final_associations, &(&1[:run_id] == run_id)) == 1

    assert {:ok, after_run_expiry} = RunApprovalRelease.status(fixture.owner, run_id)
    assert after_run_expiry.current_attempt == before_run_expiry.current_attempt
    assert after_run_expiry.attempts == before_run_expiry.attempts
    assert after_run_expiry.outcome == :out_of_time
    assert :sys.get_state(fixture.host).current == nil
    assert take_hash_calls() == []
  end

  defp advance_to_answer(host, deadline, steps) do
    if :sys.get_state(host).phase == :answer do
      :ok
    else
      result = Wave4ChannelExample.advance(host)

      if System.monotonic_time(:millisecond) >= deadline do
        flunk(
          "answer phase not reached before deadline: #{inspect(Enum.reverse([result | steps]))}"
        )
      end

      if match?({:pending, _}, result), do: Process.sleep(5)
      advance_to_answer(host, deadline, [result | steps])
    end
  end

  defp release_envelope(profile, key, now, evidence_id) do
    %{
      purpose: :command,
      tenant: profile.tenant,
      evidence: %{
        verifier: "wave4-command-approver",
        evidence_id: evidence_id,
        reviewer: "reviewer",
        request: key,
        decision: :approve,
        scope: :once,
        issued_at: now - 1_000,
        expiry: now + 60_000
      }
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

  # v2 shares one Postgres schema across the conversation, command and native
  # stores; compare only rows belonging to native streams.
  defp native_store_snapshot(store) do
    store
    |> Elzoo.DurableLog.PostgresHarness.hook(:snapshot, [])
    |> Map.new(fn {table, rows} ->
      {table,
       Enum.reject(rows, fn
         [stream | _] when is_binary(stream) ->
           String.starts_with?(stream, "conversation/") or String.starts_with?(stream, "cc1:")

         _ ->
           false
       end)}
    end)
  end

  # Route the host's own command-store calls (outbox windows, acknowledgements
  # and their readbacks) through a probe whose faults target one key. The
  # CheckedCommand handles keep their own store.
  defp probe_host_command_store!(fixture) do
    {store, probe} = Elzoo.Wave4ChannelTest.ReadProbe.attach(fixture.command_store)
    on_exit(fn -> if Process.alive?(probe), do: Agent.stop(probe) end)
    :sys.replace_state(fixture.host, &%{&1 | command_store: store})
    probe
  end

  defp probe_host_conversation_store!(fixture) do
    {store, probe} = Elzoo.Wave4ChannelTest.ReadProbe.attach(fixture.conversation_store)
    on_exit(fn -> if Process.alive?(probe), do: Agent.stop(probe) end)
    :sys.replace_state(fixture.host, &put_in(&1, [:conversation, :store], store))
    probe
  end

  # Serves the host a full outbox window: the tenant's lowest pending items
  # besides `hidden`, each passed through `rewrite`.
  defp serve_window!(fixture, probe, hidden, rewrite) do
    stream = Elzoo.Wave4ChannelTestHelper.command_stream(fixture.profile.tenant)
    raw = fixture.command_store

    Elzoo.Wave4ChannelTest.ReadProbe.transform(probe, :pending, fn
      {:ok, _rows}, _count ->
        {:ok, rows} = Elzoo.DurableLog.Store.read(raw, :pending, [stream, 64 + length(hidden)])

        {:ok,
         rows
         |> Enum.reject(&(&1.idempotency_key in hidden))
         |> Enum.take(64)
         |> Enum.map(rewrite)}

      other, _count ->
        other
    end)
  end

  # The same item as a delivery item of its own notice: another
  # conversation's pending delivery, which this conversation never observes.
  defp as_delivery_item(item) do
    rebuilt =
      Outbox.new(
        item.stream,
        item.sequence,
        item.position,
        "wave4-channel-delivery",
        item.payload,
        item.nonce
      )

    Map.merge(item, Map.from_struct(rebuilt))
  end

  defp drain!(fixture, items) do
    Enum.each(items, fn item ->
      assert {:committed, _} = Outbox.ack(fixture.command_store, item.idempotency_key, item.nonce)
    end)
  end

  # A reply round whose reply item is observed, with the key and revision its
  # reply association's delivery item will take.
  defp observed_reply_round!(prefix) do
    fixture = Elzoo.Wave4ChannelTestHelper.reply_fixture()
    {primary_listener, reply_listener} = Elzoo.Wave4ChannelTestHelper.reply_listeners!(fixture)
    {event, wait} = await_reply_wait!(fixture, primary_listener, prefix)
    post_reply!(fixture, reply_listener, wait, "#{prefix}-reply")
    assert {:reply_observed, reply_key} = Wave4ChannelExample.advance(fixture.host)
    {:ok, %{revision: head}} = Elzoo.Wave4ChannelTestHelper.command_head(fixture)
    revision = head + 1

    association_key =
      Elzoo.DurableLog.Codec.item_key(
        Elzoo.Wave4ChannelTestHelper.command_stream(fixture.profile.tenant),
        revision,
        1
      )

    {fixture, event["input_id"], reply_key, revision, association_key}
  end

  defp complete_reply_round!(fixture, primary_id, reply_key) do
    advance_to_answer(fixture.host, System.monotonic_time(:millisecond) + 30_000, [])
    assert {:answered, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:reply_acknowledged, ^reply_key} = Wave4ChannelExample.advance(fixture.host)
    assert {:acknowledged, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
  end

  # An engine whose event waits cannot be read: every other call reaches the
  # real engine.
  defp event_waits_unavailable_engine(engine) do
    proxy = spawn(fn -> forward_engine_calls(engine) end)
    on_exit(fn -> Process.exit(proxy, :kill) end)
    proxy
  end

  defp forward_engine_calls(engine) do
    receive do
      {:"$gen_call", from, {:event_waits, _scope, _limits}} ->
        GenServer.reply(from, {:error, :unavailable})

      {:"$gen_call", from, request} ->
        GenServer.reply(from, GenServer.call(engine, request, 60_000))
    end

    forward_engine_calls(engine)
  end

  defp await_result_unavailable!(host, deadline) do
    case Wave4ChannelExample.advance(host) do
      {:pending, :result_unavailable} ->
        :ok

      {:pending, _reason} = result ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("result never completed: #{inspect(result)}")

        Process.sleep(5)
        await_result_unavailable!(host, deadline)

      other ->
        flunk("unexpected advance: #{inspect(other)}")
    end
  end

  defp wait_until!(check, deadline) do
    cond do
      check.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not reached before the deadline")

      true ->
        Process.sleep(10)
        wait_until!(check, deadline)
    end
  end

  # A v1 round up to its completed native result: the next advance answers.
  defp complete_native_v1!(fixture, listener, event) do
    input_id = event["input_id"]
    run_id = run_id_of(fixture, event)
    unit_id = Elzoo.Wave4ChannelTestHelper.unit_id(run_id)

    assert {:ok, {{_, 202, _}, _, _}} = Elzoo.Wave4ChannelTestHelper.post(listener, event)
    assert {:observed, ^input_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:associated, ^run_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:run_created, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:attempt_started, _} = Wave4ChannelExample.advance(fixture.host)
    assert {:engine_started, ^unit_id} = Wave4ChannelExample.advance(fixture.host)
    assert {:native_input, :applied} = Wave4ChannelExample.advance(fixture.host)

    assert {:result, :completed} =
             wait_for_result(fixture.host, System.monotonic_time(:millisecond) + 10_000)
  end

  # A v2 primary round up to its reply wait.
  defp await_reply_wait!(fixture, primary_listener, event_id) do
    event = Elzoo.Wave4ChannelTestHelper.event(%{"event_id" => event_id})
    primary_id = event["input_id"]
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(primary_listener, event)

    assert {:observed, ^primary_id} = Wave4ChannelExample.advance(fixture.host)
    Enum.each(1..11, fn _ -> Wave4ChannelExample.advance(fixture.host) end)

    assert {:ok, %{event_waits: %{waits: [wait]}}} =
             Wave4ChannelExample.view(fixture.host, scope)

    {event, wait}
  end

  # The signed reply that wakes the primary wait, admitted at the current
  # resource revision.
  defp post_reply!(fixture, reply_listener, wait, event_id) do
    scope = Elzoo.Wave4ChannelTestHelper.scope(fixture.profile)

    assert {:ok, resource} =
             CheckedCommand.resource(fixture.handles.input, scope, fixture.profile.conversation_id)

    reply_event =
      Elzoo.Wave4ChannelTestHelper.event(%{
        "event_id" => event_id,
        "input_id" => wait.correlation_id,
        "expected_revision" => resource.revision,
        "text" => "reply"
      })

    assert {:ok, {{_, 202, _}, _, _}} =
             Elzoo.Wave4ChannelTestHelper.post(reply_listener, reply_event)

    reply_event
  end

  # The next command append commits with its reply lost, and its immediate
  # readback fails: the command's outcome is unknown to the host.
  defp lose_next_command_reply!(fixture) do
    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [
               :read_at,
               :unavailable
             ])

    assert :ok =
             Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :inject, [
               :append,
               :reply_loss
             ])
  end

  # The probed host's pending windows omit one item, as a window that does
  # not reach it would.
  defp hide_from_window!(probe, key) do
    Elzoo.Wave4ChannelTest.ReadProbe.transform(probe, :pending, fn
      {:ok, items}, _count -> {:ok, Enum.reject(items, &(&1.idempotency_key == key))}
      other, _count -> other
    end)
  end

  defp assert_native_items_pending!(fixture, items) do
    Enum.each(items, fn item ->
      nonce = item.nonce

      assert {:ok, %{state: :pending, nonce: ^nonce}} =
               Elzoo.DurableLog.Store.read(fixture.command_store, :read_ack, [
                 item.idempotency_key
               ])
    end)
  end

  # Another nonce acknowledges the answer's delivery key before the next
  # advance: the pending window no longer shows the item, so no delivery pass
  # appends the assistant message, and the host stays fenced before any
  # native acknowledgement.
  defp assert_superseded_answer_fenced!(fixture, key, nonce, native_items) do
    other_nonce = :crypto.strong_rand_bytes(16)
    refute other_nonce == nonce
    {:ok, entries_before} = Elzoo.Wave4ChannelTestHelper.conversation_entries(fixture)
    refute Enum.any?(entries_before, &(&1.kind == :answer))
    assert {:committed, _} = Outbox.ack(fixture.command_store, key, other_nonce)
    probe = probe_host_command_store!(fixture)

    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert {:delivery_ack, ^key, ^nonce, :superseded} = :sys.get_state(fixture.host).poison
    assert {:blocked, :delivery_ack_superseded} = Wave4ChannelExample.advance(fixture.host)
    assert Elzoo.Wave4ChannelTest.ReadProbe.acks(probe) == []
    assert {:ok, ^entries_before} = Elzoo.Wave4ChannelTestHelper.conversation_entries(fixture)
    assert_native_items_pending!(fixture, native_items)
  end

  # A reply-profile writer over the same tenant stream commits one reply
  # input for another conversation and acknowledges its item at once, so the
  # row is invisible to pending windows. Returns the row's key and the
  # reply-profile Store that reads it.
  defp commit_foreign_reply_row!(fixture) do
    profile = fixture.profile
    {module, options} = fixture.command_store
    destinations = ["wave4-channel-input", "wave4-channel-reply", "wave4-channel-delivery"]
    reply_store = {module, put_in(options, [:fold, :destinations], destinations)}
    allow = fn _frame, _context -> :allow end
    gates = %{input: allow, association: allow, answer: allow, reply: allow}
    {:ok, handles} = Wave4ChannelExample.CommandBindings.build_reply(reply_store, gates)
    resource = "foreign-reply-conversation"
    scope = %{tenant: profile.tenant, actor: profile.actor, resources: [resource]}
    facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
    assert {:ok, snapshot} = CheckedCommand.resource(handles.reply_input, scope, resource)

    request = %{
      operation_id:
        Elzoo.Wave4ChannelTestHelper.input_operation_for("foreign-reply-source", "foreign-reply"),
      resource: resource,
      expected_revision: snapshot.revision,
      payload: %{"message_id" => "foreign-reply-message", "text" => "foreign notice"}
    }

    assert {:ok, writes, _response} =
             Wave4ChannelExample.Intents.prepare(snapshot, request, %{
               tenant: profile.tenant,
               actor: profile.actor,
               data: facts
             })

    context = %{
      tenant: profile.tenant,
      actor: profile.actor,
      policy: Elzoo.Wave4ChannelTestHelper.policy(),
      own: writes,
      parent: :none,
      facts: facts
    }

    assert {:completed, _} = CheckedCommand.execute(handles.reply_input, context, request)
    stream = Elzoo.Wave4ChannelTestHelper.command_stream(profile.tenant)
    {:ok, pending} = Outbox.pending(reply_store, stream, 64)
    [foreign] = Enum.filter(pending, &(&1.destination == "wave4-channel-reply"))
    assert {:committed, _} = Outbox.ack(reply_store, foreign.idempotency_key, foreign.nonce)
    {foreign.idempotency_key, reply_store}
  end

  # Another conversation of the tenant commits `count` inputs; returns their
  # pending outbox items.
  defp seed_foreign_inputs!(fixture, count, prefix) do
    conversation = "#{prefix}-conversation"

    Enum.each(1..count, fn index ->
      event =
        Elzoo.Wave4ChannelTestHelper.event(%{
          "event_id" => "#{prefix}-#{index}",
          "input_id" => "#{prefix}-input-#{index}",
          "conversation_id" => conversation,
          "expected_revision" => index - 1
        })

      assert {{:completed, %{revision: ^index}}, _writes} =
               seed_input_command!(fixture, event, :allow)
    end)

    stream = Elzoo.Wave4ChannelTestHelper.command_stream(fixture.profile.tenant)
    {:ok, pending} = Outbox.pending(fixture.command_store, stream, 4_096)
    Enum.filter(pending, &(Jason.decode!(&1.payload)["resource"] == conversation))
  end

  # This round's reply input, committed through its command handle as a reply
  # admitted by an earlier lifetime would be.
  defp commit_reply_input!(fixture, wait, event_id) do
    profile = fixture.profile
    scope = Elzoo.Wave4ChannelTestHelper.scope(profile)

    assert {:ok, resource} =
             CheckedCommand.resource(fixture.handles.input, scope, profile.conversation_id)

    request = %{
      operation_id: Elzoo.Wave4ChannelTestHelper.reply_operation(profile, event_id),
      resource: profile.conversation_id,
      expected_revision: resource.revision,
      payload: %{"message_id" => wait.correlation_id, "text" => "reply"}
    }

    facts = {:record, [{"input_role", {:text, "source"}}, {"mode", {:text, "append_input"}}]}
    revision = resource.revision + 1

    assert {:completed, %{revision: ^revision}} =
             execute_reply_command(
               fixture.handles.reply_input,
               profile,
               request,
               facts,
               &Wave4ChannelExample.Intents.prepare/3
             )

    request
  end
end
