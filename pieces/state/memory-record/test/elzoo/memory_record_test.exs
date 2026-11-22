# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/memory_record_test_helper.exs", __DIR__)

defmodule Elzoo.MemoryRecordTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL
  alias Elzoo.MemoryRecord, as: MR
  alias Elzoo.MemoryRecord.{AdminRepo, AppRepo, Harness, Migration, RepeatableRepo}
  alias Elzoo.TenantIsolation, as: TI
  alias Elzoo.UntrustedContent, as: UC

  @message "invalid memory record repo or prefix"
  @rec "elzoo_memory_records"
  @tomb "elzoo_memory_tombstones"
  @max_time 9_007_199_254_740_991
  @scope_kinds [:tenant, :space, :subject, :bot]
  @kinds [:fact, :preference, :summary]
  @writer_kinds [:human, :service, :agent]
  @allow_all Map.new(
               for(s <- @scope_kinds, k <- @kinds, w <- @writer_kinds, do: {{s, k, w}, :allow})
             )

  setup_all do
    role = Harness.app_role!()
    Harness.start!(AdminRepo, pool_size: 4)
    [[version]] = Harness.query!(AdminRepo, "SELECT current_setting('server_version_num')").rows
    assert String.to_integer(version) in 160_000..169_999
    Harness.start!(AppRepo, pool_size: 6, after_connect: {Harness, :connect, [role, []]})

    Harness.start!(RepeatableRepo,
      pool_size: 1,
      after_connect:
        {Harness, :connect, [role, ["SET default_transaction_isolation = 'repeatable read'"]]}
    )

    # Every application connection is the non-owner role that does not bypass row security.
    assert [[^role, false, false]] =
             Harness.query!(
               AppRepo,
               "SELECT current_user, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user"
             ).rows

    {:ok, role: role}
  end

  setup %{role: role} do
    p = Harness.install!(AdminRepo, role)
    on_exit(fn -> Harness.drop!(AdminRepo, p) end)

    # After every case: a record and a tombstone of one ID never both exist (the invariant
    # that recall relies on when it does not look for a tombstone of a record's own ID).
    on_exit(fn ->
      assert truth(
               p,
               "SELECT count(*) FROM \"#{p}\".#{@rec} r JOIN \"#{p}\".#{@tomb} t USING (tenant, memory_id)"
             ) == [[0]]
    end)

    {:ok, p: p, m: MR.new(repo: AppRepo, prefix: p)}
  end

  # ── values ──────────────────────────────────────────────────────────────

  defp marked(text, trust \\ "untrusted", bound \\ 4096) do
    {:ok, marked} =
      UC.decode(%{
        "schema_id" => "elzoo.untrusted-content.marked",
        "schema_version" => 1,
        "sources" => ["chat:1", "run:7"],
        "trust" => trust,
        "max_bytes" => bound,
        "content" => text
      })

    marked
  end

  defp prop(id, changes \\ %{}) do
    Map.merge(
      %{
        memory_id: id,
        scope: {:subject, "s1"},
        kind: :fact,
        content: marked("content of " <> id),
        provenance: [{:run, "run-1"}, {:message, "msg-1"}],
        written_by: "agent-1",
        writer_kind: :agent,
        written_at_ms: 1000,
        expires_at_ms: nil,
        supersedes: nil
      },
      Map.new(changes)
    )
  end

  defp req(scopes, changes \\ %{}) do
    Map.merge(
      %{
        principal: "reader",
        checked_at: 5000,
        scopes: scopes,
        max_records: 256,
        max_bytes: 1_048_576,
        now_ms: 5000
      },
      Map.new(changes)
    )
  end

  defp w(m, tenant, p), do: MR.write(m, tenant, p, %{policy: @allow_all})

  defp w!(m, tenant, p), do: {:ok, :applied} = w(m, tenant, p)

  defp forget(m, tenant, id, reason \\ "user_request"),
    do:
      MR.forget(m, tenant, %{
        memory_id: id,
        actor_ref: "ops-1",
        reason: reason,
        forgotten_at_ms: 9000
      })

  defp erase(m, tenant, subject, cursor, max_batch \\ 256),
    do:
      MR.erase_subject(m, tenant, %{
        subject: subject,
        actor_ref: "ops-1",
        forgotten_at_ms: 9000,
        cursor: cursor,
        max_batch: max_batch
      })

  defp recall!(m, tenant, scopes, changes \\ %{}) do
    {:ok, result} = MR.recall(m, tenant, req(scopes, changes))
    result
  end

  defp ids(%{entries: entries}), do: Enum.map(entries, & &1.candidate.item_id)

  # ── direct reads ────────────────────────────────────────────────────────

  # A direct read as the application role inside the tenant scope (the tables force row
  # security, so a read outside a scope sees no rows and would prove nothing).
  defp direct(tenant, sql) do
    {:ok, rows} =
      TI.transact(AppRepo, %{tenant: tenant}, fn ->
        {:ok, SQL.query!(AppRepo, sql, [], log: false).rows}
      end)

    rows
  end

  # Ground truth as the owner with FORCE dropped inside a rolled-back transaction.
  defp truth(p, sql) do
    {:error, {:rows, rows}} =
      AdminRepo.transact(fn ->
        for t <- [@rec, @tomb],
            do: Harness.query!(AdminRepo, ~s(ALTER TABLE "#{p}".#{t} NO FORCE ROW LEVEL SECURITY))

        {:error, {:rows, Harness.query!(AdminRepo, sql).rows}}
      end)

    rows
  end

  # ── the per-ID lock barrier ─────────────────────────────────────────────

  # The README lock key, rebuilt here from its documented encoding.
  defp key(p, tenant, id) do
    frame = for i <- [p, tenant, id], into: "", do: <<byte_size(i)::32>> <> i

    <<k::signed-64, _::binary>> =
      :crypto.hash(:sha256, "elzoo.memory-record.lock" <> <<0>> <> frame)

    k
  end

  # Ungranted advisory locks on one key: pg_locks shows a bigint key as its high and low
  # 32 bits in classid and objid with objsubid 1.
  defp waiting(p, tenant, id) do
    <<hi::32, lo::32>> = <<key(p, tenant, id)::signed-64>>

    [[n]] =
      Harness.query!(
        AdminRepo,
        """
        SELECT count(*) FROM pg_locks
        WHERE locktype = 'advisory' AND NOT granted AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
          AND classid = $1::bigint::oid AND objid = $2::bigint::oid AND objsubid = 1
        """,
        [hi, lo]
      ).rows

    n
  end

  defp wait_until(check, tries \\ 500) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("the barrier condition never held")
      true -> Process.sleep(10) && wait_until(check, tries - 1)
    end
  end

  # Another connection holds the per-ID lock of `id`; `fun` starts the waiting calls and
  # returns their tasks; the lock is released and their results returned in start order.
  defp behind_lock(p, tenant, id, fun) do
    parent = self()

    holder =
      Task.async(fn ->
        AdminRepo.transact(fn ->
          Harness.query!(AdminRepo, "SELECT pg_catalog.pg_advisory_xact_lock($1)", [
            key(p, tenant, id)
          ])

          send(parent, :held)

          receive do
            :release -> {:ok, :released}
          end
        end)
      end)

    assert_receive :held, 5000

    try do
      tasks = fun.()
      send(holder.pid, :release)
      assert Task.await(holder) == {:ok, :released}
      Enum.map(tasks, &Task.await(&1, 10_000))
    after
      send(holder.pid, :release)
    end
  end

  # Start calls one at a time, each seen waiting on the lock before the next starts, then
  # release it. The results are compared first, so a call that does not wait shows the result
  # it gave at once; then every call must have been seen waiting.
  defp queued(p, tenant, id, calls, expected) do
    parent = self()

    results =
      behind_lock(p, tenant, id, fn ->
        calls
        |> Enum.with_index(1)
        |> Enum.map(fn {call, n} ->
          task = Task.async(call)
          wait_until(fn -> waiting(p, tenant, id) == n or not Process.alive?(task.pid) end)
          send(parent, {:seen_waiting, n, Process.alive?(task.pid)})
          task
        end)
      end)

    assert results == expected

    for n <- 1..length(calls),
        do: assert_received({:seen_waiting, ^n, true})
  end

  # ── 1 ───────────────────────────────────────────────────────────────────

  describe "1 write, duplicate and conflict" do
    test "an equal proposal is duplicate, also at another written_at_ms; any other field conflicts",
         %{m: m, p: p} do
      x = prop("m1")
      assert w(m, "T1", x) == {:ok, :applied}
      assert w(m, "T1", x) == {:ok, :duplicate}
      assert w(m, "T1", %{x | written_at_ms: 2000}) == {:ok, :duplicate}

      changes = [
        content: marked("other content"),
        content: marked("content of m1", "derived"),
        scope: {:subject, "s2"},
        scope: {:bot, "s1"},
        scope: {:tenant},
        kind: :preference,
        provenance: [{:run, "run-1"}],
        provenance: [{:message, "msg-1"}, {:run, "run-1"}],
        provenance: [{:artifact, "run-1"}, {:message, "msg-1"}],
        written_by: "agent-2",
        writer_kind: :human,
        expires_at_ms: 3000
      ]

      for {field, value} <- changes,
          do: assert(w(m, "T1", Map.put(x, field, value)) == {:error, :conflict})

      # The same memory_id under another tenant is another record.
      assert w(m, "T2", %{x | kind: :summary}) == {:ok, :applied}

      assert truth(
               p,
               ~s(SELECT tenant, memory_id, kind, written_at_ms FROM "#{p}".#{@rec} ORDER BY 1)
             ) ==
               [["T1", "m1", "fact", 1000], ["T2", "m1", "summary", 1000]]
    end

    test "two concurrent writes of one memory_id behind the per-ID lock store one record",
         %{m: m, p: p} do
      x = prop("m1")

      results =
        behind_lock(p, "T1", "m1", fn ->
          tasks = for _ <- 1..2, do: Task.async(fn -> w(m, "T1", x) end)
          wait_until(fn -> waiting(p, "T1", "m1") == 2 end)
          tasks
        end)

      assert Enum.sort(results) == [{:ok, :applied}, {:ok, :duplicate}]
      assert truth(p, "SELECT count(*) FROM \"#{p}\".#{@rec}") == [[1]]
    end
  end

  # ── 2 ───────────────────────────────────────────────────────────────────

  describe "2 policy" do
    test "check_write/2 decisions over the triple", %{m: _m} do
      x = prop("m1")
      triple = {:subject, :fact, :agent}

      assert MR.check_write(%{triple => :allow}, x) == :allow
      assert MR.check_write(%{triple => :ask}, x) == {:ask, :policy}
      assert MR.check_write(%{triple => :deny}, x) == {:deny, :policy}
      assert MR.check_write(%{{:subject, :fact, :human} => :allow}, x) == {:deny, :unlisted}
      assert MR.check_write(%{{:bot, :fact, :agent} => :allow}, x) == {:deny, :unlisted}
      assert MR.check_write(%{}, x) == {:deny, :unlisted}
      assert MR.check_write(@allow_all, %{x | scope: {:tenant}, kind: :summary}) == :allow

      for bad <- [
            %{{:conversation, :fact, :agent} => :allow},
            %{{:subject, :note, :agent} => :allow},
            %{{:subject, :fact, :model} => :allow},
            %{triple => :maybe},
            %{{:subject, :fact} => :allow},
            Map.put(@allow_all, :extra, :allow),
            [{triple, :allow}],
            nil
          ],
          do: assert(MR.check_write(bad, x) == {:error, :invalid})

      assert MR.check_write(%{triple => :allow}, Map.delete(x, :kind)) == {:error, :invalid}
    end

    test "write/4 stores only on allow or an approved ask", %{m: m, p: p} do
      triple = {:subject, :fact, :agent}
      x = prop("m1")
      {:ok, digest} = MR.digest("T1", x)

      # An approval of an edited proposal, or of another tenant's, does not admit this one.
      {:ok, edited} = MR.digest("T1", %{x | content: marked("edited")})
      {:ok, other_tenant} = MR.digest("T2", x)
      ask = %{triple => :ask}
      deny = %{triple => :deny}

      # Each refusal on its own ID, so one result does not hide another.
      refused = [
        MR.write(m, "T1", %{x | memory_id: "d1"}, %{policy: deny}),
        MR.write(m, "T1", %{x | memory_id: "d2"}, %{
          policy: deny,
          approval: %{ref: "a1", digest: digest}
        }),
        MR.write(m, "T1", %{x | memory_id: "d3"}, %{policy: %{}}),
        MR.write(m, "T1", x, %{policy: ask}),
        MR.write(m, "T1", x, %{policy: ask, approval: %{ref: "a1", digest: edited}}),
        MR.write(m, "T1", x, %{policy: ask, approval: %{ref: "a1", digest: other_tenant}})
      ]

      assert refused == [
               {:error, :denied},
               {:error, :denied},
               {:error, :denied},
               {:error, :approval_required},
               {:error, :approval_mismatch},
               {:error, :approval_mismatch}
             ]

      assert truth(p, "SELECT count(*) FROM \"#{p}\".#{@rec}") == [[0]]

      assert MR.write(m, "T1", x, %{
               policy: %{triple => :ask},
               approval: %{ref: "a1", digest: digest}
             }) ==
               {:ok, :applied}

      # An approval given on an allow is checked the same way and kept.
      y = prop("m2")
      {:ok, dy} = MR.digest("T1", y)

      assert MR.write(m, "T1", y, %{
               policy: %{triple => :allow},
               approval: %{ref: "a2", digest: digest}
             }) ==
               {:error, :approval_mismatch}

      assert MR.write(m, "T1", y, %{policy: %{triple => :allow}, approval: %{ref: "a2", digest: dy}}) ==
               {:ok, :applied}

      assert MR.write(m, "T1", prop("m3"), %{policy: %{triple => :allow}}) == {:ok, :applied}

      assert truth(p, ~s(SELECT memory_id, approval_ref FROM "#{p}".#{@rec} ORDER BY 1)) ==
               [["m1", "a1"], ["m2", "a2"], ["m3", nil]]
    end

    test "bad policy or approval in write/4 is invalid", %{m: m} do
      x = prop("m1")
      {:ok, digest} = MR.digest("T1", x)

      for opts <- [
            %{policy: %{{:conversation, :fact, :agent} => :allow}},
            %{policy: %{{:subject, :fact, :agent} => :yes}},
            %{policy: @allow_all, approval: %{ref: "a1"}},
            %{policy: @allow_all, approval: %{ref: "", digest: digest}},
            %{policy: @allow_all, approval: %{ref: String.duplicate("a", 257), digest: digest}},
            %{policy: @allow_all, approval: %{ref: "a1", digest: binary_part(digest, 0, 31)}},
            %{policy: @allow_all, approval: %{ref: "a1", digest: digest, extra: 1}},
            %{policy: @allow_all, extra: 1},
            %{}
          ],
          do: assert(MR.write(m, "T1", x, opts) == {:error, :invalid})

      assert MR.write(m, "T1", x, %{
               policy: @allow_all,
               approval: %{ref: String.duplicate("a", 256), digest: digest}
             }) == {:ok, :applied}
    end
  end

  # ── 3 ───────────────────────────────────────────────────────────────────

  describe "3 supersede" do
    test "one successor per record, of the same scope", %{m: m} do
      w!(m, "T1", prop("a"))
      assert w(m, "T1", prop("b", supersedes: "a", written_at_ms: 1100)) == {:ok, :applied}
      assert ids(recall!(m, "T1", [{:subject, "s1"}])) == ["b"]

      assert w(m, "T1", prop("c", supersedes: "a")) == {:error, :already_superseded}
      assert w(m, "T1", prop("c", supersedes: "b")) == {:ok, :applied}

      w!(m, "T1", prop("o", scope: {:subject, "s2"}))
      assert w(m, "T1", prop("d", supersedes: "o")) == {:error, :unknown_supersedes}
      assert w(m, "T1", prop("d", supersedes: "absent")) == {:error, :unknown_supersedes}
      assert w(m, "T2", prop("d", supersedes: "c")) == {:error, :unknown_supersedes}

      w!(m, "T1", prop("f"))
      assert forget(m, "T1", "f") == {:ok, :applied}
      assert w(m, "T1", prop("d", supersedes: "f")) == {:error, :unknown_supersedes}

      # Forgetting a successor does not make its predecessor current again.
      assert forget(m, "T1", "c") == {:ok, :applied}
      assert ids(recall!(m, "T1", [{:subject, "s1"}])) == []
      assert w(m, "T1", prop("e", supersedes: "b")) == {:error, :already_superseded}
    end

    test "two concurrent supersedes of one record behind its lock commit one", %{m: m, p: p} do
      w!(m, "T1", prop("a"))

      results =
        behind_lock(p, "T1", "a", fn ->
          tasks =
            for id <- ["b1", "b2"],
                do: Task.async(fn -> w(m, "T1", prop(id, supersedes: "a")) end)

          wait_until(fn -> waiting(p, "T1", "a") == 2 end)
          tasks
        end)

      assert Enum.sort(results) == [{:error, :already_superseded}, {:ok, :applied}]
      assert [_] = ids(recall!(m, "T1", [{:subject, "s1"}]))

      assert truth(p, "SELECT count(*) FROM \"#{p}\".#{@rec} WHERE supersedes = 'a'") == [[1]]
    end
  end

  # ── 4 ───────────────────────────────────────────────────────────────────

  describe "4 recall" do
    test "scope, kind, expiry at now_ms, order and the bounds", %{m: m} do
      w!(m, "T1", prop("old", written_at_ms: 1000))
      w!(m, "T1", prop("pref", kind: :preference, written_at_ms: 1500))
      w!(m, "T1", prop("tb", written_at_ms: 2000))
      w!(m, "T1", prop("ta", written_at_ms: 2000))
      w!(m, "T1", prop("tB", written_at_ms: 2000))
      w!(m, "T1", prop("exp", written_at_ms: 3000, expires_at_ms: 5000))
      w!(m, "T1", prop("live", written_at_ms: 3000, expires_at_ms: 5001))
      w!(m, "T1", prop("other", scope: {:subject, "s2"}, written_at_ms: 4000))
      w!(m, "T1", prop("gone", written_at_ms: 4000))
      {:ok, :applied} = forget(m, "T1", "gone")
      w!(m, "T1", prop("succ", supersedes: "old", written_at_ms: 900))

      # Newest first; a written_at_ms tie broken by memory_id bytes ("B" < "a" < "b").
      all = ["live", "tB", "ta", "tb", "pref", "succ"]
      assert %{more: false} = r = recall!(m, "T1", [{:subject, "s1"}])
      assert ids(r) == all
      assert Enum.map(r.entries, & &1.updated_at) == [3000, 2000, 2000, 2000, 1500, 900]

      # expires_at_ms equal to now_ms is expired; one more is current.
      assert "exp" in ids(recall!(m, "T1", [{:subject, "s1"}], now_ms: 4999))
      assert ids(recall!(m, "T1", [{:subject, "s1"}], now_ms: 5001)) -- all == []
      refute "live" in ids(recall!(m, "T1", [{:subject, "s1"}], now_ms: 5001))

      assert ids(recall!(m, "T1", [{:subject, "s1"}], kinds: [:preference])) == ["pref"]
      assert ids(recall!(m, "T1", [{:subject, "s1"}], kinds: [:summary])) == []
      assert ids(recall!(m, "T1", [{:subject, "s2"}])) == ["other"]

      assert %{entries: [%{candidate: %{item_id: "live"}}], more: true} =
               recall!(m, "T1", [{:subject, "s1"}], max_records: 1)

      assert %{more: false} = r = recall!(m, "T1", [{:subject, "s1"}], max_records: 6)
      assert length(r.entries) == 6
      assert %{more: true} = recall!(m, "T1", [{:subject, "s1"}], max_records: 5)

      # max_bytes at the edge: the sum of the first three fits exactly; the fourth passes it.
      size = fn id -> byte_size("content of " <> id) end
      edge = size.("live") + size.("tB") + size.("ta")
      assert %{more: true} = r = recall!(m, "T1", [{:subject, "s1"}], max_bytes: edge)
      assert ids(r) == ["live", "tB", "ta"]
      assert %{more: true} = r = recall!(m, "T1", [{:subject, "s1"}], max_bytes: edge - 1)
      assert ids(r) == ["live", "tB"]
      total = Enum.sum(Enum.map(all, size))
      assert %{more: false} = r = recall!(m, "T1", [{:subject, "s1"}], max_bytes: total)
      assert ids(r) == all
      assert %{entries: [], more: true} = recall!(m, "T1", [{:subject, "s1"}], max_bytes: 1)
    end

    test "max_records 256 returns 256 records and more when one more exists", %{m: m} do
      for n <- 1..257, do: w!(m, "T1", prop("m" <> String.pad_leading("#{n}", 3, "0")))

      assert %{more: true} = r = recall!(m, "T1", [{:subject, "s1"}], max_records: 256)
      assert length(r.entries) == 256
      assert hd(ids(r)) == "m001"

      {:ok, :applied} = forget(m, "T1", "m257")
      assert %{more: false} = r = recall!(m, "T1", [{:subject, "s1"}], max_records: 256)
      assert length(r.entries) == 256
    end

    test "request bounds at both edges", %{m: m} do
      w!(m, "T1", prop("m1"))
      ok = fn changes -> match?({:ok, _}, MR.recall(m, "T1", req([{:subject, "s1"}], changes))) end
      scopes = fn n -> for i <- 1..n, do: {:space, "sp#{i}"} end

      for {changes, expected} <- [
            {%{max_records: 0}, false},
            {%{max_records: 1}, true},
            {%{max_records: 256}, true},
            {%{max_records: 257}, false},
            {%{max_bytes: 0}, false},
            {%{max_bytes: 1}, true},
            {%{max_bytes: 1_048_576}, true},
            {%{max_bytes: 1_048_577}, false},
            {%{now_ms: -1}, false},
            {%{now_ms: 0}, true},
            {%{now_ms: @max_time}, true},
            {%{now_ms: @max_time + 1}, false},
            {%{checked_at: -1}, false},
            {%{checked_at: 0}, true},
            {%{checked_at: @max_time}, true},
            {%{checked_at: @max_time + 1}, false},
            {%{scopes: []}, false},
            {%{scopes: scopes.(1)}, true},
            {%{scopes: scopes.(16)}, true},
            {%{scopes: scopes.(17)}, false},
            {%{scopes: [{:tenant}, {:tenant}]}, false},
            {%{scopes: [{:conversation, "c"}]}, false},
            {%{scopes: [{:space, ""}]}, false},
            {%{kinds: []}, false},
            {%{kinds: [:fact]}, true},
            {%{kinds: @kinds}, true},
            {%{kinds: [:fact, :fact]}, false},
            {%{kinds: [:note]}, false},
            {%{kinds: @kinds ++ [:fact]}, false},
            {%{principal: ""}, false},
            {%{principal: "p"}, true},
            {%{principal: String.duplicate("p", 128)}, true},
            {%{principal: String.duplicate("p", 129)}, false},
            {%{extra: 1}, false}
          ],
          do: assert(ok.(changes) == expected, inspect(changes))

      assert MR.recall(m, "T1", Map.delete(req([{:tenant}]), :now_ms)) == {:error, :invalid}
    end
  end

  # ── 5 ───────────────────────────────────────────────────────────────────

  test "5 mixed scopes and kinds return exactly the named scopes and kinds", %{m: m} do
    scopes = [
      {:tenant},
      {:space, "x"},
      {:space, "y"},
      {:subject, "x"},
      {:subject, "s2"},
      {:bot, "x"},
      {:bot, "b2"}
    ]

    for {scope, i} <- Enum.with_index(scopes), kind <- @kinds do
      w!(m, "T1", prop("#{i}-#{kind}", scope: scope, kind: kind, written_at_ms: 1000 + i))
    end

    # A superseded record of a named scope and kind is not current.
    w!(m, "T1", prop("3-fact-2", scope: {:subject, "x"}, supersedes: "3-fact", written_at_ms: 2000))

    r = recall!(m, "T1", [{:subject, "x"}, {:tenant}], kinds: [:fact, :preference])

    assert Enum.map(r.entries, &{&1.candidate.item_id, &1.scope, &1.kind}) == [
             {"3-fact-2", {:subject, "x"}, :fact},
             {"3-preference", {:subject, "x"}, :preference},
             {"0-fact", {:tenant}, :fact},
             {"0-preference", {:tenant}, :preference}
           ]

    assert r.more == false

    for scope <- scopes,
        do: assert(Enum.all?(recall!(m, "T1", [scope]).entries, &(&1.scope == scope)))

    assert length(recall!(m, "T1", [{:space, "x"}]).entries) == 3
    assert length(recall!(m, "T1", [{:bot, "x"}]).entries) == 3
  end

  # ── 6 ───────────────────────────────────────────────────────────────────

  test "6 forget deletes content and provenance and keeps a tombstone", %{m: m, p: p} do
    secret = "the user's private preference"
    w!(m, "T1", prop("m1", content: marked(secret), provenance: [{:person, "person-secret"}]))
    w!(m, "T1", prop("m2", supersedes: nil))
    w!(m, "T1", prop("m3", supersedes: "m2"))

    assert forget(m, "T1", "m1") == {:ok, :applied}

    records = direct("T1", ~s(SELECT * FROM "#{p}".#{@rec}))
    tombstones = direct("T1", ~s(SELECT * FROM "#{p}".#{@tomb}))
    everything = inspect({records, tombstones}, limit: :infinity, printable_limit: :infinity)

    refute everything =~ secret
    refute everything =~ "person-secret"
    assert everything =~ "content of m2"
    assert length(records) == 2

    assert direct(
             "T1",
             ~s(SELECT memory_id, scope_kind, scope_id, supersedes, forgotten_at_ms, actor_ref, reason FROM "#{p}".#{@tomb})
           ) == [["m1", "subject", "s1", nil, 9000, "ops-1", "user_request"]]

    # Forgetting a successor keeps its supersedes on the tombstone.
    assert forget(m, "T1", "m3") == {:ok, :applied}

    assert direct("T1", ~s(SELECT memory_id, supersedes FROM "#{p}".#{@tomb} ORDER BY 1)) ==
             [["m1", nil], ["m3", "m2"]]

    # The first tombstone stays on a repeat.
    assert forget(m, "T1", "m1", "other_reason") == {:ok, :duplicate}

    assert direct("T1", ~s(SELECT reason FROM "#{p}".#{@tomb} WHERE memory_id = 'm1')) == [
             ["user_request"]
           ]

    assert w(m, "T1", prop("m1", content: marked(secret), provenance: [{:person, "person-secret"}])) ==
             {:error, :forgotten}

    assert w(m, "T1", prop("m1")) == {:error, :forgotten}
    assert forget(m, "T1", "absent") == {:error, :unknown_memory}
    assert ids(recall!(m, "T1", [{:subject, "s1"}])) == []
  end

  # ── 7 ───────────────────────────────────────────────────────────────────

  describe "7 write against forget and erase" do
    test "forget queued first: the write is forgotten", %{m: m, p: p} do
      x = prop("m1")
      w!(m, "T1", x)

      queued(p, "T1", "m1", [fn -> forget(m, "T1", "m1") end, fn -> w(m, "T1", x) end], [
        {:ok, :applied},
        {:error, :forgotten}
      ])

      assert_buried(p, "m1")
    end

    test "write queued first: the write is duplicate, then the forget applies", %{m: m, p: p} do
      x = prop("m1")
      w!(m, "T1", x)

      queued(p, "T1", "m1", [fn -> w(m, "T1", x) end, fn -> forget(m, "T1", "m1") end], [
        {:ok, :duplicate},
        {:ok, :applied}
      ])

      assert_buried(p, "m1")
    end

    test "erase queued first: the write is forgotten", %{m: m, p: p} do
      x = prop("m1")
      w!(m, "T1", x)

      queued(p, "T1", "m1", [fn -> erase(m, "T1", "s1", nil) end, fn -> w(m, "T1", x) end], [
        {:ok, %{forgotten: ["m1"], cursor: nil}},
        {:error, :forgotten}
      ])

      assert_buried(p, "m1")
    end

    test "write queued first: the write is duplicate, then erase forgets it", %{m: m, p: p} do
      x = prop("m1")
      w!(m, "T1", x)

      queued(p, "T1", "m1", [fn -> w(m, "T1", x) end, fn -> erase(m, "T1", "s1", nil) end], [
        {:ok, :duplicate},
        {:ok, %{forgotten: ["m1"], cursor: nil}}
      ])

      assert_buried(p, "m1")
    end

    test "two calls that list one pair of IDs in opposite orders take their locks in key order",
         %{m: m, p: p} do
      # A repeated write of "b" locks [b, a] (its ID, then its predecessor); erase_subject/3
      # over s1 locks its batch [a, b]. Another connection holds the higher of the two keys,
      # one call queues first and the other second, once in each order (one tenant each).
      # With both calls taking keys in ascending order, the first holds the lower key and the
      # second waits for it. A call that takes its keys in another order lists the held key
      # first in one of the two runs; then it waits for that key holding nothing while the
      # other call takes the lower one: a deadlock that PostgreSQL ends as :unavailable. The
      # second tenant is chosen so that the higher key is on the same ID in both runs, so
      # every run covers both cases.
      erased = {:ok, %{forgotten: ["a", "b"], cursor: nil}}
      high = fn tenant -> Enum.max_by(["a", "b"], &key(p, tenant, &1)) end
      second = Enum.find(Enum.map(2..64, &"T#{&1}"), &(high.(&1) == high.("T1")))

      for {tenant, order, expected} <- [
            {"T1", [:write, :erase], [{:ok, :duplicate}, erased]},
            {second, [:erase, :write], [erased, {:error, :forgotten}]}
          ] do
        w!(m, tenant, prop("a"))
        b = prop("b", supersedes: "a")
        w!(m, tenant, b)
        call = %{write: fn -> w(m, tenant, b) end, erase: fn -> erase(m, tenant, "s1", nil) end}
        both = fn -> waiting(p, tenant, "a") + waiting(p, tenant, "b") end

        results =
          behind_lock(p, tenant, high.(tenant), fn ->
            [first, second] = order
            t1 = Task.async(call[first])
            wait_until(fn -> both.() == 1 end)
            t2 = Task.async(call[second])
            wait_until(fn -> both.() == 2 end)
            [t1, t2]
          end)

        assert {tenant, order, results} == {tenant, order, expected}

        for id <- ["a", "b"] do
          sql = &"SELECT count(*) FROM \"#{p}\".#{&1} WHERE memory_id = '#{id}'"
          assert direct(tenant, sql.(@rec)) == [[0]]
          assert direct(tenant, sql.(@tomb)) == [[1]]
        end
      end
    end

    test "a new record written after erase read its batch stays until a repeat", %{m: m, p: p} do
      w!(m, "T1", prop("m1"))

      [erased] =
        behind_lock(p, "T1", "m1", fn ->
          task = Task.async(fn -> erase(m, "T1", "s1", nil) end)
          wait_until(fn -> waiting(p, "T1", "m1") == 1 end)
          assert w(m, "T1", prop("m2")) == {:ok, :applied}
          [task]
        end)

      assert erased == {:ok, %{forgotten: ["m1"], cursor: nil}}
      assert ids(recall!(m, "T1", [{:subject, "s1"}])) == ["m2"]
      assert erase(m, "T1", "s1", nil) == {:ok, %{forgotten: ["m1", "m2"], cursor: nil}}
      assert ids(recall!(m, "T1", [{:subject, "s1"}])) == []
    end
  end

  defp assert_buried(p, id) do
    assert direct("T1", "SELECT count(*) FROM \"#{p}\".#{@rec} WHERE memory_id = '#{id}'") == [[0]]
    assert direct("T1", "SELECT count(*) FROM \"#{p}\".#{@tomb} WHERE memory_id = '#{id}'") == [[1]]
  end

  # ── 8 ───────────────────────────────────────────────────────────────────

  test "8 erase walks resumable batches of one subject only", %{m: m, p: p} do
    for id <- ["e", "a", "d", "b", "c"], do: w!(m, "T1", prop("s1-" <> id))
    w!(m, "T1", prop("s2-a", scope: {:subject, "s2"}))
    w!(m, "T1", prop("s1-space", scope: {:space, "s1"}))
    w!(m, "T1", prop("s1-bot", scope: {:bot, "s1"}))
    w!(m, "T2", prop("s1-z"))

    batches = [
      {:ok, %{forgotten: ["s1-a", "s1-b"], cursor: "s1-b"}},
      {:ok, %{forgotten: ["s1-c", "s1-d"], cursor: "s1-d"}},
      {:ok, %{forgotten: ["s1-e"], cursor: nil}}
    ]

    # A stop after the first batch, then a repeat from cursor nil returns the same batches.
    assert erase(m, "T1", "s1", nil, 2) == hd(batches)
    assert walk(m, nil, []) == batches

    assert direct("T1", ~s(SELECT memory_id, reason FROM "#{p}".#{@tomb} ORDER BY 1)) ==
             for(id <- ~w(a b c d e), do: ["s1-" <> id, "subject_erasure"])

    assert ids(recall!(m, "T1", [{:subject, "s1"}])) == []
    assert ids(recall!(m, "T1", [{:subject, "s2"}])) == ["s2-a"]
    assert ids(recall!(m, "T1", [{:space, "s1"}, {:bot, "s1"}])) == ["s1-bot", "s1-space"]
    assert ids(recall!(m, "T2", [{:subject, "s1"}])) == ["s1-z"]

    assert erase(m, "T1", "nobody", nil, 2) == {:ok, %{forgotten: [], cursor: nil}}
    assert erase(m, "T1", "s1", "s1-e", 2) == {:ok, %{forgotten: [], cursor: nil}}
  end

  test "8 an erase batch reads at most max_batch + 1 rows of each table", %{m: m, p: p} do
    # 1,000 records and 1,000 tombstones of s1 and 1,000 records of s2, written by the owner.
    {:ok, _} =
      TI.transact(AdminRepo, %{tenant: "T1"}, fn ->
        for {table, subject, prefix} <- [{@rec, "s1", "r"}, {@tomb, "s1", "t"}, {@rec, "s2", "o"}] do
          columns =
            if table == @rec,
              do:
                "kind, schema_id, schema_version, sources, trust, max_bytes, content, provenance_kinds, provenance_ids, written_by, writer_kind, written_at_ms, digest",
              else: "forgotten_at_ms, actor_ref, reason"

          values =
            if table == @rec,
              do:
                "'fact', 'elzoo.untrusted-content.marked', 1, '{a}', 'untrusted', 4096, 'c', '{run}', '{r}', 'w', 'agent', 1, 'd'",
              else: "1, 'ops', 'r'"

          Harness.query!(
            AdminRepo,
            "INSERT INTO \"#{p}\".#{table} (tenant, memory_id, scope_kind, scope_id, #{columns}) SELECT 'T1', $1 || lpad(n::text, 4, '0'), 'subject', $2, #{values} FROM generate_series(1, 1000) n",
            [prefix, subject]
          )
        end

        {:ok, :inserted}
      end)

    for t <- [@rec, @tomb], do: Harness.query!(AdminRepo, "ANALYZE \"#{p}\".#{t}")

    handler = "elzoo-memory-record-plan-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:elzoo, :memory_record, :app_repo, :query],
      &__MODULE__.handle_statement/4,
      self()
    )

    try do
      # The first batch, a batch from the middle of the records and one past the records,
      # where only tombstones follow.
      for cursor <- [nil, "r0500", "r1000"] do
        flush_statements()
        assert {:ok, %{forgotten: [_, _]}} = erase(m, "T1", "s1", cursor, 2)

        [{sql, params}] =
          for {sql, params} <- received_statements([]), sql =~ "UNION", do: {sql, params}

        {:ok, [[plan]]} =
          TI.transact(AppRepo, %{tenant: "T1"}, fn ->
            {:ok,
             SQL.query!(AppRepo, "EXPLAIN (ANALYZE, FORMAT JSON) " <> sql, params, log: false).rows}
          end)

        plan = if is_binary(plan), do: Jason.decode!(plan), else: plan
        read = scans(hd(plan)["Plan"])

        # Each table's scan reads at most max_batch + 1 = 3 rows.
        assert Enum.sort(Map.keys(read)) == [@rec, @tomb], inspect({cursor, read})
        assert Enum.all?(read, fn {_, rows} -> rows <= 3 end), inspect({cursor, read})
      end
    after
      :telemetry.detach(handler)
    end
  end

  def handle_statement(_event, _measurements, meta, parent),
    do: send(parent, {:statement, meta.query, meta.params})

  defp flush_statements do
    receive do
      {:statement, _, _} -> flush_statements()
    after
      0 -> :ok
    end
  end

  defp received_statements(acc) do
    receive do
      {:statement, sql, params} -> received_statements([{sql, params} | acc])
    after
      0 -> acc
    end
  end

  # The rows that the scans of each Piece table read in an EXPLAIN ANALYZE plan.
  defp scans(node) do
    own =
      case node do
        %{"Relation Name" => table} when table in [@rec, @tomb] ->
          %{table => node["Actual Rows"] * node["Actual Loops"]}

        _ ->
          %{}
      end

    node
    |> Map.get("Plans", [])
    |> Enum.map(&scans/1)
    |> Enum.reduce(own, &Map.merge(&1, &2, fn _, a, b -> a + b end))
  end

  defp walk(m, cursor, acc) do
    {:ok, %{cursor: next}} = result = erase(m, "T1", "s1", cursor, 2)
    if next == nil, do: Enum.reverse([result | acc]), else: walk(m, next, [result | acc])
  end

  # ── 9 ───────────────────────────────────────────────────────────────────

  test "9 the marked value survives a round trip", %{m: m} do
    for {trust, id} <- [{"untrusted", "u"}, {"derived", "d"}] do
      content = marked("café \u0000 #{trust}", trust, 64)
      w!(m, "T1", prop(id, content: content))

      [entry] =
        recall!(m, "T1", [{:subject, "s1"}]).entries |> Enum.filter(&(&1.candidate.item_id == id))

      assert entry.marked == UC.encode(content)
      assert UC.decode(entry.marked) == {:ok, content}
      assert entry.candidate.content == UC.encode(content)["content"]
    end

    assert w(m, "T1", prop("e0", content: marked(""))) == {:error, :invalid}

    assert w(
             m,
             "T1",
             prop("e4097", content: marked(String.duplicate("a", 4097), "untrusted", 8192))
           ) ==
             {:error, :invalid}

    assert w(m, "T1", prop("e1", content: marked("a"))) == {:ok, :applied}

    assert w(m, "T1", prop("e4096", content: marked(String.duplicate("a", 4096)))) ==
             {:ok, :applied}

    for bad <- [UC.encode(marked("a")), {:UntrustedContent, %{}}, "text", nil],
        do: assert(w(m, "T1", prop("bad", content: bad)) == {:error, :invalid})
  end

  # ── 10 ──────────────────────────────────────────────────────────────────

  test "10 completed candidates pass context selection and a denied check vetoes", %{m: m} do
    w!(m, "T1", prop("keep", written_at_ms: 2000))
    w!(m, "T1", prop("deny", scope: {:space, "team"}, written_at_ms: 1000))
    r = recall!(m, "T1", [{:subject, "s1"}, {:space, "team"}])

    candidates =
      for e <- r.entries,
          do: Map.merge(e.candidate, %{estimate: byte_size(e.candidate.content), priority: 0})

    # The host's own current reading: the reader may not read the team space.
    nodes =
      for e <- r.entries do
        check =
          e.node
          |> Map.take([:item_id, :version, :tenant, :source, :content_hash])
          |> Map.merge(%{
            principal: "reader",
            checked_at: 5000,
            result: if(e.scope == {:space, "team"}, do: :denied, else: :allowed)
          })

        %{e.node | check: check}
      end

    window = %{
      provider_id: "anthropic",
      model_id: "model-a",
      size: 100_000,
      unit: :bytes,
      estimator_id: "bytes",
      estimator_version: 1
    }

    context = %{
      principal: "reader",
      tenant: "T1",
      now: 5000,
      snapshot_at: 5000,
      window: window,
      windows: [window],
      reservations: [],
      policy: %{
        max_age: 100,
        allow_derived: false,
        priority: :input,
        recency: :input,
        max_selected_count: 10,
        max_selected_bytes: 100_000
      },
      provenance: nodes
    }

    assert {:ok, %{selected: [selected], dropped: [dropped]}} =
             Elzoo.ContextSelection.select(%{candidates: candidates}, context)

    assert selected.item_id == "keep"
    assert %{item_id: "deny", reason: :access_denied} = dropped

    # With every check allowed, both pass.
    allowed = for n <- nodes, do: put_in(n, [:check, :result], :allowed)

    assert {:ok, %{selected: [_, _], dropped: []}} =
             Elzoo.ContextSelection.select(%{candidates: candidates}, %{
               context
               | provenance: allowed
             })
  end

  # ── 11 ──────────────────────────────────────────────────────────────────

  test "11 row security as the application role", %{m: m, p: p, role: role} do
    assert [[^role]] = Harness.query!(AppRepo, "SELECT current_user").rows

    for t <- [@rec, @tomb],
        do:
          assert(
            TI.verify(AppRepo, {p, t}, prefix: p, tenant_column: "tenant", space_column: nil) == :ok
          )

    w!(m, "T2", prop("t2-1"))
    w!(m, "T2", prop("t2-2"))
    w!(m, "T1", prop("t1-1"))
    assert w(m, "T1", prop("t1-2", supersedes: "t1-1")) == {:ok, :applied}

    assert ids(recall!(m, "T1", [{:subject, "s1"}])) == ["t1-2"]
    assert forget(m, "T1", "t2-1") == {:error, :unknown_memory}
    assert erase(m, "T1", "s1", nil) == {:ok, %{forgotten: ["t1-1", "t1-2"], cursor: nil}}
    assert ids(recall!(m, "T2", [{:subject, "s1"}])) == ["t2-1", "t2-2"]
    assert forget(m, "T2", "t2-1") == {:ok, :applied}

    insert = fn table, sql ->
      TI.transact(AppRepo, %{tenant: "T1"}, fn ->
        SQL.query(AppRepo, ~s(INSERT INTO "#{p}".#{table} #{sql}), [], log: false)
      end)
    end

    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             insert.(
               @rec,
               "(tenant, memory_id, scope_kind, scope_id, kind, schema_id, schema_version, sources, trust, max_bytes, content, provenance_kinds, provenance_ids, written_by, writer_kind, written_at_ms, digest) VALUES ('T2', 'x', 'tenant', '', 'fact', 's', 1, '{a}', 'untrusted', 1, 'a', '{run}', '{r}', 'w', 'agent', 1, 'd')"
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             insert.(
               @tomb,
               "(tenant, memory_id, scope_kind, scope_id, forgotten_at_ms, actor_ref, reason) VALUES ('T2', 'x', 'tenant', '', 1, 'a', 'r')"
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             TI.transact(AppRepo, %{tenant: "T2"}, fn ->
               SQL.query(AppRepo, ~s(UPDATE "#{p}".#{@rec} SET kind = 'summary'), [], log: false)
             end)

    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             TI.transact(AppRepo, %{tenant: "T2"}, fn ->
               SQL.query(AppRepo, ~s(DELETE FROM "#{p}".#{@tomb}), [], log: false)
             end)

    # Outside a scope, nothing is visible.
    assert Harness.query!(AppRepo, "SELECT count(*) FROM \"#{p}\".#{@rec}").rows == [[0]]
    assert truth(p, ~s(SELECT tenant, memory_id FROM "#{p}".#{@rec})) == [["T2", "t2-2"]]
  end

  # ── 12 ──────────────────────────────────────────────────────────────────

  test "12 a caller transaction and a repeatable read Repo are refused", %{m: m, p: p} do
    w!(m, "T1", prop("m1"))
    handler = "elzoo-memory-record-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:elzoo, :memory_record, :app_repo, :query],
      &__MODULE__.handle_query/4,
      self()
    )

    try do
      {:ok, results} =
        AppRepo.transact(fn ->
          flush_queries()

          results = [
            w(m, "T1", prop("m2")),
            MR.recall(m, "T1", req([{:subject, "s1"}])),
            forget(m, "T1", "m1"),
            erase(m, "T1", "s1", nil)
          ]

          refute_received {:query, _}
          {:ok, results}
        end)

      assert results == List.duplicate({:error, :in_transaction}, 4)

      # Invalid calls make no query either.
      flush_queries()
      assert w(m, "T1", prop("")) == {:error, :invalid}
      assert MR.recall(m, "T1", req([])) == {:error, :invalid}
      assert MR.write(m, "T1", prop("m9"), %{policy: %{}}) == {:error, :denied}
      refute_received {:query, _}
    after
      :telemetry.detach(handler)
    end

    rr = MR.new(repo: RepeatableRepo, prefix: p)
    assert w(rr, "T1", prop("m2")) == {:error, :isolation}
    assert forget(rr, "T1", "m1") == {:error, :isolation}
    assert erase(rr, "T1", "s1", nil) == {:error, :isolation}
    assert {:ok, %{entries: [_]}} = MR.recall(rr, "T1", req([{:subject, "s1"}]))

    assert truth(p, ~s(SELECT memory_id FROM "#{p}".#{@rec})) == [["m1"]]
    assert truth(p, "SELECT count(*) FROM \"#{p}\".#{@tomb}") == [[0]]

    # A missing schema is unavailable.
    missing = MR.new(repo: AppRepo, prefix: "elz332_missing")
    assert w(missing, "T1", prop("m1")) == {:error, :unavailable}
    assert MR.recall(missing, "T1", req([{:tenant}])) == {:error, :unavailable}
    assert forget(missing, "T1", "m1") == {:error, :unavailable}
    assert erase(missing, "T1", "s1", nil) == {:error, :unavailable}
  end

  def handle_query(_event, _measurements, meta, parent), do: send(parent, {:query, meta.query})

  defp flush_queries do
    receive do
      {:query, _} -> flush_queries()
    after
      0 -> :ok
    end
  end

  # ── 13 ──────────────────────────────────────────────────────────────────

  test "13 bounds at their edges", %{m: m} do
    t = fn n -> String.duplicate("a", n) end
    bad_texts = ["", t.(129), <<0xFF>>, "a\u0007", "a\u0085", 1, nil]
    good_texts = [t.(1), t.(128), "é"]
    ok? = fn p -> MR.digest("T1", p) != {:error, :invalid} end

    erase_with = fn changes ->
      MR.erase_subject(
        m,
        "T1",
        Map.merge(
          %{subject: "s1", actor_ref: "ops", forgotten_at_ms: 1, cursor: nil, max_batch: 1},
          changes
        )
      )
    end

    forget_actor = fn v ->
      MR.forget(m, "T1", %{memory_id: "m", actor_ref: v, reason: "r", forgotten_at_ms: 1})
    end

    for field <- [:memory_id, :written_by] do
      for v <- bad_texts, do: refute(ok?.(prop("m", %{field => v})), inspect({field, v}))
      for v <- good_texts, do: assert(ok?.(prop("m", %{field => v})), inspect({field, v}))
    end

    # nil is a valid supersedes and cursor ("none"), checked apart.
    for v <- bad_texts -- [nil], do: refute(ok?.(prop("m", supersedes: v)))
    for v <- bad_texts -- [nil], do: assert(erase(m, "T1", "s1", v) == {:error, :invalid})

    for v <- bad_texts do
      refute ok?.(prop("m", scope: {:subject, v}))
      refute ok?.(prop("m", provenance: [{:run, v}]))
      assert MR.digest(v, prop("m")) == {:error, :invalid}
      assert forget(m, v, "m") == {:error, :invalid}

      assert forget_actor.(v) == {:error, :invalid}
      assert erase(m, "T1", v, nil) == {:error, :invalid}
      assert erase_with.(%{actor_ref: v}) == {:error, :invalid}
      assert MR.recall(m, "T1", req([{:tenant}], principal: v)) == {:error, :invalid}
    end

    # Every text field accepts 1 and 128 bytes and a multibyte character.
    for v <- good_texts do
      for kind <- [:space, :subject, :bot], do: assert(ok?.(prop("m", scope: {kind, v})))
      assert ok?.(prop("m", provenance: [{:artifact, v}]))
      assert ok?.(prop("m", supersedes: v))
      assert MR.digest(v, prop("m")) |> elem(0) == :ok
      assert forget_actor.(v) == {:error, :unknown_memory}
      assert forget(m, "T1", v) == {:error, :unknown_memory}
      assert erase_with.(%{subject: v}) == {:ok, %{forgotten: [], cursor: nil}}
      assert erase_with.(%{actor_ref: v}) == {:ok, %{forgotten: [], cursor: nil}}
      assert erase_with.(%{cursor: v}) == {:ok, %{forgotten: [], cursor: nil}}
      assert {:ok, _} = MR.recall(m, "T1", req([{:tenant}], principal: v))
    end

    assert ok?.(prop("m", scope: {:tenant}))
    refute ok?.(prop("m", scope: {:tenant, "x"}))
    refute ok?.(prop("m", scope: {:conversation, "c"}))
    refute ok?.(prop("m", scope: :tenant))
    refute ok?.(prop("m", kind: :note))
    refute ok?.(prop("m", writer_kind: :model))
    refute ok?.(prop("m", supersedes: "m"))
    refute ok?.(prop("m", provenance: [{:tool, "x"}]))
    refute ok?.(prop("m", provenance: [{:run, "x"}, {:run, "x"}]))
    refute ok?.(prop("m", provenance: []))
    refute ok?.(prop("m", provenance: [:run]))
    assert ok?.(prop("m", provenance: [{:person, "p"}]))
    assert ok?.(prop("m", provenance: for(i <- 1..16, do: {:run, "r#{i}"})))
    refute ok?.(prop("m", provenance: for(i <- 1..17, do: {:run, "r#{i}"})))
    refute ok?.(Map.put(prop("m"), :extra, 1))
    refute ok?.(Map.delete(prop("m"), :supersedes))

    for field <- [:written_at_ms, :expires_at_ms] do
      refute ok?.(prop("m", %{field => -1}))
      refute ok?.(prop("m", %{field => @max_time + 1}))
      refute ok?.(prop("m", %{field => 1.0}))
      assert ok?.(prop("m", %{field => 0}))
      assert ok?.(prop("m", %{field => @max_time}))
    end

    forget_req = fn changes ->
      Map.merge(%{memory_id: "m", actor_ref: "ops", reason: "r", forgotten_at_ms: 1}, changes)
    end

    for {changes, valid} <- [
          {%{reason: String.duplicate("r", 64)}, true},
          {%{reason: String.duplicate("r", 65)}, false},
          {%{reason: "Capital"}, false},
          {%{reason: ""}, false},
          {%{reason: "a b"}, false},
          {%{reason: "a_z.0:9-"}, true},
          {%{forgotten_at_ms: -1}, false},
          {%{forgotten_at_ms: @max_time + 1}, false},
          {%{forgotten_at_ms: @max_time}, true}
        ] do
      result = MR.forget(m, "T1", forget_req.(changes))

      if valid,
        do: assert(result == {:error, :unknown_memory}),
        else: assert(result == {:error, :invalid})
    end

    erase_req = fn changes ->
      Map.merge(
        %{subject: "s1", actor_ref: "ops", forgotten_at_ms: 1, cursor: nil, max_batch: 1},
        changes
      )
    end

    for {changes, valid} <- [
          {%{max_batch: 0}, false},
          {%{max_batch: 1}, true},
          {%{max_batch: 256}, true},
          {%{max_batch: 257}, false},
          {%{forgotten_at_ms: -1}, false},
          {%{cursor: t.(128)}, true},
          {%{extra: 1}, false}
        ] do
      result = MR.erase_subject(m, "T1", erase_req.(changes))
      if valid, do: assert(match?({:ok, _}, result)), else: assert(result == {:error, :invalid})
    end

    # New, the migration and every function refuse a bad memory value.
    for opts <- [
          [repo: AppRepo],
          [repo: AppRepo, prefix: "Bad"],
          [repo: AppRepo, prefix: "a-b"],
          [repo: nil, prefix: "ok"],
          [repo: AppRepo, prefix: "ok", extra: 1],
          %{repo: AppRepo, prefix: "ok"}
        ],
        do: assert_raise(ArgumentError, @message, fn -> MR.new(opts) end)

    for prefix <- ["Bad", "a-b", "", nil, :atom, String.duplicate("a", 64)],
        do: assert_raise(ArgumentError, @message, fn -> Migration.install(prefix) end)

    assert w(%{repo: AppRepo, prefix: "ok"}, "T1", prop("m")) == {:error, :invalid}
  end

  # ── digest ──────────────────────────────────────────────────────────────

  test "the digest is SHA-256 of the README encoding and decides duplicates", %{m: m, p: p} do
    x = prop("m1", scope: {:space, "sp"}, expires_at_ms: 7000, supersedes: nil)
    frame = fn items -> for i <- items, into: "", do: <<byte_size(i)::32>> <> i end

    # The neutral map's six keys in byte order; an integer as decimal text, a list framed.
    content =
      frame.(["content", "content of m1"]) <>
        frame.(["max_bytes", "4096"]) <>
        frame.(["schema_id", "elzoo.untrusted-content.marked"]) <>
        frame.(["schema_version", "1"]) <>
        frame.(["sources", frame.(["chat:1", "run:7"])]) <>
        frame.(["trust", "untrusted"])

    fields = [
      {"content", content},
      {"expires_at_ms", "7000"},
      {"kind", "fact"},
      {"memory_id", "m1"},
      {"provenance", frame.([frame.(["run", "run-1"]), frame.(["message", "msg-1"])])},
      {"scope", frame.(["space", "sp"])},
      {"supersedes", ""},
      {"tenant", "T1"},
      {"written_by", "agent-1"},
      {"writer_kind", "agent"}
    ]

    body = for {k, v} <- Enum.sort(fields), into: "", do: frame.([k, v])
    expected = :crypto.hash(:sha256, "elzoo.memory-record.proposal" <> <<0>> <> body)

    assert MR.digest("T1", x) == {:ok, expected}
    assert MR.digest("T1", %{x | written_at_ms: 1}) == {:ok, expected}
    {:ok, :applied} = w(m, "T1", x)
    assert truth(p, ~s(SELECT digest FROM "#{p}".#{@rec})) == [[expected]]

    # Framing: moving bytes between adjacent fields gives another digest.
    {:ok, a} = MR.digest("T1", prop("m1", provenance: [{:run, "ab"}, {:run, "c"}]))
    {:ok, b} = MR.digest("T1", prop("m1", provenance: [{:run, "a"}, {:run, "bc"}]))
    assert a != b
    {:ok, c} = MR.digest("T1", prop("m1", scope: {:tenant}))
    {:ok, d} = MR.digest("T1", prop("m1", scope: {:space, "tenant"}))
    assert c != d

    assert MR.digest("T1", prop("m1", supersedes: nil)) !=
             MR.digest("T1", prop("m1", supersedes: "x"))
  end

  # ── Cure ────────────────────────────────────────────────────────────────

  test "selected Cure laws, a clean audit and the production decisions" do
    source = File.read!(Path.expand("../../cure/elzoo/memory_record.cure", __DIR__))
    roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
    assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
    assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(audit, key) == [])

    for law <- [
          :unlisted_denied,
          :deny_never_writes,
          :ask_writes_only_approved,
          :mismatch_never_writes
        ],
        do: assert(source =~ "fn #{law}(")

    cure = :"Cure.Elzoo.MemoryRecord"
    assert apply(cure, :decide, [:MemoryUnlisted]) == :MemoryDenyUnlisted
    assert apply(cure, :decide, [{:MemoryListed, :MemoryAllow}]) == :MemoryAllowed
    assert apply(cure, :decide, [{:MemoryListed, :MemoryAsk}]) == :MemoryAskPolicy
    assert apply(cure, :decide, [{:MemoryListed, :MemoryDeny}]) == :MemoryDenyPolicy

    table = [
      {:MemoryAllowed, :MemoryNoApproval, :MemoryWrite},
      {:MemoryAllowed, :MemoryMatching, :MemoryWrite},
      {:MemoryAllowed, :MemoryMismatching, :MemoryApprovalMismatch},
      {:MemoryAskPolicy, :MemoryNoApproval, :MemoryApprovalRequired},
      {:MemoryAskPolicy, :MemoryMatching, :MemoryWrite},
      {:MemoryAskPolicy, :MemoryMismatching, :MemoryApprovalMismatch},
      {:MemoryDenyPolicy, :MemoryMatching, :MemoryDenied},
      {:MemoryDenyUnlisted, :MemoryMatching, :MemoryDenied}
    ]

    for {d, a, expected} <- table, do: assert(apply(cure, :admit, [d, a]) == expected)
  end
end
