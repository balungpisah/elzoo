# SPDX-License-Identifier: Apache-2.0
# A tool with one module call: the run asks for it, its result is recorded, the run completes.
alias Elzoo.{LuaBinding, LuaTool}

manifest = %{
  "name" => "add",
  "version" => 1,
  "description" => "Add one to a number",
  "arguments" => %{
    "port" => %{
      "id" => "add_input",
      "direction" => "input",
      "schema_id" => "elzoo.demo.add",
      "schema_version" => 1
    },
    "schema" => %{
      "type" => "object",
      "properties" => %{"n" => %{"type" => "integer"}},
      "required" => ["n"],
      "additionalProperties" => false
    }
  },
  "result" => %{
    "port" => %{
      "id" => "add_output",
      "direction" => "output",
      "schema_id" => "elzoo.demo.add",
      "schema_version" => 1
    },
    "schema" => %{
      "type" => "object",
      "properties" => %{"n" => %{"type" => "integer"}},
      "required" => ["n"],
      "additionalProperties" => false
    }
  },
  "cost" => %{"unit" => "call", "estimate" => 1},
  "permissions" => []
}

{:ok, bindings} = LuaBinding.resolve([%{"name" => "add", "version" => 1}], [manifest])
{:ok, source} = LuaBinding.source(bindings, "demo_module")

{:ok, state} =
  LuaTool.new(%{
    id: "demo",
    source: "return function(input) return {total = bindings.add({n = input.n}).n + 1} end",
    policy: "demo-policy",
    limits: %{
      "steps" => 10_000,
      "call_depth" => 8,
      "value_bytes" => 1_024,
      "memory_bytes" => 1_048_576,
      "wall_ms" => 500
    },
    bindings: bindings,
    sources: [source],
    source_id: "demo_module",
    max_calls: 4
  })

input = fn kind, fields ->
  Map.merge(%{"type" => "input", "version" => 1, "kind" => kind, "at_ms" => 0}, fields)
end

completed = fn id, schema_id, payload ->
  input.("action_outcome", %{
    "action_id" => id,
    "outcome" => "completed",
    "schema_id" => schema_id,
    "schema_version" => 1,
    "payload" => payload
  })
end

trace = [
  input.("start", %{
    "schema_id" => "elzoo.lua-tool.input",
    "schema_version" => 1,
    "payload" => %{"input" => %{"n" => 1}}
  }),
  completed.("demo:r:1", "elzoo.lua-tool.run-result", %{
    "pending_call" => %{"index" => 0, "name" => "add", "arguments" => %{"n" => 1}}
  }),
  completed.("demo:c:0", "elzoo.lua-tool.module-result", %{"result" => %{"n" => 2}}),
  completed.("demo:r:2", "elzoo.lua-tool.run-result", %{
    "ok" => %{"value" => %{"total" => 3}, "identity" => "demo-policy", "runtime" => %{}}
  })
]

{_state, requests} =
  Enum.reduce(trace, {state, []}, fn item, {state, requests} ->
    {:Transition, state, {:some, request}} = LuaTool.step(state, item)
    {state, requests ++ [request]}
  end)

%{"actions" => [%{"payload" => finish}]} = List.last(requests)

%{
  actions: Enum.map(requests, fn %{"actions" => [action]} -> action["kind"] end),
  status: finish["status"],
  action_id: finish["action_id"],
  result: finish["result"]
}
