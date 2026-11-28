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

  # The lease must be held by this host's owner and live at a reading of the lease taken
  # now (lease_reading/4), against the last confirmed `until` of the admission's snapshot.
  # A live reading goes to the host like every other reading of the Run's tenure
  # (observed/4), so a re-claim that it shows moves the Run's deadline and stops its
  # renewals, and a reading of a replied renewal's record confirms it; the input is admitted
  # only when the host accepts that reading for the Run's current tenure (eligible/2). A
  # lease that is not live is reported with the snapshot's renewal generation; an
  # unreadable lease, or a reading that the host does not accept, admits nothing.
  defp live(host, run_ref, %{lease: lease, key: key, owner: owner, until: until} = snapshot) do
    {t0, read} = lease_reading(lease, key, owner, until)

    case lease_state(read, owner, until) do
      :live ->
        GenServer.call(host, {:reading, run_ref, snapshot.token, t0, read})

      :unknown ->
        {:error, :unavailable}

      reason ->
        GenServer.call(host, {:observed, run_ref, snapshot.token, snapshot.generation, reason})
    end
  end

  @doc false
  # The lease of a Run by a reading: `{:lease_lost, info}` (another holder, or no holder, or
  # an ambiguous lease), `:expired` (this owner's lease, but not active, or the lease clock
  # at or past the reading's own `until` or the last confirmed one), `:live` (this owner's
  # active lease before both, in a reading correlated with its lease record) or `:unknown`
  # (no reading, or a live status that could not be correlated with its record: it proves
  # no loss and grants or confirms nothing).
  def lease_state({:ok, %{now: now, status: status} = read}, owner, until) when is_integer(now) do
    holder = read.holder

    cond do
      holder == nil or holder.owner != owner or status == :ambiguous ->
        {:lease_lost, %{reason: status, holder: holder && holder.owner}}

      status != :active or now >= until or now >= holder.until ->
        :expired

      read.record == nil ->
        :unknown

      true ->
        :live
    end
  end

  def lease_state(_, _, _), do: :unknown

  @doc false
  # A reading of the lease, with this node's monotonic time taken right before the status
  # read that gave it (`t0`: the lease clock is sampled after it) and a mark of the node's
  # strict order of events taken at the same point (`mark`: a reading whose mark is after
  # the mark that a renewal job took on the owner's reply sampled the lease clock after that
  # reply). A status that proves a loss by itself (another holder, none, an ambiguous or
  # inactive lease, or a sample at or past its own `until` or the cutoff `until` that the
  # caller gives) is the reading at once, before any record read, so no failing or slow
  # record read can hide it. A status that shows `owner`'s live lease also carries the
  # sequence of its latest lease record (`record`): the identity of that record, which a
  # re-claim replaces with another one and an ordinary write of the Run's stream does not.
  # Lease.status/2 and Lease.retention_bound/2 are taken at one head revision of the stream;
  # while the head moves between them both are read again, each attempt with its own `t0`
  # and mark, at most five times in all. A live status whose record cannot be read, or whose
  # head still moves, is kept with no record (`record: nil`), also when a later status read
  # fails. Each reading also carries the node time right after its status read returned
  # (`sampled_by`): the lease clock was sampled between `t0` and it.
  def lease_reading(lease, key, owner, until \\ nil, tries \\ 5, last \\ nil) do
    t0 = now()
    mark = mark()
    status = Lease.status(lease, key)
    t1 = now()

    case status do
      {:ok, %{now: now, status: :active, holder: %{owner: ^owner, until: own}, as_of: as_of} = read}
      when now < own and (until == nil or now < until) ->
        read = Map.merge(read, %{record: nil, mark: mark, sampled_by: t1})

        case Lease.retention_bound(lease, key) do
          {:ok, %{as_of: ^as_of, through: through}} ->
            {t0, {:ok, %{read | record: through + 1}}}

          {:ok, _} when tries > 1 ->
            lease_reading(lease, key, owner, until, tries - 1, {t0, {:ok, read}})

          _ ->
            {t0, {:ok, read}}
        end

      {:ok, read} ->
        {t0, {:ok, Map.merge(read, %{record: nil, mark: mark, sampled_by: t1})}}

      error ->
        last || {t0, error}
    end
  end

  @doc false
  # A strictly increasing mark of this node's order of events, across processes.
  def mark, do: System.unique_integer([:monotonic])

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
  # whose predecessor check passed and whose tenure has a confirmed lease record, on a
  # reading that shows its lease held by this owner and live by the last confirmed `until`
  # and that the host accepts (eligible/2); the reading is kept like any other
  # (observed/4), so it may show a newer same-holder record than the confirmed one, and the
  # grant is decided on the state that results: only while the Run's deadline is still
  # ahead (ahead?/2). A reading that shows the lease lost or expired loses the Run; one
  # that the host does not accept grants nothing.
  def handle_call({:authorize, run_ref, token, t0, read}, _, s) do
    case s.runs[run_ref] do
      %{token: ^token, granted: true, admission: admission, lease: %{until: until} = l}
      when admission != :lease_lost ->
        case lease_state(read, s.c.owner_id, until) do
          :live ->
            if eligible?(l, read) do
              s = observed(s, run_ref, t0, read)

              case s.runs[run_ref] do
                %{lease: %{generation: g}} = run when g != nil ->
                  {:reply, if(ahead?(run, token), do: :granted, else: :denied), s}

                _ ->
                  {:reply, :denied, s}
              end
            else
              {:reply, :denied, s}
            end

          :unknown ->
            {:reply, :denied, s}

          reason ->
            {:reply, :denied, lost(s, run_ref, reason)}
        end

      _ ->
        {:reply, :denied, s}
    end
  end

  # A live reading that a caller's admission took: the host keeps it when it accepts it for
  # the Run's tenure that admitted it (eligible/2), and the input is admitted (`:ok`) only
  # when the Run's deadline is still ahead once it is kept (ahead?/2). Another tenure gives
  # `:stale` (the caller is admitted again from a fresh snapshot); a reading that the host
  # does not accept, or one after which the deadline has passed (its fence is due),
  # `{:error, :unavailable}`.
  def handle_call({:reading, run_ref, token, t0, read}, _, s) do
    case s.runs[run_ref] do
      %{token: ^token, phase: phase, admission: admission, lease: %{} = l}
      when phase in [:starting, :live] and admission != :lease_lost ->
        if eligible?(l, read) do
          s = observed(s, run_ref, t0, read)
          reply = if ahead?(s.runs[run_ref], token), do: :ok, else: {:error, :unavailable}
          {:reply, reply, s}
        else
          {:reply, {:error, :unavailable}, s}
        end

      _ ->
        {:reply, :stale, s}
    end
  end

  # The cutoff of an activation's reading: the last confirmed `until` of the Run's current
  # tenure.
  def handle_call({:cutoff, run_ref, token}, _, s) do
    case s.runs[run_ref] do
      %{token: ^token, granted: true, admission: admission, lease: %{until: until}}
      when admission != :lease_lost ->
        {:reply, {:ok, until}, s}

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

  # A Unit identity is in use while another Run of this host has it, or owes or holds the
  # lease key of its stream: a tenure that took an old lease over at a handover owes its
  # release before its own Unit is known (its spec callback can still run).
  defp runner({:unit, unit, stream, retention}, run_ref, run, s) do
    if Enum.any?(s.runs, fn {ref, r} ->
         ref != run_ref and (r.unit == unit or release_key(r) == stream)
       end) do
      {{:error, :identity_in_use}, run, s}
    else
      :ets.insert(s.table, {unit, retention})
      {:ok, %{run | unit: unit, stream: stream}, s}
    end
  end

  # The claim succeeded: an old lease that this tenure inherited is its own again. The claim
  # is not yet confirmed: its worker does nothing else (no Run owner, engine, admission or
  # activation) until a reading of the lease taken after the claim returned (`claimed`, the
  # worker's mark then) confirms it (:claim_read). That confirmation phase is bounded here,
  # on receipt, by the claim's TTL from now (a bound of the start, not a lease deadline: no
  # work of the Run can act before the confirmation): when no reading has confirmed the
  # claim by then, the Run is fenced and its reservation freed. The confirming reading puts
  # the lease deadline in place (deadline/1, from that reading's own sample and `until`); a
  # reading that shows the lease lost or expired fences the Run at once.
  defp runner({:held, held, claimed}, run_ref, run, s) do
    lease = %{
      generation: nil,
      record: nil,
      until: held.live.until,
      seen: nil,
      post: nil,
      deadline: nil,
      renewing: false,
      due: nil,
      floor: nil,
      chase: nil,
      timers: %{},
      pending: %{until: held.live.until, record: held.live.revision, replied: claimed, claim: true}
    }

    ttl = s.c.lease_ttl_ms
    run = arm(%{run | held: held, obligation: nil, lease: lease}, run_ref, now() + ttl, ttl)
    {:ok, run, put_in(s.runs[run_ref], run)}
  end

  # The worker's reading after its claim: `:confirmed`, `:pending` (the worker reads again)
  # or the Run's loss.
  defp runner({:claim_read, t0, read}, run_ref, _run, s) do
    s = observed(s, run_ref, t0, read)

    case s.runs[run_ref] do
      %{phase: :starting, admission: nil, lease: %{generation: g}} = run when g != nil ->
        {:confirmed, run, s}

      %{phase: :starting, admission: nil} = run ->
        {:pending, run, s}

      run ->
        {{:error, :lease_lost}, run, s}
    end
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

  # The renewal of a confirmed lease record, once per generation, through the live owner,
  # at the moment that schedule/3 set last (`due`): none while a renewal that replied is
  # unconfirmed, and none once the newest reading shows another lease record than the one
  # that the host confirmed (a re-claim's record supersedes it, also one with the same
  # `until`: the Run is then fenced at its deadline, and the host starts no renewal of that
  # record; a renewal already submitted can still write onto it, README Leases).
  def handle_info({:renew, run_ref, token, generation, due}, s) do
    case s.runs[run_ref] do
      %{
        token: ^token,
        phase: phase,
        admission: admission,
        lease: %{
          generation: ^generation,
          due: ^due,
          renewing: false,
          pending: nil,
          record: record,
          seen: %{record: record},
          deadline: deadline
        },
        pids: %{owner: owner}
      }
      when phase in [:starting, :live] and admission != :lease_lost ->
        # A renewal starts only before the Run's current deadline: once it has passed, the
        # fence is due, whatever order the two messages came in. A renewal that is not
        # started is no longer due: a reading that moves the deadline on schedules it again
        # (schedule/3).
        if deadline > now() do
          ttl = s.c.lease_ttl_ms
          job = Task.Supervisor.async_nolink(s.tasks, fn -> renewal(owner, ttl) end)
          s = put_in(s.jobs[job.ref], {:renew, run_ref, token, generation})

          {:noreply,
           put_in(s.runs[run_ref].lease, %{s.runs[run_ref].lease | renewing: true, due: nil})}
        else
          {:noreply, put_in(s.runs[run_ref].lease.due, nil)}
        end

      %{token: ^token, phase: :starting, lease: %{generation: ^generation, due: ^due}, pids: pids}
      when not is_map_key(pids, :owner) ->
        # The Run owner is not started yet: the renewal waits for it.
        Process.send_after(self(), {:renew, run_ref, token, generation, due}, 10)
        {:noreply, s}

      _ ->
        {:noreply, s}
    end
  end

  # A reading of the lease in a host task: the expiry check of one deadline (arm/4), a
  # reading again after a failed one, and the reading that a pending renewal obliges the
  # host to take (`{:pending, record}`, chase/3). The task reads in its own process and
  # spawns none. The host keeps it as one entry until its own :DOWN: its pid, its bound
  # timer, its key, whether it may still give a result (`open`) and whether it gave one
  # (`done`). Its bound is the Run's deadline when it starts: then the host closes it (a
  # result that comes later is ignored) and kills it, also when it has given a result but
  # not exited, and also when a later reading has moved the deadline since; a teardown kills
  # it at once (teardown/3). Its :DOWN cancels the bound timer and, when it gave no result,
  # counts as a failed reading. Like every job it stays listed until that :DOWN, so its end
  # comes before anything that frees the reservation.
  def handle_info({:expiry, run_ref, token, key}, s) do
    case s.runs[run_ref] do
      %{token: ^token, phase: phase, admission: admission, lease: l} = run
      when phase in [:starting, :live] and admission != :lease_lost ->
        cond do
          key == l.deadline ->
            {:noreply, read_job(s, run_ref, run, key)}

          match?({:pending, _}, key) and l.pending != nil and key == {:pending, l.pending.record} and
              match?({:timer, _}, l.chase) ->
            if l.deadline > now() do
              s = put_in(s.runs[run_ref].lease.chase, {:job, l.pending.record})
              {:noreply, read_job(s, run_ref, run, key)}
            else
              # Past the deadline the fence is due; a reading taken before that deadline that
              # reaches the host before its fence takes the obligation up again (settle/3).
              {:noreply, put_in(s.runs[run_ref].lease.chase, nil)}
            end

          true ->
            {:noreply, s}
        end

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:read_bound, ref}, s) do
    case s.jobs[ref] do
      {:expiry, run_ref, token, r} ->
        Process.exit(r.pid, :kill)
        {:noreply, put_in(s.jobs[ref], {:expiry, run_ref, token, %{r | open: false}})}

      _ ->
        {:noreply, s}
    end
  end

  # The Run's deadline, if no reading has moved it since: by it the last confirmed `until`
  # (or a shorter one that the newest reading shows) has passed, for a lease clock that
  # runs no slower than this node's. The Run is lost (:expired) with no reading, so a
  # reading that blocks or fails never holds the fence.
  def handle_info({:fence, run_ref, token, deadline}, s) do
    case s.runs[run_ref] do
      %{token: ^token, phase: phase, admission: admission, lease: %{deadline: ^deadline}}
      when phase in [:starting, :live] and admission != :lease_lost ->
        {:noreply, lost(s, run_ref, :expired)}

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

  # A job's result is applied when it arrives, so that a lost lease stops admission and
  # calls on_lost before a reap that comes after the result can begin a teardown. The job
  # stays listed, as applied with its kind, until its process is gone (its own :DOWN): what
  # frees or hands over the Run's resources waits for that exit (finish/3, proceed/3), and
  # a release's result is acted on only at the :DOWN of the release task itself
  # (release_exited/3), never at another process's exit.
  def handle_info({ref, result}, s) when is_reference(ref) and is_map_key(s.jobs, ref) do
    case s.jobs[ref] do
      {:expiry, run_ref, token, %{open: true} = r} ->
        s = put_in(s.jobs[ref], {:expiry, run_ref, token, %{r | open: false, done: true}})
        {:noreply, read_done(s, run_ref, token, r.key, result)}

      {:expiry, _, _, _} ->
        {:noreply, s}

      {:applied, _, _, _} ->
        {:noreply, s}

      job ->
        s = put_in(s.jobs[ref], {:applied, elem(job, 1), elem(job, 2), elem(job, 0)})
        {:noreply, job(s, job, result)}
    end
  end

  def handle_info({:DOWN, ref, :process, _, reason}, s) when is_map_key(s.jobs, ref) do
    {entry, jobs} = Map.pop(s.jobs, ref)
    s = %{s | jobs: jobs}

    case entry do
      {:expiry, run_ref, token, r} ->
        cancel(r.timer)
        s = if r.done, do: s, else: read_done(s, run_ref, token, r.key, :no_reading)
        {:noreply, proceed(s, run_ref, token)}

      {:applied, run_ref, token, :release} ->
        {:noreply, release_exited(s, run_ref, token)}

      {:applied, run_ref, token, _} ->
        {:noreply, proceed(s, run_ref, token)}

      {:release, run_ref, token} = job ->
        {:noreply, release_exited(job(s, job, {:crashed, reason}), run_ref, token)}

      job ->
        {:noreply, proceed(job(s, job, {:crashed, reason}), elem(job, 1), elem(job, 2))}
    end
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
      # A start that the host lost keeps its lease: no release, whoever joins (finish/3).
      keep_lease: false,
      retry: false,
      obligation: nil,
      reap: false,
      busy: false,
      released: nil
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

  # The lease state of a Run, one correlated observation: the last confirmed lease record
  # (`record`, its sequence in the stream: the claim's, then each confirmed renewal's) with
  # its `until` and generation; the newest reading that showed the lease live (`seen`:
  # newest by the Store's head revision, then by the lease clock sample, then by the node
  # time taken before it, never by the order in which readings reach the host), with the
  # lease record that it shows; the reading taken latest (`post`: the highest mark, so the
  # latest by the node's order of events, whichever the order of arrival); a renewal (or the
  # claim) that replied but is not confirmed yet (`pending`, with its record, `until` and
  # the mark taken on its reply); the deadline taken from `seen`: this node's monotonic
  # time by which the earlier of the last confirmed `until` and the one that `seen` shows
  # passes, for a lease clock that runs no slower than this node's (deadline/1); the moment
  # of the generation's renewal (`due`) and the moment before which a renewal that failed
  # with no write is not tried again (`floor`); and the timers of the deadline and the
  # renewal.
  #
  # What a reading can prove, in either order of arrival:
  #
  #   | Fact                                                  | Loss | Grant | Confirm |
  #   | any status: other holder, none, ambiguous             | yes  | no    | no      |
  #   | any status: inactive, or at or past either `until`   | yes  | no    | no      |
  #   | this owner's live status, no record (uncorrelated)    | no   | no    | no      |
  #   | live status with its record                           | no   | yes   | no      |
  #   | the same, its mark after the pending reply's mark     | no   | yes   | yes     |
  #
  # A reading whose mark is after the reply's started after the reply reached its job, so
  # its record is the pending one or a later one. An admission's loss counts only for the
  # renewal generation of its snapshot (:observed).

  # A reading of the Run's lease, taken after `t0` on this node's clock, from any job, an
  # admission or an activation, in any order of arrival. A reading that shows the lease
  # lost or expired loses the Run (lease_state/3, against the last confirmed `until`). A
  # live reading with its record becomes `seen` when it is newer and `post` when it was
  # taken later; then a pending renewal is confirmed if `post` was taken after its reply
  # (settle/3). An older reading never replaces a newer one, so a confirmation that arrives
  # late keeps a shorter `until` (or another record) that a newer reading showed, and a
  # newer reading still shortens the deadline after a confirmation. No reading changes
  # nothing: the fence needs none.
  defp observed(s, run_ref, t0, read) do
    case s.runs[run_ref] do
      %{phase: phase, admission: admission, lease: l} = run
      when phase in [:starting, :live] and admission != :lease_lost ->
        case lease_state(read, s.c.owner_id, l.until) do
          :live ->
            {:ok, %{revision: revision, now: lease_now, holder: holder} = r} = read

            cond do
              # A reading not known to have sampled the lease clock before a deadline that
              # has passed moves nothing: the fence is due (eligible/2).
              not eligible?(l, read) ->
                s

              # A record later than the claim's, before the claim is confirmed: a re-claim
              # replaced it. The claim is lost, and nothing releases the newer record.
              match?(%{claim: true}, l.pending) and r.record > l.pending.record ->
                lost(s, run_ref, {:lease_lost, %{reason: :superseded, holder: s.c.owner_id}})

              true ->
                reading = %{revision: revision, now: lease_now, until: holder.until, t0: t0}
                reading = Map.merge(reading, %{record: r.record, mark: r.mark})
                l = %{l | seen: newest(l.seen, reading), post: latest(l.post, reading)}
                put_in(s.runs[run_ref], settle(%{run | lease: l}, run_ref, s.c.lease_ttl_ms))
            end

          :unknown ->
            s

          reason ->
            lost(s, run_ref, reason)
        end

      _ ->
        s
    end
  end

  # The pending renewal (or claim) is confirmed by the latest reading when that reading was
  # taken after its reply: of the renewal's record or a later one, of the claim's own
  # record. Its record and `until` become the last confirmed ones, of a new generation with
  # a renewal of its own, and the reading that it obliged the host to take is no longer due:
  # its timer is cancelled, and a job still reading for it is left to end on its own (it is
  # kept until its :DOWN, and its end no longer concerns the new generation, read_done/5).
  # Then the deadline, the renewal and the next obligation follow the lease state: a pending
  # renewal that has no reading under way is read at once, also when an earlier attempt to
  # read it found the deadline past and an eligible reading moved it on.
  defp settle(run, run_ref, ttl) do
    l =
      case run.lease do
        %{pending: %{replied: replied} = p, post: %{mark: mark, record: record}} = l
        when mark > replied and
               ((p.claim and record == p.record) or (not p.claim and record >= p.record)) ->
          with {:timer, timer} <- l.chase, do: cancel(timer)

          %{l | until: p.until, record: p.record, pending: nil, due: nil, floor: nil}
          |> Map.merge(%{generation: make_ref(), chase: nil})

        l ->
          l
      end

    %{run | lease: l}
    |> arm(run_ref, deadline(l), ttl)
    |> schedule(run_ref, ttl)
    |> chase(run_ref, 0)
  end

  # Whether the host may act on a live reading: when the Run's deadline has passed, only a
  # reading whose status read returned before that deadline (`sampled_by`, the node time
  # after its lease clock sample) counts; one that may have sampled the clock at or after
  # the deadline moves nothing and grants nothing.
  defp eligible?(%{deadline: deadline}, {:ok, %{sampled_by: sampled_by}}),
    do: deadline == nil or deadline > now() or sampled_by < deadline

  # Whether a grant may be given on the state that a kept reading left: the Run's tenure is
  # still admitted and its deadline ahead (a passed one is due to be fenced).
  defp ahead?(%{token: token, admission: admission, lease: %{deadline: deadline}}, token)
       when admission != :lease_lost,
       do: deadline != nil and deadline > now()

  defp ahead?(_, _), do: false

  defp latest(nil, reading), do: reading
  defp latest(post, reading), do: if(reading.mark > post.mark, do: reading, else: post)

  # Equally ranked readings (one head revision, one lease clock sample) keep the later node
  # time: the lease clock stood still while the node's moved on.
  defp newest(nil, reading), do: reading

  defp newest(seen, reading) do
    if {reading.revision, reading.now, reading.t0} > {seen.revision, seen.now, seen.t0},
      do: reading,
      else: seen
  end

  # The node time by which the earlier of the last confirmed `until` and the `until` of the
  # newest reading passes, from that reading's lease clock sample, taken after its `t0`.
  defp deadline(%{seen: seen, until: until}),
    do: seen.t0 + div(min(until, seen.until) - seen.now, 1_000)

  # A deadline that moves gets its expiry check min(200 ms, TTL / 4) before it (none when
  # that moment has passed) and its fence; the timers of the deadline that it replaces are
  # cancelled, and the check and the fence of a deadline that is no longer the Run's do
  # nothing if they still come.
  defp arm(run, run_ref, deadline, ttl) do
    if deadline == run.lease.deadline do
      run
    else
      %{expiry: expiry, fence: fence} = Map.merge(%{expiry: nil, fence: nil}, run.lease.timers)
      cancel(expiry)
      cancel(fence)
      check = deadline - min(200, div(ttl, 4)) - now()

      expiry =
        if check > 0,
          do: Process.send_after(self(), {:expiry, run_ref, run.token, deadline}, check)

      fence =
        Process.send_after(self(), {:fence, run_ref, run.token, deadline}, max(deadline - now(), 0))

      timers = Map.merge(run.lease.timers, %{expiry: expiry, fence: fence})
      %{run | lease: %{run.lease | deadline: deadline, timers: timers}}
    end
  end

  # The renewal of a confirmed generation, half the TTL before the Run's deadline, never
  # before the `floor` that a renewal that failed with no write set. A renewal that has not
  # started yet moves earlier when that moment does (a newer reading shortened the
  # deadline): its old timer is cancelled and, if it still comes, starts nothing. A reading
  # that does not shorten the deadline never brings a retry before its `floor`.
  defp schedule(run, run_ref, ttl) do
    %{generation: generation, deadline: deadline, due: due, floor: floor} = l = run.lease
    at = max(deadline - div(ttl, 2), floor || deadline - div(ttl, 2))

    if generation != nil and not l.renewing and l.pending == nil and (due == nil or at < due),
      do: renew_at(run, run_ref, at),
      else: run
  end

  defp renew_at(run, run_ref, at) do
    cancel(run.lease.timers[:renew])
    message = {:renew, run_ref, run.token, run.lease.generation, at}
    timer = Process.send_after(self(), message, max(at - now(), 0))
    %{run | lease: %{run.lease | due: at, timers: Map.put(run.lease.timers, :renew, timer)}}
  end

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer, async: true, info: false)

  # The reading that a pending renewal obliges the host to take: one at a time (`chase`: a
  # timer, then its job), `delay` ms from now, only while the Run's deadline is ahead; taken
  # up again after every reading while the renewal is pending (settle/3, read_done/5), also
  # when a reading taken before a passed deadline moves it on. The claim's worker reads for
  # the claim itself (:claim_read).
  defp chase(
         %{
           phase: phase,
           admission: admission,
           lease: %{pending: %{record: record, claim: false}, chase: nil, deadline: deadline}
         } = run,
         run_ref,
         delay
       )
       when phase in [:starting, :live] and admission != :lease_lost do
    wait = deadline - now()

    if wait > 0 do
      message = {:expiry, run_ref, run.token, {:pending, record}}
      timer = Process.send_after(self(), message, min(delay, wait))
      put_in(run.lease.chase, {:timer, timer})
    else
      run
    end
  end

  defp chase(run, _, _), do: run

  # The expiry check of the Run's current deadline is read again in 100 ms at most, only
  # before that deadline.
  defp read_again(s, run_ref) do
    case s.runs[run_ref] do
      %{token: token, phase: phase, admission: admission, lease: %{deadline: deadline}}
      when phase in [:starting, :live] and admission != :lease_lost ->
        wait = deadline - now()

        if wait > 0,
          do: Process.send_after(self(), {:expiry, run_ref, token, deadline}, min(100, wait))

        s

      _ ->
        s
    end
  end

  @doc false
  # One renewal through the live owner. A renewal that replied comes back with its record
  # (the revision that the owner reports), its `until` and a mark taken on the reply: only
  # a reading taken after that mark can confirm it (settle/3). The job reads nothing.
  def renewal(owner, ttl) do
    case Owner.renew(owner, ttl) do
      {:ok, revision, %{until: until}} when is_integer(until) ->
        {:renewed, until, revision, mark()}

      other ->
        other
    end
  catch
    # A renewal that exits (its caller timeout, or the owner ending) is unconfirmed.
    :exit, _ -> {:unknown, :no_receipt}
  end

  @doc false
  # A reading job: one reading of the lease, in the job's own process, judged for loss
  # against `until` before any record read (lease_reading/4).
  def expiry(lease, key, owner, until) do
    {t0, read} = lease_reading(lease, key, owner, until)
    {:read, t0, read}
  end

  # A reading job of the Run under `key`, bounded by the Run's current deadline (:read_bound).
  defp read_job(s, run_ref, run, key) do
    %{lease: lease, owner_id: owner} = s.c
    {stream, until} = {run.stream, run.lease.until}
    job = Task.Supervisor.async_nolink(s.tasks, fn -> expiry(lease, stream, owner, until) end)
    timer = Process.send_after(self(), {:read_bound, job.ref}, max(run.lease.deadline - now(), 0))
    entry = %{pid: job.pid, timer: timer, key: key, open: true, done: false}
    put_in(s.jobs[job.ref], {:expiry, run_ref, run.token, entry})
  end

  # The end of a reading job: its result, or its :DOWN with no result (a failed reading).
  # The reading that a pending renewal obliged is owed again 100 ms later for as long as
  # that renewal is pending, whatever this reading was (failed, uncorrelated, or taken
  # before the reply). An expiry check that gave no correlated reading is read again within
  # 100 ms under the current deadline.
  defp read_done(s, run_ref, token, key, result) do
    case s.runs[run_ref] do
      %{token: ^token} ->
        {t0, read} =
          case result do
            {:read, t0, read} -> {t0, read}
            _ -> {now(), {:error, :no_reading}}
          end

        s = observed(s, run_ref, t0, read)

        case {key, s.runs[run_ref]} do
          {{:pending, rec}, %{lease: %{chase: {:job, rec}, pending: %{record: rec}}} = run} ->
            put_in(s.runs[run_ref], chase(put_in(run.lease.chase, nil), run_ref, 100))

          {{:pending, _}, _} ->
            s

          _ ->
            if match?({:ok, %{record: r}} when r != nil, read), do: s, else: read_again(s, run_ref)
        end

      _ ->
        s
    end
  end

  defp job(s, {:renew, run_ref, token, generation}, result) do
    case s.runs[run_ref] do
      %{token: ^token} = run -> renewed(s, run_ref, run, generation, result)
      _ -> s
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

  # A release's result is kept until its task has exited (release_exited/3): only then is
  # the reservation freed or handed over, or the release tried again.
  defp job(s, {:release, run_ref, token}, result) do
    case s.runs[run_ref] do
      %{token: ^token, phase: :releasing} = run ->
        put_in(s.runs[run_ref], %{run | released: result})

      _ ->
        s
    end
  end

  # A renewal that replied waits for a reading taken after its reply (settle/3): one that
  # the host already has, or the one that it obliges the host to take at once and again
  # while it is pending (chase/3), or one that an admission or an activation takes. Until
  # then the Run keeps that deadline, whose fence needs no reading. A late renewal reopens
  # nothing, and after a teardown began a result is no loss of a live Run (lost/3).
  defp renewed(s, run_ref, run, generation, {:renewed, until, record, replied}) do
    if current?(run, generation) do
      pending = %{until: until, record: record, replied: replied, claim: false}
      run = %{run | lease: %{run.lease | renewing: false, pending: pending}}
      put_in(s.runs[run_ref], settle(run, run_ref, s.c.lease_ttl_ms))
    else
      s
    end
  end

  # A definite no-write error keeps the token and the deadline; the renewal is tried again
  # within it, a twelfth of the TTL later at the earliest (`floor`); when the deadline comes
  # first, the fence does and no retry is tried.
  defp renewed(s, run_ref, run, generation, {:error, _}) do
    if current?(run, generation) do
      floor = now() + max(div(s.c.lease_ttl_ms, 12), 1)
      run = %{run | lease: %{run.lease | renewing: false, floor: floor}}
      put_in(s.runs[run_ref], renew_at(run, run_ref, floor))
    else
      s
    end
  end

  defp renewed(s, run_ref, _, _, {:refused, reason}), do: lost(s, run_ref, reason)
  defp renewed(s, run_ref, _, _, {:indeterminate, _} = reason), do: lost(s, run_ref, reason)
  defp renewed(s, run_ref, _, _, _), do: lost(s, run_ref, {:unknown, :no_receipt})

  defp current?(run, generation),
    do:
      run.lease.generation == generation and run.phase in [:starting, :live] and
        run.admission != :lease_lost

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
        run = %{run | keep_lease: run.keep_lease or phase == :starting}
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

  # A teardown kills the Run's reading jobs, also one that gave its result and has not
  # exited (one that blocks in the Store holds nothing); like every job, each is waited for
  # until its own :DOWN (finish/3). A reading job spawns no process, so its :DOWN is the end
  # of its reading. The Run's lease timers (expiry check, fence, renewal, the pending
  # renewal's reading) are cancelled: nothing of the lease is due any more.
  defp teardown(s, run_ref, run) do
    token = run.token
    for {_, {:expiry, ^run_ref, ^token, r}} <- s.jobs, do: Process.exit(r.pid, :kill)

    with %{timers: timers, chase: chase} <- run.lease do
      Enum.each(Map.values(timers), &cancel/1)
      with {:timer, timer} <- chase, do: cancel(timer)
    end

    fence(s, run_ref, %{run | phase: :tearing_down, granted: false})
  end

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
  # and waited for otherwise, and every job of the Run (a renewal, an expiry check, the
  # teardown itself) is waited for until its process is gone (a teardown starts no new
  # lease job); then a reap or a failed start releases the lease that the Run owes
  # (release_key/1), and the release's own task is waited for in turn (proceed/3).
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

      run.release and not run.keep_lease and release_key(run) != nil ->
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

  # The result of a release is acted on at the exit of the release task itself, so that
  # neither freeing the reservation nor handing the key over to the next tenure comes
  # before that exit; another process's :DOWN (a callback's that arrives late) does not
  # stand for it.
  defp release_exited(s, run_ref, token) do
    case s.runs[run_ref] do
      %{token: ^token, phase: :releasing, busy: true, released: result} = run
      when result != nil ->
        released(s, run_ref, %{run | busy: false, released: nil}, result)

      _ ->
        s
    end
  end

  defp released(s, run_ref, run, :released),
    do: finish(s, run_ref, %{run | release: false, held: nil, obligation: nil})

  defp released(s, run_ref, run, _), do: unreleased(s, run_ref, run)

  defp jobs?(s, run_ref, token),
    do: Enum.any?(s.jobs, fn {_, job} -> elem(job, 1) == run_ref and elem(job, 2) == token end)

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
