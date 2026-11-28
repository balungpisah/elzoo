# SPDX-License-Identifier: Apache-2.0
# Shared fixture of the assembly/run-host tests. A copied consumer keeps every test
# support file in one directory, so a sibling file is used before the repository path.
support = fn file, piece ->
  sibling = Path.expand(file, __DIR__)

  if File.regular?(sibling),
    do: sibling,
    else: Path.expand("../../../../#{piece}/test/support/#{file}", __DIR__)
end

Code.require_file(support.("durable_log_postgres_test_helper.exs", "integration/sql"))
Code.require_file(support.("ai_text_anthropic_test_helper.exs", "integration/ai-text-anthropic"))

defmodule Elzoo.RunHost.TestRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.RunHost.TestBinding do
  use Elzoo.AiText.Binding,
    id: "run-host-test",
    provider_account: "anthropic:test-workspace",
    recovery_grace_ms: 60_000
end

defmodule Elzoo.RunHost.TestAgent do
  @moduledoc "The root callable of an AgentLoop Run: the agent loop with an estimate of one token per byte."
  def step(state, input), do: Elzoo.AgentLoop.step(state, input, &estimate/1)

  def estimate(bytes),
    do:
      {:ok,
       %{
         size: byte_size(bytes),
         unit: :tokens,
         direction: :upper_bound,
         estimator_id: "bytes",
         estimator_version: 1
       }}
end

defmodule Elzoo.RunHost.TestPattern do
  @moduledoc """
  Root callables of the tests. `step/2` asks its model calls in one request (with the
  state's `tools` declared, when it has any) and, once each has an outcome, finishes
  naming the first one. `starts/2` asks one model call `m<n>` for the n-th start it is
  given (each Attempt sends its own start).
  """
  def step(%{phase: :new, calls: calls} = state, %{"kind" => "start"}) do
    {:Transition, %{state | phase: :calls}, {:some, request(calls, Map.get(state, :tools))}}
  end

  def step(%{phase: :calls, calls: calls, seen: seen} = state, %{
        "kind" => "action_outcome",
        "action_id" => id
      }) do
    seen = Enum.uniq(seen ++ [id])

    if Enum.sort(seen) == Enum.sort(calls) do
      finish = %{
        "id" => "done",
        "kind" => "finish",
        "schema_id" => "result",
        "schema_version" => 1,
        "payload" => %{"action_id" => hd(calls)}
      }

      {:Transition, %{state | phase: :done, seen: seen},
       {:some, %{"type" => "request", "version" => 1, "actions" => [finish]}}}
    else
      {:Transition, %{state | seen: seen}, :none}
    end
  end

  def step(state, _), do: {:Transition, state, :none}

  def starts(%{n: n} = state, %{"kind" => "start"}),
    do: {:Transition, %{state | n: n + 1}, {:some, request(["m#{n + 1}"], nil)}}

  def starts(state, _), do: {:Transition, state, :none}

  defp request(calls, tools) do
    actions =
      for id <- calls do
        payload = %{
          "version" => 1,
          "model" => "claude-sonnet-4-5",
          "max_output_tokens" => 64,
          "messages" => [%{"role" => "user", "text" => "call " <> id}]
        }

        %{
          "id" => id,
          "kind" => "model_call",
          "schema_id" => "elzoo/ai-text-request",
          "schema_version" => 1,
          "payload" => if(tools, do: Map.put(payload, "tools", tools), else: payload)
        }
      end

    %{"type" => "request", "version" => 1, "actions" => actions}
  end
end

