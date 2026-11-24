# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.OauthClient.Migration do
  @moduledoc """
  DDL of the OAuth connections for a consumer-owned Ecto migration: call `install/1` from
  `up/0` as the table owner. Nothing here is reversible.

  `install(prefix)` installs the `state/tenant-isolation` readers in `prefix`, creates the
  connection and authorization-attempt tables in the existing schema `prefix` and protects each
  with the tenant floor (`space_column: nil`). `prefix` must match `^[a-z_][a-z0-9_]{0,62}$`;
  anything else raises `ArgumentError` with one fixed message before any DDL.
  """
  import Ecto.Migration, only: [execute: 1]
  alias Elzoo.TenantIsolation.Migration, as: Floor

  @tables ~w(elzoo_oauth_connections elzoo_oauth_attempts)

  @doc "Install the readers, create the two tables in `prefix` and protect each."
  def install(prefix) do
    p = Elzoo.OauthClient.prefix!(prefix)
    Floor.install(prefix)

    # The tokens are Elzoo.Encryption envelopes only; obtained_at_ms is the clock before the
    # exchange that made the access token.
    execute("""
    CREATE TABLE #{p}.elzoo_oauth_connections (
      tenant text NOT NULL,
      connection_id text NOT NULL,
      provider_id text NOT NULL,
      grant_type text NOT NULL CHECK (grant_type IN ('authorization_code', 'client_credentials')),
      scopes text[] NOT NULL,
      state text NOT NULL CHECK (state IN ('pending', 'active', 'reauthorization_required', 'revoked')),
      access_token bytea,
      refresh_token bytea,
      obtained_at_ms bigint,
      expires_at_ms bigint,
      revision bigint NOT NULL CHECK (revision >= 1),
      PRIMARY KEY (tenant, connection_id)
    )
    """)

    # One row per begin_authorization/3: the state only as its SHA-256, the PKCE verifier sealed.
    execute("""
    CREATE TABLE #{p}.elzoo_oauth_attempts (
      tenant text NOT NULL,
      state_digest bytea NOT NULL CHECK (octet_length(state_digest) = 32),
      connection_id text NOT NULL,
      scopes text[] NOT NULL,
      verifier bytea NOT NULL,
      expires_at_ms bigint NOT NULL,
      used boolean NOT NULL DEFAULT false,
      PRIMARY KEY (tenant, state_digest)
    )
    """)

    execute(
      "CREATE INDEX elzoo_oauth_attempts_connection ON #{p}.elzoo_oauth_attempts (tenant, connection_id)"
    )

    for table <- @tables,
        do:
          Floor.protect({prefix, table}, prefix: prefix, tenant_column: "tenant", space_column: nil)

    :ok
  end
end
