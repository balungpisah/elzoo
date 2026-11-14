# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaTool do
  @moduledoc """
  A tool written in Lua as one pure pattern step over `Elzoo.PatternStep` v1 neutral
  maps. It runs no Lua and calls no module: it asks for one run action that replays the
  function from the start with the recorded module calls, and for one tool-call action
  for the first call that has no record. See the bundle README.
  """
  alias Elzoo.{LuaBinding, PatternStep, ToolRegistry}

  @bound 65_536
  @spec_keys ~w(bindings id limits max_calls policy source source_id sources)a
  @limit_keys ~w(call_depth memory_bytes steps value_bytes wall_ms)
  @input_key "elzoo.lua-tool.input"
  @run_key "elzoo.lua-tool.run"
  @run_result_key "elzoo.lua-tool.run-result"
  @call_key "elzoo.lua-tool.module-call"
  @call_result_key "elzoo.lua-tool.module-result"
  @finish_key "elzoo.lua-tool.result"

  @doc "Check the spec and give the first state; see the README for the refusals."
  def new(spec) do
    with :ok <- shape(spec),
         {:ok, tools} <- tools(spec),
         :ok <- bound_names(spec.bindings, tools) do
      state = %{
        phase: :new,
        id: spec.id,
        source: spec.source,
        policy: spec.policy,
        limits: spec.limits,
        bindings: spec.bindings,
        max_calls: spec.max_calls,
        tools: tools,
        input: nil,
        runs: 0,
        pending: nil,
        record: [],
        last_ok: nil,
        tracker: nil
      }

      if bytes(state) <= @bound, do: {:ok, state}, else: {:error, :state_too_large}
    end
  end

  @doc "One recorded input: `{:Transition, new_state, :none | {:some, request}}`."
  def step(%{phase: :closed} = state, _input), do: {:Transition, state, :none}

  def step(state, input) do
    with {:ok, checked} <- PatternStep.decode(input),
         %{"type" => "input"} = map <- PatternStep.encode(checked) do
      read(state, map)
    else
      _ -> {:Transition, state, :none}
    end
  end

  # Inputs

  defp read(state, %{"kind" => kind}) when kind in ["cancel", "run_ended"],
    do: {:Transition, closed(state), :none}

  defp read(%{phase: :new} = state, %{"kind" => "start"} = input) do
    case input do
      %{"schema_id" => @input_key, "schema_version" => 1, "payload" => %{"input" => value} = p}
      when map_size(p) == 1 ->
        if json?(value) do
          run(%{state | input: value}) |> settle()
        else
          finish_failed(state, "invalid_input", nil)
        end

      _ ->
        finish_failed(state, "invalid_input", nil)
    end
  end

  defp read(%{phase: phase, tracker: tracker} = state, %{"kind" => "action_outcome"} = input)
       when phase in [:running, :calling] do
    case PatternStep.accept(tracker, decoded(input)) do
      {:applied, tracker} -> outcome(%{state | tracker: tracker}, input)
      _ -> {:Transition, state, :none}
    end
  end

  defp read(state, _input), do: {:Transition, state, :none}

  defp decoded(input) do
    {:ok, checked} = PatternStep.decode(input)
    checked
  end

  defp outcome(%{phase: :running} = state, input) do
    case run_result(input) do
      {:ok, form} -> running(%{state | last_ok: input["action_id"]}, form, input["action_id"])
      :error -> finish_failed(state, "run_not_completed", nil)
    end
  end

  defp outcome(%{phase: :calling} = state, input) do
    case module_result(input) do
      {:ok, value} -> calling(state, value, input["action_id"])
      :error -> finish_failed(state, "module_call_not_completed", nil)
    end
  end

  defp run_result(%{
         "outcome" => "completed",
         "schema_id" => @run_result_key,
         "schema_version" => 1,
         "payload" => payload
       }) do
    case payload do
      %{"ok" => %{"value" => _, "identity" => _, "runtime" => _} = ok} = p
      when map_size(p) == 1 and map_size(ok) == 3 ->
        if json?(ok), do: {:ok, {:ok, ok["value"]}}, else: :error

      %{"pending_call" => %{"index" => index, "name" => name, "arguments" => args} = call} = p
      when map_size(p) == 1 and map_size(call) == 3 and is_integer(index) and index >= 0 and
             is_binary(name) and name != "" ->
        if json?(call), do: {:ok, {:pending, index, name, args}}, else: :error

      %{"refused" => reason} = p when map_size(p) == 1 ->
        if text?(reason), do: {:ok, {:refused, reason}}, else: :error

      %{"host_outcome" => reason} = p when map_size(p) == 1 ->
        if text?(reason), do: {:ok, {:host_outcome, reason}}, else: :error

      _ ->
        :error
    end
  end

  defp run_result(_), do: :error

  defp module_result(%{
         "outcome" => "completed",
         "schema_id" => @call_result_key,
         "schema_version" => 1,
         "payload" => %{"result" => value} = payload
       })
       when map_size(payload) == 1 do
    if json?(value), do: {:ok, value}, else: :error
  end

  defp module_result(_), do: :error

  # A run result, accepted

  defp running(state, {:ok, value}, action_id) do
    finish(state, %{
      "status" => "completed",
      "reason" => nil,
      "detail" => nil,
      "action_id" => action_id,
      "result" => value
    })
  end

  defp running(state, {:refused, detail}, _), do: finish_failed(state, "sandbox_refused", detail)

  defp running(state, {:host_outcome, detail}, _),
    do: finish_failed(state, "sandbox_host_outcome", detail)

  defp running(state, {:pending, index, name, arguments}, _) do
    count = length(state.record)

    cond do
      index != count or not is_map_key(state.tools, name) ->
        finish_failed(state, "call_mismatch", nil)

      count == state.max_calls ->
        finish_failed(state, "call_limit", nil)

      LuaBinding.check_arguments(state.bindings, name, arguments) != :ok ->
        finish_failed(state, "invalid_arguments", nil)

      true ->
        tool = Map.fetch!(state.tools, name)

        request =
          request(state.id <> ":c:" <> Integer.to_string(index), "tool_call", @call_key, %{
            "alias" => tool["alias"],
            "source" => tool["source"],
            "tool" => tool["tool"],
            "version" => tool["version"],
            "arguments" => arguments
          })

        next = %{
          state
          | phase: :calling,
            pending: %{"name" => name, "arguments" => arguments},
            tracker: open(request)
        }

        settle({next, request})
    end
  end

  # A module result, read

  defp calling(state, value, action_id) do
    %{"name" => name, "arguments" => arguments} = state.pending

    case LuaBinding.check_result(state.bindings, name, value) do
      :ok ->
        entry = %{"name" => name, "arguments" => arguments, "result" => value}

        run(%{state | record: state.record ++ [entry], pending: nil, last_ok: action_id})
        |> settle()

      _ ->
        finish_failed(state, "invalid_module_result", nil)
    end
  end

  # Requests

  defp run(state) do
    runs = state.runs + 1

    request =
      request(state.id <> ":r:" <> Integer.to_string(runs), "local_work", @run_key, %{
        "source" => state.source,
        "input" => state.input,
        "policy" => state.policy,
        "limits" => state.limits,
        "calls" => %{
          "mode" => "replay",
          "names" => LuaBinding.names(state.bindings),
          "recorded" => state.record
        }
      })

    {%{state | phase: :running, runs: runs, tracker: open(request)}, request}
  end

  defp request(id, kind, schema_id, payload) do
    %{
      "type" => "request",
      "version" => 1,
      "actions" => [
        %{
          "id" => id,
          "kind" => kind,
          "schema_id" => schema_id,
          "schema_version" => 1,
          "payload" => payload
        }
      ]
    }
  end

  defp open(request) do
    {:ok, checked} = PatternStep.decode(request)
    PatternStep.open(checked)
  end

  # A next state over the bound gives the finish `failed`, `state_over_bound`.
  defp settle({next, request}) do
    if bytes(next) <= @bound,
      do: {:Transition, next, {:some, request}},
      else: finish_failed(next, "state_over_bound", nil)
  end

  defp finish_failed(state, reason, detail) do
    finish(state, %{
      "status" => "failed",
      "reason" => reason,
      "detail" => detail,
      "action_id" => state.last_ok,
      "result" => nil
    })
  end

  defp finish(state, payload) do
    request = request(state.id <> ":finish", "finish", @finish_key, payload)
    {:Transition, closed(state), {:some, request}}
  end

  defp closed(state), do: %{phase: :closed, id: state.id}

  # The spec

  defp shape(%{} = spec) when not is_struct(spec) do
    with true <- Enum.sort(Map.keys(spec)) == @spec_keys,
         true <- id?(spec.id),
         true <- is_binary(spec.source) and String.valid?(spec.source),
         true <- text?(spec.policy),
         true <- limits?(spec.limits),
         true <- is_list(LuaBinding.names(spec.bindings)),
         true <- is_binary(spec.source_id),
         true <- is_integer(spec.max_calls) and spec.max_calls in 0..256 do
      :ok
    else
      _ -> {:error, :invalid_spec}
    end
  end

  defp shape(_), do: {:error, :invalid_spec}

  defp id?(id),
    do:
      is_binary(id) and String.valid?(id) and byte_size(id) in 1..64//1 and
        not String.contains?(id, ":")

  defp limits?(limits) when is_map(limits) and not is_struct(limits),
    do:
      Enum.sort(Map.keys(limits)) == @limit_keys and
        Enum.all?(limits, fn {_, v} -> is_integer(v) and v > 0 end)

  defp limits?(_), do: false

  defp tools(spec) do
    case ToolRegistry.snapshot(spec.sources) do
      {:error, reason} ->
        {:error, {:sources, reason}}

      {:ok, snapshot} ->
        tools =
          for %{"name" => name} <- ToolRegistry.tools(snapshot),
              {:resolved, tool} <- [ToolRegistry.resolve(snapshot, name)],
              tool.source == spec.source_id,
              into: %{} do
            {tool.tool,
             %{
               "alias" => tool.alias,
               "source" => tool.source,
               "tool" => tool.tool,
               "version" => tool.version
             }}
          end

        {:ok, tools}
    end
  end

  defp bound_names(bindings, tools) do
    case Enum.find(LuaBinding.names(bindings), &(not is_map_key(tools, &1))) do
      nil -> :ok
      name -> {:error, {:unbound_function, name}}
    end
  end

  # Data

  defp text?(value), do: is_binary(value) and value != "" and String.valid?(value)

  defp bytes(term),
    do: byte_size(:erlang.term_to_binary(term, [:deterministic, {:minor_version, 2}]))

  defp json?(value) when is_nil(value) or is_boolean(value) or is_number(value), do: true
  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?([]), do: true
  defp json?([head | rest]), do: json?(head) and is_list(rest) and json?(rest)

  defp json?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and json?(key) and json?(item) end)

  defp json?(_), do: false
end
