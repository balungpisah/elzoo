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

  def start_database!, do: Elzoo.RunEngine.TestHelper.database()

  def fixture(options \\ []) do
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

    gates =
      Keyword.get(options, :gates, %{
        input: fn _frame, _context -> :allow end,
        association: fn _frame, _context -> :allow end,
        answer: fn _frame, _context -> :allow end
      })

    {:ok, handles} = Elzoo.Wave4ChannelExample.CommandBindings.build(command_store, gates)

    run_store =
      PostgresHarness.attach(
        TestRepo,
        prefix,
        RunApprovalRelease.fold(),
        RunApprovalRelease.limits(),
        controller
      )

    {:ok, lease} = Lease.new(store: run_store, clock: :store)
    {:held, held} = Lease.claim(lease, "runs", "channel-owner", 3_600_000)

    {:ok, owner} =
      RunApprovalRelease.start_link(store: run_store, lease: lease, held: held, effect_intent: %{})

    Process.unlink(owner)

    unit_supervisor_id = make_ref()

    unit_supervisor =
      ExUnit.Callbacks.start_supervised!(
        {DynamicSupervisor, strategy: :one_for_one, max_children: 4},
        id: unit_supervisor_id
      )

    task_supervisor_id = make_ref()

    task_supervisor =
      ExUnit.Callbacks.start_supervised!({Task.Supervisor, []}, id: task_supervisor_id)

    now = Keyword.get(options, :clock, fn -> System.system_time(:millisecond) end)

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

    directory_id = make_ref()

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
        id: directory_id
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
      PostgresHarness.attach(TestRepo, prefix, evidence_fold, evidence_limits, controller)

    profile =
      Map.merge(
        %{
          tenant: @tenant,
          actor: @actor,
          conversation_id: @conversation,
          source_id: @source,
          deadline_ms: Keyword.get(options, :deadline_ms, now.() + 120_000),
          native_target: Elzoo.Wave4ChannelExample.NativeBindings.target()
        },
        Keyword.get(options, :profile_overrides, %{})
      )

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

    policy = Keyword.get(options, :policy, fn _mode, _event, _now -> policy() end)

    authority =
      Keyword.get(options, :authority, fn mode, _event, _request, _facts ->
        if mode == :release,
          do: %{approver: %{identity: "reviewer", authority: []}, now: now.(), revoked: false},
          else: %{}
      end)

    host_options = [
      profile: profile,
      bindings: Keyword.get(options, :bindings, [trigger_binding(profile)]),
      command_store: command_store,
      handles: handles,
      native: native,
      authority: authority,
      policy: policy,
      clock: now
    ]

    {:ok, host} = Elzoo.Wave4ChannelExample.start_link(host_options)

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
      host_options: host_options,
      gates: gates,
      run_store: run_store,
      unit_supervisor: unit_supervisor,
      unit_supervisor_id: unit_supervisor_id,
      task_supervisor: task_supervisor,
      task_supervisor_id: task_supervisor_id,
      directory_id: directory_id,
      unit_store: unit_store,
      unit_opts: unit_opts,
      evidence_store: evidence_store,
      clock: now
    }

    ExUnit.Callbacks.on_exit(fn -> cleanup(fixture) end)
    fixture
  end

  def listener!(fixture, options \\ []) do
    ref = make_ref()
    profile = fixture.profile
    host = Keyword.get(options, :host, fixture.host)

    webhook_principal =
      Keyword.get(options, :webhook_principal, fn _conn -> {:ok, scope(profile)} end)

    router_principal =
      Keyword.get(options, :principal, fn _conn -> {:ok, scope(profile)} end)

    webhook = [
      source_id: profile.source_id,
      key: Keyword.get(options, :key, fn -> {:ok, @signing_key} end),
      clock: fn -> System.system_time(:second) end,
      principal: webhook_principal,
      admit: fn event, trusted -> Elzoo.Wave4ChannelExample.admit(host, event, trusted) end
    ]

    router_options = [
      host: host,
      conversation_id: profile.conversation_id,
      webhook: webhook,
      principal: router_principal
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

  def post(listener, event, options \\ []) do
    body = Keyword.get(options, :body, Jason.encode!(event))
    timestamp = Keyword.get(options, :timestamp, Integer.to_string(System.system_time(:second)))
    path = Keyword.get(options, :path, "/elzoo/v1/messages")
    method = Keyword.get(options, :method, :post)
    frame = "elzoo-webhook-v1\n#{@source}\nPOST\n/elzoo/v1/messages\n#{timestamp}\n#{body}"

    signature =
      Keyword.get(
        options,
        :signature,
        "v1=" <> Base.encode16(:crypto.mac(:hmac, :sha256, @signing_key, frame), case: :lower)
      )

    headers = [
      {"content-type", "application/json"},
      {"x-elzoo-timestamp", timestamp},
      {"x-elzoo-signature", signature}
    ]

    extra_headers = Keyword.get(options, :headers, [])
    extra_names = Enum.map(extra_headers, &elem(&1, 0))
    headers = Enum.reject(headers, fn {name, _} -> name in extra_names end) ++ extra_headers

    {:ok, _} = Application.ensure_all_started(:inets)

    http_request(listener, method, path, headers, body)
  end

  def get(listener, conversation, options \\ []) do
    query = Keyword.get(options, :query, "")
    path = "/elzoo/v1/conversations/#{conversation}" <> if(query == "", do: "", else: "?#{query}")
    http_request(listener, :get, path, Keyword.get(options, :headers, []), "")
  end

  def request(listener, method, path, headers \\ [], body \\ "") do
    http_request(listener, method, path, headers, body)
  end

  def start_host!(fixture, overrides \\ []) do
    {:ok, host} =
      Elzoo.Wave4ChannelExample.start_link(Keyword.merge(fixture.host_options, overrides))

    Process.unlink(host)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(host), do: GenServer.stop(host, :normal, 5_000)
    end)

    host
  end

  def fence_and_reopen!(fixture, listener \\ nil) do
    if listener, do: stop_listener!(listener)

    host_state = :sys.get_state(fixture.host)
    native_pids = [host_state.engine, host_state.async_work, host_state.writer]

    :ok = GenServer.stop(fixture.host, :normal, 5_000)
    true = not Process.alive?(fixture.host)
    true = Enum.all?(native_pids, &(not (is_pid(&1) and Process.alive?(&1))))

    if host_state.current do
      unit_id = unit_id(host_state.current.run_id)
      :not_found = Elzoo.DynamicUnits.find(fixture.directory, unit_id)

      :ok =
        await_engine_unregistered(
          fixture.native.registry,
          unit_id,
          System.monotonic_time(:millisecond) + 5_000
        )
    end

    [] = Task.Supervisor.children(fixture.native.task_supervisor)

    if Process.alive?(fixture.owner) do
      :ok = GenServer.stop(fixture.owner, :normal, 5_000)
    end

    true = not Process.alive?(fixture.owner)
    :ok = ExUnit.Callbacks.stop_supervised!(fixture.directory_id)
    :ok = ExUnit.Callbacks.stop_supervised!(fixture.unit_supervisor_id)
    :ok = ExUnit.Callbacks.stop_supervised!(fixture.task_supervisor_id)
    true = not Process.alive?(fixture.directory)
    true = not Process.alive?(fixture.unit_supervisor)
    true = not Process.alive?(fixture.task_supervisor)

    command_store = Elzoo.DurableLog.PostgresHarness.hook(fixture.command_store, :reopen, [])
    run_store = Elzoo.DurableLog.PostgresHarness.hook(fixture.run_store, :reopen, [])
    unit_store = Elzoo.DurableLog.PostgresHarness.hook(fixture.native.unit_store, :reopen, [])
    evidence_store = Elzoo.DurableLog.PostgresHarness.hook(fixture.evidence_store, :reopen, [])
    {:ok, lease} = Lease.new(store: run_store, clock: :store)
    {:held, held} = Lease.hold(lease, fixture.native.lease_stream, fixture.native.lease_owner)

    {:ok, owner} =
      RunApprovalRelease.start_link(
        store: run_store,
        lease: lease,
        held: held,
        effect_intent: %{}
      )

    Process.unlink(owner)
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)

    unit_supervisor_id = make_ref()

    unit_supervisor =
      ExUnit.Callbacks.start_supervised!(
        {DynamicSupervisor, strategy: :one_for_one, max_children: 4},
        id: unit_supervisor_id
      )

    task_supervisor_id = make_ref()

    task_supervisor =
      ExUnit.Callbacks.start_supervised!({Task.Supervisor, []}, id: task_supervisor_id)

    directory_id = make_ref()

    directory =
      ExUnit.Callbacks.start_supervised!(
        {DynamicUnits,
         registry: Elzoo.RunEngine.UnitRegistry,
         supervisor: unit_supervisor,
         idle_ms: 60_000,
         unit_options: fn identity -> unit_options(fixture.unit_opts, unit_store, identity) end},
        id: directory_id
      )

    {:ok, handles} = Elzoo.Wave4ChannelExample.CommandBindings.build(command_store, fixture.gates)

    native = %{
      fixture.native
      | run_owner: owner,
        held: held,
        lease: lease,
        directory: directory,
        supervisor: unit_supervisor,
        task_supervisor: task_supervisor,
        unit_store: unit_store,
        evidence_store: evidence_store
    }

    fixture = %{
      fixture
      | owner: owner,
        lease: lease,
        directory: directory,
        command_store: command_store,
        run_store: run_store,
        handles: handles,
        native: native,
        unit_supervisor: unit_supervisor,
        unit_supervisor_id: unit_supervisor_id,
        task_supervisor: task_supervisor,
        task_supervisor_id: task_supervisor_id,
        directory_id: directory_id,
        unit_store: unit_store,
        evidence_store: evidence_store
    }

    host_options =
      Keyword.merge(fixture.host_options,
        command_store: command_store,
        handles: handles,
        native: native
      )

    fixture = %{fixture | host_options: host_options}
    host = start_host!(fixture)
    {:ok, %{fixture | host: host}}
  end

  def stop_listener!(listener), do: Plug.Cowboy.shutdown(listener.ref)

  def command_stream(tenant) do
    "cc1:" <>
      Base.url_encode64(:erlang.term_to_binary({:cc, 1, tenant}, [:deterministic]), padding: false)
  end

  def command_head(fixture) do
    Elzoo.DurableLog.Store.read(fixture.command_store, :head, [
      command_stream(fixture.profile.tenant)
    ])
  end

  def pending_outbox(fixture) do
    Elzoo.Outbox.pending(fixture.command_store, command_stream(fixture.profile.tenant), 64)
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

  def policy(verdict \\ :allow) do
    rule =
      if verdict == :ask do
        %{
          id: "channel-review",
          effect_class: "conversation.write",
          verdict: :ask,
          requirement: %{name: "channel-review", version: 1, scope: :once}
        }
      else
        %{id: "channel-policy-rule", effect_class: "conversation.write", verdict: verdict}
      end

    artifact = %{
      id: "channel-policy",
      version: 1,
      effect_classes: ["conversation.write"],
      rules: [rule]
    }

    Map.put(
      artifact,
      :content_hash,
      :crypto.hash(:sha256, :erlang.term_to_binary(artifact, [:deterministic]))
    )
  end

  def run_id(profile, event_id, input_id) do
    operation = input_operation(profile, event_id)

    stable_id("run", [
      profile.tenant,
      profile.actor,
      operation,
      input_id,
      Elzoo.Wave4ChannelExample.NativeBindings.target()
    ])
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
  def native_input_id(run_id), do: stable_id("native-input", [run_id])

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
      "target" => Elzoo.Wave4ChannelExample.NativeBindings.target()
    }
  end

  defp unit_options(unit_opts, unit_store, identity) do
    offer = fn item ->
      case Registry.lookup(Elzoo.RunEngine.TestRegistry, identity) do
        [{pid, _}] -> send(pid, item)
        [] -> :ok
      end

      :ok
    end

    Keyword.merge(unit_opts, store: unit_store, offer: offer)
  end

  defp await_engine_unregistered(registry, identity, deadline) do
    case Registry.lookup(registry, identity) do
      [] ->
        :ok

      [{pid, _}] ->
        true = not Process.alive?(pid)

        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1)
          await_engine_unregistered(registry, identity, deadline)
        else
          {:error, :engine_still_registered}
        end
    end
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

  defp http_request(listener, method, path, headers, body) do
    url = String.to_charlist(listener.url <> path)

    headers =
      Enum.map(headers, fn {name, value} ->
        {String.to_charlist(name), String.to_charlist(value)}
      end)

    request =
      case method do
        :get -> {url, headers}
        :head -> {url, headers}
        _ -> {url, headers, ~c"application/json", body}
      end

    :httpc.request(method, request, [connect_timeout: 2_000, timeout: 10_000], body_format: :binary)
  end
end
