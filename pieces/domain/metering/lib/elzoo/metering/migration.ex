# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Metering.Migration do
  @moduledoc """
  DDL for a consumer-owned Ecto migration, run by the table owner (call it from `up/0`;
  nothing here is reversible).

  `install/1` installs the `state/tenant-isolation` readers in the existing schema `prefix`,
  creates `elzoo_metering_observations` and `elzoo_metering_corrections` there and protects
  each with the tenant floor (`space_column: nil`). `prefix` must match
  `^[a-z_][a-z0-9_]{0,62}$`; anything else raises `ArgumentError` with a fixed message before
  any DDL is queued.
  """
  import Ecto.Migration, only: [execute: 1]
  alias Elzoo.TenantIsolation.Migration, as: Floor

  @message "invalid metering repo or prefix"
  @tables ["elzoo_metering_observations", "elzoo_metering_corrections"]

  @doc "Install the readers, both tables and their tenant floors in schema `prefix`."
  def install(prefix) do
    p = prefix!(prefix)
    Floor.install(prefix)

    # amount is the recorded amount and effective the current one; NULL is unknown.
    # revision counts the corrections; corrections carry the revision they set.
    execute("""
    CREATE TABLE #{p}.elzoo_metering_observations (
      tenant text NOT NULL,
      usage_id text NOT NULL,
      run_id text NOT NULL,
      operation_id text NOT NULL,
      attempt_id text NOT NULL,
      provider_id text NOT NULL,
      model_id text NOT NULL,
      unit text NOT NULL,
      amount bigint,
      source text NOT NULL,
      period text NOT NULL,
      observed_at_ms bigint NOT NULL,
      digest bytea NOT NULL,
      effective bigint,
      revision integer NOT NULL,
      PRIMARY KEY (tenant, usage_id)
    )
    """)

    execute("""
    CREATE INDEX elzoo_metering_observations_period
      ON #{p}.elzoo_metering_observations (tenant, period, unit, source)
    """)

    execute("""
    CREATE TABLE #{p}.elzoo_metering_corrections (
      tenant text NOT NULL,
      correction_id text NOT NULL,
      usage_id text NOT NULL,
      revision integer NOT NULL,
      amount bigint,
      reason text NOT NULL,
      actor_ref text NOT NULL,
      digest bytea NOT NULL,
      PRIMARY KEY (tenant, correction_id),
      UNIQUE (tenant, usage_id, revision),
      FOREIGN KEY (tenant, usage_id) REFERENCES #{p}.elzoo_metering_observations (tenant, usage_id)
    )
    """)

    for table <- @tables,
        do:
          Floor.protect({prefix, table}, prefix: prefix, tenant_column: "tenant", space_column: nil)

    :ok
  end

  @doc false
  # The quoted schema name; prefix?/1 and message/0 are shared with Elzoo.Metering.
  def prefix!(prefix) do
    if prefix?(prefix), do: ~s("#{prefix}"), else: raise(ArgumentError, @message)
  end

  @doc false
  def prefix?(prefix), do: is_binary(prefix) and prefix =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/

  @doc false
  def message, do: @message
end
