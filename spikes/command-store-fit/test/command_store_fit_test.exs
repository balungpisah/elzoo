Code.require_file(
  "../../../pieces/integration/sql/test/support/durable_log_postgres_test_helper.exs",
  __DIR__
)

defmodule Elzoo.CommandStoreFit do
  alias Ecto.Adapters.SQL
  alias Elzoo.Authorization
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Postgres, Record}
  alias Elzoo.Outbox

  @identity_keys [:tenant, :actor, :operation_id]
  @trigger_keys [:kind, :binding_id, :expected_revision, :bot_ref, :package_digest, :callable]
  @message_keys [:kind, :conversation_id, :expected_revision, :message_id, :message_bytes]
  @max_identity_bytes 64
  @max_value_bytes 256
  @max_message_bytes 1024
  @max_expected_revision 9_223_372_036_854_775_806
  @destination "command-effects"
  @limits %{max_record_bytes: 8_192, max_batch_size: 4, max_checkpoint_bytes: 8_192}
  @contexts [
    %{tenant: "tenant-one", actor: "actor-one", operation_id: "operation-one"},
    %{tenant: "tenant-two", actor: "actor-two", operation_id: "operation-two"}
  ]
  @tenant_ids ["tenant-one", "tenant-two"]
  @actor_ids ["actor-one", "actor-two"]
  @operation_ids ["operation-one", "operation-two"]
  @fixtures [
    %{
      tenant: "tenant-one",
      bindings: ["binding-one-a", "binding-one-b"],
      conversations: ["conversation-one-a", "conversation-one-b"],
      messages: ["message-one-a", "message-one-b"]
    },
    %{
      tenant: "tenant-two",
      bindings: ["binding-two-a", "binding-two-b"],
      conversations: ["conversation-two-a", "conversation-two-b"],
      messages: ["message-two-a", "message-two-b"]
    }
  ]

  def contexts, do: @contexts
  def identity(context), do: {context.tenant, context.actor, context.operation_id}
  def stream(tenant), do: "command-v1/" <> tenant
  def limits, do: @limits

  def fixture_request(context, kind, index \\ 0)

  def fixture_request(context, :trigger_binding, index) do
    fixture = fixture(context.tenant)

    %{
      kind: "trigger_binding",
      binding_id: Enum.at(fixture.bindings, index),
      expected_revision: 0,
      bot_ref: "bot-ref-v1",
      package_digest: "sha256:package-v1",
      callable: "handle_event"
    }
  end

  def fixture_request(context, :conversation_message, index) do
    fixture = fixture(context.tenant)

    %{
      kind: "conversation_message",
      conversation_id: Enum.at(fixture.conversations, index),
      expected_revision: 0,
      message_id: Enum.at(fixture.messages, index),
      message_bytes: "message bytes #{index + 1}"
    }
  end

  def canonical(context, request) do
    with true <- valid_context?(context),
         {:ok, command} <- canonical_request(context, request) do
      bytes = :erlang.term_to_binary(command.tuple)

      if byte_size(bytes) <= 4_096 do
        {:ok, command.tuple, bytes, :crypto.hash(:sha256, bytes)}
      else
        {:error, :invalid_request}
      end
    else
      _ -> {:error, :invalid_request}
    end
  end

  def prepare(context, request, verdict) do
    with {:ok, tuple, bytes, digest} <- canonical(context, request),
         {:ok, decision, writes} <- authorization(context, request, verdict) do
      {:ok,
       %{
         identity: identity(context),
         tenant: context.tenant,
         actor: context.actor,
         operation_id: context.operation_id,
         tuple: tuple,
         bytes: bytes,
         digest: digest,
         kind: elem(tuple, 4),
         request: request,
         decision: decision,
         writes: writes,
         resource_id: resource_id(request)
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def fold do
    %{
      initial: %{resources: %{}, receipts: %{}},
      kinds: %{
        "command_mutation" => :state_bearing,
        "command_receipt" => :state_bearing
      },
      versions: [1],
      destinations: [@destination],
      reduce: &reduce/4
    }
  end

  def execute_a(store, context, request, verdict) do
    case prepare(context, request, verdict) do
      {:ok, command} -> attempt_a(store, command, 3)
      _ -> {:rejected, :invalid_request}
    end
  end

  def lookup_a(store, context, {tenant, actor, operation_id} = identity) do
    if valid_context?(context) and context.tenant == tenant and context.actor == actor and
         operation_id in @operation_ids do
      with {:ok, model, _head} <- read_a(store, tenant) do
        case Map.get(model.receipts, identity) do
          %{digest: _digest, result: result} -> result
          nil -> :not_found
        end
      else
        _ -> {:unknown, :readback}
      end
    else
      :not_found
    end
  end

  def state_a(store, tenant), do: read_a(store, tenant)

  def execute_b(repo, prefix, context, request, verdict, opts \\ []) do
    case prepare(context, request, verdict) do
      {:ok, command} ->
        b_gate()

        case repo.transaction(fn -> run_b_transaction(repo, prefix, command, opts) end,
               timeout: 15_000
             ) do
          {:ok, result} ->
            drop_response? =
              Keyword.get(opts, :drop_response, false) == true or
                Process.get({__MODULE__, :drop_b_reply}) == true

            if drop_response?,
              do: {:unknown, :lost_response},
              else: result

          {:error, _} ->
            {:unknown, :transaction}
        end

      _ ->
        {:rejected, :invalid_request}
    end
  end

  def lookup_b(repo, prefix, context, {tenant, actor, operation_id}) do
    if valid_context?(context) and context.tenant == tenant and context.actor == actor and
         operation_id in @operation_ids do
      case SQL.query(
             repo,
             "SELECT request_digest,result FROM #{prefix}.command_receipts " <>
               "WHERE tenant=$1 AND actor=$2 AND operation_id=$3",
             [tenant, actor, operation_id],
             log: false
           ) do
        {:ok, %{rows: [[_digest, result]]}} when is_binary(result) -> decode_term(result)
        {:ok, %{rows: []}} -> :not_found
        _ -> {:unknown, :readback}
      end
    else
      :not_found
    end
  end

  def resolve_b(repo, prefix, context, {tenant, actor, operation_id} = identity) do
    if valid_context?(context) and context.tenant == tenant and context.actor == actor and
         operation_id in @operation_ids do
      case lookup_b(repo, prefix, context, identity) do
        :not_found -> {:unknown, :unresolved}
        result -> result
      end
    else
      :not_found
    end
  end

  def setup_b!(repo, prefix) do
    SQL.query!(
      repo,
      "CREATE TABLE #{prefix}.trigger_bindings (" <>
        "tenant TEXT NOT NULL, binding_id TEXT NOT NULL, revision BIGINT NOT NULL, " <>
        "bot_ref TEXT NOT NULL, package_digest TEXT NOT NULL, callable TEXT NOT NULL, " <>
        "PRIMARY KEY (tenant,binding_id))",
      [],
      log: false
    )

    SQL.query!(
      repo,
      "CREATE TABLE #{prefix}.conversations (" <>
        "tenant TEXT NOT NULL, conversation_id TEXT NOT NULL, revision BIGINT NOT NULL, " <>
        "PRIMARY KEY (tenant,conversation_id))",
      [],
      log: false
    )

    SQL.query!(
      repo,
      "CREATE TABLE #{prefix}.conversation_messages (" <>
        "tenant TEXT NOT NULL, conversation_id TEXT NOT NULL, message_id TEXT NOT NULL, " <>
        "message_bytes BYTEA NOT NULL, PRIMARY KEY (tenant,conversation_id,message_id))",
      [],
      log: false
    )

    SQL.query!(
      repo,
      "CREATE TABLE #{prefix}.command_receipts (" <>
        "tenant TEXT NOT NULL, actor TEXT NOT NULL, operation_id TEXT NOT NULL, " <>
        "request_digest BYTEA NOT NULL, target_kind TEXT NOT NULL, resource_id TEXT NOT NULL, " <>
        "status TEXT NOT NULL, result BYTEA, PRIMARY KEY (tenant,actor,operation_id))",
      [],
      log: false
    )

    SQL.query!(
      repo,
      "CREATE TABLE #{prefix}.command_outbox (" <>
        "id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, tenant TEXT NOT NULL, " <>
        "actor TEXT NOT NULL, operation_id TEXT NOT NULL, destination TEXT NOT NULL, " <>
        "payload BYTEA NOT NULL, state TEXT NOT NULL DEFAULT 'pending')",
      [],
      log: false
    )

    seed_b!(repo, prefix)
  end

  def resource_a(store, context, request) do
    with {:ok, model, head} <- read_a(store, context.tenant) do
      key = resource_key(context.tenant, request)
      {:ok, Map.get(model.resources, key, %{revision: 0}), head}
    end
  end

  def resource_b(repo, prefix, context, request) do
    case request.kind do
      "trigger_binding" ->
        SQL.query!(
          repo,
          "SELECT revision,bot_ref,package_digest,callable FROM #{prefix}.trigger_bindings " <>
            "WHERE tenant=$1 AND binding_id=$2",
          [context.tenant, request.binding_id],
          log: false
        ).rows

      "conversation_message" ->
        SQL.query!(
          repo,
          "SELECT revision FROM #{prefix}.conversations WHERE tenant=$1 AND conversation_id=$2",
          [context.tenant, request.conversation_id],
          log: false
        ).rows
    end
  end

  def message_rows_b(
        repo,
        prefix,
        context,
        %{kind: "conversation_message", conversation_id: conversation_id, message_id: message_id}
      ) do
    SQL.query!(
      repo,
      "SELECT message_id,message_bytes FROM #{prefix}.conversation_messages " <>
        "WHERE tenant=$1 AND conversation_id=$2 AND message_id=$3",
      [context.tenant, conversation_id, message_id],
      log: false
    ).rows
    |> Enum.map(fn [id, bytes] -> {id, bytes} end)
  end

  def counts_b(repo, prefix, context) do
    %{
      receipts: count!(repo, "#{prefix}.command_receipts", context.tenant),
      outbox: count!(repo, "#{prefix}.command_outbox", context.tenant),
      bindings:
        SQL.query!(
          repo,
          "SELECT count(*) FROM #{prefix}.trigger_bindings WHERE tenant=$1 AND revision>0",
          [context.tenant],
          log: false
        ).rows
        |> hd()
        |> hd(),
      messages: count!(repo, "#{prefix}.conversation_messages", context.tenant)
    }
  end

  def receipt_count_a(store, tenant) do
    with {:ok, model, _head} <- read_a(store, tenant), do: map_size(model.receipts)
  end

  defp count!(repo, table, tenant) do
    [[count]] =
      SQL.query!(repo, "SELECT count(*) FROM #{table} WHERE tenant=$1", [tenant], log: false).rows

    count
  end

  defp attempt_a(store, command, retries) do
    with {:ok, model, head} <- read_a(store, command.tenant) do
      case Map.get(model.receipts, command.identity) do
        %{digest: digest, result: result} ->
          if digest == command.digest, do: result, else: {:conflict, :identity}

        nil ->
          result = command_result(command, model)
          {records, items, nonce} = append_batch(command, head.revision, result)
          a_gate()

          case Postgres.append(store, stream(command.tenant), head.revision, records, items) do
            {:committed, _revision} ->
              result

            {:conflict, _known_conflict} when retries > 0 ->
              attempt_a(store, command, retries - 1)

            {:conflict, _known_conflict} ->
              {:unknown, :conflict_limit}

            {:indeterminate, _request} ->
              case Log.confirm(store, stream(command.tenant), head.revision, nonce, records) do
                {:committed, _revision} -> result
                _ -> {:unknown, :unresolved}
              end

            {:rejected, reason} ->
              {:rejected, reason}
          end
      end
    else
      _ -> {:unknown, :readback}
    end
  end

  defp read_a(store, tenant) do
    with {:ok, rows, head} <- Log.read(store, stream(tenant), 1, 4_096),
         true <- head.low_water == 0,
         replay <- Log.replay(rows, head, fold()),
         {applied, false, []} <- replay.cursor,
         true <- replay.tail == :intact and applied == head.revision do
      {:ok, replay.model, head}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp append_batch(command, expected, result) do
    mutation? = match?({:applied, _, _}, result)
    nonce = :crypto.strong_rand_bytes(16)
    mutation_sequence = expected + 1

    records =
      (if(mutation?,
         do: [{"command_mutation", mutation_payload(command, result)}],
         else: []
       ) ++
         [{"command_receipt", receipt_payload(command, result)}])
      |> Enum.with_index(expected + 1)
      |> Enum.map(fn {{kind, payload}, sequence} ->
        record(stream(command.tenant), sequence, kind, payload, nonce)
      end)

    items =
      if mutation? do
        [
          Outbox.new(
            stream(command.tenant),
            mutation_sequence,
            1,
            @destination,
            :erlang.term_to_binary({:effect_v1, command.identity, command.digest}),
            nonce
          )
        ]
      else
        []
      end

    {records, items, nonce}
  end

  defp record(stream, sequence, kind, payload, nonce) do
    row = %Record{
      stream: stream,
      sequence: sequence,
      kind: kind,
      schema_version: 1,
      payload: payload,
      nonce: nonce
    }

    %{row | digest: Log.digest(row)}
  end

  defp mutation_payload(command, {:applied, :trigger_binding, revision}) do
    request = command.request

    :erlang.term_to_binary(
      {:binding_v1, command.tenant, request.binding_id, revision, request.bot_ref,
       request.package_digest, request.callable}
    )
  end

  defp mutation_payload(command, {:applied, :conversation_message, revision}) do
    request = command.request

    :erlang.term_to_binary(
      {:message_v1, command.tenant, request.conversation_id, revision, request.message_id,
       request.message_bytes}
    )
  end

  defp receipt_payload(command, result),
    do:
      :erlang.term_to_binary(
        {:receipt_v1, command.tenant, command.actor, command.operation_id, command.digest, result}
      )

  defp reduce(model, "command_mutation", 1, payload) do
    case decode_term(payload) do
      {:binding_v1, tenant, id, revision, bot_ref, package_digest, callable} ->
        Map.update!(model, :resources, fn resources ->
          Map.put(resources, {:trigger_binding, tenant, id}, %{
            revision: revision,
            bot_ref: bot_ref,
            package_digest: package_digest,
            callable: callable
          })
        end)

      {:message_v1, tenant, conversation_id, revision, message_id, message_bytes} ->
        Map.update!(model, :resources, fn resources ->
          key = {:conversation_message, tenant, conversation_id}
          prior = Map.get(resources, key, %{revision: 0, messages: %{}})

          Map.put(resources, key, %{
            revision: revision,
            messages: Map.put(prior.messages, message_id, message_bytes)
          })
        end)

      _ ->
        raise ArgumentError
    end
  end

  defp reduce(model, "command_receipt", 1, payload) do
    case decode_term(payload) do
      {:receipt_v1, tenant, actor, operation_id, digest, result} ->
        Map.update!(model, :receipts, fn receipts ->
          Map.put(receipts, {tenant, actor, operation_id}, %{digest: digest, result: result})
        end)

      _ ->
        raise ArgumentError
    end
  end

  defp command_result(command, model) do
    decision = command.decision

    case decision.verdict do
      :deny ->
        {:denied, decision.reason}

      :ask ->
        {:approval_pending, decision.requirement}

      :allow ->
        if same_writes?(decision.permitted, command.writes) do
          current =
            Map.get(model.resources, resource_key(command.tenant, command.request), %{revision: 0})

          cond do
            current.revision != command.request.expected_revision ->
              {:conflict, :stale_revision}

            command.kind == :conversation_message and
                Map.has_key?(Map.get(current, :messages, %{}), command.request.message_id) ->
              {:conflict, :message_exists}

            true ->
              {:applied, command.kind, current.revision + 1}
          end
        else
          {:rejected, :unauthorized_write_set}
        end

      _ ->
        {:rejected, :unauthorized_write_set}
    end
  end

  defp authorization(context, request, verdict) when verdict in [:allow, :ask, :deny] do
    writes = writes(context, request)
    target = writes |> hd() |> Map.fetch!(:target)

    rule =
      if verdict == :ask do
        %{
          id: "fit-rule",
          effect_class: "command",
          verdict: :ask,
          requirement: %{name: "human", version: 1, scope: :once}
        }
      else
        %{id: "fit-rule", effect_class: "command", verdict: verdict}
      end

    policy = %{
      id: "fit-policy",
      version: 1,
      content_hash: :binary.copy(<<7>>, 32),
      effect_classes: ["command"],
      rules: [rule]
    }

    proposal = %{
      tenant: context.tenant,
      resource: target,
      action_id: context.operation_id,
      payload: {:record, [{"kind", {:text, request.kind}}]},
      writes: writes
    }

    authority = %{
      proposer: context.actor,
      effect_class: "command",
      own: writes,
      parent: :none
    }

    case Authorization.decide(policy, proposal, authority) do
      {:ok, %{verdict: ^verdict} = decision} ->
        valid_decision? =
          case verdict do
            :allow -> same_writes?(decision.permitted, writes) and decision.escrowed == []
            :ask -> decision.permitted == [] and same_writes?(decision.escrowed, writes)
            :deny -> decision.permitted == [] and decision.escrowed == []
          end

        if valid_decision?, do: {:ok, decision, writes}, else: {:error, :authorization}

      _ ->
        {:error, :authorization}
    end
  end

  defp authorization(_, _, _), do: {:error, :authorization}

  defp writes(context, %{kind: "trigger_binding"} = request) do
    target = "trigger-binding/" <> context.tenant <> "/" <> request.binding_id

    [
      %{target: target, field: "bot_ref", value: {:text, request.bot_ref}},
      %{target: target, field: "package_digest", value: {:text, request.package_digest}},
      %{target: target, field: "callable", value: {:text, request.callable}}
    ]
  end

  defp writes(context, %{kind: "conversation_message"} = request) do
    target = "conversation/" <> context.tenant <> "/" <> request.conversation_id

    [%{target: target, field: "message", value: {:text, Base.encode64(request.message_bytes)}}]
  end

  defp same_writes?(left, right), do: MapSet.new(left) == MapSet.new(right)

  defp canonical_request(context, %{kind: "trigger_binding"} = request) do
    with true <- exact_keys?(request, @trigger_keys),
         true <- request.binding_id in fixture(context.tenant).bindings,
         true <-
           Enum.all?(
             [request.bot_ref, request.package_digest, request.callable],
             &bounded_text?(&1, @max_value_bytes)
           ),
         true <- bounded_revision?(request.expected_revision) do
      {:ok,
       %{
         tuple:
           {:command_v1, context.tenant, context.actor, context.operation_id, :trigger_binding,
            request.binding_id, request.expected_revision, request.bot_ref, request.package_digest,
            request.callable}
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp canonical_request(context, %{kind: "conversation_message"} = request) do
    with true <- exact_keys?(request, @message_keys),
         true <- request.conversation_id in fixture(context.tenant).conversations,
         true <- request.message_id in fixture(context.tenant).messages,
         true <- bounded_revision?(request.expected_revision),
         true <-
           is_binary(request.message_bytes) and
             byte_size(request.message_bytes) in 1..@max_message_bytes do
      {:ok,
       %{
         tuple:
           {:command_v1, context.tenant, context.actor, context.operation_id, :conversation_message,
            request.conversation_id, request.expected_revision, request.message_id,
            request.message_bytes}
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp canonical_request(_, _), do: {:error, :invalid_request}

  defp exact_keys?(map, keys) when is_map(map) and not is_struct(map),
    do: MapSet.new(Map.keys(map)) == MapSet.new(keys)

  defp exact_keys?(_, _), do: false

  defp bounded_text?(value, max),
    do:
      is_binary(value) and byte_size(value) in 1..max and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp bounded_revision?(value),
    do: is_integer(value) and value >= 0 and value <= @max_expected_revision

  defp valid_context?(context) do
    exact_keys?(context, @identity_keys) and
      Enum.all?(@identity_keys, &bounded_text?(Map.get(context, &1), @max_identity_bytes)) and
      context.tenant in @tenant_ids and context.actor in @actor_ids and
      context.operation_id in @operation_ids
  end

  defp resource_key(tenant, %{kind: "trigger_binding", binding_id: id}),
    do: {:trigger_binding, tenant, id}

  defp resource_key(tenant, %{kind: "conversation_message", conversation_id: id}),
    do: {:conversation_message, tenant, id}

  defp resource_id(%{kind: "trigger_binding", binding_id: id}), do: id
  defp resource_id(%{kind: "conversation_message", conversation_id: id}), do: id

  defp fixture(tenant), do: Enum.find(@fixtures, &(&1.tenant == tenant))

  defp a_gate do
    case Process.delete({__MODULE__, :a_gate}) do
      {owner, ref} ->
        send(owner, {:a_ready, ref, self()})

        receive do
          {:a_go, ^ref} -> :ok
        after
          15_000 -> raise "command-store-fit A barrier timed out"
        end

      nil ->
        :ok
    end
  end

  defp b_gate do
    case Process.get({__MODULE__, :b_gate}) do
      {owner, ref} ->
        send(owner, {:b_ready, ref, self()})

        receive do
          {:b_go, ^ref} -> :ok
        after
          15_000 -> raise "command-store-fit B barrier timed out"
        end

      nil ->
        :ok
    end
  end

  defp b_reserve_signal(repo) do
    case Process.delete({__MODULE__, :b_reserving}) do
      {owner, ref} ->
        [[pid]] = SQL.query!(repo, "SELECT pg_backend_pid()", [], log: false).rows
        send(owner, {:b_reserving, ref, pid})

      nil ->
        :ok
    end
  end

  defp b_pause(repo) do
    case Process.get({__MODULE__, :b_pause}) do
      {owner, ref} ->
        [[pid]] = SQL.query!(repo, "SELECT pg_backend_pid()", [], log: false).rows
        send(owner, {:b_paused, ref, pid, self()})

        receive do
          {:b_continue, ^ref} -> :ok
        after
          15_000 -> repo.rollback(:barrier_timeout)
        end

      nil ->
        :ok
    end
  end

  defp run_b_transaction(repo, prefix, command, opts) do
    b_reserve_signal(repo)

    inserted =
      SQL.query!(
        repo,
        "INSERT INTO #{prefix}.command_receipts " <>
          "(tenant,actor,operation_id,request_digest,target_kind,resource_id,status,result) " <>
          "VALUES ($1,$2,$3,$4,$5,$6,'reserved',NULL) " <>
          "ON CONFLICT (tenant,actor,operation_id) DO NOTHING RETURNING 1",
        [
          command.tenant,
          command.actor,
          command.operation_id,
          command.digest,
          Atom.to_string(command.kind),
          command.resource_id
        ],
        log: false
      )

    case inserted.num_rows do
      0 ->
        case SQL.query!(
               repo,
               "SELECT request_digest,result FROM #{prefix}.command_receipts " <>
                 "WHERE tenant=$1 AND actor=$2 AND operation_id=$3",
               [command.tenant, command.actor, command.operation_id],
               log: false
             ).rows do
          [[digest, _result]] when digest != command.digest -> {:conflict, :identity}
          [[_digest, result]] when is_binary(result) -> decode_term(result)
          _ -> {:unknown, :unresolved}
        end

      1 ->
        result = apply_b_write(repo, prefix, command)

        if Keyword.get(opts, :rollback_after_mutation, false) == true and
             match?({:applied, _, _}, result),
           do: repo.rollback(:injected_rollback)

        SQL.query!(
          repo,
          "UPDATE #{prefix}.command_receipts SET status=$4,result=$5 " <>
            "WHERE tenant=$1 AND actor=$2 AND operation_id=$3",
          [
            command.tenant,
            command.actor,
            command.operation_id,
            status(result),
            :erlang.term_to_binary(result)
          ],
          log: false
        )

        b_pause(repo)
        result
    end
  end

  defp apply_b_write(repo, prefix, command) do
    decision = command.decision

    case decision.verdict do
      :deny ->
        {:denied, decision.reason}

      :ask ->
        {:approval_pending, decision.requirement}

      :allow ->
        if same_writes?(decision.permitted, command.writes) do
          case update_b_resource(repo, prefix, command) do
            :stale ->
              {:conflict, :stale_revision}

            :message_exists ->
              {:conflict, :message_exists}

            :updated ->
              SQL.query!(
                repo,
                "INSERT INTO #{prefix}.command_outbox " <>
                  "(tenant,actor,operation_id,destination,payload) VALUES ($1,$2,$3,$4,$5)",
                [
                  command.tenant,
                  command.actor,
                  command.operation_id,
                  @destination,
                  :erlang.term_to_binary({:effect_v1, command.identity, command.digest})
                ],
                log: false
              )

              {:applied, command.kind, command.request.expected_revision + 1}
          end
        else
          {:rejected, :unauthorized_write_set}
        end

      _ ->
        {:rejected, :unauthorized_write_set}
    end
  end

  defp update_b_resource(repo, prefix, %{kind: :trigger_binding} = command) do
    request = command.request

    case SQL.query!(
           repo,
           "UPDATE #{prefix}.trigger_bindings SET revision=$4,bot_ref=$5,package_digest=$6,callable=$7 " <>
             "WHERE tenant=$1 AND binding_id=$2 AND revision=$3",
           [
             command.tenant,
             request.binding_id,
             request.expected_revision,
             request.expected_revision + 1,
             request.bot_ref,
             request.package_digest,
             request.callable
           ],
           log: false
         ).num_rows do
      1 -> :updated
      _ -> :stale
    end
  end

  defp update_b_resource(repo, prefix, %{kind: :conversation_message} = command) do
    request = command.request

    case SQL.query!(
           repo,
           "SELECT revision FROM #{prefix}.conversations " <>
             "WHERE tenant=$1 AND conversation_id=$2 FOR UPDATE",
           [command.tenant, request.conversation_id],
           log: false
         ).rows do
      [[revision]] when revision != request.expected_revision ->
        :stale

      [[_revision]] ->
        case SQL.query!(
               repo,
               "SELECT 1 FROM #{prefix}.conversation_messages " <>
                 "WHERE tenant=$1 AND conversation_id=$2 AND message_id=$3",
               [command.tenant, request.conversation_id, request.message_id],
               log: false
             ).rows do
          [[1]] ->
            :message_exists

          [] ->
            case SQL.query!(
                   repo,
                   "UPDATE #{prefix}.conversations SET revision=$3 " <>
                     "WHERE tenant=$1 AND conversation_id=$2 AND revision=$4",
                   [
                     command.tenant,
                     request.conversation_id,
                     request.expected_revision + 1,
                     request.expected_revision
                   ],
                   log: false
                 ).num_rows do
              1 ->
                SQL.query!(
                  repo,
                  "INSERT INTO #{prefix}.conversation_messages " <>
                    "(tenant,conversation_id,message_id,message_bytes) VALUES ($1,$2,$3,$4)",
                  [
                    command.tenant,
                    request.conversation_id,
                    request.message_id,
                    request.message_bytes
                  ],
                  log: false
                )

                :updated

              _ ->
                :stale
            end

          _ ->
            :stale
        end

      _ ->
        :stale
    end
  end

  defp status({:applied, _, _}), do: "applied"
  defp status({:denied, _}), do: "denied"
  defp status({:approval_pending, _}), do: "approval_pending"
  defp status({:conflict, _}), do: "conflict"
  defp status(_), do: "rejected"

  defp seed_b!(repo, prefix) do
    Enum.each(@fixtures, fn fixture ->
      Enum.each(fixture.bindings, fn binding_id ->
        SQL.query!(
          repo,
          "INSERT INTO #{prefix}.trigger_bindings " <>
            "(tenant,binding_id,revision,bot_ref,package_digest,callable) VALUES ($1,$2,0,'','','')",
          [fixture.tenant, binding_id],
          log: false
        )
      end)

      Enum.each(fixture.conversations, fn conversation_id ->
        SQL.query!(
          repo,
          "INSERT INTO #{prefix}.conversations (tenant,conversation_id,revision) VALUES ($1,$2,0)",
          [fixture.tenant, conversation_id],
          log: false
        )
      end)
    end)
  end

  def wait_for_db_lock(repo, pid, deadline) do
    case SQL.query!(
           repo,
           "SELECT wait_event_type FROM pg_stat_activity WHERE pid=$1",
           [pid],
           log: false
         ).rows do
      [["Lock"]] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          wait_for_db_lock(repo, pid, deadline)
        else
          raise "database did not expose the receipt uniqueness wait"
        end
    end
  end

  defp decode_term(bytes), do: :erlang.binary_to_term(bytes, [:safe])
end

defmodule Elzoo.CommandStoreFitTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Elzoo.CommandStoreFit, as: Fit
  alias Elzoo.DurableLog.Postgres
  alias Elzoo.DurableLog.PostgresHarness
  alias Elzoo.DurableLog.TestMigration
  alias Elzoo.DurableLog.TestRepo
  alias Elzoo.Outbox

  @contexts Fit.contexts()
  @url System.get_env("ELZOO_TEST_DATABASE_URL") ||
         raise("ELZOO_TEST_DATABASE_URL is required: dedicated disposable PostgreSQL only")

  setup_all do
    {:ok, repo} = TestRepo.start_link(url: @url, pool_size: 2, log: false)

    try do
      :ok = PostgresHarness.reachable!(TestRepo)
      [[server_version]] = SQL.query!(TestRepo, "SHOW server_version", [], log: false).rows

      [[vector_version]] =
        SQL.query!(
          TestRepo,
          "SELECT extversion FROM pg_extension WHERE extname='vector'",
          [],
          log: false
        ).rows

      IO.puts("command-store-fit PostgreSQL=#{server_version} vector=#{vector_version}")
    after
      Supervisor.stop(repo)
    end

    :ok
  end

  setup do
    Process.flag(:trap_exit, true)
    {:ok, repo} = TestRepo.start_link(url: @url, pool_size: 20, log: false)
    Process.unlink(repo)
    {:ok, controller} = PostgresHarness.start_link([])
    Process.unlink(controller)
    prefix_name = "command_fit_" <> Integer.to_string(System.unique_integer([:positive]))
    prefix = Postgres.identifier(prefix_name)
    SQL.query!(TestRepo, "CREATE SCHEMA #{prefix}", [], log: false)
    :ok = Ecto.Migrator.up(TestRepo, 1, TestMigration, prefix: prefix_name, log: false)
    :ok = Fit.setup_b!(TestRepo, prefix)
    store = PostgresHarness.attach(TestRepo, prefix_name, Fit.fold(), Fit.limits(), controller)

    on_exit(fn ->
      try do
        PostgresHarness.cleanup(controller)
        SQL.query!(TestRepo, "DROP SCHEMA #{prefix} CASCADE", [], log: false)
      after
        Agent.stop(controller)
        if repo = Process.whereis(TestRepo), do: Supervisor.stop(repo)
      end
    end)

    %{store: store, prefix: prefix, controller: controller}
  end

  test "canonical tuples ignore map insertion order and bind identity, target, revision and write set" do
    [context | _] = @contexts

    for kind <- [:trigger_binding, :conversation_message] do
      request = Fit.fixture_request(context, kind, 0)
      reversed = request |> Map.to_list() |> Enum.reverse() |> Map.new()
      assert {:ok, tuple, bytes, digest} = Fit.canonical(context, request)
      assert {:ok, ^tuple, ^bytes, ^digest} = Fit.canonical(context, reversed)
      assert digest == :crypto.hash(:sha256, bytes)

      assert {:error, :invalid_request} =
               Fit.canonical(context, Map.put(request, :extra, "not accepted"))

      assert {:error, :invalid_request} =
               Fit.canonical(context, Map.put(request, :kind, :caller_atom))

      changed =
        case kind do
          :trigger_binding ->
            [
              Map.put(request, :binding_id, "binding-one-b"),
              Map.put(request, :expected_revision, 1),
              Map.put(request, :bot_ref, "bot-ref-v2"),
              Map.put(request, :package_digest, "sha256:package-v2"),
              Map.put(request, :callable, "other_callable")
            ]

          :conversation_message ->
            [
              Map.put(request, :conversation_id, "conversation-one-b"),
              Map.put(request, :expected_revision, 1),
              Map.put(request, :message_id, "message-one-b"),
              Map.put(request, :message_bytes, "changed bytes")
            ]
        end

      Enum.each(changed, fn candidate ->
        assert {:ok, _tuple, other_bytes, other_digest} = Fit.canonical(context, candidate)
        refute other_bytes == bytes
        refute other_digest == digest
      end)

      for {changed_context, changed_request} <- [
            {%{context | tenant: "tenant-two"},
             Fit.fixture_request(%{context | tenant: "tenant-two"}, kind, 0)},
            {%{context | actor: "actor-two"}, request},
            {%{context | operation_id: "operation-two"}, request}
          ] do
        assert {:ok, _tuple, other_bytes, other_digest} =
                 Fit.canonical(changed_context, changed_request)

        refute other_bytes == bytes
        refute other_digest == digest
      end

      unknown_target =
        if kind == :trigger_binding,
          do: Map.put(request, :binding_id, "unlisted-binding"),
          else: Map.put(request, :conversation_id, "unlisted-conversation")

      assert {:error, :invalid_request} = Fit.canonical(context, unknown_target)
    end
  end

  test "revision headroom rejects signed BIGINT max and beyond before either write", ctx do
    [context | _] = @contexts
    bigint_max = 9_223_372_036_854_775_807

    for kind <- [:trigger_binding, :conversation_message] do
      request = Fit.fixture_request(context, kind, 0)

      assert {:ok, _tuple, _bytes, _digest} =
               Fit.canonical(context, Map.put(request, :expected_revision, bigint_max - 1))

      for revision <- [bigint_max, bigint_max + 1] do
        invalid = Map.put(request, :expected_revision, revision)
        assert {:error, :invalid_request} = Fit.canonical(context, invalid)

        for scheme <- [:store, :sql] do
          result =
            if scheme == :store,
              do: Fit.execute_a(ctx.store, context, invalid, :allow),
              else: Fit.execute_b(TestRepo, ctx.prefix, context, invalid, :allow)

          assert result == {:rejected, :invalid_request}

          assert {:ok, %{revision: 0}, _head} =
                   Fit.resource_a(ctx.store, context, request)

          assert Fit.receipt_count_a(ctx.store, context.tenant) == 0
          assert {:ok, []} = Outbox.pending(ctx.store, Fit.stream(context.tenant), 10)

          counts = Fit.counts_b(TestRepo, ctx.prefix, context)
          assert counts.receipts == 0
          assert counts.outbox == 0
          assert counts.bindings == 0
          assert counts.messages == 0
        end
      end
    end
  end

  for {scheme, kind, verdict} <-
        for(
          scheme <- [:store, :sql],
          kind <- [:trigger_binding, :conversation_message],
          verdict <- [:allow, :deny, :ask],
          do: {scheme, kind, verdict}
        ) do
    test "#{scheme} #{kind} retains #{verdict} without unauthorized writes", ctx do
      [context | _] = @contexts
      request = Fit.fixture_request(context, unquote(kind), 0)

      result =
        case unquote(scheme) do
          :store -> Fit.execute_a(ctx.store, context, request, unquote(verdict))
          :sql -> Fit.execute_b(TestRepo, ctx.prefix, context, request, unquote(verdict))
        end

      resource_revision =
        case {unquote(scheme), unquote(kind)} do
          {:store, :trigger_binding} ->
            {:ok, state, _head} = Fit.resource_a(ctx.store, context, request)
            state.revision

          {:store, :conversation_message} ->
            {:ok, state, _head} = Fit.resource_a(ctx.store, context, request)
            state.revision

          {:sql, :trigger_binding} ->
            [[revision, _bot_ref, _digest, _callable]] =
              Fit.resource_b(TestRepo, ctx.prefix, context, request)

            revision

          {:sql, :conversation_message} ->
            [[revision]] = Fit.resource_b(TestRepo, ctx.prefix, context, request)
            revision
        end

      assert resource_revision == if(unquote(verdict) == :allow, do: 1, else: 0)
      assert result == expected_result(unquote(verdict), unquote(kind))

      retained =
        if unquote(scheme) == :store,
          do: Fit.lookup_a(ctx.store, context, Fit.identity(context)),
          else: Fit.lookup_b(TestRepo, ctx.prefix, context, Fit.identity(context))

      assert retained == expected_result(unquote(verdict), unquote(kind))
      changed_verdict = if unquote(verdict) == :deny, do: :allow, else: :deny

      replayed =
        if unquote(scheme) == :store,
          do: Fit.execute_a(ctx.store, context, request, changed_verdict),
          else: Fit.execute_b(TestRepo, ctx.prefix, context, request, changed_verdict)

      assert replayed == expected_result(unquote(verdict), unquote(kind))

      assert retained_after_replay =
               if(unquote(scheme) == :store,
                 do: Fit.lookup_a(ctx.store, context, Fit.identity(context)),
                 else: Fit.lookup_b(TestRepo, ctx.prefix, context, Fit.identity(context))
               )

      assert retained_after_replay == expected_result(unquote(verdict), unquote(kind))

      assert_write_participants(
        unquote(scheme),
        unquote(kind),
        unquote(verdict),
        ctx,
        context,
        request
      )

      counts = Fit.counts_b(TestRepo, ctx.prefix, context)

      case unquote(scheme) do
        :sql ->
          assert counts.receipts == 1
          assert counts.outbox == if(unquote(verdict) == :allow, do: 1, else: 0)

          assert counts.bindings ==
                   if(unquote(kind) == :trigger_binding and unquote(verdict) == :allow,
                     do: 1,
                     else: 0
                   )

          assert counts.messages ==
                   if(unquote(kind) == :conversation_message and unquote(verdict) == :allow,
                     do: 1,
                     else: 0
                   )

        :store ->
          assert Fit.receipt_count_a(ctx.store, context.tenant) == 1
          assert {:ok, items} = Outbox.pending(ctx.store, Fit.stream(context.tenant), 10)
          assert length(items) == if(unquote(verdict) == :allow, do: 1, else: 0)
      end
    end
  end

  test "A shares one tenant stream across callers while retaining per-resource revisions", ctx do
    [context | _] = @contexts
    binding = Fit.fixture_request(context, :trigger_binding, 0)

    message =
      Fit.fixture_request(%{context | operation_id: "operation-two"}, :conversation_message, 0)

    assert {:applied, :trigger_binding, 1} = Fit.execute_a(ctx.store, context, binding, :allow)

    assert {:applied, :conversation_message, 1} =
             Fit.execute_a(ctx.store, %{context | operation_id: "operation-two"}, message, :allow)

    {:ok, binding_state, binding_head} = Fit.resource_a(ctx.store, context, binding)
    {:ok, message_state, message_head} = Fit.resource_a(ctx.store, context, message)
    assert binding_state.revision == 1
    assert message_state.revision == 1
    assert binding_head.revision == 4
    assert message_head.revision == 4
    assert {:ok, items} = Outbox.pending(ctx.store, Fit.stream(context.tenant), 10)
    assert length(items) == 2

    assert {:applied, :trigger_binding, 1} = Fit.execute_a(ctx.store, context, binding, :allow)
    assert {:ok, after_repeat, _head} = Fit.resource_a(ctx.store, context, binding)
    assert after_repeat.revision == 1
    assert Fit.receipt_count_a(ctx.store, context.tenant) == 2
  end

  test "same identity conflicts across trigger-binding resources with valid CAS revisions", ctx do
    [context | _] = @contexts
    first = Fit.fixture_request(context, :trigger_binding, 0)
    other_binding = Fit.fixture_request(context, :trigger_binding, 1)

    for scheme <- [:store, :sql] do
      apply = fn request ->
        if scheme == :store,
          do: Fit.execute_a(ctx.store, context, request, :allow),
          else: Fit.execute_b(TestRepo, ctx.prefix, context, request, :allow)
      end

      assert {:applied, :trigger_binding, 1} = apply.(first)
      assert {:conflict, :identity} = apply.(other_binding)

      if scheme == :store do
        {:ok, untouched, _head} = Fit.resource_a(ctx.store, context, other_binding)
        assert untouched.revision == 0
      else
        assert [[0, _bot_ref, _digest, _callable]] =
                 Fit.resource_b(TestRepo, ctx.prefix, context, other_binding)
      end
    end
  end

  test "same identity conflicts across conversation resources with valid CAS revisions", ctx do
    [base_context | _] = @contexts
    context = %{base_context | operation_id: "operation-two"}
    first = Fit.fixture_request(context, :conversation_message, 0)
    other = Fit.fixture_request(context, :conversation_message, 1)

    for scheme <- [:store, :sql] do
      first_result =
        if scheme == :store,
          do: Fit.execute_a(ctx.store, context, first, :allow),
          else: Fit.execute_b(TestRepo, ctx.prefix, context, first, :allow)

      other_result =
        if scheme == :store,
          do: Fit.execute_a(ctx.store, context, other, :allow),
          else: Fit.execute_b(TestRepo, ctx.prefix, context, other, :allow)

      assert first_result == {:applied, :conversation_message, 1}
      assert other_result == {:conflict, :identity}

      if scheme == :store do
        {:ok, untouched, _head} = Fit.resource_a(ctx.store, context, other)
        assert untouched.revision == 0
      else
        assert [[0]] = Fit.resource_b(TestRepo, ctx.prefix, context, other)
      end
    end
  end

  test "same identity conflicts when the target changes from trigger binding to conversation",
       ctx do
    [context | _] = @contexts
    trigger = Fit.fixture_request(context, :trigger_binding, 0)
    conversation = Fit.fixture_request(context, :conversation_message, 0)

    for scheme <- [:store, :sql] do
      first =
        if scheme == :store,
          do: Fit.execute_a(ctx.store, context, trigger, :allow),
          else: Fit.execute_b(TestRepo, ctx.prefix, context, trigger, :allow)

      second =
        if scheme == :store,
          do: Fit.execute_a(ctx.store, context, conversation, :allow),
          else: Fit.execute_b(TestRepo, ctx.prefix, context, conversation, :allow)

      assert first == {:applied, :trigger_binding, 1}
      assert second == {:conflict, :identity}
    end
  end

  test "same identity conflicts when the target changes from conversation to trigger binding",
       ctx do
    [base_context | _] = @contexts
    context = %{base_context | operation_id: "operation-two"}
    conversation = Fit.fixture_request(context, :conversation_message, 0)
    trigger = Fit.fixture_request(context, :trigger_binding, 1)

    for scheme <- [:store, :sql] do
      first =
        if scheme == :store,
          do: Fit.execute_a(ctx.store, context, conversation, :allow),
          else: Fit.execute_b(TestRepo, ctx.prefix, context, conversation, :allow)

      second =
        if scheme == :store,
          do: Fit.execute_a(ctx.store, context, trigger, :allow),
          else: Fit.execute_b(TestRepo, ctx.prefix, context, trigger, :allow)

      assert first == {:applied, :conversation_message, 1}
      assert second == {:conflict, :identity}
    end
  end

  test "successive conversation appends retain distinct message IDs and bytes", ctx do
    [context | _] = @contexts
    next_context = %{context | operation_id: "operation-two"}
    first = Fit.fixture_request(context, :conversation_message, 0)

    second =
      next_context
      |> Fit.fixture_request(:conversation_message, 1)
      |> Map.put(:conversation_id, first.conversation_id)
      |> Map.put(:expected_revision, 1)

    for scheme <- [:store, :sql] do
      apply = fn request_context, request, verdict ->
        if scheme == :store,
          do: Fit.execute_a(ctx.store, request_context, request, verdict),
          else: Fit.execute_b(TestRepo, ctx.prefix, request_context, request, verdict)
      end

      assert {:applied, :conversation_message, 1} = apply.(context, first, :allow)
      assert {:applied, :conversation_message, 2} = apply.(next_context, second, :allow)

      case scheme do
        :store ->
          assert Fit.lookup_a(ctx.store, context, Fit.identity(context)) ==
                   {:applied, :conversation_message, 1}

          assert Fit.lookup_a(ctx.store, next_context, Fit.identity(next_context)) ==
                   {:applied, :conversation_message, 2}

          {:ok, state, head} = Fit.resource_a(ctx.store, context, first)

          assert state ==
                   %{
                     revision: 2,
                     messages: %{
                       first.message_id => first.message_bytes,
                       second.message_id => second.message_bytes
                     }
                   }

          assert head.revision == 4
          assert Fit.receipt_count_a(ctx.store, context.tenant) == 2
          assert {:ok, outbox} = Outbox.pending(ctx.store, Fit.stream(context.tenant), 10)
          assert length(outbox) == 2

        :sql ->
          assert Fit.lookup_b(TestRepo, ctx.prefix, context, Fit.identity(context)) ==
                   {:applied, :conversation_message, 1}

          assert Fit.lookup_b(TestRepo, ctx.prefix, next_context, Fit.identity(next_context)) ==
                   {:applied, :conversation_message, 2}

          assert Fit.resource_b(TestRepo, ctx.prefix, context, second) == [[2]]

          assert Fit.message_rows_b(TestRepo, ctx.prefix, context, first) ==
                   [{first.message_id, first.message_bytes}]

          assert Fit.message_rows_b(TestRepo, ctx.prefix, context, second) ==
                   [{second.message_id, second.message_bytes}]

          counts = Fit.counts_b(TestRepo, ctx.prefix, context)
          assert counts.receipts == 2
          assert counts.outbox == 2
          assert counts.messages == 2
      end
    end
  end

  test "a duplicate message ID under a new operation retains message_exists without mutation",
       ctx do
    [context | _] = @contexts
    next_context = %{context | operation_id: "operation-two"}
    first = Fit.fixture_request(context, :conversation_message, 0)

    duplicate =
      first
      |> Map.put(:expected_revision, 1)
      |> Map.put(:message_bytes, "changed duplicate bytes")

    for scheme <- [:store, :sql] do
      apply = fn request_context, request, verdict ->
        if scheme == :store,
          do: Fit.execute_a(ctx.store, request_context, request, verdict),
          else: Fit.execute_b(TestRepo, ctx.prefix, request_context, request, verdict)
      end

      assert {:applied, :conversation_message, 1} = apply.(context, first, :allow)
      assert {:applied, :conversation_message, 1} = apply.(context, first, :deny)

      assert {:conflict, :message_exists} = apply.(next_context, duplicate, :allow)
      assert {:conflict, :message_exists} = apply.(next_context, duplicate, :deny)

      case scheme do
        :store ->
          assert {:applied, :conversation_message, 1} ==
                   Fit.lookup_a(ctx.store, context, Fit.identity(context))

          assert {:conflict, :message_exists} ==
                   Fit.lookup_a(ctx.store, next_context, Fit.identity(next_context))

          assert {:ok, state, _head} = Fit.resource_a(ctx.store, context, first)
          assert state == %{revision: 1, messages: %{first.message_id => first.message_bytes}}
          assert Fit.receipt_count_a(ctx.store, context.tenant) == 2
          assert {:ok, outbox} = Outbox.pending(ctx.store, Fit.stream(context.tenant), 10)
          assert length(outbox) == 1

        :sql ->
          assert {:applied, :conversation_message, 1} ==
                   Fit.lookup_b(TestRepo, ctx.prefix, context, Fit.identity(context))

          assert {:conflict, :message_exists} ==
                   Fit.lookup_b(TestRepo, ctx.prefix, next_context, Fit.identity(next_context))

          assert Fit.resource_b(TestRepo, ctx.prefix, context, first) == [[1]]

          assert Fit.message_rows_b(TestRepo, ctx.prefix, context, first) ==
                   [{first.message_id, first.message_bytes}]

          counts = Fit.counts_b(TestRepo, ctx.prefix, context)
          assert counts.receipts == 2
          assert counts.outbox == 1
          assert counts.messages == 1
      end
    end
  end

  for {scenario, operation_id, first_kind, first_index, second_kind, second_index} <- [
        {"distinct trigger resources", "operation-one", :trigger_binding, 0, :trigger_binding, 1},
        {"distinct conversation resources", "operation-two", :conversation_message, 0,
         :conversation_message, 1},
        {"trigger to conversation", "operation-one", :trigger_binding, 0, :conversation_message, 0},
        {"conversation to trigger", "operation-two", :conversation_message, 0, :trigger_binding, 1}
      ] do
    test "concurrent same-identity different-byte race across #{scenario}", ctx do
      [base_context | _] = @contexts
      context = %{base_context | operation_id: unquote(operation_id)}
      first = Fit.fixture_request(context, unquote(first_kind), unquote(first_index))
      second = Fit.fixture_request(context, unquote(second_kind), unquote(second_index))

      for scheme <- [:store, :sql] do
        results = run_identity_race(scheme, ctx, context, [first, second])
        assert Enum.count(results, &match?({:applied, _, 1}, &1)) == 1
        assert Enum.count(results, &(&1 == {:conflict, :identity})) == 1

        for {request, result} <- Enum.zip([first, second], results) do
          expected_revision = if match?({:applied, _, 1}, result), do: 1, else: 0

          assert resource_revision(scheme, ctx, context, request) == expected_revision

          if request.kind == "conversation_message" do
            case scheme do
              :store ->
                {:ok, state, _head} = Fit.resource_a(ctx.store, context, request)
                expected_messages = if expected_revision == 1, do: 1, else: 0
                assert map_size(Map.get(state, :messages, %{})) == expected_messages

              :sql ->
                expected_rows =
                  if expected_revision == 1,
                    do: [{request.message_id, request.message_bytes}],
                    else: []

                assert Fit.message_rows_b(TestRepo, ctx.prefix, context, request) ==
                         expected_rows
            end
          end
        end

        case scheme do
          :store ->
            assert Fit.receipt_count_a(ctx.store, context.tenant) == 1
            assert {:ok, outbox} = Outbox.pending(ctx.store, Fit.stream(context.tenant), 10)
            assert length(outbox) == 1
            {:ok, _model, head} = Fit.state_a(ctx.store, context.tenant)
            assert head.revision == 2

          :sql ->
            counts = Fit.counts_b(TestRepo, ctx.prefix, context)
            assert counts.receipts == 1
            assert counts.outbox == 1
            assert counts.bindings + counts.messages == 1
        end
      end
    end
  end

  test "authorization and resource revision precede duplicate message checks", ctx do
    [first_context, second_context] = @contexts
    denied_context = %{first_context | operation_id: "operation-two"}
    stale_context = %{second_context | operation_id: "operation-one"}
    first = Fit.fixture_request(first_context, :conversation_message, 0)
    second = Fit.fixture_request(second_context, :conversation_message, 0)
    denied_duplicate = Map.put(first, :expected_revision, 0)
    stale_duplicate = Map.put(second, :expected_revision, 0)

    for scheme <- [:store, :sql] do
      apply = fn request_context, request, verdict ->
        if scheme == :store,
          do: Fit.execute_a(ctx.store, request_context, request, verdict),
          else: Fit.execute_b(TestRepo, ctx.prefix, request_context, request, verdict)
      end

      assert {:applied, :conversation_message, 1} = apply.(first_context, first, :allow)
      assert {:applied, :conversation_message, 1} = apply.(second_context, second, :allow)

      assert {:denied, {:rule, "fit-rule"}} =
               apply.(denied_context, denied_duplicate, :deny)

      assert {:conflict, :stale_revision} =
               apply.(stale_context, stale_duplicate, :allow)

      case scheme do
        :store ->
          assert Fit.lookup_a(ctx.store, denied_context, Fit.identity(denied_context)) ==
                   {:denied, {:rule, "fit-rule"}}

          assert Fit.lookup_a(ctx.store, stale_context, Fit.identity(stale_context)) ==
                   {:conflict, :stale_revision}

          for {request_context, request} <-
                [{first_context, first}, {second_context, second}] do
            assert {:ok, state, _head} = Fit.resource_a(ctx.store, request_context, request)
            assert state.revision == 1
            assert state.messages == %{request.message_id => request.message_bytes}
            assert Fit.receipt_count_a(ctx.store, request_context.tenant) == 2

            assert {:ok, outbox} =
                     Outbox.pending(ctx.store, Fit.stream(request_context.tenant), 10)

            assert length(outbox) == 1
          end

        :sql ->
          assert Fit.lookup_b(TestRepo, ctx.prefix, denied_context, Fit.identity(denied_context)) ==
                   {:denied, {:rule, "fit-rule"}}

          assert Fit.lookup_b(TestRepo, ctx.prefix, stale_context, Fit.identity(stale_context)) ==
                   {:conflict, :stale_revision}

          for {request_context, request} <-
                [{first_context, first}, {second_context, second}] do
            assert Fit.resource_b(TestRepo, ctx.prefix, request_context, request) == [[1]]

            assert Fit.message_rows_b(TestRepo, ctx.prefix, request_context, request) ==
                     [{request.message_id, request.message_bytes}]

            counts = Fit.counts_b(TestRepo, ctx.prefix, request_context)
            assert counts.receipts == 2
            assert counts.outbox == 1
            assert counts.messages == 1
          end
      end
    end
  end

  test "concurrent equal requests return one retained result for both callers and schemes", ctx do
    [context | _] = @contexts
    owner = self()

    for {scheme, kind, op} <- [
          {:store, :trigger_binding, "operation-one"},
          {:store, :conversation_message, "operation-two"},
          {:sql, :trigger_binding, "operation-one"},
          {:sql, :conversation_message, "operation-two"}
        ] do
      context = %{context | operation_id: op}
      request = Fit.fixture_request(context, kind, 0)
      refs = {make_ref(), make_ref()}

      tasks =
        Enum.map(Tuple.to_list(refs), fn ref ->
          Task.async(fn ->
            if scheme == :store do
              Process.put({Fit, :a_gate}, {owner, ref})
              Fit.execute_a(ctx.store, context, request, :allow)
            else
              Process.put({Fit, :b_gate}, {owner, ref})
              if ref == elem(refs, 0), do: Process.put({Fit, :b_pause}, {owner, ref})
              if ref == elem(refs, 1), do: Process.put({Fit, :b_reserving}, {owner, ref})
              Fit.execute_b(TestRepo, ctx.prefix, context, request, :allow)
            end
          end)
        end)

      if scheme == :store do
        ready = Enum.map(Tuple.to_list(refs), fn ref -> receive_ready(:a_ready, ref) end)
        Enum.each(ready, fn {ref, pid} -> send(pid, {:a_go, ref}) end)
      else
        [first_ref, second_ref] = Tuple.to_list(refs)

        [{^first_ref, first_worker_pid}, {^second_ref, second_worker_pid}] =
          Enum.map([first_ref, second_ref], &receive_ready(:b_ready, &1))

        send(first_worker_pid, {:b_go, first_ref})
        assert_receive {:b_paused, ^first_ref, _backend_pid, first_task_pid}, 10_000
        send(second_worker_pid, {:b_go, second_ref})
        assert_receive {:b_reserving, ^second_ref, second_backend_pid}, 10_000

        try do
          Fit.wait_for_db_lock(
            TestRepo,
            second_backend_pid,
            System.monotonic_time(:millisecond) + 5_000
          )
        after
          send(first_task_pid, {:b_continue, first_ref})
        end
      end

      results = Enum.map(tasks, &Task.await(&1, 15_000))
      assert Enum.uniq(results) == [{:applied, kind, 1}]

      if scheme == :store do
        expected_count = if kind == :trigger_binding, do: 1, else: 2
        {:ok, resource, head} = Fit.resource_a(ctx.store, context, request)
        assert resource.revision == 1
        assert head.revision == expected_count * 2
        assert Fit.receipt_count_a(ctx.store, context.tenant) == expected_count
      else
        expected_count = if kind == :trigger_binding, do: 1, else: 2
        counts = Fit.counts_b(TestRepo, ctx.prefix, context)
        assert counts.receipts == expected_count
        assert counts.outbox == expected_count
        assert counts.bindings + counts.messages == expected_count
      end
    end
  end

  test "different operation identities use resource CAS without lost updates", ctx do
    owner = self()

    for {scheme, kind} <-
          for(
            scheme <- [:store, :sql],
            kind <- [:trigger_binding, :conversation_message],
            do: {scheme, kind}
          ) do
      base_context =
        if kind == :trigger_binding, do: Enum.at(@contexts, 0), else: Enum.at(@contexts, 1)

      first_context = %{base_context | operation_id: "operation-one"}
      second_context = %{base_context | operation_id: "operation-two"}
      first_request = Fit.fixture_request(first_context, kind, 0)
      second_request = Map.put(Fit.fixture_request(second_context, kind, 0), :expected_revision, 0)
      refs = {make_ref(), make_ref()}

      tasks =
        [
          {first_context, first_request, elem(refs, 0)},
          {second_context, second_request, elem(refs, 1)}
        ]
        |> Enum.map(fn {request_context, request, ref} ->
          Task.async(fn ->
            if scheme == :store do
              Process.put({Fit, :a_gate}, {owner, ref})
              Fit.execute_a(ctx.store, request_context, request, :allow)
            else
              Process.put({Fit, :b_gate}, {owner, ref})
              Fit.execute_b(TestRepo, ctx.prefix, request_context, request, :allow)
            end
          end)
        end)

      if scheme == :store do
        ready = Enum.map(Tuple.to_list(refs), fn ref -> receive_ready(:a_ready, ref) end)
        Enum.each(ready, fn {ref, pid} -> send(pid, {:a_go, ref}) end)
      else
        ready = Enum.map(Tuple.to_list(refs), fn ref -> receive_ready(:b_ready, ref) end)
        Enum.each(ready, fn {ref, pid} -> send(pid, {:b_go, ref}) end)
      end

      results = Enum.map(tasks, &Task.await(&1, 15_000))
      assert Enum.count(results, &match?({:applied, _, 1}, &1)) == 1
      assert Enum.count(results, &(&1 == {:conflict, :stale_revision})) == 1

      if scheme == :store do
        {:ok, resource, _head} = Fit.resource_a(ctx.store, first_context, first_request)
        assert resource.revision == 1
        assert Fit.receipt_count_a(ctx.store, first_context.tenant) == 2
      else
        counts = Fit.counts_b(TestRepo, ctx.prefix, first_context)
        assert counts.receipts == 2
        assert counts.outbox == 1
        assert counts.bindings + counts.messages == 1
      end
    end
  end

  test "lost replies recover from retained results and unresolved commits remain unknown", ctx do
    [context | _] = @contexts
    request = Fit.fixture_request(context, :trigger_binding, 0)
    PostgresHarness.hook(ctx.store, :inject, [:append, :reply_loss])
    assert {:applied, :trigger_binding, 1} = Fit.execute_a(ctx.store, context, request, :allow)
    assert {:applied, :trigger_binding, 1} = Fit.lookup_a(ctx.store, context, Fit.identity(context))

    token = make_ref()
    paused_context = %{context | operation_id: "operation-two"}
    paused_request = Fit.fixture_request(paused_context, :trigger_binding, 1)
    PostgresHarness.hook(ctx.store, :inject, [:append, {:pause, token, :before_commit}])

    assert {:unknown, :unresolved} =
             Fit.execute_a(ctx.store, paused_context, paused_request, :allow)

    %{backend: backend} = PostgresHarness.paused(ctx.controller, token)

    assert [["idle in transaction"]] =
             SQL.query!(TestRepo, "SELECT state FROM pg_stat_activity WHERE pid=$1", [backend],
               log: false
             ).rows

    assert :not_found == Fit.lookup_a(ctx.store, paused_context, Fit.identity(paused_context))
    assert {:committed, _} = PostgresHarness.hook(ctx.store, :release, [token])

    assert {:applied, :trigger_binding, 1} =
             Fit.lookup_a(ctx.store, paused_context, Fit.identity(paused_context))

    Process.put({Fit, :drop_b_reply}, true)

    assert {:unknown, :lost_response} =
             Fit.execute_b(TestRepo, ctx.prefix, context, request, :allow)

    Process.delete({Fit, :drop_b_reply})

    assert {:applied, :trigger_binding, 1} =
             Fit.resolve_b(TestRepo, ctx.prefix, context, Fit.identity(context))

    unresolved_context = %{context | operation_id: "operation-two"}
    unresolved_request = Fit.fixture_request(unresolved_context, :conversation_message, 1)
    ref = make_ref()

    owner = self()

    task =
      Task.async(fn ->
        Process.put({Fit, :b_pause}, {owner, ref})
        Fit.execute_b(TestRepo, ctx.prefix, unresolved_context, unresolved_request, :allow)
      end)

    assert_receive {:b_paused, ^ref, _backend_pid, worker_pid}, 10_000
    assert worker_pid == task.pid

    try do
      assert :not_found ==
               Fit.lookup_b(
                 TestRepo,
                 ctx.prefix,
                 unresolved_context,
                 Fit.identity(unresolved_context)
               )

      assert {:unknown, :unresolved} ==
               Fit.resolve_b(
                 TestRepo,
                 ctx.prefix,
                 unresolved_context,
                 Fit.identity(unresolved_context)
               )
    after
      send(task.pid, {:b_continue, ref})
    end

    assert {:applied, :conversation_message, 1} = Task.await(task, 15_000)

    assert {:applied, :conversation_message, 1} =
             Fit.lookup_b(
               TestRepo,
               ctx.prefix,
               unresolved_context,
               Fit.identity(unresolved_context)
             )
  end

  test "A lost responses recover retained results for both caller kinds", ctx do
    for {context, kind} <- Enum.zip(@contexts, [:trigger_binding, :conversation_message]) do
      request = Fit.fixture_request(context, kind, 0)
      PostgresHarness.hook(ctx.store, :inject, [:append, :reply_loss])

      assert Fit.execute_a(ctx.store, context, request, :allow) ==
               {:applied, kind, 1}

      assert Fit.lookup_a(ctx.store, context, Fit.identity(context)) == {:applied, kind, 1}
      assert resource_revision(:store, ctx, context, request) == 1
      assert Fit.receipt_count_a(ctx.store, context.tenant) == 1
      assert {:ok, outbox} = Outbox.pending(ctx.store, Fit.stream(context.tenant), 10)
      assert length(outbox) == 1
    end
  end

  test "A paused precommit readback remains unresolved for both caller kinds", ctx do
    for {context, kind} <- Enum.zip(@contexts, [:trigger_binding, :conversation_message]) do
      request = Fit.fixture_request(context, kind, 0)
      token = make_ref()
      PostgresHarness.hook(ctx.store, :inject, [:append, {:pause, token, :before_commit}])

      assert {:unknown, :unresolved} = Fit.execute_a(ctx.store, context, request, :allow)
      %{backend: backend} = PostgresHarness.paused(ctx.controller, token)

      assert [["idle in transaction"]] ==
               SQL.query!(TestRepo, "SELECT state FROM pg_stat_activity WHERE pid=$1", [backend],
                 log: false
               ).rows

      assert Fit.lookup_a(ctx.store, context, Fit.identity(context)) == :not_found
      assert {:committed, _} = PostgresHarness.hook(ctx.store, :release, [token])
      assert Fit.lookup_a(ctx.store, context, Fit.identity(context)) == {:applied, kind, 1}
      assert resource_revision(:store, ctx, context, request) == 1
      assert Fit.receipt_count_a(ctx.store, context.tenant) == 1
      assert {:ok, outbox} = Outbox.pending(ctx.store, Fit.stream(context.tenant), 10)
      assert length(outbox) == 1
    end
  end

  test "B lost responses resolve from retained receipt readback for both caller kinds", ctx do
    for {context, kind} <- Enum.zip(@contexts, [:trigger_binding, :conversation_message]) do
      request = Fit.fixture_request(context, kind, 0)
      Process.put({Fit, :drop_b_reply}, true)

      assert {:unknown, :lost_response} =
               Fit.execute_b(TestRepo, ctx.prefix, context, request, :allow)

      Process.delete({Fit, :drop_b_reply})

      assert Fit.resolve_b(TestRepo, ctx.prefix, context, Fit.identity(context)) ==
               {:applied, kind, 1}

      assert resource_revision(:sql, ctx, context, request) == 1
      counts = Fit.counts_b(TestRepo, ctx.prefix, context)
      assert counts.receipts == 1
      assert counts.outbox == 1
      assert counts.bindings + counts.messages == 1
    end
  end

  test "B paused readback stays unknown until commit for both caller kinds", ctx do
    owner = self()

    for {context, kind} <- Enum.zip(@contexts, [:trigger_binding, :conversation_message]) do
      request = Fit.fixture_request(context, kind, 0)
      ref = make_ref()

      task =
        Task.async(fn ->
          Process.put({Fit, :b_pause}, {owner, ref})
          Fit.execute_b(TestRepo, ctx.prefix, context, request, :allow)
        end)

      assert_receive {:b_paused, ^ref, _backend_pid, worker_pid}, 10_000
      assert worker_pid == task.pid
      assert Fit.lookup_b(TestRepo, ctx.prefix, context, Fit.identity(context)) == :not_found

      assert Fit.resolve_b(TestRepo, ctx.prefix, context, Fit.identity(context)) ==
               {:unknown, :unresolved}

      send(task.pid, {:b_continue, ref})
      assert Task.await(task, 15_000) == {:applied, kind, 1}

      assert Fit.resolve_b(TestRepo, ctx.prefix, context, Fit.identity(context)) ==
               {:applied, kind, 1}

      assert resource_revision(:sql, ctx, context, request) == 1
      counts = Fit.counts_b(TestRepo, ctx.prefix, context)
      assert counts.receipts == 1
      assert counts.outbox == 1
      assert counts.bindings + counts.messages == 1
    end
  end

  test "B absent readback after caller death stays unknown for both caller kinds", ctx do
    owner = self()

    for {context, kind} <- Enum.zip(@contexts, [:trigger_binding, :conversation_message]) do
      request = Fit.fixture_request(context, kind, 0)
      ref = make_ref()

      task =
        Task.async(fn ->
          Process.put({Fit, :b_pause}, {owner, ref})
          Fit.execute_b(TestRepo, ctx.prefix, context, request, :allow)
        end)

      assert_receive {:b_paused, ^ref, _backend_pid, worker_pid}, 10_000
      assert worker_pid == task.pid

      assert Fit.resolve_b(TestRepo, ctx.prefix, context, Fit.identity(context)) ==
               {:unknown, :unresolved}

      Task.shutdown(task, :brutal_kill)
      refute Process.alive?(task.pid)

      assert Fit.lookup_b(TestRepo, ctx.prefix, context, Fit.identity(context)) == :not_found

      assert Fit.resolve_b(TestRepo, ctx.prefix, context, Fit.identity(context)) ==
               {:unknown, :unresolved}

      assert resource_revision(:sql, ctx, context, request) == 0
      counts = Fit.counts_b(TestRepo, ctx.prefix, context)
      assert counts.receipts == 0
      assert counts.outbox == 0
      assert counts.bindings + counts.messages == 0
    end
  end

  test "rollback leaves neither mutation nor result for both atomic participants", ctx do
    [context | _] = @contexts
    request = Fit.fixture_request(context, :conversation_message, 0)

    PostgresHarness.hook(ctx.store, :inject, [:append, :rollback])
    assert {:unknown, :unresolved} = Fit.execute_a(ctx.store, context, request, :allow)
    {:ok, state, _head} = Fit.resource_a(ctx.store, context, request)
    assert state.revision == 0
    assert :not_found == Fit.lookup_a(ctx.store, context, Fit.identity(context))
    assert {:ok, []} = Outbox.pending(ctx.store, Fit.stream(context.tenant), 10)

    assert {:unknown, :transaction} =
             Fit.execute_b(TestRepo, ctx.prefix, context, request, :allow,
               rollback_after_mutation: true
             )

    assert [[0]] = Fit.resource_b(TestRepo, ctx.prefix, context, request)
    assert :not_found == Fit.lookup_b(TestRepo, ctx.prefix, context, Fit.identity(context))
    counts = Fit.counts_b(TestRepo, ctx.prefix, context)
    assert counts.receipts == 0
    assert counts.messages == 0
    assert counts.outbox == 0
  end

  test "rollback leaves no participants for either caller kind or scheme", ctx do
    for {context, kind} <- Enum.zip(@contexts, [:trigger_binding, :conversation_message]) do
      request = Fit.fixture_request(context, kind, 0)
      PostgresHarness.hook(ctx.store, :inject, [:append, :rollback])

      assert Fit.execute_a(ctx.store, context, request, :allow) == {:unknown, :unresolved}
      assert resource_revision(:store, ctx, context, request) == 0
      assert Fit.lookup_a(ctx.store, context, Fit.identity(context)) == :not_found
      assert Fit.receipt_count_a(ctx.store, context.tenant) == 0
      assert {:ok, []} = Outbox.pending(ctx.store, Fit.stream(context.tenant), 10)

      assert Fit.execute_b(TestRepo, ctx.prefix, context, request, :allow,
               rollback_after_mutation: true
             ) == {:unknown, :transaction}

      assert resource_revision(:sql, ctx, context, request) == 0
      assert Fit.lookup_b(TestRepo, ctx.prefix, context, Fit.identity(context)) == :not_found
      counts = Fit.counts_b(TestRepo, ctx.prefix, context)
      assert counts.receipts == 0
      assert counts.outbox == 0
      assert counts.bindings + counts.messages == 0
    end
  end

  test "participant observations are all absent or atomically retained after failure", ctx do
    [context | _] = @contexts
    request = Fit.fixture_request(context, :conversation_message, 0)

    PostgresHarness.hook(ctx.store, :inject, [:append, :reply_loss])
    _a_reply = Fit.execute_a(ctx.store, context, request, :allow)
    {:ok, a_resource, _a_head} = Fit.resource_a(ctx.store, context, request)
    a_receipt = Fit.lookup_a(ctx.store, context, Fit.identity(context))
    {:ok, a_items} = Outbox.pending(ctx.store, Fit.stream(context.tenant), 10)

    assert (a_resource.revision == 0 and a_receipt == :not_found and a_items == []) or
             (a_resource.revision == 1 and
                a_receipt == {:applied, :conversation_message, 1} and length(a_items) == 1),
           "A exposed an orphan mutation, result or outbox item"

    _b_reply =
      Fit.execute_b(TestRepo, ctx.prefix, context, request, :allow, rollback_after_mutation: true)

    [[b_revision]] = Fit.resource_b(TestRepo, ctx.prefix, context, request)
    b_receipt = Fit.lookup_b(TestRepo, ctx.prefix, context, Fit.identity(context))
    b_counts = Fit.counts_b(TestRepo, ctx.prefix, context)

    assert (b_revision == 0 and b_receipt == :not_found and b_counts.messages == 0 and
              b_counts.outbox == 0 and b_counts.receipts == 0) or
             (b_revision == 1 and
                b_receipt == {:applied, :conversation_message, 1} and
                b_counts.messages == 1 and b_counts.outbox == 1 and b_counts.receipts == 1),
           "B exposed an orphan mutation, result or outbox item"
  end

  test "failure readback observes all atomic participants for both caller kinds", ctx do
    for {context, kind} <- Enum.zip(@contexts, [:trigger_binding, :conversation_message]) do
      request = Fit.fixture_request(context, kind, 0)

      PostgresHarness.hook(ctx.store, :inject, [:append, :reply_loss])
      _a_reply = Fit.execute_a(ctx.store, context, request, :allow)
      a_revision = resource_revision(:store, ctx, context, request)
      a_receipt = Fit.lookup_a(ctx.store, context, Fit.identity(context))
      {:ok, a_outbox} = Outbox.pending(ctx.store, Fit.stream(context.tenant), 10)

      assert (a_revision == 0 and a_receipt == :not_found and a_outbox == []) or
               (a_revision == 1 and a_receipt == {:applied, kind, 1} and length(a_outbox) == 1),
             "A exposed an orphan mutation, result or outbox item"

      Process.put({Fit, :drop_b_reply}, true)

      assert {:unknown, :lost_response} =
               Fit.execute_b(TestRepo, ctx.prefix, context, request, :allow)

      Process.delete({Fit, :drop_b_reply})
      b_revision = resource_revision(:sql, ctx, context, request)
      b_receipt = Fit.resolve_b(TestRepo, ctx.prefix, context, Fit.identity(context))
      b_counts = Fit.counts_b(TestRepo, ctx.prefix, context)

      assert b_revision == 1
      assert b_receipt == {:applied, kind, 1}
      assert b_counts.receipts == 1
      assert b_counts.outbox == 1
      assert b_counts.bindings + b_counts.messages == 1
    end
  end

  test "actor and tenant mismatch cannot infer receipts and refusals are bounded and redacted",
       ctx do
    [context, other_context] = @contexts
    request = Fit.fixture_request(context, :trigger_binding, 0)

    for scheme <- [:store, :sql] do
      if scheme == :store do
        assert {:applied, :trigger_binding, 1} = Fit.execute_a(ctx.store, context, request, :allow)
        assert :not_found == Fit.lookup_a(ctx.store, other_context, Fit.identity(context))

        assert :not_found ==
                 Fit.lookup_a(
                   ctx.store,
                   %{context | actor: other_context.actor},
                   Fit.identity(context)
                 )
      else
        assert {:applied, :trigger_binding, 1} =
                 Fit.execute_b(TestRepo, ctx.prefix, context, request, :allow)

        assert :not_found ==
                 Fit.lookup_b(TestRepo, ctx.prefix, other_context, Fit.identity(context))

        assert :not_found ==
                 Fit.lookup_b(
                   TestRepo,
                   ctx.prefix,
                   %{context | actor: other_context.actor},
                   Fit.identity(context)
                 )
      end
    end

    sentinel = String.duplicate("private-input", 20)
    invalid_context = %{context | tenant: sentinel}

    for scheme <- [:store, :sql] do
      refused =
        if scheme == :store,
          do: Fit.execute_a(ctx.store, invalid_context, request, :allow),
          else: Fit.execute_b(TestRepo, ctx.prefix, invalid_context, request, :allow)

      assert refused == {:rejected, :invalid_request}
      assert byte_size(inspect(refused)) < 64
      refute String.contains?(inspect(refused), sentinel)
    end

    oversized_message =
      Map.put(
        Fit.fixture_request(context, :conversation_message, 0),
        :message_bytes,
        :binary.copy(<<65>>, 1_025)
      )

    assert {:rejected, :invalid_request} ==
             Fit.execute_a(ctx.store, context, oversized_message, :allow)

    assert {:rejected, :invalid_request} ==
             Fit.execute_b(TestRepo, ctx.prefix, context, oversized_message, :allow)
  end

  test "actor-only and tenant-only access mismatches redact retained results independently", ctx do
    for {context, other_context, kind} <-
          Enum.zip([@contexts, Enum.reverse(@contexts), [:trigger_binding, :conversation_message]]) do
      request = Fit.fixture_request(context, kind, 0)
      actor_mismatch = %{context | actor: other_context.actor}
      tenant_mismatch = %{context | tenant: other_context.tenant}

      for scheme <- [:store, :sql] do
        assert execute(scheme, ctx, context, request, :allow) == {:applied, kind, 1}
        assert lookup(scheme, ctx, context) == {:applied, kind, 1}
        assert resource_revision(scheme, ctx, context, request) == 1

        case scheme do
          :store ->
            assert Fit.lookup_a(ctx.store, actor_mismatch, Fit.identity(context)) == :not_found
            assert Fit.lookup_a(ctx.store, tenant_mismatch, Fit.identity(context)) == :not_found
            assert Fit.receipt_count_a(ctx.store, context.tenant) == 1
            assert {:ok, outbox} = Outbox.pending(ctx.store, Fit.stream(context.tenant), 10)
            assert length(outbox) == 1

          :sql ->
            assert Fit.lookup_b(TestRepo, ctx.prefix, actor_mismatch, Fit.identity(context)) ==
                     :not_found

            assert Fit.lookup_b(TestRepo, ctx.prefix, tenant_mismatch, Fit.identity(context)) ==
                     :not_found

            assert Fit.resolve_b(TestRepo, ctx.prefix, actor_mismatch, Fit.identity(context)) ==
                     :not_found

            assert Fit.resolve_b(TestRepo, ctx.prefix, tenant_mismatch, Fit.identity(context)) ==
                     :not_found

            counts = Fit.counts_b(TestRepo, ctx.prefix, context)
            assert counts.receipts == 1
            assert counts.outbox == 1
            assert counts.bindings + counts.messages == 1
        end
      end
    end

    [context | _] = @contexts
    request = Fit.fixture_request(context, :trigger_binding, 0)
    sentinel = String.duplicate("private-input", 20)

    for scheme <- [:store, :sql] do
      refused = execute(scheme, ctx, %{context | tenant: sentinel}, request, :allow)
      assert refused == {:rejected, :invalid_request}
      assert byte_size(inspect(refused)) < 64
      refute String.contains?(inspect(refused), sentinel)
    end

    oversized =
      Fit.fixture_request(context, :conversation_message, 0)
      |> Map.put(:message_bytes, :binary.copy(<<65>>, 1_025))

    assert execute(:store, ctx, context, oversized, :allow) == {:rejected, :invalid_request}
    assert execute(:sql, ctx, context, oversized, :allow) == {:rejected, :invalid_request}
  end

  test "receipts remain retained and effects stay pending for both caller kinds", ctx do
    for {context, kind} <- Enum.zip(@contexts, [:trigger_binding, :conversation_message]) do
      request = Fit.fixture_request(context, kind, 0)

      assert execute(:store, ctx, context, request, :allow) == {:applied, kind, 1}
      assert execute(:sql, ctx, context, request, :allow) == {:applied, kind, 1}
      assert lookup(:store, ctx, context) == {:applied, kind, 1}
      assert lookup(:sql, ctx, context) == {:applied, kind, 1}

      assert {:ok, [item]} = Outbox.pending(ctx.store, Fit.stream(context.tenant), 10)
      assert item.state == :pending

      assert resource_revision(:store, ctx, context, request) == 1
      assert resource_revision(:sql, ctx, context, request) == 1
      assert Fit.receipt_count_a(ctx.store, context.tenant) == 1

      counts = Fit.counts_b(TestRepo, ctx.prefix, context)
      assert counts.receipts == 1
      assert counts.outbox == 1
      assert counts.bindings + counts.messages == 1
    end

    [[columns]] =
      SQL.query!(
        TestRepo,
        "SELECT count(*) FROM information_schema.columns WHERE table_schema=$1 " <>
          "AND table_name='command_receipts' AND column_name='expires_at'",
        [String.trim(prefix_name(ctx.prefix), "\"")],
        log: false
      ).rows

    assert columns == 0
  end

  test "no receipt GC is modeled and effects remain pending outbox intents", ctx do
    [context | _] = @contexts
    request = Fit.fixture_request(context, :conversation_message, 0)
    assert {:applied, :conversation_message, 1} = Fit.execute_a(ctx.store, context, request, :allow)

    assert {:applied, :conversation_message, 1} =
             Fit.execute_b(TestRepo, ctx.prefix, context, request, :allow)

    assert {:ok, [item]} = Outbox.pending(ctx.store, Fit.stream(context.tenant), 10)
    assert item.state == :pending

    assert Fit.lookup_a(ctx.store, context, Fit.identity(context)) ==
             {:applied, :conversation_message, 1}

    assert Fit.lookup_b(TestRepo, ctx.prefix, context, Fit.identity(context)) ==
             {:applied, :conversation_message, 1}

    [[columns]] =
      SQL.query!(
        TestRepo,
        "SELECT count(*) FROM information_schema.columns WHERE table_schema=$1 " <>
          "AND table_name='command_receipts' AND column_name='expires_at'",
        [String.trim(prefix_name(ctx.prefix), "\"")],
        log: false
      ).rows

    assert columns == 0
  end

  defp assert_write_participants(
         :store,
         :trigger_binding,
         :allow,
         ctx,
         context,
         %{kind: "trigger_binding"} = request
       ) do
    {:ok, state, _head} = Fit.resource_a(ctx.store, context, request)

    assert MapSet.new(Map.keys(state)) ==
             MapSet.new([:revision, :bot_ref, :package_digest, :callable])

    assert state.bot_ref == request.bot_ref
    assert state.package_digest == request.package_digest
    assert state.callable == request.callable
  end

  defp assert_write_participants(
         :store,
         :trigger_binding,
         _verdict,
         ctx,
         context,
         %{kind: "trigger_binding"} = request
       ) do
    {:ok, state, _head} = Fit.resource_a(ctx.store, context, request)
    assert state == %{revision: 0}
  end

  defp assert_write_participants(
         :store,
         :conversation_message,
         :allow,
         ctx,
         context,
         %{kind: "conversation_message"} = request
       ) do
    {:ok, state, _head} = Fit.resource_a(ctx.store, context, request)
    assert state.messages == %{request.message_id => request.message_bytes}
  end

  defp assert_write_participants(
         :store,
         :conversation_message,
         _verdict,
         ctx,
         context,
         %{kind: "conversation_message"} = request
       ) do
    {:ok, state, _head} = Fit.resource_a(ctx.store, context, request)
    assert state == %{revision: 0}
  end

  defp assert_write_participants(
         :sql,
         :trigger_binding,
         :allow,
         ctx,
         context,
         %{kind: "trigger_binding"} = request
       ) do
    expected = [
      request.expected_revision + 1,
      request.bot_ref,
      request.package_digest,
      request.callable
    ]

    assert [expected] == Fit.resource_b(TestRepo, ctx.prefix, context, request)
  end

  defp assert_write_participants(
         :sql,
         :trigger_binding,
         _verdict,
         ctx,
         context,
         %{kind: "trigger_binding"} = request
       ) do
    assert [[0, "", "", ""]] == Fit.resource_b(TestRepo, ctx.prefix, context, request)
  end

  defp assert_write_participants(
         :sql,
         :conversation_message,
         :allow,
         ctx,
         context,
         %{kind: "conversation_message", message_id: id, message_bytes: bytes} = request
       ) do
    assert [{id, bytes}] == Fit.message_rows_b(TestRepo, ctx.prefix, context, request)
  end

  defp assert_write_participants(
         :sql,
         :conversation_message,
         _verdict,
         ctx,
         context,
         %{kind: "conversation_message"} = request
       ) do
    assert [] == Fit.message_rows_b(TestRepo, ctx.prefix, context, request)
  end

  defp expected_result(:allow, :trigger_binding), do: {:applied, :trigger_binding, 1}
  defp expected_result(:allow, :conversation_message), do: {:applied, :conversation_message, 1}
  defp expected_result(:deny, _kind), do: {:denied, {:rule, "fit-rule"}}

  defp expected_result(:ask, _kind),
    do: {:approval_pending, %{name: "human", version: 1, scope: :once}}

  defp execute(scheme, ctx, context, request, verdict, opts \\ [])

  defp execute(:store, ctx, context, request, verdict, _opts),
    do: Fit.execute_a(ctx.store, context, request, verdict)

  defp execute(:sql, ctx, context, request, verdict, opts),
    do: Fit.execute_b(TestRepo, ctx.prefix, context, request, verdict, opts)

  defp lookup(:store, ctx, context),
    do: Fit.lookup_a(ctx.store, context, Fit.identity(context))

  defp lookup(:sql, ctx, context),
    do: Fit.lookup_b(TestRepo, ctx.prefix, context, Fit.identity(context))

  defp resource_revision(:store, ctx, context, request) do
    {:ok, state, _head} = Fit.resource_a(ctx.store, context, request)
    state.revision
  end

  defp resource_revision(:sql, ctx, context, request) do
    case Fit.resource_b(TestRepo, ctx.prefix, context, request) do
      [[revision]] -> revision
      [[revision, _bot_ref, _digest, _callable]] -> revision
    end
  end

  defp run_identity_race(:store, ctx, context, [first, second]) do
    owner = self()
    refs = [make_ref(), make_ref()]

    tasks =
      Enum.zip([first, second], refs)
      |> Enum.map(fn {request, ref} ->
        Task.async(fn ->
          Process.put({Fit, :a_gate}, {owner, ref})
          Fit.execute_a(ctx.store, context, request, :allow)
        end)
      end)

    ready = Enum.map(refs, &receive_ready(:a_ready, &1))
    Enum.each(ready, fn {ref, pid} -> send(pid, {:a_go, ref}) end)
    Enum.map(tasks, &Task.await(&1, 15_000))
  end

  defp run_identity_race(:sql, ctx, context, [first, second]) do
    owner = self()
    [first_ref, second_ref] = [make_ref(), make_ref()]

    tasks =
      [{first, first_ref}, {second, second_ref}]
      |> Enum.map(fn {request, ref} ->
        Task.async(fn ->
          Process.put({Fit, :b_gate}, {owner, ref})

          if ref == first_ref,
            do: Process.put({Fit, :b_pause}, {owner, ref}),
            else: Process.put({Fit, :b_reserving}, {owner, ref})

          Fit.execute_b(TestRepo, ctx.prefix, context, request, :allow)
        end)
      end)

    [{^first_ref, first_pid}, {^second_ref, second_pid}] =
      Enum.map([first_ref, second_ref], &receive_ready(:b_ready, &1))

    send(first_pid, {:b_go, first_ref})
    assert_receive {:b_paused, ^first_ref, _backend_pid, first_task_pid}, 10_000
    send(second_pid, {:b_go, second_ref})
    assert_receive {:b_reserving, ^second_ref, second_backend_pid}, 10_000

    try do
      Fit.wait_for_db_lock(
        TestRepo,
        second_backend_pid,
        System.monotonic_time(:millisecond) + 5_000
      )
    after
      send(first_task_pid, {:b_continue, first_ref})
    end

    Enum.map(tasks, &Task.await(&1, 15_000))
  end

  defp receive_ready(tag, ref) do
    receive do
      {^tag, ^ref, pid} -> {ref, pid}
    after
      10_000 -> flunk("concurrent command did not reach its database barrier")
    end
  end

  defp prefix_name(prefix), do: String.trim(prefix, "\"")
end
