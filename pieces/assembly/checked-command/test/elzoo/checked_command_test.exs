# SPDX-License-Identifier: Apache-2.0
sql_helper =
  Path.expand(
    "../../../../integration/sql/test/support/durable_log_postgres_test_helper.exs",
    __DIR__
  )

postgres_available? = File.regular?(sql_helper)

if postgres_available? do
  Code.require_file(sql_helper)
else
  defmodule Elzoo.DurableLog.TestRepo do
    def start_link(_), do: {:error, :postgres_test_support_unavailable}
  end

  defmodule Elzoo.DurableLog.PostgresHarness do
    def database_url!, do: nil
    def reachable!(_), do: :ok
    def start_link(_), do: {:error, :postgres_test_support_unavailable}
    def attach(_, _, _, _, _), do: {:error, :postgres_test_support_unavailable}
    def hook(_, _, _), do: {:error, :postgres_test_support_unavailable}
    def history(_), do: []
    def paused(_, _), do: nil
    def cleanup(_), do: :ok
  end
end

defmodule Elzoo.CheckedCommandTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Elzoo.{CheckedCommand, PayloadSchema}
  alias Elzoo.DurableLog.{Memory, Postgres, PostgresHarness, TestRepo}
  alias Elzoo.DurableLog.Codec, as: LogCodec

  @hash :binary.copy(<<7>>, 32)
  @port %{
    "id" => "command",
    "direction" => "input",
    "schema_id" => "command/write",
    "schema_version" => 1
  }
  @limits %{max_record_bytes: 1_048_576, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}
  @postgres_helper Path.expand(
                     "../../../../integration/sql/test/support/durable_log_postgres_test_helper.exs",
                     __DIR__
                   )
  @postgres_available File.regular?(@postgres_helper)
  @postgres_skip if(@postgres_available, do: false, else: "PostgreSQL test support is unavailable")

  defp fold do
    %{
      initial: %{},
      kinds: %{"checked_command" => :state_bearing},
      versions: [1],
      destinations: ["notify"],
      reduce: fn model, _sequence, _kind, _payload -> model end
    }
  end

  defp policy(verdict \\ :allow) do
    rule =
      case verdict do
        :ask ->
          %{
            id: "review",
            effect_class: "publish",
            verdict: :ask,
            requirement: %{name: "human", version: 1, scope: :once}
          }

        _ ->
          %{id: "allow", effect_class: "publish", verdict: verdict}
      end

    %{id: "policy", version: 1, content_hash: @hash, effect_classes: ["publish"], rules: [rule]}
  end

  defp context(opts \\ []) do
    Map.merge(
      %{
        tenant: "tenant-1",
        actor: "actor-1",
        policy: policy(),
        own: [%{target: "resource-1", field: "state", value: {:text, "ready"}}],
        parent: :none,
        facts: {:record, [{"region", {:text, "west"}}]}
      },
      Map.new(opts)
    )
  end

  defp request(opts \\ []) do
    Map.merge(
      %{
        operation_id: "operation-1",
        resource: "resource-1",
        expected_revision: 0,
        payload: %{"value" => "ready"}
      },
      Map.new(opts)
    )
  end

  defp descriptor(opts \\ []) do
    {:ok, schema} = PayloadSchema.build(@port, %{})
    observer = Keyword.get(opts, :observer, self())

    prepare =
      Keyword.get(opts, :prepare, fn snapshot, request, facts ->
        send(
          observer,
          {:prepared,
           %{
             operation_id: request.operation_id,
             payload: request.payload,
             snapshot: snapshot,
             facts: facts
           }}
        )

        {:ok, [%{target: request.resource, field: "state", value: {:text, "ready"}}],
         {:record, [{"accepted", true}]}}
      end)

    gate =
      Keyword.get(opts, :gate, fn frame, frame_context ->
        send(observer, {:gate, frame, frame_context})
        :allow
      end)

    Map.merge(
      %{
        id: "checked/write",
        version: 1,
        content_hash: @hash,
        effect_class: "publish",
        port: @port,
        schema: schema,
        prepare: prepare,
        gate: %{call: gate},
        approval: %{verifiers: ["command-reviewer"], max_age: 3_600_000},
        outbox: "notify"
      },
      Keyword.get(opts, :descriptor, %{})
    )
  end

  defp new_handle(store, opts \\ []) do
    descriptor = descriptor(opts)
    {:ok, handle} = CheckedCommand.new(store, descriptor)
    {handle, descriptor}
  end

  defp memory_store do
    {:ok, pid} = Memory.start_link(fold: fold(), limits: @limits, append_visibility: :atomic)
    Process.unlink(pid)
    {Memory.store(pid, %{fold: fold()}), pid}
  end

  defp checkpoint_fixture(store, stream) do
    {:ok, row, _head} = Elzoo.DurableLog.Store.read(store, :read_at, [stream, 1])

    checkpoint = %{
      stream: stream,
      sequence: 1,
      fold_version: 1,
      model: <<1>>,
      cursor: {1, false, []},
      seen: %{1 => row.digest},
      nonce: :crypto.strong_rand_bytes(16)
    }

    Map.put(checkpoint, :digest, LogCodec.hash(LogCodec.checkpoint_bytes(checkpoint)))
  end

  defp insert_message(messages, %{id: id, body: body} = message)
       when is_list(messages) and is_map(message) and not is_struct(message) and
              map_size(message) == 2 do
    cond do
      length(messages) >= 64 ->
        {:error, :capacity}

      not is_binary(id) or not String.valid?(id) or byte_size(id) not in 1..128 ->
        {:error, :invalid}

      :binary.match(id, <<0>>) != :nomatch ->
        {:error, :invalid}

      Enum.any?(messages, &(&1.id == id)) ->
        {:error, :duplicate}

      not is_binary(body) ->
        {:error, :invalid}

      true ->
        {:ok, messages ++ [message]}
    end
  end

  defp insert_message(_, _), do: {:error, :invalid}

  defp prepare_immutable_message(snapshot, request, _facts) do
    message = %{id: request.payload["id"], body: request.payload["body"]}

    with {:ok, messages} <- decode_messages(Map.get(snapshot.fields, "messages", {:list, []})),
         {:ok, messages} <- insert_message(messages, message) do
      writes = [
        %{
          target: request.resource,
          field: "messages",
          value: {:list, Enum.map(messages, &portable_message/1)}
        }
      ]

      {:ok, writes, {:record, [{"message_id", {:text, request.payload["id"]}}]}}
    else
      {:error, :duplicate} -> {:refused, "duplicate_message_id"}
      _ -> {:refused, "invalid_message"}
    end
  end

  defp decode_messages({:list, values}) do
    Enum.reduce_while(values, {:ok, []}, fn
      {:record, pairs}, {:ok, messages} ->
        fields = Map.new(pairs, fn {key, value} -> {key, portable_text(value)} end)

        if map_size(fields) == 2 and is_binary(fields["id"]) and is_binary(fields["body"]) do
          {:cont, {:ok, messages ++ [%{id: fields["id"], body: fields["body"]}]}}
        else
          {:halt, {:error, :invalid}}
        end

      _, _ ->
        {:halt, {:error, :invalid}}
    end)
  end

  defp decode_messages(_), do: {:error, :invalid}

  defp portable_message(%{id: id, body: body}),
    do: {:record, [{"body", {:text, body}}, {"id", {:text, id}}]}

  defp portable_text({:text, value}), do: value
  defp portable_text(_), do: nil

  defp exercise_immutable_message(store) do
    first_message = %{id: "message-1", body: "first"}

    command_context =
      context(
        own: [
          %{
            target: "resource-1",
            field: "messages",
            value: {:list, [portable_message(first_message)]}
          }
        ]
      )

    {handle, _} = new_handle(store, prepare: &prepare_immutable_message/3)
    scope = %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]}

    first =
      request(operation_id: "message-first", payload: %{"id" => "message-1", "body" => "first"})

    assert {:completed, %{revision: 1}} = CheckedCommand.execute(handle, command_context, first)

    duplicate =
      request(
        operation_id: "message-duplicate",
        expected_revision: 1,
        payload: %{"id" => "message-1", "body" => "changed"}
      )

    refusal = {:conflict, {:domain, "duplicate_message_id"}}
    assert refusal == CheckedCommand.execute(handle, command_context, duplicate)
    assert {:ok, before} = CheckedCommand.resource(handle, scope, "resource-1")
    assert before.revision == 1
    assert before.fields["messages"] == {:list, [portable_message(first_message)]}

    assert {:ok, before_items} =
             Elzoo.Outbox.pending(store, CheckedCommand.Codec.stream("tenant-1"), 64)

    assert length(before_items) == 1

    reopened = new_handle(store, prepare: &prepare_immutable_message/3) |> elem(0)
    assert refusal == CheckedCommand.execute(reopened, command_context, duplicate)

    assert refusal ==
             CheckedCommand.result(
               reopened,
               %{tenant: "tenant-1", actor: "actor-1"},
               {"tenant-1", "actor-1", "message-duplicate"}
             )

    assert {:ok, ^before} = CheckedCommand.resource(reopened, scope, "resource-1")

    assert {:ok, ^before_items} =
             Elzoo.Outbox.pending(store, CheckedCommand.Codec.stream("tenant-1"), 64)
  end

  defp gate_denial_row(tenant, actor, operation_id, sequence, nonce) do
    resource = "resource-1"
    payload = %{"value" => "ready"}
    portable_payload = {:record, [{"value", {:text, "ready"}}]}
    facts = {:record, [{"region", {:text, "west"}}]}
    descriptor = {"checked/write", 1, @hash}

    {:ok, canonical} =
      CheckedCommand.Codec.canonical_request(
        tenant,
        actor,
        operation_id,
        descriptor,
        resource,
        0,
        portable_payload,
        facts
      )

    record = %{
      identity: {tenant, actor, operation_id},
      descriptor: descriptor,
      canonical: canonical,
      canonical_digest: :crypto.hash(:sha256, canonical),
      resource: resource,
      expected_revision: 0,
      payload: payload,
      portable_payload: portable_payload,
      facts: facts,
      prepared: :none,
      mutation_binding: nil,
      decision: :none,
      outcome: {:denied, {:gate, "maintenance"}},
      delta: :none,
      approval_events: []
    }

    {:ok, encoded} = CheckedCommand.Codec.encode_record(record)

    row = %Elzoo.DurableLog.Record{
      stream: CheckedCommand.Codec.stream(tenant),
      sequence: sequence,
      kind: "checked_command",
      schema_version: 1,
      payload: encoded,
      nonce: nonce
    }

    %{row | digest: Elzoo.DurableLog.digest(row)}
  end

  defp authorization_denial_row(tenant, actor, operation_id, sequence, nonce, reason) do
    resource = "resource-1"
    payload = %{"value" => "ready"}
    portable_payload = {:record, [{"value", {:text, "ready"}}]}
    facts = {:record, [{"region", {:text, "west"}}]}
    descriptor = {"checked/write", 1, @hash}
    writes = [%{target: resource, field: "state", value: {:text, "ready"}}]
    response = {:record, [{"accepted", true}]}

    {:ok, canonical} =
      CheckedCommand.Codec.canonical_request(
        tenant,
        actor,
        operation_id,
        descriptor,
        resource,
        0,
        portable_payload,
        facts
      )

    authority = %{
      proposer: actor,
      effect_class: "publish",
      own: writes,
      parent: :none
    }

    proposal = %{
      tenant: tenant,
      resource: resource,
      action_id: operation_id,
      payload: portable_payload,
      writes: writes,
      proposer: actor,
      effect_class: "publish"
    }

    {:ok, decision} = Elzoo.Authorization.decide(policy(:deny), proposal, authority)

    record = %{
      identity: {tenant, actor, operation_id},
      descriptor: descriptor,
      canonical: canonical,
      canonical_digest: :crypto.hash(:sha256, canonical),
      resource: resource,
      expected_revision: 0,
      payload: payload,
      portable_payload: portable_payload,
      facts: facts,
      prepared: {writes, response},
      mutation_binding: CheckedCommand.Codec.mutation_binding(canonical, writes, response),
      decision: decision,
      outcome: {:denied, {:authorization, reason}},
      delta: :none,
      approval_events: []
    }

    {:ok, encoded} = CheckedCommand.Codec.encode_record(record)

    row = %Elzoo.DurableLog.Record{
      stream: CheckedCommand.Codec.stream(tenant),
      sequence: sequence,
      kind: "checked_command",
      schema_version: 1,
      payload: encoded,
      nonce: nonce
    }

    %{row | digest: Elzoo.DurableLog.digest(row)}
  end

  defp exercise_identity_races(store) do
    parent = self()

    prepare = fn _snapshot, request, _facts ->
      send(parent, {:prepared_barrier, request.operation_id, self(), request.payload})

      receive do
        :continue ->
          {:ok, [%{target: request.resource, field: "state", value: {:text, "ready"}}],
           {:record, [{"accepted", true}]}}
      after
        5_000 -> {:refused, "barrier_timeout"}
      end
    end

    {handle, _} = new_handle(store, prepare: prepare)
    scope = %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]}

    equal_request = request(operation_id: "race-equal")
    equal_results = barrier_pair(handle, context(), equal_request, equal_request)
    assert Enum.all?(equal_results, &match?({:completed, %{revision: 1}}, &1))

    first =
      request(operation_id: "race-different", expected_revision: 1, payload: %{"value" => "left"})

    second =
      request(operation_id: "race-different", expected_revision: 1, payload: %{"value" => "right"})

    different_results = barrier_pair(handle, context(), first, second)

    assert Enum.count(different_results, &match?({:completed, %{revision: 2}}, &1)) == 1
    assert Enum.count(different_results, &(&1 == {:conflict, :identity})) == 1

    assert {:ok, %{revision: 2, fields: %{"state" => {:text, "ready"}}}} =
             CheckedCommand.resource(handle, scope, "resource-1")

    assert {:ok, items} = Elzoo.Outbox.pending(store, CheckedCommand.Codec.stream("tenant-1"), 64)
    assert length(items) == 2
  end

  defp barrier_pair(handle, context, first, second) do
    tasks = [
      Task.async(fn -> CheckedCommand.execute(handle, context, first) end),
      Task.async(fn -> CheckedCommand.execute(handle, context, second) end)
    ]

    arrivals =
      Enum.map(1..2, fn _ ->
        assert_receive {:prepared_barrier, operation_id, pid, _payload}, 5_000
        {operation_id, pid}
      end)

    assert Enum.all?(arrivals, fn {operation_id, _pid} -> operation_id == first.operation_id end)
    Enum.each(arrivals, fn {_operation_id, pid} -> send(pid, :continue) end)
    Enum.map(tasks, &Task.await(&1, 15_000))
  end

  defp exercise_distinct_revision_race(store) do
    parent = self()

    prepare = fn snapshot, request, _facts ->
      send(parent, {:distinct_prepared, request.operation_id, snapshot.revision, self()})

      receive do
        :continue ->
          value = request.payload["value"]

          {:ok, [%{target: request.resource, field: "state", value: {:text, value}}],
           {:record, [{"accepted", true}]}}
      after
        5_000 -> {:refused, "barrier_timeout"}
      end
    end

    {handle, _} = new_handle(store, prepare: prepare)
    first = request(operation_id: "revision-race-a", payload: %{"value" => "left"})
    second = request(operation_id: "revision-race-b", payload: %{"value" => "right"})
    first_context = context(own: [%{target: "resource-1", field: "state", value: {:text, "left"}}])

    second_context =
      context(own: [%{target: "resource-1", field: "state", value: {:text, "right"}}])

    tasks =
      [{first, first_context}, {second, second_context}]
      |> Enum.map(fn {command, command_context} ->
        Task.async(fn -> CheckedCommand.execute(handle, command_context, command) end)
      end)

    arrivals =
      Enum.map(1..2, fn _ ->
        assert_receive {:distinct_prepared, operation_id, revision, pid}, 5_000
        {operation_id, revision, pid}
      end)

    assert MapSet.new(Enum.map(arrivals, &elem(&1, 0))) ==
             MapSet.new([first.operation_id, second.operation_id])

    assert Enum.all?(arrivals, fn {_operation_id, revision, _pid} -> revision == 0 end)

    Enum.each(arrivals, fn {_operation_id, _revision, pid} -> send(pid, :continue) end)
    pairs = Enum.zip([first, second], Enum.map(tasks, &Task.await(&1, 15_000)))

    assert Enum.count(pairs, fn {_command, result} ->
             match?({:completed, %{revision: 1}}, result)
           end) == 1

    assert Enum.count(pairs, fn {_command, result} -> result == {:conflict, :stale_revision} end) ==
             1

    Enum.each(pairs, fn {command, outcome} ->
      identity = {"tenant-1", "actor-1", command.operation_id}

      assert outcome ==
               CheckedCommand.result(handle, %{tenant: "tenant-1", actor: "actor-1"}, identity)
    end)

    {winning_request, _} =
      Enum.find(pairs, fn {_command, result} -> match?({:completed, _}, result) end)

    assert {:ok, %{revision: 1, fields: %{"state" => {:text, value}}}} =
             CheckedCommand.resource(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
               "resource-1"
             )

    assert value == winning_request.payload["value"]
    assert {:ok, items} = Elzoo.Outbox.pending(store, CheckedCommand.Codec.stream("tenant-1"), 64)
    assert length(items) == 1
  end

  if @postgres_available do
    setup_all do
      {:ok, repo} =
        TestRepo.start_link(url: PostgresHarness.database_url!(), pool_size: 20, log: false)

      Process.unlink(repo)
      :ok = PostgresHarness.reachable!(TestRepo)

      on_exit(fn ->
        if Process.alive?(repo), do: Supervisor.stop(repo)
      end)

      :ok
    end

    setup do
      {:ok, controller} = PostgresHarness.start_link([])
      Process.unlink(controller)
      prefix = "cc_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      _ = SQL.query!(TestRepo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [], log: false)

      :ok =
        Ecto.Migrator.up(TestRepo, 1, Elzoo.DurableLog.TestMigration, prefix: prefix, log: false)

      store = PostgresHarness.attach(TestRepo, prefix, fold(), @limits, controller)

      on_exit(fn ->
        PostgresHarness.cleanup(controller)

        _ =
          SQL.query!(TestRepo, "DROP SCHEMA #{Postgres.identifier(prefix)} CASCADE", [], log: false)

        Agent.stop(controller)
      end)

      %{store: store, controller: controller, prefix: prefix}
    end
  else
    setup_all do
      :ok
    end

    setup do
      %{}
    end
  end

  test "Memory commits mutation and receipt; retained replay skips gate and prepare" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {handle, _descriptor} = new_handle(store)

    assert {:completed, %{revision: 1, response: {:record, [{"accepted", true}]}}} =
             CheckedCommand.execute(handle, context(), request())

    assert_receive {:gate, {:PatternStep, frame}, frame_context}

    assert frame == %{
             "type" => "request",
             "version" => 1,
             "actions" => [
               %{
                 "id" => "operation-1",
                 "kind" => "local_work",
                 "schema_id" => "command/write",
                 "schema_version" => 1,
                 "payload" => %{"value" => "ready"}
               }
             ]
           }

    assert frame_context == %{
             proposer: "actor-1",
             effect_class: "publish",
             tenant: "tenant-1"
           }

    assert_receive {:prepared,
                    %{
                      operation_id: "operation-1",
                      payload: %{"value" => "ready"},
                      snapshot: snapshot,
                      facts: prepared_facts
                    }}

    assert snapshot == %{
             tenant: "tenant-1",
             resource: "resource-1",
             revision: 0,
             fields: %{}
           }

    assert prepared_facts == %{
             tenant: "tenant-1",
             actor: "actor-1",
             data: {:record, [{"region", {:text, "west"}}]}
           }

    stream =
      "cc1:" <>
        Base.url_encode64(
          :erlang.term_to_binary({:cc, 1, "tenant-1"}, [:deterministic]),
          padding: false
        )

    assert stream == Elzoo.CheckedCommand.Codec.stream("tenant-1")
    assert {:ok, [item]} = Elzoo.Outbox.pending(store, stream, 64)
    assert item.destination == "notify"
    assert {:committed, _revision} = Elzoo.Outbox.ack(store, item.idempotency_key, item.nonce)
    assert {:ok, []} = Elzoo.Outbox.pending(store, stream, 64)
    assert {:completed, %{revision: 1}} = CheckedCommand.execute(handle, context(), request())

    assert {:completed, %{revision: 1}} =
             CheckedCommand.execute(handle, context(policy: policy(:deny)), request())

    refute_receive {:gate, _, _}
    refute_receive {:prepared, _}

    scope = %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]}

    assert {:ok, %{revision: 1, fields: %{"state" => {:text, "ready"}}}} =
             CheckedCommand.resource(handle, scope, "resource-1")

    assert {:completed, %{revision: 1}} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "actor-1"},
               {"tenant-1", "actor-1", "operation-1"}
             )

    assert :not_found =
             CheckedCommand.result(
               handle,
               %{tenant: "other", actor: "actor-1"},
               {"tenant-1", "actor-1", "operation-1"}
             )

    assert :not_found =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "other"},
               {"tenant-1", "actor-1", "operation-1"}
             )

    assert {:unknown, :not_observed} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "actor-1"},
               {"tenant-1", "actor-1", "not-yet-observed"}
             )
  end

  test "unused valid checkpoint cannot replace full replay or authorize pruned history" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {handle, _} = new_handle(store, descriptor: %{outbox: nil})

    assert {:completed, %{revision: 1}} = CheckedCommand.execute(handle, context(), request())
    stream = Elzoo.CheckedCommand.Codec.stream("tenant-1")
    checkpoint = checkpoint_fixture(store, stream)
    assert {:committed, 1} = Memory.put_checkpoint(store, checkpoint)

    assert {:ok, %{revision: 1, fields: %{"state" => {:text, "ready"}}}} =
             CheckedCommand.resource(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
               "resource-1"
             )

    assert {:committed, 1} = Memory.retain(store, stream, 0, 1, :crypto.strong_rand_bytes(16))

    assert {:unknown, :unresolved} =
             CheckedCommand.resource(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
               "resource-1"
             )
  end

  test "resource and result scopes are checked before storage; matching absence is unknown" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {handle, _} = new_handle(store)

    assert {:ok, [%{id: "message-1", body: "first"}]} =
             insert_message([], %{id: "message-1", body: "first"})

    messages = [%{id: "message-1", body: "first"}]
    assert {:error, :duplicate} = insert_message(messages, %{id: "message-1", body: "second"})
    assert messages == [%{id: "message-1", body: "first"}]

    Memory.fault(store, :head, :unavailable)

    assert {:refused, :invalid_request} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", extra: true},
               {"tenant-1", "actor-1", "missing"}
             )

    assert {:unknown, :storage} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "actor-1"},
               {"tenant-1", "actor-1", "missing"}
             )
  end

  test "existing identity lookup remains available at the operation limit" do
    limits = Map.put(@limits, :max_batch_size, 1_024)
    {:ok, pid} = Memory.start_link(fold: fold(), limits: limits, append_visibility: :atomic)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    store = Memory.store(pid, %{fold: fold()})
    nonce = :crypto.strong_rand_bytes(16)

    rows =
      Enum.map(1..1_024, fn n ->
        gate_denial_row("tenant-1", "actor-1", "operation-#{n}", n, nonce)
      end)

    assert {:committed, 1_024} =
             Memory.append(store, CheckedCommand.Codec.stream("tenant-1"), 0, rows, [])

    {handle, _} = new_handle(store)
    scope = %{tenant: "tenant-1", actor: "actor-1"}

    assert {:denied, {:gate, "maintenance"}} =
             CheckedCommand.result(handle, scope, {"tenant-1", "actor-1", "operation-1"})

    assert {:denied, {:gate, "maintenance"}} =
             CheckedCommand.execute(handle, context(), request())

    assert {:refused, :capacity} =
             CheckedCommand.execute(
               handle,
               context(),
               request(operation_id: "operation-extra")
             )

    refute_receive {:gate, _, _}
    refute_receive {:prepared, _}
  end

  test "expected-revision maximum is valid while above-bound values are rejected" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {handle, _} = new_handle(store)
    maximum = 9_223_372_036_854_775_806

    assert {:conflict, :stale_revision} =
             CheckedCommand.execute(
               handle,
               context(),
               request(operation_id: "revision-maximum", expected_revision: maximum)
             )

    assert {:conflict, :stale_revision} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "actor-1"},
               {"tenant-1", "actor-1", "revision-maximum"}
             )

    assert {:refused, :invalid_request} =
             CheckedCommand.execute(
               handle,
               context(),
               request(operation_id: "revision-over-bound", expected_revision: maximum + 1)
             )

    assert {:unknown, :not_observed} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "actor-1"},
               {"tenant-1", "actor-1", "revision-over-bound"}
             )
  end

  test "Memory barriers preserve equal identity and different-request races" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    exercise_identity_races(store)
  end

  test "Memory distinct commands racing at one resource revision retain winner and stale receipt" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    exercise_distinct_revision_race(store)
  end

  test "Memory command preparation retains immutable message duplicate refusal" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    exercise_immutable_message(store)
  end

  test "unknown record versions fail closed" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {handle, _} = new_handle(store)
    stream = CheckedCommand.Codec.stream("tenant-1")

    row = %Elzoo.DurableLog.Record{
      stream: stream,
      sequence: 1,
      kind: "checked_command",
      schema_version: 1,
      payload: :erlang.term_to_binary({:checked_command_record, 2, :unknown}, [:deterministic]),
      nonce: :crypto.strong_rand_bytes(16)
    }

    row = %{row | digest: Elzoo.DurableLog.digest(row)}
    assert {:committed, 1} = Memory.append(store, stream, 0, [row], [])

    assert {:unknown, :unresolved} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "actor-1"},
               {"tenant-1", "actor-1", "operation-1"}
             )
  end

  test "gate denial is retained without preparation and identity conflicts skip callbacks" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    gate = fn frame, frame_context ->
      send(self(), {:gate_called, frame, frame_context})
      {:deny, "maintenance"}
    end

    {handle, _} = new_handle(store, gate: gate)
    ctx = context()
    req = request()

    assert {:denied, {:gate, "maintenance"}} = CheckedCommand.execute(handle, ctx, req)
    assert_receive {:gate_called, {:PatternStep, _}, _}
    refute_receive {:prepared, _}
    assert {:denied, {:gate, "maintenance"}} = CheckedCommand.execute(handle, ctx, req)
    refute_receive {:gate_called, _, _}

    assert {:conflict, :identity} =
             CheckedCommand.execute(handle, ctx, request(payload: %{"value" => "other"}))

    assert {:conflict, :identity} =
             CheckedCommand.execute(
               handle,
               context(facts: {:record, [{"region", {:text, "east"}}]}),
               req
             )

    assert {:conflict, :identity} =
             CheckedCommand.execute(handle, ctx, request(resource: "resource-2"))

    assert {:conflict, :identity} =
             CheckedCommand.execute(
               new_handle_variant(store, %{content_hash: :binary.copy(<<8>>, 32)}),
               ctx,
               req
             )

    refute_receive {:gate_called, _, _}
    refute_receive {:prepared, _}
  end

  test "Authorization denial and domain refusal are retained without mutation or outbox" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {handle, _} = new_handle(store)

    assert {:denied, {:authorization, _reason}} =
             CheckedCommand.execute(
               handle,
               context(policy: policy(:deny)),
               request(operation_id: "authorization-denial")
             )

    domain_prepare = fn _snapshot, _request, _facts -> {:refused, "invalid_message"} end
    {domain_handle, _} = new_handle(store, prepare: domain_prepare)

    assert {:conflict, {:domain, "invalid_message"}} =
             CheckedCommand.execute(
               domain_handle,
               context(),
               request(operation_id: "domain-refusal")
             )

    assert {:ok, %{revision: 0, fields: %{}}} =
             CheckedCommand.resource(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
               "resource-1"
             )

    assert {:ok, []} = Elzoo.Outbox.pending(store, CheckedCommand.Codec.stream("tenant-1"), 64)
  end

  test "corrupt authorization denial reasons never escape retained results" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    nonce = :crypto.strong_rand_bytes(16)

    row =
      authorization_denial_row(
        "tenant-1",
        "actor-1",
        "corrupt-reason",
        1,
        nonce,
        {:arbitrary, "record-input"}
      )

    assert {:committed, 1} =
             Memory.append(store, CheckedCommand.Codec.stream("tenant-1"), 0, [row], [])

    {handle, _} = new_handle(store)

    assert {:unknown, :unresolved} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "actor-1"},
               {"tenant-1", "actor-1", "corrupt-reason"}
             )
  end

  test "canonical request digest is retained and checked during replay" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    row =
      gate_denial_row(
        "tenant-1",
        "actor-1",
        "bad-canonical-digest",
        1,
        :crypto.strong_rand_bytes(16)
      )

    {:ok, record} = CheckedCommand.Codec.decode_record(row.payload)
    {:ok, payload} = CheckedCommand.Codec.encode_record(%{record | canonical_digest: <<0::256>>})
    row = %{row | payload: payload}
    row = %{row | digest: Elzoo.DurableLog.digest(row)}

    assert {:committed, 1} =
             Memory.append(store, CheckedCommand.Codec.stream("tenant-1"), 0, [row], [])

    {handle, _} = new_handle(store)

    assert {:unknown, :unresolved} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "actor-1"},
               {"tenant-1", "actor-1", "bad-canonical-digest"}
             )
  end

  test "initial ASK cannot be replayed as a completed mutation without release evidence" do
    {source, source_pid} = memory_store()
    on_exit(fn -> if Process.alive?(source_pid), do: GenServer.stop(source_pid) end)
    {source_handle, _} = new_handle(source)

    assert {:approval_pending, _} =
             CheckedCommand.execute(source_handle, context(policy: policy(:ask)), request())

    stream = CheckedCommand.Codec.stream("tenant-1")
    assert {:ok, [row], _head} = Elzoo.DurableLog.Store.read(source, :read, [stream, 1, 1])
    {:ok, record} = CheckedCommand.Codec.decode_record(row.payload)
    {writes, response} = record.prepared

    forged = %{
      record
      | outcome: {:completed, %{revision: 1, response: response}},
        delta: {record.resource, 0, 1, writes},
        approval_events: []
    }

    {:ok, payload} = CheckedCommand.Codec.encode_record(forged)
    forged_row = %{row | payload: payload}
    forged_row = %{forged_row | digest: Elzoo.DurableLog.digest(forged_row)}

    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert {:committed, 1} = Memory.append(store, stream, 0, [forged_row], [])
    {handle, _} = new_handle(store)
    scope = %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]}

    assert {:unknown, :unresolved} =
             CheckedCommand.result(handle, %{tenant: "tenant-1", actor: "actor-1"}, {
               "tenant-1",
               "actor-1",
               "operation-1"
             })

    assert {:unknown, :unresolved} = CheckedCommand.resource(handle, scope, "resource-1")
  end

  test "DENY replay rejects permitted, escrowed, and requirement fields" do
    for {key, value} <- [
          {:permitted, [%{target: "resource-1", field: "state", value: {:text, "ready"}}]},
          {:escrowed, [%{target: "resource-1", field: "state", value: {:text, "ready"}}]},
          {:requirement, %{name: "human", version: 1, scope: :once}}
        ] do
      {store, pid} = memory_store()

      row =
        authorization_denial_row(
          "tenant-1",
          "actor-1",
          "bad-deny-#{key}",
          1,
          :crypto.strong_rand_bytes(16),
          :authority_exceeded
        )

      {:ok, record} = CheckedCommand.Codec.decode_record(row.payload)
      decision = Map.put(record.decision, key, value)
      outcome = {:denied, {:authorization, record.decision.reason}}

      {:ok, payload} =
        CheckedCommand.Codec.encode_record(%{record | decision: decision, outcome: outcome})

      row = %{row | payload: payload}
      row = %{row | digest: Elzoo.DurableLog.digest(row)}
      assert {:committed, 1} = Memory.append(store, row.stream, 0, [row], [])
      {handle, _} = new_handle(store)

      assert {:unknown, :unresolved} =
               CheckedCommand.result(
                 handle,
                 %{tenant: "tenant-1", actor: "actor-1"},
                 {"tenant-1", "actor-1", "bad-deny-#{key}"}
               )

      GenServer.stop(pid)
    end
  end

  test "facts, prepared writes and responses require Authorization portable values" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {handle, _} = new_handle(store)

    assert {:unavailable, :context} =
             CheckedCommand.execute(handle, context(facts: %{"region" => "west"}), request())

    assert {:refused, :invalid_request} =
             CheckedCommand.execute(handle, context(), request(payload: {:text, "not-json"}))

    raw_write = fn _snapshot, command, _facts ->
      {:ok, [%{target: command.resource, field: "state", value: "ready"}],
       {:record, [{"accepted", true}]}}
    end

    {raw_write_handle, _} = new_handle(store, prepare: raw_write)

    assert {:refused, :domain_failure} =
             CheckedCommand.execute(
               raw_write_handle,
               context(),
               request(operation_id: "raw-write")
             )

    raw_response = fn _snapshot, command, _facts ->
      {:ok, [%{target: command.resource, field: "state", value: {:text, "ready"}}],
       %{"accepted" => true}}
    end

    {raw_response_handle, _} = new_handle(store, prepare: raw_response)

    assert {:refused, :domain_failure} =
             CheckedCommand.execute(
               raw_response_handle,
               context(),
               request(operation_id: "raw-response")
             )

    assert {:ok, %{revision: 0, fields: %{}}} =
             CheckedCommand.resource(
               raw_response_handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
               "resource-1"
             )
  end

  test "prepared writes are normalized, coalesced and conflict-checked by Authorization" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    writes = [
      %{target: "resource-1", field: "z", value: {:text, "last"}},
      %{target: "resource-1", field: "a", value: 7},
      %{target: "resource-1", field: "a", value: 7}
    ]

    prepare = fn _snapshot, _command, _facts ->
      {:ok, writes, {:record, [{"accepted", true}]}}
    end

    {handle, _} = new_handle(store, prepare: prepare, gate: fn _frame, _context -> :allow end)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.execute(handle, context(own: writes), request())

    assert {:ok, %{revision: 1, fields: %{"a" => 7, "z" => {:text, "last"}}}} =
             CheckedCommand.resource(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
               "resource-1"
             )

    conflict_prepare = fn _snapshot, _command, _facts ->
      {:ok,
       [
         %{target: "resource-1", field: "a", value: 7},
         %{target: "resource-1", field: "a", value: 8}
       ], {:record, [{"accepted", true}]}}
    end

    {conflict_handle, _} = new_handle(store, prepare: conflict_prepare)

    assert {:refused, :domain_failure} =
             CheckedCommand.execute(
               conflict_handle,
               context(own: writes),
               request(operation_id: "conflicting-writes", expected_revision: 1)
             )

    assert {:ok, %{revision: 1, fields: %{"a" => 7, "z" => {:text, "last"}}}} =
             CheckedCommand.resource(
               conflict_handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
               "resource-1"
             )

    too_many_writes =
      for index <- 1..17 do
        %{target: "resource-1", field: "field-#{index}", value: index}
      end

    too_many_prepare = fn _snapshot, _command, _facts ->
      {:ok, too_many_writes, {:record, [{"accepted", true}]}}
    end

    {too_many_handle, _} = new_handle(store, prepare: too_many_prepare)

    assert {:refused, :domain_failure} =
             CheckedCommand.execute(
               too_many_handle,
               context(own: writes),
               request(operation_id: "too-many-writes", expected_revision: 1)
             )

    assert {:ok, %{revision: 1, fields: %{"a" => 7, "z" => {:text, "last"}}}} =
             CheckedCommand.resource(
               too_many_handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
               "resource-1"
             )
  end

  test "the 64-field resource limit leaves the projection unchanged on overflow" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    writes =
      for index <- 1..64 do
        %{target: "resource-1", field: "field-#{index}", value: index}
      end

    last_write = %{target: "resource-1", field: "field-65", value: 65}
    own = writes ++ [last_write]

    chunks = Enum.chunk_every(writes, 16)

    prepare = fn _snapshot, command, _facts ->
      if command.operation_id == "overflow-fields" do
        {:ok, [last_write], {:record, [{"accepted", true}]}}
      else
        index =
          command.operation_id |> String.replace_prefix("field-chunk-", "") |> String.to_integer()

        {:ok, Enum.at(chunks, index - 1), {:record, [{"accepted", true}]}}
      end
    end

    {handle, _} = new_handle(store, prepare: prepare, gate: fn _frame, _context -> :allow end)
    command_context = context(own: own)

    for index <- 1..4 do
      assert {:completed, %{revision: ^index}} =
               CheckedCommand.execute(
                 handle,
                 command_context,
                 request(operation_id: "field-chunk-#{index}", expected_revision: index - 1)
               )
    end

    assert {:refused, :capacity} =
             CheckedCommand.execute(
               handle,
               command_context,
               request(operation_id: "overflow-fields", expected_revision: 4)
             )

    assert {:ok, %{revision: 4, fields: fields}} =
             CheckedCommand.resource(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
               "resource-1"
             )

    assert map_size(fields) == 64
  end

  test "the encoded resource limit includes the revision and fields map" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    base_fields =
      for index <- 1..15, into: %{} do
        {"field-#{index}", {:text, String.duplicate("x", 4_096)}}
      end

    value_size =
      Enum.find(0..4_096, fn candidate ->
        fields = Map.put(base_fields, "field-16", {:text, String.duplicate("y", candidate)})

        byte_size(:erlang.term_to_binary(%{revision: 1, fields: fields}, [:deterministic])) ==
          65_536
      end)

    assert is_integer(value_size)

    exact_writes =
      Enum.map(base_fields, fn {field, value} ->
        %{target: "resource-1", field: field, value: value}
      end) ++
        [
          %{
            target: "resource-1",
            field: "field-16",
            value: {:text, String.duplicate("y", value_size)}
          }
        ]

    overflow_write = %{target: "resource-1", field: "field-17", value: {:text, "x"}}
    own = exact_writes ++ [overflow_write]

    prepare = fn _snapshot, command, _facts ->
      writes =
        if command.operation_id == "overflow-resource-size",
          do: [overflow_write],
          else: exact_writes

      {:ok, writes, {:record, [{"accepted", true}]}}
    end

    {handle, _} = new_handle(store, prepare: prepare, gate: fn _frame, _context -> :allow end)
    command_context = context(own: own)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.execute(
               handle,
               command_context,
               request(operation_id: "exact-resource-size")
             )

    assert {:refused, :capacity} =
             CheckedCommand.execute(
               handle,
               command_context,
               request(operation_id: "overflow-resource-size", expected_revision: 1)
             )

    assert {:ok, %{revision: 1, fields: fields}} =
             CheckedCommand.resource(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
               "resource-1"
             )

    assert map_size(fields) == 16

    assert byte_size(:erlang.term_to_binary(%{revision: 1, fields: fields}, [:deterministic])) ==
             65_536
  end

  defp new_handle_variant(store, descriptor_changes) do
    {:ok, handle} = CheckedCommand.new(store, descriptor(descriptor: descriptor_changes))
    handle
  end

  test "exact public maps and issue bounds are enforced at the ingress" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    descriptor = descriptor()

    assert {:error, :invalid_descriptor} =
             CheckedCommand.new(store, Map.put(descriptor, :extra, true))

    assert {:error, :invalid_descriptor} =
             CheckedCommand.new(store, %{descriptor | version: 2_147_483_648})

    assert {:ok, _} = CheckedCommand.new(store, %{descriptor | version: 2_147_483_647})

    verifiers = Enum.map(1..64, &"reviewer-#{&1}")
    approval = %{verifiers: verifiers, max_age: 60_000}
    assert {:ok, _} = CheckedCommand.new(store, %{descriptor | approval: approval})

    assert {:error, :invalid_descriptor} =
             CheckedCommand.new(store, %{
               descriptor
               | approval: %{approval | verifiers: verifiers ++ ["reviewer-65"]}
             })

    {:ok, handle} = CheckedCommand.new(store, descriptor)

    assert {:unavailable, :context} =
             CheckedCommand.execute(handle, Map.put(context(), :override, true), request())

    assert {:unavailable, :context} =
             CheckedCommand.execute(handle, context(facts: %{"region" => "west"}), request())

    assert {:refused, :invalid_request} =
             CheckedCommand.execute(handle, context(), Map.put(request(), :tenant, "other"))

    assert {:refused, :invalid_request} =
             CheckedCommand.execute(handle, context(), request(operation_id: <<0>>))

    assert {:refused, :invalid_request} =
             CheckedCommand.execute(
               handle,
               context(),
               request(operation_id: String.duplicate("x", 129))
             )

    assert {:refused, :invalid_request} =
             CheckedCommand.execute(handle, context(), request(expected_revision: -1))

    assert {:refused, :invalid_request} =
             CheckedCommand.execute(
               handle,
               context(),
               request(expected_revision: 9_223_372_036_854_775_807)
             )

    assert {:conflict, :stale_revision} =
             CheckedCommand.execute(
               handle,
               context(),
               request(expected_revision: 9_223_372_036_854_775_806)
             )

    assert {:refused, :invalid_request} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", extra: true},
               {"tenant-1", "actor-1", "operation-1"}
             )

    assert {:refused, :invalid_request} =
             CheckedCommand.resource(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"], extra: true},
               "resource-1"
             )

    assert :not_found =
             CheckedCommand.resource(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["other"]},
               "resource-1"
             )

    assert {:refused, :invalid_request} =
             CheckedCommand.resource(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: List.duplicate("r", 65)},
               "r"
             )

    resources = Enum.map(1..63, &"resource-#{&1}") ++ ["last"]

    assert {:ok, _} =
             CheckedCommand.resource(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: resources},
               "last"
             )

    long_key = String.duplicate("k", 129)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.execute(
               handle,
               context(),
               request(
                 operation_id: "json-property-keys",
                 payload: %{"" => "empty", long_key => "long"}
               )
             )
  end

  test "ASK release accepts only fresh command-purpose once evidence" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {handle, _} = new_handle(store)
    ctx = context(policy: policy(:ask))
    assert {:approval_pending, %{key: key}} = CheckedCommand.execute(handle, ctx, request())

    stream = CheckedCommand.Codec.stream("tenant-1")
    assert {:ok, [row], _head} = Elzoo.DurableLog.Store.read(store, :read, [stream, 1, 1])
    assert {:ok, record} = CheckedCommand.Codec.decode_record(row.payload)
    assert record.decision.verdict == :ask
    assert record.canonical_digest == :crypto.hash(:sha256, record.canonical)
    assert record.decision.reason == {:ask, record.decision.requirement}
    assert record.decision.policy == %{id: "policy", version: 1, content_hash: @hash}
    [{:requested, approval_request}] = record.approval_events

    assert approval_request.binding ==
             Map.take(record.decision, [:action, :escrowed, :policy, :requirement])

    evidence = %{
      verifier: "command-reviewer",
      evidence_id: "evidence-1",
      reviewer: "human",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: 100,
      expiry: 200
    }

    envelope = %{purpose: :command, tenant: "tenant-1", evidence: evidence}

    release_ctx =
      Map.merge(ctx, %{
        approver: %{identity: "human", authority: ctx.own},
        now: 150,
        revoked: []
      })

    identity = {"tenant-1", "actor-1", "operation-1"}

    self_evidence = %{envelope.evidence | reviewer: "actor-1"}
    self_context = Map.put(release_ctx, :approver, %{identity: "actor-1", authority: ctx.own})
    stream = CheckedCommand.Codec.stream("tenant-1")
    {:ok, history_before, _} = Elzoo.DurableLog.Store.read(store, :read, [stream, 1, 64])
    {:ok, outbox_before} = Elzoo.Outbox.pending(store, stream, 64)

    assert match?(
             {:release_refused, _},
             CheckedCommand.release(
               handle,
               self_context,
               identity,
               %{purpose: :command, tenant: "tenant-1", evidence: self_evidence}
             )
           )

    assert {:ok, ^history_before, _} = Elzoo.DurableLog.Store.read(store, :read, [stream, 1, 64])
    assert {:ok, ^outbox_before} = Elzoo.Outbox.pending(store, stream, 64)

    assert {:approval_pending, _} =
             CheckedCommand.result(handle, %{tenant: "tenant-1", actor: "actor-1"}, identity)

    for revision <- [0, 2_147_483_648] do
      invalid_evidence = %{evidence | request: put_elem(key, 4, revision)}

      assert {:release_refused, :invalid_request} =
               CheckedCommand.release(
                 handle,
                 release_ctx,
                 identity,
                 %{envelope | evidence: invalid_evidence}
               )
    end

    boundary_evidence = %{evidence | request: put_elem(key, 4, 2_147_483_647)}

    assert {:release_refused, :evidence} =
             CheckedCommand.release(
               handle,
               release_ctx,
               identity,
               %{envelope | evidence: boundary_evidence}
             )

    assert {:unavailable, :context} =
             CheckedCommand.release(handle, Map.put(release_ctx, :extra, true), identity, envelope)

    assert {:release_refused, :invalid_request} =
             CheckedCommand.release(handle, release_ctx, identity, %{
               purpose: :run,
               tenant: "tenant-1",
               evidence: evidence
             })

    assert {:release_refused, :invalid_request} =
             CheckedCommand.release(handle, release_ctx, identity, %{
               purpose: :command,
               tenant: "other",
               evidence: evidence
             })

    assert {:approval_pending, _} =
             CheckedCommand.result(handle, %{tenant: "tenant-1", actor: "actor-1"}, identity)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.release(handle, release_ctx, identity, envelope)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.release(handle, release_ctx, identity, envelope)
  end

  test "resource write-field bounds are enforced before ASK is retained" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    field = String.duplicate("f", 129)

    prepare = fn _snapshot, request, _facts ->
      {:ok, [%{target: request.resource, field: field, value: {:text, "ready"}}],
       {:record, [{"accepted", true}]}}
    end

    {handle, _} = new_handle(store, prepare: prepare)
    identity = {"tenant-1", "actor-1", "operation-1"}

    assert {:refused, :domain_failure} =
             CheckedCommand.execute(handle, context(policy: policy(:ask)), request())

    assert {:refused, :domain_failure} =
             CheckedCommand.result(handle, %{tenant: "tenant-1", actor: "actor-1"}, identity)

    assert {:ok, %{revision: 0, fields: %{}}} =
             CheckedCommand.resource(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
               "resource-1"
             )
  end

  test "ASK release refusals preserve pending state and do not persist fresh revocations" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {handle, _} = new_handle(store)
    ctx = context(policy: policy(:ask))
    identity = {"tenant-1", "actor-1", "operation-1"}
    assert {:approval_pending, %{key: key}} = CheckedCommand.execute(handle, ctx, request())

    evidence = %{
      verifier: "command-reviewer",
      evidence_id: "evidence-matrix",
      reviewer: "human",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: 100,
      expiry: 200
    }

    envelope = %{purpose: :command, tenant: "tenant-1", evidence: evidence}

    release_ctx =
      Map.merge(ctx, %{
        approver: %{identity: "human", authority: ctx.own},
        now: 150,
        revoked: []
      })

    changed_policy = Map.put(policy(:ask), :id, "changed-policy")

    drift_prepare = fn _snapshot, request, _facts ->
      {:ok, [%{target: request.resource, field: "state", value: {:text, "ready"}}],
       {:record, [{"accepted", false}]}}
    end

    deny_gate = fn _frame, _context -> {:deny, "maintenance"} end
    {:ok, changed_schema} = PayloadSchema.build(@port, %{"required" => ["missing"]})

    variants = [
      {handle, Map.put(release_ctx, :own, [])},
      {handle, Map.put(release_ctx, :policy, changed_policy)},
      {new_handle_variant(store, %{prepare: drift_prepare}), release_ctx},
      {new_handle_variant(store, %{gate: %{call: deny_gate}}), release_ctx},
      {new_handle_variant(store, %{schema: changed_schema}), release_ctx},
      {handle, Map.put(release_ctx, :revoked, [{"command-reviewer", "evidence-matrix"}])}
    ]

    Enum.each(variants, fn {variant, current_context} ->
      assert match?(
               {:release_refused, _},
               CheckedCommand.release(variant, current_context, identity, envelope)
             )

      assert {:approval_pending, _} =
               CheckedCommand.result(variant, %{tenant: "tenant-1", actor: "actor-1"}, identity)

      assert {:ok, %{revision: 0, fields: %{}}} =
               CheckedCommand.resource(
                 variant,
                 %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
                 "resource-1"
               )
    end)

    write_drift = fn _snapshot, request, _facts ->
      {:ok, [%{target: request.resource, field: "state", value: {:text, "changed"}}],
       {:record, [{"accepted", true}]}}
    end

    invalid_evidence = [
      %{evidence | verifier: "unlisted-reviewer"},
      %{evidence | reviewer: "actor-1"},
      %{evidence | request: put_elem(key, 1, "other-operation")},
      %{evidence | issued_at: 151},
      %{evidence | expiry: 149}
    ]

    attempts =
      Enum.map(invalid_evidence, fn bad_evidence ->
        {handle, release_ctx, identity, %{envelope | evidence: bad_evidence}}
      end) ++
        [
          {handle, Map.put(release_ctx, :actor, "other-actor"), identity, envelope},
          {handle, Map.put(release_ctx, :now, 201), identity, envelope},
          {handle, Map.put(release_ctx, :approver, %{identity: "human", authority: []}), identity,
           envelope},
          {handle, Map.put(release_ctx, :policy, policy(:deny)), identity, envelope},
          {new_handle_variant(store, %{prepare: write_drift}), release_ctx, identity, envelope}
        ]

    Enum.each(attempts, fn {variant, current_context, current_identity, current_envelope} ->
      assert match?(
               {:release_refused, _},
               CheckedCommand.release(variant, current_context, current_identity, current_envelope)
             )

      assert {:approval_pending, _} =
               CheckedCommand.result(handle, %{tenant: "tenant-1", actor: "actor-1"}, identity)

      assert {:ok, %{revision: 0, fields: %{}}} =
               CheckedCommand.resource(
                 handle,
                 %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
                 "resource-1"
               )
    end)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.release(handle, release_ctx, identity, envelope)
  end

  test "a resource changed after ASK becomes terminal stale without consuming evidence" do
    {store, pid} = memory_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {handle, _} = new_handle(store)
    ask_context = context(policy: policy(:ask))
    pending_request = request(operation_id: "pending-operation")

    assert {:approval_pending, %{key: key}} =
             CheckedCommand.execute(handle, ask_context, pending_request)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.execute(
               handle,
               context(),
               request(operation_id: "winning-operation", expected_revision: 0)
             )

    evidence = %{
      verifier: "command-reviewer",
      evidence_id: "stale-evidence",
      reviewer: "human",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: 100,
      expiry: 200
    }

    release_context =
      Map.merge(ask_context, %{
        approver: %{identity: "human", authority: ask_context.own},
        now: 150,
        revoked: []
      })

    assert {:conflict, :stale_revision} =
             CheckedCommand.release(
               handle,
               release_context,
               {"tenant-1", "actor-1", "pending-operation"},
               %{purpose: :command, tenant: "tenant-1", evidence: evidence}
             )
  end

  @tag :postgres
  @tag skip: @postgres_skip
  test "PostgreSQL barriers preserve equal identity and different-request races", %{store: store} do
    exercise_identity_races(store)
  end

  @tag :postgres
  @tag skip: @postgres_skip
  test "PostgreSQL distinct commands racing at one resource revision retain winner and stale receipt",
       %{store: store} do
    exercise_distinct_revision_race(store)
  end

  @tag :postgres
  @tag skip: @postgres_skip
  test "PostgreSQL command preparation retains immutable message duplicate refusal", %{store: store} do
    exercise_immutable_message(store)
  end

  @tag :postgres
  @tag skip: @postgres_skip
  test "PostgreSQL retains DENY and checks both identity scope dimensions", %{store: store} do
    {handle, _} = new_handle(store, descriptor: %{outbox: nil})
    identity = {"tenant-1", "actor-1", "postgres-denied"}

    assert {:denied, {:authorization, _}} =
             CheckedCommand.execute(
               handle,
               context(policy: policy(:deny)),
               request(operation_id: "postgres-denied")
             )

    assert :not_found =
             CheckedCommand.result(
               handle,
               %{tenant: "other-tenant", actor: "actor-1"},
               identity
             )

    assert :not_found =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "other-actor"},
               identity
             )

    assert {:denied, {:authorization, _}} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "actor-1"},
               identity
             )
  end

  @tag :postgres
  @tag skip: @postgres_skip
  test "PostgreSQL rejects a gap in otherwise unpruned history", %{store: store, prefix: prefix} do
    {handle, _} = new_handle(store, descriptor: %{outbox: nil})
    assert {:completed, %{revision: 1}} = CheckedCommand.execute(handle, context(), request())
    stream = CheckedCommand.Codec.stream("tenant-1")
    checkpoint = checkpoint_fixture(store, stream)
    assert {:committed, 1} = Postgres.put_checkpoint(store, checkpoint)

    SQL.query!(
      TestRepo,
      "DELETE FROM #{Postgres.identifier(prefix)}.elzoo_log_records WHERE stream=$1 AND sequence=$2",
      [stream, 1],
      log: false
    )

    assert {:unknown, :unresolved} =
             CheckedCommand.resource(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
               "resource-1"
             )
  end

  @tag :postgres
  @tag skip: @postgres_skip
  test "PostgreSQL ASK refusal matrix preserves pending state and evidence", %{store: store} do
    {handle, _} = new_handle(store, descriptor: %{outbox: nil})
    ask_context = context(policy: policy(:ask))
    identity = {"tenant-1", "actor-1", "operation-1"}

    assert {:approval_pending, %{key: key}} =
             CheckedCommand.execute(handle, ask_context, request())

    evidence = %{
      verifier: "command-reviewer",
      evidence_id: "postgres-refusal-matrix",
      reviewer: "human",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: 100,
      expiry: 200
    }

    envelope = %{purpose: :command, tenant: "tenant-1", evidence: evidence}

    release_context =
      Map.merge(ask_context, %{
        approver: %{identity: "human", authority: ask_context.own},
        now: 150,
        revoked: []
      })

    self_evidence = %{envelope.evidence | reviewer: "actor-1"}

    self_context =
      Map.put(release_context, :approver, %{identity: "actor-1", authority: ask_context.own})

    stream = CheckedCommand.Codec.stream("tenant-1")
    {:ok, history_before, _} = Elzoo.DurableLog.Store.read(store, :read, [stream, 1, 64])
    {:ok, outbox_before} = Elzoo.Outbox.pending(store, stream, 64)

    assert match?(
             {:release_refused, _},
             CheckedCommand.release(
               handle,
               self_context,
               identity,
               %{purpose: :command, tenant: "tenant-1", evidence: self_evidence}
             )
           )

    assert {:ok, ^history_before, _} = Elzoo.DurableLog.Store.read(store, :read, [stream, 1, 64])
    assert {:ok, ^outbox_before} = Elzoo.Outbox.pending(store, stream, 64)

    assert {:approval_pending, _} =
             CheckedCommand.result(handle, %{tenant: "tenant-1", actor: "actor-1"}, identity)

    write_drift = fn _snapshot, request, _facts ->
      {:ok, [%{target: request.resource, field: "state", value: {:text, "changed"}}],
       {:record, [{"accepted", true}]}}
    end

    attempts = [
      {handle, release_context,
       %{envelope | evidence: %{evidence | verifier: "unlisted-reviewer"}}},
      {handle, release_context, %{envelope | evidence: %{evidence | reviewer: "actor-1"}}},
      {handle, release_context,
       %{envelope | evidence: %{evidence | request: put_elem(key, 1, "other-operation")}}},
      {handle, release_context, %{envelope | evidence: %{evidence | issued_at: 151}}},
      {handle, release_context, %{envelope | evidence: %{evidence | expiry: 149}}},
      {handle, Map.put(release_context, :actor, "other-actor"), envelope},
      {handle, Map.put(release_context, :now, 201), envelope},
      {handle, Map.put(release_context, :approver, %{identity: "human", authority: []}), envelope},
      {handle, Map.put(release_context, :policy, policy(:deny)), envelope},
      {new_handle_variant(store, %{prepare: write_drift}), release_context, envelope}
    ]

    Enum.each(attempts, fn {variant, current_context, current_envelope} ->
      assert match?(
               {:release_refused, _},
               CheckedCommand.release(variant, current_context, identity, current_envelope)
             )

      assert {:approval_pending, _} =
               CheckedCommand.result(
                 handle,
                 %{tenant: "tenant-1", actor: "actor-1"},
                 identity
               )

      assert {:ok, %{revision: 0, fields: %{}}} =
               CheckedCommand.resource(
                 handle,
                 %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
                 "resource-1"
               )
    end)

    assert {:completed, %{revision: 1}} =
             CheckedCommand.release(handle, release_context, identity, envelope)
  end

  @tag :postgres
  @tag skip: @postgres_skip
  test "PostgreSQL rejects an Approval request binding detached from its receipt", %{
    store: store,
    prefix: prefix
  } do
    {handle, _} = new_handle(store, descriptor: %{outbox: nil})

    assert {:approval_pending, _} =
             CheckedCommand.execute(handle, context(policy: policy(:ask)), request())

    stream = CheckedCommand.Codec.stream("tenant-1")
    {:ok, row, _head} = Elzoo.DurableLog.Store.read(store, :read_at, [stream, 1])
    {:ok, record} = CheckedCommand.Codec.decode_record(row.payload)
    [{:requested, request_event}] = record.approval_events

    binding =
      Map.update!(
        request_event.binding,
        :action,
        &Map.put(&1, :payload, {:record, [{"value", {:text, "detached"}}]})
      )

    event = Map.put(request_event, :binding, binding)

    {:ok, payload} =
      CheckedCommand.Codec.encode_record(%{record | approval_events: [{:requested, event}]})

    updated = %{row | payload: payload, digest: Elzoo.DurableLog.digest(%{row | payload: payload})}

    SQL.query!(
      TestRepo,
      "UPDATE #{Postgres.identifier(prefix)}.elzoo_log_records SET payload=$1, digest=$2 WHERE stream=$3 AND sequence=$4",
      [updated.payload, updated.digest, stream, 1],
      log: false
    )

    assert {:unknown, :unresolved} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "actor-1"},
               {"tenant-1", "actor-1", "operation-1"}
             )

    other_context = context(tenant: "tenant-2", policy: policy(:ask))
    other_identity = {"tenant-2", "actor-1", "detached-decision"}

    assert {:approval_pending, _} =
             CheckedCommand.execute(
               handle,
               other_context,
               request(operation_id: "detached-decision")
             )

    other_stream = CheckedCommand.Codec.stream("tenant-2")
    {:ok, other_row, _head} = Elzoo.DurableLog.Store.read(store, :read_at, [other_stream, 1])
    {:ok, other_record} = CheckedCommand.Codec.decode_record(other_row.payload)
    foreign_policy = Map.put(other_record.decision.policy, :id, "foreign-policy")
    foreign_decision = %{other_record.decision | policy: foreign_policy}

    {:ok, other_payload} =
      CheckedCommand.Codec.encode_record(%{other_record | decision: foreign_decision})

    other_row = %{other_row | payload: other_payload}
    other_row = %{other_row | digest: Elzoo.DurableLog.digest(other_row)}

    SQL.query!(
      TestRepo,
      "UPDATE #{Postgres.identifier(prefix)}.elzoo_log_records SET payload=$1, digest=$2 WHERE stream=$3 AND sequence=$4",
      [other_row.payload, other_row.digest, other_stream, 1],
      log: false
    )

    assert {:unknown, :unresolved} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-2", actor: "actor-1"},
               other_identity
             )
  end

  @tag :postgres
  @tag skip: @postgres_skip
  test "PostgreSQL ASK consumption survives reopen and rejects cross-command evidence reuse", %{
    store: store
  } do
    {handle, _} = new_handle(store)

    own = [
      %{target: "resource-1", field: "state", value: {:text, "ready"}},
      %{target: "resource-2", field: "state", value: {:text, "ready"}}
    ]

    ctx = context(policy: policy(:ask), own: own)
    first = request()
    assert {:approval_pending, %{key: first_key}} = CheckedCommand.execute(handle, ctx, first)

    store = PostgresHarness.hook(store, :reopen, [])
    {handle, _} = new_handle(store)
    identity = {"tenant-1", "actor-1", "operation-1"}

    evidence = %{
      verifier: "command-reviewer",
      evidence_id: "shared-evidence",
      reviewer: "human",
      request: first_key,
      decision: :approve,
      scope: :once,
      issued_at: 100,
      expiry: 200
    }

    envelope = %{purpose: :command, tenant: "tenant-1", evidence: evidence}

    release_ctx =
      Map.merge(ctx, %{approver: %{identity: "human", authority: own}, now: 150, revoked: []})

    assert {:completed, %{revision: 1}} =
             CheckedCommand.release(handle, release_ctx, identity, envelope)

    second = request(operation_id: "operation-2", resource: "resource-2", expected_revision: 0)
    assert {:approval_pending, %{key: second_key}} = CheckedCommand.execute(handle, ctx, second)

    store = PostgresHarness.hook(store, :reopen, [])
    {handle, _} = new_handle(store)
    second_identity = {"tenant-1", "actor-1", "operation-2"}

    assert {:approval_pending, _} =
             CheckedCommand.result(handle, %{tenant: "tenant-1", actor: "actor-1"}, second_identity)

    reused = %{evidence | request: second_key}
    reused_envelope = %{envelope | evidence: reused}

    assert match?(
             {:release_refused, _},
             CheckedCommand.release(handle, release_ctx, second_identity, reused_envelope)
           )

    assert {:approval_pending, _} =
             CheckedCommand.result(handle, %{tenant: "tenant-1", actor: "actor-1"}, second_identity)
  end

  @tag :postgres
  @tag skip: @postgres_skip
  test "PostgreSQL replay rejects a released event detached from its retained request", %{
    store: store,
    prefix: prefix
  } do
    {handle, _} = new_handle(store, descriptor: %{outbox: nil})
    ask_context = context(policy: policy(:ask))
    identity = {"tenant-1", "actor-1", "operation-1"}

    assert {:approval_pending, %{key: key}} =
             CheckedCommand.execute(handle, ask_context, request())

    evidence = %{
      verifier: "command-reviewer",
      evidence_id: "release-binding",
      reviewer: "human",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: 100,
      expiry: 200
    }

    release_context =
      Map.merge(ask_context, %{
        approver: %{identity: "human", authority: ask_context.own},
        now: 150,
        revoked: []
      })

    assert {:completed, %{revision: 1}} =
             CheckedCommand.release(
               handle,
               release_context,
               identity,
               %{purpose: :command, tenant: "tenant-1", evidence: evidence}
             )

    stream = CheckedCommand.Codec.stream("tenant-1")
    {:ok, row, _head} = Elzoo.DurableLog.Store.read(store, :read_at, [stream, 2])
    {:ok, record} = CheckedCommand.Codec.decode_record(row.payload)
    [{:released, release, nil}] = record.approval_events

    binding = Map.put(release.binding, :policy, Map.put(release.binding.policy, :id, "foreign"))
    event = {:released, Map.put(release, :binding, binding), nil}
    {:ok, payload} = CheckedCommand.Codec.encode_record(%{record | approval_events: [event]})
    updated = %{row | payload: payload}
    updated = %{updated | digest: Elzoo.DurableLog.digest(updated)}

    SQL.query!(
      TestRepo,
      "UPDATE #{Postgres.identifier(prefix)}.elzoo_log_records SET payload=$1, digest=$2 WHERE stream=$3 AND sequence=$4",
      [updated.payload, updated.digest, stream, 2],
      log: false
    )

    assert {:unknown, :unresolved} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "actor-1"},
               identity
             )
  end

  @tag :postgres
  @tag skip: @postgres_skip
  test "PostgreSQL replay rejects a consumed evidence key reused by another command", %{
    store: store
  } do
    {handle, descriptor} = new_handle(store, descriptor: %{outbox: nil})

    own = [
      %{target: "resource-1", field: "state", value: {:text, "ready"}},
      %{target: "resource-2", field: "state", value: {:text, "ready"}}
    ]

    ask_context = context(policy: policy(:ask), own: own)
    first_identity = {"tenant-1", "actor-1", "operation-1"}

    assert {:approval_pending, %{key: first_key}} =
             CheckedCommand.execute(handle, ask_context, request())

    evidence = %{
      verifier: "command-reviewer",
      evidence_id: "shared-replay-evidence",
      reviewer: "human",
      request: first_key,
      decision: :approve,
      scope: :once,
      issued_at: 100,
      expiry: 200
    }

    release_context =
      Map.merge(ask_context, %{
        approver: %{identity: "human", authority: own},
        now: 150,
        revoked: []
      })

    assert {:completed, %{revision: 1}} =
             CheckedCommand.release(
               handle,
               release_context,
               first_identity,
               %{purpose: :command, tenant: "tenant-1", evidence: evidence}
             )

    second_request =
      request(operation_id: "operation-2", resource: "resource-2", expected_revision: 0)

    assert {:approval_pending, %{key: second_key}} =
             CheckedCommand.execute(handle, ask_context, second_request)

    stream = CheckedCommand.Codec.stream("tenant-1")
    {:ok, pending_row, _head} = Elzoo.DurableLog.Store.read(store, :read_at, [stream, 3])
    {:ok, pending_record} = CheckedCommand.Codec.decode_record(pending_row.payload)
    owner = elem(second_key, 0)

    {:ok, approval_state, request_event, _requested} =
      Elzoo.Approval.request(Elzoo.Approval.new(), owner, pending_record.decision)

    assert request_event.key == second_key
    second_evidence = %{evidence | request: second_key}

    approval_context = %{
      now: 150,
      max_age: descriptor.approval.max_age,
      verifiers: descriptor.approval.verifiers,
      run: %{id: owner, root: owner, ancestry: []},
      policy: ask_context.policy,
      proposal: pending_record.decision.action,
      authority: %{
        proposer: ask_context.actor,
        effect_class: descriptor.effect_class,
        own: own,
        parent: :none
      },
      approver: %{identity: "human", authority: own}
    }

    assert {:released, _state, writes, release_event} =
             Elzoo.Approval.release(
               approval_state,
               second_key,
               second_evidence,
               approval_context
             )

    {prepared_writes, response} = pending_record.prepared
    assert writes == prepared_writes

    malicious_record = %{
      pending_record
      | outcome: {:completed, %{revision: 1, response: response}},
        delta: {"resource-2", 0, 1, writes},
        approval_events: [release_event]
    }

    {:ok, payload} = CheckedCommand.Codec.encode_record(malicious_record)

    row = %Elzoo.DurableLog.Record{
      stream: stream,
      sequence: 4,
      kind: "checked_command",
      schema_version: 1,
      payload: payload,
      nonce: :crypto.strong_rand_bytes(16)
    }

    row = %{row | digest: Elzoo.DurableLog.digest(row)}
    assert {:committed, 4} = Postgres.append(store, stream, 3, [row], [])

    store = PostgresHarness.hook(store, :reopen, [])
    {handle, _} = new_handle(store, descriptor: %{outbox: nil})

    assert {:unknown, :unresolved} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "actor-1"},
               {"tenant-1", "actor-1", "operation-2"}
             )
  end

  @tag :postgres
  @tag skip: @postgres_skip
  test "PostgreSQL response loss confirms one atomic record and outbox item", %{store: store} do
    {handle, _} = new_handle(store)
    PostgresHarness.hook(store, :inject, [:append, :reply_loss])
    command_result = CheckedCommand.execute(handle, context(), request())

    receipt_result =
      CheckedCommand.result(
        handle,
        %{tenant: "tenant-1", actor: "actor-1"},
        {"tenant-1", "actor-1", "operation-1"}
      )

    projection =
      CheckedCommand.resource(
        handle,
        %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
        "resource-1"
      )

    snapshot = PostgresHarness.hook(store, :snapshot, [])
    stream = Elzoo.CheckedCommand.Codec.stream("tenant-1")

    record_count =
      Enum.count(snapshot.elzoo_log_records, fn [s, sequence | _] ->
        s == stream and sequence == 1
      end)

    outbox_count =
      Enum.count(snapshot.elzoo_outbox, fn [s, sequence | _] ->
        s == stream and sequence == 1
      end)

    assert {:ok, items} = Postgres.pending(store, stream, 16)

    observed =
      {command_result, receipt_result, projection, length(items), record_count, outbox_count}

    expected =
      {{:completed, %{revision: 1, response: {:record, [{"accepted", true}]}}},
       {:completed, %{revision: 1, response: {:record, [{"accepted", true}]}}},
       {:ok,
        %{
          tenant: "tenant-1",
          resource: "resource-1",
          revision: 1,
          fields: %{"state" => {:text, "ready"}}
        }}, 1, 1, 1}

    unless observed == expected do
      decoded_rows =
        Enum.map(snapshot.elzoo_log_records, fn [
                                                  stream,
                                                  sequence,
                                                  kind,
                                                  version,
                                                  payload,
                                                  nonce,
                                                  digest
                                                ] ->
          {:ok, record} = CheckedCommand.Codec.decode_record(payload)

          %{
            stream: stream,
            sequence: sequence,
            kind: kind,
            version: version,
            identity: record.identity,
            outcome: record.outcome,
            delta: record.delta,
            nonce: nonce,
            digest: digest
          }
        end)

      IO.inspect(decoded_rows, label: "decoded durable PostgreSQL rows", limit: :infinity)
      IO.inspect(snapshot.elzoo_log_records, label: "raw durable PostgreSQL rows", limit: :infinity)
      flunk("mutation, result, resource projection and outbox diverged: #{inspect(observed)}")
    end
  end

  @tag :postgres
  @tag skip: @postgres_skip
  test "PostgreSQL ignores unused checkpoint metadata but refuses pruned replay", %{store: store} do
    {handle, _} = new_handle(store, descriptor: %{outbox: nil})

    assert {:completed, %{revision: 1}} = CheckedCommand.execute(handle, context(), request())
    stream = Elzoo.CheckedCommand.Codec.stream("tenant-1")
    checkpoint = checkpoint_fixture(store, stream)
    assert {:committed, 1} = Postgres.put_checkpoint(store, checkpoint)

    assert {:ok, %{revision: 1}} =
             CheckedCommand.resource(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
               "resource-1"
             )

    assert {:committed, 1} = Postgres.retain(store, stream, 0, 1, :crypto.strong_rand_bytes(16))

    assert {:unknown, :unresolved} =
             CheckedCommand.resource(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-1"]},
               "resource-1"
             )
  end

  @tag :postgres
  @tag skip: @postgres_skip
  test "PostgreSQL paused append remains unknown without automatic reappend", %{
    store: store,
    controller: controller
  } do
    {handle, _} = new_handle(store)
    token = make_ref()
    PostgresHarness.hook(store, :inject, [:append, {:pause, token, :after_head_cas}])
    task = Task.async(fn -> CheckedCommand.execute(handle, context(), request()) end)
    assert {:unknown, :unresolved} = Task.await(task, 15_000)
    assert %{operation: :append} = PostgresHarness.paused(controller, token)

    assert Enum.count(PostgresHarness.history(controller), fn {op, phase} ->
             op == :append and phase == :after_head_cas
           end) == 1

    :ok = PostgresHarness.hook(store, :rollback, [token])
    snapshot = PostgresHarness.hook(store, :snapshot, [])
    assert snapshot.elzoo_log_records == []
    assert snapshot.elzoo_outbox == []
  end

  @tag :postgres
  @tag skip: @postgres_skip
  test "PostgreSQL paused append commit is visible as one record and outbox item", %{
    store: store,
    controller: controller
  } do
    {handle, _} = new_handle(store)
    token = make_ref()
    PostgresHarness.hook(store, :inject, [:append, {:pause, token, :after_head_cas}])
    task = Task.async(fn -> CheckedCommand.execute(handle, context(), request()) end)

    assert {:unknown, :unresolved} = Task.await(task, 15_000)
    assert %{operation: :append} = PostgresHarness.paused(controller, token)

    assert Enum.count(PostgresHarness.history(controller), fn {op, phase} ->
             op == :append and phase == :after_head_cas
           end) == 1

    assert {:committed, 1} = PostgresHarness.hook(store, :release, [token])
    snapshot = PostgresHarness.hook(store, :snapshot, [])
    stream = CheckedCommand.Codec.stream("tenant-1")

    assert Enum.count(snapshot.elzoo_log_records, fn [s, sequence | _] ->
             s == stream and sequence == 1
           end) == 1

    assert Enum.count(snapshot.elzoo_outbox, fn [s, sequence | _] ->
             s == stream and sequence == 1
           end) == 1

    assert {:completed, %{revision: 1}} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "actor-1"},
               {"tenant-1", "actor-1", "operation-1"}
             )

    assert {:completed, %{revision: 1}} = CheckedCommand.execute(handle, context(), request())
  end

  @tag :postgres
  @tag skip: @postgres_skip
  test "resource capacity is enforced before the 65th resource is appended", %{store: store} do
    own =
      for index <- 1..65 do
        %{target: "resource-#{index}", field: "state", value: {:text, "ready"}}
      end

    prepare = fn _snapshot, command, _facts ->
      {:ok, [%{target: command.resource, field: "state", value: {:text, "ready"}}],
       {:record, [{"ok", true}]}}
    end

    {handle, _} = new_handle(store, prepare: prepare, gate: fn _frame, _context -> :allow end)
    command_context = context(own: own)

    for index <- 1..64 do
      assert {:completed, %{revision: 1}} =
               CheckedCommand.execute(
                 handle,
                 command_context,
                 request(operation_id: "capacity-#{index}", resource: "resource-#{index}")
               )
    end

    assert {:refused, :capacity} =
             CheckedCommand.execute(
               handle,
               command_context,
               request(operation_id: "capacity-65", resource: "resource-65")
             )

    assert {:ok, %{revision: 0, fields: %{}}} =
             CheckedCommand.resource(
               handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["resource-65"]},
               "resource-65"
             )

    assert {:completed, %{revision: 1}} =
             CheckedCommand.result(
               handle,
               %{tenant: "tenant-1", actor: "actor-1"},
               {"tenant-1", "actor-1", "capacity-64"}
             )
  end

  @tag :postgres
  @tag skip: @postgres_skip
  test "the 128-byte field and 8,192-byte response limits include their boundaries", %{
    store: store
  } do
    response_size_a = 4_096

    response_size_b =
      Enum.find(0..4_096, fn size ->
        response =
          {:record,
           [
             {"a", {:text, String.duplicate("x", response_size_a)}},
             {"b", {:text, String.duplicate("y", size)}}
           ]}

        byte_size(:erlang.term_to_binary(response, [:deterministic])) == 8_192
      end)

    assert is_integer(response_size_b)
    assert response_size_b < 4_096
    field = String.duplicate("f", 128)

    portable_response =
      {:record,
       [
         {"a", {:text, String.duplicate("x", response_size_a)}},
         {"b", {:text, String.duplicate("y", response_size_b)}}
       ]}

    own =
      for resource <- ["response-boundary", "response-over"] do
        %{target: resource, field: field, value: {:text, "ready"}}
      end

    prepare = fn _snapshot, command, _facts ->
      {:ok, [%{target: command.resource, field: field, value: {:text, "ready"}}], portable_response}
    end

    {handle, _} = new_handle(store, prepare: prepare, gate: fn _frame, _context -> :allow end)
    command_context = context(own: own)

    assert {:completed, %{revision: 1, response: ^portable_response}} =
             CheckedCommand.execute(
               handle,
               command_context,
               request(operation_id: "response-boundary", resource: "response-boundary")
             )

    oversized_prepare = fn _snapshot, command, _facts ->
      {:ok, [%{target: command.resource, field: field, value: {:text, "ready"}}],
       {:record,
        [
          {"a", {:text, String.duplicate("x", response_size_a)}},
          {"b", {:text, String.duplicate("y", response_size_b + 1)}}
        ]}}
    end

    {oversized_handle, _} =
      new_handle(store, prepare: oversized_prepare, gate: fn _frame, _context -> :allow end)

    assert {:refused, :domain_failure} =
             CheckedCommand.execute(
               oversized_handle,
               command_context,
               request(operation_id: "response-over", resource: "response-over")
             )

    assert {:ok, %{revision: 0, fields: %{}}} =
             CheckedCommand.resource(
               oversized_handle,
               %{tenant: "tenant-1", actor: "actor-1", resources: ["response-over"]},
               "response-over"
             )
  end
end
