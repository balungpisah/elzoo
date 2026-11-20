# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RetentionErasure.Migration do
  @moduledoc """
  DDL for a consumer-owned Ecto migration (call it from `up/0`; nothing here is reversible).

  `install/1` creates `elzoo_vault_subjects`, `elzoo_vault_keys` and `elzoo_vault_entries` in the
  existing schema `prefix`. The prefix must match `^[a-z_][a-z0-9_]{0,62}$` and is quoted;
  anything else raises `ArgumentError` with a fixed message before any DDL is queued.
  """
  import Ecto.Migration, only: [execute: 1]

  @message "invalid retention erasure prefix or options"

  @doc "Create the three vault tables in schema `prefix`."
  def install(prefix) do
    p = prefix!(prefix)

    execute("""
    CREATE TABLE #{p}.elzoo_vault_subjects (
      subject text PRIMARY KEY,
      state text NOT NULL CHECK (state IN ('active', 'erased')),
      erased_at bigint
    )
    """)

    execute("""
    CREATE TABLE #{p}.elzoo_vault_keys (
      subject text NOT NULL REFERENCES #{p}.elzoo_vault_subjects (subject),
      version bigint NOT NULL,
      wrapped bytea NOT NULL,
      PRIMARY KEY (subject, version)
    )
    """)

    execute("""
    CREATE TABLE #{p}.elzoo_vault_entries (
      ref text PRIMARY KEY,
      subject text NOT NULL REFERENCES #{p}.elzoo_vault_subjects (subject),
      key_version bigint NOT NULL,
      envelope bytea NOT NULL
    )
    """)

    # erase/2 deletes a subject's entries by subject.
    execute("CREATE INDEX elzoo_vault_entries_subject ON #{p}.elzoo_vault_entries (subject)")
  end

  @doc false
  # The quoted schema name, shared with Elzoo.RetentionErasure.vault/1.
  def prefix!(prefix) do
    if is_binary(prefix) and prefix =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/,
      do: ~s("#{prefix}"),
      else: raise(ArgumentError, @message)
  end

  @doc false
  def message, do: @message
end
