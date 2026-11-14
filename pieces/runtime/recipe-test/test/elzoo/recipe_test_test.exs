# SPDX-License-Identifier: Apache-2.0
Code.require_file("../support/recipe_test_helper.exs", __DIR__)

defmodule Elzoo.RecipeTestTest.OtherAdapter do
  # An Adapter that is not the scripted one: it must be refused unless the caller lists it.
  def failure_tags, do: [:timeout]
  def schema, do: "other-v1"
  def validate(_, _), do: :ok
  def authenticate(_, _), do: :ok
  def validate_result(_, _), do: :ok
  def poll(_), do: {:unavailable, "other"}
  def send_effect(_), do: {:error, :timeout, :unavailable}
end

defmodule Elzoo.RecipeTestTest.OtherToolBinding do
  use Elzoo.EffectIntent.Binding,
    adapter: Elzoo.RecipeTestTest.OtherAdapter,
    id: "recipe-test-other",
    provider_account: "other",
    operation: "call",
    clock: "unix-ms",
    failures: %{timeout: {"timed_out", "unknown", "unavailable"}}
end

defmodule Elzoo.RecipeTestTest do
  use ExUnit.Case, async: false
  import Kernel, except: [node: 3]
  alias Elzoo.RecipeTest
  alias Elzoo.RunEngine.TestRepo
  alias Elzoo.RecipeTest.{ModelBinding, ScriptedAdapter, ToolBinding}
  alias Elzoo.RecipeTestTest.OtherToolBinding

  setup_all do
    pid = Elzoo.RunEngine.TestHelper.database()
    {:ok, registry} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.TestRegistry)
    {:ok, units} = Registry.start_link(keys: :unique, name: Elzoo.RunEngine.UnitRegistry)
    for p <- [registry, units], do: Process.unlink(p)
    on_exit(fn -> for p <- [registry, units, pid], Process.alive?(p), do: Supervisor.stop(p) end)
    :ok
  end

  ## Package, recipe and spec builders: every package and script is a literal

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

  defp choice(from, to, name),
    do: %{"from" => from, "to" => to, "kind" => "choice", "choice" => name}

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
      "bindings" => [
        %{"name" => "worker", "target" => "agent-config"},
        %{"name" => "judge", "target" => "decision-config"}
      ],
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

  defp decision_config,
    do: %{
      request: %{
        "version" => 1,
        "model" => "scripted-decider",
        "max_output_tokens" => 32,
        "messages" => [%{"role" => "user", "text" => "Pick one."}]
      },
      repairs: 1
    }

  defp answer(text),
    do: {:completed, %{"content" => text, "finish" => "stop", "tool_proposals" => []}}

  defp base_spec(package, facts, sources, script, input),
    do: %{
      package: package,
      facts: facts,
      sources: sources,
      agents: %{"agent-config" => agent_config()},
      decisions: %{"decision-config" => decision_config()},
      script: script,
      effects: %{model: ModelBinding, tool: ToolBinding},
      adapters: [ScriptedAdapter],
      input: input
    }

  # A graph root that calls an agent callable and a decision callable, and has two adapter
  # tool nodes, one for each choice. The options change one place of the recipe.
  defp graph_spec(options \\ []) do
    agent_give = Keyword.get(options, :agent_give, "text")
    decision_give = Keyword.get(options, :decision_give, "value")
    tool = Keyword.get(options, :tool, "files_read")

    main =
      callable("main", "graph", %{
        "nodes" => [
          node("a", "call", ["x"], [agent_give], %{"callable" => "agent"}),
          node("d", "decision", ["text"], [decision_give], %{"callable" => "choice"}),
          node("t_yes", "tool", [], ["yes_result"], %{"tool" => tool}),
          node("t_no", "tool", [], ["no_result"], %{"tool" => tool})
        ],
        "links" => [
          data("$input", "x", "a", "x"),
          data("a", agent_give, "d", "text"),
          choice("d", "t_yes", "yes"),
          choice("d", "t_no", "no")
        ],
        "input_slots" => [slot("x")]
      })

    graph =
      recipe([
        main,
        callable("agent", "agent", %{"binding" => "worker"}),
        callable("choice", "decision", %{"binding" => "judge", "choices" => ["yes", "no"]})
      ])

    costs = [cost("agent", 5), cost("choice", 3), cost("main", "t_yes", 2), cost("main", "t_no", 2)]

    script = %{
      {:model, "scripted-model"} => [answer("hello")],
      {:model, "scripted-decider"} => [answer("{\"answer\":\"yes\"}")],
      {:tool, "files_read"} => [{:completed, %{"yes_result" => "r"}}]
    }

    base_spec(package(graph), facts(costs), [files(["read"])], script, %{"x" => "hi"})
  end

  # A root agent with four tools; the script of group 3.
  defp agent_spec(script) do
    graph = recipe([callable("main", "agent", %{"binding" => "worker"})])

    base_spec(
      package(graph),
      facts([cost("main", 5)]),
      [files(~w(read write list stat))],
      script,
      "Do it."
    )
  end

  defp proposal(id, name),
    do: %{"id" => id, "name" => name, "arguments" => %{}, "malformed" => nil}

  defp tools_script do
    %{
      {:model, "scripted-model"} => [
        {:completed,
         %{
           "content" => "",
           "finish" => "tool_calls",
           "tool_proposals" => [
             proposal("c1", "files_read"),
             proposal("c2", "files_write"),
             %{
               "id" => "c3",
               "name" => "files_read",
               "arguments" => nil,
               "malformed" => "schema_mismatch"
             },
             proposal("c4", "files_list"),
             proposal("c5", "files_stat")
           ]
         }},
        answer("Done.")
      ],
      {:tool, "files_read"} => [{:completed, "contents"}],
      {:tool, "files_write"} => [{:failed, "broken"}],
      {:tool, "files_list"} => [{:unknown, "timeout"}],
      {:tool, "files_stat"} => [{:refused, "denied"}]
    }
  end

  defp agent_tools_spec, do: agent_spec(tools_script())

  ## Group 1

  describe "start_refusals" do
    defp refused(spec, reason), do: assert(RecipeTest.run(spec) == {:error, reason})

    test "a spec in another shape is invalid_spec" do
      spec = graph_spec()
      refused(:nope, :invalid_spec)
      refused(Map.delete(spec, :input), :invalid_spec)
      refused(Map.put(spec, :extra, 1), :invalid_spec)
      refused(%{spec | effects: %{model: ModelBinding}}, :invalid_spec)
      refused(%{spec | adapters: :all}, :invalid_spec)
    end

    test "a binding module that does not load is invalid_binding, model before tool" do
      spec = graph_spec()

      refused(
        %{spec | effects: %{spec.effects | model: Elzoo.NoSuchBinding}},
        {:invalid_binding, :model}
      )

      refused(
        %{spec | effects: %{spec.effects | tool: Elzoo.NoSuchBinding}},
        {:invalid_binding, :tool}
      )
    end

    test "an Adapter outside the list is adapter_not_allowed" do
      spec = graph_spec()
      refused(%{spec | adapters: []}, {:adapter_not_allowed, :model})

      refused(
        %{spec | effects: %{spec.effects | tool: OtherToolBinding}},
        {:adapter_not_allowed, :tool}
      )
    end

    test "the first invalid script key in term order is invalid_script" do
      spec = graph_spec()
      script = spec.script

      for {key, entries} <- [
            {{:other, "m"}, []},
            {{:model, :m}, []},
            {{:tool, "files_read"}, :completed},
            {{:tool, "files_read"}, [:completed]},
            {{:tool, "files_read"}, [{:completed, %{atom: 1}}]},
            {{:tool, "files_read"}, [{:completed, {:tuple}}]},
            {{:tool, "files_read"}, [{:failed, "Upper"}]},
            {{:tool, "files_read"}, [{:refused, ""}]},
            {{:tool, "files_read"}, [{:unknown, String.duplicate("a", 65)}]},
            {{:tool, "files_read"}, [{:other, "x"}]},
            {{:model, "scripted-model"}, [{:completed, "not an object"}]}
          ] do
        refused(%{spec | script: Map.put(script, key, entries)}, {:invalid_script, key})
      end

      two = Map.merge(script, %{{:tool, "b"} => [:bad], {:model, "a"} => [:bad]})
      refused(%{spec | script: two}, {:invalid_script, {:model, "a"}})
    end

    test "a source that the registry refuses is sources" do
      spec = graph_spec()
      {:error, reason} = Elzoo.ToolRegistry.snapshot([:bad])
      refused(%{spec | sources: [:bad]}, {:sources, reason})
    end

    test "facts in another shape are invalid_facts" do
      spec = graph_spec()
      refused(%{spec | facts: Map.delete(spec.facts, "cap")}, :invalid_facts)
    end

    test "a recipe that the check refuses is recipe_refused" do
      spec = graph_spec()
      missing = Enum.reject(spec.facts["costs"], &(&1["callable"] == "agent"))

      assert {:error, {:recipe_refused, [%{code: :missing_cost}]}} =
               RecipeTest.run(%{spec | facts: %{spec.facts | "costs" => missing}})

      assert {:error, {:recipe_refused, reasons}} = RecipeTest.run(graph_spec(tool: "files_gone"))
      assert Enum.any?(reasons, &(&1.code == :unknown_tool))
    end

    test "a callable without an entry for its binding target is unbound_callable" do
      spec = graph_spec()
      refused(%{spec | agents: %{}}, {:unbound_callable, "agent"})
      refused(%{spec | decisions: %{}}, {:unbound_callable, "choice"})
      refused(%{spec | agents: %{}, decisions: %{}}, {:unbound_callable, "agent"})
    end

    test "a callable that its pattern refuses is invalid_callable" do
      spec = graph_spec()
      bad_agent = Map.put(agent_config(), :turn_limit, 0)

      refused(
        %{spec | agents: %{"agent-config" => bad_agent}},
        {:invalid_callable, "agent", :invalid_spec}
      )

      bad_decision = %{decision_config() | repairs: 99}

      refused(
        %{spec | decisions: %{"decision-config" => bad_decision}},
        {:invalid_callable, "choice", :invalid_spec}
      )

      no_model = %{decision_config() | request: Map.delete(decision_config().request, "model")}

      refused(
        %{spec | decisions: %{"decision-config" => no_model}},
        {:invalid_callable, "choice", :invalid_spec}
      )
    end

    test "a call node that takes a give other than text or value is invalid_callable gives" do
      refused(graph_spec(agent_give: "other"), {:invalid_callable, "main", :gives})
      refused(graph_spec(decision_give: "other"), {:invalid_callable, "main", :gives})
    end

    test "a nested tool is unsupported_tool" do
      spec = graph_spec()

      nested = %{
        "id" => "sub",
        "kind" => "other",
        "callable" => "nested",
        "tools" => [tool("plan")]
      }

      refused(%{spec | sources: spec.sources ++ [nested]}, {:unsupported_tool, "sub_plan"})
    end

    test "an input in another form than the root kind is invalid_input" do
      refused(%{graph_spec() | input: "text"}, :invalid_input)
      refused(%{graph_spec() | input: %{atom: 1}}, :invalid_input)
      refused(%{agent_tools_spec() | input: ""}, :invalid_input)
      refused(%{agent_tools_spec() | input: %{"x" => 1}}, :invalid_input)
    end

    test "an Adapter outside the list wins over an invalid script" do
      spec = graph_spec()
      script = Map.put(spec.script, {:other, "m"}, [])
      refused(%{spec | adapters: [], script: script}, {:adapter_not_allowed, :model})
    end

    test "an unknown tool in the recipe wins over an unbound callable" do
      spec = graph_spec(tool: "files_gone")
      assert {:error, {:recipe_refused, _}} = RecipeTest.run(%{spec | agents: %{}})
    end
  end

  ## Group 2

  describe "adapter_allow_list" do
    defp engine_schemas do
      %{rows: [[count]]} =
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "SELECT count(*) FROM information_schema.schemata WHERE schema_name LIKE 'engine\\_%'",
          [],
          log: false
        )

      count
    end

    defp small_spec, do: agent_spec(%{{:model, "scripted-model"} => [answer("Hello.")]})

    test "an Adapter outside the list starts nothing" do
      before = engine_schemas()

      assert RecipeTest.run(%{small_spec() | adapters: []}) ==
               {:error, {:adapter_not_allowed, :model}}

      assert RecipeTest.run(%{
               small_spec()
               | effects: %{model: ModelBinding, tool: OtherToolBinding}
             }) ==
               {:error, {:adapter_not_allowed, :tool}}

      assert engine_schemas() == before
      assert Registry.count(Elzoo.RunEngine.TestRegistry) == 0
    end

    test "the same spec with the scripted bindings runs to completed" do
      assert {:ok, %{outcome: :completed, unused: unused}} = RecipeTest.run(small_spec())
      assert unused == %{}
    end
  end

  ## Group 3

  describe "agent_with_tools" do
    test "four tool classes reach the model as notes; a malformed proposal is left out" do
      assert {:ok, record} = RecipeTest.run(agent_tools_spec())
      assert record.outcome == :completed
      assert record.unused == %{}

      actions = for %{step: :action, action: action} <- record.steps, do: action
      tools = for %{"kind" => "tool_call"} = action <- actions, do: action["id"]
      assert tools == ["d1:t:1:1", "d1:t:1:2", "d1:t:1:4", "d1:t:1:5"]
      refute Enum.any?(actions, &(&1["id"] == "d1:t:1:3"))

      classes =
        for %{step: :input, input: %{"kind" => "action_outcome", "action_id" => id} = input} <-
              record.steps,
            String.contains?(id, ":t:"),
            into: %{},
            do: {id, input["outcome"]}

      assert classes == %{
               "d1:t:1:1" => "completed",
               "d1:t:1:2" => "failed",
               "d1:t:1:4" => "unknown",
               "d1:t:1:5" => "refused"
             }

      [second] = Enum.filter(actions, &(&1["id"] == "d1:m:2"))
      text = Jason.encode!(second["payload"])
      assert text =~ "[tool call not completed: unknown: timeout]"
      assert text =~ "[tool call left out: files_read: schema_mismatch]"

      assert record.asked == %{
               {:model, "scripted-model"} => 2,
               {:tool, "files_read"} => 1,
               {:tool, "files_write"} => 1,
               {:tool, "files_list"} => 1,
               {:tool, "files_stat"} => 1
             }
    end
  end
end
