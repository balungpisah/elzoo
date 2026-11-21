# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Quota.Migration do
  @moduledoc """
  DDL of the quota for a consumer-owned Ecto migration: call `install/1` from `up/0` as the
  table owner. Nothing here is reversible.

  `install(prefix)` installs the `state/tenant-isolation` readers in `prefix`, creates the three
  quota tables in the existing schema `prefix` and protects each with the tenant floor
  (`space_column: nil`). `prefix` must match `^[a-z_][a-z0-9_]{0,62}$` (the tenant-isolation
  identifier rule); anything else raises `ArgumentError` with one fixed message before any DDL.
  """
  import Ecto.Migration, only: [execute: 1]
  alias Elzoo.TenantIsolation.Migration, as: Floor

  @tables ~w(elzoo_quota_counters elzoo_quota_reservations elzoo_quota_units)

  @doc "Install the readers, create the tables in `prefix` and protect each."
  def install(prefix) do
    p = Elzoo.Quota.prefix!(prefix)
    Floor.install(prefix)

    # One allowance counter per (tenant, window, unit); the amount is not stored.
    execute("""
    CREATE TABLE #{p}.elzoo_quota_counters (
      tenant text NOT NULL,
      window_tag text NOT NULL,
      window_id text NOT NULL,
      unit text NOT NULL,
      committed numeric(38,0) NOT NULL CHECK (committed >= 0),
      held numeric(38,0) NOT NULL CHECK (held >= 0),
      reserved numeric(38,0) NOT NULL CHECK (reserved >= 0),
      PRIMARY KEY (tenant, window_tag, window_id, unit)
    )
    """)

    execute("""
    CREATE TABLE #{p}.elzoo_quota_reservations (
      tenant text NOT NULL,
      run_id text NOT NULL,
      window_tag text NOT NULL,
      window_id text NOT NULL,
      expiry_ms bigint NOT NULL CHECK (expiry_ms >= 0),
      request_digest bytea NOT NULL CHECK (octet_length(request_digest) = 32),
      state text NOT NULL CHECK (state IN ('open', 'released', 'settled')),
      PRIMARY KEY (tenant, run_id)
    )
    """)

    # One row per reserved unit, written once with its reservation row, so the reservation key
    # decides its uniqueness. actual is NULL while the unit is open or held; settled_unknown
    # marks a settlement of :unknown, kept after the reconciliation that sets actual and basis.
    execute("""
    CREATE TABLE #{p}.elzoo_quota_units (
      tenant text NOT NULL,
      run_id text NOT NULL,
      unit text NOT NULL,
      estimate numeric(38,0) NOT NULL CHECK (estimate > 0),
      settled_unknown boolean NOT NULL DEFAULT false,
      actual numeric(38,0) CHECK (actual >= 0),
      basis text CHECK (basis IN ('metering', 'write_off')),
      actor_ref text,
      reason text,
      FOREIGN KEY (tenant, run_id) REFERENCES #{p}.elzoo_quota_reservations (tenant, run_id)
    )
    """)

    execute("CREATE INDEX elzoo_quota_units_run ON #{p}.elzoo_quota_units (tenant, run_id, unit)")

    for table <- @tables,
        do:
          Floor.protect({prefix, table}, prefix: prefix, tenant_column: "tenant", space_column: nil)

    :ok
  end
end
