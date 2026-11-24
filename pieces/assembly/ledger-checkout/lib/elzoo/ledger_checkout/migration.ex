# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LedgerCheckout.Migration do
  @moduledoc """
  DDL of the ledger checkout for a consumer-owned Ecto migration: call `install/1` from `up/0`
  as the table owner. Nothing here is reversible.

  `install(prefix)` installs the `state/tenant-isolation` readers in `prefix`, creates the two
  tables in the existing schema `prefix` and protects each with the tenant floor
  (`space_column: nil`). `prefix` must match `^[a-z_][a-z0-9_]{0,62}$`; anything else raises
  `ArgumentError` with one fixed message before any DDL.
  """
  import Ecto.Migration, only: [execute: 1]
  alias Elzoo.TenantIsolation.Migration, as: Floor

  @doc "Install the readers, create the two tables in `prefix` and protect each."
  def install(prefix) do
    p = Elzoo.LedgerCheckout.prefix!(prefix)
    Floor.install(prefix)

    # declaration is the canonical bytes of the open/3 request; failure is the fixed reason of
    # the definite failure that started the compensation.
    execute("""
    CREATE TABLE #{p}.elzoo_checkout_checkouts (
      tenant text NOT NULL,
      checkout_id text NOT NULL,
      kind text NOT NULL CHECK (kind IN ('invoice_payment', 'top_up')),
      declaration bytea NOT NULL,
      state text NOT NULL CHECK (state IN ('running', 'compensating', 'completed', 'compensated', 'needs_operator')),
      failure text,
      revision bigint NOT NULL CHECK (revision >= 1),
      PRIMARY KEY (tenant, checkout_id)
    )
    """)

    # result is the step's recorded result, compensation the canonical bytes of its
    # compensation (written with the result), failure the step's or its compensation's reason.
    execute("""
    CREATE TABLE #{p}.elzoo_checkout_steps (
      tenant text NOT NULL,
      checkout_id text NOT NULL,
      step text NOT NULL CHECK (step IN ('charge', 'invoice', 'settle', 'wallet', 'allowance')),
      position integer NOT NULL CHECK (position >= 1),
      grp integer,
      state text NOT NULL CHECK (state IN ('started', 'succeeded', 'failed', 'compensated', 'compensation_failed')),
      result text,
      compensation bytea,
      failure text,
      revision bigint NOT NULL CHECK (revision >= 1),
      PRIMARY KEY (tenant, checkout_id, step),
      CHECK (CASE state
        WHEN 'started' THEN result IS NULL AND compensation IS NULL AND failure IS NULL
        WHEN 'failed' THEN result IS NULL AND compensation IS NULL AND failure IS NOT NULL
        WHEN 'compensation_failed' THEN result IS NOT NULL AND compensation IS NOT NULL AND failure IS NOT NULL
        ELSE result IS NOT NULL AND compensation IS NOT NULL AND failure IS NULL END),
      FOREIGN KEY (tenant, checkout_id) REFERENCES #{p}.elzoo_checkout_checkouts (tenant, checkout_id)
    )
    """)

    for table <- Elzoo.LedgerCheckout.tables(),
        do:
          Floor.protect({prefix, table}, prefix: prefix, tenant_column: "tenant", space_column: nil)

    :ok
  end
end
