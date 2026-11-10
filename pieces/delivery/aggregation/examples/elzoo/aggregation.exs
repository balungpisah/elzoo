# SPDX-License-Identifier: Apache-2.0
# Bounded correlated join over declared branch results.
# Run from a consumer project that copied this piece and its dependencies:
#   mix run pieces/delivery/aggregation/examples/elzoo/aggregation.exs

alias Elzoo.Aggregation

# Declare the expected branches and the join policy. Identity comes from the
# configured field path — here each result's correlation_id names its branch.
{:ok, join} =
  Aggregation.new(["charge", "receipt", "notify"],
    branch_key: {:field, ["correlation_id"]},
    deadline_unix_ms: System.os_time(:millisecond) + 60_000,
    max_result_bytes: 16_384,
    max_branches: 8
  )

result = fn id, value ->
  %{
    "version" => 1,
    "message_id" => "demo/" <> id,
    "correlation_id" => id,
    "outcome" => "completed",
    "dispatch" => "dispatched",
    "value" => value,
    "value_schema_id" => "demo/result",
    "value_schema_version" => 1
  }
end

# Results may arrive in any order; the join attributes them by identity.
{:ok, join} = Aggregation.accept(join, result.("receipt", %{"amount" => 42}))
{:ok, join} = Aggregation.accept(join, result.("charge", %{"ok" => true}))

{:ok, status} = Aggregation.status(join)
IO.inspect(Map.new(status, fn {id, r} -> {id, r.status} end), label: "branches")

{join, outcome} = Aggregation.decision(join, System.os_time(:millisecond))
IO.inspect(outcome.decision, label: "decision")

# A volatile runner for callers without durable branches: each {id, fun} pair
# runs at most once per runner call under the caller's Task.Supervisor and
# feeds the same join policy; a new runner call may invoke it again.
# "notify" is still pending, so its fun supplies the missing branch result.
{:ok, sup} = Task.Supervisor.start_link(name: DemoBranches)

{:ok, runner} =
  Elzoo.Aggregation.Runner.start_link(
    join: join,
    branches: [{"notify", fn id -> result.(id, %{"sent" => true}) end}],
    task_supervisor: sup
  )

# Wait for the branch, then read the runner's live join state.
Process.sleep(200)

{_join, %{decision: decision}} =
  Elzoo.Aggregation.Runner.decision(runner, System.os_time(:millisecond))

IO.inspect(decision, label: "final decision")
{:ok, live} = Elzoo.Aggregation.Runner.join(runner)
IO.inspect(live.closed, label: "join closed")
