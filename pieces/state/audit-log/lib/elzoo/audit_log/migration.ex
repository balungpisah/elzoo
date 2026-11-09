# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AuditLog.Migration do
  @moduledoc """
  DDL invoked from a consumer-owned Ecto migration, run by the audit owner role.

  Options: `store_prefix` (schema of the ready Store tables, default `"public"`),
  `carbonite_prefix` (required; schema of the audit tables) and `excluded_columns`
  (default `["payload", "nonce"]`; a subset of `kind schema_version payload nonce digest`;
  `stream` and `sequence` identify the record and cannot be excluded). Both prefixes are
  lower-case SQL identifiers. Run the migration without a migrator `prefix:` or with
  `prefix:` equal to `carbonite_prefix` (Carbonite's own migrations create tables there).

  Installs Carbonite 0.17.0 migrations 1..12, Carbonite's capture trigger on
  `elzoo_log_records` (primary key `stream, sequence`, the excluded columns), the Elzoo
  attribution trigger, both trigger functions `SECURITY DEFINER` with
  `search_path = pg_catalog, pg_temp`, and revokes every PUBLIC privilege on the audit schema.
  Grants to the application role are the consumer's (README). `down/1` removes both triggers,
  the attribution function and Carbonite's objects; the audit schema itself is retained because
  it can contain the Ecto migrator's own `schema_migrations` table.
  """
  use Ecto.Migration

  @columns ~w(kind schema_version payload nonce digest)
  @setting "elzoo_audit.attribution"
  @definer "SECURITY DEFINER SET search_path = pg_catalog, pg_temp"

  def up(opts \\ []) do
    {store, carbonite, excluded} = options!(opts)
    Carbonite.Migrations.up(1..12, carbonite_prefix: carbonite)

    Carbonite.Migrations.create_trigger(:elzoo_log_records,
      table_prefix: store,
      carbonite_prefix: carbonite
    )

    trigger_options = [table_prefix: store, carbonite_prefix: carbonite]

    Carbonite.Migrations.put_trigger_config(
      :elzoo_log_records,
      :primary_key_columns,
      ["stream", "sequence"],
      trigger_options
    )

    Carbonite.Migrations.put_trigger_config(
      :elzoo_log_records,
      :excluded_columns,
      excluded,
      trigger_options
    )

    execute(attribution_function(carbonite))

    execute("""
    CREATE TRIGGER elzoo_audit_attribution BEFORE INSERT OR UPDATE OR DELETE
    ON "#{store}"."elzoo_log_records" FOR EACH ROW EXECUTE FUNCTION #{carbonite}.elzoo_attribute()
    """)

    secure(carbonite)
  end

  @doc """
  Re-applies `SECURITY DEFINER` and the fixed `search_path` to both trigger functions and the
  PUBLIC revocations. Call it after any later Carbonite migration: Carbonite recreates
  `capture_changes()` with `CREATE OR REPLACE`, which resets those attributes.
  """
  def secure(carbonite) do
    :ok = Elzoo.AuditLog.identifier(carbonite) |> ok!("carbonite_prefix")
    execute("ALTER FUNCTION #{carbonite}.capture_changes() #{@definer}")
    execute("ALTER FUNCTION #{carbonite}.elzoo_attribute() #{@definer}")
    execute("REVOKE ALL ON SCHEMA #{carbonite} FROM PUBLIC")
    execute("REVOKE ALL ON ALL TABLES IN SCHEMA #{carbonite} FROM PUBLIC")
    execute("REVOKE ALL ON ALL SEQUENCES IN SCHEMA #{carbonite} FROM PUBLIC")
    execute("REVOKE ALL ON ALL FUNCTIONS IN SCHEMA #{carbonite} FROM PUBLIC")
  end

  def down(opts \\ []) do
    {store, carbonite, _} = options!(opts)
    execute(~s(DROP TRIGGER elzoo_audit_attribution ON "#{store}"."elzoo_log_records"))
    execute("DROP FUNCTION #{carbonite}.elzoo_attribute()")

    Carbonite.Migrations.drop_trigger(:elzoo_log_records,
      table_prefix: store,
      carbonite_prefix: carbonite
    )

    # The audit schema is retained: it can contain the Ecto migrator's own schema_migrations
    # table, which Carbonite's schema drop would remove under the migrator's lock.
    Carbonite.Migrations.down(12..1//-1, carbonite_prefix: carbonite, drop_schema: false)
  end

  @doc false
  def options!(opts) do
    store = Keyword.get(opts, :store_prefix, "public")
    carbonite = Keyword.get(opts, :carbonite_prefix)
    excluded = Keyword.get(opts, :excluded_columns, ["payload", "nonce"])
    :ok = Elzoo.AuditLog.identifier(store) |> ok!("store_prefix")
    :ok = Elzoo.AuditLog.identifier(carbonite) |> ok!("carbonite_prefix")

    if store == carbonite, do: raise(ArgumentError, "store_prefix and carbonite_prefix must differ")

    unless is_list(excluded) and excluded == Enum.uniq(excluded) and
             Enum.all?(excluded, &(&1 in @columns)),
           do:
             raise(
               ArgumentError,
               "excluded_columns must be distinct names from #{Enum.join(@columns, ", ")}"
             )

    {store, carbonite, excluded}
  end

  defp ok!(:ok, _), do: :ok
  defp ok!(_, name), do: raise(ArgumentError, "#{name} must be a lower-case SQL identifier")

  # The session setting covers one operation on one stream: an append's exact record digests
  # or a retention's `through`. A residue of the setting therefore cannot attribute any other
  # record. Records are insert-only, so UPDATE is refused.
  defp attribution_function(carbonite) do
    """
    CREATE FUNCTION #{carbonite}.elzoo_attribute() RETURNS TRIGGER #{@definer} AS $$
    DECLARE a jsonb;
    BEGIN
      IF NULLIF(current_setting('#{carbonite}.override_mode', TRUE), '') IS NOT NULL THEN
        RAISE 'elzoo audit: override_mode refused' USING ERRCODE = 'insufficient_privilege';
      END IF;
      a := NULLIF(current_setting('#{@setting}', TRUE), '')::jsonb;
      IF a IS NULL THEN
        RAISE 'elzoo audit: attribution missing' USING ERRCODE = 'insufficient_privilege';
      END IF;
      IF TG_OP = 'INSERT' THEN
        IF a->>'op' IS DISTINCT FROM 'append' OR a->>'stream' IS DISTINCT FROM NEW.stream
           OR jsonb_typeof(a->'digests') IS DISTINCT FROM 'array'
           OR NOT (a->'digests') ? encode(NEW.digest, 'hex') THEN
          RAISE 'elzoo audit: attribution does not cover this record' USING ERRCODE = 'insufficient_privilege';
        END IF;
      ELSIF TG_OP = 'DELETE' THEN
        IF a->>'op' IS DISTINCT FROM 'retain' OR a->>'stream' IS DISTINCT FROM OLD.stream
           OR jsonb_typeof(a->'through') IS DISTINCT FROM 'number'
           OR OLD.sequence > (a->>'through')::numeric THEN
          RAISE 'elzoo audit: attribution does not cover this deletion' USING ERRCODE = 'insufficient_privilege';
        END IF;
      ELSE
        RAISE 'elzoo audit: % refused on an audited table', TG_OP USING ERRCODE = 'insufficient_privilege';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM #{carbonite}.transactions WHERE xact_id = pg_current_xact_id()) THEN
        INSERT INTO #{carbonite}.transactions (meta, inserted_at)
        VALUES (jsonb_build_object('actor', a->'actor', 'action', a->'action', 'reason', a->'reason'),
                now() AT TIME ZONE 'UTC');
      END IF;
      RETURN COALESCE(NEW, OLD);
    END $$ LANGUAGE plpgsql
    """
  end
end
