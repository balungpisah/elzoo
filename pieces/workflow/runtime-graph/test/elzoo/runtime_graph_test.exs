# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RuntimeGraphTest do
  use ExUnit.Case, async: false
  import Kernel, except: [node: 1]
  import ExUnit.CaptureLog
  alias Elzoo.{RecipeGraph, RuntimeGraph, ToolRegistry}

  @max_estimate 9_007_199_254_740_992

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

  defp recipe(callables, root) do
    %{
      "version" => 1,
      "id" => "recipe",
      "revision" => 3,
      "root" => root,
      "callables" => callables,
      "bindings" => [%{"name" => "worker", "target" => "binding"}],
      "rules" => []
    }
  end

  defp node(id, kind, extra \\ %{}),
    do: Map.merge(%{"id" => id, "kind" => kind, "needs" => [], "gives" => []}, extra)

  defp ask(id), do: node(id, "ask")
  defp call(id, name), do: node(id, "call", %{"callable" => name})
  defp tool(id, name), do: node(id, "tool", %{"tool" => name})
  defp repeat(id, kind, name, n), do: node(id, kind, %{"callable" => name, "max_iterations" => n})

  defp link(from, to, kind \\ "order", extra \\ %{}),
    do: Map.merge(%{"from" => from, "to" => to, "kind" => kind}, extra)

  defp proposal(nodes, links \\ []) do
    %{
      "nodes" => nodes,
      "links" => links,
      "input_slots" => [],
      "input" => typed("input"),
      "output" => typed("output")
    }
  end

  defp reason(path, code), do: %{path: path, code: code}

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

  defp snapshot(sources) do
    {:ok, snapshot} = ToolRegistry.snapshot(sources)
    snapshot
  end

  # The recipe of the Run: main (the root), two agents, a graph that calls an agent and a decision.
  defp base_recipe do
    recipe(
      [
        graph("main", []),
        callable("worker", "agent"),
        callable("heavy", "agent"),
        graph("mid", [call("go", "worker")]),
        callable("choice", "decision")
      ],
      "main"
    )
  end

  defp base_facts do
    %{
      "tools" => snapshot([source("mcp", ["fetch", "other"])]),
      "provided_needs" => [],
      "granted_permissions" => [],
      "tool_requirements" => %{},
      "unit" => "token",
      "costs" => [
        %{"callable" => "worker", "estimate" => 10},
        %{"callable" => "heavy", "estimate" => 100},
        %{"callable" => "choice", "estimate" => 5}
      ],
      "cap" => 1_000
    }
  end

  defp base_context do
    %{
      "recipe" => base_recipe(),
      "name" => "proposed",
      "callables" => ["worker", "heavy", "mid", "choice"],
      "agent_tools" => snapshot([source("mcp", ["fetch"])]),
      "declared" => %{"needs" => [], "permissions" => []},
      "facts" => base_facts(),
      "tool_costs" => %{"mcp_fetch" => 7, "mcp_other" => 9},
      "ask_cost" => 3,
      "max_nodes" => 8,
      "max_depth" => 8,
      "depth" => 1
    }
  end

  defp context(overrides \\ %{}), do: Map.merge(base_context(), overrides)

  defp facts(overrides),
    do: context(%{"facts" => Map.merge(base_facts(), overrides)})

  defp accept(proposal, overrides \\ %{}),
    do: RuntimeGraph.accept(proposal, context(overrides))

  # --- group 1 -------------------------------------------------------------------------

  describe "accepted_graph" do
    defp three_nodes do
      proposal(
        [call("go", "worker"), tool("fetch", "mcp_fetch"), ask("join")],
        [link("go", "join"), link("fetch", "join")]
      )
    end

    test "a call, a tool and a join are accepted; the recipe holds the old callables and the new one last" do
      proposal = three_nodes()
      old = base_recipe()

      assert {:ok, accepted} = RuntimeGraph.accept(proposal, context())
      assert accepted |> Map.keys() |> Enum.sort() == [:callable, :recipe, :unit, :upper_cost]
      assert accepted.callable == "proposed"
      assert accepted.unit == "token"
      # worker 10 + mcp_fetch 7 + ask 3, written by hand
      assert accepted.upper_cost == 20

      assert {:ok, _checked} = RecipeGraph.decode(accepted.recipe)
      assert accepted.recipe["root"] == "proposed"
      assert Enum.take(accepted.recipe["callables"], 5) == old["callables"]
      assert length(accepted.recipe["callables"]) == 6

      assert List.last(accepted.recipe["callables"]) ==
               Map.merge(proposal, %{"name" => "proposed", "kind" => "graph"})

      assert Map.drop(accepted.recipe, ["callables", "root"]) ==
               Map.drop(old, ["callables", "root"])
    end

    test "the sum comes from the new graph only, not from the recipe it joins" do
      assert {:ok, %{upper_cost: 100}} = accept(proposal([call("go", "heavy")]))
      assert {:ok, %{upper_cost: 0}} = accept(proposal([]))
      assert {:ok, %{upper_cost: 10}} = accept(proposal([call("go", "mid")]))
    end
  end

  # --- group 2 -------------------------------------------------------------------------

  describe "outside_the_agent" do
    test "a callable that is not in callables is refused at the node, for each naming kind" do
      for node <- [
            call("n", "heavy"),
            node("n", "decision", %{"callable" => "choice"}),
            repeat("n", "map", "heavy", 2),
            repeat("n", "loop", "heavy", 2)
          ] do
        assert accept(proposal([node]), %{"callables" => ["worker"]}) ==
                 {:refused, [reason(["nodes", 0], :callable_not_allowed)]}
      end

      # the same graph with the callable allowed is accepted, at the exact sum
      assert {:ok, %{upper_cost: 100}} = accept(proposal([call("n", "heavy")]))
      assert {:ok, %{upper_cost: 200}} = accept(proposal([repeat("n", "map", "heavy", 2)]))
    end

    test "a tool that resolves in the snapshot of the recipe but not in agent_tools is refused" do
      assert {:resolved, _} = ToolRegistry.resolve(base_facts()["tools"], "mcp_other")

      refute match?(
               {:resolved, _},
               ToolRegistry.resolve(base_context()["agent_tools"], "mcp_other")
             )

      assert accept(proposal([tool("t", "mcp_other")])) ==
               {:refused, [reason(["nodes", 0], :tool_not_allowed)]}

      assert {:ok, %{upper_cost: 7}} = accept(proposal([tool("t", "mcp_fetch")]))
    end

    test "a tool with no cost is refused" do
      assert accept(proposal([tool("t", "mcp_fetch")]), %{"tool_costs" => %{"mcp_other" => 9}}) ==
               {:refused, [reason(["nodes", 0], :tool_cost_unknown)]}
    end

    test "an ask while ask_cost is null is refused" do
      assert accept(proposal([ask("a")]), %{"ask_cost" => nil}) ==
               {:refused, [reason(["nodes", 0], :ask_not_allowed)]}

      assert {:ok, %{upper_cost: 3}} = accept(proposal([ask("a")]))
    end

    test "two faults give two reasons in path order, also at one node in code order" do
      nodes = [
        tool("a", "mcp_other"),
        ask("fine"),
        call("b", "worker"),
        ask("c"),
        call("d", "heavy")
      ]

      assert accept(proposal(nodes), %{"ask_cost" => nil, "callables" => ["worker"]}) ==
               {:refused,
                [
                  reason(["nodes", 0], :tool_not_allowed),
                  reason(["nodes", 1], :ask_not_allowed),
                  reason(["nodes", 3], :ask_not_allowed),
                  reason(["nodes", 4], :callable_not_allowed)
                ]}

      assert accept(proposal([tool("a", "nothing")]), %{"tool_costs" => %{}}) ==
               {:refused,
                [reason(["nodes", 0], :tool_cost_unknown), reason(["nodes", 0], :tool_not_allowed)]}

      # index 2 sorts before index 10
      many = for n <- 0..10, do: call("n#{n}", if(n in [2, 10], do: "heavy", else: "worker"))

      assert accept(proposal(many), %{"callables" => ["worker"], "max_nodes" => 11}) ==
               {:refused,
                [
                  reason(["nodes", 2], :callable_not_allowed),
                  reason(["nodes", 10], :callable_not_allowed)
                ]}
    end

    test "a fault of the agent limits hides the faults of the load-time check" do
      # also a structural fault and an over-cap cost; only the limits are reported
      nodes = [call("a", "heavy"), ask("a")]

      assert accept(proposal(nodes), %{"callables" => ["worker"], "ask_cost" => nil}) ==
               {:refused,
                [
                  reason(["nodes", 0], :callable_not_allowed),
                  reason(["nodes", 1], :ask_not_allowed)
                ]}
    end
  end

  # --- group 3 -------------------------------------------------------------------------

  describe "no_new_authority_and_budget" do
    defp requiring(needs, permissions),
      do: %{"mcp_fetch" => %{"needs" => needs, "permissions" => permissions}}

    test "a tool whose requirement is not declared gives the reason of the check at the node" do
      fetch = proposal([ask("first"), tool("t", "mcp_fetch")])

      assert RuntimeGraph.accept(
               fetch,
               facts(%{"tool_requirements" => requiring(["search"], ["read"])})
               |> Map.put("tool_costs", %{"mcp_fetch" => 7})
             ) ==
               {:refused,
                [
                  reason(["nodes", 1], :need_not_declared),
                  reason(["nodes", 1], :permission_not_declared)
                ]}

      declared = %{"needs" => ["search"], "permissions" => ["read"]}
      with_requirement = %{"tool_requirements" => requiring(["search"], ["read"])}

      # declared, but the host does not provide it: the reason is about the recipe
      assert RuntimeGraph.accept(fetch, Map.put(facts(with_requirement), "declared", declared)) ==
               {:refused,
                [
                  reason(["recipe", "needs", 0], :need_not_provided),
                  reason(["recipe", "permissions", 0], :permission_not_granted)
                ]}

      granted =
        Map.merge(with_requirement, %{
          "provided_needs" => ["search"],
          "granted_permissions" => ["read"]
        })

      assert {:ok, %{upper_cost: 10}} =
               RuntimeGraph.accept(fetch, Map.put(facts(granted), "declared", declared))
    end

    test "an upper cost at the share passes and share plus 1 is over_cap" do
      graph = proposal([call("go", "worker"), tool("t", "mcp_fetch")])
      assert {:ok, %{upper_cost: 17}} = RuntimeGraph.accept(graph, facts(%{"cap" => 17}))

      assert RuntimeGraph.accept(graph, facts(%{"cap" => 16})) ==
               {:refused, [reason([], :over_cap)]}
    end

    test "a map of 256 iterations over a costly callable is over_cap" do
      graph = proposal([repeat("m", "map", "heavy", 256)])

      assert RuntimeGraph.accept(graph, facts(%{"cap" => 1_000})) ==
               {:refused, [reason([], :over_cap)]}

      assert RuntimeGraph.accept(graph, facts(%{"cap" => 25_599})) ==
               {:refused, [reason([], :over_cap)]}

      assert {:ok, %{upper_cost: 25_600}} = RuntimeGraph.accept(graph, facts(%{"cap" => 25_600}))

      loop = proposal([repeat("m", "loop", "heavy", 256)])

      assert RuntimeGraph.accept(loop, facts(%{"cap" => 1_000})) ==
               {:refused, [reason([], :over_cap)]}
    end

    test "the share does not widen what the agent may call" do
      # cheap and within the share, still not in callables
      assert accept(proposal([call("go", "worker")]), %{"callables" => ["heavy"]}) ==
               {:refused, [reason(["nodes", 0], :callable_not_allowed)]}
    end

    test "a reason about the recipe itself gets recipe in front" do
      missing = %{
        "costs" => [
          %{"callable" => "heavy", "estimate" => 100},
          %{"callable" => "choice", "estimate" => 5}
        ]
      }

      assert RuntimeGraph.accept(proposal([]), facts(missing)) ==
               {:refused, [reason(["recipe", "callables", 1], :missing_cost)]}

      # a cost entry that names nothing: the path [] stays
      unknown = %{"costs" => base_facts()["costs"] ++ [%{"callable" => "gone", "estimate" => 1}]}

      assert RuntimeGraph.accept(proposal([]), facts(unknown)) ==
               {:refused, [reason([], :unknown_cost_target)]}
    end

    test "the recipe keeps its bindings and rules; the new callable adds no authority" do
      # a tool that has no requirement entry requires nothing; declared stays what the host gave
      assert {:ok, accepted} = accept(proposal([tool("t", "mcp_fetch")]))
      assert accepted.recipe["root"] == "proposed"
      assert accepted.recipe["bindings"] == base_recipe()["bindings"]
      assert accepted.recipe["rules"] == base_recipe()["rules"]
    end
  end

  # --- group 4 -------------------------------------------------------------------------

  describe "node_and_depth_maximum" do
    defp asks(count), do: for(n <- 1..count, do: ask("n#{n}"))

    test "max_nodes nodes pass and one more is too_many_nodes" do
      assert {:ok, %{upper_cost: 9}} = accept(proposal(asks(3)), %{"max_nodes" => 3})

      assert accept(proposal(asks(4)), %{"max_nodes" => 3}) ==
               {:refused, [reason([], :too_many_nodes)]}

      assert {:ok, %{upper_cost: 192}} = accept(proposal(asks(64)), %{"max_nodes" => 64})

      assert accept(proposal(asks(65)), %{"max_nodes" => 64}) ==
               {:refused, [reason([], :too_many_nodes)]}

      assert {:ok, _} = accept(proposal(asks(1)), %{"max_nodes" => 1})

      assert accept(proposal(asks(2)), %{"max_nodes" => 1}) ==
               {:refused, [reason([], :too_many_nodes)]}
    end

    test "nesting plus depth at max_depth passes and one more is depth_exceeded" do
      # the new graph calls an agent: nesting 2
      two = proposal([call("go", "worker")])
      assert {:ok, _} = accept(two, %{"depth" => 3, "max_depth" => 5})

      assert accept(two, %{"depth" => 4, "max_depth" => 5}) ==
               {:refused, [reason([], :depth_exceeded)]}

      # the new graph calls a graph that calls an agent: nesting 3, through a map and a loop too
      for node <- [call("go", "mid"), repeat("go", "map", "mid", 2), repeat("go", "loop", "mid", 2)] do
        three = proposal([ask("a"), node])
        assert {:ok, _} = accept(three, %{"depth" => 2, "max_depth" => 5})

        assert accept(three, %{"depth" => 3, "max_depth" => 5}) ==
                 {:refused, [reason([], :depth_exceeded)]}
      end

      # no call at all: nesting 1
      assert {:ok, _} = accept(proposal([ask("a")]), %{"depth" => 4, "max_depth" => 5})

      assert accept(proposal([ask("a")]), %{"depth" => 5, "max_depth" => 5}) ==
               {:refused, [reason([], :depth_exceeded)]}

      assert {:ok, _} = accept(proposal([]), %{"depth" => 15, "max_depth" => 16})

      assert accept(proposal([]), %{"depth" => 16, "max_depth" => 16}) ==
               {:refused, [reason([], :depth_exceeded)]}
    end

    test "the longest chain counts, not the first or the widest" do
      wide = proposal([call("a", "worker"), call("b", "mid"), call("c", "heavy")])
      assert {:ok, _} = accept(wide, %{"depth" => 2, "max_depth" => 5})

      assert accept(wide, %{"depth" => 3, "max_depth" => 5}) ==
               {:refused, [reason([], :depth_exceeded)]}
    end

    test "depth_exceeded is only given when the check gave no other reason" do
      costly = proposal([repeat("m", "map", "heavy", 256)])

      assert accept(costly, %{"depth" => 16, "max_depth" => 16}) ==
               {:refused, [reason([], :over_cap)]}
    end

    test "a node that names the new callable itself is callable_not_allowed" do
      assert accept(proposal([call("self", "proposed")])) ==
               {:refused, [reason(["nodes", 0], :callable_not_allowed)]}

      assert accept(proposal([repeat("self", "loop", "proposed", 3)]), %{"callables" => []}) ==
               {:refused, [reason(["nodes", 0], :callable_not_allowed)]}
    end
  end

  # --- group 5 -------------------------------------------------------------------------

  describe "data_only" do
    defp invalid_shape?(proposal, overrides \\ %{}),
      do: assert(accept(proposal, overrides) == {:refused, [reason([], :invalid_shape)]})

    test "a sixth key, a missing key and a proposal that is no map are refused" do
      invalid_shape?(Map.put(proposal([ask("a")]), "code", "System.halt()"))
      invalid_shape?(Map.put(proposal([ask("a")]), "name", "other"))
      invalid_shape?(Map.delete(proposal([ask("a")]), "links"))
      invalid_shape?(%{})
      invalid_shape?(nil)
      invalid_shape?([])
      invalid_shape?("nodes")
      invalid_shape?(%URI{})
      invalid_shape?(Map.put(proposal([]), "nodes", %{}))
      invalid_shape?(Map.put(proposal([]), "links", "none"))
      invalid_shape?(Map.put(proposal([]), "input_slots", nil))
    end

    test "a key code inside a node is refused by the checker as an unknown key" do
      invalid_shape?(proposal([Map.put(ask("a"), "code", "run")]))
    end

    test "a function, a tuple and other data that is not JSON are refused" do
      bad = [
        fn -> :run end,
        &Kernel.+/2,
        {:run, 1},
        {},
        :run,
        self(),
        make_ref(),
        <<255>>,
        %URI{},
        %{run: 1},
        %{1 => 2},
        [1 | 2]
      ]

      for value <- bad do
        invalid_shape?(proposal([Map.put(ask("a"), "extra", value)]))
        invalid_shape?(Map.put(proposal([ask("a")]), "input", value))
        invalid_shape?(Map.put(proposal([ask("a")]), "links", [value]))
      end

      # inside a nested value
      invalid_shape?(proposal([Map.put(ask("a"), "extra", %{"deep" => [1, [fn -> 1 end]]})]))
    end

    test "an entry of nodes that is not a map with a string kind is refused" do
      for entry <- ["ask", nil, [], %{"id" => "a"}, %{"id" => "a", "kind" => :ask}, %{"kind" => 1}] do
        invalid_shape?(proposal([entry]))
      end
    end

    test "a node that carries code is refused in stage 1 before any limit is read" do
      nodes = [call("a", "heavy"), Map.put(ask("b"), "extra", fn -> 1 end)]

      assert accept(proposal(nodes), %{"callables" => ["worker"]}) ==
               {:refused, [reason([], :invalid_shape)]}
    end

    test "an over-long text is refused; the byte bound is exact" do
      long = Map.put(ask("a"), "extra", String.duplicate("x", 70_000))
      assert accept(proposal([long])) == {:refused, [reason([], :too_large)]}

      assert accept(Map.put(proposal([ask("a")]), "links", [String.duplicate("x", 70_000)])) ==
               {:refused, [reason([], :too_large)]}

      # a text of 129 bytes in an id is within the proposal bound but refused by the checker
      invalid_shape?(proposal([ask(String.duplicate("i", 129))]))
      invalid_shape?(proposal([ask("")]))

      padded = fn n -> proposal([Map.put(ask("a"), "pad", String.duplicate("x", n))]) end
      size = fn proposal -> byte_size(Jason.encode!(proposal)) end
      n = 65_536 - size.(padded.(0))

      assert size.(padded.(n)) == 65_536
      assert accept(padded.(n)) == {:refused, [reason([], :invalid_shape)]}
      assert size.(padded.(n + 1)) == 65_537
      assert accept(padded.(n + 1)) == {:refused, [reason([], :too_large)]}

      # many small values are too large too, before a list is walked to its end
      many = Map.put(proposal([ask("a")]), "links", List.duplicate(1, 100_000))
      assert accept(many) == {:refused, [reason([], :too_large)]}
      wide = Map.put(proposal([ask("a")]), "links", [Map.new(1..30_000, &{"k#{&1}", 1})])
      assert accept(wide) == {:refused, [reason([], :too_large)]}
    end

    test "a structural fault of the checker is refused with its atom at the root" do
      # a need with no giver
      need = %{"name" => "value", "schema_id" => "value", "schema_version" => 1}

      assert accept(proposal([node("a", "ask", %{"needs" => [need]})])) ==
               {:refused, [reason([], :missing_giver)]}

      # a cycle
      assert accept(proposal([ask("a"), ask("b")], [link("a", "b"), link("b", "a")])) ==
               {:refused, [reason([], :cycle)]}

      # a decision with a missing branch
      choose = node("choose", "decision", %{"callable" => "choice"})

      assert accept(
               proposal([choose, ask("yes")], [
                 link("choose", "yes", "choice", %{"choice" => "yes"})
               ])
             ) ==
               {:refused, [reason([], :invalid_branch)]}

      # a link to a node that is not there; a node id repeated; an unknown kind
      assert accept(proposal([ask("a")], [link("a", "gone")])) ==
               {:refused, [reason([], :unknown_name)]}

      invalid_shape?(proposal([ask("a"), ask("a")]))
      invalid_shape?(proposal([node("a", "shell")]))
    end

    test "a proposal that carries code in any form is never accepted" do
      for node <- [
            node("a", "shell", %{"command" => "rm -rf"}),
            Map.put(ask("a"), "script", "x"),
            Map.put(call("a", "worker"), "eval", "x"),
            Map.put(tool("a", "mcp_fetch"), "module", "Elixir.Kernel")
          ] do
        assert {:refused, [%{path: [], code: :invalid_shape}]} = accept(proposal([node]))
      end
    end
  end

  # --- group 6 -------------------------------------------------------------------------

  describe "reasons_as_content" do
    @codes ~w(
      invalid_shape too_large too_many_nodes callable_not_allowed tool_not_allowed
      tool_cost_unknown ask_not_allowed depth_exceeded unknown_tool need_not_declared
      permission_not_declared need_not_provided permission_not_granted missing_cost
      unknown_cost_target over_cap unsupported_version invalid_schema unknown_name cycle
      missing_giver invalid_branch invalid_outcome invalid_rule
    )a

    test "render of one reason of each code" do
      for code <- @codes do
        assert RuntimeGraph.render([reason(["nodes", 2], code)]) ==
                 "graph refused:\n$.nodes[2]: #{code}"
      end

      assert RuntimeGraph.render([reason([], :cycle)]) == "graph refused:\n$: cycle"

      assert RuntimeGraph.render([reason(["recipe", "callables", 12, "nodes", 0], :missing_cost)]) ==
               "graph refused:\n$.recipe.callables[12].nodes[0]: missing_cost"

      assert RuntimeGraph.render([reason(["nodes", 0], :tool_not_allowed), reason([], :over_cap)]) ==
               "graph refused:\n$.nodes[0]: tool_not_allowed\n$: over_cap"

      text = RuntimeGraph.render([reason([], :cycle)])
      assert String.valid?(text)
      assert String.starts_with?(text, "graph refused:")
    end

    test "64 reasons are all shown and 65 give and 1 more" do
      reasons = fn count ->
        for n <- 0..(count - 1), do: reason(["nodes", n], :callable_not_allowed)
      end

      sixty_four = RuntimeGraph.render(reasons.(64))
      assert length(String.split(sixty_four, "\n")) == 65
      assert sixty_four =~ "$.nodes[63]: callable_not_allowed"
      refute sixty_four =~ "more"

      sixty_five = RuntimeGraph.render(reasons.(65))
      lines = String.split(sixty_five, "\n")
      assert length(lines) == 66
      assert List.last(lines) == "and 1 more"
      refute sixty_five =~ "$.nodes[64]"
      assert Enum.at(lines, 64) == "$.nodes[63]: callable_not_allowed"

      assert RuntimeGraph.render(reasons.(300)) |> String.split("\n") |> List.last() ==
               "and 236 more"

      assert RuntimeGraph.render([]) == "graph refused:"
    end

    test "a value that is not a list of reasons is invalid_input" do
      good = reason(["nodes", 0], :cycle)

      for bad <- [
            :reasons,
            nil,
            "graph refused:",
            %{},
            [1],
            [good, :cycle],
            [good | good],
            [%{path: [], code: :unlisted}],
            [%{path: [], code: "cycle"}],
            [%{path: ["Nodes"], code: :cycle}],
            [%{path: ["a\nb"], code: :cycle}],
            [%{path: ["x y"], code: :cycle}],
            [%{path: [""], code: :cycle}],
            [%{path: [String.duplicate("a", 33)], code: :cycle}],
            [%{path: [-1], code: :cycle}],
            [%{path: [1.0], code: :cycle}],
            [%{path: [:nodes], code: :cycle}],
            [%{path: "nodes", code: :cycle}],
            [%{path: ["nodes" | 1], code: :cycle}],
            [%{path: List.duplicate("a", 17), code: :cycle}],
            [%{path: [], code: :cycle, extra: 1}],
            [%{code: :cycle}],
            [%URI{}]
          ] do
        assert RuntimeGraph.render(bad) == {:error, :invalid_input}
      end
    end

    test "a sentinel in the proposal, a tool name and the context never appears" do
      sentinel = "SENTINEL-8f3a"

      logged =
        capture_log(fn ->
          refused = [
            # in a node: id, tool name, a key and an extra value
            accept(proposal([Map.put(ask(sentinel), sentinel, sentinel)]), %{"callables" => []}),
            accept(proposal([tool(sentinel, sentinel <> "-tool")]), %{"tool_costs" => %{}}),
            accept(proposal([call(sentinel, sentinel <> "-callable")])),
            accept(Map.put(proposal([ask("a")]), sentinel, sentinel)),
            accept(proposal([Map.put(ask("a"), "x", {sentinel})])),
            accept(proposal([ask("a")]), %{"name" => sentinel, "ask_cost" => nil}),
            accept(proposal([ask("a")]), %{"name" => sentinel, "max_depth" => 1, "depth" => 1})
          ]

          errors = [
            accept(proposal([ask("a")]), %{"name" => sentinel, "extra" => sentinel}),
            accept(proposal([ask("a")]), %{
              "name" => "worker",
              "declared" => %{"needs" => [sentinel]}
            }),
            accept(proposal([ask("a")]), %{"tool_costs" => %{sentinel => 0}}),
            accept(proposal([ask("a")]), %{"callables" => [sentinel]}),
            accept(proposal([ask("a")]), %{"facts" => %{sentinel => sentinel}}),
            accept(proposal([ask("a")]), %{"agent_tools" => {sentinel}}),
            accept(proposal([ask("a")]), %{
              "recipe" => %{"callables" => [%{"name" => sentinel}]},
              "name" => sentinel
            })
          ]

          assert Enum.all?(errors, &(&1 == {:error, :invalid_context}))
          assert Enum.all?(refused, &match?({:refused, [_ | _]}, &1))

          for {:refused, reasons} <- refused do
            refute inspect(reasons) =~ sentinel
            refute RuntimeGraph.render(reasons) =~ sentinel
            assert Enum.all?(reasons, &(Map.keys(&1) |> Enum.sort() == [:code, :path]))

            assert Enum.all?(reasons, fn %{path: path} ->
                     Enum.all?(
                       path,
                       &(is_integer(&1) or &1 in ~w(nodes recipe callables needs permissions))
                     )
                   end)
          end

          refute inspect(errors) =~ sentinel
        end)

      assert logged == ""
    end

    defp invalid_context?(overrides),
      do: assert(accept(proposal([ask("a")]), overrides) == {:error, :invalid_context})

    test "each malformed member of the context is invalid_context" do
      assert RuntimeGraph.accept(proposal([ask("a")]), "context") == {:error, :invalid_context}
      assert RuntimeGraph.accept(proposal([ask("a")]), %URI{}) == {:error, :invalid_context}
      assert RuntimeGraph.accept(proposal([ask("a")]), []) == {:error, :invalid_context}

      for key <- Map.keys(base_context()) do
        assert RuntimeGraph.accept(proposal([ask("a")]), Map.delete(base_context(), key)) ==
                 {:error, :invalid_context}
      end

      assert RuntimeGraph.accept(proposal([ask("a")]), Map.put(base_context(), "extra", 1)) ==
               {:error, :invalid_context}

      # recipe
      for bad <- [
            nil,
            "recipe",
            [],
            %URI{},
            %{},
            %{"callables" => :none},
            %{"callables" => ["x"]},
            %{"callables" => [%{}]},
            %{"callables" => [%{"name" => 1}]},
            %{"callables" => [%{"name" => "a"} | %{}]}
          ],
          do: invalid_context?(%{"recipe" => bad, "callables" => []})

      sixty_five = for n <- 1..65, do: %{"name" => "c#{n}"}

      invalid_context?(%{
        "recipe" => Map.put(base_recipe(), "callables", sixty_five),
        "callables" => []
      })

      # name
      for bad <- [nil, :proposed, "", String.duplicate("n", 129), <<255>>, 7, "worker", "main"],
          do: invalid_context?(%{"name" => bad})

      assert {:ok, _} = accept(proposal([ask("a")]), %{"name" => String.duplicate("n", 128)})
      assert {:ok, _} = accept(proposal([ask("a")]), %{"name" => "n"})

      # callables
      for bad <- [
            nil,
            "worker",
            [1],
            [""],
            ["worker", "worker"],
            ["nothing"],
            ["worker" | "heavy"],
            %{},
            [String.duplicate("w", 129)]
          ],
          do: invalid_context?(%{"callables" => bad})

      assert {:ok, _} = accept(proposal([ask("a")]), %{"callables" => []})
      assert {:ok, _} = accept(proposal([ask("a")]), %{"callables" => ["worker"]})

      # agent_tools
      for bad <- [
            nil,
            :snapshot,
            {:ToolRegistry, :s, %{}, %{}},
            {:ToolRegistry, [], [], %{}},
            {:ToolRegistry, [], %{}, :r},
            {:ToolRegistry, [], %{}}
          ],
          do: invalid_context?(%{"agent_tools" => bad})

      # declared and facts, by the check of the recipe
      for bad <- [
            nil,
            [],
            %{},
            %{"needs" => []},
            %{"needs" => [], "permissions" => [], "x" => []},
            %{"needs" => ["a", "a"], "permissions" => []}
          ],
          do: invalid_context?(%{"declared" => bad})

      for key <- Map.keys(base_facts()) do
        invalid_context?(%{"facts" => Map.delete(base_facts(), key)})
      end

      invalid_context?(%{"facts" => nil})
      invalid_context?(%{"facts" => Map.put(base_facts(), "cap", 0)})
      invalid_context?(%{"facts" => Map.put(base_facts(), "costs", [%{"callable" => "w"}])})

      # tool_costs
      for bad <- [
            nil,
            [],
            %URI{},
            %{"" => 1},
            %{"a" => 0},
            %{"a" => -1},
            %{"a" => 1.0},
            %{"a" => "1"},
            %{"a" => @max_estimate + 1},
            %{1 => 1},
            %{<<255>> => 1},
            %{String.duplicate("t", 129) => 1}
          ],
          do: invalid_context?(%{"tool_costs" => bad})

      many = fn count -> for n <- 1..count, into: %{}, do: {"tool#{n}", 1} end
      invalid_context?(%{"tool_costs" => many.(1_001)})
      assert {:ok, _} = accept(proposal([ask("a")]), %{"tool_costs" => many.(1_000)})
      assert {:ok, _} = accept(proposal([ask("a")]), %{"tool_costs" => %{"a" => @max_estimate}})

      # ask_cost
      for bad <- [0, -1, "3", 1.5, :none, @max_estimate + 1],
          do: invalid_context?(%{"ask_cost" => bad})

      for ok <- [nil, 1, @max_estimate],
          do: assert({:ok, _} = accept(proposal([]), %{"ask_cost" => ok}))

      # max_nodes, max_depth, depth
      for {key, max} <- [{"max_nodes", 64}, {"max_depth", 16}, {"depth", 16}] do
        for bad <- [0, -1, max + 1, 1.0, "1", nil], do: invalid_context?(%{key => bad})
      end

      assert {:ok, _} = accept(proposal([]), %{"max_nodes" => 64, "max_depth" => 16, "depth" => 1})
      assert {:ok, _} = accept(proposal([]), %{"max_nodes" => 1, "max_depth" => 16, "depth" => 15})
    end

    test "a fault of the host is reported before any verdict on the graph" do
      broken = Map.put(proposal([ask("a")]), "code", "x")

      assert RuntimeGraph.accept(broken, Map.delete(base_context(), "depth")) ==
               {:error, :invalid_context}

      assert RuntimeGraph.accept(broken, Map.put(base_context(), "facts", nil)) ==
               {:error, :invalid_context}

      assert RuntimeGraph.accept(:not_a_proposal, Map.put(base_context(), "ask_cost", 0)) ==
               {:error, :invalid_context}
    end

    test "costs that the new graph adds past the bound of the check are a fault of the host" do
      filler = for n <- 1..1_061, do: %{"callable" => "extra#{n}", "estimate" => 1}
      full = Map.put(base_facts(), "costs", base_facts()["costs"] ++ filler)
      assert length(full["costs"]) == 1_064

      assert RuntimeGraph.accept(proposal([tool("t", "mcp_fetch")]), context(%{"facts" => full})) ==
               {:error, :invalid_context}
    end
  end

  # --- group 7 -------------------------------------------------------------------------

  describe "same_input_same_verdict" do
    defp spawn_result(fun) do
      parent = self()
      ref = make_ref()
      spawn(fn -> send(parent, {ref, fun.()}) end)
      assert_receive {^ref, result}
      result
    end

    test "20 calls and a call in a second process give equal results; proposal and context are not changed" do
      accepted = {three_nodes(), context()}

      refused =
        {proposal([call("go", "heavy"), tool("t", "mcp_other")]),
         context(%{"callables" => ["worker"]})}

      for {proposal, context} <- [accepted, refused] do
        copies = {proposal, context}
        first = RuntimeGraph.accept(proposal, context)

        assert for(_ <- 1..20, do: RuntimeGraph.accept(proposal, context)) ==
                 List.duplicate(first, 20)

        assert Task.await(Task.async(fn -> RuntimeGraph.accept(proposal, context) end)) == first
        assert spawn_result(fn -> RuntimeGraph.accept(proposal, context) end) == first
        assert {proposal, context} == copies
      end

      assert {:ok, %{upper_cost: 20}} = RuntimeGraph.accept(elem(accepted, 0), elem(accepted, 1))

      assert RuntimeGraph.accept(elem(refused, 0), elem(refused, 1)) ==
               {:refused,
                [
                  reason(["nodes", 0], :callable_not_allowed),
                  reason(["nodes", 1], :tool_not_allowed)
                ]}

      {:refused, reasons} = RuntimeGraph.accept(elem(refused, 0), elem(refused, 1))
      assert spawn_result(fn -> RuntimeGraph.render(reasons) end) == RuntimeGraph.render(reasons)
    end

    test "the checked example" do
      {result, _} = Code.eval_file(Path.expand("../../examples/runtime_graph.exs", __DIR__))
      assert result == :ok
    end
  end
end
