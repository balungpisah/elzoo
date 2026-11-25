# SPDX-License-Identifier: Apache-2.0
Code.require_file("../pieces/runtime/recipe-test/test/support/recipe_test_helper.exs", __DIR__)

defmodule Elzoo.FirstReleaseRecipeTest do
  use ExUnit.Case, async: false
  alias Elzoo.RecipeTest
  alias Elzoo.RecipeTest.{ModelBinding, ScriptedAdapter, ToolBinding}

  @tag :tmp_dir
  test "a graph calls an agent that uses a Lua tool and returns its answer", %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
    repo = Elzoo.RunEngine.TestHelper.database()
    on_exit(fn -> Supervisor.stop(repo) end)
    start_supervised!({Registry, keys: :unique, name: Elzoo.RunEngine.TestRegistry})
    start_supervised!({Registry, keys: :unique, name: Elzoo.RunEngine.UnitRegistry})
    {:ok, executable} = Elzoo.LuaSandbox.build(Mix.Project.deps_paths()[:lua_source], dir)

    spec = %{
      package: package(),
      facts: %{
        "provided_needs" => [],
        "granted_permissions" => [],
        "tool_requirements" => %{},
        "unit" => "credits",
        "costs" => [%{"callable" => "agent", "estimate" => 5}],
        "cap" => 100
      },
      sources: [
        %{
          "id" => "lua",
          "kind" => "other",
          "callable" => "nested",
          "tools" => [
            %{
              "trust" => "untrusted",
              "name" => "total",
              "description" => "Compute the total",
              "input_schema" => %{"type" => "object"},
              "annotations" => nil
            }
          ]
        }
      ],
      agents: %{
        "worker" => %{
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
          result_limits: %{max_bytes: 4096, artifact_max_bytes: 1_048_576},
          turn_limit: 4
        }
      },
      decisions: %{},
      script: %{
        {:model, "scripted-model"} => [
          {:completed,
           %{
             "content" => "",
             "finish" => "tool_calls",
             "tool_proposals" => [
               %{
                 "id" => "call1",
                 "name" => "lua_total",
                 "arguments" => %{"n" => 4},
                 "malformed" => nil
               }
             ]
           }},
          {:completed, %{"content" => "Total: 13", "finish" => "stop", "tool_proposals" => []}}
        ],
        {:tool, "calc_lookup"} => [{:completed, %{"n" => 9}}]
      },
      effects: %{model: ModelBinding, tool: ToolBinding},
      adapters: [ScriptedAdapter],
      input: %{"question" => "What is the total?"},
      tools: %{"lua_total" => lua_tool()},
      executable: executable,
      restart_after: nil,
      skills: nil,
      gate: nil
    }

    assert {:ok, record} = RecipeTest.run(spec)
    assert record.outcome == :completed
    assert record.asked == %{{:model, "scripted-model"} => 2, {:tool, "calc_lookup"} => 1}
    assert record.unused == %{}

    # The model's answer is scripted. Check the actual Lua result separately so
    # that a failed tool followed by the same scripted answer cannot pass.
    assert [%{"content" => %{"content" => ~s({"total":13})}}] =
             for(
               %{
                 step: :action,
                 action: %{
                   "kind" => "finish",
                   "schema_id" => "elzoo.agent-loop.tool-result",
                   "payload" => payload
                 }
               } <- record.steps,
               do: payload
             )

    assert [finish] =
             for(
               %{
                 step: :action,
                 action: %{
                   "kind" => "finish",
                   "schema_id" => "elzoo.graph-run.result",
                   "payload" => payload
                 }
               } <- record.steps,
               do: payload
             )

    assert finish == %{
             "status" => "completed",
             "reason" => nil,
             "node" => nil,
             "action_id" => "d1:n:ask",
             "gives" => %{"text" => "Total: 13"}
           }
  end

  defp package do
    ports = %{"input" => typed("input"), "output" => typed("output")}
    slot = %{"name" => "question", "schema_id" => "value", "schema_version" => 1}

    graph = %{
      "name" => "main",
      "kind" => "graph",
      "input_slots" => [slot],
      "nodes" => [
        %{
          "id" => "ask",
          "kind" => "call",
          "callable" => "agent",
          "needs" => [slot],
          "gives" => [%{slot | "name" => "text"}]
        }
      ],
      "links" => [
        %{
          "from" => "$input",
          "give" => "question",
          "to" => "ask",
          "need" => "question",
          "kind" => "data"
        }
      ]
    }

    agent = %{"name" => "agent", "kind" => "agent", "binding" => "worker"}

    package = %{
      "format_version" => 1,
      "name" => "first-release",
      "version" => "1",
      "needs" => [],
      "permissions" => [],
      "skills" => [],
      "graph" => %{
        "version" => 1,
        "id" => "recipe",
        "revision" => 1,
        "root" => "main",
        "callables" => [Map.merge(graph, ports), Map.merge(agent, ports)],
        "bindings" => [%{"name" => "worker", "target" => "worker"}],
        "rules" => []
      },
      "settings" => %{
        "version" => 1,
        "id" => "settings",
        "revision" => 1,
        "secrets" => [],
        "port" => ports["input"]["port"],
        "schema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      }
    }

    digest = :crypto.hash(:sha256, Jason.encode!(ordered(package))) |> Base.encode16(case: :lower)
    Map.put(package, "identity", "recipe-package-v1:sha256:" <> digest)
  end

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

  defp ordered(map) when is_map(map),
    do: %Jason.OrderedObject{values: for({k, v} <- Enum.sort(map), do: {k, ordered(v)})}

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value

  defp lua_tool do
    schema = %{
      "type" => "object",
      "properties" => %{"n" => %{"type" => "integer"}},
      "required" => ["n"],
      "additionalProperties" => false
    }

    manifest = %{
      "name" => "lookup",
      "version" => 1,
      "description" => "Look up a number",
      "arguments" => %{typed("input") | "schema" => schema},
      "result" => %{typed("output") | "schema" => schema},
      "cost" => %{"unit" => "call", "estimate" => 1},
      "permissions" => []
    }

    %{
      kind: :lua,
      source:
        "return function(input) return {total = bindings.lookup({n = input.n}).n + input.n} end",
      limits: %{
        "steps" => 10_000,
        "call_depth" => 8,
        "value_bytes" => 1024,
        "memory_bytes" => 1_048_576,
        "wall_ms" => 1000
      },
      declaration: [%{"name" => "lookup", "version" => 1}],
      manifests: [manifest],
      source_id: "calc",
      max_calls: 1
    }
  end
end
