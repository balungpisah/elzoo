# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.WorkItem.Migration do
  @moduledoc """
  DDL for a consumer-owned Ecto migration, run by the table owner (call it from `up/0`;
  nothing here is reversible).

  `install/1` installs the `state/tenant-isolation` readers in the existing schema `prefix`,
  creates `elzoo_work_items` there and protects it with the tenant floor
  (`space_column: nil`). `prefix` must match `^[a-z_][a-z0-9_]{0,62}$`; anything else raises
  `ArgumentError` with a fixed message before any DDL is queued.
  """
  import Ecto.Migration, only: [execute: 1]
  alias Elzoo.TenantIsolation.Migration, as: Floor

  @message "invalid work item repo or prefix"
  @table "elzoo_work_items"

  @doc "Install the readers, the item table and its tenant floor in schema `prefix`."
  def install(prefix) do
    p = prefix!(prefix)
    Floor.install(prefix)

    # IDs compare by bytes (COLLATE "C"). The intent's content and the evidence are bytea:
    # valid UTF-8 may hold U+0000, which text refuses, and the evidence is opaque bytes.
    # digest is the SHA-256 of the item's canonical bytes (README "Canonical bytes").
    execute("""
    CREATE TABLE #{p}.#{@table} (
      tenant text COLLATE "C" NOT NULL,
      item_id text COLLATE "C" NOT NULL,
      parent_run_id text COLLATE "C" NOT NULL,
      child_run_id text COLLATE "C" NOT NULL,
      owner text COLLATE "C" NOT NULL,
      schema_id text NOT NULL,
      schema_version integer NOT NULL,
      sources text[] NOT NULL,
      trust text NOT NULL,
      max_bytes integer NOT NULL,
      content bytea NOT NULL,
      acceptance text NOT NULL,
      parent_close text NOT NULL,
      state text NOT NULL,
      revision integer NOT NULL,
      evidence bytea,
      decided_by text COLLATE "C",
      digest bytea NOT NULL,
      PRIMARY KEY (tenant, item_id),
      UNIQUE (tenant, child_run_id)
    )
    """)

    # The non-final items of one parent Run in item_id order (list_open/3 names the same
    # predicate, so the planner can use this partial index).
    execute("""
    CREATE INDEX elzoo_work_items_open
      ON #{p}.#{@table} (tenant, parent_run_id, item_id)
      WHERE state IN ('open', 'running', 'offered', 'cancel_requested')
    """)

    Floor.protect({prefix, @table}, prefix: prefix, tenant_column: "tenant", space_column: nil)
    :ok
  end

  @doc false
  # The quoted schema name; prefix?/1, message/0 and table/0 are shared with Elzoo.WorkItem.
  def prefix!(prefix) do
    if prefix?(prefix), do: ~s("#{prefix}"), else: raise(ArgumentError, @message)
  end

  @doc false
  def prefix?(prefix), do: is_binary(prefix) and prefix =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/

  @doc false
  def message, do: @message

  @doc false
  def table, do: @table
end
