# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PaymentLifecycle.Migration do
  @moduledoc """
  DDL of the payment lifecycle for a consumer-owned Ecto migration: call `install/1` from
  `up/0` as the table owner. Nothing here is reversible.

  `install(prefix)` installs the `state/tenant-isolation` readers in `prefix`, creates the four
  tables in the existing schema `prefix` and protects each with the tenant floor
  (`space_column: nil`). `prefix` must match `^[a-z_][a-z0-9_]{0,62}$`; anything else raises
  `ArgumentError` with one fixed message before any DDL.
  """
  import Ecto.Migration, only: [execute: 1]
  alias Elzoo.TenantIsolation.Migration, as: Floor

  @doc "Install the readers, create the four tables in `prefix` and protect each."
  def install(prefix) do
    p = Elzoo.PaymentLifecycle.prefix!(prefix)
    Floor.install(prefix)

    # Amounts are their domain/money Codec bytes. deadline is the intent deadline fixed by the
    # first charge/3, so a later charge/3 returns the same admission.
    execute("""
    CREATE TABLE #{p}.elzoo_payment_payments (
      tenant text NOT NULL,
      payment_id text NOT NULL,
      amount text NOT NULL,
      recipient text NOT NULL,
      approval_ref text NOT NULL,
      approval_digest bytea NOT NULL CHECK (octet_length(approval_digest) = 32),
      state text NOT NULL CHECK (state IN ('created', 'pending', 'unknown', 'succeeded', 'failed')),
      provider_ref text,
      revision bigint NOT NULL CHECK (revision >= 1),
      deadline bigint CHECK (deadline >= 0),
      PRIMARY KEY (tenant, payment_id)
    )
    """)

    # requested is 'remaining' or the Codec bytes of the explicit amount; amount is the amount
    # fixed at refund/3.
    execute("""
    CREATE TABLE #{p}.elzoo_payment_refunds (
      tenant text NOT NULL,
      payment_id text NOT NULL,
      refund_id text NOT NULL,
      requested text NOT NULL,
      amount text NOT NULL,
      state text NOT NULL CHECK (state IN ('pending', 'unknown', 'succeeded', 'failed')),
      provider_ref text,
      deadline bigint NOT NULL CHECK (deadline >= 0),
      PRIMARY KEY (tenant, payment_id, refund_id),
      FOREIGN KEY (tenant, payment_id) REFERENCES #{p}.elzoo_payment_payments (tenant, payment_id)
    )
    """)

    # body is the canonical bytes of the verified event; payment_id is not a foreign key, so an
    # event for an unknown payment is stored with applied false.
    execute("""
    CREATE TABLE #{p}.elzoo_payment_events (
      tenant text NOT NULL,
      event_id text NOT NULL,
      payment_id text NOT NULL,
      body bytea NOT NULL,
      applied boolean NOT NULL,
      PRIMARY KEY (tenant, event_id)
    )
    """)

    # One row per provider answer the Adapter received, in order; only applied changes.
    execute("""
    CREATE TABLE #{p}.elzoo_payment_observations (
      tenant text NOT NULL,
      payment_id text NOT NULL,
      operation_ref text NOT NULL,
      seq integer NOT NULL CHECK (seq >= 1),
      attempt integer NOT NULL CHECK (attempt >= 1),
      source text NOT NULL CHECK (source IN ('send', 'poll')),
      answer text NOT NULL CHECK (answer IN ('ok', 'declined', 'not_sent', 'unknown', 'no_effect', 'pending', 'unavailable')),
      state text CHECK (state IN ('succeeded', 'pending', 'failed')),
      provider_ref text,
      detail text,
      applied boolean NOT NULL DEFAULT false,
      PRIMARY KEY (tenant, payment_id, operation_ref, seq),
      FOREIGN KEY (tenant, payment_id) REFERENCES #{p}.elzoo_payment_payments (tenant, payment_id)
    )
    """)

    for table <- Elzoo.PaymentLifecycle.tables(),
        do:
          Floor.protect({prefix, table}, prefix: prefix, tenant_column: "tenant", space_column: nil)

    :ok
  end
end
