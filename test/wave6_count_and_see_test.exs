Code.require_file("support/wave6_count_and_see_helper.exs", __DIR__)

defmodule Elzoo.Wave6.CountAndSeeTest do
  # ELZ-323: the Wave 6 Pieces together on real PostgreSQL, every application call running as the
  # fixed non-owner, non-bypass role of ELZ-285. Each test names its acceptance group.
  use ExUnit.Case, async: false

  alias Elzoo.{
    AuditLog,
    DeadLetterStore,
    Entitlement,
    Eval,
    Metering,
    Pricing,
    Quota,
    TenantIsolation
  }

  alias Elzoo.Jobs.Relay
  alias Elzoo.RunEngine.TestHelper
  alias Elzoo.Wave6.{AppRepo, OwnerRepo}
  alias Elzoo.Wave6.CountHelper, as: H

  @now H.now()
  @period H.period()

  setup_all do
    role = H.start_repos!()
    on_exit(fn -> for repo <- [OwnerRepo, AppRepo], do: H.stop!(repo) end)
    # Fails, never skips: the application connection must be the application role.
    H.role_guard!(role)
    engine_repo = TestHelper.database()
    {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.TestRegistry)
    {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.UnitRegistry)
    for pid <- [registry, units], do: Process.unlink(pid)

    on_exit(fn ->
      for pid <- [registry, units, engine_repo], Process.alive?(pid), do: Supervisor.stop(pid)
    end)

    %{role: role}
  end

  setup %{role: role} do
    Process.flag(:trap_exit, true)
    fx = H.fixture!(role)
    on_exit(fn -> H.cleanup!(fx) end)
    %{fx: fx, p: fx.prefix}
  end

  defp sql(statement, params \\ []), do: H.q(AppRepo, statement, params)

  defp completed!(run),
    do: TestHelper.wait_for(run.engine, &(&1.outcome == :completed))

  defp completed_requests,
    do: [
      TestHelper.request([H.model_call("call-1")]),
      TestHelper.request([H.finish("call-1")])
    ]

  # The counted gate of the tenant's resolution.
  defp gate(fx, tenant), do: H.feature_gate(fx.resolutions[tenant])

  # The host admits a prepared Run under the resolution: reserved by its key, then started.
  defp admitted!(fx, run, resolution) do
    assert {:started, run} = H.admit(fx, run, resolution)
    run
  end

  # A completed T1 or T2 Run: admitted, one model call, then a finish; settled with its actual.
  defp completed_run(fx, tenant, usage) do
    run =
      H.prepare_run(tenant, completed_requests(), gate: gate(fx, tenant))
      |> then(&admitted!(fx, &1, fx.resolutions[&1.tenant]))

    :ok = H.serve!(fx, run, "call-1", usage)
    completed!(run)
    assert H.settle_run(fx, run) == {:ok, :applied}
    run
  end

  defp cut_requests,
    do: [
      TestHelper.request([H.model_call("call-1")]),
      TestHelper.request([H.model_call("call-2")])
    ]

  # An admitted Run whose first call completes and whose second call is cut off by an engine
  # restart. Returns the started Run and a function that restarts it and settles it with its
  # committed actual, which is unknown.
  defp cut_run(fx, %{c: _} = run, usage, resolution) do
    run = admitted!(fx, run, resolution)
    :ok = H.serve!(fx, run, "call-1", usage)
    {task, _request} = H.take_call!()

    restart = fn ->
      restarted = H.restart(run)
      # The cut call's adapter is released after the restart with no usage report: the provider
      # never answered it, so it is not counted and the host routes nothing for it.
      send(task, {:result, %{}})
      assert H.settle_run(fx, restarted) == {:ok, :applied}
      restarted
    end

    {run, restart}
  end

  defp cut_run(fx, tenant, usage),
    do:
      cut_run(
        fx,
        H.prepare_run(tenant, cut_requests(), gate: gate(fx, tenant)),
        usage,
        fx.resolutions[tenant]
      )

  defp results(meterings), do: Enum.map(meterings, &elem(&1, 2))

  # ------------------------------------------------------------ 1

  test "1 counted Runs: one usage per completed call, T1 sees no T2 row, 42501, owner-only DDL refused, replay :duplicate, cut call :unknown until corrected",
       %{fx: fx, p: p, role: role} do
    a = completed_run(fx, "T1", H.usage(3_000, 12_000))
    t2 = completed_run(fx, "T2", H.usage(1_000, 4_000))
    {b, restart} = cut_run(fx, "T1", H.usage(2_000, 8_000))

    assert results(H.meter_run!(fx, a)) == [{:ok, :applied}, {:ok, :applied}]
    assert results(H.meter_run!(fx, t2)) == [{:ok, :applied}, {:ok, :applied}]
    # Before the restart only the completed call of B is settled.
    assert H.meter_run!(fx, b) == [
             {"call-1", :input_uncached_tokens, {:ok, :applied}},
             {"call-1", :output_tokens, {:ok, :applied}}
           ]

    b = restart.()
    assert TestHelper.view(b.engine).slots[H.occurrence(b, "call-2")].outcome == "unknown"

    # The replay after the restart records the completed call once; the cut call is unknown.
    assert H.meter_run!(fx, b) == [
             {"call-1", :input_uncached_tokens, {:ok, :duplicate}},
             {"call-1", :output_tokens, {:ok, :duplicate}},
             {"call-2", :input_uncached_tokens, {:ok, :applied}},
             {"call-2", :output_tokens, {:ok, :applied}}
           ]

    # Three completed calls: each gave one usage, two observations each.
    assert H.calls(fx) == 3

    # The unknown observation is in unknown_count, not in known.
    totals = fn ->
      {:ok, rows} = Metering.totals(fx.meter, "T1", %{period: @period, max_rows: 100})
      Enum.map(rows, &{&1.unit, &1.source, &1.known, &1.unknown_count, &1.count})
    end

    assert totals.() == [
             {:input_uncached_tokens, :provider_reported, 5_000, 0, 2},
             {:input_uncached_tokens, :unknown, 0, 1, 1},
             {:output_tokens, :provider_reported, 20_000, 0, 2},
             {:output_tokens, :unknown, 0, 1, 1}
           ]

    # Under T1's scope as the application role: only T1 rows; a T2 row is SQLSTATE 42501.
    for table <- ~w(elzoo_metering_observations elzoo_metering_corrections) do
      assert TenantIsolation.verify(AppRepo, {p, table},
               prefix: p,
               tenant_column: "tenant",
               space_column: nil
             ) == :ok
    end

    assert {:ok, [["T1", 6]]} =
             H.as(%{tenant: "T1"}, fn ->
               {:ok,
                H.q!(
                  AppRepo,
                  "SELECT tenant, count(*)::int FROM #{p}.elzoo_metering_observations GROUP BY tenant"
                )}
             end)

    t2_id = H.usage_id(t2, {1, 0}, "attempt", :output_tokens)
    assert Metering.observation(fx.meter, "T1", t2_id) == {:error, :unknown_usage}
    assert {:ok, %{effective: 4_000}} = Metering.observation(fx.meter, "T2", t2_id)

    assert H.denied?(
             H.as(%{tenant: "T1"}, fn ->
               sql(
                 "INSERT INTO #{p}.elzoo_metering_observations (tenant, usage_id, run_id, operation_id, attempt_id, provider_id, model_id, unit, amount, source, period, observed_at_ms, digest, effective, revision) VALUES ('T2', 'forged', 'r', 'o', 'a', 'scripted', 'model-a', 'output_tokens', 1, 'estimated', $1, 0, '\\x00', 1, 0)",
                 [@period]
               )
             end)
           )

    # Owner-only: the application role cannot lift the floor. Forced row security filters the
    # owner's reads too, so only these refusals tell the application role from the owner.
    for statement <- [
          "ALTER TABLE #{p}.elzoo_metering_observations NO FORCE ROW LEVEL SECURITY",
          "DROP POLICY elzoo_tenant_floor ON #{p}.elzoo_metering_observations"
        ] do
      assert H.denied?(sql(statement)), statement
    end

    # A later correction moves the cut call into known.
    cut = H.usage_id(b, H.occurrence(b, "call-2"), "attempt", :output_tokens)

    assert Metering.correct(fx.meter, "T1", %{
             correction_id: "late:" <> cut,
             usage_id: cut,
             amount: 10_000,
             reason: "provider reported late",
             actor_ref: "svc:metering"
           }) == {:ok, :applied}

    assert {:output_tokens, :unknown, 10_000, 0, 1} in totals.()
    refute {:output_tokens, :unknown, 0, 1, 1} in totals.()

    assert %{current: ^role, super: false, bypass: false, inherits_owner: false} =
             H.role_facts(AppRepo)
  end

  # ------------------------------------------------------------ 2

  test "2 allowance: entitlement resolves, the host gate denies an absent feature, reserve by run_id is the Budget cap, duplicate holds once, a race starts one, unknown stays held, grace",
       %{fx: fx, role: role} do
    facts = %{
      plans: [H.plan(["agents.nested", "model.chat"], 100_000)],
      grants: [
        H.grant("g-t1", "T1"),
        H.grant("g-t2", "T2", %{valid_to_ms: @now + 60_000, grace_until_ms: @now + 120_000})
      ]
    }

    assert {:entitled, r1} = Entitlement.resolve(facts, "T1", @now)
    assert Entitlement.feature(r1, "model.chat") == :allow
    assert Entitlement.feature(r1, "tools.web") == {:deny, :feature_absent}
    gate = H.feature_gate(r1)

    # Each Run is admitted by the host: reserved by its run_id before it starts, the reserved
    # estimate its Budget cap.
    prepare = fn tenant, requests, cap -> H.prepare_run(tenant, requests, cap: cap, gate: gate) end

    # G: a tool call needs tools.web, which the plan lacks: the host gate denies it on a live Run.
    g =
      admitted!(
        fx,
        prepare.("T1", [TestHelper.request([TestHelper.action("search", "tool_call")])], 30_000),
        r1
      )

    # A retried reserve of one Run is :duplicate and holds its estimate once.
    assert H.reserve_run(fx, g, r1) == {:ok, :duplicate}
    assert %{reserved: 30_000, committed: 0} = H.status(fx, "T1", r1)

    TestHelper.wait_for(g.engine, &(&1.slots[{1, 0}].phase == :settled))

    assert %{
             outcome: "refused",
             verdict: %{verdict: :deny, reason: "feature_absent", gate_id: "entitlement-gate"}
           } = TestHelper.view(g.engine).slots[{1, 0}]

    refute_receive {:effect_started, _, _}, 200
    assert H.committed_actual(g) == 0
    assert H.settle_run(fx, g) == {:ok, :applied}

    # A: settled with the Run's committed actual.
    a = admitted!(fx, prepare.("T1", completed_requests(), 30_000), r1)
    :ok = H.serve!(fx, a, "call-1", H.usage(3_000, 12_000))
    completed!(a)
    assert H.committed_actual(a) == 12_000
    assert H.settle_run(fx, a) == {:ok, :applied}
    assert %{committed: 12_000, reserved: 0} = H.status(fx, "T1", r1)

    # B: its second call is cut off by a restart; its actual is unknown and stays held.
    {_, restart} = cut_run(fx, prepare.("T1", cut_requests(), 30_000), H.usage(2_000, 8_000), r1)
    b = restart.()
    H.meter_run!(fx, b)
    assert H.committed_actual(b) == :unknown

    held = %{committed: 12_000, held: 30_000, reserved: 0, remaining: 58_000}
    assert Map.take(H.status(fx, "T1", r1), Map.keys(held)) == held

    # Across a restart of the application connection the unit stays held.
    H.stop!(AppRepo)
    H.start_app!(role)
    H.role_guard!(role)
    assert Map.take(H.status(fx, "T1", r1), Map.keys(held)) == held

    # The metering correction gives the actual; reconcile/3 with basis: :metering ends the hold.
    occurrence = H.occurrence(b, "call-2")

    for {unit, amount} <- [input_uncached_tokens: 1_000, output_tokens: 10_000] do
      id = H.usage_id(b, occurrence, "attempt", unit)

      assert {:ok, :applied} =
               Metering.correct(fx.meter, "T1", %{
                 correction_id: "late:" <> id,
                 usage_id: id,
                 amount: amount,
                 reason: "provider reported late",
                 actor_ref: "svc:metering"
               })
    end

    actual =
      Enum.sum(
        for occ <- [H.occurrence(b, "call-1"), occurrence] do
          {:ok, %{effective: e}} =
            Metering.observation(fx.meter, "T1", H.usage_id(b, occ, "attempt", :output_tokens))

          e
        end
      )

    assert actual == 18_000

    assert Quota.reconcile(fx.quota, "T1", %{
             run_id: b.key,
             unit: :output_tokens,
             actual: actual,
             basis: :metering,
             actor_ref: "svc:metering",
             reason: "metering correction"
           }) == {:ok, :applied}

    assert %{committed: 30_000, held: 0, remaining: 70_000} = H.status(fx, "T1", r1)

    # Two Runs race behind a held counter lock for the last allowance: exactly one starts.
    racers = for _ <- 1..2, do: prepare.("T1", completed_requests(), 40_000)
    holder = H.hold!(fx, "T1")
    tasks = for run <- racers, do: Task.async(fn -> {run, H.reserve_run(fx, run, r1)} end)
    H.await_waiting!(holder, 2)
    H.release!(holder)

    admitted =
      for {run, reserved} <- Task.await_many(tasks, 30_000), do: H.start_admitted(run, reserved)

    assert [{:started, winner}] = Enum.filter(admitted, &match?({:started, _}, &1))
    assert [{:refused, {:error, :insufficient}}] = admitted -- [{:started, winner}]
    assert %{reserved: 40_000, remaining: 30_000} = H.status(fx, "T1", r1)
    :ok = H.serve!(fx, winner, "call-1", H.usage(1_000, 5_000))
    completed!(winner)
    # The refused Run never started: no second call was dispatched.
    refute_receive {:effect_started, _, _}, 200
    assert H.settle_run(fx, winner) == {:ok, :applied}
    assert %{committed: 35_000, reserved: 0, remaining: 65_000} = H.status(fx, "T1", r1)

    # Grace refuses a new reservation and accepts a settlement.
    assert {:entitled, e2} = Entitlement.resolve(facts, "T2", @now)

    t2_gate = H.feature_gate(e2)
    t2 = admitted!(fx, H.prepare_run("T2", completed_requests(), cap: 30_000, gate: t2_gate), e2)
    :ok = H.serve!(fx, t2, "call-1", H.usage(1_000, 4_000))
    completed!(t2)

    later = @now + 90_000
    assert {:grace, g2} = Entitlement.resolve(facts, "T2", later)
    next = H.prepare_run("T2", completed_requests(), cap: 30_000, gate: t2_gate)
    assert H.admit(fx, next, g2, later) == {:refused, {:error, :settle_only}}
    assert H.settle_run(fx, t2) == {:ok, :applied}
    assert %{settle_only: true, committed: 4_000, reserved: 0} = H.status(fx, "T2", g2)
  end

  # ------------------------------------------------------------ 3

  test "3 price and post: an incomplete charge is held, the corrected complete charge posts once, card v2 leaves it equal, a correction posts its difference, an equal re-price posts nothing",
       %{fx: fx} do
    H.open_accounts!(fx, "T1", [{"receivable", true}, {"revenue", true}])
    a = completed_run(fx, "T1", H.usage(3_000, 12_000))
    {_, restart} = cut_run(fx, "T1", H.usage(2_000, 8_000))
    b = restart.()
    H.meter_run!(fx, a)
    H.meter_run!(fx, b)
    v1 = H.card(1, "3", "15")
    cards = %{:current => v1, {"retail", 1} => v1}

    # While an observation of the period is unknown the charge is incomplete: the host holds it.
    assert {:held, held} = H.bill(fx, "T1", cards)
    assert held.incomplete and held.unknown_count == 2
    # 5,000 input tokens at 3/M is 1.5 cents, half-even 2; 20,000 output tokens at 15/M is 30.
    assert held.total.minor_units == 32
    assert H.operations(fx, "T1") == []

    # The provider reports the cut call late; correct/3 makes it known.
    for {unit, amount} <- [input_uncached_tokens: 1_000, output_tokens: 10_000] do
      id = H.usage_id(b, H.occurrence(b, "call-2"), "attempt", unit)

      assert {:ok, :applied} =
               Metering.correct(fx.meter, "T1", %{
                 correction_id: "late:" <> id,
                 usage_id: id,
                 amount: amount,
                 reason: "provider reported late",
                 actor_ref: "svc:metering"
               })
    end

    # The re-priced complete charge is the period's first posted charge: 6,000 input is 1.8
    # cents, 2; 30,000 output is 45. The first post's reply is lost.
    first = %{operation_id: "charge/T1/2026-11/retail/1", reason: "charge T1 2026-11"}
    assert {:lost, lost} = H.bill(fx, "T1", cards, crash: :after_post)
    assert Map.take(lost, [:operation_id, :reason]) == first
    assert lost.amount.minor_units == 47

    # Card version 2 is published before the retry and would price the period at 62. The retry
    # replays the retained pending post unchanged: one operation, 47 in total.
    v2 = H.card(2, "4", "20")
    cards = Map.merge(cards, %{:current => v2, {"retail", 2} => v2})
    assert {:ok, %{total: %{minor_units: 62}}} = Pricing.price(v2, H.usage_value(fx, "T1"))
    assert {:posted, ^lost, {:ok, :duplicate}} = H.bill(fx, "T1", cards)
    assert H.operations(fx, "T1") == [["T1", "charge/T1/2026-11/retail/1", "charge T1 2026-11"]]
    assert H.balance(fx, "T1", "receivable") == -47
    assert H.balance(fx, "T1", "revenue") == 47

    # With version 2 current, the host re-prices under the posted charge's own card version:
    # the charge stays equal and posts nothing.
    assert {:unchanged, same} = H.bill(fx, "T1", cards)
    assert {same.card.version, same.total.minor_units} == {1, 47}

    # A correction of a known observation of the posted period: re-priced under version 1, its
    # difference after rounding is nonzero and posts as a new operation from the correction.
    correction = fn run, occurrence, id, amount ->
      c = %{
        correction_id: id,
        usage_id: H.usage_id(run, occurrence, "attempt", :output_tokens),
        amount: amount,
        reason: "usage dispute",
        actor_ref: "operator:billing"
      }

      assert Metering.correct(fx.meter, "T1", c) == {:ok, :applied}
      c
    end

    dispute1 = correction.(a, {1, 0}, "dispute-1", 14_000)
    assert {:posted, posted, {:ok, :applied}} = H.bill(fx, "T1", cards, correction: dispute1)

    assert Map.take(posted, [:operation_id, :reason]) == %{
             operation_id: "charge-correction/T1/2026-11/dispute-1",
             reason: "correction dispute-1: usage dispute"
           }

    assert posted.amount.minor_units == 3
    assert H.balance(fx, "T1", "receivable") == -50

    # A second correction that leaves the rounded charge equal to the baseline (47 + 3) posts
    # nothing: 32,100 output tokens is 48.15 cents, 48, as before.
    dispute2 = correction.(b, H.occurrence(b, "call-1"), "dispute-2", 8_100)
    assert {:unchanged, again} = H.bill(fx, "T1", cards, correction: dispute2)
    assert {again.card.version, again.total.minor_units} == {1, 50}

    assert H.operations(fx, "T1") == [
             [
               "T1",
               "charge-correction/T1/2026-11/dispute-1",
               "correction dispute-1: usage dispute"
             ],
             ["T1", "charge/T1/2026-11/retail/1", "charge T1 2026-11"]
           ]

    assert H.balance(fx, "T1", "receivable") == -50
    assert H.balance(fx, "T1", "revenue") == 50
  end

  # ------------------------------------------------------------ 4

  test "4 see: the transcript of a completed nested T1 Run shows its tree, T2's scope is refused, the restarted Run shows its Effect unknown with no actual",
       %{fx: fx} do
    run =
      H.prepare_run(
        "T1",
        [
          TestHelper.request([TestHelper.action("nested", "nested_callable")]),
          TestHelper.request([H.finish("nested")])
        ],
        nested: %{
          "nested" => [
            TestHelper.request([H.model_call("inner-call")]),
            {:finish_with_seen, "child-done"}
          ]
        },
        gate: gate(fx, "T1")
      )
      |> then(&admitted!(fx, &1, fx.resolutions["T1"]))

    :ok = H.serve!(fx, run, "inner-call", H.usage(1_000, 9_000))
    completed!(run)
    assert H.committed_actual(run) == 9_000
    assert H.settle_run(fx, run) == {:ok, :applied}
    assert {:ok, %{run_id: "run", entries: entries}} = H.transcript(run)

    tree =
      for %{type: :action} = e <- entries, do: {e.occurrence, e.path, e.kind, e.action_id}

    assert tree == [
             {{1, 0}, [], "nested_callable", "nested"},
             {{2, 0}, [{1, 0}], "model_call", "inner-call"},
             {{3, 0}, [{1, 0}], "finish", "child-done"},
             {{4, 0}, [], "finish", "finish"}
           ]

    assert [%{occurrence: {1, 0}}] = Enum.filter(entries, &(&1.type == :nested_start))
    assert [%{occurrence: {1, 0}}] = Enum.filter(entries, &(&1.type == :nested_finish))

    assert %{path: [{1, 0}], outcome: "completed", actual: 9_000} =
             Enum.find(entries, &(&1.type == :settlement and &1.action_id == "inner-call"))

    assert List.last(entries) |> Map.take([:type, :outcome]) == %{
             type: :terminal,
             outcome: :completed
           }

    assert H.transcript(run, "T2") == {:error, :scope}

    {_, restart} = cut_run(fx, "T1", H.usage(2_000, 8_000))
    b = restart.()
    cut = H.occurrence(b, "call-2")
    assert {:ok, %{entries: b_entries}} = H.transcript(b)

    assert [%{outcome: "unknown", actual: :unknown, path: []}] =
             Enum.filter(b_entries, &(&1.type == :settlement and &1.occurrence == cut))

    refute Enum.any?(b_entries, &(&1.type == :actual and &1.occurrence == cut))
  end

  # ------------------------------------------------------------ 5

  test "5 failures: a Relay over a page of permanently failing items stores each with put/3, delivers the later items; a stored failure is replayed and resolved once",
       %{fx: fx} do
    outbox = H.jobs_outbox!(fx, 5)
    delivered = :ets.new(:delivered, [:public, :duplicate_bag])
    permanent? = &(&1.payload in ~w(item-1 item-2 item-3))

    handle = fn item ->
      if permanent?.(item) do
        {:ok, _} =
          DeadLetterStore.put(fx.dls, "T1", %{
            source: "jobs",
            record: H.failure_record(item.idempotency_key),
            work_ref: item.payload,
            at_ms: @now
          })
      else
        :ets.insert(delivered, {item.payload})
      end

      :done
    end

    {:ok, relay} =
      Relay.start_link(
        store: outbox,
        stream: "jobs/r",
        handle: handle,
        limit: 3,
        interval_ms: :manual
      )

    assert {:ok, %{acked: [_, _, _], skipped: []}} = Relay.run_once(relay)
    assert {:ok, %{acked: [_, _], skipped: []}} = Relay.run_once(relay)
    assert H.jobs_pending(outbox) == []
    assert Enum.sort(:ets.tab2list(delivered)) == [{"item-4"}, {"item-5"}]

    {:ok, %{entries: open, next: nil}} =
      DeadLetterStore.list(fx.dls, "T1", %{source: "jobs", after: nil, limit: 10})

    assert Enum.map(open, & &1.work_ref) == ~w(item-1 item-2 item-3)
    assert {:ok, [%{source: "jobs", open: 3}]} = DeadLetterStore.count(fx.dls, "T1")
    assert DeadLetterStore.count(fx.dls, "T2") == {:ok, []}

    # The host replays the first failure from its own work reference, then resolves it once.
    [first | _] = open
    :ets.insert(delivered, {first.work_ref})

    resolve = fn resolution, actor ->
      DeadLetterStore.resolve(fx.dls, "T1", %{
        source: "jobs",
        message_id: first.message_id,
        resolution: resolution,
        actor_ref: actor,
        at_ms: @now + 1
      })
    end

    assert resolve.(:replayed, "operator:ops") == {:ok, :applied}
    assert resolve.(:replayed, "operator:ops") == {:ok, :duplicate}
    assert resolve.(:discarded, "operator:other") == {:error, :already_resolved}
    assert {:ok, [%{source: "jobs", open: 2}]} = DeadLetterStore.count(fx.dls, "T1")
    assert Enum.count(:ets.tab2list(delivered), &(&1 == {"item-1"})) == 1
  end

  # ------------------------------------------------------------ 6

  test "6 audit capture: the allowance grant and a manual credit as checked commands with state/audit-log bound; one Carbonite transaction per appended record, a denial alone; command first, then effect",
       %{fx: fx, p: p, role: role} do
    # The audit roles check: no TRUNCATE, no audit-schema privilege, no Store table owned by the
    # application role; both definer functions owned by the non-superuser audit owner.
    assert H.audit_facts(fx, role) == %{
             app_truncate: false,
             app_owns_store_table: false,
             app_audit_schema: false,
             app_audit_tables: false,
             owner_superuser: false,
             definers: [
               ["capture_changes", true, "elzoo_test", false],
               ["elzoo_attribute", true, "elzoo_test", false]
             ],
             pool: DBConnection.ConnectionPool
           }

    assert AuditLog.verify(OwnerRepo, p, fx.audit) == :ok

    # Actors are principals verified from API keys; the host's authorization verdict for each
    # command is the permission their membership gives at the tenant's space.
    people =
      H.principals!([
        {"t1-admin", "T1"},
        {"t1-finance", "T1"},
        {"t1-support", "T1"},
        {"t2-admin", "T2"}
      ])

    members =
      H.membership_facts([
        {"t1-admin", "t1-home", "billing-admin"},
        {"t1-finance", "t1-home", "finance"},
        {"t1-support", "t1-home", "support"},
        {"t2-admin", "t2-home", "billing-admin"}
      ])

    verdict = fn id, permission -> H.verdict(people[id], "t1-home", permission, members) end
    assert verdict.("t1-admin", "billing.grant") == :allow
    assert verdict.("t1-support", "billing.grant") == :deny
    assert verdict.("t2-admin", "billing.grant") == :deny

    assert Elzoo.Membership.permissions(people["t2-admin"], "t1-home", members, H.now_s()) ==
             {:error, :cross_tenant}

    assert verdict.("t1-finance", "billing.credit") == :allow

    plan = H.plan(["model.chat"], 100_000)
    grant = H.grant_descriptor()

    grant_payload = %{
      "grant_id" => "g-t1",
      "plan_id" => "team",
      "version" => 1,
      "valid_from_ms" => @now - 1_000
    }

    resolve = fn ->
      fields = H.resource(fx, grant, "T1", "t1-admin", "plan-grant")
      Entitlement.resolve(%{plans: [plan], grants: H.grants_from("T1", fields)}, "T1", @now)
    end

    assert resolve.() == {:not_entitled, :no_grant}

    # An authorization denial is retained as a record: no write, no outbox item, no effect.
    assert {:denied, {:authorization, _}} =
             H.command(
               fx,
               grant,
               "T1",
               "t1-support",
               "grant-1-denied",
               "plan-grant",
               grant_payload,
               verdict: verdict.("t1-support", "billing.grant")
             )

    assert resolve.() == {:not_entitled, :no_grant}

    # The allowance grant writes the host's plan grant in the command's resource; the next
    # reservation sees the new allowance. domain/quota has no grant write.
    assert {:completed, %{revision: 1}} =
             H.command(fx, grant, "T1", "t1-admin", "grant-1", "plan-grant", grant_payload,
               verdict: verdict.("t1-admin", "billing.grant")
             )

    assert {:entitled, resolution} = resolve.()
    assert {:ok, :applied} = H.reserve(fx, "T1", "run-after-grant", 30_000, resolution)
    assert %{amount: 100_000, reserved: 30_000} = H.status(fx, "T1", resolution)

    # The manual credit is command first, then effect.
    H.open_accounts!(fx, "T1", [{"wallet", false}, {"credits-granted", true}])
    credit = H.credit_descriptor()

    assert {:completed, _} =
             H.command(
               fx,
               credit,
               "T1",
               "t1-admin",
               "credit-1",
               "credit-1",
               %{"account_id" => "wallet", "minor_units" => 500},
               verdict: verdict.("t1-admin", "billing.credit")
             )

    assert [%{payload: payload}] = H.pending(fx, "T1", "journal-credits")
    assert %{"operation_id" => "credit-1", "resource" => "credit-1"} = Jason.decode!(payload)

    # A crash after the post and before the acknowledgement: the retried apply replays.
    assert_raise RuntimeError, fn -> H.apply_credits(fx, "T1", crash: :after_post) end
    assert H.balance(fx, "T1", "wallet") == 500
    assert length(H.pending(fx, "T1", "journal-credits")) == 1
    assert H.apply_credits(fx, "T1") == [{"credit-1", {:ok, :duplicate}}]

    # The credit's resource is written once: a second command on it is refused, so the apply
    # reads exactly the data of the command that queued the item.
    assert {:conflict, {:domain, "immutable"}} =
             H.command(
               fx,
               credit,
               "T1",
               "t1-admin",
               "credit-1-edit",
               "credit-1",
               %{"account_id" => "wallet", "minor_units" => 9_000},
               verdict: verdict.("t1-admin", "billing.credit")
             )

    # A crash between the commit and the apply: the worker that committed the command is killed
    # before its apply. A fresh worker finds the item pending and the balance unchanged, and
    # posts it once.
    parent = self()

    worker =
      spawn(fn ->
        result =
          H.command(
            fx,
            credit,
            "T1",
            "t1-finance",
            "credit-2",
            "credit-2",
            %{"account_id" => "wallet", "minor_units" => 300},
            verdict: verdict.("t1-finance", "billing.credit")
          )

        send(parent, {:committed, self(), result})
        receive do: (:apply -> H.apply_credits(fx, "T1"))
      end)

    assert_receive {:committed, ^worker, {:completed, _}}, 10_000
    ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    assert H.balance(fx, "T1", "wallet") == 500
    assert length(H.pending(fx, "T1", "journal-credits")) == 1
    fresh = Task.async(fn -> H.apply_credits(fx, "T1") end)
    assert Task.await(fresh, 30_000) == [{"credit-2", {:ok, :applied}}]
    assert H.apply_credits(fx, "T1") == []
    assert H.balance(fx, "T1", "wallet") == 800

    # An apply whose post is not applied leaves the item pending: no acknowledgement.
    assert {:completed, _} =
             H.command(
               fx,
               credit,
               "T1",
               "t1-admin",
               "credit-3",
               "credit-3",
               %{"account_id" => "bonus", "minor_units" => 200},
               verdict: verdict.("t1-admin", "billing.credit")
             )

    assert H.apply_credits(fx, "T1") == [{"credit-3", {:error, :unknown_account}}]
    assert length(H.pending(fx, "T1", "journal-credits")) == 1
    H.open_accounts!(fx, "T1", [{"bonus", false}])
    assert H.apply_credits(fx, "T1") == [{"credit-3", {:ok, :applied}}]
    assert H.pending(fx, "T1", "journal-credits") == []
    assert H.balance(fx, "T1", "bonus") == 200

    assert [%{operation_id: "credit-1"}, %{operation_id: "credit-2"}] =
             H.history(fx, "T1", "wallet")

    # One Carbonite transaction per command that appended a record, with its actor attribution.
    {:ok, audited} = AuditLog.read(OwnerRepo, fx.audit, stream: H.stream("T1"), limit: 100)

    assert Enum.map(audited, &{&1.actor, &1.action}) == [
             {"t1-support", "allowance/grant"},
             {"t1-admin", "allowance/grant"},
             {"t1-admin", "journal/credit"},
             {"t1-admin", "journal/credit"},
             {"t1-finance", "journal/credit"},
             {"t1-admin", "journal/credit"}
           ]

    assert H.log_records(fx, "T1") == 6

    for {transaction, sequence} <- Enum.with_index(audited, 1) do
      assert [%{op: "insert", table: {^p, "elzoo_log_records"}, sequence: ^sequence}] =
               transaction.changes
    end

    # The denial's and the refused edit's records have no outbox item; each credit record has one.
    assert H.owner!(
             "SELECT sequence, destination, state FROM #{p}.elzoo_outbox WHERE stream = $1 ORDER BY sequence",
             [H.stream("T1")]
           ) == [
             [3, "journal-credits", "acked"],
             [5, "journal-credits", "acked"],
             [6, "journal-credits", "acked"]
           ]

    # The application role cannot read the audit log, and the journal, quota and metering tables
    # carry no capture trigger (a stated limit).
    assert AuditLog.read(AppRepo, fx.audit, limit: 1) == {:error, :insufficient_privilege}

    assert H.owner!(
             "SELECT c.relname::text FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = $1) AND NOT t.tgisinternal ORDER BY 1",
             [p]
           )
           |> Enum.uniq() == [["elzoo_log_records"]]
  end

  # ------------------------------------------------------------ 7

  describe "7 plan types" do
    defp t2_observations(fx, run_id, input, output) do
      for {unit, amount} <- [input_uncached_tokens: input, output_tokens: output] do
        assert {:ok, :applied} =
                 Metering.record(fx.meter, "T2", %{
                   usage_id: "#{run_id}/1.0/attempt/#{unit}",
                   run_id: run_id,
                   operation_id: "call-1",
                   attempt_id: "attempt",
                   provider_id: "scripted",
                   model_id: "model-a",
                   unit: unit,
                   amount: amount,
                   source: :provider_reported,
                   period: @period,
                   observed_at_ms: @now
                 })
      end
    end

    defp t2_charge(fx) do
      {:ok, charge} = Pricing.price(H.card(1, "3", "15"), H.usage_value(fx, "T2"))
      refute charge.incomplete
      charge
    end

    test "pay-as-you-go: metering, pricing and a post from a receivable account to revenue",
         %{fx: fx} do
      H.open_accounts!(fx, "T2", [{"receivable", true}, {"revenue", true}])
      t2_observations(fx, "t2-run-1", 10_000, 50_000)
      # 10,000 input at 3/M is 3 cents; 50,000 output at 15/M is 75.
      assert {:posted, op, {:ok, :applied}} = H.bill(fx, "T2", %{current: H.card(1, "3", "15")})
      assert op.amount.minor_units == 78
      assert {H.balance(fx, "T2", "receivable"), H.balance(fx, "T2", "revenue")} == {-78, 78}
      assert H.operations(fx, "T2") == [["T2", "charge/T2/2026-11/retail/1", "charge T2 2026-11"]]
    end

    test "quota-capped: entitlement, quota and metering, with no charge", %{fx: fx} do
      facts = %{plans: [H.plan(["model.chat"], 100_000)], grants: [H.grant("g-t2", "T2")]}
      assert {:entitled, resolution} = Entitlement.resolve(facts, "T2", @now)

      run =
        H.prepare_run("T2", completed_requests(), cap: 30_000, gate: H.feature_gate(resolution))

      run = admitted!(fx, run, resolution)
      :ok = H.serve!(fx, run, "call-1", H.usage(3_000, 12_000))
      completed!(run)
      assert results(H.meter_run!(fx, run)) == [{:ok, :applied}, {:ok, :applied}]
      assert H.settle_run(fx, run) == {:ok, :applied}
      assert %{committed: 12_000, remaining: 88_000} = H.status(fx, "T2", resolution)

      assert {:ok, %{effective: 12_000}} =
               Metering.observation(
                 fx.meter,
                 "T2",
                 H.usage_id(run, H.occurrence(run, "call-1"), "attempt", :output_tokens)
               )

      # No charge: no journal operation at all under T2's scope.
      assert H.operations(fx, "T2") == []
    end

    test "prepaid: a top-up to a no-negative wallet and charges against it; an overdraw is insufficient_funds and leaves the balance",
         %{fx: fx} do
      H.open_accounts!(fx, "T2", [{"wallet", false}, {"topups", true}, {"revenue", true}])

      assert H.transfer(fx, "T2", "topup-1", "top-up", "wallet", "topups", H.money(100)) ==
               {:ok, :applied}

      t2_observations(fx, "t2-run-1", 10_000, 50_000)
      charge = t2_charge(fx)

      assert H.transfer(fx, "T2", H.charge_id(charge), "charge", "revenue", "wallet", charge.total) ==
               {:ok, :applied}

      assert H.balance(fx, "T2", "wallet") == 22

      assert H.transfer(
               fx,
               "T2",
               H.charge_id(charge) <> "/again",
               "charge",
               "revenue",
               "wallet",
               charge.total
             ) ==
               {:error, :insufficient_funds}

      assert H.balance(fx, "T2", "wallet") == 22
      assert H.balance(fx, "T2", "revenue") == 78
    end
  end

  # ------------------------------------------------------------ 8

  # The host's spend check: when committed and held use crosses the threshold, one checked
  # command with one outbox notice under the operation ID (tenant, period, threshold).
  defp spend_check(fx, resolution, threshold) do
    row = H.status(fx, "T1", resolution)

    if (row.committed + row.held) * 100 >= row.amount * threshold do
      H.command(
        fx,
        H.alert_descriptor(),
        "T1",
        "quota-monitor",
        "spend-alert/T1/#{@period}/#{threshold}",
        "spend-alert/#{@period}/#{threshold}",
        %{"period" => @period, "threshold" => threshold},
        expected_revision: 0
      )
    else
      :below
    end
  end

  test "8 spend alert: crossing a host threshold commits one checked command with one outbox notice; a second check commits none",
       %{fx: fx} do
    facts = %{plans: [H.plan(["model.chat"], 100_000)], grants: [H.grant("g-t1", "T1")]}
    {:entitled, resolution} = Entitlement.resolve(facts, "T1", @now)

    assert {:ok, :applied} = H.reserve(fx, "T1", "run-1", 50_000, resolution)
    assert H.settle(fx, "T1", "run-1", 50_000) == {:ok, :applied}
    assert spend_check(fx, resolution, 80) == :below
    assert H.log_records(fx, "T1") == 0

    # run-2 settles unknown: its 30,000 stay held. Committed and held use is 80,000, exactly the
    # threshold; committed use alone (50,000) would not cross it.
    assert {:ok, :applied} = H.reserve(fx, "T1", "run-2", 30_000, resolution)
    assert H.settle(fx, "T1", "run-2", :unknown) == {:ok, :applied}
    assert %{committed: 50_000, held: 30_000} = H.status(fx, "T1", resolution)
    assert {:completed, _} = first = spend_check(fx, resolution, 80)
    assert H.log_records(fx, "T1") == 1

    assert [%{payload: payload}] = notices = H.pending(fx, "T1", "spend-alerts")
    assert %{"operation_id" => "spend-alert/T1/2026-11/80"} = Jason.decode!(payload)

    # A second check of the same crossing replays the first result and commits nothing.
    assert spend_check(fx, resolution, 80) == first
    assert H.log_records(fx, "T1") == 1
    # The notice is committed, not sent: it stays pending.
    assert H.pending(fx, "T1", "spend-alerts") == notices
  end

  # ------------------------------------------------------------ 9

  test "9 eval: load/4 reads the dataset artifact and run/2 passes it; a changed recipe package fails its case",
       %{fx: fx} do
    art = H.artifact!(fx)
    caller = Elzoo.Artifact.TestHelper.caller("T1")
    id = "wave6-eval-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    bytes = H.eval_dataset()
    assert {:ok, _} = Elzoo.Artifact.put(art, caller, id, Elzoo.Artifact.TestHelper.input(bytes))
    # Runs before the fixture's schema cleanup: the object leaves MinIO too.
    on_exit(fn ->
      assert {:ok, %{object: object}} = Elzoo.Artifact.delete(art, caller, id, 1)
      assert object in [:deleted, :absent]
    end)

    assert {:ok, dataset} = Eval.load(art, caller, id, :head)

    sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    passing = Eval.run(dataset, H.eval_base())
    assert passing.dataset == %{dataset_id: "wave6-eval", version: 1, sha256: sha}
    assert {passing.passed, passing.failed, passing.errored} == {1, 0, 0}

    changed = Eval.run(dataset, H.eval_base(swap: true))
    assert changed.package != passing.package
    assert {changed.passed, changed.failed, changed.errored} == {0, 1, 0}
    assert [%{case_id: "chooses-yes", status: :failed}] = changed.cases
  end
end
