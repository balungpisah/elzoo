# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/work_item_test_helper.exs", __DIR__)

defmodule Elzoo.WorkItemTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL
  alias Elzoo.TenantIsolation, as: TI
  alias Elzoo.UntrustedContent, as: UC
  alias Elzoo.WorkItem, as: WI
  alias Elzoo.WorkItem.{AdminRepo, AppRepo, Harness, LaterRepo, Migration, RepeatableRepo}
  alias Elzoo.WorkItem.WriterRepo

  @message "invalid work item repo or prefix"
  @table "elzoo_work_items"
  @max_revision 2_147_483_647

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
    {:ok, p: p, w: WI.new(repo: AppRepo, prefix: p)}
  end

  # ── values ──────────────────────────────────────────────────────────────

  defp marked(text, trust \\ "untrusted", bound \\ 4096, sources \\ ["chat:1", "run:7"]) do
    {:ok, marked} =
      UC.decode(%{
        "schema_id" => "elzoo.untrusted-content.marked",
        "schema_version" => 1,
        "sources" => sources,
        "trust" => trust,
        "max_bytes" => bound,
        "content" => text
      })

    marked
  end

  defp item(id, changes \\ %{}) do
    Map.merge(
      %{
        item_id: id,
        parent_run_id: "parent-1",
        child_run_id: "child-" <> id,
        owner: "owner-1",
        intent: marked("summarise the item"),
        acceptance: :parent,
        parent_close: :request_cancel
      },
      Map.new(changes)
    )
  end

  defp create!(w, tenant, item), do: {:ok, :applied} = WI.create(w, tenant, item)

  defp step(w, t, id, rev, :start), do: WI.start(w, t, id, %{revision: rev})

  defp step(w, t, id, rev, {:offer, evidence}),
    do: WI.offer(w, t, id, %{revision: rev, child_run_id: "child-" <> id, evidence: evidence})

  defp step(w, t, id, rev, :offer), do: step(w, t, id, rev, {:offer, "outcome-1"})

  defp step(w, t, id, rev, decision) when decision in [:accepted, :rejected],
    do: WI.decide(w, t, id, %{revision: rev, decided_by: "owner-1", decision: decision})

  defp step(w, t, id, rev, {:close, to}), do: WI.close(w, t, id, %{revision: rev, to: to})

  @paths %{
    open: [],
    running: [:start],
    offered: [:start, :offer],
    accepted: [:start, :offer, :accepted],
    rejected: [:start, :offer, :rejected],
    cancel_requested: [{:close, :cancel_requested}],
    cancelled: [{:close, :cancelled}],
    abandoned: [{:close, :abandoned}]
  }

  # Create item `id` and move it to `state` by allowed transitions; its revision.
  defp in_state(w, tenant, id, state, changes \\ %{}) do
    create!(w, tenant, item(id, changes))

    Enum.reduce(@paths[state], 1, fn s, rev ->
      assert step(w, tenant, id, rev, s) == {:ok, %{revision: rev + 1}}
      rev + 1
    end)
  end

  defp get!(w, tenant, id) do
    {:ok, item} = WI.get(w, tenant, id)
    item
  end

  defp open!(w, tenant, parent, after_id, limit) do
    {:ok, result} = WI.list_open(w, tenant, %{parent_run_id: parent, after: after_id, limit: limit})
    result
  end

  defp ids(%{items: items}), do: Enum.map(items, & &1.item_id)

  # ── direct reads ────────────────────────────────────────────────────────

  # A direct read as the application role inside the tenant scope (the table forces row
  # security, so a read outside a scope sees no rows and would prove nothing).
  defp direct(tenant, sql, params) do
    {:ok, rows} =
      TI.transact(AppRepo, %{tenant: tenant}, fn ->
        {:ok, SQL.query!(AppRepo, sql, params, log: false).rows}
      end)

    rows
  end

  # The row's revision and xmin: a write of any kind gives the row a new xmin.
  defp version(p, tenant, id),
    do:
      direct(tenant, ~s(SELECT revision, xmin::text FROM "#{p}".#{@table} WHERE item_id = $1), [
        id
      ])

  # Ground truth as the owner with FORCE dropped inside a rolled-back transaction.
  defp truth(p, sql, params \\ []) do
    {:error, {:rows, rows}} =
      AdminRepo.transact(fn ->
        Harness.query!(AdminRepo, ~s(ALTER TABLE "#{p}".#{@table} NO FORCE ROW LEVEL SECURITY))
        {:error, {:rows, Harness.query!(AdminRepo, sql, params).rows}}
      end)

    rows
  end

  # ── the row-lock barrier ────────────────────────────────────────────────

  defp wait_until(check, tries \\ 500) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("the barrier condition never held")
      true -> Process.sleep(10) && wait_until(check, tries - 1)
    end
  end

  # Ungranted locks behind the holder's row lock: the first UPDATE waits on the holder's
  # transaction ID, each later one on the tuple lock of the row's table.
  defp waiting(p, holder) do
    [[n]] =
      Harness.query!(
        AdminRepo,
        """
        SELECT count(*) FROM pg_locks w
        WHERE NOT w.granted AND (
          (w.locktype = 'tuple' AND w.relation = $1::text::regclass)
          OR (w.locktype = 'transactionid' AND w.transactionid IN (
            SELECT h.transactionid FROM pg_locks h
            WHERE h.pid = $2 AND h.locktype = 'transactionid' AND h.granted)))
        """,
        [~s("#{p}".#{@table}), holder]
      ).rows

    n
  end

  # Another connection holds the item's row lock (SELECT ... FOR UPDATE) until every call's
  # UPDATE waits on it in pg_locks; then it releases and the results return in call order.
  defp behind_row_lock(p, tenant, id, calls) do
    parent = self()

    holder =
      Task.async(fn ->
        TI.transact(AdminRepo, %{tenant: tenant}, fn ->
          sql = ~s(SELECT 1 FROM "#{p}".#{@table} WHERE tenant = $1 AND item_id = $2 FOR UPDATE)
          [[1]] = Harness.query!(AdminRepo, sql, [tenant, id]).rows
          [[pid]] = Harness.query!(AdminRepo, "SELECT pg_backend_pid()").rows
          send(parent, {:held, pid})

          receive do
            :release -> {:ok, :released}
          end
        end)
      end)

    assert_receive {:held, holder_pid}

    try do
      tasks = Enum.map(calls, &Task.async/1)
      wait_until(fn -> waiting(p, holder_pid) == length(calls) end)
      send(holder.pid, :release)
      assert Task.await(holder) == {:ok, :released}
      Enum.map(tasks, &Task.await(&1, 10_000))
    after
      send(holder.pid, :release)
    end
  end

  # ── 1 ───────────────────────────────────────────────────────────────────

  describe "1 RC-11 narrowed" do
    test "a stale holder cannot offer; a duplicate offer is unchanged, also at a stale revision",
         %{w: w, p: p} do
      rev = in_state(w, "T1", "i1", :running)
      stale = %{revision: rev, child_run_id: "child-old", evidence: "outcome-1"}
      assert WI.offer(w, "T1", "i1", stale) == {:error, :not_assignee}
      assert get!(w, "T1", "i1").state == :running

      offer = %{revision: rev, child_run_id: "child-i1", evidence: "outcome-1"}
      assert WI.offer(w, "T1", "i1", offer) == {:ok, %{revision: 3}}
      assert WI.offer(w, "T1", "i1", %{stale | revision: 3}) == {:error, :not_assignee}

      before = version(p, "T1", "i1")

      for r <- [3, 2, 1, @max_revision],
          do: assert(WI.offer(w, "T1", "i1", %{offer | revision: r}) == {:ok, :unchanged})

      assert version(p, "T1", "i1") == before
      assert %{state: :offered, evidence: "outcome-1", revision: 3} = get!(w, "T1", "i1")
    end

    test "every no-op writes nothing: revision and xmin unchanged", %{w: w, p: p} do
      no_ops = [
        {"n-start", :running, :start},
        {"n-offer", :offered, :offer},
        {"n-accept", :accepted, :accepted},
        {"n-reject", :rejected, :rejected},
        {"n-cr", :cancel_requested, {:close, :cancel_requested}},
        {"n-cancel", :cancelled, {:close, :cancelled}},
        {"n-abandon", :abandoned, {:close, :abandoned}}
      ]

      for {id, state, request} <- no_ops do
        rev = in_state(w, "T1", id, state)
        before = version(p, "T1", id)
        assert [[^rev, _]] = before

        for r <- [rev, rev - 1, 1, @max_revision],
            do: assert(step(w, "T1", id, r, request) == {:ok, :unchanged}, "#{id} at #{r}")

        assert version(p, "T1", id) == before, id
      end
    end

    test "closing to cancel_requested and then cancelled keeps the intent bytes", %{w: w} do
      intent = marked("keep <these> bytes\0 é", "derived", 64)
      create!(w, "T1", item("c1", intent: intent))
      assert step(w, "T1", "c1", 1, {:close, :cancel_requested}) == {:ok, %{revision: 2}}
      assert step(w, "T1", "c1", 2, {:close, :cancelled}) == {:ok, %{revision: 3}}
      assert %{state: :cancelled, intent: stored} = get!(w, "T1", "c1")
      assert stored == UC.encode(intent)
    end

    test "the Piece has no Attempt input and no completion without decide/4" do
      assert Enum.sort(WI.__info__(:functions) -- [__struct__: 0, __struct__: 1]) ==
               Enum.sort(
                 close: 4,
                 create: 3,
                 decide: 4,
                 get: 3,
                 list_open: 3,
                 new: 1,
                 offer: 4,
                 start: 4,
                 verify: 1
               )
    end
  end

  # ── 2 ───────────────────────────────────────────────────────────────────

  # Written from the Contract's state list, independently of the code: for an item in each
  # state, what each request gives. :ok is a write to the request's target state.
  @requests [
    start: :start,
    offer: {:offer, "outcome-2"},
    accept: :accepted,
    reject: :rejected,
    cancel_requested: {:close, :cancel_requested},
    cancelled: {:close, :cancelled},
    abandoned: {:close, :abandoned}
  ]
  @targets %{
    start: :running,
    offer: :offered,
    accept: :accepted,
    reject: :rejected,
    cancel_requested: :cancel_requested,
    cancelled: :cancelled,
    abandoned: :abandoned
  }
  @matrix %{
    open: [:ok, {:state, :open}, {:state, :open}, {:state, :open}, :ok, :ok, :ok],
    running: [:unchanged, :ok, {:state, :running}, {:state, :running}, :ok, :ok, :ok],
    offered: [{:state, :offered}, :conflict, :ok, :ok, :ok, :ok, :ok],
    accepted:
      [{:state, :accepted}, {:state, :accepted}, :unchanged] ++
        List.duplicate({:state, :accepted}, 4),
    rejected:
      [{:state, :rejected}, {:state, :rejected}, {:state, :rejected}, :unchanged] ++
        List.duplicate({:state, :rejected}, 3),
    cancel_requested: List.duplicate({:state, :cancel_requested}, 4) ++ [:unchanged, :ok, :ok],
    cancelled: List.duplicate({:state, :cancelled}, 5) ++ [:unchanged, {:state, :cancelled}],
    abandoned: List.duplicate({:state, :abandoned}, 6) ++ [:unchanged]
  }

  describe "2 lifecycle" do
    test "create, start, offer, accept; and offer, reject", %{w: w} do
      create!(w, "T1", item("a"))

      assert %{state: :open, revision: 1, evidence: nil, decided_by: nil, owner: "owner-1"} =
               get!(w, "T1", "a")

      assert step(w, "T1", "a", 1, :start) == {:ok, %{revision: 2}}
      assert step(w, "T1", "a", 2, {:offer, "outcome:a/1"}) == {:ok, %{revision: 3}}
      assert %{state: :offered, evidence: "outcome:a/1"} = get!(w, "T1", "a")
      assert step(w, "T1", "a", 3, :accepted) == {:ok, %{revision: 4}}

      assert %{state: :accepted, revision: 4, evidence: "outcome:a/1", decided_by: "owner-1"} =
               get!(w, "T1", "a")

      assert in_state(w, "T1", "r", :offered) == 3
      assert step(w, "T1", "r", 3, :rejected) == {:ok, %{revision: 4}}
      assert %{state: :rejected, decided_by: "owner-1", evidence: "outcome-1"} = get!(w, "T1", "r")
    end

    test "every request from every state", %{w: w} do
      for {state, expected} <- @matrix,
          {{name, request}, want} <- Enum.zip(@requests, expected) do
        id = "m-#{state}-#{name}"
        rev = in_state(w, "T1", id, state)
        result = step(w, "T1", id, rev, request)
        after_item = get!(w, "T1", id)

        case want do
          :ok ->
            assert result == {:ok, %{revision: rev + 1}}, id
            assert after_item.state == @targets[name], id

          :unchanged ->
            assert result == {:ok, :unchanged}, id
            assert {after_item.state, after_item.revision} == {state, rev}, id

          reason ->
            assert result == {:error, reason}, id
            assert {after_item.state, after_item.revision} == {state, rev}, id
        end
      end
    end

    test "an offer after abandoned and after cancel_requested names that state", %{w: w} do
      for state <- [:abandoned, :cancel_requested] do
        rev = in_state(w, "T1", "o-#{state}", state)
        assert step(w, "T1", "o-#{state}", rev, :offer) == {:error, {:state, state}}
      end
    end

    test "the three parent-close mappings of workflow/delegation", %{w: w} do
      # The host's mapping (README): abandon to abandoned, request_cancel to cancel_requested,
      # cancel to cancelled; a cancel_requested item ends cancelled or abandoned with its child.
      host = %{abandon: :abandoned, request_cancel: :cancel_requested, cancel: :cancelled}

      for rule <- [:abandon, :request_cancel, :cancel] do
        {id, parent} = {"pc-#{rule}", "parent-#{rule}"}
        rev = in_state(w, "T1", id, :running, parent_close: rule, parent_run_id: parent)
        assert [%{item_id: ^id, parent_close: ^rule}] = open!(w, "T1", parent, nil, 256).items
        assert step(w, "T1", id, rev, {:close, host[rule]}) == {:ok, %{revision: rev + 1}}
        assert %{state: state, parent_close: ^rule} = get!(w, "T1", id)
        assert state == host[rule]
      end

      assert open!(w, "T1", "parent-abandon", nil, 256).items == []
      assert open!(w, "T1", "parent-cancel", nil, 256).items == []

      # A cancel_requested item stays open until its child ends: then cancelled or abandoned.
      rc = "parent-request_cancel"
      assert ids(open!(w, "T1", rc, nil, 256)) == ["pc-request_cancel"]
      assert step(w, "T1", "pc-request_cancel", 3, {:close, :cancelled}) == {:ok, %{revision: 4}}
      rev = in_state(w, "T1", "rc-2", :cancel_requested, parent_run_id: rc)
      assert step(w, "T1", "rc-2", rev, {:close, :abandoned}) == {:ok, %{revision: rev + 1}}
      assert get!(w, "T1", "rc-2").state == :abandoned
      assert open!(w, "T1", rc, nil, 256).items == []
    end

    test "a decision by another principal is not_owner; other evidence is conflict", %{w: w} do
      rev = in_state(w, "T1", "d", :offered)
      other = %{revision: rev, decided_by: "owner-2", decision: :accepted}
      assert WI.decide(w, "T1", "d", other) == {:error, :not_owner}
      assert WI.decide(w, "T1", "d", %{other | decision: :rejected}) == {:error, :not_owner}
      assert step(w, "T1", "d", rev, {:offer, "outcome-2"}) == {:error, :conflict}
      assert %{state: :offered, revision: ^rev, evidence: "outcome-1"} = get!(w, "T1", "d")

      # Also after the decision: another principal is still not_owner, not a no-op.
      assert step(w, "T1", "d", rev, :accepted) == {:ok, %{revision: rev + 1}}
      assert WI.decide(w, "T1", "d", %{other | revision: rev + 1}) == {:error, :not_owner}
    end

    test "a stale revision is refused after the other checks pass", %{w: w} do
      rev = in_state(w, "T1", "s", :running)
      assert step(w, "T1", "s", rev - 1, :offer) == {:error, :stale_revision}
      assert step(w, "T1", "s", rev + 1, {:close, :abandoned}) == {:error, :stale_revision}
      assert step(w, "T1", "s", rev, :offer) == {:ok, %{revision: rev + 1}}
      assert step(w, "T1", "s", rev, :accepted) == {:error, :stale_revision}
      assert get!(w, "T1", "s").state == :offered
      assert WI.start(w, "T1", "absent", %{revision: 1}) == {:error, :unknown_item}
      assert WI.get(w, "T1", "absent") == {:error, :unknown_item}
    end
  end

  # ── 3 ───────────────────────────────────────────────────────────────────

  describe "3 two concurrent decisions behind the item's row lock" do
    test "two accepts: one commits, the other is stale_revision", %{w: w, p: p} do
      rev = in_state(w, "T1", "x", :offered)
      call = fn -> step(w, "T1", "x", rev, :accepted) end

      results = behind_row_lock(p, "T1", "x", [call, call])
      assert Enum.sort(results) == [{:error, :stale_revision}, {:ok, %{revision: rev + 1}}]
      assert %{state: :accepted, revision: 4} = get!(w, "T1", "x")
      assert call.() == {:ok, :unchanged}
    end

    test "an accept against a reject: one commits, the other is stale_revision", %{w: w, p: p} do
      rev = in_state(w, "T1", "y", :offered)
      accept = fn -> step(w, "T1", "y", rev, :accepted) end
      reject = fn -> step(w, "T1", "y", rev, :rejected) end

      results = behind_row_lock(p, "T1", "y", [accept, reject])
      assert Enum.sort(results) == [{:error, :stale_revision}, {:ok, %{revision: rev + 1}}]

      {winner, loser} =
        if hd(results) == {:ok, %{revision: rev + 1}},
          do: {:accepted, reject},
          else: {:rejected, accept}

      assert %{state: ^winner, revision: 4} = get!(w, "T1", "y")
      assert loser.() == {:error, {:state, winner}}
    end
  end

  # ── 4 ───────────────────────────────────────────────────────────────────

  # The README canonical encoding, rebuilt here from its documented form.
  defp canonical(i) do
    frame = fn parts -> for(x <- parts, into: "", do: <<byte_size(x)::32>> <> x) end
    m = UC.encode(i.intent)

    intent =
      for {k, v} <- [
            {"content", m["content"]},
            {"max_bytes", Integer.to_string(m["max_bytes"])},
            {"schema_id", m["schema_id"]},
            {"schema_version", Integer.to_string(m["schema_version"])},
            {"sources", frame.(m["sources"])},
            {"trust", m["trust"]}
          ],
          into: "",
          do: frame.([k, v])

    body =
      for {k, v} <- [
            {"acceptance", Atom.to_string(i.acceptance)},
            {"child_run_id", i.child_run_id},
            {"intent", intent},
            {"item_id", i.item_id},
            {"owner", i.owner},
            {"parent_close", Atom.to_string(i.parent_close)},
            {"parent_run_id", i.parent_run_id}
          ],
          into: "",
          do: frame.([k, v])

    :crypto.hash(:sha256, "elzoo.work-item.item" <> <<0>> <> body)
  end

  test "4 create duplicate and conflict, and one item per child_run_id", %{w: w, p: p} do
    base = item("i1")
    create!(w, "T1", base)
    assert WI.create(w, "T1", base) == {:ok, :duplicate}
    assert step(w, "T1", "i1", 1, :start) == {:ok, %{revision: 2}}
    assert WI.create(w, "T1", base) == {:ok, :duplicate}

    changes = [
      parent_run_id: "parent-2",
      child_run_id: "child-other",
      owner: "owner-2",
      parent_close: :cancel,
      intent: marked("summarise another item"),
      intent: marked("summarise the item", "derived"),
      intent: marked("summarise the item", "untrusted", 4095),
      intent: marked("summarise the item", "untrusted", 4096, ["run:7", "chat:1"])
    ]

    for {key, value} <- changes,
        do: assert(WI.create(w, "T1", %{base | key => value}) == {:error, :conflict}, "#{key}")

    # A second item for the same child Run is a conflict; a new child Run is a new item.
    assert WI.create(w, "T1", item("i2", child_run_id: "child-i1")) == {:error, :conflict}
    create!(w, "T1", item("i2"))
    # Another tenant is separate.
    create!(w, "T2", base)

    assert truth(p, ~s(SELECT tenant, item_id, child_run_id, state FROM "#{p}".#{@table}
                       ORDER BY tenant, item_id)) == [
             ["T1", "i1", "child-i1", "running"],
             ["T1", "i2", "child-i2", "open"],
             ["T2", "i1", "child-i1", "open"]
           ]

    assert truth(p, ~s(SELECT digest FROM "#{p}".#{@table} WHERE tenant = 'T1' AND item_id = 'i1')) ==
             [[canonical(base)]]
  end

  # ── 5 ───────────────────────────────────────────────────────────────────

  describe "5 list_open" do
    @tag :capture_log
    test "after a crash a new Repo finds one parent's open items and their rules",
         %{p: p, role: role} do
      parent = self()

      writer =
        spawn(fn ->
          Harness.start_linked!(WriterRepo,
            pool_size: 2,
            after_connect: {Harness, :connect, [role, []]}
          )

          wr = WI.new(repo: WriterRepo, prefix: p)

          open = [
            {"a", :open, :abandon},
            {"b", :running, :request_cancel},
            {"c", :offered, :cancel},
            {"d", :cancel_requested, :request_cancel},
            {"xa", :open, :cancel},
            {"xB", :running, :abandon}
          ]

          for {id, state, rule} <- open, do: in_state(wr, "T1", id, state, parent_close: rule)

          for state <- [:accepted, :rejected, :cancelled, :abandoned],
              do: in_state(wr, "T1", "f-#{state}", state)

          in_state(wr, "T1", "other", :open, parent_run_id: "parent-2")
          send(parent, {:written, Process.whereis(WriterRepo)})

          receive do
            :never -> :ok
          end
        end)

      ref = Process.monitor(writer)
      assert_receive {:written, repo_pid}, 30_000
      repo_ref = Process.monitor(repo_pid)
      Process.exit(writer, :kill)
      assert_receive {:DOWN, ^ref, :process, ^writer, :killed}
      assert_receive {:DOWN, ^repo_ref, :process, ^repo_pid, _}

      Harness.start!(LaterRepo, pool_size: 1, after_connect: {Harness, :connect, [role, []]})
      later = WI.new(repo: LaterRepo, prefix: p)

      # Byte order: "xB" (0x42) before "xa" (0x61).
      assert %{items: items, more: false} = open!(later, "T1", "parent-1", nil, 256)

      assert Enum.map(items, &{&1.item_id, &1.state, &1.parent_close}) == [
               {"a", :open, :abandon},
               {"b", :running, :request_cancel},
               {"c", :offered, :cancel},
               {"d", :cancel_requested, :request_cancel},
               {"xB", :running, :abandon},
               {"xa", :open, :cancel}
             ]

      assert hd(items) == get!(later, "T1", "a")
      assert hd(items).intent == UC.encode(marked("summarise the item"))
      assert ids(open!(later, "T1", "parent-2", nil, 256)) == ["other"]
      assert open!(later, "T2", "parent-1", nil, 256) == %{items: [], more: false}

      # Paging at limit 1 walks the same items one at a time.
      pages =
        Stream.unfold(nil, fn
          :done ->
            nil

          after_id ->
            page = open!(later, "T1", "parent-1", after_id, 1)
            [id] = ids(page)
            {{id, page.more}, if(page.more, do: id, else: :done)}
        end)
        |> Enum.to_list()

      assert pages == [
               {"a", true},
               {"b", true},
               {"c", true},
               {"d", true},
               {"xB", true},
               {"xa", false}
             ]

      assert open!(later, "T1", "parent-1", "xa", 1) == %{items: [], more: false}
    end

    test "limit 256 returns 256 items and more when one more is open", %{w: w} do
      ids = for n <- 0..256, do: "p-" <> String.pad_leading(Integer.to_string(n), 3, "0")
      for id <- Enum.take(ids, 256), do: create!(w, "T1", item(id, parent_run_id: "p"))

      assert %{items: items, more: false} = open!(w, "T1", "p", nil, 256)
      assert Enum.map(items, & &1.item_id) == Enum.take(ids, 256)

      create!(w, "T1", item(List.last(ids), parent_run_id: "p"))
      assert %{items: items, more: true} = open!(w, "T1", "p", nil, 256)
      assert Enum.map(items, & &1.item_id) == Enum.take(ids, 256)
      assert open!(w, "T1", "p", "p-255", 256) == %{items: [get!(w, "T1", "p-256")], more: false}

      # A final item is not listed.
      assert step(w, "T1", "p-000", 1, {:close, :abandoned}) == {:ok, %{revision: 2}}
      assert %{items: items, more: false} = open!(w, "T1", "p", nil, 256)
      assert hd(items).item_id == "p-001" and length(items) == 256
    end
  end

  # ── 6 ───────────────────────────────────────────────────────────────────

  test "6 the intent survives a round trip; content of 1..4,096 bytes", %{w: w} do
    for {id, intent} <- [
          {"u", marked("untrusted\0text é", "untrusted", 100, ["chat:9"])},
          {"d", marked("derived text", "derived", 4096)},
          {"min", marked("x", "untrusted", 1)},
          {"max", marked(String.duplicate("y", 4096))}
        ] do
      create!(w, "T1", item(id, intent: intent))
      assert get!(w, "T1", id).intent == UC.encode(intent)
    end

    assert Enum.map(open!(w, "T1", "parent-1", nil, 256).items, & &1.intent) ==
             Enum.map(["d", "max", "min", "u"], &get!(w, "T1", &1).intent)

    for bad <- [
          marked(""),
          marked(String.duplicate("z", 4097), "untrusted", 4097),
          UC.encode(marked("neutral map, not marked")),
          {:UntrustedContent, %{"content" => "forged"}},
          "plain text",
          nil
        ],
        do: assert(WI.create(w, "T1", item("bad", intent: bad)) == {:error, :invalid})

    assert WI.get(w, "T1", "bad") == {:error, :unknown_item}
  end

  # ── 7 ───────────────────────────────────────────────────────────────────

  test "7 row security as the application role", %{w: w, p: p, role: role} do
    assert [[^role]] = Harness.query!(AppRepo, "SELECT current_user").rows
    assert WI.verify(w) == :ok

    # Every function succeeds with only the README grants.
    create!(w, "T2", item("t2"))
    assert step(w, "T2", "t2", 1, :start) == {:ok, %{revision: 2}}
    assert step(w, "T2", "t2", 2, :offer) == {:ok, %{revision: 3}}
    assert step(w, "T2", "t2", 3, :accepted) == {:ok, %{revision: 4}}
    create!(w, "T2", item("t2-open"))
    assert step(w, "T2", "t2-open", 1, {:close, :cancel_requested}) == {:ok, %{revision: 2}}
    assert ids(open!(w, "T2", "parent-1", nil, 256)) == ["t2-open"]
    create!(w, "T1", item("t1"))

    # Under T1, a T2 item is unknown and not listed.
    assert WI.get(w, "T1", "t2-open") == {:error, :unknown_item}
    assert step(w, "T1", "t2-open", 2, {:close, :cancelled}) == {:error, :unknown_item}
    assert ids(open!(w, "T1", "parent-1", nil, 256)) == ["t1"]

    insert = fn ->
      TI.transact(AppRepo, %{tenant: "T1"}, fn ->
        SQL.query(
          AppRepo,
          """
          INSERT INTO "#{p}".#{@table} (tenant, item_id, parent_run_id, child_run_id, owner,
            schema_id, schema_version, sources, trust, max_bytes, content, acceptance,
            parent_close, state, revision, digest)
          VALUES ('T2', 'forged', 'parent-1', 'c-forged', 'o', 's', 1, '{a}', 'untrusted', 1,
            'a', 'parent', 'cancel', 'open', 1, 'd')
          """,
          [],
          log: false
        )
      end)
    end

    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} = insert.()

    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             TI.transact(AppRepo, %{tenant: "T2"}, fn ->
               SQL.query(AppRepo, ~s(DELETE FROM "#{p}".#{@table}), [], log: false)
             end)

    # Outside a scope, nothing is visible.
    assert Harness.query!(AppRepo, ~s(SELECT count\(*\) FROM "#{p}".#{@table})).rows == [[0]]

    assert truth(p, ~s(SELECT tenant, item_id FROM "#{p}".#{@table} ORDER BY tenant, item_id)) ==
             [["T1", "t1"], ["T2", "t2"], ["T2", "t2-open"]]
  end

  # ── 8 ───────────────────────────────────────────────────────────────────

  test "8 a caller transaction and a repeatable read Repo are refused", %{w: w, p: p} do
    create!(w, "T1", item("i1"))
    handler = "elzoo-work-item-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:elzoo, :work_item, :app_repo, :query],
      &__MODULE__.handle_query/4,
      self()
    )

    calls = fn w ->
      [
        WI.create(w, "T1", item("i2")),
        WI.get(w, "T1", "i1"),
        step(w, "T1", "i1", 1, :start),
        step(w, "T1", "i1", 1, :offer),
        step(w, "T1", "i1", 1, :accepted),
        step(w, "T1", "i1", 1, {:close, :abandoned}),
        WI.list_open(w, "T1", %{parent_run_id: "parent-1", after: nil, limit: 1})
      ]
    end

    try do
      {:ok, results} =
        AppRepo.transact(fn ->
          flush_queries()
          results = calls.(w)
          refute_received {:query, _}
          {:ok, results}
        end)

      assert results == List.duplicate({:error, :in_transaction}, 7)

      # verify/1 runs inside a caller's transaction too.
      assert {:ok, :ok} = AppRepo.transact(fn -> {:ok, WI.verify(w)} end)

      # Invalid calls make no query either.
      flush_queries()
      assert WI.create(w, "T1", item("")) == {:error, :invalid}
      assert WI.start(w, "T1", "i1", %{revision: 0}) == {:error, :invalid}

      assert WI.list_open(w, "T1", %{parent_run_id: "p", after: nil, limit: 0}) ==
               {:error, :invalid}

      refute_received {:query, _}
    after
      :telemetry.detach(handler)
    end

    rr = WI.new(repo: RepeatableRepo, prefix: p)
    [create, get, start, offer, decide, close, list] = calls.(rr)
    assert [create, start, offer, decide, close] == List.duplicate({:error, :isolation}, 5)
    assert get == {:ok, get!(w, "T1", "i1")}
    assert {:ok, %{items: [%{item_id: "i1"}]}} = list

    assert truth(p, ~s(SELECT item_id, state, revision FROM "#{p}".#{@table})) == [
             ["i1", "open", 1]
           ]

    # A missing schema is unavailable.
    missing = WI.new(repo: AppRepo, prefix: "elz347_missing")
    assert Enum.uniq(calls.(missing)) == [{:error, :unavailable}]
  end

  def handle_query(_event, _measurements, meta, parent), do: send(parent, {:query, meta.query})

  defp flush_queries do
    receive do
      {:query, _} -> flush_queries()
    after
      0 -> :ok
    end
  end

  # ── 9 ───────────────────────────────────────────────────────────────────

  @text_bad ["", String.duplicate("a", 129), <<0xFF>>, "a" <> <<0>>, "a\x1F", "a\u0085", "\u007F"]
  @text_good ["a", String.duplicate("t", 128), "é" <> String.duplicate("t", 126)]
  @run_bad ["", String.duplicate("r", 201), <<0xFF>>, "a" <> <<0>>]
  @run_good ["r", String.duplicate("r", 200), "a\x1F", "a\u0085", "é"]

  defp uid, do: "u-#{System.unique_integer([:positive])}"

  # Each bad value is invalid; each good value passes the shape check.
  defp edges(name, bad, good, call) do
    for v <- bad, do: assert(call.(v) == {:error, :invalid}, "#{name} #{inspect(v)}")
    for v <- good, do: refute(call.(v) == {:error, :invalid}, "#{name} #{inspect(v)}")
  end

  test "9 bounds at their edges", %{w: w, p: p} do
    edges("tenant", @text_bad, @text_good, &WI.create(w, &1, item("t")))
    edges("tenant", @text_bad, @text_good, &WI.get(w, &1, "t"))
    edges("tenant", @text_bad, @text_good, &step(w, &1, "t", 1, :start))

    edges("tenant", @text_bad, @text_good, fn t ->
      WI.list_open(w, t, %{parent_run_id: "p", after: nil, limit: 1})
    end)

    edges("item_id", @text_bad, @text_good, &WI.create(w, "T1", item(&1)))
    edges("item_id", @text_bad, @text_good, &WI.get(w, "T1", &1))
    edges("item_id", @text_bad, @text_good, &step(w, "T1", &1, 1, {:close, :abandoned}))

    edges("after", @text_bad, [nil | @text_good], fn a ->
      WI.list_open(w, "T1", %{parent_run_id: "p", after: a, limit: 1})
    end)

    edges("owner", @text_bad, @text_good, &WI.create(w, "T1", item(uid(), owner: &1)))

    edges("decided_by", @text_bad, @text_good, fn d ->
      WI.decide(w, "T1", "absent", %{revision: 1, decided_by: d, decision: :accepted})
    end)

    edges("parent_run_id", @run_bad, @run_good, &WI.create(w, "T1", item(uid(), parent_run_id: &1)))

    edges("parent_run_id", @run_bad, @run_good, fn r ->
      WI.list_open(w, "T1", %{parent_run_id: r, after: nil, limit: 1})
    end)

    edges("child_run_id", @run_bad, @run_good, &WI.create(w, "T1", item(uid(), child_run_id: &1)))

    edges("child_run_id", @run_bad, @run_good, fn c ->
      WI.offer(w, "T1", "absent", %{revision: 1, child_run_id: c, evidence: "e"})
    end)

    # The good values above were stored whole.
    assert get!(w, "T1", String.duplicate("t", 128)).item_id == String.duplicate("t", 128)

    assert truth(p, ~s(SELECT count\(*\) FROM "#{p}".#{@table} WHERE child_run_id = $1), [
             String.duplicate("r", 200)
           ]) == [[1]]

    # evidence: an opaque reference of 1..256 bytes.
    rev = in_state(w, "T1", "e", :running)

    offer = fn e ->
      WI.offer(w, "T1", "e", %{revision: rev, child_run_id: "child-e", evidence: e})
    end

    for e <- ["", String.duplicate("e", 257), nil, 1, :ref],
        do: assert(offer.(e) == {:error, :invalid}, inspect(e))

    evidence = <<0xFF, 0>> <> String.duplicate("e", 254)
    assert offer.(evidence) == {:ok, %{revision: rev + 1}}
    assert get!(w, "T1", "e").evidence == evidence

    # revision: 1..2^31-1.
    for r <- [0, -1, @max_revision + 1, 1.0, nil, "1"],
        do: assert(WI.start(w, "T1", "e", %{revision: r}) == {:error, :invalid}, inspect(r))

    for r <- [1, @max_revision],
        do:
          assert(
            WI.close(w, "T1", "e", %{revision: r, to: :abandoned}) == {:error, :stale_revision}
          )

    # Closed sets.
    assert WI.create(w, "T1", item(uid(), acceptance: :person)) == {:error, :invalid}

    for pc <- [:kill, nil, "cancel"],
        do: assert(WI.create(w, "T1", item(uid(), parent_close: pc)) == {:error, :invalid})

    for d <- [:maybe, :offered, nil, "accepted"],
        do:
          assert(
            WI.decide(w, "T1", "e", %{revision: 3, decided_by: "owner-1", decision: d}) ==
              {:error, :invalid}
          )

    for to <- [:open, :running, :offered, :accepted, :rejected, nil, "cancelled"],
        do: assert(WI.close(w, "T1", "e", %{revision: 3, to: to}) == {:error, :invalid})

    # list_open limit 1..256.
    for l <- [0, 257, -1, nil, 1.0],
        do:
          assert(
            WI.list_open(w, "T1", %{parent_run_id: "p", after: nil, limit: l}) == {:error, :invalid}
          )

    for l <- [1, 256],
        do: assert({:ok, _} = WI.list_open(w, "T1", %{parent_run_id: "p", after: nil, limit: l}))

    # Exact keys.
    assert WI.create(w, "T1", Map.put(item(uid()), :extra, 1)) == {:error, :invalid}
    assert WI.create(w, "T1", Map.delete(item(uid()), :owner)) == {:error, :invalid}
    assert WI.start(w, "T1", "e", %{revision: 3, extra: 1}) == {:error, :invalid}
    assert WI.start(w, "T1", "e", %{}) == {:error, :invalid}
    assert WI.close(w, "T1", "e", revision: 3, to: :abandoned) == {:error, :invalid}

    assert WI.offer(w, "T1", "e", %{revision: 3, child_run_id: "child-e"}) == {:error, :invalid}

    assert WI.list_open(w, "T1", %{parent_run_id: "p", limit: 1}) == {:error, :invalid}
    assert WI.create(w, "T1", nil) == {:error, :invalid}

    # The items value and the prefix.
    assert WI.get(%{repo: AppRepo, prefix: p}, "T1", "e") == {:error, :invalid}

    for opts <- [
          [repo: AppRepo],
          [prefix: p],
          [repo: AppRepo, prefix: p, extra: 1],
          [repo: AppRepo, prefix: "Bad"],
          [repo: AppRepo, prefix: String.duplicate("a", 64)],
          [repo: nil, prefix: p],
          %{repo: AppRepo, prefix: p}
        ],
        do: assert_raise(ArgumentError, @message, fn -> WI.new(opts) end)

    assert %WI{} = WI.new(repo: AppRepo, prefix: String.duplicate("a", 63))

    for prefix <- ["Bad", "a-b", "", nil, String.duplicate("a", 64)],
        do: assert_raise(ArgumentError, @message, fn -> Migration.install(prefix) end)
  end
end
