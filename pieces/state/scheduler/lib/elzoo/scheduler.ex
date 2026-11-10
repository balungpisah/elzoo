# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Scheduler do
  @moduledoc """
  `state/scheduler` (ELZ-097): durable schedule definitions and the
  caller-driven driver that turns due slots into admitted occurrences under
  `delivery/trigger`'s identity and overlap policy, then dispatches each
  admitted occurrence as an Oban job through `integration/jobs`.

  Each schedule's ledger is one Store stream (`scheduler/<schedule_id>`); a
  small index stream (`scheduler`) registers schedule ids so `tick/2`,
  `reap/2` and `list/2` can enumerate them. Every write is one atomic append
  batch under head-revision CAS; `{:conflict, _}` maps to `:contended` and
  the losing call changes nothing it had not already committed.

  `tick/2` and `reap/2` run no loop or supervisor; the consumer wires the
  timer (the `delivery/time` recipe) and supplies `now` through the bound
  clock or `opts[:now]`. Dispatch is at-least-once with occurrence-id dedup,
  never exactly-once. The piece reads no environment and starts nothing.
  """
  alias Elzoo.DurableLog.Codec
  alias Elzoo.{Jobs, ScheduleOccurrence}
  alias Elzoo.Scheduler.{Ledger, Record, Slots}

  @index_stream "scheduler"
  @stream_prefix "scheduler/"
  @version 1

  @max_schedules 1_000
  @max_unsettled 1_024
  @max_slots 100
  @max_gap_ms 120_000
  @default_ttl_ms 86_400_000
  @max_ttl_ms 31_536_000_000
  @max_queue_len 128
  @max_attempts 100
  @schedule_id_pattern ~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$/
  @unsettled_statuses [:admitted, :dispatched, :dispatch_pending, :dispatch_error]
  @reserved_backoff_keys ["v", "queue", "job_key"]
  @decision_keys [
    :admitted,
    :skipped,
    :replaced,
    :redefined,
    :expired,
    :dispatched,
    :dispatch_pending,
    :dispatch_errors,
    :settled,
    :settlement_unknown,
    :contended,
    :refused,
    :backlog
  ]

  defstruct [
    :store,
    :fold,
    :limits,
    :clock,
    :oban,
    :timezone_database,
    :max_schedules,
    :max_unsettled_per_schedule,
    :max_slots_per_tick,
    :max_availability_gap_ms,
    :occurrence_ttl_ms
  ]

  @typedoc "skip | replace | {:queue, n} exactly as delivery/trigger declares."
  @type overlap_policy :: :skip | :replace | {:queue, pos_integer()}
  @type spec :: {:cron, String.t()} | {:at, non_neg_integer()}
  @type dispatch :: {String.t(), pos_integer(), map()}

  @doc "Scheduler record kinds to merge into the consumer's fold (`:non_state_bearing`)."
  def kinds, do: Record.kinds()

  @doc """
  Build a scheduler. Options:

  - `store` (required): a ready Store term `{module, opts}`; its `fold.kinds`
    must contain `kinds/0`, `1` must be in `fold.versions`,
    `limits.max_record_bytes >= 1_024` and
    `limits.max_batch_size >= 2 * max_slots_per_tick + 1` (the atomic slot
    batch; settlement, expiry and dispatch effects append in fenced chunks of
    at most `max_batch_size`).
  - `clock` (required): `:system` or a 0-arity fun returning Unix ms.
  - `oban` (required): the Oban instance reference for `Elzoo.Jobs`.
  - `timezone_database`: a `Calendar.TimeZoneDatabase` module (default
    `Calendar.UTCOnlyTimeZoneDatabase` — non-UTC schedules then refuse as
    `:invalid_spec` at `put_schedule`).
  - bounds: `max_schedules` (≤ #{@max_schedules}), `max_unsettled_per_schedule`
    (≤ #{@max_unsettled}), `max_slots_per_tick` (≤ #{@max_slots}),
    `max_availability_gap_ms`, `occurrence_ttl_ms` (the default TTL applied
    to schedules that do not declare one).
  """
  def new(opts) do
    store = Keyword.get(opts, :store)

    store_opts =
      if match?({m, o} when is_atom(m) and (is_map(o) or is_list(o)), store),
        do: Map.new(elem(store, 1)),
        else: %{}

    fold = Map.get(store_opts, :fold)
    limits = Map.get(store_opts, :limits)
    clock = Keyword.get(opts, :clock)
    oban = Keyword.get(opts, :oban)
    tzdb = Keyword.get(opts, :timezone_database, Calendar.UTCOnlyTimeZoneDatabase)
    max_slots = Keyword.get(opts, :max_slots_per_tick, 8)

    with {:ok, clock} <- clock(clock),
         true <-
           (is_atom(tzdb) and Code.ensure_loaded?(tzdb)) || {:error, {:invalid, :timezone_database}},
         {:ok, bounds} <- bounds(opts, max_slots),
         true <- match?({m, _} when is_atom(m), store) || {:error, {:invalid, :store}},
         true <-
           (Codec.fold_valid?(fold) and Map.take(fold.kinds, Record.kind_names()) == kinds() and
              @version in fold.versions) || {:error, {:invalid, :fold}},
         true <-
           (is_map(limits) and is_integer(Map.get(limits, :max_record_bytes)) and
              limits.max_record_bytes >= 1_024 and is_integer(Map.get(limits, :max_batch_size)) and
              limits.max_batch_size >= 2 * bounds.max_slots_per_tick + 1) ||
             {:error, {:invalid, :limits}},
         true <- valid_oban?(oban) || {:error, {:invalid, :oban}} do
      {:ok,
       %__MODULE__{
         store: store,
         fold: fold,
         limits: limits,
         clock: clock,
         oban: oban,
         timezone_database: tzdb,
         max_schedules: bounds.max_schedules,
         max_unsettled_per_schedule: bounds.max_unsettled_per_schedule,
         max_slots_per_tick: bounds.max_slots_per_tick,
         max_availability_gap_ms: bounds.max_availability_gap_ms,
         occurrence_ttl_ms: bounds.occurrence_ttl_ms
       }}
    else
      false -> {:error, {:invalid, :store}}
      {:error, _} = error -> error
    end
  end

  defp clock(:system), do: {:ok, fn -> System.system_time(:millisecond) end}
  defp clock(fun) when is_function(fun, 0), do: {:ok, fun}
  defp clock(_), do: {:error, {:invalid, :clock}}

  # The Oban instance reference `Elzoo.Jobs` accepts: a registered name
  # (atom), a pid, or a `{:via, module, term}` tuple.
  defp valid_oban?(oban),
    do: is_atom(oban) or is_pid(oban) or (is_tuple(oban) and tuple_size(oban) == 3)

  defp bounds(opts, max_slots) do
    fields = [
      max_schedules: {1, @max_schedules},
      max_unsettled_per_schedule: {1, @max_unsettled},
      max_slots_per_tick: {1, @max_slots},
      max_availability_gap_ms: {0, @max_ttl_ms},
      occurrence_ttl_ms: {1, @max_ttl_ms}
    ]

    defaults = %{
      max_schedules: @max_schedules,
      max_unsettled_per_schedule: @max_unsettled,
      max_slots_per_tick: max_slots,
      max_availability_gap_ms: @max_gap_ms,
      occurrence_ttl_ms: @default_ttl_ms
    }

    Enum.find_value(fields, :ok, fn {key, {low, high}} ->
      value = Keyword.get(opts, key, Map.get(defaults, key))

      if is_integer(value) and value >= low and value <= high,
        do: nil,
        else: {:error, {:invalid, key}}
    end)
    |> case do
      :ok ->
        {:ok,
         Map.new(fields, fn {key, _} -> {key, Keyword.get(opts, key, Map.get(defaults, key))} end)}

      error ->
        error
    end
  end

  # ── schedule CRUD ──────────────────────────────────────────────────

  @doc """
  Create or redefine a schedule. `map` is the schedule record
  `%{schedule_id, generation, spec, timezone?, overlap_policy, dispatch,
  occurrence_ttl_ms?}`; a redefine keeps `schedule_id`, requires a strictly
  greater `generation` and records trigger's `redefined` supersessions for
  pending occurrences.
  """
  def put_schedule(scheduler, map) when is_map(map) do
    with {:ok, defn} <- validate_schedule(scheduler, map, now(scheduler)) do
      stream = stream(defn.schedule_id)

      case Ledger.load(scheduler.store, stream, scheduler.fold, scheduler.limits) do
        {:error, :not_found} ->
          not_found()

        {:ok, _head, %{definition: nil}} ->
          create(scheduler, defn)

        {:ok, _head, %{control: :deleted}} ->
          {:error, :not_found}

        {:ok, _head, %{definition: current} = projection} ->
          redefine(scheduler, projection, current, defn)

        {:error, :unreadable} ->
          {:error, :watermark_invalid}

        {:error, :unavailable} ->
          {:error, :store_unavailable}
      end
    end
  end

  def put_schedule(_, _), do: {:error, :invalid_schedule}

  defp create(scheduler, defn) do
    with :ok <- ensure_registered(scheduler, defn.schedule_id) do
      at = now(scheduler)
      defn = Map.put(defn, :at, at)

      specs = [
        {"schedule_defined", Record.defined_payload(defn)},
        {"tick_recorded", Record.tick_payload(at, at, at, 0, 0)}
      ]

      case append(scheduler, stream(defn.schedule_id), 0, specs) do
        {:committed, target} ->
          {:ok, %{created: defn.schedule_id, generation: defn.generation, revision: target}}

        {:conflict, _} ->
          {:error, :contended}

        {:rejected, reason} ->
          {:error, {:invalid, reason}}

        other ->
          store_error(other)
      end
    end
  end

  defp redefine(scheduler, projection, current, defn) do
    cond do
      defn.generation <= current.generation ->
        {:error, :generation_conflict}

      true ->
        with {:ok, trigger} <- restore_trigger(projection, current) do
          case ScheduleOccurrence.redefine(trigger, trigger_schedule(defn)) do
            {:ok, _next, {:redefined, old_generation, superseded}} ->
              at = now(scheduler)
              defn = Map.put(defn, :at, at)
              redefine_commit(scheduler, defn, old_generation, superseded)

            _ ->
              {:error, :watermark_invalid}
          end
        end
    end
  end

  # Supersession records commit first through the fenced chunked append —
  # they always fit `max_batch_size` per chunk however large the unsettled
  # set — and `schedule_defined` follows as its own CAS append at the
  # post-release head. A conflict after the releases leaves them committed
  # (harmless: the occurrences are legitimately superseded) and the retry
  # converges with an empty superseded set.
  defp redefine_commit(scheduler, defn, old_generation, superseded) do
    stream = stream(defn.schedule_id)

    entries =
      Enum.map(superseded, fn id ->
        encoded = encode!(id)

        {encoded, {"occurrence_redefined", Record.redefined_payload(encoded, defn.generation)},
         :effect}
      end)

    case append_fenced(scheduler, stream, entries) do
      :ok ->
        redefine_defined(scheduler, stream, defn, old_generation, superseded)

      {:error, :contended} ->
        {:error, :contended}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp redefine_defined(scheduler, stream, defn, old_generation, superseded) do
    case Ledger.load(scheduler.store, stream, scheduler.fold, scheduler.limits) do
      {:ok, _head, %{control: :deleted}} ->
        {:error, :not_found}

      {:ok, head, _} ->
        case append(scheduler, stream, head.revision, [
               {"schedule_defined", Record.defined_payload(defn)}
             ]) do
          {:committed, target} ->
            {:ok,
             %{
               redefined: defn.schedule_id,
               generation: {old_generation, defn.generation},
               superseded: Enum.map(superseded, &encode!/1),
               revision: target
             }}

          {:conflict, _} ->
            {:error, :contended}

          {:rejected, reason} ->
            {:error, {:invalid, reason}}

          other ->
            store_error(other)
        end

      {:error, :unavailable} ->
        {:error, :store_unavailable}

      {:error, _} ->
        {:error, :watermark_invalid}
    end
  end

  defp restore_trigger(projection, defn) do
    restore_trigger(projection, defn, unsettled_ids(projection))
  end

  defp restore_trigger(projection, defn, unsettled_encoded) do
    last = projection.last_recorded || 0
    unsettled = Enum.map(unsettled_encoded, &decode_id!/1)

    case ScheduleOccurrence.restore(trigger_schedule(defn), last, unsettled) do
      {:ok, state} -> {:ok, state}
      _ -> {:error, :watermark_invalid}
    end
  end

  defp trigger_schedule(defn),
    do: %{
      schedule_id: defn.schedule_id,
      generation: defn.generation,
      policy: defn.overlap_policy,
      payload: "#{defn.generation}:#{defn.schedule_id}"
    }

  defp ensure_registered(scheduler, schedule_id) do
    case Ledger.load_index(scheduler.store, @index_stream, scheduler.fold, scheduler.limits) do
      {:ok, head, ids} ->
        cond do
          length(ids) >= scheduler.max_schedules and schedule_id not in ids ->
            {:error, :invalid_schedule}

          schedule_id in ids ->
            :ok

          true ->
            case append(scheduler, @index_stream, head.revision, [
                   {"index_registered", Record.index_payload(schedule_id, now(scheduler))}
                 ]) do
              {:committed, _} -> :ok
              {:conflict, _} -> {:error, :contended}
              {:rejected, _} -> {:error, :invalid_schedule}
              other -> store_error(other)
            end
        end

      {:error, :not_found} ->
        case append(scheduler, @index_stream, 0, [
               {"index_registered", Record.index_payload(schedule_id, now(scheduler))}
             ]) do
          {:committed, _} -> :ok
          {:conflict, _} -> {:error, :contended}
          {:rejected, _} -> {:error, :invalid_schedule}
          other -> store_error(other)
        end

      {:error, :unreadable} ->
        {:error, :watermark_invalid}

      {:error, :unavailable} ->
        {:error, :store_unavailable}
    end
  end

  @doc "Pause slot evaluation for the schedule (durable transition; in-flight occurrences are untouched)."
  def pause(scheduler, schedule_id), do: control(scheduler, schedule_id, :paused, "schedule_paused")

  @doc "Resume a paused schedule."
  def resume(scheduler, schedule_id),
    do: control(scheduler, schedule_id, :active, "schedule_resumed")

  defp control(scheduler, schedule_id, want, kind) do
    with :ok <- schedule_id(schedule_id),
         {:ok, head, projection} <- load_schedulable(scheduler, schedule_id) do
      cond do
        projection.control == :deleted ->
          {:error, :not_found}

        projection.control == want ->
          {:ok, %{schedule: schedule_id, control: want, revision: head.revision}}

        true ->
          case append(scheduler, stream(schedule_id), head.revision, [
                 {kind, Record.control_payload(now(scheduler))}
               ]) do
            {:committed, target} -> {:ok, %{schedule: schedule_id, control: want, revision: target}}
            {:conflict, _} -> {:error, :contended}
            {:rejected, reason} -> {:error, {:invalid, reason}}
            other -> store_error(other)
          end
      end
    end
  end

  @doc """
  Retire the schedule: unsettled occurrences are recorded `released`, their
  Oban jobs cancelled through `Elzoo.Jobs.cancel/3`, pending slots stop and
  the index entry is retired.
  """
  def delete(scheduler, schedule_id) do
    with :ok <- schedule_id(schedule_id),
         {:ok, head, projection} <- load_schedulable(scheduler, schedule_id) do
      at = now(scheduler)
      unsettled = unsettled_ids(projection)

      # Releases commit first through the fenced chunked append — they always
      # fit `max_batch_size` per chunk however large the unsettled set — and
      # the `schedule_deleted` control record follows as its own CAS append.
      # A conflict after the releases leaves them committed (harmless: the
      # occurrences are legitimately released) and the retry converges.
      case release_unsettled(scheduler, schedule_id, projection, at) do
        :ok ->
          delete_control(scheduler, schedule_id, head, projection, unsettled, at)

        {:error, :contended} ->
          {:error, :contended}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp release_unsettled(scheduler, schedule_id, projection, at) do
    entries =
      projection
      |> unsettled_ids()
      |> Enum.map(fn id ->
        {id, {"occurrence_settled", Record.settled_payload(id, :released, :deleted, at)}, :effect}
      end)

    append_fenced(scheduler, stream(schedule_id), entries)
  end

  defp delete_control(scheduler, schedule_id, head, projection, unsettled, at) do
    cond do
      projection.control == :deleted ->
        # Retry index retirement: an earlier delete may have committed the
        # control record while its index append lost, leaving a phantom entry
        # that would report `refused: :retired` on every later tick/reap.
        retire_index(scheduler, schedule_id)

        {:ok, %{schedule: schedule_id, control: :deleted, released: 0, revision: head.revision}}

      true ->
        stream = stream(schedule_id)

        case Ledger.load(scheduler.store, stream, scheduler.fold, scheduler.limits) do
          {:ok, head2, %{control: :deleted}} ->
            {:ok,
             %{schedule: schedule_id, control: :deleted, released: 0, revision: head2.revision}}

          {:ok, head2, _} ->
            case append(scheduler, stream, head2.revision, [
                   {"schedule_deleted", Record.control_payload(at)}
                 ]) do
              {:committed, target} ->
                cancel_jobs(scheduler, projection, unsettled)
                retire_index(scheduler, schedule_id)

                {:ok,
                 %{
                   schedule: schedule_id,
                   control: :deleted,
                   released: length(unsettled),
                   revision: target
                 }}

              {:conflict, _} ->
                {:error, :contended}

              {:rejected, reason} ->
                {:error, {:invalid, reason}}

              other ->
                store_error(other)
            end

          {:error, :unavailable} ->
            {:error, :store_unavailable}

          {:error, _} ->
            {:error, :watermark_invalid}
        end
    end
  end

  # Cancellation is by (queue, job_key): it reaches the job whether or not a
  # dispatch record was committed, and is a no-op when none exists.
  defp cancel_jobs(scheduler, projection, ids) do
    {queue, _, _} = projection.definition.dispatch
    Enum.each(ids, fn id -> Jobs.cancel(scheduler.oban, queue, id) end)
  end

  # Bounded CAS retry: a conflict reloads the index and re-checks membership,
  # so a lost race converges instead of leaving a phantom entry that would
  # report `refused: :retired` on every later tick/reap.
  defp retire_index(scheduler, schedule_id, attempts \\ 16)

  defp retire_index(_scheduler, _schedule_id, attempts) when attempts <= 0, do: :ok

  defp retire_index(scheduler, schedule_id, attempts) do
    case Ledger.load_index(scheduler.store, @index_stream, scheduler.fold, scheduler.limits) do
      {:ok, head, ids} when ids != [] ->
        if schedule_id in ids do
          case append(scheduler, @index_stream, head.revision, [
                 {"index_retired", Record.index_payload(schedule_id, now(scheduler))}
               ]) do
            {:committed, _} -> :ok
            {:conflict, _} -> retire_index(scheduler, schedule_id, attempts - 1)
            _ -> :ok
          end
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  @doc "The schedule's durable definition record, or `:not_found`."
  def get(scheduler, schedule_id) do
    with :ok <- schedule_id(schedule_id),
         {:ok, _head, projection} <- load_schedulable(scheduler, schedule_id) do
      {:ok, Map.delete(projection.definition, :at)}
    end
  end

  @doc """
  Schedule state, watermark, `last_tick_ok_at`, unsettled count and
  dispatch-pending count `as_of` a head revision.
  """
  def status(scheduler, schedule_id) do
    with :ok <- schedule_id(schedule_id),
         {:ok, head, projection} <- load_schedulable(scheduler, schedule_id) do
      unsettled = unsettled(projection)

      {:ok,
       %{
         schedule: schedule_id,
         state: projection.control,
         generation: projection.definition.generation,
         watermark: projection.last_recorded,
         last_tick_ok_at: projection.last_tick_ok_at,
         unsettled: length(unsettled),
         dispatch_pending: Enum.count(unsettled, fn {_id, o} -> is_nil(Map.get(o, :job_id)) end),
         as_of: head.revision
       }}
    end
  end

  @doc "List the durable status of every indexed schedule (`limit` bounds the page)."
  def list(scheduler, opts \\ []) do
    limit = Keyword.get(opts, :limit, scheduler.max_schedules)

    case Ledger.load_index(scheduler.store, @index_stream, scheduler.fold, scheduler.limits) do
      {:error, :not_found} ->
        {:ok, []}

      {:ok, _head, ids} ->
        result =
          ids
          |> Enum.take(max(0, min(limit, scheduler.max_schedules)))
          |> Enum.map(&status(scheduler, &1))
          |> Enum.flat_map(fn
            {:ok, status} -> [status]
            {:error, _} -> []
          end)

        {:ok, result}

      {:error, :unreadable} ->
        {:error, :watermark_invalid}

      {:error, :unavailable} ->
        {:error, :store_unavailable}
    end
  end

  defp load_schedulable(scheduler, schedule_id) do
    case Ledger.load(scheduler.store, stream(schedule_id), scheduler.fold, scheduler.limits) do
      {:error, :not_found} -> {:error, :not_found}
      {:ok, _head, %{definition: nil}} -> {:error, :not_found}
      {:ok, head, projection} -> {:ok, head, projection}
      {:error, :unreadable} -> {:error, :watermark_invalid}
      {:error, :unavailable} -> {:error, :store_unavailable}
    end
  end

  # ── tick ───────────────────────────────────────────────────────────

  @doc """
  One caller-driven evaluation round over every active indexed schedule. Each
  schedule: reconcile settlements of already-dispatched occurrences from Oban
  job state through a fenced chunked append, reload, then restore trigger
  state from durable `last_recorded` + the post-settlement unsettled ledger +
  `last_tick_ok_at`, compute the availability boundary (the persisted
  `last_boundary`, or `last_tick_ok_at` when `now - last_tick_ok_at <=
  max_availability_gap_ms`, else `now`), evaluate at most
  `max_slots_per_tick` earliest due slots in UTC-instant order, `admit_slots`,
  and commit slot decisions + watermark (last evaluated instant only) +
  trigger state + `last_tick_ok_at` + boundary + unsettled count as one
  atomic batch under stream-head CAS. Admitted occurrences then dispatch as
  Oban jobs (`job_key` = encoded occurrence id) with the outcome persisted
  through a fenced append. Returns `%{schedule_id => decisions}`, or
  `{:error, reason}` when the index stream cannot be enumerated — an absent
  index reads as no schedules, a corrupt one fails closed.
  """
  def tick(scheduler, opts \\ []) do
    now = Keyword.get(opts, :now, scheduler.clock.())

    case active_ids(scheduler) do
      {:ok, ids} -> Map.new(ids, &{&1, tick_schedule(scheduler, &1, now)})
      {:error, reason} -> {:error, reason}
    end
  end

  defp tick_schedule(scheduler, schedule_id, now) do
    result =
      with {:ok, head, projection} <- tick_load(scheduler, schedule_id),
           {:ok, projection} <- tick_gate(scheduler, projection, now),
           {:spec, spec} when spec != :invalid <-
             {:spec, spec(scheduler, projection.definition.spec)},
           {:ok, emissions, backlog} <-
             Slots.due(
               spec,
               projection.definition.timezone,
               scheduler.timezone_database,
               projection.last_recorded,
               now,
               scheduler.max_slots_per_tick
             ) do
        admit_and_commit(scheduler, schedule_id, head, projection, emissions, backlog, now)
      else
        {:refused, reason} -> decision(refused: reason)
        {:error, reason} -> decision(refused: reason)
        {:spec, :invalid} -> decision(refused: :invalid_spec)
      end

    telemetry(schedule_id, :tick, Map.take(result, @decision_keys))
    result
  end

  defp tick_load(scheduler, schedule_id) do
    case Ledger.load(scheduler.store, stream(schedule_id), scheduler.fold, scheduler.limits) do
      {:ok, _head, %{control: :deleted}} -> {:error, :retired}
      {:ok, _head, %{definition: nil}} -> {:error, :not_found}
      {:ok, head, projection} -> {:ok, head, projection}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :unreadable} -> {:error, :watermark_invalid}
      {:error, :unavailable} -> {:error, :store_unavailable}
    end
  end

  defp tick_gate(_scheduler, projection, now) do
    cond do
      projection.control == :paused -> {:refused, :paused}
      not is_integer(projection.last_recorded) -> {:refused, :watermark_invalid}
      not is_integer(projection.last_tick_ok_at) -> {:refused, :watermark_invalid}
      projection.last_tick_ok_at > now -> {:refused, :watermark_invalid}
      true -> {:ok, projection}
    end
  end

  # The availability boundary is the classification threshold persisted by the
  # last committed tick, not the last tick instant: slots a bounded tick left
  # unevaluated keep the live/offline classification they would have had, so
  # truncation never turns known-available backlog into offline catch-up. A
  # silence longer than `max_availability_gap_ms` is genuine downtime — every
  # still-pending slot passed while offline — so the boundary jumps to `now`.
  defp boundary(projection, now, max_gap_ms) do
    if now - projection.last_tick_ok_at <= max_gap_ms,
      do: projection.last_boundary || projection.last_tick_ok_at,
      else: now
  end

  # Derived settlement scan over Oban state, returning `[{encoded_id, kind,
  # via}]` facts. Runs BEFORE admission so a job that completed since the last
  # tick frees its overlap slot within the same tick; the facts are committed
  # through the fenced append and admission then reads post-settlement state.
  # In-flight states yield no fact; an unreadable state is
  # :settlement_unknown and never guessed.
  defp scan_settlements(scheduler, projection) do
    Enum.reduce(unsettled(projection), {[], %{settled: 0, settlement_unknown: 0}, false}, fn
      {id, %{job_id: job_id}}, {facts, counts, unavailable} when is_integer(job_id) ->
        case Jobs.state_by_id(scheduler.oban, job_id) do
          {:ok, {_id, "completed"}} ->
            {[{id, :acknowledged, :completed} | facts], %{counts | settled: counts.settled + 1},
             unavailable}

          {:ok, {_id, state}} when state in ["discarded", "cancelled"] ->
            {[{id, :released, String.to_atom(state)} | facts],
             %{counts | settled: counts.settled + 1}, unavailable}

          {:ok, {_id, _in_flight}} ->
            {facts, counts, unavailable}

          _ ->
            {facts, %{counts | settlement_unknown: counts.settlement_unknown + 1}, true}
        end

      _id_occ, acc ->
        acc
    end)
  end

  defp admit_and_commit(scheduler, schedule_id, head, projection, emissions, backlog, now) do
    b = boundary(projection, now, scheduler.max_availability_gap_ms)
    winners = for {instant, :win} <- emissions, do: instant
    ambiguous = for {instant, :ambiguous} <- emissions, do: instant

    {settle_facts, settle_counts, jobs_unavailable} = scan_settlements(scheduler, projection)

    settle_entries =
      Enum.map(settle_facts, fn {id, kind, via} ->
        {id, {"occurrence_settled", Record.settled_payload(id, kind, via, now)}, :effect}
      end)

    # Settlements commit first through the fenced chunked append, then the
    # stream is reloaded: admission sees post-settlement state (a completed
    # job's overlap slot is already free) and the slot batch gets a fresh
    # head revision. A conflict here abandons only this tick's admission.
    case commit_settlements(scheduler, schedule_id, head, projection, settle_entries) do
      {:ok, head2, projection2} ->
        with {:ok, trigger} <- restore_trigger(projection2, projection2.definition),
             {:ok, next_trigger, trigger_decisions} <-
               ScheduleOccurrence.admit_slots(
                 trigger,
                 winners,
                 %{now_unix_ms: now, available_since_unix_ms: b}
               ) do
          slot_records =
            Enum.map(trigger_decisions, &decision_record(&1, now, b)) ++
              Enum.map(
                ambiguous,
                &{"slot_decided",
                 Record.slot_payload(&1, %{"decision" => "skipped", "reason" => "ambiguous"})}
              )

          {:ok, inspected} = ScheduleOccurrence.inspect_state(next_trigger)

          new_watermark =
            case List.last(emissions) do
              nil -> projection2.last_recorded
              {instant, _} -> instant
            end

          # One atomic batch: slot decisions and the tick record commit or
          # nothing does, so the watermark never advances past an uncommitted
          # decision and a concurrent write forces :contended.
          specs =
            slot_records ++
              [
                {"tick_recorded",
                 Record.tick_payload(
                   now,
                   new_watermark,
                   b,
                   backlog,
                   length(inspected.unsettled)
                 )}
              ]

          case append(scheduler, stream(schedule_id), head2.revision, specs) do
            {:committed, _} ->
              committed =
                merge_projection(
                  projection2,
                  trigger_decisions,
                  b,
                  new_watermark,
                  now
                )

              dispatch_committed(
                scheduler,
                schedule_id,
                committed,
                trigger_decisions,
                ambiguous,
                backlog,
                settle_counts,
                jobs_unavailable
              )

            {:conflict, _} ->
              decision(contended: true, backlog: backlog)

            {:rejected, reason} ->
              decision(refused: reason)

            other ->
              decision(refused: store_reason(other))
          end
        else
          {:error, :watermark_invalid} -> decision(refused: :watermark_invalid)
          {:error, _} -> decision(refused: :invalid_slots)
        end

      :contended ->
        decision(contended: true, backlog: backlog)

      {:error, reason} ->
        decision(refused: reason)
    end
  end

  # `{:ok, head, projection}` with settlements applied (a no-op reload when
  # there is nothing to settle), `:contended` or `{:error, reason}`.
  defp commit_settlements(_scheduler, _schedule_id, head, projection, []) do
    {:ok, head, projection}
  end

  defp commit_settlements(scheduler, schedule_id, _head, _projection, entries) do
    stream = stream(schedule_id)

    case append_fenced(scheduler, stream, entries) do
      :ok ->
        case Ledger.load(scheduler.store, stream, scheduler.fold, scheduler.limits) do
          {:ok, head, projection} -> {:ok, head, projection}
          {:error, :unavailable} -> {:error, :store_unavailable}
          {:error, _} -> {:error, :watermark_invalid}
        end

      {:error, :contended} ->
        :contended

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decision_record({:occurrence, id, origin}, now, _b),
    do:
      {"slot_decided",
       Record.slot_payload(elem(id, 3), %{
         "decision" => "admitted",
         "id" => encode!(id),
         "origin" => Atom.to_string(origin),
         "at" => now
       })}

  defp decision_record({:skipped, slot, reason}, _now, _b),
    do:
      {"slot_decided",
       Record.slot_payload(slot, %{"decision" => "skipped", "reason" => Atom.to_string(reason)})}

  # Trigger's `{:replaced, old, new}` carries no origin; the new occurrence's
  # classification follows the same rule trigger applies — its instant before
  # the availability boundary is `:offline_catch_up`, otherwise `:live`.
  defp decision_record({:replaced, old, new}, now, b),
    do:
      {"slot_decided",
       Record.slot_payload(elem(new, 3), %{
         "decision" => "replaced",
         "old" => encode!(old),
         "new" => encode!(new),
         "origin" => Atom.to_string(replaced_origin(new, b)),
         "at" => now
       })}

  defp decision_record({:already_recorded, slot}, _now, _b),
    do: {"slot_decided", Record.slot_payload(slot, %{"decision" => "already_recorded"})}

  defp replaced_origin(id, b), do: if(elem(id, 3) < b, do: :offline_catch_up, else: :live)

  # Apply the committed slot batch to the in-memory projection so dispatch
  # sees the post-admission world without a second durable read: slot
  # decisions admit/replace and the tick fields (watermark, boundary,
  # last_tick_ok_at) advance together. Settlements are already durable — the
  # projection was reloaded after their fenced commit.
  defp merge_projection(projection, trigger_decisions, b, new_watermark, now) do
    occurrences =
      Enum.reduce(trigger_decisions, projection.occurrences, fn
        {:occurrence, id, origin}, acc ->
          Map.put(acc, encode!(id), %{status: :admitted, origin: origin, admitted_at: now})

        {:replaced, old, new}, acc ->
          acc
          |> Map.put(encode!(old), %{status: :replaced, by: encode!(new)})
          |> Map.put(encode!(new), %{
            status: :admitted,
            origin: replaced_origin(new, b),
            admitted_at: now
          })

        _, acc ->
          acc
      end)

    %{
      projection
      | occurrences: occurrences,
        last_tick_ok_at: now,
        last_boundary: b,
        last_recorded: new_watermark
    }
  end

  # Post-commit dispatch: enqueue every still-unsettled occurrence that has no
  # recorded job, then persist the dispatch outcome through a fenced append.
  # `settle_counts`/`jobs_unavailable` come from the pre-admission scan whose
  # records already committed with the tick batch.
  defp dispatch_committed(
         scheduler,
         schedule_id,
         projection,
         trigger_decisions,
         ambiguous,
         backlog,
         settle_counts,
         jobs_unavailable
       ) do
    {queue, max_attempts, backoff} = projection.definition.dispatch

    dispatch_results =
      unsettled(projection)
      |> Enum.reject(fn {_id, occ} -> is_integer(Map.get(occ, :job_id)) end)
      |> Enum.map(fn {id, _occ} -> dispatch_one(scheduler, queue, id, max_attempts, backoff) end)

    entries =
      Enum.map(dispatch_results, fn
        {:dispatched, id, job_id} ->
          {id,
           {"occurrence_dispatch", Record.dispatch_record_payload(id, "dispatched", job_id, nil)},
           {:dispatch, "dispatched", job_id}}

        {:pending, id} ->
          {id,
           {"occurrence_dispatch",
            Record.dispatch_record_payload(id, "pending", nil, "unique_lock_held")},
           {:dispatch, "pending", nil}}

        {:error, id, detail} ->
          {id, {"occurrence_dispatch", Record.dispatch_record_payload(id, "error", nil, detail)},
           {:dispatch, "error", nil}}
      end)

    {contended, append_error} =
      case entries do
        [] ->
          {false, nil}

        _ ->
          case append_fenced(scheduler, stream(schedule_id), entries) do
            :ok -> {false, nil}
            {:error, :contended} -> {true, nil}
            {:error, reason} -> {false, reason}
          end
      end

    if jobs_unavailable, do: telemetry(schedule_id, :settlement_unknown, %{})

    Enum.each(trigger_decisions, fn
      {:occurrence, id, origin} ->
        telemetry(schedule_id, :admitted, %{occurrence: encode!(id), origin: origin})

      {:replaced, _old, new} ->
        telemetry(schedule_id, :admitted, %{
          occurrence: encode!(new),
          origin: replaced_origin(new, projection.last_boundary)
        })

      _ ->
        :ok
    end)

    Enum.each(dispatch_results, fn
      {:error, id, _} -> telemetry(schedule_id, :dispatch_error, %{occurrence: id})
      _ -> :ok
    end)

    admitted = Enum.count(trigger_decisions, &match?({:occurrence, _, _}, &1))

    decision(
      admitted: admitted,
      skipped: Enum.count(trigger_decisions, &match?({:skipped, _, _}, &1)) + length(ambiguous),
      replaced: Enum.count(trigger_decisions, &match?({:replaced, _, _}, &1)),
      dispatched: Enum.count(dispatch_results, &match?({:dispatched, _, _}, &1)),
      dispatch_pending: Enum.count(dispatch_results, &match?({:pending, _}, &1)),
      dispatch_errors: Enum.count(dispatch_results, &match?({:error, _, _}, &1)),
      settled: settle_counts.settled,
      settlement_unknown: settle_counts.settlement_unknown,
      contended: contended,
      refused: append_error,
      backlog: backlog
    )
  end

  defp dispatch_one(scheduler, queue, id, max_attempts, backoff) do
    changeset = Jobs.changeset(queue, id, max_attempts, backoff)

    case Jobs.enqueue(scheduler.oban, changeset) do
      {:ok, job_id} -> {:dispatched, id, job_id}
      {:retry, :unique_lock_held} -> {:pending, id}
      {:error, reason} -> {:error, id, dispatch_detail(reason)}
    end
  end

  # Bounded, JSON-safe detail for the durable dispatch record — never the
  # raw reason term (a changeset or exception is neither encodable nor
  # bounded).
  defp dispatch_detail(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp dispatch_detail(reason) when is_binary(reason), do: String.slice(reason, 0, 200)

  defp dispatch_detail(reason),
    do: reason |> inspect() |> String.slice(0, 200)

  # Fenced, chunked append for effects that name an occurrence (pre-tick
  # settlements, dispatch records, reap settlements/expiries, delete
  # releases). Each entry is `{encoded_id, {kind, payload}, check}`; before
  # every append the stream is reloaded and entries whose effect is already
  # reflected — or whose occurrence is no longer unsettled — are dropped, so
  # a stale effect can never resurrect a terminal occurrence (terminal states
  # are sticky in the projection) and a committed chunk never repeats.
  # `check` is `:effect` for terminal records (settled/expired/released: done
  # once the occurrence leaves the unsettled set) or
  # `{:dispatch, phase, job_id}` for dispatch records (done once the
  # projection shows that phase with that job id). Kept entries append in
  # chunks of at most `max_batch_size`, each its own CAS append; conflicts
  # retry (bounded) and committed chunks drop out of the next reload, so the
  # call converges. An unwritten dispatch record is safe because the next
  # tick re-derives dispatch state.
  defp append_fenced(scheduler, stream, entries, attempts \\ 64)

  defp append_fenced(_scheduler, _stream, [], _attempts), do: :ok

  defp append_fenced(_scheduler, _stream, _entries, attempts) when attempts <= 0,
    do: {:error, :contended}

  defp append_fenced(scheduler, stream, entries, attempts) do
    case Ledger.load(scheduler.store, stream, scheduler.fold, scheduler.limits) do
      {:ok, head, projection} ->
        kept =
          for {id, spec, check} <- entries, keep_entry?(projection, id, check), do: spec

        if kept == [] do
          :ok
        else
          {chunk, _rest} = Enum.split(kept, scheduler.limits.max_batch_size)

          case append(scheduler, stream, head.revision, chunk) do
            {:committed, _} ->
              append_fenced(scheduler, stream, entries, attempts - 1)

            {:conflict, _} ->
              append_fenced(scheduler, stream, entries, attempts - 1)

            {:rejected, reason} ->
              {:error, reason}

            other ->
              {:error, store_reason(other)}
          end
        end

      {:error, :unavailable} ->
        {:error, :store_unavailable}

      {:error, _} ->
        {:error, :watermark_invalid}
    end
  end

  defp keep_entry?(projection, id, check) do
    with %{status: status} = occ <- Map.get(projection.occurrences, id),
         true <- status in @unsettled_statuses do
      case check do
        :effect ->
          true

        {:dispatch, phase, job_id} ->
          not (status == dispatch_status(phase) and Map.get(occ, :job_id) == job_id)
      end
    else
      _ -> false
    end
  end

  defp dispatch_status("dispatched"), do: :dispatched
  defp dispatch_status("pending"), do: :dispatch_pending
  defp dispatch_status("error"), do: :dispatch_error

  # ── reap ───────────────────────────────────────────────────────────

  @doc """
  Expire unsettled occurrences whose age since admission exceeds the
  schedule's `occurrence_ttl_ms`: the ledger records `occurrence_expired`
  (the released settlement that frees the overlap slot) and a live Oban job
  is cancelled so a late completion cannot resurrect the occurrence.
  Oban-state reconcile runs first, as in `tick/2`. Returns
  `%{schedule_id => decisions}`, or `{:error, reason}` when the index
  stream cannot be enumerated.
  """
  def reap(scheduler, opts \\ []) do
    now = Keyword.get(opts, :now, scheduler.clock.())

    case active_ids(scheduler) do
      {:ok, ids} -> Map.new(ids, &{&1, reap_schedule(scheduler, &1, now)})
      {:error, reason} -> {:error, reason}
    end
  end

  defp reap_schedule(scheduler, schedule_id, now) do
    case tick_load(scheduler, schedule_id) do
      {:ok, _head, projection} ->
        {queue, _, _} = projection.definition.dispatch
        ttl = ttl(projection.definition)

        # Reconcile Oban state for ALL unsettled occurrences before the TTL
        # split: a job that reached a terminal state — even one that completed
        # before its first post-TTL reap — settles acknowledged/released and
        # must never be recorded expired.
        {settle_facts, settle_counts, jobs_unavailable} = scan_settlements(scheduler, projection)

        settled_ids = MapSet.new(for {id, _, _} <- settle_facts, do: id)

        expired =
          projection
          |> unsettled()
          |> Enum.reject(fn {id, _occ} -> MapSet.member?(settled_ids, id) end)
          |> Enum.filter(fn {_id, occ} -> older_than?(occ, ttl, now) end)

        entries =
          Enum.map(expired, fn {id, _occ} ->
            {id, {"occurrence_expired", Record.expired_payload(id, now)}, :effect}
          end) ++
            Enum.map(settle_facts, fn {id, kind, via} ->
              {id, {"occurrence_settled", Record.settled_payload(id, kind, via, now)}, :effect}
            end)

        case append_fenced(scheduler, stream(schedule_id), entries) do
          :ok ->
            if jobs_unavailable, do: telemetry(schedule_id, :settlement_unknown, %{})

            Enum.each(expired, fn {id, _occ} ->
              Jobs.cancel(scheduler.oban, queue, id)
              telemetry(schedule_id, :expired, %{occurrence: id})
            end)

            decision(
              expired: length(expired),
              settled: settle_counts.settled,
              settlement_unknown: settle_counts.settlement_unknown
            )

          {:error, :contended} ->
            decision(contended: true)

          {:error, reason} ->
            decision(refused: reason)
        end

      {:error, reason} ->
        decision(refused: reason)
    end
  end

  defp older_than?(occ, ttl, now) do
    case Map.get(occ, :admitted_at) do
      admitted_at when is_integer(admitted_at) -> now - admitted_at > ttl
      _ -> false
    end
  end

  defp ttl(%{occurrence_ttl_ms: ttl}), do: ttl

  # ── shared helpers ─────────────────────────────────────────────────

  # `{:ok, ids}`; `{:error, :not_found}` reads as an empty index (no
  # schedules registered yet). A corrupt or unavailable index fails closed —
  # returning `%{}` would be indistinguishable from "no schedules".
  defp active_ids(scheduler) do
    case Ledger.load_index(scheduler.store, @index_stream, scheduler.fold, scheduler.limits) do
      {:ok, _head, ids} -> {:ok, ids}
      {:error, :not_found} -> {:ok, []}
      {:error, :unavailable} -> {:error, :store_unavailable}
      {:error, _} -> {:error, :watermark_invalid}
    end
  end

  defp unsettled(projection),
    do:
      projection.occurrences
      |> Enum.filter(fn {_id, o} -> o.status in @unsettled_statuses end)
      |> Enum.sort_by(fn {id, _} -> id end)

  defp unsettled_ids(projection), do: Enum.map(unsettled(projection), &elem(&1, 0))

  defp append(scheduler, stream, expected, specs) do
    case Record.records(stream, expected, specs, scheduler.fold, scheduler.limits) do
      {:ok, rows, _request} ->
        {module, _} = scheduler.store
        module.append(scheduler.store, stream, expected, rows, [])

      {:error, {:rejected, reason}} ->
        {:rejected, reason}
    end
  end

  defp store_error({:indeterminate, _}), do: {:error, :store_unavailable}
  defp store_error({:error, :unavailable}), do: {:error, :store_unavailable}
  defp store_error({:error, :caller_transaction}), do: {:error, :caller_transaction}
  defp store_error(other), do: {:error, {:store, other}}

  defp store_reason({:indeterminate, _}), do: :store_unavailable
  defp store_reason({:error, :unavailable}), do: :store_unavailable
  defp store_reason({:error, :caller_transaction}), do: :caller_transaction
  defp store_reason(_), do: :store_unavailable

  defp not_found, do: {:error, :not_found}

  defp schedule_id(id) when is_binary(id),
    do: if(id =~ @schedule_id_pattern, do: :ok, else: {:error, :invalid_schedule})

  defp schedule_id(_), do: {:error, :invalid_schedule}

  defp stream(id), do: @stream_prefix <> id

  defp spec(_scheduler, {:cron, expr}), do: Slots.parse_cron(expr) |> elem_wrap()
  defp spec(_scheduler, {:at, instant}), do: {:at, instant}
  defp elem_wrap({:ok, parsed}), do: {:cron, parsed}
  defp elem_wrap({:error, _}), do: :invalid

  defp now(scheduler), do: scheduler.clock.()

  defp encode!({:OccurrenceId, _, _, _} = id), do: elem(ScheduleOccurrence.encode_id(id), 1)

  defp decode_id!(text), do: elem(ScheduleOccurrence.decode_id(text), 1)

  defp telemetry(schedule_id, event, extra) do
    :telemetry.execute(
      [:elzoo, :scheduler, event],
      %{count: 1},
      Map.merge(%{schedule_id: schedule_id}, extra)
    )
  end

  defp decision(fields) do
    Map.merge(
      %{
        admitted: 0,
        skipped: 0,
        replaced: 0,
        redefined: 0,
        expired: 0,
        dispatched: 0,
        dispatch_pending: 0,
        dispatch_errors: 0,
        settled: 0,
        settlement_unknown: 0,
        contended: false,
        refused: nil,
        backlog: 0
      },
      Map.new(fields)
    )
  end

  # ── schedule record validation ─────────────────────────────────────

  defp validate_schedule(scheduler, map, now) do
    with {:ok, id} <- field(map, :schedule_id, &schedule_id_field/1),
         {:ok, generation} <- field(map, :generation, &generation_field/1),
         {:ok, spec} <- spec_field(map),
         {:ok, zone} <- timezone_field(scheduler, map),
         {:ok, overlap} <- overlap_field(scheduler, map),
         {:ok, dispatch} <- dispatch_field(map),
         {:ok, ttl} <- ttl_field(scheduler, map),
         {:ok, _} <- at_ok(spec, now) do
      {:ok,
       %{
         schedule_id: id,
         generation: generation,
         spec: spec,
         timezone: zone,
         overlap_policy: overlap,
         dispatch: dispatch,
         occurrence_ttl_ms: ttl
       }}
    end
  end

  defp field(map, key, fun) do
    case Map.fetch(map, key) do
      {:ok, value} -> fun.(value)
      :error -> {:error, :invalid_schedule}
    end
  end

  defp schedule_id_field(id),
    do:
      if(is_binary(id) and id =~ @schedule_id_pattern,
        do: {:ok, id},
        else: {:error, :invalid_schedule}
      )

  defp generation_field(gen),
    do: if(is_integer(gen) and gen >= 0, do: {:ok, gen}, else: {:error, :invalid_schedule})

  defp spec_field(map) do
    case Map.get(map, :spec) do
      {:cron, expression} when is_binary(expression) and byte_size(expression) in 1..256 ->
        case Slots.parse_cron(expression) do
          {:ok, _} -> {:ok, {:cron, expression}}
          {:error, _} -> {:error, :invalid_spec}
        end

      {:cron, _} ->
        {:error, :invalid_spec}

      {:at, instant} when is_integer(instant) and instant >= 0 ->
        {:ok, {:at, instant}}

      _ ->
        {:error, :invalid_spec}
    end
  end

  defp at_ok({:at, instant}, now),
    do: if(instant > now, do: {:ok, instant}, else: {:error, :invalid_spec})

  defp at_ok(_spec, _now), do: {:ok, :ok}

  defp timezone_field(scheduler, map) do
    zone = Map.get(map, :timezone, "Etc/UTC")

    if is_binary(zone) and byte_size(zone) in 1..64 and
         Slots.zone_resolvable?(zone, scheduler.timezone_database),
       do: {:ok, zone},
       else: {:error, :invalid_spec}
  end

  defp overlap_field(scheduler, map) do
    case Map.get(map, :overlap_policy) do
      :skip ->
        {:ok, :skip}

      :replace ->
        {:ok, :replace}

      # An out-of-range queue bound is a spec violation (`:invalid_spec` —
      # the issue's "empty queue bound" case); a malformed policy shape is
      # `:invalid_schedule`.
      {:queue, n} when is_integer(n) ->
        if n >= 1 and n <= scheduler.max_unsettled_per_schedule,
          do: {:ok, {:queue, n}},
          else: {:error, :invalid_spec}

      _ ->
        {:error, :invalid_schedule}
    end
  end

  defp dispatch_field(map) do
    case Map.get(map, :dispatch) do
      {queue, max_attempts, backoff} when is_map(backoff) ->
        cond do
          is_binary(queue) and queue == "" ->
            {:error, :invalid_spec}

          not is_binary(queue) or byte_size(queue) > @max_queue_len ->
            {:error, :invalid_schedule}

          not (is_integer(max_attempts) and max_attempts in 1..@max_attempts) ->
            {:error, :invalid_schedule}

          not valid_backoff?(backoff) ->
            {:error, :invalid_schedule}

          true ->
            {:ok, {queue, max_attempts, backoff}}
        end

      _ ->
        {:error, :invalid_schedule}
    end
  end

  # Backoff fields are overlaid onto the worker args by `Elzoo.Jobs.changeset/4`;
  # the reserved keys `v`, `queue` and `job_key` carry the occurrence identity
  # and schema version, so a schedule may never declare them.
  defp valid_backoff?(backoff) do
    map_size(backoff) <= 32 and byte_size(Jason.encode!(backoff)) <= 1_024 and
      Enum.all?(backoff, fn {key, _value} ->
        to_string(key) not in @reserved_backoff_keys
      end)
  rescue
    _ -> false
  end

  defp ttl_field(scheduler, map) do
    ttl = Map.get(map, :occurrence_ttl_ms, scheduler.occurrence_ttl_ms)

    if is_integer(ttl) and ttl in 1..@max_ttl_ms,
      do: {:ok, ttl},
      else: {:error, :invalid_schedule}
  end
end
