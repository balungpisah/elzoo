# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Conversation do
  @moduledoc "Pure bounded preparation and projection for immutable conversation state."

  alias Elzoo.Authorization

  @cure :"Cure.Elzoo.Conversation"
  @max_id_bytes 128
  @max_text_bytes 4096
  @max_messages 64
  @max_associations 64
  @max_resources 64
  @max_encoded_bytes 65_536
  @max_revision 9_223_372_036_854_775_807
  @max_expected_revision @max_revision - 1
  @snapshot_keys [:tenant, :resource, :revision, :fields]
  @request_keys [:operation_id, :resource, :expected_revision, :payload]
  @facts_keys [:tenant, :actor, :data]
  @state_keys ["associations", "messages", "version"]
  @input_keys ["actor", "message_id", "role", "text"]
  @answer_keys ["actor", "input_message_id", "message_id", "role", "run_id", "text"]
  @association_keys ["input_message_id", "run_id"]

  @doc "Prepare one bounded conversation field replacement from exact host DTOs."
  def prepare(snapshot, request, facts) do
    with {:ok, facts} <- validate_facts(facts),
         :ok <- prepare_scope(snapshot, request, facts),
         {:ok, request} <- validate_request(request, facts.mode),
         {:ok, snapshot} <- validate_snapshot(snapshot),
         :ok <- check_revision(request.expected_revision, snapshot.revision),
         {:ok, state, response} <- propose(snapshot.state, request, facts) do
      {:ok,
       [
         %{target: request.resource, field: "conversation", value: encode_state(state)}
       ], response}
    else
      {:error, :invalid_snapshot} -> {:refused, "invalid_snapshot"}
      {:error, code} when is_binary(code) -> {:refused, code}
      {:refused, code} -> {:refused, code}
    end
  end

  @doc "Project a checked conversation when the host-vouched scope grants its resource."
  def view(snapshot, scope) do
    with {:ok, scope} <- validate_read_scope(scope),
         :ok <- read_scope_route(snapshot, scope),
         {:ok, snapshot} <- validate_snapshot(snapshot) do
      {:ok,
       %{
         tenant: snapshot.tenant,
         resource: snapshot.resource,
         revision: snapshot.revision,
         messages: Enum.map(snapshot.state.messages, &view_message/1),
         associations: Enum.map(snapshot.state.associations, &view_association/1)
       }}
    else
      :not_found -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_facts(facts) do
    if exact_plain_map?(facts, @facts_keys) and valid_id?(facts.tenant) and valid_id?(facts.actor) do
      case validate_facts_data(facts.data) do
        {:ok, data} ->
          {:ok, Map.merge(data, %{tenant: facts.tenant, actor: facts.actor})}

        :error ->
          {:error, "invalid_facts"}
      end
    else
      {:error, "invalid_facts"}
    end
  end

  defp validate_facts_data(data) do
    with {:ok, fields} <- portable_record_map(data, 4, false),
         {:ok, mode} <- tagged_mode(Map.get(fields, "mode")),
         true <- exact_string_keys?(fields, fact_keys(mode)),
         {:ok, parsed} <- parse_facts_fields(mode, fields),
         {:ok, normalized} <- normalize_portable(data),
         true <- match?({:record, _}, normalized) do
      {:ok, Map.merge(parsed, %{mode: mode, data: normalized})}
    else
      _ -> :error
    end
  end

  defp fact_keys("append_input"), do: ["mode", "input_role"]
  defp fact_keys("associate_run"), do: ["mode", "run_id"]
  defp fact_keys("append_answer"), do: ["mode", "run_id", "input_message_id", "completed"]
  defp fact_keys(_), do: []

  defp tagged_mode({:text, mode}) when mode in ["append_input", "associate_run", "append_answer"],
    do: {:ok, mode}

  defp tagged_mode(_), do: :error

  defp parse_facts_fields("append_input", fields) do
    with {:text, role} <- Map.get(fields, "input_role"),
         true <- role in ["user", "source"],
         true <- valid_id?(role) do
      {:ok, %{input_role: role}}
    else
      _ -> :error
    end
  end

  defp parse_facts_fields("associate_run", fields) do
    with {:ok, run_id} <- tagged_id(Map.get(fields, "run_id")) do
      {:ok, %{run_id: run_id}}
    else
      _ -> :error
    end
  end

  defp parse_facts_fields("append_answer", fields) do
    with {:ok, run_id} <- tagged_id(Map.get(fields, "run_id")),
         {:ok, input_message_id} <- tagged_id(Map.get(fields, "input_message_id")),
         completed when is_boolean(completed) <- Map.get(fields, "completed") do
      {:ok, %{run_id: run_id, input_message_id: input_message_id, completed: completed}}
    else
      _ -> :error
    end
  end

  defp prepare_scope(snapshot, request, facts) do
    cond do
      not plain_map?(request) or not Map.has_key?(request, :resource) ->
        {:error, "invalid_request"}

      not plain_map?(snapshot) or not Map.has_key?(snapshot, :tenant) or
          not Map.has_key?(snapshot, :resource) ->
        {:error, "invalid_snapshot"}

      not valid_id?(request.resource) or not valid_id?(snapshot.tenant) or
          not valid_id?(snapshot.resource) ->
        {:error, "invalid_scope"}

      facts.tenant != snapshot.tenant or request.resource != snapshot.resource ->
        {:error, "invalid_scope"}

      true ->
        :ok
    end
  end

  defp validate_request(request, mode) do
    if exact_plain_map?(request, @request_keys) do
      with true <- valid_id?(request.operation_id),
           true <- valid_id?(request.resource),
           true <- valid_revision?(request.expected_revision, @max_expected_revision),
           {:ok, payload} <- validate_payload(request.payload, mode) do
        {:ok,
         %{
           operation_id: request.operation_id,
           resource: request.resource,
           expected_revision: request.expected_revision,
           payload: payload
         }}
      else
        _ -> {:error, "invalid_request"}
      end
    else
      {:error, "invalid_request"}
    end
  end

  defp validate_payload(payload, "append_input"), do: validate_message_payload(payload)
  defp validate_payload(payload, "append_answer"), do: validate_message_payload(payload)

  defp validate_payload(payload, "associate_run") do
    if exact_plain_map?(payload, ["message_id"]) and valid_id?(payload["message_id"]) do
      {:ok, %{message_id: payload["message_id"]}}
    else
      :error
    end
  end

  defp validate_message_payload(payload) do
    if exact_plain_map?(payload, ["message_id", "text"]) and valid_id?(payload["message_id"]) and
         valid_message_text?(payload["text"]) do
      {:ok, %{message_id: payload["message_id"], text: payload["text"]}}
    else
      :error
    end
  end

  defp validate_snapshot(snapshot) do
    if exact_plain_map?(snapshot, @snapshot_keys) do
      with true <- valid_id?(snapshot.tenant),
           true <- valid_id?(snapshot.resource),
           true <- valid_revision?(snapshot.revision, @max_revision),
           true <- plain_map?(snapshot.fields),
           {:ok, state} <- validate_fields(snapshot.revision, snapshot.fields) do
        {:ok,
         %{
           tenant: snapshot.tenant,
           resource: snapshot.resource,
           revision: snapshot.revision,
           state: state
         }}
      else
        _ -> {:error, :invalid_snapshot}
      end
    else
      {:error, :invalid_snapshot}
    end
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

  defp check_revision(expected, actual) when expected == actual, do: :ok
  defp check_revision(_, _), do: {:error, "stale_revision"}

  defp propose(state, request, facts) do
    checks = policy_checks(state, request, facts)

    case cure_decision(facts.mode, checks) do
      :proceed -> propose_mode(state, request, facts)
      {:refused, code} -> {:refused, code}
    end
  end

  defp policy_checks(state, request, %{mode: "append_input"}) do
    duplicate = message_id_set(state.messages) |> MapSet.member?(request.payload.message_id)
    checks(duplicate_message_id: duplicate)
  end

  defp policy_checks(state, request, %{mode: "associate_run"}) do
    input_id = request.payload.message_id
    input = Enum.find(state.messages, &(&1.message_id == input_id))

    checks(
      input_exists: input != nil,
      input_is_input: input != nil and input.role in ["user", "source"],
      already_associated: Enum.any?(state.associations, &(&1.input_message_id == input_id))
    )
  end

  defp policy_checks(state, request, %{mode: "append_answer"} = facts) do
    input_id = facts.input_message_id
    input = Enum.find(state.messages, &(&1.message_id == input_id))
    association = Enum.find(state.associations, &(&1.input_message_id == input_id))

    checks(
      duplicate_message_id:
        MapSet.member?(message_id_set(state.messages), request.payload.message_id),
      input_exists: input != nil,
      input_is_input: input != nil and input.role in ["user", "source"],
      association_exists: association != nil,
      association_matches: association != nil and association.run_id == facts.run_id,
      already_answered:
        Enum.any?(state.messages, fn message ->
          message.role == "assistant" and message.input_message_id == input_id
        end),
      completed: facts.completed
    )
  end

  defp checks(opts) do
    defaults = [
      duplicate_message_id: false,
      input_exists: false,
      input_is_input: false,
      already_associated: false,
      association_exists: false,
      association_matches: false,
      already_answered: false,
      completed: false
    ]

    Keyword.merge(defaults, opts) |> Map.new()
  end

  defp propose_mode(state, request, %{mode: "append_input"} = facts) do
    message = %{
      message_id: request.payload.message_id,
      role: facts.input_role,
      actor: facts.actor,
      text: request.payload.text
    }

    prospective(
      %{state | messages: state.messages ++ [message]},
      fn revision ->
        response([{"message_id", {:text, message.message_id}}, {"revision", revision}])
      end,
      request.expected_revision
    )
  end

  defp propose_mode(state, request, %{mode: "associate_run"} = facts) do
    association = %{input_message_id: request.payload.message_id, run_id: facts.run_id}

    prospective(
      %{state | associations: state.associations ++ [association]},
      fn revision ->
        response([
          {"message_id", {:text, association.input_message_id}},
          {"revision", revision},
          {"run_id", {:text, association.run_id}}
        ])
      end,
      request.expected_revision
    )
  end

  defp propose_mode(state, request, %{mode: "append_answer"} = facts) do
    message = %{
      message_id: request.payload.message_id,
      role: "assistant",
      actor: facts.actor,
      text: request.payload.text,
      run_id: facts.run_id,
      input_message_id: facts.input_message_id
    }

    prospective(
      %{state | messages: state.messages ++ [message]},
      fn revision ->
        response([
          {"input_message_id", {:text, message.input_message_id}},
          {"message_id", {:text, message.message_id}},
          {"revision", revision},
          {"run_id", {:text, message.run_id}}
        ])
      end,
      request.expected_revision
    )
  end

  defp prospective(next_state, response_builder, expected_revision) do
    value = encode_state(next_state)

    with true <- length(next_state.messages) <= @max_messages,
         true <- length(next_state.associations) <= @max_associations,
         {:ok, ^value} <- normalize_portable(value),
         true <- encoded_size(value) <= @max_encoded_bytes do
      {:ok, next_state, response_builder.(expected_revision + 1)}
    else
      _ -> {:refused, "capacity"}
    end
  end

  defp encode_state(state) do
    {:record,
     [
       {"associations", {:list, Enum.map(state.associations, &encode_association/1)}},
       {"messages", {:list, Enum.map(state.messages, &encode_message/1)}},
       {"version", 1}
     ]}
  end

  defp encode_message(%{role: "assistant"} = message) do
    {:record,
     [
       {"actor", {:text, message.actor}},
       {"input_message_id", {:text, message.input_message_id}},
       {"message_id", {:text, message.message_id}},
       {"role", {:text, message.role}},
       {"run_id", {:text, message.run_id}},
       {"text", {:text, message.text}}
     ]}
  end

  defp encode_message(message) do
    {:record,
     [
       {"actor", {:text, message.actor}},
       {"message_id", {:text, message.message_id}},
       {"role", {:text, message.role}},
       {"text", {:text, message.text}}
     ]}
  end

  defp encode_association(association) do
    {:record,
     [
       {"input_message_id", {:text, association.input_message_id}},
       {"run_id", {:text, association.run_id}}
     ]}
  end

  defp response(pairs) do
    {:record, Enum.sort_by(pairs, &elem(&1, 0))}
  end

  defp view_message(%{role: "assistant"} = message) do
    %{
      actor: message.actor,
      input_message_id: message.input_message_id,
      message_id: message.message_id,
      role: message.role,
      run_id: message.run_id,
      text: message.text
    }
  end

  defp view_message(message) do
    %{actor: message.actor, message_id: message.message_id, role: message.role, text: message.text}
  end

  defp view_association(association) do
    %{input_message_id: association.input_message_id, run_id: association.run_id}
  end

  defp message_id_set(messages), do: MapSet.new(Enum.map(messages, & &1.message_id))

  defp cure_decision(mode, checks) when is_map(checks) do
    flags = [
      checks.duplicate_message_id,
      checks.input_exists,
      checks.input_is_input,
      checks.already_associated,
      checks.association_exists,
      checks.association_matches,
      checks.already_answered,
      checks.completed
    ]

    cure_mode =
      case mode do
        "append_input" -> :AppendInput
        "associate_run" -> :AssociateRun
        "append_answer" -> :AppendAnswer
      end

    raw = apply(@cure, :decide, [cure_mode, List.to_tuple([:ConversationChecks | flags])])

    case raw do
      :ConversationProceed -> :proceed
      :ConversationDuplicateMessageId -> {:refused, "duplicate_message_id"}
      :ConversationMissingInput -> {:refused, "missing_input"}
      :ConversationAlreadyAssociated -> {:refused, "already_associated"}
      :ConversationRunNotCompleted -> {:refused, "run_not_completed"}
      :ConversationAssociationMismatch -> {:refused, "association_mismatch"}
      :ConversationAlreadyAnswered -> {:refused, "already_answered"}
    end
  end

  defp validate_read_scope(scope) do
    if exact_plain_map?(scope, [:tenant, :actor, :resources]) and valid_id?(scope.tenant) and
         valid_id?(scope.actor) do
      case bounded_proper_list(scope.resources, @max_resources) do
        {:ok, resources} ->
          if Enum.all?(resources, &valid_id?/1),
            do: {:ok, %{tenant: scope.tenant, actor: scope.actor, resources: resources}},
            else: {:error, :invalid_scope}

        _ ->
          {:error, :invalid_scope}
      end
    else
      {:error, :invalid_scope}
    end
  end

  defp read_scope_route(snapshot, scope) do
    cond do
      not plain_map?(snapshot) ->
        {:error, :invalid_snapshot}

      not Map.has_key?(snapshot, :tenant) or not Map.has_key?(snapshot, :resource) ->
        {:error, :invalid_snapshot}

      not valid_id?(snapshot.tenant) or not valid_id?(snapshot.resource) ->
        {:error, :invalid_snapshot}

      snapshot.tenant != scope.tenant or snapshot.resource not in scope.resources ->
        :not_found

      true ->
        :ok
    end
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
