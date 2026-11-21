# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DeadLetterStore.Migration do
  @moduledoc """
  DDL for a consumer-owned Ecto migration (call it from `up/0` as the table owner; nothing here
  is reversible).

  `install/1` installs the `state/tenant-isolation` readers in the existing schema `prefix`,
  creates `elzoo_dead_letters` there and protects it with the tenant floor
  (`space_column: nil`). The prefix must match `^[a-z_][a-z0-9_]{0,62}$` and is quoted;
  anything else raises `ArgumentError` with a fixed message before any DDL is queued.
  """
  import Ecto.Migration, only: [execute: 1]
  alias Elzoo.TenantIsolation

  @message "invalid dead letter store prefix or options"
  @table "elzoo_dead_letters"

  @doc "Install the readers, the table, its index and the tenant floor in schema `prefix`."
  def install(prefix) do
    p = prefix!(prefix)
    TenantIsolation.Migration.install(prefix)

    # The record is its canonical JSON text, not jsonb, so the stored bytes are the bytes put/3
    # compares. A resolved row carries all three resolution fields; an open row none.
    execute("""
    CREATE TABLE #{p}.#{@table} (
      tenant text NOT NULL,
      source text NOT NULL,
      message_id text NOT NULL,
      record text NOT NULL,
      work_ref bytea,
      put_at_ms bigint NOT NULL,
      state text NOT NULL CHECK (state IN ('open', 'resolved')),
      resolution text,
      actor_ref text,
      resolved_at_ms bigint,
      PRIMARY KEY (tenant, source, message_id),
      CHECK ((state = 'open') = (resolution IS NULL)),
      CHECK ((resolution IS NULL) = (actor_ref IS NULL)),
      CHECK ((resolution IS NULL) = (resolved_at_ms IS NULL))
    )
    """)

    # list/3 reads the open records of one source in (put_at_ms, message_id bytes) order.
    execute(
      ~s|CREATE INDEX elzoo_dead_letters_open ON #{p}.#{@table} (tenant, source, state, put_at_ms, message_id COLLATE "C")|
    )

    TenantIsolation.Migration.protect({prefix, @table},
      prefix: prefix,
      tenant_column: "tenant",
      space_column: nil
    )
  end

  @doc false
  # The quoted schema name, shared with Elzoo.DeadLetterStore.new/1.
  def prefix!(prefix) do
    if is_binary(prefix) and prefix =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/,
      do: ~s("#{prefix}"),
      else: raise(ArgumentError, @message)
  end

  @doc false
  def message, do: @message
end
