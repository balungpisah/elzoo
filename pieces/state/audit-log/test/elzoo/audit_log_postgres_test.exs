# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/audit_log_test_helper.exs", __DIR__)

defmodule Elzoo.AuditLog.PostgresTest do
  use ExUnit.Case, async: false
  alias Elzoo.AuditLog
  alias Elzoo.AuditLog.{Harness, Retention, SingleTestRepo, TestRepo}
  alias Elzoo.DurableLog, as: Log
  import Harness, only: [query!: 2, query!: 3, row: 2, refused?: 1]

  @a %{actor: "user:1", action: "refund.request", reason: "customer request"}
  @setting Elzoo.AuditLog.Store.setting()

  setup_all do
    :ok = Harness.start!(TestRepo, 8)
    :ok = Harness.start!(SingleTestRepo, 1)
    :ok
  end

  setup context do
    install =
      Harness.install!(TestRepo, Map.get(context, :install, []))

    on_exit(fn -> Harness.drop!(TestRepo, install) end)
    store = Harness.store(TestRepo, install.prefix)
    {:ok, bound} = AuditLog.bind(store, @a)
    :persistent_term.put({__MODULE__, :carbonite}, install.carbonite)
    Map.merge(install, %{store: store, bound: bound})
  end

  defp changes(c), do: Harness.changes(TestRepo, c.carbonite)
  defp transactions(c), do: Harness.transactions(TestRepo, c.carbonite)
  defp head(c, stream), do: Log.Store.read(c.store, :head, [stream])

  defp write(store, op, args) do
    {module, _} = store
    apply(module, op, [store | args])
  end

  # Sets the attribution setting by hand on a pinned connection (database-level scenarios).
  defp raw_bound(repo, value, fun) do
    repo.checkout(fn ->
      query!(repo, "SELECT set_config($1, $2, false)", [@setting, value])

      try do
        fun.()
      after
        query!(repo, "SELECT set_config($1, '', false)", [@setting])
      end
    end)
  end

  defp covering(op, stream, extra),
    do: Jason.encode!(Map.merge(@a, Map.merge(%{op: op, stream: stream}, extra)))

  defp hex(%{digest: d}), do: Base.encode16(d, case: :lower)

  test "T1 T5 commit pairs the record with exactly one audit transaction; excluded columns absent",
       c do
    r1 = row("s", 1)
    assert {:committed, 1} = write(c.bound, :append, ["s", 0, [r1], []])
    assert :ok = AuditLog.verify(TestRepo, c.prefix, c.carbonite)

    assert [[meta, "insert", ["1", "s"], data]] = changes(c)

    assert meta == %{
             "actor" => "user:1",
             "action" => "refund.request",
             "reason" => "customer request"
           }

    assert Enum.sort(Map.keys(data)) == ~w(digest kind schema_version sequence stream)
    assert data["digest"] == "\\x" <> hex(r1)
    assert transactions(c) == 1

    # a two-record batch is one transaction with two changes
    batch = [row("s", 2), row("s", 3)] |> same_nonce()
    assert {:committed, 3} = write(c.bound, :append, ["s", 1, batch, []])
    assert transactions(c) == 2

    assert {:ok, [first, second]} = AuditLog.read(TestRepo, c.carbonite, stream: "s")
    assert {first.actor, first.action} == {"user:1", "refund.request"}
    assert [%{op: "insert", stream: "s", sequence: 1}] = first.changes
    assert [%{sequence: 2}, %{sequence: 3}] = second.changes
    assert %NaiveDateTime{} = first.inserted_at
    assert is_binary(first.xact_id)
    assert {:ok, [^second]} = AuditLog.read(TestRepo, c.carbonite, after: first.transaction_id)
    assert {:ok, []} = AuditLog.read(TestRepo, c.carbonite, stream: "other")
    assert {:error, :invalid_option} = AuditLog.read(TestRepo, c.carbonite, limit: 0)
    assert {:error, :invalid_prefix} = AuditLog.read(TestRepo, "Bad", [])
  end

  @tag install: [excluded_columns: ["payload", "digest"]]
  test "T5 a configured exclusion list is applied by the migration", c do
    assert {:committed, 1} = write(c.bound, :append, ["s", 0, [row("s", 1)], []])
    assert [[_, "insert", _, data]] = changes(c)
    assert Enum.sort(Map.keys(data)) == ~w(kind nonce schema_version sequence stream)
  end

  test "T2 rollback removes both: CAS conflict and a failure inside the Store transaction", c do
    assert {:committed, 1} = write(c.bound, :append, ["s", 0, [row("s", 1)], []])

    assert {:conflict, %{expected: 0, observed: 1}} =
             write(c.bound, :append, ["s", 0, [row("s", 1)], []])

    assert transactions(c) == 1
    assert length(changes(c)) == 1

    failing =
      Harness.store(TestRepo, c.prefix,
        test_hook: fn
          :append, :before_commit, _ -> raise "injected failure before commit"
          _, _, _ -> :ok
        end
      )

    {:ok, failing} = AuditLog.bind(failing, @a)

    assert {:indeterminate, %{cause: :exception}} =
             write(failing, :append, ["s", 1, [row("s", 2)], []])

    assert {:ok, %{revision: 1}} = head(c, "s")
    assert Harness.records(TestRepo, c.prefix) == 1
    assert transactions(c) == 1
    assert length(changes(c)) == 1
    assert TestRepo.checkout(fn -> Harness.setting(TestRepo) end) == ""
  end

  test "T4 the database refuses uncovered writes: unbound, other stream, other record, override_mode, update",
       c do
    assert {:committed, 1} = write(c.bound, :append, ["s", 0, [row("s", 1)], []])
    before = changes(c)

    unchanged = fn ->
      assert {:ok, %{revision: 1}} = head(c, "s")
      assert changes(c) == before
      assert transactions(c) == 1
    end

    assert refused?(write(c.store, :append, ["s", 1, [row("s", 2)], []]))
    unchanged.()

    r2 = row("s", 2)
    other = row("s", 2)

    for value <- [
          covering("append", "other", %{digests: [hex(r2)]}),
          covering("append", "s", %{digests: [hex(other)]}),
          covering("retain", "s", %{through: 5}),
          covering("append", "s", %{digests: hex(r2)}),
          "{}"
        ] do
      assert refused?(
               raw_bound(TestRepo, value, fn -> write(c.store, :append, ["s", 1, [r2], []]) end)
             ),
             value

      unchanged.()
    end

    override =
      TestRepo.checkout(fn ->
        query!(TestRepo, "SELECT set_config($1, 'ignore', false)", ["#{c.carbonite}.override_mode"])

        try do
          write(c.bound, :append, ["s", 1, [r2], []])
        after
          query!(TestRepo, "SELECT set_config($1, '', false)", ["#{c.carbonite}.override_mode"])
        end
      end)

    assert refused?(override)
    unchanged.()

    # records are insert-only: an UPDATE is refused even with a covering setting
    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             raw_bound(TestRepo, covering("append", "s", %{digests: [hex(r2)]}), fn ->
               Ecto.Adapters.SQL.query(
                 TestRepo,
                 "UPDATE #{c.prefix}.elzoo_log_records SET kind = 'e'",
                 []
               )
             end)

    unchanged.()

    # inside the caller's open transaction the inner Store's refusal applies and no setting is made
    assert {:error, :rollback} =
             TestRepo.transaction(fn ->
               assert {:rejected, :caller_transaction} = write(c.bound, :append, ["s", 1, [r2], []])
               assert Harness.setting(TestRepo) == ""
               TestRepo.rollback(:rollback)
             end)

    unchanged.()
  end

  test "T7 concurrent bindings with distinct actors are attributed to their own actor", c do
    tasks =
      for i <- 1..16 do
        Task.async(fn ->
          {:ok, store} = AuditLog.bind(c.store, %{@a | actor: "user:#{i}"})
          stream = "c#{i}"
          {stream, write(store, :append, [stream, 0, [row(stream, 1)], []])}
        end)
      end

    results = Task.await_many(tasks, 30_000)
    assert Enum.all?(results, &match?({_, {:committed, 1}}, &1))
    attributed = for [m, "insert", ["1", stream], _] <- changes(c), do: {stream, m["actor"]}
    assert Enum.sort(attributed) == Enum.sort(for i <- 1..16, do: {"c#{i}", "user:#{i}"})
  end

  test "T11 setting is empty on six concurrently held connections after bound writes", c do
    for i <- 1..12,
        do: assert({:committed, 1} = write(c.bound, :append, ["p#{i}", 0, [row("p#{i}", 1)], []]))

    parent = self()

    holders =
      for _ <- 1..6 do
        spawn(fn ->
          TestRepo.checkout(fn ->
            [[pid]] = query!(TestRepo, "SELECT pg_backend_pid()").rows
            send(parent, {:held, self(), pid, Harness.setting(TestRepo)})
            receive do: (:release -> :ok)
          end)
        end)
      end

    observed =
      for _ <- holders do
        receive do
          {:held, _, pid, setting} -> {pid, setting}
        after
          10_000 -> flunk("a holder did not report")
        end
      end

    refs = for h <- holders, do: Process.monitor(h)
    for h <- holders, do: send(h, :release)
    for ref <- refs, do: assert_receive({:DOWN, ^ref, _, _, :normal}, 10_000)
    assert length(Enum.uniq(Enum.map(observed, &elem(&1, 0)))) == 6
    assert Enum.all?(observed, fn {_, setting} -> setting == "" end)
  end

  for path <- [:commit, :rollback] do
    test "T11 holder killed between write and reset (#{path}): connection discarded, residue unusable",
         c do
      parent = self()
      single = Harness.store(SingleTestRepo, c.prefix)
      {:ok, bound} = AuditLog.bind(single, @a)
      assert {:committed, 1} = write(bound, :append, ["k", 0, [row("k", 1)], []])
      r2 = row("k", 2)
      phase = if unquote(path) == :commit, do: :after_commit_reply, else: :before_commit

      blocking =
        Harness.store(SingleTestRepo, c.prefix,
          test_hook: fn
            :append, ^phase, repo ->
              [[pid]] = query!(repo, "SELECT pg_backend_pid()").rows
              send(parent, {:held, pid, Harness.setting(repo)})
              Process.sleep(:infinity)

            _, _, _ ->
              :ok
          end
        )

      {:ok, blocking} = AuditLog.bind(blocking, %{@a | actor: "user:dead"})
      holder = spawn(fn -> write(blocking, :append, ["k", 1, [r2], []]) end)
      assert_receive {:held, backend, setting}, 10_000
      assert setting =~ "user:dead" and setting =~ hex(r2)
      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}

      {next, residue} =
        SingleTestRepo.checkout(fn ->
          [[pid]] = query!(SingleTestRepo, "SELECT pg_backend_pid()").rows
          {pid, Harness.setting(SingleTestRepo)}
        end)

      assert next != backend and residue == ""
      before = changes(c)

      case unquote(path) do
        :commit ->
          assert {:ok, %{revision: 2}} = head(c, "k")
          assert refused?(write(single, :append, ["k", 2, [row("k", 3)], []]))

        :rollback ->
          assert {:ok, %{revision: 1}} = head(c, "k")
          # the very record the dead holder was bound to is not insertable without a binding
          assert refused?(write(single, :append, ["k", 1, [r2], []]))
          assert {:ok, %{revision: 1}} = head(c, "k")
      end

      assert changes(c) == before
    end
  end

  test "T13 Store retention through a binding is audited as delete; a narrower setting is refused",
       c do
    for n <- 1..3,
        do: assert({:committed, ^n} = write(c.bound, :append, ["s", n - 1, [row("s", n)], []]))

    {:ok, rows, _} = Log.Store.read(c.store, :read, ["s", 1, 10])
    snapshot = Log.replay(rows, 3, Harness.fold())
    # checkpoints are outside the audited surface: no binding needed, nothing captured
    assert {:committed, 3} =
             Elzoo.Checkpoint.take(
               {c.store, snapshot, Harness.limits()},
               "s",
               1,
               &Integer.to_string/1
             )

    assert transactions(c) == 3
    assert {:committed, 1} = write(c.bound, :retain, ["s", 0, 1, :crypto.strong_rand_bytes(16)])

    assert [[%{"actor" => "user:1"}, "delete", ["1", "s"], %{"sequence" => 1}]] =
             for(r = [_, "delete", _, _] <- changes(c), do: r)

    assert refused?(
             raw_bound(TestRepo, covering("retain", "s", %{through: 1}), fn ->
               write(c.store, :retain, ["s", 1, 2, :crypto.strong_rand_bytes(16)])
             end)
           )

    assert refused?(write(c.store, :retain, ["s", 1, 2, :crypto.strong_rand_bytes(16)]))
    assert Harness.records(TestRepo, c.prefix) == 2
  end

  test "T12 the retention query selects only transactions past the dated rule", c do
    for n <- 1..4,
        do: assert({:committed, ^n} = write(c.bound, :append, ["s", n - 1, [row("s", n)], []]))

    [[a], [b], [d], [e]] =
      query!(TestRepo, "SELECT id FROM #{c.carbonite}.transactions ORDER BY id").rows

    for {id, at} <- [
          {a, ~N[2026-09-01 00:00:00]},
          {b, ~N[2026-10-10 11:59:59.999999]},
          {d, ~N[2026-10-10 12:00:00]},
          {e, ~N[2026-11-09 00:00:00]}
        ],
        do:
          query!(
            TestRepo,
            "UPDATE #{c.carbonite}.transactions SET inserted_at = $2 WHERE id = $1",
            [id, at]
          )

    rule = %{keep_days: 30, effective_from: ~D[2026-11-01]}
    now = ~U[2026-11-09 12:00:00Z]
    assert {:ok, [^a, ^b]} = Retention.expired(TestRepo, c.carbonite, rule, now, 100)
    assert {:ok, [^a]} = Retention.expired(TestRepo, c.carbonite, rule, now, 1)
    assert {:ok, []} = Retention.expired(TestRepo, c.carbonite, rule, ~U[2026-10-31 12:00:00Z], 100)

    for {id, at} <- [
          {a, ~N[2026-09-01 00:00:00]},
          {b, ~N[2026-10-10 11:59:59.999999]},
          {d, ~N[2026-10-10 12:00:00]},
          {e, ~N[2026-11-09 00:00:00]}
        ] do
      expected = id in [a, b]
      assert Retention.expired?(rule, at, now) == {:ok, expected}
    end

    # selection only: nothing was deleted
    assert transactions(c) == 4
  end

  test "T8 TRUNCATE removes records without any audit change (disclosed limit)", c do
    assert {:committed, 1} = write(c.bound, :append, ["s", 0, [row("s", 1)], []])
    before = changes(c)
    query!(TestRepo, "TRUNCATE #{c.prefix}.elzoo_log_records CASCADE")
    assert Harness.records(TestRepo, c.prefix) == 0
    assert changes(c) == before
  end

  test "T9 the table owner can disable the triggers and write without audit (disclosed limit)", c do
    assert {:committed, 1} = write(c.bound, :append, ["s", 0, [row("s", 1)], []])
    before = changes(c)
    query!(TestRepo, "ALTER TABLE #{c.prefix}.elzoo_log_records DISABLE TRIGGER USER")
    assert {:error, :trigger_disabled} = AuditLog.verify(TestRepo, c.prefix, c.carbonite)
    assert {:committed, 2} = write(c.store, :append, ["s", 1, [row("s", 2)], []])
    assert changes(c) == before
    query!(TestRepo, "ALTER TABLE #{c.prefix}.elzoo_log_records ENABLE TRIGGER USER")
    assert :ok = AuditLog.verify(TestRepo, c.prefix, c.carbonite)

    # a superuser can also switch triggers off for the session; only shown where available
    if Harness.superuser?(TestRepo) do
      replica =
        TestRepo.checkout(fn ->
          query!(TestRepo, "SET session_replication_role = replica")

          try do
            write(c.store, :append, ["s", 2, [row("s", 3)], []])
          after
            query!(TestRepo, "RESET session_replication_role")
          end
        end)

      assert {:committed, 3} = replica
      assert changes(c) == before
    else
      IO.puts(
        "ELZOO AUDIT T9 session_replication_role NOT EXERCISED: connected role is not superuser"
      )
    end
  end

  @tag install: [audit: false]
  test "opt-in: without the migration the ready Store behaves as before and no audit object exists",
       c do
    # Bindings record nothing without the migration; verify/3 says so.
    assert {:error, :not_installed} = AuditLog.verify(TestRepo, c.prefix, c.carbonite)
    assert {:committed, 1} = write(c.store, :append, ["s", 0, [row("s", 1)], []])

    assert {:conflict, %{expected: 0, observed: 1}} =
             write(c.store, :append, ["s", 0, [row("s", 1)], []])

    assert {:committed, 2} = write(c.bound, :append, ["s", 1, [row("s", 2)], []])

    assert query!(
             TestRepo,
             "SELECT count(*) FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid JOIN pg_namespace n ON n.oid = r.relnamespace WHERE n.nspname = $1 AND NOT t.tgisinternal",
             [c.prefix]
           ).rows == [[0]]

    assert query!(TestRepo, "SELECT count(*) FROM pg_namespace WHERE nspname = $1", [c.carbonite]).rows ==
             [[0]]
  end

  test "T14 T10 definer functions: fixed search_path, named non-superuser owner, every migration path; application role boundary",
       c do
    owner = owner_role!(c)
    assert_secured!(c, owner)

    # Carbonite recreates capture_changes() with CREATE OR REPLACE on a later migration: the
    # attributes are lost, verify/3 reports it, secure/1 restores them.
    run_as_migration(fn -> Carbonite.Migrations.up(12, carbonite_prefix: c.carbonite) end)
    assert {:error, :not_secured} = AuditLog.verify(TestRepo, c.prefix, c.carbonite)
    run_as_migration(fn -> Elzoo.AuditLog.Migration.secure(c.carbonite) end)
    assert_secured!(c, owner)

    # down then up again
    run_as_migration(fn ->
      Elzoo.AuditLog.Migration.down(store_prefix: c.prefix, carbonite_prefix: c.carbonite)
    end)

    assert {:error, :not_installed} = AuditLog.verify(TestRepo, c.prefix, c.carbonite)

    run_as_migration(fn ->
      Elzoo.AuditLog.Migration.up(store_prefix: c.prefix, carbonite_prefix: c.carbonite)
    end)

    owner = owner_role!(c)
    assert_secured!(c, owner)
    assert {:committed, 1} = write(c.bound, :append, ["s", 0, [row("s", 1)], []])

    if Harness.role_capable?(TestRepo),
      do: application_role!(c),
      else:
        IO.puts(
          "ELZOO AUDIT T10 application role NOT EXERCISED: connected role cannot create roles"
        )
  end

  # The audit owner named by the fixture: the connected migration role when it is not a
  # superuser (the hosted CI role); otherwise a dedicated NOLOGIN non-superuser role that takes
  # ownership of every audit object.
  defp owner_role!(c) do
    if Harness.superuser?(TestRepo) do
      role = "elzoo_audit_owner_" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

      query!(
        TestRepo,
        "CREATE ROLE #{role} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS"
      )

      on_exit(fn -> drop_role(role) end)
      query!(TestRepo, "ALTER SCHEMA #{c.carbonite} OWNER TO #{role}")

      for [kind, name] <-
            query!(
              TestRepo,
              """
              SELECT 'TABLE', quote_ident(c.relname) FROM pg_class c
              WHERE c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = $1) AND c.relkind IN ('r', 'p')
              UNION ALL
              SELECT 'SEQUENCE', quote_ident(c.relname) FROM pg_class c
              WHERE c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = $1) AND c.relkind = 'S'
                AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype IN ('a', 'i'))
              UNION ALL
              SELECT 'FUNCTION', p.oid::regprocedure::text FROM pg_proc p WHERE p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = $1)
              """,
              [c.carbonite]
            ).rows do
        target = if kind == "FUNCTION", do: name, else: "#{c.carbonite}.#{name}"
        query!(TestRepo, "ALTER #{kind} #{target} OWNER TO #{role}")
      end

      role
    else
      [[role]] = query!(TestRepo, "SELECT current_user::text").rows
      role
    end
  end

  defp assert_secured!(c, owner) do
    assert :ok = AuditLog.verify(TestRepo, c.prefix, c.carbonite)

    rows =
      query!(
        TestRepo,
        """
        SELECT p.proname, p.prosecdef, p.proconfig, pg_get_userbyid(p.proowner), r.rolsuper
        FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
        WHERE p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = $1) AND p.proname IN ('capture_changes', 'elzoo_attribute')
        ORDER BY p.proname
        """,
        [c.carbonite]
      ).rows

    assert rows == [
             ["capture_changes", true, ["search_path=pg_catalog, pg_temp"], owner, false],
             ["elzoo_attribute", true, ["search_path=pg_catalog, pg_temp"], owner, false]
           ]
  end

  defp run_as_migration(fun) do
    :persistent_term.put({__MODULE__.Step, :fun}, fun)
    version = 1_000_000 + System.unique_integer([:positive, :monotonic])

    :ok =
      Ecto.Migrator.up(TestRepo, version, __MODULE__.Step, log: false, prefix: carbonite_of(fun))
  end

  defp carbonite_of(_), do: :persistent_term.get({__MODULE__, :carbonite})

  defmodule Step do
    @moduledoc false
    use Ecto.Migration
    def up, do: :persistent_term.get({__MODULE__, :fun}).()
    def down, do: :ok
  end

  defp application_role!(c) do
    role = "elzoo_audit_app_" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

    query!(
      TestRepo,
      "CREATE ROLE #{role} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS"
    )

    on_exit(fn -> drop_role(role) end)
    query!(TestRepo, "GRANT USAGE ON SCHEMA #{c.prefix} TO #{role}")

    query!(
      TestRepo,
      "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA #{c.prefix} TO #{role}"
    )

    assert query!(
             TestRepo,
             """
             SELECT r.rolsuper, r.rolcreaterole, r.rolcreatedb, r.rolcanlogin, r.rolbypassrls,
                    has_database_privilege($1, current_database(), 'CREATE'),
                    has_schema_privilege($1, $2, 'USAGE'), has_schema_privilege($1, $2, 'CREATE'),
                    EXISTS (SELECT 1 FROM pg_tables WHERE tableowner = $1)
             FROM pg_roles r WHERE r.rolname = $1
             """,
             [role, c.carbonite]
           ).rows == [[false, false, false, false, false, false, false, false, false]]

    results =
      TestRepo.checkout(fn ->
        query!(TestRepo, "SET ROLE #{role}")

        try do
          attempt = fn sql ->
            case Ecto.Adapters.SQL.query(TestRepo, sql, []) do
              {:ok, _} -> :ok
              {:error, %Postgrex.Error{postgres: %{code: code}}} -> code
            end
          end

          %{
            bound: write(c.bound, :append, ["r", 0, [row("r", 1)], []]),
            unbound: write(c.store, :append, ["r", 1, [row("r", 2)], []]),
            insert:
              attempt.(
                "INSERT INTO #{c.carbonite}.transactions (meta, inserted_at) VALUES ('{}', now())"
              ),
            update: attempt.("UPDATE #{c.carbonite}.changes SET op = 'insert'"),
            delete: attempt.("DELETE FROM #{c.carbonite}.transactions"),
            truncate: attempt.("TRUNCATE #{c.carbonite}.changes"),
            config: attempt.("UPDATE #{c.carbonite}.triggers SET mode = 'ignore'"),
            disable: attempt.("ALTER TABLE #{c.prefix}.elzoo_log_records DISABLE TRIGGER USER"),
            schema: attempt.("CREATE SCHEMA elzoo_audit_forbidden_probe")
          }
        after
          query!(TestRepo, "RESET ROLE")
        end
      end)

    assert {:committed, 1} = results.bound
    assert refused?(results.unbound)

    for key <- [:insert, :update, :delete, :truncate, :config, :disable, :schema],
        do: assert(results[key] == :insufficient_privilege, "#{key}")

    assert [%{"actor" => "user:1"}, "insert", ["1", "r"], _] = List.last(changes(c))
  end

  defp drop_role(role) do
    Ecto.Adapters.SQL.query(TestRepo, "DROP OWNED BY #{role}", [], log: false)
    Ecto.Adapters.SQL.query(TestRepo, "DROP ROLE IF EXISTS #{role}", [], log: false)
  end

  defp same_nonce([first | rest]) do
    [
      first
      | Enum.map(rest, fn r ->
          %{r | nonce: first.nonce} |> then(&%{&1 | digest: Log.digest(&1)})
        end)
    ]
  end
end
