# SPDX-License-Identifier: Apache-2.0
alias Elzoo.{PatternStep, TypedDecision}

{:ok, state} =
  TypedDecision.new(%{
    id: "route-1",
    request: %{
      "version" => 1,
      "model" => "example-model",
      "max_output_tokens" => 64,
      "messages" => [%{"role" => "user", "text" => "Is this a billing question?"}]
    },
    port: %{
      "id" => "route",
      "direction" => "output",
      "schema_id" => "example/route",
      "schema_version" => 1
    },
    answer: {:set, ["billing", "other"]},
    repairs: 1
  })

input = fn kind, fields ->
  Map.merge(%{"type" => "input", "version" => 1, "kind" => kind, "at_ms" => 0}, fields)
end

completed = fn call, content, structured ->
  input.("action_outcome", %{
    "action_id" => call,
    "outcome" => "completed",
    "schema_id" => "elzoo.ai-text.result",
    "schema_version" => 1,
    "payload" => %{"content" => content, "structured" => structured, "finish" => "stop"}
  })
end

start = input.("start", %{"schema_id" => "example/start", "schema_version" => 1, "payload" => nil})

{:Transition, state, {:some, call0}} = TypedDecision.step(state, start)
{:ok, _} = PatternStep.decode(call0)

# "Billing" is not a member: one repair request.
{:Transition, state, {:some, call1}} =
  TypedDecision.step(
    state,
    completed.("route-1:call:0", ~s({"answer":"Billing"}), %{"invalid" => "schema_mismatch"})
  )

[%{"id" => "route-1:call:1", "payload" => %{"messages" => [_, _, repair]}}] = call1["actions"]

{:Transition, _closed, {:some, finish}} =
  TypedDecision.step(
    state,
    completed.("route-1:call:1", ~s({"answer":"billing"}), %{"valid" => %{"answer" => "billing"}})
  )

[%{"payload" => result}] = finish["actions"]
{repair["text"], result}
