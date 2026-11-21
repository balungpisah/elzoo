# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Journal.Migration do
  @moduledoc """
  DDL of the journal for a consumer-owned Ecto migration: call `install/1` from `up/0` as the
  table owner. Nothing here is reversible.

  `install(prefix)` installs the `state/tenant-isolation` readers in `prefix`, creates the three
  journal tables in the existing schema `prefix` and protects each with the tenant floor
  (`space_column: nil`). `prefix` must match `^[a-z_][a-z0-9_]{0,62}$` (the tenant-isolation
  identifier rule); anything else raises `ArgumentError` with one fixed message before any DDL.
  """
  import Ecto.Migration, only: [execute: 1]
  alias Elzoo.TenantIsolation.Migration, as: Floor

  @tables ~w(elzoo_journal_accounts elzoo_journal_operations elzoo_journal_postings)

  @doc "Install the readers, create the tables in `prefix` and protect each."
  def install(prefix) do
    p = Elzoo.Journal.prefix!(prefix)
    Floor.install(prefix)

    # Account identity is (tenant, account_id); the currency identity and the flag never change.
    execute("""
    CREATE TABLE #{p}.elzoo_journal_accounts (
      tenant text NOT NULL,
      account_id text NOT NULL,
      currency_alpha text NOT NULL,
      currency_numeric integer NOT NULL,
      currency_minor_unit integer NOT NULL,
      allow_negative boolean NOT NULL,
      balance numeric(38,0) NOT NULL,
      version bigint NOT NULL CHECK (version >= 0),
      PRIMARY KEY (tenant, account_id)
    )
    """)

    execute("""
    CREATE TABLE #{p}.elzoo_journal_operations (
      tenant text NOT NULL,
      operation_id text NOT NULL,
      actor_ref text NOT NULL,
      reason text NOT NULL,
      reverses text,
      request_digest bytea NOT NULL CHECK (octet_length(request_digest) = 32),
      CONSTRAINT elzoo_journal_operations_identity UNIQUE (tenant, operation_id),
      CONSTRAINT elzoo_journal_operations_reverses UNIQUE (tenant, reverses)
    )
    """)

    execute("""
    CREATE TABLE #{p}.elzoo_journal_postings (
      tenant text NOT NULL,
      operation_id text NOT NULL,
      account_id text NOT NULL,
      minor_units numeric(38,0) NOT NULL CHECK (minor_units <> 0),
      version bigint NOT NULL CHECK (version >= 1),
      balance numeric(38,0) NOT NULL,
      PRIMARY KEY (tenant, account_id, version),
      FOREIGN KEY (tenant, operation_id)
        REFERENCES #{p}.elzoo_journal_operations (tenant, operation_id),
      FOREIGN KEY (tenant, account_id)
        REFERENCES #{p}.elzoo_journal_accounts (tenant, account_id)
    )
    """)

    # reverse/3 reads the postings of one operation.
    execute(
      "CREATE INDEX elzoo_journal_postings_operation ON #{p}.elzoo_journal_postings (tenant, operation_id)"
    )

    for table <- @tables,
        do:
          Floor.protect({prefix, table}, prefix: prefix, tenant_column: "tenant", space_column: nil)

    :ok
  end
end
