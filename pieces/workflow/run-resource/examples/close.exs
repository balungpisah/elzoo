# SPDX-License-Identifier: Apache-2.0
# The host supplies the owner and recorded time. Closing a never-opened resource
# releases its reservation without asking a provider to create anything.
fn owner, run_id, at_ms ->
  {:ok, ended} =
    Elzoo.PatternStep.decode(%{
      "type" => "input",
      "version" => 1,
      "kind" => "run_ended",
      "at_ms" => at_ms,
      "schema_id" => "elzoo.run-resource.run-ended",
      "schema_version" => 1,
      "payload" => %{"run_id" => run_id, "outcome" => %{"host_outcome" => "done"}}
    })

  Elzoo.RunResource.command(owner, %{id: "run-ended", at_ms: at_ms, body: {:input, ended}})
end
