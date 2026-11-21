# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/quota_test_helper.exs", __DIR__)

defmodule Elzoo.QuotaTest do
  # The cases share one database server and hold row locks across connections: not async.
  use ExUnit.Case, async: false
  alias Elzoo.AiModel.Usage
  alias Elzoo.Entitlement
  alias Elzoo.Quota
  alias Elzoo.QuotaTest.{AppRepo, Harness, OwnerRepo, RepeatableRepo}
  alias Elzoo.TenantIsolation, as: TI

  @moduletag :capture_log
  @max Integer.pow(2, 63) - 1
  @nov {:period, "2026-11"}
  @dec {:period, "2026-12"}
  @denied :insufficient_privilege
  @message "invalid quota prefix or options"

  setup_all do
    if Enum.any?([OwnerRepo, AppRepo, RepeatableRepo], &Process.whereis/1),
      do: raise("the quota test Repos are already running")

    role = Harness.start_repos!()
    on_exit(fn -> Enum.each([OwnerRepo, AppRepo, RepeatableRepo], &Harness.stop!/1) end)
    {:ok, role: role}
  end

  setup %{role: role} do
    p = Harness.install!(role)
    # on_exit runs last-registered first: the invariants, then the drop.
    on_exit(fn -> Harness.drop!(p) end)
    on_exit(fn -> Harness.assert_invariants!(p) end)
    {:ok, p: p, q: Quota.new(repo: AppRepo, prefix: p)}
  end

  # ------------------------------------------------------------ fixtures

  defp all_units, do: Enum.sort(Usage.units() ++ Enum.map(Usage.ttls(), &{:cache_write_tokens, &1}))

  # A plan of {unit, amount} allowances (utc_month) and one grant g1 of it; resolved by
  # domain/entitlement while entitled (at 500), in grace (at 1500) or after a revocation.
  defp resolve(opts) do
    tenant = Keyword.get(opts, :tenant, "T1")
    allowances = Keyword.get(opts, :allowances, images: 10, output_tokens: 10)

    body = %{
      plan_id: "plan",
      version: 1,
      features: [],
      allowances:
        allowances
        |> Enum.sort()
        |> Enum.map(fn {u, a} -> %{unit: u, amount: a, period_kind: :utc_month} end)
    }

    {:ok, hash} = Entitlement.content_hash(body)

    grant = %{
      grant_id: "g1",
      tenant: tenant,
      plan_id: "plan",
      version: 1,
      valid_from_ms: 0,
      valid_to_ms: 1_000,
      grace_until_ms: 2_000,
      revoked_at_ms: Keyword.get(opts, :revoked_at_ms)
    }

    Entitlement.resolve(
      %{plans: [Map.put(body, :content_hash, hash)], grants: [grant]},
      tenant,
      Keyword.get(opts, :at, 500)
    )
  end

  defp resolution(opts \\ []) do
    {:entitled, r} = resolve(opts)
    r
  end

  defp grace(opts \\ []) do
    {:grace, r} = resolve(Keyword.put(opts, :at, 1_500))
    r
  end

  defp request(run_id, estimates, opts \\ []) do
    %{
      run_id: run_id,
      window: Keyword.get(opts, :window, @nov),
      estimates: Enum.map(estimates, fn {u, a} -> %{unit: u, amount: a} end),
      expiry_ms: Keyword.get(opts, :expiry, 1_000),
      now_ms: Keyword.get(opts, :now, 0),
      resolution: Keyword.get_lazy(opts, :resolution, fn -> resolution() end)
    }
  end

  defp reserve(q, run_id, estimates, opts \\ []),
    do: Quota.reserve(q, Keyword.get(opts, :tenant, "T1"), request(run_id, estimates, opts))

  defp settle(q, run_id, actuals, tenant \\ "T1"),
    do:
      Quota.settle(q, tenant, %{
        run_id: run_id,
        actuals: Enum.map(actuals, fn {u, a} -> %{unit: u, actual: a} end)
      })

  defp reconcile(q, run_id, unit, actual, opts \\ []),
    do:
      Quota.reconcile(q, Keyword.get(opts, :tenant, "T1"), %{
        run_id: run_id,
        unit: unit,
        actual: actual,
        basis: Keyword.get(opts, :basis, :metering),
        actor_ref: Keyword.get(opts, :actor_ref, "svc:metering"),
        reason: Keyword.get(opts, :reason, "correction")
      })

  defp release(q, run_id, now \\ 0), do: Quota.release(q, "T1", %{run_id: run_id, now_ms: now})

  defp status!(q, opts \\ []) do
    {:ok, rows} =
      Quota.status(q, Keyword.get(opts, :tenant, "T1"), %{
        window: Keyword.get(opts, :window, @nov),
        resolution: Keyword.get_lazy(opts, :resolution, fn -> resolution() end)
      })

    assert Enum.map(rows, & &1.unit) == Enum.sort(Enum.map(rows, & &1.unit))
    Map.new(rows, &{&1.unit, &1})
  end

  defp counters(q, unit, opts \\ []) do
    row = Map.fetch!(status!(q, opts), unit)
    {row.committed, row.held, row.reserved}
  end

  # A refusal with this reason that commits nothing.
  defp refused(p, reason, fun) do
    before = Harness.truth(p)
    assert fun.() == {:error, reason}
    assert Harness.truth(p) == before
  end

  defp await(tasks), do: Enum.map(tasks, &Task.await(&1, 20_000))

  # ------------------------------------------------------------ 1

  test "1 concurrent last-unit admission: one applied, one insufficient", %{q: q} do
    # The counter row exists from an earlier reservation that was released.
    assert reserve(q, "r0", images: 6) == {:ok, :applied}
    assert release(q, "r0") == {:ok, :applied}
    assert counters(q, :images) == {0, 0, 0}

    holder = Harness.hold!(q.prefix, "T1", "2026-11", "images")
    tasks = for id <- ["r1", "r2"], do: Task.async(fn -> reserve(q, id, images: 6) end)
    Harness.await_waiting!(2)
    Harness.release!(holder)

    assert Enum.sort(await(tasks)) == [{:error, :insufficient}, {:ok, :applied}]
    assert counters(q, :images) == {0, 0, 6}
  end

  # ------------------------------------------------------------ 2

  test "2 lock order: reserve, settle and release of A and B all wait on A and commit", %{q: q} do
    big = resolution(allowances: [images: 100, output_tokens: 100])
    deadlock_ms = Harness.deadlock_timeout_ms()

    for last <- [:reserve, :settle, :release] do
      for id <- ["s-#{last}", "l-#{last}"],
          do:
            assert(
              reserve(q, id, [images: 1, output_tokens: 1], resolution: big) == {:ok, :applied}
            )

      ops = %{
        reserve: fn -> reserve(q, "n-#{last}", [images: 1, output_tokens: 1], resolution: big) end,
        settle: fn -> settle(q, "s-#{last}", images: 1, output_tokens: :unknown) end,
        release: fn -> release(q, "l-#{last}") end
      }

      holder = Harness.hold!(q.prefix, "T1", "2026-11", "images")
      first = for {name, op} <- ops, name != last, do: Task.async(op)
      Harness.await_waiting!(2)
      third = Task.async(ops[last])
      Harness.await_waiting!(3)
      # Longer than deadlock_timeout: the three still wait, no deadlock is found.
      Process.sleep(deadlock_ms + 200)
      assert Harness.waiting() == 3
      Harness.release!(holder)

      assert await(first ++ [third]) == [{:ok, :applied}, {:ok, :applied}, {:ok, :applied}]
      Harness.assert_invariants!(q.prefix)
    end

    assert counters(q, :images, resolution: big) == {3, 0, 3}
    assert counters(q, :output_tokens, resolution: big) == {0, 3, 3}
  end

  # ------------------------------------------------------------ 3

  describe "3 duplicates and conflicts" do
    test "reserve: duplicate whatever the time and resolution, conflict on another request",
         %{q: q, p: p} do
      assert reserve(q, "d1", images: 3) == {:ok, :applied}
      assert reserve(q, "d1", images: 3) == {:ok, :duplicate}
      assert reserve(q, "d1", [images: 3], now: 500, resolution: grace()) == {:ok, :duplicate}
      # Also at expiry and with a resolution that lacks the unit: steps 6, 7 and 9 never run.
      assert reserve(q, "d1", [images: 3], now: 1_000) == {:ok, :duplicate}

      assert reserve(q, "d1", [images: 3], resolution: resolution(allowances: [output_tokens: 1])) ==
               {:ok, :duplicate}

      assert counters(q, :images) == {0, 0, 3}

      refused(p, :conflict, fn -> reserve(q, "d1", images: 4) end)
      refused(p, :conflict, fn -> reserve(q, "d1", [images: 3], window: @dec) end)
      refused(p, :conflict, fn -> reserve(q, "d1", [images: 3], expiry: 999) end)
      refused(p, :conflict, fn -> reserve(q, "d1", images: 3, output_tokens: 1) end)

      # The stored digest is the SHA-256 of the README encoding.
      field = fn name, value ->
        [<<byte_size(name)::32>>, name, <<IO.iodata_length(value)::32>>, value]
      end

      encoding = [
        "elzoo-quota-reservation/1",
        field.("run_id", "d1"),
        field.("window_tag", "period"),
        field.("window_id", "2026-11"),
        field.("estimates", [
          field.("estimate", [field.("unit", "images"), field.("amount", "3")])
        ]),
        field.("expiry_ms", "1000")
      ]

      [stored] = Harness.truth(p).reservations
      assert stored.digest == :crypto.hash(:sha256, encoding)

      # After release the retry is still duplicate and reserves nothing.
      assert release(q, "d1") == {:ok, :applied}
      assert reserve(q, "d1", images: 3) == {:ok, :duplicate}
      assert counters(q, :images) == {0, 0, 0}
    end

    test "settle, reconcile and release duplicates and conflicts", %{q: q, p: p} do
      assert reserve(q, "d2", images: 3, output_tokens: 2) == {:ok, :applied}
      assert settle(q, "d2", images: 2, output_tokens: :unknown) == {:ok, :applied}
      assert settle(q, "d2", images: 2, output_tokens: :unknown) == {:ok, :duplicate}
      refused(p, :conflict, fn -> settle(q, "d2", images: 1, output_tokens: :unknown) end)
      refused(p, :conflict, fn -> settle(q, "d2", images: :unknown, output_tokens: :unknown) end)
      refused(p, :conflict, fn -> settle(q, "d2", images: 2, output_tokens: 2) end)
      refused(p, :invalid, fn -> settle(q, "d2", images: 2) end)

      assert reconcile(q, "d2", :output_tokens, 1) == {:ok, :applied}
      assert reconcile(q, "d2", :output_tokens, 1) == {:ok, :duplicate}
      refused(p, :conflict, fn -> reconcile(q, "d2", :output_tokens, 2) end)
      refused(p, :conflict, fn -> reconcile(q, "d2", :output_tokens, 1, basis: :write_off) end)
      refused(p, :conflict, fn -> reconcile(q, "d2", :output_tokens, 1, actor_ref: "op") end)
      refused(p, :conflict, fn -> reconcile(q, "d2", :output_tokens, 1, reason: "other") end)
      # A settled :unknown unit stays :unknown for the settle duplicate after reconciliation.
      assert settle(q, "d2", images: 2, output_tokens: :unknown) == {:ok, :duplicate}
      refused(p, :not_held, fn -> reconcile(q, "d2", :images, 2) end)
      refused(p, :not_held, fn -> reconcile(q, "d2", :characters, 2) end)
      assert counters(q, :images) == {2, 0, 0}
      assert counters(q, :output_tokens) == {1, 0, 0}

      assert reserve(q, "d3", images: 1) == {:ok, :applied}
      refused(p, :not_held, fn -> reconcile(q, "d3", :images, 1) end)
      assert release(q, "d3") == {:ok, :applied}
      assert release(q, "d3") == {:ok, :duplicate}
      assert counters(q, :images) == {2, 0, 0}

      refused(p, :unknown_reservation, fn -> settle(q, "none", images: 1) end)
      refused(p, :unknown_reservation, fn -> reconcile(q, "none", :images, 1) end)
      refused(p, :unknown_reservation, fn -> release(q, "none") end)
    end
  end

  # ------------------------------------------------------------ 4

  test "4 unknown usage stays held until reconciled", %{q: q, p: p} do
    assert reserve(q, "u1", images: 6) == {:ok, :applied}
    assert status!(q)[:images].remaining == 4
    assert settle(q, "u1", images: :unknown) == {:ok, :applied}
    assert %{committed: 0, held: 6, reserved: 0, remaining: 4} = status!(q)[:images]

    # Fits only if held were zero.
    refused(p, :insufficient, fn -> reserve(q, "u2", images: 5) end)

    assert reconcile(q, "u1", :images, 2, basis: :metering) == {:ok, :applied}
    assert %{committed: 2, held: 0, reserved: 0, remaining: 8} = status!(q)[:images]
    assert reserve(q, "u2", images: 5) == {:ok, :applied}
  end

  # ------------------------------------------------------------ 5

  test "5 open and held reservations survive a Repo restart", %{q: q, p: p, role: role} do
    assert reserve(q, "o1", images: 2) == {:ok, :applied}
    assert reserve(q, "h1", images: 3) == {:ok, :applied}
    assert settle(q, "h1", images: :unknown) == {:ok, :applied}

    Harness.stop!(AppRepo)
    refute Process.whereis(AppRepo)
    Harness.start_app!(role)

    assert counters(q, :images) == {0, 3, 2}
    assert settle(q, "o1", images: 1) == {:ok, :applied}

    assert reconcile(q, "h1", :images, 0,
             basis: :write_off,
             actor_ref: "operator:7",
             reason: "lost run"
           ) == {:ok, :applied}

    assert counters(q, :images) == {1, 0, 0}

    assert [%{basis: "write_off", actor_ref: "operator:7", reason: "lost run", actual: 0}] =
             Enum.filter(Harness.truth(p).units, &(&1.key == {"T1", "h1"}))
  end

  # ------------------------------------------------------------ 6

  describe "6 grace, revocation and resolutions" do
    test "grace reserves nothing and settles; revocation settles; nil status", %{q: q, p: p} do
      assert reserve(q, "g1", images: 4) == {:ok, :applied}
      refused(p, :settle_only, fn -> reserve(q, "g2", [images: 1], resolution: grace()) end)
      assert %{amount: 0, settle_only: true, reserved: 4} = status!(q, resolution: grace())[:images]
      assert settle(q, "g1", images: 3) == {:ok, :applied}

      assert reserve(q, "g3", images: 1) == {:ok, :applied}
      assert resolve(revoked_at_ms: 400) == {:not_entitled, :revoked}
      assert settle(q, "g3", images: :unknown) == {:ok, :applied}

      rows = status!(q, resolution: nil)
      assert Map.keys(rows) == [:images]

      assert rows[:images] == %{
               unit: :images,
               amount: 0,
               settle_only: false,
               committed: 3,
               held: 1,
               reserved: 0,
               remaining: 0
             }
    end

    test "bad resolutions are :resolution, a missing unit :no_allowance", %{q: q, p: p} do
      base = resolution()
      [a | rest] = base.allowances

      for bad <- [
            %{base | allowances: [%{a | grant_id: "g9"} | rest]},
            %{base | tenant: "T2"},
            %{base | allowances: [%{a | settle_only: true} | rest]},
            %{grace() | allowances: Enum.map(grace().allowances, &%{&1 | settle_only: false})},
            %{base | grants: base.grants ++ base.grants},
            %{base | grants: []},
            %{base | grants: [%{hd(base.grants) | status: :revoked}]},
            %{base | allowances: [%{a | amount: 0} | rest]},
            Map.delete(base, :allowances),
            nil
          ] do
        refused(p, :resolution, fn -> reserve(q, "x", [images: 1], resolution: bad) end)

        if bad != nil do
          assert Quota.status(q, "T1", %{window: @nov, resolution: bad}) ==
                   {:error, :resolution}
        end
      end

      # Other keys are ignored.
      assert reserve(q, "y", [images: 1], resolution: Map.put(base, :extra, 1)) ==
               {:ok, :applied}

      refused(p, :no_allowance, fn -> reserve(q, "z", characters: 1, images: 1) end)
    end

    test "more than one grant: the sum of entitled allowances", %{q: q, p: p} do
      grant = fn id, status ->
        %{grant_id: id, plan_id: id, version: 1, content_hash: <<0::256>>, status: status}
      end

      al = fn unit, amount, id, settle_only, kind ->
        %{unit: unit, amount: amount, period_kind: kind, settle_only: settle_only, grant_id: id}
      end

      two = %{
        tenant: "T1",
        at_ms: 0,
        features: [],
        grants: [grant.("g1", :entitled), grant.("g2", :grace)],
        allowances: [
          al.(:images, 10, "g1", false, :utc_month),
          al.(:images, 5, "g2", true, :utc_month),
          al.(:output_tokens, 5, "g2", true, :utc_month),
          al.(:images, 7, "g1", false, :local_month)
        ]
      }

      assert %{amount: 10, settle_only: false} = status!(q, resolution: two)[:images]
      assert %{amount: 0, settle_only: true} = status!(q, resolution: two)[:output_tokens]
      assert reserve(q, "m1", [images: 10], resolution: two) == {:ok, :applied}
      refused(p, :insufficient, fn -> reserve(q, "m2", [images: 1], resolution: two) end)
      refused(p, :settle_only, fn -> reserve(q, "m3", [output_tokens: 1], resolution: two) end)

      third = %{two | allowances: two.allowances ++ [al.(:images, 1, "g3", false, :utc_month)]}
      refused(p, :resolution, fn -> reserve(q, "m4", [images: 1], resolution: third) end)

      unmapped = %{
        two
        | allowances: two.allowances ++ [al.(:characters, 1, "g3", false, :local_month)]
      }

      refused(p, :resolution, fn -> reserve(q, "m5", [images: 1], resolution: unmapped) end)
      twice = %{two | grants: two.grants ++ [grant.("g1", :entitled)]}
      refused(p, :resolution, fn -> reserve(q, "m6", [images: 1], resolution: twice) end)

      # An unmapped unit (a later entitlement member) is ignored after the grant check.
      later = %{two | allowances: two.allowances ++ [al.(:new_unit, 1, "g1", false, :utc_month)]}
      assert Enum.sort(Map.keys(status!(q, resolution: later))) == [:images, :output_tokens]
    end
  end

  # ------------------------------------------------------------ 7

  test "7 a window boundary: each reservation lands in its own window", %{q: q} do
    assert reserve(q, "n1", images: 3) == {:ok, :applied}
    assert counters(q, :images, window: @dec) == {0, 0, 0}
    assert status!(q, window: @dec)[:images].remaining == 10

    holder = Harness.hold!(q.prefix, "T1", "2026-11", "images")
    nov = Task.async(fn -> reserve(q, "n2", images: 2) end)
    Harness.await_waiting!(1)
    # December's first reservation commits while November waits on its own row.
    assert reserve(q, "d1", [images: 4], window: @dec) == {:ok, :applied}
    assert Harness.waiting() == 1
    Harness.release!(holder)
    assert await([nov]) == [{:ok, :applied}]

    december = status!(q, window: @dec)
    assert settle(q, "n1", images: 1) == {:ok, :applied}
    assert status!(q, window: @dec) == december
    assert counters(q, :images) == {1, 0, 2}
    assert counters(q, :images, window: @dec) == {0, 0, 4}
  end

  # ------------------------------------------------------------ 8

  test "8 expiry: refused at now, release before it, settle after it", %{q: q, p: p} do
    refused(p, :expiry, fn -> reserve(q, "e0", [images: 1], expiry: 100, now: 100) end)

    assert reserve(q, "e1", [images: 1], expiry: 100, now: 0) == {:ok, :applied}
    assert release(q, "e1", 99) == {:ok, :applied}

    assert reserve(q, "e2", [images: 2], expiry: 100, now: 0) == {:ok, :applied}
    refused(p, :expired, fn -> release(q, "e2", 100) end)
    assert counters(q, :images) == {0, 0, 2}
    assert settle(q, "e2", images: 2) == {:ok, :applied}
    assert counters(q, :images) == {2, 0, 0}

    assert reserve(q, "e3", [images: 3], expiry: 100, now: 0) == {:ok, :applied}
    assert release(q, "e3", 50) == {:ok, :applied}
    assert settle(q, "e3", images: 4) == {:ok, :applied}
    assert counters(q, :images) == {6, 0, 0}
    refused(p, :already_settled, fn -> release(q, "e3", 50) end)

    assert reserve(q, "e4", [images: 1], expiry: 100, now: 0) == {:ok, :applied}
    assert release(q, "e4", 50) == {:ok, :applied}
    assert settle(q, "e4", images: :unknown) == {:ok, :applied}
    assert counters(q, :images) == {6, 1, 0}
  end

  # ------------------------------------------------------------ 9

  test "9 overage: an actual above the estimate is committed in full", %{q: q, p: p} do
    assert reserve(q, "o1", images: 6) == {:ok, :applied}
    assert settle(q, "o1", images: 15) == {:ok, :applied}
    assert %{committed: 15, remaining: 0} = status!(q)[:images]
    refused(p, :insufficient, fn -> reserve(q, "o2", images: 1) end)
  end

  # ------------------------------------------------------------ 10

  test "10 row security as the application role", %{q: q, p: p, role: role} do
    Harness.role_guard!(role)

    for t <- ~w(elzoo_quota_counters elzoo_quota_reservations elzoo_quota_units),
        do:
          assert(
            TI.verify(AppRepo, {p, t}, prefix: p, tenant_column: "tenant", space_column: nil) ==
              :ok
          )

    assert reserve(q, "t2-run", [images: 1], tenant: "T2", resolution: resolution(tenant: "T2")) ==
             {:ok, :applied}

    assert reserve(q, "t1-run", images: 1) == {:ok, :applied}

    probe = fn sql, params ->
      {:error, {:probe, result}} =
        TI.transact(AppRepo, %{tenant: "T1"}, fn ->
          {:error, {:probe, Harness.q(AppRepo, sql, params)}}
        end)

      result
    end

    for t <- [:counters, :reservations, :units] do
      assert {:ok, %{rows: rows}} = probe.("SELECT DISTINCT tenant FROM #{Harness.table(p, t)}", [])
      assert rows == [["T1"]]
    end

    refused(p, :unknown_reservation, fn -> settle(q, "t2-run", images: 1) end)

    for sql <- [
          "INSERT INTO #{Harness.table(p, :counters)} (tenant, window_tag, window_id, unit, committed, held, reserved) VALUES ('T2', 'period', '2026-11', 'characters', 0, 0, 0)",
          "INSERT INTO #{Harness.table(p, :reservations)} (tenant, run_id, window_tag, window_id, expiry_ms, request_digest, state) VALUES ('T2', 'direct', 'period', '2026-11', 1, decode(repeat('00', 32), 'hex'), 'open')",
          "INSERT INTO #{Harness.table(p, :units)} (tenant, run_id, unit, estimate) VALUES ('T2', 't2-run', 'characters', 1)"
        ],
        do: assert({:error, %Postgrex.Error{postgres: %{code: @denied}}} = probe.(sql, []))

    for t <- [:counters, :reservations, :units] do
      assert {:error, %Postgrex.Error{postgres: %{code: @denied}}} =
               probe.("DELETE FROM #{Harness.table(p, t)}", [])
    end
  end

  # ------------------------------------------------------------ 11

  test "11 a caller transaction and a repeatable read Repo are refused", %{q: q, p: p} do
    assert reserve(q, "i1", images: 2) == {:ok, :applied}
    assert reserve(q, "i2", images: 2) == {:ok, :applied}
    assert settle(q, "i2", images: :unknown) == {:ok, :applied}
    me = self()
    handler = "elz303-#{System.unique_integer()}"

    {:ok, results} =
      AppRepo.transaction(fn ->
        :telemetry.attach(
          handler,
          [:elzoo, :quota_test, :app_repo, :query],
          fn _, _, meta, _ -> send(me, {:query, meta.query}) end,
          nil
        )

        results = [
          reserve(q, "i3", images: 1),
          settle(q, "i1", images: 1),
          reconcile(q, "i2", :images, 1),
          release(q, "i1"),
          Quota.status(q, "T1", %{window: @nov, resolution: nil})
        ]

        :telemetry.detach(handler)
        results
      end)

    assert results == List.duplicate({:error, :in_transaction}, 5)
    refute_received {:query, _}

    rr = Quota.new(repo: RepeatableRepo, prefix: p)
    refused(p, :isolation, fn -> reserve(rr, "i3", images: 1) end)
    refused(p, :isolation, fn -> settle(rr, "i1", images: 1) end)
    refused(p, :isolation, fn -> reconcile(rr, "i2", :images, 1) end)
    refused(p, :isolation, fn -> release(rr, "i1") end)

    assert {:ok, [%{unit: :images, reserved: 2, held: 2}]} =
             Quota.status(rr, "T1", %{window: @nov, resolution: nil})
  end

  test "11 a database failure is unavailable with nothing committed", %{q: q, p: p} do
    assert reserve(q, "f1", images: 1) == {:ok, :applied}
    missing = Quota.new(repo: AppRepo, prefix: "elz303_missing")
    refused(p, :unavailable, fn -> reserve(missing, "f1", images: 1) end)
    refused(p, :unavailable, fn -> settle(missing, "f1", images: 1) end)
    refused(p, :unavailable, fn -> reconcile(missing, "f1", :images, 1) end)
    refused(p, :unavailable, fn -> release(missing, "f1") end)

    refused(p, :unavailable, fn ->
      Quota.status(missing, "T1", %{window: @nov, resolution: nil})
    end)
  end

  # ------------------------------------------------------------ 12

  describe "12 bounds" do
    test "inner edges pass the shape check", %{q: q} do
      t128 = String.duplicate("t", 128)

      for tenant <- ["t", t128] do
        r = resolution(tenant: tenant)

        assert reserve(q, "b-#{byte_size(tenant)}", [images: 1], tenant: tenant, resolution: r) ==
                 {:ok, :applied}
      end

      for wid <- ["w", String.duplicate("w", 128)],
          do:
            assert(
              reserve(q, "w-#{byte_size(wid)}", [images: 1], window: {:period, wid}) ==
                {:ok, :applied}
            )

      run200 = String.duplicate("r", 200)
      assert reserve(q, run200, images: 1) == {:ok, :applied}
      assert settle(q, run200, images: :unknown) == {:ok, :applied}

      assert reconcile(q, run200, :images, 0,
               actor_ref: "a",
               reason: String.duplicate("é", 128)
             ) == {:ok, :applied}

      assert reserve(q, "a128", images: 1) == {:ok, :applied}
      assert settle(q, "a128", images: :unknown) == {:ok, :applied}

      assert reconcile(q, "a128", :images, 0, actor_ref: t128, reason: "r") ==
               {:ok, :applied}

      all = resolution(allowances: Enum.map(all_units(), &{&1, @max}))
      assert length(all_units()) == 15
      estimates = Enum.map(all_units(), &{&1, 1})
      assert reserve(q, "all", estimates, window: @dec, resolution: all) == {:ok, :applied}

      assert settle(q, "all", Enum.map(all_units(), &{&1, 0})) == {:ok, :applied}

      max = {:period, "max"}

      assert reserve(q, "max", [audio_seconds: @max], window: max, resolution: all) ==
               {:ok, :applied}

      assert settle(q, "max", audio_seconds: @max) == {:ok, :applied}
      assert status!(q, window: max, resolution: all)[:audio_seconds].committed == @max
    end

    test "outer edges and faults are :invalid", %{q: q, p: p} do
      assert reserve(q, "open", images: 1) == {:ok, :applied}
      assert reserve(q, "held", images: 1) == {:ok, :applied}
      assert settle(q, "held", images: :unknown) == {:ok, :applied}

      bad_texts = ["", <<0xFF>>, "a\0b", "a\nb", "a\u0085b", "a\u009Fb", "a\u007Fb"]

      for t <- bad_texts ++ [String.duplicate("t", 129)] do
        refused(p, :invalid, fn -> reserve(q, "x", [images: 1], tenant: t) end)
        refused(p, :invalid, fn -> reserve(q, "x", [images: 1], window: {:period, t}) end)
        refused(p, :invalid, fn -> reconcile(q, "held", :images, 0, actor_ref: t) end)
        refused(p, :invalid, fn -> settle(q, "open", [images: 1], t) end)
      end

      for t <- bad_texts ++ [String.duplicate("r", 201)] do
        refused(p, :invalid, fn -> reserve(q, t, images: 1) end)
        refused(p, :invalid, fn -> settle(q, t, images: 1) end)
        refused(p, :invalid, fn -> release(q, t) end)
      end

      for t <- bad_texts ++ [String.duplicate("r", 257)],
          do: refused(p, :invalid, fn -> reconcile(q, "held", :images, 0, reason: t) end)

      sixteen = Enum.map(all_units(), &{&1, 1}) ++ [{:video_seconds, 1}]
      seventeen = sixteen ++ [{:images, 1}]

      for estimates <- [
            [],
            sixteen,
            seventeen,
            [output_tokens: 1, images: 1],
            [images: 1, images: 1],
            [images: 0],
            [images: @max + 1],
            [images: -1],
            [images: 1.0],
            [tokens: 1],
            [{{:cache_write_tokens, "2h"}, 1}]
          ],
          do: refused(p, :invalid, fn -> reserve(q, "x", estimates) end)

      for window <- [{:rolling, 0, 10}, {:month, "2026-11"}, {:period, 1}, :period, nil],
          do: refused(p, :invalid, fn -> reserve(q, "x", [images: 1], window: window) end)

      for t <- [-1, @max + 1, 1.0, nil] do
        refused(p, :invalid, fn -> reserve(q, "x", [images: 1], expiry: t) end)
        refused(p, :invalid, fn -> reserve(q, "x", [images: 1], now: t) end)
        refused(p, :invalid, fn -> release(q, "open", t) end)
      end

      for a <- [-1, @max + 1, 1.0, :lost, nil] do
        refused(p, :invalid, fn -> settle(q, "open", images: a) end)
        if a != :lost, do: refused(p, :invalid, fn -> reconcile(q, "held", :images, a) end)
      end

      refused(p, :invalid, fn -> reconcile(q, "held", :images, :unknown) end)
      refused(p, :invalid, fn -> reconcile(q, "held", :images, 0, basis: :guess) end)
      refused(p, :invalid, fn -> reconcile(q, "held", :tokens, 0) end)
      refused(p, :invalid, fn -> settle(q, "open", []) end)
      refused(p, :invalid, fn -> settle(q, "open", tokens: 1) end)

      refused(p, :invalid, fn ->
        Quota.reserve(q, "T1", Map.put(request("x", images: 1), :extra, 1))
      end)

      refused(p, :invalid, fn ->
        Quota.reserve(q, "T1", Map.delete(request("x", images: 1), :now_ms))
      end)

      refused(p, :invalid, fn -> Quota.settle(q, "T1", %{run_id: "open"}) end)
      refused(p, :invalid, fn -> Quota.release(q, "T1", nil) end)

      refused(p, :invalid, fn ->
        Quota.status(q, "T1", %{window: {:rolling, 0, 1}, resolution: nil})
      end)

      refused(p, :invalid, fn -> reserve(%{q | prefix: "Bad"}, "x", images: 1) end)
      refused(p, :invalid, fn -> reserve(:quota, "x", images: 1) end)
    end

    test "new/1 and the migration refuse bad options before any DDL" do
      for opts <- [
            [repo: AppRepo],
            [prefix: "ok"],
            [repo: AppRepo, prefix: "ok", extra: 1],
            [repo: nil, prefix: "ok"],
            [repo: AppRepo, prefix: "Bad"],
            [repo: AppRepo, prefix: String.duplicate("a", 64)],
            %{repo: AppRepo, prefix: "ok"}
          ],
          do: assert_raise(ArgumentError, @message, fn -> Quota.new(opts) end)

      for prefix <- ["Bad", "a-b", "", nil, :atom],
          do: assert_raise(ArgumentError, @message, fn -> Quota.Migration.install(prefix) end)
    end
  end

  # ------------------------------------------------------------ 13

  test "13 selected Cure laws, a clean audit and the production decisions" do
    source = File.read!(Path.expand("../../cure/elzoo/quota.cure", __DIR__))
    roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
    assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
    assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(audit, key) == [])

    for law <- [
          :admission_cap,
          :settle_only_admits_nothing,
          :rejection_keeps_counters,
          :unknown_is_held,
          :settle_known_commits_actual
        ],
        do: assert(source =~ "fn #{law}(")

    cure = :"Cure.Elzoo.Quota"
    c = fn committed, held, reserved -> {:Counters, committed, held, reserved} end

    assert apply(cure, :admit, [c.(1, 2, 3), 10, false, 4]) ==
             {:Admission, c.(1, 2, 7), :QuotaAdmitted}

    assert apply(cure, :admit, [c.(1, 2, 3), 10, false, 5]) ==
             {:Admission, c.(1, 2, 3), :QuotaInsufficient}

    assert apply(cure, :admit, [c.(0, 0, 0), 10, true, 1]) ==
             {:Admission, c.(0, 0, 0), :QuotaSettleOnly}

    # Counters already over the amount after an overage stay unchanged on a refusal.
    assert apply(cure, :admit, [c.(15, 0, 0), 10, false, 1]) ==
             {:Admission, c.(15, 0, 0), :QuotaInsufficient}

    assert apply(cure, :settle, [c.(1, 2, 6), 6, :Unknown, false]) == c.(1, 8, 0)
    assert apply(cure, :settle, [c.(1, 2, 0), 6, :Unknown, true]) == c.(1, 8, 0)
    assert apply(cure, :settle, [c.(1, 2, 6), 6, {:Known, 9}, false]) == c.(10, 2, 0)
    assert apply(cure, :settle, [c.(1, 2, 0), 6, {:Known, 0}, true]) == c.(1, 2, 0)
    assert apply(cure, :reconcile, [c.(1, 8, 0), 6, 0]) == c.(1, 2, 0)
    assert apply(cure, :release, [c.(1, 2, 6), 6]) == c.(1, 2, 0)
  end

  # ------------------------------------------------------------ 14

  test "14 the unit rows: one unique constraint on (tenant, run_id, unit), its index the only one",
       %{p: p} do
    units = Harness.table(p, :units)

    # Column names in key order, from the catalog.
    columns = fn rel, keys ->
      "array(SELECT a.attname::text FROM unnest(#{keys}) WITH ORDINALITY AS k(n, i) JOIN pg_attribute a ON a.attrelid = #{rel} AND a.attnum = k.n ORDER BY k.i)"
    end

    keys =
      Harness.q!(
        OwnerRepo,
        "SELECT c.contype::text, #{columns.("c.conrelid", "c.conkey")}, c.conindid::regclass::text FROM pg_constraint c WHERE c.conrelid = to_regclass($1) AND c.contype IN ('p', 'u')",
        [units]
      )

    indexes =
      Harness.q!(
        OwnerRepo,
        "SELECT i.indexrelid::regclass::text, i.indisunique, #{columns.("i.indrelid", "i.indkey::int2[]")} FROM pg_index i WHERE i.indrelid = to_regclass($1)",
        [units]
      )

    assert [["u", ["tenant", "run_id", "unit"], index]] = keys
    assert indexes == [[index, true, ["tenant", "run_id", "unit"]]]
  end
end
