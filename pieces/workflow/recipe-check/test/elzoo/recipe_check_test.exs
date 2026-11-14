# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipeCheckTest do
  use ExUnit.Case, async: false
  import Kernel, except: [node: 1]
  import ExUnit.CaptureLog
  alias Elzoo.{RecipeCheck, ToolRegistry}

  @max_cap 9_223_372_036_854_775_807

  # --- builders: small literal neutral maps -------------------------------------------

  defp typed(direction) do
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

  defp callable(name, kind \\ "graph") do
    base = %{"name" => name, "kind" => kind, "input" => typed("input"), "output" => typed("output")}

    case kind do
      "graph" -> Map.merge(base, %{"nodes" => [], "links" => [], "input_slots" => []})
      "agent" -> Map.put(base, "binding", "worker")
      "decision" -> Map.merge(base, %{"binding" => "worker", "choices" => ["yes", "no"]})
    end
  end

  defp graph(name, nodes, links \\ []),
    do: Map.merge(callable(name), %{"nodes" => nodes, "links" => links})

  defp recipe(callables, root \\ nil) do
    %{
      "version" => 1,
      "id" => "recipe",
      "revision" => 3,
      "root" => root || hd(callables)["name"],
      "callables" => callables,
      "bindings" => [%{"name" => "worker", "target" => "binding"}],
      "rules" => []
    }
  end

  defp node(id, kind \\ "ask", extra \\ %{}),
    do: Map.merge(%{"id" => id, "kind" => kind, "needs" => [], "gives" => []}, extra)

  defp tool_node(id, tool \\ "mcp_fetch"), do: node(id, "tool", %{"tool" => tool})
  defp slot(name), do: %{"name" => name, "schema_id" => "value", "schema_version" => 1}

  defp link(from, to, kind \\ "order", extra \\ %{}),
    do: Map.merge(%{"from" => from, "to" => to, "kind" => kind}, extra)

  defp source(id, names) do
    tools =
      for name <- names do
        %{
          "trust" => "untrusted",
          "name" => name,
          "description" => "Run " <> name,
          "input_schema" => %{"type" => "object"},
          "annotations" => nil
        }
      end

    %{"id" => id, "kind" => "host_listing", "callable" => "adapter", "tools" => tools}
  end

  defp snapshot(sources \\ [source("mcp", ["fetch"])]) do
    {:ok, snapshot} = ToolRegistry.snapshot(sources)
    snapshot
  end

  defp facts(costs, overrides \\ %{}) do
    Map.merge(
      %{
        "tools" => snapshot(),
        "provided_needs" => [],
        "granted_permissions" => [],
        "tool_requirements" => %{},
        "unit" => "token",
        "costs" => costs,
        "cap" => 1_000
      },
      overrides
    )
  end

  defp cost(callable, node, estimate),
    do: %{"callable" => callable, "node" => node, "estimate" => estimate}

  defp cost(callable, estimate), do: %{"callable" => callable, "estimate" => estimate}

  @none %{"needs" => [], "permissions" => []}

  defp declared(needs, permissions),
    do: %{"needs" => needs, "permissions" => permissions}

  defp run(recipe, facts, declared \\ @none),
    do: RecipeCheck.check_graph(recipe, declared, facts)

  defp reason(path, code), do: %{path: path, code: code}

  defp one_tool, do: recipe([graph("main", [tool_node("fetch")])])
  defp one_tool_costs, do: [cost("main", "fetch", 5)]

  # Independent test oracle for the package identity, as in domain/recipe-package: scalar
  # encoding by Jason, objects with their UTF-8 binary keys in ascending order.
  defp descriptor do
    %{
      "version" => 1,
      "id" => "independent-settings",
      "revision" => 1,
      "port" => typed("input")["port"],
      "secrets" => [],
      "schema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
    }
  end

  defp canonical(value), do: Jason.encode!(ordered_value(value))

  defp ordered_value(value) when is_map(value),
    do: %Jason.OrderedObject{values: for({k, v} <- Enum.sort(value), do: {k, ordered_value(v)})}

  defp ordered_value(value) when is_list(value), do: Enum.map(value, &ordered_value/1)
  defp ordered_value(value), do: value

  defp sign(map) do
    hash = :crypto.hash(:sha256, canonical(Map.delete(map, "identity")))
    Map.put(map, "identity", "recipe-package-v1:sha256:" <> Base.encode16(hash, case: :lower))
  end

  defp package(recipe, overrides \\ %{}) do
    %{
      "format_version" => 1,
      "name" => "package",
      "version" => "opaque",
      "needs" => [],
      "permissions" => [],
      "graph" => recipe,
      "settings" => descriptor(),
      "skills" => []
    }
    |> Map.merge(overrides)
    |> sign()
  end

  defp skill do
    %{
      "name" => "helper",
      "version" => "v1",
      "tools" => [],
      "frontmatter" => %{"name" => "helper", "description" => "Instructions"},
      "body" => ""
    }
  end

  defp chain(count) do
    for n <- 1..count do
      if n == count,
        do: callable("c#{n}", "agent"),
        else: graph("c#{n}", [node("call", "call", %{"callable" => "c#{n + 1}"})])
    end
  end

  # --- group 1 -------------------------------------------------------------------------

  describe "structural_faults_located" do
    defp structural(recipe, code) do
      assert RecipeCheck.check(package(recipe), facts([])) ==
               {:refused, [reason(["graph"], code)]}
    end

    test "each structural fault of the recipe is one reason under graph" do
      repeat = fn kind, extra ->
        recipe([
          graph("main", [node("repeat", kind, Map.merge(%{"callable" => "agent"}, extra))]),
          callable("agent", "agent")
        ])
      end

      structural(recipe([graph("main", [node("a", "unknown_kind")])]), :invalid_shape)

      structural(
        recipe([graph("main", [node("a", "call", %{"callable" => "gone"})])]),
        :unknown_name
      )

      structural(
        recipe([graph("main", [node("a", "ask", %{"needs" => [slot("value")]})])]),
        :missing_giver
      )

      choose = node("choose", "decision", %{"callable" => "choice"})

      structural(
        recipe([
          graph("main", [choose, node("yes")], [
            link("choose", "yes", "choice", %{"choice" => "yes"})
          ]),
          callable("choice", "decision")
        ]),
        :invalid_branch
      )

      structural(
        recipe([graph("main", [node("a"), node("b")], [link("a", "b"), link("b", "a")])]),
        :cycle
      )

      structural(recipe(chain(17)), :depth_exceeded)

      structural(
        recipe([
          graph("main", [node("a"), node("b")], [
            link("a", "b", "outcome", %{"outcome" => "success"})
          ])
        ]),
        :invalid_outcome
      )

      structural(
        recipe([
          graph("main", [node("a")], [link("a", "gone", "outcome", %{"outcome" => "failed"})])
        ]),
        :unknown_name
      )

      for kind <- ~w(map loop) do
        for bound <- [0, 257],
            do: structural(repeat.(kind, %{"max_iterations" => bound}), :invalid_shape)

        structural(repeat.(kind, %{}), :invalid_shape)
      end
    end

    test "a skill, a settings descriptor and a package shape are located at their part" do
      ok = recipe([graph("main", [])])

      assert RecipeCheck.check(package(ok, %{"skills" => [Map.delete(skill(), "body")]}), facts([])) ==
               {:refused, [reason(["skills"], :invalid_skill)]}

      bad_settings = put_in(descriptor(), ["schema", "type"], "bad")

      assert RecipeCheck.check(package(ok, %{"settings" => bad_settings}), facts([])) ==
               {:refused, [reason(["settings"], :invalid_settings_descriptor)]}

      whole = package(ok)

      for {bad, code} <- [
            {Map.delete(whole, "name"), :invalid_shape},
            {Map.put(whole, "format_version", 2), :unsupported_version},
            {Map.put(whole, "name", "other"), :invalid_identity},
            {"not a map", :invalid_shape}
          ] do
        assert RecipeCheck.check(bad, facts([])) == {:refused, [reason([], code)]}
      end
    end

    test "a structural fault hides every stage 2 reason" do
      bad = recipe([graph("main", [tool_node("a", "nothing"), node("a", "unknown_kind")])])
      pkg = package(bad, %{"needs" => ["host"]})

      assert RecipeCheck.check(pkg, facts([])) == {:refused, [reason(["graph"], :invalid_shape)]}
      assert run(bad, facts([])) == {:refused, [reason([], :invalid_shape)]}
    end
  end

  # --- group 2 -------------------------------------------------------------------------

  describe "tools_exist" do
    test "a tool that resolves passes" do
      assert {:ok, %{upper_cost: 5}} = run(one_tool(), facts(one_tool_costs()))
    end

    test "an unknown, a removed and an ambiguous name each give unknown_tool at the node" do
      {:ok, removed} = ToolRegistry.refresh(snapshot(), "mcp", [])
      assert ToolRegistry.resolve(removed, "mcp_fetch") == :removed

      ambiguous = snapshot([source("left", ["search"]), source("right", ["search"])])
      assert {:ambiguous, _} = ToolRegistry.resolve(ambiguous, "search")

      for {tools, name} <- [
            {snapshot(), "nothing"},
            {removed, "mcp_fetch"},
            {ambiguous, "search"}
          ] do
        recipe = recipe([graph("main", [tool_node("fetch", name)])])

        assert run(recipe, facts(one_tool_costs(), %{"tools" => tools})) ==
                 {:refused, [reason(["callables", 0, "nodes", 0], :unknown_tool)]}
      end
    end

    test "two such nodes give two reasons in path order, also through a package" do
      nodes = [tool_node("first", "nothing"), tool_node("ok"), tool_node("second", "other")]
      costs = for id <- ~w(first ok second), do: cost("main", id, 1)
      main = graph("main", nodes)
      recipe = recipe([callable("agent", "agent"), main], "main")
      costs = [cost("agent", 1) | costs]

      assert run(recipe, facts(costs)) ==
               {:refused,
                [
                  reason(["callables", 1, "nodes", 0], :unknown_tool),
                  reason(["callables", 1, "nodes", 2], :unknown_tool)
                ]}

      assert RecipeCheck.check(package(recipe), facts(costs)) ==
               {:refused,
                [
                  reason(["graph", "callables", 1, "nodes", 0], :unknown_tool),
                  reason(["graph", "callables", 1, "nodes", 2], :unknown_tool)
                ]}
    end

    test "a callable that the root does not reach is checked too" do
      recipe = recipe([graph("main", []), graph("unused", [tool_node("fetch", "nothing")])])

      assert run(recipe, facts([cost("unused", "fetch", 1)])) ==
               {:refused, [reason(["callables", 1, "nodes", 0], :unknown_tool)]}
    end
  end

  # --- group 3 -------------------------------------------------------------------------

  describe "needs_and_permissions" do
    defp requiring(needs, permissions, tool \\ "mcp_fetch"),
      do: %{"tool_requirements" => %{tool => %{"needs" => needs, "permissions" => permissions}}}

    @node_path ["callables", 0, "nodes", 0]

    test "a requirement that the recipe does not declare, need then permission" do
      facts =
        facts(
          one_tool_costs(),
          Map.merge(requiring(["index"], ["read"]), %{
            "provided_needs" => ["index"],
            "granted_permissions" => ["read"]
          })
        )

      assert run(one_tool(), facts, declared([], [])) ==
               {:refused,
                [
                  reason(@node_path, :need_not_declared),
                  reason(@node_path, :permission_not_declared)
                ]}

      assert run(one_tool(), facts, declared(["index"], [])) ==
               {:refused, [reason(@node_path, :permission_not_declared)]}

      assert run(one_tool(), facts, declared([], ["read"])) ==
               {:refused, [reason(@node_path, :need_not_declared)]}

      assert run(one_tool(), facts, declared(["index"], ["read"])) |> elem(0) == :ok
    end

    test "one reason per code per node, however many members are missing" do
      facts = facts(one_tool_costs(), requiring(["a", "b", "c"], ["x", "y"]))

      assert run(one_tool(), facts, declared(["a"], [])) ==
               {:refused,
                [
                  reason(@node_path, :need_not_declared),
                  reason(@node_path, :permission_not_declared),
                  reason(["needs", 0], :need_not_provided)
                ]}
    end

    test "a declared need that the host does not provide, and a permission not granted" do
      facts = facts(one_tool_costs(), %{"provided_needs" => ["b"], "granted_permissions" => ["q"]})

      assert run(one_tool(), facts, declared(["a", "b", "c"], ["p", "q"])) ==
               {:refused,
                [
                  reason(["needs", 0], :need_not_provided),
                  reason(["needs", 2], :need_not_provided),
                  reason(["permissions", 0], :permission_not_granted)
                ]}
    end

    test "strings are compared by exact bytes" do
      facts =
        facts(one_tool_costs(), %{"provided_needs" => ["Index"], "granted_permissions" => ["read "]})

      assert run(one_tool(), facts, declared(["index"], ["read"])) ==
               {:refused,
                [
                  reason(["needs", 0], :need_not_provided),
                  reason(["permissions", 0], :permission_not_granted)
                ]}
    end

    test "a tool with no requirements entry requires nothing; the entry is keyed by the node text" do
      other = requiring(["index"], ["read"], "another_tool")
      assert {:ok, _} = run(one_tool(), facts(one_tool_costs(), other))

      # Keyed by the text that the node holds, not by resolution: an unknown tool also has them.
      ghost = recipe([graph("main", [tool_node("fetch", "ghost")])])
      facts = facts(one_tool_costs(), requiring(["index"], [], "ghost"))

      assert run(ghost, facts) ==
               {:refused,
                [reason(@node_path, :need_not_declared), reason(@node_path, :unknown_tool)]}
    end

    test "a recipe that declares more than its tools require passes when all is provided and granted" do
      facts =
        facts(
          one_tool_costs(),
          Map.merge(requiring(["index"], ["read"]), %{
            "provided_needs" => ["index", "extra-need", "unused"],
            "granted_permissions" => ["read", "extra-permission"]
          })
        )

      assert {:ok, %{upper_cost: 5}} =
               run(
                 one_tool(),
                 facts,
                 declared(["index", "extra-need"], ["read", "extra-permission"])
               )
    end
  end

  # --- group 4 -------------------------------------------------------------------------

  describe "upper_cost" do
    defp costed(recipe, costs, cap), do: run(recipe, facts(costs, %{"cap" => cap}))

    # main -> sub -> inner: two levels of nesting, six node kinds in main.
    defp six_kinds do
      choose = node("n_decision", "decision", %{"callable" => "choice"})

      main =
        graph(
          "main",
          [
            tool_node("n_tool"),
            node("n_ask"),
            node("n_call", "call", %{"callable" => "sub"}),
            choose,
            node("n_map", "map", %{"callable" => "worker", "max_iterations" => 5}),
            node("n_loop", "loop", %{"callable" => "sub", "max_iterations" => 3})
          ],
          [
            link("n_decision", "n_ask", "choice", %{"choice" => "yes"}),
            link("n_decision", "n_tool", "choice", %{"choice" => "no"})
          ]
        )

      sub =
        graph("sub", [
          node("s_ask"),
          tool_node("s_tool"),
          node("s_call", "call", %{"callable" => "inner"})
        ])

      inner =
        graph("inner", [
          node("i_ask"),
          node("i_map", "map", %{"callable" => "worker", "max_iterations" => 2})
        ])

      recipe(
        [main, sub, inner, callable("worker", "agent"), callable("choice", "decision")],
        "main"
      )
    end

    defp six_kind_costs do
      [
        cost("main", "n_tool", 3),
        cost("main", "n_ask", 4),
        cost("sub", "s_ask", 2),
        cost("sub", "s_tool", 6),
        cost("inner", "i_ask", 1),
        cost("worker", 7),
        cost("choice", 10)
      ]
    end

    test "one node of each of the six kinds, nested two levels, with the sum written by hand" do
      # inner = 1 (i_ask) + 2 * 7 (i_map) = 15
      # sub   = 2 (s_ask) + 6 (s_tool) + 15 (s_call -> inner) = 23
      # main  = 3 (n_tool) + 4 (n_ask) + 23 (n_call -> sub) + 10 (n_decision -> choice)
      #         + 5 * 7 (n_map) + 3 * 23 (n_loop -> sub) = 144; both choice branches count.
      assert {:ok, %{identity: {"recipe", 3, 1}, unit: "token", upper_cost: 144}} =
               costed(six_kinds(), six_kind_costs(), 144)

      assert costed(six_kinds(), six_kind_costs(), 143) == {:refused, [reason([], :over_cap)]}
    end

    test "a map and a loop at 256 iterations" do
      for kind <- ~w(map loop) do
        recipe =
          recipe([
            graph("main", [node("repeat", kind, %{"callable" => "worker", "max_iterations" => 256})]),
            callable("worker", "agent")
          ])

        assert {:ok, %{upper_cost: 1_280}} = costed(recipe, [cost("worker", 5)], 1_280)
        assert costed(recipe, [cost("worker", 5)], 1_279) == {:refused, [reason([], :over_cap)]}
      end
    end

    test "a branch that one run does not take still counts" do
      choose = node("choose", "decision", %{"callable" => "choice"})

      main =
        graph(
          "main",
          [choose, node("cheap"), node("dear")],
          [
            link("choose", "cheap", "choice", %{"choice" => "yes"}),
            link("choose", "dear", "choice", %{"choice" => "no"})
          ]
        )

      recipe = recipe([main, callable("choice", "decision")])
      costs = [cost("choice", 1), cost("main", "cheap", 2), cost("main", "dear", 1_000)]
      assert {:ok, %{upper_cost: 1_003}} = costed(recipe, costs, 1_003)
    end

    test "a cost at the cap passes and the cap plus 1 is over_cap" do
      assert {:ok, %{upper_cost: 5}} = costed(one_tool(), one_tool_costs(), 5)
      assert costed(one_tool(), one_tool_costs(), 4) == {:refused, [reason([], :over_cap)]}

      assert RecipeCheck.check(package(one_tool()), facts(one_tool_costs(), %{"cap" => 4})) ==
               {:refused, [reason(["graph"], :over_cap)]}
    end

    test "a missing cost of a node and of a callable; no over_cap is reported then" do
      recipe =
        recipe([graph("main", [tool_node("fetch"), node("review")]), callable("worker", "agent")])

      small = %{"cap" => 1}

      assert run(recipe, facts([cost("main", "review", 9), cost("worker", 9)], small)) ==
               {:refused, [reason(["callables", 0, "nodes", 0], :missing_cost)]}

      assert run(recipe, facts([cost("main", "fetch", 9), cost("main", "review", 9)], small)) ==
               {:refused, [reason(["callables", 1], :missing_cost)]}

      assert run(recipe, facts([cost("main", "fetch", 9), cost("worker", 9)], small)) ==
               {:refused, [reason(["callables", 0, "nodes", 1], :missing_cost)]}

      all = [cost("main", "fetch", 9), cost("main", "review", 9), cost("worker", 9)]
      assert run(recipe, facts(all, small)) == {:refused, [reason([], :over_cap)]}
    end

    test "an unknown cost target gives one reason however many entries, and adds nothing to the sum" do
      recipe =
        recipe([
          graph("main", [tool_node("fetch"), node("map", "call", %{"callable" => "worker"})]),
          callable("worker", "agent")
        ])

      base = [cost("main", "fetch", 5), cost("worker", 3)]

      unknown = [
        cost("main", "gone", 1_000_000),
        cost("gone", "fetch", 1),
        cost("gone", 1),
        # a node entry for an agent callable, a callable entry for a node, a call node
        cost("worker", "fetch", 1),
        cost("main", 1),
        cost("main", "map", 1)
      ]

      assert costed(recipe, base ++ [hd(unknown)], 1_000) ==
               {:refused, [reason([], :unknown_cost_target)]}

      assert costed(recipe, base ++ unknown, 8) == {:refused, [reason([], :unknown_cost_target)]}

      assert RecipeCheck.check(package(recipe), facts(base ++ unknown, %{"cap" => 8})) ==
               {:refused, [reason(["graph"], :unknown_cost_target)]}

      # The sum is 5 + 3 = 8; the unknown estimates are ignored, so cap 7 adds over_cap.
      assert costed(recipe, base ++ unknown, 7) ==
               {:refused, [reason([], :over_cap), reason([], :unknown_cost_target)]}

      assert {:ok, %{upper_cost: 8}} = costed(recipe, base, 8)
    end

    test "products above 2^64 are exact integers" do
      # 127 * 73 * 994_950_000... is the exact factorisation of 2^63 - 1 below.
      per = div(@max_cap, 127 * 73)
      assert per * 127 * 73 == @max_cap
      assert per <= 9_007_199_254_740_992

      recipe =
        recipe([
          graph("main", [node("outer", "map", %{"callable" => "sub", "max_iterations" => 127})]),
          graph("sub", [node("inner", "map", %{"callable" => "worker", "max_iterations" => 73})]),
          callable("worker", "agent")
        ])

      # Exactly 2^63 - 1 passes at the largest cap; a float would round it above the cap.
      assert {:ok, %{upper_cost: @max_cap}} = costed(recipe, [cost("worker", per)], @max_cap)

      assert costed(recipe, [cost("worker", per + 1)], @max_cap) ==
               {:refused, [reason([], :over_cap)]}

      # 256 * 256 * 2^53 = 2^69, above 2^64: refused at the largest cap, never wrapped or rounded.
      wide =
        recipe([
          graph("main", [node("outer", "map", %{"callable" => "sub", "max_iterations" => 256})]),
          graph("sub", [node("inner", "map", %{"callable" => "worker", "max_iterations" => 256})]),
          callable("worker", "agent")
        ])

      assert costed(wide, [cost("worker", 9_007_199_254_740_992)], @max_cap) ==
               {:refused, [reason([], :over_cap)]}
    end

    test "an agent or a decision root costs its own estimate" do
      for kind <- ~w(agent decision) do
        assert {:ok, %{upper_cost: 11}} =
                 costed(recipe([callable("root", kind)]), [cost("root", 11)], 11)
      end

      assert costed(recipe([callable("root", "agent")]), [], 11) ==
               {:refused, [reason(["callables", 0], :missing_cost)]}
    end
  end

  # --- group 5 -------------------------------------------------------------------------

  describe "all_reasons_in_order" do
    # Seven codes at once: a missing cost forbids over_cap, so over_cap has its own package.
    defp faulty(reversed?) do
      main = graph("main", [tool_node("bad", "nothing"), node("plain")])
      lists = fn list -> if reversed?, do: Enum.reverse(list), else: list end

      main = Map.update!(main, "nodes", lists)
      callables = lists.([main, callable("worker", "agent")])

      package(recipe(callables, "main"), %{
        "needs" => lists.(["host-a", "host-b"]),
        "permissions" => lists.(["perm-a", "perm-b"])
      })
    end

    defp faulty_facts(costs, cap) do
      facts(
        costs,
        Map.merge(requiring(["need-x"], ["perm-x"], "nothing"), %{
          "provided_needs" => ["host-a"],
          "granted_permissions" => ["perm-b"],
          "cap" => cap
        })
      )
    end

    defp partial, do: [cost("main", "bad", 2), cost("main", "ghost", 1)]
    defp complete, do: [cost("main", "bad", 2), cost("main", "plain", 3), cost("worker", 4)]

    test "a fault of every stage 2 code gives each reason once, in sorted order" do
      assert RecipeCheck.check(faulty(false), faulty_facts(partial(), 1_000)) ==
               {:refused,
                [
                  reason(["graph"], :unknown_cost_target),
                  reason(["graph", "callables", 0, "nodes", 0], :need_not_declared),
                  reason(["graph", "callables", 0, "nodes", 0], :permission_not_declared),
                  reason(["graph", "callables", 0, "nodes", 0], :unknown_tool),
                  reason(["graph", "callables", 0, "nodes", 1], :missing_cost),
                  reason(["graph", "callables", 1], :missing_cost),
                  reason(["needs", 1], :need_not_provided),
                  reason(["permissions", 0], :permission_not_granted)
                ]}

      # With every cost given (and the unknown target kept) over_cap joins: the root costs
      # 2 + 3 = 5 > 4; the agent that no node calls adds nothing.
      assert RecipeCheck.check(
               faulty(false),
               faulty_facts(complete() ++ [cost("main", "ghost", 1)], 4)
             ) ==
               {:refused,
                [
                  reason(["graph"], :over_cap),
                  reason(["graph"], :unknown_cost_target),
                  reason(["graph", "callables", 0, "nodes", 0], :need_not_declared),
                  reason(["graph", "callables", 0, "nodes", 0], :permission_not_declared),
                  reason(["graph", "callables", 0, "nodes", 0], :unknown_tool),
                  reason(["needs", 1], :need_not_provided),
                  reason(["permissions", 0], :permission_not_granted)
                ]}
    end

    test "the same package with its lists in another order gives the reasons at the new paths" do
      assert RecipeCheck.check(faulty(true), faulty_facts(partial(), 1_000)) ==
               {:refused,
                [
                  reason(["graph"], :unknown_cost_target),
                  reason(["graph", "callables", 0], :missing_cost),
                  reason(["graph", "callables", 1, "nodes", 0], :missing_cost),
                  reason(["graph", "callables", 1, "nodes", 1], :need_not_declared),
                  reason(["graph", "callables", 1, "nodes", 1], :permission_not_declared),
                  reason(["graph", "callables", 1, "nodes", 1], :unknown_tool),
                  reason(["needs", 0], :need_not_provided),
                  reason(["permissions", 1], :permission_not_granted)
                ]}

      assert RecipeCheck.check(
               faulty(true),
               faulty_facts(complete() ++ [cost("main", "ghost", 1)], 4)
             ) ==
               {:refused,
                [
                  reason(["graph"], :over_cap),
                  reason(["graph"], :unknown_cost_target),
                  reason(["graph", "callables", 1, "nodes", 1], :need_not_declared),
                  reason(["graph", "callables", 1, "nodes", 1], :permission_not_declared),
                  reason(["graph", "callables", 1, "nodes", 1], :unknown_tool),
                  reason(["needs", 0], :need_not_provided),
                  reason(["permissions", 1], :permission_not_granted)
                ]}
    end

    test "a shorter path comes before a longer one, and index 2 before index 10" do
      nodes = for n <- 0..11, do: node("n#{n}")
      recipe = recipe([graph("main", nodes)])
      costs = for n <- [0, 1, 3, 4, 5, 6, 7, 8, 9, 11], do: cost("main", "n#{n}", 1)

      assert run(recipe, facts(costs ++ [cost("main", "gone", 1)], %{"cap" => 1})) ==
               {:refused,
                [
                  reason([], :unknown_cost_target),
                  reason(["callables", 0, "nodes", 2], :missing_cost),
                  reason(["callables", 0, "nodes", 10], :missing_cost)
                ]}

      two = recipe([callable("a", "agent"), graph("main", [node("x")])], "main")

      assert run(two, facts([cost("main", "gone", 1)])) ==
               {:refused,
                [
                  reason([], :unknown_cost_target),
                  reason(["callables", 0], :missing_cost),
                  reason(["callables", 1, "nodes", 0], :missing_cost)
                ]}
    end
  end

  # --- group 6 -------------------------------------------------------------------------

  describe "same_input_same_verdict" do
    defp passing do
      package(one_tool(), %{"needs" => ["host"], "permissions" => ["read"]})
    end

    defp passing_facts do
      facts(
        one_tool_costs(),
        Map.merge(requiring(["host"], ["read"]), %{
          "provided_needs" => ["host"],
          "granted_permissions" => ["read"]
        })
      )
    end

    defp refused_facts, do: Map.put(passing_facts(), "granted_permissions", [])

    test "20 calls and a call in a second process give equal results; the package is not changed" do
      for {pkg, facts} <- [{passing(), passing_facts()}, {passing(), refused_facts()}] do
        copy = pkg
        first = RecipeCheck.check(pkg, facts)
        assert for(_ <- 1..20, do: RecipeCheck.check(pkg, facts)) == List.duplicate(first, 20)
        assert Task.await(Task.async(fn -> RecipeCheck.check(pkg, facts) end)) == first
        assert spawn_result(fn -> RecipeCheck.check(pkg, facts) end) == first
        assert pkg == copy
      end

      assert {:ok, %{identity: "recipe-package-v1:sha256:" <> _, upper_cost: 5}} =
               RecipeCheck.check(passing(), passing_facts())

      assert RecipeCheck.check(passing(), refused_facts()) ==
               {:refused, [reason(["permissions", 0], :permission_not_granted)]}
    end

    defp spawn_result(fun) do
      parent = self()
      ref = make_ref()
      spawn(fn -> send(parent, {ref, fun.()}) end)
      assert_receive {^ref, result}
      result
    end

    test "a sentinel in a package value, a tool name, a need and a fact never appears" do
      sentinel = "SENTINEL-8f3a"

      logged =
        capture_log(fn ->
          results = [
            # a sentinel in a package value that stage 1 refuses
            RecipeCheck.check(
              package(one_tool(), %{"skills" => [Map.put(skill(), "body", 5)], "name" => sentinel}),
              passing_facts()
            ),
            # a tool name, a need and a permission that stage 2 refuses
            RecipeCheck.check(
              package(recipe([graph("main", [tool_node("fetch", sentinel <> "-tool")])]), %{
                "needs" => [sentinel <> "-need"],
                "permissions" => [sentinel <> "-permission"]
              }),
              facts(
                [cost("main", "fetch", 1)],
                requiring([sentinel <> "-requirement"], [], sentinel <> "-tool")
              )
            ),
            # a sentinel in each member of facts that is malformed
            RecipeCheck.check(
              passing(),
              Map.put(passing_facts(), "provided_needs", [sentinel, sentinel])
            ),
            RecipeCheck.check(passing(), Map.put(passing_facts(), "unit", {sentinel})),
            RecipeCheck.check(
              passing(),
              Map.put(passing_facts(), "costs", [%{"callable" => sentinel}])
            ),
            RecipeCheck.check_graph(
              one_tool(),
              %{"needs" => [sentinel], "extra" => []},
              passing_facts()
            ),
            run(recipe([graph("main", [node(sentinel, "unknown_kind")])]), passing_facts())
          ]

          refute inspect(results) =~ sentinel

          assert [
                   {:refused, [%{path: ["skills"], code: :invalid_skill}]},
                   {:refused, reasons},
                   {:error, :invalid_facts},
                   {:error, :invalid_facts},
                   {:error, :invalid_facts},
                   {:error, :invalid_facts},
                   {:refused, [%{path: [], code: :invalid_shape}]}
                 ] = results

          assert Enum.all?(reasons, &(Map.keys(&1) |> Enum.sort() == [:code, :path]))

          assert Enum.all?(
                   reasons,
                   &Enum.all?(&1.path, fn part ->
                     is_integer(part) or part in ~w(graph callables nodes needs permissions)
                   end)
                 )
        end)

      assert logged == ""
    end

    defp invalid?(facts),
      do: assert(RecipeCheck.check(passing(), facts) == {:error, :invalid_facts})

    defp invalid_graph?(declared, facts),
      do: assert(RecipeCheck.check_graph(one_tool(), declared, facts) == {:error, :invalid_facts})

    defp not_invalid?(facts) do
      refute RecipeCheck.check(passing(), facts) == {:error, :invalid_facts}
    end

    test "facts: each malformed member is {:error, :invalid_facts}, and each bound plus 1" do
      good = passing_facts()
      invalid?("not a map")
      invalid?(%URI{})
      invalid?(Map.delete(good, "cap"))
      invalid?(Map.put(good, "extra", 1))
      invalid?(%{"tools" => good["tools"]})

      for bad <- [
            :snapshot,
            {:ToolRegistry, :sources, %{}, %{}},
            {:ToolRegistry, [], [], %{}},
            {:ToolRegistry, [], %{}, :removed},
            {:ToolRegistry, [], %URI{}, %{}},
            {:ToolRegistry, [], %{}}
          ],
          do: invalid?(%{good | "tools" => bad})

      for key <- ~w(provided_needs granted_permissions) do
        for bad <- [
              :list,
              [1],
              [""],
              [<<255>>],
              [String.duplicate("x", 129)],
              ["a", "a"],
              ["a" | "b"],
              %{}
            ] do
          invalid?(%{good | key => bad})
        end

        invalid?(%{good | key => for(n <- 1..257, do: "n#{n}")})
        not_invalid?(%{good | key => for(n <- 1..256, do: "n#{n}")})
        not_invalid?(%{good | key => [String.duplicate("x", 128)]})
      end

      bounds = fn count -> for n <- 1..count, into: %{}, do: {"tool#{n}", @none} end
      invalid?(%{good | "tool_requirements" => bounds.(1_001)})
      not_invalid?(%{good | "tool_requirements" => bounds.(1_000)})

      for bad <- [
            [],
            %URI{},
            %{"" => @none},
            %{String.duplicate("x", 129) => @none},
            %{<<255>> => @none},
            %{"t" => %{"needs" => []}},
            %{"t" => Map.put(@none, "extra", [])},
            %{"t" => %{"needs" => ["a", "a"], "permissions" => []}},
            %{"t" => %{"needs" => [:a], "permissions" => []}},
            %{"t" => %{"needs" => for(n <- 1..65, do: "n#{n}"), "permissions" => []}},
            %{"t" => %{"needs" => [], "permissions" => for(n <- 1..65, do: "p#{n}")}},
            %{"t" => %{"needs" => [], "permissions" => "p"}},
            %{"t" => []},
            %{"t" => struct(URI)}
          ],
          do: invalid?(%{good | "tool_requirements" => bad})

      sixty_four = for n <- 1..64, do: "n#{n}"

      not_invalid?(%{
        good
        | "tool_requirements" => %{"t" => %{"needs" => sixty_four, "permissions" => sixty_four}}
      })

      for bad <- ["", String.duplicate("x", 129), <<255>>, :token, 1, nil],
          do: invalid?(%{good | "unit" => bad})

      not_invalid?(%{good | "unit" => String.duplicate("u", 128)})
      not_invalid?(%{good | "unit" => "u"})
    end

    test "facts: the costs and the cap, each bound plus 1" do
      good = passing_facts()
      entry = cost("main", "fetch", 5)
      callable_entry = cost("worker", 5)

      for bad <- [
            :costs,
            %{},
            [:entry],
            [%URI{}],
            [Map.put(entry, "extra", 1)],
            [Map.delete(entry, "estimate")],
            [Map.delete(entry, "callable")],
            [Map.delete(callable_entry, "estimate")],
            [Map.put(callable_entry, "node", nil)],
            [%{entry | "callable" => ""}],
            [%{entry | "node" => ""}],
            [%{entry | "node" => String.duplicate("x", 129)}],
            [%{entry | "callable" => <<255>>}],
            [%{entry | "estimate" => 0}],
            [%{entry | "estimate" => -1}],
            [%{entry | "estimate" => 5.0}],
            [%{entry | "estimate" => "5"}],
            [%{callable_entry | "estimate" => 9_007_199_254_740_993}],
            [entry, entry],
            [callable_entry, callable_entry],
            [entry | entry]
          ],
          do: invalid?(%{good | "costs" => bad})

      for ok <- [
            [entry],
            [callable_entry],
            [cost("a", 1), cost("a", "b", 1)],
            [%{entry | "estimate" => 9_007_199_254_740_992}],
            [%{entry | "estimate" => 1}]
          ],
          do: not_invalid?(%{good | "costs" => ok})

      costs = fn count -> for n <- 1..count, do: cost("c#{n}", 1) end
      invalid?(%{good | "costs" => costs.(1_065)})
      not_invalid?(%{good | "costs" => costs.(1_064)})

      for bad <- [0, -1, @max_cap + 1, 1.0, "1", nil, 5.5],
          do: invalid?(%{good | "cap" => bad})

      not_invalid?(%{good | "cap" => 1})
      not_invalid?(%{good | "cap" => @max_cap})
    end

    test "declared: each malformed member and each bound plus 1; facts first of all" do
      good = passing_facts()
      names = fn count -> for n <- 1..count, do: "n#{n}" end

      for bad <- [
            [],
            %URI{},
            %{"needs" => []},
            %{"needs" => [], "permissions" => [], "extra" => []},
            %{"needs" => ["a", "a"], "permissions" => []},
            %{"needs" => [""], "permissions" => []},
            %{"needs" => [], "permissions" => [String.duplicate("x", 129)]},
            %{"needs" => [], "permissions" => [<<255>>]},
            %{"needs" => ["a" | "b"], "permissions" => []},
            %{"needs" => :a, "permissions" => []},
            %{"needs" => names.(65), "permissions" => []},
            %{"needs" => [], "permissions" => names.(65)}
          ],
          do: invalid_graph?(bad, good)

      assert {:refused, _} = run(one_tool(), good, declared(names.(64), names.(64)))
      invalid_graph?(@none, Map.delete(good, "cap"))
      invalid_graph?(%{}, Map.delete(good, "cap"))

      # The caller's error is reported before any verdict on the recipe.
      broken = recipe([graph("main", [node("a", "unknown_kind")])])

      assert RecipeCheck.check_graph(broken, @none, Map.delete(good, "cap")) ==
               {:error, :invalid_facts}

      assert RecipeCheck.check(%{"nothing" => 1}, Map.delete(good, "cap")) ==
               {:error, :invalid_facts}
    end

    test "check_graph on the graph member and check on the package give the same reasons" do
      declared = declared(["host"], ["read"])

      {passing_recipe, passing_facts} =
        {one_tool(), Map.merge(passing_facts(), %{"provided_needs" => ["host"]})}

      cases = [
        {passing_recipe, passing_facts, :ok},
        {one_tool(), Map.put(passing_facts, "granted_permissions", []), :refused},
        {one_tool(), %{passing_facts | "tools" => snapshot([source("mcp", [])])}, :refused},
        {recipe([graph("main", [node("a", "unknown_kind")])]), passing_facts, :refused}
      ]

      for {recipe, facts, kind} <- cases do
        pkg = package(recipe, %{"needs" => ["host"], "permissions" => ["read"]})
        by_graph = RecipeCheck.check_graph(pkg["graph"], declared, facts)
        by_package = RecipeCheck.check(pkg, facts)

        assert elem(by_graph, 0) == kind
        assert elem(by_package, 0) == kind

        case {by_graph, by_package} do
          {{:ok, left}, {:ok, right}} ->
            assert left.identity == {"recipe", 3, 1}
            assert right.identity == pkg["identity"]
            assert Map.delete(left, :identity) == Map.delete(right, :identity)

          {{:refused, left}, {:refused, right}} ->
            assert Enum.map(
                     right,
                     &update_in(&1.path, fn
                       ["graph" | rest] -> rest
                       path -> path
                     end)
                   ) == left
        end
      end
    end

    test "the checked example" do
      {result, _} = Code.eval_file(Path.expand("../../examples/recipe_check.exs", __DIR__))
      assert result == :ok
    end
  end
end
