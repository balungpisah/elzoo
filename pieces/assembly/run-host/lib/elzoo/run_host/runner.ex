# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RunHost.Runner do
  @moduledoc """
  The worker of one Run of `Elzoo.RunHost`, under the Run's own group leader: it
  starts the Run (lease claim, Run owner, Run and Attempt, predecessor check, evidence
  Writer, AsyncWork, keep-alive, engine, route), then serializes every engine input of
  the Run: the caller's inputs and controls, the outcomes that the sink of its AI
  bindings receives and the wakes at its committed deadlines. It reads the deadlines,
  the current Attempt and the terminal phase again after each. The Run's keep-alive, a
  process beside it, keeps the Unit awake while an engine input is in progress or a
  model call is in flight. The host links it and tears it down with the Run.
  """
  use GenServer, restart: :temporary
  require Logger
  alias Elzoo.{AsyncWork, DynamicUnits, Lease, PayloadSchema, RunEngine, RunHost}
  alias Elzoo.RunApprovalRelease, as: Owner
  alias Elzoo.DurableLog.{Store, Writer}
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.RunHost.Ai

  @spec_keys [
    :run_id,
    :operation_id,
    :attempt_id,
    :unit,
    :provider_refs,
    :tenant,
    :principal,
    :pattern,
    :schemas,
    :bindings,
    :ai,
    :gate,
    :context,
    :budget,
    :budget_rule,
    :request_cap,
    :run_deadline,
    :retention
  ]
  # The spec's own bindings: action kinds that need no Effect and no asynchronous
  # input that bypasses the host. model_call is the host's (the spec's `ai`).
  @kinds ["finish", "ask_person", "nested_callable"]
  @read_limits %{max_records: 65_536, max_bytes: 536_870_912}
  @evidence_limits %{max_record_bytes: 131_072, max_batch_size: 1, max_checkpoint_bytes: 1_048_576}
  @retry_ms 200
  @retries 20
  # Process.send_after/3 takes at most 2^32 - 1 ms; a later deadline is reached in steps.
  @max_timer 86_400_000
  @in_flight [:ready, :running]

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init(args) do
    # First: every process that the Run starts, at any depth, inherits it.
    Process.group_leader(self(), args.group_leader)
    Process.flag(:trap_exit, true)
    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
    true = :ets.insert(table, {:in_flight, false})

    s =
      Map.merge(args, %{
        spec: nil,
        ai: %{},
        ids: nil,
        unit: nil,
        stream: nil,
        held: nil,
        intents: %{},
        bindings: %{},
        gate: nil,
        pids: %{},
        engine: nil,
        table: table,
        attempt: nil,
        confirmed: false,
        observed: false,
        route: %{},
        verified: false,
        pending: [],
        route_retry: nil,
        inputs: %{},
        done: MapSet.new(),
        retries: %{},
        terminal: false,
        timer: nil,
        fired: nil,
        refreshing: false
      })

    {:ok, s, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, s) do
    case start(s) do
      {:ok, %{verified: true} = s} ->
        {:noreply, started(s)}

      # The route is read again shortly; the start is answered once it is known.
      {:ok, s} ->
        {:noreply, s}

      {:error, reason} ->
        {:stop, {:shutdown, reason}, s}
    end
  end

  # Once the route is verified the worker announces the Run started to the host, and only
  # then submits a held delivery: a terminal outcome which such a delivery produces reaches
  # the host after the Run is live there. The host answers the start or wake when it takes
  # that announcement (a batch, once every Run of it has its disposition), so the held
  # deliveries can be submitted before the caller has its answer.
  defp started(s) do
    send(s.host, {:started, s.run_ref, s.token})
    s |> flush() |> refresh()
  end

  ## Start

  defp start(s) do
    with {:ok, spec} <- spec(s),
         {:ok, s} <- describe(s, spec),
         :ok <- host(s, {:unit, s.unit, s.stream, spec.retention}),
         {:ok, s} <- claim(s),
         {:ok, s} <- start_child(s, :tasks, fn -> Task.Supervisor.start_link() end),
         s = provision(s),
         {:ok, s} <- start_owner(s),
         {:ok, fresh} <- fresh(s),
         :ok <- open_run(s),
         :ok <- if(fresh, do: :ok, else: proof(s.c.fencing_proof, s.run_ref)),
         {:ok, attempt} <- current_attempt(s),
         true <- :ets.insert(s.table, {:attempt, attempt}),
         :ok <- host(s, :grant),
         {:ok, s} <- start_child(s, :evidence, fn -> evidence(s) end),
         {:ok, s} <- start_child(s, :async, fn -> async(s) end),
         {:ok, s} <- start_child(s, :keep_alive, fn -> keep_alive(s) end),
         s = %{s | attempt: attempt, confirmed: true},
         {:ok, s} <- dispatching(s, fn -> start_engine(s) end) do
      verify(s)
    end
  end

  defp spec(%{mode: {:start, spec}}), do: {:ok, spec}

  defp spec(%{mode: :wake} = s) do
    case s.c.spec.(s.run_ref) do
      {:ok, spec} -> {:ok, spec}
      {:error, reason} -> {:error, {:spec, reason}}
      _ -> {:error, {:spec, :invalid}}
    end
  rescue
    _ -> {:error, {:spec, :invalid}}
  catch
    _, _ -> {:error, {:spec, :invalid}}
  end

  defp describe(s, spec) do
    with true <- is_map(spec) and Enum.sort(Map.keys(spec)) == Enum.sort(@spec_keys),
         true <- text?(spec.run_id, 200) and text?(spec.attempt_id, 200),
         true <- text?(spec.operation_id, 200) and text?(spec.unit, 155),
         true <- text?(spec.tenant, 200) and text?(spec.principal, 200),
         true <- is_map(spec.bindings) and is_map(spec.provider_refs),
         true <- is_map(spec.budget) and Map.has_key?(spec.budget, :unit),
         true <- is_map(spec.gate) and is_function(spec.gate[:call], 2),
         true <- is_function(spec.context, 0) and spec.budget_rule in [:pause, :finish],
         true <- is_integer(spec.run_deadline) and is_integer(spec.retention) and spec.retention > 0,
         {:profile, true} <- {:profile, Enum.all?(Map.keys(spec.bindings), &(&1 in @kinds))},
         {:ok, ai} <- Ai.descriptors(spec.ai),
         {:ok, ai} <- configure(ai, spec.tenant) do
      table = s.table

      ids = %{
        run_id: spec.run_id,
        attempt: fn -> :ets.lookup_element(table, :attempt, 2) end,
        run_deadline: spec.run_deadline
      }

      # Each stream of the Run has a prefix of its own, so no Unit identity of one Run
      # can name a stream of another (EffectIntent streams start with "intent").
      {:ok,
       %{s | spec: spec, ai: ai, ids: ids, unit: "unit/" <> spec.unit, stream: "run/" <> spec.unit}}
    else
      {:profile, false} -> {:error, :outside_profile}
      _ -> {:error, :invalid_spec}
    end
  end

  # One ai-text Config per AI binding, with the host's sink: every delivery comes to
  # this worker, which resolves its key to the Run's action and occurrence.
  defp configure(ai, tenant) do
    worker = self()

    sink = fn key, delivery ->
      send(worker, {:ai_delivery, key, delivery})
      :ok
    end

    Enum.reduce_while(ai, {:ok, %{}}, fn {schema_id, d}, {:ok, acc} ->
      case Ai.configure(d, tenant, sink) do
        {:ok, config} -> {:cont, {:ok, Map.put(acc, schema_id, Map.put(d, :config, config))}}
        _ -> {:halt, :error}
      end
    end)
  end

  # The claim goes to the host first, which bounds the confirmation phase on receipt (a
  # reading that blocks leaves the Run fenced by then, the worker stopped by the
  # teardown). The worker then reads the lease, judged against the claim's `until` before
  # any record read, until a reading taken after the claim returned confirms it (every
  # 100 ms while the host answers `:pending`); only then does the start go on.
  defp claim(s) do
    case Lease.claim(s.c.lease, s.stream, s.c.owner_id, s.c.lease_ttl_ms) do
      {:held, held} ->
        :ok = host(s, {:held, held, RunHost.mark()})

        with :ok <- confirm(s, held.live.until),
             do: {:ok, %{s | held: held}}

      {:lease_refused, refusal} ->
        {:error, {:lease_refused, refusal}}

      other ->
        {:error, {:lease, other}}
    end
  end

  defp confirm(s, until) do
    {t0, read} = RunHost.lease_reading(s.c.lease, s.stream, s.c.owner_id, until)

    case host(s, {:claim_read, t0, read}) do
      :confirmed ->
        :ok

      :pending ->
        Process.sleep(100)
        confirm(s, until)

      error ->
        error
    end
  end

  # The EffectIntent startup bindings of the Run, provisioned once at its start and
  # given to both the Run owner and the engine; the engine's model_call bindings and
  # the gate with the ai-text admission in front of the spec's gate.
  defp provision(s) do
    authorize = authorize(s)
    volatile = if s.c.allow_volatile, do: [allow_volatile: true], else: []

    intents =
      Map.new(s.ai, fn {schema_id, d} ->
        {schema_id,
         [
           binding: d.ai_text[:binding],
           store: s.c.intent_store,
           clock: s.c.clock,
           host: {StoreHost, %{store: s.c.activation_store, authorize: authorize}},
           task_supervisor: s.pids.tasks,
           adapter_context: d.config
         ] ++ volatile}
      end)

    model =
      Map.new(s.ai, fn {schema_id, d} ->
        {schema_id, Ai.binding(d, schema_id, d.config, s.ids, s.c.clock, s.spec.budget.unit)}
      end)

    %{
      s
      | intents: intents,
        bindings: Map.put(s.spec.bindings, "model_call", model),
        gate: Ai.gate(s.spec.gate, s.ai, s.ids)
    }
  end

  # Runs inside an EffectIntent process, in its init: the host grants an activation
  # only to a Run whose predecessor check has passed, while a reading of the lease
  # taken here shows it held by this owner and live by the last confirmed `until` that the
  # host gives for this tenure (the cutoff the reading is judged against before any record
  # read, so a loss that its first status shows is the reading).
  defp authorize(s) do
    %{host: host, run_ref: run_ref, token: token, stream: key} = s
    %{lease: lease, owner_id: owner} = s.c

    fn request, generation ->
      with {:ok, until} <- GenServer.call(host, {:cutoff, run_ref, token}),
           {t0, read} = RunHost.lease_reading(lease, key, owner, until),
           :granted <- GenServer.call(host, {:authorize, run_ref, token, t0, read}) do
        if request.revision == 0 and generation == 0,
          do: :fresh,
          else: {:recovered, generation}
      else
        _ -> :refused
      end
    end
  end

  defp start_owner(s) do
    opts =
      [store: s.c.run_store, lease: s.c.lease, held: s.held, effect_intent: s.intents] ++
        if(s.receipt, do: [reconcile: s.receipt], else: [])

    start_child(s, :owner, fn -> Owner.start_link(opts) end)
  end

  # A Run with no Run record and an empty Unit journal has no predecessor that could
  # still act or write: its start needs no predecessor check. Any other start or wake
  # opens an existing journal and needs a fresh :fenced (Recovery).
  defp fresh(%{mode: :wake}), do: {:ok, false}

  defp fresh(s) do
    case Owner.status(s.pids.owner, s.spec.run_id) do
      {:error, :not_found} ->
        case Store.read(s.c.unit_store, :head, [s.unit]) do
          {:ok, %{revision: 0}} -> {:ok, true}
          {:ok, %{revision: n}} when is_integer(n) -> {:ok, false}
          other -> {:error, {:start_failed, {:unit_head, other}}}
        end

      {:ok, _} ->
        {:ok, false}

      other ->
        {:error, {:start_failed, {:status, other}}}
    end
  end

  # A start creates the Run and begins the spec's Attempt (a retry gets
  # `{:unchanged, :duplicate, _}` for both); an existing Run that a begin_attempt
  # control moved to another Attempt keeps it. A wake opens only a Run that has a
  # current Attempt.
  defp open_run(%{mode: :wake} = s) do
    case Owner.status(s.pids.owner, s.spec.run_id) do
      {:ok, %{current_attempt: attempt}} when is_binary(attempt) -> :ok
      _ -> {:error, :no_current_attempt}
    end
  end

  defp open_run(s) do
    spec = s.spec

    create = %{
      kind: :create,
      run_id: spec.run_id,
      operation_id: spec.operation_id,
      provider_refs: spec.provider_refs,
      expected_revision: revision(s)
    }

    with :ok <- command(s, create),
         {:ok, attempt} <- attempt(s) do
      if attempt in [nil, spec.attempt_id] do
        command(s, %{
          kind: :begin_attempt,
          run_id: spec.run_id,
          attempt_id: spec.attempt_id,
          expected_revision: revision(s)
        })
      else
        :ok
      end
    end
  end

  defp command(s, command) do
    case Owner.command(s.pids.owner, command) do
      {:ok, _, _} -> :ok
      {:unchanged, :duplicate, _} -> :ok
      other -> {:error, {:start_failed, {command.kind, other}}}
    end
  end

  defp attempt(s) do
    case Owner.status(s.pids.owner, s.spec.run_id) do
      {:ok, view} -> {:ok, view.current_attempt}
      other -> {:error, {:start_failed, {:status, other}}}
    end
  end

  defp current_attempt(s) do
    case attempt(s) do
      {:ok, attempt} when is_binary(attempt) -> {:ok, attempt}
      {:ok, _} -> {:error, :no_current_attempt}
      error -> error
    end
  end

  defp revision(s) do
    case Owner.status(s.pids.owner, s.spec.run_id) do
      {:ok, view} -> view.revision
      _ -> s.held.live.revision
    end
  end

  # The predecessor check before any engine starts on an existing Run or Unit journal:
  # a fresh :fenced from the caller's fencing_proof, asked again each time. The host's
  # own teardown is no proof (a Store write submitted before it can commit after it).
  defp proof(nil, _), do: {:error, :fencing_unproven}

  defp proof(fencing_proof, run_ref) do
    if fencing_proof.(run_ref) == :fenced, do: :ok, else: {:error, :fencing_unproven}
  rescue
    _ -> {:error, :fencing_unproven}
  catch
    _, _ -> {:error, :fencing_unproven}
  end

  defp evidence(s) do
    fold = %{
      initial: nil,
      kinds: %{"completion" => :state_bearing},
      versions: [1],
      destinations: [],
      reduce: fn _, _, _, bytes -> bytes end
    }

    Writer.start_link(
      store: s.c.evidence_store,
      stream: "evidence/" <> s.spec.unit,
      fold: fold,
      limits: @evidence_limits
    )
  end

  defp async(s) do
    AsyncWork.start_link(
      owner: {:via, Registry, {s.names, s.unit}},
      task_supervisor: s.pids.tasks,
      max_concurrency: 1
    )
  end

  defp keep_alive(s) do
    args = [s.table, s.directory, s.unit, max(div(s.c.idle_ms, 4), 1)]
    {:ok, spawn_link(__MODULE__, :keep_alive, args)}
  end

  @doc false
  # The Run's keep-alive, a process of the Run beside its worker: every quarter of
  # idle_ms it touches the Unit through the directory while a model call can be in flight:
  # from each engine start, input or control (any can dispatch) until an observation of
  # the worker shows no call ready or running (dispatching/2, observe/2). It never waits
  # on the worker, so a worker held by an engine call (a long input, a transcript read)
  # does not let the Unit sleep under a call; a Run with none in flight is left to sleep.
  def keep_alive(table, directory, unit, interval) do
    Process.sleep(interval)

    if :ets.lookup_element(table, :in_flight, 2),
      do: catch_exit(fn -> DynamicUnits.start(directory, unit) end)

    keep_alive(table, directory, unit, interval)
  end

  defp start_engine(s) do
    spec = s.spec

    opts = [
      name: {:via, Registry, {s.names, s.unit}},
      identity: s.unit,
      directory: s.directory,
      store: s.c.unit_store,
      run_owner: s.pids.owner,
      run_id: spec.run_id,
      tenant: spec.tenant,
      principal: spec.principal,
      pattern: spec.pattern,
      schemas: spec.schemas,
      gate: s.gate,
      clock: s.c.clock,
      bindings: s.bindings,
      context: spec.context,
      async_work: s.pids.async,
      resources: %{},
      effect_intent: s.intents,
      request_cap: spec.request_cap,
      budget: spec.budget,
      budget_rule: spec.budget_rule,
      run_deadline: spec.run_deadline,
      evidence: %{writer: s.pids.evidence, stream: "evidence/" <> spec.unit},
      result_reader: %{evidence_store: s.c.evidence_store, retention_count: spec.retention}
    ]

    case start_child(s, :engine, fn -> RunEngine.start_link(opts) end) do
      {:ok, s} ->
        {:ok, %{s | engine: s.pids.engine}}

      {:error, {:start_failed, {:engine, :incompatible_recovery}}} ->
        {:error, :incompatible_recovery}

      error ->
        error
    end
  end

  defp start_child(s, role, start) do
    case start.() do
      {:ok, pid} ->
        :ok = host(s, {:track, role, pid})
        {:ok, put_in(s.pids[role], pid)}

      {:error, reason} ->
        {:error, {:start_failed, {role, reason}}}
    end
  end

  defp host(s, message),
    do: GenServer.call(s.host, {:runner, s.run_ref, s.token, message}, :infinity)

  ## Route

  # The route of the Run's model calls: each committed model_call action of an AI
  # binding (its occurrence, its own Attempt and action ID, from the transcript) under
  # the key that ai-text derives from the stable binding configuration. Until it is
  # verified, deliveries are held. A route that cannot be read for good fails the start.
  defp verify(s) do
    case route(s) do
      {:ok, route} -> {:ok, %{s | route: route, verified: true}}
      {:error, :transient} -> {:ok, retry_route(s, :verify)}
      {:error, {:permanent, reason}} -> {:error, {:route, reason}}
    end
  end

  defp route(s) do
    spec = s.spec
    scope = %{tenant: spec.tenant, principal: spec.principal, run_id: spec.run_id}

    case call(fn -> RunEngine.transcript(s.engine, scope, @read_limits) end) do
      {:ok, %{entries: entries}} ->
        {:ok,
         Map.new(
           for %{type: :action, kind: "model_call", schema_id: schema_id} = e <- entries,
               d <- [s.ai[schema_id]],
               d != nil do
             ref = Ai.ref(spec.run_id, e.attempt_id, e.action_id)

             {Ai.intent_key(d, spec.tenant, ref),
              %{attempt_id: e.attempt_id, action_id: e.action_id, occurrence: e.occurrence, ai: d}}
           end
         )}

      reply when reply in [{:error, :unavailable}, :exit] ->
        {:error, :transient}

      {:error, reason} ->
        {:error, {:permanent, reason}}
    end
  end

  defp retry_route(%{route_retry: nil} = s, message) do
    Process.send_after(self(), message, @retry_ms)
    %{s | route_retry: message}
  end

  defp retry_route(s, _), do: s

  # The deliveries held while the route was unread, in their order of arrival, each by
  # its own kind: an outcome by the route just read, any other delivery as it is
  # handled live (a sink failure is reported and gives no input).
  defp flush(s) do
    {pending, s} = {s.pending, %{s | pending: []}}

    Enum.reduce(pending, s, fn
      {key, {:outcome, _, _} = delivery}, acc ->
        case acc.route[key] do
          nil -> report(acc, "an outcome with no route", key)
          route -> outcome(acc, route, delivery)
        end

      {key, delivery}, acc ->
        deliver(acc, key, delivery)
    end)
  end

  # A route that cannot be read for good: each held delivery is reported.
  defp unroutable(s, reason) do
    {pending, s} = {s.pending, %{s | pending: []}}

    Enum.reduce(pending, s, fn
      {key, {:outcome, _, _}}, acc ->
        report(acc, "an outcome that cannot be routed (#{inspect(reason)})", key)

      {key, delivery}, acc ->
        deliver(acc, key, delivery)
    end)
  end

  ## Inputs

  @impl true
  def handle_call(_, _, %{terminal: true} = s), do: {:reply, {:error, :terminal}, s}

  def handle_call({:input, id, input, context}, _, s) do
    {reply, s} =
      forward(s, fn -> pass(s, fn -> RunEngine.input(s.engine, id, input, context) end) end, true)

    {:reply, reply, refresh(s)}
  end

  # The host forwards no Approval control (README, Profile).
  def handle_call({:control, _, %{kind: :approval_evidence}, _}, _, s),
    do: {:reply, {:error, :outside_profile}, s}

  # A control can move the current Attempt: until a read confirms it again, no input
  # is forwarded (forward/3). A terminal observation stays confirmed.
  def handle_call({:control, id, command, context}, _, s) do
    {reply, s} =
      forward(
        s,
        fn -> pass(s, fn -> RunEngine.control(s.engine, id, command, context) end) end,
        true
      )

    {:reply, reply, refresh(if s.terminal, do: s, else: %{s | confirmed: false})}
  end

  # Every engine input and control of the Run goes through here. The gate and facts/1
  # derive the key of each action that the engine admits from the current Attempt that
  # the worker last read; after a control that read must succeed again before anything
  # is forwarded, so no action is admitted under an Attempt that the worker has not
  # confirmed (`confirmed`). Any engine start, input or control can end the Run (a sink
  # outcome that completes it, for example): after one, a caller's input or control
  # (`public?`) is forwarded only once a read after it found the Run not terminal
  # (`observed`); one that the read finds terminal gets {:error, :terminal} and calls
  # nothing in the engine. While a read that is needed fails, nothing is forwarded:
  # {:error, :unavailable}. The host's own inputs (a late sink outcome, a wake) need only
  # the confirmed Attempt, so a failed read after an input does not hold them.
  defp forward(s, fun, public?) do
    s = if ready?(s, public?), do: s, else: refresh(s)

    cond do
      public? and s.terminal -> {{:error, :terminal}, s}
      ready?(s, public?) -> {dispatching(s, fun), unobserved(s)}
      true -> {{:error, :unavailable}, s}
    end
  end

  defp ready?(s, public?), do: s.confirmed and (s.observed or not public?)

  # A terminal observation stays: the host's own inputs still reach a terminal Run.
  defp unobserved(%{terminal: true} = s), do: s
  defp unobserved(s), do: %{s | observed: false}

  # An engine start, input or control can dispatch a model call before it returns: from
  # it until an observation shows no call ready or running (observe/2), the keep-alive
  # touches the Unit. A terminal Run dispatches nothing.
  defp dispatching(s, fun) do
    unless s.terminal, do: :ets.insert(s.table, {:in_flight, true})
    fun.()
  end

  # The engine's own result; an exit (its call limit) is given back to the caller as
  # the same exit.
  defp pass(s, fun) do
    fun.()
  catch
    :exit, reason ->
      if Process.alive?(s.engine), do: {:engine_exit, reason}, else: {:error, :not_running}
  end

  @impl true
  def handle_info({:ai_delivery, key, delivery}, %{verified: false} = s),
    do: {:noreply, %{s | pending: s.pending ++ [{key, delivery}]}}

  def handle_info({:ai_delivery, key, delivery}, s), do: {:noreply, deliver(s, key, delivery)}

  def handle_info(message, %{route_retry: message} = s) when message in [:verify, :route] do
    s = %{s | route_retry: nil}

    case route(s) do
      {:ok, route} ->
        s = %{s | route: route, verified: true}
        {:noreply, if(message == :verify, do: started(s), else: flush(s))}

      {:error, :transient} ->
        {:noreply, retry_route(s, message)}

      # A start or wake whose route cannot be read fails; a live Run reports.
      {:error, {:permanent, reason}} when message == :verify ->
        {:stop, {:shutdown, {:route, reason}}, unroutable(s, reason)}

      {:error, {:permanent, reason}} ->
        {:noreply, unroutable(s, reason)}
    end
  end

  def handle_info({:retry, id}, s) do
    case {MapSet.member?(s.done, id), s.inputs[id]} do
      {false, %{} = entry} -> {:noreply, submit(s, id, entry)}
      _ -> {:noreply, s}
    end
  end

  def handle_info(:refresh, s), do: {:noreply, refresh(%{s | refreshing: false})}

  def handle_info({:wake_timer, ref}, %{timer: %{ref: ref, target: target}} = s) do
    s = %{s | timer: nil}

    case reads(s) do
      {:ok, %{phase: :terminal}, view} ->
        {:noreply, terminal(observe(s, view), view.outcome)}

      {:ok, d, view} ->
        s = observe(s, view)
        now = s.c.clock.()

        cond do
          # Replaced by a committed deadline: no input.
          target_of(d) != target -> {:noreply, arm(s, d)}
          now >= target -> {:noreply, wake(%{s | fired: target}, target)}
          true -> {:noreply, schedule(s, target, target - now)}
        end

      # No reading: no input; the timer tries again.
      :error ->
        {:noreply, schedule(s, target, @retry_ms)}
    end
  end

  def handle_info({:EXIT, pid, reason}, s) do
    case Enum.find(s.pids, fn {_, p} -> p == pid end) do
      {role, _} -> {:stop, {:shutdown, {:exited, role, reason}}, s}
      nil -> {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp deliver(s, key, {:outcome, _attempt, _outcome} = delivery) do
    cond do
      s.pending != [] ->
        %{s | pending: s.pending ++ [{key, delivery}]}

      route = s.route[key] ->
        outcome(s, route, delivery)

      true ->
        case route(s) do
          {:ok, route} ->
            s = %{s | route: route}

            case route[key] do
              nil -> report(s, "an outcome with no route", key)
              found -> outcome(s, found, delivery)
            end

          # Kept until the route can be read again.
          {:error, :transient} ->
            retry_route(%{s | pending: [{key, delivery}]}, :route)

          {:error, {:permanent, reason}} ->
            report(s, "an outcome that cannot be routed (#{inspect(reason)})", key)
        end
    end
  end

  # The intent owner settles separately; the slot waits for reconciliation or the end
  # of the Run.
  defp deliver(s, key, {:sink_failed, _}), do: report(s, "a sink failure", key)
  defp deliver(s, key, _), do: report(s, "an unknown delivery", key)

  # One received outcome is one engine action_outcome input, under an input ID of the
  # Run, the action's own Attempt and its occurrence. The first submission fixes the
  # frame and the whole context, a pause operand included; a retry sends them again.
  # A delivery of an input that the engine acknowledged gives no input at all.
  defp outcome(s, route, {:outcome, _attempt, outcome}) do
    id = Ai.input_id(s.spec.run_id, route.attempt_id, route.occurrence)

    cond do
      MapSet.member?(s.done, id) ->
        s

      entry = s.inputs[id] ->
        submit(s, id, entry)

      true ->
        case outcome_entry(s, route, outcome) do
          {:error, reason} -> report(s, reason, route.action_id)
          entry -> submit(s, id, entry)
        end
    end
  end

  defp outcome_entry(s, route, outcome) do
    case Ai.translate(outcome, route.ai.usage) do
      {:input, class, dispatch, actual, payload} ->
        {class, dispatch, actual, payload} = bounded(s, class, dispatch, actual, payload)
        {schema_id, version} = Ai.result()

        frame = %{
          "type" => "input",
          "version" => 1,
          "kind" => "action_outcome",
          "action_id" => route.action_id,
          "outcome" => class,
          "schema_id" => schema_id,
          "schema_version" => version,
          "payload" => payload
        }

        base = %{
          run_id: s.spec.run_id,
          attempt_id: route.attempt_id,
          occurrence: route.occurrence,
          dispatch: dispatch
        }

        entry(s, frame, if(actual, do: Map.put(base, :actual, actual), else: base))

      :none ->
        {:error, "an outcome that is no ai-text outcome"}
    end
  end

  # A completed view over the engine's payload bound (65,536 bytes of compact JSON and
  # 32 levels, as core/payload-schema counts them) is the explicit refusal too_large:
  # the call reached the provider, no actual.
  defp bounded(s, "completed" = class, dispatch, actual, payload) do
    with %{compiled: compiled, port: port} <- s.spec.schemas[Ai.result()],
         {:error, reason} when reason in [:too_large, :too_deep] <-
           PayloadSchema.check(compiled, port, payload) do
      {"refused", "dispatched", nil, Ai.refusal_view(:too_large, %{})}
    else
      _ -> {class, dispatch, actual, payload}
    end
  end

  defp bounded(_s, class, dispatch, actual, payload), do: {class, dispatch, actual, payload}

  # Under budget_rule :pause the engine refuses an input without a future pause
  # deadline: it comes from the spec's trusted context, sampled once per entry.
  defp entry(s, frame, base) do
    case pause(s) do
      {:ok, operand} -> %{frame: frame, base: base, context: Map.merge(base, operand)}
      :error -> {:error, "no future pause deadline for an input"}
    end
  end

  defp pause(%{spec: %{budget_rule: :finish}}), do: {:ok, %{}}

  defp pause(s) do
    case s.spec.context.() do
      %{pause_deadline: deadline} when is_integer(deadline) ->
        if deadline > s.c.clock.(), do: {:ok, %{pause_deadline: deadline}}, else: :error

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp submit(s, id, entry) do
    s = put_in(s.inputs[id], entry)

    {reply, s} =
      forward(
        s,
        fn -> call(fn -> RunEngine.input(s.engine, id, entry.frame, entry.context) end) end,
        false
      )

    case reply do
      {:ok, _} ->
        refresh(%{
          s
          | inputs: Map.delete(s.inputs, id),
            retries: Map.delete(s.retries, id),
            done: MapSet.put(s.done, id)
        })

      # Refused before the engine appended anything: a fresh pause operand is taken.
      {:error, :pause_deadline_required} ->
        entry =
          case pause(s) do
            {:ok, operand} -> %{entry | context: Map.merge(entry.base, operand)}
            :error -> entry
          end

        again(put_in(s.inputs[id], entry), id)

      # Nothing is known about the input: it is sent again with the same frame and context.
      reply when reply in [{:error, :unavailable}, :exit] ->
        again(s, id)

      other ->
        s = report(s, "an input the engine refused (#{inspect(other)})", id)
        refresh(%{s | inputs: Map.delete(s.inputs, id)})
    end
  end

  # A host input that the engine did not take is sent again: an outcome by the input
  # retry; a wake only by its timer, which reads the committed deadline and the current
  # Attempt again before it fires, no sooner than a second later (arm/2), so a wake for
  # an Attempt or a deadline that is no longer current is never sent again.
  defp again(s, "wake:" <> _), do: refresh(s)
  defp again(s, id), do: retry(s, id)

  defp retry(s, id) do
    n = Map.get(s.retries, id, 0)

    if n < @retries do
      Process.send_after(self(), {:retry, id}, @retry_ms * (n + 1))
      %{s | retries: Map.put(s.retries, id, n + 1)}
    else
      s = report(s, "an input the engine did not take", id)
      refresh(%{s | inputs: Map.delete(s.inputs, id), retries: Map.delete(s.retries, id)})
    end
  end

  ## Time

  # The committed deadlines, the current Attempt and the terminal phase, read again;
  # a failed read is read again soon and decides nothing.
  defp refresh(%{terminal: true} = s), do: s

  defp refresh(s) do
    case reads(s) do
      {:ok, %{phase: :terminal}, view} -> terminal(observe(s, view), view.outcome)
      {:ok, d, view} -> arm(observe(s, view), d)
      :error -> later(s)
    end
  end

  defp later(%{refreshing: true} = s), do: s

  defp later(s) do
    Process.send_after(self(), :refresh, @retry_ms)
    %{s | refreshing: true}
  end

  defp reads(s) do
    with {:ok, %{} = d} <- call(fn -> RunEngine.deadlines(s.engine) end),
         {:ok, %{} = view} <- call(fn -> RunEngine.status(s.engine) end) do
      {:ok, d, view}
    else
      _ -> :error
    end
  end

  # The current Attempt (the key of each later admission, confirmed by this read), the
  # phase read after the last engine input (observed) and whether a model call is in
  # flight, for the keep-alive.
  defp observe(s, view) do
    in_flight =
      Enum.any?(view.slots, fn {_, slot} ->
        slot.kind == "model_call" and slot.phase in @in_flight
      end)

    true = :ets.insert(s.table, [{:attempt, view.attempt_id}, {:in_flight, in_flight}])
    %{s | attempt: view.attempt_id, confirmed: true, observed: true}
  end

  defp terminal(s, outcome) do
    send(s.host, {:terminal, s.run_ref, s.token, outcome})
    true = :ets.insert(s.table, {:in_flight, false})
    %{disarm(s) | terminal: true}
  end

  defp target_of(%{phase: :paused, run_deadline: run, pause_deadline: pause})
       when is_integer(pause),
       do: min(run, pause)

  defp target_of(%{run_deadline: run}), do: run

  # One correlated timer: while paused at the earlier of the Run and pause deadlines,
  # otherwise at the Run deadline. A target whose wake was already sent is tried again
  # no sooner than a second later.
  defp arm(s, d) do
    target = target_of(d)

    case s.timer do
      %{target: ^target} ->
        s

      _ ->
        delay = target - s.c.clock.()
        delay = if s.fired == target, do: max(delay, 1_000), else: delay
        s |> disarm() |> schedule(target, delay)
    end
  end

  defp schedule(s, target, delay) do
    ref = make_ref()
    timer = Process.send_after(self(), {:wake_timer, ref}, min(max(delay, 0), @max_timer))
    %{s | timer: %{ref: ref, target: target, timer: timer}}
  end

  defp disarm(%{timer: nil} = s), do: s

  defp disarm(%{timer: %{timer: timer}} = s) do
    Process.cancel_timer(timer)
    %{s | timer: nil}
  end

  # One wake input at or after the deadline, under a digest ID of Run, current Attempt
  # and that deadline, with the context that the engine requires.
  defp wake(s, target) do
    spec = s.spec
    id = "wake:" <> hex(:erlang.term_to_binary({spec.run_id, s.attempt, target}, [:deterministic]))

    cond do
      MapSet.member?(s.done, id) ->
        s

      entry = s.inputs[id] ->
        submit(s, id, entry)

      true ->
        frame = %{"type" => "input", "version" => 1, "kind" => "wake"}

        case entry(s, frame, %{run_id: spec.run_id, attempt_id: s.attempt}) do
          {:error, reason} ->
            s |> report(reason, id) |> schedule(target, 1_000)

          # A kept wake of another Attempt or deadline is obsolete: never sent again.
          entry ->
            stale = for {"wake:" <> _ = other, _} <- s.inputs, other != id, do: other
            submit(%{s | inputs: Map.drop(s.inputs, stale)}, id, entry)
        end
    end
  end

  ## Helpers

  defp call(fun) do
    fun.()
  catch
    :exit, _ -> :exit
  end

  defp catch_exit(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end

  defp report(s, what, subject) do
    Logger.warning(
      "Elzoo.RunHost: #{what} for Run #{inspect(s.run_ref)} (#{inspect(subject)}); no engine input"
    )

    s
  end

  defp hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp text?(s, max),
    do:
      is_binary(s) and byte_size(s) in 1..max and String.valid?(s) and
        not String.contains?(s, <<0>>)
end
