# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/journal_test_helper.exs", __DIR__)

defmodule Elzoo.JournalTest do
  # The cases share one database server and hold row locks across connections: not async.
  use ExUnit.Case, async: false
  alias Elzoo.Journal
  alias Elzoo.JournalTest.{AppRepo, Harness, OwnerRepo, RepeatableRepo}
  alias Elzoo.Money
  alias Elzoo.Money.{Amount, Registry}
  alias Elzoo.TenantIsolation, as: TI

  @moduletag :capture_log
  @denied :insufficient_privilege
  @message "invalid journal prefix or options"
  @bound Integer.pow(10, 38)

  setup_all do
    pids = Enum.map([OwnerRepo, AppRepo, RepeatableRepo], &Process.whereis/1)
    if Enum.any?(pids), do: raise("the journal test Repos are already running")
    role = Harness.start_repos!()

    on_exit(fn ->
      Harness.stop_repos!(Enum.map([OwnerRepo, AppRepo, RepeatableRepo], &Process.whereis/1))
    end)

    {:ok, role: role}
  end

  setup %{role: role} do
    p = Harness.install!(role)
    # on_exit runs last-registered first: the invariants, then the drop.
    on_exit(fn -> Harness.drop!(p) end)
    on_exit(fn -> Harness.assert_invariants!(p) end)
    {:ok, p: p, j: Journal.new(repo: AppRepo, prefix: p)}
  end

  # ------------------------------------------------------------ fixtures

  defp currency(alpha, opts \\ []) do
    {:ok, c} = Money.parse(alpha, opts)
    c
  end

  defp eur, do: currency("EUR")

  defp amount(c, units, opts \\ []) do
    {:ok, a} = Money.from_minor_units(c, units, opts)
    a
  end

  defp open!(j, tenant \\ "T1", id, c, allow) do
    assert {:ok, :applied} =
             Journal.open_account(j, tenant, %{account_id: id, currency: c, allow_negative: allow})
  end

  defp request(id, c, pairs, opts \\ []) do
    %{
      operation_id: id,
      actor_ref: Keyword.get(opts, :actor, "actor-1"),
      reason: Keyword.get(opts, :reason, "test"),
      postings:
        Enum.map(pairs, fn {account, units} -> %{account_id: account, amount: amount(c, units)} end)
    }
  end

  defp post(j, tenant \\ "T1", id, c, pairs), do: Journal.post(j, tenant, request(id, c, pairs))

  defp reverse(j, tenant \\ "T1", id, target),
    do:
      Journal.reverse(j, tenant, %{
        operation_id: id,
        reverses: target,
        actor_ref: "actor-1",
        reason: "undo"
      })

  defp units(j, tenant \\ "T1", id) do
    {:ok, %Amount{minor_units: u}} = Journal.balance(j, tenant, id)
    u
  end

  defp history(j, id, after_version \\ nil, limit \\ 1000),
    do: Journal.history(j, "T1", %{account_id: id, after: after_version, limit: limit})

  # A refusal with this reason that commits nothing.
  defp refused(p, reason, fun) do
    before = Harness.truth(p)
    assert fun.() == {:error, reason}
    assert Harness.truth(p) == before
  end

  # `fun`'s result and the statements it sent to AppRepo, read from the Repo's query telemetry,
  # without transaction control and the set_config pair of TenantIsolation.transact/3.
  defp statements(fun) do
    :ok =
      :telemetry.attach("elz314-statements", [:elz297, :app, :query], &Harness.forward/4, self())

    try do
      result = fun.()
      {result, own(sent([]))}
    after
      :telemetry.detach("elz314-statements")
    end
  end

  defp sent(acc) do
    receive do
      {:app_query, sql} -> sent([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Only in their places: begin and transact/3's set first, then its clear and commit last, or a
  # rollback alone after a refusal. Every statement between them is the function's own.
  defp own(["begin", "SELECT set_config('elzoo.tenant_id', $1::text, true)" <> _ | rest]) do
    case Enum.reverse(rest) do
      ["commit", "SELECT set_config('elzoo.tenant_id', '', true)" <> _ | own] -> Enum.reverse(own)
      ["rollback" | own] -> Enum.reverse(own)
    end
  end

  # ------------------------------------------------------------ 1

  describe "1 balanced post and refusals" do
    test "a balanced post across a receivable, a revenue and a wallet account", %{j: j} do
      open!(j, "receivable", eur(), true)
      open!(j, "revenue", eur(), true)
      open!(j, "wallet", eur(), false)

      assert {:ok, :applied} =
               post(j, "op-1", eur(), [{"receivable", 1500}, {"revenue", -2000}, {"wallet", 500}])

      assert Journal.balance(j, "T1", "receivable") == {:ok, amount(eur(), 1500)}
      assert Journal.balance(j, "T1", "revenue") == {:ok, amount(eur(), -2000)}
      assert Journal.balance(j, "T1", "wallet") == {:ok, amount(eur(), 500)}

      assert history(j, "wallet") ==
               {:ok,
                %{
                  entries: [
                    %{
                      version: 1,
                      operation_id: "op-1",
                      reverses: nil,
                      amount: amount(eur(), 500),
                      balance: amount(eur(), 500)
                    }
                  ],
                  next: nil
                }}

      # Each account has its own currency: a JPY pair beside the EUR accounts.
      jpy = currency("JPY")
      open!(j, "jpy-a", jpy, true)
      open!(j, "jpy-b", jpy, false)
      assert {:ok, :applied} = post(j, "op-jpy", jpy, [{"jpy-a", -1000}, {"jpy-b", 1000}])
      assert Journal.balance(j, "T1", "jpy-b") == {:ok, amount(jpy, 1000)}
    end

    test "each refusal commits nothing", %{j: j, p: p} do
      usd = currency("USD")
      open!(j, "receivable", eur(), true)
      open!(j, "revenue", eur(), true)
      open!(j, "wallet", eur(), false)
      open!(j, "usd", usd, true)

      refused(p, :invalid, fn -> post(j, "x", eur(), [{"receivable", 100}]) end)

      many = for i <- 1..64, do: {"acct-#{i}", 1}
      refused(p, :invalid, fn -> post(j, "x", eur(), many ++ [{"acct-65", -64}]) end)

      refused(p, :invalid, fn ->
        post(j, "x", eur(), [{"receivable", 100}, {"receivable", -100}])
      end)

      refused(p, :invalid, fn ->
        post(j, "x", eur(), [{"receivable", 100}, {"revenue", -100}, {"wallet", 0}])
      end)

      forged = %{amount(eur(), 100) | currency: %{eur() | status: {:retired, "2001-01"}}}
      unheld = %{amount(eur(), 100) | currency: %{eur() | version: "1999-01-01"}}

      for bad <- [forged, unheld, %{amount(eur(), 100) | minor_units: 1.0}] do
        r = request("x", eur(), [{"receivable", -100}])
        r = %{r | postings: r.postings ++ [%{account_id: "revenue", amount: bad}]}
        refused(p, :invalid, fn -> Journal.post(j, "T1", r) end)
      end

      mixed = %{
        request("x", eur(), [{"receivable", 100}])
        | postings: [
            %{account_id: "receivable", amount: amount(eur(), 100)},
            %{account_id: "usd", amount: amount(usd, -100)}
          ]
      }

      refused(p, :currency_mismatch, fn -> Journal.post(j, "T1", mixed) end)

      refused(p, :unbalanced, fn -> post(j, "x", eur(), [{"receivable", 100}, {"revenue", -99}]) end)

      refused(p, :currency_mismatch, fn ->
        post(j, "x", eur(), [{"receivable", 100}, {"usd", -100}])
      end)

      refused(p, :unknown_account, fn ->
        post(j, "x", eur(), [{"receivable", 100}, {"nobody", -100}])
      end)

      # A balance one minor unit past the money range, on either side.
      open!(j, "big-a", eur(), true)
      open!(j, "big-b", eur(), true)

      assert {:ok, :applied} =
               post(j, "max", eur(), [{"big-a", @bound - 1}, {"big-b", -(@bound - 1)}])

      refused(p, :amount_range, fn -> post(j, "x", eur(), [{"big-a", 1}, {"receivable", -1}]) end)
      refused(p, :amount_range, fn -> post(j, "x", eur(), [{"big-b", -1}, {"receivable", 1}]) end)
    end

    test "text bounds: 0 and 129 bytes, invalid UTF-8, C0 and C1 refused; 128 accepted", %{
      j: j,
      p: p
    } do
      at = &String.duplicate("a", &1)
      bad = ["", at.(129), <<0xFF>>, "a\u0001", "a\u0085", "a\u007F"]
      bad_reason = ["", at.(257), <<0xC3>>, "a\n", "a\u009F"]
      open!(j, "receivable", eur(), true)
      open!(j, "revenue", eur(), true)
      open!(j, at.(128), eur(), true)
      open!(j, at.(128), "receivable", eur(), true)
      open!(j, at.(128), "revenue", eur(), true)
      base = request("op", eur(), [{"receivable", 100}, {"revenue", -100}])

      for value <- bad do
        refused(p, :invalid, fn -> Journal.post(j, value, base) end)

        for key <- [:operation_id, :actor_ref],
            do: refused(p, :invalid, fn -> Journal.post(j, "T1", Map.put(base, key, value)) end)

        refused(p, :invalid, fn -> post(j, "op", eur(), [{value, 100}, {"revenue", -100}]) end)

        refused(p, :invalid, fn ->
          Journal.open_account(j, "T1", %{account_id: value, currency: eur(), allow_negative: true})
        end)

        refused(p, :invalid, fn ->
          Journal.open_account(j, value, %{account_id: "c", currency: eur(), allow_negative: true})
        end)

        undo = %{operation_id: "r", reverses: "op-2", actor_ref: "a", reason: "r"}

        for key <- [:operation_id, :reverses, :actor_ref],
            do: refused(p, :invalid, fn -> Journal.reverse(j, "T1", Map.put(undo, key, value)) end)

        refused(p, :invalid, fn -> Journal.reverse(j, value, undo) end)

        for f <- [&Journal.balance(j, &1, "revenue"), &Journal.balance(j, "T1", &1)],
            do: assert(f.(value) == {:error, :invalid})

        for {tenant, id} <- [{value, "revenue"}, {"T1", value}],
            do:
              assert(
                Journal.history(j, tenant, %{account_id: id, after: nil, limit: 1}) ==
                  {:error, :invalid}
              )
      end

      for value <- bad_reason do
        refused(p, :invalid, fn -> Journal.post(j, "T1", %{base | reason: value}) end)

        refused(p, :invalid, fn ->
          Journal.reverse(j, "T1", %{
            operation_id: "r",
            reverses: "x",
            actor_ref: "a",
            reason: value
          })
        end)
      end

      assert {:ok, :applied} = Journal.post(j, at.(128), %{base | operation_id: at.(128)})

      assert {:ok, :applied} =
               Journal.post(j, "T1", %{base | operation_id: at.(128), actor_ref: at.(128)})

      assert {:ok, :applied} =
               Journal.reverse(j, "T1", %{
                 operation_id: "r-128",
                 reverses: at.(128),
                 actor_ref: at.(128),
                 reason: at.(256)
               })

      assert {:ok, :applied} =
               Journal.post(j, "T1", %{base | operation_id: "op-3", reason: at.(256)})

      assert {:ok, :applied} = post(j, "op-4", eur(), [{at.(128), 100}, {"revenue", -100}])
      assert units(j, at.(128)) == 100
      assert units(j, at.(128), "receivable") == 100
    end

    test "open_account: duplicate, conflict, invalid currency and journal options", %{j: j, p: p} do
      open!(j, "a", eur(), false)

      assert Journal.open_account(j, "T1", %{
               account_id: "a",
               currency: eur(),
               allow_negative: false
             }) ==
               {:ok, :duplicate}

      refused(p, :conflict, fn ->
        Journal.open_account(j, "T1", %{account_id: "a", currency: eur(), allow_negative: true})
      end)

      refused(p, :conflict, fn ->
        Journal.open_account(j, "T1", %{
          account_id: "a",
          currency: currency("USD"),
          allow_negative: false
        })
      end)

      # A unit-less code (N.A.), a retired code with no recorded exponent and a forged value.
      {:ok, xau} = Money.parse("XAU")
      {:ok, retired} = Money.parse("FIM")

      for c <- [xau, retired, %{eur() | numeric: 1}, "EUR"] do
        refused(p, :invalid, fn ->
          Journal.open_account(j, "T1", %{account_id: "b", currency: c, allow_negative: true})
        end)
      end

      refused(p, :invalid, fn ->
        Journal.open_account(j, "T1", %{account_id: "b", currency: eur(), allow_negative: nil})
      end)

      for opts <- [
            [repo: AppRepo],
            [prefix: p],
            [repo: AppRepo, prefix: "Bad"],
            [repo: AppRepo, prefix: ~s(x"; DROP SCHEMA x; --)],
            [repo: AppRepo, prefix: p, registry: %{}],
            [repo: AppRepo, prefix: p, other: 1],
            [repo: AppRepo, prefix: p, prefix: p],
            %{repo: AppRepo, prefix: p}
          ] do
        assert_raise ArgumentError, @message, fn -> Journal.new(opts) end
      end

      assert_raise ArgumentError, @message, fn -> Elzoo.Journal.Migration.install("1bad") end
      assert Journal.balance(%{j | prefix: "Bad"}, "T1", "a") == {:error, :invalid}
    end

    test "new/1 takes only a registry that Registry.check/1 accepts and keeps it checked",
         %{j: j, p: p} do
      default = Registry.default()
      v = Registry.latest(default)

      # Forged checked values: the struct with a closure that Registry did not make, alone and
      # with the registry keys that journal/1's key-shape check reads.
      forged = [
        %Registry.Checked{read: fn -> default end},
        Map.merge(default, %{__struct__: Registry.Checked, read: fn -> default end})
      ]

      # Each raw map has the versions list and snapshots map that journal/1 checks per call.
      for registry <-
            [
              %{versions: ["bogus"], snapshots: %{}},
              %{versions: ["bogus"], snapshots: %{}, active_numeric: %{}, sources: %{}},
              put_in(default, [:snapshots, v, "EUR", :numeric], 1000),
              Map.delete(default, :active_numeric),
              Map.delete(default, :sources)
            ] ++ forged do
        refute Registry.valid?(registry)

        assert_raise ArgumentError, @message, fn ->
          Journal.new(repo: AppRepo, prefix: p, registry: registry)
        end
      end

      # A journal value that holds a forged checked value is refused on each call.
      for registry <- forged do
        assert Journal.balance(%{j | registry: registry}, "T1", "a") == {:error, :invalid}
      end

      newer = Registry.build!([Harness.extract(), Harness.derived("2027-01-01", [], [])])
      {:ok, checked} = Registry.check(newer)

      # The default stays the default; a raw custom registry is kept as its checked value, never
      # as the raw map; a checked value is kept as given.
      assert %Journal{registry: ^default} = Journal.new(repo: AppRepo, prefix: p, registry: default)
      assert %Journal{registry: ^default} = Journal.new(repo: AppRepo, prefix: p)

      assert %Journal{registry: %Registry.Checked{} = kept} =
               Journal.new(repo: AppRepo, prefix: p, registry: newer)

      refute kept === newer
      assert Registry.versions(kept) == newer.versions
      assert %Journal{registry: ^checked} = Journal.new(repo: AppRepo, prefix: p, registry: checked)
    end

    test "the default, a raw custom registry and its checked value give the same results",
         %{p: p} do
      default = Registry.default()
      v = Registry.latest(default)

      # The default's version and EUR entry with another ISK exponent: a custom registry.
      raw =
        Registry.build!([
          Harness.derived(v, [], [{"current\tISK\t352\t0\t", "current\tISK\t352\t2\t"}])
        ])

      refute raw === default
      {:ok, checked} = Registry.check(raw)

      results =
        for {tenant, registry} <- [{"T1", default}, {"T2", raw}, {"T3", checked}] do
          j = Journal.new(repo: AppRepo, prefix: p, registry: registry)
          open!(j, tenant, "a", eur(), true)
          open!(j, tenant, "b", eur(), false)
          posts = for n <- 1..3, do: post(j, tenant, "op-#{n}", eur(), [{"a", -n}, {"b", n}])
          page = &Journal.history(j, tenant, %{account_id: "b", after: &1, limit: 2})
          {posts, Journal.balance(j, tenant, "b"), page.(nil), page.(2)}
        end

      entry = fn version, units, balance ->
        %{
          version: version,
          operation_id: "op-#{version}",
          reverses: nil,
          amount: amount(eur(), units),
          balance: amount(eur(), balance)
        }
      end

      expected =
        {[{:ok, :applied}, {:ok, :applied}, {:ok, :applied}], {:ok, amount(eur(), 6)},
         {:ok, %{entries: [entry.(1, 1, 1), entry.(2, 2, 3)], next: 2}},
         {:ok, %{entries: [entry.(3, 3, 6)], next: nil}}}

      assert results == [expected, expected, expected]
    end
  end

  # ------------------------------------------------------------ 2

  test "2 two concurrent debits of a wallet whose balance covers one", %{j: j, p: p} do
    open!(j, "revenue", eur(), true)
    open!(j, "wallet", eur(), false)
    open!(j, "x-merchant", eur(), true)
    assert {:ok, :applied} = post(j, "fund", eur(), [{"revenue", -100}, {"wallet", 100}])

    holder = Harness.hold!(p, "T1", "wallet")

    tasks =
      for id <- ["debit-1", "debit-2"],
          do: Task.async(fn -> post(j, id, eur(), [{"wallet", -70}, {"x-merchant", 70}]) end)

    # Both wait on the wallet row: the first on the holder, the second behind the first.
    Harness.await_blocked!(2)
    Harness.release!(holder)
    results = Enum.map(tasks, &Task.await(&1, 30_000))

    assert Enum.sort(results) == [{:error, :insufficient_funds}, {:ok, :applied}]
    assert units(j, "wallet") == 30
    assert units(j, "x-merchant") == 70
  end

  # ------------------------------------------------------------ 3

  test "3 lock order: postings A,B and B,A both wait on A and both commit", %{j: j, p: p} do
    # Byte order (COLLATE "C") puts "B-acct" before "a-acct"; a linguistic collation would not,
    # and the NOWAIT probes of B below tell the two apart.
    a = "B-acct"
    b = "a-acct"
    open!(j, a, eur(), true)
    open!(j, b, eur(), true)

    holder = Harness.hold!(p, "T1", a)
    one = Task.async(fn -> post(j, "op-1", eur(), [{a, 10}, {b, -10}]) end)
    Harness.await_blocked_by!(holder, 1)
    # Neither post may hold B while it waits: a lock order that takes "a-acct" first makes a
    # probe :locked (55P03). The probes are asserted after the commits, so that a posting-order
    # lock first shows as the deadlock that the negative control names.
    probe_one = Harness.nowait!(p, "T1", b)
    two = Task.async(fn -> post(j, "op-2", eur(), [{b, 5}, {a, -5}]) end)
    # The second waits on A behind the first (the row's tuple lock), not on B.
    Harness.await_blocked!(2)
    probe_two = Harness.nowait!(p, "T1", b)
    Harness.release!(holder)

    assert Task.await(one, 30_000) == {:ok, :applied}
    assert Task.await(two, 30_000) == {:ok, :applied}
    assert {probe_one, probe_two} == {:free, :free}
    assert {units(j, a), units(j, b)} == {5, -5}
  end

  # ------------------------------------------------------------ 4

  describe "4 replay and conflict" do
    test "the same request is applied then duplicate; another request is a conflict", %{j: j, p: p} do
      open!(j, "a", eur(), true)
      open!(j, "b", eur(), true)
      r = request("op", eur(), [{"a", 100}, {"b", -100}])
      assert Journal.post(j, "T1", r) == {:ok, :applied}
      assert Journal.post(j, "T1", r) == {:ok, :duplicate}
      # Posting order is not part of the request digest.
      assert Journal.post(j, "T1", %{r | postings: Enum.reverse(r.postings)}) == {:ok, :duplicate}
      assert {units(j, "a"), units(j, "b")} == {100, -100}

      refused(p, :conflict, fn -> post(j, "op", eur(), [{"a", 101}, {"b", -101}]) end)
      refused(p, :conflict, fn -> Journal.post(j, "T1", %{r | actor_ref: "actor-2"}) end)
      refused(p, :conflict, fn -> Journal.post(j, "T1", %{r | reason: "other"}) end)
      refused(p, :conflict, fn -> reverse(j, "op", "op-0") end)
      # The same ID in another tenant is another operation.
      open!(j, "T2", "a", eur(), true)
      open!(j, "T2", "b", eur(), true)
      assert Journal.post(j, "T2", r) == {:ok, :applied}
    end

    test "the stored request digest is the README encoding (known answers)", %{j: j, p: p} do
      open!(j, "a", eur(), true)
      open!(j, "b", eur(), true)
      assert {:ok, :applied} = post(j, "op-d", eur(), [{"b", -100}, {"a", 100}])
      assert reverse(j, "undo-d", "op-d") == {:ok, :applied}

      # Built here from the README text, not by the Piece: length-prefixed fields after the tag,
      # postings in byte order of account_id, amounts as identity and minor units.
      field = fn name, value ->
        <<byte_size(name)::32, name::binary, byte_size(value)::32, value::binary>>
      end

      posting = fn id, units ->
        field.(
          "posting",
          field.("account_id", id) <>
            field.("alpha", "EUR") <>
            field.("numeric", "978") <>
            field.("minor_unit", "2") <> field.("minor_units", units)
        )
      end

      tag = "elzoo-journal-request/1"

      post_bytes =
        tag <>
          field.("kind", "post") <>
          field.("operation_id", "op-d") <>
          field.("actor_ref", "actor-1") <>
          field.("reason", "test") <>
          field.("postings", posting.("a", "100") <> posting.("b", "-100"))

      reverse_bytes =
        tag <>
          field.("kind", "reverse") <>
          field.("operation_id", "undo-d") <>
          field.("reverses", "op-d") <>
          field.("actor_ref", "actor-1") <> field.("reason", "undo")

      stored = Map.new(Harness.truth(p).operations, &{&1.key, &1.digest})
      assert stored[{"T1", "op-d"}] == :crypto.hash(:sha256, post_bytes)
      assert stored[{"T1", "undo-d"}] == :crypto.hash(:sha256, reverse_bytes)

      # Pinned values (SHA-256 computed outside Elixir): a change of the encoding fails here,
      # since it would turn every replay of an existing operation into a conflict.
      assert Base.encode16(stored[{"T1", "op-d"}], case: :lower) ==
               "bd9d6ec59800cdbd71a958efe741883a816546c6d245d1afd6542ad820c28b68"

      assert Base.encode16(stored[{"T1", "undo-d"}], case: :lower) ==
               "4d048a5b493929d615c82d797b29e90c3cfc70ba2a36f72b4ea2f0d831881544"
    end

    test "two concurrent posts of one request commit once", %{j: j, p: p} do
      open!(j, "a", eur(), true)
      open!(j, "b", eur(), true)
      r = request("op", eur(), [{"a", 100}, {"b", -100}])
      holder = Harness.hold!(p, "T1", "a")
      tasks = for _ <- 1..2, do: Task.async(fn -> Journal.post(j, "T1", r) end)
      # The first waits on the row lock; the second on the first's operation row.
      Harness.await_blocked!(2)
      Harness.release!(holder)

      assert Enum.sort(Enum.map(tasks, &Task.await(&1, 30_000))) ==
               [{:ok, :applied}, {:ok, :duplicate}]

      assert {units(j, "a"), units(j, "b")} == {100, -100}
    end
  end

  # ------------------------------------------------------------ 5

  describe "5 reversal" do
    test "restores balances, is linked, replays and refuses", %{j: j, p: p} do
      open!(j, "revenue", eur(), true)
      open!(j, "wallet", eur(), false)
      assert {:ok, :applied} = post(j, "sale", eur(), [{"revenue", -100}, {"wallet", 100}])
      assert reverse(j, "undo", "sale") == {:ok, :applied}
      assert {units(j, "revenue"), units(j, "wallet")} == {0, 0}

      assert {:ok, %{entries: [first, second], next: nil}} = history(j, "wallet")
      assert %{version: 1, operation_id: "sale", reverses: nil} = first
      assert %{version: 2, operation_id: "undo", reverses: "sale"} = second
      assert second.amount == amount(eur(), -100) and second.balance == amount(eur(), 0)

      assert reverse(j, "undo", "sale") == {:ok, :duplicate}
      refused(p, :conflict, fn -> reverse(j, "undo", "other") end)
      refused(p, :already_reversed, fn -> reverse(j, "undo-2", "sale") end)
      refused(p, :not_reversible, fn -> reverse(j, "undo-3", "undo") end)
      refused(p, :unknown_operation, fn -> reverse(j, "undo-4", "nothing") end)
      refused(p, :invalid, fn -> reverse(j, "same", "same") end)
      # Another tenant's operation is unknown.
      refused(p, :unknown_operation, fn -> reverse(j, "T2", "undo-5", "sale") end)
    end

    test "two racing reversals with different IDs: one applies, one is already_reversed",
         %{j: j, p: p} do
      open!(j, "revenue", eur(), true)
      open!(j, "wallet", eur(), false)
      assert {:ok, :applied} = post(j, "sale", eur(), [{"revenue", -100}, {"wallet", 100}])
      holder = Harness.hold!(p, "T1", "wallet")
      tasks = for id <- ["r-a", "r-b"], do: Task.async(fn -> reverse(j, id, "sale") end)
      # The first waits on the row lock; the second on the first's reverses key.
      Harness.await_blocked!(2)
      Harness.release!(holder)

      assert Enum.sort(Enum.map(tasks, &Task.await(&1, 30_000))) ==
               [{:error, :already_reversed}, {:ok, :applied}]

      assert {units(j, "revenue"), units(j, "wallet")} == {0, 0}
    end

    test "identical concurrent reversals: one applies, the others are duplicate", %{j: j} do
      open!(j, "revenue", eur(), true)
      open!(j, "wallet", eur(), true)

      # Released together, so the operation inserts race on both unique keys. The answer for an
      # equal request is duplicate, never already_reversed (each round below about one in seven
      # failed when only the operation ID was the conflict target).
      for i <- 1..50 do
        assert {:ok, :applied} = post(j, "sale-#{i}", eur(), [{"revenue", -1}, {"wallet", 1}])

        tasks =
          for _ <- 1..5 do
            Task.async(fn ->
              receive do: (:go -> :ok)
              reverse(j, "undo-#{i}", "sale-#{i}")
            end)
          end

        Enum.each(tasks, &send(&1.pid, :go))

        assert Enum.sort(Enum.map(tasks, &Task.await(&1, 30_000))) ==
                 [{:ok, :applied} | List.duplicate({:ok, :duplicate}, 4)]
      end

      assert {units(j, "revenue"), units(j, "wallet")} == {0, 0}
    end

    test "a reversal of a wallet credit that was spent is insufficient_funds", %{j: j, p: p} do
      open!(j, "revenue", eur(), true)
      open!(j, "wallet", eur(), false)
      open!(j, "x-merchant", eur(), true)
      assert {:ok, :applied} = post(j, "credit", eur(), [{"revenue", -100}, {"wallet", 100}])
      assert {:ok, :applied} = post(j, "spend", eur(), [{"wallet", -60}, {"x-merchant", 60}])
      refused(p, :insufficient_funds, fn -> reverse(j, "undo-credit", "credit") end)
      # Reversing the spend first makes the credit reversible.
      assert reverse(j, "undo-spend", "spend") == {:ok, :applied}
      assert reverse(j, "undo-credit", "credit") == {:ok, :applied}
      assert units(j, "wallet") == 0
    end
  end

  # ------------------------------------------------------------ 6

  test "6 retired currency: refused for new accounts and posts, accepted for replay and reversal",
       %{j: j, p: p} do
    v2 = "2027-01-01"
    newer = Registry.build!([Harness.extract(), Harness.derived(v2, ["current\tEUR\t"], [])])
    assert newer.versions == [Registry.latest(Registry.default()), v2]
    j2 = Journal.new(repo: AppRepo, prefix: p, registry: newer)
    eur2 = currency("EUR", registry: newer)
    assert eur2.version == v2 and eur2.status == {:retired, :not_recorded}

    open!(j, "eur-a", eur(), true)
    open!(j, "eur-b", eur(), false)
    original = request("before", eur(), [{"eur-a", -100}, {"eur-b", 100}])
    assert Journal.post(j, "T1", original) == {:ok, :applied}

    for c <- [eur(), eur2] do
      refused(p, :retired_currency, fn ->
        Journal.open_account(j2, "T1", %{account_id: "eur-c", currency: c, allow_negative: true})
      end)

      refused(p, :retired_currency, fn ->
        Journal.post(j2, "T1", %{
          request("after", eur(), [{"eur-a", -5}, {"eur-b", 5}])
          | postings: [
              %{account_id: "eur-a", amount: amount(c, -5, registry: newer)},
              %{account_id: "eur-b", amount: amount(c, 5, registry: newer)}
            ]
        })
      end)

      assert Journal.open_account(j2, "T1", %{
               account_id: "eur-a",
               currency: c,
               allow_negative: true
             }) ==
               {:ok, :duplicate}
    end

    reparsed = %{
      original
      | postings:
          Enum.map(original.postings, fn posting ->
            %{posting | amount: amount(eur2, posting.amount.minor_units, registry: newer)}
          end)
    }

    refute reparsed == original
    assert Journal.post(j2, "T1", original) == {:ok, :duplicate}
    assert Journal.post(j2, "T1", reparsed) == {:ok, :duplicate}
    assert reverse(j2, "undo-before", "before") == {:ok, :applied}

    # Amounts come back under the newest held version that has the stored identity.
    assert Journal.balance(j2, "T1", "eur-b") == {:ok, amount(eur2, 0, registry: newer)}
    assert Journal.balance(j, "T1", "eur-b") == {:ok, amount(eur(), 0)}
  end

  # ------------------------------------------------------------ 7

  test "7 a connection killed inside the transaction commits nothing; the retry applies once",
       %{j: j, p: p} do
    open!(j, "revenue", eur(), true)
    open!(j, "wallet", eur(), false)
    before = Harness.truth(p)
    r = request("op-k", eur(), [{"revenue", -10}, {"wallet", 10}])
    holder = Harness.hold!(p, "T1", "wallet")
    task = Task.async(fn -> Journal.post(j, "T1", r) end)
    Harness.await_blocked_by!(holder, 1)
    [backend] = Harness.blocked_by(holder)
    # The post waits after its operation insert: its backend holds the insert's lock on the
    # operations table, and the uncommitted row is not visible to the owner.
    assert Harness.q!(
             OwnerRepo,
             "SELECT count(*) FROM pg_locks WHERE pid = $1 AND relation = to_regclass($2::text) AND mode = 'RowExclusiveLock' AND granted",
             [backend, Harness.table(p, :operations)]
           ) == [[1]]

    assert Harness.q!(OwnerRepo, "SELECT pg_terminate_backend($1)", [backend]) == [[true]]
    assert Task.await(task, 30_000) == {:error, :unavailable}
    Harness.release!(holder)

    assert Harness.truth(p) == before
    assert Journal.post(j, "T1", r) == {:ok, :applied}
    assert Journal.post(j, "T1", r) == {:ok, :duplicate}
    assert units(j, "wallet") == 10
  end

  # ------------------------------------------------------------ 8

  describe "8 transaction and isolation Needs" do
    test "a caller's open transaction gives in_transaction before any query", %{j: j} do
      open!(j, "a", eur(), true)
      open!(j, "b", eur(), true)
      event = [:elz297, :app, :query]

      {:ok, results} =
        AppRepo.transaction(fn ->
          :ok = :telemetry.attach("elz297-in-tx", event, &Harness.forward/4, self())

          try do
            [
              Journal.open_account(j, "T1", %{
                account_id: "c",
                currency: eur(),
                allow_negative: true
              }),
              post(j, "op", eur(), [{"a", 1}, {"b", -1}]),
              reverse(j, "undo", "op"),
              Journal.balance(j, "T1", "a"),
              history(j, "a")
            ]
            |> tap(fn _ ->
              refute_received {:app_query, _}
              # Positive control: a query on this Repo does reach the probe.
              Harness.q!(AppRepo, "SELECT 1")
              assert_received {:app_query, "SELECT 1"}
            end)
          after
            :telemetry.detach("elz297-in-tx")
          end
        end)

      assert results == List.duplicate({:error, :in_transaction}, 5)
    end

    test "a Repo at repeatable read gets isolation from every write, with nothing committed",
         %{j: j, p: p} do
      rr = Journal.new(repo: RepeatableRepo, prefix: p)

      assert Harness.q!(RepeatableRepo, "SHOW default_transaction_isolation") == [
               ["repeatable read"]
             ]

      open!(j, "a", eur(), true)
      open!(j, "b", eur(), true)
      assert {:ok, :applied} = post(j, "op", eur(), [{"a", 1}, {"b", -1}])

      refused(p, :isolation, fn ->
        Journal.open_account(rr, "T1", %{account_id: "c", currency: eur(), allow_negative: true})
      end)

      refused(p, :isolation, fn -> post(rr, "op-2", eur(), [{"a", 1}, {"b", -1}]) end)
      refused(p, :isolation, fn -> reverse(rr, "undo", "op") end)
      # A replay is no exception: the level is checked before the identity.
      refused(p, :isolation, fn -> post(rr, "op", eur(), [{"a", 1}, {"b", -1}]) end)
      # Reads take no isolation check.
      assert units(rr, "a") == 1
    end
  end

  # ------------------------------------------------------------ 9

  test "9 row security as the application role", %{j: j, p: p, role: role} do
    Harness.role_guard!(role)

    for t <- ~w(accounts operations postings) do
      assert TI.verify(AppRepo, {p, "elzoo_journal_" <> t},
               prefix: p,
               tenant_column: "tenant",
               space_column: nil
             ) == :ok
    end

    for tenant <- ["T1", "T2"] do
      open!(j, tenant, "a", eur(), true)
      open!(j, tenant, "b", eur(), true)
      assert {:ok, :applied} = post(j, tenant, "op", eur(), [{"a", 7}, {"b", -7}])
    end

    open!(j, "T2", "t2-only", eur(), true)
    assert {:ok, :applied} = post(j, "T2", "op-2", eur(), [{"a", 3}, {"t2-only", -3}])
    assert {units(j, "T1", "a"), units(j, "T2", "a")} == {7, 10}

    {:ok, visible} =
      TI.transact(AppRepo, %{tenant: "T1"}, fn ->
        {:ok,
         for t <- ~w(accounts operations postings) do
           Harness.q!(
             AppRepo,
             "SELECT count(*) FILTER (WHERE tenant = 'T2'), count(*) FROM #{Harness.table(p, t)}"
           )
         end}
      end)

    assert visible == [[[0, 2]], [[0, 1]], [[0, 2]]]
    assert Journal.balance(j, "T1", "t2-only") == {:error, :unknown_account}

    assert Journal.history(j, "T1", %{account_id: "t2-only", after: nil, limit: 10}) ==
             {:error, :unknown_account}

    refused(p, :unknown_account, fn -> post(j, "T1", "op-3", eur(), [{"a", 1}, {"t2-only", -1}]) end)

    inserts = [
      {:accounts,
       "INSERT INTO #{Harness.table(p, :accounts)} VALUES ('T2', 'z', 'EUR', 978, 2, true, 0, 0)"},
      {:operations,
       "INSERT INTO #{Harness.table(p, :operations)} VALUES ('T2', 'z', 'a', 'r', NULL, sha256('z'))"},
      {:postings, "INSERT INTO #{Harness.table(p, :postings)} VALUES ('T2', 'op', 'a', 1, 99, 1)"}
    ]

    for {_table, sql} <- inserts do
      assert {:error, %Postgrex.Error{postgres: %{code: @denied}}} =
               TI.transact(AppRepo, %{tenant: "T1"}, fn -> Harness.q(AppRepo, sql) end)
    end

    for sql <- [
          "UPDATE #{Harness.table(p, :postings)} SET balance = 0",
          "DELETE FROM #{Harness.table(p, :postings)}",
          "UPDATE #{Harness.table(p, :operations)} SET reason = 'x'",
          "DELETE FROM #{Harness.table(p, :operations)}",
          "DELETE FROM #{Harness.table(p, :accounts)}"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: @denied}}} =
               TI.transact(AppRepo, %{tenant: "T1"}, fn -> Harness.q(AppRepo, sql) end)
    end
  end

  # ------------------------------------------------------------ 10

  test "10 a registry that does not hold an account's stored identity gives registry",
       %{j: j, p: p} do
    isk = currency("ISK")
    assert isk.minor_unit == 0
    open!(j, "isk-a", isk, true)
    open!(j, "isk-b", isk, true)
    open!(j, "eur-a", eur(), true)
    assert {:ok, :applied} = post(j, "op", isk, [{"isk-a", 5}, {"isk-b", -5}])

    # One version only, in which ISK has exponent 2: the identity {ISK, 352, 0} is held nowhere.
    other =
      Registry.build!([
        Harness.derived("2027-01-01", [], [{"current\tISK\t352\t0\t", "current\tISK\t352\t2\t"}])
      ])

    j2 = Journal.new(repo: AppRepo, prefix: p, registry: other)
    assert Journal.balance(j2, "T1", "isk-a") == {:error, :registry}
    assert history(j2, "isk-a") == {:error, :registry}
    assert {:ok, %Amount{minor_units: 0}} = Journal.balance(j2, "T1", "eur-a")
    assert units(j, "isk-a") == 5
  end

  # ------------------------------------------------------------ 11

  test "11 history bounds and paging", %{j: j} do
    open!(j, "revenue", eur(), true)
    open!(j, "wallet", eur(), false)

    for n <- 1..7,
        do: assert({:ok, :applied} = post(j, "op-#{n}", eur(), [{"revenue", -n}, {"wallet", n}]))

    for bad <- [0, 1001, -1, nil, "1"],
        do: assert(history(j, "wallet", nil, bad) == {:error, :invalid})

    for bad <- [-1, "1", 1.0],
        do: assert(history(j, "wallet", bad, 10) == {:error, :invalid})

    assert {:ok, %{entries: [%{version: 1}], next: 1}} = history(j, "wallet", nil, 1)
    assert {:ok, %{entries: all, next: nil}} = history(j, "wallet", nil, 1000)
    assert Enum.map(all, & &1.version) == Enum.to_list(1..7)
    assert Enum.map(all, & &1.balance.minor_units) == [1, 3, 6, 10, 15, 21, 28]

    pages =
      Stream.unfold(nil, fn
        :done ->
          nil

        cursor ->
          {:ok, %{entries: entries, next: next}} = history(j, "wallet", cursor, 3)
          {entries, next || :done}
      end)
      |> Enum.to_list()

    assert Enum.map(pages, &Enum.map(&1, fn e -> e.version end)) == [[1, 2, 3], [4, 5, 6], [7]]
    assert List.flatten(pages) == all
    # A page that ends exactly at the last posting has no next.
    assert {:ok, %{entries: [%{version: 5}, %{version: 6}, %{version: 7}], next: nil}} =
             history(j, "wallet", 4, 3)

    assert history(j, "wallet", 7, 3) == {:ok, %{entries: [], next: nil}}
    assert history(j, "nobody") == {:error, :unknown_account}
  end

  # ------------------------------------------------------------ 12

  test "12 history sends one statement under the tenant scope", %{j: j} do
    open!(j, "revenue", eur(), true)
    open!(j, "wallet", eur(), false)
    open!(j, "empty", eur(), false)

    for n <- 1..3,
        do: assert({:ok, :applied} = post(j, "op-#{n}", eur(), [{"revenue", -n}, {"wallet", n}]))

    # A known account with entries (a full page with next, and the last page), a known account
    # with an empty page past its last version, one with no postings, and an unknown account.
    assert {{:ok, %{entries: [%{version: 1}, %{version: 2}], next: 2}}, [_]} =
             statements(fn -> history(j, "wallet", nil, 2) end)

    assert {{:ok, %{entries: [%{version: 3, balance: %Amount{minor_units: 6}}], next: nil}}, [_]} =
             statements(fn -> history(j, "wallet", 2, 2) end)

    assert {{:ok, %{entries: [], next: nil}}, [_]} =
             statements(fn -> history(j, "wallet", 3, 10) end)

    assert {{:ok, %{entries: [], next: nil}}, [_]} = statements(fn -> history(j, "empty") end)
    assert {{:error, :unknown_account}, [_]} = statements(fn -> history(j, "nobody") end)
  end

  # ------------------------------------------------------------ Cure

  test "selected Cure laws, a clean audit and the production decisions" do
    source = File.read!(Path.expand("../../cure/elzoo/journal.cure", __DIR__))
    roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
    assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
    assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(audit, key) == [])

    cure = :"Cure.Elzoo.Journal"
    assert apply(cure, :postings, [[5, -5], true]) == :JournalBalanced
    assert apply(cure, :postings, [[5, -4], true]) == :JournalUnbalanced
    assert apply(cure, :postings, [[5, -4], false]) == :JournalCurrencyMismatch
    assert apply(cure, :balance, [@bound, true, @bound]) == :JournalAmountRange
    assert apply(cure, :balance, [-@bound, false, @bound]) == :JournalAmountRange
    assert apply(cure, :balance, [@bound - 1, true, @bound]) == :JournalBalanceOk
    assert apply(cure, :balance, [-1, false, @bound]) == :JournalInsufficientFunds
    assert apply(cure, :balance, [0, false, @bound]) == :JournalBalanceOk
    assert apply(cure, :balance, [-1, true, @bound]) == :JournalBalanceOk
  end
end
