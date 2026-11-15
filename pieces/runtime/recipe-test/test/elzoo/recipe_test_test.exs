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

  defp package(graph, skills \\ []) do
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
      "skills" => skills
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

  defp decided(member),
    do:
      {:completed,
       %{
         "content" => Jason.encode!(%{"answer" => member}),
         "finish" => "stop",
         "tool_proposals" => [],
         "structured" => %{"valid" => %{"answer" => member}}
       }}

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
      input: input,
      tools: %{},
      executable: nil,
      restart_after: nil,
      skills: nil
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
      {:model, "scripted-decider"} => [decided("yes")],
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

    test "each_invalid_script_key: the key nil is invalid_script, and no later invalid key hides it" do
      spec = graph_spec()
      script = spec.script

      # nil is the first key in term order (an atom sorts before a tuple)
      refused(%{spec | script: Map.put(script, nil, [])}, {:invalid_script, nil})
      refused(%{spec | script: %{nil => 1, {:bogus, 1} => 2}}, {:invalid_script, nil})

      refused(
        %{spec | script: Map.merge(script, %{nil => [], {:bogus, 1} => 2})},
        {:invalid_script, nil}
      )

      # an invalid key that sorts last, behind every valid key, is reported with itself
      last = {:zzz, "last"}
      assert Enum.max([last | Map.keys(script)]) == last
      refused(%{spec | script: Map.put(script, last, [])}, {:invalid_script, last})

      # a valid script is not refused with invalid_script
      assert {:ok, _record} = RecipeTest.run(spec)
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

    test "a graph that GraphRun refuses is invalid_callable" do
      # A map node must take the need `items`; the recipe check does not read that.
      map =
        node("m", "map", ["tag"], ["items"], %{"callable" => "agent", "max_iterations" => 3})

      main =
        callable("main", "graph", %{
          "nodes" => [map],
          "links" => [data("$input", "tag", "m", "tag")],
          "input_slots" => [slot("tag")]
        })

      graph = recipe([main, callable("agent", "agent", %{"binding" => "worker"})])
      spec = base_spec(package(graph), facts([cost("agent", 5)]), [], %{}, %{"tag" => "t"})
      refused(spec, {:invalid_callable, "main", :invalid_spec})
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

  ## Group 4

  describe "decision_repair" do
    defp decision_spec(script) do
      graph =
        recipe([
          callable("choice", "decision", %{"binding" => "judge", "choices" => ["yes", "no"]})
        ])

      base_spec(package(graph), facts([cost("choice", 3)]), [], script, %{})
    end

    test "a schema mismatch is repaired once and the decision is decided" do
      maybe =
        {:completed,
         %{
           "content" => ~s({"answer":"maybe"}),
           "finish" => "stop",
           "tool_proposals" => [],
           "structured" => %{"invalid" => "schema_mismatch"}
         }}

      script = %{{:model, "scripted-decider"} => [maybe, decided("yes")]}
      assert {:ok, record} = RecipeTest.run(decision_spec(script))
      assert record.outcome == :completed
      assert record.unused == %{}
      assert record.asked == %{{:model, "scripted-decider"} => 2}

      actions =
        for %{step: :action, action: action} <- record.steps, into: %{}, do: {action["id"], action}

      assert %{"status" => "decided", "value" => "yes", "repairs" => 1} =
               actions["d1:finish"]["payload"]

      first = actions["d1:call:0"]["payload"]["messages"]
      second = actions["d1:call:1"]["payload"]["messages"]
      assert length(second) == length(first) + 2

      assert [
               %{"role" => "assistant", "text" => ~s({"answer":"maybe"})},
               %{"role" => "user", "text" => repair}
             ] = Enum.take(second, -2)

      assert repair != ""
      assert Enum.take(second, length(first)) == first
    end
  end

  ## Group 5

  describe "graph_with_children" do
    defp child_id(depth, parent_action_id) do
      hex = :crypto.hash(:sha256, parent_action_id) |> Base.encode16(case: :lower)
      "d#{depth}x" <> binary_part(hex, 0, 24)
    end

    test "an agent child, a decision child and a tool node run in one graph" do
      assert {:ok, record} = RecipeTest.run(graph_spec())
      assert %{outcome: :completed} = record
      assert record.unused == %{}

      assert record.asked == %{
               {:model, "scripted-model"} => 1,
               {:model, "scripted-decider"} => 1,
               {:tool, "files_read"} => 1
             }

      agent = child_id(2, "d1:n:a")
      decision = child_id(2, "d1:n:d")
      assert agent != decision

      actions =
        for %{step: :action, action: action} <- record.steps, into: %{}, do: {action["id"], action}

      # The children carry the ids of the rule; the root's own actions are d1:n:<node>.
      assert Map.keys(actions) |> Enum.sort() ==
               Enum.sort([
                 "d1:n:a",
                 "d1:n:d",
                 "d1:n:t_yes",
                 "d1:finish",
                 agent <> ":m:1",
                 agent <> ":finish",
                 decision <> ":call:0",
                 decision <> ":finish"
               ])

      refute Map.has_key?(actions, "d1:n:t_no")

      nested = for %{step: :nested} = step <- record.steps, do: Map.delete(step, :step)

      assert nested == [
               %{
                 occurrence: {1, 0},
                 schema_id: "elzoo.agent-loop.message",
                 schema_version: 1,
                 payload: %{"text" => canonical(%{"x" => "hi"})}
               },
               %{
                 occurrence: {4, 0},
                 schema_id: "elzoo.recipe-test.input",
                 schema_version: 1,
                 payload: %{"input" => %{"text" => "hello"}}
               }
             ]

      # The agent child's answer is the give `text` that the decision child receives.
      [_, %{"role" => "user", "text" => received}] =
        actions[decision <> ":call:0"]["payload"]["messages"]

      assert received == canonical(%{"text" => "hello"})

      outcomes =
        for %{step: :input, input: %{"kind" => "action_outcome"} = input} <- record.steps,
            into: %{},
            do: {input["action_id"], input}

      assert %{
               "outcome" => "completed",
               "schema_id" => "elzoo.graph-run.node-result",
               "payload" => %{"gives" => %{"text" => "hello"}}
             } = outcomes["d1:n:a"]

      assert %{
               "outcome" => "completed",
               "payload" => %{"choice" => "yes", "gives" => %{"value" => "yes"}}
             } = outcomes["d1:n:d"]

      assert %{
               "outcome" => "completed",
               "payload" => %{"gives" => %{"yes_result" => "r"}}
             } = outcomes["d1:n:t_yes"]

      assert %{"kind" => "finish", "schema_id" => "elzoo.graph-run.result", "payload" => finish} =
               actions["d1:finish"]

      assert %{"status" => "completed", "gives" => %{"yes_result" => "r"}} = finish
      assert finish["action_id"] == "d1:n:t_yes"
    end
  end

  ## Group 6

  describe "same_spec_same_record" do
    test "the spec of the agent with tools gives two equal records" do
      assert {:ok, first} = RecipeTest.run(agent_tools_spec())
      assert {:ok, second} = RecipeTest.run(agent_tools_spec())
      assert first.outcome == :completed
      assert first == second
    end
  end

  ## Group 7

  describe "unscripted_call" do
    defp one_tool_turn do
      {:completed,
       %{
         "content" => "",
         "finish" => "tool_calls",
         "tool_proposals" => [proposal("c1", "files_read")]
       }}
    end

    test "a tool without an entry stops the run with the tool action and no outcome for it" do
      spec = agent_spec(%{{:model, "scripted-model"} => [one_tool_turn()]})

      assert {:error, {:unscripted_call, {:tool, "files_read"}, record}} = RecipeTest.run(spec)

      actions = for %{step: :action, action: action} <- record.steps, do: action["id"]
      assert "d1:t:1:1" in actions

      answered =
        for %{step: :input, input: %{"kind" => "action_outcome", "action_id" => id}} <- record.steps,
            do: id

      refute "d1:t:1:1" in answered
      assert record.asked == %{{:model, "scripted-model"} => 1, {:tool, "files_read"} => 1}
      assert record.outcome == nil
    end

    test "a model key with one entry and a second model call stops the run" do
      script = %{
        {:model, "scripted-model"} => [one_tool_turn()],
        {:tool, "files_read"} => [{:completed, "contents"}]
      }

      assert {:error, {:unscripted_call, {:model, "scripted-model"}, record}} =
               RecipeTest.run(agent_spec(script))

      assert record.asked == %{{:model, "scripted-model"} => 2, {:tool, "files_read"} => 1}
      assert record.outcome == nil
      refute Enum.any?(record.steps, &match?(%{step: :action, action: %{"id" => "d1:finish"}}, &1))
    end

    test "an entry that no call used is counted in unused and is not an error" do
      script = %{{:model, "scripted-model"} => [answer("one"), answer("two")]}

      assert {:ok, record} = RecipeTest.run(agent_spec(script))
      assert record.outcome == :completed
      assert record.unused == %{{:model, "scripted-model"} => 1}
      assert record.asked == %{{:model, "scripted-model"} => 1}
    end
  end

  ## Skills

  defp skill_entry(name, tools, body, files \\ %{}) do
    markdown = "---\nname: #{name}\ndescription: Use #{name}\n---\n" <> body

    assert {:ok, %{entry: entry, files: rest}} =
             Elzoo.Skill.read(name, "1", tools, Map.put(files, "SKILL.md", markdown))

    {entry, rest}
  end

  # `alpha` declares one tool, `beta` none; the host describes the one tool.
  defp skill_set do
    {alpha, alpha_files} =
      skill_entry("alpha", ["tool-identity-one"], "Alpha instructions\n", %{
        "notes.txt" => "Alpha notes\n"
      })

    {beta, beta_files} = skill_entry("beta", [], "Beta instructions\n")

    {[alpha, beta],
     %{
       id: "sk",
       files: %{"alpha" => alpha_files, "beta" => beta_files},
       descriptors: [tool("tool-identity-one")]
     }}
  end

  # The spec of a recipe whose package holds the two skills; `sources` are the other sources.
  defp skill_spec(graph, sources, facts, script, input) do
    {entries, skills} = skill_set()
    package = package(graph, entries)
    assert {:ok, checked} = Elzoo.RecipePackage.decode(package)
    assert {:ok, skill_sources} = Elzoo.Skill.sources("sk", checked, skills.descriptors)
    %{base_spec(package, facts, sources ++ skill_sources, script, input) | skills: skills}
  end

  defp tool_turn(id, name, arguments),
    do:
      {:completed,
       %{
         "content" => "",
         "finish" => "tool_calls",
         "tool_proposals" => [
           %{"id" => id, "name" => name, "arguments" => arguments, "malformed" => nil}
         ]
       }}

  @load_alpha {:tool, "sk_load_skill"}
  @alpha_tool "sk-1_tool-identity-one"

  defp skill_agent_spec(script) do
    graph = recipe([callable("main", "agent", %{"binding" => "worker"})])
    skill_spec(graph, [], facts([cost("main", 5)]), script, "Do it.")
  end

  defp skill_script(tool_entries) do
    %{
      {:model, "scripted-model"} => [
        tool_turn("c1", "sk_load_skill", %{"name" => "alpha"}),
        tool_turn("c2", @alpha_tool, %{}),
        answer("Done.")
      ],
      {:tool, @alpha_tool} => tool_entries
    }
  end

  defp record_actions(record),
    do: for(%{step: :action, action: action} <- record.steps, into: %{}, do: {action["id"], action})

  defp record_outcomes(record, id),
    do:
      for(
        %{step: :input, input: %{"kind" => "action_outcome", "action_id" => ^id} = input} <-
          record.steps,
        do: input
      )

  # The text between the marks of a marked tool result: its sources and its content.
  defp marked(text) do
    pattern =
      ~r/\A<<<untrusted-content [0-9a-f]+ trust=untrusted bytes=\d+ sources=(.*)>>>\n(.*)\n<<<end untrusted-content [0-9a-f]+>>>\z/s

    assert [_, sources, content] = Regex.run(pattern, text)
    {sources, content}
  end

  defp system_text(payload) do
    assert [%{"role" => "system", "text" => text} | _] = payload["messages"]
    text
  end

  defp tool_names(payload), do: payload["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()

  defp result_of(payload, id) do
    assert %{"role" => "tool_result", "text" => text} =
             Enum.find(payload["messages"], &(&1["tool_use_id"] == id))

    marked(text)
  end

  @plain_tools ["sk_load_skill", "sk_read_skill_file"]
  @system_plain "Answer."
  @system_alpha "Answer.\n\nAlpha instructions\n"

  describe "skill_load_through_engine" do
    test "a load reaches the agent as a declaration, and the skill tool is called once" do
      script = skill_script([{:completed, "tool value"}])
      assert {:ok, record} = RecipeTest.run(skill_agent_spec(script))
      assert record.outcome == :completed
      assert record.unused == %{}

      assert record.asked == %{
               {:model, "scripted-model"} => 3,
               @load_alpha => 1,
               {:tool, @alpha_tool} => 1
             }

      actions = record_actions(record)

      assert %{
               "kind" => "tool_call",
               "schema_id" => "elzoo.agent-loop.tool-call",
               "payload" => %{"alias" => "sk_load_skill", "arguments" => %{"name" => "alpha"}}
             } = actions["d1:t:1:1"]

      assert [load] = record_outcomes(record, "d1:t:1:1")
      assert load["outcome"] == "completed"
      assert load["schema_id"] == "elzoo.agent-loop.tool-result"

      # The declaration of `Skill.load/4`, not marked text.
      assert load["payload"] == %{
               "declaration" => %{
                 "skill" => %{"name" => "alpha", "instructions" => "Alpha instructions\n"},
                 "listing" => %{"source" => "sk-1", "tools" => [tool("tool-identity-one")]}
               }
             }

      [first, second, third] = for id <- ~w(d1:m:1 d1:m:2 d1:m:3), do: actions[id]["payload"]
      assert system_text(first) == @system_plain
      assert tool_names(first) == @plain_tools
      assert system_text(second) == @system_alpha
      assert tool_names(second) == [@alpha_tool | @plain_tools]
      assert result_of(second, "c1") == {"agent-loop", "[declaration accepted]"}

      assert system_text(third) == @system_alpha
      assert result_of(third, "c2") == {"recipe-test:tool", "tool value"}
      assert [done] = record_outcomes(record, "d1:t:2:1")
      assert done["outcome"] == "completed"
    end

    test "the second skill tool answers a file read with Skill.read_file/3" do
      script = %{
        {:model, "scripted-model"} => [
          tool_turn("c1", "sk_read_skill_file", %{"skill" => "alpha", "path" => "notes.txt"}),
          tool_turn("c2", "sk_read_skill_file", %{"skill" => "alpha", "path" => "SKILL.md"}),
          answer("Done.")
        ]
      }

      assert {:ok, record} = RecipeTest.run(skill_agent_spec(script))
      assert record.outcome == :completed
      assert record.unused == %{}
      assert record.asked == %{{:model, "scripted-model"} => 3, {:tool, "sk_read_skill_file"} => 2}

      assert [read] = record_outcomes(record, "d1:t:1:1")
      assert read["outcome"] == "completed"
      assert read["payload"]["media_type"] == "text/plain"
      assert read["payload"]["encoding"] == "utf8"
      assert read["payload"]["content"]["sources"] == ["skill:alpha"]
      assert read["payload"]["content"]["content"] == "Alpha notes\n"

      # SKILL.md is never a file read: a refusal of Skill, with its reason.
      assert [refused] = record_outcomes(record, "d1:t:2:1")
      assert refused["outcome"] == "refused"
      assert refused["payload"] == %{"reason" => "unknown_file"}
    end

    test "a script entry for a skill tool is never used and stays in unused" do
      script =
        Map.put(skill_script([{:completed, "tool value"}]), @load_alpha, [{:completed, "marked"}])

      assert {:ok, record} = RecipeTest.run(skill_agent_spec(script))
      assert record.unused == %{@load_alpha => 1}
      assert [load] = record_outcomes(record, "d1:t:1:1")
      assert Map.keys(load["payload"]) == ["declaration"]
    end
  end

  describe "skills_shape" do
    test "skills is nil or exactly id, files and descriptors; another value is invalid_spec" do
      spec = skill_agent_spec(skill_script([{:completed, "tool value"}]))
      skills = spec.skills

      for bad <- [
            :nope,
            %{},
            Map.delete(skills, :id),
            Map.put(skills, :extra, 1),
            %{skills | id: :sk},
            %{skills | files: [{"alpha", %{}}]},
            %{skills | descriptors: %{}},
            Map.put(skills, :__struct__, Elzoo.RecipeTestTest)
          ] do
        assert RecipeTest.run(%{spec | skills: bad}) == {:error, :invalid_spec}
      end

      assert RecipeTest.run(Map.delete(spec, :skills)) == {:error, :invalid_spec}
    end
  end

  describe "skill_load_after_restart" do
    test "a restart while the skill tool is held: the load is recorded once and not asked again" do
      script = skill_script([{:completed, "tool value"}])
      spec = %{skill_agent_spec(script) | restart_after: 3}
      assert {:ok, record} = RecipeTest.run(spec)
      assert record.restarted == true
      assert record.outcome == :completed

      assert record.asked == %{
               {:model, "scripted-model"} => 3,
               @load_alpha => 1,
               {:tool, @alpha_tool} => 1
             }

      # The dropped call used no entry.
      assert record.unused == %{{:tool, @alpha_tool} => 1}

      load_actions = for %{step: :action, action: %{"id" => "d1:t:1:1"}} <- record.steps, do: 1
      assert length(load_actions) == 1
      assert [load] = record_outcomes(record, "d1:t:1:1")
      assert load["outcome"] == "completed"
      assert Map.keys(load["payload"]) == ["declaration"]

      assert [dropped] = record_outcomes(record, "d1:t:2:1")
      assert dropped["outcome"] == "unknown"

      model_calls =
        for %{step: :action, action: %{"kind" => "model_call"} = a} <- record.steps, do: a["id"]

      assert model_calls == ["d1:m:1", "d1:m:2", "d1:m:3"]

      # The declaration is applied again from the record: the model call after the restart.
      third = record_actions(record)["d1:m:3"]["payload"]
      assert system_text(third) == @system_alpha
      assert tool_names(third) == [@alpha_tool | @plain_tools]
      assert result_of(third, "c1") == {"agent-loop", "[declaration accepted]"}
      assert {"agent-loop", "[tool call not completed: unknown" <> _} = result_of(third, "c2")
    end
  end

  describe "declared_tool_refused_at_use" do
    test "a scripted refusal of the declared tool is a notice and the instructions stay" do
      script = skill_script([{:refused, "not_permitted"}])
      assert {:ok, record} = RecipeTest.run(skill_agent_spec(script))
      assert record.outcome == :completed
      assert record.unused == %{}

      assert [refused] = record_outcomes(record, "d1:t:2:1")
      assert refused["outcome"] == "refused"
      assert refused["payload"] == %{"reason" => "not_permitted"}

      third = record_actions(record)["d1:m:3"]["payload"]

      assert result_of(third, "c2") ==
               {"agent-loop", "[tool call not completed: refused: not_permitted]"}

      assert system_text(third) == @system_alpha
      assert tool_names(third) == [@alpha_tool | @plain_tools]
    end
  end

  # A root graph with a `call` node into the agent, and a node that gives it `skill`.
  defp skill_graph(nodes, links, slots, costs, script, input) do
    main = callable("main", "graph", %{"nodes" => nodes, "links" => links, "input_slots" => slots})

    graph =
      recipe([
        main,
        callable("agent", "agent", %{"binding" => "worker"}),
        callable("choice", "decision", %{"binding" => "judge", "choices" => ["alpha", "beta"]})
      ])

    skill_spec(
      graph,
      [files(["read"])],
      facts([cost("agent", 5), cost("choice", 3) | costs]),
      script,
      input
    )
  end

  # The checks of groups 4 and 5: the agent child of the node `a` starts with the load.
  defp assert_child_loads_alpha(record) do
    child = child_id(2, "d1:n:a")

    assert [start] =
             for(
               %{step: :nested, schema_id: "elzoo.agent-loop.message"} = step <- record.steps,
               do: step.payload
             )

    assert start == %{
             "text" => canonical(%{"skill" => "alpha"}),
             "skill" => %{"tool" => "sk_load_skill", "name" => "alpha"}
           }

    # The load comes first: no model call of the child before it.
    ids =
      for %{step: :action, action: %{"id" => id}} <- record.steps,
          String.starts_with?(id, child <> ":"),
          do: String.replace_prefix(id, child, "")

    assert ids == [":t:0:1", ":m:1", ":finish"]
    actions = record_actions(record)

    assert %{"payload" => %{"alias" => "sk_load_skill", "arguments" => %{"name" => "alpha"}}} =
             actions[child <> ":t:0:1"]

    assert [load] = record_outcomes(record, child <> ":t:0:1")
    assert load["outcome"] == "completed"
    assert get_in(load, ["payload", "declaration", "skill", "name"]) == "alpha"
    assert system_text(actions[child <> ":m:1"]["payload"]) == @system_alpha

    assert tool_names(actions[child <> ":m:1"]["payload"]) ==
             ["files_read", @alpha_tool | @plain_tools]
  end

  describe "decision_chooses_skill" do
    test "the choice of a decision node is the skill that the agent child starts with" do
      nodes = [
        node("d", "decision", ["x"], ["value"], %{"callable" => "choice"}),
        node("a", "call", ["skill"], ["text"], %{"callable" => "agent"}),
        node("b", "tool", [], ["b_result"], %{"tool" => "files_read"})
      ]

      links = [
        data("$input", "x", "d", "x"),
        data("d", "value", "a", "skill"),
        choice("d", "a", "alpha"),
        choice("d", "b", "beta")
      ]

      script = %{
        {:model, "scripted-decider"} => [decided("alpha")],
        {:model, "scripted-model"} => [answer("Done.")]
      }

      spec =
        skill_graph(nodes, links, [slot("x")], [cost("main", "b", 2)], script, %{"x" => "hi"})

      assert {:ok, record} = RecipeTest.run(spec)
      assert record.outcome == :completed
      assert record.unused == %{}

      assert record.asked == %{
               {:model, "scripted-decider"} => 1,
               {:model, "scripted-model"} => 1,
               @load_alpha => 1
             }

      assert_child_loads_alpha(record)
      refute Map.has_key?(record_actions(record), "d1:n:b")
    end
  end

  describe "tool_result_chooses_skill" do
    test "the value of a tool node is the skill that the agent child starts with" do
      nodes = [
        node("t", "tool", [], ["skill"], %{"tool" => "files_read"}),
        node("a", "call", ["skill"], ["text"], %{"callable" => "agent"})
      ]

      script = %{
        {:tool, "files_read"} => [{:completed, %{"skill" => "alpha"}}],
        {:model, "scripted-model"} => [answer("Done.")]
      }

      spec =
        skill_graph(
          nodes,
          [data("t", "skill", "a", "skill")],
          [],
          [cost("main", "t", 2)],
          script,
          %{}
        )

      assert {:ok, record} = RecipeTest.run(spec)
      assert record.outcome == :completed
      assert record.unused == %{}

      assert record.asked == %{
               {:tool, "files_read"} => 1,
               {:model, "scripted-model"} => 1,
               @load_alpha => 1
             }

      assert_child_loads_alpha(record)
    end
  end
end
