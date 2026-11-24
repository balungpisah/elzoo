# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.WebhookOut.Migration do
  @moduledoc """
  DDL for a consumer-owned Ecto migration (call it from `up/0` as the table owner; nothing here
  is reversible).

  `install/1` installs the `state/tenant-isolation` readers in the existing schema `prefix` and
  creates four tables there, each protected with the tenant floor (`space_column: nil`):
  endpoints, events, deliveries and observations. The prefix must match
  `^[a-z_][a-z0-9_]{0,62}$` and is quoted; anything else raises `ArgumentError` with a fixed
  message before any DDL is queued.
  """
  import Ecto.Migration, only: [execute: 1]
  alias Elzoo.TenantIsolation

  @message "invalid webhook-out prefix"
  @tables ~w(elzoo_webhook_endpoints elzoo_webhook_events elzoo_webhook_deliveries elzoo_webhook_observations)

  @doc "Install the readers, the four tables, their indexes and the tenant floor in `prefix`."
  def install(prefix) do
    p = prefix!(prefix)
    TenantIsolation.Migration.install(prefix)

    # The Secrets reference is opaque bytes (integration/secrets), so bytea. `events` is sorted.
    execute("""
    CREATE TABLE #{p}.elzoo_webhook_endpoints (
      tenant text NOT NULL,
      endpoint_id text NOT NULL,
      url text NOT NULL,
      secret_ref bytea NOT NULL,
      secret_scope bytea NOT NULL,
      events text[] NOT NULL,
      dedup boolean NOT NULL,
      PRIMARY KEY (tenant, endpoint_id)
    )
    """)

    execute("""
    CREATE TABLE #{p}.elzoo_webhook_events (
      tenant text NOT NULL,
      event_id text NOT NULL,
      name text NOT NULL,
      payload text NOT NULL,
      payload_sha256 text NOT NULL,
      PRIMARY KEY (tenant, event_id)
    )
    """)

    # One row per (event, endpoint). `try_deadline_ms` is fixed at the try's first claim;
    # `not_sent` counts the applied not-sent results of the current try; `attempts` counts every
    # applied result of the delivery; the last-result triple is the current try's. A
    # dead-lettered row keeps the record's inputs: dl_reason, attempts, the triple and dl_at_ms.
    execute("""
    CREATE TABLE #{p}.elzoo_webhook_deliveries (
      tenant text NOT NULL,
      delivery_id text NOT NULL,
      event_id text NOT NULL,
      endpoint_id text NOT NULL,
      payload_sha256 text NOT NULL,
      state text NOT NULL CHECK (state IN ('pending', 'delivered', 'dead_lettered')),
      try integer NOT NULL CHECK (try BETWEEN 1 AND 16),
      due_at_ms bigint NOT NULL,
      claimed_until_ms bigint,
      try_deadline_ms bigint,
      rearm boolean NOT NULL,
      not_sent integer NOT NULL,
      attempts integer NOT NULL,
      last_outcome text,
      last_dispatch text,
      last_error_class text,
      dead_letter text NOT NULL CHECK (dead_letter IN ('none', 'pending', 'filed')),
      dl_reason text,
      dl_at_ms bigint,
      PRIMARY KEY (tenant, delivery_id),
      UNIQUE (tenant, event_id, endpoint_id),
      CHECK ((dead_letter = 'none') = (dl_reason IS NULL)),
      CHECK ((dl_reason IS NULL) = (dl_at_ms IS NULL)),
      CHECK ((dead_letter = 'none') OR (state = 'dead_lettered'))
    )
    """)

    # claim_due/3 reads due pending rows in (due_at_ms, delivery_id bytes) order.
    execute(
      ~s|CREATE INDEX elzoo_webhook_deliveries_due ON #{p}.elzoo_webhook_deliveries (tenant, due_at_ms, delivery_id COLLATE "C") WHERE state = 'pending'|
    )

    # file_dead_letters/3 reads pending dead letters oldest first.
    execute(
      ~s|CREATE INDEX elzoo_webhook_deliveries_dead_letter ON #{p}.elzoo_webhook_deliveries (tenant, dl_at_ms, delivery_id COLLATE "C") WHERE dead_letter = 'pending'|
    )

    # The typed result of one send, and whether record/3 has applied it.
    execute("""
    CREATE TABLE #{p}.elzoo_webhook_observations (
      tenant text NOT NULL,
      delivery_id text NOT NULL,
      try integer NOT NULL,
      attempt integer NOT NULL,
      result text NOT NULL,
      applied boolean NOT NULL,
      PRIMARY KEY (tenant, delivery_id, try, attempt)
    )
    """)

    for table <- @tables do
      TenantIsolation.Migration.protect({prefix, table},
        prefix: prefix,
        tenant_column: "tenant",
        space_column: nil
      )
    end
  end

  @doc false
  def tables, do: @tables

  @doc false
  # The quoted schema name, shared with Elzoo.WebhookOut.new/1.
  def prefix!(prefix) do
    if identifier?(prefix), do: ~s("#{prefix}"), else: raise(ArgumentError, @message)
  end

  @doc false
  def identifier?(prefix), do: is_binary(prefix) and prefix =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/
end
