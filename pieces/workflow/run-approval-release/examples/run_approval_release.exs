# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RunApprovalRelease.Example do
  @moduledoc """
  Host-owned call sequence, not an engine or cross-stream transaction. Before
  calling, retain the exact request/action/resource descriptor correlation and
  serialize cancellation, currentness and dispatch. Supply the exact descriptor's
  host-activated EffectIntent owner in dispatch_command; never also call Run's
  dispatch_approved for this action. Resource rechecks lifetime/FIFO and retains
  its reservation before advancing that owner. A release is not a send permit.
  """
  def release_then_dispatch(run_owner, release_command, resource_owner, dispatch_command) do
    key = release_command.request_key

    with {:ok, _, %{approval: :released, request_key: ^key}} <-
           Elzoo.RunApprovalRelease.command(run_owner, release_command) do
      Elzoo.RunResource.command(resource_owner, dispatch_command)
    end
  end

  def complete(owner, evidence_ref) do
    {:ok, snapshot} = Elzoo.RunApprovalRelease.status(owner, "run")

    Elzoo.RunApprovalRelease.command(owner, %{
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
