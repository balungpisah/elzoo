# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/invoice_test_helper.exs", __DIR__)

defmodule Elzoo.InvoiceTest do
  # The cases share one database server and hold row locks across connections: not async.
  use ExUnit.Case, async: false
  alias Elzoo.Invoice
  alias Elzoo.InvoiceTest.{AppRepo, FaultRepo, Harness, OwnerRepo, RepeatableRepo}
  alias Elzoo.Money
  alias Elzoo.Pricing
  alias Elzoo.TenantIsolation, as: TI

  @moduletag :capture_log
  @denied :insufficient_privilege
  @repos [OwnerRepo, AppRepo, FaultRepo, RepeatableRepo]

  setup_all do
    if Enum.any?(@repos, &Process.whereis/1),
      do: raise("the invoice test Repos are already running")

    role = Harness.start_repos!()
    on_exit(fn -> Enum.each(@repos, &Harness.stop!/1) end)
    {:ok, role: role}
  end

  setup %{role: role} do
    p = Harness.install!(role)
    # on_exit runs last-registered first: the invariants, then the drop.
    on_exit(fn -> Harness.drop!(p) end)
    on_exit(fn -> Harness.assert_invariants!(p) end)
    {:ok, inv} = Invoice.new(repo: AppRepo, prefix: p)
    {:ok, p: p, inv: inv}
  end

  # ------------------------------------------------------------ fixtures

  defp currency(alpha) do
    {:ok, c} = Money.parse(alpha)
    c
  end

  defp money(minor, alpha \\ "EUR") do
    {:ok, a} = Money.from_minor_units(currency(alpha), minor)
    a
  end

  defp create(inv, id, opts \\ []) do
    Invoice.create(inv, Keyword.get(opts, :tenant, "T1"), %{
      invoice_id: id,
      billing_account: Keyword.get(opts, :account, "acct-1"),
      currency: currency(Keyword.get(opts, :alpha, "EUR")),
      series: Keyword.get(opts, :series, "S")
    })
  end

  defp adj(line_id, minor, alpha \\ "EUR"),
    do: {:adjustment, line_id, money(minor, alpha), "adjustment #{line_id}", "ref/#{line_id}"}

  defp add(inv, id, line, tenant \\ "T1"),
    do: Invoice.add_line(inv, tenant, %{invoice_id: id, line: line})

  defp finalize(inv, id, tenant \\ "T1"),
    do: Invoice.finalize(inv, tenant, %{invoice_id: id, issued_at_ms: 1_000, due_at_ms: 2_000})

  defp pay(inv, id, ref, minor, alpha \\ "EUR"),
    do:
      Invoice.apply_payment(inv, "T1", %{
        invoice_id: id,
        payment_ref: ref,
        amount: money(minor, alpha)
      })

  defp reverse(inv, id, rid, ref, amount) do
    amount = if is_integer(amount), do: money(amount), else: amount

    Invoice.reverse_payment(inv, "T1", %{
      invoice_id: id,
      reversal_id: rid,
      payment_ref: ref,
      amount: amount
    })
  end

  defp credit(inv, id, corrects, lines),
    do: Invoice.credit_note(inv, "T1", %{invoice_id: id, corrects: corrects, lines: lines})

  defp void(inv, id) do
    {:ok, %{revision: rev}} = get(inv, id)
    Invoice.void(inv, "T1", %{invoice_id: id, expected_revision: rev})
  end

  defp get(inv, id, tenant \\ "T1"), do: Invoice.get(inv, tenant, %{invoice_id: id})

  defp get!(inv, id) do
    {:ok, d} = get(inv, id)
    d
  end

  # An open invoice of one adjustment line of `minor`.
  defp open!(inv, id, minor, opts \\ []) do
    assert create(inv, id, opts) == {:ok, :applied}
    assert add(inv, id, adj("l1", minor)) == {:ok, :applied}
    assert {:ok, %{duplicate: false}} = finalize(inv, id)
    get!(inv, id)
  end

  # A refusal with this reason that commits nothing.
  defp refused(p, reason, fun) do
    before = Harness.truth(p)
    assert fun.() == {:error, reason}
    assert Harness.truth(p) == before
  end

  # A domain/pricing charge of 250 output tokens at 0.01 EUR each (2.50 EUR); `unknown` adds an
  # observation of unknown amount, which makes it incomplete.
  defp charge(opts \\ []) do
    body = %{
      card_id: "retail",
      version: 1,
      kind: :price,
      currency: currency(Keyword.get(opts, :alpha, "EUR")),
      rounding: :half_up,
      lines: [
        %{
          provider_id: "anthropic",
          model_id: "claude-a",
          unit: :output_tokens,
          rate: "0.01",
          per: 1,
          minimum: nil
        }
      ]
    }

    {:ok, hash} = Pricing.content_hash(body)
    row = &Map.merge(%{provider_id: "anthropic", model_id: "claude-a", unit: :output_tokens}, &1)

    rows =
      [row.(%{source: :provider_reported, known: 250, unknown_count: 0, count: 1})] ++
        if Keyword.get(opts, :unknown, false),
          do: [row.(%{source: :unknown, known: 0, unknown_count: 1, count: 1})],
          else: []

    {:ok, charge} =
      Pricing.price(Map.put(body, :content_hash, hash), %{
        tenant: "T1",
        period: "2026-11",
        rows: rows
      })

    charge
  end

  # A domain/plan fee line, built as data.
  defp fee(minor, alpha \\ "EUR"),
    do: %{
      subscription_id: "sub-1",
      period: %{index: 3, start_ms: 0, end_ms: 10},
      plan: %{plan_id: "pro", version: 2},
      amount: money(minor, alpha)
    }

  # ------------------------------------------------------------ 1 numbering

  test "1 two concurrent finalizations of one series behind the series lock get 1 and 2",
       %{inv: inv, p: p} do
    for id <- ["a", "b"] do
      assert create(inv, id) == {:ok, :applied}
      assert add(inv, id, adj("l1", 100)) == {:ok, :applied}
    end

    # The series row exists, unused, so both finalizations meet it at its lock.
    {:ok, _} =
      TI.transact(OwnerRepo, %{tenant: "T1"}, fn ->
        {:ok,
         Harness.q!(
           OwnerRepo,
           "INSERT INTO #{Harness.table(p, "elzoo_invoice_series")} VALUES ('T1', 'S', 0)"
         )}
      end)

    holder = Harness.hold_series!(p, "T1", "S")
    tasks = for id <- ["a", "b"], do: Task.async(fn -> finalize(inv, id) end)
    Harness.await_waiting!(2)
    Harness.release!(holder)

    results = Enum.map(tasks, &Task.await(&1, 20_000))
    assert Enum.sort(Enum.map(results, fn {:ok, r} -> r.number end)) == [1, 2]
    assert Enum.sort([get!(inv, "a").number, get!(inv, "b").number]) == [1, 2]
  end

  test "1 a finalization that fails after taking its number uses none", %{inv: inv, p: p} do
    {:ok, fault} = Invoice.new(repo: FaultRepo, prefix: p)
    assert create(inv, "f") == {:ok, :applied}
    assert add(inv, "f", adj("l1", 100)) == {:ok, :applied}

    FaultRepo.arm()
    refused(p, :unavailable, fn -> finalize(fault, "f") end)
    # The function had taken number 1 inside the transaction that the forced error rolled back.
    assert_received {:fault_after, {:ok, %{number: 1}}}
    assert get!(inv, "f").state == :draft

    assert {:ok, %{number: 1}} = finalize(inv, "f")
    assert open!(inv, "g", 5).number == 2
  end

  test "1 series are independent and a void keeps its number", %{inv: inv} do
    assert open!(inv, "s1", 100).number == 1
    assert open!(inv, "s2", 100).number == 2
    assert open!(inv, "o1", 100, series: "other").number == 1

    assert void(inv, "s2") == {:ok, :applied}
    assert %{state: :void, number: 2} = get!(inv, "s2")
    assert open!(inv, "s3", 100).number == 3
    assert open!(inv, "o2", 100, series: "other").number == 2
  end

  # ------------------------------------------------------------ 2 lines

  test "2 charge, fee and adjustment lines in the invoice's currency", %{inv: inv, p: p} do
    assert create(inv, "i") == {:ok, :applied}

    refused(p, :incomplete_charge, fn ->
      add(inv, "i", {:charge, "c0", charge(unknown: true), "usage"})
    end)

    c = charge()
    assert c.total == money(250)
    assert add(inv, "i", {:charge, "c1", c, "November usage"}) == {:ok, :applied}
    assert add(inv, "i", {:fee, "f1", fee(1_000), "Pro plan"}) == {:ok, :applied}
    assert add(inv, "i", {:fee, "f0", fee(0), "Free add-on"}) == {:ok, :applied}
    assert add(inv, "i", adj("a1", -50)) == {:error, :invalid}
    assert add(inv, "i", adj("a1", 50)) == {:ok, :applied}

    refused(p, :currency, fn -> add(inv, "i", adj("x", 50, "USD")) end)
    refused(p, :currency, fn -> add(inv, "i", {:charge, "x", charge(alpha: "JPY"), "usage"}) end)
    refused(p, :currency, fn -> add(inv, "i", {:fee, "x", fee(5, "USD"), "fee"}) end)

    # A repeated line_id: equal line duplicate, another line conflict.
    assert add(inv, "i", {:fee, "f1", fee(1_000), "Pro plan"}) == {:ok, :duplicate}
    refused(p, :conflict, fn -> add(inv, "i", {:fee, "f1", fee(1_001), "Pro plan"}) end)

    d = get!(inv, "i")
    assert d.total == money(1_300)

    assert [
             %{line_id: "c1", kind: :usage, amount: usage, source_ref: "retail/1/2026-11"},
             %{line_id: "f1", kind: :fee, amount: plan, source_ref: "sub-1/3"},
             %{line_id: "f0", kind: :fee, source_ref: "sub-1/3"},
             %{line_id: "a1", kind: :adjustment, description: "adjustment a1"}
           ] = d.lines

    assert usage == money(250) and plan == money(1_000)

    assert {:ok, %{number: 1}} = finalize(inv, "i")
    refused(p, {:state, :open}, fn -> add(inv, "i", adj("late", 5)) end)
  end

  # ------------------------------------------------------------ 3 finalize and posting

  test "3 a repeated finalize and mark_posted", %{inv: inv, p: p} do
    assert create(inv, "inv-1") == {:ok, :applied}
    assert create(inv, "inv-1") == {:ok, :duplicate}
    refused(p, :conflict, fn -> create(inv, "inv-1", account: "acct-2") end)
    refused(p, :conflict, fn -> create(inv, "inv-1", series: "T") end)
    refused(p, :conflict, fn -> create(inv, "inv-1", alpha: "USD") end)
    refused(p, :unknown_invoice, fn -> finalize(inv, "none") end)
    refused(p, :invalid, fn -> finalize(inv, "inv-1") end)
    assert add(inv, "inv-1", adj("l1", 100)) == {:ok, :applied}

    refused(p, :invalid, fn ->
      Invoice.finalize(inv, "T1", %{invoice_id: "inv-1", issued_at_ms: 2, due_at_ms: 1})
    end)

    first = %{number: 1, operation_id: "invoice/inv-1/issue", total: money(100), duplicate: false}
    assert finalize(inv, "inv-1") == {:ok, first}
    assert finalize(inv, "inv-1") == {:ok, %{first | duplicate: true}}

    assert %{state: :open, posting: %{operation_id: "invoice/inv-1/issue", state: :pending}} =
             get!(inv, "inv-1")

    mark = fn op, result ->
      Invoice.mark_posted(inv, "T1", %{invoice_id: "inv-1", operation_id: op, result: result})
    end

    assert mark.("invoice/inv-1/issue", :applied) == {:ok, :applied}
    assert get!(inv, "inv-1").posting.state == :posted
    assert mark.("invoice/inv-1/issue", :duplicate) == {:ok, :duplicate}
    refused(p, :conflict, fn -> mark.("invoice/other/issue", :applied) end)
    assert get!(inv, "inv-1").posting.state == :posted
  end

  # ------------------------------------------------------------ 4 payments

  test "4 partial, full, over and repeated payments", %{inv: inv, p: p} do
    open!(inv, "i", 100)
    refused(p, :currency, fn -> pay(inv, "i", "usd", 10, "USD") end)
    assert pay(inv, "i", "p1", 30) == {:ok, :applied}
    assert %{state: :open, paid: paid} = get!(inv, "i")
    assert paid == money(30)

    refused(p, :over_payment, fn -> pay(inv, "i", "p2", 71) end)
    assert pay(inv, "i", "p2", 70) == {:ok, :applied}
    assert %{state: :paid} = get!(inv, "i")

    assert pay(inv, "i", "p1", 30) == {:ok, :duplicate}
    refused(p, :conflict, fn -> pay(inv, "i", "p1", 31) end)
    refused(p, {:state, :paid}, fn -> pay(inv, "i", "p3", 1) end)

    assert create(inv, "d") == {:ok, :applied}
    refused(p, {:state, :draft}, fn -> pay(inv, "d", "p1", 1) end)
  end

  # ------------------------------------------------------------ 5 reversals

  test "5 reversal by amount and by the remaining amount", %{inv: inv, p: p} do
    open!(inv, "i", 100)
    assert pay(inv, "i", "p1", 100) == {:ok, :applied}
    assert get!(inv, "i").state == :paid
    refused(p, :unknown_payment, fn -> reverse(inv, "i", "r0", "nope", 1) end)

    # The host's call after a partial refund of 30; a reversal_id equal to a payment_ref is
    # its own key.
    assert reverse(inv, "i", "p1", "p1", 30) == {:ok, :applied}
    assert %{state: :open, paid: paid} = get!(inv, "i")
    assert paid == money(70)
    assert reverse(inv, "i", "p1", "p1", 30) == {:ok, :duplicate}
    assert get!(inv, "i").paid == money(70)
    refused(p, :conflict, fn -> reverse(inv, "i", "p1", "p1", 31) end)
    refused(p, :conflict, fn -> reverse(inv, "i", "p1", "p1", :remaining) end)

    refused(p, :over_reversal, fn -> reverse(inv, "i", "big", "p1", 71) end)

    # The checkout's compensation takes back what remains, once.
    assert reverse(inv, "i", "checkout-1", "p1", :remaining) == {:ok, :applied}
    assert get!(inv, "i").paid == money(0)
    assert reverse(inv, "i", "checkout-1", "p1", :remaining) == {:ok, :duplicate}
    refused(p, :nothing_applied, fn -> reverse(inv, "i", "checkout-2", "p1", :remaining) end)
    refused(p, :over_reversal, fn -> reverse(inv, "i", "r9", "p1", 1) end)

    t = Harness.truth(p)
    assert Enum.map(t.reversals, &{&1.reversal_id, &1.amount}) == [{"checkout-1", 70}, {"p1", 30}]

    # Paid again by a new payment, the invoice is :paid again.
    assert pay(inv, "i", "p2", 100) == {:ok, :applied}
    assert get!(inv, "i").state == :paid
  end

  # ------------------------------------------------------------ 6 void and credit notes

  test "6 void with nothing paid, with a payment and after a credit note", %{inv: inv, p: p} do
    assert create(inv, "d") == {:ok, :applied}
    assert void(inv, "d") == {:ok, :applied}
    assert %{state: :void, number: nil} = get!(inv, "d")

    open!(inv, "o", 100)
    {:ok, %{revision: rev}} = get(inv, "o")

    refused(p, :stale_revision, fn ->
      Invoice.void(inv, "T1", %{invoice_id: "o", expected_revision: rev - 1})
    end)

    assert void(inv, "o") == {:ok, :applied}
    assert %{state: :void, number: 1} = get!(inv, "o")

    open!(inv, "paid", 100)
    assert pay(inv, "paid", "p1", 10) == {:ok, :applied}
    refused(p, :paid_amount, fn -> void(inv, "paid") end)

    open!(inv, "cr", 100)
    assert credit(inv, "cn", "cr", [adj("c1", -40)]) == {:ok, :applied}
    assert {:ok, %{number: 4}} = finalize(inv, "cn")
    refused(p, :credited, fn -> void(inv, "cr") end)
    refused(p, {:state, :issued}, fn -> void(inv, "cn") end)

    # A draft credit note may be voided.
    assert credit(inv, "cn2", "cr", [adj("c1", -10)]) == {:ok, :applied}
    assert void(inv, "cn2") == {:ok, :applied}
    refused(p, {:state, :void}, fn -> finalize(inv, "cn2") end)
  end

  test "6 a draft credit note of an invoice voided meanwhile is never issued", %{inv: inv, p: p} do
    open!(inv, "i", 100)
    assert credit(inv, "cn", "i", [adj("c1", -40)]) == {:ok, :applied}
    assert void(inv, "i") == {:ok, :applied}
    refused(p, {:state, :void}, fn -> finalize(inv, "cn") end)
    refused(p, {:state, :void}, fn -> credit(inv, "cn3", "i", [adj("c1", -1)]) end)
  end

  test "6 credit notes within the payable", %{inv: inv, p: p} do
    open!(inv, "i", 100)
    refused(p, :over_credit, fn -> credit(inv, "cn0", "i", [adj("c1", -60), adj("c2", -41)]) end)
    refused(p, :invalid, fn -> credit(inv, "cn0", "i", [adj("c1", 10)]) end)
    refused(p, :currency, fn -> credit(inv, "cn0", "i", [adj("c1", -1, "USD")]) end)

    assert credit(inv, "cn1", "i", [adj("c1", -25), adj("c2", -15)]) == {:ok, :applied}
    assert credit(inv, "cn1", "i", [adj("c1", -25), adj("c2", -15)]) == {:ok, :duplicate}
    refused(p, :conflict, fn -> credit(inv, "cn1", "i", [adj("c1", -25)]) end)
    assert %{kind: :credit_note, state: :draft, corrects: "i", number: nil} = get!(inv, "cn1")

    assert {:ok, %{number: 2, operation_id: "invoice/cn1/issue", total: total}} =
             finalize(inv, "cn1")

    assert total == money(-40)

    assert %{state: :issued, series: "S", billing_account: "acct-1", posting: %{state: :pending}} =
             get!(inv, "cn1")

    assert %{state: :open, credited: credited, payable: payable} = get!(inv, "i")
    assert credited == money(40) and payable == money(60)

    refused(p, :over_payment, fn -> pay(inv, "i", "p1", 61) end)
    assert pay(inv, "i", "p1", 60) == {:ok, :applied}
    assert get!(inv, "i").state == :paid
  end

  test "6 two drafts that each fit but together pass the payable", %{inv: inv, p: p} do
    open!(inv, "i", 100)
    assert credit(inv, "a", "i", [adj("c1", -60)]) == {:ok, :applied}
    assert credit(inv, "b", "i", [adj("c1", -50)]) == {:ok, :applied}
    assert {:ok, %{number: 2}} = finalize(inv, "a")
    refused(p, :over_credit, fn -> finalize(inv, "b") end)
    assert get!(inv, "i").credited == money(60)
  end

  test "6 a credit note on a paid invoice shows a credit balance", %{inv: inv} do
    open!(inv, "i", 100)
    assert pay(inv, "i", "p1", 100) == {:ok, :applied}
    assert credit(inv, "cn", "i", [adj("c1", -40)]) == {:ok, :applied}
    assert {:ok, %{number: 2}} = finalize(inv, "cn")
    assert %{state: :paid, credit_balance: balance, paid: paid} = get!(inv, "i")
    assert balance == money(40) and paid == money(100)

    # A credit note that leaves paid equal to the payable makes an open invoice :paid.
    open!(inv, "j", 100)
    assert pay(inv, "j", "p1", 70) == {:ok, :applied}
    assert credit(inv, "cnj", "j", [adj("c1", -30)]) == {:ok, :applied}
    assert {:ok, %{number: 4}} = finalize(inv, "cnj")
    assert %{state: :paid, credit_balance: zero} = get!(inv, "j")
    assert zero == money(0)
  end

  test "6 a zero-total invoice finalizes :paid with no posting", %{inv: inv, p: p} do
    assert create(inv, "z") == {:ok, :applied}
    assert add(inv, "z", {:fee, "f0", fee(0), "Free plan"}) == {:ok, :applied}

    assert finalize(inv, "z") ==
             {:ok, %{number: 1, operation_id: nil, total: money(0), duplicate: false}}

    assert %{state: :paid, posting: nil} = get!(inv, "z")

    refused(p, :conflict, fn ->
      Invoice.mark_posted(inv, "T1", %{
        invoice_id: "z",
        operation_id: "invoice/z/issue",
        result: :applied
      })
    end)

    # An invoice takes no negative line; a credit note whose total is not negative is
    # :invalid_total at its finalize/3.
    assert create(inv, "n") == {:ok, :applied}
    assert add(inv, "n", adj("l1", -11)) == {:error, :invalid}
    assert add(inv, "n", adj("l1", 10)) == {:ok, :applied}
    assert {:ok, _} = finalize(inv, "n")
    assert credit(inv, "cn", "n", [adj("c1", -5)]) == {:ok, :applied}
    assert add(inv, "cn", adj("c2", 5)) == {:ok, :applied}
    refused(p, :invalid_total, fn -> finalize(inv, "cn") end)
  end

  # ------------------------------------------------------------ 7 row security and Needs

  test "7 row security as the application role", %{inv: inv, p: p, role: role} do
    Harness.role_guard!(role)
    assert Invoice.verify(inv) == :ok

    assert create(inv, "t2", tenant: "T2") == {:ok, :applied}
    assert add(inv, "t2", adj("l1", 100), "T2") == {:ok, :applied}
    assert {:ok, %{number: 1}} = finalize(inv, "t2", "T2")

    refused(p, :unknown_invoice, fn -> get(inv, "t2") end)
    refused(p, :unknown_invoice, fn -> pay(inv, "t2", "p1", 1) end)
    refused(p, :unknown_invoice, fn -> finalize(inv, "t2") end)
    refused(p, :unknown_invoice, fn -> credit(inv, "cn", "t2", [adj("c1", -1)]) end)

    # T1's series S starts at 1, independent of T2's.
    assert open!(inv, "t1", 100).number == 1
    assert pay(inv, "t1", "p1", 40) == {:ok, :applied}
    assert reverse(inv, "t1", "r1", "p1", 10) == {:ok, :applied}

    probe = fn sql ->
      {:error, {:probe, result}} =
        TI.transact(AppRepo, %{tenant: "T1"}, fn -> {:error, {:probe, Harness.q(AppRepo, sql)}} end)

      result
    end

    for t <- Harness.tables() do
      assert {:ok, %{rows: [["T1"]]}} = probe.("SELECT DISTINCT tenant FROM #{Harness.table(p, t)}")
    end

    zero = "'" <> elem(Money.Codec.encode(money(0)), 1) <> "'"

    for sql <- [
          "INSERT INTO #{Harness.table(p, "elzoo_invoices")} (tenant, invoice_id, kind, billing_account, currency, series, state, total, paid, credited, revision, request_digest) VALUES ('T2', 'x', 'invoice', 'a', #{zero}, 'S', 'draft', #{zero}, #{zero}, #{zero}, 1, decode(repeat('00', 32), 'hex'))",
          "INSERT INTO #{Harness.table(p, "elzoo_invoice_lines")} VALUES ('T2', 't2', 'x', 2, 'fee', 'd', #{zero}, 'r')",
          "INSERT INTO #{Harness.table(p, "elzoo_invoice_applications")} VALUES ('T2', 't2', 'x', #{zero})",
          "INSERT INTO #{Harness.table(p, "elzoo_invoice_reversals")} VALUES ('T2', 't2', 'x', 'p', 'remaining', #{zero})",
          "INSERT INTO #{Harness.table(p, "elzoo_invoice_series")} VALUES ('T2', 'other', 0)"
        ],
        do: assert({:error, %Postgrex.Error{postgres: %{code: @denied}}} = probe.(sql))

    for t <- Harness.tables(),
        do:
          assert(
            {:error, %Postgrex.Error{postgres: %{code: @denied}}} =
              probe.("DELETE FROM #{Harness.table(p, t)}")
          )
  end

  test "7 a caller transaction, a repeatable read Repo and a missing schema", %{inv: inv, p: p} do
    open!(inv, "i", 100)
    assert pay(inv, "i", "p1", 10) == {:ok, :applied}
    assert create(inv, "d") == {:ok, :applied}
    me = self()
    handler = "elz367-#{System.unique_integer()}"

    calls = fn b ->
      [
        Invoice.create(b, "T1", %{
          invoice_id: "n",
          billing_account: "a",
          currency: currency("EUR"),
          series: "S"
        }),
        Invoice.add_line(b, "T1", %{invoice_id: "d", line: adj("l1", 1)}),
        Invoice.finalize(b, "T1", %{invoice_id: "d", issued_at_ms: 1, due_at_ms: 1}),
        Invoice.mark_posted(b, "T1", %{
          invoice_id: "i",
          operation_id: "invoice/i/issue",
          result: :applied
        }),
        Invoice.apply_payment(b, "T1", %{invoice_id: "i", payment_ref: "p2", amount: money(1)}),
        Invoice.reverse_payment(b, "T1", %{
          invoice_id: "i",
          reversal_id: "r",
          payment_ref: "p1",
          amount: :remaining
        }),
        Invoice.void(b, "T1", %{invoice_id: "d", expected_revision: 1}),
        Invoice.credit_note(b, "T1", %{invoice_id: "cn", corrects: "i", lines: [adj("c", -1)]})
      ]
    end

    {:ok, results} =
      AppRepo.transaction(fn ->
        :telemetry.attach(
          handler,
          [:elzoo, :invoice_test, :app_repo, :query],
          fn _, _, meta, _ -> send(me, {:query, meta.query}) end,
          nil
        )

        results = calls.(inv) ++ [get(inv, "i")]
        :telemetry.detach(handler)
        results
      end)

    assert results == List.duplicate({:error, :in_transaction}, 9)
    refute_received {:query, _}

    {:ok, rr} = Invoice.new(repo: RepeatableRepo, prefix: p)
    before = Harness.truth(p)
    assert calls.(rr) == List.duplicate({:error, :isolation}, 8)
    assert Harness.truth(p) == before
    assert {:ok, %{paid: paid}} = get(rr, "i")
    assert paid == money(10)

    {:ok, missing} = Invoice.new(repo: AppRepo, prefix: "elz367_missing")
    assert calls.(missing) ++ [get(missing, "i")] == List.duplicate({:error, :unavailable}, 9)
    assert {:error, _} = Invoice.verify(missing)
    assert Harness.truth(p) == before
  end

  # ------------------------------------------------------------ bounds

  test "bounds of new/1, the migration and request texts", %{inv: inv, p: p} do
    for opts <- [
          [],
          [repo: AppRepo],
          [repo: AppRepo, prefix: "Bad"],
          [repo: nil, prefix: "x"],
          [repo: AppRepo, prefix: "x", extra: 1],
          %{repo: AppRepo, prefix: "x"}
        ],
        do: assert(Invoice.new(opts) == {:error, :invalid})

    assert_raise ArgumentError, fn -> Elzoo.Invoice.Migration.install("bad-prefix") end

    id100 = String.duplicate("i", 100)

    assert create(inv, id100,
             account: String.duplicate("a", 128),
             series: String.duplicate("s", 128)
           ) == {:ok, :applied}

    assert add(
             inv,
             id100,
             {:adjustment, String.duplicate("l", 128), money(1), String.duplicate("é", 512),
              String.duplicate("r", 256)}
           ) == {:ok, :applied}

    assert {:ok, %{operation_id: op}} = finalize(inv, id100)
    assert byte_size(op) == 114

    refused(p, :invalid, fn -> create(inv, id100 <> "i") end)
    refused(p, :invalid, fn -> create(inv, "x", account: String.duplicate("a", 129)) end)
    refused(p, :invalid, fn -> create(inv, "x", series: String.duplicate("s", 129)) end)
    refused(p, :invalid, fn -> create(inv, "x", series: "s\n") end)
    refused(p, :invalid, fn -> create(inv, "x", tenant: String.duplicate("t", 129)) end)

    assert create(inv, "d") == {:ok, :applied}

    for line <- [
          {:adjustment, String.duplicate("l", 129), money(1), "d", "r"},
          {:adjustment, "l", money(1), String.duplicate("d", 1025), "r"},
          {:adjustment, "l", money(1), "", "r"},
          {:adjustment, "l", money(1), "d", String.duplicate("r", 257)},
          {:adjustment, "l", money(0), "d", "r"},
          {:fee, "l", %{fee(1) | subscription_id: 1}, "d"},
          {:charge, "l",
           %{
             charge()
             | card: %{card_id: String.duplicate("c", 128), version: 1},
               period: String.duplicate("p", 128)
           }, "d"},
          {:other, "l"}
        ],
        do: refused(p, :invalid, fn -> add(inv, "d", line) end)

    for n <- 1..256, do: assert(add(inv, "d", adj("l#{n}", 1)) == {:ok, :applied})
    refused(p, :invalid, fn -> add(inv, "d", adj("l257", 1)) end)
    assert length(get!(inv, "d").lines) == 256

    open!(inv, "c", 300)
    refused(p, :invalid, fn -> credit(inv, "cn", "c", []) end)
    refused(p, :invalid, fn -> credit(inv, "cn", "c", Enum.map(1..257, &adj("c#{&1}", -1))) end)
    refused(p, :invalid, fn -> credit(inv, "cn", "c", [adj("c1", -1), adj("c1", -1)]) end)
    refused(p, :invalid, fn -> credit(inv, "cn", "c", [{:fee, "f", fee(1), "d"}]) end)
    assert credit(inv, "cn", "c", Enum.map(1..256, &adj("c#{&1}", -1))) == {:ok, :applied}
    refused(p, :invalid, fn -> pay(inv, "c", String.duplicate("p", 257), 1) end)
    refused(p, :invalid, fn -> reverse(inv, "c", String.duplicate("r", 257), "p", 1) end)
    refused(p, :invalid, fn -> reverse(inv, "c", "r", "p", money(0)) end)
    refused(p, :invalid, fn -> Invoice.get(inv, "T1", %{invoice_id: "c", extra: 1}) end)
  end
end
