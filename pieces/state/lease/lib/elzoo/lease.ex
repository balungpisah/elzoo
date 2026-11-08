# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Lease do
  @moduledoc """
  Single-owner leases fenced by the record revision (`state/lease`, ELZ-028).

  A key is a Store stream. Its lease is recorded in that same stream as
  self-contained `:non_state_bearing` records (`Elzoo.Lease.Record`), so the
  stream's head revision is the one fence for lease records and guarded state
  records. Every lease operation runs as one atomic step on the Adapter
  (`Elzoo.Lease.Postgres`: one transaction under the head row lock with the
  store clock sampled under that lock; `Elzoo.Lease.Memory`: one serialized
  owner section with the manual clock): read the latest lease record, sample
  the store clock, classify, decide and gate with the pure `Cure.Elzoo.Lease`
  tables, append the lease record(s) at the observed revision.

  Sampled-time rule (issue #45 as amended): liveness is evaluated at the
  store-clock sample taken under the lock within the transaction that records
  the change; a renewal sampled before expiry may commit after expiry and an
  unlocked `status/2` or `hold/3` may report the prior lease stale before that
  commit and the renewed lease active afterwards. Revision fencing rejects a
  superseded fence; it cannot authenticate how a current fence was obtained,
  and owner strings are attribution, not identity.

  Results never raise for domain inputs; see the README result tables.
  """
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.{Codec, Store}
  alias Elzoo.Lease.Record

  @cure :"Cure.Elzoo.Lease"
  @max_limit 1_000
  @max_candidates 1_000

  defstruct [:backend, :module, :store, :fold, :limits]

  @doc "Lease kinds to merge into the consumer's fold (`:non_state_bearing`)."
  def kinds, do: Record.kinds()
  def reasons, do: Record.reasons()

  @doc """
  Build a lease over a Store. Options: `store` (a Store term whose own `fold`
  and `limits` are the source of truth: `fold.kinds` must contain `kinds/0`,
  `1` must be in `fold.versions`, `max_record_bytes >= 1_024`,
  `max_batch_size >= 2`), optional `fold` and `limits` (accepted only when
  equal to the Store's), `clock` (`:store` for the PostgreSQL Store;
  `{:manual, pid}` for the Memory Store), `timeout_ms` (default 30_000),
  `test_hook` (test seams).
  """
  def new(opts) do
    store = Keyword.get(opts, :store)
    clock = Keyword.get(opts, :clock)

    store_opts =
      case store do
        {m, o} when is_atom(m) and (is_map(o) or is_list(o)) -> Map.new(o)
        _ -> %{}
      end

    fold = Map.get(store_opts, :fold)
    limits = Map.get(store_opts, :limits)

    cond do
      not match?({module, _} when is_atom(module), store) ->
        {:error, {:invalid, :store}}

      Keyword.has_key?(opts, :fold) and Keyword.get(opts, :fold) != fold ->
        {:error, {:invalid, :fold}}

      Keyword.has_key?(opts, :limits) and Keyword.get(opts, :limits) != limits ->
        {:error, {:invalid, :limits}}

      not (Codec.fold_valid?(fold) and Map.take(fold.kinds, Record.kind_names()) == kinds() and
               Record.version() in fold.versions) ->
        {:error, {:invalid, :fold}}

      not (is_map(limits) and is_integer(Map.get(limits, :max_record_bytes)) and
             limits.max_record_bytes >= 1_024 and
             is_integer(Map.get(limits, :max_batch_size)) and limits.max_batch_size >= 2) ->
        {:error, {:invalid, :limits}}

      true ->
        backend(store, clock, opts, fold, limits)
    end
  end

  defp backend({Elzoo.DurableLog.Postgres, _} = store, :store, opts, fold, limits) do
    with {:ok, backend} <- Elzoo.Lease.Postgres.new(store, opts),
         do:
           {:ok,
            %__MODULE__{
              backend: backend,
              module: Elzoo.Lease.Postgres,
              store: store,
              fold: fold,
              limits: limits
            }}
  end

  defp backend({Elzoo.DurableLog.Memory, _} = store, {:manual, pid}, opts, fold, limits)
       when is_pid(pid) do
    with {:ok, backend} <- Elzoo.Lease.Memory.new(store, pid, opts),
         do:
           {:ok,
            %__MODULE__{
              backend: backend,
              module: Elzoo.Lease.Memory,
              store: store,
              fold: fold,
              limits: limits
            }}
  end

  defp backend(_, _, _, _, _), do: {:error, {:invalid, :clock}}

  # ── operations ───────────────────────────────────────────────────────

  def claim(lease, key, owner, ttl_ms) do
    with :ok <- validate(key: key, owner: owner, ttl_ms: ttl_ms),
         do: lease.module.single(lease.backend, key, &plan(lease, &1, :OpClaim, owner, ttl_ms, nil))
  end

  def seize(lease, key, owner, ttl_ms, reason) do
    with :ok <- validate(key: key, owner: owner, ttl_ms: ttl_ms, reason: reason),
         do:
           lease.module.single(
             lease.backend,
             key,
             &plan(lease, &1, :OpSeize, owner, ttl_ms, reason)
           )
  end

  def release(lease, key, owner) do
    with :ok <- validate(key: key, owner: owner),
         do: lease.module.single(lease.backend, key, &plan(lease, &1, :OpRelease, owner, nil, nil))
  end

  @doc "Renew several keys, one atomic step each; `{:renewed, %{keys, held, refused, errors}}`."
  def renew(lease, owner, keys, ttl_ms) do
    with :ok <- validate(owner: owner, ttl_ms: ttl_ms, keys: keys) do
      results =
        Map.new(
          keys,
          &{&1,
           lease.module.single(lease.backend, &1, fn ctx ->
             plan(lease, ctx, :OpRenew, owner, ttl_ms, nil)
           end)}
        )

      {:renewed,
       %{
         keys: for({k, {:held, _}} <- results, do: k) |> Enum.sort(),
         held: for({k, {:held, h}} <- results, into: %{}, do: {k, h}),
         refused: for({k, {:lease_refused, r}} <- results, into: %{}, do: {k, r}),
         errors:
           for(
             {k, other} <- results,
             not match?({:held, _}, other),
             not match?({:lease_refused, _}, other),
             into: %{},
             do: {k, other}
           )
       }}
    end
  end

  @doc "Claim stale keys among `candidates` (one transaction on PostgreSQL, one section on Memory)."
  def claim_expired(lease, owner, ttl_ms, limit, candidates) do
    with :ok <- validate(owner: owner, ttl_ms: ttl_ms, limit: limit, candidates: candidates) do
      lease.module.sweep(
        lease.backend,
        candidates,
        limit,
        fn ctx ->
          case plan(lease, ctx, :OpClaimExpired, owner, ttl_ms, nil) do
            {:refuse, {:lease_refused, refusal}} ->
              {:refuse, refusal}

            {:refuse, other} ->
              {:refuse,
               %{reason: :error, holder: nil, status: nil, revision: ctx.revision, detail: other}}

            {:write, rows, request, {:held, held}} ->
              {:write, rows, request, held}

            write ->
              write
          end
        end,
        fn _key -> %{reason: :free, holder: nil, status: :free, revision: 0} end
      )
    end
  end

  @doc "Read-only status: `{:ok, %{status, holder, revision, low_water, now, as_of, reason}}`."
  def status(lease, key) do
    with :ok <- validate(key: key), {:ok, ctx} <- lease.module.read(lease.backend, key) do
      {reading, recorded, reason} =
        Record.reading(ctx.latest, ctx.low_water, lease.fold, lease.limits)

      status = classify(reading, ctx.now)
      reason = if status == :ambiguous and reason == nil, do: :future_stamp, else: reason

      {:ok,
       %{
         status: status,
         holder: holder(reading, recorded),
         revision: ctx.revision,
         as_of: ctx.revision,
         low_water: ctx.low_water,
         now: ctx.now,
         reason: if(status == :ambiguous, do: reason, else: nil)
       }}
    end
  end

  @doc "Read-only check of the caller's own lease; information `as_of` a revision, never authority."
  def hold(lease, key, owner) do
    with :ok <- validate(key: key, owner: owner), {:ok, s} <- status(lease, key) do
      cond do
        s.status == :active and s.holder != nil and s.holder.owner == owner ->
          {:held, held(key, owner, s.revision, s.holder.at, s.holder.until)}

        s.status == :free ->
          {:free, %{revision: s.revision, as_of: s.revision}}

        true ->
          {:lease_refused,
           %{
             reason: s.status,
             holder: s.holder && s.holder.owner,
             status: s.status,
             revision: s.revision
           }}
      end
    end
  end

  @doc "Highest `through` for the ready Store's `retain/5` that keeps the latest lease record visible."
  def retention_bound(lease, key) do
    with :ok <- validate(key: key), {:ok, ctx} <- lease.module.read(lease.backend, key) do
      {:ok,
       %{
         through: if(ctx.latest, do: ctx.latest.sequence - 1, else: ctx.low_water),
         as_of: ctx.revision
       }}
    end
  end

  @doc """
  The holder's fenced non-terminal write through the ready Store's `append`:
  `records` are `{kind, version, payload}`, `items` are `{destination, payload}`.
  """
  def write(lease, held, records, items \\ []) do
    with {:ok, key, owner, revision} <- fence(held),
         {:ok, rows, request} <- Record.records(key, revision, records, lease.fold, lease.limits),
         {:ok, outbox} <- items(key, request, items, lease) do
      case store_write(lease, key, revision, rows, outbox, Map.delete(request, :records)) do
        {:committed, target} ->
          {:held, held(key, owner, target, held.live.at, held.live.until)}

        {:conflict, %{expected: e, observed: o}} ->
          {:fenced, %{expected: e, observed: o}}

        {:rejected, :caller_transaction} ->
          {:error, :caller_transaction}

        {:rejected, reason} ->
          {:rejected, reason}

        {:indeterminate, info} ->
          {:indeterminate, Map.put(info, :records, rows)}
      end
    end
  end

  @doc """
  The terminal write: the consumer's terminal records plus
  `lease_released{reason: terminal}` in one gated atomic step on the Adapter;
  returns `{:completed, %{key, owner, revision}}`, a receipt without a fence.
  """
  def complete(lease, held, records, items \\ []) do
    with {:ok, key, owner, revision} <- fence(held),
         :ok <- if(items == [], do: :ok, else: {:error, {:invalid, :items}}),
         :ok <-
           if(is_list(records) and records != [], do: :ok, else: {:error, {:invalid, :records}}) do
      lease.module.single(lease.backend, key, fn ctx ->
        if ctx.revision != revision do
          {:refuse, {:fenced, %{expected: revision, observed: ctx.revision}}}
        else
          {reading, recorded, _} =
            Record.reading(ctx.latest, ctx.low_water, lease.fold, lease.limits)

          status = classify(reading, ctx.now)
          decision = gated(:OpComplete, status, actor(recorded, owner), ctx.now, reading)

          case decision do
            :Permit ->
              release =
                {"lease_released", Record.version(),
                 Record.release_payload(recorded, owner, ctx.now, :terminal)}

              case Record.records(key, ctx.revision, records ++ [release], lease.fold, lease.limits) do
                {:ok, rows, request} ->
                  {:write, rows, request,
                   {:completed, %{key: key, owner: owner, revision: request.target}}}

                {:error, {:rejected, reason}} ->
                  {:refuse, {:rejected, reason}}
              end

            :RefuseAmbiguous ->
              {:refuse,
               {:lease_refused,
                %{reason: :regression, holder: recorded, status: status, revision: ctx.revision}}}
          end
        end
      end)
    end
  end

  # PostgreSQL: the ready Store's append serializes on the head row itself.
  # Memory: every Store call on a leased stream goes through the single owner.
  defp store_write(%{module: Elzoo.Lease.Memory} = lease, key, revision, rows, outbox, request),
    do: Elzoo.Lease.Memory.store_write(lease.backend, key, revision, rows, outbox, request)

  defp store_write(lease, key, revision, rows, outbox, request),
    do: Store.write(lease.store, :append, [key, revision, rows, outbox], request)

  @doc "Confirm an unknown outcome by nonce through the ready Store's `confirm/5`."
  def confirm(lease, %{stream: key, expected: expected, nonce: nonce, records: rows}) do
    case Log.confirm(lease.store, key, expected, nonce, rows) do
      {:committed, target} -> {:committed, target}
      :superseded -> :superseded
      {:unknown, reason} -> {:unknown, reason}
    end
  end

  def confirm(_, _), do: {:unknown, :malformed}

  # ── the pure plan of one operation (runs inside the Adapter's atomic step) ──

  defp plan(lease, ctx, op, owner, ttl_ms, reason) do
    {reading, recorded, read_reason} =
      Record.reading(ctx.latest, ctx.low_water, lease.fold, lease.limits)

    status = classify(reading, ctx.now)
    decision = gated(op, status, actor(recorded, owner), ctx.now, reading)
    regression? = decision == :RefuseAmbiguous and status != :ambiguous

    refusal = fn r ->
      {:refuse,
       {:lease_refused, %{reason: r, holder: recorded, status: status, revision: ctx.revision}}}
    end

    case decision do
      :Permit -> write_plan(lease, ctx, op, status, recorded, owner, ttl_ms, reason)
      :AlreadyFree -> {:refuse, {:free, %{revision: ctx.revision, as_of: ctx.revision}}}
      :RefuseHeld -> refusal.(:active)
      :RefuseStale -> refusal.(:stale)
      :RefuseNotHolder -> refusal.(:not_holder)
      :RefuseFree -> refusal.(:free)
      :RefuseAmbiguous -> refusal.(if regression?, do: :regression, else: read_reason || :ambiguous)
    end
  end

  defp write_plan(lease, ctx, op, status, recorded, owner, ttl_ms, reason) do
    now = ctx.now
    v = Record.version()

    specs =
      case op do
        :OpClaim when status == :stale ->
          [
            {"lease_released", v, Record.release_payload(recorded, owner, now, :stale)},
            {"lease_claimed", v, Record.holder_payload(owner, now, ttl_ms)}
          ]

        :OpClaim ->
          [{"lease_claimed", v, Record.holder_payload(owner, now, ttl_ms)}]

        :OpClaimExpired ->
          [
            {"lease_released", v, Record.release_payload(recorded, owner, now, :stale)},
            {"lease_claimed", v, Record.holder_payload(owner, now, ttl_ms)}
          ]

        :OpRenew ->
          [{"lease_renewed", v, Record.holder_payload(owner, now, ttl_ms)}]

        :OpRelease ->
          [
            {"lease_released", v,
             Record.release_payload(
               owner,
               owner,
               now,
               if(status == :stale, do: :stale, else: :released)
             )}
          ]

        :OpSeize ->
          [
            {"lease_released", v, Record.release_payload(recorded, owner, now, reason)},
            {"lease_seized", v, Record.holder_payload(owner, now, ttl_ms)}
          ]
      end

    case Record.records(ctx.key, ctx.revision, specs, lease.fold, lease.limits) do
      {:ok, rows, request} ->
        result =
          if op == :OpRelease,
            do: {:free, %{revision: request.target, as_of: request.target}},
            else: {:held, held(ctx.key, owner, request.target, now, Record.until(now, ttl_ms))}

        {:write, rows, request, result}

      {:error, {:rejected, reason}} ->
        {:refuse, {:error, {:rejected, reason}}}
    end
  end

  defp gated(op, status, actor, now, reading) do
    decision = apply(@cure, :decide, [op, status_tag(status), actor])
    order = apply(@cure, :compare, [now, apply(@cure, :stamp_of, [reading])])
    apply(@cure, :gate_for, [op, decision, order])
  end

  defp classify(reading, now) do
    case apply(@cure, :classify, [reading, now]) do
      :LeaseFree -> :free
      :LeaseActive -> :active
      :LeaseStale -> :stale
      :LeaseAmbiguous -> :ambiguous
    end
  end

  defp status_tag(:free), do: :LeaseFree
  defp status_tag(:active), do: :LeaseActive
  defp status_tag(:stale), do: :LeaseStale
  defp status_tag(:ambiguous), do: :LeaseAmbiguous

  defp actor(recorded, owner),
    do: if(recorded != nil and recorded == owner, do: :LeaseHolder, else: :LeaseOther)

  defp holder({:HolderStamp, at, until}, recorded), do: %{owner: recorded, at: at, until: until}
  defp holder(_, _), do: nil

  defp held(key, owner, revision, at, until),
    do: %{owner: owner, live: %{key: key, revision: revision, at: at, until: until}}

  defp fence(%{owner: owner, live: %{key: key, revision: revision}})
       when is_binary(key) and is_binary(owner) and is_integer(revision) and revision >= 0,
       do:
         if(Codec.stream?(key) and Record.owner?(owner),
           do: {:ok, key, owner, revision},
           else: {:error, {:invalid, :held}}
         )

  defp fence(_), do: {:error, {:invalid, :held}}

  defp items(_key, _request, [], _lease), do: {:ok, []}

  defp items(key, request, items, lease) do
    if is_list(items) and
         Enum.all?(items, fn
           {destination, payload} ->
             Codec.destination?(destination) and
               destination in Map.get(lease.fold, :destinations, []) and is_binary(payload)

           _ ->
             false
         end) do
      {:ok,
       items
       |> Enum.with_index(1)
       |> Enum.map(fn {{destination, payload}, position} ->
         item = %{
           stream: key,
           sequence: request.target,
           position: position,
           destination: destination,
           payload: payload,
           nonce: request.nonce,
           state: :pending,
           ack_nonce: nil,
           ack_digest: nil,
           idempotency_key: Codec.item_key(key, request.target, position)
         }

         Map.put(item, :digest, Codec.hash(Codec.item_bytes(item)))
       end)}
    else
      {:error, {:invalid, :items}}
    end
  end

  # ── input validation ─────────────────────────────────────────────────

  defp validate(fields) do
    Enum.find_value(fields, :ok, fn
      {:key, key} ->
        unless(Codec.stream?(key), do: {:error, {:invalid, :key}})

      {:owner, owner} ->
        unless(Record.owner?(owner), do: {:error, {:invalid, :owner}})

      {:ttl_ms, ttl} ->
        unless(Record.ttl?(ttl), do: {:error, {:invalid, :ttl_ms}})

      {:reason, reason} ->
        unless(Record.reason?(reason), do: {:error, {:invalid, :reason}})

      {:limit, limit} ->
        unless(is_integer(limit) and limit in 1..@max_limit, do: {:error, {:invalid, :limit}})

      {:keys, keys} ->
        unless(
          is_list(keys) and keys != [] and length(keys) <= @max_candidates and
            Enum.all?(keys, &Codec.stream?/1) and length(Enum.uniq(keys)) == length(keys),
          do: {:error, {:invalid, :keys}}
        )

      {:candidates, keys} ->
        unless(
          is_list(keys) and length(keys) <= @max_candidates and Enum.all?(keys, &Codec.stream?/1) and
            length(Enum.uniq(keys)) == length(keys),
          do: {:error, {:invalid, :candidates}}
        )
    end)
  end
end
