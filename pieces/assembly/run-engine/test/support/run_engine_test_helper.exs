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

  def fixture(overrides \\ []) do
    prefix = "engine_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    Ecto.Adapters.SQL.query!(TestRepo, "CREATE SCHEMA #{Postgres.identifier(prefix)}", [],
      log: false
    )

    :ok = Ecto.Migrator.up(TestRepo, 1, TestMigration, prefix: prefix, log: false)
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
      operator: {RunEngine, :step, %{version: 1, control: nil, slots: %{}, requests: %{}}},
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

    store =
      PostgresHarness.attach(
        TestRepo,
        prefix,
        DurableUnit.fold(unit_opts),
        DurableUnit.limits(unit_opts),
        controller
      )

    unit_opts = Keyword.put(unit_opts, :store, store)

    directory =
      ExUnit.Callbacks.start_supervised!(
        {DynamicUnits,
         registry: Elzoo.RunEngine.UnitRegistry,
         supervisor: supervisor,
         idle_ms: 60_000,
         unit_options: fn _ -> unit_opts end},
        id: make_ref()
      )

    run_store = Postgres.store(TestRepo, prefix: prefix, fold: Run.fold(), limits: Run.limits())
    {:ok, lease} = Lease.new(store: run_store, clock: :store)
    {:held, held} = Lease.claim(lease, "runs", "owner", 3_600_000)

    intent_store =
      Postgres.store(TestRepo,
        prefix: prefix,
        fold: Elzoo.EffectIntent.fold(TestBinding),
        limits: Elzoo.EffectIntent.limits()
      )

    host_store =
      Postgres.store(TestRepo, prefix: prefix, fold: StoreHost.fold(), limits: StoreHost.limits())

    host_mode = ExUnit.Callbacks.start_supervised!({Agent, fn -> :fresh end}, id: make_ref())

    intents = %{
      "effect" => [
        binding: TestBinding,
        store: intent_store,
        clock: now,
        host:
          {StoreHost,
           %{
             store: host_store,
             authorize: fn _, generation ->
               case Agent.get(host_mode, & &1) do
                 :fresh -> :fresh
                 :recover -> {:recovered, generation}
                 :read_only -> :refused
               end
             end
           }},
        task_supervisor: task_supervisor,
        adapter_context: self()
      ]
    }

    {:ok, run} = Run.start_link(store: run_store, lease: lease, held: held, effect_intent: intents)
    Process.unlink(run)

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

    opts = Keyword.merge(opts, overrides)

    c = %{
      opts: opts,
      prefix: prefix,
      controller: controller,
      clock: clock,
      context: context_agent,
      directory: directory,
      unit_opts: unit_opts,
      store: store,
      run: run,
      evidence: evidence,
      host_mode: host_mode,
      supervisor: supervisor
    }

    ExUnit.Callbacks.on_exit(fn ->
      for pid <- [run, evidence], Process.alive?(pid), do: GenServer.stop(pid)

      Ecto.Adapters.SQL.query!(
        TestRepo,
        "DROP SCHEMA IF EXISTS #{Postgres.identifier(prefix)} CASCADE",
        [],
        log: false
      )
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

  def request(actions), do: %{"type" => "request", "version" => 1, "actions" => actions}

  def start_input,
    do: %{
      "type" => "input",
      "version" => 1,
      "kind" => "start",
      "schema_id" => "message",
      "schema_version" => 1,
      "payload" => %{}
    }

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

  def resource(c, pause_policy \\ :stay) do
    fold = %{
      initial: nil,
      versions: [1],
      destinations: [],
      kinds: Map.merge(%{"run_resource_state" => :state_bearing}, Lease.kinds()),
      reduce: fn _, _, _, payload -> payload end
    }

    limits = %{max_record_bytes: 1_048_576, max_batch_size: 4, max_checkpoint_bytes: 2_097_152}
    store = Postgres.store(TestRepo, prefix: c.prefix, fold: fold, limits: limits)
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
      budget: %{budget_id: "budget", unit: "credits", cost_ref: "1:0", generation: {"sealed", 1}},
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
end
