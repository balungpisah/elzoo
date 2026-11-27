# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RunHost do
  @moduledoc """
  A supervised host for the `assembly/run-engine` Runs of one node, for one profile
  (text model calls of `integration/ai-text`); the Contract is the Piece README.

  The host process keeps the reservation table (`max_runs`, from reservation through
  confirmed teardown), the Unit directory with its own Registry and dedicated
  DynamicSupervisor, the lease renewals and the teardown of every per-Run process.
  Each Run has one worker (`Elzoo.RunHost.Runner`) that starts it, takes its inputs
  and controls, routes its model-call outcomes and wakes it at its deadlines; the
  host never waits on a worker or an engine, so a slow Run delays no other.
  """
  use GenServer
  alias Elzoo.{DynamicUnits, Lease, RunEngine}
  alias Elzoo.RunApprovalRelease, as: Owner
  alias Elzoo.RunHost.Runner

  @required [
    :owner_id,
    :max_runs,
    :idle_ms,
    :unit_store,
    :run_store,
    :evidence_store,
    :intent_store,
    :activation_store,
    :lease,
    :clock,
    :lease_ttl_ms,
    :spec
  ]
  @optional [:fencing_proof, :on_terminal, :on_lost, :allow_volatile, :name]
  @stores [:unit_store, :run_store, :evidence_store, :intent_store, :activation_store]
  @unit_state %{version: 1, control: nil, slots: %{}, requests: %{}}
  @lost [:lease_lost, :fenced, :indeterminate, :unknown]

  ## Interface

  @doc "Starts one host; the options are listed in the README (Start)."
  def start_link(opts) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Reserves, provisions and starts one Run: `:ok` or `{:error, reason}`."
  def start_run(host, run_ref, spec),
    do: GenServer.call(host, {:start_run, run_ref, spec}, :infinity)

  @doc "Opens Runs that have a current Attempt: one `{run_ref, :woken | {:error, reason}}` each."
  def wake(host, run_refs) when is_list(run_refs),
    do: GenServer.call(host, {:wake, run_refs}, :infinity)

  @doc "Stops every process of a Run, confirms it, releases its lease and frees its reservation."
  def reap(host, run_ref), do: GenServer.call(host, {:reap, run_ref}, :infinity)

  def input(host, run_ref, id, input, context),
    do: business(host, run_ref, {:input, id, input, context})

  def control(host, run_ref, id, command, context),
    do: business(host, run_ref, {:control, id, command, context})

  def status(host, run_ref), do: read(host, run_ref, &RunEngine.status/1)
  def deadlines(host, run_ref), do: read(host, run_ref, &RunEngine.deadlines/1)

  def result(host, run_ref, scope, limits),
    do: read(host, run_ref, &RunEngine.result(&1, scope, limits))

  def transcript(host, run_ref, scope, limits),
    do: read(host, run_ref, &RunEngine.transcript(&1, scope, limits))

  # Business input goes through the Run's worker, which serializes it with the
  # host's own inputs and refreshes the deadlines and the terminal phase after it.
  defp business(host, run_ref, request) do
    with {:ok, worker} <- GenServer.call(host, {:admission, run_ref}) do
      case worker_call(worker, request) do
        # The engine's own call limit: the caller gets the exit that the engine gave.
        {:engine_exit, reason} ->
          exit(reason)

        # The worker ended with its Run (a teardown or a crash).
        :gone ->
          case GenServer.call(host, {:admission, run_ref}) do
            {:ok, _} -> {:error, :not_running}
            error -> error
          end

        reply ->
          reply
      end
    end
  end

  defp worker_call(worker, request) do
    GenServer.call(worker, request, :infinity)
  catch
    :exit, _ -> :gone
  end

  # Reads go to the live engine directly; an engine that is gone is a Run that is
  # not live on this host.
  defp read(host, run_ref, fun) do
    with {:ok, engine} <- GenServer.call(host, {:engine, run_ref}) do
      try do
        fun.(engine)
      catch
        :exit, reason ->
          if Process.alive?(engine), do: exit(reason), else: {:error, :not_running}
      end
    end
  end

  ## Host process

  @impl true
  def init(opts) do
    case options(opts) do
      {:ok, c} ->
        Process.flag(:trap_exit, true)
        n = System.unique_integer([:positive])
        units = Module.concat(__MODULE__, "Units#{n}")
        names = Module.concat(__MODULE__, "Names#{n}")
        table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
        {:ok, _} = Registry.start_link(keys: :unique, name: units)
        {:ok, _} = Registry.start_link(keys: :unique, name: names)

        {:ok, supervisor} =
          DynamicSupervisor.start_link(strategy: :one_for_one, max_children: c.max_runs)

        {:ok, directory} =
          DynamicUnits.start_link(
            registry: units,
            supervisor: supervisor,
            idle_ms: c.idle_ms,
            unit_options: &unit_options(c.unit_store, names, table, &1)
          )

        {:ok, tasks} = Task.Supervisor.start_link()

        {:ok,
         %{
           c: c,
           units: units,
           names: names,
           table: table,
           supervisor: supervisor,
           directory: directory,
           tasks: tasks,
           runs: %{},
           markers: %{},
           receipts: %{},
           lost: %{},
           batches: %{},
           monitors: %{},
           workers: %{},
           jobs: %{}
         }}

      :error ->
        {:stop, :invalid_options}
    end
  end

  defp options(opts) do
    c = Map.new(opts)

    with true <- Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in @required or &1 in @optional)),
         true <- Enum.all?(@required, &Map.has_key?(c, &1)),
         true <- text?(c.owner_id, 200),
         true <- is_integer(c.max_runs) and c.max_runs > 0,
         true <- is_integer(c.idle_ms) and c.idle_ms in 1..4_294_967_295,
         true <- stores?(Enum.map(@stores, &c[&1])),
         %Lease{store: store} <- c.lease,
         true <- store == c.run_store,
         true <- is_function(c.clock, 0) and is_function(c.spec, 1),
         true <- is_integer(c.lease_ttl_ms) and c.lease_ttl_ms in 1..86_400_000,
         true <- optional_fun?(c[:fencing_proof], 1),
         true <- optional_fun?(c[:on_terminal], 2) and optional_fun?(c[:on_lost], 2),
         true <- Map.get(c, :allow_volatile, false) in [true, false] do
      {:ok,
       Map.merge(%{fencing_proof: nil, on_terminal: nil, on_lost: nil, allow_volatile: false}, c)}
    else
      _ -> :error
    end
  end

  # Every view is a Store tuple of one adapter: PostgreSQL views share the Repo and
  # prefix, Memory views share the Memory process.
  defp stores?(stores) do
    namespaces =
      Enum.map(stores, fn
        {Elzoo.DurableLog.Postgres, %{repo: repo} = o} ->
          {:postgres, repo, Map.get(o, :prefix, "public")}

        {Elzoo.DurableLog.Memory, %{pid: pid}} ->
          {:memory, pid}

        _ ->
          :invalid
      end)

    :invalid not in namespaces and length(Enum.uniq(namespaces)) == 1
  end

  defp optional_fun?(nil, _), do: true
  defp optional_fun?(fun, arity), do: is_function(fun, arity)

  # The Unit options of the directory: the engine's Operator, the retention of the
  # Run that the Unit hosts, and an offer that only sends each Outbox item to the
  # engine registered under the Unit's identity.
  defp unit_options(store, names, table, identity) do
    [{^identity, retention}] = :ets.lookup(table, identity)

    [
      operator: {RunEngine, :step, @unit_state},
      retention_count: retention,
      max_record_bytes: 16_777_216,
      max_checkpoint_bytes: 33_554_432,
      store: store,
      offer: fn item ->
        case Registry.lookup(names, identity) do
          [{pid, _}] -> send(pid, item)
          [] -> :ok
        end

        :ok
      end
    ]
  end

  @impl true
  def handle_call({:start_run, run_ref, spec}, from, s),
    do: {:noreply, request(s, run_ref, {:start, spec}, {:start, from})}

  def handle_call({:wake, run_refs}, from, s) do
    id = make_ref()
    s = put_in(s.batches[id], %{from: from, refs: run_refs, results: %{}})

    s =
      run_refs
      |> Enum.uniq()
      |> Enum.reduce(s, fn run_ref, acc -> request(acc, run_ref, :wake, {:wake, id, run_ref}) end)

    {:noreply, complete(s, id)}
  end

  def handle_call({:reap, run_ref}, from, s) do
    case s.runs[run_ref] do
      %{phase: :live} = run ->
        {:noreply, teardown(s, run_ref, %{run | waiters: [{:reap, from}]}, true)}

      %{phase: :tearing_down} = run ->
        {:noreply, put_in(s.runs[run_ref], %{run | waiters: run.waiters ++ [{:reap, from}]})}

      _ ->
        {:reply, {:error, :not_running}, s}
    end
  end

  def handle_call({:admission, run_ref}, _, s) do
    reply =
      case s.runs[run_ref] do
        %{phase: :live, admission: :open, worker: worker} ->
          {:ok, worker}

        %{phase: :live, admission: :terminal} ->
          {:error, :terminal}

        %{admission: :lease_lost} ->
          {:error, :lease_lost}

        _ ->
          if Map.has_key?(s.lost, run_ref), do: {:error, :lease_lost}, else: {:error, :not_running}
      end

    {:reply, reply, s}
  end

  def handle_call({:engine, run_ref}, _, s) do
    case s.runs[run_ref] do
      %{phase: :live, pids: %{engine: engine}} -> {:reply, {:ok, engine}, s}
      _ -> {:reply, {:error, :not_running}, s}
    end
  end

  # From the activation callback, inside an EffectIntent process: every such process
  # is tracked for teardown; only the current incarnation of a Run whose predecessor
  # check has passed is granted an activation.
  def handle_call({:authorize, run_ref, token, pid}, _, s) do
    case s.runs[run_ref] do
      %{token: ^token} = run ->
        ref = Process.monitor(pid)
        s = put_in(s.monitors[ref], {run_ref, token, :intent})
        run = %{run | intents: Map.put(run.intents, pid, ref)}
        reply = if run.granted, do: :granted, else: :denied
        {:reply, reply, put_in(s.runs[run_ref], run)}

      _ ->
        {:reply, :denied, s}
    end
  end

  def handle_call({:intents, run_ref, token}, _, s) do
    case s.runs[run_ref] do
      %{token: ^token, intents: intents} -> {:reply, Map.keys(intents), s}
      _ -> {:reply, [], s}
    end
  end

  # The start sequence of a worker.
  def handle_call({:runner, run_ref, token, message}, _, s) do
    case s.runs[run_ref] do
      %{token: ^token, phase: :starting} = run ->
        {reply, run, s} = runner(message, run_ref, run, s)
        {:reply, reply, put_in(s.runs[run_ref], run)}

      _ ->
        {:reply, {:error, :stale}, s}
    end
  end

  defp runner({:unit, unit, retention}, run_ref, run, s) do
    if Enum.any?(s.runs, fn {ref, r} -> ref != run_ref and r.unit == unit end) do
      {{:error, :identity_in_use}, run, s}
    else
      :ets.insert(s.table, {unit, retention})
      {:ok, %{run | unit: unit, stream: "run/" <> unit}, s}
    end
  end

  defp runner({:held, held, started}, run_ref, run, s) do
    {:ok, schedule_lease(%{run | held: held}, run_ref, started, s.c.lease_ttl_ms), s}
  end

  defp runner({:track, role, pid}, run_ref, run, s) do
    ref = Process.monitor(pid)
    s = put_in(s.monitors[ref], {run_ref, run.token, role})
    {:ok, %{run | pids: Map.put(run.pids, role, pid)}, s}
  end

  # Confirmed teardown covers the predecessors when nothing was written to the Run
  # stream between the teardown and this claim; the marker is taken once.
  defp runner({:predecessor, revision}, run_ref, run, s) do
    {marker, markers} = Map.pop(s.markers, run_ref)
    reply = if is_integer(marker) and marker == revision - 1, do: :confirmed, else: :proof
    {reply, run, %{s | markers: markers}}
  end

  defp runner(:grant, _run_ref, run, s), do: {:ok, %{run | granted: true, clean: true}, s}

  @impl true
  def handle_info({:started, run_ref, token}, s) do
    case s.runs[run_ref] do
      %{token: ^token, phase: :starting} = run ->
        s = %{s | receipts: Map.delete(s.receipts, run_ref)}
        s = put_in(s.runs[run_ref], %{run | phase: :live, admission: :open, waiters: []})
        {:noreply, Enum.reduce(run.waiters, s, &answer(&2, &1, :started))}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:terminal, run_ref, token, outcome}, s) do
    case s.runs[run_ref] do
      %{token: ^token, admission: :open} = run ->
        callback(s, s.c.on_terminal, [run_ref, outcome])
        {:noreply, put_in(s.runs[run_ref], %{run | admission: :terminal})}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:renew, run_ref, token, generation}, s) do
    case s.runs[run_ref] do
      %{token: ^token, lease: %{generation: ^generation, renewing: false}, pids: %{owner: owner}} =
          run ->
        ttl = s.c.lease_ttl_ms

        job =
          Task.Supervisor.async_nolink(s.tasks, fn ->
            started = now()

            try do
              {started, Owner.renew(owner, ttl)}
            catch
              # A renewal that exits on its caller timeout is unconfirmed.
              :exit, _ -> {started, {:unknown, :no_receipt}}
            end
          end)

        s = put_in(s.jobs[job.ref], {:renew, run_ref, token, generation})
        {:noreply, put_in(s.runs[run_ref], put_in(run.lease.renewing, true))}

      %{token: ^token, lease: %{generation: ^generation, renewing: false}} ->
        # The Run owner is not started yet: the renewal waits for it.
        Process.send_after(self(), {:renew, run_ref, token, generation}, 10)
        {:noreply, s}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:expiry, run_ref, token, generation}, s) do
    case s.runs[run_ref] do
      %{token: ^token, lease: %{generation: ^generation}} -> {:noreply, lost(s, run_ref, :expired)}
      _ -> {:noreply, s}
    end
  end

  def handle_info({:retry_teardown, run_ref, token}, s) do
    case s.runs[run_ref] do
      %{token: ^token, phase: :tearing_down} = run -> {:noreply, fence(s, run_ref, run)}
      _ -> {:noreply, s}
    end
  end

  def handle_info({ref, result}, s) when is_reference(ref) and is_map_key(s.jobs, ref) do
    Process.demonitor(ref, [:flush])
    {job, jobs} = Map.pop(s.jobs, ref)
    {:noreply, job(%{s | jobs: jobs}, job, result)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, s) when is_map_key(s.jobs, ref) do
    {job, jobs} = Map.pop(s.jobs, ref)
    {:noreply, job(%{s | jobs: jobs}, job, {:crashed, reason})}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, s) do
    case Map.pop(s.monitors, ref) do
      {{run_ref, token, role}, monitors} ->
        {:noreply, down(%{s | monitors: monitors}, run_ref, token, role, pid, reason)}

      {nil, _} ->
        {:noreply, s}
    end
  end

  # The host traps exits: its own infrastructure ending ends the host. A worker is
  # linked from its start, so its exit reason is never lost to a late monitor.
  def handle_info({:EXIT, pid, reason}, s) do
    cond do
      pid in [s.supervisor, s.directory, s.tasks] ->
        {:stop, {:infrastructure, reason}, s}

      Map.has_key?(s.workers, pid) ->
        {{run_ref, token}, workers} = Map.pop(s.workers, pid)
        {:noreply, down(%{s | workers: workers}, run_ref, token, :worker, pid, reason)}

      true ->
        {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  ## Requests

  defp request(s, run_ref, mode, waiter) do
    case s.runs[run_ref] do
      %{phase: :tearing_down} = run ->
        put_in(s.runs[run_ref], %{run | deferred: run.deferred ++ [{mode, waiter}]})

      %{} ->
        answer(s, waiter, {:error, :running})

      nil ->
        if map_size(s.runs) >= s.c.max_runs do
          answer(s, waiter, {:error, :capacity})
        else
          token = make_ref()

          {:ok, worker} =
            Runner.start_link(%{
              host: self(),
              run_ref: run_ref,
              token: token,
              mode: mode,
              c: s.c,
              names: s.names,
              directory: s.directory,
              receipt: s.receipts[run_ref]
            })

          run = %{
            token: token,
            phase: :starting,
            admission: nil,
            worker: worker,
            pids: %{worker: worker},
            intents: %{},
            waiters: [waiter],
            deferred: [],
            unit: nil,
            stream: nil,
            held: nil,
            lease: nil,
            clean: false,
            granted: false,
            result: nil,
            release: false
          }

          s = put_in(s.workers[worker], {run_ref, token})
          s = %{s | lost: Map.delete(s.lost, run_ref)}
          put_in(s.runs[run_ref], run)
        end
    end
  end

  defp answer(s, {:start, from}, :started), do: tap(s, fn _ -> GenServer.reply(from, :ok) end)
  defp answer(s, {:start, from}, error), do: tap(s, fn _ -> GenServer.reply(from, error) end)
  defp answer(s, {:reap, from}, _), do: tap(s, fn _ -> GenServer.reply(from, :ok) end)

  defp answer(s, {:wake, id, run_ref}, result) do
    result = if result == :started, do: :woken, else: result

    case s.batches[id] do
      %{} -> complete(put_in(s.batches[id].results[run_ref], result), id)
      nil -> s
    end
  end

  defp complete(s, id) do
    batch = s.batches[id]

    if Enum.all?(batch.refs, &Map.has_key?(batch.results, &1)) do
      GenServer.reply(batch.from, Enum.map(batch.refs, &{&1, batch.results[&1]}))
      %{s | batches: Map.delete(s.batches, id)}
    else
      s
    end
  end

  ## Leases

  # Lease `until` is in the lease clock's Unix microseconds and `until - at` of every
  # token is the TTL. Each lease call starts after `started` on this node's monotonic
  # clock and the lease samples `at` inside it, so `until` is no earlier than
  # `started + ttl` (for a lease clock that does not run faster than this node's
  # clock). The renewal starts half the TTL before that estimate, so that a renewal
  # that waits the whole 5,000 ms caller limit of `renew/2` still ends before it for a
  # TTL of 10 s or more; admission stops at the estimate when no renewal is confirmed.
  defp schedule_lease(run, run_ref, started, ttl) do
    generation = make_ref()
    until = started + ttl
    renew_at = until - max(div(ttl, 2), 1)
    Process.send_after(self(), {:renew, run_ref, run.token, generation}, max(renew_at - now(), 0))
    Process.send_after(self(), {:expiry, run_ref, run.token, generation}, max(until - now(), 0))
    %{run | lease: %{generation: generation, until: until, renewing: false}}
  end

  defp job(s, {:renew, run_ref, token, generation}, result) do
    case s.runs[run_ref] do
      %{token: ^token, lease: %{generation: ^generation}} = run ->
        renewed(s, run_ref, put_in(run.lease.renewing, false), result)

      _ ->
        s
    end
  end

  defp job(s, {:teardown, run_ref, token}, result) do
    case s.runs[run_ref] do
      %{token: ^token, phase: :tearing_down} = run -> torn_down(s, run_ref, run, result)
      _ -> s
    end
  end

  defp renewed(s, run_ref, run, {started, {:ok, _revision, %{until: until}}})
       when is_integer(until),
       do: put_in(s.runs[run_ref], schedule_lease(run, run_ref, started, s.c.lease_ttl_ms))

  # A definite no-write error keeps the token: the renewal is tried again, and the
  # expiry estimate stays as it was.
  defp renewed(s, run_ref, run, {_, {:error, _}}) do
    ttl = s.c.lease_ttl_ms
    delay = max(div(ttl, 12), 1)
    Process.send_after(self(), {:renew, run_ref, run.token, run.lease.generation}, delay)
    put_in(s.runs[run_ref], run)
  end

  defp renewed(s, run_ref, run, {_, {:refused, reason}}),
    do: lost(put_in(s.runs[run_ref], run), run_ref, reason)

  defp renewed(s, run_ref, run, {_, {:indeterminate, _} = reason}),
    do: lost(put_in(s.runs[run_ref], run), run_ref, reason)

  defp renewed(s, run_ref, run, _),
    do: lost(put_in(s.runs[run_ref], run), run_ref, {:unknown, :no_receipt})

  # Stops admission, calls on_lost and fences every process of the Run. Only an
  # indeterminate result keeps a receipt for `reconcile:` at a later start.
  defp lost(s, run_ref, reason) do
    case s.runs[run_ref] do
      %{phase: phase, admission: admission} = run
      when phase in [:starting, :live] and admission != :lease_lost ->
        s =
          case reason do
            {:indeterminate, receipt} -> put_in(s.receipts[run_ref], receipt)
            _ -> s
          end

        callback(s, s.c.on_lost, [run_ref, reason])
        s = put_in(s.lost[run_ref], reason)
        run = %{run | admission: :lease_lost, result: {:error, :lease_lost}}
        teardown(s, run_ref, run, false)

      _ ->
        s
    end
  end

  ## Teardown

  defp down(s, run_ref, token, role, pid, reason) do
    case s.runs[run_ref] do
      %{token: ^token} = run ->
        cond do
          role == :intent ->
            put_in(s.runs[run_ref], %{run | intents: Map.delete(run.intents, pid)})

          run.phase == :tearing_down ->
            s

          role == :owner and lost_reason?(reason) ->
            {:shutdown, lost} = reason
            lost(s, run_ref, lost)

          run.phase == :starting and role == :worker ->
            teardown(s, run_ref, %{run | result: {:error, start_error(reason)}}, run.held != nil)

          run.phase == :starting ->
            s

          true ->
            teardown(s, run_ref, run, false)
        end

      _ ->
        s
    end
  end

  defp lost_reason?({:shutdown, {tag, _}}) when tag in @lost, do: true
  defp lost_reason?(_), do: false

  defp start_error({:shutdown, reason}), do: reason
  defp start_error(reason), do: {:start_failed, reason}

  defp teardown(s, run_ref, run, release) do
    run = %{run | phase: :tearing_down, granted: false, lease: nil, release: release}
    fence(s, run_ref, run)
  end

  defp fence(s, run_ref, run) do
    t = %{
      host: self(),
      run_ref: run_ref,
      token: run.token,
      pids: run.pids,
      unit: run.unit,
      stream: run.stream,
      held: run.held != nil,
      release: run.release,
      clean: run.clean,
      units: s.units,
      directory: s.directory,
      supervisor: s.supervisor,
      lease: s.c.lease,
      owner_id: s.c.owner_id
    }

    job = Task.Supervisor.async_nolink(s.tasks, fn -> confirm(t) end)
    s = put_in(s.jobs[job.ref], {:teardown, run_ref, run.token})
    put_in(s.runs[run_ref], run)
  end

  defp torn_down(s, run_ref, run, %{confirmed: true, marker: marker}) do
    if run.unit, do: :ets.delete(s.table, run.unit)

    # A start that ended before its claim wrote nothing: an earlier marker stays.
    markers =
      cond do
        is_integer(marker) -> Map.put(s.markers, run_ref, marker)
        run.held != nil -> Map.delete(s.markers, run_ref)
        true -> s.markers
      end

    s = %{s | runs: Map.delete(s.runs, run_ref), markers: markers}

    result = run.result || {:error, :not_running}
    s = Enum.reduce(run.waiters, s, &answer(&2, &1, result))
    Enum.reduce(run.deferred, s, fn {mode, waiter}, acc -> request(acc, run_ref, mode, waiter) end)
  end

  # Not confirmed (the Unit's stop, or the teardown itself, failed): the Run keeps its
  # reservation and the teardown runs again.
  defp torn_down(s, run_ref, run, _) do
    Process.send_after(self(), {:retry_teardown, run_ref, run.token}, 1_000)
    s
  end

  @doc false
  # Runs in a host task: stops every process of one Run (engine, EffectIntent owners,
  # AsyncWork, the task supervisor and its tasks, Run owner, evidence Writer, worker,
  # Unit) and waits for each to be gone, then releases the lease when asked and takes
  # the predecessor marker. The engine goes first, so it starts no other process; the
  # worker then ends by itself with its linked processes, with no error report.
  def confirm(t) do
    kill([t.pids[:engine]])
    kill(GenServer.call(t.host, {:intents, t.run_ref, t.token}, :infinity))
    kill([t.pids[:async]])
    kill_supervisor(t.pids[:tasks])
    kill([t.pids[:owner], t.pids[:evidence], t.pids[:worker]])
    unit = if t.unit, do: stop_unit(t), else: :ok
    %{confirmed: unit == :ok, marker: if(unit == :ok and t.held, do: lease_end(t))}
  catch
    _, _ -> %{confirmed: false, marker: nil}
  end

  defp kill(pids) do
    pids
    |> Enum.filter(&is_pid/1)
    |> Enum.map(fn pid ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      ref
    end)
    |> Enum.each(&await/1)
  end

  defp kill_supervisor(nil), do: :ok

  defp kill_supervisor(supervisor) do
    children =
      try do
        Task.Supervisor.children(supervisor)
      catch
        :exit, _ -> []
      end

    refs = Enum.map([supervisor | children], &Process.monitor/1)
    Process.exit(supervisor, :kill)
    Enum.each(children, &Process.exit(&1, :kill))
    Enum.each(refs, &await/1)
  end

  # The Unit is stopped through its directory (a confirmed `:ok` removes its child
  # specification); the processes that the Unit started itself are waited for too.
  defp stop_unit(t) do
    refs = Enum.map(unit_processes(t.units, t.unit), &Process.monitor/1)

    case DynamicUnits.stop(t.directory, t.unit) do
      :ok ->
        Enum.each(refs, &await/1)
        :ok

      other ->
        Enum.each(refs, &Process.demonitor(&1, [:flush]))
        other
    end
  end

  @doc false
  # The live Unit of an identity and the linked processes that it started.
  def unit_processes(units, unit) do
    case Registry.lookup(units, unit) do
      [{pid, _}] ->
        {:links, links} = Process.info(pid, :links) || {:links, []}
        [pid | Enum.filter(links, &(is_pid(&1) and parent(&1) == pid))]

      [] ->
        []
    end
  end

  defp parent(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> List.first(dictionary[:"$ancestors"] || [])
      nil -> nil
    end
  end

  defp await(ref) do
    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    end
  end

  # The marker of a confirmed teardown: the Run stream's revision when the latest
  # lease record is this owner's own (its claim or renewal, or its release right
  # after it), so that no other owner can have claimed the key since this tenure
  # began clean. A later claim directly after it passes the predecessor check.
  defp lease_end(t) do
    with {:ok, %{holder: %{owner: owner}, revision: revision}} when owner == t.owner_id <-
           Lease.status(t.lease, t.stream) do
      marker =
        if t.release do
          case Lease.release(t.lease, t.stream, t.owner_id) do
            {:free, %{revision: released}} when released == revision + 1 -> released
            _ -> nil
          end
        else
          revision
        end

      if t.clean, do: marker
    else
      _ -> nil
    end
  end

  defp callback(_s, nil, _), do: :ok

  defp callback(s, fun, args) do
    {:ok, _} = Task.Supervisor.start_child(s.tasks, fn -> apply(fun, args) end)
    :ok
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp text?(s, max),
    do:
      is_binary(s) and byte_size(s) in 1..max and String.valid?(s) and
        not String.contains?(s, <<0>>)
end
