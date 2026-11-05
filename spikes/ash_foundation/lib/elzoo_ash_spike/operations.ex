# SPDX-License-Identifier: Apache-2.0
defmodule ElzooAshSpike.Operations do
  @moduledoc "Shared direct/tool authority boundary for the volatile operational experiment."
  use Ash.Resource, domain: ElzooAshSpike.Work, authorizers: [Ash.Policy.Authorizer]

  actions do
    action :snapshot, :map do
      run(&__MODULE__.execute/2)
    end

    action :configure, :map do
      argument(:expected_revision, :integer, allow_nil?: false, constraints: [min: 0])
      argument(:limit, :integer, allow_nil?: false, constraints: [min: 1, max: 64])
      run(&__MODULE__.execute/2)
    end

    for command <- [:pause, :drain, :resume] do
      action command, :map do
        argument(:expected_revision, :integer, allow_nil?: false, constraints: [min: 0])
        run(&__MODULE__.execute/2)
      end
    end

    for command <- [:admit, :finish] do
      action command, :map do
        argument(:work_id, :string,
          allow_nil?: false,
          constraints: [min_length: 1, max_length: 64, length_count: :bytes]
        )

        run(&__MODULE__.execute/2)
      end
    end
  end

  policies do
    policy always() do
      authorize_if(actor_present())
    end

    policy always() do
      access_type(:strict)
      authorize_if(expr(^tenant() == ^actor(:tenant_id)))
    end

    policy action(:snapshot) do
      authorize_if(actor_attribute_equals(:role, :viewer))
      authorize_if(actor_attribute_equals(:role, :worker))
      authorize_if(actor_attribute_equals(:role, :operator))
    end

    policy action([:configure, :pause, :drain, :resume]) do
      authorize_if(actor_attribute_equals(:role, :operator))
    end

    policy action([:admit, :finish]) do
      authorize_if(actor_attribute_equals(:role, :worker))
    end
  end

  def execute(input, context) do
    server = Map.fetch!(input.context, :controller)

    case ElzooAshSpike.AdmissionServer.command(
           server,
           context.tenant,
           input.action.name,
           input.arguments
         ) do
      {:ok, snapshot} -> {:ok, %{status: "applied", state: snapshot}}
      {:error, reason} -> {:error, Atom.to_string(reason)}
    end
  end
end
