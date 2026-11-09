# SPDX-License-Identifier: Apache-2.0
# ELZ-055 provider comparison probe P2: ash_paper_trail 0.8.1 against the ready integration/sql
# Store append path. Runs in a scratch Mix project outside the repository (ash 3.37.3,
# ash_postgres 2.15.2, ash_paper_trail 0.8.1, ecto_sql 3.14.0, postgrex 0.22.4) with the compiled
# Elzoo Store modules on the code path (ELZOO_PROBE_EBINS, prepended in test_helper.exs) and the
# same fail-closed target guard. Scratch project files used (verbatim):
#   mix.exs deps: {:ash, "== 3.37.3"}, {:ash_postgres, "== 2.15.2"}, {:ash_paper_trail, "== 0.8.1"},
#     {:ecto_sql, "== 3.14.0", override: true}, {:postgrex, "== 0.22.4", override: true},
#     {:jason, "== 1.4.5", override: true}; lock seeded from spikes/ash_foundation (spark 2.7.9,
#     ash_sql 0.8.8, reactor 1.0.7)
#   config/config.exs: config :ash, default_string_length_count: :codepoints
#                      config :apt_probe, ash_domains: [AptProbe.Domain]
#   test/test_helper.exs: prepend each ELZOO_PROBE_EBINS directory, then ExUnit.start()
defmodule AptProbe.Repo do
  use AshPostgres.Repo, otp_app: :apt_probe, warn_on_missing_ash_functions?: false
  def installed_extensions, do: []
  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
end

defmodule AptProbe.StoreMigration do
  use Ecto.Migration
  def up, do: Elzoo.DurableLog.Postgres.Migration.up()
  def down, do: :ok
end

defmodule AptProbe.Record do
  use Ash.Resource,
    domain: AptProbe.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "elzoo_log_records"
    schema "ash_paper_trail_probe"
    repo AptProbe.Repo
  end

  paper_trail do
    change_tracking_mode :snapshot
    store_action_name? true
    # the generated Version resource does not inherit the source schema; its table lives in
    # public under a probe-only name, created and dropped by the test (refused if present)
    table_name "elzoo_apt_probe_versions"
  end

  attributes do
    attribute :stream, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :sequence, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :kind, :string, allow_nil?: false, public?: true
    attribute :schema_version, :integer, allow_nil?: false, public?: true
    attribute :payload, :binary, allow_nil?: false, public?: true
    attribute :nonce, :binary, allow_nil?: false, public?: true
    attribute :digest, :binary, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:stream, :sequence, :kind, :schema_version, :payload, :nonce, :digest]
    end
  end
end

defmodule AptProbe.Domain do
  use Ash.Domain, extensions: [AshPaperTrail.Domain], validate_config_inclusion?: false

  paper_trail do
    include_versions? true
  end

  resources do
    resource AptProbe.Record
  end
end

defmodule AptProbe.Test do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL
  alias AptProbe.{Repo, Record}
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.Postgres
  alias Elzoo.DurableLog.Record, as: StoreRecord
  @schema "ash_paper_trail_probe"

  defp fold,
    do: %{
      initial: 0,
      kinds: %{"e" => :state_bearing},
      versions: [1],
      destinations: [],
      reduce: fn n, _, _, _ -> n + 1 end
    }

  setup_all do
    url = System.fetch_env!("ELZOO_TEST_DATABASE_URL")
    expected = System.get_env("ELZOO_AUDIT_EXPECTED_DB") || raise("expected database not named")
    if URI.parse(url).path != "/" <> expected, do: raise("wrong configured target database")
    {:ok, pid} = Repo.start_link(url: url, pool_size: 4, log: false)
    Process.unlink(pid)
    [[name]] = SQL.query!(Repo, "SELECT current_database()", []).rows
    if name != expected, do: raise("wrong effective database")

    [[exists]] =
      SQL.query!(Repo, "SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = $1)", [@schema]).rows

    if exists, do: raise("probe schema already exists; refusing to touch it")
    SQL.query!(Repo, "CREATE SCHEMA #{@schema}", [])
    on_exit(fn -> SQL.query!(Repo, "DROP SCHEMA #{@schema} CASCADE", []) end)
    :ok = Ecto.Migrator.up(Repo, 1, AptProbe.StoreMigration, prefix: @schema, log: false)

    columns =
      for a <- Ash.Resource.Info.attributes(Record.Version) do
        type =
          case a.type do
            Ash.Type.UUID -> "uuid"
            Ash.Type.UUIDv7 -> "uuid"
            Ash.Type.String -> "text"
            Ash.Type.Atom -> "text"
            Ash.Type.Integer -> "bigint"
            Ash.Type.Map -> "jsonb"
            Ash.Type.Binary -> "bytea"
            Ash.Type.UtcDatetimeUsec -> "timestamp"
            Ash.Type.UtcDatetime -> "timestamp"
            other -> raise "unmapped #{inspect(other)}"
          end

        "#{a.name} #{type}" <> if(a.primary_key?, do: " PRIMARY KEY", else: "")
      end

    table = AshPostgres.DataLayer.Info.table(Record.Version)
    if table != "elzoo_apt_probe_versions", do: raise("unexpected version table")
    SQL.query!(Repo, "CREATE TABLE public.#{table} (#{Enum.join(columns, ", ")})", [])
    on_exit(fn -> SQL.query!(Repo, "DROP TABLE public.#{table}", []) end)
    %{versions: "public.#{table}", columns: columns}
  end

  defp versions(c), do: hd(hd(SQL.query!(Repo, "SELECT count(*) FROM #{c.versions}", []).rows))

  defp row(stream, seq, digest \\ nil) do
    r = %StoreRecord{
      stream: stream,
      sequence: seq,
      kind: "e",
      schema_version: 1,
      payload: "p#{seq}",
      nonce: :crypto.strong_rand_bytes(16)
    }

    %{r | digest: digest || Log.digest(r)}
  end

  test "P2 AshPaperTrail sees Ash actions only; an Ash action bypasses the Store path", c do
    IO.puts("P2 version table: #{c.versions} (#{Enum.join(c.columns, ", ")})")
    store = Postgres.store(Repo, prefix: @schema, fold: fold(), limits: %{max_record_bytes: 64, max_batch_size: 8, max_checkpoint_bytes: 10_000})
    {mod, _} = store

    # (a) the ready Store append commits a record; AshPaperTrail records no version
    assert {:committed, 1} = mod.append(store, "store", 0, [row("store", 1)], [])
    assert versions(c) == 0
    assert [%{stream: "store", sequence: 1}] = Ash.read!(Record)

    # (b) an Ash create action yields a version ...
    bad = row("ash", 1, <<0::256>>)

    Ash.create!(Record, Map.take(Map.from_struct(bad), [:stream, :sequence, :kind, :schema_version, :payload, :nonce, :digest]))

    assert versions(c) == 1
    # ... but takes no part in the Store's head CAS/revision and digest checks:
    # no head row was written, a wrong digest was accepted ...
    assert {:ok, %{revision: 0}} = mod.head(store, "ash")
    # ... a later Store append at the expected revision collides with the Ash-written row ...
    assert {:conflict, %{expected: 0, observed: :unknown}} = mod.append(store, "ash", 0, [row("ash", 1)], [])
    # ... and replay through the Store sees the Ash-written row as damaged input
    {:ok, rows, _} = mod.read(store, "ash", 1, 10)
    assert [%{sequence: 1}] = rows
    snapshot = Log.replay(rows, 1, fold())
    assert {0, true, [{:corrupt, 1, :digest_mismatch}]} = snapshot.cursor
  end
end
