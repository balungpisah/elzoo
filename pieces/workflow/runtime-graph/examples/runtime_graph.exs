# SPDX-License-Identifier: Apache-2.0
typed = fn direction ->
  %{
    "port" => %{
      "id" => direction,
      "direction" => direction,
      "schema_id" => "item",
      "schema_version" => 1
    },
    "schema" => %{"type" => "object"}
  }
end

agent = fn name ->
  %{
    "name" => name,
    "kind" => "agent",
    "input" => typed.("input"),
    "output" => typed.("output"),
    "binding" => "worker"
  }
end

# The recipe of the Run: a root graph with no node, and two agents.
recipe = %{
  "version" => 1,
  "id" => "weekly-report",
  "revision" => 1,
  "root" => "main",
  "callables" => [
    %{
      "name" => "main",
      "kind" => "graph",
      "input" => typed.("input"),
      "output" => typed.("output"),
      "input_slots" => [],
      "nodes" => [],
      "links" => []
    },
    agent.("summarize"),
    agent.("translate")
  ],
  "bindings" => [%{"name" => "worker", "target" => "binding"}],
  "rules" => []
}

tool = fn name ->
  %{
    "trust" => "untrusted",
    "name" => name,
    "description" => "Run " <> name,
    "input_schema" => %{"type" => "object"},
    "annotations" => nil
  }
end

listing = fn names ->
  %{
    "id" => "docs",
    "kind" => "host_listing",
    "callable" => "adapter",
    "tools" => Enum.map(names, tool)
  }
end

# The recipe knows two tools; this agent may use one.
{:ok, recipe_tools} = Elzoo.ToolRegistry.snapshot([listing.(["search", "export"])])
{:ok, agent_tools} = Elzoo.ToolRegistry.snapshot([listing.(["search"])])

context = %{
  "recipe" => recipe,
  "name" => "plan-1",
  "callables" => ["summarize"],
  "agent_tools" => agent_tools,
  "declared" => %{"needs" => [], "permissions" => []},
  "facts" => %{
    "tools" => recipe_tools,
    "provided_needs" => [],
    "granted_permissions" => [],
    "tool_requirements" => %{},
    "unit" => "token",
    "costs" => [
      %{"callable" => "summarize", "estimate" => 30},
      %{"callable" => "translate", "estimate" => 50}
    ],
    # the budget share of this graph
    "cap" => 100
  },
  "tool_costs" => %{"docs_search" => 20, "docs_export" => 10},
  "ask_cost" => nil,
  "max_nodes" => 8,
  "max_depth" => 4,
  "depth" => 1
}

node = fn id, kind, extra ->
  Map.merge(%{"id" => id, "kind" => kind, "needs" => [], "gives" => []}, extra)
end

proposal = fn nodes, links ->
  %{
    "nodes" => nodes,
    "links" => links,
    "input_slots" => [],
    "input" => typed.("input"),
    "output" => typed.("output")
  }
end

# A model gave one search and one summary, in order: at most 20 + 30 in "token".
good =
  proposal.(
    [
      node.("find", "tool", %{"tool" => "docs_search"}),
      node.("short", "call", %{"callable" => "summarize"})
    ],
    [%{"from" => "find", "to" => "short", "kind" => "order"}]
  )

{:ok, %{callable: "plan-1", unit: "token", upper_cost: 50, recipe: recipe2}} =
  Elzoo.RuntimeGraph.accept(good, context)

# The new callable is last, and the recipe now starts at it.
"plan-1" = recipe2["root"]
"plan-1" = List.last(recipe2["callables"])["name"]
{:ok, _checked} = Elzoo.RecipeGraph.decode(recipe2)

# The agent may not call "translate", use "docs_export" or ask a person.
bad =
  proposal.(
    [
      node.("copy", "call", %{"callable" => "translate"}),
      node.("save", "tool", %{"tool" => "docs_export"}),
      node.("check", "ask", %{})
    ],
    []
  )

{:refused, reasons} = Elzoo.RuntimeGraph.accept(bad, context)

[
  %{path: ["nodes", 0], code: :callable_not_allowed},
  %{path: ["nodes", 1], code: :tool_not_allowed},
  %{path: ["nodes", 2], code: :ask_not_allowed}
] = reasons

# The text for the model holds only the places and the codes.
"graph refused:\n$.nodes[0]: callable_not_allowed\n$.nodes[1]: tool_not_allowed\n$.nodes[2]: ask_not_allowed" =
  Elzoo.RuntimeGraph.render(reasons)

# A share of 49 is not enough for the graph that cost at most 50.
{:refused, [%{path: [], code: :over_cap}]} =
  Elzoo.RuntimeGraph.accept(good, put_in(context, ["facts", "cap"], 49))

:ok
