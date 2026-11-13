# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PromptAssembly do
  @moduledoc """
  Builds one `integration/ai-text` request from instructions, selected memory,
  history and a tool list, in one declared order, inside a token limit and the
  hard bounds of ai-text, with one declared drop order. Pure: the token
  estimate is a function that the host supplies.
  """

  alias Elzoo.AiText.Request
  alias Elzoo.UntrustedContent

  @input_keys [
    :model,
    :max_output_tokens,
    :role_instructions,
    :skill_instructions,
    :memory,
    :history,
    :tools,
    :window,
    :max_request_bytes,
    :max_image_refs
  ]
  @window_keys [:provider_id, :model_id, :size, :unit, :estimator_id, :estimator_version]
  @estimate_keys [:size, :unit, :direction, :estimator_id, :estimator_version]
  @entry_keys %{
    user: [:kind, :id, :text],
    assistant: [:kind, :id, :text, :tool_calls],
    tool_result: [:kind, :id, :tool_use_id, :content, :ref_media_type],
    content: [:kind, :id, :content, :ref_media_type],
    record: [:kind, :id, :keep, :record]
  }
  @keeps [:goal, :open_action, :decision, :failed_approach]
  @removed "[image reference removed]"

  @doc "Builds the request; see the README for the order, the drop order and the results."
  def build(input, estimate) do
    with :ok <- check_input(input, estimate),
         {:ok, memory} <- mark_all(input.memory),
         {:ok, history} <- mark_all(input.history),
         :ok <- check_tool_results(history),
         :ok <- check_tools(input.tools) do
      {history, removed} = remove_old_image_refs(history, input.max_image_refs)
      memory = Enum.map(memory, &{&1.id, message(&1)})
      history = Enum.map(history, &Map.put(&1, :message, message(&1)))
      fit(input, estimate, memory, segments(history), [], removed)
    end
  end

  # Shapes. Content stays a term here; `mark_all/1` checks it.

  defp check_input(%{} = input, estimate) when is_function(estimate, 1) do
    ok =
      exact?(input, @input_keys) and is_binary(input.model) and
        is_integer(input.max_output_tokens) and
        texts?(input.role_instructions) and input.role_instructions != [] and
        texts?(input.skill_instructions) and
        is_list(input.memory) and Enum.all?(input.memory, &memory?/1) and
        is_list(input.history) and Enum.all?(input.history, &entry?/1) and
        is_list(input.tools) and Enum.all?(input.tools, &json?/1) and
        window?(input.window) and
        is_integer(input.max_request_bytes) and input.max_request_bytes in 1..65_536 and
        is_integer(input.max_image_refs) and input.max_image_refs in 0..256 and
        unique_ids?(input.memory ++ input.history)

    if ok, do: :ok, else: {:error, :invalid_input}
  end

  defp check_input(_, _), do: {:error, :invalid_input}

  defp memory?(item), do: is_map(item) and exact?(item, [:id, :content]) and id?(item.id)

  defp entry?(%{kind: kind} = e) when is_map_key(@entry_keys, kind) do
    exact?(e, @entry_keys[kind]) and id?(e.id) and fields?(e)
  end

  defp entry?(_), do: false

  defp fields?(%{kind: :user, text: text}), do: text?(text)

  defp fields?(%{kind: :assistant, text: text, tool_calls: calls}),
    do: text?(text) and is_list(calls) and Enum.all?(calls, &call?/1)

  defp fields?(%{kind: :tool_result} = e), do: text?(e.tool_use_id) and media?(e.ref_media_type)
  defp fields?(%{kind: :content} = e), do: media?(e.ref_media_type)

  defp fields?(%{kind: :record, keep: keep, record: record}),
    do: keep in @keeps and is_map(record) and json?(record)

  defp call?(%{"id" => id, "name" => name, "arguments" => args} = call),
    do: map_size(call) == 3 and text?(id) and text?(name) and is_map(args) and json?(args)

  defp call?(_), do: false

  defp window?(%{} = w) do
    exact?(w, @window_keys) and w.unit == :tokens and id?(w.provider_id) and id?(w.model_id) and
      is_integer(w.size) and w.size >= 0 and id?(w.estimator_id) and
      is_integer(w.estimator_version) and w.estimator_version >= 1
  end

  defp window?(_), do: false

  defp unique_ids?(items) do
    ids = Enum.map(items, & &1.id)
    length(Enum.uniq(ids)) == length(ids)
  end

  defp exact?(map, keys),
    do: map_size(map) == length(keys) and Enum.all?(keys, &is_map_key(map, &1))

  defp id?(id), do: text?(id) and byte_size(id) in 1..1024
  defp text?(text), do: is_binary(text) and String.valid?(text)
  defp texts?(list), do: is_list(list) and Enum.all?(list, &text?/1)
  defp media?(type), do: is_nil(type) or text?(type)

  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp json?(list) when is_list(list), do: Enum.all?(list, &json?/1)
  defp json?(%{} = map), do: Enum.all?(map, fn {k, v} -> text?(k) and json?(v) end)
  defp json?(_), do: false

  # Marks: each `content` becomes a checked value or the call is refused.

  defp mark_all(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case mark(item) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        :error -> {:halt, {:error, :unmarked}}
      end
    end)
    |> then(fn
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end)
  end

  defp mark(%{content: content} = item) do
    case UntrustedContent.decode(content) do
      {:ok, marked} -> {:ok, %{item | content: marked}}
      _ -> :error
    end
  end

  defp mark(item), do: {:ok, item}

  # A result follows its call with only results between, once per call.

  defp check_tool_results(history) do
    history
    |> Enum.reduce_while(nil, fn
      %{kind: :assistant, tool_calls: calls}, _ ->
        {:cont, {Enum.map(calls, & &1["id"]), []}}

      %{kind: :tool_result, tool_use_id: id}, {calls, answered} ->
        if id in calls and id not in answered,
          do: {:cont, {calls, [id | answered]}},
          else: {:halt, :orphan}

      %{kind: :tool_result}, nil ->
        {:halt, :orphan}

      _, _ ->
        {:cont, nil}
    end)
    |> case do
      :orphan -> {:error, :orphan_tool_result}
      _ -> :ok
    end
  end

  defp check_tools(tools) do
    cond do
      length(tools) > 64 ->
        {:error, :too_many_tools}

      Enum.any?(
        tools,
        &(is_map(&1) and is_binary(&1["description"]) and
              byte_size(&1["description"]) > 4096)
      ) ->
        {:error, :tool_description_too_large}

      true ->
        :ok
    end
  end

  # Rule 1: the newest `max` image references stay; each older one keeps its message.

  defp remove_old_image_refs(history, max) do
    refs = Enum.filter(history, &image_ref?/1)
    old = refs |> Enum.take(max(length(refs) - max, 0)) |> Enum.map(& &1.id)

    history =
      Enum.map(history, fn entry ->
        if entry.id in old, do: %{entry | content: removed(entry.content)}, else: entry
      end)

    {history, old}
  end

  defp image_ref?(%{ref_media_type: "image/" <> _}), do: true
  defp image_ref?(_), do: false

  defp removed(marked) do
    map = UntrustedContent.encode(marked)

    {:ok, marked} =
      UntrustedContent.decode(%{
        map
        | "content" => @removed,
          "max_bytes" => max(map["max_bytes"], byte_size(@removed))
      })

    marked
  end

  # Messages, rendered once.

  defp message(%{kind: :user, text: text}), do: %{"role" => "user", "text" => text}

  defp message(%{kind: :content, content: c}), do: %{"role" => "user", "text" => block(c)}

  defp message(%{kind: :assistant, text: text, tool_calls: []}),
    do: %{"role" => "assistant", "text" => text}

  defp message(%{kind: :assistant, text: text, tool_calls: calls}),
    do: %{"role" => "assistant", "text" => text, "tool_calls" => calls}

  defp message(%{kind: :tool_result, tool_use_id: id, content: c}),
    do: %{"role" => "tool_result", "tool_use_id" => id, "text" => block(c)}

  defp message(%{kind: :record, keep: keep, record: record}),
    do: %{
      "role" => "user",
      "text" => Request.canonical(%{"keep" => Atom.to_string(keep), "record" => record})
    }

  # Memory items have no kind: they are always marked content.
  defp message(%{content: c}), do: block(c)

  defp block(marked) do
    {:ok, text} = UntrustedContent.render(marked)
    text
  end

  # History as segments in time order: `{:unit, entries}` or `{:record, entry}`.

  defp segments(history) do
    history
    |> Enum.reduce([], fn
      %{kind: :tool_result} = e, [{:unit, unit} | rest] -> [{:unit, unit ++ [e]} | rest]
      %{kind: :record} = e, acc -> [{:record, e} | acc]
      e, acc -> [{:unit, [e]} | acc]
    end)
    |> Enum.reverse()
  end

  # Rules 2 and 3: check, drop one thing, check again.

  defp fit(input, estimate, memory, segments, dropped, removed) do
    request = request(input, memory, segments)

    case check(request, input, estimate) do
      {:ok, canonical, value} ->
        {:ok,
         %{
           request: request,
           canonical: canonical,
           estimate: value,
           dropped: Enum.reverse(dropped),
           image_refs_removed: removed
         }}

      :too_large ->
        case drop(memory, segments) do
          {:ok, memory, segments, gone} ->
            fit(input, estimate, memory, segments, Enum.reverse(gone, dropped), removed)

          :none ->
            {:error, :over_limit}
        end

      error ->
        error
    end
  end

  defp request(input, memory, segments) do
    system = %{
      "role" => "system",
      "text" => Enum.join(input.role_instructions ++ input.skill_instructions, "\n\n")
    }

    memory =
      if memory == [],
        do: [],
        else: [%{"role" => "user", "text" => Enum.map_join(memory, "\n", &elem(&1, 1))}]

    history =
      Enum.flat_map(segments, fn
        {:unit, entries} -> Enum.map(entries, & &1.message)
        {:record, entry} -> [entry.message]
      end)

    base = %{
      "version" => 1,
      "model" => input.model,
      "max_output_tokens" => input.max_output_tokens,
      "messages" => [system | memory] ++ history
    }

    if input.tools == [], do: base, else: Map.put(base, "tools", input.tools)
  end

  defp check(request, input, estimate) do
    with :ok <- if(length(request["messages"]) <= 256, do: :ok, else: :too_large),
         {:ok, _, canonical} <-
           Request.decode(Request.canonical(request), input.max_request_bytes),
         {:ok, value} <- estimate(estimate, canonical, input.window) do
      if value.size <= input.window.size, do: {:ok, canonical, value}, else: :too_large
    else
      :too_large -> :too_large
      {:error, :too_large} -> :too_large
      {:error, :estimate_unavailable} = error -> error
      {:error, reason} -> {:error, {:request, reason}}
    end
  end

  defp estimate(estimate, canonical, window) do
    with {:ok, %{} = v} <- estimate.(canonical),
         true <- exact?(v, @estimate_keys),
         true <- is_integer(v.size) and v.size >= 0 and v.unit == :tokens,
         true <- v.direction in [:upper_bound, :approximate],
         true <- v.estimator_id == window.estimator_id,
         true <- v.estimator_version == window.estimator_version do
      {:ok, v}
    else
      _ -> {:error, :estimate_unavailable}
    end
  end

  # Declared drop order: the oldest unit while more than one is left, then the last memory item.

  defp drop(memory, segments) do
    units = Enum.count(segments, &match?({:unit, _}, &1))

    cond do
      units > 1 ->
        index = Enum.find_index(segments, &match?({:unit, _}, &1))
        {{:unit, entries}, rest} = List.pop_at(segments, index)
        {:ok, memory, rest, Enum.map(entries, &%{part: :history, id: &1.id})}

      memory != [] ->
        {id, _} = List.last(memory)
        {:ok, Enum.drop(memory, -1), segments, [%{part: :memory, id: id}]}

      true ->
        :none
    end
  end
end
