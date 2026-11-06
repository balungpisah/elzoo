# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableLog.Postgres.Migration do
  @moduledoc "DDL invoked from a consumer-owned Ecto migration."
  use Ecto.Migration

  def up do
    create table(:elzoo_log_heads, primary_key: false) do
      add(:stream, :text, primary_key: true)
      add(:revision, :bigint, null: false)
      add(:low_water, :bigint, null: false, default: 0)
      add(:last_retention_nonce, :binary)
      add(:last_retention_digest, :binary)
      add(:last_retention_expected, :bigint)
      add(:last_retention_through, :bigint)
    end

    create(
      constraint(:elzoo_log_heads, :elzoo_head_bounds,
        check: "revision >= 0 AND low_water >= 0 AND low_water <= revision"
      )
    )

    create table(:elzoo_log_records, primary_key: false) do
      add(:stream, :text, primary_key: true)
      add(:sequence, :bigint, primary_key: true)
      add(:kind, :text, null: false)
      add(:schema_version, :integer, null: false)
      add(:payload, :binary, null: false)
      add(:nonce, :binary, null: false)
      add(:digest, :binary, null: false)
    end

    create(
      constraint(:elzoo_log_records, :elzoo_record_bounds,
        check:
          "sequence > 0 AND schema_version > 0 AND octet_length(nonce) = 16 AND octet_length(digest) = 32"
      )
    )

    create table(:elzoo_outbox, primary_key: false) do
      add(:stream, :text, primary_key: true)
      add(:sequence, :bigint, primary_key: true)
      add(:position, :integer, primary_key: true)
      add(:destination, :text, null: false)
      add(:payload, :binary, null: false)
      add(:nonce, :binary, null: false)
      add(:digest, :binary, null: false)
      add(:state, :text, null: false)
      add(:ack_nonce, :binary)
      add(:ack_digest, :binary)
    end

    create(
      constraint(:elzoo_outbox, :elzoo_outbox_bounds,
        check:
          "sequence > 0 AND position > 0 AND state IN ('pending', 'acked') AND octet_length(nonce) = 16 AND octet_length(digest) = 32"
      )
    )

    schema = Elzoo.DurableLog.Postgres.identifier(prefix() || "public")

    execute(
      "ALTER TABLE #{schema}.elzoo_outbox ADD CONSTRAINT elzoo_outbox_record_fk FOREIGN KEY (stream, sequence) REFERENCES #{schema}.elzoo_log_records (stream, sequence) ON DELETE NO ACTION"
    )

    create table(:elzoo_checkpoints, primary_key: false) do
      add(:stream, :text, primary_key: true)
      add(:sequence, :bigint, primary_key: true)
      add(:fold_version, :integer, primary_key: true)
      add(:model, :binary, null: false)
      add(:cursor, :binary, null: false)
      add(:seen, :binary, null: false)
      add(:nonce, :binary, null: false)
      add(:digest, :binary, null: false)
    end

    create(
      constraint(:elzoo_checkpoints, :elzoo_checkpoint_bounds,
        check:
          "sequence >= 0 AND fold_version > 0 AND octet_length(nonce) = 16 AND octet_length(digest) = 32"
      )
    )
  end

  def down do
    drop(table(:elzoo_checkpoints))
    drop(table(:elzoo_outbox))
    drop(table(:elzoo_log_records))
    drop(table(:elzoo_log_heads))
  end
end
