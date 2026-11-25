# SPDX-License-Identifier: Apache-2.0
sql_helper = Path.expand("durable_log_postgres_test_helper.exs", __DIR__)

sql_helper =
  if File.regular?(sql_helper),
    do: sql_helper,
    else:
      Path.expand(
        "../../../../integration/sql/test/support/durable_log_postgres_test_helper.exs",
        __DIR__
      )

Code.require_file(sql_helper)

defmodule Elzoo.RunEngine.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.RunEngine.TestPattern do
  def step(%{requests: [request | rest]} = state, _input),
    do: {:Transition, %{state | requests: rest}, {:some, request}}

  def step(%{requests: []} = state, _input), do: {:Transition, state, :none}

  # Scripted callable: every input is sent to the test process registered as
  # :run_engine_observer (a counting pattern); each input answers with the next
  # scripted request. {:finish_with_seen, id} finishes with the payload it saw; {:finish_sized, id, n} with a payload of n filler bytes.
  def scripted(%{name: name, script: script} = state, input) do
    if observer = Process.whereis(:run_engine_observer),
      do: send(observer, {:pattern_input, name, input})

    case script do
      [] ->
        {:Transition, state, :none}

      [{:finish_with_seen, id} | rest] ->
        scripted_finish(state, rest, id, %{"seen" => input["payload"]})

      [{:finish_sized, id, size} | rest] ->
        scripted_finish(state, rest, id, %{"x" => String.duplicate("x", size)})

      [request | rest] ->
        {:Transition, %{state | script: rest}, {:some, request}}
    end
  end

  defp scripted_finish(state, rest, id, payload) do
    action = %{
      "id" => id,
      "kind" => "finish",
      "schema_id" => "result",
      "schema_version" => 1,
      "payload" => payload
    }

    {:Transition, %{state | script: rest},
     {:some, %{"type" => "request", "version" => 1, "actions" => [action]}}}
  end

  # As scripted/2, with more script elements. :wait takes one input and answers
  # nothing (a child that waits for its next outcome). {:tool_finish, tool_id, id, tag}
  # asks a tool call and a finish of 65,536 JSON bytes in one request;
  # {:finish_tagged, id, tag} a finish of that size alone; {:finish_with, id, payload} a finish with the given payload. The payloads are built here, so
  # that the script (the initial state of the callable) stays small.
  def waiting(%{script: [:wait | rest]} = state, input) do
    if observer = Process.whereis(:run_engine_observer),
      do: send(observer, {:pattern_input, state.name, input})

    {:Transition, %{state | script: rest}, :none}
  end

  def waiting(%{script: [{:tool_finish, tool_id, id, tag} | rest]} = state, input) do
    if observer = Process.whereis(:run_engine_observer),
      do: send(observer, {:pattern_input, state.name, input})

    tool = %{
      "id" => tool_id,
      "kind" => "tool_call",
      "schema_id" => "action",
      "schema_version" => 1,
      "payload" => %{"value" => 7}
    }

    {:Transition, %{state | script: rest},
     {:some, %{"type" => "request", "version" => 1, "actions" => [tool, sized_finish(id, tag)]}}}
  end

  def waiting(%{script: [{:finish_tagged, id, tag} | rest]} = state, input) do
    if observer = Process.whereis(:run_engine_observer),
      do: send(observer, {:pattern_input, state.name, input})

    {:Transition, %{state | script: rest},
     {:some, %{"type" => "request", "version" => 1, "actions" => [sized_finish(id, tag)]}}}
  end

  def waiting(%{script: [{:finish_with, id, payload} | rest]} = state, input) do
    if observer = Process.whereis(:run_engine_observer),
      do: send(observer, {:pattern_input, state.name, input})

    action = %{
      "id" => id,
      "kind" => "finish",
      "schema_id" => "result",
      "schema_version" => 1,
      "payload" => payload
    }

    {:Transition, %{state | script: rest},
     {:some, %{"type" => "request", "version" => 1, "actions" => [action]}}}
  end

  # {:grow, size}: takes one input and returns a state of exactly `size` encoded bytes (a :pad).
  def waiting(%{script: [{:grow, size} | rest]} = state, input) do
    if observer = Process.whereis(:run_engine_observer),
      do: send(observer, {:pattern_input, state.name, input})

    state2 = %{state | script: rest}

    base =
      byte_size(
        :erlang.term_to_binary(Map.put(state2, :pad, ""), [:deterministic, {:minor_version, 2}])
      )

    {:Transition, Map.put(state2, :pad, :binary.copy("p", size - base)), :none}
  end

  def waiting(state, input), do: scripted(state, input)

  # A finish whose payload is 65,536 bytes of JSON and names `tag`.
  def sized_payload(tag),
    do: %{"x" => String.pad_leading("#{tag}", 16, "0") <> String.duplicate("x", 65_528 - 16)}

  defp sized_finish(id, tag) do
    %{
      "id" => id,
      "kind" => "finish",
      "schema_id" => "result",
      "schema_version" => 1,
      "payload" => sized_payload(tag)
    }
  end

  def resource_step({:open, request}, _), do: {:Transition, :waiting, {:some, request}}

  def resource_step(:waiting, %{"kind" => "resource_event"}),
    do: {:Transition, :done, {:some, :invalid}}

  def resource_step(state, _), do: {:Transition, state, :none}

  def sized(:done, _), do: {:Transition, :done, :none}

  def sized({kind, size}, _) do
    payload = %{
      "x" =>
        case kind do
          :text -> String.duplicate("x", size)
          :depth -> Enum.reduce(1..size, true, fn _, nested -> %{"x" => nested} end)
          :request -> String.duplicate("x", size)
          :floats -> List.duplicate(0.1, size)
        end
    }

    action = %{
      "id" => "sized",
      "kind" => "local_work",
      "schema_id" => "action",
      "schema_version" => 1,
      "payload" => payload
    }

    actions =
      if kind == :request, do: for(n <- 0..63, do: Map.put(action, "id", "a#{n}")), else: [action]

    {:Transition, :done, {:some, %{"type" => "request", "version" => 1, "actions" => actions}}}
  end

  def chain(n, _input) do
    request = %{
      "type" => "request",
      "version" => 1,
      "actions" =>
        for index <- 0..1 do
          %{
            "id" => "chain-#{n}-#{index}",
            "kind" => "local_work",
            "schema_id" => "action",
            "schema_version" => 1,
            "payload" => %{"value" => index}
          }
        end
    }

    {:Transition, n + 1, {:some, request}}
  end

  def batches({batch, remaining}, input) do
    if input["kind"] == "start" or remaining == 1 do
      actions =
        for n <- 0..63,
            do: %{
              "id" => "#{batch}-#{n}",
              "kind" => "local_work",
              "schema_id" => "action",
              "schema_version" => 1,
              "payload" => %{}
            }

      {:Transition, {batch + 1, 64},
       {:some, %{"type" => "request", "version" => 1, "actions" => actions}}}
    else
      {:Transition, {batch, remaining - 1}, :none}
    end
  end

  def work(payload), do: payload

  def oversized_id(size, _) do
    request =
      Elzoo.RunEngine.TestHelper.request([
        Elzoo.RunEngine.TestHelper.action(String.duplicate("i", size))
      ])

    {:Transition, size, {:some, request}}
  end

  def blocked(parent, payload) do
    send(parent, {:local_started, self()})
    receive do: (:finish -> payload)
  end
