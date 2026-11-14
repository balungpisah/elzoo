# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/recipe_test_helper.exs", __DIR__)

defmodule Elzoo.RecipeTestLuaTest do
  use ExUnit.Case, async: false
  import Kernel, except: [node: 3]
  alias Elzoo.RecipeTest
  alias Elzoo.RecipeTest.{ModelBinding, ScriptedAdapter, ToolBinding}

  setup_all do
    pid = Elzoo.RunEngine.TestHelper.database()
    {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.TestRegistry)
    {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.UnitRegistry)
    for p <- [registry, units], do: Process.unlink(p)

    directory =
      Path.join(System.tmp_dir!(), "recipe-test-sandbox-#{System.unique_integer([:positive])}")

    File.rm_rf!(directory)

    on_exit(fn ->
      File.rm_rf!(directory)
      for p <- [registry, units, pid], Process.alive?(p), do: Supervisor.stop(p)
    end)

    {:ok, executable} = Elzoo.LuaSandbox.build(Mix.Project.deps_paths()[:lua_source], directory)
    {:ok, executable: executable}
  end

  ## Package, recipe and spec builders: every package, script and manifest is a literal

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

  defp callable(name, kind, extra),
    do:
      Map.merge(
        %{"name" => name, "kind" => kind, "input" => typed("input"), "output" => typed("output")},
        extra
      )

  defp slot(name), do: %{"name" => name, "schema_id" => "value", "schema_version" => 1}

  defp node(id, kind, needs, gives, extra),
    do:
      Map.merge(
        %{
          "id" => id,
          "kind" => kind,
          "needs" => Enum.map(needs, &slot/1),
          "gives" => Enum.map(gives, &slot/1)
        },
        extra
      )

  defp data(from, give, to, need),
    do: %{"from" => from, "to" => to, "kind" => "data", "give" => give, "need" => need}

  defp canonical(value), do: Jason.encode!(ordered(value))

  defp ordered(value) when is_map(value),
    do: %Jason.OrderedObject{values: for({k, v} <- Enum.sort(value), do: {k, ordered(v)})}

  defp ordered(value) when is_list(value), do: Enum.map(value, &ordered/1)
  defp ordered(value), do: value

  defp package(graph) do
    package = %{
      "format_version" => 1,
      "name" => "package",
      "version" => "opaque",
      "needs" => [],
      "permissions" => [],
      "graph" => graph,
      "settings" => %{
        "version" => 1,
        "id" => "independent-settings",
        "revision" => 1,
        "port" => typed("input")["port"],
        "secrets" => [],
        "schema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      },
      "skills" => []
    }

    hash = :crypto.hash(:sha256, canonical(package))
    Map.put(package, "identity", "recipe-package-v1:sha256:" <> Base.encode16(hash, case: :lower))
  end

  defp recipe(callables) do
    %{
      "version" => 1,
      "id" => "recipe",
      "revision" => 1,
      "root" => hd(callables)["name"],
      "callables" => callables,
      "bindings" => [%{"name" => "worker", "target" => "agent-config"}],
      "rules" => []
    }
  end

  defp tool(name),
    do: %{
      "trust" => "untrusted",
      "name" => name,
      "description" => "Tool " <> name,
      "input_schema" => %{"type" => "object"},
      "annotations" => nil
    }

  defp files(names),
    do: %{
      "id" => "files",
      "kind" => "other",
      "callable" => "adapter",
      "tools" => Enum.map(names, &tool/1)
    }

  # A source whose tools are nested callables; the alias of a tool is `<id>_<name>`.
  defp nested_source(id, names),
    do: %{
      "id" => id,
      "kind" => "other",
      "callable" => "nested",
      "tools" => Enum.map(names, &tool/1)
    }

  defp facts(costs),
    do: %{
      "provided_needs" => [],
      "granted_permissions" => [],
      "tool_requirements" => %{},
      "unit" => "credits",
      "costs" => costs,
      "cap" => 1_000
    }

  defp cost(callable, estimate), do: %{"callable" => callable, "estimate" => estimate}

  defp cost(callable, node, estimate),
    do: %{"callable" => callable, "node" => node, "estimate" => estimate}

  defp agent_config,
    do: %{
      model: "scripted-model",
      max_output_tokens: 256,
      role_instructions: ["Answer."],
      window: %{
        provider_id: "scripted",
        model_id: "scripted-model",
        size: 100_000,
        unit: :tokens,
        estimator_id: "recipe-test-bytes",
        estimator_version: 1
      },
      max_request_bytes: 65_536,
      max_image_refs: 0,
      result_limits: %{max_bytes: 4_096, artifact_max_bytes: 1_048_576},
      turn_limit: 4
    }

  defp answer(text),
    do: {:completed, %{"content" => text, "finish" => "stop", "tool_proposals" => []}}

  defp tool_turn(name, arguments),
    do:
      {:completed,
       %{
         "content" => "",
         "finish" => "tool_calls",
         "tool_proposals" => [
           %{"id" => "c1", "name" => name, "arguments" => arguments, "malformed" => nil}
         ]
       }}

  defp base_spec(package, facts, sources, script, input, executable, tools),
    do: %{
      package: package,
      facts: facts,
      sources: sources,
      agents: %{"agent-config" => agent_config()},
      decisions: %{},
      script: script,
      effects: %{model: ModelBinding, tool: ToolBinding},
      adapters: [ScriptedAdapter],
      input: input,
      tools: tools,
      executable: executable,
      restart_after: nil
    }

  ## The Lua tool: one module function `add`, offered by the source `calc`

  defp port(id, direction),
    do: %{"id" => id, "direction" => direction, "schema_id" => "calc.add", "schema_version" => 1}

  defp n_schema,
    do: %{
      "type" => "object",
      "properties" => %{"n" => %{"type" => "integer"}},
      "required" => ["n"],
      "additionalProperties" => false
    }

  defp add_manifest,
    do: %{
      "name" => "add",
      "version" => 1,
      "description" => "Add one to a number",
      "arguments" => %{"port" => port("add_input", "input"), "schema" => n_schema()},
      "result" => %{"port" => port("add_output", "output"), "schema" => n_schema()},
      "cost" => %{"unit" => "call", "estimate" => 1},
      "permissions" => []
    }

  defp lua_entry(overrides \\ %{}),
    do:
      Map.merge(
        %{
          kind: :lua,
          source: "return function(input) return {total = bindings.add({n = input.n}).n + 1} end",
          limits: %{
            "steps" => 10_000,
            "call_depth" => 8,
            "value_bytes" => 1_024,
            "memory_bytes" => 1_048_576,
            "wall_ms" => 500
          },
          declaration: [%{"name" => "add", "version" => 1}],
          manifests: [add_manifest()],
          source_id: "calc",
          max_calls: 4
        },
        overrides
      )

  # The alias of the Lua tool in the Run is `luat_sum`; its module call is `calc_add`.
  defp lua_sources, do: [nested_source("luat", ["sum"])]

  # A root agent that calls the Lua tool once and then answers.
  defp lua_agent_spec(executable, script \\ nil, entry \\ lua_entry()) do
    script =
      script ||
        %{
          {:model, "scripted-model"} => [tool_turn("luat_sum", %{"n" => 1}), answer("Done.")],
          {:tool, "calc_add"} => [{:completed, %{"n" => 2}}]
        }

    graph = recipe([callable("main", "agent", %{"binding" => "worker"})])

    base_spec(
      package(graph),
      facts([cost("main", 5)]),
      lua_sources(),
      script,
      "Add.",
      executable,
      %{"luat_sum" => entry}
    )
  end

  # A root graph whose one tool node is the Lua tool.
  defp lua_graph_spec(executable) do
    main =
      callable("main", "graph", %{
        "nodes" => [node("t", "tool", ["n"], ["total"], %{"tool" => "luat_sum"})],
        "links" => [data("$input", "n", "t", "n")],
        "input_slots" => [slot("n")]
      })

    base_spec(
      package(recipe([main])),
      facts([cost("main", "t", 2)]),
      lua_sources(),
      %{{:tool, "calc_add"} => [{:completed, %{"n" => 2}}]},
      %{"n" => 1},
      executable,
      %{"luat_sum" => lua_entry()}
    )
  end

  defp child_id(depth, parent_action_id) do
    hex = :crypto.hash(:sha256, parent_action_id) |> Base.encode16(case: :lower)
    "d#{depth}x" <> binary_part(hex, 0, 24)
  end

  defp actions(record),
    do: for(%{step: :action, action: action} <- record.steps, into: %{}, do: {action["id"], action})

  # The text as it stands inside a JSON string.
  defp in_json(text), do: text |> Jason.encode!() |> String.slice(1..-2//1)

  ## Group 1

  describe "tool_start_refusals" do
    defp refused(spec, reason), do: assert(RecipeTest.run(spec) == {:error, reason})

    test "a nested tool with no entry, and an entry that names no nested tool, are unbound_tool",
         %{executable: executable} do
      spec = lua_agent_spec(executable)
      refused(%{spec | tools: %{}}, {:unbound_tool, "luat_sum"})
      refused(%{spec | tools: Map.put(spec.tools, "ghost", lua_entry())}, {:unbound_tool, "ghost"})

      # Ascending: `ghost` comes before `luat_sum`, whose entry is not looked at.
      refused(
        %{spec | tools: %{"ghost" => lua_entry(), "luat_sum" => lua_entry(%{max_calls: 999})}},
        {:unbound_tool, "ghost"}
      )

      refused(
        %{spec | sources: spec.sources ++ [files(["read"])], tools: %{"files_read" => lua_entry()}},
        {:unbound_tool, "files_read"}
      )
    end

    test "each call that does not give ok is invalid_tool with its whole result",
         %{executable: executable} do
      spec = lua_agent_spec(executable)

      # resolve/2: the declared function has no manifest
      refused(
        %{
          spec
          | tools: %{
              "luat_sum" => lua_entry(%{declaration: [%{"name" => "ghost", "version" => 1}]})
            }
        },
        {:invalid_tool, "luat_sum", {:refused, [%{name: "ghost", code: :unknown_function}]}}
      )

      # source/2: the source id is not a registry id
      refused(
        %{spec | tools: %{"luat_sum" => lua_entry(%{source_id: "not an id"})}},
        {:invalid_tool, "luat_sum", {:error, :invalid_input}}
      )

      # LuaTool.new/1: max_calls is over 256
      refused(
        %{spec | tools: %{"luat_sum" => lua_entry(%{max_calls: 257})}},
        {:invalid_tool, "luat_sum", {:error, :invalid_spec}}
      )
    end

    test "a graph entry whose sources the registry refuses is invalid_tool sources" do
      graph_entry = %{
        kind: :graph,
        sources: [:bad],
        callables: [],
        tool_costs: %{},
        max_nodes: 4,
        max_depth: 2,
        cap: 100
      }

      spec =
        base_spec(
          package(recipe([callable("main", "agent", %{"binding" => "worker"})])),
          facts([cost("main", 5)]),
          [nested_source("grph", ["run"])],
          %{},
          "Go.",
          nil,
          %{"grph_run" => graph_entry}
        )

      {:error, reason} = Elzoo.ToolRegistry.snapshot([:bad])
      refused(spec, {:invalid_tool, "grph_run", {:sources, reason}})
    end

    test "a Lua entry without an executable, and a restart_after of 0, are invalid_spec",
         %{executable: executable} do
      spec = lua_agent_spec(executable)
      refused(%{spec | executable: nil}, :invalid_spec)
      refused(%{spec | executable: 1}, :invalid_spec)
      refused(%{spec | restart_after: 0}, :invalid_spec)
      refused(%{spec | restart_after: -1}, :invalid_spec)
      refused(%{spec | restart_after: "1"}, :invalid_spec)
      refused(%{spec | tools: %{"luat_sum" => %{kind: :lua}}}, :invalid_spec)
      refused(%{spec | tools: %{"luat_sum" => %{kind: :other}}}, :invalid_spec)
      refused(%{spec | tools: [:none]}, :invalid_spec)
    end
  end

  ## Group 2

  describe "lua_tool_module_call" do
    test "an agent calls the Lua tool, which makes one module call", %{executable: executable} do
      assert {:ok, record} = RecipeTest.run(lua_agent_spec(executable))
      assert record.asked == %{{:model, "scripted-model"} => 2, {:tool, "calc_add"} => 1}

      child = child_id(2, "d1:t:1:1")
      actions = actions(record)

      value = %{"total" => 3}

      assert %{
               "kind" => "finish",
               "schema_id" => "elzoo.agent-loop.tool-result",
               "payload" => %{"content" => %{"content" => content}}
             } = actions[child <> ":finish"]

      assert content == canonical(value)
      assert Jason.encode!(actions["d1:m:2"]["payload"]) =~ in_json(canonical(value))
      assert record.outcome == :completed
      assert record.unused == %{}
      assert record.restarted == false

      assert actions |> Map.keys() |> Enum.sort() ==
               Enum.sort([
                 "d1:m:1",
                 "d1:t:1:1",
                 "d1:m:2",
                 "d1:finish",
                 child <> ":r:1",
                 child <> ":c:0",
                 child <> ":r:2",
                 child <> ":finish"
               ])

      assert %{"kind" => "local_work", "schema_id" => "elzoo.lua-tool.run"} =
               actions[child <> ":r:1"]

      assert %{"kind" => "tool_call", "schema_id" => "elzoo.lua-tool.module-call"} =
               call = actions[child <> ":c:0"]

      assert call["payload"]["alias"] == "calc_add"
      assert call["payload"]["arguments"] == %{"n" => 1}

      assert [%{"name" => "add", "arguments" => %{"n" => 1}, "result" => %{"n" => 2}}] =
               actions[child <> ":r:2"]["payload"]["calls"]["recorded"]

      assert actions[child <> ":r:1"]["payload"]["calls"]["recorded"] == []

      nested = for %{step: :nested} = step <- record.steps, do: Map.delete(step, :step)

      assert [
               %{
                 schema_id: "elzoo.lua-tool.input",
                 schema_version: 1,
                 payload: %{"input" => %{"n" => 1}}
               }
             ] = nested

      modules =
        for %{step: :input, input: %{"kind" => "action_outcome", "action_id" => id} = input} <-
              record.steps,
            id == child <> ":c:0",
            do: input

      assert [%{"outcome" => "completed", "payload" => %{"result" => %{"n" => 2}}}] = modules
    end

    test "a root graph tool node gives the object of the Lua tool", %{executable: executable} do
      assert {:ok, record} = RecipeTest.run(lua_graph_spec(executable))
      assert record.asked == %{{:tool, "calc_add"} => 1}

      child = child_id(2, "d1:n:t")
      actions = actions(record)

      assert %{"schema_id" => "elzoo.graph-run.node-result", "payload" => finish} =
               actions[child <> ":finish"]

      assert finish == %{"gives" => %{"total" => 3}}
      assert record.outcome == :completed
      assert record.unused == %{}

      assert actions |> Map.keys() |> Enum.sort() ==
               Enum.sort([
                 "d1:n:t",
                 "d1:finish",
                 child <> ":r:1",
                 child <> ":c:0",
                 child <> ":r:2",
                 child <> ":finish"
               ])

      assert %{
               "schema_id" => "elzoo.graph-run.node-result",
               "payload" => %{"gives" => %{"total" => 3}}
             } =
               actions[child <> ":finish"]

      assert [%{"name" => "add"}] = actions[child <> ":r:2"]["payload"]["calls"]["recorded"]

      assert %{"status" => "completed", "gives" => %{"total" => 3}} =
               actions["d1:finish"]["payload"]
    end
  end

  ## Group 4

  describe "model_graph_refused" do
    defp graph_entry,
      do: %{
        kind: :graph,
        sources: [files(["read"])],
        callables: [],
        tool_costs: %{"files_read" => 2},
        max_nodes: 4,
        max_depth: 2,
        cap: 100
      }

    defp typed_graph(nodes),
      do: %{
        "nodes" => nodes,
        "links" => [],
        "input_slots" => [],
        "input" => typed("input"),
        "output" => typed("output")
      }

    test "a graph with a tool outside the entry's sources is refused and no node runs" do
      write = node("w", "tool", [], [], %{"tool" => "files_write"})
      arguments = %{"graph" => typed_graph([write]), "input" => %{}}

      script = %{
        {:model, "scripted-model"} => [tool_turn("grph_run", arguments), answer("Done.")]
      }

      spec =
        base_spec(
          package(recipe([callable("main", "agent", %{"binding" => "worker"})])),
          facts([cost("main", 5)]),
          [files(~w(read write)), nested_source("grph", ["run"])],
          script,
          "Go.",
          nil,
          %{"grph_run" => graph_entry()}
        )

      assert {:ok, record} = RecipeTest.run(spec)
      assert record.outcome == :completed
      assert record.unused == %{}
      assert record.asked == %{{:model, "scripted-model"} => 2}

      child = child_id(2, "d1:t:1:1")
      actions = actions(record)
      child_actions = for {id, _} <- actions, String.starts_with?(id, child <> ":"), do: id
      assert child_actions == [child <> ":finish"]

      assert %{
               "schema_id" => "elzoo.agent-loop.tool-result",
               "payload" => %{
                 "content" => %{"content" => content, "sources" => ["recipe-test:graph"]}
               }
             } = actions[child <> ":finish"]

      assert String.starts_with?(content, "graph refused:")
      assert Jason.encode!(actions["d1:m:2"]["payload"]) =~ in_json(content)
    end
  end

  ## Group 5

  describe "same_lua_spec_same_record" do
    test "the agent spec of the Lua tool gives two equal records", %{executable: executable} do
      assert {:ok, first} = RecipeTest.run(lua_agent_spec(executable))
      assert {:ok, second} = RecipeTest.run(lua_agent_spec(executable))
      assert first.outcome == :completed
      assert first == second
    end
  end
end
