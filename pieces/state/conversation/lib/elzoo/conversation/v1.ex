# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Conversation.V1 do
  @moduledoc """
  The version 1 rules, kept only for `Elzoo.Conversation.import_v1/3`: the
  exact resource snapshot that `CheckedCommand.resource/3` returns for a
  version 1 conversation, its canonical portable state (validated and
  normalized by `Elzoo.Authorization.validate_value/1`), the 64-message,
  64-association and 65,536-byte bounds and the consistency rules. This is the
  Piece's only use of `domain/authorization`.
  """
  alias Elzoo.Authorization

  @max_id_bytes 128
  @max_text_bytes 4096
  @max_messages 64
  @max_associations 64
  @max_encoded_bytes 65_536
  @max_revision 9_223_372_036_854_775_807
  @snapshot_keys [:tenant, :resource, :revision, :fields]
  @state_keys ["associations", "messages", "version"]
  @input_keys ["actor", "message_id", "role", "text"]
  @answer_keys ["actor", "input_message_id", "message_id", "role", "run_id", "text"]
  @association_keys ["input_message_id", "run_id"]

  @doc """
  Validate a version 1 snapshot. Returns `{:ok, %{messages: messages,
  associations: associations}}` with the ordered message list (inputs with
  `message_id`, `role`, `actor`, `text`; answers also with `run_id` and
  `input_message_id` and role `"assistant"`) and the association list, or
  `{:error, :invalid_snapshot}`.
  """
  def parse(snapshot) do
    if exact_plain_map?(snapshot, @snapshot_keys) do
      with true <- valid_id?(snapshot.tenant),
           true <- valid_id?(snapshot.resource),
           true <- valid_revision?(snapshot.revision, @max_revision),
           true <- plain_map?(snapshot.fields),
           {:ok, state} <- validate_fields(snapshot.revision, snapshot.fields) do
        {:ok, state}
      else
        _ -> {:error, :invalid_snapshot}
      end
    else
      {:error, :invalid_snapshot}
    end
  rescue
    _ -> {:error, :invalid_snapshot}
  end

  defp validate_fields(0, fields) when map_size(fields) == 0,
    do: {:ok, %{messages: [], associations: []}}

  defp validate_fields(revision, fields) when revision > 0 and map_size(fields) == 1 do
    if Map.has_key?(fields, "conversation") do
      parse_state(Map.fetch!(fields, "conversation"))
    else
      :error
    end
  end

  defp validate_fields(_, _), do: :error

  defp parse_state(value) do
    with {:ok, fields} <- canonical_record_map(value, @state_keys, 3),
         1 <- Map.get(fields, "version"),
         {:ok, messages} <- parse_messages(Map.get(fields, "messages")),
         true <- messages != [],
         {:ok, associations} <- parse_associations(Map.get(fields, "associations")),
         :ok <- consistent_state(messages, associations),
         {:ok, ^value} <- normalize_portable(value),
         true <- encoded_size(value) <= @max_encoded_bytes do
      {:ok, %{messages: messages, associations: associations}}
    else
      _ -> :error
    end
  end

  defp parse_messages({:list, values}) do
    with {:ok, values} <- bounded_proper_list(values, @max_messages) do
      reduce_parsed(values, &parse_message/1)
    else
      _ -> :error
    end
  end

  defp parse_messages(_), do: :error

  defp parse_message(value) do
    with {:ok, fields} <- canonical_record_map(value, nil, 6),
         {:text, role} <- Map.get(fields, "role"),
         {:ok, message} <- parse_message_fields(role, fields) do
      {:ok, message}
    else
      _ -> :error
    end
  end

  defp parse_message_fields(role, fields) when role in ["user", "source"] do
    with true <- exact_string_keys?(fields, @input_keys),
         {:ok, message_id} <- tagged_id(Map.get(fields, "message_id")),
         {:ok, actor} <- tagged_id(Map.get(fields, "actor")),
         {:ok, text} <- tagged_message_text(Map.get(fields, "text")) do
      {:ok, %{message_id: message_id, role: role, actor: actor, text: text}}
    else
      _ -> :error
    end
  end

  defp parse_message_fields("assistant", fields) do
    with true <- exact_string_keys?(fields, @answer_keys),
         {:ok, message_id} <- tagged_id(Map.get(fields, "message_id")),
         {:ok, actor} <- tagged_id(Map.get(fields, "actor")),
         {:ok, text} <- tagged_message_text(Map.get(fields, "text")),
         {:ok, run_id} <- tagged_id(Map.get(fields, "run_id")),
         {:ok, input_message_id} <- tagged_id(Map.get(fields, "input_message_id")) do
      {:ok,
       %{
         message_id: message_id,
         role: "assistant",
         actor: actor,
         text: text,
         run_id: run_id,
         input_message_id: input_message_id
       }}
    else
      _ -> :error
    end
  end

  defp parse_message_fields(_, _), do: :error

  defp parse_associations({:list, values}) do
    with {:ok, values} <- bounded_proper_list(values, @max_associations) do
      reduce_parsed(values, &parse_association/1)
    else
      _ -> :error
    end
  end

  defp parse_associations(_), do: :error

  defp parse_association(value) do
    with {:ok, fields} <- canonical_record_map(value, @association_keys, 2),
         {:ok, input_message_id} <- tagged_id(Map.get(fields, "input_message_id")),
         {:ok, run_id} <- tagged_id(Map.get(fields, "run_id")) do
      {:ok, %{input_message_id: input_message_id, run_id: run_id}}
    else
      _ -> :error
    end
  end

  defp reduce_parsed(values, parser) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case parser.(value) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      :error -> :error
    end
  end

  defp consistent_state(messages, associations) do
    ids = Enum.map(messages, & &1.message_id)
    message_by_id = Map.new(messages, &{&1.message_id, &1})

    index_by_id =
      messages
      |> Enum.with_index()
      |> Map.new(fn {message, index} -> {message.message_id, index} end)

    with true <- MapSet.size(MapSet.new(ids)) == length(ids),
         {:ok, association_by_input} <- unique_associations(associations),
         :ok <- associations_reference_inputs(association_by_input, message_by_id),
         :ok <-
           answers_reference_associations(
             messages,
             message_by_id,
             index_by_id,
             association_by_input
           ) do
      :ok
    else
      _ -> :error
    end
  end

  defp unique_associations(associations) do
    pairs = Enum.map(associations, &{&1.input_message_id, &1.run_id})
    inputs = Enum.map(pairs, &elem(&1, 0))

    if MapSet.size(MapSet.new(inputs)) == length(inputs) do
      {:ok, Map.new(pairs)}
    else
      :error
    end
  end

  defp associations_reference_inputs(association_by_input, message_by_id) do
    if Enum.all?(association_by_input, fn {input_id, _run_id} ->
         case Map.get(message_by_id, input_id) do
           %{role: role} when role in ["user", "source"] -> true
           _ -> false
         end
       end) do
      :ok
    else
      :error
    end
  end

  defp answers_reference_associations(messages, message_by_id, index_by_id, association_by_input) do
    answers = Enum.filter(messages, &(&1.role == "assistant"))
    input_ids = Enum.map(answers, & &1.input_message_id)

    valid_answers? =
      MapSet.size(MapSet.new(input_ids)) == length(input_ids) and
        Enum.all?(answers, fn answer ->
          input = Map.get(message_by_id, answer.input_message_id)

          match?(%{role: role} when role in ["user", "source"], input) and
            Map.fetch!(index_by_id, answer.input_message_id) <
              Map.fetch!(index_by_id, answer.message_id) and
            Map.get(association_by_input, answer.input_message_id) == answer.run_id
        end)

    if valid_answers?, do: :ok, else: :error
  end

  defp canonical_record_map(value, expected_keys, max_fields) do
    with {:ok, fields} <- portable_record_map(value, max_fields, true),
         true <- is_nil(expected_keys) or exact_string_keys?(fields, expected_keys) do
      {:ok, fields}
    else
      _ -> :error
    end
  end

  defp portable_record_map({:record, pairs}, max_fields, canonical?) do
    with {:ok, pairs} <- bounded_proper_list(pairs, max_fields),
         true <- Enum.all?(pairs, &match?({name, _} when is_binary(name), &1)),
         names <- Enum.map(pairs, &elem(&1, 0)),
         true <- Enum.all?(names, &(byte_size(&1) <= 4096)),
         true <- MapSet.size(MapSet.new(names)) == length(names),
         true <- not canonical? or Enum.sort(names) == names do
      {:ok, Map.new(pairs)}
    else
      _ -> :error
    end
  end

  defp portable_record_map(_, _, _), do: :error

  defp exact_string_keys?(map, expected) do
    map_size(map) == length(expected) and Enum.all?(expected, &Map.has_key?(map, &1))
  end

  defp bounded_proper_list(list, limit), do: bounded_proper_list(list, limit, 0, [])

  defp bounded_proper_list([], _limit, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp bounded_proper_list([head | tail], limit, count, acc) when count < limit,
    do: bounded_proper_list(tail, limit, count + 1, [head | acc])

  defp bounded_proper_list([_ | _], _limit, _count, _acc), do: :error
  defp bounded_proper_list(_, _, _, _), do: :error

  defp normalize_portable(value) do
    case Authorization.validate_value(value) do
      {:ok, normalized} -> {:ok, normalized}
      _ -> :error
    end
  end

  defp encoded_size(value), do: byte_size(:erlang.term_to_binary(value))

  defp tagged_id({:text, value}) do
    if valid_id?(value), do: {:ok, value}, else: :error
  end

  defp tagged_id(_), do: :error

  defp tagged_message_text({:text, value}) do
    if valid_message_text?(value), do: {:ok, value}, else: :error
  end

  defp tagged_message_text(_), do: :error

  defp valid_id?(value) when is_binary(value) do
    byte_size(value) in 1..@max_id_bytes and String.valid?(value) and
      :binary.match(value, <<0>>) == :nomatch
  end

  defp valid_id?(_), do: false

  defp valid_message_text?(value) when is_binary(value),
    do: byte_size(value) in 1..@max_text_bytes and String.valid?(value)

  defp valid_message_text?(_), do: false

  defp valid_revision?(value, max), do: is_integer(value) and value >= 0 and value <= max

  defp exact_plain_map?(value, keys) do
    plain_map?(value) and map_size(value) == length(keys) and
      Enum.all?(keys, &Map.has_key?(value, &1))
  end

  defp plain_map?(value), do: is_map(value) and not is_struct(value)
end
