# SPDX-License-Identifier: Apache-2.0
defmodule ElzooAshSpike.WorkItem do
  @moduledoc "Tenant-scoped work intent with a deliberately volatile, sequential contract."
  use Ash.Resource,
    domain: ElzooAshSpike.Work,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  attributes do
    uuid_primary_key(:id)
    attribute(:tenant_id, :string, allow_nil?: false)
    attribute(:title, :string, allow_nil?: false, public?: true)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:tenant_id)
  end

  state_machine do
    initial_states([:pending])
    default_initial_state(:pending)

    transitions do
      transition(:complete, from: :pending, to: :completed)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:title])
      validate(string_length(:title, min: 1, max: 200))
    end

    update :complete do
      # ETS is not transactional. This spike tests sequential transitions only.
      require_atomic?(false)
      accept([])
      change(transition_state(:completed))
    end
  end

  policies do
    policy always() do
      authorize_if(actor_present())
    end

    policy action_type([:read, :update]) do
      authorize_if(expr(tenant_id == ^actor(:tenant_id)))
    end

    policy action_type(:create) do
      access_type(:strict)
      authorize_if(expr(^tenant() == ^actor(:tenant_id)))
    end

    policy action_type([:read, :create]) do
      authorize_if(always())
    end

    policy action(:complete) do
      authorize_if(actor_attribute_equals(:role, :worker))
    end
  end
end
