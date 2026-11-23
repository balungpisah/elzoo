# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableMailbox.Migration do
  @moduledoc """
  DDL for a consumer-owned Ecto migration, run by the table owner (call it from `up/0`;
  nothing here is reversible).

  `install/1` installs the `state/tenant-isolation` readers in the existing schema `prefix`,
  creates `elzoo_mailbox_chains`, `elzoo_mailbox_links` and `elzoo_mailbox_messages` there and
  protects each with the tenant floor (`space_column: nil`). `prefix` must match
  `^[a-z_][a-z0-9_]{0,62}$`; anything else raises `ArgumentError` with a fixed message before
  any DDL is queued.
  """
  import Ecto.Migration, only: [execute: 1]
  alias Elzoo.TenantIsolation.Migration, as: Floor

  @message "invalid durable mailbox prefix"
  @tables ["elzoo_mailbox_chains", "elzoo_mailbox_links", "elzoo_mailbox_messages"]

  @doc "Install the readers, the three tables and their tenant floors in schema `prefix`."
  def install(prefix) do
    p = prefix!(prefix)
    Floor.install(prefix)

    # tip_seq is the live link; next_message_seq the sequence of the next accepted message.
    execute("""
    CREATE TABLE #{p}.elzoo_mailbox_chains (
      tenant text NOT NULL,
      chain_id text NOT NULL,
      declaration_id text NOT NULL,
      declaration_version integer NOT NULL,
      declaration_sha256 text NOT NULL,
      tip_seq integer NOT NULL,
      next_message_seq bigint NOT NULL,
      PRIMARY KEY (tenant, chain_id)
    )
    """)

    # carry is the canonical JSON text the link's Run starts with; state is live or closed.
    execute("""
    CREATE TABLE #{p}.elzoo_mailbox_links (
      tenant text NOT NULL,
      chain_id text NOT NULL,
      seq integer NOT NULL,
      run_id text NOT NULL,
      unit_identity text NOT NULL,
      predecessor_seq integer,
      pin text NOT NULL,
      planned_pin text,
      carry text NOT NULL,
      carry_kind text NOT NULL,
      state text NOT NULL,
      outcome text,
      change_ref text,
      stopped boolean NOT NULL,
      PRIMARY KEY (tenant, chain_id, seq),
      UNIQUE (tenant, chain_id, predecessor_seq),
      UNIQUE (tenant, run_id),
      UNIQUE (tenant, unit_identity)
    )
    """)

    # payload is canonical JSON text; state is pending, delivering, consumed or refused, and
    # link_seq the link it is delivering to or was settled by.
    execute("""
    CREATE TABLE #{p}.elzoo_mailbox_messages (
      tenant text NOT NULL,
      chain_id text NOT NULL,
      message_id text NOT NULL,
      seq bigint NOT NULL,
      sender_kind text NOT NULL,
      sender_id text NOT NULL,
      name text NOT NULL,
      schema_version integer NOT NULL,
      payload text NOT NULL,
      state text NOT NULL,
      link_seq integer,
      reason text,
      PRIMARY KEY (tenant, chain_id, message_id),
      UNIQUE (tenant, chain_id, seq)
    )
    """)

    # The oldest pending message, the delivering one and the open count of a chain.
    execute("""
    CREATE INDEX elzoo_mailbox_messages_open
      ON #{p}.elzoo_mailbox_messages (tenant, chain_id, seq)
      WHERE state IN ('pending', 'delivering')
    """)

    for table <- @tables,
        do:
          Floor.protect({prefix, table}, prefix: prefix, tenant_column: "tenant", space_column: nil)

    :ok
  end

  @doc false
  # The quoted schema name; prefix?/1 is shared with Elzoo.DurableMailbox.
  def prefix!(prefix) do
    if prefix?(prefix), do: ~s("#{prefix}"), else: raise(ArgumentError, @message)
  end

  @doc false
  def prefix?(prefix), do: is_binary(prefix) and prefix =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/

  @doc false
  def tables, do: @tables
end
