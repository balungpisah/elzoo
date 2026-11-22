# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.MemoryRecord.Migration do
  @moduledoc """
  DDL for a consumer-owned Ecto migration, run by the table owner (call it from `up/0`;
  nothing here is reversible).

  `install/1` installs the `state/tenant-isolation` readers in the existing schema `prefix`,
  creates `elzoo_memory_records` and `elzoo_memory_tombstones` there and protects each with
  the tenant floor (`space_column: nil`). `prefix` must match `^[a-z_][a-z0-9_]{0,62}$`;
  anything else raises `ArgumentError` with a fixed message before any DDL is queued.
  """
  import Ecto.Migration, only: [execute: 1]
  alias Elzoo.TenantIsolation.Migration, as: Floor

  @message "invalid memory record repo or prefix"
  @tables ["elzoo_memory_records", "elzoo_memory_tombstones"]

  @doc "Install the readers, both tables and their tenant floors in schema `prefix`."
  def install(prefix) do
    p = prefix!(prefix)
    Floor.install(prefix)

    # Texts compare by bytes (COLLATE "C"). scope_id is '' for {:tenant}; every other scope
    # ID has 1..128 bytes. content is bytea: valid UTF-8 may hold U+0000, which text refuses.
    execute("""
    CREATE TABLE #{p}.elzoo_memory_records (
      tenant text COLLATE "C" NOT NULL,
      memory_id text COLLATE "C" NOT NULL,
      scope_kind text COLLATE "C" NOT NULL,
      scope_id text COLLATE "C" NOT NULL,
      kind text NOT NULL,
      schema_id text NOT NULL,
      schema_version integer NOT NULL,
      sources text[] NOT NULL,
      trust text NOT NULL,
      max_bytes integer NOT NULL,
      content bytea NOT NULL,
      provenance_kinds text[] NOT NULL,
      provenance_ids text[] NOT NULL,
      written_by text COLLATE "C" NOT NULL,
      writer_kind text NOT NULL,
      written_at_ms bigint NOT NULL,
      expires_at_ms bigint,
      supersedes text COLLATE "C",
      approval_ref text COLLATE "C",
      digest bytea NOT NULL,
      PRIMARY KEY (tenant, memory_id)
    )
    """)

    execute("""
    CREATE INDEX elzoo_memory_records_recall
      ON #{p}.elzoo_memory_records (tenant, scope_kind, scope_id, written_at_ms DESC, memory_id)
    """)

    execute("""
    CREATE INDEX elzoo_memory_records_scope_id
      ON #{p}.elzoo_memory_records (tenant, scope_kind, scope_id, memory_id)
    """)

    execute("""
    CREATE INDEX elzoo_memory_records_supersedes
      ON #{p}.elzoo_memory_records (tenant, supersedes) WHERE supersedes IS NOT NULL
    """)

    # A tombstone keeps no content and no provenance.
    execute("""
    CREATE TABLE #{p}.elzoo_memory_tombstones (
      tenant text COLLATE "C" NOT NULL,
      memory_id text COLLATE "C" NOT NULL,
      scope_kind text COLLATE "C" NOT NULL,
      scope_id text COLLATE "C" NOT NULL,
      supersedes text COLLATE "C",
      forgotten_at_ms bigint NOT NULL,
      actor_ref text COLLATE "C" NOT NULL,
      reason text NOT NULL,
      PRIMARY KEY (tenant, memory_id)
    )
    """)

    execute("""
    CREATE INDEX elzoo_memory_tombstones_scope_id
      ON #{p}.elzoo_memory_tombstones (tenant, scope_kind, scope_id, memory_id)
    """)

    execute("""
    CREATE INDEX elzoo_memory_tombstones_supersedes
      ON #{p}.elzoo_memory_tombstones (tenant, supersedes) WHERE supersedes IS NOT NULL
    """)

    for table <- @tables,
        do:
          Floor.protect({prefix, table}, prefix: prefix, tenant_column: "tenant", space_column: nil)

    :ok
  end

  @doc false
  # The quoted schema name; prefix?/1 and message/0 are shared with Elzoo.MemoryRecord.
  def prefix!(prefix) do
    if prefix?(prefix), do: ~s("#{prefix}"), else: raise(ArgumentError, @message)
  end

  @doc false
  def prefix?(prefix), do: is_binary(prefix) and prefix =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/

  @doc false
  def message, do: @message
end