end

defmodule Elzoo.RunEngine.TestAdapter do
  def failure_tags, do: [:timeout]
  def schema, do: "effect-v1"
  def validate(_, _), do: :ok
  def authenticate(_, _), do: :ok
  def validate_result(_, _), do: :ok
  def poll(_), do: {:unavailable, "trusted"}

  def send_effect(request) do
    send(request.context, {:effect_started, self(), request})

    receive do
      {:result, value} ->
        %{
          "version" => 1,
          "message_id" => request.key,
          "correlation_id" => request.key,
          "attempt_id" => request.attempt_id,
          "outcome" => "completed",
          "dispatch" => "dispatched",
          "value" => value,
          "value_schema_id" => "result",
          "value_schema_version" => 1
        }

      :unknown ->
        {:error, :timeout, :unavailable}
    end
  end
end

defmodule Elzoo.RunEngine.TestBinding do
  use Elzoo.EffectIntent.Binding,
    adapter: Elzoo.RunEngine.TestAdapter,
    id: "effect",
    provider_account: "account",
    operation: "publish",
    clock: "unix-ms",
    failures: %{timeout: {"timed_out", "unknown", "unavailable"}}
end

defmodule Elzoo.RunEngine.ChangedAccountBinding do
  use Elzoo.EffectIntent.Binding,
    adapter: Elzoo.RunEngine.TestAdapter,
    id: "effect",
    provider_account: "changed-account",
    operation: "publish",
    clock: "unix-ms",
    failures: %{timeout: {"timed_out", "unknown", "unavailable"}}
