# Run with `mix run examples/wave4_channel.exs` and ELZOO_TEST_DATABASE_URL set to a disposable local PostgreSQL database.
# The principal and messages are synthetic loopback-only demonstration data, not production authentication.
Code.require_file(Path.join(__DIR__, "support/wave4_channel.ex"))

defmodule Elzoo.Wave4ChannelDemo.Repo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.Wave4ChannelDemo.Migration do
  use Ecto.Migration

  def up, do: Elzoo.DurableLog.Postgres.Migration.up()
  def down, do: Elzoo.DurableLog.Postgres.Migration.down()
end

defmodule Elzoo.Wave4ChannelDemo do
  alias Ecto.Adapters.SQL
  alias Elzoo.{DurableUnit, DynamicUnits, Lease, RunApprovalRelease}
  alias Elzoo.DurableLog.{Postgres, Store}
  alias Elzoo.Wave4ChannelDemo.{Migration, Repo}

  @engine_registry Elzoo.Wave4ChannelDemo.EngineRegistry
  @unit_registry Elzoo.Wave4ChannelDemo.UnitRegistry
  @unit_supervisor Elzoo.Wave4ChannelDemo.UnitSupervisor
  @task_supervisor Elzoo.Wave4ChannelDemo.TaskSupervisor
  @lease_stream "wave4-demo-runs"
  @lease_owner "wave4-demo-owner"
  @lease_ttl_ms 3_600_000
  @deadline_ms 120_000

  def run! do
    url = database_url!()
    Logger.configure(level: :warning)
    {:ok, repo_pid} = Repo.start_link(url: url, pool_size: 8)
    Process.unlink(repo_pid)

    try do
      run_mode!(Repo, :immediate_v1)
      run_mode!(Repo, :reply_v2)
    rescue
      _ -> raise "Wave 4 demo failed; database configuration is not displayed"
    after
      :ok = Supervisor.stop(repo_pid, :normal, 15_000)
      true = not Process.alive?(repo_pid)
    end

    IO.puts(
      "cleanup: listener, host/native processes, owners, supervisors, and registries stopped; generated schema dropped; Repo stopped"
    )

    :ok
  end

  defp run_mode!(repo, mode) do
    prefix = "wave4_channel_demo_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    create_schema!(repo, prefix)

    try do
      migrate_schema!(repo, prefix)

      case run_owned_services(repo, prefix, mode) do
        {:ok, :complete} -> :ok
        {:error, _reason} -> raise "Wave 4 demo mode failed"
      end
    after
      drop_schema!(repo, prefix)
    end
  end

  defp database_url! do
    case System.get_env("ELZOO_TEST_DATABASE_URL") do
      url when is_binary(url) and byte_size(url) > 0 ->
        uri = URI.parse(url)

        if uri.scheme in ["ecto", "postgres", "postgresql"] and
             uri.host in ["localhost", "127.0.0.1", "::1"] do
          url
        else
          raise "ELZOO_TEST_DATABASE_URL must target a disposable local PostgreSQL database"
        end

      _ ->
        raise "Set ELZOO_TEST_DATABASE_URL to a disposable local PostgreSQL database"
    end
  rescue
    _ -> raise "ELZOO_TEST_DATABASE_URL must target a disposable local PostgreSQL database"
  end

  defp create_schema!(repo, prefix) do
    SQL.query!(repo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [], log: false)
  end

  defp migrate_schema!(_repo, prefix) do
    :ok = Ecto.Migrator.up(Repo, 1, Migration, prefix: prefix, log: false)
  end

  defp drop_schema!(repo, prefix) do
    SQL.query!(repo, "DROP SCHEMA #{Postgres.identifier(prefix)} CASCADE", [], log: false)

    {:ok, result} =
      SQL.query(repo, "SELECT count(*) FROM pg_namespace WHERE nspname = $1", [prefix], log: false)

    true = result.rows == [[0]]
    :ok
  end

  defp run_owned_services(repo, prefix, mode) do
    with {:ok, resources} <- build_services(repo, prefix, mode),
         {:ok, infrastructure} <- start_infrastructure() do
      Process.unlink(infrastructure)

      try do
        start_directory(resources, infrastructure)
      after
        stop_infrastructure!(infrastructure)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_services(repo, prefix, mode) do
    profile = profile(mode)

    run_store =
      Postgres.store(repo,
        prefix: prefix,
        fold: RunApprovalRelease.fold(),
        limits: RunApprovalRelease.limits()
      )

    {:ok, lease} = Lease.new(store: run_store, clock: :store)
    {:held, held} = Lease.claim(lease, @lease_stream, @lease_owner, @lease_ttl_ms)

    command_store =
      Postgres.store(repo, prefix: prefix, fold: command_fold(mode), limits: command_limits())

    conversation_store =
      Postgres.store(repo,
        prefix: prefix,
        fold: conversation_fold(),
        limits: conversation_limits()
      )

    {:ok, handles} = build_handles(mode, command_store)

    unit_options = unit_options(mode)

    unit_store =
      Postgres.store(repo,
        prefix: prefix,
        fold: DurableUnit.fold(unit_options),
        limits: DurableUnit.limits(unit_options)
      )

    evidence_store =
      Postgres.store(repo,
        prefix: prefix,
        fold: evidence_fold(),
        limits: evidence_limits()
      )

    true = @engine_registry != @unit_registry

    {:ok,
     %{
       profile: profile,
       mode: mode,
       signing_key: :crypto.strong_rand_bytes(32),
       reply_signing_key: if(mode == :reply_v2, do: :crypto.strong_rand_bytes(32)),
       command_store: command_store,
       conversation_store: conversation_store,
       handles: handles,
       run_store: run_store,
       lease: lease,
       held: held,
       unit_store: unit_store,
       unit_options: unit_options,
       evidence_store: evidence_store
     }}
  rescue
    _ -> {:error, :services}
  end

  defp start_infrastructure do
    children = [
      Supervisor.child_spec({Registry, keys: :unique, name: @engine_registry},
        id: :engine_registry
      ),
      Supervisor.child_spec({Registry, keys: :unique, name: @unit_registry}, id: :unit_registry),
      Supervisor.child_spec(
        {DynamicSupervisor, strategy: :one_for_one, name: @unit_supervisor, max_children: 4},
        id: :unit_supervisor
      ),
      Supervisor.child_spec({Task.Supervisor, name: @task_supervisor}, id: :task_supervisor)
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp start_directory(resources, infrastructure) do
    case DynamicUnits.start_link(
           registry: @unit_registry,
           supervisor: @unit_supervisor,
           idle_ms: 60_000,
           unit_options: fn identity ->
             offer = fn item ->
               case Registry.lookup(@engine_registry, identity) do
                 [{pid, _}] -> send(pid, item)
                 [] -> :ok
               end

               :ok
             end

             Keyword.merge(resources.unit_options, store: resources.unit_store, offer: offer)
           end
         ) do
      {:ok, directory} ->
        Process.unlink(directory)

        try do
          start_run_owner(resources, infrastructure, directory)
        after
          stop_genserver!(directory)
        end

      {:error, _} ->
        {:error, :directory}
    end
  end

  defp start_run_owner(resources, infrastructure, directory) do
    case RunApprovalRelease.start_link(
           store: resources.run_store,
           lease: resources.lease,
           held: resources.held,
           effect_intent: %{}
         ) do
      {:ok, owner} ->
        Process.unlink(owner)

        try do
          start_host(resources, infrastructure, directory, owner)
        after
          stop_genserver!(owner)
        end

      {:error, _} ->
        {:error, :run_owner}
    end
  end

  defp start_host(resources, infrastructure, directory, owner) do
    native = %{
      run_owner: owner,
      held: resources.held,
      lease: resources.lease,
      lease_owner: @lease_owner,
      lease_stream: @lease_stream,
      directory: directory,
      registry: @engine_registry,
      unit_registry: @unit_registry,
      supervisor: Process.whereis(@unit_supervisor),
      task_supervisor: Process.whereis(@task_supervisor),
      unit_store: resources.unit_store,
      evidence_store: resources.evidence_store,
      engine: Elzoo.Wave4ChannelExample.NativeBindings.build(resources.profile)
    }

    options = [
      profile: resources.profile,
      bindings: [trigger_binding(resources.profile)],
      command_store: resources.command_store,
      conversation_store: resources.conversation_store,
      handles: resources.handles,
      native: native,
      authority: authority(resources),
      policy: fn mode, _event, _at -> policy_for(resources.mode, mode) end,
      clock: fn -> System.system_time(:millisecond) end
    ]

    case Elzoo.Wave4ChannelExample.start_link(options) do
      {:ok, host} ->
        Process.unlink(host)

        try do
          run_mode_listener(host, owner, resources)
        after
          stop_host!(host, infrastructure, directory)
        end

      {:error, _} ->
        {:error, :host}
    end
  end

  defp run_with_listener(host, resources) do
    start_listener(
      host,
      resources.profile,
      resources.profile.source_id,
      resources.signing_key,
      &Elzoo.Wave4ChannelExample.admit(host, &1, &2)
    )
    |> case do
      {:ok, listener} ->
        try do
          capture_demo(fn -> demonstrate!(host, listener, resources) end)
        after
          stop_listener!(listener)
        end

      {:error, _} ->
        {:error, :listener}
    end
  end

  defp run_mode_listener(host, _owner, %{mode: :immediate_v1} = resources) do
    run_with_listener(host, resources)
  end

  defp run_mode_listener(host, owner, %{mode: :reply_v2} = resources) do
    profile = resources.profile

    with {:ok, primary} <-
           start_listener(
             host,
             profile,
             profile.source_id,
             resources.signing_key,
             &Elzoo.Wave4ChannelExample.admit(host, &1, &2)
           ) do
      try do
        with {:ok, reply} <-
               start_listener(
                 host,
                 profile,
                 profile.reply_source_id,
                 resources.reply_signing_key,
                 &Elzoo.Wave4ChannelExample.admit_reply(host, &1, &2)
               ) do
          try do
            capture_demo(fn -> demonstrate_reply!(host, owner, primary, reply, resources) end)
          after
            stop_listener!(reply)
          end
        end
      after
        stop_listener!(primary)
      end
    end
  end

  defp profile(:immediate_v1) do
    %{
      tenant: "wave4-demo-tenant",
      actor: "wave4-demo-actor",
      source_id: "wave4-demo-source",
      conversation_id: "wave4-demo-conversation",
      deadline_ms: System.system_time(:millisecond) + @deadline_ms,
      native_target: Elzoo.Wave4ChannelExample.NativeBindings.target()
    }
  end

  defp profile(:reply_v2) do
    %{
      tenant: "wave4-demo-tenant",
      actor: "wave4-demo-actor",
      source_id: "wave4-demo-primary-source",
      reply_source_id: "wave4-demo-reply-source",
      conversation_id: "wave4-demo-reply-conversation",
      deadline_ms: System.system_time(:millisecond) + @deadline_ms,
      native_target: Elzoo.Wave4ChannelExample.NativeBindings.reply_target()
    }
  end

  defp build_handles(:immediate_v1, store),
    do: Elzoo.Wave4ChannelExample.CommandBindings.build(store, gates(:immediate_v1))

  defp build_handles(:reply_v2, store),
    do: Elzoo.Wave4ChannelExample.CommandBindings.build_reply(store, gates(:reply_v2))

  defp unit_options(mode) do
    version = if mode == :immediate_v1, do: 1, else: 2

    [
      operator:
        {Elzoo.RunEngine, :step, %{version: version, control: nil, slots: %{}, requests: %{}}},
      retention_count: 1_024,
      max_record_bytes: 16_777_216,
      max_checkpoint_bytes: 33_554_432
    ]
  end

  defp command_fold(mode) do
    %{
      initial: %{},
      kinds: %{"checked_command" => :state_bearing},
      versions: [1],
      destinations:
        if(mode == :reply_v2,
          do: ["wave4-channel-input", "wave4-channel-reply", "wave4-channel-delivery"],
          else: ["wave4-channel-input", "wave4-channel-delivery"]
        ),
      reduce: fn model, _, _, _ -> model end
    }
  end

  defp command_limits,
    do: %{max_record_bytes: 1_048_576, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}

  defp conversation_fold do
    %{
      initial: %{},
      kinds: Map.new(Elzoo.Conversation.Record.kinds(), &{&1, :non_state_bearing}),
      versions: [1],
      destinations: [],
      reduce: fn model, _, _, _ -> model end
    }
  end

  defp conversation_limits,
    do: %{
      max_record_bytes: Elzoo.Conversation.Record.max_payload_bytes(),
      max_batch_size: 1_000,
      max_checkpoint_bytes: 65_536
    }

  defp evidence_fold do
    %{
      initial: nil,
      kinds: %{"completion" => :state_bearing},
      versions: [1],
      destinations: [],
      reduce: fn _, _, _, bytes -> bytes end
    }
  end

  defp evidence_limits,
    do: %{max_record_bytes: 131_072, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}

  defp gates(:immediate_v1) do
    %{
      input: fn _, _ -> :allow end,
      association: fn _, _ -> :allow end,
      answer: fn _, _ -> :allow end
    }
  end

  defp gates(:reply_v2) do
    %{
      input: fn _, _ -> :allow end,
      reply: fn _, _ -> :allow end,
      association: fn _, _ -> :allow end,
      reply_association: fn _, _ -> :allow end,
      answer: fn _, _ -> :allow end
    }
  end

  defp channel_policy(verdict \\ :allow) do
    rule =
      if verdict == :ask do
        %{
          id: "wave4-demo-review",
          effect_class: "conversation.write",
          verdict: :ask,
          requirement: %{name: "wave4-demo-review", version: 1, scope: :once}
        }
      else
        %{id: "wave4-demo-allow", effect_class: "conversation.write", verdict: verdict}
      end

    artifact = %{
      id: "wave4-demo-channel-policy",
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

  defp policy_for(:immediate_v1, _mode), do: channel_policy()

  defp policy_for(:reply_v2, mode) when mode in [:reply_input, :reply_release],
    do: channel_policy(:ask)

  defp policy_for(:reply_v2, _mode), do: channel_policy()

  defp authority(%{mode: :immediate_v1}), do: fn _mode, _event, _request, _facts -> %{} end

  defp authority(%{profile: profile, handles: handles, mode: :reply_v2}) do
    fn mode, _event, request, facts ->
      if mode == :reply_release do
        scope = %{
          tenant: profile.tenant,
          actor: profile.actor,
          resources: [profile.conversation_id]
        }

        prepared_facts = %{tenant: profile.tenant, actor: profile.actor, data: facts}

        with {:ok, snapshot} <-
               Elzoo.CheckedCommand.resource(
                 handles.reply_input,
                 scope,
                 profile.conversation_id
               ),
             {:ok, writes, _response} <-
               Elzoo.Wave4ChannelExample.Intents.prepare(
                 snapshot,
                 request,
                 prepared_facts
               ) do
          %{
            approver: %{identity: "reviewer", authority: writes},
            now: System.system_time(:millisecond),
            revoked: []
          }
        else
          _ -> %{}
        end
      else
        %{}
      end
    end
  end

  defp trigger_binding(profile) do
    %{
      "version" => 1,
      "id" => "wave4-demo-binding",
      "revision" => 1,
      "tenant" => profile.tenant,
      "source" => profile.source_id,
      "schema_id" => "elzoo.message/v1",
      "schema_version" => 1,
      "enabled" => true,
      "target" => profile.native_target
    }
  end

  defp start_listener(host, profile, source_id, signing_key, admit) do
    ref = make_ref()
    scope = scope(profile)

    webhook = [
      source_id: source_id,
      key: fn -> {:ok, signing_key} end,
      clock: fn -> System.system_time(:second) end,
      principal: fn _conn -> {:ok, scope} end,
      admit: admit
    ]

    options = [
      host: host,
      conversation_id: profile.conversation_id,
      webhook: webhook,
      principal: fn _conn -> {:ok, scope} end
    ]

    case Plug.Cowboy.http(Elzoo.Wave4ChannelExample.Router, options,
           ref: ref,
           port: 0,
           ip: {127, 0, 0, 1}
         ) do
      {:ok, pid} ->
        Process.unlink(pid)

        try do
          {:ok, %{pid: pid, ref: ref, url: "http://127.0.0.1:#{:ranch.get_port(ref)}"}}
        rescue
          _ ->
            stop_listener!(%{pid: pid, ref: ref})
            {:error, :listener}
        end

      {:error, _} ->
        {:error, :listener}
    end
  end

  defp stop_listener!(listener) do
    :ok = Plug.Cowboy.shutdown(listener.ref)
    true = not Process.alive?(listener.pid)
    :ok
  end

  defp demonstrate!(host, listener, resources) do
    first = event(resources.profile, "demo-event-1", "demo-input-1", 0, "first synthetic message")
    second = event(resources.profile, "demo-event-2", "demo-input-2", 3, "second synthetic message")
    first_request = signed_request(first, resources.profile.source_id, resources.signing_key)
    second_request = signed_request(second, resources.profile.source_id, resources.signing_key)

    {202, first_receipt} = post_signed!(listener.url, first_request)
    first_steps = drive_until_ack!(host, first["input_id"], driver_deadline(resources.profile))
    IO.puts("input 1: #{trace(first_steps)}")

    {202, _second_receipt} = post_signed!(listener.url, second_request)
    second_steps = drive_until_ack!(host, second["input_id"], driver_deadline(resources.profile))
    unit_ids = for {:engine_started, unit_id} <- first_steps ++ second_steps, do: unit_id
    Process.put({__MODULE__, :unit_ids}, unit_ids)

    IO.puts("input 2: #{trace(second_steps)}")

    before = get_view!(listener.url, resources.profile.conversation_id)
    view = before["view"]
    messages = view["messages"]
    runs = view["runs"]

    true = view["revision"] == 6
    true = length(messages) == 4
    true = length(runs) == 2
    true = Enum.all?(runs, &(&1["outcome"] == "completed"))
    answers = messages |> Enum.filter(&(&1["role"] == "assistant")) |> Enum.map(& &1["text"])
    true = length(answers) == 2
    true = Enum.all?(answers, &is_binary/1)

    stream =
      "cc1:" <>
        Base.url_encode64(
          :erlang.term_to_binary({:cc, 1, resources.profile.tenant}, [:deterministic]),
          padding: false
        )

    {:ok, head_before} = Store.read(resources.command_store, :head, [stream])
    true = head_before.revision == 6

    {202, replay_receipt} = post_signed!(listener.url, first_request)
    true = replay_receipt == first_receipt
    after_replay = get_view!(listener.url, resources.profile.conversation_id)
    {:ok, head_after} = Store.read(resources.command_store, :head, [stream])
    true = after_replay["view"] == view
    true = head_after == head_before

    IO.puts("replay 1: original receipt retained; GET view and command head unchanged")
    IO.puts("completed Runs: #{length(runs)}; messages: #{length(messages)}")
    IO.puts("native answers: #{Enum.join(answers, " | ")}")
    :ok
  end

  defp demonstrate_reply!(host, owner, primary_listener, reply_listener, resources) do
    profile = resources.profile
    scope = scope(profile)
    stream = checked_stream(profile.tenant)

    first = reply_round!(host, owner, primary_listener, reply_listener, resources, 1)

    second =
      reply_round!(host, owner, primary_listener, reply_listener, resources, 2, fn ->
        before = get_view!(primary_listener.url, profile.conversation_id)
        {:ok, head_before} = Store.read(resources.command_store, :head, [stream])

        {:ok, resource_before} =
          Elzoo.CheckedCommand.resource(resources.handles.input, scope, profile.conversation_id)

        {202, primary_receipt} = post_signed!(primary_listener.url, first.primary_request)

        {202, reply_committed_receipt} =
          post_signed!(reply_listener.url, first.reply_request)

        true = primary_receipt == first.primary_receipt
        true = reply_committed_receipt == first.reply_committed_receipt
        after_replay = get_view!(primary_listener.url, profile.conversation_id)
        {:ok, head_after} = Store.read(resources.command_store, :head, [stream])

        {:ok, resource_after} =
          Elzoo.CheckedCommand.resource(resources.handles.input, scope, profile.conversation_id)

        true = before == after_replay
        true = head_before == head_after
        true = resource_before == resource_after
      end)

    final_primary = get_view!(primary_listener.url, profile.conversation_id)
    final_reply = get_view!(reply_listener.url, profile.conversation_id)
    true = final_primary == final_reply
    view = final_primary["view"]
    true = view["revision"] == 10
    true = length(view["messages"]) == 6
    true = length(view["runs"]) == 2
    true = Enum.all?(view["runs"], &(&1["outcome"] == "completed"))

    answers =
      view["messages"] |> Enum.filter(&(&1["role"] == "assistant")) |> Enum.map(& &1["text"])

    true = answers == [expected_answer(first.reply_text), expected_answer(second.reply_text)]

    run_ids = Enum.map(view["runs"], & &1["run_id"])
    true = length(Enum.uniq(run_ids)) == 2
    {:ok, first_run} = RunApprovalRelease.status(owner, hd(run_ids))
    {:ok, second_run} = RunApprovalRelease.status(owner, List.last(run_ids))
    true = first_run.current_attempt != second_run.current_attempt
    true = first.ticket != second.ticket

    {:ok, head_before_get} = Store.read(resources.command_store, :head, [stream])

    {:ok, resource_before_get} =
      Elzoo.CheckedCommand.resource(resources.handles.input, scope, profile.conversation_id)

    ^final_primary = get_view!(primary_listener.url, profile.conversation_id)
    ^final_reply = get_view!(reply_listener.url, profile.conversation_id)
    {:ok, head_after_get} = Store.read(resources.command_store, :head, [stream])

    {:ok, resource_after_get} =
      Elzoo.CheckedCommand.resource(resources.handles.input, scope, profile.conversation_id)

    true = head_before_get == head_after_get
    true = resource_before_get == resource_after_get

    IO.puts("reply rounds: 2; reply ACK precedes primary ACK in each round")

    IO.puts(
      "replay 1: original primary and reply receipts retained; second wait/run/head unchanged"
    )

    IO.puts("completed Runs: 2; messages: 6; revision: 10")
    IO.puts("native answers: #{Enum.join(answers, " | ")}")
    :ok
  end

  defp reply_round!(
         host,
         owner,
         primary_listener,
         reply_listener,
         resources,
         number,
         during_wait \\ fn -> :ok end
       ) do
    profile = resources.profile
    scope = scope(profile)
    prefix = "demo-v2-#{number}"
    text = "retained reply text #{number}"

    expected_revision =
      if number == 1 do
        0
      else
        get_view!(primary_listener.url, profile.conversation_id)["view"]["revision"]
      end

    primary =
      event(
        profile,
        prefix <> "-primary",
        prefix <> "-input",
        expected_revision,
        "primary message #{number}"
      )

    primary_request = signed_request(primary, profile.source_id, resources.signing_key)
    {202, primary_receipt} = post_signed!(primary_listener.url, primary_request)

    {:ok, [primary_item | _]} =
      Elzoo.Outbox.pending(resources.command_store, checked_stream(profile.tenant), 64)

    true = primary_item.destination == "wave4-channel-input"

    wait_steps = drive_until_wait!(host, driver_deadline(profile))

    Process.put(
      {__MODULE__, :unit_ids},
      (Process.get({__MODULE__, :unit_ids}) || []) ++
        for({:engine_started, unit_id} <- wait_steps, do: unit_id)
    )

    waiting = get_view!(primary_listener.url, profile.conversation_id)["view"]
    [wait] = waiting["event_waits"]["waits"]
    true = wait["status"] == "waiting" and wait["action_id"] == "reply"
    ticket = wait["correlation_id"]

    [unit_id] = for {:engine_started, unit_id} <- wait_steps, do: unit_id
    [{engine, _}] = Registry.lookup(@engine_registry, unit_id)
    [active_run] = Enum.reject(waiting["runs"], &(&1["outcome"] == "completed"))
    run_id = active_run["run_id"]
    {:ok, run_status_before_reply} = RunApprovalRelease.status(owner, run_id)
    run_attempt_id = run_status_before_reply.current_attempt

    native_scope = %{
      tenant: profile.tenant,
      principal: profile.actor,
      run_id: run_id
    }

    during_wait.()

    reply = event(profile, prefix <> "-reply", ticket, waiting["revision"], text)
    reply_request = signed_request(reply, profile.reply_source_id, resources.reply_signing_key)

    {:ok, head_before_ask} =
      Store.read(resources.command_store, :head, [checked_stream(profile.tenant)])

    {:ok, resource_before_ask} =
      Elzoo.CheckedCommand.resource(resources.handles.input, scope, profile.conversation_id)

    {:ok, reply_resource_before_ask} =
      Elzoo.CheckedCommand.resource(
        resources.handles.reply_input,
        scope,
        profile.conversation_id
      )

    true = reply_resource_before_ask == resource_before_ask

    {202, reply_receipt} = post_signed!(reply_listener.url, reply_request)
    %{"status" => "pending_approval"} = Jason.decode!(reply_receipt)

    {:ok, head_after_ask} =
      Store.read(resources.command_store, :head, [checked_stream(profile.tenant)])

    {:ok, resource_after_ask} =
      Elzoo.CheckedCommand.resource(resources.handles.input, scope, profile.conversation_id)

    true = resource_before_ask.revision == resource_after_ask.revision
    true = head_after_ask.revision > head_before_ask.revision

    operation = demo_id("input", [profile.reply_source_id, reply["event_id"]])

    {:approval_pending, pending} =
      Elzoo.CheckedCommand.result(
        resources.handles.reply_input,
        %{tenant: profile.tenant, actor: profile.actor},
        {profile.tenant, profile.actor, operation}
      )

    now = System.system_time(:millisecond)

    evidence = %{
      purpose: :command,
      tenant: profile.tenant,
      evidence: %{
        verifier: "wave4-command-approver",
        evidence_id: "demo-reply-approval-#{number}",
        reviewer: "reviewer",
        request: pending.key,
        decision: :approve,
        scope: :once,
        issued_at: now - 1_000,
        expiry: now + 60_000
      }
    }

    {:committed, reply_revision} =
      Elzoo.Wave4ChannelExample.release_reply(
        host,
        normalized_event(reply),
        scope,
        evidence
      )

    {:completed, %{revision: ^reply_revision}} =
      Elzoo.CheckedCommand.result(
        resources.handles.reply_input,
        %{tenant: profile.tenant, actor: profile.actor},
        {profile.tenant, profile.actor, operation}
      )

    {202, reply_committed_receipt} = post_signed!(reply_listener.url, reply_request)

    %{"status" => "committed", "revision" => ^reply_revision} =
      Jason.decode!(reply_committed_receipt)

    {:ok, pending_items} =
      Elzoo.Outbox.pending(resources.command_store, checked_stream(profile.tenant), 64)

    reply_item = Enum.find(pending_items, &(&1.destination == "wave4-channel-reply"))
    true = is_map(reply_item) and primary_item.sequence < reply_item.sequence

    native_result =
      drive_until_native_result!(host, engine, native_scope, driver_deadline(profile))

    true =
      native_result.run_id == run_id and native_result.attempt_id == run_attempt_id and
        native_result.action_id == "hash" and
        native_result.payload["answer"] == expected_answer(text)

    {:ok, %{waits: [accepted_wait]}} =
      Elzoo.RunEngine.event_waits(engine, native_scope, %{
        max_records: 2_048,
        max_bytes: 16_777_216
      })

    true =
      accepted_wait.accepted_event.event_id == reply_item.idempotency_key and
        accepted_wait.accepted_event.sequence == reply_item.sequence

    drive_until_ack_receipt!(host, resources.command_store, reply_item, driver_deadline(profile))
    assert_ack!(resources.command_store, reply_item)

    {:ok, %{state: :pending, nonce: primary_nonce}} =
      Store.read(resources.command_store, :read_ack, [primary_item.idempotency_key])

    true = primary_nonce == primary_item.nonce

    primary_steps = drive_until_ack!(host, primary["input_id"], driver_deadline(profile))

    Process.put(
      {__MODULE__, :unit_ids},
      (Process.get({__MODULE__, :unit_ids}) || []) ++
        for({:engine_started, unit_id} <- primary_steps, do: unit_id)
    )

    assert_ack!(resources.command_store, primary_item)
    completed = get_view!(primary_listener.url, profile.conversation_id)["view"]
    true = Enum.any?(completed["messages"], &(&1["text"] == text))
    true = Enum.any?(completed["messages"], &(&1["text"] == expected_answer(text)))
    run = Enum.find(completed["runs"], &(&1["run_id"] == run_id))
    true = is_map(run)
    {:ok, run_status} = RunApprovalRelease.status(owner, run["run_id"])
    true = run["run_id"] == run_id and run_status.current_attempt == run_attempt_id

    %{
      primary_request: primary_request,
      primary_receipt: primary_receipt,
      reply_request: reply_request,
      reply_committed_receipt: reply_committed_receipt,
      ticket: ticket,
      reply_text: text,
      run_id: run["run_id"],
      attempt_id: run_status.current_attempt
    }
  end

  defp drive_until_wait!(host, deadline), do: drive_until_wait!(host, deadline, [])

  defp drive_until_wait!(host, deadline, steps) do
    if System.monotonic_time(:millisecond) >= deadline, do: raise("reply wait timed out")

    case Elzoo.Wave4ChannelExample.advance(host) do
      {:pending, :event_waiting} ->
        Enum.reverse(steps)

      {:blocked, _} ->
        raise "reply wait blocked"

      {:error, _} ->
        raise("reply wait unavailable")

      step ->
        if match?({:pending, _}, step), do: Process.sleep(2)
        drive_until_wait!(host, deadline, [step | steps])
    end
  end

  defp drive_until_native_result!(host, engine, scope, deadline) do
    case Elzoo.RunEngine.result(engine, scope, %{max_records: 2_048, max_bytes: 16_777_216}) do
      {:ok, result} ->
        result

      {:pending, _} ->
        advance_native_result!(host, deadline)
        drive_until_native_result!(host, engine, scope, deadline)

      {:error, :unavailable} ->
        advance_native_result!(host, deadline)
        drive_until_native_result!(host, engine, scope, deadline)

      _ ->
        raise "native result unavailable"
    end
  end

  defp advance_native_result!(host, deadline) do
    if System.monotonic_time(:millisecond) >= deadline, do: raise("native result timed out")

    case Elzoo.Wave4ChannelExample.advance(host) do
      {:blocked, _} -> raise "native result blocked"
      {:error, _} -> raise "native result unavailable"
      {:pending, _} -> Process.sleep(2)
      {:unknown, _} -> raise "native result unknown"
      _ -> :ok
    end
  end

  defp drive_until_ack_receipt!(host, store, item, deadline) do
    case Store.read(store, :read_ack, [item.idempotency_key]) do
      {:ok, %{state: :acked}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline, do: raise("reply ACK timed out")

        case Elzoo.Wave4ChannelExample.advance(host) do
          {:error, _} -> raise("reply ACK unavailable")
          {:pending, _} -> Process.sleep(2)
          _ -> :ok
        end

        drive_until_ack_receipt!(host, store, item, deadline)
    end
  end

  defp assert_ack!(store, item) do
    assert_ack = Store.read(store, :read_ack, [item.idempotency_key])
    {:ok, %{state: :acked, idempotency_key: key, nonce: nonce, ack_nonce: ack_nonce}} = assert_ack
    true = key == item.idempotency_key and nonce == item.nonce and ack_nonce == item.nonce
  end

  defp expected_answer(text),
    do: "answer:" <> Base.encode16(:crypto.hash(:sha256, text), case: :lower)

  defp demo_id(domain, terms) do
    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({:wave4_channel, 1, domain, terms}, [:deterministic])
      )

    domain <> ":" <> Base.url_encode64(digest, padding: false)
  end

  defp checked_stream(tenant),
    do:
      "cc1:" <>
        Base.url_encode64(:erlang.term_to_binary({:cc, 1, tenant}, [:deterministic]),
          padding: false
        )

  defp event(profile, event_id, input_id, expected_revision, text) do
    %{
      "version" => 1,
      "event_id" => event_id,
      "conversation_id" => profile.conversation_id,
      "input_id" => input_id,
      "expected_revision" => expected_revision,
      "text" => text
    }
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

  defp signed_request(event, source_id, key) do
    body = Jason.encode!(event)
    timestamp = Integer.to_string(System.system_time(:second))
    frame = "elzoo-webhook-v1\n#{source_id}\nPOST\n/elzoo/v1/messages\n#{timestamp}\n#{body}"
    signature = "v1=" <> Base.encode16(:crypto.mac(:hmac, :sha256, key, frame), case: :lower)
    %{body: body, timestamp: timestamp, signature: signature}
  end

  defp post_signed!(url, request) do
    {:ok, _} = Application.ensure_all_started(:inets)

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"x-elzoo-timestamp", String.to_charlist(request.timestamp)},
      {~c"x-elzoo-signature", String.to_charlist(request.signature)}
    ]

    response =
      :httpc.request(
        :post,
        {String.to_charlist(url <> "/elzoo/v1/messages"), headers, ~c"application/json",
         request.body},
        [timeout: 5_000, connect_timeout: 2_000],
        body_format: :binary
      )

    case response do
      {:ok, {{_, status, _}, _, body}} -> {status, body}
      _ -> raise "signed loopback POST failed"
    end
  end

  defp get_view!(url, conversation_id) do
    {:ok, _} = Application.ensure_all_started(:inets)
    path = "/elzoo/v1/conversations/#{conversation_id}"

    case :httpc.request(
           :get,
           {String.to_charlist(url <> path), []},
           [timeout: 5_000, connect_timeout: 2_000],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} ->
        %{"status" => "ok", "view" => view} = Jason.decode!(body)
        %{"status" => "ok", "view" => view}

      _ ->
        raise "loopback GET failed"
    end
  end

  defp drive_until_ack!(host, input_id, deadline) do
    drive_until_ack!(host, input_id, deadline, [])
  end

  defp drive_until_ack!(host, input_id, deadline, steps) do
    if System.monotonic_time(:millisecond) >= deadline,
      do: raise("demo exceeded the fixed Run deadline")

    case Elzoo.Wave4ChannelExample.advance(host) do
      {:acknowledged, ^input_id} = acknowledged ->
        Enum.reverse([acknowledged | steps])

      {:acknowledged, _other} ->
        raise "demo acknowledged a different input"

      {:pending, _reason} ->
        Process.sleep(2)
        drive_until_ack!(host, input_id, deadline, steps)

      {:unknown, _reason} ->
        raise "demo entered an unknown host phase"

      {:error, _reason} ->
        raise "demo host phase failed"

      {:blocked, _reason} ->
        raise "demo host phase was blocked"

      {:observed, _} = step ->
        drive_until_ack!(host, input_id, deadline, [step | steps])

      {:associated, _} = step ->
        drive_until_ack!(host, input_id, deadline, [step | steps])

      {:run_created, _} = step ->
        drive_until_ack!(host, input_id, deadline, [step | steps])

      {:attempt_started, _} = step ->
        drive_until_ack!(host, input_id, deadline, [step | steps])

      {:engine_started, _} = step ->
        drive_until_ack!(host, input_id, deadline, [step | steps])

      {:native_input, result} = step when result in [:applied, :duplicate] ->
        drive_until_ack!(host, input_id, deadline, [step | steps])

      {:result, :completed} = step ->
        drive_until_ack!(host, input_id, deadline, [step | steps])

      {:answered, _} = step ->
        drive_until_ack!(host, input_id, deadline, [step | steps])

      _unexpected ->
        raise "demo received an unexpected host phase"
    end
  end

  defp driver_deadline(profile) do
    remaining = max(profile.deadline_ms - System.system_time(:millisecond), 0)
    System.monotonic_time(:millisecond) + remaining
  end

  defp trace(steps) do
    steps
    |> Enum.map(fn {phase, _} -> Atom.to_string(phase) end)
    |> Enum.join(" -> ")
  end

  defp scope(profile),
    do: %{tenant: profile.tenant, actor: profile.actor, resources: [profile.conversation_id]}

  defp capture_demo(fun) do
    try do
      case fun.() do
        :ok -> {:ok, :complete}
        _ -> {:error, :demo_failed}
      end
    rescue
      _ ->
        {:error, :demo_failed}
    catch
      _, _ ->
        {:error, :demo_failed}
    end
  end

  defp stop_host!(host, infrastructure, directory) do
    native_pids =
      if Process.alive?(host) do
        state = :sys.get_state(host)
        [state.engine, state.async_work, state.writer] |> Enum.filter(&is_pid/1)
      else
        []
      end

    unit_supervisor = Process.whereis(@unit_supervisor)
    task_supervisor = Process.whereis(@task_supervisor)
    true = is_pid(unit_supervisor)
    true = is_pid(task_supervisor)

    unit_pids =
      DynamicSupervisor.which_children(unit_supervisor)
      |> Enum.map(fn {_, pid, _, _} -> pid end)
      |> Enum.filter(&is_pid/1)

    task_pids = Task.Supervisor.children(task_supervisor)

    if Process.alive?(host), do: :ok = GenServer.stop(host, :normal, 15_000)
    true = not Process.alive?(host)
    true = Enum.all?(native_pids ++ unit_pids ++ task_pids, &(not Process.alive?(&1)))
    [] = Task.Supervisor.children(task_supervisor)

    :ok =
      await_demo_native_cleanup!(
        directory,
        unit_supervisor,
        Process.get({__MODULE__, :unit_ids}, []),
        System.monotonic_time(:millisecond) + 5_000
      )

    true = Process.alive?(infrastructure)
    :ok
  end

  defp await_demo_native_cleanup!(directory, unit_supervisor, unit_ids, deadline) do
    registrations =
      for registry <- [@engine_registry, @unit_registry], unit_id <- unit_ids do
        Registry.lookup(registry, unit_id)
      end

    live_registration =
      Enum.any?(registrations, fn
        [{pid, _}] -> Process.alive?(pid)
        _ -> false
      end)

    live_children =
      DynamicSupervisor.which_children(unit_supervisor)
      |> Enum.any?(fn {_, pid, _, _} -> is_pid(pid) and Process.alive?(pid) end)

    directory_states = Enum.map(unit_ids, &DynamicUnits.find(directory, &1))

    live_directory_owner =
      Enum.any?(directory_states, fn
        {:ok, pid} when is_pid(pid) -> Process.alive?(pid)
        _ -> false
      end)

    directory_unavailable = Enum.any?(directory_states, &match?({:error, :unavailable}, &1))

    true = not live_registration
    true = not live_children
    true = not live_directory_owner
    true = not directory_unavailable

    cond do
      Registry.count(@engine_registry) == 0 and Registry.count(@unit_registry) == 0 and
        directory_states == List.duplicate(:not_found, length(unit_ids)) and
          DynamicSupervisor.which_children(unit_supervisor) == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :native_cleanup_timeout}

      true ->
        Process.sleep(1)
        await_demo_native_cleanup!(directory, unit_supervisor, unit_ids, deadline)
    end
  end

  defp stop_genserver!(pid) do
    if Process.alive?(pid), do: :ok = GenServer.stop(pid, :normal, 5_000)
    true = not Process.alive?(pid)
    :ok
  end

  defp stop_infrastructure!(supervisor) do
    child_pids =
      Supervisor.which_children(supervisor)
      |> Enum.map(fn {_, pid, _, _} -> pid end)
      |> Enum.filter(&is_pid/1)

    if Process.alive?(supervisor), do: :ok = Supervisor.stop(supervisor, :normal, 15_000)
    true = not Process.alive?(supervisor)
    true = Enum.all?(child_pids, &(not Process.alive?(&1)))
    true = is_nil(Process.whereis(@engine_registry))
    true = is_nil(Process.whereis(@unit_registry))
    true = is_nil(Process.whereis(@unit_supervisor))
    true = is_nil(Process.whereis(@task_supervisor))
    :ok
  end
end

Elzoo.Wave4ChannelDemo.run!()
