Code.require_file(
  "../../pieces/assembly/run-engine/test/support/run_engine_test_helper.exs",
  __DIR__
)

Code.require_file(Path.expand("../../examples/support/wave4_channel.ex", __DIR__))

defmodule Elzoo.Wave4.CommandConversationRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.Wave4.CommandConversationHelper do
  alias Ecto.Adapters.SQL
  alias Elzoo.{CheckedCommand, Conversation, PayloadSchema}
  alias Elzoo.DurableLog.{Memory, Postgres, PostgresHarness, TestMigration}
  alias Elzoo.Wave4ChannelExample.Intents

  @resource "conversation-main"
  @tenant "wave4-tenant"
  @actor "wave4-actor"
  @effect "conversation.write"
  @port %{
    "id" => "conversation-command",
    "direction" => "input",
    "schema_id" => "conversation-command/v1",
    "schema_version" => 1
  }
  @limits %{max_record_bytes: 1_048_576, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}

  def resource, do: @resource
  def tenant, do: @tenant
  def actor, do: @actor
  def port, do: @port

  def stream do
    "cc1:" <>
      Base.url_encode64(
        :erlang.term_to_binary({:cc, 1, @tenant}, [:deterministic]),
        padding: false
      )
  end

  def scope do
    %{tenant: @tenant, actor: @actor, resources: [@resource]}
  end

  def reference do
    %{target_tenant: @tenant, conversation_id: @resource}
  end

  def pending_outbox(store), do: Elzoo.Outbox.pending(store, stream(), 64)

  def start_repo! do
    {:ok, pid} =
      Elzoo.Wave4.CommandConversationRepo.start_link(
        url: PostgresHarness.database_url!(),
        pool_size: 12,
        log: false
      )

    Process.unlink(pid)
    :ok = PostgresHarness.reachable!(Elzoo.Wave4.CommandConversationRepo)
    pid
  end

  # The owners of the fixture stores, keyed by the store term itself (the
  # term carries the process identity of the store or controller, so each
  # fixture registers exactly one owner).
  def owners do
    case Process.whereis(__MODULE__.Owners) do
      nil ->
        {:ok, agent} = Agent.start_link(fn -> %{} end, name: __MODULE__.Owners)
        Process.unlink(agent)
        agent

      agent ->
        agent
    end
  end

  def start_owner!(store) do
    {:ok, owner} =
      Conversation.start_link(
        store: store,
        target_tenant: @tenant,
        conversation_id: @resource
      )

    Process.unlink(owner)
    Agent.update(owners(), &Map.put(&1, store, owner))
    owner
  end

  def owner(store) do
    case Agent.get(owners(), &Map.fetch(&1, store)) do
      {:ok, owner} when is_pid(owner) ->
        if Process.alive?(owner), do: owner, else: raise("conversation owner is not alive")

      _ ->
        raise "no conversation owner registered for this fixture store"
    end
  end

  def stop_owner(store) do
    case Agent.get_and_update(owners(), &Map.pop(&1, store)) do
      owner when is_pid(owner) ->
        if Process.alive?(owner), do: GenServer.stop(owner)

      _ ->
        :ok
    end

    :ok
  end

  def pg_fixture do
    prefix = "wave4_cc_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    SQL.query!(
      Elzoo.Wave4.CommandConversationRepo,
      "CREATE SCHEMA #{Postgres.identifier(prefix)}",
      [],
      log: false
    )

    :ok =
      Ecto.Migrator.up(Elzoo.Wave4.CommandConversationRepo, 1, TestMigration,
        prefix: prefix,
        log: false
      )

    {:ok, controller} = PostgresHarness.start_link([])
    Process.unlink(controller)

    store =
      PostgresHarness.attach(
        Elzoo.Wave4.CommandConversationRepo,
        prefix,
        fold(),
        @limits,
        controller
      )

    owner = start_owner!(store)
    %{store: store, controller: controller, prefix: prefix, owner: owner}
  end

  def cleanup_pg!(fixture) do
    stop_owner(fixture.store)
    PostgresHarness.cleanup(fixture.controller)

    SQL.query!(
      Elzoo.Wave4.CommandConversationRepo,
      "DROP SCHEMA IF EXISTS #{Postgres.identifier(fixture.prefix)} CASCADE",
      [],
      log: false
    )

    Agent.stop(fixture.controller)
    :ok
  end

  def memory_fixture do
    {:ok, pid} = Memory.start_link(fold: fold(), limits: @limits, append_visibility: :atomic)
    Process.unlink(pid)
    store = Memory.store(pid, %{fold: fold()})
    owner = start_owner!(store)
    %{store: store, pid: pid, owner: owner}
  end

  def stop_memory(fixture) do
    stop_owner(fixture.store)
    if Process.alive?(fixture.pid), do: GenServer.stop(fixture.pid)
  end

  def fold do
    %{
      initial: %{},
      kinds:
        Map.merge(
          %{"checked_command" => :state_bearing},
          Map.new(Conversation.Record.kinds(), &{&1, :non_state_bearing})
        ),
      versions: [1],
      destinations: ["conversation-notify"],
      reduce: fn model, _sequence, _kind, _payload -> model end
    }
  end

  def schema do
    {:ok, schema} =
      PayloadSchema.build(@port, %{
        "type" => "object",
        "properties" => %{
          "message_id" => %{"type" => "string"},
          "text" => %{"type" => "string"}
        },
        "required" => ["message_id"],
        "additionalProperties" => false
      })

    schema
  end

  def descriptor(opts \\ []) do
    gate = Keyword.get(opts, :gate, fn _frame, _context -> :allow end)

    %{
      id: "wave4/conversation-command",
      version: 1,
      content_hash: :crypto.hash(:sha256, "wave4-conversation-command-v1"),
      effect_class: @effect,
      port: @port,
      schema: schema(),
      prepare: &Intents.prepare/3,
      gate: %{call: gate},
      approval: %{verifiers: ["command-reviewer"], max_age: 3_600_000},
      outbox: "conversation-notify"
    }
    |> Map.merge(Keyword.get(opts, :descriptor, %{}))
  end

  def handle(store, opts \\ []) do
    {:ok, handle} = CheckedCommand.new(store, descriptor(opts))
    handle
  end

  def facts(mode, fields \\ %{}) do
    data = Map.merge(%{"mode" => {:text, mode}}, fields)
    {:record, Enum.sort_by(data, &elem(&1, 0))}
  end

  def request(operation_id, revision, message_id, text \\ nil) do
    payload =
      if is_nil(text),
        do: %{"message_id" => message_id},
        else: %{"message_id" => message_id, "text" => text}

    %{
      operation_id: operation_id,
      resource: @resource,
      expected_revision: revision,
      payload: payload
    }
  end

  def context(request, facts, snapshot, opts \\ []) do
    %{tenant: @tenant, actor: @actor, data: facts}
    |> then(fn prepare_facts ->
      writes =
        case Intents.prepare(snapshot, request, prepare_facts) do
          {:ok, writes, _} -> writes
          _ -> []
        end

      %{
        tenant: @tenant,
        actor: @actor,
        policy: policy(Keyword.get(opts, :verdict, :allow)),
        own: writes,
        parent: Keyword.get(opts, :parent, :none),
        facts: facts
      }
    end)
  end

  def policy(verdict \\ :allow) do
    rule =
      if verdict == :ask do
        %{
          id: "command-review",
          effect_class: @effect,
          verdict: :ask,
          requirement: %{name: "command-review", version: 1, scope: :once}
        }
      else
        %{id: "conversation-policy", effect_class: @effect, verdict: verdict}
      end

    artifact = %{
      id: "wave4-policy",
      version: 1,
      effect_classes: [@effect],
      rules: [rule]
    }

    Map.put(
      artifact,
      :content_hash,
      :crypto.hash(:sha256, :erlang.term_to_binary(artifact, [:deterministic]))
    )
  end

  def read(handle) do
    {:ok, snapshot} = CheckedCommand.resource(handle, scope(), @resource)
    snapshot
  end

  # The delivered conversation as version 1 exposed it: inputs and answers in
  # stream order as `messages` (answers with role "assistant"), associations
  # in stream order, and the conversation stream revision.
  def view(handle) do
    case Conversation.page(handle.store, scope(), reference(), 1, 1_000) do
      {:ok, page} ->
        messages =
          Enum.flat_map(page.entries, fn entry ->
            case entry.kind do
              :input ->
                [
                  %{
                    actor: entry.actor,
                    message_id: entry.message_id,
                    role: entry.role,
                    text: entry.text
                  }
                ]

              :answer ->
                [
                  %{
                    actor: entry.actor,
                    input_message_id: entry.input_message_id,
                    message_id: entry.message_id,
                    role: "assistant",
                    run_id: entry.run_id,
                    text: entry.text
                  }
                ]

              :association ->
                []
            end
          end)

        associations =
          for entry <- page.entries, entry.kind == :association do
            %{input_message_id: entry.input_message_id, run_id: entry.run_id}
          end

        %{
          tenant: @tenant,
          resource: @resource,
          revision: page.revision,
          messages: messages,
          associations: associations
        }

      other ->
        raise "conversation page failed: #{inspect(other)}"
    end
  end

  # One command through the host admission contract: an identity that is
  # already recorded returns its retained result without validation; a fresh
  # operation is checked against the ordered admitted state (the delivered
  # conversation plus every committed command whose delivery is still
  # pending) before the execution starts. An admission refusal is the
  # command's conflict outcome with nothing committed.
  def execute(handle, request, facts, opts \\ []) do
    snapshot = read(handle)
    context = context(request, facts, snapshot, opts)

    case CheckedCommand.result(
           handle,
           %{tenant: @tenant, actor: @actor},
           {@tenant, @actor, request.operation_id}
         ) do
      {:unknown, :not_observed} ->
        case admission(handle, request, facts) do
          :ok -> CheckedCommand.execute(handle, context, request)
          {:error, {:conflict, code}} -> {:conflict, {:domain, code}}
          {:error, _} -> {:error, :unavailable}
        end

      _ ->
        CheckedCommand.execute(handle, context, request)
    end
  end

  def admission(handle, request, facts) do
    with {:ok, mode, dto} <-
           Intents.candidate(request, %{tenant: @tenant, actor: @actor, data: facts}),
         {:ok, earlier} <- undelivered_intents(handle),
         {:ok, decisions} <-
           Conversation.check(owner(handle.store), earlier ++ [{mode, dto}]) do
      {prior, [candidate]} = Enum.split(decisions, -1)

      if Enum.all?(prior, &(&1 in [:ok, {:ok, :already_present}])) do
        case candidate do
          :ok -> :ok
          {:ok, :already_present} -> {:error, {:conflict, "already_present"}}
          {:refused, code} -> {:error, {:conflict, code}}
          _ -> {:error, :unknown}
        end
      else
        {:error, :unknown}
      end
    else
      :error -> {:error, :invalid}
      _ -> {:error, :unknown}
    end
  rescue
    _ -> {:error, :unknown}
  catch
    _, _ -> {:error, :unknown}
  end

  defp undelivered_intents(handle) do
    case pending_outbox(handle.store) do
      {:ok, items} ->
        items
        |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
          with {:ok, notice} <- Jason.decode(item.payload),
               {:completed, %{response: response}} <-
                 CheckedCommand.result(
                   handle,
                   %{tenant: @tenant, actor: @actor},
                   {@tenant, @actor, notice["operation_id"]}
                 ),
               {:ok, mode, dto} <- Intents.delivery(response) do
            {:cont, {:ok, [{mode, dto} | acc]}}
          else
            _ -> {:halt, {:error, :unavailable}}
          end
        end)
        |> case do
          {:ok, intents} -> {:ok, Enum.reverse(intents)}
          error -> error
        end

      _ ->
        {:error, :unavailable}
    end
  end

  # Deliver every pending item in sequence order: the committed intent of
  # each completed command is appended through the conversation owner and the
  # item is acknowledged with its original key and nonce. Anything unexpected
  # is a harness failure, not a tolerated outcome.
  def deliver!(handle) do
    {:ok, items} = pending_outbox(handle.store)

    Enum.each(items, fn item ->
      notice = Jason.decode!(item.payload)

      completed =
        CheckedCommand.result(
          handle,
          %{tenant: @tenant, actor: @actor},
          {@tenant, @actor, notice["operation_id"]}
        )

      with {:completed, %{response: response}} <- completed,
           {:ok, mode, dto} <- Intents.delivery(response) do
        appended =
          case mode do
            :input -> Conversation.append_input(owner(handle.store), dto)
            :association -> Conversation.associate_run(owner(handle.store), dto)
            :answer -> Conversation.append_answer(owner(handle.store), dto)
          end

        case appended do
          {:ok, %{sequence: _}} -> :ok
          {:ok, :already_present} -> :ok
          other -> raise "delivery refused: #{inspect(other)}"
        end

        case Elzoo.Outbox.ack(handle.store, item.idempotency_key, item.nonce) do
          {:committed, _} -> :ok
          other -> raise "delivery acknowledgement failed: #{inspect(other)}"
        end
      else
        other -> raise "undeliverable pending item: #{inspect(other)}"
      end
    end)

    :ok
  end

  def snapshot(fixture), do: PostgresHarness.hook(fixture.store, :snapshot, [])

  def counts(fixture) do
    snapshot = snapshot(fixture)
    %{records: length(snapshot.elzoo_log_records), outbox: length(snapshot.elzoo_outbox)}
  end

  def append_input(handle, revision, operation, message, text, opts \\ []) do
    facts = facts("append_input", %{"input_role" => {:text, "user"}})
    request = request(operation, revision, message, text)
    {execute(handle, request, facts, opts), request, facts}
  end

  def associate(handle, revision, operation, message, run_id, opts \\ []) do
    facts = facts("associate_run", %{"run_id" => {:text, run_id}})
    request = request(operation, revision, message)
    {execute(handle, request, facts, opts), request, facts}
  end

  def answer(
        handle,
        revision,
        operation,
        answer_id,
        input_id,
        run_id,
        text,
        completed \\ true,
        opts \\ []
      ) do
    facts =
      facts("append_answer", %{
        "run_id" => {:text, run_id},
        "input_message_id" => {:text, input_id},
        "completed" => completed
      })

    request = request(operation, revision, answer_id, text)
    {execute(handle, request, facts, opts), request, facts}
  end

  def observe_work(observer, payload) do
    send(observer, {:local_work, self(), payload})

    receive do
      :finish_work -> payload
    after
      5_000 -> raise "local work observer timed out"
    end
  end
end
