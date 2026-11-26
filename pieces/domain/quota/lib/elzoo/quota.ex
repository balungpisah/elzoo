# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Quota do
  @moduledoc """
  A durable tenant allowance over a consumer-owned Ecto Repo on PostgreSQL 19 (ELZ-303).

  Counters are keyed by `(tenant, window, unit)`; a window is `{:period, id}` with an opaque
  host period ID. The amount of a unit is derived at each `reserve/3` from the tenant's current
  `domain/entitlement` resolution and is never stored. A Run reservation reserves all its units
  or none and is idempotent by `run_id`; a settlement commits a known actual or holds the
  estimate when the actual is `:unknown`; `reconcile/3` ends a held amount with an attributable
  actual. Unknown usage never counts as zero, and no amount is freed by time.

  Every write runs in its own transaction through `Elzoo.TenantIsolation.transact/3` at READ
  COMMITTED (a consumer Need that the Piece checks and cannot set) and locks counter rows one at
  a time in Erlang term order of the unit. The per-unit counter decisions are the Cure module
  `Cure.Elzoo.Quota`.

  Errors are `{:error, reason}` with a fixed atom that never echoes an ID or amount. The Piece
  emits no telemetry and no log; its queries pass `log: false`.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.AiModel.Usage
  alias Elzoo.TenantIsolation

  @cure :"Cure.Elzoo.Quota"
  @message "invalid quota prefix or options"
  @max Integer.pow(2, 63) - 1
  @max_estimates 16
  # Each entitlement period_kind maps to one window tag.
  @kinds %{utc_month: :period}
  @refusals [
    :invalid,
    :resolution,
    :isolation,
    :conflict,
    :no_allowance,
    :settle_only,
    :expiry,
    :insufficient,
    :unknown_reservation,
    :not_held,
    :expired,
    :already_settled
  ]

  @enforce_keys [:repo, :prefix]
  defstruct @enforce_keys

  @doc """
  A quota value: exactly `repo:` and `prefix:`. Raises `ArgumentError` with one fixed message
  otherwise.
  """
  def new(opts) do
    with true <- Keyword.keyword?(opts),
         [:prefix, :repo] <- Enum.sort(Keyword.keys(opts)),
         repo when is_atom(repo) and repo not in [nil, true, false] <- opts[:repo] do
      prefix!(opts[:prefix])
      %__MODULE__{repo: repo, prefix: opts[:prefix]}
    else
      _ -> raise ArgumentError, @message
    end
  end

  @doc false
  # The quoted schema name, shared with Elzoo.Quota.Migration.install/1.
  def prefix!(prefix) do
    if identifier?(prefix), do: ~s("#{prefix}"), else: raise(ArgumentError, @message)
  end

  defp identifier?(name), do: is_binary(name) and name =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/

  # ── reserve ─────────────────────────────────────────────────────────────

  @doc """
  Reserve `%{run_id, window, estimates, expiry_ms, now_ms, resolution}` in `tenant`, all units
  or none: `{:ok, :applied}` or `{:ok, :duplicate}`.
  """
  def reserve(quota, tenant, request) do
    with {:ok, q} <- quota(quota),
         {:ok, r} <- reserve_shape(tenant, request),
         {:ok, allowances} <- resolution(tenant, request.resolution, r.tag),
         :ok <- outside(q) do
      run(q, tenant, fn ->
        with :ok <- isolation(q),
             :inserted <- insert_reservation(q, tenant, r),
             {:ok, limits} <- limits(r.estimates, allowances),
             :ok <- if(r.expiry_ms <= r.now_ms, do: {:error, :expiry}, else: :ok) do
          admit(q, tenant, r, limits)
        end
      end)
    end
  end

  defp reserve_shape(
         tenant,
         %{run_id: id, window: w, estimates: e, expiry_ms: x, now_ms: n, resolution: _} = r
       )
       when map_size(r) == 6 do
    with true <- text?(tenant, 128) and text?(id, 200) and time?(x) and time?(n),
         {:ok, tag, wid} <- window(w),
         {:ok, estimates} <- estimates(e, [], 0) do
      {:ok,
       %{
         run_id: id,
         tag: tag,
         window_id: wid,
         estimates: estimates,
         expiry_ms: x,
         now_ms: n,
         digest: digest(id, tag, wid, estimates, x)
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  defp reserve_shape(_tenant, _request), do: {:error, :invalid}

  # A proper list of 1..16 %{unit, amount}, strictly ascending by unit in Erlang term order.
  defp estimates([], acc, n) when n >= 1, do: {:ok, Enum.reverse(acc)}

  defp estimates([%{unit: u, amount: a} = e | rest], acc, n)
       when map_size(e) == 2 and is_integer(a) and a in 1..@max//1 and n < @max_estimates do
    if unit?(u) and after?(u, acc), do: estimates(rest, [{u, a} | acc], n + 1), else: :error
  end

  defp estimates(_list, _acc, _n), do: :error

  # Step 5: the reservation row decides the identity. ON CONFLICT without a target makes the
  # primary key (tenant, run_id) the arbiter; a concurrent insert of the same run_id waits for
  # the other transaction and then inserts nothing.
  defp insert_reservation(q, tenant, r) do
    inserted =
      query(
        q,
        "INSERT INTO #{table(q, :reservations)} (tenant, run_id, window_tag, window_id, expiry_ms, request_digest, state) VALUES ($1, $2, $3, $4, $5, $6, 'open') ON CONFLICT DO NOTHING",
        [tenant, r.run_id, Atom.to_string(r.tag), r.window_id, r.expiry_ms, r.digest]
      )

    if inserted.num_rows == 1 do
      :inserted
    else
      case rows(
             q,
             "SELECT request_digest FROM #{table(q, :reservations)} WHERE tenant = $1 AND run_id = $2",
             [tenant, r.run_id]
           ) do
        [[digest]] when digest == r.digest -> {:ok, :duplicate}
        [[_digest]] -> {:error, :conflict}
        [] -> {:error, :unavailable}
      end
    end
  end

  # Step 6: each estimated unit needs an allowance of the window's kind.
  defp limits(estimates, allowances) do
    Enum.reduce_while(estimates, {:ok, []}, fn {unit, _}, {:ok, acc} ->
      case allowances do
        %{^unit => a} -> {:cont, {:ok, [a | acc]}}
        _ -> {:halt, {:error, :no_allowance}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # Steps 8-10: create and lock each counter row in the order of estimates, decide each unit in
  # Cure, then write the unit rows and the counters.
  defp admit(q, tenant, r, limits) do
    locked =
      for {unit, _} <- r.estimates do
        query(
          q,
          "INSERT INTO #{table(q, :counters)} (tenant, window_tag, window_id, unit, committed, held, reserved) VALUES ($1, $2, $3, $4, 0, 0, 0) ON CONFLICT (tenant, window_tag, window_id, unit) DO NOTHING",
          [tenant, Atom.to_string(r.tag), r.window_id, unit_text(unit)]
        )

        lock_counter(q, tenant, r.tag, r.window_id, unit)
      end

    admissions =
      Enum.zip_with([r.estimates, limits, locked], fn [{_unit, estimate}, limit, counters] ->
        apply(@cure, :admit, [counters, limit.amount, limit.settle_only, estimate])
      end)

    case Enum.find(admissions, &(elem(&1, 2) != :QuotaAdmitted)) do
      nil ->
        query(
          q,
          "INSERT INTO #{table(q, :units)} (tenant, run_id, unit, estimate) SELECT $1, $2, x.u, x.e FROM unnest($3::text[], $4::numeric[]) AS x(u, e)",
          [
            tenant,
            r.run_id,
            Enum.map(r.estimates, &unit_text(elem(&1, 0))),
            Enum.map(r.estimates, &elem(&1, 1))
          ]
        )

        units = Enum.map(r.estimates, &elem(&1, 0))
        write_counters(q, tenant, r.tag, r.window_id, units, Enum.map(admissions, &elem(&1, 1)))
        {:ok, :applied}

      {:Admission, _, :QuotaSettleOnly} ->
        {:error, :settle_only}

      {:Admission, _, :QuotaInsufficient} ->
        {:error, :insufficient}
    end
  end

  # ── settle ──────────────────────────────────────────────────────────────

  @doc """
  Settle `%{run_id, actuals}` in `tenant`, `actuals` exactly the reserved units in unit order,
  each `%{unit, actual}` with an integer actual or `:unknown`: `{:ok, :applied}` or
  `{:ok, :duplicate}`.
  """
  def settle(quota, tenant, request) do
    with {:ok, q} <- quota(quota),
         {:ok, run_id, actuals} <- settle_shape(tenant, request),
         :ok <- outside(q) do
      run(q, tenant, fn ->
        with :ok <- isolation(q),
             {:ok, res} <- lock_reservation(q, tenant, run_id),
             units = unit_rows(q, tenant, run_id),
             :ok <- valid(Enum.map(units, & &1.unit) == Enum.map(actuals, &elem(&1, 0))),
             :fresh <- settled_before(res, units, actuals) do
          released = res.state == "released"

          next =
            Enum.zip_with(units, actuals, fn u, {_unit, actual} ->
              counters = lock_counter(q, tenant, res.tag, res.window_id, u.unit)
              outcome = if actual == :unknown, do: :Unknown, else: {:Known, actual}
              apply(@cure, :settle, [counters, u.estimate, outcome, released])
            end)

          write_counters(q, tenant, res.tag, res.window_id, Enum.map(units, & &1.unit), next)

          query(
            q,
            "UPDATE #{table(q, :units)} AS t SET actual = x.a, settled_unknown = x.k FROM unnest($3::text[], $4::numeric[], $5::boolean[]) AS x(u, a, k) WHERE t.tenant = $1 AND t.run_id = $2 AND t.unit = x.u",
            [
              tenant,
              run_id,
              Enum.map(actuals, &unit_text(elem(&1, 0))),
              Enum.map(actuals, fn {_, a} -> if a == :unknown, do: nil, else: a end),
              Enum.map(actuals, &(elem(&1, 1) == :unknown))
            ]
          )

          set_state(q, tenant, run_id, "settled")
        end
      end)
    end
  end

  defp settle_shape(tenant, %{run_id: id, actuals: list} = r) when map_size(r) == 2 do
    with true <- text?(tenant, 128) and text?(id, 200),
         {:ok, actuals} <- actuals(list, [], 0) do
      {:ok, id, actuals}
    else
      _ -> {:error, :invalid}
    end
  end

  defp settle_shape(_tenant, _request), do: {:error, :invalid}

  defp actuals([], acc, n) when n >= 1, do: {:ok, Enum.reverse(acc)}

  defp actuals([%{unit: u, actual: a} = e | rest], acc, n)
       when map_size(e) == 2 and n < @max_estimates and
              (a == :unknown or (is_integer(a) and a in 0..@max//1)) do
    if unit?(u) and after?(u, acc), do: actuals(rest, [{u, a} | acc], n + 1), else: :error
  end

  defp actuals(_list, _acc, _n), do: :error

  # A settled reservation is a duplicate with equal actuals (:unknown for a unit settled
  # :unknown, also after its reconciliation) and a conflict with others.
  defp settled_before(%{state: "settled"}, units, actuals) do
    stored = Enum.map(units, &if(&1.settled_unknown, do: :unknown, else: &1.actual))

    if stored == Enum.map(actuals, &elem(&1, 1)),
      do: {:ok, :duplicate},
      else: {:error, :conflict}
  end

  defp settled_before(_res, _units, _actuals), do: :fresh

  # ── reconcile ───────────────────────────────────────────────────────────

  @doc """
  Reconcile `%{run_id, unit, actual, basis, actor_ref, reason}` in `tenant` for a unit settled
  `:unknown`: the estimate leaves `held` and `actual` is committed. `basis` is `:metering` or
  `:write_off`. `{:ok, :applied}` or `{:ok, :duplicate}`.
  """
  def reconcile(quota, tenant, request) do
    with {:ok, q} <- quota(quota),
         {:ok, rec} <- reconcile_shape(tenant, request),
         :ok <- outside(q) do
      run(q, tenant, fn ->
        with :ok <- isolation(q),
             {:ok, res} <- lock_reservation(q, tenant, rec.run_id),
             {:ok, u} <- held_unit(q, tenant, rec),
             :fresh <- reconciled_before(u, rec) do
          counters = lock_counter(q, tenant, res.tag, res.window_id, rec.unit)
          next = apply(@cure, :reconcile, [counters, u.estimate, rec.actual])
          write_counters(q, tenant, res.tag, res.window_id, [rec.unit], [next])

          query(
            q,
            "UPDATE #{table(q, :units)} SET actual = $4, basis = $5, actor_ref = $6, reason = $7 WHERE tenant = $1 AND run_id = $2 AND unit = $3",
            [
              tenant,
              rec.run_id,
              unit_text(rec.unit),
              rec.actual,
              Atom.to_string(rec.basis),
              rec.actor_ref,
              rec.reason
            ]
          )

          {:ok, :applied}
        end
      end)
    end
  end

  defp reconcile_shape(
         tenant,
         %{run_id: id, unit: unit, actual: a, basis: basis, actor_ref: actor, reason: reason} = r
       )
       when map_size(r) == 6 and is_integer(a) and a in 0..@max//1 and
              basis in [:metering, :write_off] do
    if text?(tenant, 128) and text?(id, 200) and unit?(unit) and text?(actor, 128) and
         text?(reason, 256),
       do:
         {:ok, %{run_id: id, unit: unit, actual: a, basis: basis, actor_ref: actor, reason: reason}},
       else: {:error, :invalid}
  end

  defp reconcile_shape(_tenant, _request), do: {:error, :invalid}

  # A unit that is not reserved, or whose settlement was not :unknown, is not held.
  defp held_unit(q, tenant, rec) do
    case rows(
           q,
           "SELECT estimate::text, settled_unknown, actual::text, basis, actor_ref, reason FROM #{table(q, :units)} WHERE tenant = $1 AND run_id = $2 AND unit = $3",
           [tenant, rec.run_id, unit_text(rec.unit)]
         ) do
      [[estimate, true, actual, basis, actor, reason]] ->
        {:ok,
         %{
           estimate: String.to_integer(estimate),
           actual: actual && String.to_integer(actual),
           basis: basis,
           actor_ref: actor,
           reason: reason
         }}

      _ ->
        {:error, :not_held}
    end
  end

  defp reconciled_before(%{basis: nil}, _rec), do: :fresh

  defp reconciled_before(u, rec) do
    if {u.actual, u.basis, u.actor_ref, u.reason} ==
         {rec.actual, Atom.to_string(rec.basis), rec.actor_ref, rec.reason},
       do: {:ok, :duplicate},
       else: {:error, :conflict}
  end

  # ── release ─────────────────────────────────────────────────────────────

  @doc """
  Release `%{run_id, now_ms}` in `tenant`: free an open reservation before its expiry.
  `{:ok, :applied}` or `{:ok, :duplicate}`.
  """
  def release(quota, tenant, request) do
    with {:ok, q} <- quota(quota),
         {:ok, run_id, now} <- release_shape(tenant, request),
         :ok <- outside(q) do
      run(q, tenant, fn ->
        with :ok <- isolation(q),
             {:ok, res} <- lock_reservation(q, tenant, run_id) do
          cond do
            res.state == "settled" ->
              {:error, :already_settled}

            res.state == "released" ->
              {:ok, :duplicate}

            res.expiry_ms <= now ->
              {:error, :expired}

            true ->
              units = unit_rows(q, tenant, run_id)

              next =
                for u <- units do
                  counters = lock_counter(q, tenant, res.tag, res.window_id, u.unit)
                  apply(@cure, :release, [counters, u.estimate])
                end

              write_counters(q, tenant, res.tag, res.window_id, Enum.map(units, & &1.unit), next)
              set_state(q, tenant, run_id, "released")
          end
        end
      end)
    end
  end

  defp release_shape(tenant, %{run_id: id, now_ms: now} = r) when map_size(r) == 2 do
    if text?(tenant, 128) and text?(id, 200) and time?(now),
      do: {:ok, id, now},
      else: {:error, :invalid}
  end

  defp release_shape(_tenant, _request), do: {:error, :invalid}

  # ── status ──────────────────────────────────────────────────────────────

  @doc """
  `{:ok, rows}` for `%{window, resolution}`: one `%{unit, amount, settle_only, committed, held,
  reserved, remaining}` per unit with an allowance of the window's kind in the resolution or a
  counter row in the window, sorted by unit. `resolution` may be `nil`.
  """
  def status(quota, tenant, request) do
    with {:ok, q} <- quota(quota),
         {:ok, tag, wid, resolution} <- status_shape(tenant, request),
         {:ok, allowances} <- status_resolution(tenant, resolution, tag),
         :ok <- outside(q) do
      run(q, tenant, fn ->
        counters =
          rows(
            q,
            "SELECT unit, committed::text, held::text, reserved::text FROM #{table(q, :counters)} WHERE tenant = $1 AND window_tag = $2 AND window_id = $3",
            [tenant, Atom.to_string(tag), wid]
          )
          |> Map.new(fn [unit, c, h, r] ->
            {unit!(unit), {String.to_integer(c), String.to_integer(h), String.to_integer(r)}}
          end)

        units = Enum.sort(Enum.uniq(Map.keys(allowances) ++ Map.keys(counters)))

        {:ok,
         for unit <- units do
           %{amount: amount, settle_only: settle_only} =
             Map.get(allowances, unit, %{amount: 0, settle_only: false})

           {c, h, r} = Map.get(counters, unit, {0, 0, 0})

           %{
             unit: unit,
             amount: amount,
             settle_only: settle_only,
             committed: c,
             held: h,
             reserved: r,
             remaining: max(amount - c - h - r, 0)
           }
         end}
      end)
    end
  end

  defp status_shape(tenant, %{window: w, resolution: resolution} = r) when map_size(r) == 2 do
    with true <- text?(tenant, 128),
         {:ok, tag, wid} <- window(w) do
      {:ok, tag, wid, resolution}
    else
      _ -> {:error, :invalid}
    end
  end

  defp status_shape(_tenant, _request), do: {:error, :invalid}

  defp status_resolution(_tenant, nil, _tag), do: {:ok, %{}}
  defp status_resolution(tenant, resolution, tag), do: resolution(tenant, resolution, tag)

  # ── resolution ──────────────────────────────────────────────────────────

  # Step 2: the keys of the domain/entitlement resolution that this Piece reads (other keys are
  # ignored), the tenant, every allowance's grant among the listed grants and settle_only
  # exactly for a grace grant. Returns the derived allowance of each mapped unit of the
  # window's kind: %{unit => %{amount, settle_only}}.
  defp resolution(tenant, %{tenant: t, grants: [_ | _] = grants, allowances: allowances}, tag) do
    with true <- text?(t, 128) and t == tenant and proper?(grants) and proper?(allowances),
         {:ok, statuses} <- grants(grants, %{}),
         true <- Enum.all?(allowances, &allowance?(&1, statuses)) do
      {:ok, derive(allowances, tag)}
    else
      _ -> {:error, :resolution}
    end
  end

  defp resolution(_tenant, _resolution, _tag), do: {:error, :resolution}

  defp grants([], acc), do: {:ok, acc}

  defp grants([%{grant_id: id, status: status} | rest], acc) when status in [:entitled, :grace] do
    if text?(id, 128) and not Map.has_key?(acc, id),
      do: grants(rest, Map.put(acc, id, status)),
      else: :error
  end

  defp grants(_list, _acc), do: :error

  defp allowance?(
         %{unit: _, amount: a, period_kind: _, settle_only: settle_only, grant_id: id},
         statuses
       )
       when is_integer(a) and a in 1..@max//1 and is_boolean(settle_only) do
    case statuses do
      %{^id => status} -> settle_only == (status == :grace)
      _ -> false
    end
  end

  defp allowance?(_allowance, _statuses), do: false

  # The amount of a unit is the sum of its allowances of the window's kind that are not
  # settle_only; the unit is settle_only when every such allowance is. An unmapped unit or
  # period_kind is ignored.
  defp derive(allowances, tag) do
    allowances
    |> Enum.filter(&(Map.get(@kinds, &1.period_kind) == tag and unit?(&1.unit)))
    |> Enum.group_by(& &1.unit)
    |> Map.new(fn {unit, list} ->
      {unit,
       %{
         amount: list |> Enum.reject(& &1.settle_only) |> Enum.map(& &1.amount) |> Enum.sum(),
         settle_only: Enum.all?(list, & &1.settle_only)
       }}
    end)
  end

  # ── shared steps ────────────────────────────────────────────────────────

  # Step 4: the level is the consumer's Need; transact/3 cannot set it.
  defp isolation(q) do
    case rows(q, "SELECT current_setting('transaction_isolation')", []) do
      [["read committed"]] -> :ok
      _ -> {:error, :isolation}
    end
  end

  defp lock_reservation(q, tenant, run_id) do
    case rows(
           q,
           "SELECT window_tag, window_id, expiry_ms, state FROM #{table(q, :reservations)} WHERE tenant = $1 AND run_id = $2 FOR UPDATE",
           [tenant, run_id]
         ) do
      [] ->
        {:error, :unknown_reservation}

      [["period", wid, expiry, state]] ->
        {:ok, %{tag: :period, window_id: wid, expiry_ms: expiry, state: state}}
    end
  end

  # The unit rows of one reservation in unit order (the lock order).
  defp unit_rows(q, tenant, run_id) do
    rows(
      q,
      "SELECT unit, estimate::text, settled_unknown, actual::text FROM #{table(q, :units)} WHERE tenant = $1 AND run_id = $2",
      [tenant, run_id]
    )
    |> Enum.map(fn [unit, estimate, unknown, actual] ->
      %{
        unit: unit!(unit),
        estimate: String.to_integer(estimate),
        settled_unknown: unknown,
        actual: actual && String.to_integer(actual)
      }
    end)
    |> Enum.sort_by(& &1.unit)
  end

  # One counter row lock; callers lock one unit at a time in unit order, never another order.
  defp lock_counter(q, tenant, tag, wid, unit) do
    [[c, h, r]] =
      rows(
        q,
        "SELECT committed::text, held::text, reserved::text FROM #{table(q, :counters)} WHERE tenant = $1 AND window_tag = $2 AND window_id = $3 AND unit = $4 FOR UPDATE",
        [tenant, Atom.to_string(tag), wid, unit_text(unit)]
      )

    {:Counters, String.to_integer(c), String.to_integer(h), String.to_integer(r)}
  end

  defp write_counters(q, tenant, tag, wid, units, next) do
    query(
      q,
      "UPDATE #{table(q, :counters)} AS t SET committed = x.c, held = x.h, reserved = x.r FROM unnest($4::text[], $5::numeric[], $6::numeric[], $7::numeric[]) AS x(u, c, h, r) WHERE t.tenant = $1 AND t.window_tag = $2 AND t.window_id = $3 AND t.unit = x.u",
      [
        tenant,
        Atom.to_string(tag),
        wid,
        Enum.map(units, &unit_text/1),
        Enum.map(next, &elem(&1, 1)),
        Enum.map(next, &elem(&1, 2)),
        Enum.map(next, &elem(&1, 3))
      ]
    )
  end

  defp set_state(q, tenant, run_id, state) do
    query(
      q,
      "UPDATE #{table(q, :reservations)} SET state = $3 WHERE tenant = $1 AND run_id = $2",
      [tenant, run_id, state]
    )

    {:ok, :applied}
  end

  # ── request digest ──────────────────────────────────────────────────────

  # SHA-256 of the canonical encoding (README "Request digest"): the tag, then each field as a
  # 32-bit big-endian byte length and bytes of its name and of its value, in a fixed order. A
  # field that a later version adds as optional is appended only when present.
  defp digest(run_id, tag, wid, estimates, expiry_ms) do
    :crypto.hash(:sha256, [
      "elzoo-quota-reservation/1",
      field("run_id", run_id),
      field("window_tag", Atom.to_string(tag)),
      field("window_id", wid),
      field(
        "estimates",
        for {unit, amount} <- estimates do
          field("estimate", [
            field("unit", unit_text(unit)),
            field("amount", Integer.to_string(amount))
          ])
        end
      ),
      field("expiry_ms", Integer.to_string(expiry_ms))
    ])
  end

  defp field(name, value),
    do: [<<byte_size(name)::32>>, name, <<IO.iodata_length(value)::32>>, value]

  # ── units and windows ───────────────────────────────────────────────────

  # The unit set of domain/entitlement and domain/metering and its stored text.
  defp unit_texts do
    Map.merge(
      Map.new(Usage.units(), &{&1, Atom.to_string(&1)}),
      Map.new(Usage.ttls(), &{{:cache_write_tokens, &1}, "cache_write_tokens:" <> &1})
    )
  end

  defp unit?(unit), do: Map.has_key?(unit_texts(), unit)
  defp unit_text(unit), do: Map.fetch!(unit_texts(), unit)

  defp unit!(text) do
    {unit, ^text} = Enum.find(unit_texts(), &(elem(&1, 1) == text))
    unit
  end

  # Strictly after the previous unit in Erlang term order.
  defp after?(_unit, []), do: true
  defp after?(unit, [{previous, _} | _]), do: previous < unit

  # Version 1 has exactly the tag :period.
  defp window({:period, id}), do: if(text?(id, 128), do: {:ok, :period, id}, else: :error)
  defp window(_window), do: :error

  # ── plumbing ────────────────────────────────────────────────────────────

  defp quota(%__MODULE__{repo: repo, prefix: prefix} = q)
       when is_atom(repo) and repo not in [nil, true, false] do
    if identifier?(prefix), do: {:ok, q}, else: {:error, :invalid}
  end

  defp quota(_other), do: {:error, :invalid}

  defp valid(true), do: :ok
  defp valid(false), do: {:error, :invalid}

  # Step 3: the Piece opens its own transaction and never joins a caller's.
  defp outside(q), do: if(q.repo.in_transaction?(), do: {:error, :in_transaction}, else: :ok)

  # One transaction under the tenant scope. A refusal rolls back; a database failure, including
  # a lost connection, is :unavailable and says nothing about whether the write committed.
  defp run(q, tenant, fun) do
    case TenantIsolation.transact(q.repo, %{tenant: tenant}, fun) do
      {:ok, _} = ok -> ok
      {:error, {:tenant_isolation, :in_transaction}} -> {:error, :in_transaction}
      {:error, reason} when reason in @refusals -> {:error, reason}
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp table(q, name), do: ~s("#{q.prefix}".elzoo_quota_#{name})

  defp query(q, sql, params), do: SQL.query!(q.repo, sql, params, log: false)
  defp rows(q, sql, params), do: query(q, sql, params).rows

  defp proper?([]), do: true
  defp proper?([_ | rest]), do: proper?(rest)
  defp proper?(_), do: false

  defp time?(n), do: is_integer(n) and n in 0..@max//1

  # 1..max bytes of valid UTF-8 without a C0 or C1 control character, compared by exact bytes.
  defp text?(t, max),
    do: is_binary(t) and byte_size(t) in 1..max//1 and String.valid?(t) and printable?(t)

  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false
end
