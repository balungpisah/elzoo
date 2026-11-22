# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.KnowledgeIngest.Migration do
  @moduledoc """
  DDL for a consumer-owned Ecto migration, run by the table owner (call it from `up/0`;
  nothing here is reversible).

  `install/1` installs the `state/tenant-isolation` readers in the existing schema `prefix`,
  creates the four Piece tables there (`elzoo_knowledge_ingests`, `elzoo_knowledge_batches`,
  `elzoo_knowledge_attempts` and `elzoo_knowledge_chunks`) and protects each with the tenant
  floor (`tenant_column: "tenant"`, `space_column: nil`). `prefix` must match
  `^[a-z_][a-z0-9_]{0,62}$`; anything else raises `ArgumentError` with a fixed message before
  any DDL is queued.
  """
  import Ecto.Migration, only: [execute: 1]
  alias Elzoo.TenantIsolation.Migration, as: Floor

  @message "invalid knowledge ingest prefix"
  @tables [
    "elzoo_knowledge_ingests",
    "elzoo_knowledge_batches",
    "elzoo_knowledge_attempts",
    "elzoo_knowledge_chunks"
  ]

  @doc "Install the readers, the four tables and their tenant floors in schema `prefix`."
  def install(prefix) do
    p = prefix!(prefix)
    Floor.install(prefix)

    # One row per ingest identity (tenant, ingest_id). reason, parser: deterministic ETF.
    execute("""
    CREATE TABLE #{p}.elzoo_knowledge_ingests (
      tenant text NOT NULL,
      ingest_id text NOT NULL,
      source_ref text NOT NULL,
      version integer NOT NULL,
      request_digest bytea NOT NULL,
      index_identity text NOT NULL,
      actor text NOT NULL,
      artifact_id text NOT NULL,
      artifact_version bigint NOT NULL,
      media_type text NOT NULL,
      chunk_size integer NOT NULL,
      chunk_overlap integer NOT NULL,
      max_chunks integer NOT NULL,
      state text NOT NULL,
      reason bytea,
      failed_step text,
      job_key text,
      jobs integer NOT NULL,
      text_sha256 bytea,
      parser bytea,
      chunk_count integer NOT NULL,
      batch_count integer NOT NULL,
      batches_done integer NOT NULL,
      PRIMARY KEY (tenant, ingest_id)
    )
    """)

    # budget_base: the attempt number at the last resubmit/3 (0 since submit).
    execute("""
    CREATE TABLE #{p}.elzoo_knowledge_batches (
      tenant text NOT NULL,
      ingest_id text NOT NULL,
      batch integer NOT NULL,
      first_chunk integer NOT NULL,
      chunk_count integer NOT NULL,
      completed boolean NOT NULL,
      budget_base integer NOT NULL,
      PRIMARY KEY (tenant, ingest_id, batch),
      FOREIGN KEY (tenant, ingest_id) REFERENCES #{p}.elzoo_knowledge_ingests (tenant, ingest_id)
    )
    """)

    # outcome and usage: deterministic ETF.
    execute("""
    CREATE TABLE #{p}.elzoo_knowledge_attempts (
      tenant text NOT NULL,
      ingest_id text NOT NULL,
      batch integer NOT NULL,
      number integer NOT NULL,
      outcome bytea NOT NULL,
      usage bytea,
      PRIMARY KEY (tenant, ingest_id, batch, number),
      FOREIGN KEY (tenant, ingest_id, batch)
        REFERENCES #{p}.elzoo_knowledge_batches (tenant, ingest_id, batch)
    )
    """)

    # embedding: deterministic ETF of %{index, vector, descriptor, provenance}.
    execute("""
    CREATE TABLE #{p}.elzoo_knowledge_chunks (
      tenant text NOT NULL,
      ingest_id text NOT NULL,
      chunk_index integer NOT NULL,
      start_byte bigint NOT NULL,
      end_byte bigint NOT NULL,
      content bytea NOT NULL,
      content_digest bytea NOT NULL,
      embedding bytea,
      PRIMARY KEY (tenant, ingest_id, chunk_index),
      FOREIGN KEY (tenant, ingest_id) REFERENCES #{p}.elzoo_knowledge_ingests (tenant, ingest_id)
    )
    """)

    for table <- @tables,
        do:
          Floor.protect({prefix, table}, prefix: prefix, tenant_column: "tenant", space_column: nil)

    :ok
  end

  @doc false
  def tables, do: @tables

  @doc false
  def prefix!(prefix) do
    if prefix?(prefix), do: ~s("#{prefix}"), else: raise(ArgumentError, @message)
  end

  @doc false
  def prefix?(prefix), do: is_binary(prefix) and prefix =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/
end
