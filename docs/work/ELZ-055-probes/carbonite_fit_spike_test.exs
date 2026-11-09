# SPDX-License-Identifier: Apache-2.0
# ELZ-055 provider-fit probes P1 (generic ready-Store append spike), P3 (session-setting leak
# under holder death) and P4 (application-role privilege boundary). Recorded source; not run by
# mix check and not a deliverable. Ran from pieces/state/audit-log/test/spike/ with
# {:carbonite, "== 0.17.0"} added to mix.exs, ELZOO_TEST_DATABASE_URL set and
# ELZOO_AUDIT_EXPECTED_DB naming the same database (fail-closed target guard on both the
# configured URL and current_database()). Results are recorded in the ELZ-055 work record.
sql_helper =
  Path.expand(
    "../../../../integration/sql/test/support/durable_log_postgres_test_helper.exs",
    __DIR__
  )

Code.require_file(sql_helper)

defmodule Elzoo.AuditSpike.Repo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.AuditSpike.SingleRepo do
  use Ecto.Repo, otp_app: :elzoo, adapter: Ecto.Adapters.Postgres
end

defmodule Elzoo.AuditSpike.CarbMigration do
  use Ecto.Migration
  def up, do: Carbonite.Migrations.up(1..12, carbonite_prefix: :persistent_term.get(:audit_spike_carb))
  def down, do: :ok
end

