# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Invoice.Migration do
  @moduledoc """
  DDL of the invoices for a consumer-owned Ecto migration: call `install/1` from `up/0` as the
  table owner. Nothing here is reversible.

  `install(prefix)` installs the `state/tenant-isolation` readers in `prefix`, creates the five
  invoice tables in the existing schema `prefix` and protects each with the tenant floor
  (`space_column: nil`). `prefix` must match `^[a-z_][a-z0-9_]{0,62}$` (the tenant-isolation
  identifier rule); anything else raises `ArgumentError` with one fixed message before any DDL.
  """
  import Ecto.Migration, only: [execute: 1]
  alias Elzoo.TenantIsolation.Migration, as: Floor

  @doc "Install the readers, create the tables in `prefix` and protect each."
  def install(prefix) do
    p = Elzoo.Invoice.prefix!(prefix)
    Floor.install(prefix)

    # Amounts are their Elzoo.Money.Codec bytes; currency is the bytes of a zero amount.
    # number is NULL until finalize/3; NULLs are distinct, so drafts never collide.
    execute("""
    CREATE TABLE #{p}.elzoo_invoices (
      tenant text NOT NULL,
      invoice_id text NOT NULL,
      kind text NOT NULL CHECK (kind IN ('invoice', 'credit_note')),
      billing_account text NOT NULL,
      currency text NOT NULL,
      series text NOT NULL,
      number bigint CHECK (number >= 1),
      state text NOT NULL CHECK (state IN ('draft', 'open', 'paid', 'void', 'issued')),
      total text NOT NULL,
      paid text NOT NULL,
      credited text NOT NULL,
      issued_at_ms bigint,
      due_at_ms bigint,
      corrects text,
      operation_id text,
      posting_state text CHECK (posting_state IN ('pending', 'posted')),
      revision bigint NOT NULL CHECK (revision >= 1),
      request_digest bytea NOT NULL CHECK (octet_length(request_digest) = 32),
      PRIMARY KEY (tenant, invoice_id),
      UNIQUE (tenant, series, number)
    )
    """)

    execute("""
    CREATE TABLE #{p}.elzoo_invoice_lines (
      tenant text NOT NULL,
      invoice_id text NOT NULL,
      line_id text NOT NULL,
      position integer NOT NULL CHECK (position BETWEEN 1 AND 256),
      kind text NOT NULL CHECK (kind IN ('usage', 'fee', 'adjustment')),
      description text NOT NULL,
      amount text NOT NULL,
      source_ref text NOT NULL,
      PRIMARY KEY (tenant, invoice_id, line_id)
    )
    """)

    execute("""
    CREATE TABLE #{p}.elzoo_invoice_applications (
      tenant text NOT NULL,
      invoice_id text NOT NULL,
      payment_ref text NOT NULL,
      amount text NOT NULL,
      PRIMARY KEY (tenant, invoice_id, payment_ref)
    )
    """)

    # requested is 'remaining' or the requested amount's bytes; amount is the amount taken back.
    execute("""
    CREATE TABLE #{p}.elzoo_invoice_reversals (
      tenant text NOT NULL,
      invoice_id text NOT NULL,
      reversal_id text NOT NULL,
      payment_ref text NOT NULL,
      requested text NOT NULL,
      amount text NOT NULL,
      PRIMARY KEY (tenant, invoice_id, reversal_id)
    )
    """)

    execute("""
    CREATE TABLE #{p}.elzoo_invoice_series (
      tenant text NOT NULL,
      series text NOT NULL,
      last_number bigint NOT NULL CHECK (last_number >= 0),
      PRIMARY KEY (tenant, series)
    )
    """)

    for table <- Elzoo.Invoice.tables(),
        do:
          Floor.protect({prefix, table}, prefix: prefix, tenant_column: "tenant", space_column: nil)

    :ok
  end
end
