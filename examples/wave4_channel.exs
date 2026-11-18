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
    prefix = "wave4_channel_demo_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    try do
      create_schema!(Repo, prefix)
      migrate_schema!(Repo, prefix)

      case run_owned_services(Repo, prefix) do
        {:ok, :complete} ->
          drop_schema!(Repo, prefix)
          :ok

        {:error, _reason} ->
          drop_schema!(Repo, prefix)
          raise "Wave 4 demo failed; database configuration is not displayed"
      end
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

  defp migrate_schema!(repo, prefix) do
    try do
      :ok = Ecto.Migrator.up(Repo, 1, Migration, prefix: prefix, log: false)
    rescue
      error ->
        drop_schema!(repo, prefix)
        reraise error, __STACKTRACE__
    end
  end

  defp drop_schema!(repo, prefix) do
    SQL.query!(repo, "DROP SCHEMA #{Postgres.identifier(prefix)} CASCADE", [], log: false)

    {:ok, result} =
      SQL.query(repo, "SELECT count(*) FROM pg_namespace WHERE nspname = $1", [prefix], log: false)

    true = result.rows == [[0]]
    :ok
  end

  defp run_owned_services(repo, prefix) do
    with {:ok, resources} <- build_services(repo, prefix),
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

  defp build_services(repo, prefix) do
    profile = %{
      tenant: "wave4-demo-tenant",
      actor: "wave4-demo-actor",
      source_id: "wave4-demo-source",
      conversation_id: "wave4-demo-conversation",
      deadline_ms: System.system_time(:millisecond) + @deadline_ms,
      native_target: Elzoo.Wave4ChannelExample.NativeBindings.target()
    }

    run_store =
      Postgres.store(repo,
        prefix: prefix,
        fold: RunApprovalRelease.fold(),
        limits: RunApprovalRelease.limits()
      )

    {:ok, lease} = Lease.new(store: run_store, clock: :store)
    {:held, held} = Lease.claim(lease, @lease_stream, @lease_owner, @lease_ttl_ms)

    command_store =
      Postgres.store(repo, prefix: prefix, fold: command_fold(), limits: command_limits())

    {:ok, handles} = Elzoo.Wave4ChannelExample.CommandBindings.build(command_store, gates())

    unit_options = [
      operator: {Elzoo.RunEngine, :step, %{version: 1, control: nil, slots: %{}, requests: %{}}},
      retention_count: 1_024,
      max_record_bytes: 16_777_216,
      max_checkpoint_bytes: 33_554_432
    ]

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
       signing_key: :crypto.strong_rand_bytes(32),
       command_store: command_store,
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
      supervisor: @unit_supervisor,
      task_supervisor: @task_supervisor,
      unit_store: resources.unit_store,
      evidence_store: resources.evidence_store,
      engine: Elzoo.Wave4ChannelExample.NativeBindings.build(resources.profile)
    }

    options = [
      profile: resources.profile,
      bindings: [trigger_binding(resources.profile)],
      command_store: resources.command_store,
      handles: resources.handles,
      native: native,
      authority: fn _mode, _event, _request, _facts -> %{} end,
      policy: fn _mode, _event, _at -> channel_policy() end,
      clock: fn -> System.system_time(:millisecond) end
    ]

    case Elzoo.Wave4ChannelExample.start_link(options) do
      {:ok, host} ->
        Process.unlink(host)

        try do
          run_with_listener(host, resources)
        after
          stop_host!(host, infrastructure)
        end

      {:error, _} ->
        {:error, :host}
    end
  end

  defp run_with_listener(host, resources) do
    case start_listener(host, resources.profile, resources.signing_key) do
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

  defp command_fold do
    %{
      initial: %{},
      kinds: %{"checked_command" => :state_bearing},
      versions: [1],
      destinations: ["wave4-channel-input"],
      reduce: fn model, _, _, _ -> model end
    }
  end

  defp command_limits,
    do: %{max_record_bytes: 1_048_576, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}

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

  defp gates do
    %{
      input: fn _, _ -> :allow end,
      association: fn _, _ -> :allow end,
      answer: fn _, _ -> :allow end
    }
  end

  defp channel_policy do
    artifact = %{
      id: "wave4-demo-channel-policy",
      version: 1,
      effect_classes: ["conversation.write"],
      rules: [%{id: "wave4-demo-allow", effect_class: "conversation.write", verdict: :allow}]
    }

    Map.put(
      artifact,
      :content_hash,
      :crypto.hash(:sha256, :erlang.term_to_binary(artifact, [:deterministic]))
    )
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
      "target" => Elzoo.Wave4ChannelExample.NativeBindings.target()
    }
  end

  defp start_listener(host, profile, signing_key) do
    ref = make_ref()
    scope = scope(profile)

    webhook = [
      source_id: profile.source_id,
      key: fn -> {:ok, signing_key} end,
      clock: fn -> System.system_time(:second) end,
      principal: fn _conn -> {:ok, scope} end,
      admit: fn event, trusted_scope ->
        Elzoo.Wave4ChannelExample.admit(host, event, trusted_scope)
      end
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
      _ -> {:error, :demo_failed}
    catch
      _, _ -> {:error, :demo_failed}
    end
  end

  defp stop_host!(host, infrastructure) do
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
    [] = DynamicSupervisor.which_children(unit_supervisor)
    [] = Task.Supervisor.children(task_supervisor)
    0 = Registry.count(@engine_registry)
    0 = Registry.count(@unit_registry)
    true = Process.alive?(infrastructure)
    :ok
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
