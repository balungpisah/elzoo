# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ContextCompaction do
  @moduledoc """
  A pure pattern step that asks a model for one summary of a range of history
  and carries the keep-rule records of the range beside the summary. It gives
  one `model_call` action; the caller and the engine keep the state, the
  outcome and the original history.
  """

  alias Elzoo.{PatternStep, PromptAssembly, UntrustedContent}

  @input_keys [
    :action_id,
    :entries,
    :model,
    :max_output_tokens,
    :role_instructions,
    :window,
    :max_request_bytes,
    :summary
  ]
  @request_key {"elzoo/ai-text-request", 1}
  @result_key {"elzoo.ai-text.result", 1}

  @doc "Builds the summary request; `{:ok, state, request}` or `{:error, reason}`."
  def open(input, estimate) do
    with :ok <- check_input(input),
         {records, free} = Enum.split_with(input.entries, &match?(%{kind: :record}, &1)),
         :ok <- if(free == [], do: {:error, :nothing_to_summarize}, else: :ok),
         {:ok, %{request: payload, dropped: []}} <- summary_request(input, free, estimate),
         {:ok, request} <- step_request(input.action_id, payload) do
      state = %{
        tracker: PatternStep.open(request),
        records: records,
        derived_from: Enum.map(free, &%{item_id: &1.id, version: 1}),
        summary: input.summary
      }

      {:ok, state, PatternStep.encode(request)}
    else
      {:ok, %{dropped: [_ | _]}} -> {:error, :over_limit}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Settles the one action with a neutral pattern-step input."
  def accept(state, input) do
    with {:ok, checked} <- decode(input),
         %{"type" => "input"} <- PatternStep.encode(checked),
         {:applied, _} <- PatternStep.accept(state.tracker, checked),
         %{"outcome" => "completed"} = outcome <- PatternStep.encode(checked),
         {:ok, content} <- summary(outcome, state.summary.max_bytes) do
      compacted = %{
        entries: state.records ++ [summary_entry(state.summary, content)],
        derived_from: state.derived_from
      }

      with :ok <- check(state.records, compacted), do: {:ok, compacted}
    else
      {:late, _} -> {:late, state}
      %{"type" => "request"} -> {:error, :invalid_input}
      {:refused, reason, _} -> {:error, reason}
      %{"outcome" => outcome} -> {:error, {:model_call, outcome}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "`:ok` when each keep-rule record of `entries` is in `compacted.entries`."
  def check(entries, compacted) do
    kept = record_ids(compacted.entries)

    case Enum.reject(record_ids(entries), &(&1 in kept)) do
      [] -> :ok
      ids -> {:error, {:keep_items_lost, ids}}
    end
  end

  defp record_ids(entries), do: for(%{kind: :record, id: id} <- entries, do: id)

  defp check_input(%{} = input) do
    ok =
      map_size(input) == length(@input_keys) and Enum.all?(@input_keys, &is_map_key(input, &1)) and
        is_binary(input.action_id) and input.action_id != "" and String.valid?(input.action_id) and
        is_list(input.entries) and length(input.entries) in 1..256 and
        Enum.all?(input.entries, &(is_map(&1) and record?(&1))) and
        unique_ids?(input.entries) and summary?(input.summary, input.entries)

    if ok, do: :ok, else: {:error, :invalid_input}
  end

  defp check_input(_), do: {:error, :invalid_input}

  # Records do not reach the build, so their shape is checked here.
  defp record?(%{kind: :record} = e) do
    map_size(e) == 4 and id?(Map.get(e, :id)) and is_map(Map.get(e, :record)) and
      json?(Map.get(e, :record)) and
      Map.get(e, :keep) in [:goal, :open_action, :decision, :failed_approach]
  end

  defp record?(_), do: true

  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp json?(list) when is_list(list), do: Enum.all?(list, &json?/1)
  defp json?(%{} = map), do: Enum.all?(map, fn {k, v} -> is_binary(k) and json?(v) end)
  defp json?(_), do: false

  defp unique_ids?(entries) do
    ids = Enum.map(entries, &Map.get(&1, :id))
    length(Enum.uniq(ids)) == length(ids)
  end

  defp id?(id), do: is_binary(id) and byte_size(id) in 1..1024 and String.valid?(id)

  # The source grammar and the bound are those of a marked value.
  defp summary?(%{id: id, source: source, max_bytes: max_bytes} = summary, entries) do
    map_size(summary) == 3 and id?(id) and not Enum.any?(entries, &(Map.get(&1, :id) == id)) and
      match?({:ok, _}, mark(source, max_bytes, ""))
  end

  defp summary?(_, _), do: false

  # Records travel in the step state only; the model sees the free text.
  defp summary_request(input, free, estimate) do
    PromptAssembly.build(
      %{
        model: input.model,
        max_output_tokens: input.max_output_tokens,
        role_instructions: input.role_instructions,
        skill_instructions: [],
        memory: [],
        history: free,
        tools: [],
        window: input.window,
        max_request_bytes: input.max_request_bytes,
        max_image_refs: 256
      },
      estimate
    )
  end

  defp step_request(action_id, payload) do
    {schema_id, schema_version} = @request_key

    request = %{
      "type" => "request",
      "version" => 1,
      "actions" => [
        %{
          "id" => action_id,
          "kind" => "model_call",
          "schema_id" => schema_id,
          "schema_version" => schema_version,
          "payload" => payload
        }
      ]
    }

    case PatternStep.decode(request) do
      {:ok, checked} -> {:ok, checked}
      _ -> {:error, :invalid_input}
    end
  end

  defp decode(input) do
    case PatternStep.decode(input) do
      {:ok, checked} -> {:ok, checked}
      _ -> {:error, :invalid_input}
    end
  end

  defp summary(%{"schema_id" => id, "schema_version" => v, "payload" => payload}, max_bytes) do
    with true <- {id, v} == @result_key,
         %{"finish" => "stop", "content" => content} when is_binary(content) <- payload,
         true <- content != "" and byte_size(content) <= max_bytes and String.valid?(content) do
      {:ok, content}
    else
      _ -> {:error, :invalid_summary}
    end
  end

  defp summary_entry(summary, content) do
    {:ok, marked} = mark(summary.source, summary.max_bytes, content)

    %{
      kind: :content,
      id: summary.id,
      content: UntrustedContent.encode(marked),
      ref_media_type: nil
    }
  end

  defp mark(source, max_bytes, content) do
    UntrustedContent.decode(%{
      "schema_id" => "elzoo.untrusted-content.marked",
      "schema_version" => 1,
      "sources" => [source],
      "trust" => "derived",
      "max_bytes" => max_bytes,
      "content" => content
    })
  end
end
