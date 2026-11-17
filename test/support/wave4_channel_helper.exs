Code.require_file(
  Path.expand("../../pieces/assembly/run-engine/test/support/run_engine_test_helper.exs", __DIR__)
)

Code.require_file(Path.expand("../../examples/support/wave4_channel.ex", __DIR__))

defmodule Elzoo.Wave4ChannelTestHelper do
  alias Ecto.Adapters.SQL
  alias Elzoo.{DurableUnit, DynamicUnits, Lease, RunApprovalRelease}
  alias Elzoo.DurableLog.{Postgres, PostgresHarness, TestMigration}
  alias Elzoo.RunEngine.TestRepo

  @tenant "channel-tenant"
  @actor "channel-actor"
  @source "channel-source"
  @conversation "channel-conversation"
  @signing_key String.duplicate("k", 32)
  @target %{
    "bot_ref" => "channel-bot",
    "package_digest" => String.duplicate("a", 64),
    "callable" => "hash"
  }

  def start_database!, do: Elzoo.RunEngine.TestHelper.database()

  def fixture do
    ensure_registry!(Elzoo.RunEngine.TestRegistry)
    ensure_registry!(Elzoo.RunEngine.UnitRegistry)

    prefix = "wave4_channel_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    SQL.query!(TestRepo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [], log: false)
    :ok = Ecto.Migrator.up(TestRepo, 1, TestMigration, prefix: prefix, log: false)
    {:ok, controller} = PostgresHarness.start_link([])
    Process.unlink(controller)

    command_fold = %{
      initial: %{},
      kinds: %{"checked_command" => :state_bearing},
      versions: [1],
      destinations: ["wave4-channel-input"],
      reduce: fn model, _, _, _ -> model end
    }

    command_limits = %{
      max_record_bytes: 1_048_576,
      max_batch_size: 1,
      max_checkpoint_bytes: 1_048_576
    }

    command_store =
      PostgresHarness.attach(TestRepo, prefix, command_fold, command_limits, controller)

    {:ok, handles} =
      Elzoo.Wave4ChannelExample.CommandBindings.build(command_store, %{
        input: fn _frame, _context -> :allow end,
        association: fn _frame, _context -> :allow end,
        answer: fn _frame, _context -> :allow end
      })

    run_store =
      Postgres.store(TestRepo,
        prefix: prefix,
        fold: RunApprovalRelease.fold(),
        limits: RunApprovalRelease.limits()
      )

    {:ok, lease} = Lease.new(store: run_store, clock: :store)
    {:held, held} = Lease.claim(lease, "runs", "channel-owner", 3_600_000)

    {:ok, owner} =
      RunApprovalRelease.start_link(store: run_store, lease: lease, held: held, effect_intent: %{})

    Process.unlink(owner)

    unit_supervisor =
      ExUnit.Callbacks.start_supervised!(
        {DynamicSupervisor, strategy: :one_for_one, max_children: 4},
        id: make_ref()
      )

    task_supervisor = ExUnit.Callbacks.start_supervised!({Task.Supervisor, []}, id: make_ref())
    now = fn -> System.system_time(:millisecond) end

    unit_opts = [
      operator: {Elzoo.RunEngine, :step, %{version: 1, control: nil, slots: %{}, requests: %{}}},
      retention_count: 1_024,
      max_record_bytes: 16_777_216,
      max_checkpoint_bytes: 33_554_432
    ]

    unit_store =
      PostgresHarness.attach(
        TestRepo,
        prefix,
        DurableUnit.fold(unit_opts),
        DurableUnit.limits(unit_opts),
        controller
      )

    directory =
      ExUnit.Callbacks.start_supervised!(
        {DynamicUnits,
         registry: Elzoo.RunEngine.UnitRegistry,
         supervisor: unit_supervisor,
         idle_ms: 60_000,
         unit_options: fn identity ->
           offer = fn item ->
             case Registry.lookup(Elzoo.RunEngine.TestRegistry, identity) do
               [{pid, _}] -> send(pid, item)
               [] -> :ok
             end

             :ok
           end

           Keyword.merge(unit_opts, store: unit_store, offer: offer)
         end},
        id: make_ref()
      )

    evidence_fold = %{
      initial: nil,
      kinds: %{"completion" => :state_bearing},
      versions: [1],
      destinations: [],
      reduce: fn _, _, _, bytes -> bytes end
    }

    evidence_limits = %{
      max_record_bytes: 131_072,
      max_batch_size: 1,
      max_checkpoint_bytes: 1_048_576
    }

    evidence_store =
      Postgres.store(TestRepo, prefix: prefix, fold: evidence_fold, limits: evidence_limits)

    profile = %{
      tenant: @tenant,
      actor: @actor,
      conversation_id: @conversation,
      source_id: @source,
      deadline_ms: now.() + 120_000,
      native_target: @target
    }

    native = %{
      run_owner: owner,
      held: held,
      lease: lease,
      lease_owner: "channel-owner",
      lease_stream: "runs",
      directory: directory,
      registry: Elzoo.RunEngine.TestRegistry,
      supervisor: unit_supervisor,
      task_supervisor: task_supervisor,
      unit_store: unit_store,
      evidence_store: evidence_store,
      engine: Elzoo.Wave4ChannelExample.NativeBindings.build(profile)
    }

    policy = fn _mode, _event, _now -> policy() end

    authority = fn mode, _event, _request, _facts ->
      if mode == :release,
        do: %{approver: %{identity: "reviewer", authority: []}, now: now.(), revoked: false},
        else: %{}
    end

    {:ok, host} =
      Elzoo.Wave4ChannelExample.start_link(
        profile: profile,
        bindings: [trigger_binding(profile)],
        command_store: command_store,
        handles: handles,
        native: native,
        authority: authority,
        policy: policy,
        clock: now
      )

    Process.unlink(host)

    fixture = %{
      prefix: prefix,
      controller: controller,
      owner: owner,
      held: held,
      lease: lease,
      directory: directory,
      command_store: command_store,
      handles: handles,
      profile: profile,
      native: native,
      host: host,
      clock: now
    }

    ExUnit.Callbacks.on_exit(fn -> cleanup(fixture) end)
    fixture
  end

  def listener!(fixture) do
    ref = Elzoo.Wave4ChannelTest.Listener
    profile = fixture.profile

    webhook = [
      source_id: profile.source_id,
      key: fn -> {:ok, @signing_key} end,
      clock: fn -> System.system_time(:second) end,
      principal: fn _conn -> {:ok, scope(profile)} end,
      admit: fn event, trusted -> Elzoo.Wave4ChannelExample.admit(fixture.host, event, trusted) end
    ]

    router_options = [
      host: fixture.host,
      conversation_id: profile.conversation_id,
      webhook: webhook,
      principal: fn _conn -> {:ok, scope(profile)} end
    ]

    {:ok, pid} =
      Plug.Cowboy.http(Elzoo.Wave4ChannelExample.Router, router_options,
        ref: ref,
        port: 0,
        ip: {127, 0, 0, 1}
      )

    Process.unlink(pid)
    port = :ranch.get_port(ref)
    ExUnit.Callbacks.on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    %{port: port, url: "http://127.0.0.1:#{port}", ref: ref}
  end

  def post(listener, event) do
    body = Jason.encode!(event)
    timestamp = Integer.to_string(System.system_time(:second))
    frame = "elzoo-webhook-v1\n#{@source}\nPOST\n/elzoo/v1/messages\n#{timestamp}\n#{body}"

    signature =
      "v1=" <> Base.encode16(:crypto.mac(:hmac, :sha256, @signing_key, frame), case: :lower)

    {:ok, _} = Application.ensure_all_started(:inets)

    :httpc.request(
      :post,
      {String.to_charlist(listener.url <> "/elzoo/v1/messages"),
       [
         {~c"content-type", ~c"application/json"},
         {~c"x-elzoo-timestamp", String.to_charlist(timestamp)},
         {~c"x-elzoo-signature", String.to_charlist(signature)}
       ], ~c"application/json", body},
      [connect_timeout: 2_000, timeout: 10_000],
      body_format: :binary
    )
  end

  def get(listener, conversation) do
    :httpc.request(
      :get,
      {String.to_charlist(listener.url <> "/elzoo/v1/conversations/" <> conversation), []},
      [connect_timeout: 2_000, timeout: 10_000],
      body_format: :binary
    )
  end

  def event(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "event_id" => "event-1",
        "conversation_id" => @conversation,
        "input_id" => "input-1",
        "expected_revision" => 0,
        "text" => "hello wave4"
      },
      overrides
    )
  end

  def scope(profile),
    do: %{tenant: profile.tenant, actor: profile.actor, resources: [profile.conversation_id]}

  def policy do
    artifact = %{
      id: "channel-policy",
      version: 1,
      effect_classes: ["conversation.write"],
      rules: [%{id: "allow-channel", effect_class: "conversation.write", verdict: :allow}]
    }

    Map.put(
      artifact,
      :content_hash,
      :crypto.hash(:sha256, :erlang.term_to_binary(artifact, [:deterministic]))
    )
  end

  def run_id(profile, event_id, input_id) do
    operation = input_operation(profile, event_id)
    stable_id("run", [profile.tenant, profile.actor, operation, input_id, @target])
  end

  def input_operation(profile, event_id), do: stable_id("input", [profile.source_id, event_id])

  def association_operation(profile, event_id, input_id) do
    operation = input_operation(profile, event_id)
    stable_id("association", [profile.tenant, profile.actor, operation, input_id])
  end

  def answer_operation(profile, event_id, input_id) do
    operation = input_operation(profile, event_id)
    stable_id("answer", [profile.tenant, profile.actor, operation, input_id])
  end

  def answer_id(input_id), do: stable_id("answer-message", [input_id])
  def attempt_id(run_id), do: stable_id("attempt", [run_id])

  def native_operation(profile, run_id),
    do: stable_id("native-operation", [run_id, profile.native_target])

  def unit_id(run_id), do: stable_id("unit", [run_id])

  def cleanup(fixture) do
    for pid <- [fixture.host, fixture.owner], is_pid(pid) and Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    PostgresHarness.cleanup(fixture.controller)
    if Process.alive?(fixture.controller), do: GenServer.stop(fixture.controller)

    SQL.query!(TestRepo, "DROP SCHEMA IF EXISTS #{Postgres.identifier(fixture.prefix)} CASCADE", [],
      log: false
    )
  end

  defp trigger_binding(profile) do
    %{
      "version" => 1,
      "id" => "channel-binding",
      "revision" => 1,
      "tenant" => profile.tenant,
      "source" => profile.source_id,
      "schema_id" => "elzoo.message/v1",
      "schema_version" => 1,
      "enabled" => true,
      "target" => @target
    }
  end

  defp ensure_registry!(name) do
    if is_nil(Process.whereis(name)) do
      ExUnit.Callbacks.start_supervised!({Registry, keys: :unique, name: name}, id: name)
    end
  end

  defp stable_id(domain, terms) do
    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({:wave4_channel, 1, domain, terms}, [:deterministic])
      )

    domain <> ":" <> Base.url_encode64(digest, padding: false)
  end
end
