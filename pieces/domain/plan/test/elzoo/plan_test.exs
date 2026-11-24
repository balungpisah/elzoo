# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/plan_test_helper.exs", __DIR__)

defmodule Elzoo.PlanTest do
  # The cases share one database server and hold row locks across connections: not async.
  use ExUnit.Case, async: false
  alias Elzoo.Entitlement
  alias Elzoo.Money
  alias Elzoo.Plan
  alias Elzoo.PlanTest.{AppRepo, Harness, OwnerRepo, RepeatableRepo}
  alias Elzoo.TenantIsolation, as: TI

  @moduletag :capture_log
  @cure :"Cure.Elzoo.PlanPeriod"
  @hour 3_600_000
  @pro %{plan_id: "pro", version: 1}
  @team %{plan_id: "team", version: 2}
  @laws [
    :february_2024_has_29_days,
    :february_2100_has_28_days,
    :february_2000_has_29_days,
    :february_2027_has_28_days,
    :january_31_month_1_is_february_28,
    :january_31_month_2_is_march_31,
    :january_31_month_13_is_february_29,
    :february_29_year_1_is_february_28,
    :february_29_year_4_is_february_29,
    :march_15_k_0_is_the_anchor
  ]

  setup_all do
    if Enum.any?([OwnerRepo, AppRepo, RepeatableRepo], &Process.whereis/1),
      do: raise("the plan test Repos are already running")

    role = Harness.start_repos!()
    on_exit(fn -> Enum.each([OwnerRepo, AppRepo, RepeatableRepo], &Harness.stop!/1) end)
    {:ok, role: role}
  end

  setup %{role: role} do
    p = Harness.install!(role)
    on_exit(fn -> Harness.drop!(p) end)
    {:ok, b} = Plan.new(repo: AppRepo, prefix: p)
    {:ok, ahead} = Plan.new(repo: AppRepo, prefix: p, renew_ahead_ms: @hour)
    {:ok, p: p, b: b, ahead: ahead}
  end

  # ------------------------------------------------------------ fixtures

  defp ms(iso) do
    {:ok, dt, 0} = DateTime.from_iso8601(iso)
    DateTime.to_unix(dt, :millisecond)
  end

  defp usd(minor) do
    {:ok, currency} = Money.parse("USD")
    {:ok, amount} = Money.from_minor_units(currency, minor)
    amount
  end

  @jan31 "2027-01-31T10:00:00.123Z"

  defp request(id, opts) do
    %{
      subscription_id: id,
      plan: Keyword.get(opts, :plan, @pro),
      fee: Keyword.get(opts, :fee, usd(1_000)),
      interval: Keyword.get(opts, :interval, :month),
      start_ms: Keyword.get(opts, :start_ms, ms(@jan31)),
      trial_end_ms: Keyword.get(opts, :trial_end_ms)
    }
  end

  defp create(b, id, opts \\ []),
    do: Plan.create(b, Keyword.get(opts, :tenant, "T1"), request(id, opts))

  defp create!(b, id, opts \\ []) do
    {:ok, %{duplicate: false} = r} = create(b, id, opts)
    r
  end

  defp renew(b, id, from, now, tenant \\ "T1"),
    do: Plan.renew(b, tenant, %{subscription_id: id, from_index: from, now_ms: now})

  defp renew!(b, id, from, now, tenant \\ "T1") do
    {:ok, %{duplicate: false} = r} = renew(b, id, from, now, tenant)
    r
  end

  defp change(b, id, rev, plan, fee, tenant \\ "T1"),
    do: Plan.change(b, tenant, %{subscription_id: id, expected_revision: rev, plan: plan, fee: fee})

  defp cancel(b, id, rev, at, now, tenant \\ "T1"),
    do: Plan.cancel(b, tenant, %{subscription_id: id, expected_revision: rev, at: at, now_ms: now})

  defp past_due(b, id, rev, tenant \\ "T1"),
    do: Plan.mark_past_due(b, tenant, %{subscription_id: id, expected_revision: rev})

  defp paid(b, id, rev, tenant \\ "T1"),
    do: Plan.mark_paid(b, tenant, %{subscription_id: id, expected_revision: rev})

  defp get!(b, id) do
    {:ok, r} = Plan.get(b, "T1", %{subscription_id: id})
    r
  end

  # A refusal with this reason that writes nothing.
  defp refused(p, reason, fun) do
    before = Harness.truth(p)
    assert fun.() == {:error, reason}
    assert Harness.truth(p) == before
  end

  # A success that writes nothing.
  defp unchanged(p, fun) do
    before = Harness.truth(p)
    result = fun.()
    assert Harness.truth(p) == before
    result
  end

  defp line(id, period, plan, amount),
    do: %{subscription_id: id, period: period, plan: plan, amount: amount}

  defp grant(id, tenant, period, plan),
    do: %{
      grant_id: "#{id}/#{period.index}",
      tenant: tenant,
      plan_id: plan.plan_id,
      version: plan.version,
      valid_from_ms: period.start_ms,
      valid_to_ms: period.end_ms,
      grace_until_ms: nil,
      revoked_at_ms: nil
    }

  # The host's plan facts for domain/entitlement.
  defp plans do
    for plan <- [@pro, @team] do
      body = Map.merge(plan, %{features: ["chat"], allowances: []})
      {:ok, hash} = Entitlement.content_hash(body)
      Map.put(body, :content_hash, hash)
    end
  end

  # The host's stored grants with its revocations applied.
  defp resolve(grants, revocations, tenant, at) do
    revoked = Map.new(revocations, &{&1.grant_id, &1.revoked_at_ms})
    grants = Enum.map(grants, &%{&1 | revoked_at_ms: Map.get(revoked, &1.grant_id)})
    Entitlement.resolve(%{plans: plans(), grants: grants}, tenant, at)
  end

  defp entitled_grant(grants, revocations, tenant, at) do
    {:entitled, %{grants: [%{grant_id: id}]}} = resolve(grants, revocations, tenant, at)
    id
  end

  # A renewal ahead, then a period-end cancel inside the ahead window.
  defp ahead_window!(ahead) do
    c = create!(ahead, "s1")
    end1 = c.subscription.period.end_ms
    r1 = renew!(ahead, "s1", 1, end1 - @hour)
    {:ok, x} = cancel(ahead, "s1", 2, :period_end, end1 - 1_000)
    {c, r1, x}
  end

  # ------------------------------------------------------------ 1

  test "1 the period rule: the selected Cure laws compile and audit clean" do
    source = File.read!(Path.expand("../../cure/elzoo/plan_period.cure", __DIR__))
    roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
    assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
    assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(audit, key) == [])

    for law <- @laws do
      assert source =~ "fn #{law}()"
      assert function_exported?(@cure, law, 0)
    end
  end

  test "1 the period rule equals an independent oracle for every anchor day" do
    # days_in_month against Calendar.ISO for every month of four centuries.
    wrong_days =
      for y <- 1900..2400,
          m <- 1..12,
          apply(@cure, :days_in_month, [y, m]) != Date.days_in_month(Date.new!(y, m, 1)),
          do: {y, m}

    assert wrong_days == []

    # The independent oracle: the month index shifted by integer arithmetic, the day clamped by
    # Calendar.ISO.
    oracle = fn y, m, d, months ->
      index = y * 12 + m - 1 + months
      {oy, om} = {div(index, 12), rem(index, 12) + 1}
      {:CivilDate, oy, om, min(d, Date.days_in_month(Date.new!(oy, om, 1)))}
    end

    cases =
      for y <- [2024, 2027, 1999, 2096],
          m <- 1..12,
          d <- 1..31,
          {interval, ks, per} <- [{:Month, 0..24, 1}, {:Year, 0..8, 12}],
          k <- ks,
          do: {y, m, d, interval, k, per}

    wrong =
      for {y, m, d, interval, k, per} <- cases,
          apply(@cure, :boundary, [y, m, d, interval, k]) != oracle.(y, m, d, k * per),
          do: {y, m, d, interval, k}

    assert length(cases) == 4 * 12 * 31 * (25 + 9)
    assert wrong == []
  end

  # ------------------------------------------------------------ 2

  test "2 renewal is not due before end_ms and advances one period at it", %{
    p: p,
    b: b,
    ahead: ahead
  } do
    feb28 = ms("2027-02-28T10:00:00.123Z")
    mar31 = ms("2027-03-31T10:00:00.123Z")
    apr30 = ms("2027-04-30T10:00:00.123Z")

    c = create!(b, "s1")
    p1 = %{index: 1, start_ms: ms(@jan31), end_ms: feb28}
    assert c.subscription.period == p1
    assert c.subscription.state == :active
    assert c.subscription.anchor_ms == ms(@jan31)
    assert c.fee_line == line("s1", p1, @pro, usd(1_000))
    assert c.grants == [grant("s1", "T1", p1, @pro)]

    refused(p, :not_due, fn -> renew(b, "s1", 1, feb28 - 1) end)
    r = renew!(b, "s1", 1, feb28)
    p2 = %{index: 2, start_ms: feb28, end_ms: mar31}
    assert r.subscription.period == p2
    assert r.subscription.revision == 2
    assert r.fee_line == line("s1", p2, @pro, usd(1_000))
    assert r.grants == [grant("s1", "T1", p2, @pro)]
    assert r.withdrawn_fee_line == nil

    # A renewal far past its due time still advances exactly one period.
    r = renew!(b, "s1", 2, apr30 + 10 * @hour)
    assert r.subscription.period == %{index: 3, start_ms: mar31, end_ms: apr30}

    # With renew_ahead_ms one hour, due at end_ms - 3,600,000 (another tenant).
    c = create!(ahead, "a1", tenant: "T2")
    assert c.subscription.period.end_ms == feb28

    refused(p, :not_due, fn -> renew(ahead, "a1", 1, feb28 - @hour - 1, "T2") end)

    {:ok, r} = renew(ahead, "a1", 1, feb28 - @hour, "T2")
    assert r.subscription.period == p2
    assert r.fee_line == line("a1", p2, @pro, usd(1_000))
    # The next period's start is still in the future.
    assert r.subscription.period.start_ms > feb28 - @hour

    # A 29 February 2024 yearly anchor.
    c = create!(b, "y1", tenant: "T3", interval: :year, start_ms: ms("2024-02-29T00:00:00Z"))
    assert c.subscription.period.end_ms == ms("2025-02-28T00:00:00Z")

    ends =
      for k <- 1..3 do
        {:ok, r} = renew(b, "y1", k, ms("2030-01-01T00:00:00Z"), "T3")
        r.subscription.period.end_ms
      end

    assert ends == Enum.map(~w(2026-02-28 2027-02-28 2028-02-29), &ms("#{&1}T00:00:00Z"))
  end

  # ------------------------------------------------------------ 3

  test "3 a repeated renewal returns equal values and writes nothing; two behind is stale", %{
    p: p,
    b: b
  } do
    c = create!(b, "s1")
    first = renew!(b, "s1", 1, c.subscription.period.end_ms)

    for now <- [0, c.subscription.period.end_ms, c.subscription.period.end_ms + 40 * 24 * @hour] do
      assert unchanged(p, fn -> renew(b, "s1", 1, now) end) == {:ok, %{first | duplicate: true}}
    end

    second = renew!(b, "s1", 2, first.subscription.period.end_ms)
    assert unchanged(p, fn -> renew(b, "s1", 2, 0) end) == {:ok, %{second | duplicate: true}}
    assert [%{"revision" => 3}] = Harness.truth(p)

    refused(p, :stale_period, fn -> renew(b, "s1", 1, second.subscription.period.end_ms) end)
    refused(p, :stale_period, fn -> renew(b, "s1", 4, second.subscription.period.end_ms) end)
    # The period create made is not a renewal's: a renewal from 0 is stale.
    create!(b, "s2", tenant: "T2")
    refused(p, :stale_period, fn -> renew(b, "s2", 0, ms(@jan31), "T2") end)
  end

  # ------------------------------------------------------------ 4

  test "4 a trial: period 0 with a grant and no fee line, then active in period 1", %{
    p: p,
    b: b
  } do
    start = ms("2027-01-10T08:30:00Z")
    trial_end = ms("2027-01-24T08:30:00Z")
    c = create!(b, "t1", start_ms: start, trial_end_ms: trial_end)
    p0 = %{index: 0, start_ms: start, end_ms: trial_end}
    assert c.subscription.state == :trialing
    assert c.subscription.anchor_ms == trial_end
    assert c.subscription.trial_end_ms == trial_end
    assert c.subscription.period == p0
    assert c.fee_line == nil
    assert c.grants == [grant("t1", "T1", p0, @pro)]

    refused(p, :not_due, fn -> renew(b, "t1", 0, trial_end - 1) end)
    r = renew!(b, "t1", 0, trial_end)
    p1 = %{index: 1, start_ms: trial_end, end_ms: ms("2027-02-24T08:30:00Z")}
    assert r.subscription.state == :active
    assert r.subscription.period == p1
    assert r.fee_line == line("t1", p1, @pro, usd(1_000))
    assert r.grants == [grant("t1", "T1", p1, @pro)]
  end

  # ------------------------------------------------------------ 5

  describe "5 change and cancel" do
    test "a change takes effect at the next renewal, not before", %{p: p, b: b} do
      c = create!(b, "s1")
      end1 = c.subscription.period.end_ms
      {:ok, %{subscription: s}} = change(b, "s1", 1, @team, usd(2_500))
      assert s.pending_change == %{plan: @team, fee: usd(2_500)}
      assert {s.plan, s.fee, s.revision} == {@pro, usd(1_000), 2}
      refused(p, :not_due, fn -> renew(b, "s1", 1, end1 - 1) end)
      assert get!(b, "s1").subscription == s

      r = renew!(b, "s1", 1, end1)
      assert r.subscription.pending_change == nil
      assert {r.subscription.plan, r.subscription.fee} == {@team, usd(2_500)}
      assert r.fee_line == line("s1", r.subscription.period, @team, usd(2_500))
      assert r.grants == [grant("s1", "T1", r.subscription.period, @team)]
    end

    test "a cancel at period end ends it at the next renewal, never ahead", %{
      p: p,
      b: b,
      ahead: ahead
    } do
      for {binding, tenant} <- [{b, "T1"}, {ahead, "T2"}] do
        c = create!(binding, "s1", tenant: tenant)
        end1 = c.subscription.period.end_ms
        {:ok, r} = cancel(binding, "s1", 1, :period_end, end1 - 5 * @hour, tenant)
        assert %{revocations: [], withdrawn_fee_line: nil} = r
        assert {r.subscription.cancel_at_period_end, r.subscription.cancel_ms} == {true, end1}

        # The reply is dropped: get/3 reads it back, before and after the ending renewal.
        last = Map.take(r, [:revocations, :withdrawn_fee_line])
        {:ok, %{last_cancel: ^last}} = Plan.get(binding, tenant, %{subscription_id: "s1"})

        refused(p, :stale_revision, fn ->
          cancel(binding, "s1", 1, :period_end, end1 - 1, tenant)
        end)

        # A second period-end cancel keeps cancel_ms and writes nothing.
        assert unchanged(p, fn -> cancel(binding, "s1", 2, :period_end, end1 - 2, tenant) end) ==
                 {:ok, r}

        refused(p, :not_due, fn -> renew(binding, "s1", 1, end1 - @hour, tenant) end)
        refused(p, :not_due, fn -> renew(binding, "s1", 1, end1 - 1, tenant) end)
        {:ok, e} = renew(binding, "s1", 1, end1, tenant)
        assert e.subscription.state == :canceled
        assert e.subscription.period == c.subscription.period
        assert %{fee_line: nil, grants: [], duplicate: false, withdrawn_fee_line: nil} = e
        {:ok, %{last_cancel: ^last}} = Plan.get(binding, tenant, %{subscription_id: "s1"})
      end
    end

    test "a cancel at period end inside the ahead window ends it at the next period's start", %{
      p: p,
      ahead: ahead
    } do
      {c, r1, x} = ahead_window!(ahead)
      p2 = r1.subscription.period
      grants = c.grants ++ r1.grants
      assert x.revocations == [%{grant_id: "s1/2", revoked_at_ms: p2.start_ms}]
      assert x.withdrawn_fee_line == r1.fee_line

      refused(p, :not_due, fn -> renew(ahead, "s1", 2, p2.start_ms - 1) end)
      assert entitled_grant(grants, x.revocations, "T1", p2.start_ms - 1) == "s1/1"

      # Canceled at the boundary: cancel_ms is the next period's start.
      assert {:ok, e} = renew(ahead, "s1", 2, p2.start_ms)
      assert {e.subscription.state, e.subscription.cancel_ms} == {:canceled, p2.start_ms}
      assert %{fee_line: nil, grants: [], duplicate: false, withdrawn_fee_line: nil} = e
      assert resolve(grants, x.revocations, "T1", p2.start_ms) == {:not_entitled, :revoked}
      assert resolve(grants, x.revocations, "T1", p2.start_ms + 1) == {:not_entitled, :revoked}
    end

    test "inside the ahead window: repeats, second cancels and the dropped reply", %{
      p: p,
      ahead: ahead
    } do
      {c, r1, x} = ahead_window!(ahead)
      end1 = c.subscription.period.end_ms
      p2 = r1.subscription.period
      last = Map.take(x, [:revocations, :withdrawn_fee_line])
      assert get!(ahead, "s1").last_cancel == last
      refused(p, :stale_revision, fn -> cancel(ahead, "s1", 2, :period_end, end1 - 1_000) end)

      # A repeat of the ahead renewal bills nothing and names the withdrawn line.
      withdrawn = %{
        r1
        | fee_line: nil,
          grants: [],
          duplicate: true,
          withdrawn_fee_line: r1.fee_line
      }

      assert unchanged(p, fn -> renew(ahead, "s1", 1, end1) end) ==
               {:ok, %{withdrawn | subscription: x.subscription}}

      # A second period-end cancel inside the window keeps cancel_ms, same revocation and line.
      assert unchanged(p, fn -> cancel(ahead, "s1", 3, :period_end, end1 - 500) end) == {:ok, x}

      # After the boundary, a second period-end cancel still keeps cancel_ms.
      assert unchanged(p, fn -> cancel(ahead, "s1", 3, :period_end, p2.start_ms + 1) end) ==
               {:ok, x}

      {:ok, e} = renew(ahead, "s1", 2, p2.start_ms + 1)
      assert e.subscription.state == :canceled
      assert get!(ahead, "s1").last_cancel == last

      assert unchanged(p, fn -> renew(ahead, "s1", 1, end1) end) ==
               {:ok, %{withdrawn | subscription: e.subscription}}
    end

    test "a cancel now revokes the running grant; inside the ahead window both", %{
      p: p,
      b: b,
      ahead: ahead
    } do
      c = create!(b, "s1")
      now = c.subscription.period.start_ms + 3 * @hour
      {:ok, x} = cancel(b, "s1", 1, :now, now)
      assert x.subscription.state == :canceled
      assert x.revocations == [%{grant_id: "s1/1", revoked_at_ms: now}]
      assert x.withdrawn_fee_line == nil
      assert resolve(c.grants, x.revocations, "T1", now) == {:not_entitled, :revoked}
      assert get!(b, "s1").last_cancel == Map.take(x, [:revocations, :withdrawn_fee_line])
      refused(p, :stale_revision, fn -> cancel(b, "s1", 1, :now, now) end)
      refused(p, {:state, :canceled}, fn -> cancel(b, "s1", 2, :now, now) end)

      # Inside the ahead window (another tenant).
      c = create!(ahead, "s2", tenant: "T2")
      end1 = c.subscription.period.end_ms
      r1 = renew!(ahead, "s2", 1, end1 - @hour, "T2")
      now = end1 - 1_000
      {:ok, x} = cancel(ahead, "s2", 2, :now, now, "T2")

      assert x.revocations == [
               %{grant_id: "s2/1", revoked_at_ms: now},
               %{grant_id: "s2/2", revoked_at_ms: now}
             ]

      assert x.withdrawn_fee_line == r1.fee_line
      grants = c.grants ++ r1.grants
      assert resolve(grants, x.revocations, "T2", now) == {:not_entitled, :revoked}
      assert resolve(grants, x.revocations, "T2", end1 + 1) == {:not_entitled, :revoked}

      {:ok, %{last_cancel: last}} = Plan.get(ahead, "T2", %{subscription_id: "s2"})
      assert last == Map.take(x, [:revocations, :withdrawn_fee_line])
      refused(p, :stale_revision, fn -> cancel(ahead, "s2", 2, :now, now, "T2") end)

      assert unchanged(p, fn -> renew(ahead, "s2", 1, end1, "T2") end) ==
               {:ok,
                %{
                  r1
                  | subscription: x.subscription,
                    fee_line: nil,
                    grants: [],
                    duplicate: true,
                    withdrawn_fee_line: r1.fee_line
                }}
    end

    test "a canceled subscription refuses every transition; the tenant may create another", %{
      p: p,
      b: b
    } do
      c = create!(b, "s1")
      {:ok, %{subscription: %{revision: 2}}} = cancel(b, "s1", 1, :now, ms(@jan31) + 1)
      refused(p, {:state, :canceled}, fn -> change(b, "s1", 2, @team, usd(1)) end)
      refused(p, {:state, :canceled}, fn -> cancel(b, "s1", 2, :now, ms(@jan31) + 2) end)
      refused(p, {:state, :canceled}, fn -> cancel(b, "s1", 2, :period_end, ms(@jan31)) end)
      refused(p, {:state, :canceled}, fn -> past_due(b, "s1", 2) end)
      refused(p, {:state, :canceled}, fn -> paid(b, "s1", 2) end)
      refused(p, {:state, :canceled}, fn -> renew(b, "s1", 1, c.subscription.period.end_ms) end)

      assert create!(b, "s2", plan: @team).subscription.state == :active
      refused(p, :subscription_exists, fn -> create(b, "s3") end)
    end
  end

  # ------------------------------------------------------------ 6

  test "6 three consecutive periods resolve to their own grant, also renewed ahead", %{
    b: b,
    ahead: ahead
  } do
    for {binding, tenant, lead} <- [{b, "T1", 0}, {ahead, "T2", @hour}] do
      c = create!(binding, "s1", tenant: tenant)

      {periods, grants} =
        Enum.reduce(1..2, {[c.subscription.period], c.grants}, fn k, {periods, grants} ->
          due = hd(periods).end_ms - lead
          {:ok, r} = renew(binding, "s1", k, due, tenant)
          # Renewed ahead: the previous period is still the one in force until its end.
          if lead > 0, do: assert(entitled_grant(grants ++ r.grants, [], tenant, due) == "s1/#{k}")
          {[r.subscription.period | periods], grants ++ r.grants}
        end)

      for period <- periods,
          at <- [period.start_ms, div(period.start_ms + period.end_ms, 2), period.end_ms - 1] do
        assert entitled_grant(grants, [], tenant, at) == "s1/#{period.index}"
      end

      assert length(grants) == 3
    end
  end

  # ------------------------------------------------------------ 7

  test "7 two concurrent renewals of one period commit one advance", %{p: p, b: b} do
    c = create!(b, "s1")
    end1 = c.subscription.period.end_ms
    holder = Harness.hold!(p, "T1", "s1")
    tasks = for _ <- 1..2, do: Task.async(fn -> renew(b, "s1", 1, end1) end)
    Harness.await_waiting!(2)
    Harness.release!(holder)

    [{:ok, one}, {:ok, two}] = Enum.map(tasks, &Task.await(&1, 20_000))
    assert Enum.sort([one.duplicate, two.duplicate]) == [false, true]
    assert %{one | duplicate: true} == %{two | duplicate: true}
    assert [%{"revision" => 2, "period_index" => 2}] = Harness.truth(p)
  end

  # ------------------------------------------------------------ 8

  test "8 create duplicate, conflict and subscription_exists", %{p: p, b: b} do
    c = create!(b, "s1", trial_end_ms: ms(@jan31) + 24 * @hour)
    # The stored first result, also after a renewal and a change.
    renew!(b, "s1", 0, ms(@jan31) + 24 * @hour)
    {:ok, _} = change(b, "s1", 2, @team, usd(5))
    dup = unchanged(p, fn -> create(b, "s1", trial_end_ms: ms(@jan31) + 24 * @hour) end)
    assert dup == {:ok, Map.put(c, :duplicate, true)}

    for opts <- [
          [plan: @team],
          [plan: %{plan_id: "pro", version: 2}],
          [fee: usd(1_001)],
          [interval: :year],
          [start_ms: ms(@jan31) - 1],
          [trial_end_ms: ms(@jan31) + 24 * @hour + 1]
        ] do
      refused(p, :conflict, fn ->
        create(b, "s1", Keyword.put_new(opts, :trial_end_ms, ms(@jan31) + 24 * @hour))
      end)
    end

    refused(p, :conflict, fn -> create(b, "s1") end)
    refused(p, :subscription_exists, fn -> create(b, "s2") end)
    # Another tenant is independent.
    assert create!(b, "s1", tenant: "T2").subscription.revision == 1
  end

  test "8 every transition checks the revision, then the state", %{p: p, b: b} do
    create!(b, "s1", trial_end_ms: ms(@jan31) + 24 * @hour)
    now = ms(@jan31)

    for {name, fun} <- [
          change: &change(b, "s1", &1, @team, usd(1)),
          period_end: &cancel(b, "s1", &1, :period_end, now),
          now: &cancel(b, "s1", &1, :now, now),
          past_due: &past_due(b, "s1", &1),
          paid: &paid(b, "s1", &1)
        ] do
      refused(p, :stale_revision, fn -> fun.(2) end)
      refused(p, :stale_revision, fn -> fun.(9) end)
      if name in [:past_due, :paid], do: refused(p, {:state, :trialing}, fn -> fun.(1) end)
    end

    renew!(b, "s1", 0, ms(@jan31) + 24 * @hour)
    refused(p, {:state, :active}, fn -> paid(b, "s1", 2) end)
    {:ok, %{subscription: %{state: :past_due, revision: 3}}} = past_due(b, "s1", 2)
    refused(p, :stale_revision, fn -> past_due(b, "s1", 2) end)
    refused(p, {:state, :past_due}, fn -> past_due(b, "s1", 3) end)

    # A past-due subscription renews like an active one and stays past due.
    s = get!(b, "s1").subscription
    r = renew!(b, "s1", 1, s.period.end_ms)
    assert {r.subscription.state, r.subscription.period.index} == {:past_due, 2}
    assert r.fee_line != nil
    {:ok, %{subscription: %{state: :active, revision: 5}}} = paid(b, "s1", 4)
  end

  # ------------------------------------------------------------ 9

  test "9 row security as the application role", %{p: p, b: b, role: role} do
    Harness.role_guard!(role)
    assert Plan.verify(b) == :ok
    c = create!(b, "s1")
    end1 = c.subscription.period.end_ms

    for result <- [
          Plan.get(b, "T2", %{subscription_id: "s1"}),
          renew(b, "s1", 1, end1, "T2"),
          change(b, "s1", 1, @team, usd(1), "T2"),
          cancel(b, "s1", 1, :now, end1, "T2"),
          past_due(b, "s1", 1, "T2"),
          paid(b, "s1", 1, "T2")
        ],
        do: assert(result == {:error, :unknown_subscription})

    # A direct insert of a T2 row under the T1 scope is refused by the floor.
    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege, pg_code: "42501"}}} =
             TI.transact(AppRepo, %{tenant: "T1"}, fn ->
               Harness.q(
                 AppRepo,
                 "INSERT INTO #{Harness.table(p)} SELECT 'T2', 'x', interval, anchor_ms, created_plan_id, created_version, created_fee, start_ms, trial_end_ms, plan_id, version, fee, state, period_index, period_start_ms, period_end_ms, cancel_at_period_end, cancel_ms, pending_plan_id, pending_version, pending_fee, renewed_from, revision, last_cancel_grant_ids, last_cancel_revoked_at, last_cancel_withdrawn FROM #{Harness.table(p)}"
               )
             end)

    assert [%{"tenant" => "T1"}] = Harness.truth(p)
  end

  test "9 a caller transaction, a repeatable read Repo and a missing schema", %{p: p, b: b} do
    c = create!(b, "s1")
    end1 = c.subscription.period.end_ms
    me = self()
    handler = "elz366-#{System.unique_integer()}"

    calls = fn binding ->
      [
        fn -> create(binding, "s2", tenant: "T2") end,
        fn -> renew(binding, "s1", 1, end1) end,
        fn -> change(binding, "s1", 1, @team, usd(1)) end,
        fn -> cancel(binding, "s1", 1, :period_end, end1 - 1) end,
        fn -> cancel(binding, "s1", 1, :now, end1 - 1) end,
        fn -> past_due(binding, "s1", 1) end,
        fn -> paid(binding, "s1", 1) end
      ]
    end

    {:ok, results} =
      AppRepo.transaction(fn ->
        :telemetry.attach(
          handler,
          [:elzoo, :plan_test, :app_repo, :query],
          fn _, _, meta, _ -> send(me, {:query, meta.query}) end,
          nil
        )

        results =
          Enum.map(calls.(b), & &1.()) ++ [Plan.get(b, "T1", %{subscription_id: "s1"})]

        :telemetry.detach(handler)
        results
      end)

    assert results == List.duplicate({:error, :in_transaction}, 8)
    refute_received {:query, _}

    {:ok, rr} = Plan.new(repo: RepeatableRepo, prefix: p)
    for call <- calls.(rr), do: refused(p, :isolation, call)

    {:ok, missing} = Plan.new(repo: AppRepo, prefix: "elz366_missing")
    for call <- calls.(missing), do: refused(p, :unavailable, call)
    refused(p, :unavailable, fn -> Plan.get(missing, "T1", %{subscription_id: "s1"}) end)
    assert Plan.verify(missing) != :ok
  end

  # ------------------------------------------------------------ 10

  test "10 shapes and bounds are :invalid before any query", %{p: p, b: b} do
    create!(b, "s1")
    max = Integer.pow(2, 63) - 1
    id101 = String.duplicate("a", 101)

    assert {:ok, _} = create(b, String.duplicate("a", 100), tenant: "T2")

    for opts <- [
          [tenant: ""],
          [tenant: String.duplicate("t", 129)],
          [tenant: "T\n"],
          [plan: %{plan_id: "", version: 1}],
          [plan: %{plan_id: "pro", version: 0}],
          [plan: %{plan_id: "pro", version: Integer.pow(2, 31)}],
          [plan: %{plan_id: "pro", version: 1, extra: 1}],
          [fee: usd(-1)],
          [fee: 1_000],
          [interval: :week],
          [start_ms: -1],
          [start_ms: max + 1],
          [trial_end_ms: ms(@jan31)],
          [trial_end_ms: ms(@jan31) - 1],
          # Period 1 would end after 2^63 - 1 ms.
          [start_ms: max - 1]
        ] do
      refused(p, :invalid, fn -> create(b, "x", opts) end)
    end

    refused(p, :invalid, fn -> create(b, id101) end)
    refused(p, :invalid, fn -> create(b, "") end)
    refused(p, :invalid, fn -> Plan.create(b, "T3", Map.put(request("x", []), :extra, 1)) end)
    refused(p, :invalid, fn -> renew(b, "s1", -1, 0) end)
    refused(p, :invalid, fn -> renew(b, "s1", 1, -1) end)
    refused(p, :invalid, fn -> renew(b, id101, 1, 0) end)
    refused(p, :invalid, fn -> change(b, "s1", 0, @team, usd(1)) end)
    refused(p, :invalid, fn -> change(b, "s1", 1, @team, usd(-1)) end)
    refused(p, :invalid, fn -> cancel(b, "s1", 1, :later, 0) end)
    refused(p, :invalid, fn -> cancel(b, "s1", 1, :now, -1) end)
    refused(p, :invalid, fn -> past_due(b, "s1", -1) end)
    refused(p, :invalid, fn -> Plan.get(b, "T1", %{subscription_id: "s1", x: 1}) end)
    refused(p, :invalid, fn -> renew(:not_a_binding, "s1", 1, 0) end)
    assert Plan.verify(:not_a_binding) == {:error, :invalid}

    for opts <- [
          [],
          [repo: AppRepo],
          [prefix: p],
          [repo: AppRepo, prefix: "Bad"],
          [repo: nil, prefix: p],
          [repo: AppRepo, prefix: p, renew_ahead_ms: -1],
          [repo: AppRepo, prefix: p, renew_ahead_ms: 86_400_001],
          [repo: AppRepo, prefix: p, other: 1],
          [repo: AppRepo, repo: AppRepo, prefix: p],
          %{repo: AppRepo, prefix: p}
        ],
        do: assert(Plan.new(opts) == {:error, :invalid})

    assert {:ok, %Plan{renew_ahead_ms: 86_400_000}} =
             Plan.new(repo: AppRepo, prefix: p, renew_ahead_ms: 86_400_000)

    for prefix <- ["Bad", "", nil, "a-b", String.duplicate("a", 64)],
        do:
          assert_raise(ArgumentError, "invalid plan prefix", fn ->
            Plan.Migration.install(prefix)
          end)
  end
end
