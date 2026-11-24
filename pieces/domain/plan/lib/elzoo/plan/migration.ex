# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Plan.Migration do
  @moduledoc """
  DDL of the subscriptions for a consumer-owned Ecto migration: call `install/1` from `up/0` as
  the table owner. Nothing here is reversible.

  `install(prefix)` installs the `state/tenant-isolation` readers in `prefix`, creates the table
  `elzoo_plan_subscriptions` in the existing schema `prefix` and protects it with the tenant
  floor (`space_column: nil`). `prefix` must match `^[a-z_][a-z0-9_]{0,62}$` (the
  tenant-isolation identifier rule); anything else raises `ArgumentError` with one fixed message
  before any DDL.
  """
  import Ecto.Migration, only: [execute: 1]
  alias Elzoo.TenantIsolation.Migration, as: Floor

  @table "elzoo_plan_subscriptions"

  @doc "Install the readers, create the table in `prefix` and protect it."
  def install(prefix) do
    p = Elzoo.Plan.prefix!(prefix)
    Floor.install(prefix)

    # One row per subscription. The created_* columns keep the create request, from which the
    # first result is rebuilt for a duplicate create. renewed_from is the from_index of the
    # renewal that made the current period (NULL when create made it). last_cancel_* hold the
    # result of the cancel that committed last: the revoked grant IDs and times, and whether it
    # withdrew the current period's fee line (NULL when no cancel committed).
    execute("""
    CREATE TABLE #{p}.#{@table} (
      tenant text NOT NULL,
      subscription_id text NOT NULL,
      interval text NOT NULL CHECK (interval IN ('month', 'year')),
      anchor_ms bigint NOT NULL CHECK (anchor_ms >= 0),
      created_plan_id text NOT NULL,
      created_version integer NOT NULL CHECK (created_version >= 1),
      created_fee bytea NOT NULL,
      start_ms bigint NOT NULL CHECK (start_ms >= 0),
      trial_end_ms bigint CHECK (trial_end_ms > start_ms),
      plan_id text NOT NULL,
      version integer NOT NULL CHECK (version >= 1),
      fee bytea NOT NULL,
      state text NOT NULL CHECK (state IN ('trialing', 'active', 'past_due', 'canceled')),
      period_index bigint NOT NULL CHECK (period_index >= 0),
      period_start_ms bigint NOT NULL CHECK (period_start_ms >= 0),
      period_end_ms bigint NOT NULL CHECK (period_end_ms > period_start_ms),
      cancel_at_period_end boolean NOT NULL,
      cancel_ms bigint,
      pending_plan_id text,
      pending_version integer,
      pending_fee bytea,
      renewed_from bigint,
      revision bigint NOT NULL CHECK (revision >= 1),
      last_cancel_grant_ids text[],
      last_cancel_revoked_at bigint[],
      last_cancel_withdrawn boolean,
      PRIMARY KEY (tenant, subscription_id)
    )
    """)

    # One subscription per tenant that is not canceled.
    execute("""
    CREATE UNIQUE INDEX elzoo_plan_one_open ON #{p}.#{@table} (tenant) WHERE state <> 'canceled'
    """)

    Floor.protect({prefix, @table}, prefix: prefix, tenant_column: "tenant", space_column: nil)
    :ok
  end
end