end

defmodule Elzoo.RunEngine.ChangedRevisionBinding do
  use Elzoo.EffectIntent.Binding,
    adapter: Elzoo.RunEngine.TestAdapter,
    id: "effect",
    provider_account: "account",
    operation: "publish",
    clock: "unix-ms",
    revision: :same_key_changed_arguments,
    failures: %{timeout: {"timed_out", "unknown", "unavailable"}}
end

defmodule Elzoo.RunEngine.TestHelper do
  import ExUnit.Assertions
  alias Elzoo.{DurableUnit, DynamicUnits, Lease, PayloadSchema, RunEngine}
  alias Elzoo.RunApprovalRelease, as: Run
  alias Elzoo.DurableLog.{Postgres, PostgresHarness, TestMigration, Writer}
  alias Elzoo.RunEngine.{TestRepo, TestPattern, TestBinding}
  alias Elzoo.EffectIntent.{Binding, StoreHost}

  def database do
    {:ok, pid} =
      TestRepo.start_link(url: PostgresHarness.database_url!(), pool_size: 12, log: false)

    Process.unlink(pid)
    PostgresHarness.reachable!(TestRepo)
    pid
  end

  def fixture(overrides \\ [], recovery \\ []) do
    reopen_prefix = recovery[:prefix]
    {effect_bindings, overrides} = Keyword.pop(overrides, :effect_bindings, %{})
    {unit_store, overrides} = Keyword.pop(overrides, :unit_store)
    # The schema and its migration stay on TestRepo (the owner). The runtime Store calls use
    # `store_repo` when the caller supplies one, such as an application-role connection;
    # `grant` runs on the new schema after the migration, before the first Store call.
    {repo, overrides} = Keyword.pop(overrides, :store_repo, TestRepo)
    {grant, overrides} = Keyword.pop(overrides, :grant, fn _prefix -> :ok end)
    protocol_version_set? = Keyword.has_key?(overrides, :protocol_version)
    {protocol_version, overrides} = Keyword.pop(overrides, :protocol_version, 1)
    event_source_set? = Keyword.has_key?(overrides, :event_source)
    {event_source, overrides} = Keyword.pop(overrides, :event_source)

    event_source =
      if not event_source_set? and protocol_version == 2 do
        %{
          id: "events",
          version: 1,
          head: fn _ -> {:ok, %{revision: 0, low_water: 0}} end,
          read: fn _, _ -> {:error, :not_found} end
        }
      else
        event_source
      end

    unit_version = if protocol_version == 2, do: 2, else: 1
    prefix = reopen_prefix || "engine_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    unless reopen_prefix do
      Ecto.Adapters.SQL.query!(TestRepo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [],
        log: false
      )

      # Registered first, so it runs last (after the process shutdown below) and also when a later
      # setup step (the migration, the grant, the first append) fails.
      ExUnit.Callbacks.on_exit(fn ->
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "DROP SCHEMA IF EXISTS #{Postgres.identifier(prefix)} CASCADE",
          [],
          log: false
        )
      end)

      :ok = Ecto.Migrator.up(TestRepo, 1, TestMigration, prefix: prefix, log: false)
      :ok = grant.(prefix)
    end

    controller = ExUnit.Callbacks.start_supervised!({PostgresHarness, []}, id: make_ref())
    clock = ExUnit.Callbacks.start_supervised!({Agent, fn -> 2_000 end}, id: make_ref())
    now = fn -> Agent.get(clock, & &1) end
    name = {:via, Registry, {Elzoo.RunEngine.TestRegistry, prefix}}

    supervisor =
      ExUnit.Callbacks.start_supervised!(
        {DynamicSupervisor, strategy: :one_for_one, max_children: 2},
        id: make_ref()
      )

    task_supervisor = ExUnit.Callbacks.start_supervised!({Task.Supervisor, []}, id: make_ref())

    async =
      ExUnit.Callbacks.start_supervised!(
        {Elzoo.AsyncWork, owner: name, task_supervisor: task_supervisor, max_concurrency: 4},
        id: make_ref()
      )

    unit_opts = [
      operator:
        {RunEngine, :step, %{version: unit_version, control: nil, slots: %{}, requests: %{}}},
      retention_count: 1_024,
      max_record_bytes: 16_777_216,
      max_checkpoint_bytes: 33_554_432,
      offer: fn item ->
        case Registry.lookup(Elzoo.RunEngine.TestRegistry, prefix) do
          [{pid, _}] -> send(pid, item)
          [] -> :ok
        end

        :ok
      end
    ]

    postgres_unit_store =
      PostgresHarness.attach(
        repo,
        prefix,
        DurableUnit.fold(unit_opts),
        DurableUnit.limits(unit_opts),
        controller
      )

    store = unit_store || postgres_unit_store

    unit_opts = Keyword.put(unit_opts, :store, store)

    directory =
      ExUnit.Callbacks.start_supervised!(
        {DynamicUnits,
         registry: Elzoo.RunEngine.UnitRegistry,
         supervisor: supervisor,
         idle_ms: 60_000,
         unit_options: fn identity ->
           if audit = recovery[:audit], do: audit.(store, identity)
           unit_opts
         end},
        id: make_ref()
      )

    run_store = Postgres.store(repo, prefix: prefix, fold: Run.fold(), limits: Run.limits())
    {:ok, lease} = Lease.new(store: run_store, clock: :store)

    {:held, held} =
      if reopen_prefix,
        do: Lease.hold(lease, "runs", "owner"),
        else: Lease.claim(lease, "runs", "owner", 3_600_000)

    host_store =
      Postgres.store(repo, prefix: prefix, fold: StoreHost.fold(), limits: StoreHost.limits())

    host_mode = ExUnit.Callbacks.start_supervised!({Agent, fn -> :fresh end}, id: make_ref())

    # Not under the test supervisor: it outlives it, so the teardown can still read
    # the intents that the engine started and unlinked.
    {:ok, intent_pids} = Agent.start_link(fn -> MapSet.new() end)
    Process.unlink(intent_pids)

    startup = fn module, adapter_context ->
      [
        binding: module,
        store:
          Postgres.store(repo,
            prefix: prefix,
            fold: Elzoo.EffectIntent.fold(module),
            limits: Elzoo.EffectIntent.limits()
          ),
        clock: now,
        host:
          {StoreHost,
           %{
             store: host_store,
             authorize: fn _, generation ->
               # Runs inside the intent process, in its init.
               intent = self()
               Agent.update(intent_pids, &MapSet.put(&1, intent))

               case Agent.get(host_mode, & &1) do
                 :fresh -> :fresh
                 :recover -> {:recovered, generation}
                 :read_only -> :refused
               end
             end
           }},
        task_supervisor: task_supervisor,
        adapter_context: adapter_context
      ]
    end

    intents =
      %{"effect" => {TestBinding, self()}}
      |> Map.merge(effect_bindings)
      |> Map.new(fn {ref, {module, adapter_context}} ->
        {ref, startup.(module, adapter_context)}
      end)

    {:ok, run} = Run.start_link(store: run_store, lease: lease, held: held, effect_intent: intents)
    Process.unlink(run)

    unless reopen_prefix do
      assert {:ok, revision, _} =
               Run.command(run, %{
                 kind: :create,
                 run_id: "run",
                 operation_id: "operation",
                 provider_refs: %{},
                 expected_revision: held.live.revision
               })

      assert {:ok, _, _} =
               Run.command(run, %{
                 kind: :begin_attempt,
                 run_id: "run",
                 attempt_id: "attempt",
                 expected_revision: revision
               })
    end

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
      Postgres.store(repo, prefix: prefix, fold: evidence_fold, limits: evidence_limits)

    {:ok, evidence} =
      Writer.start_link(
        store: evidence_store,
        stream: "evidence",
        fold: evidence_fold,
        limits: evidence_limits
      )

    Process.unlink(evidence)

    schemas =
      Map.new(
        [
          {"action", %{"type" => "object"}},
          {"result", %{}},
          {"message", %{}},
          {"elzoo.run-resource.action", %{"type" => "object"}},
          {"elzoo.run-resource.result", %{"type" => "object"}},
          {"elzoo.run-engine.refusal", %{"type" => "object"}}
        ],
        fn {id, schema} ->
          port = %{"id" => id, "direction" => "input", "schema_id" => id, "schema_version" => 1}
          {:ok, compiled} = PayloadSchema.build(port, schema)

          {{id, 1},
           %{port: port, compiled: compiled, digest: :crypto.hash(:sha256, Jason.encode!(schema))}}
        end
      )

    writes = [%{target: "document", field: "published", value: true}]

    policy = %{
      id: "policy",
      version: 1,
      content_hash: <<0::256>>,
      effect_classes: ["compute", "publish"],
      rules: [
        %{id: "compute", effect_class: "compute", verdict: :allow},
        %{id: "publish", effect_class: "publish", verdict: :allow}
      ]
    }

    context_agent =
      ExUnit.Callbacks.start_supervised!(
        {Agent,
         fn ->
           %{
             policy: policy,
             authority: writes,
             resource_names: ["document"],
             pause_deadline: 50_000
           }
         end},
        id: make_ref()
      )

    context = fn -> Agent.get(context_agent, & &1) end
    {:ok, binding} = Binding.load(TestBinding)

    facts = fn action ->
      %{
        estimate: 1,
        unit: "credits",
        deadline_ms: 40_000,
        intent: %{
          identity: ["tenant", "account", "effect", "publish", action["id"]],
          arguments: Jason.encode!(action["payload"]),
          binding: "effect",
          binding_digest: binding.digest,
          deadline_ms: 40_000
        }
      }
    end

    proposal = fn action ->
      %{
        tenant: "tenant",
        resource: "document",
        action_id: action["id"],
        payload: {:text, "publish"},
        writes: writes
      }
    end

    base = %{
      id: "binding",
      version: 1,
      effect_class: "compute",
      facts: facts,
      proposal: proposal,
      result: {"result", 1}
    }

    computation = Map.put(base, :facts, fn a -> Map.delete(facts.(a), :intent) end)
    local = Map.put(computation, :work, fn action -> {TestPattern, :work, [action["payload"]]} end)
    person = Map.put(computation, :person, fn _ -> "person" end)

    nested =
      Map.put(computation, :nested, fn action ->
        %{
          budget_id: "nested-" <> action["id"],
          incarnation: "sealed",
          mfa: {TestPattern, :step},
          initial_state: %{requests: []},
          schema_id: "message",
          schema_version: 1,
          payload: action["payload"]
        }
      end)

    bindings = %{
      "local_work" => local,
      "ask_person" => person,
      "finish" => computation,
      "nested_callable" => nested,
      "tool_call" => %{base | effect_class: "publish"},
      "model_call" => %{base | effect_class: "publish"}
    }

    bindings =
      if protocol_version == 2,
        do: Map.put(bindings, "wait_event", computation),
        else: bindings

    opts = [
      name: name,
      identity: prefix,
      directory: directory,
      store: store,
      run_owner: run,
      run_id: "run",
      tenant: "tenant",
      principal: "principal",
      pattern: {TestPattern, :step, %{requests: []}},
      schemas: schemas,
      gate: %{id: "gate", version: 1, call: fn _, _ -> :allow end},
      clock: now,
      bindings: bindings,
      context: context,
      async_work: async,
      resources: %{},
      effect_intent: intents,
      request_cap: 20,
      budget: %{cap: 100, unit: "credits", id: "budget", incarnation: "sealed"},
      budget_rule: :finish,
      run_deadline: 60_000,
      evidence: %{writer: evidence, stream: "evidence"}
    ]

    version_opts =
      if protocol_version_set? or protocol_version == 2,
        do: [protocol_version: protocol_version],
        else: []

    source_opts =
      if event_source_set? or protocol_version == 2, do: [event_source: event_source], else: []

    reader_opts =
      if protocol_version == 2,
        do: [result_reader: %{evidence_store: evidence_store, retention_count: 1_024}],
        else: []

    opts = Keyword.merge(opts, version_opts ++ source_opts ++ reader_opts ++ overrides)

    c = %{
      opts: opts,
      prefix: prefix,
      repo: repo,
      controller: controller,
      clock: clock,
      context: context_agent,
      directory: directory,
      unit_opts: unit_opts,
      store: store,
      run: run,
      run_store: run_store,
      lease: lease,
      held: held,
      task_supervisor: task_supervisor,
      async: async,
      evidence: evidence,
      evidence_store: evidence_store,
      postgres_unit_store: postgres_unit_store,
      host_mode: host_mode,
      supervisor: supervisor
    }

    ExUnit.Callbacks.on_exit(fn ->
      for pid <- [run, evidence], Process.alive?(pid), do: GenServer.stop(pid)

      # The engine unlinks its intents and has no terminate, so they outlive the test
      # supervisor and can still append. Stop them before the schema goes.
      for pid <- Agent.get(intent_pids, &MapSet.to_list/1), Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      Agent.stop(intent_pids)
    end)

    c
  end

  def start(c, overrides \\ []) do
    ExUnit.Callbacks.start_supervised!(%{
      id: make_ref(),
      restart: :temporary,
      start: {RunEngine, :start_link, [Keyword.merge(c.opts, overrides)]}
    })
  end

  def action(id, kind \\ "local_work", payload \\ %{"value" => 7}),
    do: %{
      "id" => id,
      "kind" => kind,
      "schema_id" =>
        if(String.starts_with?(kind, "resource_"), do: "elzoo.run-resource.action", else: "action"),
      "schema_version" => 1,
      "payload" => payload
    }

  def finish_action(id, payload \\ %{"value" => 7}, schema_id \\ "result", version \\ 1),
    do: %{action(id, "finish", payload) | "schema_id" => schema_id, "schema_version" => version}

  # Root asks one nested_callable "nested"; `children` maps each nested action id
  # to the script of its callable. Registers the test process as the observer.
  def nested_setup(children, overrides \\ []) do
    Process.register(self(), :run_engine_observer)
    root = [request([action("nested", "nested_callable")])]

    c =
      fixture(
        Keyword.merge([pattern: {TestPattern, :scripted, %{name: "root", script: root}}], overrides)
      )

    base = c.opts[:bindings]["nested_callable"]

    nested = %{
      base
      | facts: fn a -> %{base.facts.(a) | estimate: 10} end,
        nested: fn a ->
          %{
            base.nested.(a)
            | mfa: {TestPattern, :scripted},
              initial_state: %{name: a["id"], script: Map.fetch!(children, a["id"])}
          }
        end
    }

    {c, Map.put(c.opts[:bindings], "nested_callable", nested)}
  end

  def request(actions), do: %{"type" => "request", "version" => 1, "actions" => actions}
  def request_v2(actions), do: %{"type" => "request", "version" => 2, "actions" => actions}

  def start_input,
    do: %{
      "type" => "input",
      "version" => 1,
      "kind" => "start",
      "schema_id" => "message",
      "schema_version" => 1,
      "payload" => %{}
    }

  def start_input_v2, do: Map.put(start_input(), "version", 2)

  def wake, do: %{"type" => "input", "version" => 1, "kind" => "wake"}

  def result(id, payload \\ %{"accepted" => true}),
    do: %{
      "type" => "input",
      "version" => 1,
      "kind" => "action_outcome",
      "action_id" => id,
      "outcome" => "completed",
      "schema_id" => "result",
      "schema_version" => 1,
      "payload" => payload
    }

  def verified(fields \\ %{}),
    do: Map.merge(%{run_id: "run", attempt_id: "attempt", pause_deadline: 50_000}, fields)

  def send_input(engine, id \\ "start") do
    RunEngine.input(engine, id, start_input(), verified())
  end

  def view(engine) do
    {:ok, view} = RunEngine.status(engine)
    view
  end

  def wait_for(engine, predicate, left \\ 200)

  def wait_for(engine, _, 0),
    do: flunk("engine did not reach expected committed state: #{inspect(view(engine))}")

  def wait_for(engine, predicate, left) do
    view = view(engine)

    if predicate.(view),
      do: view,
      else:
        (
          Process.sleep(5)
          wait_for(engine, predicate, left - 1)
        )
  end

  def rows(c) do
    {:ok, rows, _} = Elzoo.DurableLog.read(c.store, c.prefix, 1, 1_000)
    rows
  end

  def require_approval(c) do
    Agent.update(c.context, fn ctx ->
      policy = %{
        ctx.policy
        | rules: [
            hd(ctx.policy.rules),
            %{
              id: "publish",
              effect_class: "publish",
              verdict: :ask,
              requirement: %{name: "human", version: 1, scope: :once}
            }
          ]
      }

      Map.merge(ctx, %{
        policy: policy,
        max_age: 10_000,
        verifiers: ["verifier"],
        run: %{id: "run", root: "run", ancestry: []},
        approver: %{identity: "reviewer", authority: ctx.authority}
      })
    end)
  end

  def consent(key),
    do: %{
      verifier: "verifier",
      evidence_id: "consent",
      reviewer: "reviewer",
      request: key,
      decision: :approve,
      scope: :once,
      issued_at: 1_000,
      expiry: 20_000
    }

  def resource(c, pause_policy \\ :stay, budget \\ nil) do
    fold = %{
      initial: nil,
      versions: [1],
      destinations: [],
      kinds: Map.merge(%{"run_resource_state" => :state_bearing}, Lease.kinds()),
      reduce: fn _, _, _, payload -> payload end
    }

    limits = %{max_record_bytes: 1_048_576, max_batch_size: 4, max_checkpoint_bytes: 2_097_152}
    store = Postgres.store(c.repo, prefix: c.prefix, fold: fold, limits: limits)
    {:ok, lease} = Lease.new(store: store, clock: :store)
    {:held, held} = Lease.claim(lease, "resource", "resource-owner", 3_600_000)
    {:ok, binding} = Binding.load(TestBinding)

    cleanup = %{
      identity: ["tenant", "account", "effect", "publish", "cleanup"],
      arguments: Jason.encode!(%{"operation" => "resource_close"}),
      binding: "effect",
      binding_digest: binding.digest,
      deadline_ms: 55_000
    }

    resource = %{
      run_id: "run",
      name: "document",
      deadline_ms: 40_000,
      rate_per_minute: 1,
      max_waiting: 2,
      pause_policy: pause_policy,
      budget:
        budget ||
          %{budget_id: "budget", unit: "credits", cost_ref: "1:0", generation: {"sealed", 1}},
      close_intent: cleanup
    }

    owner =
      ExUnit.Callbacks.start_supervised!(%{
        id: make_ref(),
        restart: :temporary,
        start:
          {Elzoo.RunResource, :start_link,
           [%{lease: lease, held: held, clock: c.opts[:clock], resource: resource}]}
      })

    bindings =
      Map.new(["resource_open", "resource_use", "resource_close"], fn kind ->
        base = c.opts[:bindings]["tool_call"]

        facts = fn action ->
          result = base.facts.(action) |> Map.put(:resource_name, "document")
          if kind == "resource_close", do: Map.put(result, :intent, nil), else: result
        end

        {kind, Map.merge(base, %{facts: facts, result: {"elzoo.run-resource.result", 1}})}
      end)

    {owner, Map.merge(c.opts[:bindings], bindings)}
  end

  # ELZ-192: the bound of the control state, recomputed from a unit state alone and
  # without the engine's own functions. Returns the bytes that are left of 2,097,152
  # after the encoded control (with each admitted, not yet kept finish of a child
  # placed in it), the receipt reserve (1,024 for each receipt that can still come),
  # 4,096 for each active slot, and for each callable that is not closed the room that
  # is left of its state bound (`state_bytes`, 65,536 when absent) after its stored
  # state. A negative value is a broken bound.
  def control_headroom(state) do
    c = state.control

    placed =
      Enum.reduce(state.slots, c, fn {_, slot}, acc ->
        node = acc.callables[slot.callable]

        if slot.kind == "finish" and slot.callable != "root" and
             slot.phase in [:authorizing, :approval, :ready] and node.closed == false and
             is_nil(node[:finish]) do
          action = slot.action

          kept = %{
            schema_id: action["schema_id"],
            schema_version: action["schema_version"],
            payload: action["payload"]
          }

          put_in(acc.callables[slot.callable][:finish], kept)
        else
          acc
        end
      end)

    active =
      Enum.count(state.slots, fn {_, s} -> s.phase != :settled or s[:pending_input] != nil end)

    open_reserve =
      Enum.reduce(c.callables, 0, fn {_, node}, sum ->
        if node.closed,
          do: sum,
          else:
            sum +
              max(
                0,
                Map.get(node, :state_bytes, 65_536) -
                  byte_size(
                    :erlang.term_to_binary(node.state, [:deterministic, {:minor_version, 2}])
                  )
              )
      end)

    reserve = (c.cap + 1 - map_size(c.receipts)) * 1_024 + active * 4_096 + open_reserve

    2_097_152 -
      (byte_size(:erlang.term_to_binary(placed, [:deterministic, {:minor_version, 2}])) + reserve)
  end

  def protocol_record(id, input, opts \\ []) do
    %{
      version: 1,
      kind: :protocol,
      id: id,
      run_id: Keyword.get(opts, :run_id, "run"),
      attempt_id: Keyword.get(opts, :attempt_id, "attempt"),
      input: Map.put_new(input, "at_ms", 2_000),
      correlation: Keyword.get(opts, :correlation, %{}),
      context: Keyword.get(opts, :context, %{})
    }
  end

  def pad_invocations(state, target_headroom) do
    remaining = control_headroom(state) - target_headroom
    true = remaining == 0 or remaining >= 43
    padded = do_pad_invocations(state, remaining, map_size(state.control.invocations))
    ^target_headroom = control_headroom(padded)
    padded
  end

  defp do_pad_invocations(state, 0, _index), do: state

  defp do_pad_invocations(state, remaining, index) when remaining >= 8_142 do
    prefix = "pad-#{index}-"
    id = prefix <> String.duplicate("p", 8_000 - byte_size(prefix))
    next = put_in(state.control.invocations[id], :crypto.hash(:sha256, id))
    do_pad_invocations(next, remaining - 8_042, index + 1)
  end

  defp do_pad_invocations(state, remaining, index) do
    len = remaining - 42
    prefix = "pad-#{index}-"

    id =
      if len > byte_size(prefix),
        do: prefix <> String.duplicate("p", len - byte_size(prefix)),
        else: String.duplicate("p", len)

    put_in(state.control.invocations[id], :crypto.hash(:sha256, id))
  end
end
