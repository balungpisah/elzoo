# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipeTest.Glue do
  @moduledoc """
  Pure operator over one callable of a recipe (agent, graph, decision or Lua tool),
  or over a refused child. With `to: :node` the finish of the callable becomes the
  node result of the graph node that called it; with `to: :tool` it becomes the tool
  result of the agent tool call that started it; with `to: :root` the request is
  given unchanged.

  States: `%{kind: :agent | :graph | :decision, to: to, inner: state}`, `%{kind: :lua,
  to: to, inner: lua_state}`, `%{kind: :refused, id: id, schema_id: s, payload: p}`
  (answers `start` with one finish request and becomes `:closed`) and `%{kind: :closed}`
  (no change, no request).

  `lua_request/1`, `lua_reply/1` and `lua_run/4` carry a `elzoo.lua-tool.run` payload to
  the sandbox and its reply back.
  """

  alias Elzoo.{AgentLoop, GraphRun, LuaSandbox, LuaTool, TypedDecision}

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

  def step(%{kind: :lua, inner: inner} = state, input) do
    {:Transition, next, out} = LuaTool.step(inner, input)
    {:Transition, %{state | inner: next}, convert(out, state)}
  end

  def step(%{kind: :refused, id: id, schema_id: schema_id, payload: payload}, %{
        "type" => "input",
        "kind" => "start"
      }) do
    request = %{
      "type" => "request",
      "version" => 1,
      "actions" => [
        %{
          "id" => id <> ":finish",
          "kind" => "finish",
          "schema_id" => schema_id,
          "schema_version" => 1,
          "payload" => payload
        }
      ]
    }

    {:Transition, %{kind: :closed}, {:some, request}}
  end

  def step(%{kind: kind} = state, _input) when kind in [:refused, :closed],
    do: {:Transition, state, :none}

  @doc "The sandbox request of an `elzoo.lua-tool.run` payload."
  def lua_request(%{
        "source" => source,
        "input" => input,
        "policy" => policy,
        "limits" => limits,
        "calls" => %{"mode" => mode, "names" => names, "recorded" => recorded}
      }) do
    %{
      source: source,
      input: input,
      policy: policy,
      limits: %{
        steps: limits["steps"],
        call_depth: limits["call_depth"],
        value_bytes: limits["value_bytes"],
        memory_bytes: limits["memory_bytes"],
        wall_ms: limits["wall_ms"]
      },
      calls: %{
        mode: mode,
        names: names,
        recorded:
          Enum.map(
            recorded,
            &%{name: &1["name"], arguments: &1["arguments"], result: &1["result"]}
          )
      }
    }
  end

  @doc "The `elzoo.lua-tool.run-result` payload of a sandbox reply."
  def lua_reply({:ok, reply}), do: %{"ok" => plain(reply)}
  def lua_reply({:pending_call, call}), do: %{"pending_call" => plain(call)}
  def lua_reply({:refused, reason}), do: %{"refused" => plain(reason)}
  def lua_reply({:host_outcome, reason}), do: %{"host_outcome" => plain(reason)}

  @doc """
  The held work of a Lua run: tell the driver, wait for `:recipe_test_go`, run the
  sandbox and give the run result payload.
  """
  def lua_run(driver, executable, action_id, payload) do
    send(driver, {:recipe_test_work, self(), action_id})

    receive do
      :recipe_test_go -> :ok
    end

    lua_reply(LuaSandbox.run(executable, lua_request(payload)))
  end

  defp plain(map) when is_map(map), do: Map.new(map, fn {k, v} -> {plain_key(k), plain(v)} end)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(value) when value in [nil, true, false], do: value
  defp plain(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp plain(value), do: value

  defp plain_key(key) when is_atom(key), do: Atom.to_string(key)
  defp plain_key(key), do: key

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

  defp convert({:some, request}, %{to: :tool} = state) do
    {:some, %{request | "actions" => Enum.map(request["actions"], &tool_result(&1, state))}}
  end

  defp convert(out, _), do: out

  defp tool_result(%{"kind" => "finish", "payload" => payload} = action, state) do
    %{
      action
      | "schema_id" => "elzoo.agent-loop.tool-result",
        "schema_version" => 1,
        "payload" => tool_content(state.kind, payload)
    }
  end

  defp tool_result(action, _), do: action

  defp tool_content(:lua, %{"status" => "completed", "result" => result}),
    do: tool_payload("recipe-test:lua", text(result))

  defp tool_content(:lua, %{"reason" => reason}),
    do: tool_payload("recipe-test:lua", "[lua tool failed: #{reason}]")

  defp tool_content(:graph, %{"status" => "completed", "gives" => gives}),
    do: tool_payload("recipe-test:graph", text(gives))

  defp tool_content(:graph, %{"reason" => reason}),
    do: tool_payload("recipe-test:graph", "[graph failed: #{reason}]")

  defp tool_payload(source, content) do
    %{
      "content" => %{
        "schema_id" => "elzoo.untrusted-content.marked",
        "schema_version" => 1,
        "sources" => [source],
        "trust" => "untrusted",
        "max_bytes" => 16_777_216,
        "content" => content
      },
      "media_type" => "text/plain",
      "encoding" => "utf8"
    }
  end

  defp text(value) when is_binary(value), do: value
  defp text(value), do: Jason.encode!(ordered(value))

  defp ordered(map) when is_map(map),
    do: %Jason.OrderedObject{
      values: map |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {k, v} -> {k, ordered(v)} end)
    }

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value

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

  defp payload(:lua, %{"status" => "completed", "result" => result}, _),
    do: %{"gives" => result}

  defp payload(:decision, %{"status" => "decided", "value" => value}, _) when is_binary(value),
    do: %{"gives" => %{"value" => value}, "choice" => value}

  defp payload(:decision, %{"status" => "decided", "value" => value}, _),
    do: %{"gives" => %{"value" => value}}

  defp payload(_, %{"reason" => reason}, _), do: %{"failed" => reason}
end
