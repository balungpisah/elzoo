Code.require_file(
  "../../pieces/assembly/run-engine/test/support/run_engine_test_helper.exs",
  __DIR__
)

defmodule Elzoo.Wave4.CommandConversationRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.Wave4.CommandConversationHelper do
  alias Ecto.Adapters.SQL
  alias Elzoo.{CheckedCommand, Conversation, PayloadSchema}
  alias Elzoo.DurableLog.{Memory, Postgres, PostgresHarness, TestMigration}

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

    %{store: store, controller: controller, prefix: prefix}
  end

  def cleanup_pg!(fixture) do
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
    %{store: Memory.store(pid, %{fold: fold()}), pid: pid}
  end

  def stop_memory(fixture) do
    if Process.alive?(fixture.pid), do: GenServer.stop(fixture.pid)
  end

  def fold do
    %{
      initial: %{},
      kinds: %{"checked_command" => :state_bearing},
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
      prepare: &Conversation.prepare/3,
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
        case Conversation.prepare(snapshot, request, prepare_facts) do
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
    scope = %{tenant: @tenant, actor: @actor, resources: [@resource]}
    {:ok, snapshot} = CheckedCommand.resource(handle, scope, @resource)
    snapshot
  end

  def view(handle) do
    snapshot = read(handle)

    {:ok, view} =
      Conversation.view(snapshot, %{tenant: @tenant, actor: @actor, resources: [@resource]})

    view
  end

  def execute(handle, request, facts, opts \\ []) do
    snapshot = read(handle)
    context = context(request, facts, snapshot, opts)
    CheckedCommand.execute(handle, context, request)
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
