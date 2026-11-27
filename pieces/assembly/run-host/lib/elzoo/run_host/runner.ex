# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RunHost.Runner do
  @moduledoc """
  The worker of one Run of `Elzoo.RunHost`: it starts the Run (lease claim, Run
  owner, Run and Attempt, predecessor check, evidence Writer, AsyncWork, engine),
  then serializes every engine input of the Run: the caller's inputs and controls,
  the outcomes that the sink of its AI bindings receives and the wakes at its
  committed deadlines. It refreshes the deadlines and the terminal phase after each.
  The host links it and tears it down with the Run.
  """
  use GenServer, restart: :temporary
  require Logger
  alias Elzoo.{AsyncWork, Lease, RunEngine}
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

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)

    s =
      Map.merge(args, %{
        spec: nil,
        ai: %{},
        ids: nil,
        held: nil,
        intents: %{},
        bindings: %{},
        gate: nil,
        pids: %{},
        engine: nil,
        name: nil,
        route: %{},
        verified: false,
        buffer: [],
        inputs: %{},
        retries: %{},
        terminal: false,
        timer: nil
      })

    {:ok, s, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, s) do
    case start(s) do
      {:ok, s} ->
        send(s.host, {:started, s.run_ref, s.token})
        {:noreply, refresh(s)}

      {:error, reason} ->
        {:stop, {:shutdown, reason}, s}
    end
  end

  ## Start

  defp start(s) do
    with {:ok, spec} <- spec(s),
         {:ok, s} <- describe(s, spec),
         :ok <- host(s, {:unit, spec.unit, spec.retention}),
         {:ok, s} <- claim(s),
         {:ok, s} <- start_child(s, :tasks, fn -> Task.Supervisor.start_link() end),
         s = provision(s),
         {:ok, s} <- start_owner(s),
         {:ok, existing} <- open_run(s),
         :ok <- predecessor(s, existing),
         :ok <- host(s, :grant),
         {:ok, s} <- start_child(s, :evidence, fn -> evidence(s) end),
         {:ok, s} <- start_child(s, :async, fn -> async(s) end),
         {:ok, s} <- start_engine(s) do
      {:ok, verify(s)}
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
         true <- text?(spec.operation_id, 200) and text?(spec.unit, 160),
         true <- text?(spec.tenant, 200) and text?(spec.principal, 200),
         true <- is_map(spec.bindings) and is_map(spec.provider_refs),
         true <- is_map(spec.budget) and Map.has_key?(spec.budget, :unit),
         true <- is_map(spec.gate) and is_function(spec.gate[:call], 2),
         true <- is_function(spec.context, 0) and spec.budget_rule in [:pause, :finish],
         true <- is_integer(spec.run_deadline) and is_integer(spec.retention) and spec.retention > 0,
         {:profile, true} <- {:profile, Enum.all?(Map.keys(spec.bindings), &(&1 in @kinds))},
         {:ok, ai} <- Ai.descriptors(spec.ai),
         {:ok, ai} <- configure(ai, spec.tenant) do
      ids = %{run_id: spec.run_id, attempt_id: spec.attempt_id, run_deadline: spec.run_deadline}
      {:ok, %{s | spec: spec, ai: ai, ids: ids}}
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

  defp claim(s) do
    started = System.monotonic_time(:millisecond)
    stream = "run/" <> s.spec.unit

    case Lease.claim(s.c.lease, stream, s.c.owner_id, s.c.lease_ttl_ms) do
      {:held, held} ->
        :ok = host(s, {:held, held, started})
        {:ok, %{s | held: held}}

      {:lease_refused, refusal} ->
        {:error, {:lease_refused, refusal}}

      other ->
        {:error, {:lease, other}}
    end
  end

  # The EffectIntent startup bindings of the Run, provisioned once at its start and
  # given to both the Run owner and the engine; the engine's model_call bindings and
  # the gate with the ai-text admission in front of the spec's gate.
  defp provision(s) do
    authorize = authorize(s.host, s.run_ref, s.token)
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

  # Runs inside an EffectIntent process, in its init: the host tracks the process
  # and grants an activation only to a Run whose predecessor check has passed.
  defp authorize(host, run_ref, token) do
    fn request, generation ->
      case GenServer.call(host, {:authorize, run_ref, token, self()}) do
        :granted ->
          if request.revision == 0 and generation == 0,
            do: :fresh,
            else: {:recovered, generation}

        _ ->
          :refused
      end
    end
  end

  defp start_owner(s) do
    opts =
      [store: s.c.run_store, lease: s.c.lease, held: s.held, effect_intent: s.intents] ++
        if(s.receipt, do: [reconcile: s.receipt], else: [])

    start_child(s, :owner, fn -> Owner.start_link(opts) end)
  end

  # A start creates the Run and begins its Attempt with the spec's stable IDs; a
  # retry gets `{:unchanged, :duplicate, _}` for both. A wake opens only a Run whose
  # current Attempt is the spec's. Returns whether a Run or Unit journal existed.
  defp open_run(%{mode: :wake} = s) do
    case Owner.status(s.pids.owner, s.spec.run_id) do
      {:ok, %{current_attempt: attempt}} when attempt == s.spec.attempt_id -> {:ok, true}
      {:ok, %{current_attempt: attempt}} when is_binary(attempt) -> {:error, :incompatible_recovery}
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

    with {:ok, created} <- command(s, create),
         {:ok, attempt} <- attempt(s),
         true <- attempt in [nil, spec.attempt_id] || {:error, :incompatible_recovery},
         begin = %{
           kind: :begin_attempt,
           run_id: spec.run_id,
           attempt_id: spec.attempt_id,
           expected_revision: revision(s)
         },
         {:ok, _} <- command(s, begin) do
      {:ok, created == :duplicate or unit_journal?(s)}
    end
  end

  defp command(s, command) do
    case Owner.command(s.pids.owner, command) do
      {:ok, _, _} -> {:ok, :applied}
      {:unchanged, :duplicate, _} -> {:ok, :duplicate}
      other -> {:error, {:start_failed, {command.kind, other}}}
    end
  end

  defp attempt(s) do
    case Owner.status(s.pids.owner, s.spec.run_id) do
      {:ok, view} -> {:ok, view.current_attempt}
      other -> {:error, {:start_failed, {:status, other}}}
    end
  end

  defp revision(s) do
    case Owner.status(s.pids.owner, s.spec.run_id) do
      {:ok, view} -> view.revision
      _ -> s.held.live.revision
    end
  end

  defp unit_journal?(s) do
    case Store.read(s.c.unit_store, :head, [s.spec.unit]) do
      {:ok, %{revision: 0}} -> false
      _ -> true
    end
  end

  # Before any engine starts on an existing journal: confirmed teardown of every
  # process this host tracked (the host's marker), or a fresh `:fenced` from the
  # caller's fencing proof, asked again each time.
  defp predecessor(_s, false), do: :ok

  defp predecessor(s, true) do
    case host(s, {:predecessor, s.held.live.revision}) do
      :confirmed -> :ok
      :proof -> proof(s.c.fencing_proof, s.run_ref)
    end
  end

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
      owner: {:via, Registry, {s.names, s.spec.unit}},
      task_supervisor: s.pids.tasks,
      max_concurrency: 1
    )
  end

  defp start_engine(s) do
    spec = s.spec
    name = {:via, Registry, {s.names, spec.unit}}

    opts = [
      name: name,
      identity: spec.unit,
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
        {:ok, %{s | engine: s.pids.engine, name: name}}

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
  # binding (its occurrence, Attempt and action ID, from the transcript) under the
  # key that ai-text derives from the stable binding configuration. Until it is
  # verified, deliveries are held.
  defp verify(s) do
    case route(s) do
      {:ok, route} ->
        Enum.reduce(s.buffer, %{s | route: route, verified: true, buffer: []}, fn {key, d}, acc ->
          deliver(acc, key, d)
        end)

      :error ->
        Process.send_after(self(), :verify, 1_000)
        s
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
             ref = Ai.ref(spec.run_id, spec.attempt_id, e.action_id)

             {Ai.intent_key(d, spec.tenant, ref),
              %{attempt_id: e.attempt_id, action_id: e.action_id, occurrence: e.occurrence, ai: d}}
           end
         )}

      _ ->
        :error
    end
  end

  ## Inputs

  @impl true
  def handle_call(_, _, %{terminal: true} = s), do: {:reply, {:error, :terminal}, s}

  def handle_call({:input, id, input, context}, _, s) do
    reply = pass(s, fn -> RunEngine.input(s.engine, id, input, context) end)
    {:reply, reply, refresh(s)}
  end

  # The host forwards no Approval control and begins no other Attempt than the
  # spec's (README, Profile).
  def handle_call({:control, _, %{kind: kind}, _}, _, s)
      when kind in [:approval_evidence, :begin_attempt],
      do: {:reply, {:error, :outside_profile}, s}

  def handle_call({:control, id, command, context}, _, s) do
    reply = pass(s, fn -> RunEngine.control(s.engine, id, command, context) end)
    {:reply, reply, refresh(s)}
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
    do: {:noreply, %{s | buffer: s.buffer ++ [{key, delivery}]}}

  def handle_info({:ai_delivery, key, delivery}, s), do: {:noreply, deliver(s, key, delivery)}

  def handle_info(:verify, %{verified: false} = s), do: {:noreply, verify(s)}

  def handle_info({:retry, id}, s) do
    case s.inputs[id] do
      nil -> {:noreply, s}
      entry -> {:noreply, submit(s, id, entry)}
    end
  end

  def handle_info({:wake_timer, ref}, %{timer: %{ref: ref, target: target}} = s) do
    s = refresh(s)

    case s.timer do
      %{ref: ^ref} ->
        if s.c.clock.() >= target,
          do: {:noreply, wake(s, target)},
          else: {:noreply, s |> disarm() |> schedule(target, target - s.c.clock.())}

      # Replaced by a refreshed deadline, or the Run ended: no input.
      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:EXIT, pid, reason}, s) do
    case Enum.find(s.pids, fn {_, p} -> p == pid end) do
      {role, _} -> {:stop, {:shutdown, {:exited, role, reason}}, s}
      nil -> {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  # One received outcome is one engine action_outcome input, under an input ID of the
  # Run, Attempt and occurrence. The first submission fixes the frame and the whole
  # context, including a pause operand: a retry and a duplicate delivery send them
  # again, so the engine answers a duplicate, never a second settlement.
  defp deliver(s, key, {:outcome, _attempt, outcome}) do
    case route_for(s, key) do
      {nil, s} ->
        report(s, "an outcome with no route", key)

      {route, s} ->
        id = Ai.input_id(s.spec.run_id, route.attempt_id, route.occurrence)

        case s.inputs[id] || outcome_input(s, route, outcome) do
          {:error, reason} -> report(s, reason, route.action_id)
          entry -> submit(s, id, entry)
        end
    end
  end

  # The intent owner settles separately; the slot waits for reconciliation or the end
  # of the Run.
  defp deliver(s, key, {:sink_failed, _}), do: report(s, "a sink failure", key)
  defp deliver(s, key, _), do: report(s, "an unknown delivery", key)

  defp route_for(s, key) do
    case s.route[key] do
      nil ->
        case route(s) do
          {:ok, route} -> {route[key], %{s | route: route}}
          :error -> {nil, s}
        end

      route ->
        {route, s}
    end
  end

  defp outcome_input(s, route, outcome) do
    case Ai.translate(outcome, route.ai.usage) do
      {:input, class, dispatch, actual, payload} ->
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

        context = %{
          run_id: s.spec.run_id,
          attempt_id: route.attempt_id,
          occurrence: route.occurrence,
          dispatch: dispatch
        }

        context = if actual, do: Map.put(context, :actual, actual), else: context

        case pause(s) do
          {:ok, operand} -> {frame, Map.merge(context, operand)}
          :error -> {:error, "no future pause deadline for an outcome"}
        end

      :none ->
        {:error, "an outcome that is no ai-text outcome"}
    end
  end

  # Under budget_rule :pause the engine refuses an input without a future pause
  # deadline: it comes from the spec's trusted context, sampled once per input.
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

  defp submit(s, id, {frame, context} = entry) do
    s = put_in(s.inputs[id], entry)

    case call(fn -> RunEngine.input(s.engine, id, frame, context) end) do
      {:ok, _} ->
        refresh(%{s | retries: Map.delete(s.retries, id)})

      # Nothing is known about the input: it is sent again under the same ID.
      reply when reply in [{:error, :unavailable}, :exit] ->
        retries = Map.get(s.retries, id, 0)

        if retries < @retries do
          Process.send_after(self(), {:retry, id}, @retry_ms * (retries + 1))
          %{s | retries: Map.put(s.retries, id, retries + 1)}
        else
          report(s, "an input the engine did not take", id)
        end

      other ->
        s = report(s, "an input the engine refused (#{inspect(other)})", id)
        refresh(s)
    end
  end

  ## Time

  defp refresh(%{terminal: true} = s), do: s

  defp refresh(s) do
    case call(fn -> RunEngine.deadlines(s.engine) end) do
      {:ok, %{phase: :terminal}} -> terminal(s)
      {:ok, deadlines} -> arm(s, deadlines)
      _ -> s
    end
  end

  defp terminal(s) do
    outcome =
      case call(fn -> RunEngine.status(s.engine) end) do
        {:ok, view} -> view.outcome
        _ -> nil
      end

    send(s.host, {:terminal, s.run_ref, s.token, outcome})
    %{disarm(s) | terminal: true}
  end

  # One correlated timer: while paused at the earlier of the Run and pause deadlines,
  # otherwise at the Run deadline.
  defp arm(s, %{phase: phase, run_deadline: run, pause_deadline: pause}) do
    target = if phase == :paused and is_integer(pause), do: min(run, pause), else: run

    case s.timer do
      %{target: ^target} -> s
      _ -> s |> disarm() |> schedule(target, target - s.c.clock.())
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

  # One wake input at or after the deadline, under a digest ID of Run, Attempt and
  # that deadline, with the context the engine requires.
  defp wake(s, target) do
    spec = s.spec

    id =
      "wake:" <>
        hex(:erlang.term_to_binary({spec.run_id, spec.attempt_id, target}, [:deterministic]))

    case s.inputs[id] do
      nil ->
        case pause(s) do
          {:ok, operand} ->
            context = Map.merge(%{run_id: spec.run_id, attempt_id: spec.attempt_id}, operand)
            submit(s, id, {%{"type" => "input", "version" => 1, "kind" => "wake"}, context})

          :error ->
            s = report(s, "no future pause deadline for a wake", id)
            s |> disarm() |> schedule(target, 1_000)
        end

      entry ->
        submit(s, id, entry)
    end
  end

  ## Helpers

  defp call(fun) do
    fun.()
  catch
    :exit, _ -> :exit
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
