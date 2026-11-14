# SPDX-License-Identifier: Apache-2.0
alias Elzoo.GraphRun

port = fn direction ->
  %{
    "port" => %{
      "id" => direction,
      "direction" => direction,
      "schema_id" => "value",
      "schema_version" => 1
    },
    "schema" => %{"type" => "object"}
  }
end

slot = fn name -> %{"name" => name, "schema_id" => "value", "schema_version" => 1} end

recipe = %{
  "version" => 1,
  "id" => "greeting",
  "revision" => 1,
  "root" => "main",
  "callables" => [
    %{
      "name" => "main",
      "kind" => "graph",
      "input" => port.("input"),
      "output" => port.("output"),
      "input_slots" => [slot.("name")],
      "nodes" => [
        %{
          "id" => "greet",
          "kind" => "call",
          "callable" => "worker",
          "needs" => [slot.("name")],
          "gives" => [slot.("text")]
        },
        %{
          "id" => "shout",
          "kind" => "call",
          "callable" => "worker",
          "needs" => [slot.("text")],
          "gives" => [slot.("loud")]
        }
      ],
      "links" => [
        %{
          "from" => "$input",
          "to" => "greet",
          "kind" => "data",
          "give" => "name",
          "need" => "name"
        },
        %{"from" => "greet", "to" => "shout", "kind" => "data", "give" => "text", "need" => "text"}
      ]
    },
    %{
      "name" => "worker",
      "kind" => "agent",
      "input" => port.("input"),
      "output" => port.("output"),
      "binding" => "model"
    }
  ],
  "bindings" => [%{"name" => "model", "target" => "binding"}],
  "rules" => []
}

input = fn kind, fields ->
  Map.merge(%{"type" => "input", "version" => 1, "kind" => kind, "at_ms" => 1}, fields)
end

result = fn id, text ->
  input.("action_outcome", %{
    "action_id" => id,
    "outcome" => "completed",
    "schema_id" => "elzoo.graph-run.node-result",
    "schema_version" => 1,
    "payload" => %{"gives" => text}
  })
end

{:ok, state} =
  GraphRun.new(%{id: "demo", recipe: recipe, callable: "main", sources: [], maps: %{}, max_open: 4})

start =
  input.("start", %{
    "schema_id" => "elzoo.graph-run.input",
    "schema_version" => 1,
    "payload" => %{"input" => %{"name" => "Ada"}}
  })

{:Transition, state, {:some, first}} = GraphRun.step(state, start)

{:Transition, state, {:some, second}} =
  GraphRun.step(state, result.("demo:n:greet", %{"text" => "hello Ada"}))

{:Transition, state, {:some, last}} =
  GraphRun.step(state, result.("demo:n:shout", %{"loud" => "HELLO ADA"}))

{:ok, state, first, second, last}
