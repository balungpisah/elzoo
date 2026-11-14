# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipeTest.GlueTest do
  use ExUnit.Case, async: true

  alias Elzoo.{AgentLoop, GraphRun, LuaBinding, LuaTool, TypedDecision}
  alias Elzoo.RecipeTest.Glue

  ## Inputs

  defp input(kind, fields),
    do: Map.merge(%{"type" => "input", "version" => 1, "kind" => kind, "at_ms" => 1}, fields)

  defp start(schema_id, payload),
    do: input("start", %{"schema_id" => schema_id, "schema_version" => 1, "payload" => payload})

  defp outcome(id, class, schema_id, payload),
    do:
      input("action_outcome", %{
        "action_id" => id,
        "outcome" => class,
        "schema_id" => schema_id,
        "schema_version" => 1,
        "payload" => payload
      })

  defp model(id, content, finish, proposals \\ []),
    do:
      outcome(id, "completed", "elzoo.ai-text.result", %{
        "content" => content,
        "finish" => finish,
        "tool_proposals" => proposals
      })

  ## Inner states

  @tool_schema %{
    "type" => "object",
    "properties" => %{"path" => %{"type" => "string"}},
    "required" => ["path"]
  }

  defp agent_state do
    {:ok, inner} =
      AgentLoop.new(%{
        id: "a",
        model: "m",
        max_output_tokens: 256,
        role_instructions: ["Answer."],
        window: %{
          provider_id: "p",
          model_id: "m",
          size: 100_000,
          unit: :tokens,
          estimator_id: "recipe-test-bytes",
          estimator_version: 1
        },
        max_request_bytes: 65_536,
        max_image_refs: 0,
        sources: [
          %{
            "id" => "files",
            "kind" => "other",
            "callable" => "adapter",
            "tools" => [
              %{
                "trust" => "untrusted",
                "name" => "read",
                "description" => "Read",
                "input_schema" => @tool_schema,
                "annotations" => nil
              }
            ]
          }
        ],
        result_limits: %{max_bytes: 4_096, artifact_max_bytes: 1_048_576},
        ask: nil,
        turn_limit: 4
      })

    inner
  end

  defp slot(name), do: %{"name" => name, "schema_id" => "value", "schema_version" => 1}

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

  defp graph_state do
    node = %{
      "id" => "a",
      "kind" => "call",
      "callable" => "agent",
      "needs" => [slot("x")],
      "gives" => [slot("ga")]
    }

    link = %{"from" => "$input", "to" => "a", "kind" => "data", "give" => "x", "need" => "x"}

    recipe = %{
      "version" => 1,
      "id" => "recipe",
      "revision" => 1,
      "root" => "main",
      "callables" => [
        callable("main", "graph", %{
          "nodes" => [node],
          "links" => [link],
          "input_slots" => [slot("x")]
        }),
        callable("agent", "agent", %{"binding" => "worker"})
      ],
      "bindings" => [%{"name" => "worker", "target" => "binding"}],
      "rules" => []
    }

    {:ok, inner} =
      GraphRun.new(%{
        id: "g",
        recipe: recipe,
        callable: "main",
        sources: [],
        maps: %{},
        max_open: 8
      })

    inner
  end

  defp graph_start,
    do: start("elzoo.graph-run.input", %{"input" => %{"x" => 1}})

  defp decision_state do
    {:ok, inner} =
      TypedDecision.new(%{
        id: "d",
        request: %{
          "version" => 1,
          "model" => "m",
          "max_output_tokens" => 64,
          "messages" => [%{"role" => "user", "text" => "Yes or no?"}]
        },
        port: %{
          "id" => "route",
          "direction" => "output",
          "schema_id" => "route",
          "schema_version" => 1
        },
        answer: {:set, ["yes", "no"]},
        repairs: 0
      })

    inner
  end

  defp glue(kind, to, inner),
    do:
      if(kind == :agent,
        do: %{kind: :agent, to: to, inner: inner, content: nil},
        else: %{kind: kind, to: to, inner: inner}
      )

  ## Folding

  defp fold(state, inputs) do
    {state, requests} =
      Enum.reduce(inputs, {state, []}, fn item, {state, requests} ->
        assert {:Transition, next, out} = Glue.step(state, item)
        {next, [out | requests]}
      end)

    {state, Enum.reverse(requests)}
  end

  defp last_finish(requests) do
    assert {:some, %{"actions" => [action]}} = List.last(requests)
    assert action["kind"] == "finish"
    action
  end

  defp agent_trace(final),
    do: [
      start("elzoo.agent-loop.message", %{"text" => "Read it"}),
      model("a:m:1", "reading", "tool_calls", [
        %{
          "id" => "c1",
          "name" => "files_read",
          "arguments" => %{"path" => "p"},
          "malformed" => nil
        }
      ]),
      outcome("a:t:1:1", "completed", "elzoo.agent-loop.tool-result", %{
        "content" => %{
          "schema_id" => "elzoo.untrusted-content.marked",
          "schema_version" => 1,
          "sources" => ["files:read"],
          "trust" => "untrusted",
          "max_bytes" => 4_096,
          "content" => "data"
        },
        "media_type" => "text/plain",
        "encoding" => "utf8"
      })
      | final
    ]

  defp node_result(payload),
    do: %{
      "schema_id" => "elzoo.graph-run.node-result",
      "schema_version" => 1,
      "payload" => payload
    }

  defp matches?(action, expected), do: Map.take(action, Map.keys(expected)) == expected

  describe "glue_forms" do
    test "an answered agent gives the content of the last model result" do
      trace = agent_trace([model("a:m:2", "the second answer", "stop")])
      {state, requests} = fold(glue(:agent, :node, agent_state()), trace)
      action = last_finish(requests)

      assert action["id"] == "a:finish"
      assert matches?(action, node_result(%{"gives" => %{"text" => "the second answer"}}))
      assert state.content == "the second answer"
    end

    test "a graph that completed gives its gives" do
      trace = [
        graph_start(),
        outcome("g:n:a", "completed", "elzoo.graph-run.node-result", %{"gives" => %{"ga" => 7}})
      ]

      {_, requests} = fold(glue(:graph, :node, graph_state()), trace)
      action = last_finish(requests)

      assert action["id"] == "g:finish"
      assert matches?(action, node_result(%{"gives" => %{"ga" => 7}}))
    end

    test "a decision that decided on text gives the value and the choice" do
      trace = [
        start("route", nil),
        model("d:call:0", ~s({"answer":"yes"}), "stop")
        |> put_in(["payload", "structured"], %{"valid" => %{"answer" => "yes"}})
      ]

      {_, requests} = fold(glue(:decision, :node, decision_state()), trace)
      action = last_finish(requests)

      assert action["id"] == "d:finish"
      assert matches?(action, node_result(%{"gives" => %{"value" => "yes"}, "choice" => "yes"}))
    end

    test "any other status gives a failed payload with no gives" do
      {_, agent} =
        fold(glue(:agent, :node, agent_state()), [
          start("elzoo.agent-loop.message", %{"text" => "Read it"}),
          outcome("a:m:1", "failed", "elzoo.ai-text.result", nil)
        ])

      {_, graph} =
        fold(glue(:graph, :node, graph_state()), [
          graph_start(),
          outcome("g:n:a", "failed", "elzoo.graph-run.node-result", nil)
        ])

      {_, decision} =
        fold(glue(:decision, :node, decision_state()), [
          start("route", nil),
          outcome("d:call:0", "failed", "elzoo.ai-text.result", nil)
        ])

      for requests <- [agent, graph, decision] do
        action = last_finish(requests)
        assert action["schema_id"] == "elzoo.graph-run.node-result"
        assert %{"failed" => reason} = action["payload"]
        assert is_binary(reason)
        assert map_size(action["payload"]) == 1
      end
    end

    test "actions of other kinds are unchanged for a node" do
      {_, node} =
        fold(glue(:agent, :node, agent_state()), [
          start("elzoo.agent-loop.message", %{"text" => "Read it"})
        ])

      {_, root} =
        fold(glue(:agent, :root, agent_state()), [
          start("elzoo.agent-loop.message", %{"text" => "Read it"})
        ])

      assert [{:some, %{"actions" => [%{"kind" => "model_call"}]}}] = node
      assert node == root
    end

    test "to root gives the inner request unchanged" do
      trace = agent_trace([model("a:m:2", "the second answer", "stop")])
      {_, requests} = fold(glue(:agent, :root, agent_state()), trace)

      {_, inner} =
        Enum.reduce(trace, {agent_state(), []}, fn item, {state, acc} ->
          {:Transition, next, out} = Elzoo.AgentLoop.step(state, item, &Glue.estimate/1)
          {next, acc ++ [out]}
        end)

      assert requests == inner
      assert last_finish(requests)["schema_id"] == "elzoo.agent-loop.result"
    end

    test "estimate/1 is an upper bound of one token for each byte" do
      assert Glue.estimate("abcd") ==
               {:ok,
                %{
                  size: 4,
                  unit: :tokens,
                  direction: :upper_bound,
                  estimator_id: "recipe-test-bytes",
                  estimator_version: 1
                }}
    end
  end

  describe "glue_tool_forms" do
    @lua_limits %{
      "steps" => 1_000,
      "call_depth" => 8,
      "value_bytes" => 1_024,
      "memory_bytes" => 1_048_576,
      "wall_ms" => 500
    }

    defp lua_state do
      port = fn direction ->
        %{
          "id" => "alpha_" <> direction,
          "direction" => direction,
          "schema_id" => "elzoo.test.alpha",
          "schema_version" => 1
        }
      end

      manifest = %{
        "name" => "alpha",
        "version" => 1,
        "description" => "Function alpha",
        "arguments" => %{
          "port" => port.("input"),
          "schema" => %{
            "type" => "object",
            "properties" => %{"query" => %{"type" => "string"}},
            "required" => ["query"],
            "additionalProperties" => false
          }
        },
        "result" => %{
          "port" => port.("output"),
          "schema" => %{
            "type" => "object",
            "properties" => %{"count" => %{"type" => "integer"}},
            "required" => ["count"],
            "additionalProperties" => false
          }
        },
        "cost" => %{"unit" => "call", "estimate" => 1},
        "permissions" => ["read"]
      }

      {:ok, bindings} = LuaBinding.resolve([%{"name" => "alpha", "version" => 1}], [manifest])
      {:ok, source} = LuaBinding.source(bindings, "lua")

      {:ok, inner} =
        LuaTool.new(%{
          id: "t",
          source: "return function(input) return input end",
          policy: "lua-policy-3",
          limits: @lua_limits,
          bindings: bindings,
          sources: [source],
          source_id: "lua",
          max_calls: 4
        })

      inner
    end

    defp lua_start, do: start("elzoo.lua-tool.input", %{"input" => %{"q" => 1}})

    defp lua_run_result(payload),
      do: outcome("t:r:1", "completed", "elzoo.lua-tool.run-result", payload)

    defp lua_ok(value),
      do:
        lua_run_result(%{
          "ok" => %{
            "value" => value,
            "identity" => "lua-policy-3",
            "runtime" => %{"lua" => "5.4", "seed" => 7}
          }
        })

    defp lua_finish(to, result_input) do
      {_, requests} = fold(glue(:lua, to, lua_state()), [lua_start(), result_input])
      last_finish(requests)
    end

    defp tool_result(source, text),
      do: %{
        "schema_id" => "elzoo.agent-loop.tool-result",
        "schema_version" => 1,
        "payload" => %{
          "content" => %{
            "schema_id" => "elzoo.untrusted-content.marked",
            "schema_version" => 1,
            "sources" => [source],
            "trust" => "untrusted",
            "max_bytes" => 16_777_216,
            "content" => text
          },
          "media_type" => "text/plain",
          "encoding" => "utf8"
        }
      }

    defp graph_failed(to) do
      {_, requests} =
        fold(glue(:graph, to, graph_state()), [
          graph_start(),
          outcome("g:n:a", "failed", "elzoo.graph-run.node-result", nil)
        ])

      last_finish(requests)
    end

    test "a Lua tool that completed gives its result to a node" do
      action = lua_finish(:node, lua_ok(%{"b" => 2, "a" => [1, nil]}))

      assert action["id"] == "t:finish"
      assert matches?(action, node_result(%{"gives" => %{"b" => 2, "a" => [1, nil]}}))
    end

    test "a Lua tool that failed gives its reason to a node" do
      action = lua_finish(:node, lua_run_result(%{"refused" => "lua_error"}))

      assert action["id"] == "t:finish"
      assert matches?(action, node_result(%{"failed" => "sandbox_refused"}))
    end

    test "a Lua tool that completed gives the text of its result as a tool result" do
      action = lua_finish(:tool, lua_ok(%{"b" => 2, "a" => [1, nil], "c" => "x"}))

      assert action["id"] == "t:finish"
      assert matches?(action, tool_result("recipe-test:lua", ~s({"a":[1,null],"b":2,"c":"x"})))
      assert matches?(lua_finish(:tool, lua_ok("plain")), tool_result("recipe-test:lua", "plain"))
    end

    test "a Lua tool that failed gives a bracketed reason as a tool result" do
      action = lua_finish(:tool, lua_run_result(%{"host_outcome" => "timeout"}))

      assert matches?(
               action,
               tool_result("recipe-test:lua", "[lua tool failed: sandbox_host_outcome]")
             )

      other = lua_finish(:tool, lua_run_result(%{"nonsense" => 1}))
      assert matches?(other, tool_result("recipe-test:lua", "[lua tool failed: run_not_completed]"))
    end

    test "a graph that completed gives the text of its gives as a tool result" do
      {_, requests} =
        fold(glue(:graph, :tool, graph_state()), [
          graph_start(),
          outcome("g:n:a", "completed", "elzoo.graph-run.node-result", %{
            "gives" => %{"ga" => 7}
          })
        ])

      action = last_finish(requests)
      assert action["id"] == "g:finish"
      assert matches?(action, tool_result("recipe-test:graph", ~s({"ga":7})))
    end

    test "a graph that did not complete gives a bracketed reason as a tool result" do
      action = graph_failed(:tool)
      assert action["id"] == "g:finish"

      assert %{"payload" => %{"content" => %{"content" => "[graph failed: " <> _}}} = action
      assert matches?(action, %{"schema_id" => "elzoo.agent-loop.tool-result"})

      assert %{"failed" => reason} = graph_failed(:node)["payload"]
      assert action["payload"]["content"]["content"] == "[graph failed: #{reason}]"
      assert action["payload"]["content"]["sources"] == ["recipe-test:graph"]
    end

    test "an action that is not a finish is unchanged for a tool" do
      {_, tool} = fold(glue(:lua, :tool, lua_state()), [lua_start()])
      {_, root} = fold(glue(:lua, :root, lua_state()), [lua_start()])

      assert [{:some, %{"actions" => [%{"kind" => "local_work", "id" => "t:r:1"}]}}] = tool
      assert tool == root
    end

    test "a refused child answers start with one finish and then closes" do
      refused = %{
        kind: :refused,
        id: "c",
        schema_id: "elzoo.agent-loop.tool-result",
        payload: %{"content" => "x"}
      }

      assert {:Transition, %{kind: :closed} = closed, {:some, request}} =
               Glue.step(refused, start("elzoo.agent-loop.message", %{"text" => "go"}))

      assert request == %{
               "type" => "request",
               "version" => 1,
               "actions" => [
                 %{
                   "id" => "c:finish",
                   "kind" => "finish",
                   "schema_id" => "elzoo.agent-loop.tool-result",
                   "schema_version" => 1,
                   "payload" => %{"content" => "x"}
                 }
               ]
             }

      for input <- [start("x", nil), input("cancel", %{})] do
        assert {:Transition, ^closed, :none} = Glue.step(closed, input)
      end
    end

    test "a refused child ignores every other input and stays refused" do
      refused = %{kind: :refused, id: "c", schema_id: "s", payload: %{}}

      for item <- [
            input("cancel", %{}),
            input("run_ended", %{}),
            outcome("c:x", "completed", "s", %{})
          ] do
        assert {:Transition, ^refused, :none} = Glue.step(refused, item)
      end
    end

    test "lua_request/1 gives the sandbox request of a run payload" do
      payload = %{
        "source" => "return function(input) return input end",
        "input" => %{"q" => 1},
        "policy" => "lua-policy-3",
        "limits" => @lua_limits,
        "calls" => %{
          "mode" => "replay",
          "names" => ["alpha"],
          "recorded" => [%{"name" => "alpha", "arguments" => %{"x" => 1}, "result" => %{"n" => 2}}]
        }
      }

      assert Glue.lua_request(payload) == %{
               source: "return function(input) return input end",
               input: %{"q" => 1},
               policy: "lua-policy-3",
               limits: %{
                 steps: 1_000,
                 call_depth: 8,
                 value_bytes: 1_024,
                 memory_bytes: 1_048_576,
                 wall_ms: 500
               },
               calls: %{
                 mode: "replay",
                 names: ["alpha"],
                 recorded: [%{name: "alpha", arguments: %{"x" => 1}, result: %{"n" => 2}}]
               }
             }
    end

    test "lua_reply/1 gives the run result payload of each sandbox reply" do
      assert Glue.lua_reply(
               {:ok,
                %{
                  value: %{"a" => [1, nil]},
                  identity: "lua-policy-3",
                  runtime: %{lua: "5.4", seed: "7"}
                }}
             ) ==
               %{
                 "ok" => %{
                   "value" => %{"a" => [1, nil]},
                   "identity" => "lua-policy-3",
                   "runtime" => %{"lua" => "5.4", "seed" => "7"}
                 }
               }

      assert Glue.lua_reply({:pending_call, %{index: 0, name: "alpha", arguments: %{"x" => 1}}}) ==
               %{"pending_call" => %{"index" => 0, "name" => "alpha", "arguments" => %{"x" => 1}}}

      assert Glue.lua_reply({:refused, :lua_error}) == %{"refused" => "lua_error"}
      assert Glue.lua_reply({:host_outcome, :timeout}) == %{"host_outcome" => "timeout"}
    end
  end
end
