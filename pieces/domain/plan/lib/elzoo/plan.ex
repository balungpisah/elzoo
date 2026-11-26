# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Plan do
  @moduledoc """
  A tenant's subscription to one plan version over a consumer-owned Ecto Repo on PostgreSQL 19
  (ELZ-366).

  Periods are UTC calendar months or years counted from an anchor and clamped to the month's
  last day; the rule over civil dates is the Cure module `Cure.Elzoo.PlanPeriod`, and this
  module converts a Unix millisecond time to and from a UTC civil date and time of day with OTP
  `:calendar`. A boundary keeps the anchor's UTC time of day and is always computed from the
  anchor. `renew/3` advances exactly one period when it is due, with the host's trusted time,
  and returns that period's fee line and its `domain/entitlement` grant; a change takes effect
  at the next renewal; a cancel is at period end or now. The Piece writes no grant, invoice or
  journal row and has no timer.

  Every write checks its request (`:invalid`), then `repo.in_transaction?()`
  (`:in_transaction`) before any query, and runs in its own transaction through
  `Elzoo.TenantIsolation.transact/3` at a checked READ COMMITTED (`:isolation`); `renew/3` and
  every transition take the subscription row with `SELECT ... FOR UPDATE`.

  The fee line of the current period is fixed by the write that made the period (create or a
  renewal): no later write changes the period, the plan or the fee until the next renewal, and
  no renewal advances after a cancel. So the row keeps the last renewal's `from_index`
  (`renewed_from`), and its fee line and grant, as well as a withdrawn fee line of the last
  cancel, are those of the stored current period.

  Errors are `{:error, reason}` with a fixed atom (or `{:state, state}`) that never echoes an
  ID. The Piece emits no telemetry and no log; its queries pass `log: false`.
  """
  alias Ecto.Adapters.SQL
  alias Elzoo.Money.{Amount, Codec}
  alias Elzoo.TenantIsolation

  @cure :"Cure.Elzoo.PlanPeriod"
  @message "invalid plan prefix"
  @table "elzoo_plan_subscriptions"
  @max Integer.pow(2, 63) - 1
  @max_version Integer.pow(2, 31) - 1
  @max_ahead 86_400_000
  @day_ms 86_400_000
  @epoch_days :calendar.date_to_gregorian_days(1970, 1, 1)
  @open [:trialing, :active, :past_due]
  @refusals [
    :invalid,
    :isolation,
    :conflict,
    :subscription_exists,
    :grant_overlap,
    :unknown_subscription,
    :not_due,
    :stale_period,
    :stale_revision
  ]
  @columns ~w(subscription_id interval anchor_ms created_plan_id created_version created_fee
    start_ms trial_end_ms plan_id version fee state period_index period_start_ms period_end_ms
    cancel_at_period_end cancel_ms pending_plan_id pending_version pending_fee renewed_from
    revision last_cancel_grant_ids last_cancel_revoked_at last_cancel_withdrawn)

  @enforce_keys [:repo, :prefix, :renew_ahead_ms]
  defstruct @enforce_keys

  @doc """
  A binding: exactly `repo:` and `prefix:`, and optionally `renew_ahead_ms:` (0..86,400,000,
  default 0). `{:ok, binding}` or `{:error, :invalid}`.
  """
  def new(opts) do
    with true <- Keyword.keyword?(opts),
         keys when keys in [[:prefix, :repo], [:prefix, :renew_ahead_ms, :repo]] <-
           Enum.sort(Keyword.keys(opts)),
         repo when is_atom(repo) and repo not in [nil, true, false] <- opts[:repo],
         true <- identifier?(opts[:prefix]),
         ahead when is_integer(ahead) and ahead in 0..@max_ahead//1 <-
           Keyword.get(opts, :renew_ahead_ms, 0) do
      {:ok, %__MODULE__{repo: repo, prefix: opts[:prefix], renew_ahead_ms: ahead}}
    else
      _ -> {:error, :invalid}
    end
  end

  @doc false
  # The quoted schema name, shared with Elzoo.Plan.Migration.install/1.
  def prefix!(prefix) do
    if identifier?(prefix), do: ~s("#{prefix}"), else: raise(ArgumentError, @message)
  end

  defp identifier?(name), do: is_binary(name) and name =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/

  # ── create ──────────────────────────────────────────────────────────────

  @doc """
  Create `%{subscription_id, plan, fee, interval, start_ms, trial_end_ms}` in `tenant`:
  `{:ok, %{subscription, fee_line, grants, duplicate}}`. Idempotent by `subscription_id`.
  """
  def create(binding, tenant, request) do
    with {:ok, p} <- checked(binding),
         {:ok, c} <- create_shape(tenant, request),
         {:ok, first} <- first_result(tenant, c),
         :ok <- outside(p) do
      run(p, tenant, fn ->
        with :ok <- isolation(p) do
          insert(p, tenant, c, first.subscription)
        end
      end)
    end
  end

  defp create_shape(
         tenant,
         %{subscription_id: id, plan: plan, fee: fee, interval: i, start_ms: s, trial_end_ms: t} =
           r
       )
       when map_size(r) == 6 and i in [:month, :year] do
    with true <- text?(tenant, 128) and text?(id, 100) and time?(s),
         true <- t == nil or (time?(t) and t > s),
         {:ok, plan} <- plan(plan),
         {:ok, fee_bytes} <- fee(fee) do
      {:ok,
       %{id: id, plan: plan, fee: fee, fee_bytes: fee_bytes, interval: i, start_ms: s, trial: t}}
    else
      _ -> {:error, :invalid}
    end
  end

  defp create_shape(_tenant, _request), do: {:error, :invalid}

  # The first result of a create request, also rebuilt from the stored request for a duplicate.
  # With a trial: period 0 from start_ms to the anchor (trial_end_ms), no fee line. Without:
  # period 1 from the anchor (start_ms) to boundary 1, with its fee line.
  defp first_result(tenant, c) do
    anchor = c.trial || c.start_ms

    {state, period} =
      if c.trial,
        do: {:trialing, {:ok, %{index: 0, start_ms: c.start_ms, end_ms: anchor}}},
        else: {:active, period(anchor, c.interval, 1)}

    with {:ok, period} <- period do
      s = %{
        subscription_id: c.id,
        plan: c.plan,
        fee: c.fee,
        interval: c.interval,
        anchor_ms: anchor,
        state: state,
        period: period,
        trial_end_ms: c.trial,
        cancel_at_period_end: false,
        cancel_ms: nil,
        pending_change: nil,
        revision: 1
      }

      {:ok, %{subscription: s, fee_line: fee_line(s), grants: [grant(tenant, s)]}}
    end
  end

  # The subscription row identifies the request: ON CONFLICT without a target makes both the
  # primary key and the one-open-subscription index arbiters, and a concurrent insert of either
  # waits for the other transaction.
  defp insert(p, tenant, c, s) do
    inserted =
      query(
        p,
        "INSERT INTO #{table(p)} (tenant, subscription_id, interval, anchor_ms, created_plan_id, created_version, created_fee, start_ms, trial_end_ms, plan_id, version, fee, state, period_index, period_start_ms, period_end_ms, cancel_at_period_end, revision) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $5, $6, $7, $10, $11, $12, $13, false, 1) ON CONFLICT DO NOTHING",
        [
          tenant,
          c.id,
          Atom.to_string(c.interval),
          s.anchor_ms,
          c.plan.plan_id,
          c.plan.version,
          c.fee_bytes,
          c.start_ms,
          c.trial,
          Atom.to_string(s.state),
          s.period.index,
          s.period.start_ms,
          s.period.end_ms
        ]
      )

    if inserted.num_rows == 1 do
      # We own the open slot. This separate READ COMMITTED statement sees the cancel
      # even if the unique-index check waited for it. A refusal rolls back the insert.
      if overlap?(p, tenant, s.period) do
        {:error, :grant_overlap}
      else
        {:ok,
         %{subscription: s, fee_line: fee_line(s), grants: [grant(tenant, s)], duplicate: false}}
      end
    else
      case select(p, tenant, c.id, "") do
        nil ->
          {:error, :subscription_exists}

        row ->
          stored = row.created

          if {stored.plan, stored.fee_bytes, row.interval, stored.start_ms, stored.trial} ==
               {c.plan, c.fee_bytes, c.interval, c.start_ms, c.trial} do
            {:ok, first} = first_result(tenant, Map.put(stored, :id, row.subscription_id))
            {:ok, Map.put(first, :duplicate, true)}
          else
            {:error, :conflict}
          end
      end
    end
  end

  defp overlap?(p, tenant, period) do
    candidates =
      rows(
        p,
        """
        SELECT start_ms, period_start_ms, period_end_ms, last_cancel_revoked_at,
               period_index, anchor_ms, interval
        FROM #{table(p)} WHERE tenant = $1 AND state = 'canceled'
          AND start_ms < $2 AND period_end_ms > $3
        """,
        [tenant, period.end_ms, period.start_ms]
      )

    Enum.any?(candidates, fn [start | tail] ->
      effective_end(start, tail) > max(start, period.start_ms)
    end)
  end

  # Successive grants touch. A cancel can only trim the tail of that range:
  # no revocations, the current grant alone, or previous + current (in that order).
  # Never trim a grant for which cancel did not actually return a revocation.
  defp effective_end(_start, [_, last, [], _, _, _]), do: last
  defp effective_end(_start, [current, last, [at], _, _, _]), do: max(current, min(last, at))

  defp effective_end(start, [_, _, [at, _], i, anchor, interval]) do
    # The previous grant is the trial for i = 1, otherwise paid period i - 1.
    previous =
      if i == 1, do: start, else: boundary_ms(anchor, String.to_existing_atom(interval), i - 2)

    max(previous, at)
  end

  # ── renew ───────────────────────────────────────────────────────────────

  @doc """
  Renew `%{subscription_id, from_index, now_ms}` in `tenant`:
  `{:ok, %{subscription, fee_line, grants, duplicate, withdrawn_fee_line}}`.
  """
  def renew(binding, tenant, request) do
    with {:ok, p} <- checked(binding),
         {:ok, id, from, now} <- renew_shape(tenant, request),
         :ok <- outside(p) do
      run(p, tenant, fn ->
        with :ok <- isolation(p),
             {:ok, row} <- lock(p, tenant, id) do
          renew_row(p, tenant, row, from, now)
        end
      end)
    end
  end

  defp renew_shape(tenant, %{subscription_id: id, from_index: from, now_ms: now} = r)
       when map_size(r) == 3 do
    if text?(tenant, 128) and text?(id, 100) and time?(from) and time?(now),
      do: {:ok, id, from, now},
      else: {:error, :invalid}
  end

  defp renew_shape(_tenant, _request), do: {:error, :invalid}

  defp renew_row(p, tenant, row, from, now) do
    s = subscription(row)

    cond do
      # A repeat of the renewal that made the current period; nothing is written.
      s.period.index == from + 1 and row.renewed_from == from ->
        {:ok, repeat(tenant, row, s)}

      s.period.index != from ->
        {:error, :stale_period}

      s.state == :canceled ->
        {:error, {:state, :canceled}}

      # A cancel at period end is never taken ahead.
      s.cancel_at_period_end and now < s.cancel_ms ->
        {:error, :not_due}

      s.cancel_at_period_end ->
        s = save(p, tenant, row, %{s | state: :canceled})
        {:ok, renewal(s, nil, [], false, nil)}

      now < s.period.end_ms - p.renew_ahead_ms ->
        {:error, :not_due}

      true ->
        advance(p, tenant, row, s, from)
    end
  end

  defp advance(p, tenant, row, s, from) do
    index = s.period.index + 1

    with {:ok, period} <- period(s.anchor_ms, s.interval, index) do
      change = s.pending_change || %{plan: s.plan, fee: s.fee}
      state = if s.state == :trialing, do: :active, else: s.state

      s =
        save(p, tenant, %{row | renewed_from: from}, %{
          s
          | plan: change.plan,
            fee: change.fee,
            pending_change: nil,
            state: state,
            period: period
        })

      {:ok, renewal(s, fee_line(s), [grant(tenant, s)], false, nil)}
    end
  end

  # After a cancel withdrew the current period, a repeat bills nothing and names the withdrawn
  # line again.
  defp repeat(tenant, row, s) do
    if row.last_cancel != nil and row.last_cancel.withdrawn_fee_line != nil,
      do: renewal(s, nil, [], true, row.last_cancel.withdrawn_fee_line),
      else: renewal(s, fee_line(s), [grant(tenant, s)], true, nil)
  end

  defp renewal(s, line, grants, duplicate, withdrawn),
    do: %{
      subscription: s,
      fee_line: line,
      grants: grants,
      duplicate: duplicate,
      withdrawn_fee_line: withdrawn
    }

  # ── transitions ─────────────────────────────────────────────────────────

  @doc """
  Set `%{subscription_id, expected_revision, plan, fee}` as the pending change, taken at the
  next renewal (no proration): `{:ok, %{subscription}}`.
  """
  def change(binding, tenant, %{plan: plan, fee: fee} = request) when map_size(request) == 4 do
    with {:ok, plan} <- plan(plan),
         {:ok, _bytes} <- fee(fee) do
      transition(binding, tenant, Map.drop(request, [:plan, :fee]), @open, fn _now, row, s ->
        {:ok,
         %{subscription: save(binding, tenant, row, %{s | pending_change: %{plan: plan, fee: fee}})}}
      end)
    else
      _ -> {:error, :invalid}
    end
  end

  def change(_binding, _tenant, _request), do: {:error, :invalid}

  @doc """
  Cancel `%{subscription_id, expected_revision, at: :period_end | :now, now_ms}`:
  `{:ok, %{subscription, revocations, withdrawn_fee_line}}`.
  """
  def cancel(binding, tenant, %{at: at, now_ms: now} = request)
      when map_size(request) == 4 and at in [:period_end, :now] do
    if time?(now) do
      transition(binding, tenant, Map.drop(request, [:at, :now_ms]), @open, fn tenant, row, s ->
        cancel_row(binding, tenant, row, s, at, now)
      end)
    else
      {:error, :invalid}
    end
  end

  def cancel(_binding, _tenant, _request), do: {:error, :invalid}

  # A second period-end cancel keeps cancel_ms, writes nothing and returns what follows from the
  # row: inside the ahead window, the revocation and withdrawn line of the cancel that fixed it.
  defp cancel_row(_p, _tenant, row, %{cancel_at_period_end: true} = s, :period_end, _now) do
    if s.cancel_ms == s.period.start_ms,
      do: {:ok, Map.put(row.last_cancel, :subscription, s)},
      else: {:ok, %{subscription: s, revocations: [], withdrawn_fee_line: nil}}
  end

  # The end of the period running at now_ms: the current period's end, or its start when a
  # renewal ahead made it and it has not started; that period's grant is then revoked at its
  # start and its fee line withdrawn.
  defp cancel_row(p, tenant, row, s, :period_end, now) do
    {cancel_ms, revocations, withdrawn} =
      if now < s.period.start_ms,
        do:
          {s.period.start_ms, [revocation(tenant, s, s.period.index, s.period.start_ms)],
           fee_line(s)},
        else: {s.period.end_ms, [], nil}

    last = %{revocations: revocations, withdrawn_fee_line: withdrawn}

    s =
      save(p, tenant, %{row | last_cancel: last}, %{
        s
        | cancel_at_period_end: true,
          cancel_ms: cancel_ms
      })

    {:ok, Map.put(last, :subscription, s)}
  end

  # One revocation at now_ms for each grant that is not expired at now_ms: the period before
  # the current one while the current one has not started, and the current one. After a
  # period-end cancel, whose only revocation is of the current period's grant, that revocation
  # keeps the earlier of its time and now_ms and its withdrawn fee line stays withdrawn, so a
  # cancel now never serves or bills a withdrawn period.
  defp cancel_row(p, tenant, row, s, :now, now) do
    i = s.period.index
    before? = now < s.period.start_ms and (i >= 2 or (i == 1 and s.trial_end_ms != nil))
    earlier = Map.new((row.last_cancel || %{revocations: []}).revocations, &{&1.grant_id, &1})
    current = grant_id(tenant, s, i)

    revocations =
      if(before?, do: [revocation(tenant, s, i - 1, now)], else: []) ++
        case earlier do
          %{^current => r} -> [%{r | revoked_at_ms: min(r.revoked_at_ms, now)}]
          _ -> if(now < s.period.end_ms, do: [revocation(tenant, s, i, now)], else: [])
        end

    withdrawn =
      (row.last_cancel && row.last_cancel.withdrawn_fee_line) ||
        if(now < s.period.start_ms, do: fee_line(s), else: nil)

    last = %{revocations: revocations, withdrawn_fee_line: withdrawn}
    s = save(p, tenant, %{row | last_cancel: last}, %{s | state: :canceled})
    {:ok, Map.put(last, :subscription, s)}
  end

  defp revocation(tenant, s, index, at),
    do: %{grant_id: grant_id(tenant, s, index), revoked_at_ms: at}

  @doc "`%{subscription_id, expected_revision}`: from `:active` to `:past_due`."
  def mark_past_due(binding, tenant, request),
    do: mark(binding, tenant, request, [:active], :past_due)

  @doc "`%{subscription_id, expected_revision}`: from `:past_due` to `:active`."
  def mark_paid(binding, tenant, request),
    do: mark(binding, tenant, request, [:past_due], :active)

  defp mark(binding, tenant, request, from, to) do
    transition(binding, tenant, request, from, fn _tenant, row, s ->
      {:ok, %{subscription: save(binding, tenant, row, %{s | state: to})}}
    end)
  end

  # A transition takes %{subscription_id, expected_revision} (the rest is checked by its
  # caller), locks the row, checks the revision and then the state.
  defp transition(binding, tenant, %{subscription_id: id, expected_revision: rev} = r, from, fun)
       when map_size(r) == 2 do
    with {:ok, p} <- checked(binding),
         true <- text?(tenant, 128) and text?(id, 100) and is_integer(rev) and rev in 1..@max//1,
         :ok <- outside(p) do
      run(p, tenant, fn ->
        with :ok <- isolation(p),
             {:ok, row} <- lock(p, tenant, id) do
          s = subscription(row)

          cond do
            s.revision != rev -> {:error, :stale_revision}
            s.state not in from -> {:error, {:state, s.state}}
            true -> fun.(tenant, row, s)
          end
        end
      end)
    else
      false -> {:error, :invalid}
      error -> error
    end
  end

  defp transition(_binding, _tenant, _request, _from, _fun), do: {:error, :invalid}

  # ── reads ───────────────────────────────────────────────────────────────

  @doc """
  `%{subscription_id}`: `{:ok, %{subscription, last_cancel}}`, `last_cancel` `nil` or the
  stored `%{revocations, withdrawn_fee_line}` of the cancel that committed.
  """
  def get(binding, tenant, %{subscription_id: id} = r) when map_size(r) == 1 do
    with {:ok, p} <- checked(binding),
         true <- text?(tenant, 128) and text?(id, 100),
         :ok <- outside(p) do
      run(p, tenant, fn ->
        case select(p, tenant, id, "") do
          nil -> {:error, :unknown_subscription}
          row -> {:ok, %{subscription: subscription(row), last_cancel: row.last_cancel}}
        end
      end)
    else
      false -> {:error, :invalid}
      error -> error
    end
  end

  def get(_binding, _tenant, _request), do: {:error, :invalid}

  @doc "Check the table with `Elzoo.TenantIsolation.verify/3`: `:ok` or `{:error, reason}`."
  def verify(binding) do
    with {:ok, p} <- checked(binding),
         do:
           TenantIsolation.verify(p.repo, {p.prefix, @table},
             prefix: p.prefix,
             tenant_column: "tenant",
             space_column: nil
           )
  end

  # ── periods, fee lines and grants ───────────────────────────────────────

  # Period k runs from boundary k - 1 to boundary k, each from the anchor; boundary 0 is the
  # anchor. A period that ends after 2^63 - 1 ms is :invalid.
  defp period(anchor_ms, interval, k) do
    start_ms = boundary_ms(anchor_ms, interval, k - 1)
    end_ms = boundary_ms(anchor_ms, interval, k)

    if end_ms <= @max,
      do: {:ok, %{index: k, start_ms: start_ms, end_ms: end_ms}},
      else: {:error, :invalid}
  end

  # The UTC date of the anchor goes to the Cure rule; the boundary keeps its time of day.
  defp boundary_ms(anchor_ms, interval, k) do
    {y, m, d} = :calendar.gregorian_days_to_date(div(anchor_ms, @day_ms) + @epoch_days)
    cure_interval = if interval == :month, do: :Month, else: :Year
    {:CivilDate, by, bm, bd} = apply(@cure, :boundary, [y, m, d, cure_interval, k])
    (:calendar.date_to_gregorian_days(by, bm, bd) - @epoch_days) * @day_ms + rem(anchor_ms, @day_ms)
  end

  # Period 0 (the trial) has no fee line.
  defp fee_line(%{period: %{index: 0}}), do: nil

  defp fee_line(s),
    do: %{subscription_id: s.subscription_id, period: s.period, plan: s.plan, amount: s.fee}

  defp grant(tenant, s),
    do: %{
      grant_id: grant_id(tenant, s, s.period.index),
      tenant: tenant,
      plan_id: s.plan.plan_id,
      version: s.plan.version,
      valid_from_ms: s.period.start_ms,
      valid_to_ms: s.period.end_ms,
      grace_until_ms: nil,
      revoked_at_ms: nil
    }

  defp grant_id(tenant, %{subscription_id: id}, index) do
    input =
      <<"elzoo-plan-grant/1:", byte_size(tenant)::32, tenant::binary, byte_size(id)::32, id::binary,
        index::64>>

    "plan1." <> Base.encode16(:crypto.hash(:sha256, input), case: :lower)
  end

  # ── rows ────────────────────────────────────────────────────────────────

  defp lock(p, tenant, id) do
    case select(p, tenant, id, " FOR UPDATE") do
      nil -> {:error, :unknown_subscription}
      row -> {:ok, row}
    end
  end

  defp select(p, tenant, id, suffix) do
    case rows(
           p,
           "SELECT #{Enum.join(@columns, ", ")} FROM #{table(p)} WHERE tenant = $1 AND subscription_id = $2" <>
             suffix,
           [tenant, id]
         ) do
      [] -> nil
      [values] -> row(Map.new(Enum.zip(@columns, values)))
    end
  end

  defp row(c) do
    s = %{
      subscription_id: c["subscription_id"],
      plan: %{plan_id: c["plan_id"], version: c["version"]},
      fee: amount!(c["fee"]),
      interval: String.to_existing_atom(c["interval"]),
      anchor_ms: c["anchor_ms"],
      state: String.to_existing_atom(c["state"]),
      period: %{
        index: c["period_index"],
        start_ms: c["period_start_ms"],
        end_ms: c["period_end_ms"]
      },
      trial_end_ms: c["trial_end_ms"],
      cancel_at_period_end: c["cancel_at_period_end"],
      cancel_ms: c["cancel_ms"],
      pending_change:
        c["pending_plan_id"] &&
          %{
            plan: %{plan_id: c["pending_plan_id"], version: c["pending_version"]},
            fee: amount!(c["pending_fee"])
          },
      revision: c["revision"]
    }

    last_cancel =
      if c["last_cancel_withdrawn"] != nil,
        do: %{
          revocations:
            Enum.zip_with(c["last_cancel_grant_ids"], c["last_cancel_revoked_at"], fn id, at ->
              %{grant_id: id, revoked_at_ms: at}
            end),
          withdrawn_fee_line: if(c["last_cancel_withdrawn"], do: fee_line(s), else: nil)
        }

    Map.merge(s, %{
      created: %{
        plan: %{plan_id: c["created_plan_id"], version: c["created_version"]},
        fee: amount!(c["created_fee"]),
        fee_bytes: c["created_fee"],
        interval: s.interval,
        start_ms: c["start_ms"],
        trial: c["trial_end_ms"]
      },
      renewed_from: c["renewed_from"],
      last_cancel: last_cancel
    })
  end

  defp subscription(row),
    do:
      Map.take(row, [
        :subscription_id,
        :plan,
        :fee,
        :interval,
        :anchor_ms,
        :state,
        :period,
        :trial_end_ms,
        :cancel_at_period_end,
        :cancel_ms,
        :pending_change,
        :revision
      ])

  # The one write of renew/3 and every transition: the mutable columns of the locked row, with
  # the next revision. Returns the stored subscription.
  defp save(p, tenant, row, s) do
    s = %{s | revision: s.revision + 1}
    pending = s.pending_change
    last = row.last_cancel

    query(
      p,
      "UPDATE #{table(p)} SET plan_id = $3, version = $4, fee = $5, state = $6, period_index = $7, period_start_ms = $8, period_end_ms = $9, cancel_at_period_end = $10, cancel_ms = $11, pending_plan_id = $12, pending_version = $13, pending_fee = $14, renewed_from = $15, revision = $16, last_cancel_grant_ids = $17, last_cancel_revoked_at = $18, last_cancel_withdrawn = $19 WHERE tenant = $1 AND subscription_id = $2",
      [
        tenant,
        s.subscription_id,
        s.plan.plan_id,
        s.plan.version,
        bytes!(s.fee),
        Atom.to_string(s.state),
        s.period.index,
        s.period.start_ms,
        s.period.end_ms,
        s.cancel_at_period_end,
        s.cancel_ms,
        pending && pending.plan.plan_id,
        pending && pending.plan.version,
        pending && bytes!(pending.fee),
        row.renewed_from,
        s.revision,
        last && Enum.map(last.revocations, & &1.grant_id),
        last && Enum.map(last.revocations, & &1.revoked_at_ms),
        last && last.withdrawn_fee_line != nil
      ]
    )

    s
  end

  # ── request values ──────────────────────────────────────────────────────

  defp plan(%{plan_id: id, version: v} = plan)
       when map_size(plan) == 2 and is_integer(v) and v in 1..@max_version//1 do
    if text?(id, 128), do: {:ok, %{plan_id: id, version: v}}, else: :error
  end

  defp plan(_plan), do: :error

  # A non-negative domain/money amount, stored as its canonical bytes.
  defp fee(%Amount{minor_units: m} = fee) when is_integer(m) and m >= 0 do
    case Codec.encode(fee) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> :error
    end
  end

  defp fee(_fee), do: :error

  defp bytes!(amount) do
    {:ok, bytes} = Codec.encode(amount)
    bytes
  end

  defp amount!(bytes) do
    {:ok, amount} = Codec.decode(bytes)
    amount
  end

  # ── plumbing ────────────────────────────────────────────────────────────

  defp checked(%__MODULE__{repo: repo, prefix: prefix, renew_ahead_ms: ahead} = p)
       when is_atom(repo) and repo not in [nil, true, false] and is_integer(ahead) and
              ahead in 0..@max_ahead//1 do
    if identifier?(prefix), do: {:ok, p}, else: {:error, :invalid}
  end

  defp checked(_other), do: {:error, :invalid}

  # The level is the consumer's Need; transact/3 cannot set it.
  defp isolation(p) do
    case rows(p, "SELECT current_setting('transaction_isolation')", []) do
      [["read committed"]] -> :ok
      _ -> {:error, :isolation}
    end
  end

  # The Piece opens its own transaction and never joins a caller's.
  defp outside(p), do: if(p.repo.in_transaction?(), do: {:error, :in_transaction}, else: :ok)

  # One transaction under the tenant scope. A refusal rolls back; a database failure, including
  # a lost connection, is :unavailable and says nothing about whether the write committed.
  defp run(p, tenant, fun) do
    case TenantIsolation.transact(p.repo, %{tenant: tenant}, fun) do
      {:ok, _} = ok ->
        ok

      {:error, {:tenant_isolation, :in_transaction}} ->
        {:error, :in_transaction}

      {:error, {:state, state}} when state in [:trialing, :active, :past_due, :canceled] ->
        {:error, {:state, state}}

      {:error, reason} when reason in @refusals ->
        {:error, reason}

      {:error, _} ->
        {:error, :unavailable}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp table(p), do: ~s("#{p.prefix}".#{@table})

  defp query(p, sql, params), do: SQL.query!(p.repo, sql, params, log: false)
  defp rows(p, sql, params), do: query(p, sql, params).rows

  defp time?(n), do: is_integer(n) and n in 0..@max//1

  # 1..max bytes of valid UTF-8 without a C0 or C1 control character, compared by exact bytes
  # (the domain/entitlement text rule).
  defp text?(t, max),
    do: is_binary(t) and byte_size(t) in 1..max//1 and String.valid?(t) and printable?(t)

  defp printable?(<<>>), do: true

  defp printable?(<<c::utf8, rest::binary>>) when c > 0x1F and (c < 0x7F or c > 0x9F),
    do: printable?(rest)

  defp printable?(_), do: false
end
