# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/ledger_checkout_test_helper.exs", __DIR__)

defmodule Elzoo.LedgerCheckoutTest do
  # The cases share one database server, one scripted provider and hold session locks across
  # connections: not async.
  use ExUnit.Case, async: false
  alias Elzoo.DurableLog.Memory
  alias Elzoo.EffectIntent, as: Intent
  alias Elzoo.EffectIntent.StoreHost
  alias Elzoo.{Invoice, Journal, Money}
  alias Elzoo.LedgerCheckout, as: LC
  alias Elzoo.PaymentLifecycle, as: PL

  alias Elzoo.LedgerCheckoutTest.{
    Allowance,
    AppRepo,
    ChargeBinding,
    FaultRepo,
    Faults,
    Harness,
    Log,
    OwnerRepo,
    RefundBinding,
    RepeatableRepo,
    Script,
    ShortRepo
  }

  alias Elzoo.TenantIsolation, as: TI

  @moduletag :capture_log
  @ok {:ok, %{provider_ref: "ch_1", state: :succeeded}}
  @refunded {:ok, %{provider_ref: "re_1", state: :succeeded}}
  @steps_insert ~r/INSERT INTO "[a-z0-9_]+"\.elzoo_checkout_steps/
  @steps_update ~r/UPDATE "[a-z0-9_]+"\.elzoo_checkout_steps/

  setup_all do
    if Enum.any?(
         [OwnerRepo, AppRepo, RepeatableRepo, ShortRepo, FaultRepo, Script, Allowance, Log, Faults],
         &Process.whereis/1
       ),
       do: raise("the ledger checkout test processes are already running")

    for m <- [Log, Faults, Script, Allowance], do: {:ok, _} = m.start!()
    role = Harness.start_repos!()
    Harness.role_guard!(role)

    on_exit(fn ->
      Harness.stop_repos!()
      for m <- [Script, Allowance, Faults, Log], do: m.stop!()
    end)

    {:ok, role: role}
  end

  setup %{role: role} do
    p = Harness.install!(role)
    for m <- [Script, Allowance, Faults, Log], do: m.reset!()
    Harness.q!(FaultRepo, "SET default_transaction_isolation = 'read committed'")
    on_exit(fn -> Harness.drop!(p) end)

    {:ok, lc} =
      PL.new(
        repo: AppRepo,
        prefix: p,
        provider: Script,
        provider_account: "acct-1",
        deadline_ms: 600_000,
        clock: fn -> System.os_time(:millisecond) end
      )

    {:ok, inv} = Invoice.new(repo: AppRepo, prefix: p)
    journal = Journal.new(repo: AppRepo, prefix: p)

    for {account, negative} <- [
          {"cash", true},
          {"receivable", true},
          {"wallet:alice", false},
          {"float", true},
          {"shop", true}
        ],
        do:
          {:ok, :applied} =
            Journal.open_account(journal, "T1", %{
              account_id: account,
              currency: eur_currency(),
              allow_negative: negative
            })

    {:ok, b} = binding(AppRepo, p, lc, inv, journal)
    intents = start_supervised!({Task.Supervisor, []})
    {:ok, p: p, lc: lc, inv: inv, journal: journal, b: b, intents: intents}
  end

  # ------------------------------------------------------------ fixtures

  defp binding(repo, p, lc, inv, journal, allowance \\ Allowance.needs()) do
    LC.new(
      [repo: repo, prefix: p, payments: lc, invoices: inv, journal: journal] ++
        if(allowance, do: [allowance: allowance], else: [])
    )
  end

  defp eur_currency do
    {:ok, c} = Money.parse("EUR")
    c
  end

  defp eur(units) do
    {:ok, a} = Money.from_minor_units(eur_currency(), units)
    a
  end

  defp invoice_payment(id, opts \\ []) do
    %{
      checkout_id: id,
      kind: :invoice_payment,
      invoice_id: Keyword.get(opts, :invoice, "inv-" <> id),
      amount: eur(Keyword.get(opts, :units, 100)),
      recipient: "merchant-1",
      approved: %{amount: eur(100), recipient: "merchant-1"},
      approval_ref: "approval-" <> id,
      settle: %{to: Keyword.get(opts, :to, "cash"), from: "receivable"},
      actor_ref: "svc:checkout"
    }
  end

  defp top_up(id, opts \\ []) do
    %{
      checkout_id: id,
      kind: :top_up,
      amount: eur(Keyword.get(opts, :units, 100)),
      recipient: "merchant-1",
      approved: %{amount: eur(100), recipient: "merchant-1"},
      approval_ref: "approval-" <> id,
      wallet: %{to: Keyword.get(opts, :to, "wallet:alice"), from: "float"},
      allowance: if(g = Keyword.get(opts, :grant), do: %{grant_id: g}),
      parallel: Keyword.get(opts, :parallel, false),
      actor_ref: "svc:checkout"
    }
  end

  defp open!(b, declaration), do: {:ok, :applied} = LC.open(b, "T1", declaration)
  defp resume(b, id, tenant \\ "T1"), do: LC.resume(b, tenant, %{checkout_id: id})
  defp get(b, id, tenant \\ "T1"), do: LC.get(b, tenant, %{checkout_id: id})

  defp get!(b, id) do
    {:ok, c} = get(b, id)
    c
  end

  defp step(b, id, name), do: Enum.find(get!(b, id).steps, &(&1.step == name))

  defp list(b, state, after_id \\ nil, limit \\ 256),
    do: LC.list_running(b, "T1", %{after: after_id, limit: limit, state: state})

  # An open invoice of one adjustment line.
  defp invoice!(ctx, id, units \\ 100) do
    {:ok, :applied} =
      Invoice.create(ctx.inv, "T1", %{
        invoice_id: id,
        billing_account: "acct-1",
        currency: eur_currency(),
        series: "S"
      })

    {:ok, _} =
      Invoice.add_line(ctx.inv, "T1", %{
        invoice_id: id,
        line: {:adjustment, "l1", eur(units), "plan", "ref/l1"}
      })

    {:ok, _} =
      Invoice.finalize(ctx.inv, "T1", %{invoice_id: id, issued_at_ms: 1_000, due_at_ms: 2_000})
  end

  defp invoice(ctx, id) do
    {:ok, d} = Invoice.get(ctx.inv, "T1", %{invoice_id: id})
    d
  end

  defp balance(ctx, account) do
    {:ok, amount} = Journal.balance(ctx.journal, "T1", account)
    amount.minor_units
  end

  defp balances(ctx),
    do: Map.new(~w(cash receivable wallet:alice float shop), &{&1, balance(ctx, &1)})

  defp operations(ctx),
    do:
      Harness.scoped(
        "T1",
        ~s{SELECT operation_id, reverses FROM "#{ctx.p}".elzoo_journal_operations ORDER BY operation_id COLLATE "C"}
      )

  defp applications(ctx),
    do:
      Harness.scoped(
        "T1",
        ~s{SELECT invoice_id, payment_ref FROM "#{ctx.p}".elzoo_invoice_applications ORDER BY 1, 2}
      )

  defp refunds(ctx, id) do
    {:ok, %{refunds: refunds}} = PL.get(ctx.lc, "T1", %{payment_id: "checkout." <> id})
    Enum.map(refunds, &{&1.refund_id, &1.amount.minor_units, &1.state})
  end

  # Every step row of every checkout of the tenant: a result always has its compensation.
  defp assert_rows!(ctx) do
    for [step, state, result, compensation] <-
          Harness.scoped(
            "T1",
            ~s{SELECT step, state, result, compensation FROM "#{ctx.p}".elzoo_checkout_steps}
          ) do
      assert result == nil == (compensation == nil), "#{step} #{state} without its compensation"
    end
  end

  # The compensation and step effects since `mark`, of the given kinds, in order.
  defp effects(mark, kinds),
    do: Log.entries() |> Enum.drop(mark) |> Log.effects() |> Enum.filter(&(&1 in kinds))

  # ------------------------------------------------------------ the host's intents

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

  defp advance(pid, command) do
    assert {:ok, _} = Intent.advance(pid, command)
    settled(pid)
  end

  # The host starts the intent of an admission, dispatches it with one scripted answer and
  # calls record/3; returns the owner and the operation's state.
  defp intent!(ctx, binding, admission, operation, callback, answer) do
    Script.script(callback, [answer])
    pid = owner(ctx, binding, admission)
    advance(pid, :dispatch)

    {:ok, %{state: state}} =
      PL.record(ctx.lc, "T1", %{operation: operation, attempt: 1, fallback: nil})

    {pid, state}
  end

  # The first resume/3 waits at the charge intent; the host drives it.
  defp charged!(ctx, id, answer \\ @ok) do
    assert {:ok, %{state: :running, wait: %{step: :charge, for: :charge_intent, admission: a}}} =
             resume(ctx.b, id)

    assert a.identity |> List.last() == "checkout." <> id <> "/charge"
    intent!(ctx, ChargeBinding, a, {:charge, "checkout." <> id}, :charge, answer)
  end

  defp refund!(ctx, id, admission, answer \\ @refunded),
    do:
      intent!(
        ctx,
        RefundBinding,
        admission,
        {:refund, "checkout." <> id, "comp/charge"},
        :refund,
        answer
      )

  # ------------------------------------------------------------ processes

  # A resume/3 in its own unlinked process, held at a query by the gate and killed there.
  defp crash_at!(b, id, patterns) do
    pid = spawn(fn -> receive(do: (:go -> resume(b, id))) end)
    Log.gate!(patterns, pid)
    send(pid, :go)
    assert_receive {:gated, ^pid}, 5_000
    Process.exit(pid, :kill)
    Harness.await!(fn -> Harness.advisory_locks() == 0 end)
  end

  # A resume/3 in a Task, held at a query by the gate until `release/1`.
  defp held(b, id, patterns) do
    task =
      Task.async(fn ->
        receive do
          :go -> resume(b, id)
        end
      end)

    Log.gate!(patterns, task.pid)
    send(task.pid, :go)
    assert_receive {:gated, pid}, 5_000
    assert pid == task.pid
    task
  end

  defp release(task) do
    send(task.pid, :open)
    Task.await(task, 10_000)
  end

  # ------------------------------------------------------------ 1

  test "1 an invoice payment completes: one charge, one application, one settle operation",
       ctx do
    invoice!(ctx, "inv-c1")
    open!(ctx.b, invoice_payment("c1"))
    assert {:ok, %{checkout_ids: ["c1"], more: false}} = list(ctx.b, :open)
    assert {_, :succeeded} = charged!(ctx, "c1")

    assert resume(ctx.b, "c1") == {:ok, %{state: :completed, wait: nil}}

    assert %{kind: :invoice_payment, state: :completed, failure: nil, steps: steps} =
             get!(ctx.b, "c1")

    assert [
             %{
               step: :charge,
               position: 1,
               state: :succeeded,
               result: :succeeded,
               compensation: %{
                 kind: :refund,
                 payment_id: "checkout.c1",
                 refund_id: "comp/charge",
                 amount: :remaining
               }
             },
             %{
               step: :invoice,
               position: 2,
               state: :succeeded,
               result: :applied,
               compensation: %{
                 kind: :reverse_payment,
                 reversal_id: "checkout/c1/c/invoice",
                 payment_ref: "checkout/c1",
                 amount: :remaining
               }
             },
             %{
               step: :settle,
               position: 3,
               state: :succeeded,
               result: :applied,
               compensation: %{
                 kind: :reverse,
                 operation_id: "checkout/c1/c/settle",
                 reverses: "checkout/c1/settle"
               }
             }
           ] = steps

    assert [_] = Script.calls(:charge)
    assert applications(ctx) == [["inv-c1", "checkout/c1"]]
    assert %{state: :paid, paid: %{minor_units: 100}} = invoice(ctx, "inv-c1")
    assert operations(ctx) == [["checkout/c1/settle", nil]]
    assert %{"cash" => 100, "receivable" => -100} = balances(ctx)
    assert {:ok, %{checkout_ids: [], more: false}} = list(ctx.b, :open)
    assert_rows!(ctx)
  end

  # ------------------------------------------------------------ 2 and 7

  describe "2 a definite failure compensates the earlier steps in reverse order exactly once" do
    test "the charge declined: nothing to compensate", ctx do
      invoice!(ctx, "inv-c2")
      open!(ctx.b, invoice_payment("c2"))
      assert {_, :failed} = charged!(ctx, "c2", {:declined, "card_declined"})

      assert resume(ctx.b, "c2") == {:ok, %{state: :compensated, wait: nil}}
      assert %{failure: :payment_failed, steps: [charge]} = get!(ctx.b, "c2")
      assert %{state: :failed, failure: :payment_failed, compensation: nil} = charge
      assert refunds(ctx, "c2") == []
      assert applications(ctx) == []
    end

    test "the invoice refused (paid by another payment): the charge refunded", ctx do
      invoice!(ctx, "inv-c2")
      {:ok, :applied} = pay_other(ctx, "inv-c2")
      open!(ctx.b, invoice_payment("c2"))
      charged!(ctx, "c2")
      mark = Log.mark()

      assert {:ok,
              %{state: :compensating, wait: %{step: :charge, for: :refund_intent, admission: a}}} =
               resume(ctx.b, "c2")

      assert %{state: :failed, failure: {:state, :paid}} = step(ctx.b, "c2", :invoice)
      refund!(ctx, "c2", a)
      assert resume(ctx.b, "c2") == {:ok, %{state: :compensated, wait: nil}}
      assert %{failure: {:state, :paid}} = get!(ctx.b, "c2")
      assert %{state: :compensated} = step(ctx.b, "c2", :charge)
      assert effects(mark, [:refund, :reverse_payment]) == [:refund]
      assert refunds(ctx, "c2") == [{"comp/charge", 100, :succeeded}]
      assert applications(ctx) == [["inv-c2", "other"]]
    end

    test "the settle refused (an unknown account): the application reversed, then the charge refunded; 7 the invoice back",
         ctx do
      invoice!(ctx, "inv-c2")
      before = invoice(ctx, "inv-c2")
      open!(ctx.b, invoice_payment("c2", to: "nope"))
      charged!(ctx, "c2")
      mark = Log.mark()

      assert {:ok,
              %{state: :compensating, wait: %{step: :charge, for: :refund_intent, admission: a}}} =
               resume(ctx.b, "c2")

      assert %{state: :failed, failure: :unknown_account} = step(ctx.b, "c2", :settle)
      assert %{state: :compensated} = step(ctx.b, "c2", :invoice)
      refund!(ctx, "c2", a)
      assert resume(ctx.b, "c2") == {:ok, %{state: :compensated, wait: nil}}

      # Reverse order by the recorded order of calls.
      assert effects(mark, [:refund, :reverse_payment]) == [:reverse_payment, :refund]

      # 7: the invoice's paid and state are back, and no settle operation exists.
      after_ = invoice(ctx, "inv-c2")
      assert {after_.state, after_.paid} == {before.state, before.paid}
      assert after_.state == :open
      assert operations(ctx) == []
      assert %{"cash" => 0, "receivable" => 0} = balances(ctx)

      # Running resume/3 again after :compensated changes nothing.
      revision = get!(ctx.b, "c2").revision
      mark = Log.mark()
      assert resume(ctx.b, "c2") == {:ok, %{state: :compensated, wait: nil}}
      assert get!(ctx.b, "c2").revision == revision
      assert effects(mark, [:refund, :reverse_payment, :journal, :apply_payment]) == []
      assert Log.piece_calls(self(), mark) == []
      assert_rows!(ctx)
    end
  end

  defp pay_other(ctx, invoice_id, units \\ 100),
    do:
      Invoice.apply_payment(ctx.inv, "T1", %{
        invoice_id: invoice_id,
        payment_ref: "other",
        amount: eur(units)
      })

  # ------------------------------------------------------------ 3

  describe "3 the charge's settlement" do
    for {final, expected} <- [succeeded: :completed, failed: :compensated] do
      test "settled #{final} between get/3 and charge/3: the step reads again", ctx do
        open!(ctx.b, top_up("c3"))

        assert {:ok, %{wait: %{for: :charge_intent}}} = resume(ctx.b, "c3")

        # The host's reconciliation settles the payment after get/3 read it :pending and before
        # charge/3 locks it.
        task = held(ctx.b, "c3", [~r/FOR SHARE/, ~r/transaction_isolation/])

        assert {:ok, %{applied: true}} =
                 PL.apply_event(
                   ctx.lc,
                   "T1",
                   Script.event("ev-1", {:charge, "checkout.c3"}, unquote(final), 100, "ch_1")
                 )

        assert {:ok, %{state: unquote(expected), wait: nil}} = release(task)
        charge = step(ctx.b, "c3", :charge)

        if unquote(final) == :succeeded do
          assert %{
                   state: :succeeded,
                   result: :succeeded,
                   compensation: %{kind: :refund, refund_id: "comp/charge"}
                 } = charge
        else
          assert %{state: :failed, failure: :payment_failed, compensation: nil} = charge
          assert refunds(ctx, "c3") == []
        end

        assert Script.calls(:charge) == []
      end
    end

    test "an unknown settlement waits with nothing registered; a poll success completes", ctx do
      open!(ctx.b, top_up("c3"))
      {pid, :unknown} = charged!(ctx, "c3", {:unknown, :timeout})

      assert {:ok, %{state: :running, wait: %{step: :charge, for: :charge_intent, admission: a}}} =
               resume(ctx.b, "c3")

      assert a.identity |> List.last() == "checkout.c3/charge"
      assert %{state: :started, result: nil, compensation: nil} = step(ctx.b, "c3", :charge)
      assert refunds(ctx, "c3") == []

      Script.script(:poll, [@ok])
      advance(pid, :poll)

      assert {:ok, %{state: :succeeded}} =
               PL.record(ctx.lc, "T1", %{
                 operation: {:charge, "checkout.c3"},
                 attempt: 1,
                 fallback: nil
               })

      assert resume(ctx.b, "c3") == {:ok, %{state: :completed, wait: nil}}
      assert [_] = Script.calls(:charge)
    end

    test "an unknown settlement; a poll failure compensates with no refund", ctx do
      open!(ctx.b, top_up("c3"))
      {pid, :unknown} = charged!(ctx, "c3", {:unknown, :timeout})
      assert {:ok, %{state: :running, wait: %{for: :charge_intent}}} = resume(ctx.b, "c3")

      Script.script(:poll, [{:ok, %{provider_ref: "ch_1", state: :failed}}])
      advance(pid, :poll)

      assert {:ok, %{state: :failed}} =
               PL.record(ctx.lc, "T1", %{
                 operation: {:charge, "checkout.c3"},
                 attempt: 1,
                 fallback: nil
               })

      assert resume(ctx.b, "c3") == {:ok, %{state: :compensated, wait: nil}}
      assert refunds(ctx, "c3") == []
      assert Script.calls(:refund) == []
      assert operations(ctx) == []
    end
  end

  # ------------------------------------------------------------ 4, 5, 6

  test "4 duplicate and out-of-order provider events change nothing in the checkout's result",
       ctx do
    open!(ctx.b, top_up("c4"))
    charged!(ctx, "c4")
    assert {:ok, %{state: :completed}} = resume(ctx.b, "c4")
    before = get!(ctx.b, "c4")

    succeeded = Script.event("ev-1", {:charge, "checkout.c4"}, :succeeded, 100, "ch_1")
    assert {:ok, %{applied: false}} = PL.apply_event(ctx.lc, "T1", succeeded)
    assert {:ok, %{duplicate: true}} = PL.apply_event(ctx.lc, "T1", succeeded)

    assert {:ok, %{applied: false, state: :succeeded}} =
             PL.apply_event(
               ctx.lc,
               "T1",
               Script.event("ev-2", {:charge, "checkout.c4"}, :failed, 100, "ch_1")
             )

    assert {:ok, %{state: :completed, wait: nil}} = resume(ctx.b, "c4")
    assert get!(ctx.b, "c4") == before
    assert %{"wallet:alice" => 100, "float" => -100} = balances(ctx)
  end

  test "5 an approval drift is :approval_mismatch, a definite failure before any intent", ctx do
    open!(ctx.b, top_up("c5", units: 120))
    assert resume(ctx.b, "c5") == {:ok, %{state: :compensated, wait: nil}}

    assert %{failure: :approval_mismatch, steps: [%{step: :charge, state: :failed}]} =
             get!(ctx.b, "c5")

    assert Script.calls(:charge) == []

    assert {:ok, %{payment: %{state: :created}}} =
             PL.get(ctx.lc, "T1", %{payment_id: "checkout.c5"})
  end

  test "5 an existing payment of other terms is never adopted: :conflict or :approval_mismatch",
       ctx do
    # c5a: a succeeded payment under the checkout's ID of other approved terms (10).
    # c5b: a succeeded payment of the checkout's approved terms (100); the checkout asks 120.
    # c5c: the approved terms match; only the requested recipient differs.
    for {id, units} <- [{"c5a", 10}, {"c5b", 100}, {"c5c", 100}] do
      {:ok, :applied} =
        PL.create(ctx.lc, "T1", %{
          payment_id: "checkout." <> id,
          approved: %{amount: eur(units), recipient: "merchant-1"},
          approval_ref: "approval-" <> id
        })

      assert {:ok, %{applied: true, state: :succeeded}} =
               PL.apply_event(
                 ctx.lc,
                 "T1",
                 Script.event("ev-" <> id, {:charge, "checkout." <> id}, :succeeded, units, "ch_1")
               )
    end

    open!(ctx.b, top_up("c5a"))
    open!(ctx.b, top_up("c5b", units: 120))
    open!(ctx.b, %{top_up("c5c") | recipient: "merchant-2"})

    for {id, reason} <- [
          {"c5a", :conflict},
          {"c5b", :approval_mismatch},
          {"c5c", :approval_mismatch}
        ] do
      assert resume(ctx.b, id) == {:ok, %{state: :compensated, wait: nil}}

      assert %{
               failure: ^reason,
               steps: [%{step: :charge, state: :failed, failure: ^reason, compensation: nil}]
             } = get!(ctx.b, id)

      assert refunds(ctx, id) == []
    end

    assert Script.calls(:charge) == []
    assert Script.calls(:refund) == []
    assert operations(ctx) == []
    assert balance(ctx, "wallet:alice") == 0
  end

  test "6 a concurrent host refund: comp/charge takes only the rest, never over-refunded", ctx do
    invoice!(ctx, "inv-c6")
    {:ok, :applied} = pay_other(ctx, "inv-c6")
    open!(ctx.b, invoice_payment("c6"))
    charged!(ctx, "c6")

    # The host refunds 30 under its own refund_id; that refund stays pending.
    assert {:ok, _} =
             PL.refund(ctx.lc, "T1", %{
               payment_id: "checkout.c6",
               refund_id: "host-1",
               amount: eur(30)
             })

    assert {:ok, %{state: :compensating, wait: %{for: :refund_intent, admission: a}}} =
             resume(ctx.b, "c6")

    refund!(ctx, "c6", a)
    assert resume(ctx.b, "c6") == {:ok, %{state: :compensated, wait: nil}}
    assert refunds(ctx, "c6") == [{"comp/charge", 70, :succeeded}, {"host-1", 30, :pending}]

    assert {:ok, %{payment: %{refunded: %{minor_units: 100}, amount: %{minor_units: 100}}}} =
             PL.get(ctx.lc, "T1", %{payment_id: "checkout.c6"})
  end

  # ------------------------------------------------------------ 7 and 11 (sequential)

  test "7 a compensated top-up balances back; 11 without parallel an allowance failure reverses the wallet, then refunds",
       ctx do
    before = balances(ctx)
    Allowance.script(:grant, [{:error, :refused}])
    open!(ctx.b, top_up("c7", grant: "g7"))
    charged!(ctx, "c7")
    mark = Log.mark()

    assert {:ok, %{state: :compensating, wait: %{step: :charge, for: :refund_intent, admission: a}}} =
             resume(ctx.b, "c7")

    refund!(ctx, "c7", a)
    assert resume(ctx.b, "c7") == {:ok, %{state: :compensated, wait: nil}}

    assert effects(mark, [:journal, :grant, :revoke, :refund]) ==
             [:journal, :grant, :journal, :refund]

    assert %{failure: :refused, steps: [charge, wallet, allowance]} = get!(ctx.b, "c7")
    assert %{state: :compensated} = charge
    assert %{state: :compensated, group: nil} = wallet
    assert %{state: :failed, failure: :refused, compensation: nil} = allowance
    assert balances(ctx) == before

    assert operations(ctx) == [
             ["checkout/c7/c/wallet", "checkout/c7/wallet"],
             ["checkout/c7/wallet", nil]
           ]

    {:ok, %{entries: entries}} =
      Journal.history(ctx.journal, "T1", %{account_id: "wallet:alice", after: nil, limit: 10})

    assert Enum.map(entries, &{&1.operation_id, &1.reverses, &1.amount.minor_units}) == [
             {"checkout/c7/wallet", nil, 100},
             {"checkout/c7/c/wallet", "checkout/c7/wallet", -100}
           ]
  end

  # ------------------------------------------------------------ 8

  describe "8 crash and resume" do
    test "each invoice-payment step after a crash: one effect (:duplicate) and one compensation",
         ctx do
      invoice!(ctx, "inv-c8")
      open!(ctx.b, invoice_payment("c8"))

      # The charge: a crashed run stored its started row; the test performs create/3 itself.
      crash_at!(ctx.b, "c8", [~r/INSERT INTO "[a-z0-9_]+"\.elzoo_payment_payments/])
      assert %{state: :started} = step(ctx.b, "c8", :charge)

      {:ok, :applied} =
        PL.create(ctx.lc, "T1", %{
          payment_id: "checkout.c8",
          approved: %{amount: eur(100), recipient: "merchant-1"},
          approval_ref: "approval-c8"
        })

      charged!(ctx, "c8")

      # The invoice application.
      crash_at!(ctx.b, "c8", [~r/FROM "[a-z0-9_]+"\.elzoo_invoices WHERE/])
      assert %{state: :started} = step(ctx.b, "c8", :invoice)

      {:ok, :applied} =
        Invoice.apply_payment(ctx.inv, "T1", %{
          invoice_id: "inv-c8",
          payment_ref: "checkout/c8",
          amount: eur(100)
        })

      # The settle post, with the Contract's reason constant.
      crash_at!(ctx.b, "c8", [~r/INSERT INTO "[a-z0-9_]+"\.elzoo_journal_operations/])
      assert %{state: :started} = step(ctx.b, "c8", :settle)
      assert_rows!(ctx)

      {:ok, :applied} =
        Journal.post(ctx.journal, "T1", %{
          operation_id: "checkout/c8/settle",
          actor_ref: "svc:checkout",
          reason: "elzoo.ledger-checkout settle",
          postings: [
            %{account_id: "cash", amount: eur(100)},
            %{account_id: "receivable", amount: eur(-100)}
          ]
        })

      assert resume(ctx.b, "c8") == {:ok, %{state: :completed, wait: nil}}

      assert [
               %{state: :succeeded, result: :succeeded, compensation: %{kind: :refund}},
               %{state: :succeeded, result: :duplicate, compensation: %{kind: :reverse_payment}},
               %{state: :succeeded, result: :duplicate, compensation: %{kind: :reverse}}
             ] = get!(ctx.b, "c8").steps

      assert [_] = Script.calls(:charge)
      assert applications(ctx) == [["inv-c8", "checkout/c8"]]
      assert operations(ctx) == [["checkout/c8/settle", nil]]
      assert %{"cash" => 100} = balances(ctx)
      assert_rows!(ctx)
    end

    test "the wallet post after a crash, then a resume killed inside the grant Need holding the lock",
         ctx do
      open!(ctx.b, top_up("c8", grant: "g8"))
      charged!(ctx, "c8")

      crash_at!(ctx.b, "c8", [~r/INSERT INTO "[a-z0-9_]+"\.elzoo_journal_operations/])

      {:ok, :applied} =
        Journal.post(ctx.journal, "T1", %{
          operation_id: "checkout/c8/wallet",
          actor_ref: "svc:checkout",
          reason: "elzoo.ledger-checkout wallet",
          postings: [
            %{account_id: "wallet:alice", amount: eur(100)},
            %{account_id: "float", amount: eur(-100)}
          ]
        })

      # The grant Need decides the grant, then the resuming process is killed in it.
      Allowance.script(:grant, [:kill])
      pid = spawn(fn -> resume(ctx.b, "c8") end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
      Harness.await!(fn -> Harness.advisory_locks() == 0 end)
      assert %{state: :started} = step(ctx.b, "c8", :allowance)
      assert %{state: :succeeded, result: :duplicate} = step(ctx.b, "c8", :wallet)

      assert resume(ctx.b, "c8") == {:ok, %{state: :completed, wait: nil}}

      assert %{state: :succeeded, result: :granted, compensation: %{kind: :revoke, grant_id: "g8"}} =
               step(ctx.b, "c8", :allowance)

      assert Agent.get(Allowance, & &1.decided) == %{"g8" => :granted}
      assert operations(ctx) == [["checkout/c8/wallet", nil]]
      assert %{"wallet:alice" => 100} = balances(ctx)
      assert_rows!(ctx)
    end

    test "a crash between two recordings leaves every result with its compensation", ctx do
      open!(ctx.b, top_up("c8"))
      charged!(ctx, "c8")

      # Killed at the second step recording of the pass: the charge's, then the wallet's.
      crash_at!(ctx.b, "c8", [@steps_update, @steps_update])
      assert_rows!(ctx)
      assert %{state: :succeeded, compensation: %{kind: :refund}} = step(ctx.b, "c8", :charge)
      assert %{state: :started} = step(ctx.b, "c8", :wallet)

      assert resume(ctx.b, "c8") == {:ok, %{state: :completed, wait: nil}}
      assert %{result: :duplicate, compensation: %{kind: :reverse}} = step(ctx.b, "c8", :wallet)
      assert operations(ctx) == [["checkout/c8/wallet", nil]]
      assert_rows!(ctx)
    end

    test "an :unavailable that committed then the journal's :isolation records nothing", ctx do
      {:ok, b} =
        binding(AppRepo, ctx.p, ctx.lc, ctx.inv, Journal.new(repo: FaultRepo, prefix: ctx.p))

      open!(b, top_up("c8"))
      charged!(%{ctx | b: b}, "c8")

      Faults.script(FaultRepo, [:raise_after])

      assert {:ok, %{state: :running, wait: %{step: :wallet, for: :retry, admission: nil}}} =
               resume(b, "c8")

      assert operations(ctx) == [["checkout/c8/wallet", nil]]
      assert %{state: :started, result: nil} = step(b, "c8", :wallet)

      Harness.q!(FaultRepo, "SET default_transaction_isolation = 'repeatable read'")
      assert resume(b, "c8") == {:error, :isolation}
      assert %{state: :started, result: nil, failure: nil} = step(b, "c8", :wallet)
      assert get!(b, "c8").state == :running

      Harness.q!(FaultRepo, "SET default_transaction_isolation = 'read committed'")
      assert resume(b, "c8") == {:ok, %{state: :completed, wait: nil}}
      assert %{state: :succeeded, result: :duplicate} = step(b, "c8", :wallet)
      assert %{"wallet:alice" => 100} = balances(ctx)
    end

    test "a Need longer than the Repo's :timeout keeps the lock: a second resume/3 is :busy",
         ctx do
      {:ok, b} = binding(ShortRepo, ctx.p, ctx.lc, ctx.inv, ctx.journal)
      open!(b, top_up("c8", grant: "g8"))
      charged!(%{ctx | b: b}, "c8")
      Allowance.script(:grant, [{:sleep, 600}])

      task = Task.async(fn -> resume(b, "c8") end)
      Harness.await!(fn -> Enum.any?(Log.entries(), &match?({:grant, _, _}, &1)) end)
      Process.sleep(300)

      assert {:ok, %{state: :running, wait: %{step: :allowance, for: :busy, admission: nil}}} =
               resume(b, "c8")

      assert Task.await(task) == {:ok, %{state: :completed, wait: nil}}
      assert [{:grant, _, _}] = for({:grant, _, _} = e <- Log.entries(), do: e)
    end

    test "list_running/3 before and after; limit bounds and more at the edge", ctx do
      for id <- ["la", "lb"], do: open!(ctx.b, top_up(id))
      assert list(ctx.b, :open) == {:ok, %{checkout_ids: ["la", "lb"], more: false}}
      assert list(ctx.b, :open, nil, 1) == {:ok, %{checkout_ids: ["la"], more: true}}
      assert list(ctx.b, :open, "la", 1) == {:ok, %{checkout_ids: ["lb"], more: false}}
      assert list(ctx.b, :open, "lb", 1) == {:ok, %{checkout_ids: [], more: false}}
      assert list(ctx.b, :open, nil, 257) == {:error, :invalid}
      assert list(ctx.b, :open, nil, 0) == {:error, :invalid}
      assert list(ctx.b, :done, nil, 1) == {:error, :invalid}

      charged!(ctx, "la")
      assert {:ok, %{state: :completed}} = resume(ctx.b, "la")
      assert list(ctx.b, :open) == {:ok, %{checkout_ids: ["lb"], more: false}}
      assert list(ctx.b, :needs_operator) == {:ok, %{checkout_ids: [], more: false}}
    end
  end

  # ------------------------------------------------------------ 9

  describe "9 two concurrent resume/3 calls" do
    test "the second caller calls nothing and waits :busy", ctx do
      invoice!(ctx, "inv-c9")
      open!(ctx.b, invoice_payment("c9"))

      task = held(ctx.b, "c9", [@steps_insert])
      mark = Log.mark()

      assert resume(ctx.b, "c9") ==
               {:ok, %{state: :running, wait: %{step: :charge, for: :busy, admission: nil}}}

      assert Log.piece_calls(self(), mark) == []
      assert {:ok, %{wait: %{for: :charge_intent, admission: a}}} = release(task)
      intent!(ctx, ChargeBinding, a, {:charge, "checkout.c9"}, :charge, @ok)

      task = held(ctx.b, "c9", [@steps_update, @steps_insert])
      mark = Log.mark()

      assert {:ok, %{state: :running, wait: %{step: :invoice, for: :busy}}} = resume(ctx.b, "c9")
      assert Log.piece_calls(self(), mark) == []
      assert release(task) == {:ok, %{state: :completed, wait: nil}}

      assert [%{idempotency_key: key}] = Script.calls(:charge)
      assert key == a.key
      assert applications(ctx) == [["inv-c9", "checkout/c9"]]
      assert operations(ctx) == [["checkout/c9/settle", nil]]

      assert Harness.scoped(
               "T1",
               ~s{SELECT step, revision FROM "#{ctx.p}".elzoo_checkout_steps ORDER BY position}
             ) == [["charge", 2], ["invoice", 2], ["settle", 2]]

      assert_rows!(ctx)
    end

    test "a refusal that changes while the lock is held is read by the holder only", ctx do
      invoice!(ctx, "inv-c9")
      {:ok, :applied} = pay_other(ctx, "inv-c9")
      open!(ctx.b, invoice_payment("c9"))
      charged!(ctx, "c9")

      # Held while it records the invoice's {:state, :paid}.
      task = held(ctx.b, "c9", [@steps_update, @steps_update])

      {:ok, :applied} =
        Invoice.reverse_payment(ctx.inv, "T1", %{
          invoice_id: "inv-c9",
          reversal_id: "host-reversal",
          payment_ref: "other",
          amount: :remaining
        })

      assert %{state: :open} = invoice(ctx, "inv-c9")
      mark = Log.mark()
      assert {:ok, %{wait: %{for: :busy}}} = resume(ctx.b, "c9")
      assert Log.piece_calls(self(), mark) == []

      assert {:ok, %{state: :compensating, wait: %{for: :refund_intent, admission: a}}} =
               release(task)

      refund!(ctx, "c9", a)
      assert resume(ctx.b, "c9") == {:ok, %{state: :compensated, wait: nil}}
      assert applications(ctx) == [["inv-c9", "other"]]
      assert %{state: :open, paid: %{minor_units: 0}} = invoice(ctx, "inv-c9")
    end
  end

  # ------------------------------------------------------------ 10

  test "10 a failed compensation stops the checkout for an operator", ctx do
    Allowance.script(:grant, [:unavailable, {:error, :refused}])
    open!(ctx.b, top_up("c10", grant: "g10"))
    charged!(ctx, "c10")

    assert {:ok, %{state: :running, wait: %{step: :allowance, for: :retry, admission: nil}}} =
             resume(ctx.b, "c10")

    # The wallet credit is spent before the compensation runs.
    {:ok, :applied} =
      Journal.post(ctx.journal, "T1", %{
        operation_id: "spend-1",
        actor_ref: "svc:shop",
        reason: "spend",
        postings: [
          %{account_id: "wallet:alice", amount: eur(-60)},
          %{account_id: "shop", amount: eur(60)}
        ]
      })

    assert resume(ctx.b, "c10") == {:ok, %{state: :needs_operator, wait: nil}}

    assert %{state: :needs_operator, failure: :refused, steps: [charge, wallet, allowance]} =
             get!(ctx.b, "c10")

    assert %{state: :succeeded, compensation: %{kind: :refund, refund_id: "comp/charge"}} = charge
    assert %{state: :compensation_failed, failure: :insufficient_funds} = wallet
    assert %{compensation: %{kind: :reverse}} = wallet
    assert %{state: :failed, failure: :refused} = allowance
    assert refunds(ctx, "c10") == []
    assert list(ctx.b, :needs_operator) == {:ok, %{checkout_ids: ["c10"], more: false}}
    assert list(ctx.b, :open) == {:ok, %{checkout_ids: [], more: false}}

    mark = Log.mark()
    assert {:ok, %{state: :needs_operator, wait: nil}} = resume(ctx.b, "c10")
    assert Log.piece_calls(self(), mark) == []
  end

  # ------------------------------------------------------------ 11

  describe "11 a declared parallel group" do
    test "the wallet fails, the allowance succeeds: both started, revoke once, then refund", ctx do
      open!(ctx.b, top_up("c11", grant: "g11", parallel: true, to: "nope"))
      charged!(ctx, "c11")
      mark = Log.mark()

      assert {:ok,
              %{state: :compensating, wait: %{step: :charge, for: :refund_intent, admission: a}}} =
               resume(ctx.b, "c11")

      refund!(ctx, "c11", a)
      assert resume(ctx.b, "c11") == {:ok, %{state: :compensated, wait: nil}}
      assert effects(mark, [:grant, :revoke, :refund]) == [:grant, :revoke, :refund]

      assert %{failure: :unknown_account, steps: [_, wallet, allowance]} = get!(ctx.b, "c11")
      assert %{state: :failed, failure: :unknown_account, group: 1} = wallet
      assert %{state: :compensated, group: 1} = allowance
      assert Agent.get(Allowance, & &1.decided) == %{"g11" => :revoked}
    end

    test "a wallet post waiting :retry keeps the checkout waiting with the allowance started",
         ctx do
      {:ok, b} =
        binding(AppRepo, ctx.p, ctx.lc, ctx.inv, Journal.new(repo: FaultRepo, prefix: ctx.p))

      open!(b, top_up("c11", grant: "g11", parallel: true))
      charged!(%{ctx | b: b}, "c11")
      Faults.script(FaultRepo, [:raise_before])

      assert {:ok, %{state: :running, wait: %{step: :wallet, for: :retry, admission: nil}}} =
               resume(b, "c11")

      assert %{state: :started} = step(b, "c11", :wallet)
      assert %{state: :succeeded} = step(b, "c11", :allowance)
      assert for({:revoke, _, _} = e <- Log.entries(), do: e) == []
      assert refunds(ctx, "c11") == []

      assert resume(b, "c11") == {:ok, %{state: :completed, wait: nil}}
      assert [{:grant, _, _}] = for({:grant, _, _} = e <- Log.entries(), do: e)
    end

    test "a wallet refusal is recorded before the grant Need; a crash in it keeps the refusal",
         ctx do
      open!(ctx.b, top_up("c11", grant: "g11", parallel: true, to: "later"))
      charged!(ctx, "c11")

      # The grant is decided, then the resuming process is killed inside the Need.
      Allowance.script(:grant, [:kill])
      pid = spawn(fn -> resume(ctx.b, "c11") end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
      Harness.await!(fn -> Harness.advisory_locks() == 0 end)
      assert %{state: :failed, failure: :unknown_account} = step(ctx.b, "c11", :wallet)

      # The account the journal refused is opened before recovery.
      {:ok, :applied} =
        Journal.open_account(ctx.journal, "T1", %{
          account_id: "later",
          currency: eur_currency(),
          allow_negative: true
        })

      assert {:ok, %{state: :compensating, wait: %{step: :charge, for: :refund_intent}}} =
               resume(ctx.b, "c11")

      assert %{failure: :unknown_account, steps: [_, wallet, allowance]} = get!(ctx.b, "c11")
      assert %{state: :failed, failure: :unknown_account} = wallet
      assert %{state: :compensated} = allowance
      assert operations(ctx) == []
      assert balance(ctx, "later") == 0
    end

    test "a busy caller names the member still open, not its failed sibling", ctx do
      Allowance.script(:grant, [:unavailable, :ok])
      open!(ctx.b, top_up("c11", grant: "g11", parallel: true, to: "nope"))
      charged!(ctx, "c11")

      assert {:ok, %{state: :running, wait: %{step: :allowance, for: :retry}}} =
               resume(ctx.b, "c11")

      task = held(ctx.b, "c11", [@steps_update])

      assert resume(ctx.b, "c11") ==
               {:ok, %{state: :running, wait: %{step: :allowance, for: :busy, admission: nil}}}

      assert {:ok, %{state: :compensating, wait: %{for: :refund_intent}}} = release(task)
    end

    test "both members failing records the wallet's reason", ctx do
      Allowance.script(:grant, [{:error, :refused}])
      open!(ctx.b, top_up("c11", grant: "g11", parallel: true, to: "nope"))
      charged!(ctx, "c11")

      assert {:ok, %{state: :compensating, wait: %{for: :refund_intent}}} = resume(ctx.b, "c11")

      assert %{failure: :unknown_account, steps: [_, wallet, allowance]} = get!(ctx.b, "c11")
      assert %{state: :failed, failure: :unknown_account} = wallet
      assert %{state: :failed, failure: :refused} = allowance
    end
  end

  # ------------------------------------------------------------ 12

  test "12 cross-tenant isolation as the application role", ctx do
    open!(ctx.b, top_up("c12"))
    t = ~s("#{ctx.p}".elzoo_checkout_checkouts)

    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             Harness.q(AppRepo, "ALTER TABLE #{t} NO FORCE ROW LEVEL SECURITY")

    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             Harness.q(AppRepo, "DELETE FROM #{t}")

    assert get(ctx.b, "c12", "T2") == {:error, :unknown_checkout}
    assert resume(ctx.b, "c12", "T2") == {:error, :unknown_checkout}

    assert LC.list_running(ctx.b, "T2", %{after: nil, limit: 10, state: :open}) ==
             {:ok, %{checkout_ids: [], more: false}}

    for {table, sql} <- [
          {t,
           "INSERT INTO #{t} (tenant, checkout_id, kind, declaration, state, revision) VALUES ('T2', 'x', 'top_up', '\\x00', 'running', 1)"},
          {:steps,
           ~s{INSERT INTO "#{ctx.p}".elzoo_checkout_steps (tenant, checkout_id, step, position, state, revision) VALUES ('T2', 'c12', 'charge', 1, 'started', 1)}}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               TI.transact(AppRepo, %{tenant: "T1"}, fn -> Harness.q(AppRepo, sql) end),
             inspect(table)
    end

    assert Script.calls(:charge) == []
    assert %{state: :running, steps: []} = get!(ctx.b, "c12")
  end

  # ------------------------------------------------------------ the interface's bounds

  describe "bounds" do
    test "new/1 takes exactly its keys", ctx do
      base = [
        repo: AppRepo,
        prefix: ctx.p,
        payments: ctx.lc,
        invoices: ctx.inv,
        journal: ctx.journal
      ]

      assert {:ok, %LC{allowance: nil}} = LC.new(base)

      for bad <- [
            Keyword.delete(base, :journal),
            Keyword.put(base, :prefix, "Bad"),
            Keyword.put(base, :payments, ctx.inv),
            base ++ [allowance: %{grant: &Allowance.grant/1}],
            base ++ [allowance: nil],
            base ++ [other: 1]
          ],
          do: assert(LC.new(bad) == {:error, :invalid})
    end

    test "open/3 checks every field before it stores anything; duplicate and conflict", ctx do
      d = invoice_payment("c13")

      for bad <- [
            %{d | checkout_id: "has/slash"},
            %{d | checkout_id: String.duplicate("a", 65)},
            %{d | amount: eur(0)},
            %{d | amount: :remaining},
            %{d | recipient: String.duplicate("r", 257)},
            %{d | approved: %{amount: eur(100)}},
            %{d | approval_ref: ""},
            %{d | invoice_id: String.duplicate("i", 101)},
            %{d | settle: %{to: "cash", from: "cash"}},
            %{d | settle: %{to: String.duplicate("a", 129), from: "x"}},
            %{d | actor_ref: "bad\n"},
            Map.delete(d, :actor_ref),
            Map.put(d, :extra, 1),
            %{top_up("c13") | parallel: true},
            top_up("c13", grant: String.duplicate("g", 129)),
            %{top_up("c13") | allowance: %{grant_id: "g", other: 1}}
          ],
          do: assert(LC.open(ctx.b, "T1", bad) == {:error, :invalid})

      assert LC.open(ctx.b, "bad\u0000", d) == {:error, :invalid}
      assert {:ok, %{checkout_ids: []}} = list(ctx.b, :open)

      assert LC.open(ctx.b, "T1", d) == {:ok, :applied}
      assert LC.open(ctx.b, "T1", d) == {:ok, :duplicate}
      assert LC.open(ctx.b, "T1", %{d | actor_ref: "svc:other"}) == {:error, :conflict}
      assert LC.open(ctx.b, "T1", top_up("c13")) == {:error, :conflict}
    end

    test "an allowance needs the binding's Needs at open/3 and at resume/3", ctx do
      {:ok, plain} = binding(AppRepo, ctx.p, ctx.lc, ctx.inv, ctx.journal, nil)
      assert LC.open(plain, "T1", top_up("c14", grant: "g")) == {:error, :invalid}
      open!(ctx.b, top_up("c14", grant: "g"))
      mark = Log.mark()
      assert resume(plain, "c14") == {:error, :invalid}
      assert Log.piece_calls(self(), mark) == []
      assert get!(ctx.b, "c14").steps == []
    end

    test "in_transaction, isolation, unknown checkout and bad requests", ctx do
      open!(ctx.b, top_up("c15"))

      {:ok, result} =
        AppRepo.transaction(fn ->
          [
            resume(ctx.b, "c15"),
            get(ctx.b, "c15"),
            LC.open(ctx.b, "T1", top_up("c16")),
            list(ctx.b, :open)
          ]
        end)

      assert result == List.duplicate({:error, :in_transaction}, 4)

      {:ok, rr} = binding(RepeatableRepo, ctx.p, ctx.lc, ctx.inv, ctx.journal)
      assert LC.open(rr, "T1", top_up("c16")) == {:error, :isolation}
      assert resume(rr, "c15") == {:error, :isolation}
      assert get(rr, "c15") == {:error, :isolation}
      assert list(rr, :open) == {:error, :isolation}

      assert resume(ctx.b, "none") == {:error, :unknown_checkout}
      assert get(ctx.b, "none") == {:error, :unknown_checkout}
      assert LC.resume(ctx.b, "T1", %{checkout_id: "a/b"}) == {:error, :invalid}
      assert LC.resume(ctx.b, "T1", %{checkout_id: "c15", x: 1}) == {:error, :invalid}
      assert LC.resume(:nope, "T1", %{checkout_id: "c15"}) == {:error, :invalid}
      assert Harness.advisory_locks() == 0
    end
  end
end
