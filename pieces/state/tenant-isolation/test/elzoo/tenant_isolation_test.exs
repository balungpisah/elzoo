# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/tenant_isolation_test_helper.exs", __DIR__)

defmodule Elzoo.TenantIsolationTest do
  use ExUnit.Case, async: false
  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Elzoo.TenantIsolation, as: TI
  alias Elzoo.TenantIsolation.Migration

  alias Elzoo.TenantIsolation.{
    AdminRepo,
    AppRepo,
    DownRepo,
    Harness,
    LogRepo,
    SandboxRepo,
    TestRepo
  }

  @message "invalid tenant isolation identifier or options"
  @denied :insufficient_privilege

  setup_all do
    Harness.start!(AdminRepo, pool_size: 2)

    if Harness.bypass?(AdminRepo),
      do: raise("the test role bypasses row security; the cases need a non-bypass owner")

    [[version]] = Harness.query!(AdminRepo, "SELECT current_setting('server_version_num')").rows
    assert String.to_integer(version) in 190_000..199_999
    # pool_size 1: every call and every check below runs on the same pooled connection.
    Harness.start!(TestRepo, pool_size: 1)
    Harness.start!(SandboxRepo, pool_size: 1, pool: Sandbox)
    Sandbox.mode(SandboxRepo, :manual)
    :ok
  end

  setup do
    prefix = Harness.install!(AdminRepo)
    on_exit(fn -> Harness.drop!(AdminRepo, prefix) end)
    {:ok, p: prefix}
  end

  defp q(sql, params \\ []), do: qr(TestRepo, sql, params)
  defp q!(sql, params \\ []), do: qr!(TestRepo, sql, params)
  defp qr(repo, sql, params \\ []), do: SQL.query(repo, sql, params, log: false)
  defp qr!(repo, sql, params \\ []), do: SQL.query!(repo, sql, params, log: false).rows

  defp t1, do: %{tenant: "T1"}

  defp denied?(result),
    do: match?({:error, %Postgrex.Error{postgres: %{code: @denied}}}, result)

  # Ground truth as the owner with FORCE dropped inside a rolled-back transaction.
  defp truth(p, table) do
    {:error, {:rows, rows}} =
      AdminRepo.transact(fn ->
        Harness.query!(AdminRepo, "ALTER TABLE #{p}.#{table} NO FORCE ROW LEVEL SECURITY")

        cols = if table == "flat", do: "tenant, body", else: "tenant, space, body"

        {:error,
         {:rows, Harness.query!(AdminRepo, "SELECT #{cols} FROM #{p}.#{table} ORDER BY body").rows}}
      end)

    rows
  end

  defp seed_flat(p, repo \\ TestRepo) do
    for {t, b} <- [{"T1", "a"}, {"T1", "b"}, {"T2", "c"}, {"T2", "d"}] do
      {:ok, _} =
        TI.transact(repo, %{tenant: t}, fn ->
          qr(repo, "INSERT INTO #{p}.flat (tenant, body) VALUES ($1, $2)", [t, b])
        end)
    end
  end

  defp bodies(repo \\ TestRepo, p, table, scope) do
    {:ok, rows} =
      TI.transact(repo, scope, fn ->
        {:ok, repo.all(from(r in table, select: r.body, order_by: r.body), prefix: p)}
      end)

    rows
  end

  # Readers and visible rows on the connection, outside the helper.
  defp outside(repo \\ TestRepo, p),
    do:
      hd(
        qr!(
          repo,
          "SELECT #{p}.elzoo_tenant_id(), #{p}.elzoo_space_ids(), (SELECT count(*) FROM #{p}.flat), (SELECT count(*) FROM #{p}.notes), pg_backend_pid()"
        )
      )

  describe "1 flat table" do
    test "T1 reads, updates and deletes only T1 rows; a forgotten filter returns only T1 rows",
         %{p: p} do
      seed_flat(p)
      assert bodies(p, "flat", t1()) == ["a", "b"]

      assert {:ok, {2, 0, 0, ["u", "u"], 2}} =
               TI.transact(TestRepo, t1(), fn ->
                 {updated, _} =
                   TestRepo.update_all(from(r in "flat", update: [set: [body: "u"]]), [], prefix: p)

                 {:ok, %{num_rows: other_updated}} =
                   q("UPDATE #{p}.flat SET body = 'v' WHERE body IN ('c', 'd')")

                 {:ok, %{num_rows: other_deleted}} =
                   q("DELETE FROM #{p}.flat WHERE body IN ('c', 'd')")

                 seen = TestRepo.all(from(r in "flat", select: r.body), prefix: p)
                 {deleted, _} = TestRepo.delete_all("flat", prefix: p)
                 {:ok, {updated, other_updated, other_deleted, seen, deleted}}
               end)

      assert truth(p, "flat") == [["T2", "c"], ["T2", "d"]]
    end

    test "an INSERT or an UPDATE that writes T2 under T1 fails 42501 and leaves no row", %{p: p} do
      seed_flat(p)
      before = truth(p, "flat")

      assert denied?(
               TI.transact(TestRepo, t1(), fn ->
                 q("INSERT INTO #{p}.flat (tenant, body) VALUES ('T2', 'z')")
               end)
             )

      assert_raise Postgrex.Error, ~r/row-level security/, fn ->
        TI.transact(TestRepo, t1(), fn ->
          {:ok, TestRepo.insert_all("flat", [%{tenant: "T2", body: "z"}], prefix: p)}
        end)
      end

      assert denied?(
               TI.transact(TestRepo, t1(), fn ->
                 q("UPDATE #{p}.flat SET tenant = 'T2' WHERE body = 'a'")
               end)
             )

      assert truth(p, "flat") == before
      assert bodies(p, "flat", %{tenant: "T2"}) == ["c", "d"]
    end
  end

  describe "2 spaced table" do
    @weird ["NULL", "{a}", ~s("q"), "b\\s", ","]

    setup %{p: p} do
      rows =
        [{"T1", "s1", "a"}, {"T1", "s2", "b"}, {"T2", "s1", "c"}] ++
          Enum.map(Enum.with_index(@weird), fn {s, i} -> {"T1", s, "w#{i}"} end) ++
          [{"T1", "a", "p0"}, {"T1", "q", "p1"}, {"T1", "b", "p2"}, {"T1", "{a,b}", "p3"}]

      for {t, s, b} <- rows do
        {:ok, _} =
          TI.transact(TestRepo, %{tenant: t, spaces: [s]}, fn ->
            q("INSERT INTO #{p}.notes (tenant, space, body) VALUES ($1, $2, $3)", [t, s, b])
          end)
      end

      # A NULL space row, written by the owner with FORCE dropped.
      {:ok, _} =
        AdminRepo.transact(fn ->
          Harness.query!(AdminRepo, "ALTER TABLE #{p}.notes NO FORCE ROW LEVEL SECURITY")

          Harness.query!(
            AdminRepo,
            "INSERT INTO #{p}.notes (tenant, space, body) VALUES ('T1', NULL, 'n')"
          )

          {:ok, Harness.query!(AdminRepo, "ALTER TABLE #{p}.notes FORCE ROW LEVEL SECURITY")}
        end)

      :ok
    end

    test "only listed spaces of the scope's tenant; [] and a flat scope show nothing", %{p: p} do
      assert bodies(p, "notes", %{tenant: "T1", spaces: ["s1"]}) == ["a"]
      assert bodies(p, "notes", %{tenant: "T2", spaces: ["s1"]}) == ["c"]
      assert bodies(p, "notes", %{tenant: "T1", spaces: []}) == []
      assert bodies(p, "notes", %{tenant: "T1"}) == []
      assert bodies(p, "notes", %{tenant: "T1", spaces: ["s1", "s1"]}) == ["a"]
    end

    test "space IDs NULL, {a}, \"q\", b\\s and , match exactly", %{p: p} do
      for {s, i} <- Enum.with_index(@weird) do
        assert {:ok, {[[[^s]]], ["w" <> _ = body]}} =
                 TI.transact(TestRepo, %{tenant: "T1", spaces: [s]}, fn ->
                   {:ok,
                    {q!("SELECT #{p}.elzoo_space_ids()"),
                     TestRepo.all(from(r in "notes", select: r.body), prefix: p)}}
                 end)

        assert body == "w#{i}"
      end

      assert bodies(p, "notes", %{tenant: "T1", spaces: @weird}) == ~w(w0 w1 w2 w3 w4)
      assert bodies(p, "notes", %{tenant: "T1", spaces: ["a", "q", "b"]}) == ~w(p0 p1 p2)
      assert bodies(p, "notes", %{tenant: "T1", spaces: ["{a,b}"]}) == ["p3"]
    end

    test "a space removed from the list for the next call is hidden on that call", %{p: p} do
      assert bodies(p, "notes", %{tenant: "T1", spaces: ["s1", "s2"]}) == ["a", "b"]
      assert bodies(p, "notes", %{tenant: "T1", spaces: ["s1"]}) == ["a"]
    end

    test "writes outside the listed spaces and NULL space writes fail 42501", %{p: p} do
      before = truth(p, "notes")
      scope = %{tenant: "T1", spaces: ["s1"]}

      for sql <- [
            "INSERT INTO #{p}.notes (tenant, space, body) VALUES ('T1', 's2', 'z')",
            "INSERT INTO #{p}.notes (tenant, space, body) VALUES ('T1', NULL, 'z')",
            "INSERT INTO #{p}.notes (tenant, space, body) VALUES ('T2', 's1', 'z')",
            "UPDATE #{p}.notes SET space = 's2' WHERE body = 'a'",
            "UPDATE #{p}.notes SET space = NULL WHERE body = 'a'"
          ] do
        assert denied?(TI.transact(TestRepo, scope, fn -> q(sql) end)), sql
      end

      assert truth(p, "notes") == before
      assert ["T1", nil, "n"] in before
    end
  end

  # Outside the helper, then after each outcome of a call, on the repo's one connection: the
  # readers show no tenant and no space and the tables no row.
  defp fail_closed_sequence(repo, p) do
    scope = %{tenant: "T1", spaces: ["s1"]}
    assert [nil, [], 0, 0, pid] = outside(repo, p)

    assert {:ok, ["T1", ["s1"], 2, 0, ^pid]} =
             TI.transact(repo, scope, fn -> {:ok, outside(repo, p)} end)

    assert [nil, [], 0, 0, ^pid] = outside(repo, p)

    assert {:error, :boom} = TI.transact(repo, scope, fn -> {:error, :boom} end)
    assert [nil, [], 0, 0, ^pid] = outside(repo, p)

    assert {:error, :value} = TI.transact(repo, scope, fn -> repo.rollback(:value) end)
    assert [nil, [], 0, 0, ^pid] = outside(repo, p)

    assert_raise RuntimeError, "raised", fn ->
      TI.transact(repo, scope, fn -> raise "raised" end)
    end

    assert [nil, [], 0, 0, ^pid] = outside(repo, p)

    assert_raise ArgumentError, fn -> TI.transact(repo, scope, fn -> :neither end) end
    assert [nil, [], 0, 0, ^pid] = outside(repo, p)

    # fun caught a failed statement and still returns {:ok, _}: the clearing query raises.
    assert_raise Postgrex.Error, ~r/current transaction is aborted/, fn ->
      TI.transact(repo, scope, fn ->
        {:error, _} = qr(repo, "INSERT INTO #{p}.flat (tenant, body) VALUES ('T2', 'z')")
        {:ok, :caught}
      end)
    end

    assert [nil, [], 0, 0, ^pid] = outside(repo, p)
    assert bodies(repo, p, "flat", %{tenant: "T2"}) == ["c", "d"]

    # fun swallowed a failed nested transact and returns {:ok, _}: transact/2 gives
    # {:error, :rollback}, and so does the helper. DBConnection disconnects the aborted
    # connection on the refused clearing query (and logs it), so the pid may change here; under
    # Sandbox that disconnect also ends the sandbox transaction and its seeded rows.
    nested = fn ->
      {:error, :inner} = repo.transact(fn -> {:error, :inner} end)
      {:ok, :swallowed}
    end

    capture_log(fn ->
      assert repo.transact(nested) == {:error, :rollback}
      assert TI.transact(repo, scope, nested) == {:error, :rollback}
      assert [nil, [], 0, 0, _] = outside(repo, p)
    end)
  end

  describe "3 fail closed" do
    test "on one pooled connection (DBConnection.ConnectionPool) every outcome leaves no scope",
         %{p: p} do
      seed_flat(p)
      assert denied?(q("INSERT INTO #{p}.flat (tenant, body) VALUES ('T1', 'z')"))
      fail_closed_sequence(TestRepo, p)
      assert bodies(p, "flat", t1()) == ["a", "b"]
    end

    test "under Ecto.Adapters.SQL.Sandbox savepoints every outcome leaves no scope", %{p: p} do
      :ok = Sandbox.checkout(SandboxRepo)
      on_exit(fn -> Sandbox.checkin(SandboxRepo) end)
      seed_flat(p, SandboxRepo)
      fail_closed_sequence(SandboxRepo, p)
    end

    test "a call nested in an open transaction is :in_transaction and runs nothing", %{p: p} do
      for repo <- [TestRepo, SandboxRepo] do
        if repo == SandboxRepo, do: :ok = Sandbox.checkout(SandboxRepo)

        assert {:ok, {{:error, {:tenant_isolation, :in_transaction}}, [nil, [], 0, 0, _]}} =
                 repo.transact(fn ->
                   inner =
                     TI.transact(repo, t1(), fn ->
                       send(self(), :ran)
                       {:ok, :ran}
                     end)

                   {:ok, {inner, outside(repo, p)}}
                 end)

        refute_received :ran
        if repo == SandboxRepo, do: Sandbox.checkin(SandboxRepo)
      end
    end

    test "SET LOCAL row_security = off inside fun gives 42501", %{p: p} do
      seed_flat(p)

      assert denied?(
               TI.transact(TestRepo, t1(), fn ->
                 {:ok, _} = q("SET LOCAL row_security = off")
                 q("SELECT count(*) FROM #{p}.flat")
               end)
             )
    end
  end

  describe "4 policy composition" do
    test "added permissive policies do not widen the floor; no permissive policy shows nothing",
         %{p: p} do
      seed_flat(p)

      for table <- ["flat", "notes"] do
        Harness.query!(
          AdminRepo,
          "CREATE POLICY wide ON #{p}.#{table} AS PERMISSIVE FOR ALL TO PUBLIC USING (true) WITH CHECK (true)"
        )

        Harness.query!(
          AdminRepo,
          "CREATE POLICY other ON #{p}.#{table} AS PERMISSIVE FOR ALL TO PUBLIC USING (tenant = 'T2') WITH CHECK (tenant = 'T2')"
        )
      end

      {:ok, _} =
        TI.transact(TestRepo, %{tenant: "T2", spaces: ["s1"]}, fn ->
          q("INSERT INTO #{p}.notes (tenant, space, body) VALUES ('T2', 's1', 'c')")
        end)

      assert bodies(p, "flat", t1()) == ["a", "b"]
      assert bodies(p, "notes", %{tenant: "T1", spaces: ["s1"]}) == []
      assert [nil, [], 0, 0, _] = outside(p)

      assert denied?(
               TI.transact(TestRepo, t1(), fn ->
                 q("INSERT INTO #{p}.flat (tenant, body) VALUES ('T2', 'z')")
               end)
             )

      for policy <- ["wide", "other", "elzoo_tenant_allow"],
          do: Harness.query!(AdminRepo, "DROP POLICY #{policy} ON #{p}.flat")

      assert bodies(p, "flat", t1()) == []
      assert bodies(p, "flat", %{tenant: "T2"}) == []

      assert denied?(
               TI.transact(TestRepo, t1(), fn ->
                 q("INSERT INTO #{p}.flat (tenant, body) VALUES ('T1', 'z')")
               end)
             )
    end
  end

  describe "5 plan" do
    test "JSON EXPLAIN shows both readers as InitPlan nodes, not per-row calls", %{p: p} do
      {:ok, plan} =
        TI.transact(TestRepo, %{tenant: "T1", spaces: ["s1"]}, fn ->
          [[[plan]]] = q!("EXPLAIN (FORMAT JSON, VERBOSE) SELECT * FROM #{p}.notes")
          {:ok, plan["Plan"]}
        end)

      init = Enum.filter(nodes(plan), &(&1["Parent Relationship"] == "InitPlan"))
      outputs = Enum.flat_map(init, &(&1["Output"] || []))
      assert length(init) == 2
      # PostgreSQL inlines the SQL readers: each InitPlan computes one setting once.
      assert Enum.any?(outputs, &(&1 =~ "current_setting('elzoo.tenant_id'"))
      assert Enum.any?(outputs, &(&1 =~ "current_setting('elzoo.space_ids'"))
      refute plan["Filter"] =~ "current_setting"
      refute plan["Filter"] =~ "elzoo_"
      names = init |> Enum.map(& &1["Subplan Name"]) |> Enum.sort()
      # PostgreSQL 19 names each InitPlan by its output and the filter reads that output.
      assert names == ["InitPlan expr_1", "InitPlan expr_2"]

      assert plan["Filter"] ==
               "((notes.tenant = (InitPlan expr_1).col1) AND (notes.space = ANY ((InitPlan expr_2).col1)))"
    end
  end

  defp nodes(node), do: [node | Enum.flat_map(node["Plans"] || [], &nodes/1)]

  describe "6 verify" do
    defp flat(p), do: [prefix: p, tenant_column: "tenant", space_column: nil]
    defp spaced(p), do: [prefix: p, tenant_column: "tenant", space_column: "space"]
    defp admin!(sql), do: Harness.query!(AdminRepo, sql)

    test "ok after protect; each table change gives its reason", %{p: p} do
      assert TI.verify(TestRepo, {p, "flat"}, flat(p)) == :ok
      assert TI.verify(TestRepo, {p, "notes"}, spaced(p)) == :ok

      assert TI.verify(TestRepo, {p, "vnotes"},
               prefix: p,
               tenant_column: "org",
               space_column: "area"
             ) == :ok

      t = "#{p}.flat"
      admin!("ALTER TABLE #{t} NO FORCE ROW LEVEL SECURITY")
      assert TI.verify(TestRepo, {p, "flat"}, flat(p)) == {:error, :not_forced}
      admin!("ALTER TABLE #{t} DISABLE ROW LEVEL SECURITY")
      assert TI.verify(TestRepo, {p, "flat"}, flat(p)) == {:error, :not_enabled}
      admin!("ALTER TABLE #{t} FORCE ROW LEVEL SECURITY")
      assert TI.verify(TestRepo, {p, "flat"}, flat(p)) == {:error, :not_enabled}
      admin!("ALTER TABLE #{t} ENABLE ROW LEVEL SECURITY")
      assert TI.verify(TestRepo, {p, "flat"}, flat(p)) == :ok

      floor = "tenant = (SELECT #{p}.elzoo_tenant_id())"
      admin!("DROP POLICY elzoo_tenant_floor ON #{t}")
      assert TI.verify(TestRepo, {p, "flat"}, flat(p)) == {:error, :floor_missing}

      for {shape, reason} <- [
            {"AS PERMISSIVE FOR ALL TO PUBLIC USING (#{floor}) WITH CHECK (#{floor})",
             :floor_missing},
            {"AS RESTRICTIVE FOR SELECT TO PUBLIC USING (#{floor})", :floor_missing},
            {"AS RESTRICTIVE FOR ALL TO CURRENT_USER USING (#{floor}) WITH CHECK (#{floor})",
             :floor_missing},
            {"AS RESTRICTIVE FOR ALL TO PUBLIC USING (true) WITH CHECK (true)", :floor_changed},
            {"AS RESTRICTIVE FOR ALL TO PUBLIC USING (#{floor}) WITH CHECK (true)", :floor_changed},
            {"AS RESTRICTIVE FOR ALL TO PUBLIC USING (#{floor})", :floor_changed},
            {"AS RESTRICTIVE FOR ALL TO PUBLIC USING (#{floor}) WITH CHECK (#{floor})", :ok}
          ] do
        admin!("CREATE POLICY elzoo_tenant_floor ON #{t} #{shape}")
        expected = if reason == :ok, do: :ok, else: {:error, reason}
        assert TI.verify(TestRepo, {p, "flat"}, flat(p)) == expected, shape
        admin!("DROP POLICY elzoo_tenant_floor ON #{t}")
      end
    end

    test "swapped, renamed or missing columns and another prefix give :floor_changed", %{p: p} do
      changed = {:error, :floor_changed}
      notes = {p, "notes"}
      assert TI.verify(TestRepo, notes, spaced(p)) == :ok

      for opts <- [
            [prefix: p, tenant_column: "space", space_column: "tenant"],
            [prefix: p, tenant_column: "tenant_id", space_column: "space"],
            [prefix: p, tenant_column: "tenant", space_column: "space_id"],
            [prefix: p, tenant_column: "tenant", space_column: nil],
            [prefix: p, tenant_column: "tenant", space_column: "body"],
            [prefix: "public", tenant_column: "tenant", space_column: "space"],
            [prefix: "elz270_absent", tenant_column: "tenant", space_column: "space"]
          ] do
        assert TI.verify(TestRepo, notes, opts) == changed, inspect(opts)
      end

      assert TI.verify(TestRepo, {p, "flat"}, spaced(p) |> Keyword.put(:space_column, "body")) ==
               changed

      assert TI.verify(TestRepo, {p, "absent"}, flat(p)) == {:error, :not_enabled}
      # Nothing of the rebuild survives: no temporary table, the floor and the scope unchanged.
      assert q!("SELECT to_regclass('pg_temp.elzoo_tenant_verify')") == [[nil]]
      assert TI.verify(TestRepo, notes, spaced(p)) == :ok
    end

    test "verify runs inside an open transaction and leaves it usable", %{p: p} do
      assert {:ok, {:ok, [[1]]}} =
               TestRepo.transact(fn ->
                 {:ok, {TI.verify(TestRepo, {p, "notes"}, spaced(p)), q!("SELECT 1")}}
               end)
    end

    test "an unreachable Repo gives :unavailable" do
      capture_log(fn ->
        {:ok, pid} =
          DownRepo.start_link(
            hostname: "127.0.0.1",
            port: 1,
            database: "elz270_unreachable",
            username: "nobody",
            pool_size: 1,
            queue_target: 20,
            queue_interval: 100,
            connect_timeout: 200,
            log: false
          )

        Process.unlink(pid)
        assert TI.verify(DownRepo, {"s", "t"}, flat("s")) == {:error, :unavailable}
        Supervisor.stop(pid)
      end)
    end

    test "the pure decision: every reason and bypass ahead of every table reason" do
      floor = %{permissive: false, command: "*", public: true, using: "u", check: "c"}
      ok = %{superuser: false, bypassrls: false, table: %{enabled: true, forced: true}}
      ok = Map.merge(ok, %{floor: floor, expected: %{using: "u", check: "c"}})
      assert TI.decide(ok) == :ok

      tables = [
        ok,
        %{ok | table: nil},
        %{ok | table: %{enabled: false, forced: false}},
        %{ok | table: %{enabled: true, forced: false}},
        %{ok | floor: nil},
        %{ok | expected: nil}
      ]

      for facts <- tables, bypass <- [%{superuser: true}, %{bypassrls: true}] do
        assert TI.decide(Map.merge(facts, bypass)) == {:error, :bypass_role}
      end

      assert TI.decide(%{ok | table: nil}) == {:error, :not_enabled}
      assert TI.decide(%{ok | table: %{enabled: false, forced: true}}) == {:error, :not_enabled}
      assert TI.decide(%{ok | table: %{enabled: false, forced: false}}) == {:error, :not_enabled}

      assert TI.decide(%{ok | table: %{enabled: true, forced: false}, floor: nil}) ==
               {:error, :not_forced}

      assert TI.decide(%{ok | floor: nil, expected: nil}) == {:error, :floor_missing}

      for change <- [%{permissive: true}, %{command: "r"}, %{public: false}] do
        assert TI.decide(%{ok | floor: Map.merge(floor, change), expected: nil}) ==
                 {:error, :floor_missing}
      end

      for change <- [%{using: "x"}, %{check: "x"}, %{check: nil}] do
        assert TI.decide(%{ok | floor: Map.merge(floor, change)}) == {:error, :floor_changed}
      end

      assert TI.decide(%{ok | expected: nil}) == {:error, :floor_changed}
    end
  end

  describe "7 shape" do
    test "tenant and space text bounds", %{p: p} do
      scope_error = {:error, {:tenant_isolation, :scope}}
      max = String.duplicate("é", 64)

      for good <- ["a", String.duplicate("a", 128), max, "a\u00A0b"] do
        assert {:ok, [[^good, [^good]]]} =
                 TI.transact(TestRepo, %{tenant: good, spaces: [good]}, fn ->
                   {:ok, q!("SELECT #{p}.elzoo_tenant_id(), #{p}.elzoo_space_ids()")}
                 end)
      end

      bad = [
        "",
        String.duplicate("a", 129),
        max <> "a",
        <<0xFF>>,
        <<0xC3>>,
        "a\0b",
        "a\x1Fb",
        "a\x7Fb",
        "a\u0080b",
        "a\u0085b",
        "a\u009Fb",
        :T1,
        nil,
        ~c"T1"
      ]

      for value <- bad do
        assert TI.transact(TestRepo, %{tenant: value}, fn -> flunk("ran") end) == scope_error

        assert TI.transact(TestRepo, %{tenant: "T1", spaces: [value]}, fn -> flunk("ran") end) ==
                 scope_error
      end
    end

    test "space list bounds and scope and function shapes" do
      scope_error = {:error, {:tenant_isolation, :scope}}
      ids = for i <- 1..1025, do: "s#{i}"

      assert {:ok, 1024} =
               TI.transact(TestRepo, %{tenant: "T1", spaces: Enum.take(ids, 1024)}, fn ->
                 {:ok,
                  length(
                    hd(hd(q!("SELECT string_to_array(current_setting('elzoo.space_ids'), ',')")))
                  )}
               end)

      assert {:ok, :dup} =
               TI.transact(TestRepo, %{tenant: "T1", spaces: ["s", "s"]}, fn -> {:ok, :dup} end)

      for scope <- [
            %{tenant: "T1", spaces: ids},
            %{tenant: "T1", spaces: ["a" | "b"]},
            %{tenant: "T1", spaces: "s1"},
            %{tenant: "T1", spaces: nil},
            %{tenant: "T1", spaces: [], extra: 1},
            %{tenant: "T1", extra: 1},
            %{"tenant" => "T1"},
            %{"tenant" => "T1", spaces: []},
            %{spaces: ["s1"]},
            %{},
            [tenant: "T1"],
            nil
          ] do
        assert TI.transact(TestRepo, scope, fn -> flunk("ran") end) == scope_error
      end

      assert TI.transact(TestRepo, t1(), fn _ -> {:ok, 1} end) == scope_error
      assert TI.transact(TestRepo, t1(), :fun) == scope_error

      # Scope and arity are checked before the transaction state.
      assert {:ok, [^scope_error, ^scope_error, {:error, {:tenant_isolation, :in_transaction}}]} =
               TestRepo.transact(fn ->
                 {:ok,
                  [
                    TI.transact(TestRepo, %{tenant: ""}, fn -> {:ok, 1} end),
                    TI.transact(TestRepo, t1(), fn _ -> {:ok, 1} end),
                    TI.transact(TestRepo, t1(), fn -> {:ok, 1} end)
                  ]}
               end)
    end

    test "identifiers: bad, uppercase and 64-byte names raise the fixed ArgumentError" do
      long = String.duplicate("a", 64)
      ok63 = String.duplicate("a", 63)

      bad =
        ["bad-id", "Upper", long, "1abc", "", "a b", ~s(a"b), "a.b", "é", nil, :atom, ~c"abc"]

      for name <- bad do
        assert_raise ArgumentError, @message, fn -> Migration.install(name) end

        flat = [prefix: "p", tenant_column: "t", space_column: nil]

        cases =
          [
            {name, flat},
            {{name, "t"}, flat},
            {{"s", name}, flat},
            {"t", Keyword.put(flat, :prefix, name)},
            {"t", Keyword.put(flat, :tenant_column, name)}
          ] ++ if(name == nil, do: [], else: [{"t", Keyword.put(flat, :space_column, name)}])

        for {table, opts} <- cases do
          assert_raise ArgumentError, @message, fn -> Migration.protect(table, opts) end
          assert_raise ArgumentError, @message, fn -> TI.verify(TestRepo, table, opts) end
        end
      end

      for opts <- [
            [prefix: "p", tenant_column: "t"],
            [prefix: "p", tenant_column: "t", space_column: nil, extra: 1],
            %{prefix: "p", tenant_column: "t", space_column: nil},
            [prefix: "p", tenant_column: "t", space_column: nil, prefix: "q"]
          ] do
        assert_raise ArgumentError, @message, fn -> Migration.protect("t", opts) end
        assert_raise ArgumentError, @message, fn -> TI.verify(TestRepo, "t", opts) end
      end

      assert TI.verify(TestRepo, {ok63, ok63}, prefix: ok63, tenant_column: ok63, space_column: "_") ==
               {:error, :not_enabled}
    end
  end

  def forward_query(_event, _measurements, meta, parent), do: send(parent, {:query, meta.params})

  def hold_after_clear(
        _event,
        _measurements,
        %{query: "SELECT set_config('elzoo.tenant_id', ''," <> _},
        parent
      ) do
    send(parent, :cleared)
    Process.sleep(500)
  end

  def hold_after_clear(_, _, _, _), do: :ok

  describe "transaction timeout" do
    test "the held write commits only under the longer deadline", %{p: p} do
      write = fn body ->
        q!("INSERT INTO #{p}.flat (tenant, body) VALUES ('T1', $1)", [body])
        Process.sleep(500)
        send(self(), {:returning, body})
        {:ok, body}
      end

      capture_log(fn ->
        short = TI.transact(TestRepo, t1(), fn -> write.("short") end, timeout: 200)
        assert_received {:returning, "short"}
        assert {short, truth(p, "flat")} == {{:error, :unavailable}, []}
      end)

      assert {:ok, "long"} = TI.transact(TestRepo, t1(), fn -> write.("long") end, timeout: 5_000)
      assert truth(p, "flat") == [["T1", "long"]]
    end

    test "a delayed pool timer cannot admit a late commit", %{p: p} do
      pool = Ecto.Adapter.lookup_meta(TestRepo).pid

      result =
        try do
          TI.transact(
            TestRepo,
            t1(),
            fn ->
              q!("INSERT INTO #{p}.flat (tenant, body) VALUES ('T1', 'late')")
              :ok = :sys.suspend(pool)
              Process.sleep(500)
              send(self(), :returning_after_suspension)
              {:ok, :written}
            end,
            timeout: 200
          )
        after
          :sys.resume(pool)
        end

      assert_received :returning_after_suspension
      assert {result, truth(p, "flat")} == {{:error, :unavailable}, []}
    end

    test "expiry after clearing refuses the commit without changing an explicit :rollback", %{p: p} do
      id = make_ref()

      :ok =
        :telemetry.attach(
          id,
          [:elzoo, :tenant_isolation, :test_repo, :query],
          &__MODULE__.hold_after_clear/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(id) end)

      capture_log(fn ->
        result =
          TI.transact(
            TestRepo,
            t1(),
            fn ->
              q!("INSERT INTO #{p}.flat (tenant, body) VALUES ('T1', 'before clear')")
              {:ok, :written}
            end,
            timeout: 200
          )

        assert_received :cleared
        assert {result, truth(p, "flat")} == {{:error, :unavailable}, []}

        assert TI.transact(
                 TestRepo,
                 t1(),
                 fn ->
                   Process.sleep(500)
                   TestRepo.rollback(:rollback)
                 end,
                 timeout: 200
               ) == {:error, :rollback}
      end)
    end

    test "another Repo's error is opaque even when returned or raised after expiry" do
      {:error, %Postgrex.Error{postgres: %{code: :query_canceled}} = saved} =
        AdminRepo.transact(fn ->
          qr!(AdminRepo, "SET LOCAL statement_timeout = '30ms'")
          qr(AdminRepo, "SELECT pg_sleep(1)")
        end)

      capture_log(fn ->
        opts = [timeout: 200]

        assert TI.transact(
                 TestRepo,
                 t1(),
                 fn ->
                   Process.sleep(500)
                   {:error, saved}
                 end,
                 opts
               ) == {:error, saved}

        assert assert_raise(Postgrex.Error, fn ->
                 TI.transact(
                   TestRepo,
                   t1(),
                   fn ->
                     Process.sleep(500)
                     raise saved
                   end,
                   opts
                 )
               end) == saved
      end)
    end

    test "defaults keep the Repo deadline; callback queries return their own driver errors" do
      Harness.start!(LogRepo, pool_size: 1, timeout: 200)

      hold = fn ->
        Process.sleep(500)
        {:ok, :held}
      end

      capture_log(fn ->
        assert_raise DBConnection.ConnectionError, fn -> TI.transact(LogRepo, t1(), hold) end
        assert_raise DBConnection.ConnectionError, fn -> TI.transact(LogRepo, t1(), hold, []) end

        assert {:error, error} =
                 TI.transact(
                   LogRepo,
                   t1(),
                   fn ->
                     {:error, e} = qr(LogRepo, "SELECT pg_sleep(1)")
                     send(self(), {:driver_error, e})
                     {:error, e}
                   end,
                   timeout: 200
                 )

        assert_received {:driver_error, ^error}
      end)
    end

    test "option and checkout refusals run no SQL or callback" do
      id = make_ref()
      event = [:elzoo, :tenant_isolation, :test_repo, :query]
      :ok = :telemetry.attach(id, event, &__MODULE__.forward_query/4, self())
      on_exit(fn -> :telemetry.detach(id) end)

      fun = fn ->
        send(self(), :ran)
        {:ok, :ran}
      end

      TestRepo.checkout(
        fn ->
          assert TI.transact(TestRepo, %{}, fun, timeout: 0) ==
                   {:error, {:tenant_isolation, :scope}}

          assert TI.transact(TestRepo, t1(), nil, timeout: 0) ==
                   {:error, {:tenant_isolation, :scope}}

          for opts <- [
                [timeout: 0],
                [timeout: 600_001],
                [timeout: 1.0],
                [timeout: 2, timeout: 3],
                [other: 1],
                nil
              ] do
            assert TI.transact(TestRepo, t1(), fun, opts) == {:error, {:tenant_isolation, :timeout}}
          end

          for ms <- [200, 1, 600_000] do
            assert TI.transact(TestRepo, t1(), fun, timeout: ms) ==
                     {:error, {:tenant_isolation, :in_checkout}}
          end

          refute_received {:query, _}
          refute_received :ran
          assert TI.transact(TestRepo, t1(), fun) == {:ok, :ran}
          assert TI.transact(TestRepo, t1(), fun, []) == {:ok, :ran}
          assert_received {:query, ["T1", []]}
        end,
        timeout: 610_000
      )

      assert {:ok, {:error, {:tenant_isolation, :in_transaction}}} =
               TestRepo.transact(fn ->
                 {:ok, TI.transact(TestRepo, t1(), fn -> flunk("ran") end, timeout: 1)}
               end)
    end

    test "explicit timeout preserves callback errors, rollback values and unrelated exceptions" do
      opts = [timeout: 600_000]
      assert TI.transact(TestRepo, t1(), fn -> {:error, :domain} end, opts) == {:error, :domain}

      assert TI.transact(TestRepo, t1(), fn -> TestRepo.rollback(:value) end, opts) ==
               {:error, :value}

      assert_raise DBConnection.ConnectionError, "unrelated", fn ->
        TI.transact(TestRepo, t1(), fn -> raise DBConnection.ConnectionError, "unrelated" end, opts)
      end
    end
  end

  describe "limits" do
    test "the Repo's query telemetry still receives the scope parameters (log: false)" do
      event = [:elzoo, :tenant_isolation, :test_repo, :query]
      id = {__MODULE__, make_ref()}

      :telemetry.attach(id, event, &__MODULE__.forward_query/4, self())

      try do
        {:ok, :ok} = TI.transact(TestRepo, %{tenant: "T1", spaces: ["s1"]}, fn -> {:ok, :ok} end)
        assert_received {:query, ["T1", ["s1"]]}
        assert_received {:query, []}
      after
        :telemetry.detach(id)
      end
    end

    test "the helper's set and clear queries are not logged by a logging Repo (log: false)" do
      # Earlier modules can leave the global Logger level above :info, which would drop the
      # control query too; this module is synchronous, so it sets the level and restores it.
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)
      Harness.start!(LogRepo, pool_size: 1, log: :info)
      scope = %{tenant: "tenant-log-probe", spaces: ["space-log-probe"]}

      log =
        capture_log(fn ->
          assert {:ok, :ok} = TI.transact(LogRepo, scope, fn -> {:ok, :ok} end)
          {:ok, _} = SQL.query(LogRepo, "SELECT $1::text", ["control-log-probe"])
        end)

      assert log =~ "control-log-probe"
      refute log =~ "tenant-log-probe"
      refute log =~ "space-log-probe"
      refute log =~ "set_config"
    end

    test "non-owner, non-bypass application role", %{p: p} do
      role = System.fetch_env!("ELZOO_TEST_APP_ROLE")
      assert role =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/
      admin!("GRANT USAGE ON SCHEMA #{p} TO #{role}")
      admin!("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA #{p} TO #{role}")
      admin!("GRANT USAGE ON ALL SEQUENCES IN SCHEMA #{p} TO #{role}")
      seed_flat(p)

      Harness.start!(AppRepo,
        pool_size: 1,
        after_connect: {Postgrex, :query!, ["SET ROLE #{role}", []]}
      )

      assert qr!(AppRepo, "SELECT current_user") == [[role]]
      assert [nil, [], 0, 0, _] = outside(AppRepo, p)
      assert bodies(AppRepo, p, "flat", t1()) == ["a", "b"]

      assert {:ok, ["T1", [], 2, 0, _]} =
               TI.transact(AppRepo, t1(), fn -> {:ok, outside(AppRepo, p)} end, timeout: 5_000)

      assert [nil, [], 0, 0, _] = outside(AppRepo, p)

      for sql <- [
            "INSERT INTO #{p}.flat (tenant, body) VALUES ('T2', 'z')",
            "ALTER TABLE #{p}.flat NO FORCE ROW LEVEL SECURITY",
            "ALTER TABLE #{p}.flat DISABLE ROW LEVEL SECURITY",
            "DROP POLICY elzoo_tenant_floor ON #{p}.flat"
          ] do
        assert {:error, %Postgrex.Error{postgres: %{code: code}}} =
                 TI.transact(AppRepo, t1(), fn -> qr(AppRepo, sql) end)

        assert code == @denied, sql
      end

      assert denied?(
               TI.transact(AppRepo, t1(), fn ->
                 {:ok, _} = qr(AppRepo, "SET LOCAL row_security = off")
                 qr(AppRepo, "SELECT count(*) FROM #{p}.flat")
               end)
             )

      assert TI.verify(AppRepo, {p, "flat"}, flat(p)) == :ok
      Supervisor.stop(AppRepo)
      IO.puts("TenantIsolation non-owner boundary: EXERCISED")
    end
  end
end
