# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipeTest.GlueTest do
  use ExUnit.Case, async: true

  alias Elzoo.{AgentLoop, GraphRun, TypedDecision}
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
end
