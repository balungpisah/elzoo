# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Run.Example do
  @moduledoc "A host calls completion only after retaining correlated evidence in its Store."
  def complete(owner, evidence_ref) do
    {:ok, snapshot} = Elzoo.Run.status(owner, "run")

    Elzoo.Run.command(owner, %{
      kind: :complete,
      run_id: "run",
      expected_revision: snapshot.revision,
      attempt_id: snapshot.current_attempt,
      outcome: :completed,
      reason: nil,
      evidence_ref: evidence_ref
    })
  end
end