defmodule Elzoo.RunHost.TestHelper do
  import ExUnit.Assertions
  alias Elzoo.{DurableUnit, EffectIntent, Lease, PayloadSchema, RunEngine, RunHost}
  alias Elzoo.RunApprovalRelease, as: Owner
  alias Elzoo.DurableLog.{Memory, Postgres, PostgresHarness, TestMigration}
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.AiText.AnthropicStub
  alias Elzoo.RunHost.{TestAgent, TestBinding, TestPattern, TestRepo}

  @model "claude-sonnet-4-5"
  @limits %{max_records: 65_536, max_bytes: 536_870_912}
  @writes [%{target: "document", field: "published", value: true}]
  @unit_options [
    operator: {RunEngine, :step, %{version: 1, control: nil, slots: %{}, requests: %{}}},
    retention_count: 1_024
  ]
  @evidence_fold %{
    initial: nil,
    kinds: %{"completion" => :state_bearing},
    versions: [1],
    destinations: [],
    reduce: &__MODULE__.keep/4
  }
  @evidence_limits %{max_record_bytes: 131_072, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}

  def keep(_, _, _, bytes), do: bytes
  def limits, do: @limits
  def clock, do: System.os_time(:millisecond)

  ## Stores

  def database do
    {:ok, pid} =
      TestRepo.start_link(url: PostgresHarness.database_url!(), pool_size: 16, log: false)

    Process.unlink(pid)
    PostgresHarness.reachable!(TestRepo)
    pid
  end

  @doc """
  One disposable PostgreSQL schema with every Store view of the host and its Lease.
  `lease:` gives more Lease options (a `test_hook`); `harness: true` attaches the Unit
  view and the activation view each to a fault controller of its own.
  """
  def postgres(opts \\ []) do
    prefix = "runhost_" <> hex(6)
    sql!("CREATE SCHEMA #{Postgres.identifier(prefix)}")

    ExUnit.Callbacks.on_exit(fn ->
      sql!("DROP SCHEMA IF EXISTS #{Postgres.identifier(prefix)} CASCADE")
    end)

    :ok = Ecto.Migrator.up(TestRepo, 1, TestMigration, prefix: prefix, log: false)

    view = fn fold, limits ->
      Postgres.store(TestRepo, prefix: prefix, fold: fold, limits: limits)
    end

    faulty = fn fold, limits ->
      if opts[:harness] do
        controller = ExUnit.Callbacks.start_supervised!({PostgresHarness, []}, id: make_ref())
        PostgresHarness.attach(TestRepo, prefix, fold, limits, controller)
      else
        view.(fold, limits)
      end
    end

    run_store = view.(Owner.fold(), Owner.limits())
    {:ok, lease} = Lease.new([store: run_store, clock: :store] ++ Keyword.get(opts, :lease, []))

    %{
      kind: :postgres,
      prefix: prefix,
      lease: lease,
      stores: [
        unit_store: faulty.(DurableUnit.fold(@unit_options), DurableUnit.limits(unit_limits())),
        run_store: run_store,
        evidence_store: view.(@evidence_fold, @evidence_limits),
        intent_store: view.(EffectIntent.fold(TestBinding), EffectIntent.limits()),
        activation_store: faulty.(StoreHost.fold(), StoreHost.limits())
      ]
    }
  end

  @doc """
  One Memory namespace for every Store view: its fold admits the kinds of every owner
  (Unit, Run with the lease kinds, evidence, EffectIntent, activation) and folds the
  Unit's own records with the Unit's fold, so that a read of a sleeping Unit restores
  its state; its limits are the largest that any owner needs. One manual clock and one
  Lease backend; `lease:` gives more Lease options (a `test_hook`).
  """
  def memory(opts \\ []) do
    unit = DurableUnit.fold(@unit_options)

    kinds =
      [unit, Owner.fold(), @evidence_fold, EffectIntent.fold(TestBinding), StoreHost.fold()]
      |> Enum.map(& &1.kinds)
      |> Enum.reduce(&Map.merge/2)

    fold = %{
      initial: unit.initial,
      kinds: kinds,
      versions: [1],
      destinations: ["outputs"],
      reduce: fn model, kind, version, bytes ->
        if kind in ["input", "result"],
          do: unit.reduce.(model, kind, version, bytes),
          else: bytes
      end
    }

    limits = %{max_record_bytes: 16_777_216, max_batch_size: 4, max_checkpoint_bytes: 33_554_432}

    memory =
      ExUnit.Callbacks.start_supervised!({Memory, fold: fold, limits: limits}, id: make_ref())

    store = Memory.store(memory)
    {:ok, clock} = Lease.Clock.manual(1_800_000_000_000_000)

    {:ok, lease} =
      Lease.new([store: store, clock: {:manual, clock}] ++ Keyword.get(opts, :lease, []))

    %{
      kind: :memory,
      lease: lease,
      clock: clock,
      store: store,
      stores:
        for(
          k <- [:unit_store, :run_store, :evidence_store, :intent_store, :activation_store],
          do: {k, store}
        )
    }
  end

  defp unit_limits, do: [max_record_bytes: 16_777_216, max_checkpoint_bytes: 33_554_432]

  def intent?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, d} -> d[:"$initial_call"] == {EffectIntent, :init, 1}
      _ -> false
    end
  end

  def sql!(sql, params \\ []), do: Ecto.Adapters.SQL.query!(TestRepo, sql, params, log: false).rows

  def rows(env, stream) do
    if env.kind == :postgres do
      sql!(
        "SELECT kind, payload FROM #{Postgres.identifier(env.prefix)}.elzoo_log_records WHERE stream = $1 ORDER BY sequence",
        [stream]
      )
      |> Enum.map(fn [kind, payload] -> %{kind: kind, payload: payload} end)
    else
      {:ok, rows, _} = Elzoo.DurableLog.read(env.stores[:run_store], stream, 1, 10_000)
      Enum.map(rows, &%{kind: &1.kind, payload: &1.payload})
    end
  end

  def streams(env, like) do
    List.flatten(
      sql!(
        "SELECT stream FROM #{Postgres.identifier(env.prefix)}.elzoo_log_heads WHERE stream LIKE $1",
        [like]
      )
    )
  end

  def count_rows(env, like) do
    [[n]] =
      sql!(
        "SELECT count(*) FROM #{Postgres.identifier(env.prefix)}.elzoo_log_records WHERE stream LIKE $1",
        [like]
      )

    n
  end

  @doc "The protocol inputs that the Unit journal of a spec's Run committed: `{id, record}`."
  def protocol_inputs(env, spec) do
    for %{kind: "input", payload: payload} <- rows(env, "unit/" <> spec.unit),
        {1, {id, %{kind: :protocol} = record}} <- [:erlang.binary_to_term(payload)],
        do: {id, record}
  end

  def ai_inputs(env, spec),
    do: for({"ai:" <> _ = id, record} <- protocol_inputs(env, spec), do: {id, record})

  ## Host

  @doc "A host over `env` with test defaults; `opts` override them."
  def host(env, opts \\ []) do
    {opts, specs} = host_options(env, opts)

    host =
      ExUnit.Callbacks.start_supervised!(
        %{id: make_ref(), start: {RunHost, :start_link, [opts]}, restart: :temporary},
        []
      )

    {host, specs}
  end

  # Each test host has a name of its own (its Registries are named after it).
  def host_options(env, opts) do
    specs = Keyword.get_lazy(opts, :specs, fn -> specs() end)

    defaults = [
      owner_id: "node-a",
      max_runs: 4,
      idle_ms: 60_000,
      lease: env.lease,
      clock: &clock/0,
      lease_ttl_ms: 60_000,
      spec: fn ref -> Agent.get(specs, &Map.fetch(&1, ref)) |> spec_reply() end,
      allow_volatile: env.kind == :memory,
      name: Module.concat(Elzoo.RunHost.TestHost, "H#{System.unique_integer([:positive])}")
    ]

    {Keyword.merge(defaults, Keyword.delete(opts, :specs)) ++ env.stores, specs}
  end

  defp spec_reply({:ok, spec}), do: {:ok, spec}
  defp spec_reply(:error), do: {:error, :unknown_run}

  def specs do
    {:ok, specs} = Agent.start_link(fn -> %{} end)
    specs
  end

  def remember(specs, ref, spec), do: Agent.update(specs, &Map.put(&1, ref, spec))

  def notify(test \\ self()) do
    [
      on_terminal: fn ref, outcome -> send(test, {:terminal, ref, outcome}) end,
      on_lost: fn ref, reason -> send(test, {:lost, ref, reason}) end
    ]
  end

  def state(host), do: :sys.get_state(host)
  def run(host, ref), do: state(host).runs[ref]

  ## Another node in this VM

  @doc """
  The group leader of a stand-in for another node: every process that a host started
  on it creates, at any depth, has it at the end of its group-leader chain (a Run's
  group leader is itself one of its processes), so the test can find and stop them
  without the host's own tracking.
  """
  def node_leader do
    original = Process.group_leader()
    leader = spawn(fn -> relay(original) end)

    ExUnit.Callbacks.on_exit(fn ->
      fence_node(leader)
      Process.exit(leader, :kill)
    end)

    leader
  end

  defp relay(original) do
    receive do
      message -> send(original, message)
    end

    relay(original)
  end

  @doc "Starts a host with `opts` under the node's group leader."
  def host_on_node(leader, env, opts) do
    {opts, specs} = host_options(env, opts)
    parent = self()

    root =
      spawn(fn ->
        Process.group_leader(self(), leader)
        Process.flag(:trap_exit, true)
        send(parent, {:on_node, self(), RunHost.start_link(opts)})
        receive do: (:never -> :ok)
      end)

    receive do
      {:on_node, ^root, {:ok, host}} -> {host, specs}
    end
  end

  def node_processes(leader),
    do: for(pid <- Process.list(), pid != leader, under?(pid, leader, 4), do: pid)

  defp under?(_, _, 0), do: false

  defp under?(pid, leader, n) do
    case Process.info(pid, :group_leader) do
      {:group_leader, ^leader} -> true
      {:group_leader, gl} when gl != pid -> under?(gl, leader, n - 1)
      _ -> false
    end
  end

  @doc "Stops every process of the node and confirms that none is left."
  def fence_node(leader) do
    case node_processes(leader) do
      [] ->
        :ok

      pids ->
        fence(pids)
        fence_node(leader)
    end
  end

  @doc "Kills each of `pids` that is alive and confirms that it is gone."
  def fence(pids) do
    refs =
      Enum.map(alive_pids(pids), fn pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        ref
      end)

    for ref <- refs, do: receive(do: ({:DOWN, ^ref, _, _, _} -> :ok))
    :ok
  end

  @doc "The head revision of each stream of a Memory namespace that starts with `prefix`."
  def heads(env, prefix) do
    for {stream, %{revision: revision}} <- Memory.inspect_state(env.store).heads,
        String.starts_with?(stream, prefix),
        into: %{},
        do: {stream, revision}
  end

  @doc """
  The root Budget of a spec's Run, by the state that its Unit committed (read through
  the live Unit): `%{reserved, committed, ...}` of `Elzoo.Budget`.
  """
  def budget(host, spec) do
    [{unit, _}] = Registry.lookup(state(host).units, "unit/" <> spec.unit)
    %{control: %{budgets: %{"root" => root}}} = DurableUnit.snapshot(unit)
    {:Transition, _, {:some, {:status, status}}} = Elzoo.Budget.step(root.state, {clock(), :status})
    status
  end

  ## Stub

  @doc """
  The scripted stub of integration/ai-text-anthropic: each request takes the next
  answer of `script` (a list), or `script.(text)` for a function, given the text of the
  request's last message. `{:block, answer}` reports `{:stub_entered, pid}` to the test
  and waits for `{:release, answer}` or `:release`; `{:block_trap, answer}` does the
  same while trapping exits.
  """
  def stub(script, test \\ self()) do
    {:ok, answers} = Agent.start_link(fn -> script end)

    {agent, plug} =
      AnthropicStub.start(fn body ->
        text = body |> Map.get("messages", []) |> List.last() |> text_of()

        answer =
          Agent.get_and_update(answers, fn
            fun when is_function(fun, 1) -> {fun.(text), fun}
            [a | rest] -> {a, rest}
            [] -> {{500, [], AnthropicStub.error("api_error", "unscripted")}, []}
          end)

        case answer do
          {:block_trap, default} ->
            Process.flag(:trap_exit, true)
            blocked(test, default)

          {:block, default} ->
            blocked(test, default)

          answer ->
            answer
        end
      end)

    %{agent: agent, plug: plug, answers: answers}
  end

  defp blocked(test, default) do
    send(test, {:stub_entered, self()})

    receive do
      {:release, answer} -> answer
      :release -> default
    end
  end

  defp text_of(%{"content" => [%{"text" => text} | _]}), do: text
  defp text_of(%{"content" => text}) when is_binary(text), do: text
  defp text_of(_), do: nil

  def requests(stub), do: AnthropicStub.requests(stub.agent)

  def answer(text),
    do: AnthropicStub.ok(AnthropicStub.message([AnthropicStub.text(text)], "end_turn"))

  ## Specs

  def schemas do
    ~w(elzoo.agent-loop.message elzoo/ai-text-request elzoo.ai-text.result elzoo.agent-loop.result
       elzoo.run-engine.refusal result)
    |> Map.new(fn id ->
      port = %{"id" => id, "direction" => "input", "schema_id" => id, "schema_version" => 1}
      {:ok, compiled} = PayloadSchema.build(port, %{})
      {{id, 1}, %{port: port, compiled: compiled, digest: :crypto.hash(:sha256, "{}")}}
    end)
  end

  def proposal(tenant),
    do: fn action ->
      %{
        tenant: tenant,
        resource: "document",
        action_id: action["id"],
        payload: {:text, "publish"},
        writes: @writes
      }
    end

  def policy,
    do: %{
      id: "policy",
      version: 1,
      content_hash: <<0::256>>,
      effect_classes: ["compute", "model"],
      rules: [
        %{id: "compute", effect_class: "compute", verdict: :allow},
        %{id: "model", effect_class: "model", verdict: :allow}
      ]
    }

  @doc "Input and output tokens that the provider reported, in the Budget unit tokens."
  def tokens(%{counters: counters}) do
    amounts =
      for %{unit: unit, amount: amount} <- counters,
          unit in [:input_uncached_tokens, :output_tokens],
          do: amount

    if amounts != [] and Enum.all?(amounts, &is_integer/1),
      do: {:ok, Enum.sum(amounts)},
      else: :unknown
  end

  def descriptor(stub, opts \\ []) do
    tenant = Keyword.get(opts, :tenant, "tenant")

    %{
      id: "model",
      version: 1,
      effect_class: "model",
      proposal: Keyword.get(opts, :proposal, proposal(tenant)),
      estimate: Keyword.get(opts, :estimate, 1_000),
      call_ms: 600_000,
      usage: &__MODULE__.tokens/1,
      ai_text: [
        binding: TestBinding,
        provider: Elzoo.AiText.Anthropic,
        provider_config: %{plug: stub.plug},
        credentials: fn -> {:ok, "sk-ant-test-INJECTED-k7"} end,
        models: [@model],
        max_output_tokens: 4_096,
        receive_timeout_ms: 5_000
      ]
    }
  end

  def agent(opts \\ []) do
    {:ok, state} =
      Elzoo.AgentLoop.new(
        Map.merge(
          %{
            id: "bot",
            model: @model,
            max_output_tokens: 256,
            role_instructions: ["You are a test agent."],
            window: %{
              provider_id: "anthropic",
              model_id: @model,
              size: 100_000,
              unit: :tokens,
              estimator_id: "bytes",
              estimator_version: 1
            },
            max_request_bytes: 60_000,
            max_image_refs: 8,
            sources: [],
            result_limits: %{max_bytes: 4_096, artifact_max_bytes: 1_048_576},
            ask: nil,
            turn_limit: 4
          },
          Map.new(opts)
        )
      )

    {TestAgent, :step, state}
  end

  @doc "A spec of one Run; `opts` override its members."
  def spec(name, stub, opts \\ []) do
    {context, opts} = Keyword.pop(opts, :context)
    {descriptor_opts, opts} = Keyword.pop(opts, :descriptor, [])
    tenant = "tenant"

    context =
      context ||
        fn ->
          %{
            policy: policy(),
            authority: @writes,
            resource_names: ["document"],
            pause_deadline: clock() + 600_000
          }
        end

    finish = %{
      id: "finish",
      version: 1,
      effect_class: "compute",
      result: {"result", 1},
      proposal: proposal(tenant),
      facts: fn _ -> %{estimate: 1, unit: "tokens", deadline_ms: clock() + 600_000} end
    }

    Map.merge(
      %{
        run_id: "run-" <> name,
        operation_id: "operation-" <> name,
        attempt_id: "attempt-" <> name,
        unit: name,
        provider_refs: %{},
        tenant: tenant,
        principal: "principal",
        pattern: agent(),
        schemas: schemas(),
        bindings: %{"finish" => finish},
        ai: %{"elzoo/ai-text-request" => descriptor(stub, descriptor_opts)},
        gate: %{id: "gate", version: 1, call: fn _, _ -> :allow end},
        context: context,
        budget: %{cap: 1_000_000, unit: "tokens", id: "budget", incarnation: "sealed"},
        budget_rule: :finish,
        request_cap: 16,
        run_deadline: clock() + 600_000,
        retention: 1_024
      },
      Map.new(opts)
    )
  end

  def two_calls, do: {TestPattern, :step, %{phase: :new, calls: ["a", "b"], seen: []}}
  def starts, do: {TestPattern, :starts, %{n: 0}}

  @doc "One model call `id` that declares the tool `lookup` with any object as its input."
  def tool_call(id) do
    tool = %{
      "name" => "lookup",
      "description" => "Looks a thing up.",
      "input_schema" => %{"type" => "object"}
    }

    {TestPattern, :step, %{phase: :new, calls: [id], seen: [], tools: [tool]}}
  end

  def start_input(text \\ "Say hello.", extra \\ %{}),
    do: %{
      "type" => "input",
      "version" => 1,
      "kind" => "start",
      "schema_id" => "elzoo.agent-loop.message",
      "schema_version" => 1,
      "payload" => Map.merge(%{"text" => text}, extra)
    }

  def verified(spec, extra \\ %{}),
    do: Map.merge(%{run_id: spec.run_id, attempt_id: spec.attempt_id}, extra)

  def scope(spec), do: %{tenant: spec.tenant, principal: spec.principal, run_id: spec.run_id}

  def transcript(host, ref, spec) do
    {:ok, %{entries: entries}} = RunHost.transcript(host, ref, scope(spec), @limits)
    entries
  end

  def settlements(entries, action_id),
    do: for(%{type: :settlement, action_id: ^action_id} = e <- entries, do: e)

  def occurrence(entries, action_id),
    do: hd(for %{type: :action, action_id: ^action_id, occurrence: o} <- entries, do: o)

  ## Time and processes

  def eventually(fun, left \\ 500) do
    cond do
      fun.() -> :ok
      left == 0 -> flunk("condition not reached")
      true -> Process.sleep(10) && eventually(fun, left - 1)
    end
  end

  def not_running?(host, ref), do: RunHost.status(host, ref) == {:error, :not_running}

  def alive_pids(pids), do: Enum.filter(pids, &Process.alive?/1)

  @doc """
  A fencing_proof and its cell. The proof answers what the cell holds: `:unproven` (no
  proof, the start), `:fenced`, or a non-empty list of processes, which proves fencing
  only once each of them has ended. The test sets the predecessor's processes with
  prove/3, collected in the test process itself, so the proof is demonstrated, not
  assumed; an empty list proves nothing.
  """
  def proof_cell do
    {:ok, cell} = Agent.start_link(fn -> :unproven end)

    proof = fn _run_ref ->
      case Agent.get(cell, & &1) do
        [_ | _] = pids -> if alive_pids(pids) == [], do: :fenced, else: :unproven
        [] -> :unproven
        answer -> answer
      end
    end

    {cell, proof}
  end

  @doc """
  Sets a proof cell to `pids`, a list collected in the calling test process (spawned/0,
  unit_pids/2), which holds `known`: a predecessor process that the test saw itself.
  """
  def prove(cell, pids, known) do
    assert known in pids
    Agent.update(cell, fn _ -> pids end)
  end

  ## Processes of one Run, without the host's tracking

  @doc """
  Runs `start` (a start or wake of one Run) with spawn tracing on the host, set on every
  process that the host spawns meanwhile and on everything that those spawn later, at
  any depth: the Run's group leader, its worker and all that the worker starts. The
  processes are then known to the test independently of the host (spawned/0), which
  reads them in this test process.
  """
  def attribute(host, start) do
    trace_spawns(host)

    try do
      start.()
    after
      :erlang.trace(host, false, [:procs, :set_on_spawn])
    end
  end

  @doc """
  Spawn tracing (set on spawn) on `pid` from now on, to this test process (spawned/0):
  on the host's shared task supervisor, every renewal, expiry, teardown, release and
  callback task that it starts.
  """
  def trace_spawns(pid), do: :erlang.trace(pid, true, [:procs, :set_on_spawn, {:tracer, self()}])

  @doc "Every process whose spawn was traced in this test so far (attribute/2)."
  def spawned do
    ref = :erlang.trace_delivered(:all)
    receive do: ({:trace_delivered, :all, ^ref} -> :ok)
    pids = collect_spawns(Process.get({__MODULE__, :spawned}, []))
    Process.put({__MODULE__, :spawned}, pids)
    pids
  end

  @process_events [
    :exit,
    :register,
    :unregister,
    :link,
    :unlink,
    :getting_linked,
    :getting_unlinked
  ]

  defp collect_spawns(acc) do
    receive do
      {:trace, _, :spawn, pid, _} -> collect_spawns(acc ++ [pid])
      {:trace, _, :spawned, _, _} -> collect_spawns(acc)
      {:trace, _, event, _} when event in @process_events -> collect_spawns(acc)
    after
      0 -> acc
    end
  end

  @doc """
  The directory-owned Unit of `identity`, found in the directory's Registry, and the
  linked processes that it started (its Writer).
  """
  def unit_pids(units, identity) do
    case Registry.lookup(units, identity) do
      [{unit, _}] ->
        {:links, links} = Process.info(unit, :links) || {:links, []}
        [unit | for(pid <- links, is_pid(pid), started_by?(pid, unit), do: pid)]

      [] ->
        []
    end
  end

  defp started_by?(pid, parent) do
    case Process.info(pid, :dictionary) do
      {:dictionary, d} -> List.first(d[:"$ancestors"] || []) == parent
      _ -> false
    end
  end

  @doc """
  Holds the next engine registered under `identity`: a suspension queued while it
  starts takes effect when its init has ended, so the first call that the Run's worker
  makes to it waits until the test resumes it. Sends `{:engine_held, pid}`.
  """
  def hold_engine(names, identity) do
    test = self()

    spawn_link(fn ->
      pid = registered(names, identity)
      :sys.suspend(pid, :infinity)
      send(test, {:engine_held, pid})
    end)
  end

  defp registered(names, identity) do
    case Registry.lookup(names, identity) do
      [{pid, _}] ->
        pid

      [] ->
        :erlang.yield()
        registered(names, identity)
    end
  end

  @doc "A PostgreSQL stream whose history is kept only after `through`: a pruned journal."
  def prune!(env, stream, through \\ 1),
    do:
      sql!(
        "UPDATE #{Postgres.identifier(env.prefix)}.elzoo_log_heads SET low_water = $2 WHERE stream = $1",
        [stream, through]
      )

  ## Observation

  @doc """
  Call tracing of `mfas` (with their returns) in every process, to this test
  process: the observation of what the host gives ai-text and the engine.
  """
  def trace(mfas) do
    tracer = self()
    :erlang.trace(:all, true, [:call, {:tracer, tracer}])

    for {m, _, _} = mfa <- mfas do
      Code.ensure_loaded!(m)
      :erlang.trace_pattern(mfa, [{:_, [], [{:exception_trace}]}], [:global])
    end

    ExUnit.Callbacks.on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      for mfa <- mfas, do: :erlang.trace_pattern(mfa, false, [:global])
    end)
  end

  @doc "The next traced `RunEngine.input/4` whose ID passes `pick`, with its reply."
  def engine_input(pick, timeout \\ 5_000) do
    receive do
      {:trace, pid, :call, {RunEngine, :input, [_, id, frame, context]}} ->
        reply =
          receive do
            {:trace, ^pid, :return_from, {RunEngine, :input, 4}, reply} -> reply
          after
            timeout -> flunk("no reply traced for #{id}")
          end

        if pick.(id),
          do: %{id: id, frame: frame, context: context, reply: reply},
          else: engine_input(pick, timeout)
    after
      timeout -> flunk("no traced engine input")
    end
  end

  def ai_input?(id), do: String.starts_with?(id, "ai:")

  def hex(n), do: Base.encode16(:crypto.strong_rand_bytes(n), case: :lower)
end
