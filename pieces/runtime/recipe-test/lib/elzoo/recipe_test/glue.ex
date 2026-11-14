# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipeTest.Glue do
  @moduledoc """
  Pure operator over one callable of a recipe (agent, graph or decision). With
  `to: :node` the finish of the callable becomes the node result of the graph
  node that called it; with `to: :root` the request is given unchanged.
  """

  alias Elzoo.{AgentLoop, GraphRun, TypedDecision}

  def step(%{kind: :agent, inner: inner} = state, input) do
    state = %{state | content: content(state.content, input)}
    {:Transition, next, out} = AgentLoop.step(inner, input, &estimate/1)
    {:Transition, %{state | inner: next}, convert(out, state)}
  end

  def step(%{kind: :graph, inner: inner} = state, input) do
    {:Transition, next, out} = GraphRun.step(inner, input)
    {:Transition, %{state | inner: next}, convert(out, state)}
  end

  def step(%{kind: :decision, inner: inner} = state, input) do
    {:Transition, next, out} = TypedDecision.step(inner, input)
    {:Transition, %{state | inner: next}, convert(out, state)}
  end

  def estimate(bytes) do
    {:ok,
     %{
       size: byte_size(bytes),
       unit: :tokens,
       direction: :upper_bound,
       estimator_id: "recipe-test-bytes",
       estimator_version: 1
     }}
  end

  defp content(
         _,
         %{
           "kind" => "action_outcome",
           "outcome" => "completed",
           "schema_id" => "elzoo.ai-text.result",
           "payload" => %{"content" => text}
         }
       )
       when is_binary(text),
       do: text

  defp content(previous, _), do: previous

  defp convert({:some, request}, %{to: :node} = state) do
    {:some, %{request | "actions" => Enum.map(request["actions"], &node_result(&1, state))}}
  end

  defp convert(out, _), do: out

  defp node_result(%{"kind" => "finish", "payload" => payload} = action, state) do
    %{
      action
      | "schema_id" => "elzoo.graph-run.node-result",
        "schema_version" => 1,
        "payload" => payload(state.kind, payload, state)
    }
  end

  defp node_result(action, _), do: action

  defp payload(:agent, %{"status" => "answered"}, state),
    do: %{"gives" => %{"text" => state.content}}

  defp payload(:graph, %{"status" => "completed", "gives" => gives}, _), do: %{"gives" => gives}

  defp payload(:decision, %{"status" => "decided", "value" => value}, _) when is_binary(value),
    do: %{"gives" => %{"value" => value}, "choice" => value}

  defp payload(:decision, %{"status" => "decided", "value" => value}, _),
    do: %{"gives" => %{"value" => value}}

  defp payload(_, %{"reason" => reason}, _), do: %{"failed" => reason}
end
