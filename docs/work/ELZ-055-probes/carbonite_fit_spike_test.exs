# SPDX-License-Identifier: Apache-2.0
# ELZ-055 provider-fit probe P1 (recorded source; not run by mix check, not a deliverable).
# Ran from pieces/state/audit-log/test/spike/ with {:carbonite, "== 0.17.0"} added to mix.exs,
# ELZOO_TEST_DATABASE_URL set and ELZOO_AUDIT_EXPECTED_DB naming the same database (fail-closed
# target guard). Output is recorded in docs/work/ELZ-055.md.
sql_helper =
  Path.expand("../../../../integration/sql/test/support/durable_log_postgres_test_helper.exs", __DIR__)

Code.require_file(sql_helper)

defmodule Elzoo.AuditSpike.Repo do
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
  alias Elzoo.AuditSpike.Repo

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
    # fail-closed target guard: URL and effective database must both match the named target
    if URI.parse(url).path != "/" <> expected, do: raise("wrong target database")
    {:ok, repo} = Repo.start_link(url: url, pool_size: 6, log: false)
    Process.unlink(repo)
    %{rows: [[name]]} = SQL.query!(Repo, "SELECT current_database()", [], log: false)
    if name != expected, do: raise("wrong effective database")
    :ok
  end

  setup do
    hex = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    prefix = "aud_" <> hex
    carb = "carb_" <> hex
    SQL.query!(Repo, "CREATE SCHEMA #{prefix}", [], log: false)
    :ok = Ecto.Migrator.up(Repo, 1, TestMigration, prefix: prefix, log: false)
    :persistent_term.put(:audit_spike_carb, carb)
    SQL.query!(Repo, "CREATE SCHEMA #{carb}", [], log: false)
    :ok = Ecto.Migrator.up(Repo, 2, Elzoo.AuditSpike.CarbMigration, log: false, prefix: carb)

    run = fn sql -> SQL.query!(Repo, sql, [], log: false) end
    run.("""
    CREATE CONSTRAINT TRIGGER capture_changes_into_#{carb}_trigger
    AFTER INSERT OR UPDATE OR DELETE ON "#{prefix}"."elzoo_log_records"
    DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE PROCEDURE #{carb}.capture_changes()
    """)

    run.("""
    INSERT INTO #{carb}.triggers (id, table_prefix, table_name, primary_key_columns, excluded_columns, inserted_at, updated_at)
    VALUES (NEXTVAL('#{carb}.triggers_id_seq'), '#{prefix}', 'elzoo_log_records', '{stream,sequence}', '{payload,nonce}', NOW(), NOW())
    """)

    run.("""
    CREATE FUNCTION #{carb}.elzoo_attribute() RETURNS TRIGGER AS $$
    DECLARE a jsonb; s text;
    BEGIN
      IF NULLIF(current_setting('#{carb}.override_mode', TRUE), '') IS NOT NULL THEN
        RAISE 'elzoo audit: override_mode refused' USING ERRCODE = 'insufficient_privilege';
      END IF;
      IF EXISTS (SELECT 1 FROM #{carb}.transactions WHERE xact_id = pg_current_xact_id()) THEN
        RETURN COALESCE(NEW, OLD);
      END IF;
      a := NULLIF(current_setting('elzoo_audit.attribution', TRUE), '')::jsonb;
      s := COALESCE(NEW.stream, OLD.stream);
      IF a IS NULL OR a->>'stream' IS DISTINCT FROM s THEN
        RAISE 'elzoo audit: attribution missing' USING ERRCODE = 'insufficient_privilege';
      END IF;
      INSERT INTO #{carb}.transactions (meta, inserted_at) VALUES (a - 'stream', now());
      PERFORM set_config('elzoo_audit.attribution', '', false);
      RETURN COALESCE(NEW, OLD);
    END $$ LANGUAGE plpgsql
    """)

    run.("""
    CREATE TRIGGER elzoo_attribute BEFORE INSERT OR UPDATE OR DELETE ON "#{prefix}"."elzoo_log_records"
    FOR EACH ROW EXECUTE FUNCTION #{carb}.elzoo_attribute()
    """)

    limits = %{max_record_bytes: 64, max_batch_size: 8, max_checkpoint_bytes: 10_000}

    store = Postgres.store(Repo, prefix: prefix, fold: fold(), limits: limits)

    on_exit(fn ->
      SQL.query!(Repo, "DROP SCHEMA #{prefix} CASCADE", [], log: false)
      SQL.query!(Repo, "DROP SCHEMA #{carb} CASCADE", [], log: false)
    end)

    %{store: store, prefix: prefix, carb: carb}
  end

  defp row(stream, seq) do
    r = %Record{
      stream: stream,
      sequence: seq,
      kind: "e",
      schema_version: 1,
      payload: "secret-#{seq}",
      nonce: :crypto.strong_rand_bytes(16)
    }

    %{r | digest: Log.digest(r)}
  end

  defp attributed(attr, stream, fun) do
    Repo.checkout(fn ->
      SQL.query!(Repo, "SELECT set_config('elzoo_audit.attribution', $1, false)", [
        Jason.encode!(Map.put(attr, :stream, stream))
      ])

      try do
        fun.()
      after
        SQL.query!(Repo, "SELECT set_config('elzoo_audit.attribution', '', false)", [])
      end
    end)
  end

  defp audit(c) do
    SQL.query!(
      Repo,
      "SELECT t.meta, ch.op, ch.table_pk, ch.data FROM #{c.carb}.transactions t JOIN #{c.carb}.changes ch ON ch.transaction_id = t.id ORDER BY t.id",
      [],
      log: false
    ).rows
  end

  test "commit pairs, conflict rollback, missing attribution, override, concurrency", c do
    {mod, _} = c.store
    a = %{actor: "user:1", action: "refund.request", reason: "r"}

    assert {:committed, 1} = attributed(a, "s", fn -> mod.append(c.store, "s", 0, [row("s", 1)], []) end)
    assert [[%{"actor" => "user:1"}, "insert", ["s", "1"], data]] = audit(c)
    refute Map.has_key?(data, "payload")
    IO.inspect(data, label: "audit data")

    # conflict -> rollback: no audit
    assert {:conflict, _} = attributed(a, "s", fn -> mod.append(c.store, "s", 0, [row("s", 1)], []) end)
    assert length(audit(c)) == 1

    # missing attribution -> refused by DB, Store reports indeterminate
    r = mod.append(c.store, "s", 1, [row("s", 2)], [])
    IO.inspect(r, label: "unattributed")
    assert length(audit(c)) == 1
    assert {:ok, %{revision: 1}} = mod.head(c.store, "s")

    # wrong stream binding refused
    r = attributed(a, "other", fn -> mod.append(c.store, "s", 1, [row("s", 2)], []) end)
    IO.inspect(r, label: "wrong stream")
    assert {:ok, %{revision: 1}} = mod.head(c.store, "s")

    # override_mode ignore refused
    r =
      attributed(a, "s", fn ->
        SQL.query!(Repo, "SELECT set_config('#{c.carb}.override_mode', 'ignore', false)", [])
        try do
          mod.append(c.store, "s", 1, [row("s", 2)], [])
        after
          SQL.query!(Repo, "SELECT set_config('#{c.carb}.override_mode', '', false)", [])
        end
      end)

    IO.inspect(r, label: "override")
    assert {:ok, %{revision: 1}} = mod.head(c.store, "s")

    # concurrency
    tasks =
      for i <- 1..8 do
        Task.async(fn ->
          st = "c#{i}"
          attributed(%{actor: "user:#{i}", action: "x", reason: "r"}, st, fn ->
            mod.append(c.store, st, 0, [row(st, 1)], [])
          end)
        end)
      end

    assert Enum.all?(Task.await_many(tasks), &match?({:committed, 1}, &1))

    for [m, _, [st, _], _] <- audit(c), String.starts_with?(st, "c") do
      assert m["actor"] == "user:" <> String.trim_leading(st, "c")
    end

    # leaked GUC after commit? new checkout sees none
    Repo.checkout(fn ->
      IO.inspect(SQL.query!(Repo, "SELECT current_setting('elzoo_audit.attribution', true)", []).rows,
        label: "post"
      )
    end)

    # TRUNCATE bypass
    SQL.query!(Repo, "TRUNCATE #{c.prefix}.elzoo_log_records CASCADE", [])
    IO.inspect(length(audit(c)), label: "audit after truncate")
    # owner can disable trigger
    SQL.query!(Repo, "ALTER TABLE #{c.prefix}.elzoo_log_records DISABLE TRIGGER USER", [])
    IO.inspect(SQL.query!(Repo, "SELECT rolsuper, rolcreaterole FROM pg_roles WHERE rolname = current_user", []).rows, label: "role")
  end
end
