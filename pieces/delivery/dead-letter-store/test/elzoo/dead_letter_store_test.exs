# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/dead_letter_store_test_helper.exs", __DIR__)

defmodule Elzoo.DeadLetterStoreTest do
  use ExUnit.Case, async: false
  alias Elzoo.DeadLetterStore, as: DLS
  alias Elzoo.DeadLetterStore.{AppRepo, DownRepo, Harness, IsoRepo, OwnerRepo, RaceRepo}
  alias Elzoo.DurableLog.{Memory, Writer}
  alias Elzoo.Jobs.Relay
  import Harness, only: [record: 1, record: 2, q!: 2, q!: 3, q: 3]

  @fold %{
    initial: 0,
    kinds: %{"event" => :state_bearing},
    versions: [1],
    destinations: ["jobs"],
    reduce: &__MODULE__.count_fold/4
  }
  @limits %{max_record_bytes: 1024, max_batch_size: 4, max_checkpoint_bytes: 10_000}
  def count_fold(n, _, _, _), do: n + 1

  setup_all do
    ctx = Harness.start_repos!()
    p = Harness.install!(ctx.role)
    Map.merge(ctx, %{prefix: p})
  end

  setup %{prefix: p} = ctx do
    Harness.q!(OwnerRepo, ~s(TRUNCATE "#{p}".elzoo_dead_letters))
    %{store: DLS.new(repo: AppRepo, prefix: p), race: ctx.race}
  end

  defp put(store, tenant, source, rec, work_ref \\ nil, at \\ 10),
    do: DLS.put(store, tenant, %{source: source, record: rec, work_ref: work_ref, at_ms: at})

  defp resolve(store, tenant, source, id, resolution, actor \\ "operator", at \\ 100),
    do:
      DLS.resolve(store, tenant, %{
        source: source,
        message_id: id,
        resolution: resolution,
        actor_ref: actor,
        at_ms: at
      })

  defp list(store, tenant, source, cursor, limit),
    do: DLS.list(store, tenant, %{source: source, after: cursor, limit: limit})

  defp all_open(store, tenant, source, limit, cursor \\ nil, acc \\ []) do
    {:ok, %{entries: entries, next: next}} = list(store, tenant, source, cursor, limit)
    assert length(entries) <= limit
    acc = acc ++ entries
    if next, do: all_open(store, tenant, source, limit, next, acc), else: acc
  end

  # An outbox stream of `n` items "item-1".."item-n" in a Memory Store of state/outbox.
  defp outbox(n) do
    {:ok, pid} = Memory.start_link(fold: @fold, limits: @limits)
    store = Memory.store(pid)
    {:ok, w} = Writer.start_link(store: store, stream: "jobs/r", fold: @fold, limits: @limits)

    for i <- 1..n,
        do: {:committed, ^i} = Writer.append(w, [{"event", 1, "e"}], [{"jobs", "item-#{i}"}])

    GenServer.stop(w)
    store
  end

  defp relay(outbox, handle, limit) do
    {:ok, relay} =
      Relay.start_link(
        store: outbox,
        stream: "jobs/r",
        handle: handle,
        limit: limit,
        interval_ms: :manual
      )

    relay
  end

  defp pending(outbox) do
    {:ok, items} = Elzoo.Outbox.pending(outbox, "jobs/r", 100)
    Enum.map(items, & &1.payload)
  end

  # The host's permanent-failure record for an outbox item; its key is the item's own key.
  defp item_record(item), do: record(item.idempotency_key)

  describe "1 and 11: Relay re-offer after a crash between put/3 and the ack" do
    test "the record is stored once and the second offer is :duplicate", %{store: s, prefix: p} do
      box = outbox(1)
      seen = :ets.new(:seen, [:public, :duplicate_bag])
      crash = :atomics.new(1, [])

      handle = fn item ->
        result = put(s, "T1", "jobs", item_record(item), "work:" <> item.payload)
        :ets.insert(seen, {:put, result})
        if :atomics.add_get(crash, 1, 1) == 1, do: raise("crash before the ack")
        {:ok, _} = result
        :done
      end

      r = relay(box, handle, 10)
      assert {:ok, %{acked: [], skipped: [{_, {:exception, RuntimeError}}]}} = Relay.run_once(r)
      assert pending(box) == ["item-1"]
      assert {:ok, %{acked: [_], skipped: []}} = Relay.run_once(r)
      assert pending(box) == []

      assert [["T1", "jobs", "jobs/r/1/1", "open" | _]] = Harness.truth(p)

      assert Enum.map(:ets.lookup(seen, :put), &elem(&1, 1)) ==
               [{:ok, :applied}, {:ok, :duplicate}]
    end
  end

  describe "2: same key, other record or work_ref" do
    test "is :conflict; equal bytes are :duplicate, also for an equivalent map", %{store: s} do
      assert {:ok, :applied} = put(s, "T1", "src", record("m1"), "w1")
      assert {:ok, :duplicate} = put(s, "T1", "src", record("m1"), "w1")
      # Same canonical bytes from another put_at_ms: still the same record.
      assert {:ok, :duplicate} = put(s, "T1", "src", record("m1"), "w1", 99)
      assert {:error, :conflict} = put(s, "T1", "src", record("m1", %{"attempts" => 4}), "w1")
      assert {:error, :conflict} = put(s, "T1", "src", record("m1"), "w2")
      assert {:error, :conflict} = put(s, "T1", "src", record("m1"), nil)
      # The same message_id in another source or tenant is another key.
      assert {:ok, :applied} = put(s, "T1", "other", record("m1"), "w2")
      assert {:ok, :applied} = put(s, "T2", "src", record("m1"), nil)
    end

    test "a put of a resolved key with equal bytes is :duplicate and does not reopen it", ctx do
      %{store: s, prefix: p} = ctx
      assert {:ok, :applied} = put(s, "T1", "src", record("m1"))
      assert {:ok, :applied} = resolve(s, "T1", "src", "m1", :discarded)
      assert {:ok, :duplicate} = put(s, "T1", "src", record("m1"))
      assert {:error, :conflict} = put(s, "T1", "src", record("m1"), "w")
      assert [["T1", "src", "m1", "resolved", "discarded" | _]] = Harness.truth(p)
      assert {:ok, %{entries: [], next: nil}} = list(s, "T1", "src", nil, 10)
    end

    test "the record is stored as canonical JSON text with keys in byte order", ctx do
      rec =
        record("m1", %{
          "last_outcome" => "timed_out",
          "last_dispatch" => "not_dispatched",
          "last_error_class" => "permanent",
          "deadline_unix_ms" => 7
        })

      assert {:ok, :applied} = put(ctx.store, "T1", "src", rec)

      assert [[_, _, _, _, _, _, _, stored, nil, 10]] = Harness.truth(ctx.prefix)

      assert stored ==
               ~s({"attempts":3,"correlation_id":"m1","deadline_unix_ms":7,"last_dispatch":"not_dispatched","last_error_class":"permanent","last_outcome":"timed_out","message_id":"m1","reason":"permanent","version":1})

      [[type]] =
        q!(
          OwnerRepo,
          "SELECT data_type FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'elzoo_dead_letters' AND column_name = 'record'",
          [ctx.prefix]
        )

      assert type == "text"
      assert {:ok, %{entries: [%{record: ^rec}]}} = list(ctx.store, "T1", "src", nil, 1)
    end
  end

  describe "3: resolve once" do
    test "applied, duplicate, already_resolved and unknown_record", %{store: s, prefix: p} do
      assert {:ok, :applied} = put(s, "T1", "src", record("m1"))
      assert {:error, :unknown_record} = resolve(s, "T1", "src", "m2", :replayed)
      assert {:error, :unknown_record} = resolve(s, "T1", "other", "m1", :replayed)
      assert {:ok, :applied} = resolve(s, "T1", "src", "m1", :replayed, "op-a", 100)
      assert {:ok, :duplicate} = resolve(s, "T1", "src", "m1", :replayed, "op-a", 100)
      assert {:error, :already_resolved} = resolve(s, "T1", "src", "m1", :discarded, "op-a", 100)
      assert {:error, :already_resolved} = resolve(s, "T1", "src", "m1", :replayed, "op-b", 100)
      assert {:error, :already_resolved} = resolve(s, "T1", "src", "m1", :replayed, "op-a", 101)

      assert [["T1", "src", "m1", "resolved", "replayed", "op-a", 100 | _]] = Harness.truth(p)
    end

    test "two concurrent resolves behind a held row lock commit one", ctx do
      %{prefix: p, race: race} = ctx
      s = ctx.store
      assert {:ok, :applied} = put(s, "T1", "src", record("m1"))
      racer = DLS.new(repo: RaceRepo, prefix: p)
      test = self()

      # Another connection holds the row lock until both resolves wait for it.
      holder =
        Task.async(fn ->
          # The owner is forced too: it sees the row only under the tenant's scope.
          Elzoo.TenantIsolation.transact(OwnerRepo, %{tenant: "T1"}, fn ->
            q!(
              OwnerRepo,
              ~s|SELECT 1 FROM "#{p}".elzoo_dead_letters WHERE message_id = 'm1' FOR UPDATE|
            )

            send(test, :locked)

            receive do
              :release -> {:ok, :released}
            end
          end)
        end)

      assert_receive :locked, 5_000

      resolvers =
        for {resolution, actor} <- [{:replayed, "op-a"}, {:discarded, "op-b"}] do
          Task.async(fn -> resolve(racer, "T1", "src", "m1", resolution, actor, 100) end)
        end

      Harness.poll(fn -> Harness.waiting(race) == 2 end)
      send(holder.pid, :release)
      assert {:ok, :released} = Task.await(holder)

      results = Enum.map(resolvers, &Task.await(&1, 10_000))
      assert Enum.sort(results) == [{:error, :already_resolved}, {:ok, :applied}]

      winner =
        Enum.zip([{"replayed", "op-a"}, {"discarded", "op-b"}], results)
        |> Enum.find_value(fn {fields, result} -> result == {:ok, :applied} && fields end)

      {resolution, actor} = winner
      assert [["T1", "src", "m1", "resolved", ^resolution, ^actor, 100 | _]] = Harness.truth(p)
    end

    test "two concurrent equal resolves: one applied, one duplicate", ctx do
      %{prefix: p, race: race} = ctx
      assert {:ok, :applied} = put(ctx.store, "T1", "src", record("m1"))
      racer = DLS.new(repo: RaceRepo, prefix: p)
      test = self()

      holder =
        Task.async(fn ->
          # The owner is forced too: it sees the row only under the tenant's scope.
          Elzoo.TenantIsolation.transact(OwnerRepo, %{tenant: "T1"}, fn ->
            q!(OwnerRepo, ~s|SELECT 1 FROM "#{p}".elzoo_dead_letters FOR UPDATE|)
            send(test, :locked)

            receive do
              :release -> {:ok, :released}
            end
          end)
        end)

      assert_receive :locked, 5_000

      resolvers =
        for _ <- 1..2, do: Task.async(fn -> resolve(racer, "T1", "src", "m1", :replayed) end)

      Harness.poll(fn -> Harness.waiting(race) == 2 end)
      send(holder.pid, :release)
      Task.await(holder)

      assert Enum.sort(Enum.map(resolvers, &Task.await(&1, 10_000))) ==
               [{:ok, :applied}, {:ok, :duplicate}]
    end
  end

  describe "4: list order and paging, count" do
    test "oldest first, every open record once across pages, resolved ones absent", %{store: s} do
      # Put order differs from the expected order: put_at_ms first, then message_id bytes.
      puts = [
        {"b", 20},
        {"a", 20},
        {"z", 5},
        {"é", 20},
        {"B", 20},
        {"c", 30},
        {"d", 30},
        {"gone", 1},
        {"y", 40}
      ]

      for {id, at} <- puts, do: assert({:ok, :applied} = put(s, "T1", "src", record(id), nil, at))
      assert {:ok, :applied} = put(s, "T1", "elsewhere", record("x"), nil, 0)
      assert {:ok, :applied} = resolve(s, "T1", "src", "gone", :discarded)
      assert {:ok, :applied} = resolve(s, "T1", "src", "d", :replayed)

      expected = ["z", "B", "a", "b", "é", "c", "y"]

      for limit <- [1, 2, 3, 7, 1000] do
        entries = all_open(s, "T1", "src", limit)
        assert Enum.map(entries, & &1.message_id) == expected, "limit #{limit}"
      end

      {:ok, %{entries: [first | _] = page, next: next}} = list(s, "T1", "src", nil, 3)
      assert length(page) == 3 and is_binary(next)
      assert first == %{message_id: "z", record: record("z"), work_ref: nil, put_at_ms: 5}
      # A page that ends exactly at the last open record reports no next.
      assert {:ok, %{entries: [_, _, _, _, _, _, _], next: nil}} = list(s, "T1", "src", nil, 7)
      {:ok, %{next: n6}} = list(s, "T1", "src", nil, 6)
      assert {:ok, %{entries: [%{message_id: "y"}], next: nil}} = list(s, "T1", "src", n6, 7)

      assert {:ok, [%{source: "elsewhere", open: 1}, %{source: "src", open: 7}]} =
               DLS.count(s, "T1")

      assert {:ok, []} = DLS.count(s, "T2")
    end

    test "a record put after the cursor's position is seen on a later page", %{store: s} do
      for {id, at} <- [{"a", 1}, {"b", 2}],
          do: {:ok, :applied} = put(s, "T1", "src", record(id), nil, at)

      {:ok, %{entries: [%{message_id: "a"}], next: next}} = list(s, "T1", "src", nil, 1)
      assert {:ok, :applied} = put(s, "T1", "src", record("c"), nil, 3)
      assert {:ok, :applied} = resolve(s, "T1", "src", "b", :replayed)
      assert {:ok, %{entries: [%{message_id: "c"}], next: nil}} = list(s, "T1", "src", next, 1)
    end

    test "count refuses more than 1,000 sources with an open record", %{store: s, prefix: p} do
      {:ok, _} =
        Elzoo.TenantIsolation.transact(OwnerRepo, %{tenant: "T1"}, fn ->
          q(
            OwnerRepo,
            ~s|INSERT INTO "#{p}".elzoo_dead_letters (tenant, source, message_id, record, put_at_ms, state) SELECT 'T1', concat('s', lpad(g::text, 4, '0')), 'm', '{}', 0, 'open' FROM generate_series(1, 1000) g|,
            []
          )
        end)

      assert {:ok, counts} = DLS.count(s, "T1")
      assert length(counts) == 1000 and hd(counts) == %{source: "s0001", open: 1}
      assert {:ok, :applied} = put(s, "T1", "s1001", record("m"))
      assert {:error, :read_limit} = DLS.count(s, "T1")
      assert {:ok, :applied} = resolve(s, "T1", "s1001", "m", :replayed)
      assert {:ok, [_ | _]} = DLS.count(s, "T1")
    end
  end

  describe "5: cross-tenant isolation as the application role" do
    test "verify passes; T1 sees no T2 record and cannot write one", ctx do
      %{store: s, prefix: p, role: role} = ctx
      Harness.role_facts!(AppRepo, role)

      assert :ok =
               Elzoo.TenantIsolation.verify(AppRepo, {p, "elzoo_dead_letters"},
                 prefix: p,
                 tenant_column: "tenant",
                 space_column: nil
               )

      assert {:ok, :applied} = put(s, "T2", "src", record("t2-m"), nil, 1)
      assert {:ok, :applied} = put(s, "T2", "t2-only", record("t2-n"), nil, 1)
      assert {:ok, :applied} = put(s, "T1", "src", record("t1-m"), nil, 2)

      assert Enum.map(all_open(s, "T1", "src", 10), & &1.message_id) == ["t1-m"]
      assert {:ok, %{entries: [], next: nil}} = list(s, "T1", "t2-only", nil, 10)
      assert {:ok, [%{source: "src", open: 1}]} = DLS.count(s, "T1")
      assert {:error, :unknown_record} = resolve(s, "T1", "src", "t2-m", :discarded)
      # A T1 put of the T2 key is a new T1 key, not a duplicate or conflict.
      assert {:ok, :applied} = put(s, "T1", "src", record("t2-m"), "other")

      assert {:ok, :applied} = resolve(s, "T2", "src", "t2-m", :discarded, "op", 1)
      assert {:ok, 0} = DLS.purge(s, "T1", %{before_ms: 10, limit: 10})

      forged =
        ~s|INSERT INTO "#{p}".elzoo_dead_letters (tenant, source, message_id, record, put_at_ms, state) VALUES ('T2', 'src', 'forged', '{}', 0, 'open')|

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "42501"}}} =
               Elzoo.TenantIsolation.transact(AppRepo, %{tenant: "T1"}, fn ->
                 q(AppRepo, forged, [])
               end)

      truth = Harness.truth(p)
      assert Enum.count(truth, &match?(["T2" | _], &1)) == 2

      assert ["T2", "src", "t2-m", "resolved" | _] =
               Enum.find(truth, &match?(["T2", "src" | _], &1))

      refute Enum.any?(truth, &match?([_, _, "forged" | _], &1))
    end
  end

  describe "6: a caller's open transaction" do
    test "every function is :in_transaction before any query", %{store: s} do
      ref = make_ref()
      handler = "elz301-#{inspect(ref)}"
      test = self()

      :telemetry.attach(handler, [:elzoo_dls_app, :query], &__MODULE__.forward_query/4, test)

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, results} =
        AppRepo.transact(fn ->
          flush_queries()

          results = [
            put(s, "T1", "src", record("m1")),
            resolve(s, "T1", "src", "m1", :replayed),
            list(s, "T1", "src", nil, 10),
            DLS.count(s, "T1"),
            DLS.purge(s, "T1", %{before_ms: 10, limit: 10})
          ]

          refute_received {:query, _}
          {:ok, results}
        end)

      assert results == List.duplicate({:error, :in_transaction}, 5)
      assert {:ok, %{entries: []}} = list(s, "T1", "src", nil, 10)
    end

    def forward_query(_event, _measurements, meta, test), do: send(test, {:query, meta.query})

    defp flush_queries do
      receive do
        {:query, _} -> flush_queries()
      after
        0 -> :ok
      end
    end
  end

  describe "7: malformed records" do
    test "are :record through Elzoo.DeadLetter.validate/1", %{store: s, prefix: p} do
      triple = %{
        "last_outcome" => "timed_out",
        "last_dispatch" => "not_dispatched",
        "last_error_class" => "permanent"
      }

      assert {:ok, _} = Elzoo.DeadLetter.validate(record("m", triple))
      assert {:ok, :applied} = put(s, "T1", "src", record("m", triple))

      for bad <- [
            record("m1", %{"payload" => "secret"}),
            record("m1", Map.delete(triple, "last_dispatch")),
            record("m1", %{"reason" => "invented"}),
            record("m1", %{"version" => 2}),
            record("m1", %{"attempts" => -1}),
            record(""),
            Map.delete(record("m1"), "correlation_id"),
            nil,
            "not a map"
          ] do
        assert {:error, _} = Elzoo.DeadLetter.validate(bad)
        assert put(s, "T1", "src", bad) == {:error, :record}, inspect(bad)
      end

      assert length(Harness.truth(p)) == 1
    end
  end

  describe "8: purge" do
    test "deletes only resolved records older than the cutoff, at most limit", ctx do
      %{store: s, prefix: p} = ctx
      for id <- ~w(a b c d e open), do: {:ok, :applied} = put(s, "T1", "src", record(id), nil, 0)
      {:ok, :applied} = put(s, "T2", "src", record("t2"), nil, 0)

      for {id, at} <- [{"a", 30}, {"b", 10}, {"c", 20}, {"d", 50}, {"e", 40}],
          do: {:ok, :applied} = resolve(s, "T1", "src", id, :discarded, "op", at)

      {:ok, :applied} = resolve(s, "T2", "src", "t2", :discarded, "op", 1)

      ids = fn -> for [t, _, id | _] <- Harness.truth(p), do: {t, id} end

      assert {:ok, 2} = DLS.purge(s, "T1", %{before_ms: 50, limit: 2})
      # The oldest resolved_at_ms first: b (10) and c (20).
      assert ids.() == [{"T1", "a"}, {"T1", "d"}, {"T1", "e"}, {"T1", "open"}, {"T2", "t2"}]
      assert {:ok, 2} = DLS.purge(s, "T1", %{before_ms: 50, limit: 1000})
      # d was resolved at 50, not before 50.
      assert ids.() == [{"T1", "d"}, {"T1", "open"}, {"T2", "t2"}]
      assert {:ok, 1} = DLS.purge(s, "T1", %{before_ms: 51, limit: 1000})
      assert {:ok, 0} = DLS.purge(s, "T1", %{before_ms: 9_223_372_036_854_775_807, limit: 1000})
      assert ids.() == [{"T1", "open"}, {"T2", "t2"}]
      # A purged key may be put again; it is a new open record.
      assert {:ok, :applied} = put(s, "T1", "src", record("a"))
    end

    test "stated limit: a resolve retried after purge and key reuse resolves the new record",
         %{store: s} do
      assert {:ok, :applied} = put(s, "T1", "src", record("m1"))
      assert {:ok, :applied} = resolve(s, "T1", "src", "m1", :discarded, "op", 10)
      assert {:ok, 1} = DLS.purge(s, "T1", %{before_ms: 11, limit: 10})
      assert {:ok, :applied} = put(s, "T1", "src", record("m1", %{"attempts" => 9}))
      # The retry of the first resolve cannot tell the new record from the purged one.
      assert {:ok, :applied} = resolve(s, "T1", "src", "m1", :discarded, "op", 10)
      assert {:ok, %{entries: [], next: nil}} = list(s, "T1", "src", nil, 10)
    end
  end

  describe "9: Relay over a stream whose first full page fails permanently" do
    test "with the store, a later pass delivers the later items; without, they stay", ctx do
      s = ctx.store
      limit = 3
      delivered = :ets.new(:delivered, [:public, :duplicate_bag])

      permanent? = fn item -> item.payload in ["item-1", "item-2", "item-3"] end

      deliver = fn item ->
        :ets.insert(delivered, {item.payload})
        :done
      end

      # Without the store: the first page is skipped on every pass.
      plain = outbox(5)

      without = fn item -> if permanent?.(item), do: {:skip, :permanent}, else: deliver.(item) end

      r1 = relay(plain, without, limit)
      for _ <- 1..3, do: assert({:ok, %{acked: [], skipped: [_, _, _]}} = Relay.run_once(r1))
      assert pending(plain) == ~w(item-1 item-2 item-3 item-4 item-5)
      assert :ets.tab2list(delivered) == []

      # With the store: each permanent failure is stored and acked.
      stored = outbox(5)

      with_store = fn item ->
        if permanent?.(item) do
          {:ok, _} = put(s, "T1", "jobs", item_record(item), item.payload)
          :done
        else
          deliver.(item)
        end
      end

      r2 = relay(stored, with_store, limit)
      assert {:ok, %{acked: [_, _, _], skipped: []}} = Relay.run_once(r2)
      assert {:ok, %{acked: [_, _], skipped: []}} = Relay.run_once(r2)
      assert pending(stored) == []
      assert Enum.sort(:ets.tab2list(delivered)) == [{"item-4"}, {"item-5"}]

      assert Enum.map(all_open(s, "T1", "jobs", 10), &{&1.message_id, &1.work_ref}) ==
               [{"jobs/r/1/1", "item-1"}, {"jobs/r/2/1", "item-2"}, {"jobs/r/3/1", "item-3"}]
    end
  end

  describe "10: bounds" do
    test "texts, work_ref, limit and times", %{store: s} do
      t128 = String.duplicate("t", 128)
      t129 = String.duplicate("t", 129)
      two_byte = String.duplicate("é", 64)

      for good <- ["T", t128, two_byte, "ok space"] do
        assert {:ok, :applied} = put(s, good, good, record("m"))
        assert {:ok, :applied} = resolve(s, good, good, "m", :replayed, good)
      end

      for bad <- ["", t129, two_byte <> "x", "c1\u0085", "c0\n", "del\u007f", <<255>>, :atom, nil] do
        assert {:error, :invalid} = put(s, bad, "src", record("m"))
        assert {:error, :invalid} = put(s, "T1", bad, record("m"))
        assert {:error, :invalid} = resolve(s, "T1", "src", "m", :replayed, bad)
        assert {:error, :invalid} = resolve(s, bad, "src", "m", :replayed)
        assert {:error, :invalid} = list(s, bad, "src", nil, 1)
        assert {:error, :invalid} = list(s, "T1", bad, nil, 1)
        assert {:error, :invalid} = DLS.count(s, bad)
        assert {:error, :invalid} = DLS.purge(s, bad, %{before_ms: 1, limit: 1})
      end

      w256 = :binary.copy(<<0>>, 256)
      assert {:ok, :applied} = put(s, "T1", "w", record("w0"), nil)
      assert {:ok, :applied} = put(s, "T1", "w", record("w1"), <<0>>)
      assert {:ok, :applied} = put(s, "T1", "w", record("w256"), w256)
      assert {:error, :invalid} = put(s, "T1", "w", record("w-empty"), "")
      assert {:error, :invalid} = put(s, "T1", "w", record("w257"), w256 <> <<1>>)
      assert {:error, :invalid} = put(s, "T1", "w", record("w-atom"), :ref)

      assert {:ok, %{entries: [_]}} = list(s, "T1", "w", nil, 1)
      assert {:ok, %{entries: [_, _, _]}} = list(s, "T1", "w", nil, 1000)
      assert {:error, :invalid} = list(s, "T1", "w", nil, 0)
      assert {:error, :invalid} = list(s, "T1", "w", nil, 1001)
      assert {:ok, 0} = DLS.purge(s, "T1", %{before_ms: 1, limit: 1})
      assert {:ok, 0} = DLS.purge(s, "T1", %{before_ms: 1, limit: 1000})
      assert {:error, :invalid} = DLS.purge(s, "T1", %{before_ms: 1, limit: 0})
      assert {:error, :invalid} = DLS.purge(s, "T1", %{before_ms: 1, limit: 1001})

      max = 9_223_372_036_854_775_807
      assert {:ok, :applied} = put(s, "T1", "time", record("t0"), nil, 0)
      assert {:ok, :applied} = put(s, "T1", "time", record("tmax"), nil, max)
      assert {:error, :invalid} = put(s, "T1", "time", record("t-1"), nil, -1)
      assert {:error, :invalid} = put(s, "T1", "time", record("tbig"), nil, max + 1)
      assert {:error, :invalid} = put(s, "T1", "time", record("tf"), nil, 1.0)
      assert {:ok, :applied} = put(s, "T1", "time", record("tmax2"), nil, max)
      assert {:ok, :applied} = resolve(s, "T1", "time", "t0", :replayed, "op", max)
      assert {:error, :invalid} = resolve(s, "T1", "time", "t0", :replayed, "op", max + 1)
      assert {:error, :invalid} = DLS.purge(s, "T1", %{before_ms: -1, limit: 1})
      assert {:error, :invalid} = resolve(s, "T1", "time", "t0", :requeued)
      assert {:error, :invalid} = resolve(s, "T1", "time", "t0", "replayed")

      # The paging cursor of the maximum time is still a valid cursor.
      {:ok, %{entries: [%{message_id: "tmax"}], next: next}} = list(s, "T1", "time", nil, 1)
      assert {:ok, %{entries: [%{message_id: "tmax2"}], next: nil}} = list(s, "T1", "time", next, 1)
      assert {:error, :invalid} = list(s, "T1", "time", "c1.garbage!", 1)
      assert {:error, :invalid} = list(s, "T1", "time", "opaque", 1)
      assert {:error, :invalid} = list(s, "T1", "time", 5, 1)
    end

    test "message_id, encoded size and NUL are :record", %{store: s} do
      id256 = String.duplicate("i", 256)
      id257 = String.duplicate("i", 257)
      assert {:ok, :applied} = put(s, "T1", "src", record(id256))
      assert {:error, :record} = put(s, "T1", "src", record(id257))
      assert {:ok, :applied} = resolve(s, "T1", "src", id256, :replayed)
      assert {:error, :invalid} = resolve(s, "T1", "src", id257, :replayed)

      # A record of exactly 16,384 canonical bytes, then one of 16,385.
      base =
        Jason.encode!(
          Enum.sort(record("big", %{"correlation_id" => ""}))
          |> Jason.OrderedObject.new()
        )

      pad = 16_384 - byte_size(base)
      at = record("big", %{"correlation_id" => String.duplicate("c", pad)})
      over = record("big2", %{"correlation_id" => String.duplicate("c", pad)})

      assert byte_size(Jason.encode!(Jason.OrderedObject.new(Enum.sort(at)))) == 16_384
      assert byte_size(Jason.encode!(Jason.OrderedObject.new(Enum.sort(over)))) == 16_385
      assert {:ok, :applied} = put(s, "T1", "big", at)
      assert {:error, :record} = put(s, "T1", "big", over)
      assert {:ok, %{entries: [%{record: ^at}]}} = list(s, "T1", "big", nil, 1)

      # JSON escapes count: a quote is two encoded bytes.
      quoted = record("q", %{"correlation_id" => String.duplicate("\"", div(pad, 2) + 2)})
      assert {:error, :record} = put(s, "T1", "big", quoted)

      assert {:ok, _} = Elzoo.DeadLetter.validate(record("nul\0id"))
      assert {:error, :record} = put(s, "T1", "src", record("nul\0id"))
      assert {:error, :record} = put(s, "T1", "src", record("m", %{"correlation_id" => "c\0"}))
      assert {:error, :record} = put(s, "T1", "src", record("m", %{"last_attempt_id" => "a\0"}))
      assert {:error, :invalid} = resolve(s, "T1", "src", "nul\0id", :replayed)
    end

    test "long integers and escaped or non-ASCII texts are listed back unchanged", %{store: s} do
      long = record("long", %{"attempts" => Integer.pow(10, 1024), "deadline_unix_ms" => 7})
      longer = record("longer", %{"attempts" => 1, "deadline_unix_ms" => Integer.pow(10, 9_999)})
      assert {:ok, _} = Elzoo.DeadLetter.validate(long)
      assert {:ok, :applied} = put(s, "T1", "long", long, nil, 1)
      assert {:ok, :applied} = put(s, "T1", "long", longer, nil, 2)
      texts = record("é\"\\/\u2028😀", %{"correlation_id" => "line\nquote\"back\\slash\u00e9\u0001"})
      assert {:ok, :applied} = put(s, "T1", "long", texts, nil, 3)
      assert {:ok, :duplicate} = put(s, "T1", "long", long, nil, 4)

      assert {:ok, %{entries: [%{record: ^long}, %{record: ^longer}, %{record: ^texts}], next: nil}} =
               list(s, "T1", "long", nil, 10)
    end
  end

  describe "interface" do
    test "new/1 and install/1 refuse other options before any DDL", %{prefix: p} do
      for bad <- [
            [repo: AppRepo],
            [prefix: p],
            [repo: AppRepo, prefix: p, extra: 1],
            [repo: AppRepo, prefix: "Bad"],
            [repo: AppRepo, prefix: "a-b"],
            [repo: AppRepo, prefix: String.duplicate("a", 64)],
            [repo: "AppRepo", prefix: p],
            %{repo: AppRepo, prefix: p}
          ] do
        assert_raise ArgumentError, "invalid dead letter store prefix or options", fn ->
          DLS.new(bad)
        end
      end

      for bad <- ["Bad", "x;drop", "", nil, :atom, String.duplicate("a", 64)] do
        assert_raise ArgumentError, "invalid dead letter store prefix or options", fn ->
          Elzoo.DeadLetterStore.Migration.install(bad)
        end
      end
    end

    test "other request shapes are :invalid", %{store: s} do
      assert {:error, :invalid} =
               DLS.put(s, "T1", %{source: "s", record: record("m"), work_ref: nil})

      assert {:error, :invalid} =
               DLS.put(s, "T1", %{source: "s", record: record("m"), work_ref: nil, at_ms: 1, x: 1})

      assert {:error, :invalid} = DLS.list(s, "T1", %{source: "s", limit: 1})
      assert {:error, :invalid} = DLS.purge(s, "T1", %{before_ms: 1})
      assert {:error, :invalid} = DLS.resolve(s, "T1", [])
      assert {:error, :invalid} = DLS.count(:not_a_store, "T1")
      assert {:error, :invalid} = DLS.list(:not_a_store, "T1", %{source: "s", after: nil, limit: 1})
      # A shape error wins over a bad record.
      assert {:error, :invalid} = put(s, "", "src", record("m", %{"payload" => 1}))
    end

    test "a level other than read committed is :isolation; a down Repo is :unavailable", ctx do
      iso = DLS.new(repo: IsoRepo, prefix: ctx.prefix)
      assert {:error, :isolation} = put(iso, "T1", "src", record("m"))
      assert {:error, :isolation} = resolve(iso, "T1", "src", "m", :replayed)
      assert {:error, :isolation} = list(iso, "T1", "src", nil, 1)
      assert {:error, :isolation} = DLS.count(iso, "T1")
      assert {:error, :isolation} = DLS.purge(iso, "T1", %{before_ms: 1, limit: 1})
      assert Harness.truth(ctx.prefix) == []

      down = DLS.new(repo: DownRepo, prefix: ctx.prefix)
      assert {:error, :unavailable} = put(down, "T1", "src", record("m"))
      assert {:error, :unavailable} = DLS.count(down, "T1")

      # A missing table is a database failure, never a raise.
      missing = DLS.new(repo: AppRepo, prefix: "elz301_missing")
      assert {:error, :unavailable} = put(missing, "T1", "src", record("m"))
      assert {:error, :unavailable} = list(missing, "T1", "src", nil, 1)
    end

    test "errors never echo an ID", %{store: s} do
      secret = "secret-id-#{System.unique_integer([:positive])}"
      {:ok, :applied} = put(s, "T1", secret, record(secret), secret)

      results = [
        put(s, "T1", secret, record(secret), "other"),
        resolve(s, "T1", secret, secret <> "x", :replayed, secret),
        put(s, "T1", secret, record(secret, %{"payload" => secret})),
        put(DLS.new(repo: DownRepo, prefix: "x"), "T1", secret, record(secret))
      ]

      assert results == [
               {:error, :conflict},
               {:error, :unknown_record},
               {:error, :record},
               {:error, :unavailable}
             ]
    end
  end
end
