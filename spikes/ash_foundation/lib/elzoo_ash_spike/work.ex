# SPDX-License-Identifier: Apache-2.0
defmodule ElzooAshSpike.Work do
  @moduledoc "Isolated foundation experiment; not a published Elzoo Piece."
  use Ash.Domain, extensions: [AshAi]

  resources do
    resource(ElzooAshSpike.WorkItem)
  end

  tools do
    tool(:list_work, ElzooAshSpike.WorkItem, :read)
    tool(:create_work, ElzooAshSpike.WorkItem, :create)
    tool(:complete_work, ElzooAshSpike.WorkItem, :complete)
  end
end