defmodule Elzoo.AuditSpikeTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL
  alias Elzoo.DurableLog.{Postgres, PostgresHarness, TestMigration, Record}
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.AuditSpike.{Repo, SingleRepo}

  @setting "elzoo_audit.attribution"
  @limits %{max_record_bytes: 64, max_batch_size: 8, max_checkpoint_bytes: 10_000}

  defp fold,
    do: %{
      initial: 0,
      kinds: %{"e" => :state_bearing},
      versions: [1],
      destinations: [],
      reduce: fn n, _, _, _ -> n + 1 end
    }

  setup_all do
    url = PostgresHarness.database_url!()
    expected = System.get_env("ELZOO_AUDIT_EXPECTED_DB") || raise("expected database not named")
    if URI.parse(url).path != "/" <> expected, do: raise("wrong configured target database")

    for repo <- [Repo, SingleRepo] do
      size = if repo == SingleRepo, do: 1, else: 6
      {:ok, pid} = repo.start_link(url: url, pool_size: size, log: false)
      Process.unlink(pid)
      %{rows: [[name]]} = SQL.query!(repo, "SELECT current_database()", [], log: false)
      if name != expected, do: raise("wrong effective database")
    end

    :ok
  end

  setup do
    hex = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    prefix = "aud_" <> hex
    carb = "carb_" <> hex
    run = fn sql -> SQL.query!(Repo, sql, [], log: false) end
    run.("CREATE SCHEMA #{prefix}")
    :ok = Ecto.Migrator.up(Repo, 1, TestMigration, prefix: prefix, log: false)
    :persistent_term.put(:audit_spike_carb, carb)
    run.("CREATE SCHEMA #{carb}")
    :ok = Ecto.Migrator.up(Repo, 2, Elzoo.AuditSpike.CarbMigration, log: false, prefix: carb)

    run.("""
    CREATE CONSTRAINT TRIGGER capture_changes_into_#{carb}_trigger
    AFTER INSERT OR UPDATE OR DELETE ON "#{prefix}"."elzoo_log_records"
    DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE PROCEDURE #{carb}.capture_changes()
    """)

    run.("""
    INSERT INTO #{carb}.triggers (id, table_prefix, table_name, primary_key_columns, excluded_columns, inserted_at, updated_at)
    VALUES (NEXTVAL('#{carb}.triggers_id_seq'), '#{prefix}', 'elzoo_log_records', '{stream,sequence}', '{payload,nonce}', NOW(), NOW())
    """)

    # Attribution trigger: the session setting is bound to one operation on one stream and, for
    # an append, to the exact record digests; a leaked setting can match only those records.
    run.("""
    CREATE FUNCTION #{carb}.elzoo_attribute() RETURNS TRIGGER
    SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    DECLARE a jsonb;
    BEGIN
      IF NULLIF(current_setting('#{carb}.override_mode', TRUE), '') IS NOT NULL THEN
        RAISE 'elzoo audit: override_mode refused' USING ERRCODE = 'insufficient_privilege';
      END IF;
      a := NULLIF(current_setting('#{@setting}', TRUE), '')::jsonb;
      IF a IS NULL THEN
        RAISE 'elzoo audit: attribution missing' USING ERRCODE = 'insufficient_privilege';
      END IF;
      IF TG_OP = 'INSERT' THEN
        IF a->>'op' IS DISTINCT FROM 'append' OR a->>'stream' IS DISTINCT FROM NEW.stream
           OR NOT (a->'digests') ? encode(NEW.digest, 'hex') THEN
          RAISE 'elzoo audit: attribution does not cover this record' USING ERRCODE = 'insufficient_privilege';
        END IF;
      ELSIF TG_OP = 'DELETE' THEN
        IF a->>'op' IS DISTINCT FROM 'retain' OR a->>'stream' IS DISTINCT FROM OLD.stream
           OR OLD.sequence > (a->>'through')::bigint THEN
          RAISE 'elzoo audit: attribution does not cover this deletion' USING ERRCODE = 'insufficient_privilege';
        END IF;
      ELSE
        RAISE 'elzoo audit: % refused on an audited table', TG_OP USING ERRCODE = 'insufficient_privilege';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM #{carb}.transactions WHERE xact_id = pg_current_xact_id()) THEN
        INSERT INTO #{carb}.transactions (meta, inserted_at)
          VALUES (jsonb_build_object('actor', a->'actor', 'action', a->'action', 'reason', a->'reason'), now());
      END IF;
      RETURN COALESCE(NEW, OLD);
    END $$ LANGUAGE plpgsql
    """)

    run.("""
    CREATE TRIGGER elzoo_attribute BEFORE INSERT OR UPDATE OR DELETE ON "#{prefix}"."elzoo_log_records"
    FOR EACH ROW EXECUTE FUNCTION #{carb}.elzoo_attribute()
    """)

    # Carbonite's capture function runs as the invoker by default; as definer with a fixed
    # search path the application role needs no privilege on the audit schema.
    run.("ALTER FUNCTION #{carb}.capture_changes() SECURITY DEFINER SET search_path = pg_catalog, pg_temp")

    on_exit(fn ->
      SQL.query!(Repo, "DROP SCHEMA #{prefix} CASCADE", [], log: false)
      SQL.query!(Repo, "DROP SCHEMA #{carb} CASCADE", [], log: false)
    end)

    %{
      store: Postgres.store(Repo, prefix: prefix, fold: fold(), limits: @limits),
      single: Postgres.store(SingleRepo, prefix: prefix, fold: fold(), limits: @limits),
      prefix: prefix,
      carb: carb
    }
  end

  defp row(stream, seq, payload \\ nil) do
    r = %Record{
      stream: stream,
      sequence: seq,
      kind: "e",
      schema_version: 1,
      payload: payload || "secret-#{seq}",
      nonce: :crypto.strong_rand_bytes(16)
    }

    %{r | digest: Log.digest(r)}
  end

  defp attribution(attr, op, stream, extra),
    do: Jason.encode!(Map.merge(attr, Map.merge(%{op: op, stream: stream}, extra)))

  defp set(repo, value), do: SQL.query!(repo, "SELECT set_config($1, $2, false)", [@setting, value])

  defp current(repo),
    do: hd(hd(SQL.query!(repo, "SELECT coalesce(current_setting($1, true), '')", [@setting]).rows))

  # The wrapper shape: pin a connection, set the bound attribution, run the inner write, reset.
  defp bound(repo, value, fun) do
    repo.checkout(fn ->
      set(repo, value)

      try do
        fun.()
      after
        set(repo, "")
      end
    end)
  end

  defp append(c, attr, stream, expected, records, repo \\ Repo) do
    {mod, _} = store = if repo == Repo, do: c.store, else: c.single
    digests = Enum.map(records, &Base.encode16(&1.digest, case: :lower))
    value = attribution(attr, "append", stream, %{digests: digests})
    bound(repo, value, fn -> mod.append(store, stream, expected, records, []) end)
  end

  defp audit(c) do
    SQL.query!(
      Repo,
      "SELECT t.meta, ch.op, ch.table_pk, ch.data FROM #{c.carb}.transactions t JOIN #{c.carb}.changes ch ON ch.transaction_id = t.id ORDER BY ch.id",
      [],
      log: false
    ).rows
  end

  defp transactions(c),
    do: hd(hd(SQL.query!(Repo, "SELECT count(*) FROM #{c.carb}.transactions", []).rows))

  defp head(c, stream) do
    {mod, _} = c.store
    mod.head(c.store, stream)
  end

  defp refused?(reply), do: match?({:indeterminate, %{cause: :unavailable}}, reply)

  @a %{actor: "user:1", action: "refund.request", reason: "r"}

  test "P1 generic ready-Store append spike: assertions", c do
    {mod, _} = c.store
    r1 = row("s", 1)
    assert {:committed, 1} = append(c, @a, "s", 0, [r1])
    assert [[%{"actor" => "user:1", "action" => "refund.request", "reason" => "r"}, "insert", ["s", "1"], data]] = audit(c)
    assert Map.keys(data) |> Enum.sort() == ~w(digest kind schema_version sequence stream)
    assert data["digest"] == "\\x" <> Base.encode16(r1.digest, case: :lower)
    assert transactions(c) == 1

    # P1.2 CAS conflict: Store rolls back; nothing new
    assert {:conflict, %{expected: 0, observed: 1}} = append(c, @a, "s", 0, [row("s", 1)])
    assert length(audit(c)) == 1 and transactions(c) == 1

    # P1.3 unbound writer: refused by the trigger; conservative Store result; nothing changes
    assert refused?(mod.append(c.store, "s", 1, [row("s", 2)], []))
    assert {:ok, %{revision: 1}} = head(c, "s")
    assert length(audit(c)) == 1 and transactions(c) == 1

    # P1.4 attribution bound to another stream
    r2 = row("s", 2)
    value = attribution(@a, "append", "other", %{digests: [Base.encode16(r2.digest, case: :lower)]})
    assert refused?(bound(Repo, value, fn -> mod.append(c.store, "s", 1, [r2], []) end))

    # P1.4b attribution bound to another record of the same stream (digest mismatch)
    other = row("s", 2)
    value = attribution(@a, "append", "s", %{digests: [Base.encode16(other.digest, case: :lower)]})
    assert refused?(bound(Repo, value, fn -> mod.append(c.store, "s", 1, [r2], []) end))
    assert {:ok, %{revision: 1}} = head(c, "s")
    assert length(audit(c)) == 1 and transactions(c) == 1

    # P1.5 Carbonite override_mode set in the session: refused
    reply =
      Repo.checkout(fn ->
        SQL.query!(Repo, "SELECT set_config('#{c.carb}.override_mode', 'ignore', false)", [])

        try do
          append(c, @a, "s", 1, [row("s", 2)])
        after
          SQL.query!(Repo, "SELECT set_config('#{c.carb}.override_mode', '', false)", [])
        end
      end)

    assert refused?(reply)
    assert {:ok, %{revision: 1}} = head(c, "s")
    assert length(audit(c)) == 1 and transactions(c) == 1

    # P1.6 concurrency (finite: 8 actors, 8 streams)
    tasks =
      for i <- 1..8 do
        Task.async(fn ->
          append(c, %{actor: "user:#{i}", action: "x", reason: ""}, "c#{i}", 0, [row("c#{i}", 1)])
        end)
      end

    assert Enum.all?(Task.await_many(tasks), &match?({:committed, 1}, &1))
    concurrent = for [m, _, [st, _], _] <- audit(c), String.starts_with?(st, "c"), do: {st, m["actor"]}
    assert Enum.sort(concurrent) == Enum.sort(for i <- 1..8, do: {"c#{i}", "user:#{i}"})

    # P1.7 setting empty after an ordinary bound write, on every pooled connection
    for _ <- 1..6, do: assert(Repo.checkout(fn -> current(Repo) end) == "")

    # P1.10 Store retention DELETE through a binding is audited as delete (checkpoints are not
    # audited, so the anchor checkpoint needs no attribution)
    assert {:committed, 2} = append(c, @a, "s", 1, [row("s", 2)])
    {:ok, rows, 2} = Elzoo.DurableLog.Store.read(c.store, :read, ["s", 1, 10]) |> then(fn {:ok, r, h} -> {:ok, r, h.revision} end)
    snapshot = Log.replay(rows, 2, fold())
    assert {:committed, 2} = Elzoo.Checkpoint.take({c.store, snapshot, @limits}, "s", 1, &Integer.to_string/1)

    assert {:committed, 1} =
             bound(Repo, attribution(@a, "retain", "s", %{through: 1}), fn ->
               mod.retain(c.store, "s", 0, 1, :crypto.strong_rand_bytes(16))
             end)

    assert [[_, "delete", ["s", "1"], %{"sequence" => 1}]] =
             for(r = [_, "delete", _, _] <- audit(c), do: r)

    # a retention binding with a shorter range does not cover the deletion
    assert refused?(
             bound(Repo, attribution(@a, "retain", "s", %{through: 1}), fn ->
               mod.retain(c.store, "s", 1, 2, :crypto.strong_rand_bytes(16))
             end)
           )

    before = audit(c)

    # P1.8 TRUNCATE: records removed, no change captured
    SQL.query!(Repo, "TRUNCATE #{c.prefix}.elzoo_log_records CASCADE", [])
    assert SQL.query!(Repo, "SELECT count(*) FROM #{c.prefix}.elzoo_log_records", []).rows == [[0]]
    assert audit(c) == before

    # P1.9 owner disables user triggers, then writes: no change captured
    SQL.query!(Repo, "ALTER TABLE #{c.prefix}.elzoo_log_records DISABLE TRIGGER USER", [])
    SQL.query!(Repo, "DELETE FROM #{c.prefix}.elzoo_log_heads", [])
    assert {:committed, 1} = mod.append(c.store, "s", 0, [row("s", 1)], [])
    assert audit(c) == before
    SQL.query!(Repo, "ALTER TABLE #{c.prefix}.elzoo_log_records ENABLE TRIGGER USER", [])
  end

  # P3: the holder dies between set and reset. Pool of one connection, so a later checkout gets
  # the same pool slot; the question is whether it is the same backend with the setting.
  for path <- [:commit, :rollback] do
    test "P3 holder killed after a #{path} with the setting still set", c do
      parent = self()
      {mod, _} = c.single
      seed = row("k", 1)
      assert {:committed, 1} = append(c, @a, "k", 0, [seed], SingleRepo)
      r2 = row("k", 2)
      value = attribution(%{@a | actor: "user:dead"}, "append", "k", %{digests: [Base.encode16(r2.digest, case: :lower)]})
      # rollback path: the batch carries a second record the binding does not cover, so the
      # trigger refuses it and the whole Store transaction rolls back with r2 uncommitted
      # (one batch shares one nonce)
      r3 = %{row("k", 3) | nonce: r2.nonce}
      r3 = %{r3 | digest: Log.digest(r3)}
      batch = if unquote(path) == :commit, do: [r2], else: [r2, r3]

      holder =
        spawn(fn ->
          SingleRepo.checkout(fn ->
            set(SingleRepo, value)
            pid = hd(hd(SQL.query!(SingleRepo, "SELECT pg_backend_pid()", []).rows))
            reply = mod.append(c.single, "k", 1, batch, [])
            send(parent, {:held, pid, reply, current(SingleRepo)})
            Process.sleep(:infinity)
          end)
        end)

      assert_receive {:held, backend, reply, setting_in_holder}, 5_000

      case unquote(path) do
        # commit: the trigger leaves the session setting in place (no consumption) until reset
        :commit -> assert {:committed, 2} = reply
        :rollback -> assert refused?(reply)
      end

      assert setting_in_holder == value
      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}

      {next_backend, setting} =
        SingleRepo.checkout(fn ->
          {hd(hd(SQL.query!(SingleRepo, "SELECT pg_backend_pid()", []).rows)), current(SingleRepo)}
        end)

      IO.puts("P3 #{unquote(path)}: backend before=#{backend} after=#{next_backend} setting=#{inspect(setting)}")
      assert setting == ""
      assert next_backend != backend

      # a later unbound matching-stream write is refused; on the rollback path this includes the
      # very record the dead holder was bound to (uncommitted, so it is still insertable)
      before = audit(c)

      case unquote(path) do
        :commit ->
          assert refused?(mod.append(c.single, "k", 2, [row("k", 3)], []))
          assert {:ok, %{revision: 2}} = head(c, "k")

        :rollback ->
          assert refused?(mod.append(c.single, "k", 1, [r2], []))
          assert {:ok, %{revision: 1}} = head(c, "k")
      end

      assert audit(c) == before
    end
  end

  test "P4 application role: captured append works, audit tables refuse direct DML", c do
    role = "elzoo_audit_app_" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
    run = fn sql -> SQL.query!(Repo, sql, [], log: false) end
    run.("CREATE ROLE #{role} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS")

    on_exit(fn ->
      SQL.query(Repo, "DROP OWNED BY #{role}", [], log: false)
      SQL.query!(Repo, "DROP ROLE IF EXISTS #{role}", [], log: false)
    end)

    run.("GRANT USAGE ON SCHEMA #{c.prefix} TO #{role}")
    run.("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA #{c.prefix} TO #{role}")

    assert [[false, false, false, false, false]] =
             SQL.query!(
               Repo,
               "SELECT rolsuper, rolcreaterole, rolcreatedb, rolcanlogin, rolbypassrls FROM pg_roles WHERE rolname = $1",
               [role]
             ).rows

    assert [[false, false, false, false]] =
             SQL.query!(
               Repo,
               """
               SELECT has_database_privilege($1, current_database(), 'CREATE'),
                      has_schema_privilege($1, $2, 'USAGE'),
                      has_schema_privilege($1, $2, 'CREATE'),
                      EXISTS (SELECT 1 FROM pg_tables WHERE tableowner = $1)
               """,
               [role, c.carb]
             ).rows

    {mod, _} = c.store

    results =
      Repo.checkout(fn ->
        SQL.query!(Repo, "SET ROLE #{role}", [])

        try do
          attempt = fn sql ->
            case SQL.query(Repo, sql, []) do
              {:ok, _} -> :ok
              {:error, %Postgrex.Error{postgres: %{code: code}}} -> code
            end
          end

          %{
            append: append(c, @a, "r", 0, [row("r", 1)]),
            unbound: mod.append(c.store, "r", 1, [row("r", 2)], []),
            insert_tx: attempt.("INSERT INTO #{c.carb}.transactions (meta, inserted_at) VALUES ('{}', now())"),
            update: attempt.("UPDATE #{c.carb}.changes SET op = 'insert'"),
            delete: attempt.("DELETE FROM #{c.carb}.changes"),
            truncate: attempt.("TRUNCATE #{c.carb}.changes"),
            triggers: attempt.("UPDATE #{c.carb}.triggers SET mode = 'ignore'"),
            disable: attempt.("ALTER TABLE #{c.prefix}.elzoo_log_records DISABLE TRIGGER USER"),
            schema: attempt.("CREATE SCHEMA elzoo_audit_probe_forbidden")
          }
        after
          SQL.query!(Repo, "RESET ROLE", [])
        end
      end)

    IO.inspect(results, label: "P4")
    assert {:committed, 1} = results.append
    assert refused?(results.unbound)

    for k <- [:insert_tx, :update, :delete, :truncate, :triggers, :schema],
        do: assert(results[k] == :insufficient_privilege, "#{k}")

    assert results.disable == :insufficient_privilege
    assert [[%{"actor" => "user:1"}, "insert", ["r", "1"], _]] = audit(c)
  end
end
