# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TypedDecision do
  @moduledoc "Pure pattern step: one model answer of a fixed set or of a schema, with bounded repair."
  alias Elzoo.{OutputRepair, PatternStep, PayloadSchema}

  @invalid %{
    "missing" => :missing,
    "schema_mismatch" => :schema_mismatch,
    "invalid_json" => :invalid_json
  }
  @finishes %{
    "stop" => :stop,
    "length" => :length,
    "tool_calls" => :tool_calls,
    "content_filter" => :content_filter,
    "refusal" => :refusal
  }

  @doc "Check a spec; `{:ok, state}` or `{:error, :invalid_set | :invalid_schema | :invalid_spec}`."
  def new(%{id: id, request: request, port: port, answer: answer, repairs: repairs} = spec)
      when map_size(spec) == 5 do
    if text?(id) and byte_size(id) <= 128 and request?(request) and output_port?(port) and
         is_integer(repairs) and repairs in 0..8 do
      with {:ok, kind, schema} <- answer(answer),
           {:ok, _} <- build(port, schema) do
        {:ok,
         %{
           phase: :new,
           id: id,
           request: request,
           port: port,
           answer: kind,
           schema: schema,
           repairs: repairs,
           used: 0
         }}
      end
    else
      {:error, :invalid_spec}
    end
  end

  def new(_), do: {:error, :invalid_spec}

  @doc "One `core/operator` transition over a neutral PatternStep input map."
  def step(state, input) do
    case PatternStep.decode(input) do
      {:ok, _} -> transition(state, input)
      _ -> unchanged(state)
    end
  end

  defp transition(%{phase: phase} = state, %{"kind" => kind})
       when phase in [:new, :waiting] and kind in ["cancel", "run_ended"],
       do: {:Transition, %{state | phase: :closed}, :none}

  defp transition(%{phase: :new} = state, %{"kind" => "start"}),
    do: {:Transition, %{state | phase: :waiting}, {:some, call(state, [])}}

  defp transition(%{phase: :waiting} = state, %{"kind" => "action_outcome"} = input) do
    cond do
      input["action_id"] != call_id(state) -> unchanged(state)
      input["outcome"] == "late" -> unchanged(state)
      input["outcome"] == "completed" -> completed(state, input)
      true -> failed(state, "call_not_completed", [], input["outcome"])
    end
  end

  defp transition(state, _), do: unchanged(state)

  defp completed(state, input) do
    with %{"schema_id" => "elzoo.ai-text.result", "schema_version" => 1, "payload" => payload} <-
           input,
         {:ok, completed} <- result(payload),
         {:ok, checked} <- build(state.port, state.schema) do
      case OutputRepair.decide(checked, state.port, completed, state.used, state.repairs) do
        {:accept, value} ->
          decided(state, value)

        {:repair, violations} ->
          next = %{state | used: state.used + 1}
          {:Transition, next, {:some, call(next, repair(completed.content, violations))}}

        {:fail, reason, violations} ->
          failed(state, Atom.to_string(reason), violations, "completed")

        {:error, :invalid_input} ->
          failed(state, "malformed_result", [], "completed")
      end
    else
      _ -> failed(state, "malformed_result", [], "completed")
    end
  end

  defp decided(%{answer: :schema} = state, value), do: finish(state, decided_result(state, value))

  defp decided(%{answer: :set, schema: schema} = state, value) do
    case value do
      %{"answer" => member} when is_binary(member) ->
        if member in schema["properties"]["answer"]["enum"],
          do: finish(state, decided_result(state, member)),
          else: failed(state, "malformed_result", [], "completed")

      _ ->
        failed(state, "malformed_result", [], "completed")
    end
  end

  defp decided_result(state, value),
    do: %{
      "status" => "decided",
      "value" => value,
      "repairs" => state.used,
      "action_id" => call_id(state)
    }

  defp failed(state, reason, violations, outcome) do
    finish(state, %{
      "status" => "failed",
      "reason" => reason,
      "violations" => Enum.map(violations, &violation/1),
      "outcome" => outcome,
      "repairs" => state.used,
      "action_id" => call_id(state)
    })
  end

  defp finish(state, result) do
    action = %{
      "id" => state.id <> ":finish",
      "kind" => "finish",
      "schema_id" => "elzoo.typed-decision.result",
      "schema_version" => 1,
      "payload" => result
    }

    {:Transition, %{state | phase: :closed}, {:some, request(action)}}
  end

  defp violation(%{path: path, code: code}) do
    %{
      "path" => Enum.map(path, fn segment -> if segment == :key, do: "*", else: segment end),
      "code" => Atom.to_string(code)
    }
  end

  defp call(state, extra) do
    payload =
      state.request
      |> Map.put("output_schema", state.schema)
      |> Map.update!("messages", &(&1 ++ extra))

    request(%{
      "id" => call_id(state),
      "kind" => "model_call",
      "schema_id" => "elzoo/ai-text-request",
      "schema_version" => 1,
      "payload" => payload
    })
  end

  defp repair(content, violations) do
    [
      %{"role" => "assistant", "text" => content},
      %{"role" => "user", "text" => OutputRepair.render(violations)}
    ]
  end

  defp request(action), do: %{"type" => "request", "version" => 1, "actions" => [action]}
  defp call_id(state), do: state.id <> ":call:" <> Integer.to_string(state.used)
  defp unchanged(state), do: {:Transition, state, :none}

  # The JSON view of the ai-text completed map; only these three members are read.
  defp result(%{"content" => content, "structured" => structured, "finish" => finish}) do
    with {:ok, structured} <- structured(structured),
         {:ok, finish} <- finish(finish) do
      {:ok, %{content: content, structured: structured, finish: finish}}
    end
  end

  defp result(_), do: :error

  defp structured(nil), do: {:ok, nil}
  defp structured(%{"valid" => value} = map) when map_size(map) == 1, do: {:ok, {:valid, value}}

  defp structured(%{"invalid" => reason} = map) when map_size(map) == 1 do
    with {:ok, reason} <- Map.fetch(@invalid, reason), do: {:ok, {:invalid, reason}}
  end

  defp structured(_), do: :error

  defp finish(%{"other" => text} = map) when map_size(map) == 1 and is_binary(text),
    do: {:ok, {:other, text}}

  defp finish(finish) when is_binary(finish), do: Map.fetch(@finishes, finish)
  defp finish(_), do: :error

  defp answer({:set, members}) do
    if is_list(members) and length(members) >= 2 and Enum.all?(members, &text?/1) and
         length(Enum.uniq(members)) == length(members) do
      {:ok, :set,
       %{
         "type" => "object",
         "properties" => %{"answer" => %{"enum" => members}},
         "required" => ["answer"],
         "additionalProperties" => false
       }}
    else
      {:error, :invalid_set}
    end
  end

  defp answer({:schema, schema}), do: {:ok, :schema, schema}
  defp answer(_), do: {:error, :invalid_spec}

  defp build(port, schema) do
    case PayloadSchema.build(port, schema) do
      {:ok, checked} -> {:ok, checked}
      _ -> {:error, :invalid_schema}
    end
  end

  defp request?(request) do
    is_map(request) and not is_struct(request) and is_list(request["messages"]) and
      not Map.has_key?(request, "output_schema")
  end

  defp output_port?(port),
    do: match?({:ok, _}, Elzoo.Port.decode(port)) and port["direction"] == "output"

  defp text?(value), do: is_binary(value) and value != "" and String.valid?(value)
end
