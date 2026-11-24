# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/payment_lifecycle_test_helper.exs", __DIR__)

defmodule Elzoo.PaymentLifecycleTest do
  # The cases share one database server, one scripted provider and hold row locks across
  # connections: not async.
  use ExUnit.Case, async: false
  alias Elzoo.DurableLog.Memory
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.Money
  alias Elzoo.PaymentLifecycle, as: PL

  alias Elzoo.PaymentLifecycleTest.{
    AppRepo,
    ChargeBinding,
    Harness,
    OwnerRepo,
    RefundBinding,
    RepeatableRepo,
    Script
  }

  alias Elzoo.TenantIsolation, as: TI

  @moduletag :capture_log
  @ok_succeeded {:ok, %{provider_ref: "ch_1", state: :succeeded}}

  setup_all do
    if Enum.any?([OwnerRepo, AppRepo, RepeatableRepo, Script], &Process.whereis/1),
      do: raise("the payment lifecycle test processes are already running")

    role = Harness.start_repos!()
    Script.start!()

    on_exit(fn ->
      Script.stop!()
      Enum.each([OwnerRepo, AppRepo, RepeatableRepo], &Harness.stop!/1)
    end)

    {:ok, role: role}
  end

  setup %{role: role} do
    p = Harness.install!(role)
    Script.reset!()
    on_exit(fn -> Harness.drop!(p) end)
    {:ok, lc} = new(AppRepo, p)
    intents = start_supervised!({Task.Supervisor, []})
    {:ok, p: p, lc: lc, intents: intents}
  end

  # ------------------------------------------------------------ fixtures

  defp new(repo, p),
    do:
      PL.new(
        repo: repo,
        prefix: p,
        provider: Script,
        provider_account: "acct-1",
        deadline_ms: 600_000,
        clock: fn -> System.os_time(:millisecond) end
      )

  defp money(alpha, units) do
    {:ok, c} = Money.parse(alpha)
    {:ok, a} = Money.from_minor_units(c, units)
    a
  end

  defp eur(units), do: money("EUR", units)

  defp create!(lc, id, units \\ 100, tenant \\ "T1") do
    {:ok, :applied} =
      PL.create(lc, tenant, %{
        payment_id: id,
        approved: %{amount: eur(units), recipient: "merchant-1"},
        approval_ref: "approval-" <> id
      })
  end

  defp charge(lc, id, units \\ 100, recipient \\ "merchant-1", tenant \\ "T1"),
    do: PL.charge(lc, tenant, %{payment_id: id, amount: eur(units), recipient: recipient})

  defp event(lc, id, op, state, amount \\ {"EUR", 100}, ref \\ "ch_1", tenant \\ "T1"),
    do: PL.apply_event(lc, tenant, Script.event(id, op, state, amount, ref))

  # A succeeded payment, settled by a verified event (no intent).
  defp paid!(lc, id, units \\ 100) do
    create!(lc, id, units)
    {:ok, _} = charge(lc, id, units)

    {:ok, %{applied: true, state: :succeeded}} =
      event(lc, "ev-" <> id, {:charge, id}, :succeeded, {"EUR", units})

    :ok
  end

  defp record(lc, op, attempt, fallback \\ nil, tenant \\ "T1"),
    do: PL.record(lc, tenant, %{operation: op, attempt: attempt, fallback: fallback})

  defp comp(id), do: %{kind: :refund, payment_id: id, refund_id: "comp/charge", amount: :remaining}

  # The ready effect-intent owner over a volatile Memory Store, acknowledged for the tests.
  defp owner(ctx, binding, admission) do
    memory =
      start_supervised!({Memory, fold: Intent.fold(binding), limits: Intent.limits()},
        id: make_ref()
      )

    host =
      start_supervised!({Memory, fold: StoreHost.fold(), limits: StoreHost.limits()},
        id: make_ref()
      )

    {:ok, pid} =
      Intent.start_link(
        binding: binding,
        identity: admission.identity,
        arguments: admission.arguments,
        deadline: admission.deadline,
        clock: fn -> System.os_time(:millisecond) end,
        store: Memory.store(memory),
        host: {StoreHost, %{store: Memory.store(host), authorize: fn _, _ -> :fresh end}},
        task_supervisor: ctx.intents,
        adapter_context: ctx.lc,
        allow_volatile: true
      )

    pid
  end

  defp settled(pid, tries \\ 250) do
    cond do
      :sys.get_state(pid).tasks == %{} -> Intent.status(pid)
      tries == 0 -> flunk("attempt never settled")
      true -> Process.sleep(20) && settled(pid, tries - 1)
    end
  end

  defp run(pid, command) do
    assert {:ok, _} = Intent.advance(pid, command)
    settled(pid)
  end

  defp charge_intent(ctx, id) do
    {:ok, a} = charge(ctx.lc, id)
    {owner(ctx, ChargeBinding, a), a}
  end

  defp refund_intent(ctx, id, rid, amount) do
    {:ok, a} = PL.refund(ctx.lc, "T1", %{payment_id: id, refund_id: rid, amount: amount})
    {owner(ctx, RefundBinding, a), a}
  end

  defp observations(p, ref) do
    for [_, _, ^ref, seq, attempt, source, answer, state, applied] <- Harness.truth(p).observations,
        do: {seq, attempt, source, answer, state, applied}
  end

  defp payment(lc, id, tenant \\ "T1") do
    {:ok, %{payment: payment}} = PL.get(lc, tenant, %{payment_id: id})
    payment
  end

  defp refund_state(lc, id, rid) do
    {:ok, %{refunds: refunds}} = PL.get(lc, "T1", %{payment_id: id})
    Enum.find(refunds, &(&1.refund_id == rid))
  end

  # ------------------------------------------------------------ 1

  describe "1 RC-24 unknown outcomes reconciled" do
    test "a charge that times out is :unknown, a poll succeeded makes it :succeeded with the compensation",
         ctx do
      create!(ctx.lc, "p1")
      Script.script(:charge, [{:unknown, :timeout}])
      Script.script(:poll, [@ok_succeeded])
      {pid, a} = charge_intent(ctx, "p1")

      assert %{phase: {:Dispatched, :Fresh, 1}} = run(pid, :dispatch)
      assert record(ctx.lc, {:charge, "p1"}, 1) == {:ok, %{state: :unknown, compensation: nil}}

      assert %{phase: {:Confirmed, 1}} = run(pid, :poll)

      assert record(ctx.lc, {:charge, "p1"}, 1) ==
               {:ok, %{state: :succeeded, compensation: comp("p1")}}

      assert [%{idempotency_key: key}] = Script.calls(:charge)
      assert key == a.key
      assert [%{idempotency_key: ^key, kind: :charge}] = Script.calls(:poll)

      # The send answer and the poll answer of attempt 1: two rows, each applied once.
      assert observations(ctx.p, "p1/charge") == [
               {1, 1, "send", "unknown", nil, true},
               {2, 1, "poll", "ok", "succeeded", true}
             ]

      revision = payment(ctx.lc, "p1").revision

      assert record(ctx.lc, {:charge, "p1"}, 1) ==
               {:ok, %{state: :succeeded, compensation: comp("p1")}}

      assert {:ok, %{compensation: c, payment: %{state: :succeeded, provider_ref: "ch_1"} = pay}} =
               PL.get(ctx.lc, "T1", %{payment_id: "p1"})

      assert c == comp("p1")
      assert pay.revision == revision
      assert pay.refunded == eur(0)
    end

    test "a charge answered pending keeps the intent dispatched; a later poll succeeded settles it",
         ctx do
      create!(ctx.lc, "p1")
      Script.script(:charge, [{:ok, %{provider_ref: "ch_1", state: :pending}}])
      Script.script(:poll, [:pending, @ok_succeeded])
      {pid, _} = charge_intent(ctx, "p1")

      assert %{phase: {:Dispatched, :Fresh, 1}} = run(pid, :dispatch)
      assert record(ctx.lc, {:charge, "p1"}, 1) == {:ok, %{state: :pending, compensation: nil}}
      assert %{phase: {:Dispatched, :Fresh, 1}} = run(pid, :poll)
      assert %{phase: {:Confirmed, 1}} = run(pid, :poll)

      assert record(ctx.lc, {:charge, "p1"}, 1) ==
               {:ok, %{state: :succeeded, compensation: comp("p1")}}
    end

    test "a malformed poll answer is stored as unavailable and changes nothing", ctx do
      create!(ctx.lc, "p1")
      Script.script(:charge, [{:unknown, :timeout}])
      Script.script(:poll, [:garbage])
      {pid, _} = charge_intent(ctx, "p1")
      run(pid, :dispatch)
      assert %{phase: {:Dispatched, :Fresh, 1}} = run(pid, :poll)

      assert observations(ctx.p, "p1/charge") == [
               {1, 1, "send", "unknown", nil, false},
               {2, 1, "poll", "unavailable", nil, false}
             ]

      assert record(ctx.lc, {:charge, "p1"}, 1) == {:ok, %{state: :unknown, compensation: nil}}
    end

    test "observations recorded together keep the provider ref of a round trip to the same state",
         ctx do
      paid!(ctx.lc, "p1")
      Script.script(:refund, [{:unknown, :timeout}])
      Script.script(:poll, [{:ok, %{provider_ref: "re_42", state: :pending}}])
      {pid, _} = refund_intent(ctx, "p1", "r1", eur(10))
      run(pid, :dispatch)
      run(pid, :poll)

      assert record(ctx.lc, {:refund, "p1", "r1"}, 1) ==
               {:ok, %{state: :pending, compensation: comp("p1")}}

      assert %{state: :pending, provider_ref: "re_42"} = refund_state(ctx.lc, "p1", "r1")
    end

    test "a crash after the send with no observation stored: fallback :unknown makes it :unknown",
         ctx do
      create!(ctx.lc, "p1")
      Script.script(:charge, [:crash])
      {pid, _} = charge_intent(ctx, "p1")

      assert %{phase: {:Dispatched, :Fresh, 1}} = run(pid, :dispatch)
      assert observations(ctx.p, "p1/charge") == []
      # Without the fallback nothing is observed and nothing changes.
      assert record(ctx.lc, {:charge, "p1"}, 1) == {:ok, %{state: :pending, compensation: nil}}

      assert record(ctx.lc, {:charge, "p1"}, 1, :unknown) ==
               {:ok, %{state: :unknown, compensation: nil}}

      assert length(Script.calls(:charge)) == 1
    end

    test "a succeeded charge whose observation write fails stays dispatched, then a poll settles it",
         ctx do
      create!(ctx.lc, "p1")
      Script.script(:charge, [@ok_succeeded])
      Script.script(:poll, [@ok_succeeded])
      {pid, _} = charge_intent(ctx, "p1")

      Harness.refuse_observations!(ctx.p, ctx.role)
      status = run(pid, :dispatch)
      Harness.restore_observations!(ctx.p, ctx.role)

      # observation_unrecorded: unknown / dispatched, so the intent stays pollable.
      assert status.phase == {:Dispatched, :Fresh, 1}
      assert observations(ctx.p, "p1/charge") == []

      assert record(ctx.lc, {:charge, "p1"}, 1, :unknown) ==
               {:ok, %{state: :unknown, compensation: nil}}

      assert %{phase: {:Confirmed, 1}} = run(pid, :poll)

      assert record(ctx.lc, {:charge, "p1"}, 1) ==
               {:ok, %{state: :succeeded, compensation: comp("p1")}}

      assert length(Script.calls(:charge)) == 1
    end

    test "a completed poll answer whose write fails is the pending certificate; a later poll settles",
         ctx do
      create!(ctx.lc, "p1")
      Script.script(:charge, [{:unknown, :timeout}])
      Script.script(:poll, [@ok_succeeded, @ok_succeeded])
      {pid, _} = charge_intent(ctx, "p1")
      run(pid, :dispatch)

      Harness.refuse_observations!(ctx.p, ctx.role)
      assert %{phase: {:Dispatched, :Fresh, 1}} = run(pid, :poll)
      Harness.restore_observations!(ctx.p, ctx.role)

      assert record(ctx.lc, {:charge, "p1"}, 1) == {:ok, %{state: :unknown, compensation: nil}}
      assert %{phase: {:Confirmed, 1}} = run(pid, :poll)

      assert record(ctx.lc, {:charge, "p1"}, 1) ==
               {:ok, %{state: :succeeded, compensation: comp("p1")}}

      assert length(Script.calls(:charge)) == 1
    end

    test "a verified pending event before the first charge/3 still gives a startable admission",
         ctx do
      create!(ctx.lc, "p1")

      assert {:ok, %{applied: true, state: :pending}} =
               event(ctx.lc, "ev0", {:charge, "p1"}, :pending)

      assert {:ok, a} = charge(ctx.lc, "p1")
      assert is_integer(a.deadline)
      assert charge(ctx.lc, "p1") == {:ok, a}
      Script.script(:charge, [@ok_succeeded])
      pid = owner(ctx, ChargeBinding, a)
      assert %{phase: {:Confirmed, 1}} = run(pid, :dispatch)

      assert record(ctx.lc, {:charge, "p1"}, 1) ==
               {:ok, %{state: :succeeded, compensation: comp("p1")}}
    end
  end

  # ------------------------------------------------------------ 2

  test "2 a verified success event settles the row while the intent stays dispatched", ctx do
    create!(ctx.lc, "p1")
    Script.script(:charge, [{:ok, %{provider_ref: "ch_1", state: :pending}}])
    Script.script(:poll, [{:ok, %{provider_ref: "ch_other", state: :failed}}])
    {pid, _} = charge_intent(ctx, "p1")
    assert %{phase: {:Dispatched, :Fresh, 1}} = run(pid, :dispatch)
    assert record(ctx.lc, {:charge, "p1"}, 1) == {:ok, %{state: :pending, compensation: nil}}

    assert event(ctx.lc, "ev1", {:charge, "p1"}, :succeeded) ==
             {:ok, %{applied: true, state: :succeeded, compensation: comp("p1")}}

    assert Intent.status(pid).phase == {:Dispatched, :Fresh, 1}

    before = Harness.truth(ctx.p)

    assert record(ctx.lc, {:charge, "p1"}, 1) ==
             {:ok, %{state: :succeeded, compensation: comp("p1")}}

    assert Harness.truth(ctx.p) == before

    # A later poll result is recorded and changes nothing.
    run(pid, :poll)

    assert record(ctx.lc, {:charge, "p1"}, 1) ==
             {:ok, %{state: :succeeded, compensation: comp("p1")}}

    assert {2, 1, "poll", "ok", "failed", true} in observations(ctx.p, "p1/charge")
    assert %{state: :succeeded, provider_ref: "ch_1"} = payment(ctx.lc, "p1")
  end

  # ------------------------------------------------------------ 3

  describe "3 a dispatch after a definite failure keeps the idempotency key" do
    test "a not_sent send, then :rearm and :dispatch", ctx do
      create!(ctx.lc, "p1")
      Script.script(:charge, [{:not_sent, :connect_refused}, @ok_succeeded])
      {pid, a} = charge_intent(ctx, "p1")

      assert %{phase: {:Definite, :AdapterNoSend, 1}} = run(pid, :dispatch)
      assert {:ok, _} = Intent.advance(pid, :rearm)
      assert %{phase: {:Confirmed, 2}} = run(pid, :dispatch)

      assert [k1, k2] = Enum.map(Script.calls(:charge), & &1.idempotency_key)
      assert k1 == a.key and k2 == a.key

      # record/3 applies only rows of attempts up to the one it names.
      assert record(ctx.lc, {:charge, "p1"}, 1) == {:ok, %{state: :pending, compensation: nil}}
      assert {_, 2, "send", "ok", "succeeded", false} = List.last(observations(ctx.p, "p1/charge"))

      assert record(ctx.lc, {:charge, "p1"}, 2) ==
               {:ok, %{state: :succeeded, compensation: comp("p1")}}
    end

    test "a charge's poll :no_effect, then a new dispatch", ctx do
      create!(ctx.lc, "p1")
      Script.script(:charge, [{:unknown, :transport}, @ok_succeeded])
      Script.script(:poll, [:no_effect])
      {pid, a} = charge_intent(ctx, "p1")

      run(pid, :dispatch)
      assert %{phase: {:Definite, :ProviderNoEffect, 1}} = run(pid, :poll)
      # :no_effect changes nothing for a charge.
      assert record(ctx.lc, {:charge, "p1"}, 1) == {:ok, %{state: :unknown, compensation: nil}}
      assert {:ok, _} = Intent.advance(pid, :rearm)
      assert %{phase: {:Confirmed, 2}} = run(pid, :dispatch)

      assert [k1, k2] = Enum.map(Script.calls(:charge), & &1.idempotency_key)
      assert k1 == a.key and k2 == a.key
    end
  end

  test "3 a declined charge closes its intent: a :rearm and :dispatch after a poll :no_effect calls no provider",
       ctx do
    create!(ctx.lc, "p1")
    Script.script(:charge, [{:declined, "card_declined"}, @ok_succeeded])
    Script.script(:poll, [:no_effect])
    {pid, _} = charge_intent(ctx, "p1")
    run(pid, :dispatch)
    assert %{phase: {:Definite, :ProviderNoEffect, 1}} = run(pid, :poll)

    # The decline is stored and not yet applied; the gate reads it anyway.
    {:ok, _} = Intent.advance(pid, :rearm)
    status = run(pid, :dispatch)
    assert status.phase == {:Definite, :AdapterNoSend, 2} and status.flags.disarmed
    assert length(Script.calls(:charge)) == 1

    assert record(ctx.lc, {:charge, "p1"}, 2) == {:ok, %{state: :failed, compensation: nil}}
  end

  test "3 a charge settled :failed by an event closes its intent with no final observation stored",
       ctx do
    create!(ctx.lc, "p1")
    Script.script(:charge, [{:unknown, :timeout}, @ok_succeeded])
    Script.script(:poll, [:no_effect])
    {pid, _} = charge_intent(ctx, "p1")
    run(pid, :dispatch)

    assert {:ok, %{applied: true, state: :failed}} = event(ctx.lc, "ev-f", {:charge, "p1"}, :failed)

    assert %{phase: {:Definite, :ProviderNoEffect, 1}} = run(pid, :poll)
    {:ok, _} = Intent.advance(pid, :rearm)
    status = run(pid, :dispatch)
    assert status.phase == {:Definite, :AdapterNoSend, 2} and status.flags.disarmed
    assert length(Script.calls(:charge)) == 1
    assert payment(ctx.lc, "p1").state == :failed
  end

  # ------------------------------------------------------------ 4

  describe "4 refunds are serialized by the payment row lock" do
    test "two concurrent refunds that together pass the amount: one stored, one over_refund",
         ctx do
      paid!(ctx.lc, "p1")
      holder = Harness.hold!(ctx.p, "T1", "p1")

      tasks =
        for rid <- ["ra", "rb"] do
          Task.async(fn ->
            PL.refund(ctx.lc, "T1", %{payment_id: "p1", refund_id: rid, amount: eur(60)})
          end)
        end

      Harness.await_waiting!(2)
      Harness.release!(holder)
      results = Enum.map(tasks, &Task.await/1)

      assert Enum.count(results, &match?({:ok, %{key: _}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :over_refund})) == 1
      assert length(Harness.truth(ctx.p).refunds) == 1
      assert payment(ctx.lc, "p1").refunded == eur(60)
    end

    test "get/3 reads under the payment row lock, so a writer's rows are seen together", ctx do
      paid!(ctx.lc, "p1")
      holder = Harness.hold!(ctx.p, "T1", "p1")
      task = Task.async(fn -> PL.get(ctx.lc, "T1", %{payment_id: "p1"}) end)
      Harness.await_waiting!(1)
      Harness.release!(holder)
      assert {:ok, %{payment: %{state: :succeeded}}} = Task.await(task)
    end

    test "a pending and an unknown refund are held", ctx do
      paid!(ctx.lc, "p1")
      Script.script(:refund, [{:unknown, :timeout}])
      {:ok, _} = PL.refund(ctx.lc, "T1", %{payment_id: "p1", refund_id: "r1", amount: eur(30)})
      {pid, _} = refund_intent(ctx, "p1", "r2", eur(30))
      run(pid, :dispatch)

      assert record(ctx.lc, {:refund, "p1", "r2"}, 1) ==
               {:ok, %{state: :unknown, compensation: comp("p1")}}

      assert %{state: :pending} = refund_state(ctx.lc, "p1", "r1")
      assert payment(ctx.lc, "p1").refunded == eur(60)

      assert PL.refund(ctx.lc, "T1", %{payment_id: "p1", refund_id: "r3", amount: eur(41)}) ==
               {:error, :over_refund}

      assert {:ok, _} =
               PL.refund(ctx.lc, "T1", %{payment_id: "p1", refund_id: "r3", amount: eur(40)})

      assert PL.refund(ctx.lc, "T1", %{payment_id: "p1", refund_id: "r4", amount: :remaining}) ==
               {:error, :nothing_to_refund}
    end
  end

  # ------------------------------------------------------------ 5

  describe "5 events and attempts" do
    test "a duplicate event changes nothing and returns the compensation", ctx do
      paid!(ctx.lc, "p1")
      before = Harness.truth(ctx.p)

      assert event(ctx.lc, "ev-p1", {:charge, "p1"}, :succeeded) ==
               {:ok, %{duplicate: true, applied: true, state: :succeeded, compensation: comp("p1")}}

      assert Harness.truth(ctx.p) == before

      # The same event ID with other bytes is a conflict.
      assert event(ctx.lc, "ev-p1", {:charge, "p1"}, :succeeded, {"EUR", 100}, "ch_x") ==
               {:error, :conflict}
    end

    test "a not-sent first attempt followed by a crash in the second send", ctx do
      create!(ctx.lc, "p1")
      Script.script(:charge, [{:not_sent, :refused}, :crash])
      {pid, _} = charge_intent(ctx, "p1")
      run(pid, :dispatch)
      {:ok, _} = Intent.advance(pid, :rearm)
      run(pid, :dispatch)

      assert record(ctx.lc, {:charge, "p1"}, 2, :unknown) ==
               {:ok, %{state: :unknown, compensation: nil}}

      assert observations(ctx.p, "p1/charge") == [{1, 1, "send", "not_sent", nil, true}]
    end

    test "an out-of-order event is recorded with applied false", ctx do
      paid!(ctx.lc, "p1")

      assert event(ctx.lc, "ev2", {:charge, "p1"}, :failed) ==
               {:ok, %{applied: false, state: :succeeded, compensation: comp("p1")}}

      assert ["T1", "ev2", "p1", false] in Harness.truth(ctx.p).events
      assert payment(ctx.lc, "p1").state == :succeeded
    end

    test "an event of another amount or currency is recorded and changes nothing", ctx do
      create!(ctx.lc, "p1")
      {:ok, _} = charge(ctx.lc, "p1")

      for {id, amount} <- [{"ev-a", {"EUR", 99}}, {"ev-c", {"USD", 100}}] do
        assert event(ctx.lc, id, {:charge, "p1"}, :succeeded, amount) ==
                 {:ok, %{applied: false, state: :pending, compensation: nil}}
      end

      assert payment(ctx.lc, "p1").state == :pending
      assert length(Harness.truth(ctx.p).events) == 2
    end

    test "an event for an unknown payment or refund is stored with applied false", ctx do
      paid!(ctx.lc, "p1")

      assert event(ctx.lc, "ev-x", {:charge, "nobody"}, :succeeded) ==
               {:ok, %{applied: false, state: nil, compensation: nil}}

      assert event(ctx.lc, "ev-y", {:refund, "p1", "nope"}, :succeeded) ==
               {:ok, %{applied: false, state: nil, compensation: comp("p1")}}

      assert ["T1", "ev-x", "nobody", false] in Harness.truth(ctx.p).events
    end

    test "a forward event of a refund applies; a pending event moves :unknown to :pending", ctx do
      paid!(ctx.lc, "p1")
      Script.script(:refund, [{:unknown, :timeout}])
      {pid, _} = refund_intent(ctx, "p1", "r1", eur(10))
      run(pid, :dispatch)
      {:ok, %{state: :unknown}} = record(ctx.lc, {:refund, "p1", "r1"}, 1)

      assert {:ok, %{applied: true, state: :pending}} =
               event(ctx.lc, "e1", {:refund, "p1", "r1"}, :pending, {"EUR", 10}, "re_1")

      assert {:ok, %{applied: true, state: :succeeded}} =
               event(ctx.lc, "e2", {:refund, "p1", "r1"}, :succeeded, {"EUR", 10}, "re_1")

      assert %{state: :succeeded, provider_ref: "re_1"} = refund_state(ctx.lc, "p1", "r1")
    end
  end

  # ------------------------------------------------------------ 6

  test "6 an event that fails verification changes nothing and stores nothing", ctx do
    create!(ctx.lc, "p1")
    {:ok, _} = charge(ctx.lc, "p1")
    good = Script.event("ev1", {:charge, "p1"}, :succeeded, {"EUR", 100}, "ch_1")
    changed = %{good | raw_body: String.replace(good.raw_body, "100", "101")}
    before = Harness.truth(ctx.p)
    event = [:elz365, :app, :query]
    :ok = :telemetry.attach("elz365-verify", event, &Harness.forward/4, self())

    try do
      assert PL.apply_event(ctx.lc, "T1", changed) == {:error, :verification_failed}
      assert PL.apply_event(ctx.lc, "T1", %{good | headers: []}) == {:error, :verification_failed}
      refute_received {:app_query, _}
    after
      :telemetry.detach("elz365-verify")
    end

    assert Harness.truth(ctx.p) == before
  end

  # ------------------------------------------------------------ 7

  test "7 a changed approved amount, currency or recipient is approval_mismatch with nothing written",
       ctx do
    create!(ctx.lc, "p1")
    before = Harness.truth(ctx.p)

    for request <- [
          %{payment_id: "p1", amount: eur(101), recipient: "merchant-1"},
          %{payment_id: "p1", amount: money("USD", 100), recipient: "merchant-1"},
          %{payment_id: "p1", amount: eur(100), recipient: "merchant-2"}
        ] do
      assert PL.charge(ctx.lc, "T1", request) == {:error, :approval_mismatch}
    end

    assert Harness.truth(ctx.p) == before
    assert %{state: :created, revision: 1} = payment(ctx.lc, "p1")
    assert {:ok, %{key: _}} = charge(ctx.lc, "p1")
  end

  # ------------------------------------------------------------ 8

  describe "8 compensation" do
    test "run twice is one refund, of the whole amount", ctx do
      paid!(ctx.lc, "p1")
      {:ok, %{compensation: c}} = PL.get(ctx.lc, "T1", %{payment_id: "p1"})
      request = Map.delete(c, :kind)
      assert {:ok, a} = PL.refund(ctx.lc, "T1", request)
      assert PL.refund(ctx.lc, "T1", request) == {:ok, a}

      assert [%{refund_id: "comp/charge", amount: amount}] =
               Harness.truth(ctx.p).refunds
               |> Enum.map(fn [_, _, rid, _, amt, _, _] -> %{refund_id: rid, amount: amt} end)

      assert {:ok, eur(100)} == Money.Codec.decode(amount)
      assert List.last(a.identity) == "p1/refund/comp/charge"
    end

    test "after a partial refund of 30 of 100 it refunds 70; after a full refund nothing", ctx do
      paid!(ctx.lc, "p1")
      paid!(ctx.lc, "p2")
      {:ok, _} = PL.refund(ctx.lc, "T1", %{payment_id: "p1", refund_id: "r1", amount: eur(30)})
      {:ok, _} = PL.refund(ctx.lc, "T1", Map.delete(comp("p1"), :kind))
      assert %{amount: amount} = refund_state(ctx.lc, "p1", "comp/charge")
      assert amount == eur(70)

      {:ok, _} = PL.refund(ctx.lc, "T1", %{payment_id: "p2", refund_id: "r1", amount: eur(100)})

      assert PL.refund(ctx.lc, "T1", Map.delete(comp("p2"), :kind)) ==
               {:error, :nothing_to_refund}
    end

    test "a compensation whose refund fails leaves that refund :failed and the payment :succeeded",
         ctx do
      paid!(ctx.lc, "p1")
      Script.script(:refund, [{:declined, "insufficient_balance"}])
      {pid, a} = refund_intent(ctx, "p1", "comp/charge", :remaining)
      run(pid, :dispatch)

      assert record(ctx.lc, {:refund, "p1", "comp/charge"}, 1) ==
               {:ok, %{state: :failed, compensation: comp("p1")}}

      assert [%{idempotency_key: key, provider_ref: "ch_1", amount: amount}] =
               Script.calls(:refund)

      assert key == a.key and amount == eur(100)
      assert payment(ctx.lc, "p1").state == :succeeded
      assert payment(ctx.lc, "p1").refunded == eur(0)
    end

    test "a declined answer with a malformed code is unknown and keeps the hold", ctx do
      paid!(ctx.lc, "p1")
      Script.script(:refund, [{:declined, 123}])
      {pid, _} = refund_intent(ctx, "p1", "r1", eur(100))
      assert %{phase: {:Dispatched, :Fresh, 1}} = run(pid, :dispatch)

      assert record(ctx.lc, {:refund, "p1", "r1"}, 1) ==
               {:ok, %{state: :unknown, compensation: comp("p1")}}

      assert payment(ctx.lc, "p1").refunded == eur(100)

      assert PL.refund(ctx.lc, "T1", %{payment_id: "p1", refund_id: "r2", amount: :remaining}) ==
               {:error, :nothing_to_refund}
    end

    test "a declined refund whose write fails, then a poll :no_effect, releases its hold", ctx do
      paid!(ctx.lc, "p1")
      Script.script(:refund, [{:declined, "x"}])
      Script.script(:poll, [:no_effect])
      {pid, _} = refund_intent(ctx, "p1", "r1", eur(100))

      Harness.refuse_observations!(ctx.p, ctx.role)
      assert %{phase: {:Dispatched, :Fresh, 1}} = run(pid, :dispatch)
      Harness.restore_observations!(ctx.p, ctx.role)

      assert %{phase: {:Definite, :ProviderNoEffect, 1}} = run(pid, :poll)

      assert record(ctx.lc, {:refund, "p1", "r1"}, 1) ==
               {:ok, %{state: :failed, compensation: comp("p1")}}

      assert payment(ctx.lc, "p1").refunded == eur(0)

      assert {:ok, _} =
               PL.refund(ctx.lc, "T1", %{payment_id: "p1", refund_id: "r2", amount: :remaining})

      assert refund_state(ctx.lc, "p1", "r2").amount == eur(100)
    end

    test "a poll :no_effect whose write fails is pending; the next one closes the refund", ctx do
      paid!(ctx.lc, "p1")
      Script.script(:refund, [{:unknown, :timeout}])
      Script.script(:poll, [:no_effect, :no_effect])
      {pid, _} = refund_intent(ctx, "p1", "r1", eur(100))
      run(pid, :dispatch)

      Harness.refuse_observations!(ctx.p, ctx.role)
      assert %{phase: {:Dispatched, :Fresh, 1}} = run(pid, :poll)
      Harness.restore_observations!(ctx.p, ctx.role)

      assert %{phase: {:Definite, :ProviderNoEffect, 1}} = run(pid, :poll)

      assert record(ctx.lc, {:refund, "p1", "r1"}, 1) ==
               {:ok, %{state: :failed, compensation: comp("p1")}}

      assert payment(ctx.lc, "p1").refunded == eur(0)

      {:ok, _} = Intent.advance(pid, :rearm)
      status = run(pid, :dispatch)
      assert status.phase == {:Definite, :AdapterNoSend, 2} and status.flags.disarmed
      assert length(Script.calls(:refund)) == 1
    end

    test "a :rearm and :dispatch after the poll :no_effect is stored and before record/3", ctx do
      paid!(ctx.lc, "p1")
      Script.script(:refund, [{:unknown, :timeout}])
      Script.script(:poll, [:no_effect])
      {pid, _} = refund_intent(ctx, "p1", "r1", eur(100))
      run(pid, :dispatch)
      assert %{phase: {:Definite, :ProviderNoEffect, 1}} = run(pid, :poll)
      # Stored, not yet applied: the refund keeps its state and its hold.
      assert %{state: :pending} = refund_state(ctx.lc, "p1", "r1")

      {:ok, _} = Intent.advance(pid, :rearm)
      status = run(pid, :dispatch)
      assert status.phase == {:Definite, :AdapterNoSend, 2} and status.flags.disarmed
      assert length(Script.calls(:refund)) == 1

      assert record(ctx.lc, {:refund, "p1", "r1"}, 2) ==
               {:ok, %{state: :failed, compensation: comp("p1")}}
    end
  end

  # ------------------------------------------------------------ 9

  describe "9 idempotency, conflicts and shapes" do
    test "create/3 and refund/3 idempotency and conflict", ctx do
      create!(ctx.lc, "p1")

      base = %{
        payment_id: "p1",
        approved: %{amount: eur(100), recipient: "merchant-1"},
        approval_ref: "approval-p1"
      }

      assert PL.create(ctx.lc, "T1", base) == {:ok, :duplicate}

      for changed <- [
            put_in(base, [:approved, :amount], eur(101)),
            put_in(base, [:approved, :recipient], "other"),
            %{base | approval_ref: "other"}
          ],
          do: assert(PL.create(ctx.lc, "T1", changed) == {:error, :conflict})

      {:ok, _} = charge(ctx.lc, "p1")
      {:ok, %{applied: true}} = event(ctx.lc, "ev", {:charge, "p1"}, :succeeded)
      r = %{payment_id: "p1", refund_id: "r1", amount: eur(10)}
      assert {:ok, a} = PL.refund(ctx.lc, "T1", r)
      assert PL.refund(ctx.lc, "T1", r) == {:ok, a}
      assert PL.refund(ctx.lc, "T1", %{r | amount: eur(11)}) == {:error, :conflict}
      assert PL.refund(ctx.lc, "T1", %{r | amount: :remaining}) == {:error, :conflict}
    end

    test "a refund of a payment that is not :succeeded, in another currency, and bad IDs", ctx do
      create!(ctx.lc, "p1")
      r = %{payment_id: "p1", refund_id: "r1", amount: eur(10)}
      assert PL.refund(ctx.lc, "T1", r) == {:error, {:state, :created}}
      {:ok, _} = charge(ctx.lc, "p1")
      assert PL.refund(ctx.lc, "T1", r) == {:error, {:state, :pending}}
      {:ok, _} = event(ctx.lc, "ev", {:charge, "p1"}, :succeeded)
      assert PL.refund(ctx.lc, "T1", %{r | amount: money("USD", 10)}) == {:error, :currency}
      assert PL.refund(ctx.lc, "T1", %{r | amount: eur(101)}) == {:error, :over_refund}

      assert PL.refund(ctx.lc, "T1", %{r | refund_id: "a/b"}) == {:error, :invalid}
      assert PL.refund(ctx.lc, "T1", %{r | refund_id: "comp/charge"}) == {:error, :invalid}
      assert PL.refund(ctx.lc, "T1", %{r | amount: eur(0)}) == {:error, :invalid}
      assert PL.get(ctx.lc, "T1", %{payment_id: "a/b"}) == {:error, :invalid}

      assert PL.create(ctx.lc, "T1", %{
               payment_id: "a/charge",
               approved: %{amount: eur(1), recipient: "m"},
               approval_ref: "x"
             }) == {:error, :invalid}

      assert charge(ctx.lc, "p1") == {:error, {:state, :succeeded}}
      assert PL.get(ctx.lc, "T1", %{payment_id: "absent"}) == {:error, :unknown_payment}
    end

    test "new/1, the bounds and the migration prefix", ctx do
      assert {:error, :invalid} = PL.new(repo: AppRepo, prefix: ctx.p)
      assert {:error, :invalid} = PL.new(Keyword.put(opts(ctx.p), :prefix, "Bad"))
      assert {:error, :invalid} = PL.new(Keyword.put(opts(ctx.p), :deadline_ms, 0))
      assert {:error, :invalid} = PL.new(Keyword.put(opts(ctx.p), :deadline_ms, 86_400_001))
      assert {:ok, _} = PL.new(Keyword.put(opts(ctx.p), :deadline_ms, 86_400_000))
      assert {:error, :invalid} = PL.new(Keyword.put(opts(ctx.p), :provider_account, ""))
      assert {:error, :invalid} = PL.new(Keyword.put(opts(ctx.p), :provider, Enum))

      assert {:error, :invalid} =
               PL.new(Keyword.put(opts(ctx.p), :provider_account, String.duplicate("a", 129)))

      refute inspect(ctx.lc) =~ "seal_key"

      assert_raise ArgumentError, fn -> PL.Migration.install("bad-prefix") end

      id100 = String.duplicate("a", 100)
      create!(ctx.lc, id100)

      assert {:error, :invalid} =
               PL.create(ctx.lc, "T1", %{
                 payment_id: id100 <> "a",
                 approved: %{amount: eur(1), recipient: "m"},
                 approval_ref: "x"
               })

      assert {:error, :invalid} =
               PL.apply_event(ctx.lc, "T1", %{raw_body: :binary.copy("a", 65_537), headers: []})

      assert {:error, :invalid} =
               PL.apply_event(ctx.lc, "T1", %{raw_body: "", headers: List.duplicate({"a", "b"}, 65)})

      assert {:error, :verification_failed} =
               PL.apply_event(ctx.lc, "T1", %{raw_body: "", headers: List.duplicate({"a", "b"}, 64)})

      assert {:error, :invalid} = record(ctx.lc, {:charge, "p1"}, 0)
      assert {:error, :invalid} = record(ctx.lc, {:charge, "p1"}, 1, :other)
    end
  end

  defp opts(p),
    do: [
      repo: AppRepo,
      prefix: p,
      provider: Script,
      provider_account: "acct-1",
      deadline_ms: 1,
      clock: fn -> 0 end
    ]

  # ------------------------------------------------------------ 10

  describe "10 row security and transaction Needs" do
    test "verify passes; a T2 payment is invisible under T1; direct T2 inserts fail 42501", ctx do
      Harness.role_guard!(ctx.role)
      assert PL.verify(ctx.lc) == :ok
      create!(ctx.lc, "p2", 100, "T2")
      {:ok, _} = charge(ctx.lc, "p2", 100, "merchant-1", "T2")

      {:ok, %{applied: true}} =
        event(ctx.lc, "e2", {:charge, "p2"}, :succeeded, {"EUR", 100}, "ch", "T2")

      before = Harness.truth(ctx.p).payments |> Enum.filter(&(hd(&1) == "T2"))

      assert charge(ctx.lc, "p2") == {:error, :unknown_payment}
      assert record(ctx.lc, {:charge, "p2"}, 1) == {:error, :unknown_payment}

      assert PL.refund(ctx.lc, "T1", %{payment_id: "p2", refund_id: "r", amount: :remaining}) ==
               {:error, :unknown_payment}

      assert PL.get(ctx.lc, "T1", %{payment_id: "p2"}) == {:error, :unknown_payment}

      create!(ctx.lc, "p2", 50, "T1")
      assert payment(ctx.lc, "p2").state == :created
      assert payment(ctx.lc, "p2", "T2").state == :succeeded
      assert Harness.truth(ctx.p).payments |> Enum.filter(&(hd(&1) == "T2")) == before

      assert event(ctx.lc, "e3", {:charge, "p9"}, :succeeded, {"EUR", 100}, "ch", "T1") ==
               {:ok, %{applied: false, state: nil, compensation: nil}}

      create!(ctx.lc, "p8", 100, "T2")
      {:ok, _} = charge(ctx.lc, "p8", 100, "merchant-1", "T2")

      assert event(ctx.lc, "e4", {:charge, "p8"}, :succeeded, {"EUR", 100}, "ch", "T1") ==
               {:ok, %{applied: false, state: nil, compensation: nil}}

      assert ["T1", "e4", "p8", false] in Harness.truth(ctx.p).events
      assert payment(ctx.lc, "p8", "T2").state == :pending

      t = &Harness.table(ctx.p, &1)

      for sql <- [
            "INSERT INTO #{t.(:payments)} (tenant, payment_id, amount, recipient, approval_ref, approval_digest, state, revision) VALUES ('T2', 'x', 'a', 'r', 'f', decode(repeat('00', 32), 'hex'), 'created', 1)",
            "INSERT INTO #{t.(:refunds)} (tenant, payment_id, refund_id, requested, amount, state, deadline) VALUES ('T2', 'p2', 'x', 'remaining', 'a', 'pending', 1)",
            "INSERT INTO #{t.(:events)} (tenant, event_id, payment_id, body, applied) VALUES ('T2', 'x', 'p2', 'b', false)",
            "INSERT INTO #{t.(:observations)} (tenant, payment_id, operation_ref, seq, attempt, source, answer) VALUES ('T2', 'p2', 'p2/charge', 1, 1, 'send', 'pending')"
          ] do
        assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
                 TI.transact(AppRepo, %{tenant: "T1"}, fn -> Harness.q(AppRepo, sql) end)
      end
    end

    test "a caller's open transaction gives in_transaction before any query", ctx do
      create!(ctx.lc, "p1")
      event = [:elz365, :app, :query]

      {:ok, results} =
        AppRepo.transaction(fn ->
          :ok = :telemetry.attach("elz365-in-tx", event, &Harness.forward/4, self())

          try do
            results = [
              PL.create(ctx.lc, "T1", %{
                payment_id: "p2",
                approved: %{amount: eur(1), recipient: "m"},
                approval_ref: "x"
              }),
              charge(ctx.lc, "p1"),
              record(ctx.lc, {:charge, "p1"}, 1),
              PL.apply_event(
                ctx.lc,
                "T1",
                Script.event("e", {:charge, "p1"}, :succeeded, {"EUR", 100}, "c")
              ),
              PL.refund(ctx.lc, "T1", %{payment_id: "p1", refund_id: "r", amount: :remaining}),
              PL.get(ctx.lc, "T1", %{payment_id: "p1"})
            ]

            refute_received {:app_query, _}
            Harness.q!(AppRepo, "SELECT 1")
            assert_received {:app_query, "SELECT 1"}
            results
          after
            :telemetry.detach("elz365-in-tx")
          end
        end)

      assert results == List.duplicate({:error, :in_transaction}, 6)
    end

    test "a repeatable read Repo gets isolation with nothing written", ctx do
      create!(ctx.lc, "p1")
      {:ok, rr} = new(RepeatableRepo, ctx.p)
      before = Harness.truth(ctx.p)

      assert PL.create(rr, "T1", %{
               payment_id: "p2",
               approved: %{amount: eur(1), recipient: "m"},
               approval_ref: "x"
             }) ==
               {:error, :isolation}

      assert PL.charge(rr, "T1", %{payment_id: "p1", amount: eur(100), recipient: "merchant-1"}) ==
               {:error, :isolation}

      assert PL.record(rr, "T1", %{operation: {:charge, "p1"}, attempt: 1, fallback: :unknown}) ==
               {:error, :isolation}

      assert PL.apply_event(
               rr,
               "T1",
               Script.event("e", {:charge, "p1"}, :succeeded, {"EUR", 100}, "c")
             ) ==
               {:error, :isolation}

      assert PL.refund(rr, "T1", %{payment_id: "p1", refund_id: "r", amount: :remaining}) ==
               {:error, :isolation}

      assert PL.get(rr, "T1", %{payment_id: "p1"}) == {:error, :isolation}
      assert Harness.truth(ctx.p) == before
    end
  end
end
