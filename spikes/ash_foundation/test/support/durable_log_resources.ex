# SPDX-License-Identifier: Apache-2.0
defmodule ElzooAshSpike.LogRepo do
  use AshPostgres.Repo, otp_app: :elzoo_ash_spike, warn_on_missing_ash_functions?: false
  def installed_extensions, do: []
  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
end

defmodule ElzooAshSpike.LogHead do
  use Ash.Resource, domain: ElzooAshSpike.LogComparison, data_layer: AshPostgres.DataLayer

  postgres do
    repo(ElzooAshSpike.LogRepo)
    table("elzoo_log_heads")
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    attribute(:stream, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:revision, :integer, allow_nil?: false)
    attribute(:low_water, :integer, allow_nil?: false, default: 0)
    attribute(:last_retention_nonce, :binary)
    attribute(:last_retention_digest, :binary)
    attribute(:last_retention_expected, :integer)
    attribute(:last_retention_through, :integer)
  end

  actions do
    defaults([:read, create: [:stream, :revision, :low_water]])

    update :advance do
      require_atomic?(false)
      accept([])
      argument(:target, :integer, allow_nil?: false)

      change(fn cs, _ ->
        cs
        |> Ash.Changeset.filter(revision: cs.data.revision)
        |> Ash.Changeset.force_change_attribute(
          :revision,
          Ash.Changeset.get_argument(cs, :target)
        )
      end)
    end

    update :retain do
      require_atomic?(false)

      accept([
        :low_water,
        :last_retention_nonce,
        :last_retention_digest,
        :last_retention_expected,
        :last_retention_through
      ])

      change(fn cs, _ -> Ash.Changeset.filter(cs, low_water: cs.data.low_water) end)
    end
  end
end

defmodule ElzooAshSpike.LogRecord do
  use Ash.Resource, domain: ElzooAshSpike.LogComparison, data_layer: AshPostgres.DataLayer

  postgres do
    repo(ElzooAshSpike.LogRepo)
    table("elzoo_log_records")
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    attribute(:stream, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:sequence, :integer, primary_key?: true, allow_nil?: false)
    attribute(:kind, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
    attribute(:schema_version, :integer, allow_nil?: false)
    attribute(:payload, :binary, allow_nil?: false)
    attribute(:nonce, :binary, allow_nil?: false)
    attribute(:digest, :binary, allow_nil?: false)
  end

  actions do
    defaults([
      :read,
      :destroy,
      create: [:stream, :sequence, :kind, :schema_version, :payload, :nonce, :digest]
    ])
  end
end

defmodule ElzooAshSpike.LogItem do
  use Ash.Resource, domain: ElzooAshSpike.LogComparison, data_layer: AshPostgres.DataLayer

  postgres do
    repo(ElzooAshSpike.LogRepo)
    table("elzoo_outbox")
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    attribute(:stream, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:sequence, :integer, primary_key?: true, allow_nil?: false)
    attribute(:position, :integer, primary_key?: true, allow_nil?: false)
    attribute(:destination, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:payload, :binary, allow_nil?: false)
    attribute(:nonce, :binary, allow_nil?: false)
    attribute(:digest, :binary, allow_nil?: false)
    attribute(:state, :string, allow_nil?: false)
    attribute(:ack_nonce, :binary)
    attribute(:ack_digest, :binary)
  end

  actions do
    defaults([
      :read,
      :destroy,
      create: [:stream, :sequence, :position, :destination, :payload, :nonce, :digest, :state]
    ])

    update :ack do
      require_atomic?(false)
      accept([:ack_nonce, :ack_digest])
      change(set_attribute(:state, "acked"))
      change(fn cs, _ -> Ash.Changeset.filter(cs, state: "pending") end)
    end
  end
end

defmodule ElzooAshSpike.LogCheckpoint do
  use Ash.Resource, domain: ElzooAshSpike.LogComparison, data_layer: AshPostgres.DataLayer

  postgres do
    repo(ElzooAshSpike.LogRepo)
    table("elzoo_checkpoints")
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    attribute(:stream, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:sequence, :integer, primary_key?: true, allow_nil?: false)
    attribute(:fold_version, :integer, primary_key?: true, allow_nil?: false)
    attribute(:model, :binary, allow_nil?: false)
    attribute(:cursor, :binary, allow_nil?: false)
    attribute(:seen, :binary, allow_nil?: false)
    attribute(:nonce, :binary, allow_nil?: false)
    attribute(:digest, :binary, allow_nil?: false)
  end

  actions do
    defaults([
      :read,
      create: [:stream, :sequence, :fold_version, :model, :cursor, :seen, :nonce, :digest]
    ])
  end
end

defmodule ElzooAshSpike.LogComparison do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(ElzooAshSpike.LogHead)
    resource(ElzooAshSpike.LogRecord)
    resource(ElzooAshSpike.LogItem)
    resource(ElzooAshSpike.LogCheckpoint)
  end
end
