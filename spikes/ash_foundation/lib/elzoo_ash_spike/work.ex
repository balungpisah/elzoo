# SPDX-License-Identifier: Apache-2.0
defmodule ElzooAshSpike.Work do
  @moduledoc "Isolated foundation experiment; not a published Elzoo Piece."
  use Ash.Domain, extensions: [AshAi]

  resources do
    resource(ElzooAshSpike.WorkItem)
    resource(ElzooAshSpike.Operations)
  end

  tools do
    tool(:list_work, ElzooAshSpike.WorkItem, :read)
    tool(:create_work, ElzooAshSpike.WorkItem, :create)
    tool(:complete_work, ElzooAshSpike.WorkItem, :complete)
    tool(:inspect_admission, ElzooAshSpike.Operations, :snapshot)
    tool(:configure_admission, ElzooAshSpike.Operations, :configure)
    tool(:pause_admission, ElzooAshSpike.Operations, :pause)
    tool(:drain_admission, ElzooAshSpike.Operations, :drain)
    tool(:resume_admission, ElzooAshSpike.Operations, :resume)
  end
end
