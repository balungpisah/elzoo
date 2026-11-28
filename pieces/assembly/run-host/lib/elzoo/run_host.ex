# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RunHost do
  @moduledoc """
  A supervised host for the `assembly/run-engine` Runs of one node, for one profile
  (text model calls of `integration/ai-text`); the Contract is the Piece README.

  The host process keeps the reservation table (`max_runs`, from reservation through
  confirmed teardown), the Unit directory with its own Registries and dedicated
  DynamicSupervisor, the lease renewals and expiry checks on the lease clock, the
  callbacks and the teardown of every per-Run process. Each Run has one worker
  (`Elzoo.RunHost.Runner`) under a group leader of its own: every process that the Run
  starts, at any depth, inherits it, so a teardown finds each of them without their
  supervisors. The host never waits on a worker, an engine or a Store: those calls run
  in the worker, in the caller or in a host task.
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
  def start_link(opts) do
    if Keyword.keyword?(opts) and is_atom(Keyword.get(opts, :name)),
      do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name])),
      else: {:error, :invalid_options}
  end

  @doc "Reserves, provisions and starts one Run: `:ok` or `{:error, reason}`."
  def start_run(host, run_ref, spec),
    do: GenServer.call(host, {:start_run, run_ref, spec}, :infinity)

  @doc "Opens Runs that have a current Attempt: one `{run_ref, :woken | {:error, reason}}` each."
  def wake(host, run_refs) when is_list(run_refs),
    do: GenServer.call(host, {:wake, run_refs}, :infinity)

  @doc """
  Stops every process of a Run, confirms it, releases its lease and frees its
  reservation: `:ok`, `{:error, :release_unconfirmed}` (the reservation stays; a
  later reap tries again) or `{:error, :not_running}`.
  """
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

  # Business input is admitted by the host's state and by a sample of the lease clock,
  # then goes through the Run's worker, which serializes it with the host's own inputs.
  defp business(host, run_ref, request) do
    with {:ok, worker, lease} <- GenServer.call(host, {:admission, run_ref}),
         :ok <- live(host, run_ref, lease) do
      case worker_call(worker, request) do
        # The engine's own call limit: the caller gets the exit that the engine gave.
        {:engine_exit, reason} ->
          exit(reason)

        # The worker ended with its Run (a teardown or a crash).
        :gone ->
          case GenServer.call(host, {:admission, run_ref}) do
            {:ok, _, _} -> {:error, :not_running}
            error -> error
          end

        reply ->
          reply
      end
    else
      # A renewal was confirmed (or the Run replaced) after this admission's snapshot:
      # its observation decides nothing, and the input is admitted again.
      :stale -> business(host, run_ref, request)
      error -> error
    end
  end

  defp worker_call(worker, request) do
    GenServer.call(worker, request, :infinity)
  catch
    :exit, _ -> :gone
  end

  # The lease must be held by this host's owner and live at a sample of the lease clock
  # taken now (Unix microseconds, compared with the last confirmed `until` of the
  # admission's snapshot). A lease that is not is reported to the host with the
  # snapshot's renewal generation; an unreadable lease clock admits nothing.
  defp live(host, run_ref, %{lease: lease, key: key, owner: owner, until: until} = snapshot) do
    case lease_state(Lease.status(lease, key), owner, until) do
      :live ->
        :ok

      :unknown ->
        {:error, :unavailable}

      reason ->
        GenServer.call(host, {:observed, run_ref, snapshot.token, snapshot.generation, reason})
    end
  end

  @doc false
  # The lease of a Run by a status read: `:live` (held by this owner, active, and the lease
  # clock before both the reading's own `until` and the last confirmed one), `:expired`
  # (this owner's lease, but not active or past either `until`), `{:lease_lost, info}`
  # (another holder, or no holder, or an ambiguous lease) or `:unknown` (no reading).
  def lease_state({:ok, %{now: now, status: status} = read}, owner, until) when is_integer(now) do
    holder = read.holder

    cond do
      holder == nil or holder.owner != owner or status == :ambiguous ->
        {:lease_lost, %{reason: status, holder: holder && holder.owner}}

      status != :active or now >= until or now >= holder.until ->
        :expired

      true ->
        :live
    end
  end

  def lease_state(_, _, _), do: :unknown

  @doc false
  # The node's monotonic time by which `until` passes at the latest, for a lease clock
  # that runs no slower than this node's: the lease clock is sampled after `t0`.
  def lease_deadline(lease, key, until) do
    t0 = now()
    deadline(t0, Lease.status(lease, key), until)
  end

  defp deadline(t0, {:ok, %{now: lease_now}}, until) when is_integer(lease_now),
    do: t0 + div(until - lease_now, 1_000)

  defp deadline(t0, _, _), do: t0

  # Reads go to the live engine directly; an engine that is gone is a Run that is not
  # live on this host.
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
    with {:ok, c} <- options(opts),
         _ = Process.flag(:trap_exit, true),
         base = c.name || Module.concat(__MODULE__, c.owner_id),
         units = Module.concat(base, Units),
         names = Module.concat(base, Names),
         {:ok, units_registry} <- Registry.start_link(keys: :unique, name: units),
         {:ok, names_registry} <- Registry.start_link(keys: :unique, name: names) do
      table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])

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
         infrastructure: [units_registry, names_registry, supervisor, directory, tasks],
         runs: %{},
         receipts: %{},
         lost: %{},
         batches: %{},
         monitors: %{},
         workers: %{},
         jobs: %{}
       }}
    else
      :error -> {:stop, :invalid_options}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp options(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in @required or &1 in @optional)),
         c = Map.new(opts),
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
         true <- Map.get(c, :allow_volatile, false) in [true, false],
         true <- is_atom(Map.get(c, :name)) do
      defaults = %{fencing_proof: nil, on_terminal: nil, on_lost: nil, allow_volatile: false}
      {:ok, Map.merge(Map.put(defaults, :name, nil), c)}
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

  # The Unit options of the directory: the engine's Operator, the retention of the Run
  # that the Unit hosts, and an offer that only sends each Outbox item to the engine
  # registered under the Unit's identity.
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
        run = %{run | waiters: run.waiters ++ [{:reap, from}], release: true, reap: true}
        {:noreply, teardown(s, run_ref, run)}

      %{phase: :tearing_down} = run ->
        run = %{
          run
          | waiters: run.waiters ++ [{:reap, from}],
            release: release_key(run) != nil,
            reap: true
        }

        {:noreply, put_in(s.runs[run_ref], run)}

      %{phase: phase} = run when phase in [:awaiting, :releasing] ->
        run = %{
          run
          | waiters: run.waiters ++ [{:reap, from}],
            release: release_key(run) != nil,
            reap: true
        }

        {:noreply, if(run.busy, do: put_in(s.runs[run_ref], run), else: finish(s, run_ref, run))}

      _ ->
        {:reply, {:error, :not_running}, s}
    end
  end

  def handle_call({:admission, run_ref}, _, s) do
    reply =
      case s.runs[run_ref] do
        %{phase: :live, admission: :open} = run ->
          {:ok, run.worker,
           %{
             lease: s.c.lease,
             key: run.stream,
             owner: s.c.owner_id,
             until: run.lease.until,
             token: run.token,
             generation: run.lease.generation
           }}

        %{phase: :live, admission: :terminal} ->
          {:error, :terminal}

        %{admission: :lease_lost} ->
          {:error, :lease_lost}

        _ ->
          if Map.has_key?(s.lost, run_ref), do: {:error, :lease_lost}, else: {:error, :not_running}
      end

    {:reply, reply, s}
  end

  # A caller's reading of a lost or expired lease, against the snapshot of one renewal
  # generation: a loss only while that snapshot is still the Run's own. After a renewal
  # was confirmed (or for another tenure) the caller is admitted again from a fresh one.
  def handle_call({:observed, run_ref, token, generation, reason}, _, s) do
    case s.runs[run_ref] do
      %{token: ^token, lease: %{generation: ^generation}} ->
        {:reply, {:error, :lease_lost}, lost(s, run_ref, reason)}

      _ ->
        {:reply, :stale, s}
    end
  end

  def handle_call({:engine, run_ref}, _, s) do
    case s.runs[run_ref] do
      %{phase: :live, pids: %{engine: engine}} -> {:reply, {:ok, engine}, s}
      _ -> {:reply, {:error, :not_running}, s}
    end
  end

  # From the activation callback, inside an EffectIntent process, with a reading of the
  # lease taken there: an activation is granted only to the current incarnation of a Run
  # whose predecessor check passed, while that reading shows its lease held by this
  # owner and live by the last confirmed `until`. A reading that shows the lease lost or
  # expired loses the Run.
  def handle_call({:authorize, run_ref, token, read}, _, s) do
    case s.runs[run_ref] do
      %{token: ^token, granted: true, admission: admission, lease: %{until: until}}
      when admission != :lease_lost ->
        case lease_state(read, s.c.owner_id, until) do
          :live -> {:reply, :granted, s}
          :unknown -> {:reply, :denied, s}
          reason -> {:reply, :denied, lost(s, run_ref, reason)}
        end

      _ ->
        {:reply, :denied, s}
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

  defp runner({:unit, unit, stream, retention}, run_ref, run, s) do
    if Enum.any?(s.runs, fn {ref, r} -> ref != run_ref and r.unit == unit end) do
      {{:error, :identity_in_use}, run, s}
    else
      :ets.insert(s.table, {unit, retention})
      {:ok, %{run | unit: unit, stream: stream}, s}
    end
  end

  defp runner({:held, held, deadline}, run_ref, run, s) do
    # The claim succeeded: an old lease that this tenure inherited is its own again.
    run = %{run | held: held, obligation: nil}
    run = schedule_lease(run, run_ref, held.live.until, deadline, s.c.lease_ttl_ms)
    {:ok, run, s}
  end

  defp runner({:track, role, pid}, run_ref, run, s) do
    ref = Process.monitor(pid)
    s = put_in(s.monitors[ref], {run_ref, run.token, role})
    {:ok, %{run | pids: Map.put(run.pids, role, pid)}, s}
  end

  # The predecessor check passed (or the Run is fresh): activations may be granted.
  defp runner(:grant, _run_ref, run, s), do: {:ok, %{run | granted: true}, s}

  @impl true
  def handle_info({:started, run_ref, token}, s) do
    case s.runs[run_ref] do
      %{token: ^token, phase: :starting, admission: nil} = run ->
        s = %{s | receipts: Map.delete(s.receipts, run_ref)}
        s = put_in(s.runs[run_ref], %{run | phase: :live, admission: :open, waiters: []})
        {:noreply, Enum.reduce(run.waiters, s, &answer(&2, &1, :started))}

      _ ->
        {:noreply, s}
    end
  end

  # Only a live Run calls on_terminal: once a teardown began, no callback starts.
  def handle_info({:terminal, run_ref, token, outcome}, s) do
    case s.runs[run_ref] do
      %{token: ^token, phase: :live, admission: :open} = run ->
        {s, run} = callback(s, run_ref, run, s.c.on_terminal, [run_ref, outcome])
        {:noreply, put_in(s.runs[run_ref], %{run | admission: :terminal})}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:renew, run_ref, token, generation}, s) do
    case s.runs[run_ref] do
      %{
        token: ^token,
        phase: phase,
        admission: admission,
        lease: %{generation: ^generation, renewing: false},
        pids: %{owner: owner}
      } = run
      when phase in [:starting, :live] and admission != :lease_lost ->
        %{lease: lease, lease_ttl_ms: ttl} = s.c
        key = run.stream
        deadline = run.lease.deadline

        job =
          Task.Supervisor.async_nolink(s.tasks, fn -> renewal(owner, lease, key, ttl, deadline) end)

        s = put_in(s.jobs[job.ref], {:renew, run_ref, token, generation})
        {:noreply, put_in(s.runs[run_ref].lease.renewing, true)}

      %{token: ^token, phase: :starting, lease: %{generation: ^generation, renewing: false}} ->
        # The Run owner is not started yet: the renewal waits for it.
        Process.send_after(self(), {:renew, run_ref, token, generation}, 10)
        {:noreply, s}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:expiry, run_ref, token, generation}, s) do
    case s.runs[run_ref] do
      %{token: ^token, phase: phase, admission: admission, lease: %{generation: ^generation} = l} =
          run
      when phase in [:starting, :live] and admission != :lease_lost ->
        %{lease: lease, owner_id: owner} = s.c
        key = run.stream
        until = l.until
        job = Task.Supervisor.async_nolink(s.tasks, fn -> expiry(lease, key, owner, until) end)
        {:noreply, put_in(s.jobs[job.ref], {:expiry, run_ref, token, generation})}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:retry_teardown, run_ref, token}, s) do
    case s.runs[run_ref] do
      %{token: ^token, phase: :tearing_down} = run -> {:noreply, fence(s, run_ref, run)}
      _ -> {:noreply, s}
    end
  end

  def handle_info({:retry_release, run_ref, token}, s) do
    case s.runs[run_ref] do
      %{token: ^token, phase: :releasing, busy: false} = run -> {:noreply, finish(s, run_ref, run)}
      _ -> {:noreply, s}
    end
  end

  # A job's result is kept until its process is gone (its :DOWN), so that a teardown that
  # waits for the Run's jobs waits for their exit, not only for their results.
  def handle_info({ref, result}, s) when is_reference(ref) and is_map_key(s.jobs, ref) do
    entry =
      case s.jobs[ref] do
        {:done, _, _} = done -> done
        job -> {:done, job, result}
      end

    {:noreply, put_in(s.jobs[ref], entry)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, s) when is_map_key(s.jobs, ref) do
    {entry, jobs} = Map.pop(s.jobs, ref)

    {job, result} =
      case entry do
        {:done, job, result} -> {job, result}
        job -> {job, {:crashed, reason}}
      end

    {:noreply, job(%{s | jobs: jobs}, job, result)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, s) do
    case Map.pop(s.monitors, ref) do
      {{run_ref, token, role}, monitors} ->
        {:noreply, down(%{s | monitors: monitors}, run_ref, token, role, ref, reason)}

      {nil, _} ->
        {:noreply, s}
    end
  end

  # The host traps exits. Its own infrastructure ending (a Registry, the Unit
  # supervisor, the directory or its task supervisor) stops the host with that reason,
  # so that its supervisor starts the subtree again; recovery then goes through wake/2
  # and its predecessor check. A worker is linked from its start, so its exit reason is
  # never lost to a late monitor.
  def handle_info({:EXIT, pid, reason}, s) do
    cond do
      pid in s.infrastructure ->
        {:stop, reason, s}

      Map.has_key?(s.workers, pid) ->
        {{run_ref, token}, workers} = Map.pop(s.workers, pid)
        {:noreply, down(%{s | workers: workers}, run_ref, token, :worker, nil, reason)}

      true ->
        {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  # Best effort when the host stops: every process of every Run and its group leader,
  # then the host's own infrastructure, so that a restarted host finds its names free.
  # A replacement host still recovers each Run through wake/2 and its predecessor check.
  @impl true
  def terminate(_reason, s) do
    for {_, run} <- s.runs do
      kill_group(run.gl)
      kill([run.gl])
    end

    for pid <- Enum.reverse(s.infrastructure), do: stop_now(pid)
    :ok
  end

  ## Requests

  defp request(s, run_ref, mode, waiter) do
    case s.runs[run_ref] do
      %{phase: phase} = run when phase in [:tearing_down, :awaiting] ->
        put_in(s.runs[run_ref], %{run | deferred: run.deferred ++ [{mode, waiter}]})

      # A release that is not confirmed is no longer wanted by a new start of the Run:
      # the new tenure takes the key over (handover/3).
      %{phase: :releasing, busy: false} = run ->
        handover(s, run_ref, %{run | deferred: run.deferred ++ [{mode, waiter}]})

      %{phase: :releasing} = run ->
        put_in(s.runs[run_ref], %{run | deferred: run.deferred ++ [{mode, waiter}]})

      %{} ->
        answer(s, waiter, {:error, :running})

      nil ->
        if map_size(s.runs) >= s.c.max_runs do
          answer(s, waiter, {:error, :capacity})
        else
          start(s, run_ref, mode, waiter)
        end
    end
  end

  defp start(s, run_ref, mode, waiter) do
    token = make_ref()
    leader = Process.group_leader()
    gl = spawn_link(fn -> relay(leader) end)

    {:ok, worker} =
      Runner.start_link(%{
        host: self(),
        run_ref: run_ref,
        token: token,
        mode: mode,
        c: s.c,
        names: s.names,
        directory: s.directory,
        receipt: s.receipts[run_ref],
        group_leader: gl
      })

    run = %{
      token: token,
      phase: :starting,
      admission: nil,
      worker: worker,
      gl: gl,
      pids: %{worker: worker},
      callbacks: %{},
      waiters: [waiter],
      deferred: [],
      unit: nil,
      stream: nil,
      held: nil,
      lease: nil,
      granted: false,
      result: nil,
      release: false,
      retry: false,
      obligation: nil,
      reap: false,
      busy: false
    }

    s = put_in(s.workers[worker], {run_ref, token})
    s = %{s | lost: Map.delete(s.lost, run_ref)}
    put_in(s.runs[run_ref], run)
  end

  # The group leader of one Run relays every I/O request to the host's group leader.
  defp relay(leader) do
    receive do
      message -> send(leader, message)
    end

    relay(leader)
  end

  defp answer(s, {:start, from}, :started), do: tap(s, fn _ -> GenServer.reply(from, :ok) end)
  defp answer(s, {:start, from}, error), do: tap(s, fn _ -> GenServer.reply(from, error) end)

  defp answer(s, {:reap, from}, reply) when reply != :ok and elem(reply, 1) == :release_unconfirmed,
    do: tap(s, fn _ -> GenServer.reply(from, reply) end)

  defp answer(s, {:reap, from}, _), do: tap(s, fn _ -> GenServer.reply(from, :ok) end)

  defp answer(s, {:wake, id, run_ref}, result) do
    result = if result == :started, do: :woken, else: result

    case s.batches[id] do
      %{} -> complete(put_in(s.batches[id].results[run_ref], result), id)
      nil -> s
    end
  end

  # Replies once, when every Run of the batch has its disposition.
  defp complete(s, id) do
    case s.batches[id] do
      %{refs: refs, results: results, from: from} ->
        if Enum.all?(refs, &Map.has_key?(results, &1)) do
          GenServer.reply(from, Enum.map(refs, &{&1, results[&1]}))
          %{s | batches: Map.delete(s.batches, id)}
        else
          s
        end

      nil ->
        s
    end
  end

  ## Leases

  # Renewal and expiry are timed on this node's monotonic clock from a deadline that
  # each claim and renewal takes from a sample of the lease clock (lease_deadline/3).
  # The renewal starts half the TTL before it; at the deadline the lease clock is read
  # again, and only that reading declares the lease expired.
  defp schedule_lease(run, run_ref, until, deadline, ttl) do
    generation = make_ref()
    renew_in = max(deadline - div(ttl, 2) - now(), 0)
    Process.send_after(self(), {:renew, run_ref, run.token, generation}, renew_in)
    Process.send_after(self(), {:expiry, run_ref, run.token, generation}, max(deadline - now(), 0))
    %{run | lease: %{generation: generation, until: until, deadline: deadline, renewing: false}}
  end

  @doc false
  # One renewal through the live owner. A confirmed renewal comes back with a reading of
  # the lease taken after the reply, read again until one succeeds or the last confirmed
  # expiry moment (`deadline`, on this node's clock) has passed: only a reading can show
  # that the confirmation came before the last confirmed `until`.
  def renewal(owner, lease, key, ttl, deadline) do
    case Owner.renew(owner, ttl) do
      {:ok, _revision, %{until: until}} when is_integer(until) ->
        {t0, read} = reading(lease, key, deadline)
        {:renewed, until, read, t0}

      other ->
        other
    end
  catch
    # A renewal that exits (its caller timeout, or the owner ending) is unconfirmed.
    :exit, _ -> {:unknown, :no_receipt}
  end

  defp reading(lease, key, deadline) do
    t0 = now()

    case Lease.status(lease, key) do
      {:ok, _} = read ->
        {t0, read}

      error when t0 < deadline ->
        Process.sleep(min(100, deadline - t0))
        if now() < deadline, do: reading(lease, key, deadline), else: {t0, error}

      error ->
        {t0, error}
    end
  end

  @doc false
  def expiry(lease, key, owner, until) do
    t0 = now()
    read = Lease.status(lease, key)

    case lease_state(read, owner, until) do
      :live -> {:later, t0 + div(until - elem(read, 1).now, 1_000)}
      other -> other
    end
  end

  defp job(s, {:renew, run_ref, token, generation}, result) do
    case s.runs[run_ref] do
      %{token: ^token} = run ->
        s |> renewed(run_ref, run, generation, result) |> proceed(run_ref, token)

      _ ->
        s
    end
  end

  defp job(s, {:expiry, run_ref, token, generation}, result) do
    case s.runs[run_ref] do
      %{token: ^token, phase: phase, lease: %{generation: ^generation}}
      when phase in [:starting, :live] ->
        case result do
          {:later, deadline} ->
            message = {:expiry, run_ref, token, generation}
            Process.send_after(self(), message, max(deadline - now(), 0))
            s

          reason when reason == :expired or elem(reason, 0) == :lease_lost ->
            lost(s, run_ref, reason)

          # No reading of the lease clock: read again soon; admission reads it too.
          _ ->
            Process.send_after(self(), {:expiry, run_ref, token, generation}, 500)
            s
        end

      %{token: ^token} ->
        proceed(s, run_ref, token)

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

  defp job(s, {:callbacks, run_ref, token}, _) do
    case s.runs[run_ref] do
      %{token: ^token} = run -> finish(s, run_ref, %{run | busy: false})
      _ -> s
    end
  end

  defp job(s, {:release, run_ref, token}, result) do
    case s.runs[run_ref] do
      %{token: ^token, phase: :releasing} = run ->
        run = %{run | busy: false}
        if result == :released, do: free(s, run_ref, run), else: unreleased(s, run_ref, run)

      _ ->
        s
    end
  end

  # A renewal is confirmed only by a reading of the lease taken after its reply that shows
  # it held by this owner, active and before the last confirmed `until`: then the expiry
  # moves. A reading that shows the lease lost (another holder, or none) is that loss; a
  # reading at or after the last confirmed `until`, or no reading before it, is :expired.
  # This node's clock never stands in for a reading. A late renewal reopens nothing, and
  # after a teardown began a result is no loss of a live Run (lost/3).
  defp renewed(s, run_ref, run, generation, {:renewed, until, read, t0}) do
    cond do
      run.lease.generation != generation or run.phase not in [:starting, :live] or
          run.admission == :lease_lost ->
        s

      true ->
        case lease_state(read, s.c.owner_id, run.lease.until) do
          :live ->
            run = schedule_lease(run, run_ref, until, deadline(t0, read, until), s.c.lease_ttl_ms)
            put_in(s.runs[run_ref], run)

          {:lease_lost, _} = reason ->
            lost(s, run_ref, reason)

          _ ->
            lost(s, run_ref, :expired)
        end
    end
  end

  # A definite no-write error keeps the token and the expiry deadline; the renewal is
  # tried again within it.
  defp renewed(s, run_ref, run, generation, {:error, _}) do
    if run.lease.generation == generation and run.phase in [:starting, :live] do
      delay = max(div(s.c.lease_ttl_ms, 12), 1)
      Process.send_after(self(), {:renew, run_ref, run.token, generation}, delay)
      put_in(s.runs[run_ref].lease.renewing, false)
    else
      s
    end
  end

  defp renewed(s, run_ref, _, _, {:refused, reason}), do: lost(s, run_ref, reason)
  defp renewed(s, run_ref, _, _, {:indeterminate, _} = reason), do: lost(s, run_ref, reason)
  defp renewed(s, run_ref, _, _, _), do: lost(s, run_ref, {:unknown, :no_receipt})

  # A loss of a live (or starting) Run stops admission, calls on_lost and fences every
  # process of the Run, whichever of the renewal result, an observation, the owner's
  # exit or the worker's exit comes first. Every later report, and every report after a
  # teardown began (a reap, a failed start, a crash), adds only its receipt: an
  # indeterminate result keeps one for `reconcile:`.
  defp lost(s, run_ref, reason) do
    case s.runs[run_ref] do
      %{phase: phase, admission: admission} = run
      when phase in [:starting, :live] and admission != :lease_lost ->
        s = %{receipt(s, run_ref, reason) | lost: Map.put(s.lost, run_ref, reason)}
        {s, run} = callback(s, run_ref, run, s.c.on_lost, [run_ref, reason])
        run = %{run | admission: :lease_lost, result: run.result || {:error, :lease_lost}}
        teardown(s, run_ref, run)

      _ ->
        receipt(s, run_ref, reason)
    end
  end

  defp receipt(s, run_ref, {:indeterminate, receipt}), do: put_in(s.receipts[run_ref], receipt)
  defp receipt(s, _, _), do: s

  ## Teardown

  defp down(s, run_ref, token, role, ref, reason) do
    loss = loss(role, reason)

    case s.runs[run_ref] do
      %{token: ^token} = run ->
        cond do
          role == :callback ->
            run = %{run | callbacks: Map.delete(run.callbacks, ref)}
            s |> put_in([:runs, run_ref], run) |> proceed(run_ref, token)

          loss != nil ->
            lost(s, run_ref, loss)

          run.phase in [:tearing_down, :awaiting, :releasing] ->
            s

          # A failed start: the lease that it claimed, or the old lease that it inherited,
          # is released, and that release is tried until it is confirmed (unreleased/3).
          run.phase == :starting and role == :worker ->
            run = %{
              run
              | result: run.result || {:error, start_error(reason)},
                release: release_key(run) != nil,
                retry: true
            }

            teardown(s, run_ref, run)

          run.phase == :starting ->
            s

          true ->
            teardown(s, run_ref, run)
        end

      # The tenure ended before this report reached the host: an indeterminate receipt
      # is still kept for the next start.
      _ ->
        receipt(s, run_ref, loss)
    end
  end

  defp loss(:owner, {:shutdown, {tag, _} = reason}) when tag in @lost, do: reason
  defp loss(:worker, {:shutdown, {:exited, :owner, reason}}), do: loss(:owner, reason)
  defp loss(_, _), do: nil

  defp start_error({:shutdown, reason}), do: reason
  defp start_error(reason), do: {:start_failed, reason}

  defp teardown(s, run_ref, run),
    do: fence(s, run_ref, %{run | phase: :tearing_down, granted: false})

  defp fence(s, run_ref, run) do
    t = %{
      gl: run.gl,
      engine: run.pids[:engine],
      unit: run.unit,
      units: s.units,
      directory: s.directory
    }

    job = Task.Supervisor.async_nolink(s.tasks, fn -> confirm(t) end)
    s = put_in(s.jobs[job.ref], {:teardown, run_ref, run.token})
    put_in(s.runs[run_ref], run)
  end

  defp torn_down(s, run_ref, run, :confirmed) do
    if run.unit, do: :ets.delete(s.table, run.unit)
    finish(s, run_ref, run)
  end

  # Not confirmed (the Unit's stop, or the teardown itself, failed): the Run keeps its
  # reservation and the teardown runs again.
  defp torn_down(s, run_ref, run, _) do
    Process.send_after(self(), {:retry_teardown, run_ref, run.token}, 1_000)
    s
  end

  # Every process of the Run is gone. A callback that still runs is stopped by a reap
  # and waited for otherwise, and a renewal or expiry job of the Run is waited for until
  # its process is gone (a teardown starts no new one); then a reap or a failed start
  # releases the lease that the Run owes (release_key/1).
  defp finish(s, run_ref, run) do
    alive = for {ref, pid} <- run.callbacks, Process.alive?(pid), into: %{}, do: {ref, pid}
    run = %{run | callbacks: alive}

    cond do
      alive != %{} and run.reap ->
        pids = Map.values(alive)
        job = Task.Supervisor.async_nolink(s.tasks, fn -> kill(pids) end)
        s = put_in(s.jobs[job.ref], {:callbacks, run_ref, run.token})
        put_in(s.runs[run_ref], %{run | phase: :awaiting, busy: true})

      alive != %{} or jobs?(s, run_ref, run.token) ->
        put_in(s.runs[run_ref], %{run | phase: :awaiting})

      run.release and release_key(run) != nil ->
        %{lease: lease, owner_id: owner} = s.c
        key = release_key(run)
        job = Task.Supervisor.async_nolink(s.tasks, fn -> release(lease, key, owner) end)
        s = put_in(s.jobs[job.ref], {:release, run_ref, run.token})
        put_in(s.runs[run_ref], %{run | phase: :releasing, busy: true})

      true ->
        free(s, run_ref, run)
    end
  end

  # The key whose release the Run owes: the lease that it claimed, or, until its own claim
  # succeeds, the old lease that it inherited at a handover.
  defp release_key(%{held: nil, obligation: key}), do: key
  defp release_key(%{stream: key}), do: key

  # A teardown that waits for a callback or a job of the Run goes on when it ends.
  defp proceed(s, run_ref, token) do
    case s.runs[run_ref] do
      %{token: ^token, phase: :awaiting, busy: false} = run -> finish(s, run_ref, run)
      _ -> s
    end
  end

  defp jobs?(s, run_ref, token),
    do: Enum.any?(s.jobs, fn {_, job} -> lease_job?(job, run_ref, token) end)

  defp lease_job?({:done, job, _}, run_ref, token), do: lease_job?(job, run_ref, token)

  defp lease_job?({kind, run_ref, token, _}, run_ref, token) when kind in [:renew, :expiry],
    do: true

  defp lease_job?(_, _, _), do: false

  # A release that is not confirmed keeps the reservation, and with it the
  # responsibility for the lease: each waiting reap gets {:error, :release_unconfirmed}
  # and a failed start's caller its start error. A start or wake of the Run already
  # waiting takes the key over (handover/3); otherwise a failed start's release is tried
  # again every second, whoever joined its wait, and a reaped Run's by a later reap.
  defp unreleased(s, run_ref, run) do
    {reaps, waiters} = Enum.split_with(run.waiters, &match?({:reap, _}, &1))
    s = Enum.reduce(reaps, s, &answer(&2, &1, {:error, :release_unconfirmed}))
    s = Enum.reduce(waiters, s, &answer(&2, &1, run.result || {:error, :not_running}))
    run = %{run | waiters: [], reap: false}

    cond do
      run.deferred != [] ->
        handover(s, run_ref, run)

      run.retry ->
        Process.send_after(self(), {:retry_release, run_ref, run.token}, 1_000)
        put_in(s.runs[run_ref], run)

      true ->
        put_in(s.runs[run_ref], run)
    end
  end

  defp free(s, run_ref, run) do
    s = %{s | runs: Map.delete(s.runs, run_ref)}
    result = run.result || {:error, :not_running}
    s = Enum.reduce(run.waiters, s, &answer(&2, &1, result))
    Enum.reduce(run.deferred, s, fn {mode, waiter}, acc -> request(acc, run_ref, mode, waiter) end)
  end

  # The waiting requests of a Run whose release is not confirmed are replayed: the first
  # starts the new tenure, which inherits the release of the old lease (`obligation`) until
  # its own claim succeeds; a new tenure that ends before its claim releases that lease,
  # tried until confirmed, like a failed start.
  defp handover(s, run_ref, run) do
    key = release_key(run)
    s = free(s, run_ref, %{run | waiters: []})

    case s.runs[run_ref] do
      %{phase: :starting, held: nil, obligation: nil} = next ->
        put_in(s.runs[run_ref], %{next | obligation: key})

      _ ->
        Process.send_after(self(), {:retry_release, run_ref, run.token}, 1_000)
        put_in(s.runs[run_ref], %{run | waiters: [], deferred: [], retry: true})
    end
  end

  @doc false
  # Runs in a host task: kills the engine first (so it starts nothing more), then every
  # process whose group leader is the Run's (the worker, the keep-alive, the Run owner,
  # the evidence Writer, AsyncWork, the task supervisor, every task and every
  # EffectIntent owner, at any depth), confirms each is gone, stops the Unit through its
  # directory and waits for the processes that the Unit started. Last, the group leader
  # itself is stopped and confirmed gone.
  def confirm(t) do
    kill([t.engine])
    kill_group(t.gl)

    case if(t.unit, do: stop_unit(t), else: :ok) do
      :ok ->
        kill([t.gl])
        :confirmed

      _ ->
        :unconfirmed
    end
  catch
    _, _ -> :unconfirmed
  end

  @doc false
  # Confirmed when the lease is released, free, or held by another owner.
  def release(lease, key, owner) do
    case Lease.release(lease, key, owner) do
      {:free, _} ->
        :released

      _ ->
        case Lease.status(lease, key) do
          {:ok, %{status: :free}} -> :released
          {:ok, %{holder: %{owner: holder}}} when holder != owner -> :released
          _ -> :unconfirmed
        end
    end
  rescue
    _ -> :unconfirmed
  catch
    _, _ -> :unconfirmed
  end

  @doc false
  # The processes whose group leader is `gl`.
  def members(gl),
    do:
      for(
        pid <- Process.list(),
        pid != gl,
        Process.info(pid, :group_leader) == {:group_leader, gl},
        do: pid
      )

  defp kill_group(nil), do: :ok

  defp kill_group(gl) do
    case members(gl) do
      [] ->
        :ok

      pids ->
        kill(pids)
        kill_group(gl)
    end
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

  # An orderly stop of one piece of infrastructure, and a kill when that fails.
  defp stop_now(pid) do
    Process.unlink(pid)

    try do
      :ok = GenServer.stop(pid, :shutdown, 5_000)
    catch
      :exit, _ -> kill([pid])
    end
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

  defp callback(s, _run_ref, run, nil, _), do: {s, run}

  # A callback runs in a task of the Run: a teardown waits for it, a reap stops it.
  defp callback(s, run_ref, run, fun, args) do
    {:ok, pid} = Task.Supervisor.start_child(s.tasks, fn -> apply(fun, args) end)
    ref = Process.monitor(pid)
    s = put_in(s.monitors[ref], {run_ref, run.token, :callback})
    {s, %{run | callbacks: Map.put(run.callbacks, ref, pid)}}
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp text?(s, max),
    do:
      is_binary(s) and byte_size(s) in 1..max and String.valid?(s) and
        not String.contains?(s, <<0>>)
end
